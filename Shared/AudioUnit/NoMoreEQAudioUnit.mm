// NoMore EQ — AUv3 effect implementation.
#import "NoMoreEQAudioUnit.h"
#import <AVFoundation/AVFoundation.h>

#include "../DSP/NoMoreEQKernel.hpp"
#include <cstdlib>
#include <vector>

namespace {

/// Owns the buffer the effect pulls its input into.
struct InputPullBuffer {
    std::vector<float> storage;
    std::vector<float> extraOutput;   // backing for output channels with no matching input
    AudioBufferList* list = nullptr;
    UInt32 channels = 0;
    UInt32 maxFrames = 0;

    void allocate(UInt32 channelCount, UInt32 frames) {
        release();
        channels = channelCount;
        maxFrames = frames;
        storage.assign(size_t(channelCount) * frames, 0.0f);
        extraOutput.assign(size_t(nmeq::GraphicEQ::kMaxChannels) * frames, 0.0f);
        list = static_cast<AudioBufferList*>(std::calloc(1, offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer) * channelCount));
        list->mNumberBuffers = channelCount;
    }

    void prepare(UInt32 frames) {
        for (UInt32 ch = 0; ch < channels; ++ch) {
            list->mBuffers[ch].mNumberChannels = 1;
            list->mBuffers[ch].mData = storage.data() + size_t(ch) * maxFrames;
            list->mBuffers[ch].mDataByteSize = frames * sizeof(float);
        }
    }

    void release() {
        if (list) std::free(list);
        list = nullptr;
        channels = 0;
        maxFrames = 0;
    }

    ~InputPullBuffer() { release(); }
};

struct FactoryPresetValues {
    const char* name;
    float values[NMEQParamCount];  // recover, tame, bias, brighten, low, high, output (sidechain is left alone)
};

const FactoryPresetValues kFactoryPresets[] = {
    { "Gentle",          { 35, 35,   0,   0,  30, 18000, 0 } },
    { "Clarity",         { 70, 40,  20,  15,  30, 18000, 0 } },
    { "Tame Harshness",  { 20, 75, -30, -10, 200, 18000, 0 } },
    { "Live Vocal",      { 50, 60,   0,  10, 120, 16000, 0 } },
    { "Mix Bus Polish",  { 30, 25,   0,   5,  30, 18000, 0 } },
};

NSString* const kParameterStateKey = @"nomoreeq.parameters";

} // namespace

@interface NoMoreEQAudioUnit ()
@property (nonatomic, readwrite) AUParameterTree *parameterTree;
@end

@implementation NoMoreEQAudioUnit {
    nmeq::NoMoreEQKernel _kernel;
    InputPullBuffer _pullBuffer;
    InputPullBuffer _sidechainBuffer;
    AUAudioUnitBus *_inputBus;
    AUAudioUnitBus *_sidechainBus;
    AUAudioUnitBus *_outputBus;
    AUAudioUnitBusArray *_inputBusArray;
    AUAudioUnitBusArray *_outputBusArray;
    NSArray<AUAudioUnitPreset *> *_factoryPresets;
    AUAudioUnitPreset *_currentPreset;
}

@synthesize parameterTree = _parameterTree;

- (instancetype)initWithComponentDescription:(AudioComponentDescription)componentDescription
                                     options:(AudioComponentInstantiationOptions)options
                                       error:(NSError **)outError {
    self = [super initWithComponentDescription:componentDescription options:options error:outError];
    if (!self) return nil;

    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000.0 channels:2];
    _inputBus = [[AUAudioUnitBus alloc] initWithFormat:format error:outError];
    _sidechainBus = [[AUAudioUnitBus alloc] initWithFormat:format error:outError];
    _outputBus = [[AUAudioUnitBus alloc] initWithFormat:format error:outError];
    if (!_inputBus || !_sidechainBus || !_outputBus) return nil;
    _inputBus.name = @"Main Input";
    _sidechainBus.name = @"Sidechain";
    _outputBus.name = @"Output";
    _inputBus.maximumChannelCount = nmeq::GraphicEQ::kMaxChannels;
    _sidechainBus.maximumChannelCount = nmeq::GraphicEQ::kMaxChannels;
    _outputBus.maximumChannelCount = nmeq::GraphicEQ::kMaxChannels;
    // Bus 1 is the sidechain; hosts that support
    // sidechains route a track into it. It only feeds the analyzer.
    _inputBusArray = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeInput
                                                             busses:@[ _inputBus, _sidechainBus ]];
    _outputBusArray = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeOutput busses:@[ _outputBus ]];

    [self buildParameterTree];
    [self buildFactoryPresets];
    self.maximumFramesToRender = 4096;
    return self;
}

