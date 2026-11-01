#include "win32_input_adapter.h"
#include "remote_control_win32_constants.h"

#define NOMINMAX
#include <windows.h>
#include <bcrypt.h>

#include <limits>
#include <vector>

namespace sybl::remote {
namespace {

bool SendOne(INPUT input) {
  return SendInput(1, &input, sizeof(INPUT)) == 1;
}

std::optional<POINT> QueryCursorPosition() {
  POINT point{};
  return GetCursorPos(&point) ? std::optional<POINT>(point) : std::nullopt;
}

bool IsExtendedKey(std::uint16_t key) {
  switch (key) {
    case VK_RMENU:
    case VK_RCONTROL:
    case VK_INSERT:
    case VK_DELETE:
    case VK_HOME:
    case VK_END:
    case VK_PRIOR:
    case VK_NEXT:
    case VK_LEFT:
    case VK_UP:
    case VK_RIGHT:
    case VK_DOWN:
    case VK_NUMLOCK:
    case VK_CANCEL:
    case VK_SNAPSHOT:
    case VK_DIVIDE:
      return true;
    default:
      return false;
  }
}

INPUT KeyInput(std::uint16_t key, bool down) {
  INPUT input{};
  input.type = INPUT_KEYBOARD;
  input.ki.wVk = key;
  input.ki.dwFlags = (down ? 0U : KEYEVENTF_KEYUP) |
      (IsExtendedKey(key) ? KEYEVENTF_EXTENDEDKEY : 0U);
  input.ki.dwExtraInfo = static_cast<ULONG_PTR>(kRemoteInputExtraInfo);
  return input;
}

INPUT UnicodeInput(std::uint16_t unit, bool key_up) {
  INPUT input{};
  input.type = INPUT_KEYBOARD;
  input.ki.wScan = unit;
  input.ki.dwFlags = KEYEVENTF_UNICODE | (key_up ? KEYEVENTF_KEYUP : 0U);
  input.ki.dwExtraInfo = static_cast<ULONG_PTR>(kRemoteInputExtraInfo);
  return input;
}

std::optional<std::pair<DWORD, DWORD>> ButtonFlags(MouseButton button, bool down) {
  switch (button) {
    case MouseButton::kLeft:
      return std::pair<DWORD, DWORD>{down ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP, 0};
    case MouseButton::kRight:
      return std::pair<DWORD, DWORD>{down ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_RIGHTUP, 0};
    case MouseButton::kMiddle:
      return std::pair<DWORD, DWORD>{down ? MOUSEEVENTF_MIDDLEDOWN : MOUSEEVENTF_MIDDLEUP, 0};
    case MouseButton::kX1:
      return std::pair<DWORD, DWORD>{down ? MOUSEEVENTF_XDOWN : MOUSEEVENTF_XUP, XBUTTON1};
    case MouseButton::kX2:
      return std::pair<DWORD, DWORD>{down ? MOUSEEVENTF_XDOWN : MOUSEEVENTF_XUP, XBUTTON2};
  }
  return std::nullopt;
}

std::string Hex(const std::vector<std::uint8_t>& bytes) {
  static constexpr char kHex[] = "0123456789abcdef";
  std::string result;
  result.resize(bytes.size() * 2);
  for (std::size_t i = 0; i < bytes.size(); ++i) {
    result[i * 2] = kHex[bytes[i] >> 4];
    result[i * 2 + 1] = kHex[bytes[i] & 0x0f];
  }
  return result;
}

}  // namespace

Win32InputAdapter::Win32InputAdapter(InputSender sender,
                                     CursorPositionQuery cursor_position,
                                     SurfaceValidator surface_validator)
    : sender_(sender ? std::move(sender) : SendOne),
      cursor_position_(cursor_position ? std::move(cursor_position) : QueryCursorPosition),
      surface_validator_(std::move(surface_validator)) {}

bool Win32InputAdapter::BindCursorPosition(
    INPUT& input, const DesktopRect& source,
    const DesktopRect& virtual_desktop) const {
  const auto point = cursor_position_();
  if (!point || source.width <= 0 || source.height <= 0 ||
      point->x < source.left || point->y < source.top ||
      static_cast<std::int64_t>(point->x) >=
          static_cast<std::int64_t>(source.left) + source.width ||
      static_cast<std::int64_t>(point->y) >=
          static_cast<std::int64_t>(source.top) + source.height)
    return false;
  const auto mapped = MapToVirtualDesktop(
      MoveEvent{
          source.width == 1 ? 0 :
              static_cast<double>(static_cast<std::int64_t>(point->x) - source.left) /
                  (source.width - 1),
          source.height == 1 ? 0 :
              static_cast<double>(static_cast<std::int64_t>(point->y) - source.top) /
                  (source.height - 1)},
      source, virtual_desktop);
  if (!mapped) return false;
  input.mi.dx = mapped->x;
  input.mi.dy = mapped->y;
  // Position and button/wheel belong to the same INPUT. A physical move after
  // the cursor query cannot redirect this submission to another monitor.
  input.mi.dwFlags |= MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
  return true;
}

bool SendUnicodeCodeUnitSafely(std::uint16_t code_unit,
                               const UnicodeCodeUnitSender& sender) {
  if (code_unit == 0 || !sender || !sender(code_unit, false)) return false;
  if (sender(code_unit, true)) return true;
  sender(code_unit, true);
  return false;
}

bool Win32InputAdapter::Apply(const InputEvent& event,
                              const DesktopRect& source,
                              const DesktopRect& virtual_desktop) {
  return ApplyGuarded(event, source, virtual_desktop, {});
}

bool Win32InputAdapter::ApplyGuarded(
    const InputEvent& event,
    const DesktopRect& source,
    const DesktopRect& virtual_desktop,
    const std::function<bool()>& allowed) {
  if (!allowed || !allowed() || !pending_unicode_releases_.empty()) return false;
  const auto send = [&](const INPUT& input) {
    return allowed() && sender_(input);
  };
  const auto send_mouse = [&](INPUT input, bool bind_cursor) {
    try {
      if (bind_cursor && !BindCursorPosition(input, source, virtual_desktop)) return false;
      // Re-resolve the host's complete granted surface after the cursor query,
      // immediately before submission. Geometry alone cannot identify a device.
      return surface_validator_ && surface_validator_(source, virtual_desktop) && send(input);
    } catch (...) {
      return false;
    }
  };
  if (const auto* move = std::get_if<MoveEvent>(&event)) {
    const auto mapped = MapToVirtualDesktop(*move, source, virtual_desktop);
    if (!mapped) return false;
    INPUT input{};
    input.type = INPUT_MOUSE;
    input.mi.dx = mapped->x;
    input.mi.dy = mapped->y;
    input.mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE |
        MOUSEEVENTF_VIRTUALDESK;
    input.mi.dwExtraInfo = static_cast<ULONG_PTR>(kRemoteInputExtraInfo);
    return send_mouse(input, false);
  }
  if (const auto* button = std::get_if<ButtonEvent>(&event)) {
    const auto flags = ButtonFlags(button->button, button->down);
    if (!flags) return false;
    INPUT input{};
    input.type = INPUT_MOUSE;
    input.mi.dwFlags = flags->first;
    input.mi.mouseData = flags->second;
    input.mi.dwExtraInfo = static_cast<ULONG_PTR>(kRemoteInputExtraInfo);
    return send_mouse(input, true);
  }
  if (const auto* wheel = std::get_if<WheelEvent>(&event)) {
    INPUT input{};
    input.type = INPUT_MOUSE;
    input.mi.dwFlags = MOUSEEVENTF_WHEEL;
    input.mi.mouseData = static_cast<DWORD>(wheel->delta);
    input.mi.dwExtraInfo = static_cast<ULONG_PTR>(kRemoteInputExtraInfo);
    return send_mouse(input, true);
  }
  if (const auto* key = std::get_if<KeyEvent>(&event))
    return send(KeyInput(key->virtual_key, key->down));

  const auto* text = std::get_if<TextEvent>(&event);
  if (!text || text->utf8.empty() ||
      text->utf8.size() > static_cast<std::size_t>(std::numeric_limits<int>::max())) {
    return false;
  }
  const auto utf8_size = static_cast<int>(text->utf8.size());
  const int required = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                           text->utf8.data(), utf8_size,
                                           nullptr, 0);
  if (required <= 0) return false;
  std::wstring utf16(static_cast<std::size_t>(required), L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text->utf8.data(),
                          utf8_size, utf16.data(), required) != required) {
    return false;
  }
  for (const auto code_unit : utf16) {
    if (!allowed()) return false;
    if (!SendUnicodeCodeUnitSafely(
            static_cast<std::uint16_t>(code_unit),
            [&](std::uint16_t unit, bool key_up) {
              // Once down was accepted, up is cleanup, not new remote input.
              // A failed up stays owed until native release confirms it.
              if (!key_up && !allowed()) return false;
              const bool sent = sender_(UnicodeInput(unit, key_up));
              if (key_up && sent) pending_unicode_releases_.erase(unit);
              if (!key_up && sent) pending_unicode_releases_.insert(unit);
              return sent;
            })) {
      return false;
    }
  }
  return allowed();
}

