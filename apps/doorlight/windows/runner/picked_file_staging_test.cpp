#ifdef NDEBUG
#undef NDEBUG
#endif

#include "picked_file_staging.h"

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <cassert>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <string>

namespace {

std::filesystem::path UniqueRoot() {
  wchar_t temporary[MAX_PATH]{};
  assert(GetTempPathW(MAX_PATH, temporary) > 0);
  return std::filesystem::path(temporary) /
         (L"sybl-picked-file-staging-" +
          std::to_wstring(GetCurrentProcessId()));
}

void Write(const std::filesystem::path& path, const std::string& bytes) {
  std::ofstream stream(path, std::ios::binary | std::ios::trunc);
  stream.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
  stream.close();
  assert(stream.good());
}

std::string Read(const std::filesystem::path& path) {
  std::ifstream stream(path, std::ios::binary);
  return {std::istreambuf_iterator<char>(stream),
          std::istreambuf_iterator<char>()};
}

std::size_t ChildCount(const std::filesystem::path& path) {
  return static_cast<std::size_t>(
      std::distance(std::filesystem::directory_iterator(path),
                    std::filesystem::directory_iterator()));
}

}  // namespace

int main() {
  using namespace sybl::picked_file;

  assert(!IsAllowedMaxBytes(0));
  assert(IsAllowedMaxBytes(1));
  assert(IsAllowedMaxBytes(kMaxPickedFileBytes));
  assert(!IsAllowedMaxBytes(kMaxPickedFileBytes + 1));

  const auto root = UniqueRoot();
  const auto staging = root / L"staging";
  const auto outside = root / L"outside";
  std::filesystem::remove_all(root);
  std::filesystem::create_directories(staging);
  std::filesystem::create_directories(outside);

  const auto source = outside / L"source.bin";
  Write(source, "safe");
  const auto first = Stage(source, staging, 4);
  assert(first);
  assert(sybl::picked_file::IsOwned(*first, staging));
  assert(!sybl::picked_file::IsOwned(source, staging));
  assert(first->parent_path().parent_path() == staging);
  assert(first->filename() == source.filename());
  assert(*first != source);
  assert(Read(*first) == "safe");

  // The returned path is a stable snapshot, not the mutable selected path.
  Write(source, "changed");
  assert(Read(*first) == "safe");
  const auto second = Stage(source, staging, 7);
  assert(second && *second != *first);
  assert(second->parent_path() != first->parent_path());
  assert(second->filename() == source.filename());
  assert(Read(*second) == "changed");

  const auto children_before_rejection = ChildCount(staging);
  assert(!Stage(source, staging, 6));
  assert(ChildCount(staging) == children_before_rejection);
  assert(!Stage(outside, staging, 1024));

  const auto recording = sybl::picked_file::ReserveRecordingOutput(staging);
  const auto other_recording = sybl::picked_file::ReserveRecordingOutput(staging);
  assert(recording && other_recording && *recording != *other_recording);
  assert(recording->filename() == L"voice.m4a");
  assert(sybl::picked_file::IsOwned(*recording, staging));
  assert(Read(*recording).empty());
  assert(!sybl::picked_file::ReserveRecordingOutput(L"relative"));
  assert(Discard(*recording, staging));
  assert(Discard(*other_recording, staging));
  const auto gif = sybl::picked_file::ReserveReceivedMediaOutput(staging, true, false);
  assert(gif && gif->filename() == L"media.gif");
  assert(!std::filesystem::exists(*gif));
  assert(std::filesystem::is_directory(gif->parent_path()));
  Write(*gif, "received");
  assert(sybl::picked_file::IsOwned(*gif, staging));
  assert(Discard(*gif, staging));

  const auto source_link = outside / L"source-link.bin";
  if (CreateSymbolicLinkW(source_link.c_str(), source.c_str(),
                          SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE)) {
    assert(!Stage(source_link, staging, 1024));
    assert(DeleteFileW(source_link.c_str()));
  }
  const auto staging_alias = root / L"staging-alias";
  if (CreateSymbolicLinkW(
          staging_alias.c_str(), staging.c_str(),
          SYMBOLIC_LINK_FLAG_DIRECTORY |
              SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE)) {
    assert(!Stage(source, staging_alias, 1024));
    assert(RemoveDirectoryW(staging_alias.c_str()));
  }

  // An attacker-controlled path or reparse child can never make discard touch
  // the selected original (or anything outside the validated staging root).
  const auto staged_name =
      std::filesystem::path(L"picked-00000000000000000000000000000000");
  const auto external_parent = outside / staged_name;
  std::filesystem::create_directory(external_parent);
  const auto external_lookalike = external_parent / source.filename();
  Write(external_lookalike, "original");
  assert(!Discard(external_lookalike, staging));
  assert(!sybl::picked_file::IsOwned(external_lookalike, staging));
  assert(Read(external_lookalike) == "original");
  const auto staged_parent = staging / staged_name;
  const auto staged_directory = staged_parent / source.filename();
  std::filesystem::create_directory(staged_parent);
  std::filesystem::create_directory(staged_directory);
  assert(!Discard(staged_directory, staging));
  std::filesystem::remove_all(staged_parent);

  const auto staged_link_parent =
      staging / L"picked-11111111111111111111111111111111";
  const auto staged_link = staged_link_parent / source.filename();
  std::filesystem::create_directory(staged_link_parent);
  if (CreateSymbolicLinkW(staged_link.c_str(), source.c_str(),
                          SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE)) {
    assert(!Discard(staged_link, staging));
    assert(!sybl::picked_file::IsOwned(staged_link, staging));
    assert(std::filesystem::exists(source));
    assert(DeleteFileW(staged_link.c_str()));
  }
  std::filesystem::remove(staged_link_parent);

  assert(!Discard(source, staging));
  assert(std::filesystem::exists(source));
  assert(Discard(*first, staging));
  assert(!std::filesystem::exists(*first));
  assert(!std::filesystem::exists(first->parent_path()));
  assert(Discard(*second, staging));
  assert(!std::filesystem::exists(*second));
  assert(!std::filesystem::exists(second->parent_path()));
  assert(std::filesystem::exists(source));

  std::filesystem::remove_all(root);
}
