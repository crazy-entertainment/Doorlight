#include "remote_control_host.h"

#include "remote_control_focus.h"
#include "remote_control_preview.h"
#include "remote_control_cursor.h"
#include "screen_source.h"
#include "identity_color_wire.h"

#include <algorithm>
#include <array>
#include <cstring>
#include <cwchar>
#include <type_traits>
#include <utility>
#include <variant>
#include <vector>

namespace sybl::remote {
namespace {

constexpr UINT kBannerSyncMessage = WM_APP + 0x237;
constexpr UINT kCursorSyncMessage = WM_APP + 0x239;
constexpr UINT_PTR kSafetyTimerId = 0x4d3130;

struct MonitorCollector {
  std::vector<screen_source::Monitor> monitors;
  std::vector<std::wstring> devices;
  int next_index = 0;
};

BOOL CALLBACK CollectMonitor(HMONITOR monitor, HDC, LPRECT, LPARAM data) {
  auto* collector = reinterpret_cast<MonitorCollector*>(data);
  const int index = collector->next_index++;
  MONITORINFOEXW info{};
  info.cbSize = sizeof(info);
  if (!GetMonitorInfoW(monitor, &info)) return TRUE;
  const auto& rect = info.rcMonitor;
  screen_source::Monitor descriptor;
  descriptor.index = index;
  descriptor.left = rect.left;
  descriptor.top = rect.top;
  descriptor.width = rect.right - rect.left;
  descriptor.height = rect.bottom - rect.top;
  if (descriptor.width > 0 && descriptor.height > 0) {
    collector->monitors.push_back(std::move(descriptor));
    // The durable identity, index-aligned with monitors: the positional index
    // and rect cannot distinguish two same-size displays that traded places.
    // Bounded read: szDevice is a fixed WCHAR[CCHDEVICENAME] and is the struct's
    // last member, so an unterminated fill would run off the stack object.
    collector->devices.emplace_back(
        info.szDevice, wcsnlen(info.szDevice, CCHDEVICENAME));
  }
  return TRUE;
}

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) return {};
  const int required = MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0);
  if (required <= 0) return {};
  std::wstring result(static_cast<std::size_t>(required), L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                          static_cast<int>(value.size()), result.data(),
                          required) != required) {
    return {};
  }
  return result;
}

std::map<std::string, std::string> LifecycleFields(
    const std::optional<InboundControlEnvelope>& context,
    const std::string& state,
    const std::string& reason,
    std::uint64_t host_generation) {
  return {
      {"accountId", context ? context->account_id : std::string()},
      {"callId", context ? context->call_id : std::string()},
      {"controllerAccountId",
       context ? context->controller_account : std::string()},
      {"controllerDeviceId",
       context ? context->controller_device : std::string()},
      {"sourceRevision",
       context ? std::to_string(context->source_revision) : "0"},
      {"state", state},
      {"reason", reason},
      {"hostGeneration", std::to_string(host_generation)},
      {"coControl", "false"},
      {"arbitrationMode", "host-priority"},
  };
}

RuntimeReason RuntimeReasonForActivationAbort(
    ActivationAbortReason reason) {
  switch (reason) {
    case ActivationAbortReason::kLocalStop:
      return RuntimeReason::kLocalStop;
    case ActivationAbortReason::kCallEnded:
      return RuntimeReason::kCallEnded;
    case ActivationAbortReason::kSourceChanged:
    case ActivationAbortReason::kSuperseded:
      return RuntimeReason::kSourceChanged;
    case ActivationAbortReason::kShutdown:
      return RuntimeReason::kShutdown;
    case ActivationAbortReason::kNone:
      return RuntimeReason::kNone;
  }
  return RuntimeReason::kSourceChanged;
}

}  // namespace

class RemoteControlHost::Banner final : public BannerVisibilityProbe {
 public:
  Banner(HWND owner, std::function<void(std::uint64_t)> stop)
      : owner_(owner), stop_(std::move(stop)) {
    WNDCLASSW edge_class{};
    edge_class.lpfnWndProc = &Banner::EdgeWndProc;
    edge_class.hInstance = GetModuleHandleW(nullptr);
    edge_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    edge_class.lpszClassName = L"SyblRemoteControlEdge";
    RegisterClassW(&edge_class);
    WNDCLASSW panel_class{};
    panel_class.lpfnWndProc = &Banner::PanelWndProc;
    panel_class.hInstance = edge_class.hInstance;
    panel_class.hCursor = edge_class.hCursor;
    panel_class.hbrBackground = GetSysColorBrush(COLOR_WINDOW);
    panel_class.lpszClassName = L"DoorlightRemoteHelpControls";
    RegisterClassW(&panel_class);
#ifndef WDA_EXCLUDEFROMCAPTURE
#define WDA_EXCLUDEFROMCAPTURE 0x00000011
#endif
    for (auto& edge : edges_) {
      edge = CreateWindowExW(
          WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE |
              WS_EX_TRANSPARENT,
          edge_class.lpszClassName, L"", WS_POPUP, 0, 0, 0, 0, owner_,
          nullptr, edge_class.hInstance, this);
      if (edge && !SetWindowDisplayAffinity(edge, WDA_EXCLUDEFROMCAPTURE))
        SetWindowDisplayAffinity(edge, WDA_MONITOR);
    }
  }

  ~Banner() override {
    if (panel_) DestroyWindow(panel_);
    if (font_) DeleteObject(font_);
    for (auto edge : edges_)
      if (edge) DestroyWindow(edge);
  }

  SafetyObservation Observe() override {
    Win32BannerVisibilityProbe controls(panel_);
    const auto visible = controls.Observe();
    if (visible != SafetyObservation::kSafe) return visible;
    if (!stop_button_ || !IsWindowVisible(stop_button_))
      return SafetyObservation::kUnknown;
    Win32BannerVisibilityProbe probe(edges_.front());
    return probe.Observe();
  }

