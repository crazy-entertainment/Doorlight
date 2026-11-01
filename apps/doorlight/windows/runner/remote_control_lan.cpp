#include "remote_control_lan.h"

#include <winsock2.h>
#include <ws2tcpip.h>

#include <iphlpapi.h>

#include <algorithm>
#include <array>
#include <cstring>
#include <vector>

namespace sybl::remote {
namespace {

struct ParsedAddress {
  int family = AF_UNSPEC;
  std::array<unsigned char, 16> bytes{};
  std::uint32_t scope_id = 0;
};

bool RemoveZone(std::string& address, std::uint32_t& scope_id) {
  const auto zone = address.find('%');
  if (zone == std::string::npos) return true;
  if (zone + 1 >= address.size()) return false;
  std::uint64_t value = 0;
  for (std::size_t i = zone + 1; i < address.size(); ++i) {
    const auto c = static_cast<unsigned char>(address[i]);
    if (c < '0' || c > '9') return false;
    value = value * 10 + static_cast<unsigned>(c - '0');
    if (value > UINT32_MAX) return false;
  }
  if (value == 0) return false;
  scope_id = static_cast<std::uint32_t>(value);
  address.resize(zone);
  return true;
}

bool ParseAddress(const std::string& text, ParsedAddress& result) {
  auto address = text;
  if (!RemoveZone(address, result.scope_id)) return false;
  IN_ADDR ipv4{};
  if (InetPtonA(AF_INET, address.c_str(), &ipv4) == 1) {
    result.family = AF_INET;
    std::memcpy(result.bytes.data(), &ipv4, sizeof(ipv4));
    return true;
  }
  IN6_ADDR ipv6{};
  if (InetPtonA(AF_INET6, address.c_str(), &ipv6) == 1) {
    result.family = AF_INET6;
    std::memcpy(result.bytes.data(), &ipv6, sizeof(ipv6));
    return true;
  }
  return false;
}

bool IsPrivateOrLinkLocal(const ParsedAddress& address) {
  if (address.family == AF_INET) {
    const auto* b = address.bytes.data();
    return b[0] == 10 ||
        (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
        (b[0] == 192 && b[1] == 168) ||
        (b[0] == 169 && b[1] == 254);
  }
  if (address.family == AF_INET6) {
    const auto* b = address.bytes.data();
    return (b[0] == 0xfe && (b[1] & 0xc0) == 0x80) ||
        (b[0] & 0xfe) == 0xfc;
  }
  return false;
}

bool IsIpv6LinkLocal(const ParsedAddress& address) {
  return address.family == AF_INET6 &&
      address.bytes[0] == 0xfe &&
      (address.bytes[1] & 0xc0) == 0x80;
}

bool AddressEqual(const ParsedAddress& left,
                  const ParsedAddress& right) {
  if (left.family != right.family) return false;
  const auto byte_count = left.family == AF_INET ? 4u : 16u;
  return std::equal(left.bytes.begin(),
                    left.bytes.begin() + byte_count,
                    right.bytes.begin());
}

bool PrefixMatches(const ParsedAddress& left,
                   const ParsedAddress& right,
                   std::uint8_t prefix_length) {
  if (left.family != right.family) return false;
  const auto bit_count = left.family == AF_INET ? 32u : 128u;
  if (prefix_length == 0 || prefix_length > bit_count) return false;
  const auto whole_bytes = prefix_length / 8;
  const auto remaining_bits = prefix_length % 8;
  if (!std::equal(left.bytes.begin(),
                  left.bytes.begin() + whole_bytes,
                  right.bytes.begin())) {
    return false;
  }
  if (remaining_bits == 0) return true;
  const auto mask =
      static_cast<unsigned char>(0xffu << (8u - remaining_bits));
  return (left.bytes[whole_bytes] & mask) ==
      (right.bytes[whole_bytes] & mask);
}

std::string SocketAddressText(const SOCKADDR* socket_address) {
  if (!socket_address) return {};
  char buffer[INET6_ADDRSTRLEN]{};
  if (socket_address->sa_family == AF_INET) {
    const auto* address =
        reinterpret_cast<const SOCKADDR_IN*>(socket_address);
    return InetNtopA(AF_INET, &address->sin_addr, buffer,
                     static_cast<DWORD>(std::size(buffer)))
        ? std::string(buffer)
        : std::string();
  }
  if (socket_address->sa_family == AF_INET6) {
    const auto* address =
        reinterpret_cast<const SOCKADDR_IN6*>(socket_address);
    return InetNtopA(AF_INET6, &address->sin6_addr, buffer,
                     static_cast<DWORD>(std::size(buffer)))
        ? std::string(buffer)
        : std::string();
  }
  return {};
}

}  // namespace

bool IsProvenSameLan(
    const LocalIceObservation& observation,
    const std::vector<LocalAdapterPrefix>& local_prefixes) {
  if (observation.path != LocalIcePath::kHostToHost ||
      observation.local_address.empty() ||
      observation.remote_address.empty()) {
    return false;
  }
  ParsedAddress selected_local;
  ParsedAddress selected_remote;
  if (!ParseAddress(observation.local_address, selected_local) ||
      !ParseAddress(observation.remote_address, selected_remote) ||
      selected_local.family != selected_remote.family ||
      !IsPrivateOrLinkLocal(selected_local) ||
      !IsPrivateOrLinkLocal(selected_remote)) {
    return false;
  }
  for (const auto& prefix : local_prefixes) {
    ParsedAddress adapter;
    if (!ParseAddress(prefix.address, adapter) ||
        adapter.family != selected_local.family ||
        !AddressEqual(adapter, selected_local)) {
      continue;
    }
    if (IsIpv6LinkLocal(selected_local) &&
        (selected_local.scope_id == 0 || prefix.scope_id == 0 ||
         selected_local.scope_id != prefix.scope_id)) {
      continue;
    }
    if (PrefixMatches(adapter, selected_remote, prefix.prefix_length))
      return true;
  }
  return false;
}

std::vector<LocalAdapterPrefix> CurrentLocalAdapterPrefixes() {
  constexpr ULONG flags =
      GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST |
      GAA_FLAG_SKIP_DNS_SERVER;
  ULONG size = 16 * 1024;
  std::vector<unsigned char> buffer(size);
  auto* adapters =
      reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());
  auto status =
      GetAdaptersAddresses(AF_UNSPEC, flags, nullptr, adapters, &size);
  if (status == ERROR_BUFFER_OVERFLOW && size <= 1024 * 1024) {
    buffer.resize(size);
    adapters =
        reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());
    status =
        GetAdaptersAddresses(AF_UNSPEC, flags, nullptr, adapters, &size);
  }
  if (status != NO_ERROR) return {};

  std::vector<LocalAdapterPrefix> result;
  for (auto* adapter = adapters; adapter; adapter = adapter->Next) {
    if (adapter->OperStatus != IfOperStatusUp) continue;
    for (auto* unicast = adapter->FirstUnicastAddress; unicast;
         unicast = unicast->Next) {
      const auto address =
          SocketAddressText(unicast->Address.lpSockaddr);
      if (address.empty() || unicast->OnLinkPrefixLength == 0) continue;
      std::uint32_t scope_id = 0;
      if (unicast->Address.lpSockaddr->sa_family == AF_INET6) {
        scope_id = reinterpret_cast<const SOCKADDR_IN6*>(
            unicast->Address.lpSockaddr)->sin6_scope_id;
      }
      result.push_back(LocalAdapterPrefix{
          address, unicast->OnLinkPrefixLength, scope_id});
    }
  }
  return result;
}

}  // namespace sybl::remote
