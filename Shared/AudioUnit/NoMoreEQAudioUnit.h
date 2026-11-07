// NoMore EQ — AUv3 effect (aufx / nmeq / Riam).
#import <AudioToolbox/AudioToolbox.h>

NS_ASSUME_NONNULL_BEGIN

/// Linear peak |sample| per side since the previous read.
typedef struct {
    float inputLeft, inputRight;
    float outputLeft, outputRight;
} NMEQLevelPeaks;

@interface NoMoreEQAudioUnit : AUAudioUnit

/// Number of analysis / EQ bands (32).
@property (nonatomic, readonly) NSInteger bandCount;

/// Band centre frequencies in Hz.
- (void)copyBandFrequencies:(float *)frequencies count:(NSInteger)count;

/// Latest gain curve (dB) and perceptual band levels (dB) for metering. Thread-safe.
- (void)copyBandGains:(float *)gains levels:(float *)levels count:(NSInteger)count;

/// Whether the analyzer is listening to the sidechain input (Sidechain on and a
/// sidechain signal arriving). Thread-safe.
@property (nonatomic, readonly, getter=isAnalyzingSidechain) BOOL analyzingSidechain;

/// Main-input (before processing) and output peaks since the previous call,
/// then cleared. Meant for one reader, the editor's meters. Thread-safe.
- (NMEQLevelPeaks)takeLevelPeaks;

@end

NS_ASSUME_NONNULL_END