  void Show(RuntimeState state, RuntimeReason reason,
             const std::string& controller,
             const std::optional<DesktopRect>& source,
             std::uint64_t generation) {
    if (state == RuntimeState::kIdle || !source) {
      for (auto edge : edges_)
        if (edge) ShowWindowAsync(edge, SW_HIDE);
      if (panel_) DestroyWindow(panel_);
      panel_ = nullptr;
      stop_button_ = nullptr;
      return;
    }
    if (panel_ && generation_ != generation) {
      DestroyWindow(panel_);
      panel_ = nullptr;
      stop_button_ = nullptr;
    }
    generation_ = generation;
    if (!panel_) {
      panel_ = CreateWindowExW(
          WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
          L"DoorlightRemoteHelpControls", L"Doorlight remote help", WS_POPUP,
          0, 0, 0, 0, owner_, nullptr, GetModuleHandleW(nullptr), this);
      if (panel_ && !SetWindowDisplayAffinity(panel_, WDA_EXCLUDEFROMCAPTURE) &&
          !SetWindowDisplayAffinity(panel_, WDA_MONITOR)) {
        DestroyWindow(panel_);
        panel_ = nullptr;
      }
      if (panel_) {
        stop_button_ = CreateWindowExW(0, L"BUTTON", L"Stop control",
            WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 0, 0, 0, 0, panel_,
            reinterpret_cast<HMENU>(1), GetModuleHandleW(nullptr), nullptr);
        SendMessageW(stop_button_, WM_SETFONT,
            reinterpret_cast<WPARAM>(font_ ? font_ : GetStockObject(DEFAULT_GUI_FONT)), TRUE);
      }
    }
    const auto name = controller.empty() ? std::string("Your friend") : controller;
    const auto text = name + (state == RuntimeState::kActive
        ? " is helping — control is on" : " is helping — control is paused");
    const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
        text.data(), static_cast<int>(text.size()), nullptr, 0);
    label_.assign(static_cast<std::size_t>(std::max(0, count)), L' ');
    if (count > 0) MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
        text.data(), static_cast<int>(text.size()), label_.data(), count);
    if (panel_) {
      const int dpi = static_cast<int>(GetDpiForWindow(panel_));
      if (!font_ || font_dpi_ != dpi) {
        NONCLIENTMETRICSW metrics{};
        metrics.cbSize = sizeof(metrics);
        if (SystemParametersInfoForDpi(SPI_GETNONCLIENTMETRICS,
              sizeof(metrics), &metrics, 0, static_cast<UINT>(dpi))) {
          if (const auto replacement = CreateFontIndirectW(&metrics.lfMessageFont)) {
            SendMessageW(stop_button_, WM_SETFONT,
                reinterpret_cast<WPARAM>(replacement), TRUE);
            if (font_) DeleteObject(font_);
            font_ = replacement;
            font_dpi_ = dpi;
          }
        }
      }
      const int width = std::min(source->width, MulDiv(440, dpi, 96));
      const int height = MulDiv(104, dpi, 96);
      SetWindowPos(panel_, HWND_TOPMOST,
          source->left + (source->width - width) / 2, source->top + 8,
          width, height, SWP_NOACTIVATE | SWP_SHOWWINDOW);
      SetWindowPos(stop_button_, nullptr, MulDiv(12, dpi, 96),
          MulDiv(62, dpi, 96), width - MulDiv(24, dpi, 96), MulDiv(32, dpi, 96),
          SWP_NOACTIVATE | SWP_NOZORDER);
      InvalidateRect(panel_, nullptr, TRUE);
    }
    edge_color_ = state == RuntimeState::kActive
        ? RGB(42, 190, 88)
        : (reason == RuntimeReason::kPhysicalTakeover
               ? RGB(18, 92, 45)
               : RGB(232, 166, 36));
    constexpr int thickness = 4;
    const std::array<RECT, 4> positions{
        RECT{source->left, source->top, source->left + source->width,
             source->top + thickness},
        RECT{source->left, source->top + source->height - thickness,
             source->left + source->width, source->top + source->height},
        RECT{source->left, source->top, source->left + thickness,
             source->top + source->height},
        RECT{source->left + source->width - thickness, source->top,
             source->left + source->width, source->top + source->height},
    };
    for (std::size_t index = 0; index < edges_.size(); ++index) {
      if (!edges_[index]) continue;
      const auto& rect = positions[index];
      InvalidateRect(edges_[index], nullptr, TRUE);
      SetWindowPos(edges_[index], HWND_TOPMOST, rect.left, rect.top,
                   rect.right - rect.left, rect.bottom - rect.top,
                   SWP_NOACTIVATE | SWP_SHOWWINDOW);
    }
  }

 private:
  static LRESULT CALLBACK PanelWndProc(HWND hwnd, UINT message, WPARAM wparam,
                                       LPARAM lparam) {
    if (message == WM_NCCREATE) {
      const auto* create = reinterpret_cast<CREATESTRUCTW*>(lparam);
      SetWindowLongPtrW(hwnd, GWLP_USERDATA,
          reinterpret_cast<LONG_PTR>(create->lpCreateParams));
    }
    auto* self = reinterpret_cast<Banner*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    if (self && message == WM_COMMAND && LOWORD(wparam) == 1 &&
        HIWORD(wparam) == BN_CLICKED &&
        reinterpret_cast<HWND>(lparam) == self->stop_button_) {
      self->stop_(self->generation_);
      return 0;
    }
    if (self && message == WM_PAINT) {
      PAINTSTRUCT paint{};
      const auto dc = BeginPaint(hwnd, &paint);
      RECT rect{};
      GetClientRect(hwnd, &rect);
      const int dpi = static_cast<int>(GetDpiForWindow(hwnd));
      InflateRect(&rect, -MulDiv(12, dpi, 96), -MulDiv(8, dpi, 96));
      rect.bottom = MulDiv(58, dpi, 96);
      const auto old = SelectObject(dc, self->font_
          ? self->font_ : GetStockObject(DEFAULT_GUI_FONT));
      SetTextColor(dc, GetSysColor(COLOR_WINDOWTEXT));
      SetBkMode(dc, TRANSPARENT);
      DrawTextW(dc, self->label_.data(), static_cast<int>(self->label_.size()),
          &rect, DT_WORDBREAK | DT_END_ELLIPSIS | DT_NOPREFIX);
      SelectObject(dc, old);
      EndPaint(hwnd, &paint);
      return 0;
    }
    return DefWindowProcW(hwnd, message, wparam, lparam);
  }
  static LRESULT CALLBACK EdgeWndProc(HWND hwnd, UINT message, WPARAM wparam,
                                      LPARAM lparam) {
    if (message == WM_NCCREATE) {
      const auto* create = reinterpret_cast<CREATESTRUCTW*>(lparam);
      SetWindowLongPtrW(hwnd, GWLP_USERDATA,
                        reinterpret_cast<LONG_PTR>(create->lpCreateParams));
    }
    auto* self = reinterpret_cast<Banner*>(
        GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    if (message == WM_PAINT) {
      PAINTSTRUCT paint{};
      const auto dc = BeginPaint(hwnd, &paint);
      RECT rect{};
      GetClientRect(hwnd, &rect);
      const auto brush = CreateSolidBrush(
          self ? self->edge_color_ : RGB(232, 166, 36));
      FillRect(dc, &rect, brush);
      DeleteObject(brush);
      EndPaint(hwnd, &paint);
      return 0;
    }
    return DefWindowProcW(hwnd, message, wparam, lparam);
  }

  HWND owner_ = nullptr;
  HWND panel_ = nullptr;
  HWND stop_button_ = nullptr;
  HFONT font_ = nullptr;
  int font_dpi_ = 0;
  std::uint64_t generation_ = 0;
  std::wstring label_;
  std::function<void(std::uint64_t)> stop_;
  std::array<HWND, 4> edges_{};
  COLORREF edge_color_ = RGB(42, 190, 88);
};

class RemoteControlHost::CursorOverlay final {
 public:
  explicit CursorOverlay(HWND owner) {
    WNDCLASSW wc{};
    wc.lpfnWndProc = &CursorOverlay::WndProc;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.lpszClassName = L"SyblRemoteControlCursor";
    RegisterClassW(&wc);
    window_ = CreateWindowExW(
        WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE |
            WS_EX_TRANSPARENT | WS_EX_LAYERED,
        wc.lpszClassName, L"", WS_POPUP, 0, 0, 0, 0, owner, nullptr,
        wc.hInstance, this);
    if (window_)
      SetLayeredWindowAttributes(window_, RGB(255, 0, 255), 0, LWA_COLORKEY);
  }

  ~CursorOverlay() {
    if (window_) DestroyWindow(window_);
  }

  void Show(POINT point, COLORREF color) {
    if (!window_) return;
    color_ = color;
    const auto placement = PlaceRemoteCursor(point.x, point.y);
    InvalidateRect(window_, nullptr, TRUE);
    SetWindowPos(window_, HWND_TOPMOST, placement.left, placement.top,
                 placement.width, placement.height,
                 SWP_NOACTIVATE | SWP_SHOWWINDOW);
  }

  void Hide() {
    if (window_) ShowWindowAsync(window_, SW_HIDE);
  }

