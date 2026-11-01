#include "system_tray.h"

#include <windowsx.h>

#include <cwchar>
#include <algorithm>
#include <utility>

namespace {

// A stable shell identity prevents duplicate/orphaned entries when the window
// handle changes between launches. The GUID is part of Syb-L's Windows shell
// contract and must not be regenerated per build.
#ifdef SYBL_VISUAL_UAT
// The isolated host can run beside the maintained installation.
constexpr GUID kSybLTrayIconGuid{
    0x5a6c9e35, 0x4527, 0x4c49,
    {0x88, 0x43, 0xe8, 0x46, 0xc2, 0xc9, 0x9c, 0x72}};
#else
constexpr GUID kSybLTrayIconGuid{
    0x4c6c0639,
    0xceb8,
    0x477f,
    {0x85, 0xae, 0x2c, 0xf3, 0x1f, 0x3e, 0x82, 0xb2}};
#endif

}  // namespace

SystemTray::~SystemTray() {
  Shutdown();
}

POINT SystemTray::AnimationTarget() const noexcept {
  NOTIFYICONIDENTIFIER identity{sizeof(identity)};
  identity.guidItem = icon_data_.guidItem;
  RECT icon{}, bar{}, overflow{};
  const HWND taskbar = FindWindowW(L"Shell_TrayWnd", nullptr);
  const HWND flyout = FindWindowW(L"NotifyIconOverflowWindow", nullptr);
  GetWindowRect(taskbar, &bar);
  if (installed_ && SUCCEEDED(Shell_NotifyIconGetRect(&identity, &icon)) &&
      icon.right > icon.left && icon.bottom > icon.top) {
    const POINT center{(icon.left + icon.right) / 2, (icon.top + icon.bottom) / 2};
    // Hidden overflow icons can retain stale bounds. Only accept visible shell areas.
    if (PtInRect(&bar, center) || (IsWindowVisible(flyout) &&
        GetWindowRect(flyout, &overflow) && PtInRect(&overflow, center))) return center;
  }
  RECT notification{};
  const HWND tray = FindWindowExW(taskbar, nullptr, L"TrayNotifyWnd", nullptr);
  const bool visible_notification = tray && IsWindowVisible(tray) &&
      GetWindowRect(tray, &notification) && notification.right > notification.left &&
      notification.bottom > notification.top;
  if (visible_notification)
    bar = notification;
  MONITORINFO monitor{sizeof(monitor)};
  if (!GetMonitorInfoW(MonitorFromWindow(taskbar, MONITOR_DEFAULTTOPRIMARY), &monitor)) return {};
  POINT fallback{monitor.rcMonitor.right - 24, monitor.rcMonitor.bottom - 24};
  if (bar.right > bar.left && bar.bottom > bar.top)
    fallback = {visible_notification ? (bar.left + bar.right) / 2 : bar.right - 24,
                (bar.top + bar.bottom) / 2};
  fallback.x = std::clamp(fallback.x, monitor.rcMonitor.left + 2, monitor.rcMonitor.right - 2);
  fallback.y = std::clamp(fallback.y, monitor.rcMonitor.top + 2, monitor.rcMonitor.bottom - 2);
  return fallback;
}

bool SystemTray::Initialize(HWND owner,
                            UINT icon_id,
                            const wchar_t* tooltip,
                            std::function<bool()> reveal) noexcept {
  Shutdown();
  if (!owner || !::IsWindow(owner) || !tooltip || tooltip[0] == L'\0' ||
      !reveal) {
    return false;
  }

  const UINT taskbar_created =
      ::RegisterWindowMessageW(L"TaskbarCreated");
  const UINT callback_message = CallbackMessage();
  if (taskbar_created == 0 || callback_message == 0) {
    return false;
  }

  auto icon = static_cast<HICON>(::LoadImageW(
      ::GetModuleHandleW(nullptr), MAKEINTRESOURCEW(icon_id), IMAGE_ICON, 0, 0,
      LR_DEFAULTSIZE | LR_SHARED));
  if (!icon) {
    return false;
  }

  owner_ = owner;
  icon_ = icon;
  callback_message_ = callback_message;
  taskbar_created_message_ = taskbar_created;
  icon_data_ = {};
  icon_data_.cbSize = sizeof(icon_data_);
  icon_data_.hWnd = owner_;
  icon_data_.uID = 1;
  // Version 4 suppresses the standard tooltip unless NIF_SHOWTIP is explicit.
  icon_data_.uFlags =
      NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP | NIF_GUID;
  icon_data_.uCallbackMessage = callback_message_;
  icon_data_.hIcon = icon_;
  icon_data_.guidItem = kSybLTrayIconGuid;
  ::wcsncpy_s(icon_data_.szTip, tooltip, _TRUNCATE);
  reveal_ = std::move(reveal);

  return AddIcon();
}

bool SystemTray::AttachForTest(HWND owner,
                               std::function<bool()> reveal) noexcept {
  Shutdown();
  const UINT callback_message = CallbackMessage();
  if (!owner || !::IsWindow(owner) || callback_message == 0) {
    return false;
  }
  owner_ = owner;
  callback_message_ = callback_message;
  reveal_ = std::move(reveal);
  return true;
}

