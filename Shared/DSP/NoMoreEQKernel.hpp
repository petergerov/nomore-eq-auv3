// NoMore EQ — DSP kernel: parameters, analysis side-chain, EQ, output gain.
#pragma once

#include <AudioToolbox/AudioToolbox.h>
#include <atomic>
#include <array>
#include <vector>
#include <algorithm>
#include <cmath>
#include <cstring>

#include "NoMoreEQParameters.h"
#include "BandLayout.hpp"
#include "PerceptualAnalyzer.hpp"
#include "GraphicEQ.hpp"
#include "PeakMeter.hpp"

namespace nmeq {

class NoMoreEQKernel {
public:
    NoMoreEQKernel() {
        for (int i = 0; i < NMEQParamCount; ++i) params_[i].store(NMEQParamDefault[i]);
        for (int b = 0; b < kNumBands; ++b) { displayGain_[b].store(0.0f); displayLevel_[b].store(-120.0f); }
        layout_.build(48000.0);
    }
    NoMoreEQKernel(const NoMoreEQKernel&) = delete;
    NoMoreEQKernel& operator=(const NoMoreEQKernel&) = delete;

    // Allocates. Call from allocateRenderResources.
    void prepare(double sampleRate, int channels, int maxFrames) {
        prepared_.store(false);
        sampleRate_ = sampleRate;
        channels_ = std::max(1, std::min(channels, GraphicEQ::kMaxChannels));
        layout_.build(sampleRate);
        analyzer_.prepare(sampleRate, layout_);
        eq_.prepare(sampleRate, layout_, channels_);
        mono_.assign(size_t(std::max(1, maxFrames)), 0.0f);
        outputGain_ = dbToGain(params_[NMEQParamOutput].load());
        outputGlide_ = float(1.0 - std::exp(-1.0 / (0.020 * sampleRate)));
        prepared_.store(true);
    }

    void setParameter(uint64_t address, float value) {
        if (address >= NMEQParamCount) return;
        params_[address].store(std::min(NMEQParamMax[address], std::max(NMEQParamMin[address], value)));
    }
    float getParameter(uint64_t address) const {
        return address < NMEQParamCount ? params_[address].load() : 0.0f;
    }

    void setBypass(bool bypass) { bypass_.store(bypass); }
    bool isBypassed() const { return bypass_.load(); }

    int bandCount() const { return kNumBands; }
    void copyFrequencies(float* out, int count) const {
        for (int b = 0; b < std::min(count, int(kNumBands)); ++b) out[b] = float(layout_.center[size_t(b)]);
    }
    void copyDisplay(float* gainsDb, float* levelsDb, int count) const {
        for (int b = 0; b < std::min(count, int(kNumBands)); ++b) {
            if (gainsDb)  gainsDb[b]  = displayGain_[b].load(std::memory_order_relaxed);
            if (levelsDb) levelsDb[b] = displayLevel_[b].load(std::memory_order_relaxed);
        }
    }

    /// Whether the analyzer is currently fed by the sidechain (Sidechain on and
    /// the host delivered a sidechain input on the last render).
    bool isAnalyzingSidechain() const { return analyzingSidechain_.load(std::memory_order_relaxed); }

    /// Main-input peak (before processing) since the last call, linear, then cleared.
    void takeInputPeak(float& left, float& right) { inputMeter_.take(left, right); }
    /// Output peak (after EQ and output gain) since the last call, linear, then cleared.
    void takeOutputPeak(float& left, float& right) { outputMeter_.take(left, right); }