 private:
  static LRESULT CALLBACK WndProc(HWND hwnd, UINT message, WPARAM wparam,
                                  LPARAM lparam) {
    if (message == WM_NCCREATE) {
      const auto* create = reinterpret_cast<CREATESTRUCTW*>(lparam);
      SetWindowLongPtrW(hwnd, GWLP_USERDATA,
                        reinterpret_cast<LONG_PTR>(create->lpCreateParams));
    }
    auto* self = reinterpret_cast<CursorOverlay*>(
        GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    if (message == WM_ERASEBKGND) return 1;
    if (message == WM_PAINT) {
      PAINTSTRUCT paint{};
      const auto dc = BeginPaint(hwnd, &paint);
      RECT rect{};
      GetClientRect(hwnd, &rect);
      const auto transparent = CreateSolidBrush(RGB(255, 0, 255));
      FillRect(dc, &rect, transparent);
      DeleteObject(transparent);
      const POINT points[]{{4, 4}, {4, 36}, {11, 29}, {17, 43},
                           {24, 39}, {18, 27}, {30, 27}};
      const auto white = CreateSolidBrush(RGB(255, 255, 255));
      const auto outer = CreatePen(PS_SOLID, 8,
                                   self ? self->color_ : RGB(242, 183, 117));
      const auto old_brush = SelectObject(dc, white);
      const auto old_pen = SelectObject(dc, outer);
      Polygon(dc, points, static_cast<int>(std::size(points)));
      const auto dark = CreatePen(PS_SOLID, 3, RGB(24, 24, 24));
      SelectObject(dc, dark);
      Polygon(dc, points, static_cast<int>(std::size(points)));
      SelectObject(dc, old_pen);
      SelectObject(dc, old_brush);
      DeleteObject(dark);
      DeleteObject(outer);
      DeleteObject(white);
      EndPaint(hwnd, &paint);
      return 0;
    }
    return DefWindowProcW(hwnd, message, wparam, lparam);
  }

  HWND window_ = nullptr;
  COLORREF color_ = RGB(242, 183, 117);
};

RemoteControlHost::RemoteControlHost(HWND owner,
                                     ControlPacketSender sender,
                                     HostEventSink events,
                                     HostAuthorityVerifier authority,
                                     HostDependencies dependencies)
    : owner_(owner),
      sender_(std::move(sender)),
      events_(std::move(events)),
      authority_(std::move(authority)),
      dependencies_(std::move(dependencies)),
      input_({}, dependencies_.cursor_position,
             [this](const DesktopRect& source, const DesktopRect& desktop) {
               return InputSurfaceCurrent(source, desktop);
             }),
      clock_(dependencies_.clock ? *dependencies_.clock : default_clock_),
      default_grants_(grant_storage_, grant_protector_),
      grants_(dependencies_.grants ? *dependencies_.grants : default_grants_),
      secrets_(dependencies_.secrets ? *dependencies_.secrets : crypto_),
      hashes_(dependencies_.hashes ? *dependencies_.hashes : crypto_) {
  if (!dependencies_.banner) {
    banner_ = std::make_unique<Banner>(owner_,
        [this](std::uint64_t generation) { StopGeneration(generation); });
    cursor_overlay_ = std::make_unique<CursorOverlay>(owner_);
  }
  runtime_ = std::make_unique<RemoteControlRuntime>(
      dependencies_.input ? *dependencies_.input : input_, secrets_, hashes_,
      dependencies_.process_privilege ? *dependencies_.process_privilege
                                      : process_privilege_,
      dependencies_.desktop ? *dependencies_.desktop : desktop_,
      dependencies_.banner ? *dependencies_.banner : *banner_,
      dependencies_.hotkey ? *dependencies_.hotkey : hotkey_,
      dependencies_.raw_input ? *dependencies_.raw_input : raw_input_, clock_);
  runtime_->SetEventCallback(
      [this](const RuntimeEvent& event) { HandleRuntimeEvent(event); });
  if (owner_ && !dependencies_.banner)
    SetTimer(owner_, kSafetyTimerId, 100, nullptr);
}

RemoteControlHost::~RemoteControlHost() {
  Shutdown();
  runtime_.reset();
  cursor_overlay_.reset();
  banner_.reset();
}

SessionBinding RemoteControlHost::BindingFor(
    const InboundControlEnvelope& envelope) const {
  return {envelope.call_id, envelope.controller_account,
          envelope.controller_device, envelope.source_revision};
}

bool RemoteControlHost::PendingMatchesLocked(
    const PendingRequest& pending,
    const std::string& call_id,
    const std::string& controller_account,
    const std::string& controller_device,
    std::uint64_t source_revision) const {
  return pending.envelope.call_id == call_id &&
      pending.envelope.controller_account == controller_account &&
      pending.envelope.controller_device == controller_device &&
      pending.envelope.source_revision == source_revision;
}

std::optional<ResolvedSurface> RemoteControlHost::ResolveSurface(
    const InboundControlEnvelope& envelope) const {
  if (dependencies_.resolve_surface)
    return dependencies_.resolve_surface(envelope);
  if (envelope.source_uri.empty() || envelope.source_width <= 0 ||
      envelope.source_height <= 0) {
    return std::nullopt;
  }
  MonitorCollector collector;
  EnumDisplayMonitors(nullptr, nullptr, CollectMonitor,
                      reinterpret_cast<LPARAM>(&collector));
  for (std::size_t i = 0; i < collector.monitors.size(); ++i) {
    const auto& monitor = collector.monitors[i];
    const auto mrl = screen_source::DisplayMrl(monitor);
    if (!mrl || *mrl != envelope.source_uri ||
        monitor.width != envelope.source_width ||
        monitor.height != envelope.source_height) {
      continue;
    }
    DesktopRect source{monitor.left, monitor.top, monitor.width,
                       monitor.height};
    DesktopRect desktop{GetSystemMetrics(SM_XVIRTUALSCREEN),
                        GetSystemMetrics(SM_YVIRTUALSCREEN),
                        GetSystemMetrics(SM_CXVIRTUALSCREEN),
                        GetSystemMetrics(SM_CYVIRTUALSCREEN)};
    if (desktop.width <= 1 || desktop.height <= 1) return std::nullopt;
    return ResolvedSurface{source, desktop, collector.devices[i]};
  }
  return std::nullopt;
}

bool RemoteControlHost::InputSurfaceCurrent(
    const DesktopRect& source, const DesktopRect& virtual_desktop) const {
  // The runtime owns input permission and interruption. This immutable proof
  // owns only the granted mapping. Never take the host mutex from this path:
  // consent publication and clipboard admission use host -> runtime order.
  const auto proof = std::atomic_load_explicit(
      &input_surface_proof_, std::memory_order_acquire);
  if (!proof || !SameSurface(
          ResolvedSurface{source, virtual_desktop, proof->surface.device}, proof->surface))
    return false;
  const auto current = ResolveSurface(proof->envelope);
  return current && SameSurface(*current, proof->surface) &&
         proof == std::atomic_load_explicit(
             &input_surface_proof_, std::memory_order_acquire);
}

void RemoteControlHost::OnControlMessage(InboundControlEnvelope envelope) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (shutdown_) return;
  }
  const auto parsed = ParsePacket(
      envelope.payload, WireDirection::kControllerToControllee);
  if (!parsed) return;
  RefreshPendingPathProof(envelope);
  std::visit(
      [this, &envelope](const auto& message) {
        using T = std::decay_t<decltype(message)>;
        if constexpr (std::is_same_v<T, RequestMessage>) {
          HandleRequest(envelope, message);
        } else if constexpr (std::is_same_v<T, InputMessage>) {
          HandleInput(envelope, message);
        } else if constexpr (std::is_same_v<T, ClipboardOfferMessage>) {
          HandleClipboardOffer(envelope, message);
        } else if constexpr (std::is_same_v<T, ClipboardDataMessage>) {
          HandleClipboardData(envelope, message);
        } else if constexpr (std::is_same_v<T, ClipboardAcceptMessage>) {
          HandleClipboardResponse(envelope, message.id, true);
        } else if constexpr (std::is_same_v<T, ClipboardRejectMessage>) {
          HandleClipboardResponse(envelope, message.id, false);
        } else if constexpr (std::is_same_v<T, EndMessage>) {
          std::optional<SessionBinding> expected;
          std::uint64_t expected_epoch = 0;
          {
            std::lock_guard<std::mutex> lock(mutex_);
            if (pending_ &&
                pending_->envelope.call_id == envelope.call_id &&
                pending_->envelope.controller_account ==
                    envelope.controller_account &&
                pending_->envelope.controller_device ==
                    envelope.controller_device) {
              pending_.reset();
            }
            if (activation_.pending() && active_ &&
                active_->call_id == envelope.call_id &&
                active_->controller_account ==
                    envelope.controller_account &&
                active_->controller_device ==
                    envelope.controller_device) {
              activation_.Cancel(ActivationAbortReason::kLocalStop);
            }
            if (active_ &&
                active_->call_id == envelope.call_id &&
                active_->controller_account ==
                    envelope.controller_account &&
                active_->controller_device ==
                    envelope.controller_device) {
              expected = BindingFor(*active_);
              expected_epoch = active_runtime_epoch_;
            }
          }
          if (expected) {
            runtime_->StopIfBinding(
                *expected, expected_epoch, RuntimeReason::kLocalStop);
          }
        }
        // grant/deny/revoke are rejected by direction parsing.
      },
      *parsed.message);
}

void RemoteControlHost::HandleRequest(const InboundControlEnvelope& envelope,
                                      const RequestMessage& request) {
  if (input_blocked_.load(std::memory_order_acquire) ||
      !runtime_->InputAllowed()) {
    Send(envelope.call_id, Message{DenyMessage{DenyReason::kBusy}});
    return;
  }
  if (!AuthorityValid(envelope)) {
    return;
  }
  if (request.source_revision != envelope.source_revision ||
      !ResolveSurface(envelope)) {
    Send(envelope.call_id, Message{DenyMessage{DenyReason::kUnsupported}});
    return;
  }
  const auto matches_active = [this, &envelope]() {
    return active_ &&
        active_->call_id == envelope.call_id &&
        active_->controller_account == envelope.controller_account &&
        active_->controller_device == envelope.controller_device &&
        active_->source_revision == envelope.source_revision;
  };
  bool occupied = false;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (shutdown_ || input_blocked_.load(std::memory_order_acquire)) return;
    if (activation_.pending() || active_) {
      // A retransmission of the exact request while its local Allow is being
      // activated is a dedupe, not a denial: publishing Deny and then Grant
      // would make the controller retire the very session being granted.
      if (activation_.pending() && matches_active()) return;
      occupied = true;
    }
  }
  if (occupied) {
    Send(envelope.call_id, Message{DenyMessage{DenyReason::kBusy}});
    return;
  }
  if (runtime_->state() != RuntimeState::kIdle) {
    Send(envelope.call_id, Message{DenyMessage{DenyReason::kBusy}});
    return;
  }
  const auto decision = runtime_->ObserveRequest(BindingFor(envelope));
  if (decision != RequestDecision::kPrompt) {
    if (decision == RequestDecision::kCapped)
      Send(envelope.call_id, Message{DenyMessage{DenyReason::kBusy}});
    return;
  }
  // Legacy stored grants are not admission authority in v1.
  constexpr Capabilities kWindowsCapabilities =
      CapabilityBit(Capability::kMouse) |
      CapabilityBit(Capability::kKeyboard) |
      CapabilityBit(Capability::kText) |
      CapabilityBit(Capability::kClipboard);
  const auto supported = static_cast<Capabilities>(
      request.capabilities & kWindowsCapabilities);
  if (supported == 0) {
    Send(envelope.call_id, Message{DenyMessage{DenyReason::kUnsupported}});
    return;
  }
  PendingRequest pending{
      envelope, supported, clock_.NowMs(),
      0, request.identity_color};
  bool busy = false;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (shutdown_ || input_blocked_.load(std::memory_order_acquire)) return;
    if (activation_.pending() || active_) {
      if (activation_.pending() && matches_active()) return;
      busy = true;
    }
    // One visible consent prompt owns the slot. A second authenticated caller
    // cannot replace it and later inherit an already-posted auto-allow.
    if (!busy && pending_) {
      busy = !PendingMatchesLocked(
          *pending_, envelope.call_id, envelope.controller_account,
          envelope.controller_device, envelope.source_revision);
      if (!busy) return;
    } else if (!busy) {
      pending.generation = next_pending_generation_++;
      if (next_pending_generation_ == 0) ++next_pending_generation_;
      pending_ = pending;
    }
  }
  if (busy) {
    Send(envelope.call_id, Message{DenyMessage{DenyReason::kBusy}});
    return;
  }
  EmitRequest(pending);
}

void RemoteControlHost::EmitRequest(const PendingRequest& request) const {
  const auto& envelope = request.envelope;
  // The durable key uses the stable local 40-hex Jami identity carried
  // separately from libjami's internal account id.
  constexpr bool persistent_available = false;
  Emit("remoteControlRequest",
       {{"accountId", envelope.account_id},
        {"callId", envelope.call_id},
        {"controllerAccountId", envelope.controller_account},
        {"controllerDeviceId", envelope.controller_device},
        {"sourceRevision", std::to_string(envelope.source_revision)},
        {"hostGeneration", std::to_string(request.generation)},
        {"controlCapabilities", std::to_string(request.capabilities)},
        {"persistentAvailable", persistent_available ? "true" : "false"}});
}

