#include "macpp_audio_dsp.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const float kHardwareLowHz = 30.0f;
static const float kHardwareHighHz = 20000.0f;
static const float kHardwareSilenceEnterDB = -84.0f;
static const float kHardwareSilenceExitDB = -78.0f;
static const float kHardwareDynamicRangeDB = 30.0f;
static const float kHardwareBrightnessGamma = 2.00f;

float macpp_audio_finite_clamp(float value, float low, float high) {
    if (!isfinite(value)) {
        return low;
    }
    if (value < low) {
        return low;
    }
    if (value > high) {
        return high;
    }
    return value;
}

/*
 * Treat each observed onset interval as an integer multiple of a candidate
 * beat period. Weighting a match by 1/multiple rejects the common half-time
 * solution, while candidate division handles missed beats. The winner is
 * refined from every interval aligned to its grid.
 */
float macpp_audio_estimate_beat_period(const float *samples, int count,
                                      float previousPeriod,
                                      float *confidenceOut) {
    if (confidenceOut) {
        *confidenceOut = 0.0f;
    }
    if (count < 4) {
        return 0.0f;
    }

    const float tolerance = 0.12f;
    const int maxMultiple = 8;
    float bestCandidate = 0.0f;
    float bestScore = -1.0f;
    static const float divisors[] = {1.0f, 2.0f, 3.0f, 4.0f};
    const int divisorCount = (int)(sizeof(divisors) / sizeof(divisors[0]));

    for (int source = 0; source <= count; source++) {
        for (int divisor = 0; divisor < divisorCount; divisor++) {
            float candidate;
            if (source == count) {
                if (previousPeriod <= 0.0f || divisor > 0) {
                    continue;
                }
                candidate = previousPeriod;
            } else {
                candidate = samples[source] / divisors[divisor];
            }
            if (!isfinite(candidate) || candidate <= 0.02f) {
                continue;
            }

            float score = 0.0f;
            for (int index = 0; index < count; index++) {
                float ratio = samples[index] / candidate;
                int multiple = (int)lrintf(ratio);
                if (multiple < 1 || multiple > maxMultiple) {
                    continue;
                }
                float error = fabsf(samples[index] -
                                     (float)multiple * candidate) /
                              candidate;
                if (error <= tolerance) {
                    score += 1.0f / (float)multiple;
                }
            }
            score /= (float)count;
            if (score > bestScore) {
                bestScore = score;
                bestCandidate = candidate;
            }
        }
    }

    if (bestCandidate <= 0.0f || bestScore <= 0.0f) {
        return 0.0f;
    }

    float sum = 0.0f;
    int aligned = 0;
    for (int index = 0; index < count; index++) {
        float ratio = samples[index] / bestCandidate;
        int multiple = (int)lrintf(ratio);
        if (multiple < 1 || multiple > maxMultiple) {
            continue;
        }
        float error = fabsf(samples[index] -
                             (float)multiple * bestCandidate) /
                      bestCandidate;
        if (error <= tolerance) {
            sum += samples[index] / (float)multiple;
            aligned++;
        }
    }
    if (aligned < 3) {
        return 0.0f;
    }
    float refined = sum / (float)aligned;

    if (confidenceOut) {
        float spread = 0.0f;
        for (int index = 0; index < count; index++) {
            float ratio = samples[index] / refined;
            int multiple = (int)lrintf(ratio);
            if (multiple < 1 || multiple > maxMultiple) {
                continue;
            }
            float error = fabsf(samples[index] -
                                 (float)multiple * refined) /
                          refined;
            if (error <= tolerance) {
                spread += error;
            }
        }
        spread /= (float)aligned;
        float tightness = fmaxf(0.0f, 1.0f - (spread / tolerance));
        *confidenceOut = fminf(
            1.0f, bestScore * (0.55f + 0.45f * tightness));
    }
    return refined;
}

float macpp_audio_normalized_display_bpm(float bpm) {
    if (!isfinite(bpm) || bpm < 1.0f) {
        return 0.0f;
    }
    float display = bpm;
    int adjustments = 0;
    while (display > 320.0f && adjustments++ < 8) {
        display *= 0.5f;
    }
    while (display < 60.0f && adjustments++ < 8) {
        display *= 2.0f;
    }
    return isfinite(display) && display >= 1.0f ? display : 0.0f;
}

