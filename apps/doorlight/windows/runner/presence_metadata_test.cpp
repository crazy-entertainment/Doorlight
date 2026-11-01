#ifdef NDEBUG
#undef NDEBUG
#endif

#include "presence_metadata.h"

#include <cassert>
#include <string>

int main() {
  using sybl::presence_metadata::SanitizeActivity;
  using sybl::presence_metadata::kMaxActivityUtf8Bytes;

  assert(SanitizeActivity("  Team Fortress 2  ") == "Team Fortress 2");
  assert(SanitizeActivity("chat \"private title\"") ==
         "chat private title");
  assert(SanitizeActivity("one\\two\tthree") == "one two three");
  assert(SanitizeActivity(std::string("\xc3\x28", 2)).empty());

  const std::string emoji = "\xf0\x9f\x8e\xae";
  const auto bounded = SanitizeActivity(std::string(95, 'a') + emoji);
  assert(bounded.size() == 95);
  assert(bounded.size() <= kMaxActivityUtf8Bytes);
  return 0;
}
