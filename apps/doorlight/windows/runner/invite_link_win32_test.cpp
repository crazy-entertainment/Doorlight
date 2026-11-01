#ifdef NDEBUG
#undef NDEBUG
#endif

#include "invite_link_win32.h"
#include "window_presentation.h"

#include <cassert>
#include <string>
#include <vector>

namespace {
int g_invites = 0;
int g_reveals = 0;
std::string g_order;
LRESULT CALLBACK ProbeProc(HWND hwnd, UINT message, WPARAM wparam,
                           LPARAM lparam) {
  if (message == WM_COPYDATA) {
    ++g_invites;
    g_order += "invite,";
    return TRUE;
  }
  LRESULT result = 0;
  sybl::window::RevealOperations ops{
      [] { g_order += "cover,"; return true; },
      [] { g_order += "show,"; },
      [] { g_order += "finish,"; },
      [] { g_order += "foreground,"; }};
  if (sybl::window::DispatchRevealRequest(message, ops, &result)) {
    ++g_reveals;
    return result;
  }
  return DefWindowProcW(hwnd, message, wparam, lparam);
}
}  // namespace

int main() {
  using sybl::invite_link::FindInviteArgument;
  using sybl::invite_link::IsInviteUri;

  const std::string id(40, 'a');
  const std::string valid = "sybl://add/" + id + "?name=Mara";
  assert(IsInviteUri(valid));
  const std::string alias = "doorlight://add/" + id + "?name=Mara";
  assert(IsInviteUri(alias));
  assert(!IsInviteUri("doorlight://remove/" + id));
  assert(!IsInviteUri("doorlight://add/" + id + "\n"));
  assert(!IsInviteUri("doorlight://add/" + std::string(1024, 'a')));
  assert(FindInviteArgument({"--trace-startup", alias}) == alias);
  assert(!IsInviteUri("https://example.test/" + id));
  assert(!IsInviteUri("sybl://remove/" + id));
  assert(!IsInviteUri("sybl://add/" + id + "\n"));
  assert(!IsInviteUri(std::string(1025, 'x')));

  const auto found = FindInviteArgument({"--trace-startup", valid});
  assert(found && *found == valid);
  assert(!FindInviteArgument({"--trace-startup"}));

  // The display title may change without changing forwarding identity.
  HWND window = CreateWindowExW(0, L"STATIC", L"Doorlight test window", 0,
                                0, 0, 1, 1, nullptr, nullptr,
                                GetModuleHandleW(nullptr), nullptr);
  assert(window);
  assert(sybl::invite_link::MarkMainWindow(window));
  assert(sybl::invite_link::FindMainWindow() == window);
  SetWindowTextW(window, L"A different display title");
  assert(sybl::invite_link::FindMainWindow() == window);
  RemovePropW(window, sybl::invite_link::kWindowIdentity);
  DestroyWindow(window);

  // Looking the main window up never presents it: a hidden throwaway window
  // stays hidden and does not become the foreground window.
  HWND hidden = CreateWindowExW(0, L"STATIC", L"Doorlight hidden window", 0,
                                0, 0, 1, 1, nullptr, nullptr,
                                GetModuleHandleW(nullptr), nullptr);
  assert(hidden);
  assert(!IsWindowVisible(hidden));
  assert(sybl::invite_link::MarkMainWindow(hidden));
  assert(sybl::invite_link::FindMainWindow() == hidden);
  assert(!IsWindowVisible(hidden));
  assert(GetForegroundWindow() != hidden);
  RemovePropW(hidden, sybl::invite_link::kWindowIdentity);
  DestroyWindow(hidden);

  // Invite + reveal request: the invite arrives exactly once, before the
  // covered reveal sequence, which the receiving window runs itself.
  WNDCLASSW cls{};
  cls.lpfnWndProc = ProbeProc;
  cls.hInstance = GetModuleHandleW(nullptr);
  cls.lpszClassName = L"SybLInviteProbeWindow";
  assert(RegisterClassW(&cls));
  HWND probe = CreateWindowExW(0, cls.lpszClassName, L"probe", 0, 0, 0, 1, 1,
                               nullptr, nullptr, cls.hInstance, nullptr);
  assert(probe);
  assert(sybl::invite_link::ForwardAndRequestReveal(probe, valid));
  assert(g_invites == 1 && g_reveals == 1);
  assert(g_order == "invite,cover,show,finish,foreground,");
  // The sender never shows the target itself; the probe stays hidden.
  assert(!IsWindowVisible(probe));
  g_invites = g_reveals = 0;
  g_order.clear();
  assert(sybl::invite_link::ForwardAndRequestReveal(probe, std::nullopt));
  assert(g_invites == 0 && g_reveals == 1);
  assert(!IsWindowVisible(probe));
  assert(!sybl::invite_link::ForwardAndRequestReveal(nullptr, valid));
  DestroyWindow(probe);
  return 0;
}