int macpp_audio_hardware_band_for_frequency(float hz) {
    if (!isfinite(hz) || hz <= kHardwareLowHz) {
        return 0;
    }
    if (hz >= kHardwareHighHz) {
        return MACPP_AUDIO_HARDWARE_BAND_COUNT - 1;
    }
    float position = logf(hz / kHardwareLowHz) /
                     logf(kHardwareHighHz / kHardwareLowHz) *
                     (float)(MACPP_AUDIO_HARDWARE_BAND_COUNT - 1);
    return (int)macpp_audio_finite_clamp(
        roundf(position), 0.0f,
        (float)(MACPP_AUDIO_HARDWARE_BAND_COUNT - 1));
}

/*
 * Maintain one reference for the entire spectrum. A per-band AGC would teach
 * a sustained tone to disappear and would lift a dense musical bed until the
 * whole keyboard flashed together.
 */
void macpp_audio_update_hardware_spectrum_envelope(
    MacPlusPlusAudioHardwareSpectrumEnvelope *state,
    const float inputDB[MACPP_AUDIO_HARDWARE_BAND_COUNT]) {
    float peakDB = MACPP_AUDIO_HARDWARE_MINIMUM_DB;
    for (int band = 0; band < MACPP_AUDIO_HARDWARE_BAND_COUNT; band++) {
        peakDB = fmaxf(
            peakDB,
            macpp_audio_finite_clamp(
                inputDB[band], MACPP_AUDIO_HARDWARE_MINIMUM_DB, 12.0f));
    }

    if (state->signalActive) {
        if (peakDB <= kHardwareSilenceEnterDB) {
            state->signalActive = false;
        }
    } else if (peakDB >= kHardwareSilenceExitDB) {
        state->signalActive = true;
    }

    bool signalPresent = state->signalActive;
    if (signalPresent) {
        state->silenceTicks = 0;
        float desiredReference =
            macpp_audio_finite_clamp(peakDB + 3.0f, -72.0f, 6.0f);
        if (!state->referenceReady) {
            state->referenceDB = desiredReference;
            state->referenceReady = true;
            state->referenceHoldTicks = 0;
        } else if (desiredReference > state->referenceDB) {
            const float referenceAttack = 0.295f;
            state->referenceDB +=
                (desiredReference - state->referenceDB) * referenceAttack;
            state->referenceHoldTicks = 0;
        } else if (state->referenceHoldTicks < 15) {
            state->referenceHoldTicks++;
        } else {
            state->referenceDB = fmaxf(
                desiredReference, state->referenceDB - 0.112f);
        }
    } else {
        state->silenceTicks++;
        state->referenceHoldTicks = 0;
        if (state->silenceTicks >= 27) {
            state->referenceReady = false;
        }
    }

    float floorDB = state->referenceDB - kHardwareDynamicRangeDB;
    for (int band = 0; band < MACPP_AUDIO_HARDWARE_BAND_COUNT; band++) {
        float target = 0.0f;
        if (signalPresent && state->referenceReady) {
            float db = macpp_audio_finite_clamp(
                inputDB[band], MACPP_AUDIO_HARDWARE_MINIMUM_DB, 12.0f);
            float normalized = macpp_audio_finite_clamp(
                (db - floorDB) / kHardwareDynamicRangeDB, 0.0f, 1.0f);
            target = powf(normalized, kHardwareBrightnessGamma);
        }
        state->bands[band] =
            macpp_audio_finite_clamp(target, 0.0f, 1.0f);
    }
}

