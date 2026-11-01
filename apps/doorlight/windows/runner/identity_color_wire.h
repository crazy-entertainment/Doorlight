#pragma once

#include <array>
#include <cstdint>
#include <optional>
#include <string_view>

namespace sybl::identity_color_wire {

struct Value {
  std::string_view key;
  std::uint32_t argb;
};

inline constexpr std::array<Value, 24> kValues{{
    {"amber", 0xfff2b775u},
    {"coral", 0xfff08a6cu},
    {"rose", 0xffd97a9au},
    {"violet", 0xffa98bd4u},
    {"sky", 0xff7fafd8u},
    {"teal", 0xff67beb6u},
    {"sage", 0xff8fbe83u},
    {"lime", 0xffb5c96au},
    {"red", 0xffe86b69u},
    {"orange", 0xffef9d5du},
    {"yellow", 0xffe6ca63u},
    {"green", 0xff6acb7au},
    {"emerald", 0xff49af84u},
    {"mint", 0xff73d1b1u},
    {"cyan", 0xff58c7d7u},
    {"ice", 0xff9dcfe7u},
    {"azure", 0xff559ce0u},
    {"blue", 0xff6386e5u},
    {"cobalt", 0xff5570c5u},
    {"navy", 0xff526994u},
    {"indigo", 0xff8277cdu},
    {"magenta", 0xffc975bdu},
    {"slate", 0xff98a4b7u},
    {"ivory", 0xffe3ddc9u},
}};

inline std::optional<std::size_t> Index(std::string_view key) {
  for (std::size_t index = 0; index < kValues.size(); ++index) {
    if (kValues[index].key == key) return index;
  }
  return std::nullopt;
}

inline std::string_view Key(std::size_t index) {
  return index < kValues.size() ? kValues[index].key : std::string_view{};
}

inline std::optional<std::uint32_t> Argb(std::string_view key) {
  const auto index = Index(key);
  return index ? std::optional{kValues[*index].argb} : std::nullopt;
}

}  // namespace sybl::identity_color_wire
