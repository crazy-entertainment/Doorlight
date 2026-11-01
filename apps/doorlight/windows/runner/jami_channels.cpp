#include "jami_channels.h"
#include "window_presentation.h"
#include "win32_window.h"

#include <flutter/event_stream_handler_functions.h>
#include <flutter/standard_method_codec.h>
#include <flutter/method_result_functions.h>
#include "widget_companion.h"

#include <commdlg.h>  // GetOpenFileNameW — the "send a file" picker (M5)
#include <dwmapi.h>
#pragma comment(lib, "Dwmapi.lib")

#include <charconv>
#include <cstring>
#include <map>
#include <set>
#include <string>
#include <variant>
#include <vector>

#include "jami_bridge.h"
#include "picked_file_staging.h"
#include "remote_control_host_channel.h"
#include "screen_source.h"
#include "video_frame_limits.h"
#include "window_capture_protection.h"

namespace {

const wchar_t kMsgWindowClass[] = L"SyblJamiChannelsMsgWindow";
constexpr UINT WM_JAMI_DISPATCH = WM_USER + 1;
constexpr UINT_PTR kDeviceRevocationTimer = 1;
constexpr UINT_PTR kWindowShakeTimer = 2;

bool WriteControllerClipboard(HWND owner, const std::string& utf8) {
  if (!IsWindowVisible(owner) || GetAncestor(GetForegroundWindow(), GA_ROOT) != owner)
    return false;
  HDESK desktop = OpenInputDesktop(0, FALSE, DESKTOP_READOBJECTS);
  if (!desktop) return false;
  wchar_t name[64]{};
  DWORD required = 0;
  const bool unlocked = GetUserObjectInformationW(desktop, UOI_NAME, name,
      sizeof(name), &required) && _wcsicmp(name, L"Default") == 0;
  CloseDesktop(desktop);
  if (!unlocked) return false;
  const int units = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
      utf8.data(), static_cast<int>(utf8.size()), nullptr, 0);
  if (units <= 0) return false;
  HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, (units + 1) * sizeof(wchar_t));
  if (!memory) return false;
  auto* text = static_cast<wchar_t*>(GlobalLock(memory));
  if (!text) { GlobalFree(memory); return false; }
  const bool converted = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
      utf8.data(), static_cast<int>(utf8.size()), text, units) == units;
  text[units] = 0;
  GlobalUnlock(memory);
  if (!converted || !OpenClipboard(owner)) { GlobalFree(memory); return false; }
  const bool wrote = EmptyClipboard() && SetClipboardData(CF_UNICODETEXT, memory);
  CloseClipboard();
  if (!wrote) GlobalFree(memory);
  return wrote;
}

flutter::EncodableValue DeviceRevocationValue(const jami_bridge::DeviceRevocationResult& result) {
  return flutter::EncodableValue(flutter::EncodableMap{
      {flutter::EncodableValue("accountId"), flutter::EncodableValue(result.account_id)},
      {flutter::EncodableValue("deviceId"), flutter::EncodableValue(result.device_id)},
      {flutter::EncodableValue("status"), flutter::EncodableValue(
          sybl::known_device::RevocationStatusName(result.status))},
  });
}

flutter::EncodableMap PairingStateValue(const jami_bridge::DevicePairingState& value) {
  flutter::EncodableMap result;
  for (const auto& entry : std::map<std::string, std::string>{
      {"flowToken", value.flowToken}, {"accountId", value.accountId}, {"ownerAccountId", value.ownerAccountId},
      {"role", value.role}, {"status", value.status}, {"uri", value.uri}, {"code", value.code},
      {"peerId", value.peerId}, {"peerDeviceId", value.peerDeviceId}, {"deviceId", value.deviceId}, {"error", value.error}})
    result[flutter::EncodableValue(entry.first)] = flutter::EncodableValue(entry.second);
  result[flutter::EncodableValue("operation")] = flutter::EncodableValue(static_cast<int64_t>(value.operation));
  result[flutter::EncodableValue("terminal")] = flutter::EncodableValue(value.terminal);
  result[flutter::EncodableValue("invalidCode")] = flutter::EncodableValue(value.invalidCode);
  result[flutter::EncodableValue("recovery")] = flutter::EncodableValue(value.recovery);
  return result;
}

flutter::EncodableValue IdentityRestoreValue(const jami_bridge::Account& value) {
  flutter::EncodableMap result;
  for (const auto& entry : std::map<std::string, std::string>{
      {"status", value.status}, {"accountId", value.accountId}, {"jamiId", value.jamiId},
      {"displayName", value.displayName}, {"avatarBase64", value.avatarBase64},
      {"settingsDocument", value.settingsDocument}, {"restoreToken", value.restoreToken},
      {"backupSourceAccountId", value.backupSourceAccountId}, {"registration", value.registration},
      {"recoveryReason", value.recoveryReason}, {"recoveryOwnerAccountId", value.recoveryOwnerAccountId}})
    result[flutter::EncodableValue(entry.first)] = flutter::EncodableValue(entry.second);
  result[flutter::EncodableValue("enabled")] = flutter::EncodableValue(value.enabled);
  result[flutter::EncodableValue("announced")] = flutter::EncodableValue(value.announced);
  result[flutter::EncodableValue("settingsAlreadyNormalized")] = flutter::EncodableValue(value.settingsAlreadyNormalized);
  result[flutter::EncodableValue("devicePairing")] = flutter::EncodableValue(value.devicePairing);
  result[flutter::EncodableValue("canDiscard")] = flutter::EncodableValue(value.canDiscard);
  if (value.pendingPairing) result[flutter::EncodableValue("pairing")] = flutter::EncodableValue(PairingStateValue(*value.pendingPairing));
  return flutter::EncodableValue(result);
}

// UTF-16 → UTF-8 (file paths from the OS picker travel to Dart / the daemon as UTF-8).
std::string WideToUtf8(const std::wstring& w) {
  if (w.empty()) return std::string();
  int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), static_cast<int>(w.size()), nullptr, 0, nullptr, nullptr);
  std::string s(static_cast<size_t>(n), '\0');
  WideCharToMultiByte(CP_UTF8, 0, w.c_str(), static_cast<int>(w.size()), s.data(), n, nullptr, nullptr);
  return s;
}

// The event keys the Dart layer reads as real BOOLEANS (app_state.dart compares `e.data[k] == true`); a "true"
// STRING would compare false in Dart and silently break the gate. jami_bridge ships every value as a string
// ("true"/"false" for these), so restore them here. Everything else (type/accountId/state/callId/peerJamiId/
// fromJamiId/role) stays a string — matching Android. KEEP THIS SET IN LOCK-STEP with jami_bridge.cpp's Emit
// producers: announced (deviceAnnounced), withVideo (incomingCall), cameraOn (callState/cameraState),
// on (peerVideo), front (cameraFacing), active (video), outgoing (fileProgress/folderFile), downloaded (folderFile). Numeric values
// (transferred/total/size/timestamp — and `status` on presence) ride as strings — the Dart layer parses them
// defensively (_asInt/int.tryParse), matching Android's int payloads.
const std::set<std::string>& BoolKeys() {
  static const std::set<std::string> keys{"announced", "withVideo", "cameraOn", "on", "front",
                                           "active", "outgoing", "downloaded", "live", "hasMore",
                                           "persistentAvailable", "hotkeyAvailable", "coControl",
                                           "blocked", "releaseComplete", "grantsRemoved", "ready"};
  return keys;
}

const std::set<std::string>& IntKeys() {
  static const std::set<std::string> keys{
      "sourceRevision", "controlCapabilities", "clipboardBytes",
      "channelEpoch", "surfaceRevision", "revokedThrough", "hostGeneration"};
  return keys;
}

// Translate a daemon event (flat string map) into the EncodableMap the Dart EventChannel expects.
flutter::EncodableValue ToEventValue(const std::string& type,
                                     const std::map<std::string, std::string>& data) {
  flutter::EncodableMap m;
  m[flutter::EncodableValue("type")] = flutter::EncodableValue(type);
  for (const auto& kv : data) {
    if (BoolKeys().count(kv.first))
      m[flutter::EncodableValue(kv.first)] = flutter::EncodableValue(kv.second == "true");
    else if (IntKeys().count(kv.first)) {
      int64_t value = 0;
      const auto parsed = std::from_chars(
          kv.second.data(), kv.second.data() + kv.second.size(), value);
      if (parsed.ec != std::errc{} ||
          parsed.ptr != kv.second.data() + kv.second.size())
        value = 0;
      m[flutter::EncodableValue(kv.first)] = flutter::EncodableValue(value);
    } else
      m[flutter::EncodableValue(kv.first)] = flutter::EncodableValue(kv.second);
  }
  return flutter::EncodableValue(m);
}

// A bridge JSON-shaped value, one-to-one.
flutter::EncodableValue ToEncodableValue(const jami_bridge::WireValue& value) {
  using Kind = jami_bridge::WireValue::Kind;
  switch (value.kind) {
    case Kind::kBool:
      return flutter::EncodableValue(value.boolean);
    case Kind::kInt:
      return flutter::EncodableValue(value.integer);
    case Kind::kString:
      return flutter::EncodableValue(value.text);
    case Kind::kList: {
      flutter::EncodableList list;
      for (const auto& entry : value.list) list.push_back(ToEncodableValue(entry));
      return flutter::EncodableValue(std::move(list));
    }
    case Kind::kMap: {
      flutter::EncodableMap map;
      for (std::size_t i = 0; i < value.keys.size() && i < value.values.size(); ++i)
        map[flutter::EncodableValue(value.keys[i])] = ToEncodableValue(value.values[i]);
      return flutter::EncodableValue(std::move(map));
    }
    case Kind::kNull:
    default:
      return flutter::EncodableValue();
  }
}

std::string ArgString(const flutter::MethodCall<flutter::EncodableValue>& call, const char* key,
                      const std::string& fallback) {
  if (const auto* args = std::get_if<flutter::EncodableMap>(call.arguments())) {
    auto it = args->find(flutter::EncodableValue(key));
    if (it != args->end())
      if (const auto* s = std::get_if<std::string>(&it->second)) return *s;
  }
  return fallback;
}

std::optional<std::string> ArgExpectedAccountId(
    const flutter::MethodCall<flutter::EncodableValue>& call) {
  if (const auto* args = std::get_if<flutter::EncodableMap>(call.arguments())) {
    const auto it = args->find(flutter::EncodableValue("expectedAccountId"));
    if (it != args->end()) {
      if (const auto* account = std::get_if<std::string>(&it->second)) return *account;
      // A malformed supplied owner is refused by the bridge, never treated as an omitted owner.
      return std::string{};
    }
  }
  return std::nullopt;
}

bool ArgBool(const flutter::MethodCall<flutter::EncodableValue>& call, const char* key, bool fallback) {
  if (const auto* args = std::get_if<flutter::EncodableMap>(call.arguments())) {
    auto it = args->find(flutter::EncodableValue(key));
    if (it != args->end())
      if (const auto* b = std::get_if<bool>(&it->second)) return *b;
  }
  return fallback;
}

// A Dart int arrives as int32_t or int64_t in the standard codec depending on magnitude — accept either.
std::vector<std::string> ArgStringList(const flutter::MethodCall<flutter::EncodableValue>& call,
                                       const char* key) {
  std::vector<std::string> result;
  if (const auto* args = std::get_if<flutter::EncodableMap>(call.arguments())) {
    auto it = args->find(flutter::EncodableValue(key));
    if (it != args->end()) {
      if (const auto* values = std::get_if<flutter::EncodableList>(&it->second)) {
        for (const auto& value : *values)
          if (const auto* text = std::get_if<std::string>(&value)) result.push_back(*text);
      }
    }
  }
  return result;
}

int ArgInt(const flutter::MethodCall<flutter::EncodableValue>& call, const char* key, int fallback) {
  if (const auto* args = std::get_if<flutter::EncodableMap>(call.arguments())) {
    auto it = args->find(flutter::EncodableValue(key));
    if (it != args->end()) {
      if (const auto* i32 = std::get_if<int32_t>(&it->second)) return static_cast<int>(*i32);
      if (const auto* i64 = std::get_if<int64_t>(&it->second)) return static_cast<int>(*i64);
    }
  }
  return fallback;
}

struct MonitorCollector {
  std::vector<screen_source::Monitor> monitors;
  int next_index = 0;
};

BOOL CALLBACK CollectMonitor(HMONITOR monitor, HDC, LPRECT, LPARAM data) {
  auto* collector = reinterpret_cast<MonitorCollector*>(data);
  // EnumDisplayMonitors order is the index consumed by the daemon's dxgigrab
  // source. Advance even when descriptor lookup fails so our indices cannot
  // silently shift onto a different physical display.
  const int index = collector->next_index++;
  MONITORINFOEXW info{};
  info.cbSize = sizeof(info);
  if (!GetMonitorInfoW(monitor, &info)) return TRUE;
  const auto& rect = info.rcMonitor;
  screen_source::Monitor descriptor;
  descriptor.index = index;
  descriptor.id = WideToUtf8(info.szDevice) + "|" + std::to_string(rect.left) + "," +
      std::to_string(rect.top) + "," + std::to_string(rect.right - rect.left) + "," +
      std::to_string(rect.bottom - rect.top);
  descriptor.label = "Display " + std::to_string(index + 1);
  descriptor.primary = (info.dwFlags & MONITORINFOF_PRIMARY) != 0;
  descriptor.left = rect.left;
  descriptor.top = rect.top;
  descriptor.width = rect.right - rect.left;
  descriptor.height = rect.bottom - rect.top;
  if (descriptor.width > 0 && descriptor.height > 0)
    collector->monitors.push_back(std::move(descriptor));
  return TRUE;
}

std::vector<screen_source::Monitor> EnumerateMonitors() {
  MonitorCollector collector;
  EnumDisplayMonitors(nullptr, nullptr, CollectMonitor, reinterpret_cast<LPARAM>(&collector));
  return std::move(collector.monitors);
}

std::optional<sybl::annotation::Surface> ResolveAnnotationSurface(
    const jami_bridge::OwnedScreenSource& source) {
  for (const auto& monitor : EnumerateMonitors()) {
    const auto mrl = screen_source::DisplayMrl(monitor);
    if (mrl && *mrl == source.uri && monitor.width == source.width &&
        monitor.height == source.height) {
      return sybl::annotation::Surface{monitor.left, monitor.top,
                                       monitor.width, monitor.height};
    }
  }
  return std::nullopt;
}

flutter::EncodableList EncodeMonitors(const std::vector<screen_source::Monitor>& monitors) {
  flutter::EncodableList result;
  for (const auto& monitor : monitors) {
    flutter::EncodableMap map;
    map[flutter::EncodableValue("id")] = flutter::EncodableValue(monitor.id);
    map[flutter::EncodableValue("label")] = flutter::EncodableValue(monitor.label);
    map[flutter::EncodableValue("primary")] = flutter::EncodableValue(monitor.primary);
    map[flutter::EncodableValue("left")] = flutter::EncodableValue(monitor.left);
    map[flutter::EncodableValue("top")] = flutter::EncodableValue(monitor.top);
    map[flutter::EncodableValue("width")] = flutter::EncodableValue(monitor.width);
    map[flutter::EncodableValue("height")] = flutter::EncodableValue(monitor.height);
    result.emplace_back(std::move(map));
  }
  return result;
}

int64_t ArgInt64(const flutter::MethodCall<flutter::EncodableValue>& call, const char* key, int64_t fallback) {
  if (const auto* args = std::get_if<flutter::EncodableMap>(call.arguments())) {
    auto it = args->find(flutter::EncodableValue(key));
    if (it != args->end()) {
      if (const auto* i32 = std::get_if<int32_t>(&it->second)) return static_cast<int64_t>(*i32);
      if (const auto* i64 = std::get_if<int64_t>(&it->second)) return *i64;
    }
  }
  return fallback;
}

