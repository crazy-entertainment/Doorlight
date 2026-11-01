#pragma once

#include <cstddef>
#include <optional>
#include <string_view>

namespace sybl::timeline {

// These limits are the native mirror of Dart's TimelineWireContract. The
// Flutter boundary counts UTF-16 code units, not UTF-8 bytes.
inline constexpr std::size_t kMaxDaemonIdCodeUnits = 1024;
inline constexpr std::size_t kMaxAuthorIdCodeUnits = 1024;
inline constexpr std::size_t kMaxTextCodeUnits = 64 * 1024;
inline constexpr std::size_t kMaxFileIdCodeUnits = 4096;
inline constexpr std::size_t kMaxDisplayNameCodeUnits = 1024;
inline constexpr std::size_t kMaxHashCodeUnits = 256;

// loadConversation is already paged, but native code still treats daemon
// output as untrusted at the Flutter boundary. This prevents one callback from
// constructing an unbounded JSON value before Dart has a chance to reject it.
inline constexpr std::size_t kMaxTimelineSnapshotItems = 500;
inline constexpr std::size_t kMaxTimelineSnapshotBytes = 8 * 1024 * 1024;

struct Utf8Measure {
  std::size_t utf16_code_units;
  std::size_t utf8_bytes;
};

// Strict UTF-8 validation with the resulting Flutter/Dart UTF-16 length.
// Rejects overlong forms, surrogate code points, truncated sequences, and
// values above U+10FFFF.
std::optional<Utf8Measure> MeasureUtf8(std::string_view value,
                                      std::size_t max_utf16_code_units);

bool IsRequiredUtf8(std::string_view value,
                    std::size_t max_utf16_code_units);
bool IsOptionalUtf8(std::string_view value,
                    std::size_t max_utf16_code_units);

// current_json_bytes includes the opening '[' and previously appended commas.
// item_json_bytes is the exact encoded item length before the next comma.
bool CanAppendTimelineSnapshotItem(std::size_t current_item_count,
                                   std::size_t current_json_bytes,
                                   std::size_t item_json_bytes);

}  // namespace sybl::timeline