bool Win32InputAdapter::ReleaseKey(std::uint16_t virtual_key) {
  return virtual_key != 0 && sender_(KeyInput(virtual_key, false));
}

bool Win32InputAdapter::ReleaseButton(MouseButton button) {
  const auto flags = ButtonFlags(button, false);
  if (!flags) return false;
  INPUT input{};
  input.type = INPUT_MOUSE;
  input.mi.dwFlags = flags->first;
  input.mi.mouseData = flags->second;
  input.mi.dwExtraInfo = static_cast<ULONG_PTR>(kRemoteInputExtraInfo);
  return sender_(input);
}

bool Win32InputAdapter::ReleasePending() {
  for (auto it = pending_unicode_releases_.begin();
       it != pending_unicode_releases_.end();) {
    if (sender_(UnicodeInput(*it, true))) {
      it = pending_unicode_releases_.erase(it);
    } else {
      ++it;
    }
  }
  return pending_unicode_releases_.empty();
}

std::optional<std::string> Win32Crypto::GenerateHex(std::size_t bytes) {
  if (bytes == 0 || bytes > 64 || bytes > std::numeric_limits<ULONG>::max())
    return std::nullopt;
  std::vector<std::uint8_t> random(bytes);
  if (BCryptGenRandom(nullptr, random.data(), static_cast<ULONG>(random.size()),
                      BCRYPT_USE_SYSTEM_PREFERRED_RNG) < 0) {
    return std::nullopt;
  }
  return Hex(random);
}

