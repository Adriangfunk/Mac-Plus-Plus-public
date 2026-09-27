#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/AudioHardware.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <Accelerate/Accelerate.h>
#import <dispatch/dispatch.h>
#import <math.h>
#import <signal.h>
#import <stdbool.h>
#import <stdatomic.h>
#import <string.h>
#import <stdlib.h>
#import <errno.h>
#import <libproc.h>
#import <sys/stat.h>
#import <unistd.h>

#include "macpp_audio_engine.h"
#include "macpp_audio_dsp.h"
#include "macpp_audio_shared.h"

// Cleanup-only compatibility path from the pre-shared-memory transport.
static NSString *const kLegacyAudioStateCleanupPath = @"/tmp/macpp-audio-levels.json";
static NSString *const kMediaStatePath = @"/tmp/macpp-media.json";
// Media metadata is sampled by several independent providers. A single
// transient "paused" sample must not disable tap recovery while the actual
// output stream is still playing.
static const CFTimeInterval kMediaPauseDebounceSeconds = 1.50;
// If the tap remains alive but stops receiving real signal, a playing session
// still needs a recovery path. The hardware FFT heartbeat alone cannot detect
// that failure because zero-filled callbacks continue to advance it.
// A quiet section of a song is not a broken tap. Two seconds was short
// enough to turn normal pauses/fades into a destroy/create cycle, which made
// every visual consumer disappear briefly and could create a repeating audio
// drop. Require a sustained absence of signal before recovery instead.
static const CFTimeInterval kAudioSignalRecoverySeconds = 7.00;
static const CFTimeInterval kTapRecoveryCooldownSeconds = 15.0;
// Keep a short release tail in the shared activity bit. This prevents one
// empty callback from making every consumer cut to idle while a tap refresh is
// being scheduled, without keeping a genuinely paused session lit for long.
static const CFTimeInterval kAudioActivityReleaseSeconds = 1.25;
enum {
    kKeyboardColumns = 15,
    kFFTSize = 2048,
    kFFTHalf = 1024,
    kFFTLog2 = 11,
    // The shell consumes spectrum frames at about 35 Hz. Keep the compact
    // transform comfortably above that rate without recomputing it for every
    // small CoreAudio callback (which can be 90-180 callbacks/sec).
    kCompactFFTHop = 1024,
    // A separate, longer transform feeds keyboard hardware. The 2048-point
    // compact transform and its calibration remain unchanged; only its hop
    // cadence is bounded above. At 48 kHz,
    // 4096 samples put multiple bins into the lowest 30-46 Hz log band.
    kHardwareFFTSize = MACPP_AUDIO_HARDWARE_FFT_SIZE,
    kHardwareFFTHalf = MACPP_AUDIO_HARDWARE_FFT_HALF,
    kHardwareFFTLog2 = MACPP_AUDIO_HARDWARE_FFT_LOG2,
    kHardwareFFTHop = MACPP_AUDIO_HARDWARE_FFT_HOP,
    kHardwareChannels = MACPP_AUDIO_HARDWARE_MAX_CHANNELS
};

_Static_assert(kKeyboardColumns == MACPP_AUDIO_HARDWARE_BAND_COUNT,
               "hardware spectrum band count must match the keyboard");

static const float kBandFrequencies[kKeyboardColumns] = {
    70.0f, 100.0f, 145.0f, 205.0f, 290.0f,
    410.0f, 580.0f, 820.0f, 1160.0f, 1640.0f,
    2320.0f, 3280.0f, 4640.0f, 6560.0f, 9280.0f
};
static NSString *statusString(OSStatus status) {
    UInt32 value = CFSwapInt32HostToBig((UInt32)status);
    char text[5] = {0};
    memcpy(text, &value, 4);
    for (int i = 0; i < 4; i++) {
        if (text[i] < 32 || text[i] > 126) {
            return [NSString stringWithFormat:@"%d", (int)status];
        }
    }
    return [NSString stringWithFormat:@"'%s'", text];
}

// Exclude this analyzer from the global tap so its own output can never feed
// back into the displayed spectrum.
static NSArray<NSNumber *> *globalTapExcludedProcesses(void) {
    NSMutableArray<NSNumber *> *excluded = [NSMutableArray arrayWithCapacity:1];
    AudioObjectID ownProcess = kAudioObjectUnknown;
    pid_t pid = getpid();
    UInt32 size = sizeof(ownProcess);
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyTranslatePIDToProcessObject,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, sizeof(pid),
                               &pid, &size, &ownProcess);
    if (ownProcess != kAudioObjectUnknown) {
        [excluded addObject:@(ownProcess)];
    }
    return excluded;
}

@interface MacPlusPlusAudioEngine : NSObject {
    MacPlusPlusAudioEngineConfiguration _configuration;
    id<MacPlusPlusAudioRenderer> _renderer;
    MacPlusPlusAudioSharedMapping _audioShared;
    AudioObjectID _tapID;
    AudioObjectID _aggregateID;
    AudioDeviceIOProcID _ioProcID;
    AudioStreamBasicDescription _format;
    FFTSetup _fftSetup;
    float _fftWindow[kFFTSize];
    float _fftSamples[kFFTSize];
    float _fftReal[kFFTHalf];
    float _fftImag[kFFTHalf];
    float _fftMagnitudes[kFFTHalf];
    float _audioRing[kFFTSize];
    size_t _audioRingIndex;
    size_t _audioRingFill;
    size_t _fftFramesSinceTransform;
    FFTSetup _hardwareFFTSetup;
    float _hardwareFFTWindow[kHardwareFFTSize];
    float _hardwareFFTSamples[kHardwareFFTSize];
    float _hardwareFFTReal[kHardwareFFTHalf];
    float _hardwareFFTImag[kHardwareFFTHalf];
    float _hardwareFFTMagnitudes[kHardwareFFTHalf];
    float _hardwareAudioRing[kHardwareChannels][kHardwareFFTSize];
    size_t _hardwareAudioRingIndex;
    size_t _hardwareAudioRingFill;
    size_t _hardwareFramesSinceFFT;
    size_t _hardwareChannelCount;
    AudioObjectPropertyListenerBlock _outputDeviceListener;
    AudioDeviceID _lastDefaultOutputDevice;
    bool _defaultOutputDeviceKnown;
    // CoreAudio invokes the tap callback here. Retaining and draining this
    // queue prevents callbacks racing aggregate/tap teardown.
    dispatch_queue_t _audioQueue;
    dispatch_queue_t _analysisQueue;
    dispatch_source_t _analysisTimer;
    _Atomic(float) _latestRMS;
    _Atomic(float) _latestPeak;
    _Atomic(float) _latestBands[kKeyboardColumns];
    _Atomic(float) _latestHardwareDB[kKeyboardColumns];
    // Even values identify complete hardware FFT snapshots; odd values mean
    // the audio queue is currently publishing one. The lighting queue retries
    // an odd/changing sequence so it never blends two FFT frames.
    _Atomic(uint64_t) _hardwareSequence;
    _Atomic(bool) _hardwareResetRequested;
    float _bandFloor[kKeyboardColumns];
    float _bandCeiling[kKeyboardColumns];
    float _bands[kKeyboardColumns];
    MacPlusPlusAudioHardwareSpectrumEnvelope _hardwareSpectrum;
    uint64_t _lastHardwareSequence;
    CFAbsoluteTime _lastHardwareFFTTime;
    CFAbsoluteTime _audioTapStartTime;
    CFAbsoluteTime _lastAudioSignalTime;
    CFAbsoluteTime _lastMediaParseWarning;
    CFAbsoluteTime _lastMediaStateStatCheck;
    CFAbsoluteTime _lastPublishWarning;
    float _meterBands[6];
    float _level;
    float _beatFloor;
    float _beatPulse;
    float _beatStrength;
    float _lastTransient;
    float _bpm;
    float _bpmConfidence;
    float _previousTransient;
    // 32 rather than 16: the refinement below averages the aligned intervals,
    // and timing jitter falls as 1/sqrt(N), so a deeper history is a direct
    // precision win at negligible cost.
    float _beatIntervals[32];
    CFAbsoluteTime _lastBeatTime;
    CFAbsoluteTime _lastBeatDetectorRecovery;
    unsigned int _beatRecoveryCount;
    CFAbsoluteTime _lastTapRecoveryTime;
    int _beatIntervalCount;
    int _beatIntervalIndex;
    NSString *_mediaSessionKey;
    NSString *_mediaStateFingerprint;
    double _mediaPosition;
    CFAbsoluteTime _mediaPauseCandidateSince;
    bool _mediaWasPlaying;
    bool _mediaStateSeen;
    unsigned int _statePublishTick;
    bool _beatHit;
    bool _audioRouteWatchReady;
    bool _tapRefreshPending;
    bool _systemSleeping;
    _Atomic(double) _tapRecoverySuppressedUntil;
    _Atomic(bool) _audioCallbackEnabled;
    bool _running;
    bool _stopping;
    bool _loggedAudio;
}
- (instancetype)initWithConfiguration:(MacPlusPlusAudioEngineConfiguration)configuration
                        analysisQueue:(dispatch_queue_t)analysisQueue
                             renderer:(id<MacPlusPlusAudioRenderer>)renderer;
- (BOOL)start;
- (void)stop;
- (void)publishAudioResponse:(float)response level:(float)level bass:(float)bass;
- (void)beginAudioRouteMonitoring;
- (BOOL)readDefaultOutputDevice:(AudioDeviceID *)deviceOut;
- (void)audioRouteChanged;
- (void)handleSystemWillSleep:(NSNotification *)notification;
- (void)handleSystemDidWake:(NSNotification *)notification;
- (void)scheduleTapRefreshForReason:(NSString *)reason;
- (BOOL)createAudioTap API_AVAILABLE(macos(14.2));
- (void)destroyAudioTap;
- (void)clearPlaybackMetadata;
- (void)refreshPlaybackSession;
- (void)resetTempoState:(NSString *)reason;
- (void)removeLegacyAudioState;
@end

