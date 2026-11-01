#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>

namespace sybl::video {

// Decoded dimensions are negotiated by the remote endpoint. Keep the bound
// high enough for current 4K/ultrawide sources while preventing a peer from
// driving unbounded RGBA allocations in the daemon-to-Flutter render path.
inline constexpr std::int64_t kMaxDecodedDimension = 8192;
inline constexpr std::int64_t kMaxDecodedPixels = 16 * 1024 * 1024;
inline constexpr std::size_t kRgbaBytesPerPixel = 4;

constexpr bool IsSafeDecodedFrameSize(int width, int height) {
  if (width <= 0 || height <= 0 ||
      width > kMaxDecodedDimension || height > kMaxDecodedDimension) {
    return false;
  }
  return static_cast<std::int64_t>(width) *
             static_cast<std::int64_t>(height) <=
         kMaxDecodedPixels;
}

constexpr std::optional<std::size_t> DecodedRgbaByteCount(
    int width, int height) {
  if (!IsSafeDecodedFrameSize(width, height)) return std::nullopt;
  return static_cast<std::size_t>(width) *
         static_cast<std::size_t>(height) * kRgbaBytesPerPixel;
}

}  // namespace sybl::video
