#pragma once

#include "remote_control_host.h"

#include <flutter/encodable_value.h>
#include <flutter/method_call.h>
#include <flutter/method_result.h>

namespace sybl::remote {

inline flutter::EncodableValue EncodeHostAuthority(
    const HostAuthorityStatus& status) {
  using flutter::EncodableValue;
  return EncodableValue(flutter::EncodableMap{
      {EncodableValue("channelEpoch"),
       EncodableValue(static_cast<int64_t>(status.channel_epoch))},
      {EncodableValue("surfaceRevision"),
       EncodableValue(static_cast<int64_t>(status.surface_revision))},
      {EncodableValue("hostGeneration"),
       EncodableValue(static_cast<int64_t>(status.host_generation))},
      {EncodableValue("revokedThrough"),
       EncodableValue(static_cast<int64_t>(status.revoked_through))},
      {EncodableValue("blocked"), EncodableValue(status.blocked)},
      {EncodableValue("releaseComplete"), EncodableValue(status.release_complete)},
      {EncodableValue("state"), EncodableValue(status.state)},
  });
}

// This is the production MethodChannel boundary. Host integration tests use
// the same argument validation and acknowledgement encoding as JamiChannels.
inline bool HandleRemoteControlAuthorityCall(
    RemoteControlHost& host,
    const flutter::MethodCall<flutter::EncodableValue>& call,
    flutter::MethodResult<flutter::EncodableValue>& result) {
  if (call.method_name() == "remoteControlHostAuthority") {
    result.Success(EncodeHostAuthority(host.AuthorityStatus()));
    return true;
  }
  if (call.method_name() != "remoteControlSetProtectedSurface") return false;
  const auto* arguments = call.arguments();
  const auto* args = arguments
      ? std::get_if<flutter::EncodableMap>(arguments) : nullptr;
  const auto integer = [args](const char* key) -> int64_t {
    if (!args) return -1;
    const auto it = args->find(flutter::EncodableValue(key));
    if (it == args->end()) return -1;
    if (const auto* value = std::get_if<int32_t>(&it->second)) return *value;
    if (const auto* value = std::get_if<int64_t>(&it->second)) return *value;
    return -1;
  };
  const auto epoch = integer("channelEpoch");
  const auto revision = integer("surfaceRevision");
  const bool* blocked = nullptr;
  if (args) {
    const auto it = args->find(flutter::EncodableValue("blocked"));
    if (it != args->end()) blocked = std::get_if<bool>(&it->second);
  }
  if (epoch <= 0 || revision <= 0 || !blocked) {
    result.Error("invalid_control_authority",
                 "A current channel epoch, surface revision and Boolean block state are required.");
    return true;
  }
  result.Success(EncodeHostAuthority(host.SetProtectedSurface(
      static_cast<uint64_t>(epoch), static_cast<uint64_t>(revision), *blocked)));
  return true;
}

}  // namespace sybl::remote
