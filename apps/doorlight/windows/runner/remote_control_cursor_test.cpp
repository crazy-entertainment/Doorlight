#ifdef NDEBUG
#undef NDEBUG
#endif

#include "remote_control_cursor.h"

#include <cassert>

int main() {
  const auto placement = sybl::remote::PlaceRemoteCursor(100, 200);
  assert(placement.left == 96);
  assert(placement.top == 196);
  assert(placement.width == 36);
  assert(placement.height == 52);
  assert(sybl::remote::ColorRefFromArgb(0xff67beb6u) == 0x00b6be67u);
  return 0;
}
