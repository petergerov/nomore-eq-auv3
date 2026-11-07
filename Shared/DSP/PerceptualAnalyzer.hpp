// NoMore EQ — perceptual analysis side-chain.
//
// Runs on a mono sum of the input, never on the audio path, so it adds no
// latency. Every hop it:
//   1. takes a Hann-windowed FFT and integrates power into 32, 48 or 64 ERB
//      bands, normalised to energy per reference (32-layout) band,
//   2. applies equal-loudness weighting to get a perceptual band level,
//   3. compares each band with its local spectral envelope (peaks → "tame",
//      dips → "recover"),
//   4. estimates how strongly each band is masked by its neighbours using an
//      asymmetric spreading function (upward spread of masking is wider than
//      downward), and lifts bands that are buried ("recover"),
//   5. smooths the resulting gain curve across bands and over time.
//
// Widths that describe the signal (the local envelope, masking) are set in
// ERB, so a finer layout resolves narrower peaks without cutting or lifting
// harder overall.
#pragma once

#include <Accelerate/Accelerate.h>
#include <array>
#include <vector>
#include <algorithm>
#include <cmath>

#include "BandLayout.hpp"

namespace nmeq {

struct AnalysisSettings {
    float recover  = 0.4f;     // 0 … 1
    float tame     = 0.4f;     // 0 … 1
    float bias     = 0.0f;     // -1 … 1
    float lowHz    = 30.0f;
    float highHz   = 18000.0f;
};

class PerceptualAnalyzer {
public:
    static constexpr float kMaxBoostDb = 9.0f;
    static constexpr float kMaxCutDb   = 12.0f;

    PerceptualAnalyzer() = default;
    PerceptualAnalyzer(const PerceptualAnalyzer&) = delete;
    PerceptualAnalyzer& operator=(const PerceptualAnalyzer&) = delete;
    ~PerceptualAnalyzer() { if (fftSetup_) vDSP_destroy_fftsetup(fftSetup_); }

    // Allocates. Call from a non-realtime thread.
    void prepare(double sampleRate, const BandLayout& layout) {
        sampleRate_ = sampleRate;
        n_ = layout.count;
        relativeStep_ = float(layout.relativeStep);
        fftSize_ = sampleRate <= 50000.0 ? 2048 : (sampleRate <= 100000.0 ? 4096 : 8192);
        log2n_ = vDSP_Length(std::lround(std::log2(double(fftSize_))));
        hop_ = fftSize_ / 4;

        if (fftSetup_) vDSP_destroy_fftsetup(fftSetup_);
        fftSetup_ = vDSP_create_fftsetup(log2n_, kFFTRadix2);

        ring_.assign(size_t(fftSize_), 0.0f);
        frame_.assign(size_t(fftSize_), 0.0f);
        window_.assign(size_t(fftSize_), 0.0f);
        vDSP_hann_window(window_.data(), vDSP_Length(fftSize_), vDSP_HANN_NORM);
        real_.assign(size_t(fftSize_ / 2), 0.0f);
        imag_.assign(size_t(fftSize_ / 2), 0.0f);
        power_.assign(size_t(fftSize_ / 2 + 1), 0.0f);

        // A full-scale sine reads ~0 dB. vDSP_fft_zrip output is 2x the
        // textbook DFT, so the textbook 4/(N·Σw²) becomes 1/(N·Σw²).
        double sumW2 = 0.0;
        for (float w : window_) sumW2 += double(w) * double(w);
        norm_ = 1.0 / (double(fftSize_) * sumW2);

        // Fractional bin → band integration weights.
        const double binHz = sampleRate / double(fftSize_);
        const int lastBin = fftSize_ / 2;
        for (int b = 0; b < n_; ++b) {
            auto& span = spans_[size_t(b)];
            span.weights.clear();
            span.first = -1;
            for (int k = 0; k <= lastBin; ++k) {
                const double lo = (k - 0.5) * binHz, hi = (k + 0.5) * binHz;
                const double overlap = std::min(hi, layout.upper[size_t(b)]) - std::max(lo, layout.lower[size_t(b)]);
                if (overlap <= 0.0) { if (span.first >= 0) break; continue; }
                if (span.first < 0) span.first = k;
                span.weights.push_back(float(overlap / binHz));
            }
            if (span.first < 0) { span.first = 0; span.weights.assign(1, 0.0f); }
        }

        for (int b = 0; b < n_; ++b) {
            centers_[size_t(b)] = float(layout.center[size_t(b)]);
            loudnessWeightDb_[size_t(b)] = float(0.5 * aWeightingDb(layout.center[size_t(b)]));
        }

        // Asymmetric spreading function in ERB units. A masker spreads 10 dB
        // + 10 dB/ERB toward higher bands and 10 dB + 25 dB/ERB toward lower.
        for (int j = 0; j < n_; ++j) {
            for (int b = 0; b < n_; ++b) {
                if (j == b) { spread_[size_t(j)][size_t(b)] = 0.0f; continue; }
                const double dErb = double(b - j) * layout.erbStep;
                const double attDb = dErb > 0.0 ? 10.0 + 10.0 * dErb : 10.0 + 25.0 * -dErb;
                spread_[size_t(j)][size_t(b)] = float(std::pow(10.0, -attDb / 10.0));
            }
        }
        // Local envelope: a Gaussian of 2 reference bands (about 2.5 ERB),
        // cut off at 6, whatever the band count.
        const double sigma = 2.0 / layout.relativeStep;
        envelopeRadius_ = std::min(kMaxEnvelopeRadius, int(std::lround(6.0 / layout.relativeStep)));
        for (int d = 0; d <= envelopeRadius_; ++d)
            envelopeKernel_[size_t(d)] = float(std::exp(-0.5 * (d / sigma) * (d / sigma)));

        const double hopSeconds = double(hop_) / sampleRate;
        attackCoef_  = float(std::exp(-hopSeconds / 0.020));
        releaseCoef_ = float(std::exp(-hopSeconds / 0.250));
        gainCoef_    = float(std::exp(-hopSeconds / 0.150));

        reset();
    }

