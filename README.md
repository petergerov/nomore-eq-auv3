# NoMore EQ

A perceptual, self-adjusting EQ packaged as an **AUv3** for **macOS, iPadOS and iOS**.

NoMore EQ listens to the signal and adjusts 32 bands continuously. **Cut** pulls down
bands that stick out above the local spectral balance, such as resonances and harshness.
**Lift** brings up bands that are buried, either masked by louder neighbours or sitting
in a dip. The processing adds zero latency: analysis runs on a side-chain, and the
audio passes through minimum-phase filters only.

This is an original, clean-room design built from published psychoacoustics. It contains
no code, assets or reverse-engineered internals from any commercial product.

## Controls

| Control  | Range            | What it does |
|----------|------------------|--------------|
| Cut      | 0 – 100 %        | Cut dominant or resonant bands (up to −12 dB) |
| Lift     | 0 – 100 %        | Lift masked or buried bands (up to +9 dB) |
| Lean     | −100 – +100 %    | Shift the work: − leans toward cutting, + toward lifting |
| Tilt     | −100 – +100 %    | Tilt the overall balance dark ↔ bright by up to ±1.2 dB/oct around 1 kHz |
| Low/High | 20 Hz – 20 kHz   | Frequency range that gets processed (soft edges) |
| Output   | ±12 dB           | Output gain. The IN and OUT meters beside it show the main input and the output, left and right; the top lamp lights at 0 dBFS |
| Sidechain | On / Off        | Analyze the sidechain input instead of the main input (see below) |

Each control plate has an ⓘ button that lays a short explanation over the plate.

Factory presets: Gentle, Clarity, Tame Harshness, Live Vocal, Mix Bus Polish. Presets
leave the Sidechain switch as it is, since it is routing rather than sound.

## Sidechain

The AU has a second input bus, **Sidechain**. With the Sidechain switch on (bottom left
of the analyzer), the analyzer listens to that input instead of the main one, and the EQ
applies the resulting curve to the main signal. Everything else (Cut, Lift, Lean, Tilt,
range, output) works as usual.

- **Routing:** send a track to the plug-in's sidechain input in your host. Hosts differ
  in how they offer sidechains for AUv3 effects.
- **No sidechain connected:** the analyzer stays on the main input, and the readout next
  to the switch says *No sidechain input*. A host that connects the bus but sends
  silence gives a flat curve.
- **Uses:** stem mastering (drive each stem's instance with the sum of the stems, so the
  stems sound as if the sum had been processed), ducking content that clashes with
  another track, and sound design.
- **Timing:** the plug-in adds no latency, but the result depends on the main and
  sidechain signals being aligned. If your host doesn't compensate delay on sidechain
  inputs, line them up by hand.

## How it works

`Shared/DSP/`
1. **Analysis** (`PerceptualAnalyzer.hpp`): a Hann-windowed FFT (about 43 ms, 75 % overlap)
   of the mono sum is integrated into 32 bands spaced on the ERB scale (Glasberg & Moore),
   weighted by an approximate equal-loudness curve, then smoothed (20 ms attack, 250 ms
   release).
2. **Decisions**:
   - Each band is compared with its local spectral envelope. Peaks are cut.
   - An asymmetric masking spread (wider upward than downward) gives each band a
     signal-to-mask ratio. Masked bands and dips are lifted.
   - Lifting is gated so the noise floor and silence are never boosted.
   - With Sidechain on, steps 1–2 run on the sidechain input instead (see above).
3. **Filtering** (`GraphicEQ.hpp`): a cascade of 32 peaking biquads. Band gains are mapped
   to filter gains through a regularised least-squares inverse of the filters' interaction
   matrix, after Välimäki & Liski's *Accurate Cascade Graphic Equalizer* (2017).
   Coefficients glide every 32 samples.

CPU use is about 1 % of one core for stereo at 48 kHz on Apple silicon.

## Layout

```
project.yml          XcodeGen spec (run `xcodegen generate` after adding files)
App/                 Container app: demo loop / file player hosting the AU, bypass
Extension/           AUv3 principal class, Info.plist (aufx · nmeq · Riam), entitlements
Shared/AudioUnit/    AUAudioUnit subclass (Objective-C++): busses, parameters, presets, state
Shared/DSP/          Realtime C++ kernel (header-only, Accelerate)
Shared/UI/           SwiftUI editor: live curve + band levels, knobs, preset menu
Tests/               Offline DSP checks (`make -C Tests test`)
```

## Build

```sh
xcodegen generate
open NoMoreEQ.xcodeproj        # schemes: NoMoreEQ_macOS, NoMoreEQ_iOS
```

Or from the command line:

```sh
xcodebuild -scheme NoMoreEQ_macOS -derivedDataPath build/DerivedData -allowProvisioningUpdates build
open "build/DerivedData/Build/Products/Debug/NoMore EQ.app"  # registers the AUv3
auval -v aufx nmeq Riam                                        # validate
```

macOS installer package (Developer ID signed, installs to `/Applications` and registers the AU):

```sh
cp .env.example .env                             # set TEAM_ID and BUNDLE_ID_PREFIX
scripts/make-pkg.sh                              # → build/pkg/NoMoreEQ-<version>.pkg
NOTARY_PROFILE=<profile> scripts/make-pkg.sh     # also notarize + staple
```

- **macOS:** launch the app once so the system registers the extension. After that it shows
  up as *Ria: NoMore EQ* in Logic Pro, GarageBand, Ableton Live and other AU hosts.
- **iOS / iPadOS:** run the `NoMoreEQ_iOS` scheme on a device. Hosts such as AUM, Logic Pro
  for iPad, GarageBand and Cubasis then list it under effects.

Signing uses team `C9LBGZNZ6P` with automatic provisioning (`project.yml`).
Bundle IDs are `com.gerov.nomoreeq` and `com.gerov.nomoreeq.auv3`.

## Channel support

Any 1–8 channels in, to any 1–8 channels out. Output channel *c* carries input channel
*c mod N*, so a mono-in, stereo-out insert feeds both sides.