#pragma mark - Parameters

- (void)buildParameterTree {
    const AudioUnitParameterOptions flags = kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable;

    AUParameter *(^make)(NSString *, NSString *, AUParameterAddress, AudioUnitParameterUnit, AudioUnitParameterOptions) =
        ^AUParameter *(NSString *identifier, NSString *name, AUParameterAddress address, AudioUnitParameterUnit unit, AudioUnitParameterOptions extra) {
            AUParameter *p = [AUParameterTree createParameterWithIdentifier:identifier
                                                                       name:name
                                                                    address:address
                                                                        min:NMEQParamMin[address]
                                                                        max:NMEQParamMax[address]
                                                                       unit:unit
                                                                   unitName:nil
                                                                      flags:flags | extra
                                                               valueStrings:nil
                                                        dependentParameters:nil];
            p.value = NMEQParamDefault[address];
            return p;
        };

    NSArray<AUParameter *> *parameters = @[
        // Identifiers keep their original names so saved sessions and
        // automation still load; the names are what hosts show.
        make(@"recover",  @"Lift",     NMEQParamRecover,  kAudioUnitParameterUnit_Percent, 0),
        make(@"tame",     @"Cut",      NMEQParamTame,     kAudioUnitParameterUnit_Percent, 0),
        make(@"bias",     @"Lean",     NMEQParamBias,     kAudioUnitParameterUnit_Percent, 0),
        make(@"brighten", @"Tilt",     NMEQParamBrighten, kAudioUnitParameterUnit_Percent, 0),
        make(@"lowFreq",  @"Low",      NMEQParamLowFreq,  kAudioUnitParameterUnit_Hertz, kAudioUnitParameterFlag_DisplayLogarithmic),
        make(@"highFreq", @"High",     NMEQParamHighFreq, kAudioUnitParameterUnit_Hertz, kAudioUnitParameterFlag_DisplayLogarithmic),
        make(@"output",   @"Output",   NMEQParamOutput,   kAudioUnitParameterUnit_Decibels, 0),
        make(@"sidechain", @"Sidechain", NMEQParamSidechain, kAudioUnitParameterUnit_Boolean, 0),
    ];
    _parameterTree = [AUParameterTree createTreeWithChildren:parameters];

    nmeq::NoMoreEQKernel *kernel = &_kernel;
    _parameterTree.implementorValueObserver = ^(AUParameter *param, AUValue value) {
        kernel->setParameter(param.address, value);
    };
    _parameterTree.implementorValueProvider = ^AUValue(AUParameter *param) {
        return kernel->getParameter(param.address);
    };
    _parameterTree.implementorStringFromValueCallback = ^NSString *(AUParameter *param, const AUValue *valuePtr) {
        const AUValue v = valuePtr ? *valuePtr : param.value;
        switch (param.address) {
            case NMEQParamLowFreq:
            case NMEQParamHighFreq:
                return v >= 1000.f ? [NSString stringWithFormat:@"%.1f kHz", v / 1000.f]
                                   : [NSString stringWithFormat:@"%.0f Hz", v];
            case NMEQParamOutput:
                return [NSString stringWithFormat:@"%+.1f dB", v];
            case NMEQParamBias:
            case NMEQParamBrighten:
                return [NSString stringWithFormat:@"%+.0f%%", v];
            case NMEQParamSidechain:
                return v >= 0.5f ? @"On" : @"Off";
            default:
                return [NSString stringWithFormat:@"%.0f%%", v];
        }
    };

    for (AUParameter *p in parameters) _kernel.setParameter(p.address, p.value);
}

#pragma mark - Presets & state

- (void)buildFactoryPresets {
    NSMutableArray *presets = [NSMutableArray array];
    for (NSInteger i = 0; i < NSInteger(sizeof(kFactoryPresets) / sizeof(kFactoryPresets[0])); ++i) {
        AUAudioUnitPreset *preset = [AUAudioUnitPreset new];
        preset.number = i;
        preset.name = @(kFactoryPresets[i].name);
        [presets addObject:preset];
    }
    _factoryPresets = presets;
    _currentPreset = presets.firstObject;
}

