#include "window_dismiss.h"

#include <UIAutomation.h>
#include <dwmapi.h>
#include <wrl/client.h>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <string>

namespace sybl::window {
namespace {
using Microsoft::WRL::ComPtr;
constexpr wchar_t kEffectClass[] = L"DoorlightWindowDismiss";

BOOL CALLBACK FindTaskbars(HWND window, LPARAM parameter) {
  wchar_t name[64]{};
  GetClassNameW(window, name, 64);
  if (wcscmp(name, L"Shell_TrayWnd") == 0 ||
      wcscmp(name, L"Shell_SecondaryTrayWnd") == 0)
    reinterpret_cast<std::vector<HWND>*>(parameter)->push_back(window);
  return TRUE;
}

uint32_t BlendPixels(uint32_t a, uint32_t b, unsigned weight) noexcept {
  const auto rb = (((a & 0x00ff00ff) * (256 - weight) +
      (b & 0x00ff00ff) * weight) >> 8) & 0x00ff00ff;
  const auto ag = (((a >> 8) & 0x00ff00ff) * (256 - weight) +
      ((b >> 8) & 0x00ff00ff) * weight) & 0xff00ff00;
  return rb | ag;
}

double Ease(double progress) noexcept {
  const double t = std::clamp(progress, 0.0, 1.0);
  return t * t * (3 - 2 * t);
}
}  // namespace

TaskbarTarget::TaskbarTarget() : worker_([this] { Run(); }) {}
TaskbarTarget::~TaskbarTarget() {
  { std::lock_guard<std::mutex> lock(mutex_); stop_ = true; }
  wake_.notify_one();
  worker_.join();
}

void TaskbarTarget::Refresh() {
  { std::lock_guard<std::mutex> lock(mutex_); ++requested_; }
  wake_.notify_all();
}

void TaskbarTarget::Run() {
  if (FAILED(CoInitializeEx(nullptr, COINIT_MULTITHREADED))) return;
  ComPtr<IUIAutomation> automation;
  if (SUCCEEDED(CoCreateInstance(CLSID_CUIAutomation8, nullptr,
      CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&automation)))) {
    ComPtr<IUIAutomation2> bounded;
    if (SUCCEEDED(automation.As(&bounded))) {
      bounded->put_ConnectionTimeout(200);
      bounded->put_TransactionTimeout(200);
    }
    wchar_t path[32768]{};
    const DWORD length = GetModuleFileNameW(nullptr, path, 32768);
    const std::wstring appid = L"Appid: " + std::wstring(path, length);
    VARIANT value{};
    value.vt = VT_BSTR;
    value.bstrVal = SysAllocString(appid.c_str());
    ComPtr<IUIAutomationCondition> condition;
    automation->CreatePropertyCondition(UIA_AutomationIdPropertyId, value, &condition);
    VariantClear(&value);
    while (condition) {
      uint64_t request;
      { std::lock_guard<std::mutex> lock(mutex_); request = requested_; }
      std::vector<HWND> taskbars;
      EnumWindows(FindTaskbars, reinterpret_cast<LPARAM>(&taskbars));
      std::vector<RECT> buttons;
      for (HWND taskbar : taskbars) {
        ComPtr<IUIAutomationElement> root;
        ComPtr<IUIAutomationElementArray> matches;
        if (FAILED(automation->ElementFromHandle(taskbar, &root)) ||
            FAILED(root->FindAll(TreeScope_Descendants, condition.Get(), &matches))) continue;
        int count = 0;
        matches->get_Length(&count);
        for (int i = 0; i < (std::min)(count, 16); ++i) {
          ComPtr<IUIAutomationElement> button;
          RECT rect{};
          BOOL offscreen = TRUE;
          if (SUCCEEDED(matches->GetElement(i, &button)) &&
              SUCCEEDED(button->get_CurrentBoundingRectangle(&rect)) &&
              SUCCEEDED(button->get_CurrentIsOffscreen(&offscreen)) && !offscreen &&
              rect.right > rect.left && rect.bottom > rect.top)
            buttons.push_back(rect);
        }
      }
      std::unique_lock<std::mutex> lock(mutex_);
      buttons_ = std::move(buttons);
      completed_ = request;
      wake_.notify_all();
      wake_.wait_for(lock, std::chrono::seconds(3), [this, request] {
        return stop_ || requested_ != request;
      });
      if (stop_) break;
    }
  }
  automation.Reset();
  CoUninitialize();
}

