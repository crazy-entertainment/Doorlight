#pragma once

#include "remote_control_policy.h"

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <functional>

namespace sybl::remote {

using UnicodeCodeUnitSender =
    std::function<bool(std::uint16_t code_unit, bool key_up)>;

// Sends one UTF-16 code unit as down/up. If the down succeeds but the first up
// fails, a best-effort compensating up is issued and the operation still
// reports failure so native policy revokes the session.
bool SendUnicodeCodeUnitSafely(std::uint16_t code_unit,
                               const UnicodeCodeUnitSender& sender);

// The production implementation is deliberately behind the InputAdapter and
// SecretSource/HashProvider interfaces. Policy tests inject recording fakes and
// therefore never call SendInput or mutate the real clipboard/input state.
class Win32InputAdapter final : public InputAdapter {
 public:
  using InputSender = std::function<bool(const INPUT&)>;
  using CursorPositionQuery = std::function<std::optional<POINT>()>;
  using SurfaceValidator = std::function<bool(const DesktopRect&, const DesktopRect&)>;
  // The host supplies exact current surface validation. Without it, mouse
  // submissions are refused. Cleanup releases do not require a cursor/source.
  explicit Win32InputAdapter(InputSender sender = {},
                             CursorPositionQuery cursor_position = {},
                             SurfaceValidator surface_validator = {});
  bool Apply(const InputEvent& event,
             const DesktopRect& source,
             const DesktopRect& virtual_desktop) override;
  bool ApplyGuarded(const InputEvent& event,
                    const DesktopRect& source,
                    const DesktopRect& virtual_desktop,
                    const std::function<bool()>& allowed) override;
  bool ReleaseKey(std::uint16_t virtual_key) override;
  bool ReleaseButton(MouseButton button) override;
  bool ReleasePending() override;

 private:
  bool BindCursorPosition(INPUT& input, const DesktopRect& source,
                          const DesktopRect& virtual_desktop) const;
  InputSender sender_;
  CursorPositionQuery cursor_position_;
  SurfaceValidator surface_validator_;
  std::set<std::uint16_t> pending_unicode_releases_;
};

class Win32Crypto final : public SecretSource, public HashProvider {
 public:
  std::optional<std::string> GenerateHex(std::size_t bytes) override;
  std::optional<std::string> Sha256Hex(std::string_view bytes) override;
};

}  // namespace sybl::remote