std::optional<sybl::remote::Capabilities> ArgCapabilities(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    const char* key) {
  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
  if (!args) return std::nullopt;
  const auto it = args->find(flutter::EncodableValue(key));
  if (it == args->end()) return std::nullopt;
  const auto* values = std::get_if<flutter::EncodableList>(&it->second);
  if (!values || values->empty() ||
      values->size() > sybl::remote::kMaxCapabilities) {
    return std::nullopt;
  }
  sybl::remote::Capabilities result = 0;
  for (const auto& value : *values) {
    const auto* name = std::get_if<std::string>(&value);
    if (!name) return std::nullopt;
    sybl::remote::Capability capability;
    if (*name == "mouse")
      capability = sybl::remote::Capability::kMouse;
    else if (*name == "keyboard")
      capability = sybl::remote::Capability::kKeyboard;
    else if (*name == "text")
      capability = sybl::remote::Capability::kText;
    else if (*name == "clipboard")
      capability = sybl::remote::Capability::kClipboard;
    else if (*name == "back")
      capability = sybl::remote::Capability::kBack;
    else if (*name == "home")
      capability = sybl::remote::Capability::kHome;
    else if (*name == "recents")
      capability = sybl::remote::Capability::kRecents;
    else
      return std::nullopt;
    const auto bit = sybl::remote::CapabilityBit(capability);
    if ((result & bit) != 0) return std::nullopt;
    result = static_cast<sybl::remote::Capabilities>(result | bit);
  }
  return result;
}

std::optional<int64_t> EncodableInt(const flutter::EncodableValue& value) {
  if (const auto* i32 = std::get_if<int32_t>(&value))
    return static_cast<int64_t>(*i32);
  if (const auto* i64 = std::get_if<int64_t>(&value)) return *i64;
  return std::nullopt;
}

std::optional<double> EncodableNumber(const flutter::EncodableValue& value) {
  if (const auto* number = std::get_if<double>(&value)) return *number;
  const auto integer = EncodableInt(value);
  if (integer) return static_cast<double>(*integer);
  return std::nullopt;
}

const flutter::EncodableValue* MapValue(const flutter::EncodableMap& map,
                                        const char* key) {
  const auto it = map.find(flutter::EncodableValue(key));
  return it == map.end() ? nullptr : &it->second;
}

std::optional<sybl::annotation::Snapshot> ArgAnnotationSnapshot(
    const flutter::MethodCall<flutter::EncodableValue>& call) {
  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
  if (!args) return std::nullopt;
  sybl::annotation::Snapshot snapshot;
  snapshot.call_id = ArgString(call, "callId", "");
  const int64_t revision = ArgInt64(call, "sourceRevision", 0);
  if (snapshot.call_id.empty() || revision <= 0) return std::nullopt;
  snapshot.source_revision = static_cast<std::uint64_t>(revision);
  const auto* raw_strokes_value = MapValue(*args, "strokes");
  const auto* raw_strokes = raw_strokes_value
      ? std::get_if<flutter::EncodableList>(raw_strokes_value)
      : nullptr;
  if (!raw_strokes ||
      raw_strokes->size() > sybl::annotation::kMaxStrokes) {
    return std::nullopt;
  }
  std::size_t point_count = 0;
  snapshot.strokes.reserve(raw_strokes->size());
  for (const auto& raw_stroke_value : *raw_strokes) {
    const auto* raw_stroke =
        std::get_if<flutter::EncodableMap>(&raw_stroke_value);
    if (!raw_stroke) return std::nullopt;
    const auto* color_value = MapValue(*raw_stroke, "color");
    const auto* width_value = MapValue(*raw_stroke, "width");
    const auto* points_value = MapValue(*raw_stroke, "points");
    const auto color = color_value ? EncodableInt(*color_value) : std::nullopt;
    const auto width =
        width_value ? EncodableNumber(*width_value) : std::nullopt;
    const auto* raw_points =
        points_value ? std::get_if<flutter::EncodableList>(points_value)
                     : nullptr;
    if (!color || *color < 0 ||
        static_cast<std::uint64_t>(*color) > UINT32_MAX || !width ||
        !raw_points || raw_points->empty() ||
        raw_points->size() > sybl::annotation::kMaxPoints ||
        point_count >
            sybl::annotation::kMaxPoints - raw_points->size()) {
      return std::nullopt;
    }
    point_count += raw_points->size();
    sybl::annotation::Stroke stroke;
    stroke.argb = static_cast<std::uint32_t>(*color);
    stroke.width = *width;
    stroke.points.reserve(raw_points->size());
    for (const auto& raw_point_value : *raw_points) {
      const auto* raw_point =
          std::get_if<flutter::EncodableList>(&raw_point_value);
      if (!raw_point || raw_point->size() != 2) return std::nullopt;
      const auto x = EncodableNumber((*raw_point)[0]);
      const auto y = EncodableNumber((*raw_point)[1]);
      if (!x || !y) return std::nullopt;
      stroke.points.push_back({*x, *y});
    }
    snapshot.strokes.push_back(std::move(stroke));
  }
  return snapshot;
}

std::optional<std::vector<sybl::remote::InputEvent>> ArgInputEvents(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    const char* key) {
  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
  if (!args) return std::nullopt;
  const auto it = args->find(flutter::EncodableValue(key));
  if (it == args->end()) return std::nullopt;
  const auto* values = std::get_if<flutter::EncodableList>(&it->second);
  if (!values || values->empty() ||
      values->size() > sybl::remote::kMaxInputEvents) {
    return std::nullopt;
  }
  std::vector<sybl::remote::InputEvent> result;
  result.reserve(values->size());
  for (const auto& raw : *values) {
    const auto* event = std::get_if<flutter::EncodableList>(&raw);
    if (!event || event->empty()) return std::nullopt;
    const auto* type = std::get_if<std::string>(&(*event)[0]);
    if (!type) return std::nullopt;
    if (*type == "m") {
      if (event->size() != 3) return std::nullopt;
      const auto x = EncodableNumber((*event)[1]);
      const auto y = EncodableNumber((*event)[2]);
      if (!x || !y) return std::nullopt;
      result.emplace_back(sybl::remote::MoveEvent{*x, *y});
    } else if (*type == "d" || *type == "u") {
      if (event->size() != 2) return std::nullopt;
      const auto* button = std::get_if<std::string>(&(*event)[1]);
      if (!button) return std::nullopt;
      sybl::remote::MouseButton parsed;
      if (*button == "left")
        parsed = sybl::remote::MouseButton::kLeft;
      else if (*button == "right")
        parsed = sybl::remote::MouseButton::kRight;
      else if (*button == "middle")
        parsed = sybl::remote::MouseButton::kMiddle;
      else if (*button == "x1")
        parsed = sybl::remote::MouseButton::kX1;
      else if (*button == "x2")
        parsed = sybl::remote::MouseButton::kX2;
      else
        return std::nullopt;
      result.emplace_back(
          sybl::remote::ButtonEvent{parsed, *type == "d"});
    } else if (*type == "w") {
      if (event->size() != 2) return std::nullopt;
      const auto delta = EncodableInt((*event)[1]);
      if (!delta || *delta < INT32_MIN || *delta > INT32_MAX)
        return std::nullopt;
      result.emplace_back(
          sybl::remote::WheelEvent{static_cast<int32_t>(*delta)});
    } else if (*type == "k") {
      if (event->size() != 3) return std::nullopt;
      const auto key_code = EncodableInt((*event)[1]);
      const auto* down = std::get_if<bool>(&(*event)[2]);
      if (!key_code || *key_code < 0 || *key_code > UINT16_MAX || !down)
        return std::nullopt;
      result.emplace_back(sybl::remote::KeyEvent{
          static_cast<uint16_t>(*key_code), *down});
    } else if (*type == "t") {
      if (event->size() != 2) return std::nullopt;
      const auto* text = std::get_if<std::string>(&(*event)[1]);
      if (!text) return std::nullopt;
      result.emplace_back(sybl::remote::TextEvent{*text});
    } else if (*type == "a") {
      if (event->size() != 2) return std::nullopt;
      const auto* action = std::get_if<std::string>(&(*event)[1]);
      if (!action) return std::nullopt;
      sybl::remote::GlobalAction parsed;
      if (*action == "back")
        parsed = sybl::remote::GlobalAction::kBack;
      else if (*action == "home")
        parsed = sybl::remote::GlobalAction::kHome;
      else if (*action == "recents")
        parsed = sybl::remote::GlobalAction::kRecents;
      else
        return std::nullopt;
      result.emplace_back(sybl::remote::ActionEvent{parsed});
    } else {
      return std::nullopt;
    }
  }
  return result;
}

}  // namespace