POINT TaskbarTarget::ForWindow(HWND window) {
  const HMONITOR monitor = MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST);
  std::unique_lock<std::mutex> lock(mutex_);
  // Refresh runs alongside Flutter's frame capture. Never use pre-click bounds
  // after centered taskbar buttons moved; a slow shell gets the honest fallback.
  const bool fresh = wake_.wait_for(lock, std::chrono::milliseconds(40), [this] {
    return completed_ >= requested_ || stop_;
  });
  const RECT* unique = nullptr;
  bool ambiguous = false;
  for (const RECT& button : buttons_) {
    if (fresh && MonitorFromRect(&button, MONITOR_DEFAULTTONEAREST) == monitor) {
      if (unique) { ambiguous = true; break; }
      unique = &button;
    }
  }
  if (unique && !ambiguous)
    return {(unique->left + unique->right) / 2, (unique->top + unique->bottom) / 2};
  MONITORINFO info{sizeof(info)};
  if (!GetMonitorInfoW(monitor, &info)) return {};
  // Auto-hidden/grouped/unavailable buttons still travel to this taskbar edge.
  std::vector<HWND> taskbars;
  EnumWindows(FindTaskbars, reinterpret_cast<LPARAM>(&taskbars));
  for (HWND taskbar : taskbars) {
    RECT bar{};
    if (MonitorFromWindow(taskbar, MONITOR_DEFAULTTONEAREST) == monitor &&
        GetWindowRect(taskbar, &bar)) {
      return {std::clamp((bar.left + bar.right) / 2,
                  info.rcMonitor.left + 2, info.rcMonitor.right - 2),
              std::clamp((bar.top + bar.bottom) / 2,
                  info.rcMonitor.top + 2, info.rcMonitor.bottom - 2)};
    }
  }
  POINT point{(info.rcWork.left + info.rcWork.right) / 2, info.rcMonitor.bottom - 2};
  if (info.rcWork.left > info.rcMonitor.left) point = {info.rcMonitor.left + 2,
      (info.rcWork.top + info.rcWork.bottom) / 2};
  else if (info.rcWork.top > info.rcMonitor.top) point = {
      (info.rcWork.left + info.rcWork.right) / 2, info.rcMonitor.top + 2};
  else if (info.rcWork.right < info.rcMonitor.right) point = {
      info.rcMonitor.right - 2, (info.rcWork.top + info.rcWork.bottom) / 2};
  return point;
}

bool IsOverlappingForeignWindow(HWND owner, HWND other) noexcept {
  if (!IsWindow(owner) || !IsWindow(other) || !IsWindowVisible(owner) ||
      !IsWindowVisible(other) || IsIconic(owner) || IsIconic(other)) return false;
  other = GetAncestor(other, GA_ROOT);
  DWORD owner_pid = 0, other_pid = 0;
  GetWindowThreadProcessId(owner, &owner_pid);
  GetWindowThreadProcessId(other, &other_pid);
  if (!other_pid || owner_pid == other_pid || other == GetShellWindow() ||
      other == GetDesktopWindow()) return false;
  const auto other_style = GetWindowLongPtrW(other, GWL_EXSTYLE);
  if ((other_style & (WS_EX_TOOLWINDOW | WS_EX_TRANSPARENT)) ||
      ((GetWindowLongPtrW(owner, GWL_EXSTYLE) & WS_EX_TOPMOST) &&
       !(other_style & WS_EX_TOPMOST))) return false;
  wchar_t name[64]{};
  GetClassNameW(other, name, 64);
  if (wcscmp(name, L"Shell_TrayWnd") == 0 ||
      wcscmp(name, L"Shell_SecondaryTrayWnd") == 0) return false;
  DWORD owner_cloak = 0, other_cloak = 0;
  if (FAILED(DwmGetWindowAttribute(owner, DWMWA_CLOAKED, &owner_cloak, sizeof(owner_cloak))) ||
      FAILED(DwmGetWindowAttribute(other, DWMWA_CLOAKED, &other_cloak, sizeof(other_cloak))) ||
      owner_cloak || other_cloak) return false;
  RECT source{}, covering{}, overlap{};
  return SUCCEEDED(DwmGetWindowAttribute(owner, DWMWA_EXTENDED_FRAME_BOUNDS,
             &source, sizeof(source))) &&
      SUCCEEDED(DwmGetWindowAttribute(other, DWMWA_EXTENDED_FRAME_BOUNDS,
             &covering, sizeof(covering))) && IntersectRect(&overlap, &source, &covering);
}