void RemoteControlHost::HandleInput(const InboundControlEnvelope& envelope,
                                    const InputMessage& input) {
  const auto queued = runtime_->QueueInput(BindingFor(envelope), input);
  if (queued != RuntimeQueueDecision::kQueued) return;
  runtime_->DrainOne();
  if (std::none_of(input.events.begin(), input.events.end(),
                   [](const InputEvent& event) {
                     return std::holds_alternative<MoveEvent>(event);
                   })) {
    return;
  }
  POINT point{};
  if (dependencies_.cursor_position) {
    const auto observed = dependencies_.cursor_position();
    if (!observed) return;
    point = *observed;
  } else if (!GetCursorPos(&point)) {
    return;
  }
  {
    std::lock_guard<std::mutex> lock(mutex_);
    cursor_point_ = point;
  }
  if (owner_) PostMessageW(owner_, kCursorSyncMessage, 0, 0);
}

void RemoteControlHost::RefreshPendingPathProof(
    const InboundControlEnvelope& envelope) {
  const bool unsafe_path =
      envelope.local_ice_path != LocalIcePath::kHostToHost ||
      !envelope.local_lan_proven;
  if (!unsafe_path) return;

  std::lock_guard<std::mutex> arbitration_lock(arbitration_mutex_);
  {
    std::lock_guard<std::mutex> lock(mutex_);
    // A locally observed downgrade is monotonic for the pending transaction.
    // A later packet cannot restore LAN proof and race consent into the looser
    // default.
    if (pending_ &&
        pending_->envelope.call_id == envelope.call_id &&
        pending_->envelope.controller_account ==
            envelope.controller_account &&
        pending_->envelope.controller_device ==
            envelope.controller_device &&
        pending_->envelope.source_revision == envelope.source_revision) {
      pending_->envelope.local_ice_path = envelope.local_ice_path;
      pending_->envelope.local_lan_proven = false;
    }
  }
}

void RemoteControlHost::HandleClipboardOffer(
    const InboundControlEnvelope& envelope,
    const ClipboardOfferMessage& offer) {
  bool displaying;
  { std::lock_guard<std::mutex> lock(mutex_); displaying = pending_clipboard_.has_value(); }
  const auto result = runtime_->ObserveClipboardOffer(BindingFor(envelope), offer);
  if (result == ClipboardDecision::kPrompt && displaying)
    runtime_->RejectClipboard(offer.id);
  if (result == ClipboardDecision::kBusy || (result == ClipboardDecision::kPrompt && displaying))
    Send(envelope.call_id, Message{ClipboardRejectMessage{offer.id}});
}

void RemoteControlHost::HandleClipboardData(
    const InboundControlEnvelope& envelope,
    const ClipboardDataMessage& data) {
  const auto decision =
      runtime_->ReceiveClipboardData(BindingFor(envelope), data);
  if (decision != ClipboardDecision::kReady) {
    if (decision == ClipboardDecision::kInvalid ||
        decision == ClipboardDecision::kExpired ||
        decision == ClipboardDecision::kHashMismatch) {
      Send(envelope.call_id, Message{ClipboardRejectMessage{data.id}});
    }
    return;
  }
  const auto preview = runtime_->PreviewClipboard(data.id);
  if (!preview) return;
  PendingClipboard pending{
      envelope, data.id, SafeClipboardPreview(*preview), preview->size(), 0};
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!active_ || !(BindingFor(*active_) == BindingFor(envelope)) || pending_clipboard_) return;
    pending.generation = next_clipboard_generation_++;
    if (next_clipboard_generation_ == 0) ++next_clipboard_generation_;
    pending_clipboard_ = pending;
  }
  EmitClipboardRequest(pending);
}

void RemoteControlHost::HandleClipboardResponse(
    const InboundControlEnvelope& envelope,
    const std::string& id,
    bool accepted) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (shutdown_ || !active_ ||
        active_->call_id != envelope.call_id ||
        active_->controller_account != envelope.controller_account ||
        active_->controller_device != envelope.controller_device ||
        active_->source_revision != envelope.source_revision ||
        outgoing_clipboards_.erase(id) != 1) {
      return;
    }
  }
  Emit("remoteClipboardHostResult",
       {{"callId", envelope.call_id},
        {"id", id},
        {"state", accepted ? "accepted" : "rejected"},
        {"reason", accepted ? "" : "remote"}});
}

void RemoteControlHost::EmitClipboardRequest(
    const PendingClipboard& request) const {
  const auto& envelope = request.envelope;
  Emit("remoteClipboardRequest",
       {{"accountId", envelope.account_id},
        {"callId", envelope.call_id},
        {"controllerAccountId", envelope.controller_account},
        {"controllerDeviceId", envelope.controller_device},
        {"id", request.id},
        {"promptGeneration", std::to_string(request.generation)},
        {"clipboardBytes", std::to_string(request.bytes)},
        {"preview", request.preview}});
}

LocalControlResult RemoteControlHost::AllowOnce(
    const std::string& call_id,
    const std::string& controller_account,
    const std::string& controller_device,
    std::uint64_t source_revision,
    std::uint64_t host_generation) {
  // A block can interrupt input while waiting for this transaction, but its
  // acknowledgement cannot overtake an activation that could still finish.
  std::lock_guard<std::mutex> authority_lock(authority_mutex_);
  PendingRequest pending;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (shutdown_ || input_blocked_.load(std::memory_order_acquire) ||
        !pending_ ||
        !PendingMatchesLocked(*pending_, call_id, controller_account,
                              controller_device, source_revision) ||
        pending_->generation != host_generation) {
      return LocalControlResult::kStale;
    }
    if (clock_.NowMs() - pending_->received_ms >= kPromptTimeoutMs) {
      pending_.reset();
      return LocalControlResult::kStale;
    }
    pending = *pending_;
  }
  // Consent is a decision about the authority that exists NOW, not merely the
  // authenticated envelope that existed when the prompt was posted.
  if (!AuthorityValid(pending.envelope)) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (pending_ && pending_->generation == pending.generation)
        pending_.reset();
    }
    Send(pending.envelope.call_id,
         Message{DenyMessage{DenyReason::kUnsupported}});
    return LocalControlResult::kUnavailable;
  }
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (shutdown_ || input_blocked_.load(std::memory_order_acquire) ||
        !pending_ ||
        pending_->generation != pending.generation ||
        !PendingMatchesLocked(*pending_, call_id, controller_account,
                              controller_device, source_revision)) {
      return LocalControlResult::kStale;
    }
    if (!activation_.Begin(pending.generation))
      return LocalControlResult::kUnavailable;
    pending_.reset();
    active_ = pending.envelope;
    active_identity_color_ = pending.identity_color;
    active_host_generation_ = pending.generation;
    desired_co_control_ = false;
  }
  const auto surface = ResolveSurface(pending.envelope);
  if (!surface) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (activation_.generation() == pending.generation) {
      active_.reset();
      active_host_generation_ = 0;
      active_runtime_epoch_ = 0;
      active_source_.reset();
      std::atomic_store_explicit(&input_surface_proof_,
          std::shared_ptr<const InputSurfaceProof>{}, std::memory_order_release);
      active_identity_color_.clear();
      cursor_point_.reset();
      desired_co_control_ = false;
      activation_.Clear();
    }
    return LocalControlResult::kUnavailable;
  }
  ShowBanner(RuntimeState::kActive, RuntimeReason::kNone,
             pending.envelope.controller_account, surface->source);
  {
    std::lock_guard<std::mutex> lock(mutex_);
    active_source_ = *surface;
    std::atomic_store_explicit(&input_surface_proof_,
        std::shared_ptr<const InputSurfaceProof>{}, std::memory_order_release);
  }
  const auto grant = runtime_->Activate(
      owner_, BindingFor(pending.envelope), surface->source,
      surface->virtual_desktop, pending.capabilities);
  if (!grant) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (activation_.generation() == pending.generation) {
        active_.reset();
        active_host_generation_ = 0;
        active_runtime_epoch_ = 0;
        active_source_.reset();
        std::atomic_store_explicit(&input_surface_proof_,
            std::shared_ptr<const InputSurfaceProof>{}, std::memory_order_release);
        active_identity_color_.clear();
        cursor_point_.reset();
        desired_co_control_ = false;
        activation_.Clear();
      }
    }
    ShowBanner(RuntimeState::kIdle, RuntimeReason::kNone, {}, std::nullopt);
    return LocalControlResult::kUnavailable;
  }
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (active_host_generation_ == pending.generation) {
      active_runtime_epoch_ = grant->epoch;
    }
  }
  if (!AuthorityValid(pending.envelope)) {
    runtime_->StopIfBinding(grant->binding, grant->epoch,
                            RuntimeReason::kLocalStop);
    return LocalControlResult::kUnavailable;
  }
  // Permission can change during token generation or a durable store write.
  // The routing callback also cancels activation, but this check covers a
  // refreshed authority view before that callback reaches the host.
  if (!AuthorityValid(pending.envelope)) {
    runtime_->StopIfBinding(grant->binding, grant->epoch,
                            RuntimeReason::kLocalStop);
    return LocalControlResult::kUnavailable;
  }
  RuntimeReason cancellation = RuntimeReason::kNone;
  bool mode_reconciled = false;
  bool still_current = false;
  bool sent = false;
  {
    // Arbitration changes and final publication share one ordering lane. A
    // locally observed path downgrade that arrived while Activate was still
    // idle is applied before Grant can be published.
    std::lock_guard<std::mutex> arbitration_lock(arbitration_mutex_);
    bool desired_co_control = false;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      desired_co_control = desired_co_control_;
    }
    if (runtime_->co_control() != desired_co_control) {
      mode_reconciled = runtime_->SetCoControlIfBinding(
          grant->binding, desired_co_control);
    }

    // Keep ConsentActivation pending through persistence and mode
    // reconciliation. A lifecycle callback that wins mutex_ first records its
    // cancellation; only this final serialized block consumes it. Conversely,
    // if publication wins, the later callback queues Revoke after Grant.
    {
      std::lock_guard<std::mutex> lock(mutex_);
      const auto commit = activation_.Commit(pending.generation);
      const auto live = runtime_->grant();
      still_current = commit.current && !shutdown_ &&
          !input_blocked_.load(std::memory_order_acquire) && active_ &&
          active_->call_id == pending.envelope.call_id &&
          active_->controller_account ==
              pending.envelope.controller_account &&
          active_->controller_device ==
              pending.envelope.controller_device &&
          active_->source_revision == pending.envelope.source_revision &&
          live.active && live.binding == grant->binding &&
          live.token == grant->token && live.epoch == grant->epoch;
      if (!still_current) {
        cancellation = commit.reason == ActivationAbortReason::kNone
            ? RuntimeReason::kSourceChanged
            : RuntimeReasonForActivationAbort(commit.reason);
      } else {
        std::atomic_store_explicit(&input_surface_proof_,
            std::make_shared<const InputSurfaceProof>(
                InputSurfaceProof{pending.envelope, *surface}),
            std::memory_order_release);
        sent = Send(call_id, Message{GrantMessage{
                                 grant->token, grant->epoch,
                                 grant->binding.source_revision,
                                 grant->capabilities}});
      }
    }
  }
  if (!still_current) {
    runtime_->StopIfBinding(
        grant->binding, grant->epoch,
        cancellation == RuntimeReason::kNone
            ? RuntimeReason::kSourceChanged
            : cancellation);
    return LocalControlResult::kStale;
  }
  if (!sent) {
    // Local authority must never outlive failure to publish the matching
    // grant. This also releases any held input and retires clipboard state.
    runtime_->StopIfBinding(
        grant->binding, grant->epoch, RuntimeReason::kTransportFailure);
    return LocalControlResult::kUnavailable;
  }
  if (mode_reconciled) {
    auto fields = LifecycleFields(
        pending.envelope, "arbitration", "path-changed",
        pending.generation);
    fields["coControl"] = "false";
    fields["arbitrationMode"] = "host-priority";
    Emit("remoteControlState", std::move(fields));
  }
  // Activation events are held until both persistence and Grant publication
  // succeed. An intermediate runtime grant is not a completed local Allow.
  if (!input_blocked_.load(std::memory_order_acquire)) {
    const auto live = runtime_->grant();
    if (live.active && live.epoch == grant->epoch &&
        live.binding == grant->binding) {
      auto fields = LifecycleFields(pending.envelope, "active", "none",
                                    pending.generation);
      fields["hotkeyAvailable"] =
          runtime_->hotkey_available() ? "true" : "false";
      fields["coControl"] = runtime_->co_control() ? "true" : "false";
      fields["arbitrationMode"] =
          runtime_->co_control() ? "co-control" : "host-priority";
      Emit("remoteControlState", std::move(fields));
      EmitAuthority();
    }
  }
  return LocalControlResult::kApplied;
}