- (NSArray<AUAudioUnitPreset *> *)factoryPresets { return _factoryPresets; }
- (BOOL)supportsUserPresets { return YES; }
- (AUAudioUnitPreset *)currentPreset { return _currentPreset; }

- (void)setCurrentPreset:(AUAudioUnitPreset *)preset {
    if (!preset) { _currentPreset = nil; return; }

    if (preset.number >= 0) {
        if (preset.number >= NSInteger(_factoryPresets.count)) return;
        const FactoryPresetValues &values = kFactoryPresets[preset.number];
        // Presets shape the sound; whether the analyzer listens to the
        // sidechain is routing, so a preset leaves it as it is.
        for (AUParameter *p in _parameterTree.allParameters)
            if (p.address != NMEQParamSidechain) p.value = values.values[p.address];
        _currentPreset = _factoryPresets[preset.number];
        return;
    }

    // A user preset. Hosts (and auval) may hand us one that was never saved, and
    // -presetStateFor: raises when its file is missing, so only load presets we
    // know about and never let an exception escape into the XPC handler.
    BOOL known = NO;
    for (AUAudioUnitPreset *user in self.userPresets) {
        if (user.number == preset.number && [user.name isEqualToString:preset.name]) { known = YES; break; }
    }
    if (known) {
        @try {
            NSError *error = nil;
            NSDictionary<NSString *, id> *state = [self presetStateFor:preset error:&error];
            if (state) self.fullStateForDocument = state;
        } @catch (NSException *exception) {
            NSLog(@"NoMore EQ: couldn't load user preset %@: %@", preset.name, exception.reason);
        }
    }
    _currentPreset = preset;
}

- (NSDictionary<NSString *, id> *)fullState {
    NSMutableDictionary *state = [[super fullState] mutableCopy] ?: [NSMutableDictionary dictionary];
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    for (AUParameter *p in _parameterTree.allParameters) values[p.identifier] = @(p.value);
    state[kParameterStateKey] = values;
    return state;
}

- (void)setFullState:(NSDictionary<NSString *, id> *)fullState {
    [super setFullState:fullState];
    NSDictionary *values = fullState[kParameterStateKey];
    if (![values isKindOfClass:NSDictionary.class]) return;
    for (AUParameter *p in _parameterTree.allParameters) {
        NSNumber *v = values[p.identifier];
        if ([v isKindOfClass:NSNumber.class]) p.value = v.floatValue;
    }
}

#pragma mark - Busses & capabilities

- (AUAudioUnitBusArray *)inputBusses { return _inputBusArray; }
- (AUAudioUnitBusArray *)outputBusses { return _outputBusArray; }
// Any input count (1–8) to any output count (1–8); see NoMoreEQKernel::process.
- (NSArray<NSNumber *> *)channelCapabilities { return @[ @(-1), @(-2) ]; }
// Input is pulled into our own buffer, so output never aliases the host's input.
- (BOOL)canProcessInPlace { return NO; }

- (BOOL)shouldBypassEffect { return _kernel.isBypassed(); }
- (void)setShouldBypassEffect:(BOOL)shouldBypassEffect { _kernel.setBypass(shouldBypassEffect); }

#pragma mark - Metering

- (NSInteger)bandCount { return _kernel.bandCount(); }

- (void)copyBandFrequencies:(float *)frequencies count:(NSInteger)count {
    _kernel.copyFrequencies(frequencies, int(count));
}

- (void)copyBandGains:(float *)gains levels:(float *)levels count:(NSInteger)count {
    _kernel.copyDisplay(gains, levels, int(count));
}

- (BOOL)isAnalyzingSidechain { return _kernel.isAnalyzingSidechain(); }

- (NMEQLevelPeaks)takeLevelPeaks {
    NMEQLevelPeaks peaks{};
    _kernel.takeInputPeak(peaks.inputLeft, peaks.inputRight);
    _kernel.takeOutputPeak(peaks.outputLeft, peaks.outputRight);
    return peaks;
}

#pragma mark - Rendering