bool IsCoveredByAnotherWindow(HWND owner) noexcept {
  HWND other = GetWindow(owner, GW_HWNDPREV);
  for (int count = 0; other && count < 256; ++count) {
    if (IsOverlappingForeignWindow(owner, other)) return true;
    other = GetWindow(other, GW_HWNDPREV);
  }
  return false;
}

bool ValidDismissFrame(int width, int height, size_t bytes) noexcept {
  return width > 0 && height > 0 && width <= 8192 && height <= 8192 &&
      static_cast<size_t>(width) * height <= 16 * 1024 * 1024 &&
      bytes == static_cast<size_t>(width) * height * 4;
}

RECT DismissBounds(RECT source, POINT target, double progress) noexcept {
  const double t = Ease(progress);
  const double final_scale = (std::min)(1.0, 24.0 / (std::max)(
      source.right - source.left, source.bottom - source.top));
  const double scale = 1 + (final_scale - 1) * t;
  const LONG width = (std::max)(1L, static_cast<LONG>(std::lround(
      (source.right - source.left) * scale)));
  const LONG height = (std::max)(1L, static_cast<LONG>(std::lround(
      (source.bottom - source.top) * scale)));
  const double x = (source.left + source.right) * .5;
  const double y = (source.top + source.bottom) * .5;
  const LONG left = static_cast<LONG>(std::lround(x + (target.x - x) * t - width * .5));
  const LONG top = static_cast<LONG>(std::lround(y + (target.y - y) * t - height * .5));
  return {left, top, left + width, top + height};
}

void ShapeDismissFrame(std::vector<uint32_t>& pixels, int width, int height,
    double radius, COLORREF border, double thickness) noexcept {
  const bool outlined = border != DWMWA_COLOR_NONE && border != DWMWA_COLOR_DEFAULT;
  const uint32_t color = 0xff000000u | (GetRValue(border) << 16) |
      (GetGValue(border) << 8) | GetBValue(border);
  for (int y = 0; y < height; ++y) {
    for (int x = 0; x < width; ++x) {
      const double edge_x = (std::min)(x + .5, width - x - .5);
      const double edge_y = (std::min)(y + .5, height - y - .5);
      const double dx = (std::max)(radius - edge_x, 0.0);
      const double dy = (std::max)(radius - edge_y, 0.0);
      const double distance = dx > 0 && dy > 0 ? radius - std::hypot(dx, dy) :
          (std::min)(edge_x, edge_y);
      auto& pixel = pixels[static_cast<size_t>(y) * width + x];
      if (outlined) pixel = BlendPixels(pixel, color, static_cast<unsigned>(256 *
          std::clamp(thickness + .5 - distance, 0.0, 1.0)));
      const auto coverage = static_cast<unsigned>(255 * std::clamp(distance + .5, 0.0, 1.0));
      uint32_t masked = 0;
      for (unsigned shift = 0; shift < 32; shift += 8)
        masked |= (((pixel >> shift) & 255) * coverage / 255) << shift;
      pixel = masked;
    }
  }
}

double FoldOutlineDistance(double along, double across, int axis, int cross_axis,
    double cosine, double sine) noexcept {
  const double focal = axis * 1.6;
  const double span = axis * cosine * focal / (focal + axis * sine);
  const double slope = cross_axis * .5 * sine / (focal * cosine);
  return (std::min)({along, span - along,
      (cross_axis * .5 - std::abs(across) - slope * along) / std::hypot(1.0, slope)});
}

WindowDismissEffect::~WindowDismissEffect() { Reset(); }

