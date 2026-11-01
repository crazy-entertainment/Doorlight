#pragma once
#include <windows.h>
#include <dwmapi.h>
#include "window_bounds.h"

// Synchronous platform-thread command. 0 = normal, 1 = compact conversation,
// 2/3 = direct/group audio. HWND lifetime owns both placements.
constexpr UINT kWindowPresentationMessage = WM_APP + 0x391;
// Posted by the channel to quit for real (close normally hides to the tray).
constexpr UINT kQuitRequestMessage = WM_APP + 0x392;
constexpr UINT kWindowPresentationStateMessage = WM_APP + 0x395;
constexpr UINT kFinishWindowPresentationMessage = WM_APP + 0x396;
constexpr UINT kWindowPresentationFrameMessage = WM_APP + 0x398;
constexpr UINT kWindowEdgeSpacingMessage = WM_APP + 0x399;
constexpr wchar_t kCompactWindowProperty[] = L"Doorlight.CompactWindow";

#include <functional>
#include <algorithm>
#include <cmath>
#include <utility>

namespace sybl::window {

constexpr int kDefaultWindowWidth = 700;
constexpr int kDefaultWindowHeight = 500;
// Flutter collapses the people pane below its desktop breakpoint during resize.
constexpr int kMinimumClientWidth = 280;

inline LONG MinimumTrackWidth(UINT dpi, LONG resize_border) noexcept {
  return MulDiv(kMinimumClientWidth, dpi ? dpi : 96, 96) + 2 * resize_border;
}

inline SIZE DefaultWindowSize(UINT dpi, const RECT& work_area) noexcept {
  return {(std::min)(static_cast<LONG>(MulDiv(kDefaultWindowWidth, dpi ? dpi : 96, 96)),
                     work_area.right - work_area.left),
          (std::min)(static_cast<LONG>(MulDiv(kDefaultWindowHeight, dpi ? dpi : 96, 96)),
                     work_area.bottom - work_area.top)};
}

inline FrameInsets VisibleFrameInsets(HWND window, const RECT& outer) noexcept {
  RECT visible{};
  if (SUCCEEDED(DwmGetWindowAttribute(window, DWMWA_EXTENDED_FRAME_BOUNDS,
          &visible, sizeof(visible))) &&
      visible.right > visible.left && visible.bottom > visible.top &&
      visible.left >= outer.left && visible.top >= outer.top &&
      visible.right <= outer.right && visible.bottom <= outer.bottom) {
    return {visible.left - outer.left, visible.top - outer.top,
            outer.right - visible.right, outer.bottom - visible.bottom};
  }
  return {};
}

inline bool IsDefaultWindowSize(SIZE actual, UINT dpi, const RECT& work_area,
                                FrameInsets frame = {}, int logical_gap = 8) noexcept {
  const SIZE expected = DefaultWindowSize(dpi, work_area);
  // A few pixels of restored-frame drift should not turn Compact into a reset.
  const LONG tolerance = MulDiv(4, dpi ? dpi : 96, 96);
  const auto matches = [actual, tolerance](LONG width, LONG height) {
    return actual.cx >= width - tolerance && actual.cx <= width + tolerance &&
        actual.cy >= height - tolerance && actual.cy <= height + tolerance;
  };
  if (matches(expected.cx, expected.cy)) return true;
  // The canonical corner placement leaves its visible gap even on a small
  // display. That may be smaller than the remembered-position default size.
  const auto corner = ChooseDefaultBounds(
      {work_area.left, work_area.top, work_area.right, work_area.bottom},
      expected.cx, expected.cy, frame, MulDiv(logical_gap, dpi ? dpi : 96, 96));
  return matches(corner.width, corner.height);
}

constexpr UINT kPresentationAnimationMs = 220;

// Anchor deadlines to the animation clock so late frames are skipped rather
// than queued or allowed to extend the animation. Windows uses 100ns units.
inline LONGLONG PresentationFrameDelay(double elapsed_ms, double refresh_hz) noexcept {
  if (refresh_hz < 30 || refresh_hz > 360) refresh_hz = 60;
  const double frame_ms = 1000.0 / refresh_hz;
  const double next_ms = (std::min)(
      (std::floor(elapsed_ms / frame_ms) + 1) * frame_ms,
      static_cast<double>(kPresentationAnimationMs));
  return (std::max)(1LL, static_cast<LONGLONG>(std::ceil((next_ms - elapsed_ms) * 10000)));
}

inline RECT InterpolateBounds(const RECT& from, const RECT& to, double progress) noexcept {
  const double t = std::clamp(progress, 0.0, 1.0);
  const double eased = 1 - (1 - t) * (1 - t) * (1 - t);
  const auto blend = [eased](LONG a, LONG b) {
    return a + static_cast<LONG>((b - a) * eased);
  };
  return {blend(from.left, to.left), blend(from.top, to.top),
          blend(from.right, to.right), blend(from.bottom, to.bottom)};
}

// Bit 0 is restored compact layout; bit 1 is the canonical default size.
// The window owner adds bit 2 (value 4) while animating toward those bounds.
inline LRESULT PresentationState(HWND window, int mode, int logical_gap = 8) noexcept {
  if (!window || !::IsWindow(window) || ::IsZoomed(window) || ::IsIconic(window))
    return 0;
  if (mode != 0) return 1;
  MONITORINFO monitor{sizeof(MONITORINFO)};
  RECT bounds{};
  if (!GetMonitorInfoW(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST), &monitor) ||
      !GetWindowRect(window, &bounds)) return 0;
  return IsDefaultWindowSize(
      {bounds.right - bounds.left, bounds.bottom - bounds.top},
      GetDpiForWindow(window), monitor.rcWork,
      VisibleFrameInsets(window, bounds), logical_gap) ? 2 : 0;
}

