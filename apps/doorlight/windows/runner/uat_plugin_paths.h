#pragma once
#include "uat_profile.h"

#ifdef SYBL_VISUAL_UAT
namespace sybl::uat {
inline HRESULT PluginKnownFolderPath(REFKNOWNFOLDERID folder, DWORD flags, HANDLE token, PWSTR* output) {
  if (!InitializeProfile()) return E_ACCESSDENIED;
  return KnownFolderPath(folder, flags, token, output);
}
}  // namespace sybl::uat
// Scope the unmodified camera plugin's native folder requests in UAT builds only.
#define SHGetKnownFolderPath sybl::uat::PluginKnownFolderPath
#endif
