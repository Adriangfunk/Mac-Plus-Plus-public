#ifndef MACPP_AUDIO_ENGINE_H
#define MACPP_AUDIO_ENGINE_H

#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <stdbool.h>
#import <stdint.h>

#include "macpp_audio_dsp.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(uint8_t, MacPlusPlusAudioRendererMode) {
    MacPlusPlusAudioRendererModeExternal = 0,
    MacPlusPlusAudioRendererModeStatic,
    MacPlusPlusAudioRendererModeAudio,
    MacPlusPlusAudioRendererModeAlert,
};

typedef struct {
    CFAbsoluteTime now;
    float response;
    float visualLevel;
    float visualBass;
    float beatPulse;
    bool hardwareFresh;
    bool hardwareSignalActive;
    float compactBands[MACPP_AUDIO_HARDWARE_BAND_COUNT];
    float hardwareBands[MACPP_AUDIO_HARDWARE_BAND_COUNT];
} MacPlusPlusAudioRenderFrame;

typedef struct {
    float mouseEnergy;
    unsigned char mouseRGB[3];
    MacPlusPlusAudioRendererMode mouseMode;
    uint32_t mouseFlashCount;
    uint32_t mouseWriteCount;
    uint32_t mouseWriteFailures;
    double mouseLastFailureAge;
} MacPlusPlusAudioRendererTelemetry;

@protocol MacPlusPlusAudioRenderer <NSObject>
- (BOOL)start;
- (void)prepareForSystemSleep;
- (void)resumeAfterSystemWake;
// Called from the audio analysis path before publishing. Implementations must
// return quickly; slow HID/device work belongs on the renderer's own queue so
// it cannot back-pressure the shared audio snapshot.
- (BOOL)renderFrame:(const MacPlusPlusAudioRenderFrame *)frame;
- (void)copyTelemetry:(MacPlusPlusAudioRendererTelemetry *)telemetry;
- (void)prepareToStop;
- (void)stopOnRenderQueue;
@end

typedef struct {
    __unsafe_unretained NSString *productName;
    __unsafe_unretained NSString *aggregateUID;
    const char *audioQueueLabel;
} MacPlusPlusAudioEngineConfiguration;

FOUNDATION_EXPORT int MacPlusPlusAudioEngineMain(
    int argc,
    const char * _Nonnull const * _Nonnull argv,
    MacPlusPlusAudioEngineConfiguration configuration,
    dispatch_queue_t analysisQueue,
    id<MacPlusPlusAudioRenderer> _Nullable renderer);

NS_ASSUME_NONNULL_END

#endif
