#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>

namespace sybl::presence_metadata {

inline constexpr std::size_t kMaxActivityUtf8Bytes = 96;

// Produces a JSON-safe, bounded friendly application label. Invalid UTF-8 is
// rejected; control characters and JSON delimiters are normalized away.
std::string SanitizeActivity(std::string_view value);

// Returns the foreground executable's ProductName/FileDescription, falling
// back to its filename stem. It never reads a window title. The current Syb-L
// process maps to an empty label because "in Syb-L" is already conveyed by fg.
std::string ForegroundApplicationLabel(std::uint32_t own_process_id);

}  // namespace sybl::presence_metadata