    void reset() {
        std::fill(ring_.begin(), ring_.end(), 0.0f);
        writePos_ = 0;
        hopCounter_ = 0;
        energy_.fill(0.0f);
        levelDb_.fill(-120.0f);
        perceptualDb_.fill(-120.0f);
        gainDb_.fill(0.0f);
    }

    // Realtime-safe. Returns true if a new gain curve was produced.
    bool push(const float* mono, int frames, const AnalysisSettings& settings) {
        bool updated = false;
        const int mask = fftSize_ - 1;
        for (int i = 0; i < frames; ++i) {
            ring_[size_t(writePos_)] = mono[i];
            writePos_ = (writePos_ + 1) & mask;
            if (++hopCounter_ >= hop_) {
                hopCounter_ = 0;
                analyzeFrame(settings);
                updated = true;
            }
        }
        return updated;
    }

    const std::array<float, kMaxBands>& gainDb() const { return gainDb_; }
    const std::array<float, kMaxBands>& perceptualLevelDb() const { return perceptualDb_; }
    const std::array<float, kMaxBands>& centers() const { return centers_; }
    int bandCount() const { return n_; }

private:
    static constexpr int kMaxEnvelopeRadius = 16;

    struct BinSpan { int first = 0; std::vector<float> weights; };

    static float clampf(float x, float lo, float hi) { return std::min(hi, std::max(lo, x)); }
    static float smoothstep01(float x) { x = clampf(x, 0.0f, 1.0f); return x * x * (3.0f - 2.0f * x); }

    float rangeWeight(int b, const AnalysisSettings& s) const {
        const float fc = centers_[size_t(b)];
        const float inLow  = std::log2(fc / std::max(1.0f, s.lowHz));
        const float inHigh = std::log2(std::max(1.0f, s.highHz) / fc);
        // 0 half an octave outside the edge, 1 a quarter octave inside it.
        return smoothstep01((inLow + 0.5f) / 0.75f) * smoothstep01((inHigh + 0.5f) / 0.75f);
    }