JamiChannels::JamiChannels(flutter::BinaryMessenger* messenger,
                           FlutterDesktopTextureRegistrarRef textures,
                           HWND owner)
    : textures_(textures), owner_(owner) {
  // Message-only window for the daemon-thread -> platform-thread hop. Created on the platform thread, so its
  // WndProc is serviced by the runner's main GetMessage loop (also the platform thread).
  WNDCLASSW wc = {};
  wc.lpfnWndProc = &JamiChannels::WndProc;
  wc.hInstance = GetModuleHandle(nullptr);
  wc.lpszClassName = kMsgWindowClass;
  RegisterClassW(&wc);  // harmless if already registered (single instance) — CreateWindow still succeeds
  msg_window_ = CreateWindowExW(0, kMsgWindowClass, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr,
                                wc.hInstance, this);
  device_revoke_timer_ready_ = msg_window_ &&
      SetTimer(msg_window_, kDeviceRevocationTimer, 250, nullptr) != 0;

  appearance_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "syb.l/appearance_bridge", &flutter::StandardMethodCodec::GetInstance());
  appearance_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    const auto snapshot = call.arguments() ? std::get_if<std::string>(call.arguments()) : nullptr;
    if (call.method_name() != "publish" || !snapshot || !msg_window_ || appearance_stopping_) {
      result->Error("invalid_arguments", "Invalid appearance snapshot");
      return;
    }
    if (!appearance_pipe_) {
      appearance_pipe_ = sybl::appearance::CreateWidgetPipe(
          [this](std::string frame, sybl::appearance::Reply reply, sybl::appearance::Current current) {
        PostToPlatform([this, frame = std::move(frame), reply = std::move(reply),
                        current = std::move(current)] {
          if (appearance_stopping_ || !current()) { reply({}); return; }
          appearance_channel_->InvokeMethod("request", std::make_unique<flutter::EncodableValue>(frame),
              std::make_unique<flutter::MethodResultFunctions<flutter::EncodableValue>>(
                [reply](const auto* response) {
                  const auto line = response ? std::get_if<std::string>(response) : nullptr;
                  reply(line ? *line : std::string{});
                },
                [reply](const auto&, const auto&, const auto*) { reply({}); },
                [reply] { reply({}); }));
        });
      });
    }
    result->Success(flutter::EncodableValue(appearance_pipe_ && appearance_pipe_->Publish(*snapshot)));
  });

  overlay_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "syb.l/overlay_bridge", &flutter::StandardMethodCodec::GetInstance());
  overlay_input_ = std::make_unique<sybl::overlay::CompanionInput>([this](sybl::overlay::InputEvent event) {
    const auto epoch = overlay_epoch_.load();
    const auto lease = overlay_connection_epoch_.load();
    PostToPlatform([this, epoch, lease, event = std::move(event)] {
      if (appearance_stopping_ || !overlay_connected_ || epoch != overlay_epoch_.load() ||
          lease != overlay_connection_epoch_.load()) return;
      flutter::EncodableMap value;
      value[flutter::EncodableValue("type")] = flutter::EncodableValue(event.type);
      value[flutter::EncodableValue("lease")] = flutter::EncodableValue(lease);
      if (event.type == "cursor") {
        value[flutter::EncodableValue("x")] = flutter::EncodableValue(event.x);
        value[flutter::EncodableValue("y")] = flutter::EncodableValue(event.y);
        value[flutter::EncodableValue("mask")] = flutter::EncodableValue(event.mask);
        value[flutter::EncodableValue("eligible")] = flutter::EncodableValue(event.eligible);
      }
      if (!event.action.empty()) value[flutter::EncodableValue("action")] = flutter::EncodableValue(event.action);
      if (event.type == "compose" || event.type == "submit" || event.type == "capture" || event.type == "blocked")
        value[flutter::EncodableValue("text")] = flutter::EncodableValue(event.text);
      if (event.type == "compose" || event.type == "submit" || event.type == "cancel")
        value[flutter::EncodableValue("owner")] = flutter::EncodableValue(event.owner);
      if (event.type == "aim") {
        value[flutter::EncodableValue("button")] = flutter::EncodableValue(event.button);
        value[flutter::EncodableValue("down")] = flutter::EncodableValue(event.down);
      }
      overlay_channel_->InvokeMethod("input", std::make_unique<flutter::EncodableValue>(value));
    });
  });
  overlay_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (appearance_stopping_ || !msg_window_) { result->Error("unavailable", "Overlay bridge unavailable"); return; }
    if (call.method_name() == "configure") {
      const auto* map = call.arguments() ? std::get_if<flutter::EncodableMap>(call.arguments()) : nullptr;
      sybl::overlay::InputConfig config;
      bool valid = map != nullptr;
      auto get = [map](const char* key) -> const flutter::EncodableValue* {
        if (!map) return nullptr;
        const auto found = map->find(flutter::EncodableValue(key));
        return found == map->end() ? nullptr : &found->second;
      };
      auto flag = [&](const char* key, bool& out) {
        const auto* value = get(key); const auto* parsed = value ? std::get_if<bool>(value) : nullptr;
        if (!parsed) valid = false; else out = *parsed;
      };
      flag("enabled", config.enabled); flag("quickChatAllowed", config.quick_chat_allowed); flag("aimToggle", config.aim_toggle);
      const auto* hold_value = get("crossHold");
      const auto* hold = hold_value ? std::get_if<std::string>(hold_value) : nullptr;
      if (!hold) valid = false; else config.cross_hold = *hold;
      const auto* owner_value = get("owner");
      const auto* chat_owner = owner_value ? std::get_if<std::string>(owner_value) : nullptr;
      if (!chat_owner) valid = false; else config.owner = *chat_owner;
      const auto* lease_value = get("lease");
      int64_t lease = -1;
      if (lease_value) {
        if (const auto* wide = std::get_if<int64_t>(lease_value)) lease = *wide;
        else if (const auto* narrow = std::get_if<int32_t>(lease_value)) lease = *narrow;
      }
      if (lease < 0) valid = false;
      const auto* hotkeys_value = get("hotkeys");
      const auto* hotkeys = hotkeys_value ? std::get_if<flutter::EncodableMap>(hotkeys_value) : nullptr;
      if (!hotkeys) valid = false;
      else for (const auto& entry : *hotkeys) {
        const auto* action = std::get_if<std::string>(&entry.first);
        const auto* combo = std::get_if<std::string>(&entry.second);
        if (!action || !combo) { valid = false; break; }
        config.hotkeys[*action] = *combo;
      }
      ++overlay_epoch_;
      // Admission and permission application share the connection transition
      // lock: a reconnect cannot slip between the lease check and Configure.
      std::lock_guard<std::mutex> connection_guard(overlay_connection_mutex_);
      if (config.enabled && (!overlay_connected_ || lease != overlay_connection_epoch_.load())) valid = false;
      if (!valid || !overlay_input_->Configure(std::move(config))) {
        overlay_input_->Configure({});
        result->Error("invalid_arguments", "Invalid overlay input configuration");
      } else result->Success(flutter::EncodableValue(true));
      return;
    }
    if (call.method_name() == "capture") {
      const auto* action = call.arguments() ? std::get_if<std::string>(call.arguments()) : nullptr;
      result->Success(flutter::EncodableValue(action && overlay_input_->Capture(*action))); return;
    }
    if (call.method_name() == "cancel") { overlay_input_->Cancel(); result->Success(); return; }
    const auto* snapshot = call.arguments() ? std::get_if<std::string>(call.arguments()) : nullptr;
    if (call.method_name() != "publish" || !snapshot) {
      result->Error("invalid_arguments", "Invalid overlay snapshot"); return;
    }
    if (!overlay_pipe_) {
      overlay_pipe_ = sybl::appearance::CreateOverlayPipe(
          [this](std::string frame, sybl::appearance::Reply reply, sybl::appearance::Current current) {
        PostToPlatform([this, frame = std::move(frame), reply = std::move(reply), current = std::move(current)] {
          if (appearance_stopping_ || !current()) { reply({}); return; }
          overlay_channel_->InvokeMethod("request", std::make_unique<flutter::EncodableValue>(frame),
              std::make_unique<flutter::MethodResultFunctions<flutter::EncodableValue>>(
                [reply](const auto* response) { const auto* line = response ? std::get_if<std::string>(response) : nullptr; reply(line ? *line : std::string{}); },
                [reply](const auto&, const auto&, const auto*) { reply({}); },
                [reply] { reply({}); }));
        });
      }, [this](bool connected, sybl::appearance::Current current) {
        int64_t lease;
        {
          std::lock_guard<std::mutex> connection_guard(overlay_connection_mutex_);
          overlay_connected_ = false;
          overlay_input_->SetConnected(false);
          ++overlay_epoch_;
          lease = ++overlay_connection_epoch_;
          if (connected) overlay_input_->SetConnected(true);
          overlay_connected_ = connected;
        }
        PostToPlatform([this, connected, lease, current = std::move(current)] {
          if (appearance_stopping_ || lease != overlay_connection_epoch_.load() ||
              (connected && !current())) return;
          flutter::EncodableMap value;
          value[flutter::EncodableValue("type")] = flutter::EncodableValue("connection");
          value[flutter::EncodableValue("connected")] = flutter::EncodableValue(connected);
          value[flutter::EncodableValue("lease")] = flutter::EncodableValue(lease);
          overlay_channel_->InvokeMethod("input", std::make_unique<flutter::EncodableValue>(value));
        });
      });
    }
    result->Success(flutter::EncodableValue(overlay_pipe_ && overlay_pipe_->Publish(*snapshot)));
  });

  // syb.l/core — method calls from Dart (ensureAccount / myJamiId).
  core_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "syb.l/core", &flutter::StandardMethodCodec::GetInstance());
  core_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        HandleMethodCall(call, std::move(result));
      });

  // syb.l/events — daemon events up to Dart (registrationState / deviceAnnounced).
  events_ = std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
      messenger, "syb.l/events", &flutter::StandardMethodCodec::GetInstance());
  events_->SetStreamHandler(
      std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
          [this](const flutter::EncodableValue*,
                 std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events)
              -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
            // onListen — platform thread. Store the sink, then wire jami_bridge's sink to hop here.
            event_sink_ = std::move(events);
            // A new Dart listener cannot inherit a previous isolate's grant
            // or queued unlock. It must complete a fresh surface handshake.
            if (remote_control_) remote_control_->ResetAuthorityChannel(true);
            jami_bridge::SetEventSink(
                [this](const std::string& type, const std::map<std::string, std::string>& data) {
                  // DAEMON thread: snapshot into a closure and hop to the platform thread.
                  size_t annotation_bytes = 0;
                  const auto channel = data.find("channel");
                  if (type == "callMessage" && channel != data.end() && channel->second == "annotation") {
                    const auto payload = data.find("payload");
                    if (payload == data.end()) return;
                    annotation_bytes = payload->second.size();
                    std::lock_guard<std::mutex> lock(queue_mutex_);
                    if (!annotation_ingress_.Admit(annotation_bytes, GetTickCount64())) return;
                  }
                  PostToPlatform([this, type, data, annotation_bytes]() {
                    if (event_sink_) event_sink_->Success(ToEventValue(type, data));
                    if (annotation_bytes) {
                      std::lock_guard<std::mutex> lock(queue_mutex_);
                      annotation_ingress_.Delivered(annotation_bytes);
                    }
                  });
                });
            if (remote_control_) remote_control_->ReplayPendingEvents();
            if (remote_controller_) remote_controller_->ReplayPendingEvents();
            if (!pending_invite_link_.empty() && event_sink_) {
              event_sink_->Success(ToEventValue(
                  "inviteLink", {{"link", pending_invite_link_}}));
              pending_invite_link_.clear();
            }
            if (capture_activity_active_.has_value() && event_sink_) {
              event_sink_->Success(ToEventValue(
                  "captureActivity",
                  {{"active", *capture_activity_active_ ? "true" : "false"},
                   {"source", "captureProductLog"}}));
            }
            return nullptr;
          },
          [this](const flutter::EncodableValue*)
              -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
            // onCancel — platform thread. Detach the bridge sink first, then drop ours.
            if (remote_control_) remote_control_->ResetAuthorityChannel(false);
            PruneRemoteControlRoles();
            jami_bridge::SetEventSink(nullptr);
            event_sink_.reset();
            return nullptr;
          }));

  // Route daemon decoded video frames (self/remote) into the matching external texture. Invoked on a daemon
  // decoder thread; OnVideoFrame copies under the texture's lock + marks the Flutter frame available (both
  // thread-safe). Cleared in the dtor BEFORE the textures are freed.
  jami_bridge::SetVideoFrameSink(
      [this](const std::string& role, const uint8_t* rgba, int w, int h) { OnVideoFrame(role, rgba, w, h); });

  sybl::remote::HostDependencies host_dependencies;
  host_dependencies.peer_name = [](const sybl::remote::InboundControlEnvelope& envelope) {
    return jami_bridge::ControlPeerNameForCall(
        envelope.account_id, envelope.call_id, envelope.controller_account);
  };
  remote_control_ = std::make_unique<sybl::remote::RemoteControlHost>(
      owner,
      [](const std::string& call_id, const std::string& packet) {
        return jami_bridge::SendCallMessage(call_id, packet, "control");
      },
       [this](const std::string& type,
              const std::map<std::string, std::string>& data) {
         PostToPlatform([this, type, data]() {
           if (event_sink_) event_sink_->Success(ToEventValue(type, data));
         });
       },
       [](const sybl::remote::InboundControlEnvelope& envelope) {
         return jami_bridge::RevalidateControlAuthority(
             jami_bridge::ControlSignal{
                 jami_bridge::ControlSignalType::kMessage,
                 envelope.account_id,
                 envelope.call_id,
                 envelope.controller_account,
                 envelope.controller_device,
                 {},
                 envelope.source_uri,
                 envelope.source_revision,
                 envelope.source_width,
                 envelope.source_height,
                 true,
                 envelope.local_ice_path,
                 envelope.local_lan_proven,
                 envelope.local_jami_id,
             });
       }, std::move(host_dependencies));
  remote_controller_ =
      std::make_unique<sybl::remote::RemoteControlController>(
          [](const std::string& call_id, const std::string& packet) {
            return jami_bridge::SendCallMessage(
                call_id, packet, "control");
          },
          [this](const std::string& type,
                 const std::map<std::string, std::string>& data) {
            PostToPlatform([this, type, data]() {
              if (event_sink_)
                event_sink_->Success(ToEventValue(type, data));
            });
          },
          controller_crypto_, controller_crypto_,
          []() { return static_cast<std::uint64_t>(GetTickCount64()); },
          [this](const std::string& account, const std::string& call,
              const std::string& peer, const std::string& device,
              const std::string& text) {
            return jami_bridge::WithControllerClipboardAuthority(account, call, peer, device,
                [this, &text] { return WriteControllerClipboard(owner_, text); });
          });
  jami_bridge::SetControlSink([this](const jami_bridge::ControlSignal& signal) {
    switch (signal.type) {
      case jami_bridge::ControlSignalType::kMessage: {
        if (signal.payload.empty() ||
            signal.payload.size() > sybl::remote::kMaxPacketBytes) break;
        const sybl::remote::InboundControlEnvelope host_envelope{
            signal.accountId,
            signal.callId,
            signal.controllerAccountId,
            signal.controllerDeviceId,
            signal.payload,
            signal.sourceUri,
            signal.sourceRevision,
            signal.sourceWidth,
            signal.sourceHeight,
            signal.localIcePath,
            signal.localLanProven,
            signal.localJamiId,
        };
        const auto host_packet = sybl::remote::ParsePacket(
            signal.payload,
            sybl::remote::WireDirection::kControllerToControllee);
        const bool incoming_request = host_packet &&
            std::holds_alternative<sybl::remote::RequestMessage>(
                *host_packet.message);
        auto role = remote_roles_.RoleFor(signal.callId);
        if (incoming_request) {
          if (role == sybl::remote::LocalControlRole::kController) {
            if (remote_control_) remote_control_->RejectBusy(signal.callId);
            break;
          }
          if (role == sybl::remote::LocalControlRole::kNone &&
              !remote_roles_.TryClaim(
                  signal.callId,
                  sybl::remote::LocalControlRole::kControllee)) {
            if (remote_control_) remote_control_->RejectBusy(signal.callId);
            break;
          }
          if (remote_control_)
            remote_control_->OnControlMessage(host_envelope);
          if (!remote_control_ ||
              !remote_control_->OwnsCall(signal.callId)) {
            remote_roles_.Release(
                signal.callId,
                sybl::remote::LocalControlRole::kControllee);
          }
          break;
        }
        if (role == sybl::remote::LocalControlRole::kController) {
          if (remote_controller_)
            remote_controller_->OnControlMessage(
                sybl::remote::ControllerInboundEnvelope{
                    signal.accountId,
                    signal.callId,
                    signal.controllerAccountId,
                    signal.controllerDeviceId,
                    signal.payload,
                });
          if (!remote_controller_ ||
              !remote_controller_->OwnsCall(signal.callId)) {
            remote_roles_.Release(
                signal.callId,
                sybl::remote::LocalControlRole::kController);
          }
        } else if (role ==
                   sybl::remote::LocalControlRole::kControllee) {
          if (remote_control_)
            remote_control_->OnControlMessage(host_envelope);
          if (!remote_control_ ||
              !remote_control_->OwnsCall(signal.callId)) {
            remote_roles_.Release(
                signal.callId,
                sybl::remote::LocalControlRole::kControllee);
          }
        }
        break;
      }
      case jami_bridge::ControlSignalType::kCallEnded:
        PostToPlatform([this] { annotation_overlay_.Clear(); });
        if (remote_roles_.RoleFor(signal.callId) ==
                sybl::remote::LocalControlRole::kController &&
            remote_controller_)
          remote_controller_->OnCallEnded(signal.callId);
        if (remote_roles_.RoleFor(signal.callId) ==
                sybl::remote::LocalControlRole::kControllee &&
            remote_control_)
          remote_control_->OnCallEnded(signal.callId);
        remote_roles_.Release(
            signal.callId, sybl::remote::LocalControlRole::kController);
        remote_roles_.Release(
            signal.callId, sybl::remote::LocalControlRole::kControllee);
        break;
      case jami_bridge::ControlSignalType::kSourceChanged:
        PostToPlatform([this] { annotation_overlay_.Clear(); });
        if (remote_roles_.RoleFor(signal.callId) ==
                sybl::remote::LocalControlRole::kControllee &&
            remote_control_)
          remote_control_->OnSourceChanged(signal.callId,
                                           signal.sourceRevision,
                                           signal.screenActive);
        PruneRemoteControlRoles();
        break;
      case jami_bridge::ControlSignalType::kTrustReduced: {
        if (remote_controller_)
          remote_controller_->OnTrustReduced(signal.accountId,
                                             signal.controllerAccountId);
        const bool retired = remote_control_ &&
            remote_control_->OnTrustReduced(signal.accountId,
                signal.localJamiId, signal.controllerAccountId);
        PruneRemoteControlRoles();
        return retired;
      }
    }
    return true;
  });

  capture_activity_monitor_ =
      std::make_unique<sybl::capture::WindowsCaptureActivityMonitor>(
          [this](bool active) {
            PostToPlatform([this, active]() {
              capture_activity_active_ = active;
              if (!active) ++capture_prompt_request_;
              if (event_sink_) {
                event_sink_->Success(ToEventValue(
                    "captureActivity",
                    {{"active", active ? "true" : "false"},
                     {"source", "captureProductLog"}}));
              }
            });
          });
  capture_activity_monitor_->Start();
}

JamiChannels::~JamiChannels() {
  appearance_stopping_ = true;
  if (overlay_channel_) overlay_channel_->SetMethodCallHandler(nullptr);
  if (overlay_pipe_) overlay_pipe_->Stop();
  if (overlay_input_) overlay_input_->Stop();
  if (appearance_channel_) appearance_channel_->SetMethodCallHandler(nullptr);
  if (appearance_pipe_) appearance_pipe_->Stop();
  StopWindowShake();
  if (device_revoke_timer_ready_) KillTimer(msg_window_, kDeviceRevocationTimer);
  device_revoke_timer_ready_ = false;
  jami_bridge::CancelKnownDeviceRevocations();
  // Stop first. Its callback posts closures that capture this instance.
  if (capture_activity_monitor_) capture_activity_monitor_->Stop();
  hologram_popup_.Cancel();
  annotation_overlay_.Shutdown();
  jami_bridge::SetControlSink(nullptr);
  if (remote_controller_) remote_controller_->Shutdown();
  if (remote_control_) remote_control_->Shutdown();
  remote_controller_.reset();
  remote_control_.reset();
  // Clear the daemon-side video frame sink (symmetric with SetEventSink). This only swaps the std::function to
  // empty — it does NOT drain an in-flight OnVideoFrame. The guarantee that no decoder thread is inside
  // OnVideoFrame during teardown comes from FlutterWindow::OnDestroy, which runs jami_bridge::Stop() (posts fini()
  // + JOINS the worker; fini destroys the daemon sinks, whose dtors block behind any in-flight push) BEFORE
  // destroying us. The separate raster-thread CopyBuffer path is handled by the async-unregister free below.
  jami_bridge::SetVideoFrameSink(nullptr);
  jami_bridge::SetEventSink(nullptr);
  if (core_) core_->SetMethodCallHandler(nullptr);
  // Flutter's EventChannel destructor does NOT unregister its BinaryMessenger handler (see event_channel.h: the
  // dtor is =default and its own comment says the caller must unregister). The registered listen/cancel lambdas
  // capture `this`, so dropping JamiChannels without clearing leaves a live handler pointing at freed memory — a
  // later cancel/relisten during engine/window teardown would be a use-after-free. Clear it explicitly, symmetric
  // with core_ above, BEFORE we drain and free.
  if (events_) events_->SetStreamHandler(nullptr);
  // Drain BEFORE teardown: a worker completion can be sitting in queue_ (Stop() joins the worker, which runs the
  // completion -> PostToPlatform, but OnDestroy isn't pumping messages). Run them now while the channels are
  // still alive so a pending MethodResult replies instead of being destroyed unanswered (Flutter logs that as a
  // leak). event_sink_ is still set here, so any queued event closures still deliver; reset it afterward.
  DrainQueue();
  event_sink_.reset();

  // Tear down the video textures. UnregisterExternalTexture is ASYNCHRONOUS — the engine erases the texture on its
  // raster thread — and its pixel-buffer callback (CopyBuffer) can still fire on the raster thread until that erase
  // runs. Freeing the VideoTexture synchronously here would let a raster-thread CopyBuffer touch freed memory
  // (lock a destroyed mutex / read a destroyed buffer): a use-after-free on window close. Instead hand ownership to
  // the unregister COMPLETION callback (FreeTrampoline), which the engine invokes after the texture is gone.
  {
    std::lock_guard<std::mutex> lock(tex_mutex_);
    for (auto* slot : {&self_tex_, &remote_tex_}) {
      if (*slot && (*slot)->id != -1 && textures_) {
        VideoTexture* raw = slot->release();  // ownership passes to the completion callback
        FlutterDesktopTextureRegistrarUnregisterExternalTexture(textures_, raw->id, &VideoTexture::FreeTrampoline,
                                                                raw);
      } else {
        slot->reset();
      }
    }
  }

  if (msg_window_) DestroyWindow(msg_window_);
}

