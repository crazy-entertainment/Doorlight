#ifdef NDEBUG
#undef NDEBUG
#endif

#include "win32_input_adapter.h"

#include "remote_control_win32_constants.h"

#include <cassert>
#include <cstdint>
#include <cstdio>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

using namespace sybl::remote;

namespace {

// Reproduces the round trip the OS performs on the injected-input marker:
// SendInput takes it as ULONG_PTR (64-bit on x64), raw input hands it back in a
// 32-bit ULONG field. Anything that does not survive this is unrecognisable on
// the way back, and every event we injected gets misread as the local user
// grabbing the mouse.
std::uintptr_t RawInputReadback(std::uintptr_t sent_via_dwextrainfo) {
  return static_cast<std::uintptr_t>(
      static_cast<std::uint32_t>(sent_via_dwextrainfo));
}

void MouseOutsideGrantedSourceIsRefused(bool wheel) {
  const DesktopRect source{-1920, -200, 1920, 1080};
  const DesktopRect desktop{-1920, -200, 3840, 1280};
  std::vector<INPUT> sent;
  Win32InputAdapter adapter(
      [&](const INPUT& input) { sent.push_back(input); return true; },
      [] { return std::optional<POINT>(POINT{100, 200}); },
      [](const DesktopRect&, const DesktopRect&) { return true; });
  const InputEvent event = wheel ? InputEvent{WheelEvent{120}}
      : InputEvent{ButtonEvent{MouseButton::kLeft, true}};
  assert(!adapter.ApplyGuarded(event, source, desktop, [] { return true; }));
  assert(sent.empty());
}

void MousePositionAndButtonAreOneSubmission() {
  const DesktopRect source{-1920, -200, 1920, 1080};
  const DesktopRect desktop{-1920, -200, 3840, 1280};
  POINT cursor{-480, 270};
  const POINT captured = cursor;
  std::vector<INPUT> sent;
  Win32InputAdapter adapter(
      [&](const INPUT& input) {
        cursor = POINT{100, 200};  // Local movement after the position query.
        sent.push_back(input);
        return true;
      },
      [&] { return std::optional<POINT>(cursor); },
      [](const DesktopRect&, const DesktopRect&) { return true; });
  assert(adapter.ApplyGuarded(ButtonEvent{MouseButton::kX1, true},
                              source, desktop, [] { return true; }));
  assert(sent.size() == 1);
  const auto expected = MapToVirtualDesktop(
      MoveEvent{static_cast<double>(captured.x - source.left) / (source.width - 1),
                static_cast<double>(captured.y - source.top) / (source.height - 1)},
      source, desktop);
  assert(expected);
  assert(sent[0].mi.dwFlags == (MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE |
                                 MOUSEEVENTF_VIRTUALDESK | MOUSEEVENTF_XDOWN));
  assert(sent[0].mi.dx == expected->x && sent[0].mi.dy == expected->y);
  assert(sent[0].mi.mouseData == XBUTTON1);
  assert(sent[0].mi.dwExtraInfo == kRemoteInputExtraInfo);
}

void MouseRejectsChangedSurfaceAndUnknownPosition() {
  const DesktopRect desktop{0, 0, 1920, 1080};
  bool surface_current = true;
  bool cursor_known = true;
  std::vector<INPUT> sent;
  Win32InputAdapter adapter(
      [&](const INPUT& input) { sent.push_back(input); return true; },
      [&] { return cursor_known ? std::optional<POINT>(POINT{100, 200}) : std::nullopt; },
      [&](const DesktopRect&, const DesktopRect&) { return surface_current; });
  assert(adapter.ApplyGuarded(MoveEvent{0.5, 0.5}, desktop, desktop, [] { return true; }));
  surface_current = false;
  assert(!adapter.ApplyGuarded(ButtonEvent{MouseButton::kLeft, true},
                               desktop, desktop, [] { return true; }));
  assert(sent.size() == 1);
  surface_current = true;
  cursor_known = false;
  assert(!adapter.ApplyGuarded(WheelEvent{120}, desktop, desktop, [] { return true; }));
  assert(sent.size() == 1);
}

void MouseQueryFailuresKeepCleanupAvailable() {
  const DesktopRect desktop{0, 0, 1920, 1080};
  std::vector<INPUT> sent;
  Win32InputAdapter query_failure(
      [&](const INPUT& input) { sent.push_back(input); return true; },
      []() -> std::optional<POINT> { throw std::runtime_error("synthetic cursor failure"); },
      [](const DesktopRect&, const DesktopRect&) { return true; });
  assert(!query_failure.ApplyGuarded(ButtonEvent{MouseButton::kLeft, true},
                                     desktop, desktop, [] { return true; }));
  assert(sent.empty());
  assert(query_failure.ReleaseButton(MouseButton::kLeft));
  assert(sent.size() == 1 && sent[0].mi.dwFlags == MOUSEEVENTF_LEFTUP);
  Win32InputAdapter surface_failure(
      [&](const INPUT& input) { sent.push_back(input); return true; },
      [] { return std::optional<POINT>(POINT{100, 200}); },
      [](const DesktopRect&, const DesktopRect&) -> bool {
        throw std::runtime_error("synthetic surface failure");
      });
  assert(!surface_failure.ApplyGuarded(MoveEvent{0.5, 0.5},
                                       desktop, desktop, [] { return true; }));
  assert(sent.size() == 1);
}

}  // namespace

