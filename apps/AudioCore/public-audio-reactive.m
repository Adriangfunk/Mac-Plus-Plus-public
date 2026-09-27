#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>

#include "macpp_audio_engine.h"

int main(int argc, const char *argv[]) {
    dispatch_queue_t analysisQueue = dispatch_queue_create(
        "com.macplusplus.audio-puller.analysis", DISPATCH_QUEUE_SERIAL);
    MacPlusPlusAudioEngineConfiguration configuration = {
        .productName = @"Mac++ Audio Puller",
        .aggregateUID = @"com.macplusplus.audio-puller.aggregate",
        .audioQueueLabel = "com.macplusplus.audio-puller.audio",
    };
    // Public audio is intentionally device-neutral. It publishes the shared
    // spectrum/tempo transport and never claims a vendor HID device.
    return MacPlusPlusAudioEngineMain(argc, argv, configuration, analysisQueue, nil);
}
