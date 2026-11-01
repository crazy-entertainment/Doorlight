#pragma once

#include <cstddef>
#include <map>
#include <optional>
#include <string>

namespace sybl::dm_topic {

inline constexpr char kMain[] = "main";
inline constexpr char kItemField[] = "sybl-topic-v1";
inline constexpr char kEventMime[] = "application/x-sybl-dm-topic+json";
inline constexpr std::size_t kMaxEventBytes = 4096;
inline constexpr int kMaxStatePageItems = 200;

struct ItemTag {
  std::string topic_id;
  bool tagged = false;

  bool operator==(const ItemTag& other) const {
    return topic_id == other.topic_id && tagged == other.tagged;
  }
};

struct StateEnvelope {
  std::string commit_id;
  std::string author_id;
  std::string mime_type;
  std::string topic_id;
  bool topic_tagged = false;
  std::string linearized_parent;
  std::string event_body;
  bool daemon_read = false;

  bool operator==(const StateEnvelope& other) const {
    return commit_id == other.commit_id && author_id == other.author_id &&
           mime_type == other.mime_type && topic_id == other.topic_id &&
           topic_tagged == other.topic_tagged &&
           linearized_parent == other.linearized_parent &&
           event_body == other.event_body && daemon_read == other.daemon_read;
  }
};

ItemTag NormalizeItemTopic(const std::string& value);
bool IsValidOutgoingTopic(const std::string& value);
std::optional<StateEnvelope> ProjectStateEnvelope(
    const std::string& commit_id, const std::string& mime_type,
    const std::string& linearized_parent,
    const std::map<std::string, std::string>& body,
    bool daemon_read = false);

}  // namespace sybl::dm_topic
