#ifdef NDEBUG
#undef NDEBUG
#endif

#include "group_policy.h"

#include <cassert>

int main() {
  constexpr auto me = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
  constexpr auto alice = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
  constexpr auto bob = "cccccccccccccccccccccccccccccccccccccccc";

  assert(sybl::group::NormalizeTitle("  The Crew  ") ==
         std::optional<std::string>("The Crew"));
  assert(!sybl::group::NormalizeTitle(""));
  assert(!sybl::group::NormalizeTitle("bad\nname"));
  assert(!sybl::group::NormalizeTitle(std::string(129, 'x')));
  assert(sybl::group::NormalizeLayout(
             "sybl-group-layout:v1:eyJjIjpbXSwiciI6W119") ==
         std::optional<std::string>(
             "sybl-group-layout:v1:eyJjIjpbXSwiciI6W119"));
  assert(!sybl::group::NormalizeLayout("plain description"));
  assert(!sybl::group::NormalizeLayout("sybl-group-layout:v1:bad+base64"));

  const std::set<std::string> trusted{alice, bob};
  const auto members =
      sybl::group::NewMemberIds({bob, alice}, me, trusted);
  assert(members == std::optional<std::vector<std::string>>({alice, bob}));
  assert(!sybl::group::NewMemberIds({alice, alice}, me, trusted));
  assert(!sybl::group::NewMemberIds({me}, me, trusted));
  assert(!sybl::group::NewMemberIds({bob}, me, {alice}));
  assert(!sybl::group::NewMemberIds({bob}, me, trusted, {bob}));
}
