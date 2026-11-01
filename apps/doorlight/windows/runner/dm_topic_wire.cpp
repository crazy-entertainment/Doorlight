#include "dm_topic_wire.h"

#include <algorithm>

namespace sybl::dm_topic {
namespace {

constexpr std::size_t kMaxIdBytes = 1024;

bool IsCustomTopic(const std::string& value) {
  return value.size() == 32 &&
         std::all_of(value.begin(), value.end(), [](char unit) {
           return (unit >= '0' && unit <= '9') ||
                  (unit >= 'a' && unit <= 'f');
         });
}

bool BoundedId(const std::string& value) {
  return !value.empty() && value.size() <= kMaxIdBytes;
}

std::string Field(const std::map<std::string, std::string>& body,
                  const char* key) {
  const auto found = body.find(key);
  return found == body.end() ? std::string{} : found->second;
}

}  // namespace

ItemTag NormalizeItemTopic(const std::string& value) {
  if (value == kMain || IsCustomTopic(value)) return {value, true};
  return {kMain, false};
}

bool IsValidOutgoingTopic(const std::string& value) {
  return value.empty() || NormalizeItemTopic(value).tagged;
}

std::optional<StateEnvelope> ProjectStateEnvelope(
    const std::string& commit_id, const std::string& mime_type,
    const std::string& linearized_parent,
    const std::map<std::string, std::string>& body, bool daemon_read) {
  const auto author = Field(body, "author");
  if (!BoundedId(commit_id) || !BoundedId(author) ||
      linearized_parent.size() > kMaxIdBytes) {
    return std::nullopt;
  }
  if (mime_type == kEventMime) {
    const auto event = Field(body, "body");
    if (event.empty() || event.size() > kMaxEventBytes) return std::nullopt;
    return StateEnvelope{commit_id, author, mime_type, kMain, false,
                         linearized_parent, event};
  }
  if (mime_type != "text/plain" &&
      mime_type != "application/data-transfer+json") {
    return std::nullopt;
  }
  const auto topic = body.find(kItemField);
  const auto tag = NormalizeItemTopic(topic == body.end() ? "" : topic->second);
  return StateEnvelope{commit_id, author, mime_type, tag.topic_id, tag.tagged,
                       linearized_parent, "", daemon_read};
}

}  // namespace sybl::dm_topic
