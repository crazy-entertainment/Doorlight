#include "flutter_window.h"

#include <flutter_plugin_registrar.h>  // FlutterDesktopRegistrarGetTextureRegistrar (C API)

#include <array>
#include <cmath>
#include <cstdint>
#include <optional>
#include <string>
#include <variant>

#include <flutter/event_stream_handler_functions.h>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

#include "jami_bridge.h"
#include "jami_channels.h"
#include "nearby_radio.h"
#include "invite_link_win32.h"
#include "resource.h"
#include "window_bounds.h"
#include "window_presentation.h"
#include "uat_profile.h"
#include "utils.h"

namespace {

constexpr ULONG_PTR kSybLStressCopyDataId = 0x5359424c;  // "SYBL"
constexpr UINT kPresentedFrameMessage = WM_APP + 0x31A;

sybl::window::DismissStyle DismissStyleFromName(const std::string& name) {
  using sybl::window::DismissStyle;
  if (name == "tray") return DismissStyle::kTray;
  if (name == "door") return DismissStyle::kDoor;
  if (name == "foldRight") return DismissStyle::kFoldRight;
  if (name == "foldUp") return DismissStyle::kFoldUp;
  if (name == "foldDown") return DismissStyle::kFoldDown;
  if (name == "warp") return DismissStyle::kWarp;
  if (name == "fade") return DismissStyle::kFade;
  return DismissStyle::kNone;
}

bool IsAllowedStressCommand(const std::string& command) {
  constexpr std::array<const char*, 25> allowed{
      "ping",        "voice",       "video",       "answer",
      "hangup",      "camera:on",   "camera:off",  "camera:flip",
      "screen:on",   "screen:off",  "profile:lan", "profile:jami",
      "group:join",  "group:camera", "group:leave", "group:screen:on",
      "group:screen:off", "control", "control:home", "control:move",
      "control:tap", "focus", "window:probe", "window:frame", "window:client"};
  for (const char* candidate : allowed) {
    if (command == candidate) return true;
  }
  if (command.size() == 47 && command.compare(0, 7, "select:") == 0 &&
      command.find_first_not_of("0123456789abcdef", 7) == std::string::npos) {
    return true;
  }
  return command.size() == 6 && command.compare(0, 5, "chat:") == 0 &&
         command[5] >= '1' && command[5] <= '9';
}

bool StressControlRequested() {
  wchar_t value[8]{};
  const DWORD length =
      GetEnvironmentVariableW(L"SYBL_STRESS_CONTROL", value, static_cast<DWORD>(sizeof(value) / sizeof(value[0])));
  return length == 1 && value[0] == L'1';
}

bool ReadNumber(const flutter::EncodableValue& value, double* result) {
  if (const auto number = std::get_if<double>(&value)) {
    *result = *number;
    return std::isfinite(*result);
  }
  if (const auto number = std::get_if<int32_t>(&value)) {
    *result = *number;
    return true;
  }
  if (const auto number = std::get_if<int64_t>(&value)) {
    *result = static_cast<double>(*number);
    return std::isfinite(*result);
  }
  return false;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }
  // Win32Window::Create first calls Destroy, even for a fresh object.
  destroying_ = false;
  presented_callback_armed_ = false;
  presented_frame_ready_ = false;

