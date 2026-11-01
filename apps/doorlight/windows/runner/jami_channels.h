#ifndef RUNNER_JAMI_CHANNELS_H_
#define RUNNER_JAMI_CHANNELS_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/method_channel.h>
#include <flutter/method_result.h>
#include <flutter_texture_registrar.h>  // C texture API (FlutterDesktopTextureRegistrarRef / FlutterDesktopPixelBuffer)

#include <cstdint>
#include <atomic>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

#include <windows.h>

#include "annotation_overlay.h"
#include "appearance_pipe.h"
#include "companion_input.h"
#include "annotation_ingress.h"
#include "hologram_popup.h"
#include "capture_activity_monitor.h"
#include "remote_control_controller.h"
#include "remote_control_host.h"
#include "remote_control_role.h"
#include "win32_input_adapter.h"

// Runner-side wiring of the syb.l/core MethodChannel + syb.l/events EventChannel (the Windows twin of Android's
// MainActivity channel setup). Lives in a runner translation unit (compiled /WX + _HAS_EXCEPTIONS=0) so it may
// use flutter types; it talks to the daemon ONLY through the plain (flutter-free, libjami-free) jami_bridge.h.
//
// It owns the two concerns jami_bridge deliberately does not:
//   1. EncodableValue<->plain translation (the daemon sends flat string maps; "announced" is restored to bool);
//   2. the platform-thread hop — daemon callbacks arrive on a daemon thread, but flutter MethodChannel/Event
//      Channel must only be touched on the platform (UI) thread. Windows has no Looper, so this hops via a
//      message-only window whose WndProc is pumped by the runner's main GetMessage loop (the platform thread).
class JamiChannels {
 public:
  // Constructed on the platform thread (FlutterWindow::OnCreate) with the engine's binary messenger and the
  // engine's texture registrar (C ref, for the video external textures; may be null if unavailable).
  JamiChannels(flutter::BinaryMessenger* messenger,
               FlutterDesktopTextureRegistrarRef textures,
               HWND owner);
  ~JamiChannels();

  JamiChannels(const JamiChannels&) = delete;
  JamiChannels& operator=(const JamiChannels&) = delete;

  // Inject an opt-in diagnostic command into the same EventChannel used by daemon events. FlutterWindow exposes
  // this only while SYBL_STRESS_CONTROL=1, via WM_COPYDATA, so the stress harness can drive the app without moving
  // the user's physical mouse. The production process has no command surface when that environment variable is
  // absent.
  void SendDiagnosticCommand(const std::string& command);
  void SendInviteLink(const std::string& link);
  bool HandleRemoteWindowMessage(UINT message, WPARAM wparam, LPARAM lparam);
  void ShutdownRemoteControl();
  // Platform-thread window dismissal also retires native onboarding motion.
  void StopWindowShake();
  void SetCaptureFrameBarrier(std::function<void(std::function<void(bool)>)> barrier) {
    capture_frame_barrier_ = std::move(barrier);
  }
  void SetBeforeCapturePolicyChange(std::function<void()> callback) {
    before_capture_policy_change_ = std::move(callback);
  }

 private:
  // One Flutter external (pixel-buffer) texture for a video role. The daemon decoder thread writes `buffer` (via
  // OnVideoFrame) and Flutter's raster thread reads it (via CopyBuffer); `mutex` + the FlutterDesktopPixelBuffer
  // release callback serialize the two so a frame is never half-overwritten while the GPU is uploading it.
  struct VideoTexture {
    int64_t id = -1;
    std::mutex mutex;
    std::vector<uint8_t> buffer;  // latest tightly-packed RGBA (stride == width*4), guarded by mutex
    int width = 0;
    int height = 0;
    FlutterDesktopPixelBuffer fb{};  // reused descriptor returned to Flutter (points into buffer)

    // Raster thread: lock + return the latest buffer; the release callback unlocks once Flutter has copied it.
    const FlutterDesktopPixelBuffer* CopyBuffer();
    static void ReleaseTrampoline(void* ctx);
    // The C pixel-buffer-texture callback: forwards to CopyBuffer() via user_data.
    static const FlutterDesktopPixelBuffer* CopyBufferTrampoline(size_t width, size_t height, void* user_data);
    // Deletes the VideoTexture. Handed to UnregisterExternalTexture as its completion callback so the object is
    // freed only AFTER the engine has erased the texture (raster thread) — never while a CopyBuffer can still fire.
    static void FreeTrampoline(void* ctx);
  };

