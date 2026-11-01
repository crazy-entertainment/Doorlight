#include "desktop_sonar.h"

#include <algorithm>
#include <cmath>
#include <mutex>

namespace sybl::sonar {
namespace {

constexpr wchar_t kWindowClass[] = L"SybLDesktopSonar";
constexpr UINT_PTR kTimer = 1;
constexpr COLORREF kTransparentKey = RGB(1, 2, 3);
constexpr int kMaxOverlayDimension = 32768;

ATOM EnsureWindowClass() noexcept {
  static std::once_flag once;
  static ATOM atom = 0;
  std::call_once(once, [] {
    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = DesktopSonar::WindowProc;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.lpszClassName = kWindowClass;
    atom = RegisterClassExW(&wc);
    if (!atom && GetLastError() == ERROR_CLASS_ALREADY_EXISTS) atom = 1;
  });
  return atom;
}

}  // namespace

bool IsValidReveal(double x, double y, std::uint32_t color) noexcept {
  return std::isfinite(x) && std::isfinite(y) && x >= 0 && y >= 0 &&
         x <= 16384 && y <= 16384 && color <= 0x00ffffff &&
         color != 0x00010203;
}

DesktopSonar::~DesktopSonar() { Cancel(); }

bool DesktopSonar::Reveal(HWND flutter_view, double x, double y,
                          std::uint32_t color) noexcept {
  Cancel();
  if (!IsValidReveal(x, y, color) || !IsWindow(flutter_view)) return false;
  owner_ = GetAncestor(flutter_view, GA_ROOT);
  if (!owner_ || !IsWindowVisible(owner_) || IsIconic(owner_)) {
    owner_ = nullptr;
    return false;
  }

  const UINT dpi = GetDpiForWindow(flutter_view);
  if (dpi == 0 || dpi > 768) { owner_ = nullptr; return false; }
  const double scale = static_cast<double>(dpi) / 96.0;
  POINT point{static_cast<LONG>(std::lround(x * scale)),
              static_cast<LONG>(std::lround(y * scale))};
  if (!ClientToScreen(flutter_view, &point)) { owner_ = nullptr; return false; }

  const int left = GetSystemMetrics(SM_XVIRTUALSCREEN);
  const int top = GetSystemMetrics(SM_YVIRTUALSCREEN);
  const int width = GetSystemMetrics(SM_CXVIRTUALSCREEN);
  const int height = GetSystemMetrics(SM_CYVIRTUALSCREEN);
  if (width <= 0 || height <= 0 || width > kMaxOverlayDimension ||
      height > kMaxOverlayDimension || point.x < left || point.y < top ||
      point.x >= left + width || point.y >= top + height) {
    owner_ = nullptr;
    return false;
  }

  center_ = point;
  color_ = RGB((color >> 16) & 0xff, (color >> 8) & 0xff, color & 0xff);
  radius_ = static_cast<int>(std::ceil(std::hypot(
      (std::max)(point.x - left, left + width - point.x),
      (std::max)(point.y - top, top + height - point.y))));
  if (!EnsureWindowClass()) { owner_ = nullptr; return false; }
  // A topmost window covering a whole monitor reads to the shell as a
  // fullscreen app and hides the taskbar; one row short of it does not.
  // ponytail: rings skip the bottom pixel row of the virtual screen.
  const int overlay_height = height - 1;
  window_ = CreateWindowExW(kWindowStyles, kWindowClass, L"", WS_POPUP,
      left, top, width, overlay_height, nullptr, nullptr,
      GetModuleHandleW(nullptr), this);
  if (!window_ || !SetLayeredWindowAttributes(window_, kTransparentKey, 0,
                                               LWA_COLORKEY)) {
    Cancel();
    return false;
  }

  started_ = GetTickCount64();
  if (!SetTimer(window_, kTimer, 16, nullptr) ||
      !SetWindowPos(window_, HWND_TOPMOST, left, top, width, overlay_height,
                    SWP_NOACTIVATE | SWP_SHOWWINDOW)) {
    Cancel();
    return false;
  }
  Tick();
  return true;
}

void DesktopSonar::Tick() noexcept {
  if (!window_) return;
  if (!IsWindow(owner_) || !IsWindowVisible(owner_) || IsIconic(owner_) ||
      GetTickCount64() - started_ >= kDurationMs) {
    Cancel();
    return;
  }
  const int left = GetSystemMetrics(SM_XVIRTUALSCREEN);
  const int top = GetSystemMetrics(SM_YVIRTUALSCREEN);
  const int width = GetSystemMetrics(SM_CXVIRTUALSCREEN);
  const int height = GetSystemMetrics(SM_CYVIRTUALSCREEN);
  const double progress = std::clamp(
      static_cast<double>(GetTickCount64() - started_) / kDurationMs, 0.0, 1.0);
  if (!SetLayeredWindowAttributes(window_, kTransparentKey,
      static_cast<BYTE>(255 * (1.0 - progress)), LWA_COLORKEY | LWA_ALPHA)) {
    Cancel();
    return;
  }
  RECT bounds{(std::max<LONG>)(0, center_.x - radius_ - left),
              (std::max<LONG>)(0, center_.y - radius_ - top),
              (std::min<LONG>)(width, center_.x + radius_ - left),
              (std::min<LONG>)(height, center_.y + radius_ - top)};
  InvalidateRect(window_, &bounds, FALSE);
}

void DesktopSonar::Paint(HWND window) noexcept {
  PAINTSTRUCT ps{};
  HDC dc = BeginPaint(window, &ps);
  if (!dc) return;
  HBRUSH background = CreateSolidBrush(kTransparentKey);
  if (!background) {
    EndPaint(window, &ps);
    Cancel();
    return;
  }
  FillRect(dc, &ps.rcPaint, background);
  DeleteObject(background);
  // GDI's RGB drawing over a color-keyed surface keeps this geometry-only and
  // avoids reading back or copying any desktop pixels.
  const ULONGLONG elapsed = GetTickCount64() - started_;
  const int screen_left = GetSystemMetrics(SM_XVIRTUALSCREEN);
  const int screen_top = GetSystemMetrics(SM_YVIRTUALSCREEN);
  for (int ring = 0; ring < 4; ++ring) {
    const int age = static_cast<int>(elapsed) - ring * 190;
    if (age < 0 || age >= static_cast<int>(kDurationMs)) continue;
    const double progress = static_cast<double>(age) / kDurationMs;
    const int radius = 18 + static_cast<int>(radius_ * progress);
    const int left = center_.x - radius - screen_left;
    const int top = center_.y - radius - screen_top;
    const int right = center_.x + radius - screen_left;
    const int bottom = center_.y + radius - screen_top;
    // Darkening the pen toward black reads as a shadow on the desktop; the
    // window-wide alpha in Tick() fades the rings instead.
    HPEN pen = CreatePen(PS_SOLID, (std::max)(1, 5 - static_cast<int>(progress * 4)),
                         color_);
    if (pen) {
      const HGDIOBJ old = SelectObject(dc, pen);
      const HGDIOBJ brush = SelectObject(dc, GetStockObject(NULL_BRUSH));
      Ellipse(dc, left, top, right, bottom);
      SelectObject(dc, brush);
      SelectObject(dc, old);
      DeleteObject(pen);
    }
  }
  EndPaint(window, &ps);
}

void DesktopSonar::Cancel() noexcept {
  if (window_) {
    HWND window = window_;
    window_ = nullptr;
    KillTimer(window, kTimer);
    DestroyWindow(window);
  }
  owner_ = nullptr;
}

LRESULT CALLBACK DesktopSonar::WindowProc(HWND window, UINT message, WPARAM wp,
                                          LPARAM lp) noexcept {
  auto self = reinterpret_cast<DesktopSonar*>(GetWindowLongPtrW(window, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    self = static_cast<DesktopSonar*>(reinterpret_cast<CREATESTRUCTW*>(lp)->lpCreateParams);
    SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
  }
  if (message == WM_NCHITTEST) return HTTRANSPARENT;
  if (message == WM_MOUSEACTIVATE) return MA_NOACTIVATE;
  if (self && message == WM_PAINT) { self->Paint(window); return 0; }
  if (self && message == WM_TIMER && wp == kTimer) { self->Tick(); return 0; }
  if (self && message == WM_CLOSE) { self->Cancel(); return 0; }
  return DefWindowProcW(window, message, wp, lp);
}

}  // namespace sybl::sonar