@implementation MacPlusPlusAudioEngine

- (instancetype)initWithConfiguration:(MacPlusPlusAudioEngineConfiguration)configuration
                        analysisQueue:(dispatch_queue_t)analysisQueue
                             renderer:(id<MacPlusPlusAudioRenderer>)renderer {
    self = [super init];
    if (self) {
        _configuration = configuration;
        _renderer = renderer;
        _tapID = kAudioObjectUnknown;
        _aggregateID = kAudioObjectUnknown;
        _ioProcID = NULL;
        _audioShared.fd = -1;
        _audioShared.owner_fd = -1;
        _audioShared.state = NULL;
        _fftSetup = vDSP_create_fftsetup(kFFTLog2, kFFTRadix2);
        vDSP_hann_window(_fftWindow, kFFTSize, vDSP_HANN_NORM);
        _hardwareFFTSetup =
            vDSP_create_fftsetup(kHardwareFFTLog2, kFFTRadix2);
        // A NULL setup silently disables the full-resolution spectrum while
        // leaving the compact meters alive, so make the fallback explicit.
        if (_hardwareFFTSetup == NULL) {
            NSLog(@"Hardware FFT setup could not be allocated; "
                  "hardware consumers will fall back to the compact spectrum.");
        }
        if (_fftSetup == NULL) {
            NSLog(@"Primary FFT setup could not be allocated; "
                  "spectrum lighting will not work.");
        }
        vDSP_hann_window(_hardwareFFTWindow, kHardwareFFTSize,
                         vDSP_HANN_NORM);
        memset(_audioRing, 0, sizeof(_audioRing));
        memset(_hardwareAudioRing, 0, sizeof(_hardwareAudioRing));
        _audioRingIndex = 0;
        _audioRingFill = 0;
        _fftFramesSinceTransform = 0;
        _hardwareAudioRingIndex = 0;
        _hardwareAudioRingFill = 0;
        _hardwareFramesSinceFFT = 0;
        _hardwareChannelCount = 1;
        memset(&_hardwareSpectrum, 0, sizeof(_hardwareSpectrum));
        _lastHardwareSequence = 0;
        _lastHardwareFFTTime = 0.0;
        _audioTapStartTime = 0.0;
        _lastAudioSignalTime = 0.0;
        _lastDefaultOutputDevice = kAudioObjectUnknown;
        _defaultOutputDeviceKnown = false;
        _outputDeviceListener = nil;
        _audioQueue = nil;
        _analysisQueue = analysisQueue;
        _level = 0.0f;
        _beatFloor = 0.0f;
        _beatPulse = 0.0f;
        _beatStrength = 0.0f;
        _lastTransient = 0.0f;
        _previousTransient = 0.0f;
        _bpm = 0.0f;
        _bpmConfidence = 0.0f;
        _lastBeatTime = 0.0;
        _lastBeatDetectorRecovery = 0.0;
        _beatRecoveryCount = 0;
        _lastTapRecoveryTime = 0.0;
        _beatIntervalCount = 0;
        _beatIntervalIndex = 0;
        _mediaSessionKey = @"";
        _mediaStateFingerprint = nil;
        _mediaPosition = 0.0;
        _mediaPauseCandidateSince = 0.0;
        _mediaWasPlaying = false;
        _mediaStateSeen = false;
        _lastMediaStateStatCheck = 0.0;
        _statePublishTick = 0;
        _beatHit = false;
        _audioRouteWatchReady = false;
        _tapRefreshPending = false;
        _systemSleeping = false;
        _stopping = false;
        atomic_init(&_tapRecoverySuppressedUntil, 0.0);
        atomic_init(&_audioCallbackEnabled, false);
        atomic_init(&_latestRMS, 0.0f);
        atomic_init(&_latestPeak, 0.0f);
        atomic_init(&_hardwareSequence, 0);
        atomic_init(&_hardwareResetRequested, false);
        for (int column = 0; column < kKeyboardColumns; column++) {
            atomic_init(&_latestBands[column], 0.0f);
            atomic_init(&_latestHardwareDB[column], MACPP_AUDIO_HARDWARE_MINIMUM_DB);
            _bandFloor[column] = 0.0f;
            _bandCeiling[column] = 0.0008f;
            _bands[column] = 0.0f;
        }
        for (int group = 0; group < 6; group++) {
            _meterBands[group] = 0.0f;
        }
    }
    return self;
}

- (void)resetTempoState:(NSString *)reason {
    _beatFloor = 0.0f;
    _beatPulse = 0.0f;
    _beatStrength = 0.0f;
    _lastTransient = 0.0f;
    _previousTransient = 0.0f;
    _bpm = 0.0f;
    _bpmConfidence = 0.0f;
    _lastBeatTime = 0.0;
    _beatIntervalCount = 0;
    _beatIntervalIndex = 0;
    _beatHit = false;
    memset(_beatIntervals, 0, sizeof(_beatIntervals));
    _lastBeatDetectorRecovery = CFAbsoluteTimeGetCurrent();
    NSLog(@"BPM tempo session reset: %@", reason ?: @"session boundary");
}

- (void)clearPlaybackMetadata {
    // Metadata is advisory. Once it is missing, unreadable, stale, or
    // malformed, it must not keep a stopped session looking playable to the
    // tap-recovery watchdog. Clear the fingerprint too so an atomic publisher
    // can be retried even if the replacement file keeps the same contents.
    _mediaStateFingerprint = nil;
    _mediaPauseCandidateSince = 0.0;
    _mediaWasPlaying = false;
    _mediaStateSeen = false;
    _mediaSessionKey = @"";
    _mediaPosition = 0.0;
}

- (void)refreshPlaybackSession {
    // The media publisher updates this file much less often than the audio
    // analysis timer runs. Reopening and parsing unchanged JSON every 28 ms
    // showed up in the audio puller's profile, especially while the rest of
    // the system was already decoding the wallpaper. Stat at a modest cadence
    // and parse only when the atomic publisher changes the file.
    CFAbsoluteTime statNow = CFAbsoluteTimeGetCurrent();
    if (statNow - _lastMediaStateStatCheck < 0.20) return;
    _lastMediaStateStatCheck = statNow;
    struct stat mediaAttributes;
    if (stat(kMediaStatePath.fileSystemRepresentation, &mediaAttributes) != 0) {
        // The media publisher uses an atomic replacement, so a healthy update
        // can make this path absent for one polling turn. Do not preserve a
        // stale "playing" bit across that boundary: if the file is genuinely
        // gone while playback has stopped, treating the old state as live
        // makes the recovery watchdog destroy/recreate the audio tap and
        // publishes a zeroed spectrum to the lighting consumers.
        [self clearPlaybackMetadata];
        return;
    }
    NSString *fingerprint = [NSString stringWithFormat:@"%llu:%lld:%lld:%ld",
        (unsigned long long)mediaAttributes.st_ino,
        (long long)mediaAttributes.st_size,
        (long long)mediaAttributes.st_mtimespec.tv_sec,
        (long)mediaAttributes.st_mtimespec.tv_nsec];
    if (_mediaStateFingerprint != nil &&
        [_mediaStateFingerprint isEqualToString:fingerprint]) {
        return;
    }
    _mediaStateFingerprint = fingerprint;

    NSData *data = [NSData dataWithContentsOfFile:kMediaStatePath];
    if (data == nil) {
        [self clearPlaybackMetadata];
        return;
    }
    NSError *parseError = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data
                                                           options:0
                                                             error:&parseError];
    if (![json isKindOfClass:NSDictionary.class]) {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - _lastMediaParseWarning >= 30.0) {
            NSLog(@"Media state was not valid JSON metadata: %@",
                  parseError.localizedDescription ?: @"root was not a dictionary");
            _lastMediaParseWarning = now;
        }
        [self clearPlaybackMetadata];
        return;
    }

    double now = CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970;
    NSNumber *updated = json[@"updated_at"];
    if ([updated respondsToSelector:@selector(doubleValue)] &&
        updated.doubleValue > 0.0 && fabs(now - updated.doubleValue) > 10.0) {
        [self clearPlaybackMetadata];
        return;
    }

    NSString *state = [json[@"state"] isKindOfClass:NSString.class]
        ? [json[@"state"] lowercaseString] : @"stopped";
    bool playing = [state isEqualToString:@"playing"];
    NSString *key = [json[@"session_key"] isKindOfClass:NSString.class]
        ? json[@"session_key"] : @"";
    if (key.length == 0) {
        NSString *source = [json[@"source"] isKindOfClass:NSString.class]
            ? json[@"source"] : @"";
        NSString *artist = [json[@"artist"] isKindOfClass:NSString.class]
            ? json[@"artist"] : @"";
        NSString *track = [json[@"track"] isKindOfClass:NSString.class]
            ? json[@"track"] : @"";
        NSString *album = [json[@"album"] isKindOfClass:NSString.class]
            ? json[@"album"] : @"";
        double duration = [json[@"duration"] respondsToSelector:@selector(doubleValue)]
            ? [json[@"duration"] doubleValue] : 0.0;
        if (source.length > 0 || track.length > 0) {
            key = [NSString stringWithFormat:@"%@|%@|%@|%@|%.0f",
                source, artist, track, album, duration];
        }
    }

    NSNumber *positionNumber = json[@"position"];
    bool positionKnown = [positionNumber respondsToSelector:@selector(doubleValue)];
    double position = positionKnown ? positionNumber.doubleValue : 0.0;
    // Spotify's desktop AppleScript and its MediaRemote/CLI provider can
    // disagree for one refresh while a track is buffering or the app is
    // handing off its output route. Debounce only the playing -> paused edge
    // for the same track; a real pause is still accepted promptly, while a
    // single bad sample cannot suppress tap recovery.
    CFAbsoluteTime playbackNow = CFAbsoluteTimeGetCurrent();
    bool effectivePlaying = playing;
    bool sameSession = key.length == 0 || _mediaSessionKey.length == 0 ||
        [key isEqualToString:_mediaSessionKey];
    if (_mediaStateSeen && _mediaWasPlaying && !playing && sameSession) {
        if (_mediaPauseCandidateSince <= 0.0) {
            _mediaPauseCandidateSince = playbackNow;
        }
        if (playbackNow - _mediaPauseCandidateSince < kMediaPauseDebounceSeconds) {
            effectivePlaying = true;
        }
    } else if (playing) {
        _mediaPauseCandidateSince = 0.0;
    } else if (!sameSession) {
        _mediaPauseCandidateSince = 0.0;
    }

    bool boundary = false;
    NSString *reason = nil;
    if (_mediaStateSeen) {
        if (key.length > 0 && _mediaSessionKey.length > 0 &&
            ![key isEqualToString:_mediaSessionKey]) {
            boundary = true;
            reason = @"media item changed";
        } else if (effectivePlaying && _mediaWasPlaying && positionKnown &&
                   fabs(position - _mediaPosition) > 5.0) {
            boundary = true;
            reason = @"seek detected";
        } else if (effectivePlaying != _mediaWasPlaying) {
            boundary = true;
            reason = effectivePlaying ? @"playback resumed" : @"playback paused";
        }
    }
    if (boundary) [self resetTempoState:reason];

    if (key.length > 0) _mediaSessionKey = [key copy];
    _mediaPosition = position;
    _mediaWasPlaying = effectivePlaying;
    _mediaStateSeen = true;
}

