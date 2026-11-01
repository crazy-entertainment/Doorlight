#include "friend_routing.h"

#include <algorithm>
#include <cctype>
#include <charconv>

namespace sybl::routing {
namespace {

constexpr auto kGroupOwnerPrefix = "group:";

std::string Value(const StringMap& map, const char* key) {
  const auto it = map.find(key);
  return it == map.end() ? std::string{} : it->second;
}

int64_t IntValue(const StringMap& map, const char* key) {
  const auto value = Value(map, key);
  int64_t result = 0;
  const auto parsed = std::from_chars(value.data(), value.data() + value.size(), result);
  return parsed.ec == std::errc{} ? result : 0;
}

bool IsHex(char c) {
  return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
}

}  // namespace

std::string GroupOwnerKey(const std::string& conversation_id) {
  return conversation_id.empty() ? std::string{} :
                                   std::string(kGroupOwnerPrefix) + conversation_id;
}

std::string Lower(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) {
    return static_cast<char>(std::tolower(c));
  });
  return value;
}

std::optional<std::string> GroupConversationId(const std::string& owner_key) {
  if (owner_key.rfind(kGroupOwnerPrefix, 0) != 0) return std::nullopt;
  auto id = owner_key.substr(std::char_traits<char>::length(kGroupOwnerPrefix));
  return id.empty() ? std::nullopt : std::optional<std::string>(std::move(id));
}

std::string GroupRoute::OwnerKey() const {
  return GroupOwnerKey(conversation_id);
}

std::string BareJamiId(const std::string& value) {
  std::string out = value;
  out.erase(out.begin(), std::find_if(out.begin(), out.end(), [](unsigned char c) {
    return !std::isspace(c);
  }));
  out.erase(std::find_if(out.rbegin(), out.rend(), [](unsigned char c) {
    return !std::isspace(c);
  }).base(), out.end());
  if (out.rfind("jami:", 0) == 0) out.erase(0, 5);
  const auto at = out.find('@');
  if (at != std::string::npos) out.resize(at);
  std::transform(out.begin(), out.end(), out.begin(), [](unsigned char c) {
    return static_cast<char>(std::tolower(c));
  });
  if (out.size() != 40 || !std::all_of(out.begin(), out.end(), IsHex)) return {};
  return out;
}

GroupReceiptState FoldGroupReceipt(
    const GroupRoute& group,
    const std::map<std::string, int>& member_statuses) {
  GroupReceiptState result;
  for (const auto& [raw_id, raw_state] : member_statuses) {
    const auto id = BareJamiId(raw_id);
    if (group.active_member_ids.find(id) == group.active_member_ids.end()) continue;
    const auto state = std::clamp(raw_state, 1, 3);
    result.delivery_state = std::max(result.delivery_state, state);
    if (state == 3) result.read_by.insert(id);
  }
  return result;
}

const FriendRoute* RoutingSnapshot::Friend(const std::string& peer_id) const {
  const auto it = friends.find(BareJamiId(peer_id));
  return it == friends.end() ? nullptr : &it->second;
}

const GroupRoute* RoutingSnapshot::Group(const std::string& conversation_id) const {
  const auto it = groups.find(conversation_id);
  return it == groups.end() ? nullptr : &it->second;
}

bool RoutingSnapshot::IsTrusted(const std::string& peer_id) const {
  return Friend(peer_id) != nullptr;
}

bool RoutingSnapshot::AcceptsWakePeer(const std::string& peer_id) const {
  const auto peer = BareJamiId(peer_id);
  if (peer.empty()) return false;
  if (friends.find(peer) != friends.end()) return true;
  return std::any_of(groups.begin(), groups.end(), [&](const auto& entry) {
    return entry.second.active_member_ids.find(peer) !=
           entry.second.active_member_ids.end();
  });
}

bool RoutingSnapshot::Owns(const std::string& owner_key, const std::string& conversation_id) const {
  if (conversation_id.empty()) return false;
  if (const auto group_id = GroupConversationId(owner_key)) {
    return *group_id == conversation_id && groups.find(conversation_id) != groups.end();
  }
  const auto it = peer_by_conversation.find(conversation_id);
  return it != peer_by_conversation.end() && it->second == BareJamiId(owner_key);
}

std::string RoutingSnapshot::OwnerKey(const std::string& conversation_id) const {
  if (const auto peer = peer_by_conversation.find(conversation_id);
      peer != peer_by_conversation.end()) {
    return peer->second;
  }
  return groups.find(conversation_id) == groups.end()
      ? std::string{}
      : GroupOwnerKey(conversation_id);
}

bool RoutingSnapshot::AcceptsComposerActivity(
    const std::string& event_account_id, const std::string& conversation_id,
    const std::string& participant_id, int status) const {
  const auto participant = BareJamiId(participant_id);
  return event_account_id == account_id && (status == 0 || status == 1) &&
         participant != self_id && Owns(participant, conversation_id);
}

