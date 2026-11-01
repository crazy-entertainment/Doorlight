#pragma once

#include <windows.h>
#include <appmodel.h>
#include <optional>

namespace sybl::companion {
inline constexpr wchar_t kWidgetFamily[] = L"DoorlightOverlayProto_ygmhnd3vvdymm";
inline constexpr wchar_t kGameBarFamily[] = L"Microsoft.XboxGamingOverlay_8wekyb3d8bbwe";

// A failed package query is unknown, never evidence that a package is missing.
inline std::optional<bool> Installed(
    const wchar_t* family,
    decltype(&GetPackagesByPackageFamily) query = &GetPackagesByPackageFamily) {
  UINT32 count = 0, length = 0;
  const auto error = query(family, &count, nullptr, &length, nullptr);
  if (error == ERROR_SUCCESS) return count != 0;
  if (error == ERROR_INSUFFICIENT_BUFFER && count != 0) return true;
  return std::nullopt;
}
}  // namespace sybl::companion