void JamiChannels::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  if (method == "widgetCompanionStatus") {
    flutter::EncodableMap status;
    for (const auto& entry : {std::pair{"widgetInstalled", sybl::companion::kWidgetFamily},
                              std::pair{"gameBarInstalled", sybl::companion::kGameBarFamily}}) {
      const auto installed = sybl::companion::Installed(entry.second);
      status[flutter::EncodableValue(entry.first)] = installed
          ? flutter::EncodableValue(*installed) : flutter::EncodableValue();
    }
    result->Success(flutter::EncodableValue(status));
    return;
  }
  if (method == "restoreIdentity" || method == "finalizeIdentityRestore" || method == "discardIdentityRestore" ||
      method == "ensureAccount" || (method == "setAppearOffline" && ArgBool(call, "on", false))) {
    hologram_allowed_ = false;
    hologram_policy_until_ = 0;
    hologram_popup_.Cancel();
  }
  // Another branch in the main chain exceeds MSVC's nested-block limit.
  if (method == "discardIdentityRestore") {
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::DiscardIdentityRestore(ArgString(call, "accountId", ""),
        ArgString(call, "restoreToken", ""), ArgString(call, "expectedAccountId", ""),
        [this, res](bool removed) {
          PostToPlatform([res, removed] { res->Success(flutter::EncodableValue(removed)); });
        });
    return;
  }
  if (method == "remoteControlHostAuthority" ||
      method == "remoteControlSetProtectedSurface") {
    if (!remote_control_) {
      result->Error("control_host_unavailable", "The native control host is unavailable.");
    } else {
      sybl::remote::HandleRemoteControlAuthorityCall(*remote_control_, call, *result);
      PruneRemoteControlRoles();
    }
    return;
  }
  if (method == "setWindowAppearance") {
    const auto* args = call.arguments()
        ? std::get_if<flutter::EncodableMap>(call.arguments()) : nullptr;
    const auto key = flutter::EncodableValue("disaccord");
    const bool* enabled = args && args->size() == 1 && args->count(key)
        ? std::get_if<bool>(&args->at(key)) : nullptr;
    if (!enabled) {
      result->Error("invalid_arguments", "Expected a Disaccord appearance flag.");
    } else if (!owner_ || !::IsWindow(owner_) ||
               !::SendMessageW(owner_, Win32Window::kAppearanceMessage,
                               *enabled ? 1 : 0, 0)) {
      result->Error("window_unavailable", "The application window is gone.");
    } else {
      result->Success();
    }
    return;
  }
  if (method == "setWindowEdgeSpacing") {
    const auto* args = call.arguments()
        ? std::get_if<flutter::EncodableMap>(call.arguments()) : nullptr;
    const auto spacing_key = flutter::EncodableValue("spacing");
    const auto reposition_key = flutter::EncodableValue("reposition");
    const auto* spacing = args && args->size() == 2 && args->count(spacing_key)
        ? std::get_if<std::string>(&args->at(spacing_key)) : nullptr;
    const auto* reposition = args && args->count(reposition_key)
        ? std::get_if<bool>(&args->at(reposition_key)) : nullptr;
    if (!spacing || (*spacing != "close" && *spacing != "floating") || !reposition) {
      result->Error("invalid_arguments", "Expected edge spacing and a reposition flag.");
    } else if (!owner_ || !::IsWindow(owner_) ||
        !::SendMessageW(owner_, kWindowEdgeSpacingMessage,
                       *spacing == "floating" ? 24 : 8, *reposition ? 1 : 0)) {
      result->Error("window_unavailable", "Could not apply window edge spacing.");
    } else {
      result->Success();
    }
    return;
  }
  if (method == "windowPresentationState") {
    if (!owner_ || !::IsWindow(owner_)) {
      result->Error("window_unavailable", "The application window is gone.");
    } else {
      const LRESULT state = ::SendMessageW(owner_, kWindowPresentationStateMessage, 0, 0);
      result->Success(flutter::EncodableValue(flutter::EncodableMap{
          {flutter::EncodableValue("compact"), flutter::EncodableValue((state & 1) != 0)},
          {flutter::EncodableValue("defaultSize"), flutter::EncodableValue((state & 2) != 0)},
          {flutter::EncodableValue("animating"), flutter::EncodableValue((state & 4) != 0)}}));
    }
    return;
  }
  if (method == "ensureAccount") {
    const std::string display_name = ArgString(call, "displayName", "Me");
    const std::string preferred_account = ArgString(call, "preferredAccountId", "");
    const std::string preferred_peer = ArgString(call, "preferredPeerId", "");
    const bool create_if_missing = ArgBool(call, "createIfMissing", false);
    // MethodResult is move-only; share it into the worker completion which fulfills it after the hop back.
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    // A visible retry does not recreate this process. Queue boot reconciliation first; both tasks share the daemon
    // worker, so EnsureAccount cannot overtake it.
    jami_bridge::RetryBoot();
    jami_bridge::EnsureAccount(display_name, preferred_account, preferred_peer,
                               create_if_missing,
                               [this, res](const jami_bridge::Account& a) {
      // WORKER thread -> hop to the platform thread to touch the channel reply.
      PostToPlatform([res, a]() {
        if (a.status == "error") {
          res->Error("native_startup_failed", "Native engine is unavailable");
          return;
        }
        flutter::EncodableMap m;
        m[flutter::EncodableValue("status")] = flutter::EncodableValue(a.status);
        m[flutter::EncodableValue("accountId")] = flutter::EncodableValue(a.accountId);
        m[flutter::EncodableValue("jamiId")] = flutter::EncodableValue(a.jamiId);
        m[flutter::EncodableValue("displayName")] = flutter::EncodableValue(a.displayName);
        m[flutter::EncodableValue("avatarBase64")] = flutter::EncodableValue(a.avatarBase64);
        m[flutter::EncodableValue("enabled")] = flutter::EncodableValue(a.enabled);
        m[flutter::EncodableValue("announced")] = flutter::EncodableValue(a.announced);
        m[flutter::EncodableValue("registration")] = flutter::EncodableValue(a.registration);
        res->Success(flutter::EncodableValue(m));
      });
    });
  } else if (method == "loadSendJournal") {
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::LoadSendJournal([this, res](bool healthy, std::optional<std::string> source) {
      PostToPlatform([res, healthy, source]() {
        if (!healthy) res->Error("journal_unavailable", "Send recovery is unavailable.");
        else if (source) res->Success(flutter::EncodableValue(*source));
        else res->Success();
      });
    });
  } else if (method == "saveSendJournal") {
    const auto source = ArgString(call, "source", "");
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::SaveSendJournal(source, [this, res](bool saved) {
      PostToPlatform([res, saved]() { res->Success(flutter::EncodableValue(saved)); });
    });
  } else if (method == "myJamiId") {
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::MyJamiId([this, res](const std::string& jid) {
      PostToPlatform([res, jid]() { res->Success(flutter::EncodableValue(jid)); });
    });
  } else if (method == "replayPendingNativeEvents") {
    result->Success(flutter::EncodableValue(jami_bridge::ReplayPendingNativeEvents()));
  } else if (method == "getPeerId") {
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::PeerId([this, res](const std::string& id) {
      PostToPlatform([res, id]() { res->Success(flutter::EncodableValue(id)); });
    });
  } else if (method == "listFriends") {
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::ListFriends([this, res](const jami_bridge::FriendList& value) {
      PostToPlatform([res, value]() {
        flutter::EncodableList friends;
        for (const auto& friendValue : value.friends) {
          flutter::EncodableMap item;
          item[flutter::EncodableValue("peerJamiId")] = flutter::EncodableValue(friendValue.peerJamiId);
          item[flutter::EncodableValue("confirmed")] = flutter::EncodableValue(friendValue.confirmed);
          item[flutter::EncodableValue("conversationId")] =
              flutter::EncodableValue(friendValue.conversationId);
          item[flutter::EncodableValue("displayName")] =
              flutter::EncodableValue(friendValue.displayName);
          item[flutter::EncodableValue("avatarBase64")] =
              flutter::EncodableValue(friendValue.avatarBase64);
          friends.emplace_back(item);
        }
        flutter::EncodableList groups;
        for (const auto& groupValue : value.groups) {
          flutter::EncodableList members;
          for (const auto& memberValue : groupValue.members) {
            flutter::EncodableMap member;
            member[flutter::EncodableValue("peerJamiId")] =
                flutter::EncodableValue(memberValue.peerJamiId);
            member[flutter::EncodableValue("role")] =
                flutter::EncodableValue(memberValue.role);
            member[flutter::EncodableValue("displayName")] =
                flutter::EncodableValue(memberValue.displayName);
            member[flutter::EncodableValue("avatarBase64")] =
                flutter::EncodableValue(memberValue.avatarBase64);
            members.emplace_back(member);
          }
          flutter::EncodableMap item;
          item[flutter::EncodableValue("conversationId")] =
              flutter::EncodableValue(groupValue.conversationId);
          item[flutter::EncodableValue("title")] =
              flutter::EncodableValue(groupValue.title);
          item[flutter::EncodableValue("description")] =
              flutter::EncodableValue(groupValue.description);
          item[flutter::EncodableValue("memberCount")] =
              flutter::EncodableValue(groupValue.memberCount);
          item[flutter::EncodableValue("canManageMembers")] =
              flutter::EncodableValue(groupValue.canManageMembers);
          item[flutter::EncodableValue("localRole")] =
              flutter::EncodableValue(groupValue.localRole);
          item[flutter::EncodableValue("members")] =
              flutter::EncodableValue(members);
          groups.emplace_back(item);
        }
        flutter::EncodableMap response;
        response[flutter::EncodableValue("revision")] =
            flutter::EncodableValue(static_cast<int64_t>(value.revision));
        response[flutter::EncodableValue("friends")] = flutter::EncodableValue(friends);
        response[flutter::EncodableValue("groups")] = flutter::EncodableValue(groups);
        res->Success(flutter::EncodableValue(response));
      });
    });
  } else if (method == "listKnownDevices") {
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(
        std::move(result));
    jami_bridge::ListKnownDevices(
        [this, res](const jami_bridge::KnownDeviceList& devices) {
          PostToPlatform([res, devices]() {
            flutter::EncodableList response;
            for (const auto& device : devices) {
              flutter::EncodableMap item;
              item[flutter::EncodableValue("id")] =
                  flutter::EncodableValue(device.id);
              item[flutter::EncodableValue("name")] =
                  flutter::EncodableValue(device.name);
              item[flutter::EncodableValue("current")] =
                  flutter::EncodableValue(device.current);
              response.emplace_back(item);
            }
            res->Success(flutter::EncodableValue(response));
          });
        });
  } else if (method == "revokeKnownDevice") {
    const auto account_id = ArgString(call, "accountId", "");
    const auto device_id = ArgString(call, "deviceId", "");
    if (!device_revoke_timer_ready_) {
      result->Success(DeviceRevocationValue({account_id, device_id,
          sybl::known_device::RevocationStatus::kUnavailable}));
      return;
    }
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(
        std::move(result));
    jami_bridge::RevokeKnownDevice(account_id, device_id,
        [this, res](const jami_bridge::DeviceRevocationResult& value) {
      PostToPlatform([res, value]() { res->Success(DeviceRevocationValue(value)); });
    });
  } else if (method == "updateProfile") {
    const std::string display_name = ArgString(call, "displayName", "");
    const std::string avatar = ArgString(call, "avatar", "");
    const std::string file_type = ArgString(call, "fileType", "");
    const int flag = static_cast<int>(ArgInt64(call, "flag", -1));
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(
        std::move(result));
    jami_bridge::UpdateProfile(
        display_name, avatar, file_type, flag, ArgExpectedAccountId(call), [this, res](bool ok) {
          PostToPlatform(
              [res, ok]() { res->Success(flutter::EncodableValue(ok)); });
        });
  } else if (method == "addFriend") {
    const std::string peer = ArgString(call, "peerJamiId", "");
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::AddFriend(peer, ArgExpectedAccountId(call), [this, res](bool ok) {
      PostToPlatform([res, ok]() { res->Success(flutter::EncodableValue(ok)); });
    });
  } else if (method == "createGroup") {
    const auto title = ArgString(call, "title", "");
    const auto members = ArgStringList(call, "memberIds");
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(
        std::move(result));
    jami_bridge::CreateGroup(
        title, members, ArgExpectedAccountId(call), [this, res](const std::string& conversation_id) {
          PostToPlatform([res, conversation_id]() {
            res->Success(flutter::EncodableValue(conversation_id));
          });
        });
  } else if (method == "addGroupMembers") {
    const auto conversation_id =
        ArgString(call, "conversationId", "");
    const auto members = ArgStringList(call, "memberIds");
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(
        std::move(result));
    jami_bridge::AddGroupMembers(
        conversation_id, members, ArgExpectedAccountId(call), [this, res](bool ok) {
          PostToPlatform([res, ok]() {
            res->Success(flutter::EncodableValue(ok));
          });
        });
  } else if (method == "removeGroupMember") {
    const auto conversation_id =
        ArgString(call, "conversationId", "");
    const auto member_id = ArgString(call, "memberId", "");
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(
        std::move(result));
    jami_bridge::RemoveGroupMember(
        conversation_id, member_id, ArgExpectedAccountId(call), [this, res](bool ok) {
          PostToPlatform([res, ok]() {
            res->Success(flutter::EncodableValue(ok));
          });
        });
  } else if (method == "renameGroup") {
    const auto conversation_id =
        ArgString(call, "conversationId", "");
    const auto title = ArgString(call, "title", "");
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(
        std::move(result));
    jami_bridge::RenameGroup(
        conversation_id, title, ArgExpectedAccountId(call), [this, res](bool ok) {
          PostToPlatform([res, ok]() {
            res->Success(flutter::EncodableValue(ok));
          });
        });
  } else if (method == "updateGroupLayout") {
    const auto conversation_id =
        ArgString(call, "conversationId", "");
    const auto description = ArgString(call, "description", "");
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(
        std::move(result));
    jami_bridge::UpdateGroupLayout(
        conversation_id, description, ArgExpectedAccountId(call), [this, res](bool ok) {
          PostToPlatform([res, ok]() {
            res->Success(flutter::EncodableValue(ok));
          });
        });
  } else if (method == "leaveGroup") {
    const auto conversation_id =
        ArgString(call, "conversationId", "");
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(
        std::move(result));
    jami_bridge::LeaveGroup(
        conversation_id, ArgExpectedAccountId(call), [this, res](bool ok) {
          PostToPlatform([res, ok]() {
            res->Success(flutter::EncodableValue(ok));
          });
        });
  } else if (method == "setPresenceSubscriptions") {
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::SetPresenceSubscriptions(
        ArgStringList(call, "peerJamiIds"), [this, res](bool ok) {
          PostToPlatform([res, ok]() {
            res->Success(flutter::EncodableValue(ok));
          });
        });
  } else if (method == "probeReachable") {
    const std::string peer = ArgString(call, "peerJamiId", "");
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::ProbeReachable(peer, [this, res](const std::string& id) {
      PostToPlatform([res, id]() { res->Success(flutter::EncodableValue(id)); });
    });
  } else if (method == "sendComposerActivity") {
    const std::string account_id = ArgString(call, "accountId", "");
    const std::string peer = ArgString(call, "peerJamiId", "");
    const std::string conversation_id =
        ArgString(call, "conversationId", "");
    const std::string kind = ArgString(call, "kind", "");
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(
        std::move(result));
    jami_bridge::SendComposerActivity(account_id, peer, conversation_id, kind, [this, res](bool ok) {
      PostToPlatform(
          [res, ok]() { res->Success(flutter::EncodableValue(ok)); });
    });
  } else if (method == "sendFileThumbnail") {
    const std::string peer = ArgString(call, "peerJamiId", "");
    const std::string conversation_id =
        ArgString(call, "conversationId", "");
    const std::string file_id = ArgString(call, "fileId", "");
    const std::string png_base64 = ArgString(call, "pngBase64", "");
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(
        std::move(result));
    jami_bridge::SendFileThumbnail(
        peer, conversation_id, file_id, png_base64, [this, res](bool ok) {
          PostToPlatform(
              [res, ok]() { res->Success(flutter::EncodableValue(ok)); });
        });
  } else if (method == "setHologramPrivacy") {
    const auto generation = ArgInt64(call, "generation", -1);
    if (generation > hologram_generation_) {
      hologram_popup_.Cancel();
      hologram_generation_ = generation;
      hologram_account_ = ArgString(call, "accountId", "");
      hologram_allowed_ = ArgBool(call, "enabled", false) && !hologram_account_.empty();
      hologram_policy_until_ = 0;
    }
    result->Success();
  } else if (method == "hologramPresentationState") {
    const auto generation = ArgInt64(call, "generation", -1);
    const auto account = ArgString(call, "accountId", "");
    const auto authority = jami_bridge::HologramPresentationAuthority(account,
        ArgString(call, "peerJamiId", ""), ArgString(call, "conversationId", ""));
    std::string surface = "unavailable";
    if (hologram_allowed_ && generation == hologram_generation_ && account == hologram_account_ &&
        authority && authority() && HologramPopup::SessionAllows()) {
      hologram_policy_until_ = GetTickCount64() + 500;
      surface = IsWindowVisible(owner_) && !IsIconic(owner_) ? "visible" : "hidden";
    }
    result->Success(flutter::EncodableValue(surface));
  } else if (method == "showHologram") {
    const auto generation = ArgInt64(call, "generation", -1);
    const auto account = ArgString(call, "accountId", "");
    const auto authority = jami_bridge::HologramPresentationAuthority(account,
        ArgString(call, "peerJamiId", ""), ArgString(call, "conversationId", ""));
    const bool allowed = ArgString(call, "assetId", "") == "sybl.chubby-cats.angry.v1" &&
        hologram_allowed_ && generation == hologram_generation_ && account == hologram_account_ &&
        GetTickCount64() < hologram_policy_until_ && authority && authority();
    const bool shown = allowed && hologram_popup_.Show(owner_, ArgBool(call, "reducedMotion", false),
        [this, generation, account, authority]() {
          return hologram_allowed_ && generation == hologram_generation_ && account == hologram_account_ &&
              GetTickCount64() < hologram_policy_until_ && authority();
        });
    result->Success(flutter::EncodableValue(shown));
  } else if (method == "cancelHologram") {
    if (ArgInt64(call, "generation", -1) == hologram_generation_) hologram_popup_.Cancel();
    result->Success();
  } else if (method == "sendHologramControl") {
    const std::string account = ArgString(call, "accountId", "");
    const std::string peer = ArgString(call, "peerJamiId", "");
    const std::string payload = ArgString(call, "payload", "");
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::SendHologramControl(account, peer, payload, [this, res](bool ok) {
      PostToPlatform([res, ok]() { res->Success(flutter::EncodableValue(ok)); });
    });
  } else if (method == "sendFileDeclined") {
    const std::string peer = ArgString(call, "peerJamiId", "");
    const std::string conversation_id =
        ArgString(call, "conversationId", "");
    const std::string file_id = ArgString(call, "fileId", "");
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(
        std::move(result));
    jami_bridge::SendFileDeclined(
        peer, conversation_id, file_id, [this, res](bool ok) {
          PostToPlatform(
              [res, ok]() { res->Success(flutter::EncodableValue(ok)); });
        });
  } else if (method == "notifyCallRequest") {
    const std::string peer = ArgString(call, "peerJamiId", "");
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(
        std::move(result));
    jami_bridge::NotifyCallRequest(peer, [this, res](bool ok) {
      PostToPlatform(
          [res, ok]() { res->Success(flutter::EncodableValue(ok)); });
    });
  } else if (method == "placeCall") {
    const std::string peer = ArgString(call, "peerJamiId", "");
    const bool with_video = ArgBool(call, "withVideo", false);
    const bool initial_audio_muted =
        ArgBool(call, "initialAudioMuted", false);
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::PlaceCall(peer, with_video, initial_audio_muted,
                          [this, res](const std::string& call_id, bool camera_on) {
      PostToPlatform([res, call_id, camera_on]() {
        flutter::EncodableMap placement;
        placement[flutter::EncodableValue("callId")] = flutter::EncodableValue(call_id);
        placement[flutter::EncodableValue("cameraOn")] = flutter::EncodableValue(camera_on);
        res->Success(flutter::EncodableValue(placement));
      });
    });
  } else if (method == "listGroupCalls") {
    const auto conversation_id = ArgString(call, "conversationId", "");
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(
        std::move(result));
    jami_bridge::ListGroupCalls(conversation_id, [this, res](const auto& calls) {
      PostToPlatform([res, calls]() {
        flutter::EncodableList list;
        for (const auto& call : calls) {
          flutter::EncodableMap item;
          item[flutter::EncodableValue("conferenceId")] =
              flutter::EncodableValue(call.conferenceId);
          item[flutter::EncodableValue("hostUri")] =
              flutter::EncodableValue(call.hostUri);
          item[flutter::EncodableValue("hostDevice")] =
              flutter::EncodableValue(call.hostDevice);
          list.emplace_back(item);
        }
        res->Success(flutter::EncodableValue(list));
      });
    });
  } else if (method == "reserveGroupCall") {
    const auto account = ArgString(call, "accountId", "");
    const auto conversation = ArgString(call, "conversationId", "");
    const auto reservation = ArgString(call, "reservationId", "");
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::ReserveGroupCall(account, conversation, reservation, [this, res](bool ok) {
      PostToPlatform([res, ok]() { res->Success(flutter::EncodableValue(ok)); });
    });
  } else if (method == "joinGroupCall") {
    const auto conversation_id = ArgString(call, "conversationId", "");
    const auto conference_id = ArgString(call, "conferenceId", "");
    const auto reservation = ArgString(call, "reservationId", "");
    const auto host_uri = ArgString(call, "hostUri", "");
    const auto host_device = ArgString(call, "hostDevice", "");
    const bool initial_audio_muted =
        ArgBool(call, "initialAudioMuted", false);
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(
        std::move(result));
    jami_bridge::JoinGroupCall(
        conversation_id, conference_id, reservation, host_uri, host_device,
        initial_audio_muted, [this, res](const auto& placement) {
          PostToPlatform([res, placement]() {
            flutter::EncodableMap value;
            value[flutter::EncodableValue("conferenceId")] =
                flutter::EncodableValue(placement.conferenceId);
            value[flutter::EncodableValue("callId")] =
                flutter::EncodableValue(placement.callId);
            value[flutter::EncodableValue("hosting")] =
                flutter::EncodableValue(placement.hosting);
            res->Success(flutter::EncodableValue(value));
          });
        });
  } else if (method == "leaveGroupCall") {
    const auto conference_id = ArgString(call, "conferenceId", "");
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(
        std::move(result));
    jami_bridge::LeaveGroupCall(conference_id, ArgString(call, "reservationId", ""), [this, res](bool ok) {
      PostToPlatform([res, ok]() {
        res->Success(flutter::EncodableValue(ok));
      });
    });
  } else if (method == "setGroupMicMuted") {
    const auto conference_id = ArgString(call, "conferenceId", "");
    const bool muted = ArgBool(call, "muted", false);
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(
        std::move(result));
    jami_bridge::SetGroupMicMuted(
        conference_id, muted, [this, res](bool ok) {
          PostToPlatform([res, ok]() {
            res->Success(flutter::EncodableValue(ok));
          });
        });
  } else if (method == "setGroupDeafened") {
    const auto conference_id = ArgString(call, "conferenceId", "");
    const bool deafened = ArgBool(call, "deafened", false);
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(
        std::move(result));
    jami_bridge::SetGroupDeafened(
        conference_id, deafened, [this, res](bool ok) {
          PostToPlatform([res, ok]() {
            res->Success(flutter::EncodableValue(ok));
          });
        });
  } else if (method == "setGroupConferenceLayout") {
    const auto conference_id = ArgString(call, "conferenceId", "");
    const int layout = ArgInt(call, "layout", -1);
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(
        std::move(result));
    jami_bridge::SetGroupConferenceLayout(
        conference_id, layout, [this, res](bool ok) {
          PostToPlatform([res, ok]() {
            res->Success(flutter::EncodableValue(ok));
          });
        });
  } else if (method == "setGroupActiveStream") {
    const auto conference_id = ArgString(call, "conferenceId", "");
    const auto account_id = ArgString(call, "accountId", "");
    const auto device_id = ArgString(call, "deviceId", "");
    const auto stream_id = ArgString(call, "streamId", "");
    const bool active = ArgBool(call, "active", false);
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(
        std::move(result));
    jami_bridge::SetGroupActiveStream(
        conference_id, account_id, device_id, stream_id, active,
        [this, res](bool ok) {
          PostToPlatform([res, ok]() {
            res->Success(flutter::EncodableValue(ok));
          });
        });
  } else if (method == "muteGroupParticipant") {
    const auto conference_id = ArgString(call, "conferenceId", "");
    const auto account_id = ArgString(call, "accountId", "");
    const auto device_id = ArgString(call, "deviceId", "");
    const auto stream_id = ArgString(call, "streamId", "");
    const bool muted = ArgBool(call, "muted", false);
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(
        std::move(result));
    jami_bridge::MuteGroupParticipant(
        conference_id, account_id, device_id, stream_id, muted,
        [this, res](bool ok) {
          PostToPlatform([res, ok]() {
            res->Success(flutter::EncodableValue(ok));
          });
        });
  } else if (method == "disconnectGroupParticipant") {
    const auto conference_id = ArgString(call, "conferenceId", "");
    const auto account_id = ArgString(call, "accountId", "");
    const auto device_id = ArgString(call, "deviceId", "");
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(
        std::move(result));
    jami_bridge::DisconnectGroupParticipant(
        conference_id, account_id, device_id, [this, res](bool ok) {
          PostToPlatform([res, ok]() {
            res->Success(flutter::EncodableValue(ok));
          });
        });
  } else if (method == "publishGroupCallPresence") {
    const auto conversation_id = ArgString(call, "conversationId", "");
    const auto payload = ArgString(call, "payload", "");
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(
        std::move(result));
    jami_bridge::PublishGroupCallPresence(
        conversation_id, payload, [this, res](bool ok) {
          PostToPlatform([res, ok]() {
            res->Success(flutter::EncodableValue(ok));
          });
        });
  } else if (method == "answerCall") {
    const std::string id = ArgString(call, "callId", "");
    const bool initial_audio_muted =
        ArgBool(call, "initialAudioMuted", false);
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::AnswerCall(id, initial_audio_muted, [this, res](bool ok) {
      PostToPlatform([res, ok]() { res->Success(flutter::EncodableValue(ok)); });
    });
  } else if (method == "hangUp") {
    const std::string id = ArgString(call, "callId", "");
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::HangUp(id, [this, res](bool ok) {
      PostToPlatform([res, ok]() { res->Success(flutter::EncodableValue(ok)); });
    });
  } else if (method == "refuse") {
    const std::string id = ArgString(call, "callId", "");
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::Refuse(id, [this, res](bool ok) {
      PostToPlatform([res, ok]() { res->Success(flutter::EncodableValue(ok)); });
    });
  } else if (method == "audioOutputs") {
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::AudioOutputs([this, res](std::vector<std::string> devices) {
      PostToPlatform([res, devices = std::move(devices)]() {
        flutter::EncodableList list;
        list.reserve(devices.size());
        for (const auto& device : devices) list.emplace_back(device);
        res->Success(flutter::EncodableValue(list));
      });
    });
  } else if (method == "setAudioOutput") {
    const int index = ArgInt(call, "index", -1);
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::SetAudioOutput(index, [this, res](bool ok) {
      PostToPlatform([res, ok]() { res->Success(flutter::EncodableValue(ok)); });
    });
  } else if (method == "audioInputs") {
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::AudioInputs([this, res](std::vector<std::string> devices) {
      PostToPlatform([res, devices = std::move(devices)]() {
        flutter::EncodableList list;
        list.reserve(devices.size());
        for (const auto& device : devices) list.emplace_back(device);
        res->Success(flutter::EncodableValue(list));
      });
    });
  } else if (method == "setAudioInput") {
    const int index = ArgInt(call, "index", -1);
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::SetAudioInput(index, [this, res](bool ok) {
      PostToPlatform([res, ok]() { res->Success(flutter::EncodableValue(ok)); });
    });
  } else if (method == "setMicMuted") {
    const std::string id = ArgString(call, "callId", "");
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::SetMicMuted(id, ArgBool(call, "muted", false), [this, res](bool ok) {
      PostToPlatform([res, ok]() {
        if (ok)
          res->Success(flutter::EncodableValue());
        else
          res->Error("daemon_command_failed", "setMicMuted failed");
      });
    });
  } else if (method == "setAudioTransmissionMode") {
    const std::string id = ArgString(call, "callId", "");
    const std::string mode = ArgString(call, "mode", "");
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::SetAudioTransmissionMode(id, mode, [this, res](bool ok) {
      PostToPlatform([res, ok]() {
        if (ok)
          res->Success(flutter::EncodableValue());
        else
          res->Error("daemon_command_failed",
                     "setAudioTransmissionMode failed");
      });
    });
  } else if (method == "setAudioMeterEnabled") {
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::SetAudioMeterEnabled(ArgBool(call, "enabled", false), [this, res](bool ok) {
      PostToPlatform([res, ok]() {
        if (ok)
          res->Success(flutter::EncodableValue());
        else
          res->Error("daemon_command_failed", "setAudioMeterEnabled failed");
      });
    });
  } else if (method == "setAppearOffline") {
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::SetAppearOffline(ArgBool(call, "on", false), ArgExpectedAccountId(call), [this, res](bool ok) {
      PostToPlatform([res, ok]() {
        if (ok)
          res->Success(flutter::EncodableValue());
        else
          res->Error("daemon_command_failed", "setAppearOffline failed");
      });
    });
  } else if (method == "setForeground") {
    // presence v2: fg stamp for the native pong (Dart lifecycle → the "fg" flag on every ping/pong).
    jami_bridge::SetForeground(ArgBool(call, "fg", true));
    result->Success(flutter::EncodableValue());
  } else if (method == "setPresenceMetadata") {
    jami_bridge::SetPresenceMetadata(
        ArgBool(call, "shareActivity", false),
        ArgString(call, "color", ""));
    result->Success(flutter::EncodableValue());
  } else if (method == "connectivitySweep") {
    jami_bridge::ConnectivitySweep();
    result->Success(flutter::EncodableValue());
  } else if (method == "setConnectionProfile") {
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::SetConnectionProfile(ArgString(call, "profile", "jami"), ArgString(call, "dhtBootstrap", ""),
                                      ArgString(call, "turnServer", ""), ArgString(call, "turnRealm", ""),
                                      ArgString(call, "turnUser", ""), ArgString(call, "turnPassword", ""),
                                      ArgExpectedAccountId(call),
                                      [this, res](bool ok) {
                                        PostToPlatform([res, ok]() {
                                          if (ok)
                                            res->Success(flutter::EncodableValue());
                                          else
                                            res->Error("daemon_command_failed", "setConnectionProfile failed");
                                        });
                                      });
  } else if (method == "setSpeaker") {
    // Windows audio is daemon-owned with a single system output — there's no earpiece/speaker route to switch
    // (unlike Android). Accept the call so the Dart toggle resolves, but it's a no-op.
    result->Success(flutter::EncodableValue());
  } else if (method == "hasMicPermission") {
    // Windows has no per-app runtime mic prompt like Android; WASAPI capture is governed by OS privacy settings.
    // Report available so the call UI proceeds (a blocked mic surfaces as no audio, not a permission gate).
    result->Success(flutter::EncodableValue(true));
  } else if (method == "setAnnotationOverlay") {
    if (!ArgBool(call, "active", false)) {
      annotation_overlay_.Clear();
      result->Success(flutter::EncodableValue(true));
      return;
    }
    const auto snapshot = ArgAnnotationSnapshot(call);
    if (!snapshot) {
      annotation_overlay_.Clear();
      result->Success(flutter::EncodableValue(false));
      return;
    }
    const auto source = jami_bridge::ResolveOwnedScreenSource(
        snapshot->call_id, snapshot->source_revision);
    const auto surface =
        source ? ResolveAnnotationSurface(*source) : std::nullopt;
    if (!source || !surface) {
      annotation_overlay_.Clear();
      result->Success(flutter::EncodableValue(false));
      return;
    }
    result->Success(flutter::EncodableValue(
        annotation_overlay_.Update(std::move(*snapshot), *surface)));
  } else if (method == "createVideoTexture") {
    // Daemon-captured video on Windows: create (or reuse) the role's external pixel-buffer texture and hand its
    // Flutter id back. The daemon's decoded sink frames render into it via OnVideoFrame.
    const std::string role = ArgString(call, "role", "remote");
    result->Success(flutter::EncodableValue(EnsureVideoTexture(role)));
  } else if (method == "listScreenSources") {
    if (ArgString(call, "callId", "").empty()) {
      result->Success(flutter::EncodableValue(flutter::EncodableList{}));
    } else {
      result->Success(flutter::EncodableValue(EncodeMonitors(EnumerateMonitors())));
    }
  } else if (method == "setOutgoingVideoSource") {
    const std::string call_id = ArgString(call, "callId", "");
    const std::string kind = ArgString(call, "kind", "off");
    std::string uri;
    int width = 0;
    int height = 0;
    if (kind == "screen") {
      const auto monitors = EnumerateMonitors();
      const auto* monitor = screen_source::FindMonitor(
          monitors, ArgString(call, "sourceId", ""));
      if (!monitor) {
        result->Success(flutter::EncodableValue(false));
        return;
      }
      const auto mrl = screen_source::DisplayMrl(*monitor);
      if (!mrl) {
        result->Success(flutter::EncodableValue(false));
        return;
      }
      uri = *mrl;
      width = monitor->width;
      height = monitor->height;
    } else if (kind != "camera" && kind != "off") {
      result->Success(flutter::EncodableValue(false));
      return;
    }
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::SetOutgoingVideoSource(
        call_id, kind, uri, width, height, [this, res](bool ok) {
          PostToPlatform([res, ok]() {
            res->Success(flutter::EncodableValue(ok));
          });
        });
  } else if (method == "startVideo") {
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::StartVideo(ArgString(call, "callId", ""), [this, res](bool ok) {
      PostToPlatform([res, ok]() { res->Success(flutter::EncodableValue(ok)); });
    });
  } else if (method == "stopVideo") {
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::StopVideo(ArgString(call, "callId", ""), [this, res](bool ok) {
      PostToPlatform([res, ok]() { res->Success(flutter::EncodableValue(ok)); });
    });
  } else if (method == "switchCamera") {
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::SwitchCamera(ArgString(call, "callId", ""), [this, res](bool /*ok*/) {
      // Dart's switchCamera returns void — reply with monostate once the worker has issued the re-invite.
      PostToPlatform([res]() { res->Success(flutter::EncodableValue()); });
    });
  } else if (method == "hasCameraPermission") {
    // Windows has no per-app runtime camera prompt like Android; capture is governed by OS privacy settings (a
    // blocked camera surfaces as no frames, not a permission gate). Report available so the call UI proceeds.
    result->Success(flutter::EncodableValue(true));
  } else if (method == "pickFile") {
    const auto max_bytes = ArgInt64(call, "maxBytes", 0);
    if (!sybl::picked_file::IsAllowedMaxBytes(max_bytes)) {
      result->Success(flutter::EncodableValue());
      return;
    }
    // The selected path is untrusted and never crosses the channel. Open and
    // inspect it once, then return only a bounded app-owned stable copy.
    wchar_t buf[MAX_PATH];
    buf[0] = L'\0';
    OPENFILENAMEW ofn{};
    ofn.lStructSize = sizeof(ofn);
    ofn.hwndOwner = GetActiveWindow();
    ofn.lpstrFile = buf;
    ofn.nMaxFile = MAX_PATH;
    const std::string mime_type = ArgString(call, "mimeType", "*/*");
    const wchar_t image_filter[] =
        L"Images (*.jpg;*.jpeg;*.png;*.webp;*.bmp)\0"
        L"*.jpg;*.jpeg;*.png;*.webp;*.bmp\0"
        L"All files (*.*)\0*.*\0\0";
    if (mime_type == "image/*") ofn.lpstrFilter = image_filter;
    ofn.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR | OFN_EXPLORER;
    if (GetOpenFileNameW(&ofn) && buf[0] != L'\0') {
      const auto root = sybl::picked_file::DefaultStagingRoot();
      const auto staged = root ? sybl::picked_file::Stage(
                                     std::filesystem::path(buf), *root,
                                     max_bytes)
                               : std::nullopt;
      if (staged) {
        result->Success(
            flutter::EncodableValue(WideToUtf8(staged->wstring())));
        return;
      }
    }
    result->Success(flutter::EncodableValue());
  } else if (method == "prepareVoiceRecording") {
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::PrepareVoiceRecording(ArgString(call, "accountId", ""),
        ArgString(call, "peerJamiId", ""), ArgString(call, "conversationId", ""),
        [this, res](std::string path) {
          PostToPlatform([res, path]() {
            res->Success(path.empty() ? flutter::EncodableValue()
                                     : flutter::EncodableValue(path));
          });
        });
  } else if (method == "renewVoiceRecording") {
    result->Success(flutter::EncodableValue(
        jami_bridge::RenewVoiceRecording(ArgString(call, "path", ""))));
  } else if (method == "stageStarterGif") {
    const auto id = ArgString(call, "id", "");
    const auto staging = sybl::picked_file::DefaultStagingRoot();
    std::vector<wchar_t> executable(32768);
    const auto count = GetModuleFileNameW(nullptr, executable.data(),
                                         static_cast<DWORD>(executable.size()));
    if (!staging || id.empty() || id.size() > 20 ||
        id.find_first_not_of("abcdefghijklmnopqrstuvwxyz") != std::string::npos ||
        count == 0 || count >= executable.size()) {
      result->Success(flutter::EncodableValue());
      return;
    }
    const auto source = std::filesystem::path(std::wstring(executable.data(), count)).parent_path() /
        L"data" / L"flutter_assets" / L"assets" / L"gifs" / L"doorlight" /
        std::filesystem::u8path(id + ".gif");
    const auto staged = sybl::picked_file::Stage(source, *staging, 4 * 1024 * 1024);
    result->Success(staged ? flutter::EncodableValue(WideToUtf8(staged->wstring()))
                           : flutter::EncodableValue());
  } else if (method == "archivedChatsDirectory") {
    const auto staging = sybl::picked_file::DefaultStagingRoot();
    result->Success(staging ? flutter::EncodableValue(WideToUtf8(
                                  (staging->parent_path() / L"Syb-L" / L"archived-chats").wstring()))
                            : flutter::EncodableValue());
  } else if (method == "gifLibraryDirectory" || method == "stageGifLibraryEntry") {
    const auto staging = sybl::picked_file::DefaultStagingRoot();
    if (!staging) {
      result->Success(flutter::EncodableValue());
      return;
    }
    const auto library = staging->parent_path() / L"Syb-L GIF Library";
    if (method == "gifLibraryDirectory") {
      result->Success(flutter::EncodableValue(WideToUtf8(library.wstring())));
      return;
    }
    const auto hash = ArgString(call, "hash", "");
    if (hash.size() != 64 || hash.find_first_not_of("0123456789abcdef") != std::string::npos) {
      result->Success(flutter::EncodableValue());
      return;
    }
    const auto staged = sybl::picked_file::Stage(
        library / std::filesystem::u8path(hash + ".gif"), *staging, 4 * 1024 * 1024);
    result->Success(staged ? flutter::EncodableValue(WideToUtf8(staged->wstring()))
                           : flutter::EncodableValue());
  } else if (method == "discardPickedFile") {
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::DiscardUnissuedStage(ArgString(call, "path", ""), [this, res](bool) {
      PostToPlatform([res]() { res->Success(flutter::EncodableValue()); });
    });
  } else if (method == "sendFile") {
    const std::string peer = ArgString(call, "peerJamiId", "");
    const std::string conversation = ArgString(call, "conversationId", "");
    const std::string path = ArgString(call, "path", "");
    const std::string name = ArgString(call, "name", "");
    const std::string topic = ArgString(call, "topicId", "");
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::SendFile(peer, conversation, path, name, topic, [this, res, path](bool ok) {
      // SendFile has made the stable outgoing copy before reporting success. Drop the picker handoff copy now so
      // one successful send does not retain the same payload in both app-owned stores.
      if (ok) {
        const auto root = sybl::picked_file::DefaultStagingRoot();
        if (root) {
          sybl::picked_file::Discard(std::filesystem::u8path(path), *root);
        }
      }
      PostToPlatform([res, ok]() { res->Success(flutter::EncodableValue(ok)); });
    });
  } else if (method == "acceptFile") {
    const std::string peer = ArgString(call, "peerJamiId", "");
    const std::string conversation = ArgString(call, "conversationId", "");
    const std::string iid = ArgString(call, "interactionId", "");
    const std::string fid = ArgString(call, "fileId", "");
    const std::string name = ArgString(call, "name", "");
    const int64_t maxBytes = ArgInt64(call, "maxBytes", 0);
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::AcceptFile(peer, conversation, iid, fid, name, maxBytes, ArgString(call, "attemptId", ""), [this, res](bool ok) {
      PostToPlatform([res, ok]() { res->Success(flutter::EncodableValue(ok)); });
    });
  } else if (method == "openReceivedFile") {
    const std::string path = ArgString(call, "path", "");
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::OpenReceivedFile(path, [this, res](bool ok) {
      PostToPlatform([res, ok]() { res->Success(flutter::EncodableValue(ok)); });
    });
  } else if (method == "loadFolder") {
    const std::string peer = ArgString(call, "peerJamiId", "");
    const std::string conversation = ArgString(call, "conversationId", "");
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::LoadFolder(peer, conversation, ArgInt(call, "n", 200), [this, res](uint32_t id) {
      PostToPlatform([res, id]() {
        res->Success(flutter::EncodableValue(static_cast<int64_t>(id)));
      });
    });
  } else if (method == "sendOwnedFile") {
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::SendOwnedFile(
        ArgString(call, "accountId", ""), ArgString(call, "peerJamiId", ""),
        ArgString(call, "conversationId", ""), ArgString(call, "path", ""),
        ArgString(call, "name", ""), ArgString(call, "topicId", ""),
        ArgString(call, "roomId", ""), ArgString(call, "media", ""),
        ArgString(call, "operationId", ""), [this, res](const std::string& status) {
          PostToPlatform([res, status]() { res->Success(flutter::EncodableValue(status)); });
        });
  } else if (method == "acknowledgeFileSeed") {
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::AcknowledgeFileSeed(
        ArgString(call, "accountId", ""), ArgString(call, "operationId", ""),
        ArgString(call, "commitId", ""), ArgString(call, "conversationId", ""), [this, res](bool ok) {
          PostToPlatform([res, ok]() { res->Success(flutter::EncodableValue(ok)); });
        });
  } else if (method == "sendOwnedMessage") {
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::SendOwnedMessage(
        ArgString(call, "accountId", ""), ArgString(call, "peerJamiId", ""),
        ArgString(call, "conversationId", ""), ArgString(call, "mimeType", ""),
        ArgString(call, "body", ""), ArgString(call, "replyTo", ""),
        ArgString(call, "topicId", ""), ArgString(call, "roomId", ""),
        ArgString(call, "operationId", ""), [this, res](const std::string& status) {
          PostToPlatform([res, status]() { res->Success(flutter::EncodableValue(status)); });
        });
  } else if (method == "sendOwnedReaction") {
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::SendOwnedReaction(
        ArgString(call, "accountId", ""), ArgString(call, "peerJamiId", ""),
        ArgString(call, "conversationId", ""), ArgString(call, "messageId", ""),
        ArgString(call, "removedId", ""), ArgString(call, "emoji", ""),
        ArgString(call, "topicId", ""), ArgString(call, "roomId", ""),
        ArgString(call, "operationId", ""), [this, res](const std::string& status) {
          PostToPlatform([res, status]() { res->Success(flutter::EncodableValue(status)); });
        });
  } else if (method == "sendChatMessage") {
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::SendChatMessage(
        ArgString(call, "peerJamiId", ""), ArgString(call, "conversationId", ""),
        ArgString(call, "body", ""), ArgString(call, "replyTo", ""),
        ArgString(call, "topicId", ""),
        [this, res](bool ok) {
          PostToPlatform([res, ok]() { res->Success(flutter::EncodableValue(ok)); });
        });
  } else if (method == "sendDmTopicEvent") {
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::SendDmTopicEvent(
        ArgString(call, "peerJamiId", ""), ArgString(call, "conversationId", ""),
        ArgString(call, "body", ""), [this, res](const std::string& id) {
          PostToPlatform([res, id]() { res->Success(flutter::EncodableValue(id)); });
        });
  } else if (method == "setMessageDisplayed") {
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::SetMessageDisplayed(
        ArgString(call, "peerJamiId", ""), ArgString(call, "conversationId", ""),
        ArgString(call, "messageId", ""), [this, res](bool ok) {
          PostToPlatform([res, ok]() { res->Success(flutter::EncodableValue(ok)); });
        });
  } else if (method == "searchHistory") {
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::SearchHistory(
        ArgString(call, "accountId", ""), ArgString(call, "peerJamiId", ""),
        ArgString(call, "conversationId", ""), ArgString(call, "query", ""),
        ArgInt(call, "limit", 0), [this, res](std::optional<jami_bridge::HistorySearchReply> reply) {
          PostToPlatform([res, reply = std::move(reply)] {
            if (!reply || !jami_bridge::HistorySearchReplyCurrent(*reply)) {
              res->Success();
              return;
            }
            using V = flutter::EncodableValue;
            flutter::EncodableList hits;
            for (const auto& hit : reply->hits) {
              hits.emplace_back(flutter::EncodableMap{
                  {V("accountId"), V(reply->accountId)}, {V("peerId"), V(reply->peerId)},
                  {V("conversationId"), V(reply->conversationId)},
                  {V("kind"), V(reply->peerId.rfind("group:", 0) == 0 ? "group" : "direct")},
                  {V("messageId"), V(hit.messageId)}, {V("authorId"), V(hit.authorId)},
                  {V("channelId"), V(hit.channelId)}, {V("snippet"), V(hit.snippet)},
                  {V("timestampSeconds"), V(hit.timestampSeconds)},
                  {V("contentKind"), V(hit.file ? "file" : "text")}});
            }
            res->Success(V(flutter::EncodableMap{
                {V("hits"), V(std::move(hits))}, {V("truncated"), V(reply->truncated)}}));
          });
        });
  } else if (method == "retireHistorySearch") {
    jami_bridge::RetireHistorySearch(ArgString(call, "accountId", ""));
    result->Success();
  } else if (method == "loadSearchMessage") {
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::LoadSearchMessage(
        ArgString(call, "accountId", ""), ArgString(call, "peerJamiId", ""),
        ArgString(call, "conversationId", ""), ArgString(call, "messageId", ""),
        [this, res](std::optional<jami_bridge::SearchMessageReply> reply) {
          PostToPlatform([res, reply = std::move(reply)] {
            if (!reply || !jami_bridge::SearchMessageReplyCurrent(*reply)) {
              res->Success();
              return;
            }
            using V = flutter::EncodableValue;
            res->Success(V(flutter::EncodableMap{
                {V("accountId"), V(reply->accountId)}, {V("peerId"), V(reply->peerId)},
                {V("conversationId"), V(reply->conversationId)},
                {V("kind"), V(reply->peerId.rfind("group:", 0) == 0 ? "group" : "direct")},
                {V("messageId"), V(reply->messageId)},
                {V("items"), V(flutter::EncodableList{ToEncodableValue(reply->item)})}}));
          });
        });
  } else if (method == "loadChat") {
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::LoadChat(
        ArgString(call, "peerJamiId", ""), ArgString(call, "conversationId", ""),
        ArgString(call, "fromMessage", ""), ArgInt(call, "n", 50),
        [this, res](uint32_t id) {
          PostToPlatform([res, id]() {
            res->Success(flutter::EncodableValue(static_cast<int64_t>(id)));
          });
        });
  } else if (method == "loadDmTopicState") {
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::LoadDmTopicState(
        ArgString(call, "peerJamiId", ""), ArgString(call, "conversationId", ""),
        ArgString(call, "fromMessage", ""), ArgInt(call, "pageSize", 200),
        [this, res](uint32_t id) {
          PostToPlatform([res, id]() {
            res->Success(flutter::EncodableValue(static_cast<int64_t>(id)));
          });
        });
  } else if (method == "cancelDmTopicStateLoad") {
    const auto loadId = ArgInt64(call, "loadId", 0);
    result->Success(flutter::EncodableValue(
        loadId > 0 && loadId <= 0xffffffffLL &&
        jami_bridge::CancelDmTopicStateLoad(static_cast<uint32_t>(loadId))));
  } else if (method == "cancelChatLoad") {
    const auto loadId = ArgInt64(call, "loadId", 0);
    result->Success(flutter::EncodableValue(
        loadId > 0 && loadId <= 0xffffffffLL &&
        jami_bridge::CancelChatLoad(static_cast<uint32_t>(loadId))));
  } else if (method == "acceptConnect") {
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::AcceptConnect(ArgString(call, "conversationId", ""), [this, res](bool ok) {
      PostToPlatform([res, ok]() {
        if (ok)
          res->Success(flutter::EncodableValue());
        else
          res->Error("daemon_command_failed", "acceptConnect failed");
      });
    });
  } else if (method == "declineConnect") {
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::DeclineConnect(ArgString(call, "conversationId", ""), ArgString(call, "fromJamiId", ""),
                                [this, res](bool ok) {
                                  PostToPlatform([res, ok]() {
                                    if (ok)
                                      res->Success(flutter::EncodableValue());
                                    else
                                      res->Error("daemon_command_failed", "declineConnect failed");
                                  });
                                });
  } else if (method == "removeContact") {
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::RemoveContact(
        ArgString(call, "uri", ""), ArgBool(call, "ban", false),
        [this, res](bool ok) {
          PostToPlatform([res, ok]() {
            res->Success(flutter::EncodableValue(ok));
          });
        });
  } else if (method == "backupIdentity") {
    // Identity backup (M7.5 a): Save dialog (modal, platform thread) → ExportAccount runs the daemon round-trip
    // on the worker. Default a .gz name; lpstrDefExt appends .gz to an extension-less name. false on cancel.
    const std::string passphrase = ArgString(call, "passphrase", "");
    const std::string settings_document =
        ArgString(call, "settingsDocument", "");
    // The modal dialog pumps messages. Bind the native lifetime before it can
    // outlive an account selection, including A to B to A.
    const auto owner = jami_bridge::CaptureBackupOwner(ArgExpectedAccountId(call));
    wchar_t buf[MAX_PATH];
    wcscpy_s(buf, MAX_PATH, L"sybl-identity-backup.gz");
    OPENFILENAMEW ofn{};
    ofn.lStructSize = sizeof(ofn);
    ofn.hwndOwner = GetActiveWindow();
    ofn.lpstrFile = buf;
    ofn.nMaxFile = MAX_PATH;
    ofn.lpstrDefExt = L"gz";
    ofn.Flags = OFN_OVERWRITEPROMPT | OFN_NOCHANGEDIR | OFN_EXPLORER;
    const bool chosen = owner && GetSaveFileNameW(&ofn) && buf[0] != L'\0';
    if (!chosen) {
      result->Success(flutter::EncodableValue(false));  // cancelled
    } else {
      const std::string dest = WideToUtf8(buf);
      std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
      jami_bridge::ExportAccount(*owner, dest, passphrase, settings_document,
                                 [this, res](bool ok) {
        PostToPlatform([res, ok]() { res->Success(flutter::EncodableValue(ok)); });
      });
    }
  } else if (method == "resetDoorlight") {
    hologram_allowed_ = false;
    hologram_popup_.Cancel();
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::RetryBoot();
    jami_bridge::ResetDoorlight(ArgString(call, "expectedAccountId", ""), [this, res](bool removed) {
      PostToPlatform([res, removed] { res->Success(flutter::EncodableValue(removed)); });
    });
  } else if (method == "relaunchRetired") {
    // Reset completion requires a new process, and closing only hides to the tray. The single-instance
    // lock forbids spawning the successor here, so quit for real and let the user reopen.
    if (owner_ && ::IsWindow(owner_)) ::PostMessageW(owner_, kQuitRequestMessage, 0, 0);
    result->Success();
  } else if (method == "restoreIdentity") {
    // Identity restore (M7.5 a): import a backup file (path from the reused pickFile open dialog) → same 40-hex.
    const std::string file_path = ArgString(call, "filePath", "");
    const std::string passphrase = ArgString(call, "passphrase", "");
    const std::string connection_profile = ArgString(call, "connectionProfile", "jami");
    const std::string dht_bootstrap = ArgString(call, "dhtBootstrap", "");
    const std::string turn_server = ArgString(call, "turnServer", "");
    const std::string turn_realm = ArgString(call, "turnRealm", "");
    const std::string turn_user = ArgString(call, "turnUser", "");
    const std::string turn_password = ArgString(call, "turnPassword", "");
    const bool appear_offline = ArgBool(call, "appearOffline", false);
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::RestoreAccount(
        file_path, passphrase, connection_profile, dht_bootstrap, turn_server,
        turn_realm, turn_user, turn_password, appear_offline,
        ArgString(call, "expectedJamiId", ""), ArgExpectedAccountId(call),
        [this, res](const jami_bridge::Account& a) {
      PostToPlatform([res, a]() {
        res->Success(IdentityRestoreValue(a));
      });
    });
  } else if (method == "devicePairing") {
    std::map<std::string, std::string> network;
    for (const auto* key : {"connectionProfile", "dhtBootstrap", "turnServer", "turnRealm", "turnUser", "turnPassword"})
      network[key] = ArgString(call, key, "");
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::DevicePairingCommand(ArgString(call, "action", ""), ArgString(call, "flowToken", ""),
        ArgString(call, "accountId", ""), ArgString(call, "uri", ""), ArgString(call, "code", ""),
        ArgString(call, "settingsDocument", ""), network, ArgBool(call, "appearOffline", false),
        ArgString(call, "expectedAccountId", ""), [this, res](const jami_bridge::DevicePairingReply& value) {
          PostToPlatform([res, value] {
            if (!jami_bridge::DevicePairingReplyCurrent(value)) {
              res->Success(flutter::EncodableValue(flutter::EncodableMap{
                  {flutter::EncodableValue("status"), flutter::EncodableValue("unavailable")}}));
              return;
            }
            auto out = PairingStateValue(value.state);
            if (value.preparedIdentity)
              out[flutter::EncodableValue("preparedIdentity")] = IdentityRestoreValue(*value.preparedIdentity);
            if (value.peerOutcomeUnconfirmed)
              out[flutter::EncodableValue("peerOutcome")] = flutter::EncodableValue("unconfirmed");
            res->Success(flutter::EncodableValue(out));
          });
        });
  } else if (method == "getPendingIdentityRestore") {
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::RetryBoot();
    jami_bridge::GetPendingIdentityRestore([this, res](const jami_bridge::Account& value) {
      PostToPlatform([res, value]() { res->Success(IdentityRestoreValue(value)); });
    });
  } else if (method == "finalizeIdentityRestore") {
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::FinalizeIdentityRestore(ArgString(call, "accountId", ""),
        ArgString(call, "restoreToken", ""), ArgString(call, "settingsDocument", ""),
        [this, res](const jami_bridge::Account& value) {
      PostToPlatform([res, value]() { res->Success(IdentityRestoreValue(value)); });
    });
  } else if (method == "cancelFile") {
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(
        std::move(result));
    jami_bridge::CancelFile(
        ArgString(call, "peerJamiId", ""),
        ArgString(call, "conversationId", ""),
        ArgString(call, "fileId", ""), ArgString(call, "attemptId", ""), [this, res](bool ok) {
          PostToPlatform(
              [res, ok]() { res->Success(flutter::EncodableValue(ok)); });
        });
  } else if (method == "presentWindowCapturePrompt") {
    if (capture_activity_active_ != true || !capture_frame_barrier_) {
      result->Success(flutter::EncodableValue("unavailable"));
    } else {
      const auto request = ++capture_prompt_request_;
      std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
      capture_frame_barrier_([this, request, res](bool presented) {
        // Leave the engine's presentation callback before synchronizing with DWM.
        PostToPlatform([this, request, res, presented]() {
        auto status = QueryWindowCaptureProtection(owner_, WindowCaptureProtection::kUnavailable);
        const auto flushed = DwmFlush();
        if (!presented || request != capture_prompt_request_ || FAILED(flushed)) {
          res->Error("capture_frame_unavailable", "Capture presentation was not confirmed");
          return;
        }
        if (presented && request == capture_prompt_request_ && capture_activity_active_ == true) {
          if (before_capture_policy_change_) before_capture_policy_change_();
          status = ApplyWindowCaptureProtection(owner_, false);
        }
        res->Success(flutter::EncodableValue(WindowCaptureProtectionName(status)));
        });
      });
    }
  } else if (method == "windowCaptureProtectionStatus") {
    // Live truth: the affinity can change at runtime through
    // applyWindowCaptureProtection, so this must never be a constructor-time
    // snapshot. A failed query is reported as unavailable (never protected).
    result->Success(flutter::EncodableValue(WindowCaptureProtectionName(
        QueryWindowCaptureProtection(
            owner_, WindowCaptureProtection::kUnavailable))));
  } else if (method == "applyWindowCaptureProtection") {
    ++capture_prompt_request_;
    if (before_capture_policy_change_) before_capture_policy_change_();
    // Platform thread == the thread that owns owner_. Returns the ACTUAL
    // post-operation state (confirmed by re-query), never the request echo.
    result->Success(flutter::EncodableValue(WindowCaptureProtectionName(
        ApplyWindowCaptureProtection(owner_,
                                     ArgBool(call, "protect", true)))));
  } else if (method == "windowCommand") {
    const std::string command = ArgString(call, "command", "");
    if (command != "shake") StopWindowShake();
    if (owner_ && (command == "minimize" || command == "toggleMaximize"))
      ::SendMessageW(owner_, kFinishWindowPresentationMessage, 0, 0);
    if (!owner_ || !::IsWindow(owner_)) {
      result->Error("window_unavailable", "The application window is gone.");
    } else if (command == "shake" || command == "stopShake") {
      if (command == "shake") StartWindowShake();
      result->Success();
    } else if (command == "pin" || command == "unpin") {
      if (::SetWindowPos(owner_, command == "pin" ? HWND_TOPMOST : HWND_NOTOPMOST,
                         0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE) &&
          ((::GetWindowLongPtrW(owner_, GWL_EXSTYLE) & WS_EX_TOPMOST) != 0) ==
              (command == "pin"))
        result->Success();
      else result->Error("window_pin_failed", "Could not change window pinning.");
    } else if (command == "compact" || command == "expand" ||
               command == "compactAnimated" || command == "expandAnimated" ||
               command == "resetWindow" || command == "resetWindowAnimated" ||
               command == "compactDirectAudio" || command == "compactGroupAudio") {
      const bool animate = command == "compactAnimated" || command == "expandAnimated" ||
          command == "resetWindowAnimated";
      const bool reset_position = command == "resetWindow" || command == "resetWindowAnimated";
      const int mode = command == "expand" || command == "expandAnimated" || reset_position ? 0 :
          command == "compact" || command == "compactAnimated" ? 1 :
          command == "compactDirectAudio" ? 2 : 3;
      // lParam bit 0 animates; bit 1 restores the canonical corner position.
      if (::SendMessageW(owner_, kWindowPresentationMessage, mode,
                         (animate ? 1 : 0) | (reset_position ? 2 : 0)))
        result->Success();
      else result->Error("window_mode_failed", "Could not change window mode.");
    } else if (command == "minimize") {
      if (::IsWindowVisible(owner_) && !::IsIconic(owner_)) {
        ::PostMessageW(owner_, WM_SYSCOMMAND, SC_MINIMIZE, 0);
        result->Success();
      } else result->Error("window_hidden", "The window is hidden.");
    } else if (command == "toggleMaximize") {
      const HWND owner = owner_;
      if (sybl::window::ToggleMaximizeWithoutReveal(owner, [owner]() {
            return ::SendMessageW(owner, sybl::window::RevealRequestMessage(),
                                  0, 0) != 0;
          }))
        result->Success();
      else result->Error("window_hidden", "The window is hidden.");
    } else if (command == "systemMenu") {
      const HWND owner = owner_;
      if (!::IsWindowVisible(owner)) {
        result->Error("window_hidden", "The window is hidden.");
      } else if (::IsIconic(owner) &&
          !::SendMessageW(owner, sybl::window::RevealRequestMessage(), 0, 0)) {
        result->Error("window_restore_failed", "Could not restore the window.");
      } else {
        POINT cursor{};
        ::GetCursorPos(&cursor);
        const HMENU menu = ::GetSystemMenu(owner, FALSE);
        if (!menu) {
          result->Error("window_menu_failed", "Could not open the window menu.");
          return;
        }
        const bool maximized = ::IsZoomed(owner) != FALSE;
        ::EnableMenuItem(menu, SC_RESTORE, MF_BYCOMMAND | (maximized ? MF_ENABLED : MF_GRAYED));
        ::EnableMenuItem(menu, SC_MAXIMIZE, MF_BYCOMMAND | (maximized ? MF_GRAYED : MF_ENABLED));
        ::EnableMenuItem(menu, SC_MOVE, MF_BYCOMMAND | (maximized ? MF_GRAYED : MF_ENABLED));
        ::EnableMenuItem(menu, SC_SIZE, MF_BYCOMMAND | (maximized ? MF_GRAYED : MF_ENABLED));
        const UINT selected = ::TrackPopupMenu(menu,
            TPM_RETURNCMD | TPM_RIGHTBUTTON, cursor.x, cursor.y, 0, owner, nullptr);
        if (selected && ::IsWindow(owner) && ::IsWindowVisible(owner) && !::IsIconic(owner))
          ::PostMessageW(owner, WM_SYSCOMMAND, selected, 0);
        result->Success();
      }
    } else if (command == "close") {
      ::PostMessageW(owner_, WM_CLOSE, 0, 0);
      result->Success();
    } else if (command == "drag") {
      POINT cursor{};
      ::GetCursorPos(&cursor);
      ::ReleaseCapture();
      ::SendMessageW(owner_, WM_NCLBUTTONDOWN, HTCAPTION,
                     MAKELPARAM(cursor.x, cursor.y));
      result->Success();
    } else {
      result->Error("invalid_window_command", "Unknown window command.");
    }
  } else if (method == "remoteControlRequest") {
    const auto revision = ArgInt64(call, "sourceRevision", 0);
    const auto capabilities = ArgCapabilities(call, "capabilities");
    const auto identity_color = ArgString(call, "identityColor", "");
    const auto call_id = ArgString(call, "callId", "");
    const auto peer_id = ArgString(call, "peerJamiId", "");
    const auto account_id = jami_bridge::ControlAccountForCall(call_id, peer_id);
    bool applied = remote_controller_ && revision > 0 && capabilities &&
        remote_roles_.TryClaim(
            call_id, sybl::remote::LocalControlRole::kController) &&
        remote_controller_->Request(
            account_id, call_id, peer_id,
            static_cast<uint64_t>(revision), *capabilities, identity_color);
    if (!applied &&
        (!remote_controller_ ||
         !remote_controller_->OwnsCall(call_id))) {
      remote_roles_.Release(
          call_id, sybl::remote::LocalControlRole::kController);
    }
    PruneRemoteControlRoles();
    result->Success(flutter::EncodableValue(applied));
  } else if (method == "remoteControlInput") {
    const auto revision = ArgInt64(call, "sourceRevision", 0);
    auto events = ArgInputEvents(call, "events");
    result->Success(flutter::EncodableValue(
        remote_controller_ && revision > 0 && events &&
        remote_controller_->Input(
            ArgString(call, "callId", ""),
            ArgString(call, "peerJamiId", ""),
            static_cast<uint64_t>(revision), std::move(*events))));
  } else if (method == "remoteControlEnd") {
    const auto revision = ArgInt64(call, "sourceRevision", 0);
    const bool applied =
        remote_controller_ && revision > 0 &&
        remote_controller_->End(
            ArgString(call, "callId", ""),
            ArgString(call, "peerJamiId", ""),
            static_cast<uint64_t>(revision));
    PruneRemoteControlRoles();
    result->Success(flutter::EncodableValue(applied));
  } else if (method == "remoteClipboardSend") {
    const auto revision = ArgInt64(call, "sourceRevision", 0);
    result->Success(flutter::EncodableValue(
        remote_controller_ && revision > 0 &&
        remote_controller_->SendClipboard(
            ArgString(call, "callId", ""),
            ArgString(call, "peerJamiId", ""),
            static_cast<uint64_t>(revision),
            ArgString(call, "text", ""))));
  } else if (method == "remoteClipboardControllerAccept" ||
             method == "remoteClipboardControllerReject") {
    const auto revision = ArgInt64(call, "sourceRevision", 0);
    const auto generation = ArgInt64(call, "promptGeneration", 0);
    if (method == "remoteClipboardControllerAccept") {
      const auto call_id = ArgString(call, "callId", "");
      const auto peer = ArgString(call, "peerJamiId", "");
      const auto id = ArgString(call, "id", "");
      std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> reply(std::move(result));
      jami_bridge::RefreshControllerClipboardAuthority(call_id, peer,
          [this, reply, call_id, peer, id, revision, generation](bool current) {
            PostToPlatform([this, reply, call_id, peer, id, revision, generation, current] {
              const bool applied = current && remote_controller_ && revision > 0 && generation > 0 &&
                  remote_controller_->RespondClipboard(call_id, peer,
                      static_cast<uint64_t>(revision), id, static_cast<uint64_t>(generation), true);
              reply->Success(flutter::EncodableValue(applied));
            });
          });
      return;
    }
    result->Success(flutter::EncodableValue(
        remote_controller_ && revision > 0 &&
        remote_controller_->RespondClipboard(
            ArgString(call, "callId", ""),
            ArgString(call, "peerJamiId", ""),
            static_cast<uint64_t>(revision),
            ArgString(call, "id", ""),
            generation > 0 ? static_cast<uint64_t>(generation) : 0,
            method == "remoteClipboardControllerAccept")));
  } else if (method == "remoteControlAllowOnce") {
    const auto revision = ArgInt64(call, "sourceRevision", 0);
    const auto generation = ArgInt64(call, "hostGeneration", 0);
    const auto decision = remote_control_
        ? remote_control_->AllowOnce(
              ArgString(call, "callId", ""),
              ArgString(call, "controllerAccountId", ""),
              ArgString(call, "controllerDeviceId", ""),
              revision > 0 ? static_cast<uint64_t>(revision) : 0,
              generation > 0 ? static_cast<uint64_t>(generation) : 0)
        : sybl::remote::LocalControlResult::kUnavailable;
    PruneRemoteControlRoles();
    result->Success(flutter::EncodableValue(
        decision == sybl::remote::LocalControlResult::kApplied));
  } else if (method == "remoteControlAllowDevice") {
    const auto revision = ArgInt64(call, "sourceRevision", 0);
    const auto generation = ArgInt64(call, "hostGeneration", 0);
    const auto decision = remote_control_
        ? remote_control_->AllowDevice(
              ArgString(call, "callId", ""),
              ArgString(call, "controllerAccountId", ""),
              ArgString(call, "controllerDeviceId", ""),
              revision > 0 ? static_cast<uint64_t>(revision) : 0,
              generation > 0 ? static_cast<uint64_t>(generation) : 0)
        : sybl::remote::LocalControlResult::kUnavailable;
    PruneRemoteControlRoles();
    if (decision == sybl::remote::LocalControlResult::kUnsupported)
      result->Error("persistent_grants_unavailable",
                    "Device-bound persistent remote-control grants are not enabled");
    else
      result->Success(flutter::EncodableValue(
          decision == sybl::remote::LocalControlResult::kApplied));
  } else if (method == "remoteControlDeny") {
    const auto revision = ArgInt64(call, "sourceRevision", 0);
    const auto generation = ArgInt64(call, "hostGeneration", 0);
    const auto decision = remote_control_
        ? remote_control_->Deny(
              ArgString(call, "callId", ""),
              ArgString(call, "controllerAccountId", ""),
              ArgString(call, "controllerDeviceId", ""),
              revision > 0 ? static_cast<uint64_t>(revision) : 0,
              generation > 0 ? static_cast<uint64_t>(generation) : 0)
        : sybl::remote::LocalControlResult::kUnavailable;
    PruneRemoteControlRoles();
    result->Success(flutter::EncodableValue(
        decision == sybl::remote::LocalControlResult::kApplied));
  } else if (method == "remoteControlForgetDevice") {
    result->Success(flutter::EncodableValue(
        remote_control_ &&
        remote_control_->ForgetDevice(
            ArgString(call, "accountId", ""),
            ArgString(call, "controllerAccountId", ""),
            ArgString(call, "controllerDeviceId", ""))));
  } else if (method == "remoteControlStop") {
    const bool applied = remote_control_ && remote_control_->Stop();
    PruneRemoteControlRoles();
    result->Success(flutter::EncodableValue(applied));
  } else if (method == "remoteControlSetCoControl") {
    const auto decision = remote_control_
        ? remote_control_->SetCoControl(ArgBool(call, "enabled", false))
        : sybl::remote::LocalControlResult::kUnavailable;
    result->Success(flutter::EncodableValue(
        decision == sybl::remote::LocalControlResult::kApplied));
  } else if (method == "remoteClipboardAccept") {
    const auto generation = ArgInt64(call, "promptGeneration", 0);
    const auto decision = remote_control_
        ? remote_control_->AcceptClipboard(
              ArgString(call, "id", ""),
              generation > 0 ? static_cast<uint64_t>(generation) : 0)
        : sybl::remote::LocalControlResult::kUnavailable;
    result->Success(flutter::EncodableValue(
        decision == sybl::remote::LocalControlResult::kApplied));
  } else if (method == "remoteClipboardReject") {
    const auto generation = ArgInt64(call, "promptGeneration", 0);
    const auto decision = remote_control_
        ? remote_control_->RejectClipboard(
              ArgString(call, "id", ""),
              generation > 0 ? static_cast<uint64_t>(generation) : 0)
        : sybl::remote::LocalControlResult::kUnavailable;
    result->Success(flutter::EncodableValue(
        decision == sybl::remote::LocalControlResult::kApplied));
  } else if (method == "remoteClipboardHostSend") {
    const auto revision = ArgInt64(call, "sourceRevision", 0);
    const auto generation = ArgInt64(call, "hostGeneration", 0);
    const auto decision = remote_control_
        ? remote_control_->SendClipboard(
              ArgString(call, "text", ""), ArgString(call, "callId", ""),
              ArgString(call, "peerJamiId", ""),
              ArgString(call, "controllerDeviceId", ""),
              revision > 0 ? static_cast<uint64_t>(revision) : 0,
              generation > 0 ? static_cast<uint64_t>(generation) : 0)
        : sybl::remote::LocalControlResult::kUnavailable;
    result->Success(flutter::EncodableValue(
        decision == sybl::remote::LocalControlResult::kApplied));
  } else if (method == "sendCallMessage") {
    // Dart may originate only the low-impact annotation channel. Remote-control
    // packets are constructed and sent by RemoteControlHost after native
    // consent/state checks; accepting a caller-supplied "control" channel here
    // would move business authority back into Dart.
    const bool accepted = jami_bridge::SendCallMessage(
        ArgString(call, "callId", ""), ArgString(call, "payload", ""),
        "annotation");
    result->Success(flutter::EncodableValue(accepted));
  } else if (method == "fileInfo") {
    const std::string peer = ArgString(call, "peerJamiId", "");
    const std::string conversation = ArgString(call, "conversationId", "");
    const std::string fid = ArgString(call, "fileId", "");
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));
    jami_bridge::FileInfoQuery(peer, conversation, fid, [this, res](const jami_bridge::FileInfo& info) {
      PostToPlatform([res, info]() {
        flutter::EncodableMap m;
        m[flutter::EncodableValue("transferred")] = flutter::EncodableValue(static_cast<int64_t>(info.transferred));
        m[flutter::EncodableValue("total")] = flutter::EncodableValue(static_cast<int64_t>(info.total));
        m[flutter::EncodableValue("path")] = flutter::EncodableValue(info.path);
        m[flutter::EncodableValue("completed")] = flutter::EncodableValue(info.completed);
        res->Success(flutter::EncodableValue(m));
      });
    });
  } else {
    result->NotImplemented();
  }
}