LocalControlResult RemoteControlHost::AllowDevice(
    const std::string& call_id,
    const std::string& controller_account,
    const std::string& controller_device,
    std::uint64_t source_revision,
    std::uint64_t host_generation) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!pending_ ||
        !PendingMatchesLocked(*pending_, call_id, controller_account,
                              controller_device, source_revision) ||
        pending_->generation != host_generation) {
      return LocalControlResult::kStale;
    }
  }
  return LocalControlResult::kUnavailable;
}

bool RemoteControlHost::ForgetDevice(
    const std::string& local_account,
    const std::string& controller_account,
    const std::string& controller_device) {
  return grants_.Remove(PersistentGrantKey{
      local_account, controller_account, controller_device});
}

LocalControlResult RemoteControlHost::Deny(
    const std::string& call_id,
    const std::string& controller_account,
    const std::string& controller_device,
    std::uint64_t source_revision,
    std::uint64_t host_generation) {
  std::optional<InboundControlEnvelope> context;
  std::uint64_t denied_generation = 0;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!pending_ ||
        !PendingMatchesLocked(*pending_, call_id, controller_account,
                              controller_device, source_revision) ||
        pending_->generation != host_generation) {
      return LocalControlResult::kStale;
    }
    context = pending_->envelope;
    denied_generation = pending_->generation;
    pending_.reset();
  }
  Send(call_id, Message{DenyMessage{DenyReason::kUser}});
  Emit("remoteControlState",
       LifecycleFields(context, "denied", "user", denied_generation));
  return LocalControlResult::kApplied;
}

bool RemoteControlHost::Stop() {
  if (!runtime_) return false;
  std::uint64_t change;
  {
    std::lock_guard<std::mutex> surface_lock(surface_mutex_);
    change = ++authority_change_;
    requested_blocked_ = true;
    input_blocked_.store(true, std::memory_order_release);
    runtime_->BlockInput();
  }
  std::lock_guard<std::mutex> authority_lock(authority_mutex_);
  bool current;
  {
    std::lock_guard<std::mutex> surface_lock(surface_mutex_);
    current = change == authority_change_;
  }
  if (current) RevokeAuthority(RuntimeReason::kLocalStop);
  const auto status = AuthorityStatus();
  return status.state == "inactive" && status.release_complete;
}

bool RemoteControlHost::StopGeneration(std::uint64_t generation) {
  std::optional<SessionBinding> expected;
  std::uint64_t epoch = 0;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!active_ || generation == 0 || active_host_generation_ != generation)
      return false;
    expected = BindingFor(*active_);
    epoch = active_runtime_epoch_;
    activation_.Cancel(ActivationAbortReason::kLocalStop);
    revoked_through_ = std::max(revoked_through_, generation);
  }
  return runtime_->StopIfBinding(*expected, epoch, RuntimeReason::kLocalStop);
}

void RemoteControlHost::RevokeAuthority(RuntimeReason reason) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    pending_.reset();
    pending_clipboard_.reset();
    activation_.Cancel(ActivationAbortReason::kLocalStop);
    revoked_through_ = std::max(revoked_through_, next_pending_generation_ - 1);
  }
  runtime_->Stop(reason);
  {
    std::lock_guard<std::mutex> lock(mutex_);
    active_.reset();
    active_host_generation_ = 0;
    active_runtime_epoch_ = 0;
    active_source_.reset();
    std::atomic_store_explicit(&input_surface_proof_,
        std::shared_ptr<const InputSurfaceProof>{}, std::memory_order_release);
    active_identity_color_.clear();
    cursor_point_.reset();
    desired_co_control_ = false;
    activation_.Clear();
  }
  EmitAuthority();
}

HostAuthorityStatus RemoteControlHost::AuthorityStatusLocked() const {
  std::lock_guard<std::mutex> surface_lock(surface_mutex_);
  const auto runtime = runtime_->AuthorityStatus();
  const bool blocked = input_blocked_.load(std::memory_order_acquire) ||
      !runtime.input_allowed;
  return {channel_epoch_, surface_revision_,
          active_host_generation_, revoked_through_,
          blocked,
          runtime.release_complete,
          runtime.grant.active ? (blocked ? "revoking" : "active")
              : (!runtime.release_complete ? "revoking" : "inactive")};
}

HostAuthorityStatus RemoteControlHost::AuthorityStatus() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return AuthorityStatusLocked();
}

void RemoteControlHost::EmitAuthority() const {
  const auto state = AuthorityStatus();
  Emit("remoteControlHostAuthority",
       {{"channelEpoch", std::to_string(state.channel_epoch)},
        {"surfaceRevision", std::to_string(state.surface_revision)},
        {"hostGeneration", std::to_string(state.host_generation)},
        {"revokedThrough", std::to_string(state.revoked_through)},
        {"blocked", state.blocked ? "true" : "false"},
        {"releaseComplete", state.release_complete ? "true" : "false"},
        {"state", state.state}});
}

HostAuthorityStatus RemoteControlHost::ResetAuthorityChannel(bool connected) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (shutdown_) connected = false;
  }
  std::uint64_t change;
  {
    std::lock_guard<std::mutex> surface_lock(surface_mutex_);
    change = ++authority_change_;
    requested_blocked_ = true;
    ++channel_epoch_;
    if (channel_epoch_ == 0) ++channel_epoch_;
    surface_revision_ = 0;
    channel_connected_ = connected;
    input_blocked_.store(true, std::memory_order_release);
    runtime_->BlockInput();
  }
  std::lock_guard<std::mutex> authority_lock(authority_mutex_);
  bool current;
  {
    std::lock_guard<std::mutex> surface_lock(surface_mutex_);
    current = change == authority_change_;
  }
  if (current) RevokeAuthority(RuntimeReason::kProtectedSurface);
  return AuthorityStatus();
}