- (void)beginAudioRouteMonitoring {
    __weak MacPlusPlusAudioEngine *weakSelf = self;
    _outputDeviceListener =
        ^(UInt32 numberAddresses, const AudioObjectPropertyAddress *addresses) {
            (void)numberAddresses;
            (void)addresses;
            [weakSelf audioRouteChanged];
        };
    AudioObjectPropertyAddress outputAddress = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioObjectPropertyAddress systemAddress = {
        kAudioHardwarePropertyDefaultSystemOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    OSStatus outputStatus = AudioObjectAddPropertyListenerBlock(
        kAudioObjectSystemObject, &outputAddress, dispatch_get_main_queue(),
        _outputDeviceListener);
    OSStatus systemStatus = AudioObjectAddPropertyListenerBlock(
        kAudioObjectSystemObject, &systemAddress, dispatch_get_main_queue(),
        _outputDeviceListener);
    if (outputStatus != noErr && systemStatus != noErr) {
        NSLog(@"Could not monitor audio output route changes.");
        _outputDeviceListener = nil;
        return;
    }
    AudioDeviceID initialDevice = kAudioObjectUnknown;
    _defaultOutputDeviceKnown = [self readDefaultOutputDevice:&initialDevice];
    if (_defaultOutputDeviceKnown) {
        _lastDefaultOutputDevice = initialDevice;
    }
    _audioRouteWatchReady = true;
    NSLog(@"Audio output route monitoring is active.");
}

- (BOOL)readDefaultOutputDevice:(AudioDeviceID *)deviceOut {
    if (deviceOut == NULL) return NO;
    AudioDeviceID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    OSStatus status = AudioObjectGetPropertyData(
        kAudioObjectSystemObject, &address, 0, NULL, &size, &device);
    if (status != noErr || device == kAudioObjectUnknown) return NO;
    *deviceOut = device;
    return YES;
}

- (void)handleSystemWillSleep:(NSNotification *)notification {
    if (_systemSleeping) return;
    _systemSleeping = true;
    NSLog(@"%@ received; pausing audio tap for sleep.",
          notification.name);
    // Keep the supervised process alive across sleep. Exiting here used to
    // leave launchd's RunAtLoad-only job in the `exited` state after wake,
    // removing the shared audio snapshot and freezing every MacPlusPlus visualizer.
    [_renderer prepareForSystemSleep];
    [self destroyAudioTap];
    atomic_store_explicit(&_latestRMS, 0.0f, memory_order_relaxed);
    atomic_store_explicit(&_latestPeak, 0.0f, memory_order_relaxed);
}

- (void)handleSystemDidWake:(NSNotification *)notification {
    _systemSleeping = false;
    NSLog(@"%@ received; resuming audio tap after wake.", notification.name);
    [_renderer resumeAfterSystemWake];
    [self scheduleTapRefreshForReason:@"System woke"];
}

- (void)scheduleTapRefreshForReason:(NSString *)reason {
    // Route listeners and stall recovery arrive on different queues. Keep
    // destroy/create and debounce ownership on the main queue.
    __weak MacPlusPlusAudioEngine *weakSelf = self;
    NSString *refreshReason = [reason copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        MacPlusPlusAudioEngine *strongSelf = weakSelf;
        if (strongSelf == nil || !strongSelf->_running ||
            strongSelf->_systemSleeping || strongSelf->_tapRefreshPending) {
            return;
        }
        strongSelf->_tapRefreshPending = true;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 350 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            MacPlusPlusAudioEngine *current = weakSelf;
            if (current == nil) return;
            if (!current->_running || current->_systemSleeping) {
                current->_tapRefreshPending = false;
                return;
            }
            NSLog(@"%@; reattaching system audio tap.", refreshReason);
            [current destroyAudioTap];
            atomic_store_explicit(&current->_latestRMS, 0.0f,
                                  memory_order_relaxed);
            atomic_store_explicit(&current->_latestPeak, 0.0f,
                                  memory_order_relaxed);
            bool attached = false;
            if (@available(macOS 14.2, *)) {
                attached = [current createAudioTap];
            }
            current->_tapRefreshPending = false;
            atomic_store_explicit(&current->_tapRecoverySuppressedUntil,
                                  CFAbsoluteTimeGetCurrent() +
                                  (attached ? 3.0 : 1.0),
                                  memory_order_release);
            NSLog(attached ? @"System audio tap reattached."
                           : @"Could not reattach system audio tap.");
        });
    });
}

- (void)audioRouteChanged {
    AudioDeviceID currentDevice = kAudioObjectUnknown;
    if (![self readDefaultOutputDevice:&currentDevice]) {
        // A route can briefly disappear while macOS is switching devices.
        // Mark the identity unknown, but wait for the next valid device before
        // tearing down a healthy tap.
        _defaultOutputDeviceKnown = false;
        return;
    }
    if (_defaultOutputDeviceKnown &&
        currentDevice == _lastDefaultOutputDevice) {
        // Both default-output selectors can fire for one transition. The tap
        // only needs a refresh when the actual device identity changes.
        return;
    }
    _lastDefaultOutputDevice = currentDevice;
    _defaultOutputDeviceKnown = true;
    [self scheduleTapRefreshForReason:@"Audio output route changed"];
}