const FlutterDesktopPixelBuffer* JamiChannels::VideoTexture::CopyBuffer() {
  // Raster thread. Lock and keep the lock until ReleaseTrampoline (called by Flutter once it has consumed the
  // buffer) — this blocks OnVideoFrame from overwriting `buffer` mid-upload. A frame may not exist yet → null.
  mutex.lock();
  if (buffer.empty() || width <= 0 || height <= 0) {
    mutex.unlock();
    return nullptr;
  }
  fb.buffer = buffer.data();
  fb.width = static_cast<size_t>(width);
  fb.height = static_cast<size_t>(height);
  fb.release_callback = &VideoTexture::ReleaseTrampoline;
  fb.release_context = this;
  return &fb;  // mutex stays LOCKED until ReleaseTrampoline runs
}

void JamiChannels::VideoTexture::ReleaseTrampoline(void* ctx) {
  static_cast<VideoTexture*>(ctx)->mutex.unlock();
}

void JamiChannels::VideoTexture::FreeTrampoline(void* ctx) {
  delete static_cast<VideoTexture*>(ctx);
}

const FlutterDesktopPixelBuffer* JamiChannels::VideoTexture::CopyBufferTrampoline(size_t /*width*/,
                                                                                 size_t /*height*/,
                                                                                 void* user_data) {
  return static_cast<VideoTexture*>(user_data)->CopyBuffer();
}