HostAuthorityStatus RemoteControlHost::SetProtectedSurface(
    std::uint64_t channel_epoch, std::uint64_t surface_revision, bool blocked) {
  std::uint64_t change = 0;
  std::uint64_t runtime_generation = 0;
  bool accepted = false;
  bool same_revision = false;
  {
    // This short lane reserves the latest request before any long activation
    // or adapter wait. An older operation cannot later clear a newer block.
    std::lock_guard<std::mutex> surface_lock(surface_mutex_);
    same_revision = surface_revision == surface_revision_.load();
    if (channel_connected_ && channel_epoch == channel_epoch_ &&
        surface_revision > 0 && surface_revision >= surface_revision_ &&
        (!same_revision || blocked == requested_blocked_) &&
        !(same_revision && !blocked && input_blocked_)) {
      accepted = true;
      change = ++authority_change_;
      surface_revision_ = surface_revision;
      requested_blocked_ = blocked;
      if (blocked) {
        input_blocked_.store(true, std::memory_order_release);
        runtime_->BlockInput();
      }
      runtime_generation = runtime_->block_generation();
    }
  }
  if (!accepted) return AuthorityStatus();
  std::lock_guard<std::mutex> authority_lock(authority_mutex_);
  bool current;
  {
    std::lock_guard<std::mutex> surface_lock(surface_mutex_);
    current = change == authority_change_;
  }
  if (!current) return AuthorityStatus();
  if (blocked) {
    RevokeAuthority(RuntimeReason::kProtectedSurface);
  } else {
    const bool expired = runtime_->PermissionExpired();
    if (input_blocked_.load(std::memory_order_acquire) || expired) {
      {
        std::lock_guard<std::mutex> surface_lock(surface_mutex_);
        if (change != authority_change_) current = false;
        if (current) {
          if (expired && same_revision) {
            ++surface_revision_;
            requested_blocked_ = true;
          }
          input_blocked_.store(true, std::memory_order_release);
          runtime_->BlockInput();
          runtime_generation = runtime_->block_generation();
        }
      }
      if (!current) return AuthorityStatus();
      RevokeAuthority(expired ? RuntimeReason::kLeaseExpired
                              : RuntimeReason::kProtectedSurface);
      if (expired && same_revision) return AuthorityStatus();
    }
    const bool opened = runtime_->SetInputBlocked(
        false, clock_.NowMs() + 1500, runtime_generation);
    {
      std::lock_guard<std::mutex> surface_lock(surface_mutex_);
      if (change == authority_change_)
        input_blocked_.store(!opened, std::memory_order_release);
    }
    EmitAuthority();
  }
  return AuthorityStatus();
}

LocalControlResult RemoteControlHost::SetCoControl(bool enabled) {
  if (!runtime_) return LocalControlResult::kUnavailable;
  std::lock_guard<std::mutex> arbitration_lock(arbitration_mutex_);
  std::optional<InboundControlEnvelope> context;
  SessionBinding expected;
  std::uint64_t host_generation = 0;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    context = active_;
    if (context) expected = BindingFor(*context);
    host_generation = active_host_generation_;
  }
  if (!context) return LocalControlResult::kStale;
  if (!runtime_->SetCoControlIfBinding(expected, enabled))
    return LocalControlResult::kStale;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (shutdown_ || !active_ ||
        BindingFor(*active_) != expected) {
      return LocalControlResult::kStale;
    }
    desired_co_control_ = enabled;
  }
  auto fields =
      LifecycleFields(context, "arbitration", "local", host_generation);
  fields["coControl"] = enabled ? "true" : "false";
  fields["arbitrationMode"] =
      enabled ? "co-control" : "host-priority";
  Emit("remoteControlState", std::move(fields));
  return LocalControlResult::kApplied;
}

LocalControlResult RemoteControlHost::AcceptClipboard(
    const std::string& id,
    std::uint64_t prompt_generation) {
  PendingClipboard pending;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!pending_clipboard_ || pending_clipboard_->id != id ||
        pending_clipboard_->generation != prompt_generation) {
      return LocalControlResult::kStale;
    }
    pending = *pending_clipboard_;
  }
  if (!AuthorityValid(pending.envelope)) return LocalControlResult::kStale;
  const auto accepted = runtime_->AcceptClipboard(id);
  if (!accepted || accepted->id != id ||
      !(accepted->sender == BindingFor(pending.envelope))) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (pending_clipboard_ &&
        pending_clipboard_->generation == prompt_generation) {
      pending_clipboard_.reset();
    }
    return LocalControlResult::kStale;
  }
  bool wrote = false;
  bool still_current = false;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    still_current = pending_clipboard_ &&
        pending_clipboard_->generation == prompt_generation && active_ &&
        BindingFor(*active_) == accepted->sender;
    if (pending_clipboard_ &&
        pending_clipboard_->generation == prompt_generation) {
      pending_clipboard_.reset();
    }
    if (still_current) {
      wrote = WriteClipboardText(accepted->text);
    }
  }
  if (!still_current) {
    Send(pending.envelope.call_id, Message{ClipboardRejectMessage{id}});
    return LocalControlResult::kStale;
  }
  if (!wrote) {
    Send(pending.envelope.call_id, Message{ClipboardRejectMessage{id}});
    Emit("remoteClipboardResult",
         {{"callId", pending.envelope.call_id},
          {"id", id},
          {"promptGeneration", std::to_string(prompt_generation)},
          {"state", "rejected"},
          {"reason", "os-failure"}});
    return LocalControlResult::kUnavailable;
  }
  Send(pending.envelope.call_id, Message{ClipboardAcceptMessage{id}});
  Emit("remoteClipboardResult",
       {{"callId", pending.envelope.call_id},
        {"id", id},
        {"promptGeneration", std::to_string(prompt_generation)},
        {"state", "accepted"}});
  return LocalControlResult::kApplied;
}

LocalControlResult RemoteControlHost::RejectClipboard(
    const std::string& id,
    std::uint64_t prompt_generation) {
  PendingClipboard pending;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!pending_clipboard_ || pending_clipboard_->id != id ||
        pending_clipboard_->generation != prompt_generation) {
      return LocalControlResult::kStale;
    }
    pending = *pending_clipboard_;
  }
  if (runtime_->RejectClipboard(id) != ClipboardDecision::kRejected) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (pending_clipboard_ &&
        pending_clipboard_->generation == prompt_generation) {
      pending_clipboard_.reset();
    }
    return LocalControlResult::kStale;
  }
  bool still_current = false;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    still_current = pending_clipboard_ &&
        pending_clipboard_->generation == prompt_generation && active_ &&
        BindingFor(*active_) == BindingFor(pending.envelope);
    if (pending_clipboard_ &&
        pending_clipboard_->generation == prompt_generation) {
      pending_clipboard_.reset();
    }
  }
  if (!still_current) {
    return LocalControlResult::kStale;
  }
  Send(pending.envelope.call_id, Message{ClipboardRejectMessage{id}});
  return LocalControlResult::kApplied;
}

LocalControlResult RemoteControlHost::SendClipboard(
    const std::string& utf8,
    const std::string& expected_call_id,
    const std::string& expected_controller_account,
    const std::string& expected_controller_device,
    std::uint64_t expected_source_revision,
    std::uint64_t expected_host_generation) {
  if (utf8.empty() || utf8.size() > kMaxClipboardBytes ||
      expected_call_id.empty() || expected_host_generation == 0)
    return LocalControlResult::kStale;
  const SessionBinding expected{expected_call_id, expected_controller_account,
                                expected_controller_device,
                                expected_source_revision};
  const auto id = secrets_.GenerateHex(16);
  const auto hash = hashes_.Sha256Hex(utf8);
  if (!id || !hash) return LocalControlResult::kUnavailable;
  const ClipboardOfferMessage offer{
      *id, *hash, static_cast<std::uint32_t>(utf8.size())};
  const ClipboardDataMessage data{*id, *hash, utf8};
  if (!SerializePacket(Message{offer},
                       WireDirection::kControlleeToController) ||
      !SerializePacket(Message{data},
                       WireDirection::kControlleeToController)) {
    return LocalControlResult::kStale;
  }

  std::string call_id;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto grant = runtime_->grant();
    if (shutdown_ || !active_ || !grant.active ||
        grant.binding != BindingFor(*active_) ||
        active_host_generation_ != expected_host_generation ||
        BindingFor(*active_) != expected ||
        !HasCapability(grant.capabilities, Capability::kClipboard)) {
      return LocalControlResult::kStale;
    }
    if (outgoing_clipboards_.size() >= 8)
      return LocalControlResult::kUnavailable;
    call_id = active_->call_id;
    outgoing_clipboards_[*id] =
        OutgoingClipboard{call_id, clock_.NowMs()};
  }
  if (!Send(call_id, Message{offer}) ||
      !Send(call_id, Message{data})) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      outgoing_clipboards_.erase(*id);
    }
    // If only the offer reached the worker, explicitly retire it when the
    // channel is still writable; otherwise the peer's bounded timeout does.
    (void) Send(call_id, Message{ClipboardRejectMessage{*id}});
    return LocalControlResult::kUnavailable;
  }
  return LocalControlResult::kApplied;
}

void RemoteControlHost::OnCallEnded(const std::string& call_id) {
  std::optional<SessionBinding> expected;
  std::uint64_t expected_epoch = 0;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (pending_ && pending_->envelope.call_id == call_id) pending_.reset();
    if (active_ && active_->call_id == call_id) {
      expected = BindingFor(*active_);
      expected_epoch = active_runtime_epoch_;
      if (activation_.pending()) {
        activation_.Cancel(ActivationAbortReason::kCallEnded);
      }
    }
  }
  if (expected) {
    runtime_->StopIfBinding(
        *expected, expected_epoch, RuntimeReason::kCallEnded);
  }
}