- (BOOL)createAudioTap API_AVAILABLE(macos(14.2)) {
    NSArray<NSNumber *> *excludedProcesses = globalTapExcludedProcesses();
    CATapDescription *description =
        [[CATapDescription alloc]
            initStereoGlobalTapButExcludeProcesses:excludedProcesses];
    description.name = _configuration.productName;
    description.UUID = [NSUUID UUID];
    description.privateTap = YES;
    description.muteBehavior = CATapUnmuted;

    OSStatus status = AudioHardwareCreateProcessTap(description, &_tapID);
    if (status != noErr) {
        NSLog(@"Could not create audio tap: %@. Check System Audio Recording permission.",
              statusString(status));
        return NO;
    }

    NSDictionary *subTap = @{
        @kAudioSubTapUIDKey: description.UUID.UUIDString,
        @kAudioSubTapDriftCompensationKey: @YES
    };
    NSDictionary *aggregate = @{
        @kAudioAggregateDeviceNameKey: _configuration.productName,
        @kAudioAggregateDeviceUIDKey: _configuration.aggregateUID,
        @kAudioAggregateDeviceIsPrivateKey: @YES,
        @kAudioAggregateDeviceTapAutoStartKey: @YES,
        @kAudioAggregateDeviceTapListKey: @[subTap]
    };
    status = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)aggregate,
                                                 &_aggregateID);
    if (status != noErr) {
        NSLog(@"Could not create audio tap device: %@", statusString(status));
        [self destroyAudioTap];
        return NO;
    }

    AudioObjectPropertyAddress formatAddress = {
        kAudioTapPropertyFormat,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 formatSize = sizeof(_format);
    status = AudioObjectGetPropertyData(_tapID, &formatAddress, 0, NULL,
                                        &formatSize, &_format);
    if (status != noErr ||
        _format.mFormatID != kAudioFormatLinearPCM ||
        (_format.mFormatFlags & kAudioFormatFlagIsFloat) == 0) {
        NSLog(@"Tap returned an unsupported sample format.");
        [self destroyAudioTap];
        return NO;
    }

    _audioQueue = dispatch_queue_create(_configuration.audioQueueLabel,
                                        DISPATCH_QUEUE_SERIAL);
    __weak MacPlusPlusAudioEngine *weakSelf = self;
    status = AudioDeviceCreateIOProcIDWithBlock(
        &_ioProcID, _aggregateID, _audioQueue,
        ^(const AudioTimeStamp *now, const AudioBufferList *inputData,
          const AudioTimeStamp *inputTime, AudioBufferList *outputData,
          const AudioTimeStamp *outputTime) {
            (void)now;
            (void)inputTime;
            (void)outputData;
            (void)outputTime;
            MacPlusPlusAudioEngine *strongSelf = weakSelf;
            if (strongSelf == nil || inputData == NULL ||
                !atomic_load_explicit(&strongSelf->_audioCallbackEnabled,
                                      memory_order_acquire)) {
                return;
            }
            double squared = 0.0;
            float peak = 0.0f;
            size_t samples = 0;
            for (UInt32 bufferIndex = 0; bufferIndex < inputData->mNumberBuffers;
                 bufferIndex++) {
                AudioBuffer buffer = inputData->mBuffers[bufferIndex];
                const float *values = (const float *)buffer.mData;
                size_t count = buffer.mDataByteSize / sizeof(float);
                if (values == NULL || count == 0) continue;
                for (size_t index = 0; index < count; index++) {
                    float sampleValue = values[index];
                    if (!isfinite(sampleValue)) continue;
                    float value = fabsf(sampleValue);
                    squared += value * value;
                    if (value > peak) {
                        peak = value;
                    }
                    samples++;
                }
            }
            if (samples > 0) {
                atomic_store_explicit(&strongSelf->_latestRMS,
                                      sqrtf((float)(squared / samples)),
                                      memory_order_relaxed);
                atomic_store_explicit(&strongSelf->_latestPeak, peak,
                                      memory_order_relaxed);
            } else {
                // A transiently empty or invalid CoreAudio buffer should be
                // treated as silence, not as permission to reuse the previous
                // frame forever.
                atomic_store_explicit(&strongSelf->_latestRMS, 0.0f,
                                      memory_order_relaxed);
                atomic_store_explicit(&strongSelf->_latestPeak, 0.0f,
                                      memory_order_relaxed);
            }

            if (inputData->mNumberBuffers > 0 &&
                strongSelf->_format.mSampleRate > 0 &&
                strongSelf->_fftSetup != NULL) {
                bool nonInterleaved =
                    (strongSelf->_format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
                size_t channels = nonInterleaved
                    ? MAX((size_t)1, (size_t)inputData->mNumberBuffers)
                    : MAX((size_t)1, (size_t)strongSelf->_format.mChannelsPerFrame);
                AudioBuffer firstBuffer = inputData->mBuffers[0];
                const float *firstValues = (const float *)firstBuffer.mData;
                size_t firstValueCount = firstBuffer.mDataByteSize / sizeof(float);
                size_t totalFrames = nonInterleaved
                    ? firstValueCount
                    : firstValueCount / channels;
                size_t hardwareChannelCount = nonInterleaved
                    ? MIN((size_t)inputData->mNumberBuffers,
                          (size_t)kHardwareChannels)
                    : MIN(channels, (size_t)kHardwareChannels);
                hardwareChannelCount = MAX((size_t)1, hardwareChannelCount);

                if (firstValues != NULL && totalFrames > 0) {
                    for (size_t frame = 0; frame < totalFrames; frame++) {
                        float sample = 0.0f;
                        float channelSamples[kHardwareChannels] = {0.0f, 0.0f};
                        if (nonInterleaved) {
                            size_t activeChannels = 0;
                            for (UInt32 bufferIndex = 0;
                                 bufferIndex < inputData->mNumberBuffers;
                                 bufferIndex++) {
                                AudioBuffer buffer = inputData->mBuffers[bufferIndex];
                                const float *values = (const float *)buffer.mData;
                                size_t valueCount = buffer.mDataByteSize / sizeof(float);
                                if (values != NULL && frame < valueCount) {
                                    float value = values[frame];
                                    if (isfinite(value)) {
                                        sample += value;
                                        if (bufferIndex < kHardwareChannels) {
                                            channelSamples[bufferIndex] = value;
                                        }
                                        activeChannels++;
                                    }
                                }
                            }
                            if (activeChannels > 0) {
                                sample /= (float)activeChannels;
                            }
                        } else {
                            size_t base = frame * channels;
                            for (size_t channel = 0; channel < channels; channel++) {
                                float value = firstValues[base + channel];
                                if (!isfinite(value)) value = 0.0f;
                                sample += value;
                                if (channel < kHardwareChannels) {
                                    channelSamples[channel] =
                                        value;
                                }
                            }
                            sample /= (float)channels;
                        }
                        strongSelf->_audioRing[strongSelf->_audioRingIndex] = sample;
                        strongSelf->_audioRingIndex =
                            (strongSelf->_audioRingIndex + 1) % kFFTSize;
                        if (strongSelf->_audioRingFill < kFFTSize) {
                            strongSelf->_audioRingFill++;
                        }
                        for (size_t channel = 0;
                             channel < (size_t)kHardwareChannels; channel++) {
                            strongSelf->_hardwareAudioRing[channel]
                                [strongSelf->_hardwareAudioRingIndex] =
                                    channelSamples[channel];
                        }
                        strongSelf->_hardwareAudioRingIndex =
                            (strongSelf->_hardwareAudioRingIndex + 1) %
                            kHardwareFFTSize;
                        if (strongSelf->_hardwareAudioRingFill <
                            kHardwareFFTSize) {
                            strongSelf->_hardwareAudioRingFill++;
                        }
                    }
                    strongSelf->_hardwareChannelCount = hardwareChannelCount;
                    strongSelf->_hardwareFramesSinceFFT += totalFrames;

                    strongSelf->_fftFramesSinceTransform += totalFrames;
                    bool compactFFTReady =
                        strongSelf->_fftFramesSinceTransform >= kCompactFFTHop;
                    if (compactFFTReady) {
                        strongSelf->_fftFramesSinceTransform %= kCompactFFTHop;
                    }

                    if (compactFFTReady) {
                        size_t available =
                            MIN(strongSelf->_audioRingFill, (size_t)kFFTSize);
                        vDSP_vclr(strongSelf->_fftSamples, 1, kFFTSize);
                        size_t padding = kFFTSize - available;
                        for (size_t sampleIndex = 0;
                             sampleIndex < available;
                             sampleIndex++) {
                            size_t ringIndex =
                                (strongSelf->_audioRingIndex + kFFTSize - available +
                                 sampleIndex) % kFFTSize;
                            size_t destination = padding + sampleIndex;
                            strongSelf->_fftSamples[destination] =
                                strongSelf->_audioRing[ringIndex] *
                                strongSelf->_fftWindow[destination];
                        }

                        for (int index = 0; index < kFFTHalf; index++) {
                            strongSelf->_fftReal[index] =
                                strongSelf->_fftSamples[index * 2];
                            strongSelf->_fftImag[index] =
                                strongSelf->_fftSamples[index * 2 + 1];
                        }
                        DSPSplitComplex split = {
                            .realp = strongSelf->_fftReal,
                            .imagp = strongSelf->_fftImag
                        };
                        vDSP_fft_zrip(strongSelf->_fftSetup, &split, 1, kFFTLog2,
                                      FFT_FORWARD);
                        float scale = 1.0f / (float)kFFTSize;
                        vDSP_vsmul(split.realp, 1, &scale, split.realp, 1, kFFTHalf);
                        vDSP_vsmul(split.imagp, 1, &scale, split.imagp, 1, kFFTHalf);
                        vDSP_zvmags(&split, 1, strongSelf->_fftMagnitudes, 1,
                                    kFFTHalf);
                        strongSelf->_fftMagnitudes[0] = 0.0f;

                        float binHz =
                            (float)strongSelf->_format.mSampleRate / (float)kFFTSize;
                        float nyquist =
                            (float)strongSelf->_format.mSampleRate * 0.5f;
                        for (int band = 0; band < kKeyboardColumns; band++) {
                            float center = kBandFrequencies[band];
                            float lower = band == 0
                                ? 25.0f
                                : sqrtf(kBandFrequencies[band - 1] * center);
                            float upper = band == (kKeyboardColumns - 1)
                                ? fminf(nyquist * 0.88f, center * 1.42f)
                                : sqrtf(center * kBandFrequencies[band + 1]);
                            int firstBin = MAX(1, (int)floorf(lower / binHz));
                            int lastBin =
                                MIN(kFFTHalf - 1, (int)ceilf(upper / binHz));
                            float weightedPower = 0.0f;
                            float weights = 0.0f;
                            for (int bin = firstBin; bin <= lastBin; bin++) {
                                float hz = (float)bin * binHz;
                                float octaveDistance =
                                    fabsf(log2f(fmaxf(hz, 1.0f) / center));
                                float weight = fmaxf(0.05f, 1.0f - octaveDistance);
                                weightedPower +=
                                    strongSelf->_fftMagnitudes[bin] * weight;
                                weights += weight;
                            }
                            float averagePower =
                                weights > 0.0f ? weightedPower / weights : 0.0f;
                            float rmsMagnitude = sqrtf(fmaxf(0.0f, averagePower));
                            float magnitude = log1pf(rmsMagnitude * 680.0f);
                            atomic_store_explicit(&strongSelf->_latestBands[band],
                                                  magnitude, memory_order_relaxed);
                        }
                    }

                    if (strongSelf->_hardwareFFTSetup != NULL &&
                        strongSelf->_hardwareFramesSinceFFT >=
                            kHardwareFFTHop) {
                        strongSelf->_hardwareFramesSinceFFT %=
                            kHardwareFFTHop;
                        float hardwareDB[kKeyboardColumns];
                        macpp_audio_calculate_hardware_band_db(
                            strongSelf->_hardwareAudioRing,
                            strongSelf->_hardwareAudioRingIndex,
                            strongSelf->_hardwareAudioRingFill,
                            strongSelf->_hardwareChannelCount,
                            (float)strongSelf->_format.mSampleRate,
                            strongSelf->_hardwareFFTSetup,
                            strongSelf->_hardwareFFTWindow,
                            strongSelf->_hardwareFFTSamples,
                            strongSelf->_hardwareFFTReal,
                            strongSelf->_hardwareFFTImag,
                            strongSelf->_hardwareFFTMagnitudes,
                            hardwareDB);
                        atomic_fetch_add_explicit(
                            &strongSelf->_hardwareSequence, 1,
                            memory_order_acq_rel);
                        for (int band = 0; band < kKeyboardColumns; band++) {
                            atomic_store_explicit(
                                &strongSelf->_latestHardwareDB[band],
                                hardwareDB[band], memory_order_relaxed);
                        }
                        atomic_fetch_add_explicit(
                            &strongSelf->_hardwareSequence, 1,
                            memory_order_release);
                    }
                }
            }
        });
    if (status != noErr) {
        NSLog(@"Could not attach the audio callback: %@", statusString(status));
        [self destroyAudioTap];
        return NO;
    }
    atomic_store_explicit(&_audioCallbackEnabled, true, memory_order_release);
    status = AudioDeviceStart(_aggregateID, _ioProcID);
    if (status != noErr) {
        NSLog(@"Could not start audio capture: %@", statusString(status));
        [self destroyAudioTap];
        return NO;
    }
    _audioTapStartTime = CFAbsoluteTimeGetCurrent();
    atomic_store_explicit(&_tapRecoverySuppressedUntil,
                          _audioTapStartTime + 3.0,
                          memory_order_release);
    return YES;
}

- (void)destroyAudioTap {
    atomic_store_explicit(&_audioCallbackEnabled, false, memory_order_release);
    if (_ioProcID != NULL && _aggregateID != kAudioObjectUnknown) {
        AudioDeviceStop(_aggregateID, _ioProcID);
        if (_audioQueue != nil) dispatch_sync(_audioQueue, ^{});
        AudioDeviceDestroyIOProcID(_aggregateID, _ioProcID);
        _ioProcID = NULL;
    } else if (_audioQueue != nil) {
        dispatch_sync(_audioQueue, ^{});
    }
    _audioQueue = nil;
    if (_aggregateID != kAudioObjectUnknown) {
        AudioHardwareDestroyAggregateDevice(_aggregateID);
        _aggregateID = kAudioObjectUnknown;
    }
    if (_tapID != kAudioObjectUnknown) {
        if (@available(macOS 14.2, *)) {
            AudioHardwareDestroyProcessTap(_tapID);
        }
        _tapID = kAudioObjectUnknown;
    }
    // Do not mix samples from two output routes in the hardware-only FFT.
    _hardwareAudioRingIndex = 0;
    _hardwareAudioRingFill = 0;
    _hardwareFramesSinceFFT = 0;
    _fftFramesSinceTransform = 0;
    _hardwareChannelCount = 1;
    atomic_fetch_add_explicit(&_hardwareSequence, 1, memory_order_acq_rel);
    for (int band = 0; band < kKeyboardColumns; band++) {
        atomic_store_explicit(&_latestHardwareDB[band], MACPP_AUDIO_HARDWARE_MINIMUM_DB,
                              memory_order_relaxed);
    }
    atomic_fetch_add_explicit(&_hardwareSequence, 1, memory_order_release);
    // The envelope itself belongs to the lighting queue; request its reset
    // there rather than writing cross-queue state during tap teardown.
    atomic_store_explicit(&_hardwareResetRequested, true, memory_order_release);
    atomic_store_explicit(&_tapRecoverySuppressedUntil,
                          CFAbsoluteTimeGetCurrent() + 0.75,
                          memory_order_release);
}

- (void)publishAudioResponse:(float)response level:(float)level bass:(float)bass {
    _statePublishTick++;
    // Publish the analyzer at a steady cadence while avoiding repeated frames.
    if (!_beatHit && (_statePublishTick % 2) != 0) {
        return;
    }

    CFAbsoluteTime publishTime = CFAbsoluteTimeGetCurrent();
    double beatAge = _lastBeatTime > 0.0
        ? publishTime - _lastBeatTime
        : 999.0;
    double hardwareAgeMilliseconds = _lastHardwareFFTTime > 0.0
        ? fmax(0.0, (publishTime - _lastHardwareFFTTime) * 1000.0)
        : 999000.0;
    float safeResponse = macpp_audio_finite_clamp(response, 0.0f, 1.0f);
    float safeLevel = macpp_audio_finite_clamp(level, 0.0f, 4.0f);
    float safeBass = macpp_audio_finite_clamp(bass, 0.0f, 4.0f);
    float safeBeatPulse = macpp_audio_finite_clamp(_beatPulse, 0.0f, 1.0f);
    float safeBeatStrength = macpp_audio_finite_clamp(_beatStrength, 0.0f, 1.0f);
    float safeBeatFloor = macpp_audio_finite_clamp(_beatFloor, 0.0f, 1.0f);
    // Upper bound only as an overflow guard, not as a tempo opinion.
    float safeBPM = macpp_audio_finite_clamp(_bpm, 0.0f, 1000.0f);
    float safeConfidence = macpp_audio_finite_clamp(_bpmConfidence, 0.0f, 1.0f);
    if (safeBPM < 1.0f) safeBPM = 0.0f;
    if (safeConfidence < 0.01f) safeConfidence = 0.0f;
    // Normalize only the sanitized value so the raw and display fields cannot
    // disagree when the detector has decayed into a subnormal float.
    float displayBPM = macpp_audio_normalized_display_bpm(safeBPM);
    float bandMin = 1.0f;
    float bandMax = 0.0f;
    float bandAverage = 0.0f;
    for (int column = 0; column < kKeyboardColumns; column++) {
        bandMin = fminf(bandMin, _bands[column]);
        bandMax = fmaxf(bandMax, _bands[column]);
        bandAverage += _bands[column] / (float)kKeyboardColumns;
    }
    float bandRange = fmaxf(0.001f, bandMax - bandMin);
    float visualBands[kKeyboardColumns];
    float visualPeak = 0.0f;
    for (int column = 0; column < kKeyboardColumns; column++) {
        float contrast = (_bands[column] - bandMin) / bandRange;
        float lift = fmaxf(0.0f, _bands[column] - bandAverage) * 1.6f;
        float usableRange = bandRange < 0.11f ? bandRange / 0.11f : 1.0f;
        float shaped = 0.04f + (powf(contrast, 1.45f) * 0.58f + lift * 0.18f) * usableRange;
        if (safeResponse < 0.010f) {
            shaped *= 0.18f;
        }
        visualBands[column] = macpp_audio_finite_clamp(shaped, 0.0f, 0.78f);
        visualPeak = fmaxf(visualPeak, visualBands[column]);
    }

    float visualMeters[6] = {0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f};
    for (int column = 0; column < kKeyboardColumns; column++) {
        int group = column < 2 ? 0 :
            (column < 4 ? 1 :
            (column < 6 ? 2 :
            (column < 9 ? 3 :
            (column < 12 ? 4 : 5))));
        visualMeters[group] = fmaxf(visualMeters[group], visualBands[column]);
    }
    NSMutableArray<NSNumber *> *bars = [NSMutableArray arrayWithCapacity:6];
    for (int group = 0; group < 6; group++) {
        [bars addObject:@(macpp_audio_finite_clamp(visualMeters[group], 0.0f, 1.0f))];
    }
    NSMutableArray<NSNumber *> *spectrum =
        [NSMutableArray arrayWithCapacity:kKeyboardColumns];
    for (int column = 0; column < kKeyboardColumns; column++) {
        [spectrum addObject:@(macpp_audio_finite_clamp(visualBands[column], 0.0f, 1.0f))];
    }
    // `spectrum` is intentionally contrast-shaped for compact shell meters:
    // every update is normalised against that frame's min/max, which can make
    // a quiet band appear to jump when another band changes. Hardware lighting
    // needs the already attack/release-smoothed values instead. Publish both
    // views so existing MacPlusPlus UI consumers keep their high-contrast meters while
    // keyboard consumers can follow a stable physical envelope.
    NSMutableArray<NSNumber *> *smoothSpectrum =
        [NSMutableArray arrayWithCapacity:kKeyboardColumns];
    for (int column = 0; column < kKeyboardColumns; column++) {
        [smoothSpectrum addObject:@(macpp_audio_finite_clamp(_bands[column], 0.0f, 1.0f))];
    }
    // Hardware consumers get a separate full-range spectrum. It is derived
    // from stereo power and one shared dB reference; none of the compact UI
    // arrays above are modified.
    NSMutableArray<NSNumber *> *hardwareSpectrum =
        [NSMutableArray arrayWithCapacity:kKeyboardColumns];
    for (int column = 0; column < kKeyboardColumns; column++) {
        [hardwareSpectrum addObject:@(macpp_audio_finite_clamp(
            _hardwareSpectrum.bands[column], 0.0f, 1.0f))];
    }

    MacPlusPlusAudioRendererTelemetry rendererTelemetry = {
        .mouseMode = MacPlusPlusAudioRendererModeExternal,
        .mouseLastFailureAge = -1.0,
    };
    NSString *tempoState = safeBPM > 0.0f && safeConfidence >= 0.30f
        ? @"locked" : (_mediaWasPlaying ? @"learning" : @"idle");
    if (_renderer != nil) [_renderer copyTelemetry:&rendererTelemetry];
    NSString *mouseMode = @"external";
    switch (rendererTelemetry.mouseMode) {
        case MacPlusPlusAudioRendererModeStatic: mouseMode = @"static"; break;
        case MacPlusPlusAudioRendererModeAudio: mouseMode = @"audio"; break;
        case MacPlusPlusAudioRendererModeAlert: mouseMode = @"alert"; break;
        default: break;
    }
    NSString *mouseRGB = [NSString stringWithFormat:@"#%02X%02X%02X",
        rendererTelemetry.mouseRGB[0], rendererTelemetry.mouseRGB[1],
        rendererTelemetry.mouseRGB[2]];

    bool signalActive = safeResponse > 0.004f || safeLevel > 0.018f;
    bool activityHeld = _lastAudioSignalTime > 0.0 &&
        publishTime - _lastAudioSignalTime < kAudioActivityReleaseSeconds;
    NSMutableDictionary *state = [@{
        @"active": @(signalActive || activityHeld),
        @"response": @(safeResponse),
        @"level": @(macpp_audio_finite_clamp(fmaxf(safeLevel * 0.25f, visualPeak), 0.0f, 1.0f)),
        @"bass": @(macpp_audio_finite_clamp(fmaxf(fmaxf(visualMeters[0], visualMeters[1]), safeBass * 0.20f), 0.0f, 1.0f)),
        @"mouse": @(macpp_audio_finite_clamp(rendererTelemetry.mouseEnergy, 0.0f, 1.0f)),
        @"mouse_energy": @(macpp_audio_finite_clamp(rendererTelemetry.mouseEnergy, 0.0f, 1.0f)),
        @"mouse_rgb": mouseRGB,
        @"mouse_mode": mouseMode,
        @"mouse_flash_count": @(rendererTelemetry.mouseFlashCount),
        @"mouse_peak_count": @(rendererTelemetry.mouseFlashCount),
        @"mouse_write_count": @(rendererTelemetry.mouseWriteCount),
        @"mouse_write_failures": @(rendererTelemetry.mouseWriteFailures),
        @"beat": @(safeBeatPulse),
        @"hit": @(_beatHit),
        @"bpm": @((int)lrintf(safeBPM)),
        @"raw_bpm": @((int)lrintf(safeBPM)),
        @"display_bpm": @((int)lrintf(displayBPM)),
        @"tempo_state": tempoState,
        @"tempo_session": _mediaSessionKey ?: @"",
        @"tempo_confidence": @(safeConfidence),
        @"beat_history": @(_beatIntervalCount),
        @"bpm_recoveries": @(_beatRecoveryCount),
        // Liveness is now purely about evidence -- a real reading, enough
        // agreement across the history, a recent beat, and actual signal --
        // with no assumption about which tempos are plausible. A 0.30
        // confidence floor keeps a good rolling estimate live through a
        // normal gap between beats; beatAge still expires the live flag.
        @"tempo_live": @(safeBPM > 0.0f &&
                         safeConfidence >= 0.30f &&
                         beatAge < 2.2 && safeResponse > 0.006f),
        @"beat_age": @(macpp_audio_finite_clamp((float)beatAge, 0.0f, 999.0f)),
        @"onset": @(safeBeatStrength),
        @"signal": @(macpp_audio_finite_clamp(safeBeatFloor + safeBeatStrength, 0.0f, 2.0f)),
        @"floor": @(safeBeatFloor),
        @"bars": bars,
        @"spectrum": spectrum,
        @"spectrum_smooth": smoothSpectrum,
        @"spectrum_hardware": hardwareSpectrum,
        @"hardware_sequence": @(_lastHardwareSequence),
        @"hardware_age_ms": @(macpp_audio_finite_clamp(
            (float)hardwareAgeMilliseconds, 0.0f, 999000.0f)),
        @"timestamp": @([[NSDate date] timeIntervalSince1970])
    } mutableCopy];
    // Preserve the former Game schema while Work retains its device failure
    // diagnostic. Both products otherwise publish the same shared snapshot.
    if (_renderer != nil) {
        state[@"mouse_last_failure_age_s"] =
            @(rendererTelemetry.mouseLastFailureAge);
    }
    NSError *serializationError = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:state
                                                     options:0
                                                       error:&serializationError];
    if (json == nil) {
        if (publishTime - _lastPublishWarning >= 30.0) {
            NSLog(@"Audio state serialization failed: %@",
                  serializationError.localizedDescription ?: @"unknown error");
            _lastPublishWarning = publishTime;
        }
        return;
    }
    if (_audioShared.state != NULL) {
        (void)macpp_audio_shared_publish(&_audioShared,
                                        json.bytes,
                                        json.length);
    }
}

