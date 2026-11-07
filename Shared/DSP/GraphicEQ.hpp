// NoMore EQ — zero-latency 32-band cascade graphic EQ.
//
// The analyzer produces a desired gain per band. Because neighbouring peaking
// filters overlap, setting each filter to its band's gain would overshoot.
// Following the least-squares design idea from Välimäki & Liski, "Accurate
// Cascade Graphic Equalizer" (IEEE SPL, 2017), an interaction matrix is
// measured once per sample rate. Its regularised pseudo-inverse then maps
// desired band gains → filter gains with a single matrix-vector product.
//
// Filter gains glide toward their targets every 32 samples, which keeps
// coefficient changes inaudible.
#pragma once

#include <array>
#include <vector>
#include <complex>
#include <cmath>
#include <algorithm>

#include "BandLayout.hpp"

namespace nmeq {

class GraphicEQ {
public:
    static constexpr int kMaxChannels = 8;
    static constexpr int kSubBlock = 32;

    // Allocates. Call from a non-realtime thread.
    void prepare(double sampleRate, const BandLayout& layout, int channels) {
        channels_ = std::max(1, std::min(channels, kMaxChannels));
        constexpr int N = kNumBands;

        for (int k = 0; k < N; ++k) {
            const double fc = layout.center[size_t(k)];
            double bw;
            if (k == 0)           bw = layout.center[1] - layout.center[0];
            else if (k == N - 1)  bw = layout.center[size_t(N - 1)] - layout.center[size_t(N - 2)];
            else                  bw = 0.5 * (layout.center[size_t(k + 1)] - layout.center[size_t(k - 1)]);
            const double q = fc / bw;
            const double w0 = 2.0 * M_PI * fc / sampleRate;
            cosW_[size_t(k)] = std::cos(w0);
            alpha_[size_t(k)] = std::sin(w0) / (2.0 * q);
        }

        // Design points: every band centre plus the ERB midpoint between neighbours.
        constexpr int M = kDesignPoints;
        std::array<double, M> w{};
        for (int m = 0; m < M; ++m) {
            double hz;
            if (m % 2 == 0) hz = layout.center[size_t(m / 2)];
            else hz = erbNumberToHz(0.5 * (hzToErbNumber(layout.center[size_t(m / 2)]) +
                                           hzToErbNumber(layout.center[size_t(m / 2 + 1)])));
            w[size_t(m)] = 2.0 * M_PI * hz / sampleRate;
        }

        // Interaction matrix B (M×N): dB response of filter j at point m, per dB of gain.
        constexpr double prototypeDb = 8.0;
        std::vector<double> B(size_t(M * N));
        for (int m = 0; m < M; ++m)
            for (int j = 0; j < N; ++j)
                B[size_t(m * N + j)] = responseDb(j, prototypeDb, w[size_t(m)]) / prototypeDb;

        // P = (BᵀB + λI)⁻¹ Bᵀ  (N×M)
        std::vector<double> A(size_t(N * N), 0.0);
        for (int i = 0; i < N; ++i)
            for (int j = 0; j < N; ++j) {
                double sum = 0.0;
                for (int m = 0; m < M; ++m) sum += B[size_t(m * N + i)] * B[size_t(m * N + j)];
                A[size_t(i * N + j)] = sum + (i == j ? 1e-2 : 0.0);
            }
        std::vector<double> Ainv = invert(A, N);
        for (int i = 0; i < N; ++i)
            for (int m = 0; m < M; ++m) {
                double sum = 0.0;
                for (int k = 0; k < N; ++k) sum += Ainv[size_t(i * N + k)] * B[size_t(m * N + k)];
                P_[size_t(i)][size_t(m)] = float(sum);
            }

        glide_ = float(1.0 - std::exp(-double(kSubBlock) / (0.030 * sampleRate)));
        reset();
    }

    void reset() {
        for (auto& ch : state_) for (auto& s : ch) s = {0.0f, 0.0f};
        targetDb_.fill(0.0f);
        currentDb_.fill(0.0f);
        for (int k = 0; k < kNumBands; ++k) computeCoefs(k, 0.0f);
    }

    // Realtime-safe. Desired gain per band (dB) → filter gains.
    void setBandGainsDb(const std::array<float, kNumBands>& bandDb) {
        std::array<float, kDesignPoints> t{};
        for (int m = 0; m < kDesignPoints; ++m)
            t[size_t(m)] = (m % 2 == 0) ? bandDb[size_t(m / 2)]
                                        : 0.5f * (bandDb[size_t(m / 2)] + bandDb[size_t(m / 2 + 1)]);
        for (int k = 0; k < kNumBands; ++k) {
            float g = 0.0f;
            for (int m = 0; m < kDesignPoints; ++m) g += P_[size_t(k)][size_t(m)] * t[size_t(m)];
            targetDb_[size_t(k)] = std::min(18.0f, std::max(-18.0f, g));
        }
    }