    void analyzeFrame(const AnalysisSettings& s) {
        const int n = fftSize_, half = n / 2, mask = n - 1;

        for (int i = 0; i < n; ++i)
            frame_[size_t(i)] = ring_[size_t((writePos_ + i) & mask)] * window_[size_t(i)];

        DSPSplitComplex split{ real_.data(), imag_.data() };
        vDSP_ctoz(reinterpret_cast<const DSPComplex*>(frame_.data()), 2, &split, 1, vDSP_Length(half));
        vDSP_fft_zrip(fftSetup_, &split, 1, log2n_, FFT_FORWARD);

        power_[0] = real_[0] * real_[0];
        power_[size_t(half)] = imag_[0] * imag_[0];
        for (int k = 1; k < half; ++k)
            power_[size_t(k)] = real_[size_t(k)] * real_[size_t(k)] + imag_[size_t(k)] * imag_[size_t(k)];

        // 1–2. Band energy (attack/release smoothed) → perceptual level.
        double total = 0.0;
        float maxPerceptual = -200.0f;
        std::array<float, kMaxBands> perceptualLin{};
        for (int b = 0; b < n_; ++b) {
            const auto& span = spans_[size_t(b)];
            double e = 0.0;
            for (size_t i = 0; i < span.weights.size(); ++i)
                e += double(power_[size_t(span.first) + i]) * double(span.weights[i]);
            const float ef = float(e * norm_) / relativeStep_;
            const float coef = ef > energy_[size_t(b)] ? attackCoef_ : releaseCoef_;
            energy_[size_t(b)] = coef * energy_[size_t(b)] + (1.0f - coef) * ef;
            total += energy_[size_t(b)];

            levelDb_[size_t(b)] = 10.0f * std::log10(energy_[size_t(b)] + 1e-12f);
            perceptualDb_[size_t(b)] = levelDb_[size_t(b)] + loudnessWeightDb_[size_t(b)];
            perceptualLin[size_t(b)] = std::pow(10.0f, perceptualDb_[size_t(b)] / 10.0f);
            maxPerceptual = std::max(maxPerceptual, perceptualDb_[size_t(b)]);
        }
        const float frameDb = 10.0f * std::log10(float(total) + 1e-12f);
        const bool active = frameDb > -60.0f;

        // 3–4. Deviation from local envelope, and signal-to-mask ratio.
        const float tameThreshold = 1.5f + 3.0f * s.bias;    // + bias → tame less
        const float dipThreshold  = 1.5f - 1.0f * s.bias;    // + bias → recover more
        const float maskThreshold = 10.0f + 6.0f * s.bias;

        std::array<float, kMaxBands> raw{};
        for (int b = 0; b < n_; ++b) {
            if (!active) { raw[size_t(b)] = 0.0f; continue; }

            float num = 0.0f, den = 0.0f;
            for (int d = -envelopeRadius_; d <= envelopeRadius_; ++d) {
                const int j = b + d;
                if (j < 0 || j >= n_) continue;
                const float w = envelopeKernel_[size_t(std::abs(d))] * (d == 0 ? 0.5f : 1.0f);
                num += w * perceptualDb_[size_t(j)];
                den += w;
            }
            const float deviation = perceptualDb_[size_t(b)] - num / den;

            // Levels are per reference band, so weight each masker by how
            // much of a reference band it spans.
            float masking = 0.0f;
            for (int j = 0; j < n_; ++j)
                masking += perceptualLin[size_t(j)] * spread_[size_t(j)][size_t(b)];
            masking = masking * relativeStep_ + 1e-12f;
            const float smr = perceptualDb_[size_t(b)] - 10.0f * std::log10(masking);

            // Don't lift the noise floor or bands far below everything else.
            const float presence = clampf((perceptualDb_[size_t(b)] - (maxPerceptual - 45.0f)) / 10.0f, 0.0f, 1.0f)
                                 * clampf((levelDb_[size_t(b)] + 80.0f) / 10.0f, 0.0f, 1.0f);

            const float tameDb = clampf(0.8f * (deviation - tameThreshold), 0.0f, kMaxCutDb);
            const float recoverNeed = std::max(maskThreshold - smr, -deviation - dipThreshold);
            const float recoverDb = clampf(0.7f * recoverNeed, 0.0f, kMaxBoostDb) * presence;

            raw[size_t(b)] = (s.recover * recoverDb - s.tame * tameDb) * rangeWeight(b, s);
        }

        // 5. Smooth across bands, then over time.
        for (int b = 0; b < n_; ++b) {
            const float l = raw[size_t(std::max(0, b - 1))];
            const float r = raw[size_t(std::min(n_ - 1, b + 1))];
            float target = 0.25f * l + 0.5f * raw[size_t(b)] + 0.25f * r;
            // Smoothing may soften a cut, but must not push a boost into a band
            // that didn't ask for one (e.g. the loud masker next to a buried band).
            if (target > 0.0f) target = std::min(target, std::max(raw[size_t(b)], 0.0f) + 0.5f);
            target = clampf(target, -kMaxCutDb, kMaxBoostDb);
            gainDb_[size_t(b)] = gainCoef_ * gainDb_[size_t(b)] + (1.0f - gainCoef_) * target;
        }
    }

    double sampleRate_ = 48000.0;
    int fftSize_ = 2048;
    int hop_ = 512;
    vDSP_Length log2n_ = 11;
    FFTSetup fftSetup_ = nullptr;
    double norm_ = 1.0;

    std::vector<float> ring_, frame_, window_, real_, imag_, power_;
    int writePos_ = 0;
    int hopCounter_ = 0;

    int n_ = kReferenceBands;
    float relativeStep_ = 1.0f;
    int envelopeRadius_ = 6;

    std::array<BinSpan, kMaxBands> spans_{};
    std::array<float, kMaxBands> centers_{};
    std::array<float, kMaxBands> loudnessWeightDb_{};
    std::array<std::array<float, kMaxBands>, kMaxBands> spread_{};
    std::array<float, kMaxEnvelopeRadius + 1> envelopeKernel_{};

    std::array<float, kMaxBands> energy_{};
    std::array<float, kMaxBands> levelDb_{};
    std::array<float, kMaxBands> perceptualDb_{};
    std::array<float, kMaxBands> gainDb_{};

    float attackCoef_ = 0.5f, releaseCoef_ = 0.9f, gainCoef_ = 0.9f;
};

} // namespace nmeq
