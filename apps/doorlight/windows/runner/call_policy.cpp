#include "call_policy.h"

namespace sybl::calls {

IncomingAdmission AdmitIncoming(bool trusted, const std::string& incoming_peer,
                                const std::string& reserved_peer) {
  if (!trusted) return IncomingAdmission::kRejectUntrusted;
  if (reserved_peer.empty()) return IncomingAdmission::kAcceptFirst;
  if (reserved_peer == incoming_peer) return IncomingAdmission::kSamePeerGlare;
  return IncomingAdmission::kRejectCrossPeerBusy;
}

std::optional<AudioTransmissionMode> ParseAudioTransmissionMode(
    std::string_view value) {
  if (value == "open") return AudioTransmissionMode::kOpen;
  if (value == "voiceActivated")
    return AudioTransmissionMode::kVoiceActivated;
  return std::nullopt;
}

std::string_view AudioTransmissionModeValue(AudioTransmissionMode mode) {
  switch (mode) {
    case AudioTransmissionMode::kOpen:
      return "open";
    case AudioTransmissionMode::kVoiceActivated:
      return "voiceActivated";
  }
  return {};
}

}  // namespace sybl::calls