- (void)beginAnalysisTimer {
    _analysisTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                             _analysisQueue);
    dispatch_source_set_timer(_analysisTimer, DISPATCH_TIME_NOW,
                              28 * NSEC_PER_MSEC, 4 * NSEC_PER_MSEC);
    __weak MacPlusPlusAudioEngine *weakSelf = self;
    dispatch_source_set_event_handler(_analysisTimer, ^{
        @autoreleasepool {
        MacPlusPlusAudioEngine *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        float rms = atomic_exchange_explicit(&strongSelf->_latestRMS, 0.0f,
                                             memory_order_relaxed);
        float peak = atomic_exchange_explicit(&strongSelf->_latestPeak, 0.0f,
                                              memory_order_relaxed);
        float response = fminf(1.0f, powf(fminf(1.0f, rms * 85.0f), 0.43f));
        response = fmaxf(response, fminf(1.0f, peak * 14.0f) * 0.58f);
        response = macpp_audio_finite_clamp(response, 0.0f, 1.0f);
        /*
         * Silence is expected when playback pauses or a track has a break.
         * Rebuilding the tap here can leave an otherwise healthy capture tap
         * silent on resume. Output device changes still refresh the tap.
         */
        if (!strongSelf->_loggedAudio && response > 0.10f) {
            NSLog(@"Audio detected; reactive lighting is active.");
            strongSelf->_loggedAudio = true;
        }
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (response > 0.004f) {
            strongSelf->_lastAudioSignalTime = now;
        }
        [strongSelf refreshPlaybackSession];
        float blend = response > strongSelf->_level ? 0.64f : 0.13f;
        strongSelf->_level += (response - strongSelf->_level) * blend;

        float bassEnergy = 0.0f;
        float meterRaw[6] = {0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f};
        for (int column = 0; column < kKeyboardColumns; column++) {
            float raw = macpp_audio_finite_clamp(
                atomic_load_explicit(&strongSelf->_latestBands[column],
                                     memory_order_relaxed),
                0.0f, 32.0f);
            int meterGroup = column < 2 ? 0 :
                (column < 4 ? 1 :
                (column < 6 ? 2 :
                (column < 9 ? 3 :
                (column < 12 ? 4 : 5))));
            meterRaw[meterGroup] = fmaxf(meterRaw[meterGroup], raw);
            if (column < 6) {
                static const float bassWeights[6] = {
                    1.00f, 1.18f, 1.26f, 1.10f, 0.80f, 0.54f
                };
                bassEnergy += raw * bassWeights[column];
            }
            /*
             * The tap gives real frequency magnitudes, but their absolute scale
             * varies wildly by output device and track mastering. A fixed
             * gain/clamp turns dense music into fifteen permanent 1.0 bands.
             * Track a slow per-band floor and ceiling instead, like a compact
             * spectrum analyzer AGC, then apply a mild gamma so bars keep room
             * for real peaks.
             */
            float floorSpeed = raw > strongSelf->_bandFloor[column] ? 0.002f : 0.035f;
            strongSelf->_bandFloor[column] +=
                (raw - strongSelf->_bandFloor[column]) * floorSpeed;
            strongSelf->_bandFloor[column] =
                fminf(strongSelf->_bandFloor[column], raw * 0.84f);

            float ceilingTarget = fmaxf(raw, strongSelf->_bandFloor[column] + 0.18f);
            float ceilingSpeed = raw > strongSelf->_bandCeiling[column] ? 0.12f : 0.003f;
            strongSelf->_bandCeiling[column] +=
                (ceilingTarget - strongSelf->_bandCeiling[column]) * ceilingSpeed;
            strongSelf->_bandCeiling[column] =
                fmaxf(strongSelf->_bandCeiling[column],
                      strongSelf->_bandFloor[column] + 0.24f);

            float normalized =
                (raw - strongSelf->_bandFloor[column]) /
                ((strongSelf->_bandCeiling[column] - strongSelf->_bandFloor[column]) *
                 1.55f);
            normalized = fmaxf(0.0f, fminf(1.0f, normalized));
            float band = powf(normalized, 1.70f);
            band = fmaxf(band, response * 0.015f);
            float speed = band > strongSelf->_bands[column] ? 0.42f : 0.20f;
            strongSelf->_bands[column] +=
                (band - strongSelf->_bands[column]) * speed;
        }

        float hardwareDB[kKeyboardColumns];
        if (atomic_exchange_explicit(
                &strongSelf->_hardwareResetRequested, false,
                memory_order_acq_rel)) {
            memset(&strongSelf->_hardwareSpectrum, 0,
                   sizeof(strongSelf->_hardwareSpectrum));
            strongSelf->_lastHardwareSequence = 0;
            strongSelf->_lastHardwareFFTTime = 0.0;
        }
        bool hardwareSnapshotReady = false;
        uint64_t hardwareSequence = 0;
        for (int attempt = 0; attempt < 3 && !hardwareSnapshotReady; attempt++) {
            uint64_t before = atomic_load_explicit(
                &strongSelf->_hardwareSequence, memory_order_acquire);
            if ((before & 1u) != 0) continue;
            for (int band = 0; band < kKeyboardColumns; band++) {
                hardwareDB[band] = atomic_load_explicit(
                    &strongSelf->_latestHardwareDB[band], memory_order_relaxed);
            }
            uint64_t after = atomic_load_explicit(
                &strongSelf->_hardwareSequence, memory_order_acquire);
            if (before == after && (after & 1u) == 0) {
                hardwareSequence = after;
                hardwareSnapshotReady = true;
            }
        }
        if (hardwareSnapshotReady && hardwareSequence !=
                strongSelf->_lastHardwareSequence) {
            strongSelf->_lastHardwareSequence = hardwareSequence;
            strongSelf->_lastHardwareFFTTime = now;
        }
        // The JSON writer can remain healthy even if CoreAudio silently stops
        // invoking its callback. Never republish the last spectrum forever.
        bool hardwareFresh = hardwareSnapshotReady && hardwareSequence > 0 &&
            now - strongSelf->_lastHardwareFFTTime <= 0.35;
        // A fresh shared-memory heartbeat does not prove that CoreAudio is
        // still delivering useful audio: zero-filled callbacks can continue
        // advancing the hardware FFT sequence after a route-specific stream
        // disappears. Recover only during a known playing session. A recently
        // active session is deliberately not enough: after media stops,
        // CoreAudio may remain quiet for many seconds and destroying/recreating
        // the tap then makes every shared visual consumer jump together.
        double recoverySuppressedUntil = atomic_load_explicit(
            &strongSelf->_tapRecoverySuppressedUntil, memory_order_acquire);
        bool tapNeverPublished = strongSelf->_lastHardwareSequence == 0 &&
            strongSelf->_audioTapStartTime > 0.0 &&
            now - strongSelf->_audioTapStartTime > 2.0;
        bool signalStalledDuringPlayback = strongSelf->_mediaWasPlaying &&
            strongSelf->_lastAudioSignalTime > 0.0 &&
            now - strongSelf->_lastAudioSignalTime >
                kAudioSignalRecoverySeconds;
        bool hardwareTapStalled =
            (strongSelf->_lastHardwareFFTTime > 0.0 &&
             now - strongSelf->_lastHardwareFFTTime > 1.5) ||
            tapNeverPublished || signalStalledDuringPlayback;
        if (strongSelf->_mediaWasPlaying &&
            now >= recoverySuppressedUntil &&
            hardwareTapStalled &&
            now - strongSelf->_lastTapRecoveryTime > kTapRecoveryCooldownSeconds) {
            strongSelf->_lastTapRecoveryTime = now;
            [strongSelf scheduleTapRefreshForReason:
                @"CoreAudio tap stalled during playback"];
        }
        if (!hardwareFresh) {
            for (int band = 0; band < kKeyboardColumns; band++) {
                hardwareDB[band] = MACPP_AUDIO_HARDWARE_MINIMUM_DB;
            }
        }
        macpp_audio_update_hardware_spectrum_envelope(&strongSelf->_hardwareSpectrum,
                                       hardwareDB);
        float visualLevel = 0.0f;
        for (int group = 0; group < 6; group++) {
            float meter = 0.0f;
            switch (group) {
                case 0:
                    meter = fmaxf(strongSelf->_bands[0], strongSelf->_bands[1]);
                    break;
                case 1:
                    meter = fmaxf(strongSelf->_bands[2], strongSelf->_bands[3]);
                    break;
                case 2:
                    meter = fmaxf(strongSelf->_bands[4], strongSelf->_bands[5]);
                    break;
                case 3:
                    meter = fmaxf(fmaxf(strongSelf->_bands[6], strongSelf->_bands[7]),
                                  strongSelf->_bands[8]);
                    break;
                case 4:
                    meter = fmaxf(fmaxf(strongSelf->_bands[9], strongSelf->_bands[10]),
                                  strongSelf->_bands[11]);
                    break;
                default:
                    meter = fmaxf(fmaxf(strongSelf->_bands[12], strongSelf->_bands[13]),
                                  strongSelf->_bands[14]);
                    break;
            }
            float meterSpeed =
                meter > strongSelf->_meterBands[group] ? 0.62f : 0.18f;
            strongSelf->_meterBands[group] +=
                (meter - strongSelf->_meterBands[group]) * meterSpeed;
            visualLevel = fmaxf(visualLevel, strongSelf->_meterBands[group]);
        }
        float visualBass =
            fmaxf(strongSelf->_meterBands[0], strongSelf->_meterBands[1]);

        /*
         * Detect kick-like onsets from low bands before visual smoothing.
         * The adaptive floor follows sustained bass but not brief attacks, so
         * repeated kicks become discrete events instead of a constant glow.
         */
        float beatSignal = log1pf(bassEnergy * 360.0f);
        if (strongSelf->_beatFloor <= 0.0f) {
            strongSelf->_beatFloor = beatSignal;
        }
        float transient =
            fmaxf(0.0f, beatSignal - strongSelf->_beatFloor);
        float floorSpeed =
            beatSignal > strongSelf->_beatFloor ? 0.020f : 0.15f;
        strongSelf->_beatFloor +=
            (beatSignal - strongSelf->_beatFloor) * floorSpeed;
        strongSelf->_beatStrength = strongSelf->_beatStrength * 0.70f + transient * 0.30f;

        // The FFT magnitude is log-scaled, so a loud master can put the
        // adaptive floor well above 1. A fixed 3% gate then rejects real
        // attacks in dense tracks even though the spectrum is moving. Keep a
        // small absolute floor, but make the relative gate 1.2% of that
        // calibrated signal instead.
        float minimumTransient =
            fmaxf(0.0018f, strongSelf->_beatFloor * 0.012f);
        float transientRise = transient - strongSelf->_lastTransient;
        // A timer tick can land just after a short kick. Keep one sample of
        // look-behind so a clear local peak still becomes an onset instead of
        // being discarded by the rise-only gate.
        bool localPeak = strongSelf->_lastTransient > minimumTransient &&
            strongSelf->_lastTransient >= strongSelf->_previousTransient &&
            strongSelf->_lastTransient >= transient &&
            (strongSelf->_lastTransient - strongSelf->_previousTransient >
                 fmaxf(0.00035f, minimumTransient * 0.012f) ||
             strongSelf->_lastTransient > minimumTransient * 1.35f);
        double sinceHit = strongSelf->_lastBeatTime > 0.0
            ? now - strongSelf->_lastBeatTime
            : 9.0;
        // Refractory period. This used to be a flat 0.26s, which silently
        // imposed a 230 BPM ceiling on the whole detector -- anything faster
        // simply could not register a second onset. It now scales with the
        // tempo already being tracked, so it only rejects a re-trigger of the
        // same transient rather than capping how fast the music may be. The
        // absolute floor exists solely to stop one attack firing twice inside
        // consecutive frames.
        double refractory = strongSelf->_bpm > 0.0f
            ? fmax(0.12, (60.0 / strongSelf->_bpm) * 0.46)
            : 0.20;
        // The lighting timer samples the audio callback about 35 times per
        // second. A narrow rise-only gate can miss a real kick when the
        // callback lands just after the peak, leaving the detector forever
        // without the four intervals it needs to establish a tempo. Keep the
        // rise test, but allow a clear local transient peak to count as well.
        float riseGate = fmaxf(0.00035f, minimumTransient * 0.012f);
        bool clearPeak = transient > fmaxf(minimumTransient * 1.65f,
                                            strongSelf->_beatStrength * 1.25f);
        bool beatHit = response > 0.004f &&
            visualBass > 0.045f &&
            (transient > minimumTransient || localPeak) &&
            (transientRise > riseGate || clearPeak || localPeak) &&
            sinceHit > refractory;
        strongSelf->_previousTransient = strongSelf->_lastTransient;
        strongSelf->_lastTransient = transient;
        strongSelf->_beatHit = beatHit;
        if (beatHit) {
            // 4.0s rather than 1.50s. The old window discarded any gap longer
            // than that, which floored the detector at 40 BPM and, worse,
            // threw away exactly the gaps that occur when an onset is missed
            // -- the very evidence the estimator now uses to work out that a
            // gap spanned several beats.
            if (strongSelf->_lastBeatTime > 0.0 && sinceHit < 4.0) {
                const int historySize =
                    (int)(sizeof(strongSelf->_beatIntervals) / sizeof(float));
                strongSelf->_beatIntervals[strongSelf->_beatIntervalIndex] =
                    (float)sinceHit;
                strongSelf->_beatIntervalIndex =
                    (strongSelf->_beatIntervalIndex + 1) % historySize;
                if (strongSelf->_beatIntervalCount < historySize) {
                    strongSelf->_beatIntervalCount++;
                }
                if (strongSelf->_beatIntervalCount >= 4) {
                    float previousPeriod = strongSelf->_bpm > 0.0f
                        ? 60.0f / strongSelf->_bpm
                        : 0.0f;
                    float confidence = 0.0f;
                    float period =
                        macpp_audio_estimate_beat_period(strongSelf->_beatIntervals,
                                           strongSelf->_beatIntervalCount,
                                           previousPeriod,
                                           &confidence);
                    float measuredBPM = period > 0.0f ? 60.0f / period : 0.0f;
                    // No range gate. A tempo outside some assumed window is
                    // still the tempo; the confidence score is what decides
                    // whether a reading is trustworthy, and it does that on
                    // evidence rather than on a guess about genre.
                    if (measuredBPM > 0.0f && isfinite(measuredBPM) &&
                        confidence >= 0.45f) {
                        // Converge quickly when the estimate is confident and
                        // far from the current value -- a track change is a
                        // step, not a drift -- then settle to fine trim as it
                        // closes in. The old flat 6% took roughly forty beats
                        // to cross a tempo change, so the reading spent most
                        // of a song being wrong on the way to being right.
                        float ratio = strongSelf->_bpm > 0.0f
                            ? fabsf(measuredBPM - strongSelf->_bpm) / strongSelf->_bpm
                            : 1.0f;
                        float tempoBlend = strongSelf->_bpm <= 0.0f
                            ? 1.0f
                            : fminf(0.85f, (0.05f + 0.80f * fminf(1.0f, ratio * 4.0f)) * confidence);
                        strongSelf->_bpm +=
                            (measuredBPM - strongSelf->_bpm) * tempoBlend;
                        strongSelf->_bpmConfidence +=
                            (confidence - strongSelf->_bpmConfidence) * 0.22f;
                    } else {
                        // Confidence is evidence about the rolling interval
                        // history, not an audio envelope. Decaying it by 6%
                        // every 28ms made a healthy tempo lose its lock
                        // between ordinary beats.
                        strongSelf->_bpmConfidence *= 0.997f;
                    }
                }
            }
            strongSelf->_lastBeatTime = now;
            float tempoScale = fmaxf(0.0f, fminf(1.0f,
                (strongSelf->_bpm - 70.0f) / 260.0f));
            strongSelf->_beatPulse =
                fminf(1.0f, 0.30f + (transient * 2.35f) +
                              (tempoScale * 0.30f));
        } else {
            strongSelf->_beatPulse *= 0.78f;
            if (strongSelf->_lastBeatTime > 0.0) {
                float expectedBeatInterval = strongSelf->_bpm >= 40.0f
                    ? 60.0f / strongSelf->_bpm
                    : 0.55f;
                double tempoTimeout = fmax(1.80, fmin(4.50,
                    expectedBeatInterval * 4.50));
                if (now - strongSelf->_lastBeatTime > tempoTimeout) {
                    strongSelf->_bpm *= 0.985f;
                    strongSelf->_bpmConfidence *= 0.997f;
                    if (strongSelf->_bpm < 1.0f) {
                        strongSelf->_bpm = 0.0f;
                    }
                    if (strongSelf->_bpmConfidence < 0.01f) {
                        strongSelf->_bpmConfidence = 0.0f;
                    }
                    if (strongSelf->_beatIntervalCount > 0) {
                        strongSelf->_beatIntervalCount--;
                    }
                }
            }
        }

        // A healthy tap can keep delivering loud, changing audio while the
        // onset state gets trapped above the next kick. Without a re-arm the
        // interval history never fills and BPM remains dead for the rest of
        // the process lifetime. Re-baseline only during sustained signal, and
        // rate-limit the recovery so a quiet/beatless passage stays harmless.
        bool detectorAudioActive = response > 0.05f && visualBass > 0.08f;
        bool hadBeat = strongSelf->_lastBeatTime > 0.0;
        double detectorSilence = hadBeat
            ? now - strongSelf->_lastBeatTime
            : (strongSelf->_lastBeatDetectorRecovery > 0.0
                ? now - strongSelf->_lastBeatDetectorRecovery : 0.0);
        bool detectorStalled = hadBeat
            ? detectorSilence > 8.0
            : (strongSelf->_lastBeatDetectorRecovery <= 0.0 ||
               detectorSilence > 8.0);
        if (detectorAudioActive && detectorStalled &&
            (strongSelf->_lastBeatDetectorRecovery <= 0.0 ||
             now - strongSelf->_lastBeatDetectorRecovery > 4.0)) {
            strongSelf->_beatFloor = beatSignal * 0.72f;
            strongSelf->_beatStrength = 0.0f;
            strongSelf->_lastTransient = 0.0f;
            strongSelf->_previousTransient = 0.0f;
            strongSelf->_lastBeatTime = 0.0;
            strongSelf->_bpm = 0.0f;
            strongSelf->_bpmConfidence = 0.0f;
            strongSelf->_beatIntervalCount = 0;
            strongSelf->_beatIntervalIndex = 0;
            strongSelf->_lastBeatDetectorRecovery = now;
            strongSelf->_beatRecoveryCount++;
            if (hadBeat) {
                NSLog(@"BPM detector re-armed after %.1fs without a beat.",
                      detectorSilence);
            } else {
                NSLog(@"BPM detector primed for active audio.");
            }
        }

        MacPlusPlusAudioRenderFrame renderFrame = {0};
        renderFrame.now = now;
        renderFrame.response = response;
        renderFrame.visualLevel = visualLevel;
        renderFrame.visualBass = visualBass;
        renderFrame.beatPulse = strongSelf->_beatPulse;
        renderFrame.hardwareFresh = hardwareFresh;
        renderFrame.hardwareSignalActive =
            strongSelf->_hardwareSpectrum.signalActive;
        for (int column = 0; column < kKeyboardColumns; column++) {
            renderFrame.compactBands[column] = strongSelf->_bands[column];
            renderFrame.hardwareBands[column] =
                strongSelf->_hardwareSpectrum.bands[column];
        }
        BOOL rendererConsumedFrame =
            [strongSelf->_renderer renderFrame:&renderFrame];

        if (!rendererConsumedFrame && response <= 0.004f) {
            strongSelf->_beatPulse *= 0.50f;
        }

        [strongSelf publishAudioResponse:response
                                   level:visualLevel
                                    bass:visualBass];
        }
    });
    dispatch_resume(_analysisTimer);
}

