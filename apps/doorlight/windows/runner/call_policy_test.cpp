#ifdef NDEBUG
#undef NDEBUG
#endif

#include "call_policy.h"

#include <cassert>

using sybl::calls::AdmitIncoming;
using sybl::calls::AudioTransmissionMode;
using sybl::calls::AudioTransmissionModeValue;
using sybl::calls::IncomingAdmission;
using sybl::calls::ParseAudioTransmissionMode;

int main() {
  assert(AdmitIncoming(false, "peer-a", "") ==
         IncomingAdmission::kRejectUntrusted);
  assert(AdmitIncoming(true, "peer-a", "") ==
         IncomingAdmission::kAcceptFirst);
  assert(AdmitIncoming(true, "peer-a", "peer-a") ==
         IncomingAdmission::kSamePeerGlare);
  assert(AdmitIncoming(true, "peer-b", "peer-a") ==
         IncomingAdmission::kRejectCrossPeerBusy);

  assert(ParseAudioTransmissionMode("open") ==
         AudioTransmissionMode::kOpen);
  assert(ParseAudioTransmissionMode("voiceActivated") ==
         AudioTransmissionMode::kVoiceActivated);
  assert(!ParseAudioTransmissionMode(""));
  assert(!ParseAudioTransmissionMode("voice-activated"));
  assert(!ParseAudioTransmissionMode("VOICE_ACTIVATED"));
  assert(AudioTransmissionModeValue(AudioTransmissionMode::kOpen) == "open");
  assert(AudioTransmissionModeValue(AudioTransmissionMode::kVoiceActivated) ==
         "voiceActivated");
}
