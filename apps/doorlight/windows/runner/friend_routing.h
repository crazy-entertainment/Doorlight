#pragma once

#include <cstdint>
#include <map>
#include <optional>
#include <set>
#include <string>
#include <vector>

namespace sybl::routing {

using StringMap = std::map<std::string, std::string>;
using ConversationMembers = std::map<std::string, std::vector<StringMap>>;
using ConversationInfos = std::map<std::string, StringMap>;

struct FriendRoute {
  std::string peer_id;
  bool confirmed{false};
  std::string canonical_conversation_id;
  std::set<std::string> conversation_ids;
};

struct GroupRoute {
  std::string conversation_id;
  std::vector<std::string> member_ids;
  std::set<std::string> active_member_ids;
  std::set<std::string> admin_member_ids;
  std::set<std::string> invited_member_ids;
  std::string local_role;

  std::string OwnerKey() const;
  size_t MemberCount() const { return member_ids.size() + 1; }
  bool CanManageMembers() const { return local_role == "admin"; }
};

struct GroupReceiptState {
  int delivery_state{1};
  std::set<std::string> read_by;
};

struct RoutingSnapshot {
  std::string account_id;
  std::string self_id;
  uint64_t revision{0};
  std::map<std::string, FriendRoute> friends;
  std::map<std::string, GroupRoute> groups;
  std::map<std::string, std::string> peer_by_conversation;

  const FriendRoute* Friend(const std::string& peer_id) const;
  const GroupRoute* Group(const std::string& conversation_id) const;
  bool IsTrusted(const std::string& peer_id) const;
  bool AcceptsWakePeer(const std::string& peer_id) const;
  bool Owns(const std::string& owner_key, const std::string& conversation_id) const;
  std::string OwnerKey(const std::string& conversation_id) const;
  bool AcceptsComposerActivity(const std::string& event_account_id,
                               const std::string& conversation_id,
                               const std::string& participant_id,
                               int status) const;
  bool AcceptsRemoteAuthor(const std::string& owner_key,
                           const std::string& conversation_id,
                           const std::string& author_id) const;
};

std::string BareJamiId(const std::string& value);
std::string GroupOwnerKey(const std::string& conversation_id);
std::optional<std::string> GroupConversationId(const std::string& owner_key);
GroupReceiptState FoldGroupReceipt(
    const GroupRoute& group,
    const std::map<std::string, int>& member_statuses);

// Pure builder over libjami-shaped maps. The bridge gathers daemon truth on its serialized worker, calls this,
// then atomically publishes the resulting immutable snapshot without holding its mutex across libjami calls.
RoutingSnapshot BuildRoutingSnapshot(const std::string& account_id, uint64_t revision,
                                     const std::string& self_id,
                                     const std::vector<StringMap>& contacts,
                                     const ConversationMembers& conversations,
                                     const ConversationInfos& conversation_infos = {});

}  // namespace sybl::routing