void RemoteControlHost::OnSourceChanged(
    const std::string& call_id,
    std::uint64_t source_revision,
    bool screen_active) {
  std::optional<SessionBinding> expected;
  std::uint64_t expected_epoch = 0;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (pending_ && pending_->envelope.call_id == call_id &&
        (!screen_active ||
         pending_->envelope.source_revision != source_revision)) {
      pending_.reset();
    }
    if (active_ && active_->call_id == call_id &&
        (!screen_active ||
         active_->source_revision != source_revision)) {
      expected = BindingFor(*active_);
      expected_epoch = active_runtime_epoch_;
      if (activation_.pending()) {
        activation_.Cancel(ActivationAbortReason::kSourceChanged);
      }
    }
  }
  if (expected) {
    runtime_->StopIfBinding(
        *expected, expected_epoch, RuntimeReason::kSourceChanged);
  }
}

bool RemoteControlHost::Send(const std::string& call_id,
                             const Message& message) {
  const auto encoded =
      SerializePacket(message, WireDirection::kControlleeToController);
  if (!encoded || call_id.empty() || !sender_) return false;
  try {
    return sender_(call_id, encoded.packet);
  } catch (...) {
    return false;
  }
}

void RemoteControlHost::Emit(
    const std::string& type,
    std::map<std::string, std::string> data) const {
  if (type != "remoteControlHostAuthority") {
    std::lock_guard<std::mutex> lock(mutex_);
    std::lock_guard<std::mutex> surface_lock(surface_mutex_);
    data["channelEpoch"] = std::to_string(channel_epoch_.load());
    data["surfaceRevision"] = std::to_string(surface_revision_.load());
    data["revokedThrough"] = std::to_string(revoked_through_);
  }
  if (!events_) return;
  try {
    events_(type, data);
  } catch (...) {
  }
}

const char* RemoteControlHost::ReasonName(RuntimeReason reason) {
  switch (reason) {
    case RuntimeReason::kProcessPrivilegeUnsafe:
      return "process-privilege-unsafe";
    case RuntimeReason::kProcessPrivilegeUnknown:
      return "process-privilege-unknown";
    case RuntimeReason::kDesktopUnsafe: return "desktop-unsafe";
    case RuntimeReason::kDesktopUnknown: return "desktop-unknown";
    case RuntimeReason::kBannerHidden: return "banner-hidden";
    case RuntimeReason::kBannerUnknown: return "banner-unknown";
    case RuntimeReason::kPhysicalTakeover: return "physical-takeover";
    case RuntimeReason::kLocalStop: return "local-stop";
    case RuntimeReason::kHotkey: return "hotkey";
    case RuntimeReason::kCallEnded: return "call-ended";
    case RuntimeReason::kSourceChanged: return "source-changed";
    case RuntimeReason::kFocusDenied: return "focus-denied";
    case RuntimeReason::kAppForegroundLost: return "app-foreground-lost";
    case RuntimeReason::kRateExceeded: return "rate-exceeded";
    case RuntimeReason::kQueueOverflow: return "queue-overflow";
    case RuntimeReason::kSequenceGap: return "sequence-gap";
    case RuntimeReason::kInputFailure: return "input-failure";
    case RuntimeReason::kTransportFailure: return "transport-failure";
    case RuntimeReason::kProtectedSurface: return "protected-surface";
    case RuntimeReason::kLeaseExpired: return "lease-expired";
    case RuntimeReason::kShutdown: return "shutdown";
    case RuntimeReason::kNone: return "none";
  }
  return "unknown";
}

void RemoteControlHost::HandleRuntimeEvent(const RuntimeEvent& event) {
  std::optional<InboundControlEnvelope> context;
  std::uint64_t host_generation = 0;
  std::vector<std::pair<std::string, OutgoingClipboard>> outgoing;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (event.epoch == 0 || !active_ ||
        BindingFor(*active_) != event.binding ||
        (active_runtime_epoch_ != 0 && active_runtime_epoch_ != event.epoch)) {
      return;
    }
    if (active_runtime_epoch_ == 0) active_runtime_epoch_ = event.epoch;
    if (activation_.pending() && event.type != RuntimeEventType::kRevoked)
      return;
    context = active_;
    host_generation = active_host_generation_;
    if (event.type == RuntimeEventType::kRevoked) {
      revoked_through_ = std::max(revoked_through_, active_host_generation_);
      if (event.reason == RuntimeReason::kLeaseExpired) {
        std::lock_guard<std::mutex> surface_lock(surface_mutex_);
        if (!input_blocked_.load(std::memory_order_acquire)) {
          ++surface_revision_;
          ++authority_change_;
          requested_blocked_ = true;
          input_blocked_.store(true, std::memory_order_release);
          runtime_->BlockInput();
        }
      }
      if (event.reason == RuntimeReason::kProtectedSurface) {
        std::lock_guard<std::mutex> surface_lock(surface_mutex_);
        input_blocked_.store(true, std::memory_order_release);
      }
      active_.reset();
      active_host_generation_ = 0;
      active_runtime_epoch_ = 0;
      active_source_.reset();
      std::atomic_store_explicit(&input_surface_proof_,
          std::shared_ptr<const InputSurfaceProof>{}, std::memory_order_release);
      active_identity_color_.clear();
      cursor_point_.reset();
      pending_clipboard_.reset();
      for (const auto& entry : outgoing_clipboards_)
        outgoing.push_back(entry);
      outgoing_clipboards_.clear();
      desired_co_control_ = false;
      owner_unavailable_since_ms_ = 0;
      activation_.Clear();
    }
  }
  RequestBannerSync();
  if (owner_) PostMessageW(owner_, kCursorSyncMessage, 0, 0);
  if (event.type == RuntimeEventType::kRevoked) {
    if (context) Send(context->call_id, Message{RevokeMessage{}});
    for (const auto& [id, pending] : outgoing) {
      Emit("remoteClipboardHostResult",
           {{"callId", pending.call_id},
            {"id", id},
            {"state", "rejected"},
            {"reason", ReasonName(event.reason)}});
    }
    Emit("remoteControlState",
         LifecycleFields(context, "ended", ReasonName(event.reason),
                         host_generation));
  } else if (event.type == RuntimeEventType::kActivated ||
             event.type == RuntimeEventType::kSuspended ||
             event.type == RuntimeEventType::kResumed) {
    const char* state = event.type == RuntimeEventType::kActivated
        ? "active"
        : (event.type == RuntimeEventType::kSuspended ? "suspended"
                                                      : "active");
    auto fields =
        LifecycleFields(context, state, ReasonName(event.reason),
                        host_generation);
    fields["hotkeyAvailable"] =
        runtime_->hotkey_available() ? "true" : "false";
    fields["coControl"] = runtime_->co_control() ? "true" : "false";
    fields["arbitrationMode"] =
        runtime_->co_control() ? "co-control" : "host-priority";
    Emit("remoteControlState", std::move(fields));
  } else if (event.type == RuntimeEventType::kPhysicalTakeover) {
    auto fields = LifecycleFields(context, "host-priority",
                                  "physical-takeover", host_generation);
    fields["coControl"] = runtime_->co_control() ? "true" : "false";
    fields["arbitrationMode"] =
        runtime_->co_control() ? "co-control" : "host-priority";
    Emit("remoteControlState", std::move(fields));
  }
  EmitAuthority();
}

bool RemoteControlHost::AuthorityValid(
    const InboundControlEnvelope& envelope) const {
  try {
    return !authority_ || authority_(envelope);
  } catch (...) {
    return false;
  }
}

bool RemoteControlHost::OnTrustReduced(
    const std::string& account_id, const std::string& local_jami_id,
    const std::string& controller_account) {
  std::optional<SessionBinding> expected;
  std::optional<PendingRequest> denied;
  std::uint64_t epoch = 0;
  const auto matches = [&](const InboundControlEnvelope& value) {
    return value.account_id == account_id &&
        value.local_jami_id == local_jami_id &&
        value.controller_account == controller_account;
  };
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (pending_ && matches(pending_->envelope)) {
      denied = pending_;
      revoked_through_ = std::max(revoked_through_, pending_->generation);
      pending_.reset();
    }
    if (pending_clipboard_ && matches(pending_clipboard_->envelope))
      pending_clipboard_.reset();
    if (active_ && matches(*active_)) {
      expected = BindingFor(*active_);
      epoch = active_runtime_epoch_;
      activation_.Cancel(ActivationAbortReason::kLocalStop);
      revoked_through_ = std::max(revoked_through_, active_host_generation_);
    }
  }
  // StopIfBinding publishes the exact grant interrupt before waiting for
  // native input. It cannot interrupt a replacement grant.
  if (expected) runtime_->StopIfBinding(*expected, epoch, RuntimeReason::kLocalStop);
  // Fence Allow's persistence and publication before deleting saved consent.
  // Cancellation above runs first even while Allow owns this mutex.
  std::lock_guard<std::mutex> authority_lock(authority_mutex_);
  const bool removed = grants_.RemovePeer(local_jami_id, controller_account);
  const auto status = runtime_->AuthorityStatus();
  const bool released = !expected ||
      (status.release_complete &&
       !(status.grant.active && status.grant.binding == *expected &&
         status.grant.epoch == epoch));
  if (denied) {
    Emit("remoteControlState", LifecycleFields(denied->envelope, "denied",
         "trust-removed", denied->generation));
  }
  Emit("remoteControlTrustRetired",
       {{"accountId", account_id}, {"peerJamiId", controller_account},
        {"grantsRemoved", removed ? "true" : "false"},
        {"releaseComplete", released ? "true" : "false"}});
  EmitAuthority();
  return removed && released;
}

void RemoteControlHost::RequestBannerSync() {
  if (owner_) PostMessageW(owner_, kBannerSyncMessage, 0, 0);
}

