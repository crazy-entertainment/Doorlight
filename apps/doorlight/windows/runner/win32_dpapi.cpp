#include "win32_dpapi.h"

#define NOMINMAX
#include <windows.h>
#include <wincrypt.h>

#include <limits>

namespace sybl::win32 {
namespace {

constexpr std::size_t kMaxPurposeBytes = 256;

DATA_BLOB Blob(const std::string& bytes) {
  DATA_BLOB blob{};
  blob.cbData = static_cast<DWORD>(bytes.size());
  blob.pbData = reinterpret_cast<BYTE*>(
      const_cast<char*>(bytes.data()));
  return blob;
}

}  // namespace

Win32DpapiProtector::Win32DpapiProtector(std::string purpose) {
  if (!purpose.empty() && purpose.size() <= kMaxPurposeBytes)
    entropy_ = "Syb-L DPAPI purpose: " + purpose;
}

std::optional<std::string> Win32DpapiProtector::Protect(
    const std::string& clear) const {
  if (entropy_.empty() || clear.empty() ||
      clear.size() > std::numeric_limits<DWORD>::max()) {
    return std::nullopt;
  }
  auto input = Blob(clear);
  auto entropy = Blob(entropy_);
  DATA_BLOB output{};
  if (!CryptProtectData(&input, L"Syb-L protected data", &entropy,
                        nullptr, nullptr, CRYPTPROTECT_UI_FORBIDDEN,
                        &output)) {
    return std::nullopt;
  }
  std::string result(reinterpret_cast<char*>(output.pbData), output.cbData);
  SecureZeroMemory(output.pbData, output.cbData);
  LocalFree(output.pbData);
  return result;
}

std::optional<std::string> Win32DpapiProtector::Unprotect(
    const std::string& sealed) const {
  if (entropy_.empty() || sealed.empty() ||
      sealed.size() > std::numeric_limits<DWORD>::max()) {
    return std::nullopt;
  }
  auto input = Blob(sealed);
  auto entropy = Blob(entropy_);
  DATA_BLOB output{};
  if (!CryptUnprotectData(&input, nullptr, &entropy, nullptr, nullptr,
                          CRYPTPROTECT_UI_FORBIDDEN, &output)) {
    return std::nullopt;
  }
  std::string result(reinterpret_cast<char*>(output.pbData), output.cbData);
  SecureZeroMemory(output.pbData, output.cbData);
  LocalFree(output.pbData);
  return result;
}

}  // namespace sybl::win32
