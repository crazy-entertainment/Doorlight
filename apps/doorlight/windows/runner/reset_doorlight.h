#pragma once
#include <algorithm>
#include <string>
#include <vector>

namespace sybl::reset {
// The exact persisted consent owns both the initial attempt and its retry.
// Retirement must acknowledge media stop and disable the account before removal.
template<class Retire, class Remove, class Removed>
bool LocalAccount(const std::string& expected, const std::string& marker,
                  const std::string& selected, const std::vector<std::string>& accounts,
                  Retire retire, Remove remove, Removed removed) {
  if (expected.empty() || expected.size() > 128 ||
      expected.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-") != std::string::npos ||
      marker != expected || (!selected.empty() && selected != expected) ||
      std::any_of(accounts.begin(), accounts.end(), [&](const auto& id) { return id != expected; })) return false;
  if (!retire()) return false;
  if (std::find(accounts.begin(), accounts.end(), expected) != accounts.end()) remove(expected);
  return removed(expected);
}
}
