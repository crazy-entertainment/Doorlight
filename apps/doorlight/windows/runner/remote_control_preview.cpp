#include "remote_control_preview.h"

#include <cstdint>
#include <cstdio>

namespace sybl::remote {
namespace {

bool DecodeScalar(const std::string& value,
                  std::size_t& offset,
                  std::uint32_t& scalar) {
  if (offset >= value.size()) return false;
  const auto first = static_cast<unsigned char>(value[offset]);
  std::size_t length = 0;
  std::uint32_t minimum = 0;
  if (first <= 0x7f) {
    length = 1;
    scalar = first;
  } else if ((first & 0xe0) == 0xc0) {
    length = 2;
    minimum = 0x80;
    scalar = first & 0x1f;
  } else if ((first & 0xf0) == 0xe0) {
    length = 3;
    minimum = 0x800;
    scalar = first & 0x0f;
  } else if ((first & 0xf8) == 0xf0) {
    length = 4;
    minimum = 0x10000;
    scalar = first & 0x07;
  } else {
    return false;
  }
  if (offset + length > value.size()) return false;
  for (std::size_t i = 1; i < length; ++i) {
    const auto next = static_cast<unsigned char>(value[offset + i]);
    if ((next & 0xc0) != 0x80) return false;
    scalar = (scalar << 6) | (next & 0x3f);
  }
  if ((length > 1 && scalar < minimum) ||
      scalar > 0x10ffff ||
      (scalar >= 0xd800 && scalar <= 0xdfff)) {
    return false;
  }
  offset += length;
  return true;
}

bool MustEscape(std::uint32_t scalar) {
  if (scalar <= 0x1f || (scalar >= 0x7f && scalar <= 0x9f))
    return true;
  return scalar == 0x00ad || scalar == 0x034f ||
      (scalar >= 0x0600 && scalar <= 0x0605) ||
      scalar == 0x061c || scalar == 0x06dd || scalar == 0x070f ||
      (scalar >= 0x0890 && scalar <= 0x0891) ||
      scalar == 0x08e2 ||
      (scalar >= 0x115f && scalar <= 0x1160) ||
      (scalar >= 0x17b4 && scalar <= 0x17b5) ||
      (scalar >= 0x180b && scalar <= 0x180e) ||
      (scalar >= 0x200b && scalar <= 0x200f) ||
      (scalar >= 0x2028 && scalar <= 0x202e) ||
      (scalar >= 0x2060 && scalar <= 0x206f) ||
      scalar == 0x3164 ||
      (scalar >= 0xfe00 && scalar <= 0xfe0f) ||
      scalar == 0xfeff || scalar == 0xffa0 ||
      (scalar >= 0xfff9 && scalar <= 0xfffb) ||
      scalar == 0x110bd || scalar == 0x110cd ||
      (scalar >= 0x13430 && scalar <= 0x13455) ||
      (scalar >= 0x1bca0 && scalar <= 0x1bca3) ||
      (scalar >= 0x1d173 && scalar <= 0x1d17a) ||
      scalar == 0xe0001 ||
      (scalar >= 0xe0020 && scalar <= 0xe007f) ||
      (scalar >= 0xe0100 && scalar <= 0xe01ef);
}

std::string VisibleEscape(std::uint32_t scalar) {
  char buffer[16]{};
  std::snprintf(buffer, sizeof(buffer), "\\u{%04X}",
                static_cast<unsigned>(scalar));
  return buffer;
}

}  // namespace

std::string SafeClipboardPreview(const std::string& utf8,
                                 std::size_t max_scalars) {
  std::string result;
  std::size_t offset = 0;
  std::size_t displayed = 0;
  bool truncated = false;
  while (offset < utf8.size()) {
    const auto scalar_start = offset;
    std::uint32_t scalar = 0;
    if (!DecodeScalar(utf8, offset, scalar)) return "[invalid text]";
    if (displayed < max_scalars) {
      if (MustEscape(scalar)) {
        result += VisibleEscape(scalar);
      } else {
        result.append(utf8, scalar_start, offset - scalar_start);
      }
      ++displayed;
    } else {
      truncated = true;
    }
  }
  if (truncated) result += "...";
  return result;
}

}  // namespace sybl::remote
