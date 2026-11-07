// NoMore EQ — ERB-spaced band layout and psychoacoustic helpers.
//
// Band spacing follows the ERB-number scale (Glasberg & Moore, 1990), so each
// band covers a roughly equal slice of the cochlea. Equal-loudness weighting
// uses half of the IEC 61672 A-weighting curve as a cheap approximation of a
// mid-level equal-loudness contour.
#pragma once

#include <array>
#include <algorithm>
#include <cmath>

namespace nmeq {

constexpr int kNumBands = 32;

inline double hzToErbNumber(double hz) { return 21.4 * std::log10(1.0 + 0.00437 * hz); }
inline double erbNumberToHz(double erb) { return (std::pow(10.0, erb / 21.4) - 1.0) / 0.00437; }

inline double aWeightingDb(double f) {
    const double f2 = f * f;
    const double c1 = 20.6 * 20.6, c2 = 107.7 * 107.7, c3 = 737.9 * 737.9, c4 = 12194.0 * 12194.0;
    const double ra = (c4 * f2 * f2) / ((f2 + c1) * std::sqrt((f2 + c2) * (f2 + c3)) * (f2 + c4));
    return 20.0 * std::log10(ra) + 2.0;
}

struct BandLayout {
    std::array<double, kNumBands> center{};
    std::array<double, kNumBands> lower{};
    std::array<double, kNumBands> upper{};
    double erbStep = 1.0;   // ERB-number distance between neighbouring bands

    void build(double sampleRate) {
        const double fMin = 30.0;
        const double fMax = std::min(18000.0, 0.42 * sampleRate);
        const double e0 = hzToErbNumber(fMin);
        const double e1 = hzToErbNumber(fMax);
        erbStep = (e1 - e0) / double(kNumBands - 1);
        for (int k = 0; k < kNumBands; ++k) {
            const double e = e0 + k * erbStep;
            center[k] = erbNumberToHz(e);
            lower[k]  = erbNumberToHz(std::max(0.0, e - 0.5 * erbStep));
            upper[k]  = erbNumberToHz(e + 0.5 * erbStep);
        }
    }
};

} // namespace nmeq