bool WindowDismissEffect::PrepareRestore(HWND owner) {
  Reset();
  owner_ = owner;
  if (!ConcealOwner()) { Reset(); return false; }
  return true;
}

bool WindowDismissEffect::Start(HWND owner, int width, int height,
    const std::vector<std::uint8_t>& rgba, POINT target, DismissStyle style,
    std::function<void(bool)> finish, bool restoring, UINT duration_ms, bool preview) {
  if (!restoring || owner_ != owner || !cloaked_owner_) Reset();
  RECT client{};
  failure_ = 1;
  if (duration_ms < 100 || duration_ms > 800 ||
      style == DismissStyle::kNone || !ValidDismissFrame(width, height, rgba.size())) return false;
  failure_ = 2;
  if (!IsWindowVisible(owner) || IsIconic(owner)) return false;
  DWORD cloak = 0;
  if (FAILED(DwmGetWindowAttribute(owner, DWMWA_CLOAKED, &cloak, sizeof(cloak))) ||
      cloak != (cloaked_owner_ ? static_cast<DWORD>(DWM_CLOAKED_APP) : 0u)) return false;
  DWORD source_affinity = 0;
  if (!GetWindowDisplayAffinity(owner, &source_affinity) ||
      (source_affinity != WDA_NONE && source_affinity != WDA_MONITOR &&
       source_affinity != 0x11)) return false;
  failure_ = 4;
  if (!GetClientRect(owner, &client) || client.right != width || client.bottom != height) return false;
  POINT origin{};
  failure_ = 5;
  if (!ClientToScreen(owner, &origin)) return false;
  WNDCLASSW wc{};
  wc.lpfnWndProc = WindowProc;
  wc.hInstance = GetModuleHandleW(nullptr);
  wc.lpszClassName = kEffectClass;
  if (!RegisterClassW(&wc) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return false;
  owner_ = owner;
  width_ = width;
  height_ = height;
  source_bounds_ = {origin.x, origin.y, origin.x + width, origin.y + height};
  target_ = target;
  style_ = style;
  duration_ms_ = duration_ms;
  restoring_ = restoring;
  preview_round_trip_ = preview && !restoring;
  finish_ = std::move(finish);
  source_.resize(static_cast<size_t>(width) * height);
  for (size_t i = 0; i < source_.size(); ++i) {
    source_[i] = (static_cast<std::uint32_t>(rgba[i * 4 + 3]) << 24) |
        (static_cast<std::uint32_t>(rgba[i * 4]) << 16) |
        (static_cast<std::uint32_t>(rgba[i * 4 + 1]) << 8) | rgba[i * 4 + 2];
  }
  DWORD corners = 0;
  double radius = 0;
  const double scale = GetDpiForWindow(owner) / 96.0;
  if (!IsZoomed(owner) && SUCCEEDED(DwmGetWindowAttribute(owner,
      DWMWA_WINDOW_CORNER_PREFERENCE, &corners, sizeof(corners))) &&
      (corners == DWMWCP_ROUND || corners == DWMWCP_ROUNDSMALL))
    radius = (corners == DWMWCP_ROUNDSMALL ? 4.0 : 8.0) * scale;
  COLORREF border = DWMWA_COLOR_NONE;
  DwmGetWindowAttribute(owner, DWMWA_BORDER_COLOR, &border, sizeof(border));
  border_ = border;
  border_width_ = scale;
  // Flutter's frame excludes the DWM edge; carry it through the same projection.
  ShapeDismissFrame(source_, width, height, radius, border, scale);
  BITMAPINFO info{};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = width;
  info.bmiHeader.biHeight = -height;
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  dc_ = CreateCompatibleDC(nullptr);
  failure_ = 6;
  bitmap_ = CreateDIBSection(dc_, &info, DIB_RGB_COLORS,
      reinterpret_cast<void**>(&output_), nullptr, 0);
  if (!dc_ || !bitmap_) { Reset(); return false; }
  previous_ = SelectObject(dc_, bitmap_);
  if (!previous_ || previous_ == HGDI_ERROR) { Reset(); return false; }
  // The presentation has the same capture policy as its source. Applying and
  // confirming it before first show also keeps protected frames out of streams.
  overlay_ = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE |
      WS_EX_TRANSPARENT | static_cast<DWORD>(GetWindowLongPtrW(owner, GWL_EXSTYLE) & WS_EX_TOPMOST),
      kEffectClass, L"", WS_POPUP, origin.x, origin.y, width, height,
      nullptr, nullptr, wc.hInstance, this);
  DWORD affinity = 0;
  failure_ = 7;
  if (!overlay_ || !SetWindowDisplayAffinity(overlay_, source_affinity) ||
      !GetWindowDisplayAffinity(overlay_, &affinity) || affinity != source_affinity) {
    Reset(); return false;
  }
  // Set protection before layering, then confirm it again on the final style.
  // Some compositors reject affinity on a window created already layered.
  SetLastError(ERROR_SUCCESS);
  const LONG_PTR extended_style = GetWindowLongPtrW(overlay_, GWL_EXSTYLE);
  if (!extended_style && GetLastError() != ERROR_SUCCESS) { Reset(); return false; }
  SetLastError(ERROR_SUCCESS);
  if (!SetWindowLongPtrW(overlay_, GWL_EXSTYLE, extended_style | WS_EX_LAYERED) &&
      GetLastError() != ERROR_SUCCESS) { Reset(); return false; }
  if (GetWindowLongPtrW(overlay_, GWL_EXSTYLE) != (extended_style | WS_EX_LAYERED) ||
      !SetWindowPos(overlay_, nullptr, 0, 0, 0, 0,
          SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED) ||
      !SetWindowDisplayAffinity(overlay_, source_affinity) ||
      !GetWindowDisplayAffinity(overlay_, &affinity) || affinity != source_affinity ||
      IsWindowVisible(overlay_) ||
      !Paint(restoring ? 1 : 0, restoring ? 0 : 255)) { Reset(); return false; }
  // Create the timer before hiding the real surface: a failed
  // allocation must leave the ordinary window untouched for immediate fallback.
  if (!SetTimer(overlay_, 1, 8, nullptr)) { Reset(); return false; }
  failure_ = 8;
  DwmGetWindowAttribute(owner, DWMWA_TRANSITIONS_FORCEDISABLED,
      &old_transitions_, sizeof(old_transitions_));
  const BOOL disable = TRUE;
  transitions_changed_ = SUCCEEDED(DwmSetWindowAttribute(owner,
      DWMWA_TRANSITIONS_FORCEDISABLED, &disable, sizeof(disable)));
  ShowWindow(overlay_, SW_SHOWNOACTIVATE);
  if (!IsWindowVisible(overlay_) || !ConcealOwner()) { Reset(); return false; }
  started_ = GetTickCount64();
  endpoint_presented_ = 0;
  failure_ = 0;
  return true;
}