  // Flutter starts with a data-free surface. Before it builds private content,
  // Dart applies and confirms the saved window capture protection setting.
  // Capture activity can later open the protected consent prompt.

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
#ifdef SYBL_VISUAL_UAT
  flutter::MethodChannel<flutter::EncodableValue> uat_profile(
      flutter_controller_->engine()->messenger(), "doorlight/visual-uat-profile",
      &flutter::StandardMethodCodec::GetInstance());
  uat_profile.SetMethodCallHandler([](const auto& call, auto result) {
    if (call.method_name() != "root" || sybl::uat::profile_root.empty()) {
      result->Error("uat-profile", "Isolated profile is unavailable");
      return;
    }
    result->Success(flutter::EncodableValue(Utf8FromUtf16(sybl::uat::profile_root.c_str())));
  });
#endif
  nearby_radio_ = std::make_unique<NearbyRadio>(flutter_controller_->engine()->messenger());
  sonar_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "syb.l/sonar",
      &flutter::StandardMethodCodec::GetInstance());
  sonar_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "cancel") {
          desktop_sonar_.Cancel();
          result->Success();
          return;
        }
        if (call.method_name() != "reveal" || !call.arguments()) {
          desktop_sonar_.Cancel();
          result->NotImplemented();
          return;
        }
        const auto args = std::get_if<flutter::EncodableMap>(call.arguments());
        if (!args || args->size() != 3) {
          desktop_sonar_.Cancel();
          result->Error("invalid_arguments", "Invalid sonar request");
          return;
        }
        const auto x_it = args->find(flutter::EncodableValue("x"));
        const auto y_it = args->find(flutter::EncodableValue("y"));
        const auto color_it = args->find(flutter::EncodableValue("color"));
        double x = 0, y = 0, color_value = 0;
        if (x_it == args->end() || y_it == args->end() || color_it == args->end() ||
            !ReadNumber(x_it->second, &x) || !ReadNumber(y_it->second, &y) ||
            !ReadNumber(color_it->second, &color_value) || color_value < 0 ||
            color_value > 0xffffff || std::floor(color_value) != color_value ||
            !desktop_sonar_.Reveal(flutter_controller_->view()->GetNativeWindow(),
                                   x, y, static_cast<std::uint32_t>(color_value))) {
          desktop_sonar_.Cancel();
          result->Error("invalid_arguments", "Invalid sonar request");
          return;
        }
        result->Success();
      });
  gravity_channel_ = std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "syb.l/gravity",
      &flutter::StandardMethodCodec::GetInstance());
  gravity_channel_->SetStreamHandler(
      std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
          [this](const flutter::EncodableValue*,
                 std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events)
              -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
            gravity_sink_ = std::move(events);
            return nullptr;
          },
          [this](const flutter::EncodableValue*)
              -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
            gravity_sink_ = nullptr;
            return nullptr;
          }));
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  taskbar_target_ = std::make_unique<sybl::window::TaskbarTarget>();
  dismiss_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "syb.l/window-dismiss",
      &flutter::StandardMethodCodec::GetInstance());
  dismiss_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "configure") {
      // A setting change retires any frame captured under the previous policy.
      if (dismiss_preview_ || dismiss_restoring_ || restore_motion_prepared_) RetireRestoreMotion();
      else if (dismiss_pending_) CommitDismiss();
      dismiss_enabled_ = false;
      const auto args = call.arguments() ? std::get_if<flutter::EncodableMap>(call.arguments()) : nullptr;
      const auto style = [args](const char* key) {
        using sybl::window::DismissStyle;
        if (!args) return DismissStyle::kNone;
        const auto it = args->find(flutter::EncodableValue(key));
        if (it == args->end()) return DismissStyle::kNone;
        const auto value = std::get_if<std::string>(&it->second);
        return value ? DismissStyleFromName(*value) : DismissStyle::kNone;
      };
      const auto duration = [args](const char* key) -> UINT {
        if (!args) return sybl::window::kDismissDurationMs;
        const auto it = args->find(flutter::EncodableValue(key));
        if (it == args->end()) return sybl::window::kDismissDurationMs;
        const auto value = std::get_if<int32_t>(&it->second);
        return value && *value >= 100 && *value <= 800
            ? static_cast<UINT>(*value) : sybl::window::kDismissDurationMs;
      };
      open_animation_ = style("openAnimation");
      minimize_animation_ = style("minimizeAnimation");
      close_animation_ = style("closeAnimation");
      open_duration_ms_ = duration("openDurationMs");
      minimize_duration_ms_ = duration("minimizeDurationMs");
      close_duration_ms_ = duration("closeDurationMs");
      if (args) {
        const auto enabled = args->find(flutter::EncodableValue("enabled"));
        if (enabled != args->end()) {
          const auto value = std::get_if<bool>(&enabled->second);
          dismiss_enabled_ = value && *value;
        }
      }
      result->Success(flutter::EncodableValue(stress_control_enabled_));
      return;
    }
    if (call.method_name() == "preview") {
      const auto args = call.arguments() ? std::get_if<flutter::EncodableMap>(call.arguments()) : nullptr;
      const auto text = [args](const char* key) -> std::string {
        if (!args) return {};
        const auto it = args->find(flutter::EncodableValue(key));
        if (it == args->end()) return {};
        const auto value = std::get_if<std::string>(&it->second);
        return value ? *value : std::string{};
      };
      const std::string action = text("action"), style = text("animation");
      int duration = 0;
      if (args) {
        const auto it = args->find(flutter::EncodableValue("durationMs"));
        if (it != args->end()) {
          const auto value = std::get_if<int32_t>(&it->second);
          if (value) duration = *value;
        }
      }
      using sybl::window::DismissStyle;
      const auto animation = DismissStyleFromName(style);
      if ((action != "open" && action != "minimize" && action != "close") ||
          duration < 100 || duration > 800 || !dismiss_enabled_ || dismiss_pending_ ||
          restore_motion_prepared_ || privacy_restore_cover_ || preview_result_ ||
          (animation == DismissStyle::kNone && style != "none")) {
        result->Success(flutter::EncodableValue(false));
        return;
      }
      if (animation == DismissStyle::kNone) {
        result->Success(flutter::EncodableValue(true));
        return;
      }
      preview_result_ = std::move(result);
      if (!BeginDismissCapture(action == "close" || (action == "open" && last_dismiss_close_),
              action == "open", animation,
              static_cast<UINT>(duration), true)) CancelDismiss();
      return;
    }
    if ((call.method_name() != "present" && call.method_name() != "trace") || !call.arguments()) {
      result->NotImplemented();
      return;
    }
    const auto args = std::get_if<flutter::EncodableMap>(call.arguments());
    const auto number = [args](const char* key) -> int {
      if (!args) return -1;
      const auto it = args->find(flutter::EncodableValue(key));
      if (it == args->end()) return -1;
      const auto value = std::get_if<int32_t>(&it->second);
      return value ? *value : -1;
    };
    const int token = number("token"), width = number("width"), height = number("height");
    if (call.method_name() == "trace") {
      if (stress_control_enabled_ && dismiss_pending_ && token == dismiss_token_)
        dismiss_trace_ = number("stage");
      result->Success();
      return;
    }
    const std::vector<uint8_t>* pixels = nullptr;
    if (args) {
      const auto it = args->find(flutter::EncodableValue("rgba"));
      if (it != args->end()) pixels = std::get_if<std::vector<uint8_t>>(&it->second);
    }
    if (!dismiss_pending_ || token != dismiss_token_ || !dismiss_enabled_) {
      result->Success();
      return;
    }
    dismiss_frame_width_ = width;
    dismiss_frame_height_ = height;
    dismiss_stage_ = 2;
    if (!pixels || !sybl::window::ValidDismissFrame(width, height, pixels->size()) ||
        dismiss_effect_.active() ||
        !dismiss_effect_.Start(GetHandle(), width, height, *pixels,
            (dismiss_animation_ == sybl::window::DismissStyle::kTray ||
             dismiss_animation_ == sybl::window::DismissStyle::kWarp)
                ? (dismiss_close_ ? system_tray_.AnimationTarget() : taskbar_target_->ForWindow(GetHandle()))
                : POINT{},
            dismiss_animation_, [this](bool completed) { CommitDismiss(completed); }, dismiss_restoring_, dismiss_duration_ms_, dismiss_preview_)) {
      CommitDismiss();
    } else {
      dismiss_stage_ = 3;
      if (dismiss_restoring_ && privacy_restore_cover_) {
        DestroyWindow(privacy_restore_cover_);
        privacy_restore_cover_ = nullptr;
        restore_motion_prepared_ = false;
      }
      dismiss_deadline_ = GetTickCount64() + dismiss_duration_ms_ *
          (dismiss_preview_ && !dismiss_restoring_ ? 2 : 1) + 100;
    }
    result->Success();
  });

  AfterPresentedFrame([this](bool) {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  // Boot the libjami daemon off the UI thread (M3 unit b: the engine loads inside the Flutter app).
  jami_bridge::Start();

  // The texture registrar (C ref) for the daemon-captured video external textures. Reached via a plugin registrar
  // ref (engine-owned); the C texture API is exported from flutter_windows.dll, so no C++ plugin-wrapper lib is
  // needed (only flutter_wrapper_app is linked into the runner).
  FlutterDesktopTextureRegistrarRef texture_registrar = FlutterDesktopRegistrarGetTextureRegistrar(
      flutter_controller_->engine()->GetRegistrarForPlugin("sybl_video"));

  // Wire the syb.l/core + syb.l/events channels against the engine messenger (unit c: identity surface). Built
  // on the platform thread so its message-only window pumps on this thread; the event sink attaches lazily on
  // the Dart side's onListen, and jami_bridge replays the latest registration state to it.
  jami_channels_ =
      std::make_unique<JamiChannels>(flutter_controller_->engine()->messenger(),
                                     texture_registrar, GetHandle());
  jami_channels_->SetBeforeCapturePolicyChange([this] {
    // Retire both the active surface and queued capture token before changing
    // affinity: an old private frame must never inherit a newer permissive policy.
    if (dismiss_preview_ || dismiss_restoring_ || restore_motion_prepared_) RetireRestoreMotion();
    else if (dismiss_pending_) CommitDismiss();
  });
  jami_channels_->SetCaptureFrameBarrier([this](std::function<void(bool)> done) {
    // Dart requests this only after submitting the data-free gate's frame.
    // Drain an already-in-flight frame, then require another presented frame.
    AfterPresentedFrame([this, done](bool ok) {
      if (!ok) { done(false); return; }
      AfterPresentedFrame(done);
    });
  });
  if (!pending_invite_link_.empty()) {
    jami_channels_->SendInviteLink(pending_invite_link_);
    pending_invite_link_.clear();
  }
  stress_control_enabled_ = StressControlRequested();
  // The app remains usable if Explorer rejects the icon: WM_CLOSE then follows
  // the normal destructive path instead of hiding an unreachable process.
  system_tray_.Initialize(
      GetHandle(), IDI_APP_ICON, L"Doorlight",
      [this]() { return RevealCovered(); });

  return true;
}

void FlutterWindow::OnDestroy() {
  nearby_radio_.reset();
  destroying_ = true;
  if (dismiss_effect_.active() && GetHandle()) ShowWindow(GetHandle(), SW_HIDE);
  CancelDismiss();
  if (dismiss_channel_) dismiss_channel_->SetMethodCallHandler(nullptr);
  dismiss_channel_.reset();
  taskbar_target_.reset();
  desktop_sonar_.Cancel();
  if (sonar_channel_) sonar_channel_->SetMethodCallHandler(nullptr);
  sonar_channel_ = nullptr;
  gravity_sink_ = nullptr;
  if (gravity_channel_) gravity_channel_->SetStreamHandler(nullptr);
  gravity_channel_ = nullptr;
  auto pending = std::move(presented_callbacks_);
  for (auto& callback : pending) callback(false);
  // Remove the shell surface before tearing down Flutter or libjami so no tray
  // callback can target a partially destroyed application.
  system_tray_.Shutdown();
  if (privacy_restore_cover_ && ::IsWindow(privacy_restore_cover_)) {
    ::DestroyWindow(privacy_restore_cover_);
  }
  privacy_restore_cover_ = nullptr;
  // Stop the daemon FIRST: Stop() joins the worker, so no further EnsureAccount/event completion can fire into
  // the channels after this. THEN drop the channels (unhooks the sink + destroys the message-only window) while
  // the engine/messenger they reference is still alive, and only then release the controller.
  if (jami_channels_) jami_channels_->ShutdownRemoteControl();
  jami_bridge::Stop();
  jami_channels_ = nullptr;

  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

bool FlutterWindow::BeginPrivacyCoveredRestore(bool animate) {
  if (!flutter_controller_ || !GetHandle() || !::IsWindow(GetHandle())) {
    return false;
  }
  // Explorer can deliver both select and button-up for one tray click. A
  // second reveal must not cancel the incoming effect started by the first.
  if (animate && (restore_motion_prepared_ || dismiss_restoring_)) return true;
  if (privacy_restore_cover_ && ::IsWindow(privacy_restore_cover_)) {
    ::DestroyWindow(privacy_restore_cover_);
  }
  privacy_restore_cover_ = nullptr;

  RECT client{};
  if (!::GetClientRect(GetHandle(), &client)) {
    return false;
  }
  const HWND cover = ::CreateWindowExW(
      0, L"STATIC", nullptr, WS_CHILD | WS_VISIBLE | SS_BLACKRECT, client.left,
      client.top, client.right - client.left, client.bottom - client.top,
      GetHandle(), nullptr, ::GetModuleHandleW(nullptr), nullptr);
  if (!cover) {
    return false;
  }
  privacy_restore_cover_ = cover;
  ::SetWindowPos(cover, HWND_TOP, client.left, client.top,
                 client.right - client.left, client.bottom - client.top,
                 SWP_NOACTIVATE | SWP_SHOWWINDOW);
  ::RedrawWindow(cover, nullptr, nullptr,
                 RDW_INVALIDATE | RDW_UPDATENOW | RDW_ALLCHILDREN);

  // Retire any protected exit frame while the fresh-frame restore cover is up.
  CancelDismiss();
  if (animate && dismiss_enabled_ &&
      (!IsWindowVisible(GetHandle()) || IsIconic(GetHandle())) &&
      open_animation_ != sybl::window::DismissStyle::kNone) {
    restore_motion_prepared_ = dismiss_effect_.PrepareRestore(GetHandle());
    if (restore_motion_prepared_) {
      dismiss_deadline_ = GetTickCount64() + sybl::window::kDismissWatchdogMs;
      if (!SetTimer(GetHandle(), sybl::window::kDismissWatchdog, 25, nullptr))
        CancelDismiss();
    }
  }

  return true;
}

void FlutterWindow::FinishPrivacyCoveredRestore(bool animate) {
  if (!flutter_controller_ || !privacy_restore_cover_ ||
      !::IsWindow(privacy_restore_cover_)) {
    return;
  }
  const HWND cover = privacy_restore_cover_;
  AfterPresentedFrame([this, cover, animate](bool presented) {
    if (presented && privacy_restore_cover_ == cover) {
      if (animate && restore_motion_prepared_ &&
          RequestDismiss(last_dismiss_close_, true)) return;
      if (restore_motion_prepared_) CancelDismiss();
      if (::IsWindow(cover)) {
        ::DestroyWindow(cover);
      }
      privacy_restore_cover_ = nullptr;
    }
  });
}

void FlutterWindow::RetireRestoreMotion() {
  // Cover before retiring a capturable incoming frame, then wait for fresh
  // Flutter content. Never replay a frame captured before a privacy transition.
  if (BeginPrivacyCoveredRestore(false)) {
    const HWND cover = privacy_restore_cover_;
    AfterPresentedFrame([this, cover](bool presented) {
      if (presented && privacy_restore_cover_ == cover)
        FinishPrivacyCoveredRestore(false);
    });
  }
  else {
    ShowWindow(GetHandle(), SW_HIDE);
    CancelDismiss();
  }
}

void FlutterWindow::PulseAttention() {
  const auto now = GetTickCount64();
  if (!dismiss_enabled_ || !dismiss_channel_ || dismiss_pending_ ||
      restore_motion_prepared_ || privacy_restore_cover_ || now - last_attention_ < 500) return;
  last_attention_ = now;
  dismiss_channel_->InvokeMethod("attention", nullptr);
}

bool FlutterWindow::RevealCovered() noexcept {
  if (destroying_ || !GetHandle() || !::IsWindow(GetHandle())) return false;
  if (IsWindowVisible(GetHandle()) && !IsIconic(GetHandle()) &&
      !privacy_restore_cover_ && !dismiss_pending_ && !restore_motion_prepared_) {
    SetForegroundWindow(GetHandle());
    PulseAttention();
    return true;
  }
  return sybl::window::RunCoveredReveal(sybl::window::WindowRevealOperations(
      GetHandle(), [this]() { return BeginPrivacyCoveredRestore(); },
      [this]() { FinishPrivacyCoveredRestore(); },
      [this]() { ApplyDeferredPresentation(); }));
}

bool FlutterWindow::RevealMinimized(HWND) noexcept {
  return RevealCovered();
}

bool FlutterWindow::RequestDismiss(bool close, bool restoring) {
  if (!restoring) {
    last_dismiss_close_ = close;
    if (dismiss_preview_ || dismiss_restoring_ || restore_motion_prepared_) {
      RetireRestoreMotion();
      return false;
    }
  }
  if (dismiss_pending_) {
    dismiss_close_ = dismiss_close_ || close;
    if (!restoring && close && (!system_tray_.installed() ||
        close_animation_ == sybl::window::DismissStyle::kNone)) CommitDismiss();
    return true;
  }
  const auto animation = restoring ? open_animation_ : close ? close_animation_ : minimize_animation_;
  if ((!restoring && close && !system_tray_.installed()) ||
      animation == sybl::window::DismissStyle::kNone) return false;
  return BeginDismissCapture(close, restoring, animation,
      restoring ? open_duration_ms_ : close ? close_duration_ms_ : minimize_duration_ms_);
}

bool FlutterWindow::BeginDismissCapture(bool close, bool restoring,
    sybl::window::DismissStyle animation, UINT duration_ms, bool preview) {
  if (!dismiss_enabled_ || !dismiss_channel_ || destroying_ ||
      (privacy_restore_cover_ && !restoring) || !IsWindowVisible(GetHandle()) || IsIconic(GetHandle()))
    { dismiss_stage_ = 6; return false; }
  FinishPresentationAnimation();
  if (!close && (animation == sybl::window::DismissStyle::kTray ||
      animation == sybl::window::DismissStyle::kWarp)) taskbar_target_->Refresh();
  dismiss_animation_ = animation;
  dismiss_duration_ms_ = duration_ms;
  dismiss_preview_ = preview;
  dismiss_pending_ = true;
  dismiss_restoring_ = restoring;
  dismiss_stage_ = 1;
  dismiss_trace_ = 0;
  dismiss_close_ = close;
  ++dismiss_token_;
  dismiss_deadline_ = GetTickCount64() + sybl::window::kDismissWatchdogMs;
  if (!SetTimer(GetHandle(), sybl::window::kDismissWatchdog, 25, nullptr)) {
    dismiss_pending_ = false;
    return false;
  }
  dismiss_channel_->InvokeMethod("capture",
      std::make_unique<flutter::EncodableValue>(dismiss_token_));
  return true;
}

void FlutterWindow::CancelDismiss(bool completed) {
  ++dismiss_token_;
  dismiss_pending_ = false;
  dismiss_preview_ = false;
  dismiss_restoring_ = false;
  restore_motion_prepared_ = false;
  if (GetHandle()) KillTimer(GetHandle(), sybl::window::kDismissWatchdog);
  dismiss_effect_.Reset();
  if (dismiss_channel_ && !destroying_)
    dismiss_channel_->InvokeMethod("reset", nullptr);
  if (preview_result_) {
    auto result = std::move(preview_result_);
    result->Success(flutter::EncodableValue(completed));
  }
}

void FlutterWindow::CommitDismiss(bool completed) {
  if (!dismiss_pending_ || dismiss_committing_) return;
  dismiss_committing_ = true;
  if (dismiss_stage_ == 3) dismiss_stage_ = 4;
  const bool close = dismiss_close_;
  if (dismiss_preview_) {
    if (completed) CancelDismiss(true);
    else RetireRestoreMotion();
    dismiss_committing_ = false;
    return;
  }
  if (dismiss_restoring_) {
    CancelDismiss();
    if (privacy_restore_cover_) {
      DestroyWindow(privacy_restore_cover_);
      privacy_restore_cover_ = nullptr;
    }
    dismiss_committing_ = false;
    return;
  }
  // Retain the source's cloak until it is hidden/iconic. Geometry and
  // WINDOWPLACEMENT were never changed by the independent exit surface.
  if (close) {
    if (!system_tray_.HideWindow()) {
      // Destroy after the channel callback returns, matching the normal quit.
      PostMessageW(GetHandle(), kQuitRequestMessage, 0, 0);
      ShowWindow(GetHandle(), SW_HIDE);
    }
  } else {
    sybl::window::MinimizeWithoutReveal(GetHandle());
  }
  CancelDismiss();
  dismiss_committing_ = false;
}

void FlutterWindow::AfterPresentedFrame(std::function<void(bool)> callback) {
  if (destroying_ || !flutter_controller_) { callback(false); return; }
  presented_callbacks_.push_back(std::move(callback));
  if (presented_callback_armed_) return;
  presented_callback_armed_ = true;
  flutter_controller_->engine()->SetNextFrameCallback([this]() {
    // Flutter's wrapper clears its callback after invocation. Registering the
    // successor inside this callback would destroy/clear that successor.
    inside_presented_callback_ = true;
    presented_frame_ready_ = true;
    PostMessageW(GetHandle(), kPresentedFrameMessage, 0, 0);
    inside_presented_callback_ = false;
  });
  flutter_controller_->ForceRedraw();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == WM_MOUSEACTIVATE) {
    covered_before_activation_ = sybl::window::IsCoveredByAnotherWindow(hwnd);
  } else if (message == WM_ACTIVATE && LOWORD(wparam) != WA_INACTIVE &&
      !HIWORD(wparam) && IsWindowVisible(hwnd) && !IsIconic(hwnd)) {
    // On activation Z-order has already changed; the previous active window's
    // overlap is a conservative fallback for taskbar and keyboard activation.
    if (covered_before_activation_ || sybl::window::IsOverlappingForeignWindow(
        hwnd, reinterpret_cast<HWND>(lparam))) PulseAttention();
    covered_before_activation_ = false;
  }
  if (jami_channels_ && (message == WM_CLOSE ||
      (message == WM_SYSCOMMAND && (wparam & 0xfff0) == SC_MINIMIZE)))
    jami_channels_->StopWindowShake();
  if (message == WM_CLOSE) FinishPresentationAnimation();
  // Capture the unchanged placement before WM_CLOSE can be deferred for motion.
  if ((message == WM_EXITSIZEMOVE || message == WM_CLOSE) &&
      !GetPropW(hwnd, kCompactWindowProperty)) {
    WINDOWPLACEMENT placement{};
    placement.length = sizeof(placement);
    if (::GetWindowPlacement(hwnd, &placement)) {
      const RECT& normal = placement.rcNormalPosition;
      sybl::window::SaveBounds({normal.left, normal.top,
          normal.right - normal.left, normal.bottom - normal.top,
          placement.showCmd == SW_SHOWMAXIMIZED});
    }
  }
  if (!dismiss_committing_) {
    if (message == WM_CLOSE && RequestDismiss(true)) return 0;
    if (message == WM_SYSCOMMAND && (wparam & 0xfff0) == SC_MINIMIZE &&
        RequestDismiss(false)) return 0;
    if (message == WM_TIMER && wparam == sybl::window::kDismissWatchdog) {
      if (restore_motion_prepared_ && !dismiss_pending_ &&
          GetTickCount64() >= dismiss_deadline_) {
        RetireRestoreMotion();
        return 0;
      }
      if (dismiss_pending_ && GetTickCount64() >= dismiss_deadline_) {
        dismiss_stage_ = 5;
        CommitDismiss();
      }
      return 0;
    }
    if (dismiss_pending_ && (message == WM_DISPLAYCHANGE || message == WM_DPICHANGED ||
        (message == WM_THEMECHANGED && dismiss_effect_.active()) ||
        message == WM_DWMCOLORIZATIONCOLORCHANGED ||
        message == WM_ENTERSIZEMOVE || message == WM_QUERYENDSESSION ||
        (message == WM_ACTIVATEAPP && !wparam))) CommitDismiss();
    if (dismiss_pending_ && message == WM_SIZE && wparam == SIZE_MINIMIZED)
      CancelDismiss();
  }
  if (message == kPresentedFrameMessage) {
    // The message carries no authority: only the engine callback sets ready.
    if (!presented_frame_ready_ || inside_presented_callback_) return 0;
    presented_frame_ready_ = false;
    presented_callback_armed_ = false;
    auto pending = std::move(presented_callbacks_);
    presented_callbacks_.clear();
    for (auto& callback : pending) callback(!destroying_);
    return 0;
  }
  if (message == WM_SIZE && privacy_restore_cover_ &&
      ::IsWindow(privacy_restore_cover_)) {
    RECT client{};
    if (::GetClientRect(hwnd, &client)) {
      ::SetWindowPos(
          privacy_restore_cover_, HWND_TOP, client.left, client.top,
          client.right - client.left, client.bottom - client.top,
          SWP_NOACTIVATE | SWP_SHOWWINDOW);
    }
  }
  // Pieces of the /gravity easter egg keep their place on screen while the
  // window is dragged. Minimizing parks the window far off screen: no move.
  if (message == WM_MOVE && gravity_sink_ && !::IsIconic(hwnd)) {
    gravity_sink_->Success(flutter::EncodableValue(flutter::EncodableList{
        flutter::EncodableValue(static_cast<double>(static_cast<short>(LOWORD(lparam)))),
        flutter::EncodableValue(static_cast<double>(static_cast<short>(HIWORD(lparam))))}));
  }
  if ((message == WM_SHOWWINDOW && !wparam) ||
      (message == WM_SIZE && wparam == SIZE_MINIMIZED)) {
    desktop_sonar_.Cancel();
  }

  // A second launch asks this instance to reveal itself; the covered
  // sequence runs here, never in the requesting process.
  if (LRESULT revealed = FALSE;
      sybl::window::DispatchRevealRequest(
          message,
          sybl::window::WindowRevealOperations(
              hwnd, [this]() { return BeginPrivacyCoveredRestore(); },
              [this]() { FinishPrivacyCoveredRestore(); },
              [this]() { ApplyDeferredPresentation(); }),
          &revealed)) {
    return revealed;
  }

  if (message == kQuitRequestMessage) {
    system_tray_.Shutdown();
    ::DestroyWindow(hwnd);
    return 0;
  }
  if (message == WM_CLOSE && system_tray_.HideWindow()) {
    return 0;
  }
  if (system_tray_.HandleWindowMessage(message, wparam, lparam)) {
    return 0;
  }

  // Personalized links from a second launch are untrusted hints only: Dart
  // strictly parses them and still requires recipient confirmation.
  if (message == WM_COPYDATA) {
    const auto* copy = reinterpret_cast<const COPYDATASTRUCT*>(lparam);
    if (copy &&
        copy->dwData ==
            static_cast<ULONG_PTR>(sybl::invite_link::kCopyDataId) &&
        copy->lpData && copy->cbData > 1 &&
        copy->cbData <= sybl::invite_link::kMaxUriBytes + 1) {
      const auto* bytes = static_cast<const char*>(copy->lpData);
      if (bytes[copy->cbData - 1] == '\0') {
        const std::string link(bytes, copy->cbData - 1);
        if (sybl::invite_link::IsInviteUri(link)) {
          if (jami_channels_)
            jami_channels_->SendInviteLink(link);
          else
            pending_invite_link_ = link;
          return TRUE;
        }
      }
      return FALSE;
    }
  }

  // Diagnostic-only automation: WM_COPYDATA is synchronous and process-local, so the payload remains valid for
  // this handler. It is deliberately disabled for normal launches and accepts only a tiny fixed command set.
  // Returning TRUE acknowledges that the command reached Dart's event queue; call success remains observable in
  // the normal call-state diagnostics.
  if (message == WM_COPYDATA && stress_control_enabled_ && jami_channels_) {
    const auto* copy = reinterpret_cast<const COPYDATASTRUCT*>(lparam);
    if (copy && copy->dwData == kSybLStressCopyDataId && copy->lpData &&
        copy->cbData > 1 && copy->cbData <= 64) {
      const auto* bytes = static_cast<const char*>(copy->lpData);
      if (bytes[copy->cbData - 1] == '\0') {
        const std::string command(bytes, copy->cbData - 1);
        if (IsAllowedStressCommand(command)) {
          if (command == "window:probe") {
            return 0x40000000 | (dismiss_enabled_ ? 1 : 0) |
                (dismiss_pending_ ? 2 : 0) | (dismiss_effect_.active() ? 4 : 0) |
                (dismiss_stage_ << 8) | (dismiss_trace_ << 16) |
                (dismiss_effect_.failure() << 24);
          }
          if (command == "window:frame")
            return (dismiss_frame_width_ << 16) | (dismiss_frame_height_ & 0xffff);
          if (command == "window:client") {
            RECT client{};
            GetClientRect(hwnd, &client);
            return (client.right << 16) | (client.bottom & 0xffff);
          }
          if (command == "focus") {
            return RevealCovered() ? TRUE : FALSE;
          }
          jami_channels_->SendDiagnosticCommand(command);
          return TRUE;
        }
      }
    }
    return FALSE;
  }

  if (jami_channels_ &&
      jami_channels_->HandleRemoteWindowMessage(message, wparam, lparam)) {
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
