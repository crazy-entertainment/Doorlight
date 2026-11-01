#ifdef NDEBUG
#undef NDEBUG
#endif
#include "reset_doorlight.h"
#include <cassert>

int main() {
  std::string sequence;
  bool retirement = true, removal = true;
  auto reset = [&](const std::string& expected, const std::string& marker,
                   const std::string& selected, const std::vector<std::string>& accounts) {
    return sybl::reset::LocalAccount(expected, marker, selected, accounts,
        [&] { sequence += 'R'; return retirement; },
        [&](const auto& id) { assert(id == "account"); sequence += 'D'; },
        [&](const auto& id) { assert(id == "account"); sequence += 'V'; return removal; });
  };
  assert(!reset("account", "different", "account", {"account"}));
  assert(!reset("account", "account", "different", {"account"}));
  assert(!reset("account", "account", "account", {"account", "other"}));
  assert(!reset("../account", "../account", "", {}));
  assert(sequence.empty());
  retirement = false;
  assert(!reset("account", "account", "account", {"account"}));
  assert(sequence == "R");
  retirement = true; sequence.clear(); removal = false;
  assert(!reset("account", "account", "account", {"account"}));
  assert(sequence == "RDV");
  sequence.clear(); removal = true;
  assert(reset("account", "account", "", {})); // Removed identity, unfinished preferences: exact retry.
  assert(sequence == "RV");
  sequence.clear();
  assert(reset("account", "account", "account", {"account"}));
  assert(sequence == "RDV");
}
