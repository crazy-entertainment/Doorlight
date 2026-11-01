#include "timeline_wire.h"

#include <limits>

namespace sybl::timeline {
namespace {

bool IsContinuation(unsigned char value) {
  return (value & 0xc0u) == 0x80u;
}

}  // namespace

std::optional<Utf8Measure> MeasureUtf8(
    std::string_view value,
    std::size_t max_utf16_code_units) {
  // A valid Unicode scalar needs at most three UTF-8 bytes per UTF-16 code
  // unit. This cheap guard avoids walking a clearly impossible hostile value.
  if (max_utf16_code_units <=
          std::numeric_limits<std::size_t>::max() / 3 &&
      value.size() > max_utf16_code_units * 3) {
    return std::nullopt;
  }

  std::size_t utf16_units = 0;
  for (std::size_t i = 0; i < value.size();) {
    const auto first = static_cast<unsigned char>(value[i]);
    std::size_t width = 0;
    std::size_t units = 1;

    if (first <= 0x7fu) {
      width = 1;
    } else if (first >= 0xc2u && first <= 0xdfu) {
      width = 2;
      if (i + width > value.size() ||
          !IsContinuation(static_cast<unsigned char>(value[i + 1]))) {
        return std::nullopt;
      }
    } else if (first >= 0xe0u && first <= 0xefu) {
      width = 3;
      if (i + width > value.size()) return std::nullopt;
      const auto second = static_cast<unsigned char>(value[i + 1]);
      const auto third = static_cast<unsigned char>(value[i + 2]);
      if (!IsContinuation(third) ||
          (first == 0xe0u && (second < 0xa0u || second > 0xbfu)) ||
          (first == 0xedu && (second < 0x80u || second > 0x9fu)) ||
          (first != 0xe0u && first != 0xedu && !IsContinuation(second))) {
        return std::nullopt;
      }
    } else if (first >= 0xf0u && first <= 0xf4u) {
      width = 4;
      units = 2;
      if (i + width > value.size()) return std::nullopt;
      const auto second = static_cast<unsigned char>(value[i + 1]);
      if ((first == 0xf0u && (second < 0x90u || second > 0xbfu)) ||
          (first == 0xf4u && (second < 0x80u || second > 0x8fu)) ||
          (first != 0xf0u && first != 0xf4u && !IsContinuation(second)) ||
          !IsContinuation(static_cast<unsigned char>(value[i + 2])) ||
          !IsContinuation(static_cast<unsigned char>(value[i + 3]))) {
        return std::nullopt;
      }
    } else {
      return std::nullopt;
    }

    if (units > max_utf16_code_units ||
        utf16_units > max_utf16_code_units - units) {
      return std::nullopt;
    }
    utf16_units += units;
    i += width;
  }

  return Utf8Measure{utf16_units, value.size()};
}

bool IsRequiredUtf8(std::string_view value,
                    std::size_t max_utf16_code_units) {
  return !value.empty() &&
         MeasureUtf8(value, max_utf16_code_units).has_value();
}

bool IsOptionalUtf8(std::string_view value,
                    std::size_t max_utf16_code_units) {
  return MeasureUtf8(value, max_utf16_code_units).has_value();
}

bool CanAppendTimelineSnapshotItem(std::size_t current_item_count,
                                   std::size_t current_json_bytes,
                                   std::size_t item_json_bytes) {
  if (current_item_count >= kMaxTimelineSnapshotItems ||
      current_json_bytes > kMaxTimelineSnapshotBytes) {
    return false;
  }
  const std::size_t comma_bytes = current_item_count == 0 ? 0 : 1;
  const std::size_t remaining =
      kMaxTimelineSnapshotBytes - current_json_bytes;
  const std::size_t fixed_bytes = comma_bytes + 1;  // final ']'
  return fixed_bytes <= remaining &&
         item_json_bytes <= remaining - fixed_bytes;
}

}  // namespace sybl::timeline
