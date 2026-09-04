#include "include/pipit_aec3.h"

#include <memory>
#include <vector>

#include "modules/audio_processing/include/audio_processing.h"
#include "api/audio/audio_processing.h"
#include "api/scoped_refptr.h"

namespace {

// The library works in blocks of this length whatever the sample rate.
constexpr int kBlockMilliseconds = 10;

}  // namespace

struct PipitAEC3 {
  webrtc::scoped_refptr<webrtc::AudioProcessing> apm;
  webrtc::StreamConfig config;
  int frames = 0;
  float echo_removed_db = 0;
};

PipitAEC3 *pipit_aec3_create(int sample_rate_hz) {
  // Below 8 kHz the library reports an unsupported format on every block, so
  // the rate is refused here instead of handing back a canceller that fails.
  if (sample_rate_hz < 8000) return nullptr;

  webrtc::AudioProcessing::Config config;
  config.echo_canceller.enabled = true;
  config.echo_canceller.mobile_mode = false;
  // Only the echo canceller. Levelling and noise suppression would rewrite the
  // user's own voice, and this audio is going to a transcriber and then into a
  // voice profile, both of which want it as it was recorded.
  config.gain_controller1.enabled = false;
  config.gain_controller2.enabled = false;
  config.noise_suppression.enabled = false;
  config.high_pass_filter.enabled = false;

  auto apm = webrtc::AudioProcessingBuilder().Create();
  if (!apm) return nullptr;
  apm->ApplyConfig(config);

  auto *aec = new PipitAEC3();
  aec->apm = apm;
  aec->config = webrtc::StreamConfig(sample_rate_hz, 1);
  aec->frames = sample_rate_hz / (1000 / kBlockMilliseconds);
  return aec;
}

int pipit_aec3_frame_size(const PipitAEC3 *aec) {
  return aec ? aec->frames : 0;
}

int pipit_aec3_process_reverse(PipitAEC3 *aec, const float *reference, size_t frames) {
  if (!aec || !reference || frames != static_cast<size_t>(aec->frames)) return -1;
  // Analysis rather than processing. The canceller only has to hear what was
  // played, and this form takes no output buffer, so there is nowhere for the
  // caller's reference to be written back into.
  const float *const input[] = {reference};
  return aec->apm->AnalyzeReverseStream(input, aec->config);
}

int pipit_aec3_process(PipitAEC3 *aec, float *microphone, size_t frames) {
  if (!aec || !microphone || frames != static_cast<size_t>(aec->frames)) return -1;
  float *const channels[] = {microphone};
  const int status =
      aec->apm->ProcessStream(channels, aec->config, aec->config, channels);
  if (status != 0) return status;
  // The library hands statistics over a one-slot queue and drops what nobody
  // took, so a caller reading every few seconds reads the block after its own
  // last read. Take the figure on every block and hold the newest.
  const auto metrics = aec->apm->GetStatistics();
  aec->echo_removed_db =
      metrics.echo_return_loss_enhancement.has_value()
          ? static_cast<float>(*metrics.echo_return_loss_enhancement)
          : 0.0f;
  return status;
}

float pipit_aec3_echo_removed_db(const PipitAEC3 *aec) {
  return aec ? aec->echo_removed_db : 0.0f;
}

void pipit_aec3_destroy(PipitAEC3 *aec) { delete aec; }