    // Realtime-safe, in-place on `io`.
    void process(float* const* io, int channels, int frames) {
        channels = std::min(channels, channels_);
        for (int start = 0; start < frames; start += kSubBlock) {
            const int n = std::min(kSubBlock, frames - start);

            for (int k = 0; k < kNumBands; ++k) {
                const float diff = targetDb_[size_t(k)] - currentDb_[size_t(k)];
                if (std::fabs(diff) > 1e-4f) {
                    currentDb_[size_t(k)] += diff * glide_;
                    computeCoefs(k, currentDb_[size_t(k)]);
                }
            }

            for (int ch = 0; ch < channels; ++ch) {
                float* x = io[ch] + start;
                auto& st = state_[size_t(ch)];
                for (int k = 0; k < kNumBands; ++k) {
                    const Coefs c = coefs_[size_t(k)];
                    float z1 = st[size_t(k)][0], z2 = st[size_t(k)][1];
                    for (int i = 0; i < n; ++i) {
                        const float in = x[i];
                        const float out = c.b0 * in + z1;
                        z1 = c.b1 * in - c.a1 * out + z2;
                        z2 = c.b2 * in - c.a2 * out;
                        x[i] = out;
                    }
                    // Flush denormals once per sub-block.
                    st[size_t(k)][0] = std::fabs(z1) < 1e-20f ? 0.0f : z1;
                    st[size_t(k)][1] = std::fabs(z2) < 1e-20f ? 0.0f : z2;
                }
            }
        }
    }

    const std::array<float, kNumBands>& filterGainsDb() const { return currentDb_; }

private:
    static constexpr int kDesignPoints = 2 * kNumBands - 1;

    struct Coefs { float b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0; };

    void computeCoefs(int k, float gainDb) {
        const double A = std::pow(10.0, double(gainDb) / 40.0);
        const double al = alpha_[size_t(k)], cw = cosW_[size_t(k)];
        const double a0 = 1.0 + al / A;
        Coefs& c = coefs_[size_t(k)];
        c.b0 = float((1.0 + al * A) / a0);
        c.b1 = float(-2.0 * cw / a0);
        c.b2 = float((1.0 - al * A) / a0);
        c.a1 = float(-2.0 * cw / a0);
        c.a2 = float((1.0 - al / A) / a0);
    }

    double responseDb(int k, double gainDb, double w) const {
        const double A = std::pow(10.0, gainDb / 40.0);
        const double al = alpha_[size_t(k)], cw = cosW_[size_t(k)];
        const std::complex<double> z1 = std::polar(1.0, -w), z2 = std::polar(1.0, -2.0 * w);
        const std::complex<double> num = (1.0 + al * A) + (-2.0 * cw) * z1 + (1.0 - al * A) * z2;
        const std::complex<double> den = (1.0 + al / A) + (-2.0 * cw) * z1 + (1.0 - al / A) * z2;
        return 20.0 * std::log10(std::abs(num) / std::abs(den));
    }

    // Gauss–Jordan inverse with partial pivoting.
    static std::vector<double> invert(std::vector<double> a, int n) {
        std::vector<double> inv(size_t(n * n), 0.0);
        for (int i = 0; i < n; ++i) inv[size_t(i * n + i)] = 1.0;
        for (int col = 0; col < n; ++col) {
            int pivot = col;
            for (int r = col + 1; r < n; ++r)
                if (std::fabs(a[size_t(r * n + col)]) > std::fabs(a[size_t(pivot * n + col)])) pivot = r;
            if (pivot != col)
                for (int c = 0; c < n; ++c) {
                    std::swap(a[size_t(col * n + c)], a[size_t(pivot * n + c)]);
                    std::swap(inv[size_t(col * n + c)], inv[size_t(pivot * n + c)]);
                }
            const double d = a[size_t(col * n + col)];
            for (int c = 0; c < n; ++c) { a[size_t(col * n + c)] /= d; inv[size_t(col * n + c)] /= d; }
            for (int r = 0; r < n; ++r) {
                if (r == col) continue;
                const double f = a[size_t(r * n + col)];
                if (f == 0.0) continue;
                for (int c = 0; c < n; ++c) {
                    a[size_t(r * n + c)] -= f * a[size_t(col * n + c)];
                    inv[size_t(r * n + c)] -= f * inv[size_t(col * n + c)];
                }
            }
        }
        return inv;
    }

    int channels_ = 2;
    std::array<double, kNumBands> cosW_{}, alpha_{};
    std::array<std::array<float, kDesignPoints>, kNumBands> P_{};
    std::array<Coefs, kNumBands> coefs_{};
    std::array<float, kNumBands> targetDb_{}, currentDb_{};
    std::array<std::array<std::array<float, 2>, kNumBands>, kMaxChannels> state_{};
    float glide_ = 0.1f;
};

} // namespace nmeq
