#ifdef NDEBUG
#undef NDEBUG
#endif

#include "archive_secret_store.h"

#define NOMINMAX
#include <windows.h>

#include <cassert>
#include <filesystem>
#include <fstream>
#include <string>

namespace {

std::filesystem::path TestDirectory() {
  wchar_t temporary[MAX_PATH]{};
  const DWORD length =
      GetTempPathW(static_cast<DWORD>(std::size(temporary)), temporary);
  assert(length > 0 && length < std::size(temporary));
  const auto directory =
      std::filesystem::path(temporary) /
      (L"sybl-archive-secret-test-" + std::to_wstring(GetCurrentProcessId()) +
       L"-" + std::to_wstring(GetTickCount64()));
  assert(CreateDirectoryW(directory.c_str(), nullptr));
  return directory;
}

void CreatesThenLoadsTheSameDeviceSecret() {
  const auto directory = TestDirectory();
  const auto path = directory / L"secret.dpapi";
  {
    sybl::archive::ArchiveSecretStore first_store(path);
    auto first = first_store.LoadOrCreate();
    assert(first && first->created);
    assert(sybl::archive::IsValidArchiveSecret(first->secret));

    sybl::archive::ArchiveSecretStore second_store(path);
    auto second = second_store.LoadOrCreate();
    assert(second && !second->created);
    assert(second->secret == first->secret);

    std::ifstream encrypted(path, std::ios::binary);
    const std::string sealed((std::istreambuf_iterator<char>(encrypted)),
                             std::istreambuf_iterator<char>());
    assert(!sealed.empty());
    assert(sealed.find(first->secret) == std::string::npos);
  }

  std::error_code error;
  std::filesystem::remove_all(directory, error);
  assert(!error);
}

void PresentCorruptionFailsClosedWithoutReplacement() {
  const auto directory = TestDirectory();
  const auto path = directory / L"secret.dpapi";
  {
    std::ofstream corrupt(path, std::ios::binary);
    corrupt << "not a DPAPI record";
  }
  const auto original_size = std::filesystem::file_size(path);
  {
    sybl::archive::ArchiveSecretStore store(path);
    assert(!store.LoadOrCreate());
    assert(std::filesystem::file_size(path) == original_size);
  }

  std::error_code error;
  std::filesystem::remove_all(directory, error);
  assert(!error);
}

void RejectsInvalidPlaintextShapes() {
  assert(!sybl::archive::IsValidArchiveSecret(""));
  assert(!sybl::archive::IsValidArchiveSecret(std::string(63, 'a')));
  assert(!sybl::archive::IsValidArchiveSecret(std::string(65, 'a')));
  assert(!sybl::archive::IsValidArchiveSecret(std::string(64, 'A')));
  assert(sybl::archive::IsValidArchiveSecret(std::string(64, 'f')));
}

}  // namespace

int main() {
  CreatesThenLoadsTheSameDeviceSecret();
  PresentCorruptionFailsClosedWithoutReplacement();
  RejectsInvalidPlaintextShapes();
}
