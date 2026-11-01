#include "window_capture_protection.h"

#ifndef WDA_EXCLUDEFROMCAPTURE
#define WDA_EXCLUDEFROMCAPTURE 0x00000011
#endif

namespace {

DWORD WindowsBuildNumber() {
  DWORD build = 0;
  if (const auto ntdll = GetModuleHandleW(L"ntdll.dll")) {
    using RtlGetVersionFn = LONG(WINAPI*)(OSVERSIONINFOW*);
    const auto get_version = reinterpret_cast<RtlGetVersionFn>(
        GetProcAddress(ntdll, "RtlGetVersion"));
    OSVERSIONINFOW version{};
    version.dwOSVersionInfoSize = sizeof(version);
    if (get_version && get_version(&version) == 0)
      build = version.dwBuildNumber;
  }
  return build;
}

}  // namespace

WindowCaptureProtection CaptureProtectionFromResults(bool exclude_applied,
                                                     bool monitor_applied,
                                                     DWORD windows_build) {
  if (exclude_applied && windows_build >= 19041)
    return WindowCaptureProtection::kExclude;
  // Before Windows 10 2004, 0x11 is accepted with WDA_MONITOR semantics.
  // Unknown build is reported conservatively as the weaker applied mode.
  if (exclude_applied) return WindowCaptureProtection::kMonitor;
  if (monitor_applied) return WindowCaptureProtection::kMonitor;
  return WindowCaptureProtection::kUnavailable;
}

WindowCaptureProtection CaptureProtectionFromAffinity(DWORD affinity,
                                                      DWORD windows_build) {
  if (affinity == WDA_NONE) return WindowCaptureProtection::kNone;
  if (affinity == WDA_EXCLUDEFROMCAPTURE)
    return CaptureProtectionFromResults(true, false, windows_build);
  if (affinity == WDA_MONITOR) return WindowCaptureProtection::kMonitor;
  return WindowCaptureProtection::kUnavailable;
}

WindowCaptureProtection CaptureProtectionAfterQuery(bool query_succeeded,
                                                     DWORD affinity,
                                                     DWORD windows_build) {
  if (!query_succeeded) return WindowCaptureProtection::kUnavailable;
  return CaptureProtectionFromAffinity(affinity, windows_build);
}

WindowCaptureProtection QueryWindowCaptureProtection(
    HWND window, WindowCaptureProtection query_failure) {
  if (!window) return query_failure;
  DWORD affinity = 0;
  const bool queried = GetWindowDisplayAffinity(window, &affinity) != FALSE;
  if (!queried) return query_failure;
  return CaptureProtectionAfterQuery(true, affinity, WindowsBuildNumber());
}

WindowCaptureProtection ApplyWindowCaptureProtection(HWND window,
                                                     bool protect) {
  if (!window) return WindowCaptureProtection::kUnavailable;
  if (protect) {
    const bool exclude =
        SetWindowDisplayAffinity(window, WDA_EXCLUDEFROMCAPTURE) != FALSE;
    if (!exclude) {
      SetWindowDisplayAffinity(window, WDA_MONITOR);
    }
  } else {
    SetWindowDisplayAffinity(window, WDA_NONE);
  }
  // The set-call result is not state. Only the post-query can establish what
  // the compositor actually applied.
  return QueryWindowCaptureProtection(
      window, WindowCaptureProtection::kUnavailable);
}

const char* WindowCaptureProtectionName(
    WindowCaptureProtection protection) {
  switch (protection) {
    case WindowCaptureProtection::kNone:
      return "none";
    case WindowCaptureProtection::kExclude:
      return "exclude";
    case WindowCaptureProtection::kMonitor:
      return "monitor";
    case WindowCaptureProtection::kUnavailable:
      return "unavailable";
  }
  return "unavailable";
}
