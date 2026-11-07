# NoMore EQ

A perceptual, self-adjusting EQ packaged as an **AUv3** for **macOS, iPadOS and iOS**.

NoMore EQ listens to the signal and adjusts 32, 48 or 64 bands continuously. **Cut** pulls down
bands that stick out above the local spectral balance, such as resonances and harshness.
**Lift** brings up bands that are buried, either masked by louder neighbours or sitting
in a dip. The processing adds zero latency: analysis runs on a side-chain, and the
audio passes through minimum-phase filters only.

## Controls

| Control   | Range           | What it does |
|-----------|-----------------|--------------|
| Cut       | 0 – 100 %       | Cut dominant or resonant bands (up to −12 dB) |
| Lift      | 0 – 100 %       | Lift masked or buried bands (up to +9 dB) |
| Lean      | −100 – +100 %   | Shift the work: − leans toward cutting, + toward lifting |
| Tilt      | −100 – +100 %   | Tilt the overall balance dark ↔ bright by up to ±1.2 dB/oct around 1 kHz |
| Low/High  | 20 Hz – 20 kHz  | Frequency range that gets processed (soft edges) |
| Output    | ±12 dB          | Output gain |
| Sidechain | On / Off        | Analyze the sidechain input instead of the main input (see below) |
| Bands     | 32 / 48 / 64    | Resolution of the analysis and the EQ; more bands treat narrow resonances more precisely |

**Choosing Bands:** 32 bands follow the ear's frequency resolution and suit broad tonal
balance at the lowest CPU. 48 or 64 bands resolve narrower peaks, such as a ringing snare,
a whistling resonance or a harsh vowel, and cut them more narrowly and a little deeper.
Switching while playing crossfades smoothly.

The AU parameter identifiers are `tame`, `recover`, `bias`, `brighten`, `lowFreq`,
`highFreq`, `output`, `sidechain` and `bands` (0, 1, 2 for 32, 48, 64). Cut, Lift, Lean
and Tilt kept the identifiers of their earlier names, so saved sessions and automation
still load.

Factory presets: Gentle, Clarity, Tame Harshness, Live Vocal, Mix Bus Polish. Presets
leave the Sidechain and Bands switches as they are: one is routing, the other resolution.

## Editor

The editor is a rack unit with four plates. Each plate has an ⓘ button in place of its
top-right screw that lays a short explanation over the plate; tap it again (or the
explanation) to close it.

- **Analyzer:** the applied EQ curve, green where it lifts and amber where it cuts, over
  the level of each band. The dashed line is the Tilt, pivoting at 1 kHz. Below it are
  the Sidechain switch, a readout of what the analyzer hears, and the Bands switch.
- **Balance:** Cut, Lift, Lean and Tilt, spread evenly across the plate. Lean and Tilt
  print their scale ends (CUT/LIFT, DARK/BRIGHT).
- **Range:** Low and High.
- **Output:** the Output knob between the **IN** and **OUT** meters. IN shows the main
  input before processing (not the sidechain), OUT the signal after EQ and output gain.
  Each meter has a left and a right column from −48 to 0 dBFS (green up to −18, amber to
  −6, red above), a peak-hold lamp, and a clip lamp on top that stays lit for 2.5 s after
  the signal reaches 0 dBFS.

Knobs turn by dragging up or right; double-click (or double-tap) resets one to its
default. The small rotary switch next to the name cycles the panel finish (Tweed, Field
Green, Slate); the choice is remembered. The layout follows the host's window: below the
analyzer, the three control plates share one row when there is room and stack on narrow
screens.

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
- **Meters:** the IN meter always shows the main input, not the sidechain.
- **Timing:** the plug-in adds no latency, but the result depends on the main and
  sidechain signals being aligned. If your host doesn't compensate delay on sidechain
  inputs, line them up by hand.

## Container app

The *NoMore EQ* app hosts the plug-in, so you can try it without a DAW. Launching it once
also registers the AUv3 with the system.

- **Play / Stop** loops the current source through the plug-in's editor.
- **Bypass** switches the plug-in out for an A/B comparison.
- **Source** plays the built-in demo loop or an audio file of your own. The demo loop has a
  buried pad and a harsh resonant lead, so Cut and Lift are both audible. The files in
  `TestAudio/` work well too.

## How it works

