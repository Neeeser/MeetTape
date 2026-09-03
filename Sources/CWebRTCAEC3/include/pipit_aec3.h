// Acoustic echo cancellation over two recorded tracks.
//
// The microphone of a call taken on speakers holds the far end as well as the
// user, because the far end came out of the speakers and back in. Pipit records
// the far end separately, so the pair is exactly what an echo canceller needs:
// a capture stream to clean and a reference stream saying what was played.
//
// The reference is why Apple's own voice-processing unit could not help. It
// subtracts what its host renders, and Pipit renders nothing. The meeting app
// does. What Pipit has instead is the recording of it.
#ifndef PIPIT_AEC3_H
#define PIPIT_AEC3_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct PipitAEC3 PipitAEC3;

/// One canceller for one recording. Nil where the rate or channel count is not
/// one the library accepts.
PipitAEC3 *pipit_aec3_create(int sample_rate_hz, int channels);

/// Frames per call, for both streams. The library works in 10 ms blocks.
int pipit_aec3_frame_size(const PipitAEC3 *aec);

/// Hands over one block of what was played, before the microphone block that
/// overlaps it in time.
int pipit_aec3_process_reverse(PipitAEC3 *aec, const float *reference, size_t frames);

/// Cleans one block of microphone audio in place. Returns 0 on success.
int pipit_aec3_process(PipitAEC3 *aec, float *microphone, size_t frames);

/// How much of the microphone the canceller is currently removing, in decibels.
/// Near zero for a meeting taken on headphones, where there is no path from the
/// speakers to the microphone and nothing to subtract.
float pipit_aec3_echo_return_loss_db(const PipitAEC3 *aec);

void pipit_aec3_destroy(PipitAEC3 *aec);

#ifdef __cplusplus
}
#endif
#endif
