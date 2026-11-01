#pragma once

#include <cstdint>
#include <filesystem>
#include <optional>

namespace sybl::picked_file {

inline constexpr std::int64_t kMaxPickedFileBytes =
    2LL * 1024 * 1024 * 1024;

constexpr bool IsAllowedMaxBytes(std::int64_t value) {
  return value >= 1 && value <= kMaxPickedFileBytes;
}

// Per-user app-owned staging kept outside Syb-L's private identity root so a
// staged backup remains an allowed archive import source.
std::optional<std::filesystem::path> DefaultStagingRoot();

// Reserves an empty, private M4A output. The recorder receives only this native
// generated path; it cannot select an arbitrary output supplied by Dart.
std::optional<std::filesystem::path> ReserveRecordingOutput(
    const std::filesystem::path& staging_root);

std::optional<std::filesystem::path> ReserveReceivedMediaOutput(
    const std::filesystem::path& staging_root, bool gif, bool create_placeholder = true);

// Opens the selected file once, rejects non-regular/reparse/oversized inputs,
// and copies that same locked handle into a unique stable staging directory.
// The file keeps its selected leaf name so outgoing transfers retain the
// user-visible name without trusting the original path again.
std::optional<std::filesystem::path> Stage(
    const std::filesystem::path& selected,
    const std::filesystem::path& staging_root, std::int64_t max_bytes);

// Deletes only a regular, non-reparse file below a generated directory that is
// itself a direct, validated child of the staging root.
bool Discard(const std::filesystem::path& candidate,
             const std::filesystem::path& staging_root);

// Checks the same owned-directory, regular-file and reparse boundaries without
// deleting anything. Publication retains the source until seed acknowledgement.
bool IsOwned(const std::filesystem::path& candidate,
             const std::filesystem::path& staging_root);

}  // namespace sybl::picked_file