void RemoteControlHost::ShowBanner(RuntimeState state, RuntimeReason reason,
                                  const std::string& controller,
                                  std::optional<DesktopRect> source) {
  if (dependencies_.show_banner)
    dependencies_.show_banner(state, reason, controller, source);
  else if (banner_) {
    std::optional<InboundControlEnvelope> active;
    std::uint64_t generation = 0;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      active = active_;
      generation = active_host_generation_;
    }
    const auto name = active && dependencies_.peer_name
        ? dependencies_.peer_name(*active) : std::string("Your friend");
    banner_->Show(state, reason, name, source, generation);
  }
}

void RemoteControlHost::SyncBanner() {
  std::string controller;
  std::optional<DesktopRect> source;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (active_) controller = active_->controller_account;
    if (active_source_) source = active_source_->source;
  }
  ShowBanner(runtime_->state(), runtime_->suspend_reason(), controller, source);
}

void RemoteControlHost::SyncCursor() {
  if (!cursor_overlay_) return;
  std::optional<POINT> point;
  std::string color;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    point = cursor_point_;
    color = active_identity_color_;
  }
  if (!point || runtime_->state() != RuntimeState::kActive) {
    cursor_overlay_->Hide();
    return;
  }
  const auto argb = identity_color_wire::Argb(color);
  if (!argb) {
    cursor_overlay_->Hide();
    return;
  }
  cursor_overlay_->Show(*point,
                        static_cast<COLORREF>(ColorRefFromArgb(*argb)));
}

void RemoteControlHost::ExpirePrompt() {
  std::optional<PendingRequest> expired;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (pending_ &&
        clock_.NowMs() - pending_->received_ms >= kPromptTimeoutMs) {
      expired = *pending_;
      pending_.reset();
    }
  }
  if (!expired) return;
  Send(expired->envelope.call_id,
       Message{DenyMessage{DenyReason::kTimeout}});
  Emit("remoteControlState",
       LifecycleFields(expired->envelope, "denied", "timeout",
                       expired->generation));
}

void RemoteControlHost::ExpireOutgoingClipboards() {
  std::vector<std::pair<std::string, OutgoingClipboard>> expired;
  const auto now = clock_.NowMs();
  {
    std::lock_guard<std::mutex> lock(mutex_);
    for (auto it = outgoing_clipboards_.begin();
         it != outgoing_clipboards_.end();) {
      if (now - it->second.sent_ms >= kClipboardResponseTimeoutMs) {
        expired.push_back(*it);
        it = outgoing_clipboards_.erase(it);
      } else {
        ++it;
      }
    }
  }
  for (const auto& [id, pending] : expired) {
    Emit("remoteClipboardHostResult",
         {{"callId", pending.call_id},
          {"id", id},
          {"state", "rejected"},
          {"reason", "timeout"}});
  }
}

bool RemoteControlHost::HandleWindowMessage(UINT message,
                                            WPARAM wparam,
                                            LPARAM lparam) {
  if (message == kBannerSyncMessage) {
    SyncBanner();
    return true;
  }
  if (message == kCursorSyncMessage) {
    SyncCursor();
    return true;
  }
  if (message == WM_TIMER && wparam == kSafetyTimerId) {
    PollSafety();
    return true;
  }
  if (message == WM_HOTKEY &&
      runtime_->HandleWindowMessage(message, wparam, lparam)) {
    return true;
  }
  if (message == WM_INPUT) runtime_->HandleRawInput(lparam);
  return false;
}

void RemoteControlHost::PollSafety() {
  if (runtime_->PermissionExpired()) {
    std::uint64_t change;
    {
      std::lock_guard<std::mutex> surface_lock(surface_mutex_);
      ++surface_revision_;
      change = ++authority_change_;
      requested_blocked_ = true;
      input_blocked_.store(true, std::memory_order_release);
      runtime_->BlockInput();
    }
    std::lock_guard<std::mutex> authority_lock(authority_mutex_);
    bool current;
    {
      std::lock_guard<std::mutex> surface_lock(surface_mutex_);
      current = change == authority_change_;
    }
    if (current) RevokeAuthority(RuntimeReason::kLeaseExpired);
    return;
  }
  const auto release_complete = runtime_->AuthorityStatus().release_complete;
  ExpirePrompt();
  ExpireOutgoingClipboards();
  std::optional<InboundControlEnvelope> pending_authority;
  std::optional<InboundControlEnvelope> active;
  std::optional<ResolvedSurface> expected;
  std::uint64_t expected_epoch = 0;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (pending_) pending_authority = pending_->envelope;
    active = active_;
    expected = active_source_;
    expected_epoch = active_runtime_epoch_;
  }
  if (pending_authority) AuthorityValid(*pending_authority);
  if (active && expected) {
    if (!AuthorityValid(*active)) {
      runtime_->StopIfBinding(BindingFor(*active), expected_epoch,
                              RuntimeReason::kLocalStop);
      return;
    }
    if (DeniedSensitiveForeground()) {
      runtime_->StopIfBinding(
          BindingFor(*active), expected_epoch, RuntimeReason::kFocusDenied);
      return;
    }
    const auto now = clock_.NowMs();
    if (OwnerWindowAllowsWholeDesktopControl(owner_)) {
      std::lock_guard<std::mutex> lock(mutex_);
      owner_unavailable_since_ms_ = 0;
    } else {
      bool expired = false;
      {
        std::lock_guard<std::mutex> lock(mutex_);
        if (owner_unavailable_since_ms_ == 0)
          owner_unavailable_since_ms_ = now;
        else
          expired = now - owner_unavailable_since_ms_ >=
              kOwnerUnavailableGraceMs;
      }
      if (expired) {
        runtime_->StopIfBinding(
            BindingFor(*active), expected_epoch,
            RuntimeReason::kAppForegroundLost);
        return;
      }
    }
    // Compare the FULL surface identity, not just the source rect: removing
    // another monitor moves the virtual desktop while the shared rect stays
    // byte-identical (absolute injection would silently retarget an unshared
    // display), and two same-size monitors can trade places with only the
    // device name changing (M10 audit 2026-07-27).
    const auto current = ResolveSurface(*active);
    if (!current || !SameSurface(*current, *expected)) {
      runtime_->StopIfBinding(
          BindingFor(*active), expected_epoch, RuntimeReason::kSourceChanged);
      return;
    }
  }
  runtime_->PollSafety();
  if (!release_complete && runtime_->AuthorityStatus().release_complete)
    EmitAuthority();
}

void RemoteControlHost::ReplayPendingEvents() {
  std::optional<PendingRequest> request;
  std::optional<PendingClipboard> clipboard;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (shutdown_ || input_blocked_.load(std::memory_order_acquire)) return;
    request = pending_;
    clipboard = pending_clipboard_;
  }
  if (request &&
      clock_.NowMs() - request->received_ms < kPromptTimeoutMs) {
    EmitRequest(*request);
  }
  if (clipboard && runtime_->PreviewClipboard(clipboard->id))
    EmitClipboardRequest(*clipboard);
}

void RemoteControlHost::Shutdown() {
  {
    std::lock_guard<std::mutex> surface_lock(surface_mutex_);
    ++authority_change_;
    requested_blocked_ = true;
    channel_connected_ = false;
    input_blocked_.store(true, std::memory_order_release);
    if (runtime_) runtime_->BlockInput();
  }
  std::lock_guard<std::mutex> authority_lock(authority_mutex_);
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (shutdown_) return;
    shutdown_ = true;
    pending_.reset();
    pending_clipboard_.reset();
    outgoing_clipboards_.clear();
    desired_co_control_ = false;
    activation_.Cancel(ActivationAbortReason::kShutdown);
  }
  if (runtime_) runtime_->Stop(RuntimeReason::kShutdown);
  // Stop() only PARKS the hotkey unregistration for the owner thread, and this
  // IS the owner thread — so settle it before killing the timer that would
  // otherwise have been the drain point. Without this the release depends on
  // window destruction order rather than on us.
  if (runtime_) runtime_->DrainHotkeyCleanup();
  if (owner_ && !dependencies_.banner) KillTimer(owner_, kSafetyTimerId);
  ShowBanner(RuntimeState::kIdle, RuntimeReason::kNone, {}, std::nullopt);
}

bool RemoteControlHost::OwnsCall(const std::string& call_id) const {
  std::lock_guard<std::mutex> lock(mutex_);
  return !shutdown_ &&
      ((pending_ && pending_->envelope.call_id == call_id) ||
       (active_ && active_->call_id == call_id));
}

void RemoteControlHost::RejectBusy(const std::string& call_id) {
  Send(call_id, Message{DenyMessage{DenyReason::kBusy}});
}

bool RemoteControlHost::WriteClipboardText(const std::string& utf8) const {
  const auto wide = Utf8ToWide(utf8);
  if (wide.empty() && !utf8.empty()) return false;
  const auto bytes = (wide.size() + 1) * sizeof(wchar_t);
  HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, bytes);
  if (!memory) return false;
  void* target = GlobalLock(memory);
  if (!target) {
    GlobalFree(memory);
    return false;
  }
  std::memcpy(target, wide.c_str(), bytes);
  GlobalUnlock(memory);
  if (!OpenClipboard(owner_)) {
    GlobalFree(memory);
    return false;
  }
  bool ok = false;
  if (EmptyClipboard() && SetClipboardData(CF_UNICODETEXT, memory)) {
    ok = true;
    memory = nullptr;  // ownership transferred to the system
  }
  CloseClipboard();
  if (memory) GlobalFree(memory);
  return ok;
}

}  // namespace sybl::remote
