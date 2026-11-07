// NoMore EQ — offline DSP sanity test.
// Build & run:  make -C Tests
#include "../Shared/DSP/NoMoreEQKernel.hpp"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <random>
#include <vector>

using namespace nmeq;

namespace {

int failures = 0;
void check(bool ok, const char* what) {
    std::printf("  [%s] %s\n", ok ? "ok" : "FAIL", what);
    if (!ok) ++failures;
}

struct Signal { std::vector<float> l, r; };

// Pink-ish noise (Paul Kellet filter) + optional strong resonance + optional quiet tone.
Signal makeSignal(double sr, double seconds, float resonanceHz, float resonanceAmp, float quietHz, float quietAmp) {
    const size_t n = size_t(sr * seconds);
    Signal s{ std::vector<float>(n), std::vector<float>(n) };
    std::mt19937 rng(1234);
    std::uniform_real_distribution<float> uni(-1.f, 1.f);
    float b0 = 0, b1 = 0, b2 = 0, b3 = 0, b4 = 0, b5 = 0, b6 = 0;
    for (size_t i = 0; i < n; ++i) {
        const float w = uni(rng);
        b0 = 0.99886f * b0 + w * 0.0555179f; b1 = 0.99332f * b1 + w * 0.0750759f;
        b2 = 0.96900f * b2 + w * 0.1538520f; b3 = 0.86650f * b3 + w * 0.3104856f;
        b4 = 0.55000f * b4 + w * 0.5329522f; b5 = -0.7616f * b5 - w * 0.0168980f;
        float pink = (b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362f) * 0.05f;
        b6 = w * 0.115926f;
        const double t = double(i) / sr;
        float x = pink;
        x += resonanceAmp * float(std::sin(2.0 * M_PI * resonanceHz * t));
        x += quietAmp * float(std::sin(2.0 * M_PI * quietHz * t));
        s.l[i] = x; s.r[i] = x;
    }
    return s;
}

double rms(const std::vector<float>& v, size_t from) {
    double acc = 0; for (size_t i = from; i < v.size(); ++i) acc += double(v[i]) * v[i];
    return std::sqrt(acc / double(v.size() - from));
}

struct Result { std::array<float, kNumBands> gain{}, level{}, freq{}; bool finite = true; double outRms = 0; double seconds = 0; };

// `sidechain`, when given, is fed to the kernel's sidechain input block by block.
Result run(NoMoreEQKernel& k, double sr, Signal sig, int block, const Signal* sidechain = nullptr) {
    k.prepare(sr, 2, 4096);
    std::vector<float> outL(sig.l.size()), outR(sig.r.size());
    AudioBufferList* in = static_cast<AudioBufferList*>(std::calloc(1, sizeof(AudioBufferList) + sizeof(AudioBuffer)));
    AudioBufferList* out = static_cast<AudioBufferList*>(std::calloc(1, sizeof(AudioBufferList) + sizeof(AudioBuffer)));
    AudioBufferList* sc = static_cast<AudioBufferList*>(std::calloc(1, sizeof(AudioBufferList) + sizeof(AudioBuffer)));
    in->mNumberBuffers = out->mNumberBuffers = sc->mNumberBuffers = 2;

    const auto t0 = std::chrono::steady_clock::now();
    for (size_t pos = 0; pos < sig.l.size(); pos += size_t(block)) {
        const int n = int(std::min(size_t(block), sig.l.size() - pos));
        in->mBuffers[0] = { 1, UInt32(n * 4), sig.l.data() + pos };
        in->mBuffers[1] = { 1, UInt32(n * 4), sig.r.data() + pos };
        out->mBuffers[0] = { 1, UInt32(n * 4), outL.data() + pos };
        out->mBuffers[1] = { 1, UInt32(n * 4), outR.data() + pos };
        if (sidechain) {
            sc->mBuffers[0] = { 1, UInt32(n * 4), const_cast<float*>(sidechain->l.data()) + pos };
            sc->mBuffers[1] = { 1, UInt32(n * 4), const_cast<float*>(sidechain->r.data()) + pos };
        }
        k.process(in, out, n, sidechain ? sc : nullptr);
    }
    Result r;
    r.seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    for (float v : outL) if (!std::isfinite(v)) { r.finite = false; break; }
    r.outRms = rms(outL, outL.size() / 2);
    k.copyDisplay(r.gain.data(), r.level.data(), kNumBands);
    k.copyFrequencies(r.freq.data(), kNumBands);
    std::free(in); std::free(out); std::free(sc);
    return r;
}

int nearestBand(const Result& r, float hz) {
    int best = 0;
    for (int b = 1; b < kNumBands; ++b)
        if (std::fabs(std::log(r.freq[size_t(b)] / hz)) < std::fabs(std::log(r.freq[size_t(best)] / hz))) best = b;
    return best;
}

void printCurve(const Result& r) {
    for (int b = 0; b < kNumBands; ++b)
        std::printf("    %7.0f Hz  level %6.1f dB  gain %+5.2f dB\n", r.freq[size_t(b)], r.level[size_t(b)], r.gain[size_t(b)]);
}

} // namespace