int main(int argc, char** argv) {
  if (argc > 2) return 2;
  const std::string selected = argc == 2 ? argv[1] : "";
  if (selected.empty() || selected == "outside-button") MouseOutsideGrantedSourceIsRefused(false);
  if (selected.empty() || selected == "outside-wheel") MouseOutsideGrantedSourceIsRefused(true);
  if (selected.empty() || selected == "atomic-position") MousePositionAndButtonAreOneSubmission();
  if (selected.empty() || selected == "source-query") MouseRejectsChangedSurfaceAndUnknownPosition();
  if (selected.empty() || selected == "query-failure") MouseQueryFailuresKeepCleanupAvailable();
  if (!selected.empty()) {
    if (selected != "outside-button" && selected != "outside-wheel" &&
        selected != "atomic-position" && selected != "source-query" && selected != "query-failure") {
      std::fprintf(stderr, "Unknown test case: %s\n", selected.c_str());
      return 2;
    }
    return 0;
  }
  const DesktopRect desktop{0, 0, 1920, 1080};
  std::vector<INPUT> injected;
  bool allowed = true;
  Win32InputAdapter guarded([&](const INPUT& input) {
    injected.push_back(input);
    allowed = false;  // Protection enters after the first Unicode key-down.
    return true;
  });
  assert(!guarded.ApplyGuarded(TextEvent{"ab"}, desktop, desktop,
                               [&]() { return allowed; }));
  assert(injected.size() == 2);  // Only the matching cleanup key-up may follow.
  assert(injected[0].ki.wScan == 'a');
  assert(injected[1].ki.wScan == 'a');
  assert((injected[1].ki.dwFlags & KEYEVENTF_KEYUP) != 0);
  injected.clear();
  assert(!guarded.ApplyGuarded(KeyEvent{VK_CONTROL, true}, desktop, desktop,
                               [&]() { return allowed; }));
  assert(injected.empty());
  for (const InputEvent& event : std::vector<InputEvent>{
           MoveEvent{0.5, 0.5}, ButtonEvent{MouseButton::kLeft, true},
           WheelEvent{120}, TextEvent{"x"}}) {
    assert(!guarded.ApplyGuarded(event, desktop, desktop,
                                [&]() { return allowed; }));
    assert(injected.empty());
  }
  assert(!guarded.Apply(KeyEvent{VK_CONTROL, true}, desktop, desktop));
  assert(injected.empty());

  bool release_succeeds = false;
  Win32InputAdapter failed_release([&](const INPUT& input) {
    injected.push_back(input);
    return (input.ki.dwFlags & KEYEVENTF_KEYUP) == 0 || release_succeeds;
  });
  assert(!failed_release.ApplyGuarded(TextEvent{"x"}, desktop, desktop,
                                      []() { return true; }));
  assert(injected.size() == 3);  // Down, failed up, failed compensation.
  assert(!failed_release.ReleasePending());
  const auto pending_count = injected.size();
  assert(!failed_release.ApplyGuarded(TextEvent{"y"}, desktop, desktop,
                                      []() { return true; }));
  assert(injected.size() == pending_count);
  release_succeeds = true;
  assert(failed_release.ReleasePending());
  assert(failed_release.ReleasePending());  // Idempotent cleanup.
  assert(failed_release.ApplyGuarded(TextEvent{"y"}, desktop, desktop,
                                     []() { return true; }));

  // The marker must compare equal after the ULONG truncation, or
  // Win32RawInputMonitor::Classify can never return kInjected.
  assert(RawInputReadback(kRemoteInputExtraInfo) == kRemoteInputExtraInfo);
  // And it must not collide with the 0 that ordinary hardware input carries.
  assert(kRemoteInputExtraInfo != 0);

  // Construction is side-effect-free. Deliberately do not call Apply or either
  // release method: repository tests must never synthesize real machine input.
  Win32InputAdapter adapter;
  (void)adapter;

  Win32Crypto crypto;
  const auto first = crypto.GenerateHex(16);
  const auto second = crypto.GenerateHex(16);
  assert(first && second);
  assert(first->size() == 32 && second->size() == 32);
  assert(*first != *second);
  assert(!crypto.GenerateHex(0));
  assert(!crypto.GenerateHex(65));

  const auto digest = crypto.Sha256Hex("hello");
  assert(digest);
  assert(*digest ==
         "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824");

  std::vector<std::pair<std::uint16_t, bool>> calls;
  std::vector<bool> results{true, true};
  assert(SendUnicodeCodeUnitSafely(
      0x00e9, [&](std::uint16_t unit, bool key_up) {
        calls.emplace_back(unit, key_up);
        const bool result = results.front();
        results.erase(results.begin());
        return result;
      }));
  assert((calls == std::vector<std::pair<std::uint16_t, bool>>{
                       {0x00e9, false}, {0x00e9, true}}));

  calls.clear();
  results = {true, false, true};
  assert(!SendUnicodeCodeUnitSafely(
      0x00e9, [&](std::uint16_t unit, bool key_up) {
        calls.emplace_back(unit, key_up);
        const bool result = results.front();
        results.erase(results.begin());
        return result;
      }));
  assert((calls == std::vector<std::pair<std::uint16_t, bool>>{
                       {0x00e9, false}, {0x00e9, true},
                       {0x00e9, true}}));

  calls.clear();
  results = {false};
  assert(!SendUnicodeCodeUnitSafely(
      0x00e9, [&](std::uint16_t unit, bool key_up) {
        calls.emplace_back(unit, key_up);
        const bool result = results.front();
        results.erase(results.begin());
        return result;
      }));
  assert((calls == std::vector<std::pair<std::uint16_t, bool>>{
                       {0x00e9, false}}));
}