bool WindowDismissEffect::ConcealOwner() noexcept {
  if (cloaked_owner_) return true;
  DWORD cloak = 0;
  if (!IsWindow(owner_) || FAILED(DwmGetWindowAttribute(owner_, DWMWA_CLOAKED,
      &cloak, sizeof(cloak))) || cloak != 0) return false;
  // Cloaking hides the entire native frame and shadow while Flutter keeps composing.
  // The presentation is unowned so it cannot inherit the source's cloak.
  const BOOL hidden = TRUE;
  cloaked_owner_ = SUCCEEDED(DwmSetWindowAttribute(owner_, DWMWA_CLOAK,
      &hidden, sizeof(hidden)));
  return cloaked_owner_ && SUCCEEDED(DwmGetWindowAttribute(owner_, DWMWA_CLOAKED,
      &cloak, sizeof(cloak))) && (cloak & DWM_CLOAKED_APP);
}

void WindowDismissEffect::Reset() noexcept {
  if (overlay_) DestroyWindow(overlay_);
  overlay_ = nullptr;
  if (cloaked_owner_ && IsWindow(owner_)) {
    const BOOL hidden = FALSE;
    DwmSetWindowAttribute(owner_, DWMWA_CLOAK, &hidden, sizeof(hidden));
  }
  if (transitions_changed_ && IsWindow(owner_))
    DwmSetWindowAttribute(owner_, DWMWA_TRANSITIONS_FORCEDISABLED,
        &old_transitions_, sizeof(old_transitions_));
  transitions_changed_ = false;
  cloaked_owner_ = false;
  owner_ = nullptr;
  if (output_) SecureZeroMemory(output_, source_.size() * sizeof(std::uint32_t));
  if (dc_ && previous_) SelectObject(dc_, previous_);
  if (bitmap_) DeleteObject(bitmap_);
  if (dc_) DeleteDC(dc_);
  dc_ = nullptr;
  bitmap_ = nullptr;
  output_ = nullptr;
  previous_ = nullptr;
  if (!source_.empty()) SecureZeroMemory(source_.data(), source_.size() * sizeof(std::uint32_t));
  source_.clear();
  finish_ = nullptr;
}

