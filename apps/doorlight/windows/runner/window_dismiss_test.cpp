#include "window_dismiss.h"
#include <dwmapi.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <string>

namespace {
int failures = 0;
struct FixtureEvent { UINT message; WPARAM wp; LPARAM lp; };
FixtureEvent preview_events[64]{};
unsigned preview_event_count = 0;
bool record_preview = false;
LRESULT CALLBACK FixtureProc(HWND hwnd, UINT message, WPARAM wp, LPARAM lp) {
  if (record_preview && preview_event_count < 64 &&
      (message == WM_CLOSE || message == WM_MOVE || message == WM_SIZE ||
       message == WM_SHOWWINDOW || message == WM_DESTROY || message == WM_SYSCOMMAND))
    preview_events[preview_event_count++] = {message, wp, lp};
  return DefWindowProcW(hwnd, message, wp, lp);
}
DWORD Cloak(HWND window, HRESULT* status = nullptr) {
  DWORD cloak = 0xffffffff;
  const HRESULT result = DwmGetWindowAttribute(window, DWMWA_CLOAKED, &cloak, sizeof(cloak));
  if (status) *status = result;
  return cloak;
}
void Check(bool value, const char* label) {
  if (!value) { std::fprintf(stderr, "%s\n", label); ++failures; }
}
RECT Bounds(HWND window, BOOL* status = nullptr) {
  RECT rect{};
  const BOOL result = GetWindowRect(window, &rect);
  if (status) *status = result;
  return rect;
}
WINDOWPLACEMENT Placement(HWND window, BOOL* status = nullptr) {
  WINDOWPLACEMENT placement{sizeof(placement)};
  const BOOL result = GetWindowPlacement(window, &placement);
  if (status) *status = result;
  return placement;
}
void Pump(DWORD duration, const std::function<void()>& observe = {}) {
  const ULONGLONG end = GetTickCount64() + duration;
  do {
    MSG message{};
    while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
      TranslateMessage(&message);
      DispatchMessageW(&message);
      if (observe) observe();
      if (GetTickCount64() >= end) return;
    }
    Sleep(1);
  } while (GetTickCount64() < end);
}
// Wait for lifecycle acknowledgement before changing the fixture's window state.
bool PumpUntil(const std::function<bool()>& completed, DWORD timeout,
    const std::function<void()>& observe = {}) {
  const ULONGLONG end = GetTickCount64() + timeout;
  while (!completed() && GetTickCount64() < end) Pump(1, observe);
  return completed();
}
}

LRESULT CALLBACK AttentionPeerProc(HWND hwnd, UINT message, WPARAM wp, LPARAM lp) {
  if (message == WM_DESTROY) PostQuitMessage(0);
  if (message == WM_APP + 1) {
    const BOOL hidden = wp != 0;
    return SUCCEEDED(DwmSetWindowAttribute(hwnd, DWMWA_CLOAK, &hidden, sizeof(hidden)));
  }
  return DefWindowProcW(hwnd, message, wp, lp);
}