UINT SystemTray::CallbackMessage() noexcept {
  return ::RegisterWindowMessageW(
      L"Syb-L.Tray.Callback.4c6c0639-ceb8-477f-85ae-2cf31f3e82b2");
}

void SystemTray::Shutdown() noexcept {
  RemoveIcon();
  icon_data_ = {};
  owner_ = nullptr;
  icon_ = nullptr;
  callback_message_ = 0;
  taskbar_created_message_ = 0;
  reveal_ = {};
}

bool SystemTray::HandleWindowMessage(UINT message,
                                     WPARAM wparam,
                                     LPARAM lparam) noexcept {
  if (taskbar_created_message_ != 0 &&
      message == taskbar_created_message_) {
    // Explorer discarded every icon when its taskbar was recreated. The old
    // registration no longer exists, so add a fresh one and re-apply v4
    // callback semantics.
    installed_ = false;
    AddIcon();
    return true;
  }
  if (message != callback_message_ || !owner_) {
    return false;
  }

  // NOTIFYICON_VERSION_4 places the notification code in LOWORD(lParam) and
  // the menu anchor in wParam. Using the shell-provided anchor also positions
  // keyboard-invoked menus at the notification icon rather than the mouse.
  switch (ActivationForNotification(LOWORD(lparam))) {
    case Activation::kOpen:
      RestoreWindow();
      break;
    case Activation::kMenu:
      ShowContextMenu(
          POINT{GET_X_LPARAM(wparam), GET_Y_LPARAM(wparam)});
      break;
    case Activation::kNone:
      break;
  }
  return true;
}

bool SystemTray::HideWindow() noexcept {
  if (!installed_ || !owner_ || !::IsWindow(owner_)) {
    return false;
  }
  ::ShowWindow(owner_, SW_HIDE);
  return !::IsWindowVisible(owner_);
}

SystemTray::Activation SystemTray::ActivationForNotification(
    UINT notification) noexcept {
  switch (notification) {
    case NIN_SELECT:
    case NIN_KEYSELECT:
    case WM_LBUTTONUP:
    case WM_LBUTTONDBLCLK:
      return Activation::kOpen;
    case WM_CONTEXTMENU:
    case WM_RBUTTONUP:
      return Activation::kMenu;
    default:
      return Activation::kNone;
  }
}

bool SystemTray::AddIcon() noexcept {
  if (!owner_ || !icon_ || installed_) {
    return installed_;
  }
  if (!::Shell_NotifyIconW(NIM_ADD, &icon_data_)) {
    return false;
  }

  icon_data_.uVersion = NOTIFYICON_VERSION_4;
  if (!::Shell_NotifyIconW(NIM_SETVERSION, &icon_data_)) {
    ::Shell_NotifyIconW(NIM_DELETE, &icon_data_);
    return false;
  }
  installed_ = true;
  return true;
}

void SystemTray::RemoveIcon() noexcept {
  if (installed_) {
    ::Shell_NotifyIconW(NIM_DELETE, &icon_data_);
    installed_ = false;
  }
}

void SystemTray::RestoreWindow() noexcept {
  if (!owner_ || !::IsWindow(owner_) || !reveal_) {
    return;
  }
  // The owner handles covered restore or attention for an already-visible window;
  // the tray never exposes the window itself.
  try {
    reveal_();
  } catch (...) {
  }
}

void SystemTray::ShowContextMenu(POINT anchor) noexcept {
  if (!owner_ || !::IsWindow(owner_)) {
    return;
  }

  HMENU menu = ::CreatePopupMenu();
  if (!menu) {
    return;
  }
  const bool built =
      ::AppendMenuW(menu, MF_STRING, kOpenCommand, L"Open Doorlight") != FALSE &&
      ::AppendMenuW(menu, MF_SEPARATOR, 0, nullptr) != FALSE &&
      ::AppendMenuW(menu, MF_STRING, kQuitCommand, L"Quit") != FALSE;
  if (!built) {
    ::DestroyMenu(menu);
    return;
  }

  ::SetMenuDefaultItem(menu, kOpenCommand, FALSE);
  if (anchor.x == -1 && anchor.y == -1 &&
      !::GetCursorPos(&anchor)) {
    anchor = {0, 0};
  }

  // Required by the notification-area contract so the menu dismisses when it
  // loses focus. TPM_RETURNCMD keeps command dispatch explicit and synchronous.
  ::SetForegroundWindow(owner_);
  const UINT command = ::TrackPopupMenuEx(
      menu, TPM_RIGHTBUTTON | TPM_RETURNCMD | TPM_NONOTIFY, anchor.x, anchor.y,
      owner_, nullptr);
  ::DestroyMenu(menu);
  ::PostMessageW(owner_, WM_NULL, 0, 0);

  HandleMenuCommand(command);
}

void SystemTray::HandleMenuCommand(UINT command) noexcept {
  if (command == kOpenCommand) {
    RestoreWindow();
  } else if (command == kQuitCommand) {
    Quit();
  }
}

void SystemTray::Quit() noexcept {
  if (!owner_ || !::IsWindow(owner_)) {
    return;
  }
  const HWND owner = owner_;
  RemoveIcon();
  if (!::DestroyWindow(owner)) {
    // Do not leave a live but unreachable process if an exceptional teardown
    // failure occurs.
    AddIcon();
    RestoreWindow();
  }
}