bool WindowDismissEffect::Paint(double progress, BYTE opacity) noexcept {
  if (style_ == DismissStyle::kFade) {
    opacity = static_cast<BYTE>(opacity * (1 - Ease(progress)));
    progress = 0;
  }
  const bool door = IsFold(style_);
  const bool vertical = style_ == DismissStyle::kFoldUp || style_ == DismissStyle::kFoldDown;
  const bool reverse = style_ == DismissStyle::kFoldRight || style_ == DismissStyle::kFoldDown;
  const int axis = vertical ? height_ : width_;
  const bool warp = style_ == DismissStyle::kWarp;
  RECT bounds = DismissBounds(source_bounds_, target_, progress);
  const double angle = Ease(progress) * 1.5707963267948966;
  const double cosine = std::cos(angle), sine = std::sin(angle);
  const double focal = axis * 1.6;
  if (door) {
    bounds = source_bounds_;
    const LONG span = (std::max)(1L, static_cast<LONG>(std::ceil(
        axis * cosine * focal / (focal + axis * sine))));
    if (vertical) {
      if (reverse) bounds.top = bounds.bottom - span;
      else bounds.bottom = bounds.top + span;
    } else {
      if (reverse) bounds.left = bounds.right - span;
      else bounds.right = bounds.left + span;
    }
  }
  const int width = bounds.right - bounds.left;
  const int height = bounds.bottom - bounds.top;
  if (progress <= 0) {
    std::copy(source_.begin(), source_.end(), output_);
  } else {
    for (int y = 0; y < height; ++y)
      std::fill_n(output_ + static_cast<size_t>(y) * width_, width, 0);
    for (int x = 0; x < width; ++x) {
      for (int y = 0; y < height; ++y) {
        double u, v;
        if (door) {
          const double along = vertical ? (reverse ? height - y - .5 : y + .5) :
              (reverse ? width - x - .5 : x + .5);
          const double depth = along * focal / (focal * cosine - along * sine);
          if (!std::isfinite(depth) || depth < 0 || depth >= axis) continue;
          const double factor = focal / (focal + depth * sine);
          const double across = vertical ? (x + .5 - width_ * .5) / factor + width_ * .5 :
              (y + .5 - height_ * .5) / factor + height_ * .5;
          u = vertical ? across : (reverse ? width_ - depth : depth);
          v = vertical ? (reverse ? height_ - depth : depth) : across;
        } else {
          u = (x + .5) * width_ / width;
          const double factor = warp ? 1 - .75 * std::sin(Ease(progress) * 3.141592653589793) *
              std::sin(u / width_ * 3.141592653589793) : 1;
          v = ((y + .5) * height_ / height - height_ * .5) / factor + height_ * .5;
        }
        if (u < 0 || u >= width_ || v < 0 || v >= height_) continue;
        // Pixel-center sampling keeps the full-size endpoint identical and
        // avoids text/edge shimmer as the image grows through fractional scales.
        const double sx = std::clamp(u - .5, 0.0, width_ - 1.0);
        const double sy = std::clamp(v - .5, 0.0, height_ - 1.0);
        const int x0 = static_cast<int>(sx), y0 = static_cast<int>(sy);
        const int x1 = (std::min)(x0 + 1, width_ - 1);
        const int y1 = (std::min)(y0 + 1, height_ - 1);
        const auto fx = static_cast<unsigned>((sx - x0) * 256);
        const auto fy = static_cast<unsigned>((sy - y0) * 256);
        auto pixel = BlendPixels(
            BlendPixels(source_[static_cast<size_t>(y0) * width_ + x0],
                source_[static_cast<size_t>(y0) * width_ + x1], fx),
            BlendPixels(source_[static_cast<size_t>(y1) * width_ + x0],
                source_[static_cast<size_t>(y1) * width_ + x1], fx), fy);
        if (door && border_ != DWMWA_COLOR_NONE && border_ != DWMWA_COLOR_DEFAULT) {
          const double along = vertical ? (reverse ? height - y - .5 : y + .5) :
              (reverse ? width - x - .5 : x + .5);
          const double across = vertical ? x + .5 - width_ * .5 : y + .5 - height_ * .5;
          const double distance = FoldOutlineDistance(along, across, axis,
              vertical ? width_ : height_, cosine, sine);
          // Keep a readable edge after perspective compresses the source stroke.
          const auto alpha = pixel >> 24;
          const uint32_t color = (alpha << 24) |
              ((GetRValue(border_) * alpha / 255) << 16) |
              ((GetGValue(border_) * alpha / 255) << 8) | (GetBValue(border_) * alpha / 255);
          pixel = BlendPixels(pixel, color, static_cast<unsigned>(256 *
              std::clamp(border_width_ + .5 - distance, 0.0, 1.0)));
        }
        output_[static_cast<size_t>(y) * width_ + x] = pixel;
      }
    }
  }
  POINT position{bounds.left, bounds.top}, origin{};
  SIZE size{width, height};
  BLENDFUNCTION blend{AC_SRC_OVER, 0, opacity, AC_SRC_ALPHA};
  return UpdateLayeredWindow(overlay_, nullptr, &position, &size, dc_, &origin,
      0, &blend, ULW_ALPHA) != FALSE;
}

