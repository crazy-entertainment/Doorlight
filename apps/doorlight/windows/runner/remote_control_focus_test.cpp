#ifdef NDEBUG
#undef NDEBUG
#endif

#include "remote_control_focus.h"

#include <cassert>

using sybl::remote::IsDeniedForegroundExecutable;
using sybl::remote::OwnerWindowStateAllowsWholeDesktopControl;

int main() {
  assert(IsDeniedForegroundExecutable(
      L"C:\\Program Files\\Bitwarden\\Bitwarden.EXE"));
  assert(IsDeniedForegroundExecutable(L"keepassxc.exe"));
  assert(IsDeniedForegroundExecutable(L"CredentialUIBroker.exe"));
  assert(!IsDeniedForegroundExecutable(L"explorer.exe"));
  assert(!IsDeniedForegroundExecutable(L"chrome.exe"));
  assert(!IsDeniedForegroundExecutable(L"bitwarden-helper.exe"));
  assert(!IsDeniedForegroundExecutable(L""));

  // Whole-desktop control remains valid while an ordinary target application
  // owns OS foreground. Only the Syb-L owner window's actual lifecycle state
  // matters here; the sensitive-foreground denylist is evaluated separately.
  assert(OwnerWindowStateAllowsWholeDesktopControl(true, true, false));
  assert(!OwnerWindowStateAllowsWholeDesktopControl(false, true, false));
  assert(!OwnerWindowStateAllowsWholeDesktopControl(true, false, false));
  assert(!OwnerWindowStateAllowsWholeDesktopControl(true, true, true));
}
