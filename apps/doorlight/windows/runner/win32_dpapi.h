#pragma once

#include <optional>
#include <string>

namespace sybl::win32 {

// Current-user DPAPI protection with mandatory purpose separation. Callers
// must use a stable, versioned purpose unique to the data class; ciphertext
// protected for one purpose cannot be opened by another.
class Win32DpapiProtector {
 public:
  explicit Win32DpapiProtector(std::string purpose);

  std::optional<std::string> Protect(const std::string& clear) const;
  std::optional<std::string> Unprotect(const std::string& sealed) const;

 private:
  std::string entropy_;
};

}  // namespace sybl::win32