/*
 * Analyse channels independently and average power. Summing stereo in the
 * time domain would erase perfectly anti-phase material. FFT bins are split
 * between adjacent logarithmic band centres with weights that sum to one.
 */
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
    float outDB[MACPP_AUDIO_HARDWARE_BAND_COUNT]) {
    for (int band = 0; band < MACPP_AUDIO_HARDWARE_BAND_COUNT; band++) {
        outDB[band] = MACPP_AUDIO_HARDWARE_MINIMUM_DB;
    }
    if (setup == NULL || sampleRate <= 0.0f || available == 0) {
        return;
    }

    if (available > MACPP_AUDIO_HARDWARE_FFT_SIZE) {
        available = MACPP_AUDIO_HARDWARE_FFT_SIZE;
    }
    if (channelCount < 1) {
        channelCount = 1;
    } else if (channelCount > MACPP_AUDIO_HARDWARE_MAX_CHANNELS) {
        channelCount = MACPP_AUDIO_HARDWARE_MAX_CHANNELS;
    }

    float accumulatedPower[MACPP_AUDIO_HARDWARE_BAND_COUNT] = {0.0f};
    float binHz = sampleRate / (float)MACPP_AUDIO_HARDWARE_FFT_SIZE;
    float nyquist = sampleRate * 0.5f;

    for (size_t channel = 0; channel < channelCount; channel++) {
        vDSP_vclr(samples, 1, MACPP_AUDIO_HARDWARE_FFT_SIZE);
        size_t padding = MACPP_AUDIO_HARDWARE_FFT_SIZE - available;
        for (size_t sampleIndex = 0; sampleIndex < available; sampleIndex++) {
            size_t source =
                (ringIndex + MACPP_AUDIO_HARDWARE_FFT_SIZE - available +
                 sampleIndex) %
                MACPP_AUDIO_HARDWARE_FFT_SIZE;
            size_t destination = padding + sampleIndex;
            samples[destination] = ring[channel][source] * window[destination];
        }

        for (int index = 0; index < MACPP_AUDIO_HARDWARE_FFT_HALF; index++) {
            real[index] = samples[index * 2];
            imag[index] = samples[index * 2 + 1];
        }
        DSPSplitComplex split = {.realp = real, .imagp = imag};
        vDSP_fft_zrip(setup, &split, 1, MACPP_AUDIO_HARDWARE_FFT_LOG2,
                      FFT_FORWARD);
        float scale = 1.0f / (float)MACPP_AUDIO_HARDWARE_FFT_SIZE;
        vDSP_vsmul(split.realp, 1, &scale, split.realp, 1,
                   MACPP_AUDIO_HARDWARE_FFT_HALF);
        vDSP_vsmul(split.imagp, 1, &scale, split.imagp, 1,
                   MACPP_AUDIO_HARDWARE_FFT_HALF);
        vDSP_zvmags(&split, 1, magnitudes, 1,
                    MACPP_AUDIO_HARDWARE_FFT_HALF);
        magnitudes[0] = 0.0f;

        float lowestCapturedHz = kHardwareLowHz * 0.67f;
        float highestCapturedHz = fminf(kHardwareHighHz, nyquist * 0.98f);
        float logSpan = logf(kHardwareHighHz / kHardwareLowHz);
        for (int bin = 1; bin < MACPP_AUDIO_HARDWARE_FFT_HALF; bin++) {
            float hz = (float)bin * binHz;
            if (hz < lowestCapturedHz || hz > highestCapturedHz) {
                continue;
            }
            float position = hz <= kHardwareLowHz
                                 ? 0.0f
                                 : logf(hz / kHardwareLowHz) / logSpan *
                                       (float)(MACPP_AUDIO_HARDWARE_BAND_COUNT -
                                               1);
            position = macpp_audio_finite_clamp(
                position, 0.0f,
                (float)(MACPP_AUDIO_HARDWARE_BAND_COUNT - 1));
            int lowerBand = (int)floorf(position);
            int upperBand = lowerBand + 1;
            if (upperBand >= MACPP_AUDIO_HARDWARE_BAND_COUNT) {
                upperBand = MACPP_AUDIO_HARDWARE_BAND_COUNT - 1;
            }
            float fraction = position - (float)lowerBand;
            float power = magnitudes[bin] * 4.0f;
            accumulatedPower[lowerBand] += power * (1.0f - fraction);
            if (upperBand != lowerBand) {
                accumulatedPower[upperBand] += power * fraction;
            }
        }
    }

    for (int band = 0; band < MACPP_AUDIO_HARDWARE_BAND_COUNT; band++) {
        float power = accumulatedPower[band] / (float)channelCount;
        outDB[band] = macpp_audio_finite_clamp(
            10.0f * log10f(fmaxf(power, 1.0e-12f)),
            MACPP_AUDIO_HARDWARE_MINIMUM_DB, 12.0f);
    }
}