    // Realtime-safe. Output channel i may alias input channel i (in-place).
    // Input and output channel counts may differ: output channel c carries
    // input channel c % inputs (so mono in → stereo out feeds both sides).
    //
    // `sidechain` is the host's sidechain input (bus 1), or null when there is
    // none. With the Sidechain parameter on, the analyzer listens to it instead
    // of the main input and the EQ applies the resulting curve to the main
    // signal. Without a sidechain input it keeps analyzing
    // the main input.
    void process(const AudioBufferList* in, AudioBufferList* out, int frames,
                 const AudioBufferList* sidechain = nullptr) {
        const int inCh  = int(std::min(in->mNumberBuffers, UInt32(GraphicEQ::kMaxChannels)));
        const int nch   = int(std::min(out->mNumberBuffers, UInt32(GraphicEQ::kMaxChannels)));
        if (frames <= 0 || nch <= 0 || inCh <= 0) return;

        std::array<const float*, GraphicEQ::kMaxChannels> src{};
        std::array<float*, GraphicEQ::kMaxChannels> dst{};
        for (int ch = 0; ch < nch; ++ch) {
            src[size_t(ch)] = static_cast<const float*>(in->mBuffers[ch % inCh].mData);
            dst[size_t(ch)] = static_cast<float*>(out->mBuffers[ch].mData);
        }

        // Meter the input before anything is written (in-place safe).
        std::array<const float*, GraphicEQ::kMaxChannels> inputs{};
        for (int ch = 0; ch < inCh; ++ch) inputs[size_t(ch)] = static_cast<const float*>(in->mBuffers[ch].mData);
        inputMeter_.accumulate(inputs.data(), inCh, frames);

        render(in, inCh, src.data(), dst.data(), nch, frames, sidechain);

        outputMeter_.accumulate(dst.data(), nch, frames);
    }

private:
    void render(const AudioBufferList* in, int inCh, const float* const* src, float* const* dst,
                int nch, int frames, const AudioBufferList* sidechain) {
        if (!prepared_.load() || frames > int(mono_.size()) || nch > channels_) {
            copyThrough(src, dst, nch, frames);
            return;
        }

        if (bypass_.load()) {
            copyThrough(src, dst, nch, frames);
            for (int b = 0; b < kNumBands; ++b) displayGain_[b].store(0.0f, std::memory_order_relaxed);
            return;
        }

        // Analysis source: mono sum, read before anything is written (in-place safe).
        const bool useSidechain = params_[NMEQParamSidechain].load() >= 0.5f && hasAudio(sidechain);
        analyzingSidechain_.store(useSidechain, std::memory_order_relaxed);
        const AudioBufferList* source = useSidechain ? sidechain : in;
        const int srcCh = useSidechain ? int(std::min(sidechain->mNumberBuffers, UInt32(GraphicEQ::kMaxChannels))) : inCh;
        const float scale = 1.0f / float(srcCh);
        for (int i = 0; i < frames; ++i) {
            float s = 0.0f;
            for (int ch = 0; ch < srcCh; ++ch) s += static_cast<const float*>(source->mBuffers[ch].mData)[i];
            mono_[size_t(i)] = s * scale;
        }

        AnalysisSettings settings;
        settings.recover = params_[NMEQParamRecover].load() / 100.0f;
        settings.tame    = params_[NMEQParamTame].load() / 100.0f;
        settings.bias    = params_[NMEQParamBias].load() / 100.0f;
        settings.lowHz   = params_[NMEQParamLowFreq].load();
        settings.highHz  = params_[NMEQParamHighFreq].load();

        if (analyzer_.push(mono_.data(), frames, settings)) {
            // Brighten: a static tilt of up to ±1.2 dB/octave pivoting at 1 kHz.
            // The editor draws the same tilt as a guide (ResponseView.brightenTiltDb); keep them in step.
            const float brighten = params_[NMEQParamBrighten].load() / 100.0f;
            const auto& g = analyzer_.gainDb();
            const auto& lvl = analyzer_.perceptualLevelDb();
            for (int b = 0; b < kNumBands; ++b) {
                const float tilt = std::min(6.0f, std::max(-6.0f,
                    brighten * 1.2f * std::log2(float(layout_.center[size_t(b)]) / 1000.0f)));
                combined_[size_t(b)] = g[size_t(b)] + tilt;
                displayGain_[b].store(combined_[size_t(b)], std::memory_order_relaxed);
                displayLevel_[b].store(lvl[size_t(b)], std::memory_order_relaxed);
            }
            eq_.setBandGainsDb(combined_);
        }

        copyThrough(src, dst, nch, frames);
        eq_.process(dst, nch, frames);

        const float targetGain = dbToGain(params_[NMEQParamOutput].load());
        float g = outputGain_;
        if (std::fabs(targetGain - g) < 1e-6f && std::fabs(g - 1.0f) < 1e-6f) return;
        for (int i = 0; i < frames; ++i) {
            g += (targetGain - g) * outputGlide_;
            for (int ch = 0; ch < nch; ++ch) dst[ch][i] *= g;
        }
        outputGain_ = g;
    }

    static float dbToGain(float db) { return std::pow(10.0f, db / 20.0f); }

    static bool hasAudio(const AudioBufferList* list) {
        if (!list || list->mNumberBuffers == 0) return false;
        for (UInt32 ch = 0; ch < std::min(list->mNumberBuffers, UInt32(GraphicEQ::kMaxChannels)); ++ch)
            if (!list->mBuffers[ch].mData) return false;
        return true;
    }

    static void copyThrough(const float* const* src, float* const* dst, int nch, int frames) {
        for (int ch = 0; ch < nch; ++ch)
            if (src[ch] != dst[ch]) std::memcpy(dst[ch], src[ch], size_t(frames) * sizeof(float));
    }

    std::atomic<float> params_[NMEQParamCount];
    std::atomic<bool> bypass_{false};
    std::atomic<bool> prepared_{false};
    std::atomic<bool> analyzingSidechain_{false};
    std::atomic<float> displayGain_[kNumBands];
    std::atomic<float> displayLevel_[kNumBands];
    PeakMeter inputMeter_;
    PeakMeter outputMeter_;

    double sampleRate_ = 48000.0;
    int channels_ = 2;
    BandLayout layout_;
    PerceptualAnalyzer analyzer_;
    GraphicEQ eq_;
    std::vector<float> mono_;
    std::array<float, kNumBands> combined_{};
    float outputGain_ = 1.0f;
    float outputGlide_ = 0.001f;
};

} // namespace nmeq
