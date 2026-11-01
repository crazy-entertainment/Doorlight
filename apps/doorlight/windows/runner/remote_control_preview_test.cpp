#ifdef NDEBUG
#undef NDEBUG
#endif

#include "remote_control_preview.h"

#include <cassert>
#include <string>

using sybl::remote::SafeClipboardPreview;

int main() {
  assert(SafeClipboardPreview("ordinary text") == "ordinary text");
  assert(SafeClipboardPreview("a\nb\tc\x7f") ==
         "a\\u{000A}b\\u{0009}c\\u{007F}");
  assert(SafeClipboardPreview(
             std::string("left") + "\xE2\x80\xAE" + "right") ==
         "left\\u{202E}right");
  assert(SafeClipboardPreview(
             std::string("a") + "\xC2\xAD" + "\xE2\x81\xA6" + "b") ==
         "a\\u{00AD}\\u{2066}b");
  assert(SafeClipboardPreview(
             std::string("x") + "\xEF\xB8\x8F" + "y") ==
         "x\\u{FE0F}y");

  const std::string emoji = "\xF0\x9F\x98\x80";
  assert(SafeClipboardPreview(std::string(159, 'x') + emoji + "z") ==
         std::string(159, 'x') + emoji + "...");
  assert(SafeClipboardPreview(emoji + emoji, 1) == emoji + "...");
  assert(SafeClipboardPreview("\xF0\x9F\x98") == "[invalid text]");
  assert(SafeClipboardPreview(std::string(160, 'x') + "\xF0\x9F\x98") ==
         "[invalid text]");
  assert(SafeClipboardPreview("\xED\xA0\x80") == "[invalid text]");
  assert(SafeClipboardPreview("", 0).empty());
  assert(SafeClipboardPreview("x", 0) == "...");
  return 0;
}