- (void)removeLegacyAudioState {
    NSError *cleanupError = nil;
    if (![[NSFileManager defaultManager]
            removeItemAtPath:kLegacyAudioStateCleanupPath
                       error:&cleanupError] &&
        cleanupError.code != NSFileNoSuchFileError) {
        NSLog(@"Could not remove obsolete audio state %@: %@",
              kLegacyAudioStateCleanupPath,
              cleanupError.localizedDescription ?: @"unknown error");
    }
}

- (BOOL)start {
    _stopping = false;
    [self removeLegacyAudioState];
    if (_renderer != nil && ![_renderer start]) {
        NSLog(@"%@ renderer started without a connected lighting device.",
              _configuration.productName);
    }
    if (@available(macOS 14.2, *)) {
        BOOL tapReady = NO;
        for (int attempt = 0; attempt < 3 && !tapReady; attempt++) {
            tapReady = [self createAudioTap];
            if (!tapReady && attempt < 2) usleep(200000);
        }
        if (!tapReady) {
            [self stop];
            return NO;
        }
    } else {
        NSLog(@"%@ requires macOS 14.2 or later.", _configuration.productName);
        [self stop];
        return NO;
    }
    BOOL sharedReady = NO;
    for (int attempt = 0; attempt < 4 && !sharedReady; attempt++) {
        sharedReady = macpp_audio_shared_open_writer(&_audioShared);
        if (!sharedReady && attempt < 3) usleep(100000);
    }
    if (!sharedReady) {
        NSLog(@"Could not open MacPlusPlus audio shared-memory transport after retries "
              @"(errno=%d: %s).", errno, strerror(errno));
        [self stop];
        return NO;
    }
    _running = true;
    [self beginAnalysisTimer];
    [self beginAudioRouteMonitoring];
    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserver:self
           selector:@selector(handleSystemWillSleep:)
               name:NSWorkspaceWillSleepNotification
             object:nil];
    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserver:self
           selector:@selector(handleSystemWillSleep:)
               name:NSWorkspaceScreensDidSleepNotification
             object:nil];
    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserver:self
           selector:@selector(handleSystemDidWake:)
               name:NSWorkspaceDidWakeNotification
             object:nil];
    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserver:self
           selector:@selector(handleSystemDidWake:)
               name:NSWorkspaceScreensDidWakeNotification
             object:nil];
    NSLog(@"%@ system audio tap started; shared spectrum is waiting for playback.",
          _configuration.productName);
    return YES;
}

