#ifdef NDEBUG
#undef NDEBUG
#endif

#include "group_call_wire.h"
#include "annotation_ingress.h"

#include <cassert>
#include <string>

int main() {
  sybl::AnnotationIngress stalled, rate, bytes;
  for (int i = 0; i < 128; ++i) {
    assert(stalled.Admit(100, 0));
    assert(rate.Admit(100, 0));
    rate.Delivered(100);
  }
  assert(!stalled.Admit(100, 100000));
  assert(!rate.Admit(100, 0));
  assert(rate.Admit(100, 1000));
  assert(!rate.Admit(65537, 1000));
  for (int i = 0; i < 128; ++i) stalled.Delivered(100);
  assert(stalled.Admit(100, 100000));
  for (int i = 0; i < 16; ++i) assert(bytes.Admit(65536, 0));
  assert(!bytes.Admit(1, 1000));
  for (int i = 0; i < 16; ++i) bytes.Delivered(65536);
  assert(bytes.Admit(6000, 1000));
  using sybl::group_call::ConferenceInfoWithinBounds;
  const std::map<std::string, std::string> row{{"uri", std::string(40, 'a')},
      {"device", std::string(64, 'b')}, {"sinkId", "video"}};
  assert(ConferenceInfoWithinBounds({row}));
  assert(!ConferenceInfoWithinBounds(std::vector<std::map<std::string, std::string>>(129, row)));
  assert(!ConferenceInfoWithinBounds({{{"field", std::string(1025, 'x')}}}));
  std::map<std::string, std::string> heavy;
  for (int i = 0; i < 32; ++i) heavy[std::to_string(i)] = std::string(1024, 'x');
  assert(!ConferenceInfoWithinBounds({heavy, heavy, heavy}));
  heavy["extra"] = "x";
  assert(!ConferenceInfoWithinBounds({heavy}));
  using Gate = sybl::group_call::ConferenceInfoIngress<int>;
  Gate ingress;
  const auto start = Gate::TimePoint{};
  for (int i = 0; i < 1000; ++i) ingress.Offer(i, start);
  assert(ingress.Due() == start + Gate::kDelay);
  assert(!ingress.Take(start + Gate::kDelay - std::chrono::milliseconds(1)));
  assert(ingress.Take(start + Gate::kDelay) == 999);
  for (int i = 1000; i < 2000; ++i) ingress.Offer(i, start + Gate::kDelay);
  assert(!ingress.Due());
  ingress.Finish(start + Gate::kDelay);
  assert(ingress.Due() == start + Gate::kDelay * 2);
  assert(ingress.Take(start + Gate::kDelay * 2) == 1999);
  ingress.Finish(start + Gate::kDelay * 2);
  assert(!ingress.Due());
  using sybl::group_call::AcceptPresence;
  using sybl::group_call::MediaTarget;
  using sybl::group_call::OwnsMediaSink;
  using sybl::group_call::HostConferenceForCurrent;
  using sybl::group_call::RoomId;

  assert(MediaTarget("conference", "leg", false) == "leg");
  assert(MediaTarget("conference", "", false) == "conference");
  assert(MediaTarget("conference", "leg", true) == "conference");
  assert(OwnsMediaSink("conference", "leg", "conference"));
  assert(OwnsMediaSink("conference", "leg", "leg"));
  assert(!OwnsMediaSink("conference", "leg", "other"));
  assert(HostConferenceForCurrent("conference", true, false, "CURRENT") ==
         "conference");
  assert(HostConferenceForCurrent("conference", true, true, "CURRENT").empty());
  assert(HostConferenceForCurrent("conference", true, false, "INCOMING").empty());

  assert(RoomId("syblv1-voice-42") == "voice");
  assert(RoomId("syblv1-games-room-9") == "games-room");
  assert(RoomId("ordinary-call").empty());
  assert(RoomId("syblv1-Voice-1").empty());
  assert(RoomId("syblv1-voice-0").empty());
  assert(RoomId("syblv1-" + std::string(33, 'a') + "-1").empty());

  const auto member = std::string(40, 'a');
  sybl::routing::GroupRoute group;
  group.conversation_id = std::string(40, 'b');
  group.member_ids = {member};
  group.active_member_ids = {member};
  group.local_role = "member";
  sybl::routing::RoutingSnapshot snapshot;
  snapshot.account_id = std::string(40, 'c');
  snapshot.self_id = std::string(40, 'd');
  snapshot.groups.emplace(group.conversation_id, group);

  assert(AcceptPresence(snapshot, member, "{}"));
  assert(!AcceptPresence(snapshot, std::string(40, 'e'), "{}"));
  assert(!AcceptPresence(
      snapshot, member,
      std::string(sybl::group_call::kMaxPresenceBytes + 1, 'x')));
}
