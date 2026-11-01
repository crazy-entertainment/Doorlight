#pragma once

#include <algorithm>
#include <map>
#include <set>
#include <string>
#include <vector>

namespace sybl::reaction {
inline constexpr size_t kMaxEntries = 512;
inline bool Identity(const std::string& value) {
  return value.size() == 40 && std::all_of(value.begin(), value.end(), [](char c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
  });
}
inline bool Supported(const std::string& value) {
  return value == "\xf0\x9f\x91\x8d" || value == "\xe2\x9d\xa4\xef\xb8\x8f" ||
         value == "\xf0\x9f\x98\x82" || value == "\xf0\x9f\x98\xae" ||
         value == "\xf0\x9f\x98\xa2" || value == "\xf0\x9f\x99\x8f";
}
struct Entry {
  std::string commit_id, author_id, emoji;
};
struct Projection {
  bool complete = true;
  std::vector<Entry> entries;
};

// Input is Jami's authenticated folded history, never fields in a text body.
template <class NormalizeAuthor, class AcceptsAuthor>
Projection Project(const std::string& message_id,
                   const std::vector<std::map<std::string, std::string>>& raw,
                   NormalizeAuthor normalize, AcceptsAuthor accepts) {
  Projection result;
  result.complete = raw.size() <= kMaxEntries;
  std::map<std::string, Entry> entries;
  std::set<std::string> ambiguous;
  for (size_t index = 0; index < std::min(raw.size(), kMaxEntries); ++index) {
    const auto& fields = raw[index];
    const auto body = fields.find("body");
    if (body == fields.end() || !Supported(body->second)) continue;
    const auto id = fields.find("id");
    const auto author = fields.find("author");
    const auto target = fields.find("react-to");
    if (id == fields.end() || !Identity(id->second) || id->second == message_id ||
        author == fields.end() || author->second.size() > 1024 ||
        target == fields.end() || target->second != message_id) {
      result.complete = false;
      continue;
    }
    const auto canonical = normalize(author->second);
    if (!Identity(canonical) || !accepts(canonical)) {
      result.complete = false;
      continue;
    }
    if (ambiguous.count(id->second)) continue;
    const Entry entry{id->second, canonical, body->second};
    const auto previous = entries.find(entry.commit_id);
    if (previous != entries.end() &&
        (previous->second.author_id != entry.author_id || previous->second.emoji != entry.emoji)) {
      entries.erase(previous);
      ambiguous.insert(entry.commit_id);
      result.complete = false;
    } else {
      entries[entry.commit_id] = entry;
    }
  }
  for (auto& [id, entry] : entries) result.entries.push_back(std::move(entry));
  return result;
}
}  // namespace sybl::reaction
