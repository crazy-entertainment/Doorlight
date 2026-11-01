#pragma once

#include <cstddef>
#include <string>

namespace sybl::remote {

// Produces a UTF-8, scalar-boundary-safe consent preview. C0/C1 controls and
// Unicode direction/invisibility format characters are rendered as visible
// \u{...} escapes so preview text cannot visually spoof the clipboard bytes
// whose digest is being approved.
std::string SafeClipboardPreview(const std::string& utf8,
                                 std::size_t max_scalars = 160);

}  // namespace sybl::remote