bool RoutingSnapshot::AcceptsRemoteAuthor(const std::string& owner_key,
                                          const std::string& conversation_id,
                                          const std::string& author_id) const {
  const auto author = BareJamiId(author_id);
  if (author.empty() || !Owns(owner_key, conversation_id)) return false;
  if (const auto group_id = GroupConversationId(owner_key)) {
    const auto* route = Group(*group_id);
    return route &&
           route->active_member_ids.find(author) != route->active_member_ids.end();
  }
  return author == BareJamiId(owner_key);
}

RoutingSnapshot BuildRoutingSnapshot(const std::string& account_id, uint64_t revision,
                                     const std::string& self_id,
                                     const std::vector<StringMap>& contacts,
                                     const ConversationMembers& conversations,
                                     const ConversationInfos& conversation_infos) {
  struct Contact {
    bool confirmed{false};
    std::string canonical;
  };
  const auto me = BareJamiId(self_id);
  std::map<std::string, Contact> active;
  for (const auto& contact : contacts) {
    const auto peer = BareJamiId(Value(contact, "id"));
    if (peer.empty() || peer == me || Value(contact, "banned") == "true") continue;
    if (IntValue(contact, "added") <= IntValue(contact, "removed")) continue;
    auto& entry = active[peer];
    entry.confirmed = entry.confirmed || Value(contact, "confirmed") == "true";
    const auto canonical = Value(contact, "conversationId");
    if (!canonical.empty()) entry.canonical = canonical;
  }

  std::map<std::string, std::set<std::string>> conversations_by_peer;
  for (const auto& [peer, unused] : active) conversations_by_peer.emplace(peer, std::set<std::string>{});
  std::map<std::string, std::string> candidate_owner;
  std::map<std::string, GroupRoute> groups;
  for (const auto& [conversation_id, members] : conversations) {
    if (conversation_id.empty()) continue;
    const auto info = conversation_infos.find(conversation_id);
    const auto mode = info == conversation_infos.end()
        ? 0
        : IntValue(info->second, "mode");
    if (info != conversation_infos.end() && mode != 0) {
      std::map<std::string, std::string> roles;
      for (const auto& member : members) {
        const auto id = BareJamiId(Value(member, "uri"));
        const auto role = Lower(Value(member, "role"));
        if (id.empty() || role == "banned" || role == "left") continue;
        roles[id] = role;
      }
      const auto local = roles.find(me);
      if (local != roles.end() &&
          (local->second == "admin" || local->second == "member")) {
        GroupRoute route;
        route.conversation_id = conversation_id;
        route.local_role = local->second;
        for (const auto& [id, role] : roles) {
          if (id == me) continue;
          route.member_ids.push_back(id);
          if (role == "admin" || role == "member") {
            route.active_member_ids.insert(id);
            if (role == "admin") route.admin_member_ids.insert(id);
          } else if (role == "invited") {
            route.invited_member_ids.insert(id);
          }
        }
        groups.emplace(conversation_id, std::move(route));
      }
      continue;
    }
    std::set<std::string> peers;
    for (const auto& member : members) {
      const auto peer = BareJamiId(Value(member, "uri"));
      if (!peer.empty() && peer != me) peers.insert(peer);
    }
    if (peers.size() != 1 || active.find(*peers.begin()) == active.end()) continue;
    candidate_owner.emplace(conversation_id, *peers.begin());
  }
  for (const auto& [conversation_id, peer] : candidate_owner) {
    conversations_by_peer[peer].insert(conversation_id);
  }

  RoutingSnapshot result;
  result.account_id = account_id;
  result.self_id = me;
  result.revision = revision;
  result.groups = std::move(groups);
  std::map<std::string, std::string> owner_candidates;
  std::set<std::string> ambiguous_owners;
  for (const auto& [peer, contact] : active) {
    auto all = conversations_by_peer[peer];
    if (!contact.canonical.empty()) all.insert(contact.canonical);
    FriendRoute route;
    route.peer_id = peer;
    route.confirmed = contact.confirmed;
    route.conversation_ids = std::move(all);
    route.canonical_conversation_id = !contact.canonical.empty()
        ? contact.canonical
        : (route.conversation_ids.empty() ? std::string{} : *route.conversation_ids.begin());
    for (const auto& conversation_id : route.conversation_ids) {
      const auto [it, inserted] = owner_candidates.emplace(conversation_id, peer);
      if (!inserted && it->second != peer) ambiguous_owners.insert(conversation_id);
    }
    result.friends.emplace(peer, std::move(route));
  }
  for (const auto& conversation_id : ambiguous_owners)
    owner_candidates.erase(conversation_id);
  result.peer_by_conversation = std::move(owner_candidates);
  return result;
}

}  // namespace sybl::routing
