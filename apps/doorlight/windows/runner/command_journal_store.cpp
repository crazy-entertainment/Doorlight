#include "command_journal_store.h"
#include "verified_received_seed.h"
#include "win32_dpapi.h"
#include <bcrypt.h>
#include <array>

namespace sybl::journal {
namespace {
constexpr size_t kMaxClear = 1024 * 1024;
constexpr size_t kMaxSealed = 2 * 1024 * 1024;

ReadResult ReadUnlocked(const std::filesystem::path& path) {
  std::error_code error;
  const auto status = std::filesystem::symlink_status(path, error);
  if (status.type() == std::filesystem::file_type::not_found &&
      (!error || error == std::errc::no_such_file_or_directory)) return {true, std::nullopt};
  if (error) return {};
  jami::received_seed::File file(path, false);
  if (!file.valid() || file.size() == 0 || file.size() > kMaxSealed) return {};
  std::string sealed(size_t(file.size()), '\0');
  size_t offset = 0;
  while (offset < sealed.size()) {
    const int count = file.read(reinterpret_cast<unsigned char*>(sealed.data() + offset),
                                unsigned(sealed.size() - offset));
    if (count <= 0) return {};
    offset += size_t(count);
  }
  sybl::win32::Win32DpapiProtector protector("composer-command-journal-v1");
  auto clear = protector.Unprotect(sealed);
  if (!clear || clear->empty() || clear->size() > kMaxClear) return {};
  return {true, std::move(clear)};
}

std::optional<std::filesystem::path> Temporary(const std::filesystem::path& path) {
  std::array<unsigned char, 16> random {};
  if (BCryptGenRandom(nullptr, random.data(), ULONG(random.size()),
                     BCRYPT_USE_SYSTEM_PREFERRED_RNG) < 0) return std::nullopt;
  constexpr char hex[] = "0123456789abcdef";
  std::string suffix;
  for (auto byte : random) { suffix += hex[byte >> 4]; suffix += hex[byte & 15]; }
  return path.parent_path() / (".command-journal-" + suffix);
}
}  // namespace

ReadResult Load(const std::filesystem::path& path) {
  try {
    // A writable held lock file denies any second writer/open, including from
    // another process. Parent traversal and the leaf are no-follow checked.
    jami::received_seed::File lock(path.wstring() + L".lock", jami::received_seed::File::Mode::append);
    return lock.valid() ? ReadUnlocked(path) : ReadResult{};
  } catch (...) { return {}; }
}

bool Save(const std::filesystem::path& path, const std::string& source) {
  try {
    if (source.empty() || source.size() > kMaxClear) return false;
    jami::received_seed::File lock(path.wstring() + L".lock", jami::received_seed::File::Mode::append);
    if (!lock.valid() || !ReadUnlocked(path).healthy) return false;
    sybl::win32::Win32DpapiProtector protector("composer-command-journal-v1");
    const auto sealed = protector.Protect(source);
    const auto temporary = Temporary(path);
    if (!sealed || sealed->size() > kMaxSealed || !temporary) return false;
    jami::received_seed::File output(*temporary, true);
    if (!output.valid()) return false;
    const bool saved = output.write(reinterpret_cast<const unsigned char*>(sealed->data()), unsigned(sealed->size())) &&
                       output.publishTo(path, true);
    if (!saved) output.removeOwned();
    output.close();
    if (!saved) return false;
    const auto verified = ReadUnlocked(path);
    return verified.healthy && verified.source == source;
  } catch (...) { return false; }
}
}  // namespace sybl::journal
