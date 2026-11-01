#include "annotation_overlay.h"

#include <algorithm>
#include <cmath>
#include <mutex>

namespace sybl::annotation {
namespace {

constexpr wchar_t kOverlayClass[] = L"SybLAnnotationOverlay";
constexpr COLORREF kTransparentKey = RGB(1, 2, 3);

ATOM EnsureOverlayClass() noexcept {
  static std::once_flag once;
  static ATOM atom = 0;
  std::call_once(once, [] {
    WNDCLASSEXW window_class{};
    window_class.cbSize = sizeof(window_class);
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.lpfnWndProc = Overlay::WndProc;
    window_class.hInstance = GetModuleHandleW(nullptr);
    window_class.hbrBackground = nullptr;
    window_class.lpszClassName = kOverlayClass;
    atom = RegisterClassExW(&window_class);
    if (!atom && GetLastError() == ERROR_CLASS_ALREADY_EXISTS) atom = 1;
  });
  return atom;
}

COLORREF ToColorRef(std::uint32_t argb) noexcept {
  return RGB((argb >> 16) & 0xff, (argb >> 8) & 0xff, argb & 0xff);
}

}  // namespace

bool IsValid(const Snapshot& snapshot, const Surface& surface) noexcept {
  if (snapshot.call_id.empty() || snapshot.source_revision == 0 ||
      surface.width <= 0 || surface.height <= 0 ||
      snapshot.strokes.size() > kMaxStrokes) {
    return false;
  }
  std::size_t points = 0;
  for (const auto& stroke : snapshot.strokes) {
    if (!std::isfinite(stroke.width) || stroke.width < 0.5 ||
        stroke.width > 24 || stroke.points.empty()) {
      return false;
    }
    if (points > kMaxPoints - stroke.points.size()) return false;
    points += stroke.points.size();
    for (const auto& point : stroke.points) {
      if (!std::isfinite(point.x) || !std::isfinite(point.y) ||
          point.x < 0 || point.x > 1 || point.y < 0 || point.y > 1) {
        return false;
      }
    }
  }
  return true;
}

std::pair<int, int> ProjectPoint(const Point& point,
                                 const Surface& surface) noexcept {
  const double width = (std::max)(1, surface.width - 1);
  const double height = (std::max)(1, surface.height - 1);
  return {static_cast<int>(std::lround(point.x * width)),
          static_cast<int>(std::lround(point.y * height))};
}

Overlay::~Overlay() { Shutdown(); }

bool Overlay::Update(Snapshot snapshot, const Surface& surface) noexcept {
  if (!IsValid(snapshot, surface)) {
    Clear();
    return false;
  }
  if (snapshot.strokes.empty()) {
    Clear();
    return true;
  }
  snapshot_ = std::move(snapshot);
  surface_ = surface;
  if (!EnsureWindow()) {
    snapshot_ = {};
    surface_ = {};
    return false;
  }
  if (!SetWindowPos(window_, HWND_TOPMOST, surface.left, surface.top,
                    surface.width, surface.height,
                    SWP_NOACTIVATE | SWP_SHOWWINDOW)) {
    Clear();
    return false;
  }
  InvalidateRect(window_, nullptr, FALSE);
  UpdateWindow(window_);
  return true;
}

void Overlay::Clear() noexcept {
  snapshot_ = {};
  surface_ = {};
  if (window_) ShowWindow(window_, SW_HIDE);
}

void Overlay::Shutdown() noexcept {
  snapshot_ = {};
  surface_ = {};
  if (window_) DestroyWindow(window_);
  window_ = nullptr;
}

bool Overlay::visible() const noexcept {
  return window_ && IsWindowVisible(window_);
}

bool Overlay::EnsureWindow() noexcept {
  if (window_ && IsWindow(window_)) return true;
  window_ = nullptr;
  if (!EnsureOverlayClass()) return false;
  const DWORD ex_style = WS_EX_LAYERED | WS_EX_TRANSPARENT |
      WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TOPMOST;
  window_ = CreateWindowExW(ex_style, kOverlayClass, L"", WS_POPUP, 0, 0, 1,
                            1, nullptr, nullptr, GetModuleHandleW(nullptr),
                            this);
  if (!window_) return false;
  if (!SetLayeredWindowAttributes(window_, kTransparentKey, 0,
                                  LWA_COLORKEY)) {
    DestroyWindow(window_);
    window_ = nullptr;
    return false;
  }
  return true;
}

void Overlay::Paint(HWND window) noexcept {
  PAINTSTRUCT paint{};
  HDC dc = BeginPaint(window, &paint);
  if (!dc) return;
  RECT client{};
  GetClientRect(window, &client);
  HBRUSH background = CreateSolidBrush(kTransparentKey);
  if (background) {
    FillRect(dc, &client, background);
    DeleteObject(background);
  }
  SetBkMode(dc, TRANSPARENT);
  for (const auto& stroke : snapshot_.strokes) {
    const COLORREF color = ToColorRef(stroke.argb);
    const int width =
        std::clamp(static_cast<int>(std::lround(stroke.width)), 1, 24);
    HPEN pen = CreatePen(PS_SOLID, width, color);
    if (!pen) continue;
    const HGDIOBJ old_pen = SelectObject(dc, pen);
    const auto first = ProjectPoint(stroke.points.front(), surface_);
    if (stroke.points.size() == 1) {
      HBRUSH brush = CreateSolidBrush(color);
      const HGDIOBJ old_brush = brush ? SelectObject(dc, brush) : nullptr;
      const int radius = (std::max)(1, width);
      Ellipse(dc, first.first - radius, first.second - radius,
              first.first + radius + 1, first.second + radius + 1);
      if (old_brush) SelectObject(dc, old_brush);
      if (brush) DeleteObject(brush);
    } else {
      MoveToEx(dc, first.first, first.second, nullptr);
      for (std::size_t index = 1; index < stroke.points.size(); ++index) {
        const auto point = ProjectPoint(stroke.points[index], surface_);
        LineTo(dc, point.first, point.second);
      }
    }
    SelectObject(dc, old_pen);
    DeleteObject(pen);
  }
  EndPaint(window, &paint);
}

LRESULT CALLBACK Overlay::WndProc(HWND window, UINT message, WPARAM wparam,
                                  LPARAM lparam) noexcept {
  Overlay* overlay =
      reinterpret_cast<Overlay*>(GetWindowLongPtrW(window, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    const auto* create = reinterpret_cast<const CREATESTRUCTW*>(lparam);
    overlay = static_cast<Overlay*>(create->lpCreateParams);
    SetWindowLongPtrW(window, GWLP_USERDATA,
                      reinterpret_cast<LONG_PTR>(overlay));
  }
  switch (message) {
    case WM_NCHITTEST:
      return HTTRANSPARENT;
    case WM_MOUSEACTIVATE:
      return MA_NOACTIVATE;
    case WM_ERASEBKGND:
      return 1;
    case WM_PAINT:
      if (overlay) {
        overlay->Paint(window);
        return 0;
      }
      break;
    case WM_NCDESTROY:
      SetWindowLongPtrW(window, GWLP_USERDATA, 0);
      break;
  }
  return DefWindowProcW(window, message, wparam, lparam);
}

}  // namespace sybl::annotation