- (BOOL)allocateRenderResourcesAndReturnError:(NSError **)outError {
    if (![super allocateRenderResourcesAndReturnError:outError]) return NO;

    AVAudioFormat *inFormat = _inputBus.format;
    AVAudioFormat *outFormat = _outputBus.format;
    if (inFormat.channelCount > nmeq::GraphicEQ::kMaxChannels || outFormat.channelCount > nmeq::GraphicEQ::kMaxChannels ||
        inFormat.sampleRate != outFormat.sampleRate ||
        inFormat.commonFormat != AVAudioPCMFormatFloat32 || inFormat.isInterleaved ||
        outFormat.commonFormat != AVAudioPCMFormatFloat32 || outFormat.isInterleaved) {
        if (outError) *outError = [NSError errorWithDomain:NSOSStatusErrorDomain code:kAudioUnitErr_FormatNotSupported userInfo:nil];
        return NO;
    }

    _pullBuffer.allocate(inFormat.channelCount, self.maximumFramesToRender);

    // The sidechain is optional: a mismatched one just isn't used. Not gated on
    // the bus's `enabled` flag (off by default for extra busses, and hosts set it
    // inconsistently); pulling an unconnected sidechain fails and the analyzer
    // stays on the main input.
    AVAudioFormat *scFormat = _sidechainBus.format;
    const BOOL sidechainUsable = scFormat.sampleRate == inFormat.sampleRate &&
        scFormat.channelCount >= 1 && scFormat.channelCount <= nmeq::GraphicEQ::kMaxChannels &&
        scFormat.commonFormat == AVAudioPCMFormatFloat32 && !scFormat.isInterleaved;
    if (sidechainUsable) _sidechainBuffer.allocate(scFormat.channelCount, self.maximumFramesToRender);
    else _sidechainBuffer.release();
    _kernel.prepare(outFormat.sampleRate, int(outFormat.channelCount), int(self.maximumFramesToRender));
    return YES;
}

- (void)deallocateRenderResources {
    _pullBuffer.release();
    _sidechainBuffer.release();
    [super deallocateRenderResources];
}

- (AUInternalRenderBlock)internalRenderBlock {
    nmeq::NoMoreEQKernel *kernel = &_kernel;
    InputPullBuffer *pull = &_pullBuffer;
    InputPullBuffer *sidechain = &_sidechainBuffer;

    return ^AUAudioUnitStatus(AudioUnitRenderActionFlags *actionFlags,
                              const AudioTimeStamp *timestamp,
                              AUAudioFrameCount frameCount,
                              NSInteger outputBusNumber,
                              AudioBufferList *outputData,
                              const AURenderEvent *realtimeEventListHead,
                              AURenderPullInputBlock pullInputBlock) {
        if (!pull->list) return kAudioUnitErr_Uninitialized;
        if (frameCount > pull->maxFrames) return kAudioUnitErr_TooManyFramesToProcess;
        if (!pullInputBlock) return kAudioUnitErr_NoConnection;

        pull->prepare(frameCount);
        AudioUnitRenderActionFlags pullFlags = 0;
        const AUAudioUnitStatus status = pullInputBlock(&pullFlags, timestamp, frameCount, 0, pull->list);
        if (status != noErr) return status;

        // Host may hand us null output buffers: render in place into our input
        // buffer, or into our own storage for outputs beyond the input count.
        const UInt32 count = std::min(outputData->mNumberBuffers, UInt32(nmeq::GraphicEQ::kMaxChannels));
        for (UInt32 i = 0; i < count; ++i) {
            if (!outputData->mBuffers[i].mData) {
                outputData->mBuffers[i].mData = i < pull->channels ? pull->list->mBuffers[i].mData
                                                                   : pull->extraOutput.data() + size_t(i) * pull->maxFrames;
            }
            outputData->mBuffers[i].mDataByteSize = frameCount * sizeof(float);
        }

        for (const AURenderEvent *event = realtimeEventListHead; event; event = event->head.next) {
            if (event->head.eventType == AURenderEventParameter || event->head.eventType == AURenderEventParameterRamp)
                kernel->setParameter(event->parameter.parameterAddress, event->parameter.value);
        }

        // Pull the sidechain only when it's in use. A host that left it
        // unconnected returns an error; then the analyzer stays on the main input.
        const AudioBufferList *sidechainList = nullptr;
        if (sidechain->list && kernel->getParameter(NMEQParamSidechain) >= 0.5f) {
            sidechain->prepare(frameCount);
            AudioUnitRenderActionFlags sidechainFlags = 0;
            if (pullInputBlock(&sidechainFlags, timestamp, frameCount, 1, sidechain->list) == noErr)
                sidechainList = sidechain->list;
        }

        kernel->process(pull->list, outputData, int(frameCount), sidechainList);
        return noErr;
    };
}

@end
