#pragma once
#include <functional>
#include <map>
#include <optional>
#include <string>

namespace sybl::stage {
struct Record {
  std::string path, account, peer, conversation, operation;
  bool recording = false;
  bool issued() const { return !operation.empty(); }
};
// Call under the owner's serialization lock. A failed durable mutation disables
// further mutations: its on-disk outcome may be unknown.
class Registry {
 public:
  using Persist = std::function<bool(const std::string&)>;
  Registry(const std::optional<std::string>& source, Persist persist);
  bool healthy() const { return healthy_; }
  bool ReserveRecording(const std::string& path);
  bool Issue(const Record& record);
  bool Forget(const std::string& path);
  bool OwnsIssued(const std::string& path) const;
  std::optional<Record> Find(const std::string& operation) const;
  const std::map<std::string, Record>& records() const { return records_; }
 private:
  bool Save(std::map<std::string, Record> next);
  bool healthy_ = true;
  Persist persist_;
  std::map<std::string, Record> records_;
};
}
