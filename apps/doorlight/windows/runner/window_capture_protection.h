#pragma once

#include <windows.h>

enum class WindowCaptureProtection {
  kNone,
  kExclude,
  kMonitor,
  kUnavailable,
};

WindowCaptureProtection CaptureProtectionFromResults(bool exclude_applied,
                                                     bool monitor_applied,
                                                     DWORD windows_build);
// Map a raw GetWindowDisplayAffinity value to the honest applied state.
// Unknown affinity values are reported as kUnavailable — never as protected.
WindowCaptureProtection CaptureProtectionFromAffinity(DWORD affinity,
                                                      DWORD windows_build);
// Pure reducer for post-operation queries. A failed query is unavailable,
// regardless of whether the preceding SetWindowDisplayAffinity call claimed
// success; requested state is never substituted for observed state.
WindowCaptureProtection CaptureProtectionAfterQuery(bool query_succeeded,
                                                     DWORD affinity,
                                                     DWORD windows_build);
// Read the actual current affinity of `window`. A failed query returns
// `query_failure` so a caller can keep previously confirmed truth instead of
// substituting an optimistic guess.
WindowCaptureProtection QueryWindowCaptureProtection(
    HWND window, WindowCaptureProtection query_failure);
// Apply the desired protection and return the ACTUAL post-operation state:
// protect=true tries WDA_EXCLUDEFROMCAPTURE then WDA_MONITOR; protect=false
// applies WDA_NONE. The result is confirmed by re-querying the window where
// possible. A failed post-query is unavailable, even if the set call returned
// success.
WindowCaptureProtection ApplyWindowCaptureProtection(HWND window, bool protect);
const char* WindowCaptureProtectionName(WindowCaptureProtection protection);