int main(int argc, char** argv) {
  if (argc > 1 && std::strcmp(argv[1], "--attention-peer") == 0) {
    WNDCLASSW wc{};
    wc.lpfnWndProc = AttentionPeerProc;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.lpszClassName = L"DoorlightAttentionPeer";
    RegisterClassW(&wc);
    if (!CreateWindowW(wc.lpszClassName, L"Synthetic attention peer",
        WS_OVERLAPPEDWINDOW | WS_VISIBLE, 110, 110, 200, 200,
        nullptr, nullptr, wc.hInstance, nullptr)) return EXIT_FAILURE;
    MSG message{};
    while (GetMessageW(&message, nullptr, 0, 0) > 0) {
      TranslateMessage(&message);
      DispatchMessageW(&message);
    }
    return EXIT_SUCCESS;
  }
  using namespace sybl::window;
  for (const auto axis : {400, 700}) {
    const double cosine = .7071067811865476, sine = cosine;
    const double focal = axis * 1.6;
    const double span = axis * cosine * focal / (focal + axis * sine);
    Check(FoldOutlineDistance(span - .5, 0, axis, 300, cosine, sine) < 1,
        "compressed far edge retains a screen-space outline");
    Check(FoldOutlineDistance(.5, 0, axis, 300, cosine, sine) < 1,
        "hinge edge retains a screen-space outline");
    Check(FoldOutlineDistance(span * .5, 0, axis, 300, cosine, sine) > 10,
        "fold interior stays outside the outline");
  }
  std::vector<uint32_t> outlined(40 * 30, 0xff202020);
  ShapeDismissFrame(outlined, 40, 30, 8, RGB(64, 64, 69), 1);
  Check(outlined[20] == 0xff404045 && outlined[15 * 40] == 0xff404045 &&
      outlined[29 * 40 + 20] == 0xff404045 && outlined[15 * 40 + 39] == 0xff404045,
      "native outline is included on all four frame edges");
  Check(outlined[15 * 40 + 20] == 0xff202020 && outlined[0] == 0,
      "outline preserves content and rounded corner transparency");
  std::vector<uint32_t> borderless(40 * 30, 0xff202020);
  ShapeDismissFrame(borderless, 40, 30, 8, DWMWA_COLOR_NONE, 1);
  Check(borderless[20] == 0xff202020 && borderless[0] == 0,
      "borderless appearance stays borderless during motion");
  Check(!ValidDismissFrame(-1, 10, 40), "reject negative width");
  Check(!ValidDismissFrame(8192, 8192, 8192ull * 8192 * 4), "bound frame memory");
  Check(!ValidDismissFrame(10, 10, 399), "require exact RGBA byte count");
  const RECT source{-500, 100, 200, 600};
  const POINT target{-1100, 1050};
  const RECT first = DismissBounds(source, target, 0);
  const RECT last = DismissBounds(source, target, 1);
  Check(EqualRect(&first, &source), "first frame preserves full bounds");
  Check(last.right - last.left == 24 &&
      abs((last.left + last.right) / 2 - target.x) <= 1 &&
      abs((last.top + last.bottom) / 2 - target.y) <= 1,
      "finish at exact button center on negative-coordinate monitor");
  const RECT tiny{0, 0, 10, 5};
  const RECT tiny_end = DismissBounds(tiny, target, 1);
  Check(tiny_end.right - tiny_end.left <= 10, "small frames never grow past bitmap");

  WNDCLASSW wc{};
  wc.lpfnWndProc = FixtureProc;
  wc.hInstance = GetModuleHandleW(nullptr);
  wc.lpszClassName = L"DoorlightDismissFixture";
  RegisterClassW(&wc);
  HWND window = CreateWindowExW(0, wc.lpszClassName, L"Synthetic fixture",
      WS_OVERLAPPEDWINDOW | WS_VISIBLE, 100, 100, 400, 300,
      nullptr, nullptr, wc.hInstance, nullptr);
  Check(window != nullptr, "create synthetic owner");
  RECT client{};
  GetClientRect(window, &client);
  const int width = client.right, height = client.bottom;
  std::vector<uint8_t> frame(static_cast<size_t>(width) * height * 4, 255);
  const RECT original = Bounds(window);
  const auto placement = Placement(window);
  WindowDismissEffect effect;
  const auto await_completion = [&](const std::function<bool()>& completed,
      const char* label, const std::function<void()>& observe = {}) {
    if (PumpUntil(completed, 2000, observe)) return true;
    Check(false, label);
    effect.Reset();
    DestroyWindow(window);
    return false;
  };
  const BOOL concealed = TRUE, revealed = FALSE;
  Check(SUCCEEDED(DwmSetWindowAttribute(window, DWMWA_CLOAK, &concealed,
      sizeof(concealed))), "prepare preexisting concealment");
  Check(!effect.Start(window, width, height, frame, target, DismissStyle::kTray, [](bool) {}),
      "already concealed source cannot publish an independent frame");
  Check(!FindWindowW(L"DoorlightWindowDismiss", nullptr) &&
      Cloak(window) == DWM_CLOAKED_APP, "preexisting concealment is untouched");
  Check(!effect.PrepareRestore(window) && Cloak(window) == DWM_CLOAKED_APP,
      "restore cannot claim another owner's concealment");
  DwmSetWindowAttribute(window, DWMWA_CLOAK, &revealed, sizeof(revealed));
  bool completed = false;
  SetWindowDisplayAffinity(window, 0x11);
  Check(effect.Start(window, width, height, frame, target, DismissStyle::kTray, [&](bool successful) { Check(successful, "motion completed without rendering failure");
    completed = true;
    ShowWindow(window, SW_MINIMIZE);
    effect.Reset();
  }), "start protected synthetic minimize");
  HWND overlay = FindWindowW(L"DoorlightWindowDismiss", nullptr);
  DWORD affinity = 0;
  Check(overlay && GetWindowDisplayAffinity(overlay, &affinity) && affinity == 0x11,
      "exit surface has confirmed capture exclusion");
  Check(Cloak(window) == DWM_CLOAKED_APP,
      "whole source HWND including native shadow is concealed during exit");
  Check(Cloak(overlay) == 0, "presentation does not inherit the source cloak");
  const RECT during = Bounds(window);
  const auto during_placement = Placement(window);
  Check(EqualRect(&original, &during) && EqualRect(&placement.rcNormalPosition,
      &during_placement.rcNormalPosition), "animation never changes real placement");
  bool endpoint_seen = false;
  if (!await_completion([&] { return completed; },
      "protected minimize completion callback arrives", [&] {
    if (effect.active()) {
      const RECT endpoint = Bounds(overlay);
      if (endpoint.right - endpoint.left == 24 &&
          abs((endpoint.left + endpoint.right) / 2 - target.x) <= 1 &&
          abs((endpoint.top + endpoint.bottom) / 2 - target.y) <= 1)
        endpoint_seen = true;
    }
  })) return EXIT_FAILURE;
  Check(endpoint_seen, "present exact icon endpoint before completing minimize");
  Check(completed && IsIconic(window) && !effect.active(), "timer completes native minimize");
  Check(!(GetWindowLongPtrW(window, GWL_EXSTYLE) & WS_EX_LAYERED), "source style restored after minimize");
  Check(Cloak(window) == 0, "source cloak restored after minimize");
  GetWindowDisplayAffinity(window, &affinity);
  Check(affinity == 0x11, "source capture affinity survives presentation");
  ShowWindow(window, SW_RESTORE);
  const RECT restored = Bounds(window);
  Check(EqualRect(&original, &restored), "taskbar restore retains original bounds");

  SetWindowDisplayAffinity(window, WDA_NONE);
  bool door_completed = false;
  Check(effect.Start(window, width, height, frame, target, DismissStyle::kDoor, [&](bool successful) { Check(successful, "motion completed without rendering failure");
    ShowWindow(window, SW_HIDE);
    effect.Reset();
    door_completed = true;
  }), "start door exit");
  Pump(60);
  overlay = FindWindowW(L"DoorlightWindowDismiss", nullptr);
  const RECT door_bounds = Bounds(overlay);
  GetWindowDisplayAffinity(overlay, &affinity);
  Check(affinity == WDA_NONE, "presentation is stream-visible when source permits capture");
  Check(door_bounds.right - door_bounds.left < width &&
      door_bounds.bottom - door_bounds.top == height, "door narrows around its vertical hinge");
  if (!await_completion([&] { return door_completed; },
      "door completion callback arrives")) return EXIT_FAILURE;
  Check(!IsWindowVisible(window) && !effect.active(), "door completes while owner remains hidden");
  GetWindowDisplayAffinity(window, &affinity);
  Check(affinity == WDA_NONE, "source capture preference is unchanged");
  ShowWindow(window, SW_SHOW);
  Check(!effect.Start(window, width, height, frame, target, DismissStyle::kNone, [](bool) {}),
      "none never starts a presentation");
  int warp_completions = 0;
  Check(effect.Start(window, width, height, frame, target, DismissStyle::kWarp, [&](bool successful) { Check(successful, "motion completed without rendering failure");
    ++warp_completions;
    ShowWindow(window, SW_HIDE);
    effect.Reset();
  }), "start warp exit");
  if (!await_completion([&] { return warp_completions != 0; },
      "warp completion callback arrives")) return EXIT_FAILURE;
  Check(warp_completions == 1 && !effect.active() && !IsWindowVisible(window),
      "warp completes the intended native action exactly once");
  ShowWindow(window, SW_SHOW);
  Check(effect.Start(window, width, height, frame, target, DismissStyle::kDoor, [](bool) {}), "start cancellable exit");
  HWND cover = CreateWindowW(L"STATIC", nullptr, WS_CHILD | WS_VISIBLE | SS_BLACKRECT,
      0, 0, width, height, window, nullptr, wc.hInstance, nullptr);
  effect.Reset();
  Check(IsWindowVisible(window) && IsWindowVisible(cover) && !effect.active(),
      "covered cancellation removes stale exit surface");
  DestroyWindow(cover);
  SetWindowDisplayAffinity(window, WDA_MONITOR);
  Check(effect.Start(window, width, height, frame, target, DismissStyle::kDoor, [](bool) {}),
      "start monitor-protected exit");
  overlay = FindWindowW(L"DoorlightWindowDismiss", nullptr);
  Check(GetWindowDisplayAffinity(overlay, &affinity) && affinity == WDA_MONITOR,
      "monitor-only source protection is preserved before presentation");
  ShowWindow(window, SW_HIDE);
  effect.Reset();
  ShowWindow(window, SW_HIDE);
  Check(!effect.Start(window, width, height, frame, target, DismissStyle::kDoor, [](bool) {}),
      "never reveal a hidden owner for an effect");

  for (auto style : {DismissStyle::kTray, DismissStyle::kDoor, DismissStyle::kWarp,
                      DismissStyle::kFoldRight, DismissStyle::kFoldUp, DismissStyle::kFoldDown}) {
    ShowWindow(window, SW_HIDE);
    Check(effect.PrepareRestore(window), "conceal restore before showing source");
    ShowWindow(window, SW_SHOWNOACTIVATE);
    Check(Cloak(window) == DWM_CLOAKED_APP,
        "fresh-frame wait cannot flash the full-sized source");
    int restored_count = 0;
    Check(effect.Start(window, width, height, frame, target, style, [&](bool successful) { Check(successful, "motion completed without rendering failure");
      ++restored_count;
      effect.Reset();
    }, true), "start reverse presentation with freshly supplied pixels");
    overlay = FindWindowW(L"DoorlightWindowDismiss", nullptr);
    const RECT incoming = Bounds(overlay);
    const bool vertical = style == DismissStyle::kFoldUp || style == DismissStyle::kFoldDown;
    Check((vertical ? incoming.bottom - incoming.top : incoming.right - incoming.left) <= 24,
        "incoming starts collapsed along its fold axis");
    bool grew = false;
    const auto observe_growth = [&] {
      if (!effect.active()) return;
      const RECT opening = Bounds(overlay);
      if (vertical ? opening.bottom - opening.top > incoming.bottom - incoming.top :
          opening.right - opening.left > incoming.right - incoming.left) grew = true;
    };
    Pump(80, observe_growth);
    Check(grew,
        "incoming grows toward the remembered placement");
    bool live_handoff = false;
    if (!await_completion([&] { return restored_count != 0; },
        "incoming completion callback arrives", [&] {
      if (effect.active() && Cloak(window) == 0) live_handoff = true;
    })) return EXIT_FAILURE;
    Check(live_handoff, "incoming blends over live source before retiring proxy");
    Check(restored_count == 1 && IsWindowVisible(window) && !IsIconic(window) &&
        !effect.active() && Cloak(window) == 0,
        "reverse completes once with live source visible and cloak restored");
    const RECT after_restore = Bounds(window);
    Check(EqualRect(&original, &after_restore), "incoming preserves actual placement");
  }

  for (auto style : {DismissStyle::kDoor, DismissStyle::kFoldRight,
                      DismissStyle::kFoldUp, DismissStyle::kFoldDown}) {
    Check(effect.Start(window, width, height, frame, target, style, [](bool) {}, false, 800),
        "start directional fold");
    const RECT start = Bounds(FindWindowW(L"DoorlightWindowDismiss", nullptr));
    Pump(200);
    const RECT mid = Bounds(FindWindowW(L"DoorlightWindowDismiss", nullptr));
    const bool vertical = style == DismissStyle::kFoldUp || style == DismissStyle::kFoldDown;
    Check(vertical ? mid.right - mid.left == width && mid.bottom - mid.top < height :
        mid.bottom - mid.top == height && mid.right - mid.left < width,
        "fold narrows only its selected axis");
    Check(style == DismissStyle::kFoldDown ? mid.bottom == start.bottom :
        style == DismissStyle::kFoldRight ? mid.right == start.right :
        vertical ? mid.top == start.top : mid.left == start.left,
        "selected fold edge remains anchored");
    effect.Reset();
  }

  for (const UINT invalid_duration : {0u, 99u, 801u}) {
    Check(!effect.Start(window, width, height, frame, target, DismissStyle::kFade,
        [](bool) {}, false, invalid_duration), "reject out-of-range duration before concealment");
    Check(Cloak(window) == 0 && !effect.active(), "bad duration leaves live window untouched");
  }
  bool faded = false;
  Check(effect.Start(window, width, height, frame, target, DismissStyle::kFade,
      [&](bool successful) { Check(successful, "motion completed without rendering failure"); faded = true; effect.Reset(); }, false, 800), "start slow fade");
  overlay = FindWindowW(L"DoorlightWindowDismiss", nullptr);
  const RECT fade_start = Bounds(overlay);
  Pump(400);
  const RECT fade_mid = Bounds(overlay);
  Check(effect.active() && !faded && EqualRect(&fade_start, &fade_mid),
      "slow fade retains full geometry and exceeds the old fixed watchdog duration");
  if (!await_completion([&] { return faded; },
      "slow fade completion callback arrives")) return EXIT_FAILURE;
  Check(faded && !effect.active() && Cloak(window) == 0, "slow fade completes safely");
  ShowWindow(window, SW_HIDE);
  Check(effect.PrepareRestore(window), "prepare fast fade restore");
  ShowWindow(window, SW_SHOWNOACTIVATE);
  bool opened = false;
  Check(effect.Start(window, width, height, frame, target, DismissStyle::kFade,
      [&](bool successful) { Check(successful, "motion completed without rendering failure"); opened = true; effect.Reset(); }, true, 100), "start independent fast opening fade");
  overlay = FindWindowW(L"DoorlightWindowDismiss", nullptr);
  const RECT opening_start = Bounds(overlay);
  Pump(50);
  const RECT opening_mid = Bounds(overlay);
  Check(EqualRect(&opening_start, &opening_mid) && !opened,
      "opening fade changes opacity without shrinking or moving");
  if (!await_completion([&] { return opened; },
      "opening fade completion callback arrives")) return EXIT_FAILURE;
  Check(opened && !effect.active() && Cloak(window) == 0,
      "fast opening completes independently of slow dismissal");

  for (auto style : {DismissStyle::kTray, DismissStyle::kDoor,
                      DismissStyle::kWarp, DismissStyle::kFade, DismissStyle::kFoldRight,
                      DismissStyle::kFoldUp, DismissStyle::kFoldDown}) {
    record_preview = true;
    preview_event_count = 0;
    unsigned preview_callbacks = 0;
    bool preview_success = false;
    bool preview_completed = false;
    const bool preview_started = effect.Start(window, width, height, frame, target, style,
        [&](bool successful) { Check(successful, "motion completed without rendering failure");
          ++preview_callbacks; preview_success = successful; preview_completed = true; effect.Reset();
        }, false, 100, true);
    Check(preview_started, "start non-destructive outgoing preview");
    const auto report_preview = [&](BOOL bounds_ok, const RECT& bounds,
        HRESULT cloak_status, DWORD cloak, bool active) {
      RECT current_client{};
      const BOOL client_ok = GetClientRect(window, &current_client);
      BOOL placement_ok = FALSE;
      const auto current_placement = Placement(window, &placement_ok);
      std::fprintf(stderr, "preview_state style=%d callbacks=%u success=%d completed=%d active=%d stage=%d valid=%d visible=%d iconic=%d cloak_hr=0x%lx cloak=%lu bounds_ok=%d bounds=%ld,%ld,%ld,%ld expected=%ld,%ld,%ld,%ld client_ok=%d client=%ld,%ld placement_ok=%d placement=%u flags=%u events=%u\n",
          static_cast<int>(style), preview_callbacks, preview_success, preview_completed, active,
          effect.failure(), IsWindow(window), IsWindowVisible(window), IsIconic(window),
          static_cast<unsigned long>(cloak_status), cloak, bounds_ok,
          bounds.left, bounds.top, bounds.right, bounds.bottom,
          original.left, original.top, original.right, original.bottom,
          client_ok, current_client.right, current_client.bottom,
          placement_ok, current_placement.showCmd, current_placement.flags, preview_event_count);
      for (unsigned i = 0; i < preview_event_count; ++i)
        std::fprintf(stderr, "preview_event msg=%u wp=%llu lp=%lld\n", preview_events[i].message,
            static_cast<unsigned long long>(preview_events[i].wp),
            static_cast<long long>(preview_events[i].lp));
      std::fflush(stderr);
    };
    if (!preview_started) {
      BOOL bounds_ok = FALSE;
      const RECT bounds = Bounds(window, &bounds_ok);
      HRESULT cloak_status = E_FAIL;
      const DWORD cloak = Cloak(window, &cloak_status);
      report_preview(bounds_ok, bounds, cloak_status, cloak, effect.active());
      effect.Reset(); DestroyWindow(window); return EXIT_FAILURE;
    }
    Pump(130);
    Check(effect.active() && !preview_completed && IsWindowVisible(window) && !IsIconic(window),
        "outgoing preview reverses without hiding or minimizing the source");
    if (!await_completion([&] { return preview_completed; },
        "preview completion callback arrives")) return EXIT_FAILURE;
    BOOL bounds_ok = FALSE;
    const RECT after_preview = Bounds(window, &bounds_ok);
    const bool active = effect.active();
    HRESULT cloak_status = E_FAIL;
    const DWORD cloak = Cloak(window, &cloak_status);
    const bool preview_restored = preview_completed && !active && bounds_ok &&
        SUCCEEDED(cloak_status) && cloak == 0 && EqualRect(&original, &after_preview);
    Check(preview_restored, "preview returns to unchanged live placement");
    Check(preview_callbacks == 1 && preview_success, "preview completes successfully exactly once");
    if (!preview_restored) {
      report_preview(bounds_ok, after_preview, cloak_status, cloak, active);
      effect.Reset(); DestroyWindow(window); return EXIT_FAILURE;
    }
    record_preview = false;
  }
  Check(effect.Start(window, width, height, frame, target, DismissStyle::kFade,
      [](bool) {}, false, 800, true), "start cancellable preview");
  Pump(30);
  effect.Reset();
  Check(IsWindowVisible(window) && !IsIconic(window) && Cloak(window) == 0,
      "cancelled preview never performs a real dismissal");

  wchar_t executable[MAX_PATH]{};
  GetModuleFileNameW(nullptr, executable, MAX_PATH);
  std::wstring command = L"\"" + std::wstring(executable) + L"\" --attention-peer";
  wchar_t desktop_name[256]{};
  DWORD desktop_bytes = 0;
  const bool desktop_ready = GetUserObjectInformationW(GetThreadDesktop(GetCurrentThreadId()), UOI_NAME,
      desktop_name, sizeof(desktop_name), &desktop_bytes) != FALSE;
  Check(desktop_ready, "read synthetic fixture desktop");
  STARTUPINFOW startup{sizeof(startup)};
  startup.lpDesktop = desktop_name;
  PROCESS_INFORMATION process{};
  Check(desktop_ready && CreateProcessW(nullptr, command.data(), nullptr, nullptr, FALSE,
      CREATE_NO_WINDOW, nullptr, nullptr, &startup, &process), "start synthetic foreign window");
  if (process.hProcess) {
    HWND peer = nullptr;
    const auto peer_deadline = GetTickCount64() + 2000;
    do {
      peer = FindWindowW(L"DoorlightAttentionPeer", nullptr);
      if (!peer) Pump(5);
    } while (!peer && GetTickCount64() < peer_deadline);
    DWORD peer_pid = 0;
    GetWindowThreadProcessId(peer, &peer_pid);
    Check(peer && peer_pid == process.dwProcessId, "identify owned synthetic foreign process");
    if (peer && peer_pid == process.dwProcessId) {
      SetWindowPos(peer, HWND_TOP, 110, 110, 200, 200, SWP_NOACTIVATE);
      DwmFlush();
      Check(IsOverlappingForeignWindow(window, peer) && IsCoveredByAnotherWindow(window),
          "overlapping foreign window above source is detected");
      Check(!IsOverlappingForeignWindow(window, window), "own windows do not trigger attention");
      SetWindowPos(peer, nullptr, 2000, 2000, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
      DwmFlush();
      Check(!IsOverlappingForeignWindow(window, peer), "non-overlapping activation does not pulse");
      SetWindowPos(peer, HWND_TOP, 110, 110, 200, 200, SWP_NOACTIVATE);
      ShowWindow(peer, SW_HIDE);
      Check(!IsOverlappingForeignWindow(window, peer), "hidden windows do not count as covering");
      ShowWindow(peer, SW_SHOWNOACTIVATE);
      SetWindowPos(window, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
      Check(!IsOverlappingForeignWindow(window, peer), "normal windows cannot cover a pinned source");
      SetWindowPos(window, HWND_NOTOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
      Check(SendMessageW(peer, WM_APP + 1, TRUE, 0) != 0, "peer conceals its own window");
      Check(!IsOverlappingForeignWindow(window, peer), "cloaked windows cannot trigger attention");
      Check(SendMessageW(peer, WM_APP + 1, FALSE, 0) != 0, "peer restores its own window");
      PostMessageW(peer, WM_CLOSE, 0, 0);
    }
    const auto exited = WaitForSingleObject(process.hProcess, 2000);
    Check(exited == WAIT_OBJECT_0, "synthetic attention peer exits");
    if (exited != WAIT_OBJECT_0) TerminateProcess(process.hProcess, 1);
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
  }

  HWND lost_owner = CreateWindowW(wc.lpszClassName, L"Disposable preview source",
      WS_OVERLAPPEDWINDOW | WS_VISIBLE, 100, 100, 400, 300,
      nullptr, nullptr, wc.hInstance, nullptr);
  RECT lost_client{};
  GetClientRect(lost_owner, &lost_client);
  std::vector<uint8_t> lost_frame(static_cast<size_t>(lost_client.right) * lost_client.bottom * 4, 255);
  bool failure_reported = false;
  Check(effect.Start(lost_owner, lost_client.right, lost_client.bottom, lost_frame,
      target, DismissStyle::kFade, [&](bool successful) {
        failure_reported = !successful;
        effect.Reset();
      }, false, 100, true), "start preview whose source will disappear");
  DestroyWindow(lost_owner);
  if (!await_completion([&] { return failure_reported; },
      "lost source failure callback arrives")) return EXIT_FAILURE;
  Check(failure_reported && !effect.active(), "lost source reports failed preview, never success");

  bool minimize_completed = false;
  ShowWindow(window, SW_SHOWMAXIMIZED);
  GetClientRect(window, &client);
  frame.assign(static_cast<size_t>(client.right) * client.bottom * 4, 255);
  Check(effect.Start(window, client.right, client.bottom, frame, target, DismissStyle::kTray, [&](bool successful) { Check(successful, "motion completed without rendering failure");
    ShowWindow(window, SW_MINIMIZE);
    effect.Reset();
    minimize_completed = true;
  }), "animate maximized source without changing its layout");
  if (!await_completion([&] { return minimize_completed; },
      "maximized minimize completion callback arrives")) return EXIT_FAILURE;
  Check(IsIconic(window), "maximized source minimizes");
  ShowWindow(window, SW_RESTORE);
  Check(IsZoomed(window), "minimized maximized source restores maximized");
  bool tray_completed = false;
  Check(effect.Start(window, client.right, client.bottom, frame, target, DismissStyle::kDoor, [&](bool successful) { Check(successful, "motion completed without rendering failure");
    ShowWindow(window, SW_HIDE);
    effect.Reset();
    tray_completed = true;
  }), "close maximized source to tray");
  if (!await_completion([&] { return tray_completed; },
      "maximized tray completion callback arrives")) return EXIT_FAILURE;
  ShowWindow(window, SW_SHOW);
  Check(IsZoomed(window), "tray restore retains maximized state");
  effect.Reset();
  DestroyWindow(window);
  return failures ? EXIT_FAILURE : EXIT_SUCCESS;
}
