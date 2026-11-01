#pragma once

#include <windows.h>

#include <string>

namespace sybl::remote {

bool IsDeniedForegroundExecutable(const std::wstring& executable_name);
bool OwnerWindowStateAllowsWholeDesktopControl(bool exists,
                                               bool visible,
                                               bool minimized);
bool OwnerWindowAllowsWholeDesktopControl(HWND owner);
bool DeniedSensitiveForeground();

}  // namespace sybl::remote
