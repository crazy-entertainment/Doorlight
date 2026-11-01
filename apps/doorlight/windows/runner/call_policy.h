#pragma once

#include <optional>
#include <string>
#include <string_view>

namespace sybl::calls {

enum class IncomingAdmission {
  kAcceptFirst,
  kSamePeerGlare,
  kRejectCrossPeerBusy,
  kRejectUntrusted,
};

// libjami owns same-peer crossed-call arbitration before CURRENT. Syb-L owns admission to its one process-global
// call slot across different peers, including while denySecondCall does not yet see a CURRENT call.
IncomingAdmission AdmitIncoming(bool trusted, const std::string& incoming_peer,
                                const std::string& reserved_peer);

enum class AudioTransmissionMode {
  kOpen,
  kVoiceActivated,
};

// Parse only the exact public libjami values. Unknown values must fail instead
// of silently selecting an open microphone.
std::optional<AudioTransmissionMode> ParseAudioTransmissionMode(
    std::string_view value);
std::string_view AudioTransmissionModeValue(AudioTransmissionMode mode);

}  // namespace sybl::calls
