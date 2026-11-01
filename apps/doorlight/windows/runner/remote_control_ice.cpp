#include "remote_control_ice.h"

#include <algorithm>
#include <cctype>
#include <optional>
#include <set>
#include <sstream>
#include <string>

namespace sybl::remote {
namespace {

constexpr std::size_t kMaxSocketsBytes = 4096;
constexpr std::size_t kMaxComponents = 32;
constexpr const char* kPairArrow = "\xE2\x86\x94";

bool ParseComponent(const std::string& token, unsigned& component) {
  if (token.size() < 3 || token.front() != '[' || token.back() != ']')
    return false;
  unsigned value = 0;
  for (std::size_t i = 1; i + 1 < token.size(); ++i) {
    const auto c = static_cast<unsigned char>(token[i]);
    if (!std::isdigit(c)) return false;
    const auto digit = static_cast<unsigned>(c - '0');
    if (value > 1000 || value * 10 + digit > 1000) return false;
    value = value * 10 + digit;
  }
  if (value == 0) return false;
  component = value;
  return true;
}

std::optional<LocalIcePath> CandidateType(const std::string& token) {
  if (token == "[host]") return LocalIcePath::kHostToHost;
  if (token == "[srflx]") return LocalIcePath::kServerReflexive;
  if (token == "[prflx]") return LocalIcePath::kPeerReflexive;
  if (token == "[relay]") return LocalIcePath::kRelay;
  return std::nullopt;
}

bool ValidAddress(const std::string& value) {
  if (value.empty() || value.size() > 256) return false;
  const auto port_separator = value.find_last_of(':');
  if (port_separator == std::string::npos || port_separator == 0 ||
      port_separator + 1 >= value.size()) {
    return false;
  }
  unsigned port = 0;
  for (std::size_t i = port_separator + 1; i < value.size(); ++i) {
    const auto c = static_cast<unsigned char>(value[i]);
    if (!std::isdigit(c)) return false;
    port = port * 10 + static_cast<unsigned>(c - '0');
    if (port > 65535) return false;
  }
  if (port == 0) return false;
  const auto host = value.substr(0, port_separator);
  if (host.front() == '[') {
    if (host.size() < 4 || host.back() != ']') return false;
    for (std::size_t i = 1; i + 1 < host.size(); ++i) {
      const auto c = static_cast<unsigned char>(host[i]);
      if (!std::isxdigit(c) && c != ':' && c != '.' && c != '%' &&
          c != '-' && c != '_') {
        return false;
      }
    }
    return true;
  }
  return std::all_of(host.begin(), host.end(), [](unsigned char c) {
    return std::isdigit(c) || c == '.';
  });
}

std::optional<std::string> AddressHost(const std::string& value) {
  if (!ValidAddress(value)) return std::nullopt;
  const auto port_separator = value.find_last_of(':');
  auto host = value.substr(0, port_separator);
  if (host.front() == '[') host = host.substr(1, host.size() - 2);
  return host;
}

LocalIcePath Combine(LocalIcePath current,
                     LocalIcePath local,
                     LocalIcePath remote) {
  if (local == LocalIcePath::kRelay || remote == LocalIcePath::kRelay)
    return LocalIcePath::kRelay;
  if (local == LocalIcePath::kServerReflexive ||
      remote == LocalIcePath::kServerReflexive) {
    return current == LocalIcePath::kRelay
        ? current
        : LocalIcePath::kServerReflexive;
  }
  if (local == LocalIcePath::kPeerReflexive ||
      remote == LocalIcePath::kPeerReflexive) {
    return current == LocalIcePath::kRelay ||
            current == LocalIcePath::kServerReflexive
        ? current
        : LocalIcePath::kPeerReflexive;
  }
  return current == LocalIcePath::kUnknown
      ? LocalIcePath::kHostToHost
      : current;
}

}  // namespace

LocalIceObservation ParseLocalIceObservation(const std::string& sockets) {
  if (sockets.empty() || sockets.size() > kMaxSocketsBytes)
    return {};
  std::istringstream input(sockets);
  std::set<unsigned> components;
  LocalIcePath result = LocalIcePath::kUnknown;
  std::string selected_local;
  std::string selected_remote;
  bool consistent_addresses = true;
  bool active = false;
  std::string line;
  std::size_t lines = 0;
  while (std::getline(input, line)) {
    if (!line.empty() && line.back() == '\r') line.pop_back();
    if (line.empty() || ++lines > kMaxComponents)
      return {};
    std::istringstream tokens(line);
    std::string component_token;
    std::string second;
    if (!(tokens >> component_token >> second))
      return {};
    unsigned component = 0;
    if (!ParseComponent(component_token, component) ||
        !components.insert(component).second) {
      return {};
    }
    if (second == "disabled") {
      return {};
    }

    std::string local_type_token;
    std::string arrow;
    std::string remote_address;
    std::string remote_type_token;
    std::string extra;
    if (!(tokens >> local_type_token >> arrow >> remote_address >>
          remote_type_token) ||
        (tokens >> extra) || !ValidAddress(second) ||
        !ValidAddress(remote_address) ||
        arrow != kPairArrow) {
      return {};
    }
    const auto local_type = CandidateType(local_type_token);
    const auto remote_type = CandidateType(remote_type_token);
    const auto local_host = AddressHost(second);
    const auto remote_host = AddressHost(remote_address);
    if (!local_type || !remote_type || !local_host || !remote_host)
      return {};
    if (active) {
      if (*local_host != selected_local ||
          *remote_host != selected_remote) {
        consistent_addresses = false;
      }
    } else {
      selected_local = *local_host;
      selected_remote = *remote_host;
    }
    result = Combine(result, *local_type, *remote_type);
    active = true;
  }
  return active
      ? LocalIceObservation{
            result,
            consistent_addresses ? selected_local : std::string(),
            consistent_addresses ? selected_remote : std::string()}
      : LocalIceObservation{};
}

LocalIcePath ParseLocalIcePath(const std::string& sockets) {
  return ParseLocalIceObservation(sockets).path;
}

bool DefaultCoControlForPath(LocalIcePath path,
                             bool same_lan_prefix_proven,
                             bool exact_device_persistent) {
  return path == LocalIcePath::kHostToHost && same_lan_prefix_proven &&
      exact_device_persistent;
}

}  // namespace sybl::remote