int macpp_audio_run_hardware_spectrum_self_test(void) {
    FFTSetup setup =
        vDSP_create_fftsetup(MACPP_AUDIO_HARDWARE_FFT_LOG2, kFFTRadix2);
    float(*ring)[MACPP_AUDIO_HARDWARE_FFT_SIZE] =
        calloc(MACPP_AUDIO_HARDWARE_MAX_CHANNELS, sizeof(*ring));
    float *window = calloc(MACPP_AUDIO_HARDWARE_FFT_SIZE, sizeof(float));
    float *samples = calloc(MACPP_AUDIO_HARDWARE_FFT_SIZE, sizeof(float));
    float *real = calloc(MACPP_AUDIO_HARDWARE_FFT_HALF, sizeof(float));
    float *imag = calloc(MACPP_AUDIO_HARDWARE_FFT_HALF, sizeof(float));
    float *magnitudes = calloc(MACPP_AUDIO_HARDWARE_FFT_HALF, sizeof(float));
    bool allocated = setup != NULL && ring != NULL && window != NULL &&
                     samples != NULL && real != NULL && imag != NULL &&
                     magnitudes != NULL;
    if (!allocated) {
        fprintf(stderr,
                "Hardware spectrum self-test could not allocate FFT state.\n");
        if (setup != NULL) {
            vDSP_destroy_fftsetup(setup);
        }
        free(ring);
        free(window);
        free(samples);
        free(real);
        free(imag);
        free(magnitudes);
        return 1;
    }

    vDSP_hann_window(window, MACPP_AUDIO_HARDWARE_FFT_SIZE, vDSP_HANN_NORM);
    const float sampleRate = 48000.0f;
    const float testHz[] = {40.0f, 1000.0f, 18000.0f};
    bool tonesPassed = true;
    for (size_t test = 0; test < sizeof(testHz) / sizeof(testHz[0]); test++) {
        memset(ring, 0,
               sizeof(*ring) * MACPP_AUDIO_HARDWARE_MAX_CHANNELS);
        for (int index = 0; index < MACPP_AUDIO_HARDWARE_FFT_SIZE; index++) {
            float value = 0.55f * sinf(
                2.0f * (float)M_PI * testHz[test] * (float)index /
                sampleRate);
            ring[0][index] = value;
            ring[1][index] = -value;
        }
        float db[MACPP_AUDIO_HARDWARE_BAND_COUNT];
        macpp_audio_calculate_hardware_band_db(
            ring, 0, MACPP_AUDIO_HARDWARE_FFT_SIZE,
            MACPP_AUDIO_HARDWARE_MAX_CHANNELS, sampleRate, setup, window,
            samples, real, imag, magnitudes, db);
        int peakBand = 0;
        for (int band = 1; band < MACPP_AUDIO_HARDWARE_BAND_COUNT; band++) {
            if (db[band] > db[peakBand]) {
                peakBand = band;
            }
        }
        int expected = macpp_audio_hardware_band_for_frequency(testHz[test]);
        float strongestDistantDB = MACPP_AUDIO_HARDWARE_MINIMUM_DB;
        for (int band = 0; band < MACPP_AUDIO_HARDWARE_BAND_COUNT; band++) {
            if (abs(band - peakBand) <= 1) {
                continue;
            }
            strongestDistantDB = fmaxf(strongestDistantDB, db[band]);
        }
        bool located = peakBand >= expected - 1 &&
                       peakBand <= expected + 1 && db[peakBand] > -60.0f &&
                       db[peakBand] - strongestDistantDB >= 12.0f;
        tonesPassed = tonesPassed && located;
        printf("hardware tone %.0fHz expected=%d peak=%d db=%.1f "
               "distant_gap=%.1f %s\n",
               testHz[test], expected, peakBand, db[peakBand],
               db[peakBand] - strongestDistantDB,
               located ? "PASS" : "FAIL");
    }

    MacPlusPlusAudioHardwareSpectrumEnvelope envelope = {0};
    float relativeDB[MACPP_AUDIO_HARDWARE_BAND_COUNT];
    for (int band = 0; band < MACPP_AUDIO_HARDWARE_BAND_COUNT; band++) {
        relativeDB[band] = MACPP_AUDIO_HARDWARE_MINIMUM_DB;
    }
    relativeDB[3] = -24.0f;
    relativeDB[10] = -36.0f;
    for (int tick = 0; tick < 240; tick++) {
        macpp_audio_update_hardware_spectrum_envelope(&envelope, relativeDB);
    }
    float sustained = envelope.bands[3];
    float quieter = envelope.bands[10];
    for (int tick = 0; tick < 100; tick++) {
        macpp_audio_update_hardware_spectrum_envelope(&envelope, relativeDB);
    }
    bool sustainedPassed =
        sustained >= 0.79f && sustained <= 0.83f &&
        envelope.bands[3] >= 0.79f && envelope.bands[3] <= 0.83f &&
        fabsf(envelope.bands[3] - sustained) < 0.01f && quieter >= 0.23f &&
        quieter <= 0.27f && envelope.bands[3] > quieter + 0.50f;

    MacPlusPlusAudioHardwareSpectrumEnvelope contrastEnvelope = {0};
    float contrastDB[MACPP_AUDIO_HARDWARE_BAND_COUNT];
    for (int band = 0; band < MACPP_AUDIO_HARDWARE_BAND_COUNT; band++) {
        contrastDB[band] = -48.0f;
    }
    contrastDB[3] = -12.0f;
    contrastDB[4] = -24.0f;
    for (int tick = 0; tick < 60; tick++) {
        macpp_audio_update_hardware_spectrum_envelope(&contrastEnvelope,
                                                     contrastDB);
    }
    int backgroundAbove = 0;
    float backgroundMaximum = 0.0f;
    for (int band = 0; band < MACPP_AUDIO_HARDWARE_BAND_COUNT; band++) {
        if (band == 3 || band == 4) {
            continue;
        }
        backgroundMaximum =
            fmaxf(backgroundMaximum, contrastEnvelope.bands[band]);
        if (contrastEnvelope.bands[band] > 0.12f) {
            backgroundAbove++;
        }
    }
    bool contrastPassed =
        contrastEnvelope.bands[3] >= 0.79f &&
        contrastEnvelope.bands[3] <= 0.83f &&
        contrastEnvelope.bands[4] >= 0.23f &&
        contrastEnvelope.bands[4] <= 0.27f &&
        backgroundMaximum <= 0.02f && backgroundAbove == 0;

    MacPlusPlusAudioHardwareSpectrumEnvelope quietEnvelope = {0};
    MacPlusPlusAudioHardwareSpectrumEnvelope loudEnvelope = {0};
    float quietDB[MACPP_AUDIO_HARDWARE_BAND_COUNT];
    float loudDB[MACPP_AUDIO_HARDWARE_BAND_COUNT];
    for (int band = 0; band < MACPP_AUDIO_HARDWARE_BAND_COUNT; band++) {
        quietDB[band] = -54.0f + (float)band * 1.5f;
        loudDB[band] = quietDB[band] + 12.0f;
    }
    for (int tick = 0; tick < 60; tick++) {
        macpp_audio_update_hardware_spectrum_envelope(&quietEnvelope, quietDB);
        macpp_audio_update_hardware_spectrum_envelope(&loudEnvelope, loudDB);
    }
    float levelInvariantError = 0.0f;
    for (int band = 0; band < MACPP_AUDIO_HARDWARE_BAND_COUNT; band++) {
        levelInvariantError = fmaxf(
            levelInvariantError,
            fabsf(quietEnvelope.bands[band] - loudEnvelope.bands[band]));
    }
    bool levelInvariant = levelInvariantError < 0.01f;

    for (int band = 0; band < MACPP_AUDIO_HARDWARE_BAND_COUNT; band++) {
        relativeDB[band] = MACPP_AUDIO_HARDWARE_MINIMUM_DB;
    }
    for (int tick = 0; tick < 100; tick++) {
        macpp_audio_update_hardware_spectrum_envelope(&envelope, relativeDB);
    }
    bool silencePassed =
        envelope.bands[3] < 0.001f && !envelope.referenceReady;
    printf("hardware envelope sustained=%.3f quieter=%.3f silence=%.4f %s\n",
           sustained, quieter, envelope.bands[3],
           sustainedPassed && silencePassed ? "PASS" : "FAIL");
    printf("hardware contrast dominant=%.3f neighbour=%.3f background=%.3f "
           "level_error=%.4f %s\n",
           contrastEnvelope.bands[3], contrastEnvelope.bands[4],
           backgroundMaximum, levelInvariantError,
           contrastPassed && levelInvariant ? "PASS" : "FAIL");

    vDSP_destroy_fftsetup(setup);
    free(ring);
    free(window);
    free(samples);
    free(real);
    free(imag);
    free(magnitudes);
    return tonesPassed && sustainedPassed && silencePassed && contrastPassed &&
                   levelInvariant
               ? 0
               : 1;
}