void WindowDismissEffect::Finish(bool completed) noexcept {
  auto finish = std::move(finish_);
  if (finish) finish(completed);
}

void WindowDismissEffect::Tick() noexcept {
  if (!IsWindow(owner_)) { Finish(false); return; }
  const auto now = GetTickCount64();
  const double progress = static_cast<double>(now - started_) / duration_ms_;
  const double position = restoring_ ? 1 - (std::min)(progress, 1.0) : progress;
  if (progress >= 1 && preview_round_trip_) {
    if (!Paint(1)) { Finish(false); return; }
    preview_round_trip_ = false;
    restoring_ = true;
    started_ = now;
    return;
  }
  if (progress >= 1 && !endpoint_presented_ &&
      (restoring_ || !IsFold(style_))) {
    if (!Paint(restoring_ ? 0 : 1)) { Finish(false); return; }
    endpoint_presented_ = now;
    if (restoring_ && cloaked_owner_) {
      // Blend the matching full-size image into the live window, never desktop.
      const BOOL hidden = FALSE;
      if (FAILED(DwmSetWindowAttribute(owner_, DWMWA_CLOAK, &hidden, sizeof(hidden)))) {
        Finish(false);
        return;
      }
      cloaked_owner_ = false;
    }
    return;
  }
  if (endpoint_presented_) {
    const auto elapsed = now - endpoint_presented_;
    if (restoring_ && elapsed < 48) {
      if (!Paint(0, static_cast<BYTE>(255 * (1 - Ease(elapsed / 48.0))))) Finish(false);
      return;
    }
    if (!restoring_ && elapsed < 16) return;
  }
  if (progress >= 1) { Finish(true); return; }
  const BYTE opacity = restoring_ && style_ != DismissStyle::kFade
      ? static_cast<BYTE>(255 * (std::min)(1.0, progress / .22)) : 255;
  if (!Paint(position, opacity)) Finish(false);
}

LRESULT CALLBACK WindowDismissEffect::WindowProc(HWND hwnd, UINT message,
    WPARAM wp, LPARAM lp) noexcept {
  if (message == WM_NCCREATE) {
    SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(
        reinterpret_cast<CREATESTRUCTW*>(lp)->lpCreateParams));
  }
  auto* self = reinterpret_cast<WindowDismissEffect*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  if (self && message == WM_TIMER) { self->Tick(); return 0; }
  return DefWindowProcW(hwnd, message, wp, lp);
}
}  // namespace sybl::window
