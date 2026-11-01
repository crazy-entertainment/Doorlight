#ifdef NDEBUG
#undef NDEBUG
#endif

#include "window_capture_protection.h"

#include <cassert>
#include <string>

#ifndef WDA_EXCLUDEFROMCAPTURE
#define WDA_EXCLUDEFROMCAPTURE 0x00000011
#endif

int main() {
  assert(CaptureProtectionFromResults(true, false, 19041) ==
         WindowCaptureProtection::kExclude);
  assert(CaptureProtectionFromResults(true, true, 22621) ==
         WindowCaptureProtection::kExclude);
  assert(CaptureProtectionFromResults(true, false, 18363) ==
         WindowCaptureProtection::kMonitor);
  assert(CaptureProtectionFromResults(true, false, 0) ==
         WindowCaptureProtection::kMonitor);
  assert(CaptureProtectionFromResults(false, true, 22621) ==
         WindowCaptureProtection::kMonitor);
  assert(CaptureProtectionFromResults(false, false, 22621) ==
         WindowCaptureProtection::kUnavailable);

  // Raw affinity mapping: WDA_NONE is the intentional visible state, 0x11
  // keeps its documented pre-2004 monitor semantics, and an unknown value is
  // never reported as protected.
  assert(CaptureProtectionFromAffinity(WDA_NONE, 22621) ==
         WindowCaptureProtection::kNone);
  assert(CaptureProtectionFromAffinity(WDA_EXCLUDEFROMCAPTURE, 22621) ==
         WindowCaptureProtection::kExclude);
  assert(CaptureProtectionFromAffinity(WDA_EXCLUDEFROMCAPTURE, 18363) ==
         WindowCaptureProtection::kMonitor);
  assert(CaptureProtectionFromAffinity(WDA_EXCLUDEFROMCAPTURE, 0) ==
         WindowCaptureProtection::kMonitor);
  assert(CaptureProtectionFromAffinity(WDA_MONITOR, 22621) ==
         WindowCaptureProtection::kMonitor);
  assert(CaptureProtectionFromAffinity(0xdead, 22621) ==
         WindowCaptureProtection::kUnavailable);
  assert(CaptureProtectionAfterQuery(true, WDA_MONITOR, 22621) ==
         WindowCaptureProtection::kMonitor);
  assert(CaptureProtectionAfterQuery(false, WDA_EXCLUDEFROMCAPTURE, 22621) ==
         WindowCaptureProtection::kUnavailable);

  // A null/invalid window cannot report a protected state, and a failed query
  // returns the caller-provided fallback instead of inventing truth.
  assert(ApplyWindowCaptureProtection(nullptr, true) ==
         WindowCaptureProtection::kUnavailable);
  assert(ApplyWindowCaptureProtection(nullptr, false) ==
         WindowCaptureProtection::kUnavailable);
  assert(QueryWindowCaptureProtection(nullptr,
                                      WindowCaptureProtection::kMonitor) ==
         WindowCaptureProtection::kMonitor);

  // Live Win32 round trip on a real top-level window owned by this process:
  // none -> protect (exclude or monitor per OS) -> none.
  const HWND window = CreateWindowExW(0, L"STATIC", L"sybl capture test",
                                      WS_OVERLAPPED, 0, 0, 32, 32, nullptr,
                                      nullptr, GetModuleHandleW(nullptr),
                                      nullptr);
  assert(window != nullptr);
  assert(QueryWindowCaptureProtection(
             window, WindowCaptureProtection::kUnavailable) ==
         WindowCaptureProtection::kNone);
  const auto protectedState = ApplyWindowCaptureProtection(window, true);
  assert(protectedState == WindowCaptureProtection::kExclude ||
         protectedState == WindowCaptureProtection::kMonitor);
  assert(QueryWindowCaptureProtection(
             window, WindowCaptureProtection::kUnavailable) == protectedState);
  assert(ApplyWindowCaptureProtection(window, false) ==
         WindowCaptureProtection::kNone);
  assert(QueryWindowCaptureProtection(
             window, WindowCaptureProtection::kUnavailable) ==
         WindowCaptureProtection::kNone);
  DestroyWindow(window);

  assert(std::string(WindowCaptureProtectionName(
             WindowCaptureProtection::kNone)) == "none");
  assert(std::string(WindowCaptureProtectionName(
             WindowCaptureProtection::kExclude)) == "exclude");
  assert(std::string(WindowCaptureProtectionName(
             WindowCaptureProtection::kMonitor)) == "monitor");
  assert(std::string(WindowCaptureProtectionName(
             WindowCaptureProtection::kUnavailable)) == "unavailable");
}
