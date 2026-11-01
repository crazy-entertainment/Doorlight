#ifdef NDEBUG
#undef NDEBUG
#endif

#include "friend_routing.h"

#include <cassert>

using sybl::routing::BuildRoutingSnapshot;
using sybl::routing::ConversationMembers;
using sybl::routing::StringMap;

namespace {

constexpr auto kMe = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
constexpr auto kAlice = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
constexpr auto kBob = "cccccccccccccccccccccccccccccccccccccccc";
constexpr auto kCarol = "dddddddddddddddddddddddddddddddddddddddd";

StringMap Contact(const std::string& id, const std::string& added = "2",
                  const std::string& removed = "0", const std::string& banned = "false",
                  const std::string& confirmed = "false", const std::string& conversation = "") {
  return {{"id", id}, {"added", added}, {"removed", removed}, {"banned", banned},
          {"confirmed", confirmed}, {"conversationId", conversation}};
}

std::vector<StringMap> Members(std::initializer_list<std::string> ids) {
  std::vector<StringMap> result;
  for (const auto& id : ids) result.push_back({{"uri", id}});
  return result;
}

}  // namespace

int main() {
  {
    auto snapshot = BuildRoutingSnapshot(
        "account", 7, kMe,
        {Contact(kBob), Contact(kAlice, "2", "0", "false", "true"),
         Contact("not-an-id"), Contact("dddddddddddddddddddddddddddddddddddddddd", "1", "2"),
         Contact("eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", "2", "0", "true")},
        {});
    assert(snapshot.friends.size() == 2);
    assert(snapshot.self_id == kMe);
    assert(snapshot.friends.begin()->first == kAlice);
    assert(snapshot.IsTrusted(kAlice));
    assert(snapshot.IsTrusted(kBob));
    assert(snapshot.Friend(kAlice)->confirmed);
    assert(!snapshot.Friend(kBob)->confirmed);
  }
  {
    ConversationMembers conversations{
        {"a-duplicate", Members({kMe, kAlice})},
        {"z-canonical", Members({kMe, kAlice})},
        {"group", Members({kMe, kAlice, kBob})},
    };
    auto snapshot = BuildRoutingSnapshot(
        "account", 8, kMe, {Contact(kAlice, "2", "0", "false", "false", "z-canonical"),
                            Contact(kBob)},
        conversations);
    const auto* route = snapshot.Friend(kAlice);
    assert(route);
    assert(route->canonical_conversation_id == "z-canonical");
    assert(route->conversation_ids == std::set<std::string>({"a-duplicate", "z-canonical"}));
    assert(snapshot.Owns(kAlice, "a-duplicate"));
    assert(!snapshot.Owns(kBob, "a-duplicate"));
    assert(snapshot.AcceptsComposerActivity("account", "z-canonical", kAlice, 1));
    assert(snapshot.AcceptsComposerActivity("account", "z-canonical", kAlice, 0));
    assert(!snapshot.AcceptsComposerActivity("other", "z-canonical", kAlice, 1));
    assert(!snapshot.AcceptsComposerActivity("account", "missing", kAlice, 1));
    assert(!snapshot.AcceptsComposerActivity("account", "z-canonical", kMe, 1));
    assert(!snapshot.AcceptsComposerActivity("account", "z-canonical", kAlice, 2));
    assert(snapshot.peer_by_conversation.find("group") == snapshot.peer_by_conversation.end());
  }
  {
    auto snapshot = BuildRoutingSnapshot(
        "account", 9, kMe, {Contact(kAlice)},
        {{"z-last", Members({kMe, kAlice})}, {"a-first", Members({kMe, kAlice})}});
    assert(snapshot.Friend(kAlice)->canonical_conversation_id == "a-first");
  }
  {
    auto snapshot = BuildRoutingSnapshot(
        "account", 10, kMe,
        {Contact(kAlice, "2", "0", "false", "false", "collision"),
         Contact(kBob, "2", "0", "false", "false", "collision"),
         Contact(kCarol, "2", "0", "false", "false", "collision")},
        {});
    assert(snapshot.peer_by_conversation.find("collision") ==
           snapshot.peer_by_conversation.end());
    assert(!snapshot.Owns(kAlice, "collision"));
    assert(!snapshot.Owns(kBob, "collision"));
    assert(!snapshot.Owns(kCarol, "collision"));
  }
  {
    const std::string conversation_id = "group-conversation";
    const ConversationMembers conversations{
        {conversation_id,
         {{{"uri", kMe}, {"role", "admin"}},
          {{"uri", kAlice}, {"role", "admin"}},
          {{"uri", kBob}, {"role", "invited"}},
          {{"uri", kCarol}, {"role", "banned"}}}},
    };
    const sybl::routing::ConversationInfos infos{
        {conversation_id, {{"mode", "2"}, {"title", "The Crew"}}},
    };
    auto snapshot = BuildRoutingSnapshot(
        "account", 12, kMe,
        {Contact(kAlice), Contact(kBob), Contact(kCarol)}, conversations, infos);
    const auto* group = snapshot.Group(conversation_id);
    assert(group);
    assert(group->OwnerKey() == sybl::routing::GroupOwnerKey(conversation_id));
    assert(group->member_ids == std::vector<std::string>({kAlice, kBob}));
    assert(group->active_member_ids == std::set<std::string>({kAlice}));
    assert(group->admin_member_ids == std::set<std::string>({kAlice}));
    assert(group->invited_member_ids == std::set<std::string>({kBob}));
    assert(group->MemberCount() == 3);
    assert(group->CanManageMembers());
    assert(snapshot.Owns(group->OwnerKey(), conversation_id));
    assert(snapshot.OwnerKey(conversation_id) == group->OwnerKey());
    assert(snapshot.AcceptsRemoteAuthor(group->OwnerKey(), conversation_id, kAlice));
    assert(!snapshot.AcceptsRemoteAuthor(group->OwnerKey(), conversation_id, kBob));
    assert(!snapshot.AcceptsRemoteAuthor(group->OwnerKey(), conversation_id, kCarol));
    assert(snapshot.peer_by_conversation.find(conversation_id) ==
           snapshot.peer_by_conversation.end());

    const auto receipt = sybl::routing::FoldGroupReceipt(
        *group, {{kAlice, 2}, {std::string("jami:") + kAlice, 3},
                 {kBob, 3}, {kCarol, 9}});
    assert(receipt.delivery_state == 3);
    assert(receipt.read_by == std::set<std::string>({kAlice}));
  }
  {
    const std::string conversation_id = "pending-group";
    auto snapshot = BuildRoutingSnapshot(
        "account", 13, kMe, {Contact(kAlice)},
        {{conversation_id,
          {{{"uri", kMe}, {"role", "invited"}},
           {{"uri", kAlice}, {"role", "admin"}}}}},
        {{conversation_id, {{"mode", "2"}}}});
    assert(!snapshot.Group(conversation_id));
    assert(!snapshot.Owns(sybl::routing::GroupOwnerKey(conversation_id),
                          conversation_id));
  }
  {
    const std::string conversation_id = "wake-group";
    auto snapshot = BuildRoutingSnapshot(
        "account", 14, kMe, {Contact(kAlice)},
        {{conversation_id,
          {{{"uri", kMe}, {"role", "member"}},
           {{"uri", kBob}, {"role", "member"}},
           {{"uri", kCarol}, {"role", "invited"}}}}},
        {{conversation_id, {{"mode", "2"}}}});
    assert(snapshot.AcceptsWakePeer(kAlice));
    assert(snapshot.AcceptsWakePeer(kBob));
    assert(!snapshot.AcceptsWakePeer(kCarol));
    assert(!snapshot.AcceptsWakePeer("eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"));
  }
}
