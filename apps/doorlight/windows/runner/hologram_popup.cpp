#include "hologram_popup.h"
#include "resource.h"
#include "window_capture_protection.h"
#include <mmsystem.h>
#include <shellapi.h>
#include <wincodec.h>
#include <wtsapi32.h>
#include <wrl/client.h>
#include <algorithm>
#include <array>

namespace {
constexpr DWORD kExcludeFromCapture = 0x11;
constexpr wchar_t kClass[] = L"SybLPrivateHologram";
constexpr UINT_PTR kTimer = 1;
using Microsoft::WRL::ComPtr;
bool DefaultInputDesktop() {
  const auto desktop = OpenInputDesktop(0, FALSE, DESKTOP_READOBJECTS);
  if (!desktop) return false;
  std::array<wchar_t, 64> name{};
  DWORD needed = 0;
  const bool ok = GetUserObjectInformationW(desktop, UOI_NAME, name.data(),
      static_cast<DWORD>(sizeof(name)), &needed) != FALSE &&
      needed <= sizeof(name) && wcscmp(name.data(), L"Default") == 0;
  CloseDesktop(desktop);
  return ok;
}
}

HologramPopup::~HologramPopup() { Cancel(); }

bool HologramPopup::EnvironmentAllows(HWND main_window) {
  return IsWindow(main_window) && (!IsWindowVisible(main_window) || IsIconic(main_window)) && SessionAllows();
}

bool HologramPopup::SessionAllows() {
  if (!DefaultInputDesktop()) return false;
  QUERY_USER_NOTIFICATION_STATE notification = QUNS_NOT_PRESENT;
  if (FAILED(SHQueryUserNotificationState(&notification)) || notification != QUNS_ACCEPTS_NOTIFICATIONS)
    return false;
  DWORD session = 0, bytes = 0;
  LPWSTR buffer = nullptr;
  if (!ProcessIdToSessionId(GetCurrentProcessId(), &session) ||
      !WTSQuerySessionInformationW(WTS_CURRENT_SERVER_HANDLE, session, WTSConnectState, &buffer, &bytes))
    return false;
  const bool active = bytes == sizeof(WTS_CONNECTSTATE_CLASS) && buffer &&
      *reinterpret_cast<WTS_CONNECTSTATE_CLASS*>(buffer) == WTSActive;
  if (buffer) WTSFreeMemory(buffer);
  return active;
}

bool HologramPopup::Protected() const {
  return window_ && QueryWindowCaptureProtection(window_, WindowCaptureProtection::kUnavailable) ==
      WindowCaptureProtection::kExclude;
}

bool HologramPopup::LoadPixels(int size) {
  const auto instance = GetModuleHandleW(nullptr);
  const auto resource = FindResourceW(instance, MAKEINTRESOURCEW(IDR_HOLOGRAM_PNG), RT_RCDATA);
  if (!resource) return false;
  const DWORD bytes = SizeofResource(instance, resource);
  const auto loaded = LoadResource(instance, resource);
  auto data = static_cast<BYTE*>(LockResource(loaded));
  if (!data || bytes == 0 || bytes > 1024 * 1024) return false;
  ComPtr<IWICImagingFactory> factory;
  ComPtr<IWICStream> stream;
  ComPtr<IWICBitmapDecoder> decoder;
  ComPtr<IWICBitmapFrameDecode> frame;
  ComPtr<IWICBitmapScaler> scaler;
  ComPtr<IWICFormatConverter> converter;
  if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
      IID_PPV_ARGS(&factory))) || FAILED(factory->CreateStream(&stream)) ||
      FAILED(stream->InitializeFromMemory(data, bytes)) ||
      FAILED(factory->CreateDecoderFromStream(stream.Get(), nullptr, WICDecodeMetadataCacheOnLoad, &decoder)))
    return false;
  UINT frames = 0, width = 0, height = 0;
  if (FAILED(decoder->GetFrameCount(&frames)) || frames != 1 ||
      FAILED(decoder->GetFrame(0, &frame)) || FAILED(frame->GetSize(&width, &height)) ||
      width != 512 || height != 512 || FAILED(factory->CreateBitmapScaler(&scaler)) ||
      FAILED(scaler->Initialize(frame.Get(), static_cast<UINT>(size), static_cast<UINT>(size), WICBitmapInterpolationModeFant)) ||
      FAILED(factory->CreateFormatConverter(&converter)) ||
      FAILED(converter->Initialize(scaler.Get(), GUID_WICPixelFormat32bppPBGRA,
        WICBitmapDitherTypeNone, nullptr, 0, WICBitmapPaletteTypeCustom))) return false;
  BITMAPINFO info{};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = size;
  info.bmiHeader.biHeight = -size;
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  void* target = nullptr;
  pixels_ = CreateCompatibleDC(nullptr);
  if (!pixels_) return false;
  bitmap_ = CreateDIBSection(pixels_, &info, DIB_RGB_COLORS, &target, nullptr, 0);
  if (!bitmap_ || !target) return false;
  old_bitmap_ = SelectObject(pixels_, bitmap_);
  if (!old_bitmap_ || old_bitmap_ == HGDI_ERROR) return false;
  return SUCCEEDED(converter->CopyPixels(nullptr, static_cast<UINT>(size * 4),
      static_cast<UINT>(size * size * 4), static_cast<BYTE*>(target)));
}

