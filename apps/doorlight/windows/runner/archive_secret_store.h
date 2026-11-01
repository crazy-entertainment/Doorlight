#pragma once

#include <filesystem>
#include <optional>
#include <string>

namespace sybl::archive {

struct ArchiveSecretResult {
  std::string secret;
  bool created = false;
};

// Persists one 256-bit libjami archive password under current-user DPAPI.
// A present-but-corrupt record fails closed and is never replaced.
class ArchiveSecretStore {
 public:
  explicit ArchiveSecretStore(std::filesystem::path path);

  static std::optional<std::filesystem::path> DefaultPath();
  std::optional<ArchiveSecretResult> LoadOrCreate();

 private:
  std::filesystem::path path_;
};

bool IsValidArchiveSecret(const std::string& value);

}  // namespace sybl::archive
