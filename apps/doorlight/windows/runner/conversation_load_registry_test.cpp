#undef NDEBUG

#include "conversation_load_registry.h"
#include "history_search.h"

#include <cassert>
#include <chrono>
#include <string>
#include <utility>
#include <vector>

namespace {

sybl::conversation::PendingLoad Chat(std::string peer = "peer") {
  return {sybl::conversation::LoadKind::kChat, std::move(peer), "conversation",
          "", 50};
}

sybl::conversation::PendingLoad Folder(std::string peer = "peer") {
  return {sybl::conversation::LoadKind::kFolder, std::move(peer),
          "conversation", "", 200};
}

sybl::conversation::PendingLoad DmTopicState(std::string peer = "peer") {
  return {sybl::conversation::LoadKind::kDmTopicState, std::move(peer),
          "conversation", "cursor", 200};
}

sybl::conversation::PendingLoad SearchMessage(std::string peer = "peer") {
  return {sybl::conversation::LoadKind::kSearchMessage, std::move(peer),
          "conversation", std::string(40, 'd'), 1};
}

}  // namespace

int main() {
  using sybl::conversation::LoadRegistry;

  LoadRegistry registry;
  const auto start = LoadRegistry::TimePoint{};
  assert(registry.Register(7, Chat(), start));
  assert(registry.active_size() == 1);
  const auto claimed = registry.Take(7, start);
  assert(claimed && claimed->kind == sybl::conversation::LoadKind::kChat);
  assert(registry.active_size() == 0);

  // Completed ids are process-lifetime tombstones: a late callback can never
  // claim a later request that happens to receive the same random daemon id.
  assert(!registry.Register(7, Chat("other"), start));
  assert(!registry.Take(7, start));

  assert(registry.Register(8, Chat(), start));
  assert(registry.CancelChat(8, start));
  assert(!registry.Take(8, start));
  assert(!registry.Register(8, Chat(), start));

  assert(registry.Register(9, Folder(), start));
  assert(!registry.CancelChat(9, start));
  assert(registry.Take(9, start));

  assert(registry.Register(13, DmTopicState(), start));
  assert(!registry.CancelChat(13, start));
  const auto topic_state = registry.Take(13, start);
  assert(topic_state && topic_state->kind ==
                            sybl::conversation::LoadKind::kDmTopicState);

  assert(registry.Register(14, DmTopicState(), start));
  assert(registry.CancelDmTopicState(14, start));
  assert(!registry.Take(14, start));
  assert(!registry.Register(14, DmTopicState(), start));
  assert(registry.Register(15, Chat(), start));
  assert(!registry.CancelDmTopicState(15, start));
  assert(registry.Take(15, start));

  assert(registry.Register(10, Chat(), start));
  const auto expired = start + LoadRegistry::kDeadline;
  assert(!registry.Take(10, expired));
  assert(!registry.Register(10, Chat(), expired));

  assert(registry.Register(11, Chat("peer-a"), expired));
  assert(registry.Register(12, Chat("peer-b"), expired));
  registry.RemovePeer("peer-a", expired);
  assert(!registry.Take(11, expired));
  assert(registry.Take(12, expired));

  LoadRegistry bounded;
  for (std::uint32_t id = 1;
       id <= LoadRegistry::kMaxActiveLoads; ++id) {
    assert(bounded.Register(id, Chat(), start));
  }
  assert(!bounded.CanStart(start));
  assert(bounded.CanStart(start + LoadRegistry::kDeadline));

  LoadRegistry remembered;
  for (std::uint32_t id = 1;
       id <= LoadRegistry::kMaxRememberedIds; ++id) {
    assert(remembered.Register(id, Chat(), start));
    assert(remembered.Take(id, start));
  }
  assert(!remembered.CanStart(start));

  {
    using sybl::conversation::AnsweredLoads;
    using sybl::conversation::LoadKind;
    struct Request {
      int tag;
    };
    LoadRegistry loads;
    AnsweredLoads<Request> answered;
    assert(answered.Register(loads, 20, SearchMessage(), Request{1}, start));
    assert(answered.size() == 1 && loads.active_size() == 1);
    assert(answered.Due(loads) == start + LoadRegistry::kDeadline);
    // The daemon answer: the registry load is taken, then its caller, once.
    const auto taken = loads.Take(20, start);
    assert(taken && taken->kind == LoadKind::kSearchMessage &&
           taken->cursor == std::string(40, 'd') && taken->limit == 1);
    const auto completed = answered.Complete(20);
    assert(completed && completed->tag == 1);
    assert(!answered.Complete(20));
    assert(answered.Retired(loads, start).empty() && answered.size() == 0);
    assert(!answered.Due(loads));
    // A late callback for the completed id is rejected, and the id is never reused.
    assert(!loads.Take(20, start));
    assert(!answered.Register(loads, 20, SearchMessage(), Request{2}, start));
    assert(answered.size() == 0);

    // Expiry yields the stored request for an unavailable answer exactly once.
    assert(answered.Register(loads, 21, SearchMessage(), Request{3}, start));
    const auto before = start + LoadRegistry::kDeadline - std::chrono::nanoseconds(1);
    assert(answered.Retired(loads, before).empty() && answered.size() == 1);
    const auto deadline = start + LoadRegistry::kDeadline;
    const auto expired_requests = answered.Retired(loads, deadline);
    assert(expired_requests.size() == 1 && expired_requests.front().tag == 3);
    assert(answered.Retired(loads, deadline).empty());
    assert(!loads.Take(21, deadline) && !answered.Complete(21));
    // A registry purge by another feature leaves the caller due at once.
    assert(answered.Register(loads, 22, SearchMessage(), Request{4}, start));
    assert(!loads.Take(99, deadline));
    assert(answered.Due(loads) == LoadRegistry::TimePoint::min());
    const auto purged = answered.Retired(loads, deadline);
    assert(purged.size() == 1 && purged.front().tag == 4);

    // Peer removal and clear keep a selected-result load registered and
    // unanswered: its daemon scan still runs. Other kinds are dropped as before.
    assert(answered.Register(loads, 23, SearchMessage("peer-a"), Request{5}, deadline));
    assert(answered.Register(loads, 24, SearchMessage("peer-b"), Request{6}, deadline));
    assert(loads.Register(25, Chat("peer-a"), deadline));
    assert(loads.Register(26, Folder("peer-a"), deadline));
    assert(loads.Register(27, DmTopicState("peer-a"), deadline));
    assert(loads.Register(29, Chat("peer-b"), deadline));
    loads.RemovePeer("peer-a", deadline);
    assert(loads.Active(23) && loads.Active(24) && loads.Active(29));
    assert(!loads.Active(25) && !loads.Active(26) && !loads.Active(27));
    assert(answered.Due(loads) == deadline + LoadRegistry::kDeadline);
    assert(answered.Retired(loads, deadline).empty() && answered.size() == 2);
    assert(loads.Register(32, Folder("peer-b"), deadline));
    assert(loads.Register(33, DmTopicState("peer-b"), deadline));
    loads.ClearActive();
    assert(loads.Active(23) && loads.Active(24) && loads.active_size() == 2);
    assert(!loads.Take(29, deadline) && !loads.Take(32, deadline) && !loads.Take(33, deadline));
    assert(answered.Retired(loads, deadline).empty() && answered.size() == 2);
    // The daemon's later answer takes the held load, once.
    const auto held = loads.Take(23, deadline);
    assert(held && held->kind == LoadKind::kSearchMessage);
    const auto late = answered.Complete(23);
    assert(late && late->tag == 5 && !answered.Complete(23));
    // With no answer, the deadline answers it exactly once.
    const auto second_deadline = deadline + LoadRegistry::kDeadline;
    assert(answered.Retired(loads, second_deadline - std::chrono::nanoseconds(1)).empty());
    const auto timed_out = answered.Retired(loads, second_deadline);
    assert(timed_out.size() == 1 && timed_out.front().tag == 6);
    assert(answered.Retired(loads, second_deadline).empty() && answered.size() == 0);
    assert(!loads.Take(24, second_deadline) && !answered.Complete(24));

    // A duplicate daemon id retires the first caller and is refused itself.
    assert(answered.Register(loads, 28, SearchMessage(), Request{9}, deadline));
    assert(!answered.Register(loads, 28, SearchMessage(), Request{10}, deadline));
    const auto duplicate = answered.Retired(loads, deadline);
    assert(duplicate.size() == 1 && duplicate.front().tag == 9);
    assert(!answered.Complete(28));
    // A duplicate id claimed by another kind answers it at once too.
    assert(answered.Register(loads, 34, SearchMessage(), Request{14}, deadline));
    assert(!loads.Register(34, Chat(), deadline));
    assert(answered.Due(loads) == LoadRegistry::TimePoint::min());
    const auto claimed_id = answered.Retired(loads, deadline);
    assert(claimed_id.size() == 1 && claimed_id.front().tag == 14);

    // Held selected-result loads still count against the start cap after
    // clear and peer removal, until their deadline answers them.
    LoadRegistry capped;
    AnsweredLoads<Request> scans;
    for (std::uint32_t id = 1; id <= LoadRegistry::kMaxActiveLoads; ++id) {
      assert(scans.Register(capped, id, SearchMessage(), Request{static_cast<int>(id)}, start));
    }
    capped.ClearActive();
    capped.RemovePeer("peer", start);
    assert(!capped.CanStart(start) && capped.active_size() == LoadRegistry::kMaxActiveLoads);
    assert(scans.Retired(capped, start).empty());
    assert(scans.Retired(capped, deadline).size() == LoadRegistry::kMaxActiveLoads);
    assert(capped.CanStart(deadline) && scans.size() == 0);

    // Exhaustion answers a held selected-result load at once.
    LoadRegistry exhausting;
    AnsweredLoads<Request> exhausted;
    assert(exhausted.Register(exhausting, 1, SearchMessage(), Request{15}, start));
    for (std::uint32_t id = 2; id <= LoadRegistry::kMaxRememberedIds; ++id) {
      assert(exhausting.Register(id, Chat(), start));
      assert(exhausting.Take(id, start));
    }
    assert(exhausting.Active(1) && exhausted.Retired(exhausting, start).empty());
    assert(!exhausting.Register(LoadRegistry::kMaxRememberedIds + 1, Chat(), start));
    const auto exhaustion = exhausted.Retired(exhausting, start);
    assert(exhaustion.size() == 1 && exhaustion.front().tag == 15);
    assert(exhausted.size() == 0);

    // A held load completed after a retirement advanced the search epoch is
    // answered unavailable, never with content.
    {
      using sybl::history_search::CompleteMessageLoad;
      using sybl::history_search::DispatchMessageLoad;
      using sybl::history_search::MessageLoadFacts;
      using sybl::history_search::MessageLoadHandlers;
      using sybl::history_search::MessageLoadTicket;
      struct Message {
        std::string id;
      };
      struct Selected {
        MessageLoadTicket ticket;
      };
      const std::string conversation(40, 'c');
      const std::string message(40, 'd');
      const MessageLoadTicket ticket{"account", "peer", conversation, message, 7, 3};
      LoadRegistry selected_loads;
      AnsweredLoads<Selected> selected;
      assert(selected.Register(selected_loads, 40, SearchMessage(), Selected{ticket}, start));
      MessageLoadFacts facts{"account", 7, true, 3, false};
      const auto answer = [&](const Selected& request) {
        std::string outcome;
        DispatchMessageLoad(
            CompleteMessageLoad(request.ticket, "account", conversation, facts,
                                std::vector<Message>{{message}}),
            MessageLoadHandlers{[&](std::size_t) { outcome = "content"; },
                                [&] { outcome = "unavailable"; }});
        return outcome;
      };
      assert(answer(Selected{ticket}) == "content");
      facts.epoch = 4;  // the retirement
      selected_loads.ClearActive();
      assert(selected.Retired(selected_loads, start).empty());
      assert(selected_loads.Take(40, start));
      const auto request = selected.Complete(40);
      assert(request && answer(*request) == "unavailable");
      assert(!selected.Complete(40) && selected.Retired(selected_loads, deadline).empty());
    }

    // A full registry stores nothing; shutdown takes every stored caller once.
    LoadRegistry full;
    AnsweredLoads<Request> refused;
    for (std::uint32_t id = 1; id <= LoadRegistry::kMaxActiveLoads; ++id) {
      assert(full.Register(id, Chat(), start));
    }
    assert(!refused.Register(full, 1000, SearchMessage(), Request{11}, start));
    assert(refused.size() == 0);
    LoadRegistry stopping;
    AnsweredLoads<Request> pending;
    assert(pending.Register(stopping, 30, SearchMessage(), Request{12}, start));
    assert(pending.Register(stopping, 31, SearchMessage(), Request{13}, start));
    assert(pending.TakeAll().size() == 2);
    assert(pending.TakeAll().empty() && !pending.Complete(30));
  }

  return 0;
}
