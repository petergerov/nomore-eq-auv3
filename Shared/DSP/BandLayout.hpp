// NoMore EQ — ERB-spaced band layout (32, 48 or 64 bands) and psychoacoustic helpers.
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

/// The band counts the Bands switch offers, and the most any layout holds.
constexpr int kBandCounts[] = {32, 48, 64};
constexpr int kBandCountOptions = int(sizeof(kBandCounts) / sizeof(kBandCounts[0]));
constexpr int kMaxBands = 64;
/// The analysis was tuned at this count; finer layouts are normalised to it.
constexpr int kReferenceBands = 32;

/// Band count for the Bands parameter's index (0, 1, 2), clamped.
inline int bandCountForIndex(float index) {
    const int i = std::min(kBandCountOptions - 1, std::max(0, int(std::lround(index))));
    return kBandCounts[i];
}

inline double hzToErbNumber(double hz) { return 21.4 * std::log10(1.0 + 0.00437 * hz); }
inline double erbNumberToHz(double erb) { return (std::pow(10.0, erb / 21.4) - 1.0) / 0.00437; }

inline double aWeightingDb(double f) {
    const double f2 = f * f;
    const double c1 = 20.6 * 20.6, c2 = 107.7 * 107.7, c3 = 737.9 * 737.9, c4 = 12194.0 * 12194.0;
    const double ra = (c4 * f2 * f2) / ((f2 + c1) * std::sqrt((f2 + c2) * (f2 + c3)) * (f2 + c4));
    return 20.0 * std::log10(ra) + 2.0;
}

struct BandLayout {
    int count = kReferenceBands;
    std::array<double, kMaxBands> center{};
    std::array<double, kMaxBands> lower{};
    std::array<double, kMaxBands> upper{};
    double erbStep = 1.0;   // ERB-number distance between neighbouring bands
    /// erbStep relative to the reference layout over the same range: 1 at
    /// 32 bands, about 0.5 at 64. Band energies are divided by it so levels
    /// read as energy per reference band whatever the count.
    double relativeStep = 1.0;

    void build(double sampleRate, int bands = kReferenceBands) {
        count = std::min(kMaxBands, std::max(2, bands));
        const double fMin = 30.0;
        const double fMax = std::min(18000.0, 0.42 * sampleRate);
        const double e0 = hzToErbNumber(fMin);
        const double e1 = hzToErbNumber(fMax);
        erbStep = (e1 - e0) / double(count - 1);
        relativeStep = double(kReferenceBands - 1) / double(count - 1);
        for (int k = 0; k < count; ++k) {
            const double e = e0 + k * erbStep;
            center[k] = erbNumberToHz(e);
            lower[k]  = erbNumberToHz(std::max(0.0, e - 0.5 * erbStep));
            upper[k]  = erbNumberToHz(e + 0.5 * erbStep);
        }
    }
};

} // namespace nmeq
