#ifdef NDEBUG
#undef NDEBUG
#endif
#include "widget_companion.h"
#include <cassert>

namespace {
LONG result = ERROR_SUCCESS;
UINT32 packages = 0;
LONG WINAPI Query(PCWSTR, UINT32* count, PWSTR*, UINT32*, PWSTR) {
  *count = packages;
  return result;
}
}
int main() {
  using sybl::companion::Installed;
  assert(Installed(L"fixture", Query) == false);
  packages = 1;
  result = ERROR_INSUFFICIENT_BUFFER;
  assert(Installed(L"fixture", Query) == true);
  result = ERROR_ACCESS_DENIED;
  assert(!Installed(L"fixture", Query).has_value());
  packages = 0;
  result = ERROR_INSUFFICIENT_BUFFER;
  assert(!Installed(L"fixture", Query).has_value());
}
