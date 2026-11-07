// NoMore EQ — synthesises a short loop with a buried pad and a harsh resonant lead,
// so Lift and Cut are both audible without loading a file.
import AVFoundation

enum DemoSignal {
    static func make(sampleRate: Double = 48_000) -> AVAudioPCMBuffer {
        let bpm = 112.0
        let beat = 60.0 / bpm
        let seconds = beat * 16   // four bars
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let frameCount = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let left = buffer.floatChannelData![0], right = buffer.floatChannelData![1]

        let bassNotes = [41.20, 41.20, 49.00, 36.71]                      // E1 E1 G1 D1
        let leadNotes = [329.6, 392.0, 440.0, 392.0, 493.9, 440.0, 392.0, 329.6]
        let padChords: [[Double]] = [[164.8, 207.7, 246.9], [164.8, 207.7, 246.9], [196.0, 246.9, 293.7], [146.8, 185.0, 220.0]]

        var kickPhase = 0.0, bassPhase = 0.0, bassLP = 0.0, leadPhase = 0.0
        var padPhases = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
        var resonance = Resonator(frequency: 2900, q: 7, sampleRate: sampleRate)
        var noiseState: UInt32 = 0x1234_5678, hatPrev = 0.0

        var peak: Float = 0
        for i in 0..<Int(frameCount) {
            let t = Double(i) / sampleRate
            let beatPos = t / beat
            let beatTime = (beatPos - floor(beatPos)) * beat
            let bar = Int(beatPos / 4) % 4

            // Kick: pitch-swept sine on every beat.
            let kickEnv = exp(-beatTime * 9)
            kickPhase += 2 * .pi * (45 + 110 * exp(-beatTime * 30)) / sampleRate
            let kick = sin(kickPhase) * kickEnv * 0.9

            // Bass: low-passed saw, ducked by the kick. Masks the low mids.
            bassPhase += bassNotes[bar] / sampleRate
            let saw = 2 * (bassPhase - floor(bassPhase)) - 1
            bassLP += (saw - bassLP) * 0.06
            let bass = bassLP * 0.6 * (1 - 0.6 * kickEnv)

            // Pad: quiet chord that gets buried under the bass and lead.
            var padL = 0.0, padR = 0.0
            for (n, f) in padChords[bar].enumerated() {
                padPhases[n] += f * 1.002 / sampleRate
                padPhases[n + 3] += f * 0.998 / sampleRate
                padL += sin(2 * .pi * padPhases[n]); padR += sin(2 * .pi * padPhases[n + 3])
            }
            padL *= 0.035; padR *= 0.035

            // Lead: square through a sharp 2.9 kHz resonance (the harshness to tame).
            let eighth = Int(beatPos * 2)
            let eighthTime = (beatPos * 2 - floor(beatPos * 2)) * beat / 2
            leadPhase += leadNotes[eighth % leadNotes.count] / sampleRate
            let square = (leadPhase - floor(leadPhase)) < 0.5 ? 1.0 : -1.0
            let leadEnv = exp(-eighthTime * 5)
            let lead = (0.08 * square + 0.55 * resonance.process(square)) * leadEnv * 0.5

            // Hats: high-passed noise on the off-beats.
            noiseState = noiseState &* 1_664_525 &+ 1_013_904_223
            let noise = Double(Int32(bitPattern: noiseState)) / Double(Int32.max)
            let hp = noise - hatPrev; hatPrev = noise
            let offbeat = beatTime > beat / 2 ? exp(-(beatTime - beat / 2) * 45) : 0
            let hat = hp * offbeat * 0.07

            let l = Float(kick + bass + padL + lead * 0.8 + hat * 0.7)
            let r = Float(kick + bass + padR + lead * 1.0 + hat * 1.0)
            left[i] = l; right[i] = r
            peak = max(peak, abs(l), abs(r))
        }

        let gain = 0.6 / max(peak, 1e-6)
        for i in 0..<Int(frameCount) { left[i] *= gain; right[i] *= gain }
        return buffer
    }

    /// RBJ constant-peak band-pass.
    private struct Resonator {
        var b0 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0, z1 = 0.0, z2 = 0.0
        init(frequency: Double, q: Double, sampleRate: Double) {
            let w0 = 2 * .pi * frequency / sampleRate
            let alpha = sin(w0) / (2 * q)
            let a0 = 1 + alpha
            b0 = alpha / a0; b2 = -alpha / a0
            a1 = -2 * cos(w0) / a0; a2 = (1 - alpha) / a0
        }
        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = -a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }
}
