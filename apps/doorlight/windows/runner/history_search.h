#pragma once

#include <algorithm>
#include <charconv>
#include <cstdint>
#include <functional>
#include <limits>
#include <map>
#include <mutex>
#include <optional>
#include <regex>
#include <string>
#include <stdexcept>
#include <tuple>
#include <vector>

#include "timeline_wire.h"

namespace sybl::history_search {
inline bool HexId(const std::string& value, size_t size) {
  return value.size() == size && std::all_of(value.begin(), value.end(), [](char c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
  });
}
inline bool Text(const std::string& value, size_t limit, bool single_line) {
  return timeline::IsRequiredUtf8(value, limit) &&
      std::all_of(value.begin(), value.end(), [single_line](unsigned char c) {
        return c != 127 && (c >= 32 || (!single_line && (c == 9 || c == 10 || c == 13)));
      });
}
inline std::optional<std::string> LiteralPattern(const std::string& value) {
  if (!Text(value, 256, true)) return std::nullopt;
  std::string result;
  const std::string syntax = R"(\^$.|?*+()[]{})";
  for (char c : value) {
    if (syntax.find(c) != std::string::npos) result.push_back('\\');
    result.push_back(c);
  }
  return result;
}
struct Hit {
  std::string message_id, author_id, channel_id, snippet;
  int64_t timestamp_seconds = 0;
  bool file = false;
};

// Only accepts daemon-folded message fields. Request scope and current
// membership are checked by the owning bridge, never inferred from content.
inline std::optional<Hit> Project(const std::map<std::string, std::string>& raw,
                                  bool group, const std::string& literal) {
  auto get = [&](const char* key) -> std::string {
    const auto it = raw.find(key);
    return it == raw.end() ? std::string{} : it->second;
  };
  const auto pattern = LiteralPattern(literal);
  if (!pattern) return std::nullopt;
  Hit hit;
  hit.message_id = get("id");
  hit.author_id = get("author");
  if (!HexId(hit.message_id, 40) || !HexId(hit.author_id, 40) ||
      !get("react-to").empty() || !get("edit").empty()) return std::nullopt;
  const auto type = get("type");
  if (type == "application/data-transfer+json") hit.file = true;
  else if (type != "text/plain") return std::nullopt;
  const auto timestamp = get("timestamp");
  const auto parsed = std::from_chars(timestamp.data(), timestamp.data() + timestamp.size(), hit.timestamp_seconds);
  if (parsed.ec != std::errc{} || parsed.ptr != timestamp.data() + timestamp.size() ||
      hit.timestamp_seconds < 0 || hit.timestamp_seconds > 8640000000000LL) return std::nullopt;
  auto content = get(hit.file ? "displayName" : "body");
  if (!timeline::IsRequiredUtf8(content, timeline::kMaxTextCodeUnits)) return std::nullopt;
  if (group) {
    if (!get("sybl-topic-v1").empty()) return std::nullopt;
    static const std::regex room("[a-z0-9][a-z0-9-]{0,31}");
    static const std::regex prefix(R"(^\[#([a-z0-9][a-z0-9-]{0,31})\] )");
    std::smatch match;
    std::string legacy;
    if (!hit.file && std::regex_search(content, match, prefix)) {
      legacy = match[1].str();
      content.erase(0, match.length());
    }
    if (raw.count("sybl-room-v1")) {
      hit.channel_id = get("sybl-room-v1");
      if (!std::regex_match(hit.channel_id, room) || (!legacy.empty() && legacy != hit.channel_id)) return std::nullopt;
    } else hit.channel_id = legacy.empty() ? "general" : legacy;
  } else {
    if (raw.count("sybl-room-v1")) return std::nullopt;
    hit.channel_id = raw.count("sybl-topic-v1") ? get("sybl-topic-v1") : "main";
    if (hit.channel_id != "main" && !HexId(hit.channel_id, 32)) return std::nullopt;
  }
  std::smatch match;
  if (!std::regex_search(content, match, std::regex(*pattern, std::regex_constants::icase))) return std::nullopt;
  size_t start = static_cast<size_t>(match.position());
  start = start > 96 ? start - 96 : 0;
  while (start > 0 && (static_cast<unsigned char>(content[start]) & 0xc0) == 0x80) --start;
  size_t end = start, units = 0;
  while (end < content.size()) {
    const auto c = static_cast<unsigned char>(content[end]);
    const size_t bytes = c < 0x80 ? 1 : c < 0xe0 ? 2 : c < 0xf0 ? 3 : 4;
    const size_t next_units = bytes == 4 ? 2 : 1;
    if (units + next_units > 512) break;
    units += next_units;
    end += bytes;
  }
  hit.snippet = content.substr(start, end - start);
  if (!Text(hit.snippet, 512, false)) return std::nullopt;
  return hit;
}
struct Result {
  std::vector<Hit> hits;
  bool truncated = false;
};

// The bridge correlates the native request ID first. Account/privacy retirement
// may race callback processing, so the private payload has its own mutex.
// Retirement/error never substitutes for the daemon's empty terminal event.
class Request {
 public:
  Request(std::string account, std::string conversation, bool group,
          std::string literal, size_t limit)
      : account_(std::move(account)), conversation_(std::move(conversation)),
        group_(group), literal_(std::move(literal)), limit_(limit) {
    if (account_.empty() || !HexId(conversation_, 40) || !LiteralPattern(literal_) ||
        limit_ == 0 || limit_ > 200) throw std::invalid_argument("Invalid search request");
  }
  void Accept(const std::string& account, const std::string& conversation,
              const std::vector<std::map<std::string, std::string>>& raw) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (terminal_ || account != account_ ||
        (!conversation.empty() && conversation != conversation_)) return;
    if (conversation.empty()) {
      if (raw.empty()) {
        terminal_ = true;
        literal_.clear();
      } else Fail();
      return;
    }
    if (retired_ || failed_) return;
    if (raw.size() > limit_ + 1) { Fail(); return; }
    truncated_ = truncated_ || raw.size() > limit_;
    try {
      for (const auto& fields : raw) {
        const auto hit = Project(fields, group_, literal_);
        if (!hit) continue;
        const auto prior = std::find_if(hits_.begin(), hits_.end(), [&](const Hit& old) {
          return old.message_id == hit->message_id;
        });
        if (prior != hits_.end()) {
          if (std::tie(prior->author_id, prior->channel_id, prior->snippet, prior->timestamp_seconds, prior->file) !=
              std::tie(hit->author_id, hit->channel_id, hit->snippet, hit->timestamp_seconds, hit->file)) {
            Fail(); return;
          }
        } else if (hits_.size() == limit_) truncated_ = true;
        else hits_.push_back(*hit);
      }
    } catch (...) { Fail(); }
  }
  void Retire() {
    std::lock_guard<std::mutex> lock(mutex_);
    retired_ = true; literal_.clear(); hits_.clear();
  }
  bool terminal() const { std::lock_guard<std::mutex> lock(mutex_); return terminal_; }
  bool failed() const { std::lock_guard<std::mutex> lock(mutex_); return failed_; }
  std::optional<Result> result() const {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!terminal_ || retired_ || failed_) return std::nullopt;
    return Result{hits_, truncated_};
  }

 private:
  mutable std::mutex mutex_;
  void Fail() { failed_ = true; literal_.clear(); hits_.clear(); }
  std::string account_, conversation_;
  bool group_;
  std::string literal_;
  size_t limit_;
  bool retired_ = false, terminal_ = false, failed_ = false, truncated_ = false;
  std::vector<Hit> hits_;
};
// One selected result's fresh message (loadSearchMessage). The bridge samples
// the facts; admission and completion are decided only here. The ticket holds
// the request plus the owner revision and privacy epoch captured at admission.
struct MessageLoadTicket {
  std::string account_id, peer_id, conversation_id, message_id;
  uint64_t account_revision = 0, epoch = 0;
};
struct MessageLoadFacts {
  std::string account_id;  // current command owner; empty when there is none
  uint64_t account_revision = 0;
  bool routing_owns = false;  // routing owns (ticket peer, ticket conversation)
  uint64_t epoch = 0;
  bool restore_pending = false;  // identity activation pending or restore blocked
};
inline bool MessageLoadCurrent(const MessageLoadTicket& request, const MessageLoadFacts& facts) {
  return !request.account_id.empty() && facts.account_id == request.account_id &&
      facts.account_revision == request.account_revision && facts.routing_owns &&
      facts.epoch == request.epoch && !facts.restore_pending;
}
inline bool AdmitMessageLoad(const MessageLoadTicket& request, const MessageLoadFacts& facts,
                             bool registry_can_start) {
  return !request.peer_id.empty() && HexId(request.conversation_id, 40) &&
      HexId(request.message_id, 40) && request.epoch != std::numeric_limits<uint64_t>::max() &&
      MessageLoadCurrent(request, facts) && registry_can_start;
}
// The index of the one returned message to project, or nullopt for unavailable.
// The ids are read from the daemon's own answer, never supplied separately.
template <class Message>
std::optional<std::size_t> CompleteMessageLoad(const MessageLoadTicket& request,
                                               const std::string& account_id,
                                               const std::string& conversation_id,
                                               const MessageLoadFacts& facts,
                                               const std::vector<Message>& messages) {
  if (account_id != request.account_id || conversation_id != request.conversation_id ||
      !MessageLoadCurrent(request, facts) || messages.size() != 1 ||
      messages.front().id != request.message_id) return std::nullopt;
  return 0;
}
struct MessageLoadHandlers {
  std::function<void(std::size_t)> project;
  std::function<void()> unavailable;
};
inline void DispatchMessageLoad(const std::optional<std::size_t>& decision,
                                const MessageLoadHandlers& handlers) {
  if (decision) handlers.project(*decision);
  else handlers.unavailable();
}
}  // namespace sybl::history_search
