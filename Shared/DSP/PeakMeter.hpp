// NoMore EQ — lock-free peak hold for the editor's level meters.
#pragma once

#include <atomic>
#include <algorithm>
#include <cmath>

namespace nmeq {

/// Peak |sample| per side, held until a reader takes it. The render thread only
/// ever raises the held value (lock-free CAS max), so a transient between two
/// reads can't slip past; the reader swaps it back to zero. Meant for a single
/// reader: the editor's meter timer.
class PeakMeter {
public:
    static_assert(std::atomic<float>::is_always_lock_free);

    /// Render thread: fold a block in. Even channels count as left, odd as
    /// right; a mono signal shows on both sides.
    void accumulate(const float* const* channels, int channelCount, int frames) noexcept {
        float side[2] = {0.0f, 0.0f};
        for (int ch = 0; ch < channelCount; ++ch) {
            const float* x = channels[ch];
            if (!x) continue;
            float peak = 0.0f;
            for (int i = 0; i < frames; ++i) peak = std::max(peak, std::fabs(x[i]));
            side[ch & 1] = std::max(side[ch & 1], peak);
        }
        if (channelCount == 1) side[1] = side[0];
        raise(left_, side[0]);
        raise(right_, side[1]);
    }

    /// Any thread: the peaks since the previous take, then start over.
    void take(float& left, float& right) noexcept {
        left = left_.exchange(0.0f, std::memory_order_relaxed);
        right = right_.exchange(0.0f, std::memory_order_relaxed);
    }

private:
    static void raise(std::atomic<float>& slot, float value) noexcept {
        // NaN compares false and is dropped.
        float held = slot.load(std::memory_order_relaxed);
        while (value > held &&
               !slot.compare_exchange_weak(held, value, std::memory_order_relaxed)) {
        }
    }

    std::atomic<float> left_{0.0f};
    std::atomic<float> right_{0.0f};
};

} // namespace nmeq
