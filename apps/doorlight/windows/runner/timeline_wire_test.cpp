#undef NDEBUG

#include "timeline_wire.h"
#include "profile_wire.h"
#include "rich_timeline.h"
#include "reaction_projection.h"
#include "history_search.h"

#include <cassert>
#include <limits>
#include <string>
#include <thread>

int main() {
  using namespace sybl::timeline;
  {
    const std::string message(40, 'a'), author(40, 'b');
    const auto normalize = [](const std::string& value) { return value; };
    const auto accepts = [&](const std::string& value) { return value == author; };
    std::map<std::string, std::string> reaction{{"id", std::string(40, '1')},
        {"author", author}, {"body", "\xf0\x9f\x91\x8d"}, {"react-to", message}};
    const auto result = sybl::reaction::Project(message, {reaction, reaction}, normalize, accepts);
    assert(result.complete && result.entries.size() == 1);
    assert(result.entries.front().commit_id == std::string(40, '1'));
    auto conflicting_reaction = reaction;
    conflicting_reaction["body"] = "\xf0\x9f\x98\x82";
    const auto conflicting_result = sybl::reaction::Project(
        message, {reaction, conflicting_reaction, reaction}, normalize, accepts);
    assert(!conflicting_result.complete && conflicting_result.entries.empty());
    reaction["react-to"] = "other";
    const auto foreign = sybl::reaction::Project(message, {reaction}, normalize, accepts);
    assert(!foreign.complete && foreign.entries.empty());
    std::vector<std::map<std::string, std::string>> many(sybl::reaction::kMaxEntries + 1);
    assert(!sybl::reaction::Project(message, many, normalize, accepts).complete);
  }
  const auto reply = sybl::rich_timeline::Project({{"reply-to", std::string(40, 'a')}, {"quotedText", "untrusted"}}, false);
  for (const auto& body : {std::string("reaction"), std::string{}}) {
    for (bool group : {false, true}) {
      assert(!sybl::rich_timeline::Project({{"react-to", std::string(40, 'a')}, {"body", body}}, group));
    }
  }
  assert(sybl::rich_timeline::Project({{"react-to", ""}, {"body", "ordinary"}}, false));
  assert(reply && reply->size() == 1 && reply->at("replyTo") == std::string(40, 'a'));
  assert(!sybl::rich_timeline::Project({{"reply-to", std::string(1025, 'x')}}, false));
  assert(!sybl::rich_timeline::Project({{"reply-to", std::string{"\xed\xa0\x80"}}}, false));

  const std::map<std::string, std::string> rich_fields{
      {"sybl-room-v1", "games"}, {"sybl-op-v1", std::string(32, 'a')}};
  const auto rich = sybl::rich_timeline::Project(rich_fields, true);
  assert(rich && rich->at("roomId") == "games" &&
         rich->at("operationId") == std::string(32, 'a'));
  assert(!sybl::rich_timeline::Project(rich_fields, false));
  auto conflicting = rich_fields;
  conflicting.emplace("sybl-topic-v1", "main");
  assert(!sybl::rich_timeline::Project(conflicting, true));
  assert(!sybl::rich_timeline::Project({{"sybl-op-v1", "bad"}}, false));
  assert(sybl::rich_timeline::BoundedBody("{\"v\":2}"));
  assert(!sybl::rich_timeline::BoundedBody(std::string(1025, 'x')));

  const auto ascii = MeasureUtf8("hello", 5);
  assert(ascii && ascii->utf16_code_units == 5 &&
         ascii->utf8_bytes == 5);

  const std::string e_acute{"\xc3\xa9"};
  const auto bmp = MeasureUtf8(e_acute, 1);
  assert(bmp && bmp->utf16_code_units == 1 && bmp->utf8_bytes == 2);

  const std::string grin{"\xf0\x9f\x98\x80"};
  const auto astral = MeasureUtf8(grin, 2);
  assert(astral && astral->utf16_code_units == 2 &&
         astral->utf8_bytes == 4);
  assert(!MeasureUtf8(grin, 1));

  assert(!MeasureUtf8(std::string{"\xc0\xaf"}, 2));       // overlong
  assert(!MeasureUtf8(std::string{"\xed\xa0\x80"}, 1));  // surrogate
  assert(!MeasureUtf8(std::string{"\xf4\x90\x80\x80"}, 2));  // > U+10FFFF
  assert(!MeasureUtf8(std::string{"\xe2\x82"}, 2));       // truncated
  assert(!MeasureUtf8(std::string{"\x80"}, 1));           // stray continuation

  using sybl::profile_wire::DecodeDisplayName;
  using sybl::profile_wire::kMaxDisplayNameUtf8Bytes;
  assert(DecodeDisplayName(std::string(kMaxDisplayNameUtf8Bytes, 'x')));
  assert(!DecodeDisplayName(
      std::string(kMaxDisplayNameUtf8Bytes + 1, 'x')));
  std::string emoji_boundary;
  for (std::size_t i = 0; i < kMaxDisplayNameUtf8Bytes / 4; ++i)
    emoji_boundary += grin;
  assert(DecodeDisplayName(emoji_boundary));
  assert(!DecodeDisplayName(std::string{"\xed\xa0\x80"}));

  using sybl::profile_wire::DecodeAvatar;
  using sybl::profile_wire::kMaxAvatarDecodedBytes;
  using sybl::profile_wire::kMaxAvatarBase64Bytes;
  assert(DecodeAvatar("AQID"));
  assert(DecodeAvatar(""));
  assert(!DecodeAvatar("not base64"));
  assert(!DecodeAvatar(std::string(kMaxAvatarBase64Bytes + 4, 'A')));
  const auto just_over_avatar_limit =
      ((kMaxAvatarDecodedBytes + 1 + 2) / 3) * 4;
  assert(!DecodeAvatar(std::string(just_over_avatar_limit, 'A')));

  using sybl::profile_wire::DecodeVCard;
  const auto profile = DecodeVCard(
      "BEGIN:VCARD\nFN:Mara \xF0\x9F\x98\x80\n"
      "PHOTO;ENCODING=BASE64;TYPE=JPEG:AQID\nEND:VCARD\n");
  assert(profile && profile->display_name == "Mara \xF0\x9F\x98\x80" &&
         profile->avatar_base64 == "AQID");
  const auto windows_profile = DecodeVCard(
      "BEGIN:VCARD\r\nFN:Peer\r\n"
      "PHOTO;ENCODING=BASE64;TYPE=JPEG:AQID\r\nEND:VCARD\r\n");
  assert(windows_profile && windows_profile->display_name == "Peer" &&
         windows_profile->avatar_base64 == "AQID");
  const auto no_avatar = DecodeVCard("FN:Mara\n");
  assert(no_avatar && no_avatar->avatar_base64.empty());
  const auto ignored_property = DecodeVCard("FN:Mara\nPHOTOGRAPH:not base64\n");
  assert(ignored_property && ignored_property->avatar_base64.empty());
  const auto invalid_avatar = DecodeVCard("FN:Mara\nPHOTO:not base64\n");
  assert(invalid_avatar && invalid_avatar->display_name == "Mara" &&
         invalid_avatar->avatar_base64.empty());
  assert(!DecodeVCard(""));
  assert(!DecodeVCard(
      "FN:" + std::string(kMaxDisplayNameUtf8Bytes + 1, 'x') + "\n"));
  assert(!DecodeVCard(std::string{"FN:\xed\xa0\x80\n"}));

  assert(IsRequiredUtf8(std::string(kMaxTextCodeUnits, 'x'),
                        kMaxTextCodeUnits));
  assert(!IsRequiredUtf8(std::string(kMaxTextCodeUnits + 1, 'x'),
                         kMaxTextCodeUnits));
  assert(!IsRequiredUtf8("", kMaxTextCodeUnits));
  assert(IsOptionalUtf8("", kMaxHashCodeUnits));

  assert(CanAppendTimelineSnapshotItem(0, 1, 128));
  assert(!CanAppendTimelineSnapshotItem(kMaxTimelineSnapshotItems, 1, 1));
  assert(!CanAppendTimelineSnapshotItem(
      1, kMaxTimelineSnapshotBytes - 1, 1));
  assert(CanAppendTimelineSnapshotItem(
      1, kMaxTimelineSnapshotBytes - 3, 1));
  assert(!CanAppendTimelineSnapshotItem(
      0, 1, std::numeric_limits<std::size_t>::max()));

  {
    using namespace sybl::history_search;
    const std::string literal = R"(a.b+[c](d)? {e} ^f$ | g\h)";
    const auto pattern = LiteralPattern(literal);
    assert(pattern && std::regex_search(literal, std::regex(*pattern)));
    assert(!LiteralPattern(std::string(257, 'x')));
    assert(!LiteralPattern("a\nb"));
    assert(!LiteralPattern("\xed\xa0\x80"));
    std::map<std::string, std::string> raw{
        {"id", std::string(40, 'a')}, {"author", std::string(40, 'b')},
        {"type", "text/plain"}, {"timestamp", "1700000000"},
        {"body", "[#games] A visible message"}};
    assert(!Project(raw, true, "games"));
    const auto group_hit = Project(raw, true, "VISIBLE");
    assert(group_hit && group_hit->channel_id == "games" && group_hit->snippet == "A visible message");
    raw["sybl-room-v1"] = "clips";
    assert(!Project(raw, true, "visible"));
    raw.erase("sybl-room-v1");
    raw["body"] = "private message";
    for (const auto& invalid : std::map<std::string, std::string>{
        {"react-to", std::string(40, 'c')}, {"edit", std::string(40, 'c')},
        {"sybl-topic-v1", "unknown"}, {"timestamp", "-1"}}) {
      auto bad = raw;
      bad[invalid.first] = invalid.second;
      assert(!Project(bad, false, "private"));
    }
    raw["body"] = std::string(700, 'x') + "\xf0\x9f\x91\x8d private " + std::string(700, 'y');
    const auto long_hit = Project(raw, false, "private");
    assert(long_hit && MeasureUtf8(long_hit->snippet, 512));
    assert(long_hit->snippet.find("\xf0\x9f\x91\x8d private") != std::string::npos);
    raw["type"] = "application/data-transfer+json";
    raw["displayName"] = "[#games] visible.txt";
    const auto file_hit = Project(raw, true, "games");
    assert(file_hit && file_hit->file && file_hit->channel_id == "general");
    const std::string conversation(40, 'c');
    Request request("account", conversation, true, "games", 1);
    request.Accept("account", conversation, {raw});
    assert(!request.terminal() && !request.result());
    request.Accept("foreign", "", {});
    assert(!request.terminal());
    request.Accept("account", "", {});
    assert(request.result() && request.result()->hits.size() == 1);
    Request retired("account", conversation, true, "games", 1);
    retired.Accept("account", conversation, {raw});
    retired.Retire();
    assert(!retired.terminal() && !retired.result());
    retired.Accept("account", "", {});
    assert(retired.terminal() && !retired.result());
    Request failed("account", conversation, true, "games", 1);
    failed.Accept("account", "", {{{"sybl-search-error", "unavailable"}}});
    assert(failed.failed() && !failed.terminal());
    failed.Accept("account", "", {});
    assert(failed.terminal() && !failed.result());
    Request bounded("account", conversation, true, "games", 1);
    auto second = raw;
    second["id"] = std::string(40, 'd');
    bounded.Accept("account", conversation, {raw, second});
    bounded.Accept("account", "", {});
    assert(bounded.result() && bounded.result()->truncated && bounded.result()->hits.size() == 1);
    Request conflicting("account", conversation, true, "games", 1);
    conflicting.Accept("account", conversation, {raw});
    raw["displayName"] = "different games file";
    conflicting.Accept("account", conversation, {raw});
    assert(conflicting.failed() && !conflicting.terminal());
    for (int iteration = 0; iteration < 100; ++iteration) {
      Request racing("account", conversation, true, "games", 1);
      std::thread callback([&] {
        racing.Accept("account", conversation, {raw});
        racing.Accept("account", "", {});
      });
      racing.Retire();
      callback.join();
      assert(racing.terminal() && !racing.result());
    }
  }
  {
    using namespace sybl::history_search;
    const std::string conversation(40, 'c'), message(40, 'd');
    const MessageLoadTicket request{"account", "peer", conversation, message, 7, 3};
    const MessageLoadFacts current{"account", 7, true, 3, false};
    assert(AdmitMessageLoad(request, current, true));
    auto refused = [&](MessageLoadTicket ticket, MessageLoadFacts facts, bool can_start) {
      return !AdmitMessageLoad(ticket, facts, can_start);
    };
    auto facts = current;
    facts.account_id = "other";
    assert(refused(request, facts, true));  // wrong account
    facts = current;
    facts.account_id.clear();
    assert(refused(request, facts, true));  // no command owner
    facts = current;
    facts.account_revision = 8;
    assert(refused(request, facts, true));
    facts = current;
    facts.routing_owns = false;
    assert(refused(request, facts, true));  // conversation not owned by the peer
    for (const auto& bad : {std::string(39, 'c'), std::string(41, 'c'), std::string(40, 'C'),
                            std::string(39, 'c') + "g", std::string{}}) {
      auto ticket = request;
      ticket.conversation_id = bad;
      assert(refused(ticket, current, true));
      ticket = request;
      ticket.message_id = bad;
      assert(refused(ticket, current, true));
    }
    auto ticket = request;
    ticket.account_id.clear();
    facts = current;
    facts.account_id.clear();
    assert(refused(ticket, facts, true));
    ticket = request;
    ticket.peer_id.clear();
    assert(refused(ticket, current, true));
    facts = current;
    facts.epoch = 4;
    assert(refused(request, facts, true));  // epoch retired
    ticket = request;
    ticket.epoch = std::numeric_limits<uint64_t>::max();
    facts = current;
    facts.epoch = ticket.epoch;
    assert(refused(ticket, facts, true));  // saturated epoch
    facts = current;
    facts.restore_pending = true;
    assert(refused(request, facts, true));  // restore or activation pending
    assert(refused(request, current, false));  // registry full

    struct Returned {
      std::string id;
    };
    using Messages = std::vector<Returned>;
    assert(CompleteMessageLoad(request, "account", conversation, current, Messages{{message}}) ==
           std::optional<std::size_t>{0});
    assert(!CompleteMessageLoad(request, "account", conversation, current, Messages{}));
    assert(!CompleteMessageLoad(request, "account", conversation, current,
                                Messages{{std::string(40, 'e')}}));
    assert(!CompleteMessageLoad(request, "account", conversation, current,
                                Messages{{message}, {message}}));
    assert(!CompleteMessageLoad(request, "account", conversation, current,
                                Messages{{std::string(40, 'e')}, {message}}));
    assert(!CompleteMessageLoad(request, "other", conversation, current, Messages{{message}}));
    assert(!CompleteMessageLoad(request, "account", std::string(40, 'e'), current,
                                Messages{{message}}));
    const auto changed = [&](auto change) {
      auto later = current;
      change(later);
      return !CompleteMessageLoad(request, "account", conversation, later, Messages{{message}}) &&
             !MessageLoadCurrent(request, later);
    };
    assert(MessageLoadCurrent(request, current));
    assert(changed([](MessageLoadFacts& f) { f.account_id = "other"; }));
    assert(changed([](MessageLoadFacts& f) { f.account_id.clear(); }));
    assert(changed([](MessageLoadFacts& f) { f.routing_owns = false; }));
    assert(changed([](MessageLoadFacts& f) { f.epoch = 4; }));
    assert(changed([](MessageLoadFacts& f) { f.restore_pending = true; }));
    // A -> B -> A: the same identifiers return, but switching accounts twice
    // advanced both the owner revision and the privacy epoch.
    assert(changed([](MessageLoadFacts& f) { f.account_revision = 9; f.epoch = 5; }));
    assert(changed([](MessageLoadFacts& f) { f.account_revision = 9; }));

    std::vector<std::string> calls;
    DispatchMessageLoad(std::optional<std::size_t>{0},
                        MessageLoadHandlers{
                            [&](std::size_t index) { calls.push_back("project " + std::to_string(index)); },
                            [&] { calls.push_back("unavailable"); }});
    DispatchMessageLoad(std::nullopt,
                        MessageLoadHandlers{
                            [&](std::size_t index) { calls.push_back("project " + std::to_string(index)); },
                            [&] { calls.push_back("unavailable"); }});
    assert((calls == std::vector<std::string>{"project 0", "unavailable"}));
  }
  return 0;
}
