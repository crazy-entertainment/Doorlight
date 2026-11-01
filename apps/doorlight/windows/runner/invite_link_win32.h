#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include <windows.h>

namespace sybl::invite_link {

inline constexpr std::uintptr_t kCopyDataId = 0x53594249;  // "SYBI"
inline constexpr std::size_t kMaxUriBytes = 1024;

bool IsInviteUri(std::string_view value);
std::optional<std::string> FindInviteArgument(
    const std::vector<std::string>& arguments);

// Stable non-display identity; the legacy title lookup supports older installs.
inline constexpr wchar_t kWindowIdentity[] = L"SybL.MainWindow.Invites.v1";
bool MarkMainWindow(HWND window);
HWND FindMainWindow();

// Best-effort per-user registration for both invite schemes. No elevation.
bool RegisterCurrentExecutable();

// Forward a link from a second process to the existing single instance.
bool ForwardToWindow(HWND window, const std::string& uri);

// Second-launch activation. The running instance owns every reveal: this
// grants it foreground permission and sends an acknowledged request, and never
// shows or focuses the window itself. The optional invite is forwarded first
// and exactly once. Returns true only if the reveal was acknowledged.
bool RequestReveal(HWND window);
bool ForwardAndRequestReveal(HWND window,
                             const std::optional<std::string>& invite);

}  // namespace sybl::invite_link