  void HandleMethodCall(const flutter::MethodCall<flutter::EncodableValue>& call,
                        std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Get-or-create the external texture for role ("self"|"remote"); returns its Flutter texture id (or -1).
  // Platform thread (called from HandleMethodCall).
  int64_t EnsureVideoTexture(const std::string& role);
  // Daemon decoder thread (via jami_bridge's frame sink): copy an RGBA frame into the role's buffer + mark it.
  void OnVideoFrame(const std::string& role, const uint8_t* rgba, int width, int height);

  // Queue a closure to run on the platform (UI) thread, then wake the message-only window to drain it.
  void PostToPlatform(std::function<void()> fn);
  void DrainQueue();  // platform thread only
  void PruneRemoteControlRoles();
  void StartWindowShake();
  void TickWindowShake();

  static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> core_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> appearance_channel_;
  std::unique_ptr<sybl::appearance::Pipe> appearance_pipe_;
  bool appearance_stopping_ = false;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> overlay_channel_;
  std::unique_ptr<sybl::appearance::Pipe> overlay_pipe_;
  std::unique_ptr<sybl::overlay::CompanionInput> overlay_input_;
  std::atomic<uint64_t> overlay_epoch_{0};
  std::atomic<int64_t> overlay_connection_epoch_{0};
  std::atomic<bool> overlay_connected_{false};
  std::mutex overlay_connection_mutex_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> events_;
  // The Dart-side EventChannel listener. Created/cleared in onListen/onCancel and used only from drained
  // closures — i.e. touched ONLY on the platform thread, so it needs no lock.
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> event_sink_;
  std::string pending_invite_link_;
  std::optional<bool> capture_activity_active_;  // platform thread only
  std::unique_ptr<sybl::capture::WindowsCaptureActivityMonitor>
      capture_activity_monitor_;
  std::function<void(std::function<void(bool)>)> capture_frame_barrier_;
  std::function<void()> before_capture_policy_change_;
  uint64_t capture_prompt_request_ = 0;

  HWND msg_window_ = nullptr;  // message-only window; its WndProc runs on the platform thread
  bool device_revoke_timer_ready_ = false;
  bool window_shaking_ = false;
  RECT shake_origin_{};
  POINT shake_position_{};
  ULONGLONG shake_started_ = 0;
  std::mutex queue_mutex_;
  sybl::AnnotationIngress annotation_ingress_;  // guarded by queue_mutex_
  std::deque<std::function<void()>> queue_;  // guarded by queue_mutex_

  // Video textures. Created on the platform thread, read (pointer) on the daemon decoder thread; tex_mutex_ guards
  // the two slot pointers. The slots are created once (idempotent) and reset only at teardown — and the frame sink
  // is cleared before that — so a raw VideoTexture* held past the lock stays valid during normal operation.
  FlutterDesktopTextureRegistrarRef textures_ = nullptr;  // not owned (lives on the engine)
  std::mutex tex_mutex_;
  std::unique_ptr<VideoTexture> self_tex_;
  std::unique_ptr<VideoTexture> remote_tex_;
  sybl::remote::Win32Crypto controller_crypto_;
  std::unique_ptr<sybl::remote::RemoteControlController> remote_controller_;
  std::unique_ptr<sybl::remote::RemoteControlHost> remote_control_;
  sybl::remote::RemoteControlRoleRegistry remote_roles_;
  sybl::annotation::Overlay annotation_overlay_;
  HologramPopup hologram_popup_;
  int64_t hologram_generation_ = -1;
  bool hologram_allowed_ = false;
  std::string hologram_account_;
  ULONGLONG hologram_policy_until_ = 0;
  // The top-level application window whose capture affinity the
  // windowCaptureProtectionStatus / applyWindowCaptureProtection methods
  // read and change. Both run on the platform thread (HandleMethodCall),
  // which owns this HWND — no extra synchronization path.
  const HWND owner_;
};

#endif  // RUNNER_JAMI_CHANNELS_H_
