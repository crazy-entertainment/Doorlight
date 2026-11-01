#include "stage_registry.h"
#include <json/json.h>
#include <memory>
#include <set>

namespace sybl::stage {
namespace {
bool Valid(const Record& r) {
  if (r.path.empty() || r.path.size() > 32768 || r.path.find('\0') != std::string::npos) return false;
  if (!r.issued()) return r.recording && r.account.empty() && r.peer.empty() && r.conversation.empty();
  if (r.operation.size() != 32 || r.operation.find_first_not_of("0123456789abcdef") != std::string::npos) return false;
  for (const auto* field : {&r.account, &r.peer, &r.conversation})
    if (field->empty() || field->size() > 1024 || field->find('\0') != std::string::npos) return false;
  return true;
}
}
Registry::Registry(const std::optional<std::string>& source, Persist persist) : persist_(std::move(persist)) {
  if (!source) return;
  try {
    if (source->size() > 1024 * 1024) throw 0;
    Json::CharReaderBuilder builder;
    builder["rejectDupKeys"] = true;
    builder["failIfExtra"] = true;
    std::unique_ptr<Json::CharReader> reader(builder.newCharReader());
    Json::Value root;
    if (!reader->parse(source->data(), source->data() + source->size(), &root, nullptr) ||
        !root.isObject() || root.size() != 2 || !root["v"].isInt() || root["v"].asInt() != 1 ||
        !root["stages"].isArray() || root["stages"].size() > 256) throw 0;
    std::set<std::string> operations;
    for (const auto& value : root["stages"]) {
      if (!value.isObject() || value.size() != 6 || !value["recording"].isBool()) throw 0;
      for (const auto* key : {"path", "account", "peer", "conversation", "operation"})
        if (!value[key].isString()) throw 0;
      Record record {value["path"].asString(), value["account"].asString(), value["peer"].asString(),
                     value["conversation"].asString(), value["operation"].asString(), value["recording"].asBool()};
      if (!Valid(record) || records_.count(record.path) ||
          (record.issued() && !operations.insert(record.operation).second)) throw 0;
      records_.emplace(record.path, std::move(record));
    }
  } catch (...) {
    healthy_ = false;
    records_.clear();
  }
}
bool Registry::Save(std::map<std::string, Record> next) {
  if (!healthy_ || next.size() > 256) return false;
  Json::Value root(Json::objectValue), entries(Json::arrayValue);
  root["v"] = 1;
  for (const auto& [path, r] : next) {
    Json::Value value(Json::objectValue);
    value["path"] = r.path;
    value["account"] = r.account;
    value["peer"] = r.peer;
    value["conversation"] = r.conversation;
    value["operation"] = r.operation;
    value["recording"] = r.recording;
    entries.append(std::move(value));
  }
  root["stages"] = std::move(entries);
  Json::StreamWriterBuilder builder;
  builder["indentation"] = "";
  const auto encoded = Json::writeString(builder, root);
  if (encoded.size() > 1024 * 1024) return false;
  try {
    if (!persist_(encoded)) {
      healthy_ = false;
      return false;
    }
  } catch (...) {
    healthy_ = false;
    return false;
  }
  records_ = std::move(next);
  return true;
}
bool Registry::ReserveRecording(const std::string& path) {
  Record record {path, {}, {}, {}, {}, true};
  if (!Valid(record) || records_.count(path)) return false;
  auto next = records_;
  next.emplace(path, std::move(record));
  return Save(std::move(next));
}
bool Registry::Issue(const Record& record) {
  if (!Valid(record) || !record.issued() || Find(record.operation)) return false;
  auto next = records_;
  const auto existing = next.find(record.path);
  if (existing != next.end() && existing->second.issued()) return false;
  auto issued = record;
  if (existing != next.end()) issued.recording = existing->second.recording;
  next[record.path] = std::move(issued);
  return Save(std::move(next));
}
bool Registry::Forget(const std::string& path) {
  auto next = records_;
  if (!next.erase(path)) return healthy_;
  return Save(std::move(next));
}
bool Registry::OwnsIssued(const std::string& path) const {
  const auto it = records_.find(path);
  return !healthy_ || (it != records_.end() && it->second.issued());
}
std::optional<Record> Registry::Find(const std::string& operation) const {
  if (!healthy_ || operation.empty()) return std::nullopt;
  for (const auto& [path, record] : records_) {
    if (record.operation == operation) return record;
  }
  return std::nullopt;
}
}