int64_t JamiChannels::EnsureVideoTexture(const std::string& role) {
  if (!textures_) return -1;
  std::lock_guard<std::mutex> lock(tex_mutex_);
  auto& slot = (role == "self") ? self_tex_ : remote_tex_;
  if (slot && slot->id != -1) return slot->id;
  slot = std::make_unique<VideoTexture>();
  VideoTexture* vt = slot.get();
  FlutterDesktopTextureInfo info{};
  info.type = kFlutterDesktopPixelBufferTexture;
  info.pixel_buffer_config.callback = &VideoTexture::CopyBufferTrampoline;
  info.pixel_buffer_config.user_data = vt;
  vt->id = FlutterDesktopTextureRegistrarRegisterExternalTexture(textures_, &info);
  return vt->id;
}

void JamiChannels::OnVideoFrame(const std::string& role, const uint8_t* rgba, int w, int h) {
  const auto byteCount = sybl::video::DecodedRgbaByteCount(w, h);
  if (!byteCount || !rgba) return;
  VideoTexture* vt = nullptr;
  {
    std::lock_guard<std::mutex> lock(tex_mutex_);
    VideoTexture* slot = (role == "self") ? self_tex_.get() : remote_tex_.get();
    if (slot && slot->id != -1) vt = slot;  // raw ptr stays valid: slots reset only at teardown (sink cleared first)
  }
  if (!vt) return;  // Dart hasn't created this role's texture yet — drop; the next frame (~33ms) will land
  {
    std::lock_guard<std::mutex> lock(vt->mutex);
    if (vt->buffer.size() != *byteCount) vt->buffer.resize(*byteCount);
    std::memcpy(vt->buffer.data(), rgba, *byteCount);
    vt->width = w;
    vt->height = h;
  }
  FlutterDesktopTextureRegistrarMarkExternalTextureFrameAvailable(textures_, vt->id);
}

