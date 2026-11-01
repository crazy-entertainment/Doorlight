#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/event_channel.h>
#include <flutter/method_channel.h>
#include <flutter/flutter_view_controller.h>

#include <memory>
#include <string>
#include <functional>
#include <vector>

#include "system_tray.h"
#include "win32_window.h"
#include "desktop_sonar.h"
#include "window_dismiss.h"

class JamiChannels;  // runner-side syb.l/core + syb.l/events wiring (jami_channels.h)
class NearbyRadio;

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  bool RevealMinimized(HWND window) noexcept override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // Installs an opaque child above Flutter before a hidden window is restored.
  // The child is removed only after Flutter presents a fresh frame.
  bool BeginPrivacyCoveredRestore(bool animate = true);
  void FinishPrivacyCoveredRestore(bool animate = true);
  void RetireRestoreMotion();
  // The one covered reveal shared by tray, second-launch request, focus.
  bool RevealCovered() noexcept;
  void AfterPresentedFrame(std::function<void(bool)> callback);
  bool RequestDismiss(bool close, bool restoring = false);
  bool BeginDismissCapture(bool close, bool restoring,
      sybl::window::DismissStyle animation, UINT duration_ms, bool preview = false);
  void CommitDismiss(bool completed = false);
  void CancelDismiss(bool completed = false);
  void PulseAttention();
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> dismiss_channel_;
  std::unique_ptr<sybl::window::TaskbarTarget> taskbar_target_;
  sybl::window::WindowDismissEffect dismiss_effect_;
  bool dismiss_enabled_ = false;
  bool dismiss_pending_ = false;
  bool dismiss_preview_ = false;
  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> preview_result_;
  ULONGLONG last_attention_ = 0;
  bool covered_before_activation_ = false;
  bool dismiss_close_ = false;
  bool last_dismiss_close_ = false;
  bool dismiss_restoring_ = false;
  bool restore_motion_prepared_ = false;
  sybl::window::DismissStyle open_animation_ = sybl::window::DismissStyle::kTray;
  sybl::window::DismissStyle minimize_animation_ = sybl::window::DismissStyle::kTray;
  UINT open_duration_ms_ = sybl::window::kDismissDurationMs;
  UINT minimize_duration_ms_ = sybl::window::kDismissDurationMs;
  UINT close_duration_ms_ = sybl::window::kDismissDurationMs;
  sybl::window::DismissStyle dismiss_animation_ = sybl::window::DismissStyle::kTray;
  UINT dismiss_duration_ms_ = sybl::window::kDismissDurationMs;
  sybl::window::DismissStyle close_animation_ = sybl::window::DismissStyle::kTray;
  bool dismiss_committing_ = false;
  int dismiss_token_ = 0;
  int dismiss_stage_ = 0;
  int dismiss_trace_ = 0;
  int dismiss_frame_width_ = 0, dismiss_frame_height_ = 0;
  ULONGLONG dismiss_deadline_ = 0;
  std::vector<std::function<void(bool)>> presented_callbacks_;
  bool presented_callback_armed_ = false;
  bool presented_frame_ready_ = false;
  bool inside_presented_callback_ = false;
  bool destroying_ = false;

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // The syb.l/core + syb.l/events channel bridge (owns the platform-thread hop). Built once the engine exists.
  std::unique_ptr<JamiChannels> jami_channels_;
  std::unique_ptr<NearbyRadio> nearby_radio_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> sonar_channel_;
  sybl::sonar::DesktopSonar desktop_sonar_;
  // syb.l/gravity: the window's screen position while the /gravity easter egg listens.
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> gravity_channel_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> gravity_sink_;

  // Test-only, process-local control is opt-in. It lets the paired stress harness send commands directly to this
  // window without stealing the user's cursor; normal launches leave the WM_COPYDATA surface disabled.
  bool stress_control_enabled_ = false;
  std::string pending_invite_link_;
  SystemTray system_tray_;
  HWND privacy_restore_cover_ = nullptr;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
