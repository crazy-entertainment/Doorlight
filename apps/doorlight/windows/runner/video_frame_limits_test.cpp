#undef NDEBUG

#include "video_frame_limits.h"

#include <cassert>

int main() {
  using sybl::video::DecodedRgbaByteCount;
  using sybl::video::IsSafeDecodedFrameSize;

  assert(IsSafeDecodedFrameSize(1920, 1080));
  assert(IsSafeDecodedFrameSize(3840, 2160));
  assert(IsSafeDecodedFrameSize(8192, 2048));
  assert(DecodedRgbaByteCount(8192, 2048) == 64U * 1024U * 1024U);

  assert(!IsSafeDecodedFrameSize(0, 1080));
  assert(!IsSafeDecodedFrameSize(1920, 0));
  assert(!IsSafeDecodedFrameSize(-1, 1080));
  assert(!IsSafeDecodedFrameSize(8193, 1));
  assert(!IsSafeDecodedFrameSize(4096, 4097));
  assert(!IsSafeDecodedFrameSize(8192, 8192));
  assert(!DecodedRgbaByteCount(8192, 8192));

  return 0;
}