void JamiChannels::PostToPlatform(std::function<void()> fn) {
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    queue_.push_back(std::move(fn));
  }
  if (msg_window_) PostMessageW(msg_window_, WM_JAMI_DISPATCH, 0, 0);
}

void JamiChannels::SendDiagnosticCommand(const std::string& command) {
  // FlutterWindow invokes this on the platform thread, so deliver directly rather than posting back through the
  // message-only window. A command sent before Dart attaches is rejected by the caller's subsequent observable
  // state check, just like any pre-listen EventChannel event.
  if (event_sink_) {
    event_sink_->Success(ToEventValue("stressCommand", {{"command", command}}));
  }
}

void JamiChannels::SendInviteLink(const std::string& link) {
  if (event_sink_) {
    event_sink_->Success(ToEventValue("inviteLink", {{"link", link}}));
  } else {
    pending_invite_link_ = link;
  }
}

bool JamiChannels::HandleRemoteWindowMessage(UINT message,
                                             WPARAM wparam,
                                             LPARAM lparam) {
  if (message == WM_TIMER && remote_controller_)
    remote_controller_->Poll();
  const bool handled = remote_control_ &&
      remote_control_->HandleWindowMessage(message, wparam, lparam);
  if (message == WM_TIMER) PruneRemoteControlRoles();
  return handled;
}