- (void)stop {
    _stopping = true;
    _running = false;
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
    if (_analysisTimer != nil) {
        dispatch_source_cancel(_analysisTimer);
        _analysisTimer = nil;
    }
    [_renderer prepareToStop];
    if (_audioRouteWatchReady && _outputDeviceListener != nil) {
        AudioObjectPropertyAddress outputAddress = {
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        AudioObjectPropertyAddress systemAddress = {
            kAudioHardwarePropertyDefaultSystemOutputDevice,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject,
                                               &outputAddress,
                                               dispatch_get_main_queue(),
                                               _outputDeviceListener);
        AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject,
                                               &systemAddress,
                                               dispatch_get_main_queue(),
                                               _outputDeviceListener);
        _audioRouteWatchReady = false;
        _outputDeviceListener = nil;
    }
    [self destroyAudioTap];
    // Cancellation does not wait for an analysis handler already running.
    // Drain its serial queue before unmapping the single-writer transport.
    dispatch_sync(_analysisQueue, ^{
        [self->_renderer stopOnRenderQueue];
    });
    macpp_audio_shared_close_writer(&_audioShared);
    [self removeLegacyAudioState];
}

- (void)dealloc {
    [self stop];
    if (_fftSetup != NULL) {
        vDSP_destroy_fftsetup(_fftSetup);
        _fftSetup = NULL;
    }
    if (_hardwareFFTSetup != NULL) {
        vDSP_destroy_fftsetup(_hardwareFFTSetup);
        _hardwareFFTSetup = NULL;
    }
}