int macpp_audio_run_tempo_self_test(void) {
    float denormal = 1.0e-30f;
    bool normalizationPassed =
        macpp_audio_normalized_display_bpm(denormal) == 0.0f &&
        macpp_audio_normalized_display_bpm(33.0f) == 66.0f &&
        macpp_audio_normalized_display_bpm(128.0f) == 128.0f;

    const float intervals[] = {0.50f, 0.51f, 1.00f, 0.49f,
                               0.50f, 0.99f, 0.50f, 0.51f};
    float confidence = 0.0f;
    float period = macpp_audio_estimate_beat_period(
        intervals, (int)(sizeof(intervals) / sizeof(intervals[0])), 0.0f,
        &confidence);
    bool estimatorPassed =
        period > 0.47f && period < 0.54f && confidence >= 0.45f;
    printf("tempo normalization=%.1f/%.1f/%.1f estimator_period=%.3f "
           "confidence=%.3f %s\n",
           macpp_audio_normalized_display_bpm(denormal),
           macpp_audio_normalized_display_bpm(33.0f),
           macpp_audio_normalized_display_bpm(128.0f), period, confidence,
           normalizationPassed && estimatorPassed ? "PASS" : "FAIL");
    return normalizationPassed && estimatorPassed ? 0 : 1;
}