// Every application-controlled path that can make the main window visible
// runs this sequence in the instance that owns the window. The steps are
// injected so the order and the fail-closed rules are observable in tests.
struct RevealOperations {
  std::function<bool()> cover;    // Install the opaque privacy cover.
  std::function<void()> show;     // Make the window visible or restore it.
  std::function<void()> finish;   // Schedule cover removal after a frame.
  std::function<void()> foreground;
};

// cover -> show -> finish -> foreground. A failed or throwing cover leaves the
// window untouched; a throwing finish leaves the cover installed and the
// window unfocused. Returns true only when the whole sequence completed.
inline bool RunCoveredReveal(const RevealOperations& operations) noexcept {
  try {
    if (!operations.cover || !operations.show || !operations.finish ||
        !operations.foreground || !operations.cover()) {
      return false;
    }
  } catch (...) {
    return false;
  }
  try {
    operations.show();
    operations.finish();
  } catch (...) {
    return false;
  }
  try {
    operations.foreground();
  } catch (...) {
    return false;
  }
  return true;
}

// Show/foreground steps shared by the tray, the reveal request and the
// diagnostic focus command. |apply_deferred| runs right after the window is
// shown, so a presentation mode requested while hidden is applied under the
// cover.
inline RevealOperations WindowRevealOperations(
    HWND window, std::function<bool()> cover, std::function<void()> finish,
    std::function<void()> apply_deferred = nullptr) {
  return RevealOperations{
      std::move(cover),
      [window, apply_deferred = std::move(apply_deferred)]() {
        ::ShowWindow(window, ::IsIconic(window) ? SW_RESTORE : SW_SHOW);
        if (apply_deferred) apply_deferred();
      },
      std::move(finish),
      [window]() { ::SetForegroundWindow(window); }};
}

// Second launches ask the running instance to reveal itself; they never show
// the window. Registered so the id cannot collide with WM_APP users.
inline UINT RevealRequestMessage() noexcept {
  static const UINT message =
      ::RegisterWindowMessageW(L"Syb-L.RevealRequest.v1");
  return message;
}

// Returns true (and sets |result|) when |message| is a reveal request. The
// acknowledgement is TRUE only when the covered sequence completed.
inline bool DispatchRevealRequest(UINT message, const RevealOperations& ops,
                                  LRESULT* result) noexcept {
  if (message == 0 || message != RevealRequestMessage()) return false;
  *result = RunCoveredReveal(ops) ? TRUE : FALSE;
  return true;
}

// Window commands must never make a hidden window visible. |reveal| restores a
// visible-but-minimized window through the covered sequence first.
inline bool MinimizeWithoutReveal(HWND window) noexcept {
  if (!window || !::IsWindow(window) || !::IsWindowVisible(window)) return false;
  ::ShowWindow(window, SW_MINIMIZE);
  return true;
}

inline bool ToggleMaximizeWithoutReveal(
    HWND window, const std::function<bool()>& reveal_minimized) noexcept {
  if (!window || !::IsWindow(window) || !::IsWindowVisible(window)) return false;
  if (::IsIconic(window)) {
    try {
      if (!reveal_minimized || !reveal_minimized()) return false;
    } catch (...) {
      return false;
    }
  }
  ::ShowWindow(window, ::IsZoomed(window) ? SW_RESTORE : SW_MAXIMIZE);
  return true;
}

}  // namespace sybl::window