`Shared/DSP/`
1. **Analysis** (`PerceptualAnalyzer.hpp`): a Hann-windowed FFT (about 43 ms, 75 % overlap)
   of the mono sum is integrated into 32, 48 or 64 bands spaced on the ERB scale (Glasberg &
   Moore, `BandLayout.hpp`), weighted by an approximate equal-loudness curve, then smoothed
   (20 ms attack, 250 ms release). Band levels are normalised to energy per 32-layout band,
   and the local envelope and masking spread are set in ERB, so finer layouts resolve
   narrower peaks without cutting or lifting harder overall.
2. **Decisions**:
   - Each band is compared with its local spectral envelope. Peaks are cut.
   - An asymmetric masking spread (wider upward than downward) gives each band a
     signal-to-mask ratio. Masked bands and dips are lifted.
   - Lifting is gated so the noise floor and silence are never boosted.
   - With Sidechain on, steps 1–2 run on the sidechain input instead (see above).
3. **Filtering** (`GraphicEQ.hpp`): a cascade of one peaking biquad per band. Band gains are mapped
   to filter gains through a regularised least-squares inverse of the filters' interaction
   matrix, after Välimäki & Liski's *Accurate Cascade Graphic Equalizer* (2017).
   Coefficients glide every 32 samples.
4. **Metering** (`PeakMeter.hpp`): the kernel keeps the peak of the main input and of the
   output per side, lock-free; the editor takes it 30 times a second and applies the
   meter ballistics (fall 24 dB/s, peak hold 1.5 s).

The kernel (`NoMoreEQKernel.hpp`) prepares all three band layouts up front, each with its
own analyzer and EQ, and all three analyzers keep listening. Switching Bands therefore
needs no allocation and the new curve is ready at once; the two EQs crossfade over 40 ms.

CPU use is about 1.3 % of one core at 32 bands and 1.6 % at 64, for stereo at 48 kHz on
Apple silicon.

## Layout

```
project.yml          XcodeGen spec (run `xcodegen generate` after adding files)
App/                 Container app: demo loop / file player hosting the AU, bypass
Extension/           AUv3 principal class, Info.plist (aufx · nmeq · Riam), entitlements
Shared/AudioUnit/    AUAudioUnit subclass (Objective-C++): busses, parameters, presets, state
Shared/DSP/          Realtime C++ kernel (header-only, Accelerate)
Shared/UI/           SwiftUI editor: analyzer, knobs, IN/OUT meters, info buttons, preset menu
Tests/               Offline DSP checks (`make -C Tests test`)
TestAudio/           Listening material (Wikimedia Commons; licences in SOURCES.txt)
scripts/make-pkg.sh  Builds the signed macOS installer package
packaging/           Installer distribution file and postinstall script
```

## Tests

```sh
make -C Tests test           # all checks; exits non-zero on a failure
make -C Tests test ARGS=-v   # also prints every band's level and gain
```

The offline checks drive the DSP kernel directly with synthetic signals:

1. A resonance in pink noise is cut, and nothing is boosted with Lift at 0.
2. The zone masked by a loud tone is lifted, and nothing is cut with Cut at 0.
3. Silence stays silent and the curve stays flat.

Checks 1–3 run at 32, 48 and 64 bands. The rest cover:

4. Range limits.
5. Bypass and output gain.
6. Other sample rates and block sizes.
7. Mono in, stereo out.
8. Sidechain.
9. Level meters.
10. Bands: levels read alike at every count, 64 bands cut more narrowly, and switching
    while playing doesn't click.

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

If Logic shows no **Side Chain** menu for NoMore EQ, or a newly added parameter such as
**Bands** is missing from its automation list, it is still using an older plug-in scan: in
*Settings › Plug-in Manager*, select NoMore EQ, choose *Reset & Rescan Selection*, then insert
the plug-in again. Logic rescans on its own when the AU's version changes.

Packages built without `NOTARY_PROFILE` are signed but not notarized: they install fine
on the Mac that built them, but Gatekeeper blocks them once downloaded onto another Mac.

Signing uses team `C9LBGZNZ6P` with automatic provisioning (`project.yml`).
Bundle IDs are `com.gerov.nomoreeq` and `com.gerov.nomoreeq.auv3`.

## Channel support

Any 1–8 channels in, to any 1–8 channels out. Output channel *c* carries input channel
*c mod N*, so a mono-in, stereo-out insert feeds both sides.