std::optional<std::string> Win32Crypto::Sha256Hex(std::string_view bytes) {
  if (bytes.size() > std::numeric_limits<ULONG>::max()) return std::nullopt;
  BCRYPT_ALG_HANDLE algorithm = nullptr;
  BCRYPT_HASH_HANDLE hash = nullptr;
  DWORD object_size = 0;
  DWORD hash_size = 0;
  DWORD copied = 0;
  if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) < 0)
    return std::nullopt;
  const auto close_algorithm = [&]() {
    if (hash) BCryptDestroyHash(hash);
    BCryptCloseAlgorithmProvider(algorithm, 0);
  };
  if (BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH,
                        reinterpret_cast<PUCHAR>(&object_size), sizeof(object_size),
                        &copied, 0) < 0 ||
      BCryptGetProperty(algorithm, BCRYPT_HASH_LENGTH,
                        reinterpret_cast<PUCHAR>(&hash_size), sizeof(hash_size),
                        &copied, 0) < 0 ||
      hash_size != 32) {
    close_algorithm();
    return std::nullopt;
  }
  std::vector<std::uint8_t> object(object_size);
  std::vector<std::uint8_t> digest(hash_size);
  if (BCryptCreateHash(algorithm, &hash, object.data(),
                       static_cast<ULONG>(object.size()), nullptr, 0, 0) < 0 ||
      BCryptHashData(hash,
                     reinterpret_cast<PUCHAR>(const_cast<char*>(bytes.data())),
                     static_cast<ULONG>(bytes.size()), 0) < 0 ||
      BCryptFinishHash(hash, digest.data(), static_cast<ULONG>(digest.size()), 0) < 0) {
    close_algorithm();
    return std::nullopt;
  }
  close_algorithm();
  return Hex(digest);
}

}  // namespace sybl::remote
