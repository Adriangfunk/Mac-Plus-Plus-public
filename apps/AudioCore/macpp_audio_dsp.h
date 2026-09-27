#ifndef MACPP_AUDIO_DSP_H
#define MACPP_AUDIO_DSP_H

#include <Accelerate/Accelerate.h>
#include <stdbool.h>
#include <stddef.h>

#define MACPP_AUDIO_HARDWARE_BAND_COUNT 15
#define MACPP_AUDIO_HARDWARE_FFT_SIZE 4096
#define MACPP_AUDIO_HARDWARE_FFT_HALF (MACPP_AUDIO_HARDWARE_FFT_SIZE / 2)
#define MACPP_AUDIO_HARDWARE_FFT_LOG2 12
#define MACPP_AUDIO_HARDWARE_FFT_HOP 2048
#define MACPP_AUDIO_HARDWARE_MAX_CHANNELS 8
#define MACPP_AUDIO_HARDWARE_MINIMUM_DB (-96.0f)

typedef struct {
    bool signalActive;
    bool referenceReady;
    unsigned int silenceTicks;
    unsigned int referenceHoldTicks;
    float referenceDB;
    float bands[MACPP_AUDIO_HARDWARE_BAND_COUNT];
} MacPlusPlusAudioHardwareSpectrumEnvelope;

float macpp_audio_finite_clamp(float value, float low, float high);
float macpp_audio_estimate_beat_period(const float *samples, int count,
                                       float previousPeriod,
                                       float *confidenceOut);
float macpp_audio_normalized_display_bpm(float bpm);
int macpp_audio_hardware_band_for_frequency(float hz);
void macpp_audio_update_hardware_spectrum_envelope(
    MacPlusPlusAudioHardwareSpectrumEnvelope *state,
    const float inputDB[MACPP_AUDIO_HARDWARE_BAND_COUNT]);
void macpp_audio_calculate_hardware_band_db(
    const float ring[MACPP_AUDIO_HARDWARE_MAX_CHANNELS]
                    [MACPP_AUDIO_HARDWARE_FFT_SIZE],
    size_t ringIndex,
    size_t available,
    size_t channelCount,
    float sampleRate,
    FFTSetup setup,
    const float window[MACPP_AUDIO_HARDWARE_FFT_SIZE],
    float samples[MACPP_AUDIO_HARDWARE_FFT_SIZE],
    float real[MACPP_AUDIO_HARDWARE_FFT_HALF],
    float imag[MACPP_AUDIO_HARDWARE_FFT_HALF],
    float magnitudes[MACPP_AUDIO_HARDWARE_FFT_HALF],
    float outDB[MACPP_AUDIO_HARDWARE_BAND_COUNT]);
int macpp_audio_run_hardware_spectrum_self_test(void);
int macpp_audio_run_tempo_self_test(void);

#endif
