#include "window_dismiss.h"
#include <dwmapi.h>
#include <cstdio>
#include <cstring>

namespace {
LRESULT CALLBACK ProbeProc(HWND window, UINT message, WPARAM wp, LPARAM lp) {
  if (message == WM_PAINT) {
    PAINTSTRUCT paint{};
    HDC dc = BeginPaint(window, &paint);
    FillRect(dc, &paint.rcPaint, static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH)));
    EndPaint(window, &paint);
    return 0;
  }
  return DefWindowProcW(window, message, wp, lp);
}
bool PrimeBlank(HWND window) {
  HDC dc = CreateCompatibleDC(nullptr);
  BITMAPINFO info{};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = 2;
  info.bmiHeader.biHeight = -2;
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  void* pixels = nullptr;
  HBITMAP bitmap = CreateDIBSection(dc, &info, DIB_RGB_COLORS, &pixels, nullptr, 0);
  if (!dc || !bitmap || !pixels) {
    std::printf("blank_setup failed error=%lu\n", GetLastError());
    if (bitmap) DeleteObject(bitmap);
    if (dc) DeleteDC(dc);
    return false;
  }
  std::memset(pixels, 0, 16);
  auto previous = SelectObject(dc, bitmap);
  POINT position{100, 100}, origin{};
  SIZE size{2, 2};
  BLENDFUNCTION blend{AC_SRC_OVER, 0, 0, AC_SRC_ALPHA};
  SetLastError(ERROR_SUCCESS);
  const BOOL result = UpdateLayeredWindow(window, nullptr, &position, &size,
      dc, &origin, 0, &blend, ULW_ALPHA);
  const DWORD error = GetLastError();
  std::printf("blank_UpdateLayeredWindow ok=%d error=%lu visible=%d\n",
      result != FALSE, error, IsWindowVisible(window) != FALSE);
  SelectObject(dc, previous);
  DeleteObject(bitmap);
  DeleteDC(dc);
  return result != FALSE;
}
void Query(HWND window, const char* phase) {
  DWORD affinity = 0xdeadbeef;
  SetLastError(ERROR_SUCCESS);
  const BOOL result = GetWindowDisplayAffinity(window, &affinity);
  const DWORD error = GetLastError();
  std::printf("%s GetWindowDisplayAffinity ok=%d error=%lu affinity=0x%lx visible=%d\n",
      phase, result != FALSE, error, affinity, IsWindowVisible(window) != FALSE);
}
void Set(HWND window, DWORD affinity, const char* phase) {
  SetLastError(ERROR_SUCCESS);
  const BOOL result = SetWindowDisplayAffinity(window, affinity);
  const DWORD error = GetLastError();
  std::printf("%s SetWindowDisplayAffinity requested=0x%lx ok=%d error=%lu\n",
      phase, affinity, result != FALSE, error);
  Query(window, phase);
}

void FlushAndQuery(HWND window, const char* phase) {
  const HRESULT flush = DwmFlush();
  std::printf("%s flush_hr=0x%lx layered=%d\n", phase,
      static_cast<unsigned long>(flush),
      (GetWindowLongPtrW(window, GWL_EXSTYLE) & WS_EX_LAYERED) != 0);
  Query(window, phase);
}

bool SetLayered(HWND window, bool layered) {
  const auto before = GetWindowLongPtrW(window, GWL_EXSTYLE);
  SetLastError(ERROR_SUCCESS);
  const auto previous = SetWindowLongPtrW(window, GWL_EXSTYLE,
      layered ? before | WS_EX_LAYERED : before & ~WS_EX_LAYERED);
  const DWORD error = GetLastError();
  const bool ok = previous != 0 || error == ERROR_SUCCESS;
  std::printf("SetLayered requested=%d ok=%d error=%lu\n", layered, ok, error);
  if (!ok) return false;
  SetLastError(ERROR_SUCCESS);
  const BOOL positioned = SetWindowPos(window, nullptr, 0, 0, 0, 0,
      SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
  const DWORD positioned_error = GetLastError();
  std::printf("style_framechanged ok=%d error=%lu\n", positioned != FALSE, positioned_error);
  return positioned != FALSE;
}

bool ExpandedMatrix(const WNDCLASSW& wc, DWORD affinity) {
  const DWORD shared = WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TRANSPARENT;
  for (bool layered : {false, true}) {
    for (bool visible : {false, true}) {
      std::printf("expanded requested=0x%lx layered=%d visible=%d\n", affinity, layered, visible);
      HWND window = CreateWindowExW(shared | (layered ? WS_EX_LAYERED : 0),
          wc.lpszClassName, L"", WS_POPUP, 100, 100, 2, 2,
          nullptr, nullptr, wc.hInstance, nullptr);
      if (!window) return false;
      if (layered && !PrimeBlank(window)) { DestroyWindow(window); return false; }
      if (visible) {
        ShowWindow(window, SW_SHOWNOACTIVATE);
        if (!layered) { InvalidateRect(window, nullptr, FALSE); UpdateWindow(window); }
      }
      FlushAndQuery(window, "before_affinity");
      Set(window, affinity, "expanded_set");
      FlushAndQuery(window, "expanded_after_set");
      DestroyWindow(window);
    }
  }
  for (bool visible : {false, true}) {
    std::printf("style_transition requested=0x%lx initially_visible=%d\n", affinity, visible);
    HWND window = CreateWindowExW(shared, wc.lpszClassName, L"", WS_POPUP,
        100, 100, 2, 2, nullptr, nullptr, wc.hInstance, nullptr);
    if (!window) return false;
    if (visible) {
      ShowWindow(window, SW_SHOWNOACTIVATE);
      InvalidateRect(window, nullptr, FALSE);
      UpdateWindow(window);
    }
    Set(window, affinity, "before_layered_style");
    if (!SetLayered(window, true)) { DestroyWindow(window); return false; }
    FlushAndQuery(window, "after_layered_style_before_bitmap");
    if (!PrimeBlank(window)) { DestroyWindow(window); return false; }
    FlushAndQuery(window, "after_layered_style_and_blank");
    Set(window, affinity, "retry_after_layered_style");
    FlushAndQuery(window, "after_retry");
    if (!SetLayered(window, false)) { DestroyWindow(window); return false; }
    FlushAndQuery(window, "after_remove_layered_style");
    DestroyWindow(window);
  }
  return true;
}
}

