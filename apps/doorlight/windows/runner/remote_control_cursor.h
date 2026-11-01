#pragma once

#include <cstdint>

namespace sybl::remote {

struct CursorOverlayPlacement {
  int left;
  int top;
  int width;
  int height;
};

inline constexpr CursorOverlayPlacement PlaceRemoteCursor(int x, int y) {
  return {x - 4, y - 4, 36, 52};
}

inline constexpr std::uint32_t ColorRefFromArgb(std::uint32_t argb) {
  return ((argb >> 16) & 0xffu) | (argb & 0xff00u) |
      ((argb & 0xffu) << 16);
}

}  // namespace sybl::remote