@end

int MacPlusPlusAudioEngineMain(int argc, const char * _Nonnull const * _Nonnull argv,
                        MacPlusPlusAudioEngineConfiguration configuration,
                        dispatch_queue_t analysisQueue,
                        id<MacPlusPlusAudioRenderer> renderer) {
    @autoreleasepool {
        if (argc == 2 &&
            strcmp(argv[1], "--hardware-spectrum-self-test") == 0) {
            return macpp_audio_run_hardware_spectrum_self_test();
        }
        if (argc == 2 &&
            strcmp(argv[1], "--tempo-self-test") == 0) {
            return macpp_audio_run_tempo_self_test();
        }
        // The two product wrappers are long-lived single-writer processes.
        // Treat unknown arguments as a usage error instead of silently
        // starting another producer: a stray `--status` probe could otherwise
        // unlink the active Work/Game shared-memory name and leave the first
        // owner holding an orphaned descriptor.
        if (argc != 1) {
            fprintf(stderr,
                    "Usage: %s [--hardware-spectrum-self-test|--tempo-self-test]\n",
                    argv[0]);
            return 2;
        }
        MacPlusPlusAudioEngine *controller = [[MacPlusPlusAudioEngine alloc]
            initWithConfiguration:configuration
                    analysisQueue:analysisQueue
                         renderer:renderer];
        if (![controller start]) {
            return 1;
        }

        signal(SIGTERM, SIG_IGN);
        signal(SIGINT, SIG_IGN);
        dispatch_queue_t signals = dispatch_get_main_queue();
        dispatch_source_t termSource =
            dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0,
                                   signals);
        dispatch_source_t intSource =
            dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGINT, 0,
                                   signals);
        dispatch_block_t terminate = ^{
            [controller stop];
            CFRunLoopStop(CFRunLoopGetMain());
        };
        dispatch_source_set_event_handler(termSource, terminate);
        dispatch_source_set_event_handler(intSource, terminate);
        dispatch_resume(termSource);
        dispatch_resume(intSource);
        CFRunLoopRun();
    }
    return 0;
}
