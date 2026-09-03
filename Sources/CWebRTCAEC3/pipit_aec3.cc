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
};

PipitAEC3 *pipit_aec3_create(int sample_rate_hz, int channels) {
  if (sample_rate_hz <= 0 || channels <= 0) return nullptr;

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
  aec->config = webrtc::StreamConfig(sample_rate_hz, channels);
  aec->frames = sample_rate_hz / (1000 / kBlockMilliseconds);
  return aec;
}

int pipit_aec3_frame_size(const PipitAEC3 *aec) {
  return aec ? aec->frames : 0;
}

int pipit_aec3_process_reverse(PipitAEC3 *aec, const float *reference, size_t frames) {
  if (!aec || !reference || frames != static_cast<size_t>(aec->frames)) return -1;
  const float *const channels[] = {reference};
  return aec->apm->ProcessReverseStream(channels, aec->config, aec->config,
                                        const_cast<float *const *>(channels));
}

int pipit_aec3_process(PipitAEC3 *aec, float *microphone, size_t frames) {
  if (!aec || !microphone || frames != static_cast<size_t>(aec->frames)) return -1;
  float *const channels[] = {microphone};
  return aec->apm->ProcessStream(channels, aec->config, aec->config, channels);
}

float pipit_aec3_echo_return_loss_db(const PipitAEC3 *aec) {
  if (!aec) return 0;
  auto metrics = aec->apm->GetStatistics();
  return metrics.echo_return_loss.has_value()
             ? static_cast<float>(*metrics.echo_return_loss)
             : 0.0f;
}

void pipit_aec3_destroy(PipitAEC3 *aec) { delete aec; }
