#ifndef RUNNER_SYSTEM_TRAY_H_
#define RUNNER_SYSTEM_TRAY_H_

#include <windows.h>
#include <shellapi.h>

#include <functional>

// Owns Syb-L's Windows notification-area icon and its native lifecycle.
//
// The top-level window remains the single message owner. Closing may hide the
// window only while this object has a live tray icon; if Explorer rejected the
// icon, the caller can fall back to normal window destruction instead of
// stranding an invisible process.
class SystemTray {
 public:
  enum class Activation {
    kNone,
    kOpen,
    kMenu,
  };

  SystemTray() = default;
  ~SystemTray();

  SystemTray(const SystemTray&) = delete;
  SystemTray& operator=(const SystemTray&) = delete;

  // Registers the Explorer-restart message and adds the tray icon. |icon_id|
  // is loaded from the current executable as a shared resource.
  bool Initialize(HWND owner,
                  UINT icon_id,
                  const wchar_t* tooltip,
                  std::function<bool()> reveal) noexcept;

  // |reveal| is the owner's single covered reveal. The tray calls it for every
  // restore and never shows the window itself.

  // Test seam: binds an owner and reveal callback without a shell icon.
  bool AttachForTest(HWND owner, std::function<bool()> reveal) noexcept;

  // Executes a popup-menu command (the menu itself needs a shell session).
  void HandleMenuCommand(UINT command) noexcept;

  static constexpr UINT kOpenCommand = 1;
  static constexpr UINT kQuitCommand = 2;

  // Removes the icon if present and releases all non-owning handles. Safe to
  // call repeatedly and from the destructor.
  void Shutdown() noexcept;

  // Handles the callback message and TaskbarCreated recovery. Returns true
  // when |message| belongs to the tray component.
  bool HandleWindowMessage(UINT message,
                           WPARAM wparam,
                           LPARAM lparam) noexcept;

  // Hides only when a tray icon is known to be installed. Returns false when
  // the window should follow its normal close path.
  bool HideWindow() noexcept;
  POINT AnimationTarget() const noexcept;

  bool installed() const noexcept { return installed_; }

  // Kept pure so callback semantics remain regression-testable without
  // creating an Explorer notification-area fixture.
  static Activation ActivationForNotification(UINT notification) noexcept;

 private:
  static UINT CallbackMessage() noexcept;
  bool AddIcon() noexcept;
  void RemoveIcon() noexcept;
  void RestoreWindow() noexcept;
  void ShowContextMenu(POINT anchor) noexcept;
  void Quit() noexcept;

  HWND owner_ = nullptr;
  HICON icon_ = nullptr;  // Shared resource; this class does not destroy it.
  UINT callback_message_ = 0;
  UINT taskbar_created_message_ = 0;
  NOTIFYICONDATAW icon_data_{};
  bool installed_ = false;
  std::function<bool()> reveal_;
};

#endif  // RUNNER_SYSTEM_TRAY_H_
