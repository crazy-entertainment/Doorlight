#pragma once

#include <cstdint>

namespace sybl::remote {

// Marks input this process injected, so raw input can tell our own SendInput
// events apart from the local user's hardware and not mistake them for a
// physical host takeover.
//
// MUST fit in 32 bits. SendInput carries it in dwExtraInfo (ULONG_PTR, 64-bit
// on x64), but raw input reports it back through RAWMOUSE::ulExtraInformation
// and RAWKEYBOARD::ExtraInformation, which are ULONG - 32 bits on every
// architecture. A wider sentinel is silently truncated on the way back, the
// comparison in Win32RawInputMonitor::Classify can then never match, and every
// injected event is misread as physical input: host-priority re-arms its 600 ms
// suppression window on our own injection, remote control collapses to about
// one event per 600 ms, and the banner reports a local takeover that never
// happened. The static_assert below is what keeps that from returning.
constexpr std::uintptr_t kRemoteInputExtraInfo =
    static_cast<std::uintptr_t>(0x5359424cUL);  // "SYBL"

static_assert(kRemoteInputExtraInfo <= 0xffffffffULL,
              "kRemoteInputExtraInfo must survive the 32-bit ULONG round trip "
              "through RAWMOUSE::ulExtraInformation / "
              "RAWKEYBOARD::ExtraInformation, or injected input is "
              "indistinguishable from physical input.");
static_assert(kRemoteInputExtraInfo != 0,
              "Zero is the default dwExtraInfo for ordinary hardware input.");

}  // namespace sybl::remote
