#include <windows.h>
#include <dwmapi.h>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <initializer_list>
#include "window_dismiss.h"

namespace {
constexpr uint32_t kRed = 0x00ff0000;
constexpr uint32_t kBlue = 0x000000ff;
constexpr int kSample = 8;
bool Present() {
  const ULONGLONG until = GetTickCount64() + 150;
  do {
    MSG message{};
    while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
      TranslateMessage(&message);
      DispatchMessageW(&message);
    }
    Sleep(5);
  } while (GetTickCount64() < until);
  return SUCCEEDED(DwmFlush());
}
LRESULT CALLBACK BackdropProc(HWND window, UINT message, WPARAM wp, LPARAM lp) {
  if (message == WM_PAINT) {
    PAINTSTRUCT paint{};
    HDC dc = BeginPaint(window, &paint);
    HBRUSH brush = CreateSolidBrush(RGB(0, 0, 255));
    FillRect(dc, &paint.rcPaint, brush);
    DeleteObject(brush);
    EndPaint(window, &paint);
    return 0;
  }
  return DefWindowProcW(window, message, wp, lp);
}
struct Bitmap {
  HDC dc = nullptr;
  HBITMAP bitmap = nullptr;
  HGDIOBJ old = nullptr;
  uint32_t* pixels = nullptr;
  int count = 0;
  explicit Bitmap(int side) : count(side * side) {
    dc = CreateCompatibleDC(nullptr);
    BITMAPINFO info{};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = side;
    info.bmiHeader.biHeight = -side;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    bitmap = CreateDIBSection(dc, &info, DIB_RGB_COLORS,
        reinterpret_cast<void**>(&pixels), nullptr, 0);
    if (dc && bitmap && pixels) old = SelectObject(dc, bitmap);
  }
  bool valid() const { return dc && bitmap && pixels && old && old != HGDI_ERROR; }
  ~Bitmap() {
    if (pixels) SecureZeroMemory(pixels, count * sizeof(uint32_t));
    if (dc && old && old != HGDI_ERROR) SelectObject(dc, old);
    if (bitmap) DeleteObject(bitmap);
    if (dc) DeleteDC(dc);
  }
};
bool Check(bool ok, const char* label) {
  std::printf("%s %s\n", ok ? "PASS" : "FAIL", label);
  return ok;
}
bool Protected(HWND window, DWORD requested) {
  DWORD actual = 0xdeadbeef;
  SetLastError(ERROR_SUCCESS);
  const BOOL set = SetWindowDisplayAffinity(window, requested);
  const DWORD set_error = GetLastError();
  SetLastError(ERROR_SUCCESS);
  const BOOL get = GetWindowDisplayAffinity(window, &actual);
  const DWORD get_error = GetLastError();
  std::printf("affinity requested=0x%lx set=%d set_error=%lu get=%d get_error=%lu exact=%d hidden=%d\n",
      requested, set != FALSE, set_error, get != FALSE, get_error,
      actual == requested, IsWindowVisible(window) == FALSE);
  return set && get && actual == requested && !IsWindowVisible(window);
}
// Check every sampled point before and after the screen copy. Never save or
// print pixels. The only accepted foreground HWNDs are this process's fixtures.
bool OwnedSample(HWND backdrop, HWND overlay, POINT position) {
  for (int y = 0; y < kSample; ++y) {
    for (int x = 0; x < kSample; ++x) {
      HWND hit = WindowFromPoint(POINT{position.x + x, position.y + y});
      if (hit != backdrop && hit != overlay) return false;
      DWORD process = 0;
      GetWindowThreadProcessId(hit, &process);
      if (process != GetCurrentProcessId()) return false;
    }
  }
  return true;
}
bool CaptureEquals(HWND backdrop, HWND overlay, POINT position, uint32_t expected) {
  if (!OwnedSample(backdrop, overlay, position)) return Check(false, "capture scope owned before copy");
  Bitmap sample(kSample);
  if (!sample.valid()) return Check(false, "allocate bounded capture");
  HDC screen = GetDC(nullptr);
  const BOOL copied = screen && BitBlt(sample.dc, 0, 0, kSample, kSample,
      screen, position.x, position.y, SRCCOPY | CAPTUREBLT);
  if (screen) ReleaseDC(nullptr, screen);
  if (!copied || !OwnedSample(backdrop, overlay, position))
    return Check(false, "capture copied only owned region");
  GdiFlush();
  for (int i = 0; i < sample.count; ++i)
    if ((sample.pixels[i] & 0xffffff) != expected) return false;
  return true;
}
bool Case(HINSTANCE instance, HWND backdrop, POINT origin, DWORD affinity, bool prime) {
  std::printf("capture_case affinity=0x%lx zero_prime=%d\n", affinity, prime);
  HWND overlay = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TRANSPARENT,
      L"STATIC", L"", WS_POPUP, origin.x + 16, origin.y + 16, 64, 64,
      nullptr, nullptr, instance, nullptr);
  if (!overlay) return Check(false, "create hidden nonlayered fixture");
  bool ok = Protected(overlay, affinity);
  if (ok) {
    const auto style = GetWindowLongPtrW(overlay, GWL_EXSTYLE);
    SetLastError(ERROR_SUCCESS);
    const auto previous = SetWindowLongPtrW(overlay, GWL_EXSTYLE, style | WS_EX_LAYERED);
    const DWORD error = GetLastError();
    ok = (previous != 0 || error == ERROR_SUCCESS) &&
        (GetWindowLongPtrW(overlay, GWL_EXSTYLE) & WS_EX_LAYERED) &&
        SetWindowPos(overlay, nullptr, 0, 0, 0, 0,
            SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    Check(ok, "enable layered style while hidden");
  }
  if (ok && prime) {
    Bitmap blank(64);
    ok = blank.valid();
    if (ok) {
      SecureZeroMemory(blank.pixels, blank.count * sizeof(uint32_t));
      POINT position{origin.x + 16, origin.y + 16}, source{};
      SIZE size{64, 64};
      BLENDFUNCTION blend{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
      ok = !IsWindowVisible(overlay) && UpdateLayeredWindow(overlay, nullptr,
          &position, &size, blank.dc, &source, 0, &blend, ULW_ALPHA) &&
          !IsWindowVisible(overlay);
    }
    Check(ok, "prime hidden final style with only zero RGBA pixels");
  }
  if (ok) ok = Protected(overlay, affinity); // Reapply on the FINAL style, not readback alone.
  Bitmap red(64);
  if (ok) ok = red.valid();
  if (ok) {
    for (int i = 0; i < red.count; ++i) red.pixels[i] = 0xffff0000;
    POINT position{origin.x + 16, origin.y + 16}, source{};
    SIZE size{64, 64};
    BLENDFUNCTION blend{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
    ok = UpdateLayeredWindow(overlay, nullptr, &position, &size,
        red.dc, &source, 0, &blend, ULW_ALPHA) != FALSE;
    Check(ok, "submit only synthetic red after confirmed final protection");
  }
  if (ok) {
    ok = SetWindowPos(overlay, HWND_TOPMOST, 0, 0, 0, 0,
        SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW) != FALSE;
    ok = ok && Present() && IsWindowVisible(overlay);
    const POINT sample{origin.x + 32, origin.y + 32};
    const auto expected = affinity == WDA_NONE ? kRed : affinity == WDA_MONITOR ? 0u : kBlue;
    if (ok) ok = CaptureEquals(backdrop, overlay, sample, expected);
    Check(ok, affinity == WDA_NONE ? "CAPTUREBLT includes unprotected red positive control" :
        affinity == WDA_MONITOR ? "CAPTUREBLT returns black for monitor protection" :
        "CAPTUREBLT excludes overlay and returns known blue backdrop");
  }
  DestroyWindow(overlay);
  DwmFlush();
  return ok;
}
struct OverlaySearch { HWND found = nullptr; unsigned count = 0; };
BOOL CALLBACK FindOverlay(HWND window, LPARAM context) {
  DWORD process = 0;
  const DWORD thread = GetWindowThreadProcessId(window, &process);
  wchar_t name[128]{};
  if (process == GetCurrentProcessId() && thread == GetCurrentThreadId() &&
      GetClassNameW(window, name, 128) && wcscmp(name, L"DoorlightWindowDismiss") == 0) {
    auto& search = *reinterpret_cast<OverlaySearch*>(context);
    search.found = window;
    ++search.count;
  }
  return TRUE;
}
bool ProductionCase(HINSTANCE instance, HWND backdrop, POINT origin, DWORD affinity) {
  std::printf("production_capture_case affinity=0x%lx\n", affinity);
  HWND owner = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW |
      WS_EX_NOACTIVATE | WS_EX_TRANSPARENT,
      L"DoorlightCaptureDiagnosticBackdrop", L"", WS_POPUP,
      origin.x + 16, origin.y + 16, 64, 64, nullptr, nullptr, instance, nullptr);
  if (!owner) return Check(false, "create synthetic production owner");
  bool ok = Protected(owner, affinity);
  if (ok) ok = SetWindowPos(owner, HWND_TOPMOST, 0, 0, 0, 0,
      SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW) && Present();
  sybl::window::WindowDismissEffect effect;
  std::vector<uint8_t> rgba(64 * 64 * 4, 0);
  for (size_t i = 0; i < rgba.size(); i += 4) {
    rgba[i] = 255;
    rgba[i + 3] = 255;
  }
  if (ok) {
    ok = effect.Start(owner, 64, 64, rgba, POINT{origin.x + 48, origin.y + 48},
        sybl::window::DismissStyle::kTray, [](bool) {}, false, 800);
    std::printf("production Start=%d failure=%d\n", ok, effect.failure());
  }
  if (ok) ok = Present();
  OverlaySearch search;
  if (ok) {
    ok = EnumThreadWindows(GetCurrentThreadId(), FindOverlay,
        reinterpret_cast<LPARAM>(&search)) && search.count == 1;
    Check(ok, "find unique production overlay on current thread and process");
  }
  if (ok) {
    DWORD actual = ~affinity, cloak = 0;
    RECT bounds{}, background{};
    ok = GetWindowDisplayAffinity(search.found, &actual) && actual == affinity &&
        GetWindowRect(search.found, &bounds) && GetWindowRect(backdrop, &background) &&
        bounds.right - bounds.left >= kSample && bounds.bottom - bounds.top >= kSample &&
        bounds.left >= background.left && bounds.top >= background.top &&
        bounds.right <= background.right && bounds.bottom <= background.bottom &&
        SUCCEEDED(DwmGetWindowAttribute(owner, DWMWA_CLOAKED, &cloak, sizeof(cloak))) &&
        (cloak & DWM_CLOAKED_APP) && IsWindowVisible(search.found);
    Check(ok, "production affinity exact and source cloaked within synthetic backdrop");
    if (ok) {
      const POINT sample{(bounds.left + bounds.right - kSample) / 2,
                         (bounds.top + bounds.bottom - kSample) / 2};
      const auto expected = affinity == WDA_NONE ? kRed : affinity == WDA_MONITOR ? 0u : kBlue;
      ok = CaptureEquals(backdrop, search.found, sample, expected);
      Check(ok, affinity == WDA_NONE ? "production CAPTUREBLT includes red positive control" :
          affinity == WDA_MONITOR ? "production CAPTUREBLT returns black" :
          "production CAPTUREBLT returns blue backdrop");
    }
  }
  effect.Reset();
  DWORD retained = ~affinity;
  const bool retained_ok = GetWindowDisplayAffinity(owner, &retained) && retained == affinity;
  Check(retained_ok, "production cleanup retains source affinity");
  DestroyWindow(owner);
  SecureZeroMemory(rgba.data(), rgba.size());
  Present();
  return ok && retained_ok;
}
}
int main() {
  std::setvbuf(stdout, nullptr, _IONBF, 0);
  std::puts("capture_probe_started");
  SetProcessDPIAware(); // This synthetic process only; no OS setting is changed.
  const HINSTANCE instance = GetModuleHandleW(nullptr);
  WNDCLASSW wc{};
  wc.lpfnWndProc = BackdropProc;
  wc.hInstance = instance;
  wc.lpszClassName = L"DoorlightCaptureDiagnosticBackdrop";
  if (!RegisterClassW(&wc)) return 2;
  MONITORINFO monitor{sizeof(monitor)};
  if (!GetMonitorInfoW(MonitorFromPoint(POINT{0, 0}, MONITOR_DEFAULTTOPRIMARY), &monitor)) return 2;
  const POINT origin{monitor.rcWork.left + 32, monitor.rcWork.top + 32};
  HWND backdrop = CreateWindowExW(WS_EX_TOPMOST | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW,
      wc.lpszClassName, L"", WS_POPUP, origin.x, origin.y, 96, 96,
      nullptr, nullptr, instance, nullptr);
  if (!backdrop) return 2;
  bool ok = SetWindowPos(backdrop, HWND_TOPMOST, 0, 0, 0, 0,
      SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW) != FALSE;
  InvalidateRect(backdrop, nullptr, FALSE);
  UpdateWindow(backdrop);
  ok = ok && Present();
  if (ok) ok = Check(CaptureEquals(backdrop, nullptr, POINT{origin.x + 32, origin.y + 32}, kBlue),
      "known opaque blue backdrop positive control");
  const bool backdrop_ready = ok;
  if (backdrop_ready) {
    for (bool prime : {false, true}) {
      for (DWORD affinity : {DWORD(WDA_NONE), DWORD(WDA_MONITOR), DWORD(0x11)}) {
        const bool passed = Case(instance, backdrop, origin, affinity, prime);
        ok = passed && ok;
      }
    }
  }
  if (backdrop_ready) {
    for (DWORD affinity : {DWORD(WDA_NONE), DWORD(WDA_MONITOR), DWORD(0x11)}) {
      const bool passed = ProductionCase(instance, backdrop, origin, affinity);
      ok = passed && ok;
    }
  }
  DestroyWindow(backdrop);
  std::printf("capture_probe_completed ok=%d\n", ok);
  if (std::fflush(stdout) != 0 || std::ferror(stdout)) return 2;
  return ok ? 0 : 1;
}
