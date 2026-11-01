#pragma once
#include <filesystem>
#include <optional>
#include <string>

namespace sybl::journal {
struct ReadResult {
  bool healthy = false;
  std::optional<std::string> source;
};
ReadResult Load(const std::filesystem::path& path);
bool Save(const std::filesystem::path& path, const std::string& source);
}  // namespace sybl::journal