int main() {
  BOOL composing = FALSE;
  const HRESULT composition = DwmIsCompositionEnabled(&composing);
  std::printf("composition_hr=0x%lx composing=%d remote_session=%d\n",
      static_cast<unsigned long>(composition), composing != FALSE,
      GetSystemMetrics(SM_REMOTESESSION) != 0);
  HDC desktop_dc = GetDC(nullptr);
  if (desktop_dc) {
    std::printf("display technology=%d bits=%d planes=%d raster_caps=0x%x blend_caps=0x%x monitors=%d\n",
        GetDeviceCaps(desktop_dc, TECHNOLOGY), GetDeviceCaps(desktop_dc, BITSPIXEL),
        GetDeviceCaps(desktop_dc, PLANES), GetDeviceCaps(desktop_dc, RASTERCAPS),
        GetDeviceCaps(desktop_dc, SHADEBLENDCAPS), GetSystemMetrics(SM_CMONITORS));
    ReleaseDC(nullptr, desktop_dc);
  }
  WNDCLASSW wc{};
  wc.lpfnWndProc = ProbeProc;
  wc.hInstance = GetModuleHandleW(nullptr);
  wc.lpszClassName = L"DoorlightAffinityDiagnosticFixture";
  if (!RegisterClassW(&wc)) return 2;
  for (DWORD affinity : {DWORD(WDA_NONE), DWORD(WDA_MONITOR), DWORD(0x11)}) {
    for (bool prime_first : {false, true}) {
      std::printf("matrix requested=0x%lx prime_first=%d\n", affinity, prime_first);
      HWND overlay = CreateWindowExW(WS_EX_LAYERED | WS_EX_TOOLWINDOW |
          WS_EX_NOACTIVATE | WS_EX_TRANSPARENT, wc.lpszClassName, L"",
          WS_POPUP, 100, 100, 2, 2, nullptr, nullptr, wc.hInstance, nullptr);
      if (!overlay) { std::printf("create failed=%lu\n", GetLastError()); return 2; }
      Query(overlay, "created_hidden");
      if (prime_first && !PrimeBlank(overlay)) { DestroyWindow(overlay); return 2; }
      Set(overlay, affinity, "first_set");
      if (!prime_first) {
        if (!PrimeBlank(overlay)) { DestroyWindow(overlay); return 2; }
        Query(overlay, "after_blank");
        Set(overlay, affinity, "second_set");
      }
      const HRESULT flush = DwmFlush();
      std::printf("flush_hr=0x%lx\n", static_cast<unsigned long>(flush));
      Query(overlay, "after_flush");
      if (IsWindowVisible(overlay)) { DestroyWindow(overlay); return 3; }
      DestroyWindow(overlay);
    }
    if (!ExpandedMatrix(wc, affinity)) return 2;
    HWND owner = CreateWindowExW(0, wc.lpszClassName, L"Synthetic affinity probe",
        WS_OVERLAPPEDWINDOW | WS_VISIBLE, 100, 100, 128, 96,
        nullptr, nullptr, wc.hInstance, nullptr);
    if (!owner) return 2;
    Set(owner, affinity, "synthetic_owner");
    RECT client{};
    if (!GetClientRect(owner, &client)) { DestroyWindow(owner); return 2; }
    std::vector<uint8_t> transparent(static_cast<size_t>(client.right) * client.bottom * 4, 0);
    sybl::window::WindowDismissEffect effect;
    SetLastError(ERROR_SUCCESS);
    const bool started = effect.Start(owner, client.right, client.bottom,
        transparent, POINT{100, 100}, sybl::window::DismissStyle::kTray, [](bool) {});
    std::printf("unchanged_production_Start requested=0x%lx ok=%d stage=%d last_error_after_return=%lu\n",
        affinity, started, effect.failure(), GetLastError());
    effect.Reset();
    DestroyWindow(owner);
  }
  return 0; // API failures are diagnostic observations, not relaxed production tests.
}
