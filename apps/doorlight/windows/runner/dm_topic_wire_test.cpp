#undef NDEBUG

#include "dm_topic_wire.h"

#include <cassert>
#include <map>
#include <string>

int main() {
  using sybl::dm_topic::ItemTag;
  using sybl::dm_topic::StateEnvelope;

  const std::string custom = "0123456789abcdef0123456789abcdef";
  assert((sybl::dm_topic::NormalizeItemTopic("") == ItemTag{"main", false}));
  assert((sybl::dm_topic::NormalizeItemTopic("BAD") == ItemTag{"main", false}));
  assert((sybl::dm_topic::NormalizeItemTopic("main") == ItemTag{"main", true}));
  assert((sybl::dm_topic::NormalizeItemTopic(custom) == ItemTag{custom, true}));
  assert(sybl::dm_topic::IsValidOutgoingTopic(""));
  assert(sybl::dm_topic::IsValidOutgoingTopic("main"));
  assert(sybl::dm_topic::IsValidOutgoingTopic(custom));
  assert(!sybl::dm_topic::IsValidOutgoingTopic("BAD"));

  const std::map<std::string, std::string> common{
      {"author", "alice"},
      {"linearizedParent", "spoofed-parent"},
      {sybl::dm_topic::kItemField, custom},
  };
  const auto text = sybl::dm_topic::ProjectStateEnvelope(
      "message-a", "text/plain", "parent-a", common, true);
  assert((text == StateEnvelope{"message-a", "alice", "text/plain", custom,
                                true, "parent-a", "", true}));

  auto legacy = common;
  legacy.erase(sybl::dm_topic::kItemField);
  assert((sybl::dm_topic::ProjectStateEnvelope(
              "legacy", "text/plain", "parent-a", legacy) ==
          StateEnvelope{"legacy", "alice", "text/plain", "main", false,
                        "parent-a", ""}));
  legacy[sybl::dm_topic::kItemField] = "BAD";
  assert((sybl::dm_topic::ProjectStateEnvelope(
              "bad", "text/plain", "parent-a", legacy) ==
          StateEnvelope{"bad", "alice", "text/plain", "main", false,
                        "parent-a", ""}));

  std::map<std::string, std::string> control{
      {"author", "alice"},
      {"linearizedParent", "spoofed-parent"},
      {"body", R"({"v":1})"},
  };
  const auto event = sybl::dm_topic::ProjectStateEnvelope(
      "event-a", sybl::dm_topic::kEventMime, "parent-a", control);
  assert(event && event->event_body == R"({"v":1})");
  control["body"] = std::string(sybl::dm_topic::kMaxEventBytes + 1, 'x');
  assert(!sybl::dm_topic::ProjectStateEnvelope(
      "large", sybl::dm_topic::kEventMime, "parent-a", control));
  assert(!sybl::dm_topic::ProjectStateEnvelope(
      "foreign", "member", "parent-a", common));
  return 0;
}