void JamiChannels::PruneRemoteControlRoles() {
  for (const auto& [call_id, role] : remote_roles_.Snapshot()) {
    if (role == sybl::remote::LocalControlRole::kController &&
        (!remote_controller_ ||
         !remote_controller_->OwnsCall(call_id))) {
      remote_roles_.Release(call_id, role);
    } else if (role == sybl::remote::LocalControlRole::kControllee &&
               (!remote_control_ ||
                !remote_control_->OwnsCall(call_id))) {
      remote_roles_.Release(call_id, role);
    }
  }
}

void JamiChannels::ShutdownRemoteControl() {
  annotation_overlay_.Shutdown();
  if (remote_controller_) remote_controller_->Shutdown();
  if (remote_control_) remote_control_->Shutdown();
}

void JamiChannels::DrainQueue() {
  std::deque<std::function<void()>> local;
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    local.swap(queue_);
  }
  for (auto& fn : local) fn();  // platform thread: channel replies / sink->Success happen here
}

void JamiChannels::StartWindowShake() {
  if (window_shaking_) return;
  if (!::IsWindowVisible(owner_) || ::IsIconic(owner_) || ::IsZoomed(owner_) ||
      ::GetAncestor(::GetForegroundWindow(), GA_ROOT) != owner_) return;
  // Finish each short pulse before accepting another, without accumulating moves.
  if (!::GetWindowRect(owner_, &shake_origin_)) return;
  shake_position_ = {shake_origin_.left, shake_origin_.top};
  window_shaking_ = true;
  shake_started_ = ::GetTickCount64();
  if (!::SetTimer(msg_window_, kWindowShakeTimer, 16, nullptr)) StopWindowShake();
}

void JamiChannels::StopWindowShake() {
  if (!window_shaking_) return;
  ::KillTimer(msg_window_, kWindowShakeTimer);
  window_shaking_ = false;
  RECT current{};
  // Preserve a user's move, snap or maximize performed during the effect.
  if (!::IsIconic(owner_) && !::IsZoomed(owner_) &&
      ::GetWindowRect(owner_, &current) &&
      current.left == shake_position_.x && current.top == shake_position_.y &&
      current.right - current.left == shake_origin_.right - shake_origin_.left &&
      current.bottom - current.top == shake_origin_.bottom - shake_origin_.top) {
    ::SetWindowPos(owner_, nullptr, shake_origin_.left, shake_origin_.top, 0, 0,
                   SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
  }
}

void JamiChannels::TickWindowShake() {
  if (!window_shaking_) return;
  RECT current{};
  const auto elapsed = ::GetTickCount64() - shake_started_;
  if (elapsed >= 192 || !::IsWindowVisible(owner_) || ::IsIconic(owner_) ||
      ::IsZoomed(owner_) ||
      ::GetAncestor(::GetForegroundWindow(), GA_ROOT) != owner_ ||
      !::GetWindowRect(owner_, &current) ||
      current.left != shake_position_.x || current.top != shake_position_.y ||
      current.right - current.left != shake_origin_.right - shake_origin_.left ||
      current.bottom - current.top != shake_origin_.bottom - shake_origin_.top) {
    StopWindowShake();
    return;
  }
  constexpr int offsets[] = {0, 3, -3, 3, -3, 2, -2, 2, -2, 1, -1, 0};
  const int x = shake_origin_.left + offsets[elapsed / 16];
  if (::SetWindowPos(owner_, nullptr, x, shake_origin_.top, 0, 0,
                     SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE)) {
    shake_position_ = {x, shake_origin_.top};
  } else {
    StopWindowShake();
  }
}

LRESULT CALLBACK JamiChannels::WndProc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
  if (msg == WM_NCCREATE) {
    auto* cs = reinterpret_cast<CREATESTRUCTW*>(lparam);
    SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(cs->lpCreateParams));
    return DefWindowProcW(hwnd, msg, wparam, lparam);
  }
  if (msg == WM_TIMER && wparam == kDeviceRevocationTimer) {
    auto* self = reinterpret_cast<JamiChannels*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    if (self && self->device_revoke_timer_ready_) jami_bridge::PollKnownDeviceRevocations();
    return 0;
  }
  if (msg == WM_TIMER && wparam == kWindowShakeTimer) {
    auto* self = reinterpret_cast<JamiChannels*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    if (self) self->TickWindowShake();
    return 0;
  }
  if (msg == WM_JAMI_DISPATCH) {
    auto* self = reinterpret_cast<JamiChannels*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    if (self) self->DrainQueue();
    return 0;
  }
  return DefWindowProcW(hwnd, msg, wparam, lparam);
}