bool HologramPopup::Draw(BYTE opacity) {
  if (!Protected()) return false;
  POINT origin{};
  BLENDFUNCTION blend{AC_SRC_OVER, 0, opacity, AC_SRC_ALPHA};
  return UpdateLayeredWindow(window_, nullptr, &position_, &size_, pixels_, &origin,
      0, &blend, ULW_ALPHA) != FALSE;
}

bool HologramPopup::Show(HWND main_window, bool reduced_motion, std::function<bool()> still_allowed) {
  if (window_ || !still_allowed || !still_allowed() || !EnvironmentAllows(main_window)) return false;
  main_ = main_window;
  still_allowed_ = std::move(still_allowed);
  WNDCLASSEXW wc{};
  wc.cbSize = sizeof(wc);
  wc.hInstance = GetModuleHandleW(nullptr);
  wc.lpfnWndProc = WindowProc;
  wc.lpszClassName = kClass;
  if (!RegisterClassExW(&wc) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) { Cancel(); return false; }
  MONITORINFO monitor{};
  monitor.cbSize = sizeof(monitor);
  if (!GetMonitorInfoW(MonitorFromWindow(main_, MONITOR_DEFAULTTONEAREST), &monitor)) { Cancel(); return false; }
  const UINT dpi = GetDpiForWindow(main_);
  if (dpi == 0 || dpi > 768) { Cancel(); return false; }
  const int size = MulDiv(192, static_cast<int>(dpi), 96);
  const int margin = MulDiv(24, static_cast<int>(dpi), 96);
  size_ = {size, size};
  position_ = {monitor.rcWork.right - margin - size, monitor.rcWork.bottom - margin - size};
  if (position_.x < monitor.rcWork.left || position_.y < monitor.rcWork.top) { Cancel(); return false; }
  window_ = CreateWindowExW(WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_LAYERED | WS_EX_TRANSPARENT,
      kClass, L"", WS_POPUP, position_.x, position_.y, size, size, nullptr, nullptr, wc.hInstance, this);
  // No pixels are decoded, uploaded, or shown before verified exclusion.
  if (!window_ || !SetWindowDisplayAffinity(window_, kExcludeFromCapture) || !Protected() ||
      !LoadPixels(size) || !still_allowed_() || !EnvironmentAllows(main_)) { Cancel(); return false; }
  // Motion is controlled by Doorlight's own setting, independently of Windows.
  reduced_motion_ = reduced_motion;
  if (!Draw(reduced_motion_ ? 255 : 0) || !WTSRegisterSessionNotification(window_, NOTIFY_FOR_THIS_SESSION) ||
      !SetTimer(window_, kTimer, 16, nullptr)) { Cancel(); return false; }
  started_ = GetTickCount64();
  if (!SetWindowPos(window_, HWND_TOPMOST, position_.x, position_.y, size, size,
      SWP_NOACTIVATE | SWP_SHOWWINDOW)) { Cancel(); return false; }
  // Same native presentation turn as the first fade frame; no delayed media loading.
  sounding_ = PlaySoundW(MAKEINTRESOURCEW(IDR_HOLOGRAM_SOUND), wc.hInstance,
      SND_RESOURCE | SND_ASYNC | SND_NODEFAULT) != FALSE;
  return true;
}

void HologramPopup::Tick() {
  if (!window_) return;
  if (!still_allowed_ || !still_allowed_() || !EnvironmentAllows(main_) || !Protected()) { Cancel(); return; }
  const auto elapsed = GetTickCount64() - started_;
  const ULONGLONG duration = reduced_motion_ ? 3000 : 3350;
  if (elapsed >= duration) { Cancel(); return; }
  BYTE alpha = 255;
  if (!reduced_motion_) {
    if (elapsed < 150) alpha = static_cast<BYTE>(elapsed * 255 / 150);
    else if (elapsed >= 3150) alpha = static_cast<BYTE>((3350 - elapsed) * 255 / 200);
  }
  if (!Draw(alpha)) Cancel();
}

void HologramPopup::Cancel() {
  if (sounding_) { PlaySoundW(nullptr, nullptr, 0); sounding_ = false; }
  if (window_) {
    const auto window = window_;
    window_ = nullptr;
    KillTimer(window, kTimer);
    WTSUnRegisterSessionNotification(window);
    DestroyWindow(window);
  }
  if (pixels_ && old_bitmap_ && old_bitmap_ != HGDI_ERROR) SelectObject(pixels_, old_bitmap_);
  old_bitmap_ = nullptr;
  if (bitmap_) { DeleteObject(bitmap_); bitmap_ = nullptr; }
  if (pixels_) { DeleteDC(pixels_); pixels_ = nullptr; }
  still_allowed_ = nullptr;
  main_ = nullptr;
}

LRESULT CALLBACK HologramPopup::WindowProc(HWND window, UINT message, WPARAM wp, LPARAM lp) {
  auto self = reinterpret_cast<HologramPopup*>(GetWindowLongPtrW(window, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    self = static_cast<HologramPopup*>(reinterpret_cast<CREATESTRUCTW*>(lp)->lpCreateParams);
    SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
  }
  if (message == WM_NCHITTEST) return HTTRANSPARENT;
  if (message == WM_MOUSEACTIVATE) return MA_NOACTIVATE;
  if (self && message == WM_TIMER && wp == kTimer) { self->Tick(); return 0; }
  if (self && (message == WM_WTSSESSION_CHANGE || message == WM_DISPLAYCHANGE || message == WM_CLOSE)) {
    self->Cancel(); return 0;
  }
  return DefWindowProcW(window, message, wp, lp);
}