int main(int argc, char** argv) {
    const bool verbose = argc > 1 && std::string(argv[1]) == "-v";
    const double seconds = 4.0;

    std::printf("1. Harsh 3 kHz resonance in pink noise, Tame 100%%, Recover 0%%\n");
    {
        NoMoreEQKernel k;
        k.setParameter(NMEQParamTame, 100); k.setParameter(NMEQParamRecover, 0);
        auto r = run(k, 48000, makeSignal(48000, seconds, 3000, 0.25f, 0, 0), 256);
        if (verbose) printCurve(r);
        const int b = nearestBand(r, 3000);
        std::printf("    gain at %.0f Hz: %+.2f dB\n", r.freq[size_t(b)], r.gain[size_t(b)]);
        check(r.finite, "output is finite");
        check(r.gain[size_t(b)] < -2.0f, "resonant band is cut by more than 2 dB");
        float maxBoost = -100; for (float g : r.gain) maxBoost = std::max(maxBoost, g);
        check(maxBoost <= 0.01f, "no band is boosted when Recover is 0%");
        std::printf("    CPU: %.2f%% of realtime (stereo, 48 kHz)\n", 100.0 * r.seconds / seconds);
    }

    std::printf("2. Quiet 5 kHz tone buried next to a loud 4 kHz tone, Recover 100%%, Tame 0%%\n");
    {
        NoMoreEQKernel k;
        k.setParameter(NMEQParamTame, 0); k.setParameter(NMEQParamRecover, 100);
        auto sig = makeSignal(48000, seconds, 4000, 0.3f, 5200, 0.004f);
        auto r = run(k, 48000, sig, 512);
        if (verbose) printCurve(r);
        const int b = nearestBand(r, 5200);
        std::printf("    gain at %.0f Hz: %+.2f dB\n", r.freq[size_t(b)], r.gain[size_t(b)]);
        check(r.finite, "output is finite");
        check(r.gain[size_t(b)] > 1.0f, "masked band is lifted by more than 1 dB");
        float minGain = 100; for (float g : r.gain) minGain = std::min(minGain, g);
        check(minGain >= -0.01f, "no band is cut when Tame is 0%");
    }

    std::printf("3. Silence: the EQ stays flat and output stays silent\n");
    {
        NoMoreEQKernel k;
        k.setParameter(NMEQParamTame, 100); k.setParameter(NMEQParamRecover, 100);
        auto r = run(k, 48000, makeSignal(48000, 1.0, 0, 0, 0, 0) /* still has pink */, 512);
        Signal silent{ std::vector<float>(48000), std::vector<float>(48000) };
        r = run(k, 48000, silent, 512);
        float maxAbs = 0; for (float g : r.gain) maxAbs = std::max(maxAbs, std::fabs(g));
        check(r.finite && r.outRms == 0.0, "silent in → silent out");
        check(maxAbs < 0.05f, "gain curve is flat on silence");
    }

    std::printf("4. Range limits: processing outside 200 Hz – 2 kHz is suppressed\n");
    {
        NoMoreEQKernel k;
        k.setParameter(NMEQParamTame, 100); k.setParameter(NMEQParamRecover, 0);
        k.setParameter(NMEQParamLowFreq, 200); k.setParameter(NMEQParamHighFreq, 2000);
        auto r = run(k, 48000, makeSignal(48000, seconds, 6000, 0.25f, 0, 0), 128);
        const int b = nearestBand(r, 6000);
        check(std::fabs(r.gain[size_t(b)]) < 0.3f, "6 kHz resonance left alone");
    }

    std::printf("5. Bypass and output gain\n");
    {
        NoMoreEQKernel k;
        k.setBypass(true);
        auto sig = makeSignal(48000, 1.0, 1000, 0.2f, 0, 0);
        auto r = run(k, 48000, sig, 512);
        check(std::fabs(r.outRms - rms(sig.l, sig.l.size() / 2)) < 1e-9, "bypass is bit-transparent");
        NoMoreEQKernel k2;
        k2.setParameter(NMEQParamTame, 0); k2.setParameter(NMEQParamRecover, 0);
        k2.setParameter(NMEQParamOutput, -6);
        auto r2 = run(k2, 48000, sig, 512);
        const double ratioDb = 20.0 * std::log10(r2.outRms / rms(sig.l, sig.l.size() / 2));
        std::printf("    output change: %+.2f dB\n", ratioDb);
        check(std::fabs(ratioDb + 6.0) < 0.1, "output gain -6 dB ≈ -6 dB");
    }

    std::printf("6. Other sample rates and odd block sizes stay stable\n");
    for (double sr : { 44100.0, 88200.0, 96000.0, 192000.0 }) {
        NoMoreEQKernel k;
        k.setParameter(NMEQParamTame, 100); k.setParameter(NMEQParamRecover, 100);
        k.setParameter(NMEQParamBrighten, 100);
        auto r = run(k, sr, makeSignal(sr, 2.0, 2500, 0.2f, 0, 0), 333);
        char msg[96]; std::snprintf(msg, sizeof msg, "%.0f Hz: finite, output RMS %.3f", sr, r.outRms);
        check(r.finite && r.outRms > 0.01 && r.outRms < 2.0, msg);
    }

    std::printf("7. Mono in → stereo out feeds both outputs identically\n");
    {
        NoMoreEQKernel k;
        k.setParameter(NMEQParamTame, 100); k.setParameter(NMEQParamRecover, 100);
        k.prepare(48000, 2, 512);
        auto sig = makeSignal(48000, 1.0, 3000, 0.25f, 0, 0);
        std::vector<float> outL(sig.l.size()), outR(sig.l.size());
        AudioBufferList inList{};  // one input buffer
        AudioBufferList* out = static_cast<AudioBufferList*>(std::calloc(1, sizeof(AudioBufferList) + sizeof(AudioBuffer)));
        out->mNumberBuffers = 2;
        inList.mNumberBuffers = 1;
        for (size_t pos = 0; pos < sig.l.size(); pos += 512) {
            const int n = int(std::min(size_t(512), sig.l.size() - pos));
            inList.mBuffers[0] = { 1, UInt32(n * 4), sig.l.data() + pos };
            out->mBuffers[0] = { 1, UInt32(n * 4), outL.data() + pos };
            out->mBuffers[1] = { 1, UInt32(n * 4), outR.data() + pos };
            k.process(&inList, out, n);
        }
        std::free(out);
        bool same = true, finite = true;
        for (size_t i = 0; i < outL.size(); ++i) {
            if (outL[i] != outR[i]) same = false;
            if (!std::isfinite(outL[i])) finite = false;
        }
        check(finite && rms(outL, 0) > 0.01, "left output is processed audio");
        check(same, "right output matches left");
    }

    std::printf("8. Sidechain: the analyzer follows the sidechain, the EQ processes the main input\n");
    {
        // Main: plain pink noise. Sidechain: pink noise with a harsh 3 kHz resonance.
        const Signal main = makeSignal(48000, seconds, 0, 0, 0, 0);
        const Signal key = makeSignal(48000, seconds, 3000, 0.25f, 0, 0);

        NoMoreEQKernel off;
        off.setParameter(NMEQParamTame, 100); off.setParameter(NMEQParamRecover, 0);
        auto rOff = run(off, 48000, main, 256, &key);
        const int b = nearestBand(rOff, 3000);
        std::printf("    Sidechain off: gain at %.0f Hz %+.2f dB\n", rOff.freq[size_t(b)], rOff.gain[size_t(b)]);
        check(rOff.gain[size_t(b)] > -1.0f, "off: the sidechain is ignored (no 3 kHz cut on plain noise)");
        check(!off.isAnalyzingSidechain(), "off: analyzer reports the main input");

        NoMoreEQKernel on;
        on.setParameter(NMEQParamTame, 100); on.setParameter(NMEQParamRecover, 0);
        on.setParameter(NMEQParamSidechain, 1);
        auto rOn = run(on, 48000, main, 256, &key);
        std::printf("    Sidechain on:  gain at %.0f Hz %+.2f dB\n", rOn.freq[size_t(b)], rOn.gain[size_t(b)]);
        check(rOn.finite, "on: output is finite");
        check(rOn.gain[size_t(b)] < -2.0f, "on: the key's resonance drives a cut on the main input");
        check(on.isAnalyzingSidechain(), "on: analyzer reports the sidechain");
        check(std::fabs(rOn.level[size_t(b)] - rOff.level[size_t(b)]) > 3.0f, "on: displayed levels are the sidechain's");

        NoMoreEQKernel missing;
        missing.setParameter(NMEQParamTame, 100); missing.setParameter(NMEQParamRecover, 0);
        missing.setParameter(NMEQParamSidechain, 1);
        auto rMissing = run(missing, 48000, makeSignal(48000, seconds, 3000, 0.25f, 0, 0), 256, nullptr);
        std::printf("    Sidechain on, none connected: gain at %.0f Hz %+.2f dB\n",
                    rMissing.freq[size_t(b)], rMissing.gain[size_t(b)]);
        check(rMissing.gain[size_t(b)] < -2.0f && !missing.isAnalyzingSidechain(),
              "on without a sidechain input: falls back to analyzing the main input");
    }

    std::printf("9. Input / output level meters\n");
    {
        // 1 kHz at 0.5 on the left, silence on the right; flat EQ, output −6 dB.
        NoMoreEQKernel k;
        k.setParameter(NMEQParamTame, 0); k.setParameter(NMEQParamRecover, 0);
        k.setParameter(NMEQParamOutput, -6);
        const size_t n = 48000;
        Signal sig{ std::vector<float>(n), std::vector<float>(n, 0.0f) };
        for (size_t i = 0; i < n; ++i) sig.l[i] = 0.5f * float(std::sin(2.0 * M_PI * 1000.0 * double(i) / 48000.0));
        run(k, 48000, sig, 256);

        float inL, inR, outL, outR;
        k.takeInputPeak(inL, inR);
        k.takeOutputPeak(outL, outR);
        std::printf("    in  L %.3f R %.3f   out L %.3f R %.3f\n", inL, inR, outL, outR);
        check(std::fabs(inL - 0.5f) < 0.01f && inR == 0.0f, "input peaks: left 0.5, right silent");
        check(std::fabs(20.0f * std::log10(outL / inL) + 6.0f) < 0.3f && outR == 0.0f,
              "output peaks follow the −6 dB output gain");
        float again, againR;
        k.takeInputPeak(again, againR);
        check(again == 0.0f && againR == 0.0f, "taking the peaks clears them");
    }

    std::printf(failures ? "\n%d check(s) failed\n" : "\nall checks passed\n", failures);
    return failures ? 1 : 0;
}
