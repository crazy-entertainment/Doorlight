#include "identity_restore.h"

#define NOMINMAX
#include <windows.h>
#include <bcrypt.h>
#include <shlobj.h>
#include "uat_profile.h"
#include <json/json.h>

#include <algorithm>
#include <array>
#include <set>
#include <tuple>
#include <vector>

#include "archive_secret_store.h"
#include "timeline_wire.h"
#include "win32_dpapi.h"

namespace sybl::identity_restore {
namespace {

constexpr size_t kMaxPendingBytes = 1024 * 1024;
constexpr size_t kMaxPreferencesBytes = 16 * 1024 * 1024;
constexpr char kPurpose[] = "identity-restore-v1";

struct Handle {
  HANDLE value = INVALID_HANDLE_VALUE;
  ~Handle() { if (value != INVALID_HANDLE_VALUE) CloseHandle(value); }
};

bool HasComment(const std::string& bytes) {
  bool quoted = false;
  bool escaped = false;
  for (const char ch : bytes) {
    if (quoted) {
      if (escaped) escaped = false;
      else if (ch == '\\') escaped = true;
      else if (ch == '"') quoted = false;
    } else if (ch == '"') quoted = true;
    else if (ch == '/') return true;
  }
  return false;
}

std::optional<Json::Value> Object(const std::string& bytes, size_t limit) {
  if (bytes.empty() || bytes.size() > limit || HasComment(bytes) ||
      !timeline::MeasureUtf8(bytes, limit)) return std::nullopt;
  try {
    Json::CharReaderBuilder builder;
    Json::CharReaderBuilder::strictMode(&builder.settings_);
    builder["allowComments"] = false;
    builder["collectComments"] = false;
    builder["failIfExtra"] = true;
    builder["rejectDupKeys"] = true;
    builder["stackLimit"] = 20;
    const std::unique_ptr<Json::CharReader> reader(builder.newCharReader());
    Json::Value root;
    std::string errors;
    if (!reader || !reader->parse(bytes.data(), bytes.data() + bytes.size(), &root, &errors) ||
        !root.isObject()) return std::nullopt;
    return root;
  } catch (...) { return std::nullopt; }
}

std::string Encode(const Json::Value& value) {
  Json::StreamWriterBuilder writer;
  writer["indentation"] = "";
  writer["emitUTF8"] = true;
  return Json::writeString(writer, value);
}

bool OpaqueId(const std::string& id, bool allow_empty = false) {
  return (allow_empty && id.empty()) ||
      (!id.empty() && id.size() <= 1024 && id.find('\0') == std::string::npos &&
       timeline::MeasureUtf8(id, 1024).has_value());
}

// Match FriendPreferenceScope: a nonempty, untrimmed owner of at most 128
// UTF-16 units, with no ASCII controls. Do not silently normalize ownership.
bool CanonicalFriendAccount(const std::string& value) {
  const auto measure = timeline::MeasureUtf8(value, 128);
  if (value.empty() || !measure || std::any_of(value.begin(), value.end(),
      [](unsigned char c) { return c < 32 || c == 127; })) return false;
  std::wstring wide(measure->utf16_code_units, L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), wide.data(), static_cast<int>(wide.size())) !=
      static_cast<int>(wide.size())) return false;
  const auto whitespace = [](wchar_t c) {
    return c == 0x20 || c == 0x85 || c == 0xa0 || c == 0x1680 ||
        (c >= 0x2000 && c <= 0x200a) || c == 0x2028 || c == 0x2029 ||
        c == 0x202f || c == 0x205f || c == 0x3000 || c == 0xfeff;
  };
  return !whitespace(wide.front()) && !whitespace(wide.back());
}

std::optional<std::string> Read(HANDLE file, size_t limit) {
  LARGE_INTEGER size{};
  if (!GetFileSizeEx(file, &size) || size.QuadPart <= 0 ||
      size.QuadPart > static_cast<LONGLONG>(limit)) return std::nullopt;
  std::string bytes(static_cast<size_t>(size.QuadPart), '\0');
  DWORD read = 0;
  if (!ReadFile(file, bytes.data(), static_cast<DWORD>(bytes.size()), &read, nullptr) ||
      read != bytes.size()) return std::nullopt;
  return bytes;
}

bool WriteDurably(const std::filesystem::path& path, const std::string& bytes) {
  if (path.empty() || bytes.empty() || bytes.size() > kMaxPendingBytes) return false;
  const auto temporary = path.wstring() + L".tmp";
  Handle file;
  file.value = CreateFileW(temporary.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                          FILE_ATTRIBUTE_HIDDEN | FILE_ATTRIBUTE_NOT_CONTENT_INDEXED, nullptr);
  if (file.value == INVALID_HANDLE_VALUE) return false;
  DWORD written = 0;
  const bool wrote = WriteFile(file.value, bytes.data(), static_cast<DWORD>(bytes.size()),
                              &written, nullptr) && written == bytes.size() && FlushFileBuffers(file.value);
  CloseHandle(file.value);
  file.value = INVALID_HANDLE_VALUE;
  if (wrote && MoveFileExW(temporary.c_str(), path.c_str(),
                          MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) return true;
  DeleteFileW(temporary.c_str());
  return false;
}

}  // namespace

std::optional<std::string> StampBackupSettings(
    const std::string& document, const std::string& account_id) {
  if (!OpaqueId(account_id)) return std::nullopt;
  auto root = Object(document, kMaxSettingsBytes);
  if (!root) return std::nullopt;
  Json::Value metadata(Json::objectValue);
  metadata["version"] = 1;
  metadata["sourceAccountId"] = account_id;
  (*root)["syblBackup"] = std::move(metadata);
  auto result = Encode(*root);
  return result.size() <= kMaxSettingsBytes ? std::optional<std::string>(std::move(result)) : std::nullopt;
}

std::string BackupSourceAccount(const std::string& document) {
  const auto root = Object(document, kMaxSettingsBytes);
  if (!root) return {};
  const auto& metadata = (*root)["syblBackup"];
  if (!metadata.isObject() || metadata.size() != 2 ||
      metadata["version"].type() != Json::intValue || !metadata["version"].isInt() || metadata["version"].asInt() != 1 ||
      !metadata["sourceAccountId"].isString()) return {};
  const auto id = metadata["sourceAccountId"].asString();
  return OpaqueId(id) ? id : std::string{};
}

bool IsNormalizedSettings(const std::string& document) {
  const auto root = Object(document, kMaxSettingsBytes);
  if (!(root && (*root)["schemaVersion"].type() == Json::intValue && (*root)["schemaVersion"].isInt() &&
      ((*root)["schemaVersion"].asInt() >= 16 && (*root)["schemaVersion"].asInt() <= 22) && (*root)["microphone"].isObject() &&
      (*root)["microphone"]["reviewRequired"].isBool() && (*root)["appLock"].isObject() &&
      (*root)["appLock"]["enabled"].isBool() &&
      (*root)["notifications"]["showMessage"].isBool() &&
      (*root)["notifications"]["hologramPresentationEnabled"].isBool())) return false;
  if ((*root)["schemaVersion"].asInt() >= 17) {
    const auto& friends = (*root)["friendPreferences"];
    if (!(*root)["notifications"]["messageAlertsEnabled"].isBool() ||
        !friends.isObject() || !friends["reviewRequired"].isBool() ||
        !friends["overrides"].isArray() || friends["overrides"].size() > 256) return false;
    std::set<std::pair<std::string, std::string>> owners;
    for (const auto& entry : friends["overrides"]) {
      if (!entry.isObject() || !entry["accountId"].isString() ||
          !entry["peerId"].isString() || !entry["holograms"].isString() ||
          !entry["messageAlerts"].isString()) return false;
      const auto account = entry["accountId"].asString();
      auto peer = entry["peerId"].asString();
      if (!CanonicalFriendAccount(account) || peer.size() != 40) return false;
      for (auto& ch : peer) {
        if (ch >= 'A' && ch <= 'F') ch = static_cast<char>(ch - 'A' + 'a');
        if (!((ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f'))) return false;
      }
      const auto holograms = entry["holograms"].asString();
      const auto alerts = entry["messageAlerts"].asString();
      if ((holograms != "useGlobalDefault" && holograms != "allow" && holograms != "block") ||
          (alerts != "useGlobalDefault" && alerts != "mute") ||
          !owners.emplace(account, peer).second) return false;
    }
  }
  const auto mode = [](const Json::Value& value) {
    return value.isString() && (value.asString() == "pushToTalk" ||
        value.asString() == "open" || value.asString() == "voiceActivated");
  };
  const auto& microphone = (*root)["microphone"];
  if (!mode(microphone["globalDefault"]) ||
      !microphone["conversationOverrides"].isArray()) return false;
  std::set<std::tuple<std::string, std::string, std::string, std::string>> scopes;
  for (const auto& entry : microphone["conversationOverrides"]) {
    if (!entry.isObject() || !mode(entry["mode"])) return false;
    for (const auto* key : {"accountId", "peerId", "conversationId"})
      if (!entry[key].isString() || !OpaqueId(entry[key].asString())) return false;
    const auto peer = entry["peerId"].asString();
    if (entry.isMember("kind") && !entry["kind"].isString()) return false;
    const auto kind = entry.isMember("kind") ? entry["kind"].asString() :
        (peer.rfind("group:", 0) == 0 ? "group" : "direct");
    if ((kind != "direct" && kind != "group") || !scopes.emplace(
        entry["accountId"].asString(), peer, entry["conversationId"].asString(), kind).second)
      return false;
  }
  return true;
}

std::optional<std::string> RandomToken() {
  std::array<unsigned char, 32> bytes{};
  if (!BCRYPT_SUCCESS(BCryptGenRandom(nullptr, bytes.data(), static_cast<ULONG>(bytes.size()),
                                    BCRYPT_USE_SYSTEM_PREFERRED_RNG))) return std::nullopt;
  constexpr char hex[] = "0123456789abcdef";
  std::string result(bytes.size() * 2, '\0');
  for (size_t i = 0; i < bytes.size(); ++i) {
    result[2 * i] = hex[bytes[i] >> 4];
    result[2 * i + 1] = hex[bytes[i] & 15];
  }
  SecureZeroMemory(bytes.data(), bytes.size());
  return result;
}

std::optional<std::string> EncodePending(const PendingRestore& value) {
  const auto canonical_id = [](const std::string& id) {
    return id.size() == 40 && std::all_of(id.begin(), id.end(), [](char ch) {
      return (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f');
    });
  };
  if (!archive::IsValidArchiveSecret(value.token) || !OpaqueId(value.account_id) ||
      !OpaqueId(value.previous_account_id, true) || value.settings_document.size() > kMaxSettingsBytes ||
      value.normalized_document.size() > kMaxSettingsBytes ||
      (value.settings_already_normalized && !IsNormalizedSettings(value.settings_document)) ||
      (value.phase == Phase::kPrivacyCommitted && !IsNormalizedSettings(value.normalized_document)) ||
      (!value.expected_jami_id.empty() && !canonical_id(value.expected_jami_id)) ||
      (value.pairing_operation && !value.expected_jami_id.empty()))
    return std::nullopt;
  if ((!value.pairing_operation && value.pairing_acknowledged) ||
      (value.pairing_operation && value.phase == Phase::kRollingBack) ||
      (value.pairing_operation &&
       ((*value.pairing_operation != 0 && (*value.pairing_operation < 100000 || *value.pairing_operation > 999999)) ||
        (value.phase != Phase::kImporting && !value.pairing_acknowledged) ||
        (value.pairing_acknowledged && (*value.pairing_operation == 0 || value.phase == Phase::kImporting ||
         !value.settings_already_normalized || !IsNormalizedSettings(value.normalized_document))))))
    return std::nullopt;
  Json::Value root(Json::objectValue);
  root["version"] = value.pairing_operation ? 2 : value.expected_jami_id.empty() ? 1 : 3;
  if (value.pairing_operation) {
    root["pairingOperation"] = *value.pairing_operation;
    root["pairingAcknowledged"] = value.pairing_acknowledged;
  }
  if (!value.expected_jami_id.empty()) root["expectedJamiId"] = value.expected_jami_id;
  root["token"] = value.token;
  root["accountId"] = value.account_id;
  root["previousAccountId"] = value.previous_account_id;
  root["phase"] = value.phase == Phase::kImporting ? "importing" :
      value.phase == Phase::kPrepared ? "prepared" :
      value.phase == Phase::kPrivacyCommitted ? "privacyCommitted" : "rollingBack";
  root["appearOffline"] = value.appear_offline;
  root["settingsDocument"] = value.settings_document;
  root["normalizedDocument"] = value.normalized_document;
  Json::Value network(Json::objectValue);
  if (value.network_details.size() != 6) return std::nullopt;
  for (const char* key : {"connectionProfile", "dhtBootstrap", "turnServer", "turnRealm", "turnUser", "turnPassword"}) {
    const auto entry = value.network_details.find(key);
    if (entry == value.network_details.end() || entry->second.size() > 4096 ||
        !timeline::MeasureUtf8(entry->second, 4096)) return std::nullopt;
    network[key] = entry->second;
  }
  root["network"] = std::move(network);
  root["settingsAlreadyNormalized"] = value.settings_already_normalized;
  const auto encoded = Encode(root);
  return encoded.size() <= kMaxPendingBytes - 4096 ? std::optional<std::string>(encoded) : std::nullopt;
}

std::optional<PendingRestore> DecodePending(const std::string& bytes) {
  const auto root = Object(bytes, kMaxPendingBytes);
  if (!root || (*root)["version"].type() != Json::intValue || !(*root)["version"].isInt() ||
      (((*root)["version"].asInt() != 1 || root->size() != 10) &&
       ((*root)["version"].asInt() != 2 || root->size() != 12) &&
       ((*root)["version"].asInt() != 3 || root->size() != 11)) || !(*root)["token"].isString() ||
      !(*root)["accountId"].isString() || !(*root)["previousAccountId"].isString() ||
      !(*root)["phase"].isString() || !(*root)["appearOffline"].isBool() ||
      !(*root)["settingsDocument"].isString() || !(*root)["normalizedDocument"].isString() ||
      !(*root)["network"].isObject() || !(*root)["settingsAlreadyNormalized"].isBool())
    return std::nullopt;
  const auto phase = (*root)["phase"].asString();
  if (phase != "importing" && phase != "prepared" && phase != "privacyCommitted" && phase != "rollingBack")
    return std::nullopt;
  PendingRestore value{(*root)["token"].asString(), (*root)["accountId"].asString(),
      (*root)["previousAccountId"].asString(), phase == "importing" ? Phase::kImporting :
          phase == "prepared" ? Phase::kPrepared :
          phase == "privacyCommitted" ? Phase::kPrivacyCommitted : Phase::kRollingBack,
      (*root)["appearOffline"].asBool(), (*root)["settingsDocument"].asString(),
      (*root)["normalizedDocument"].asString()};
  for (const auto& key : (*root)["network"].getMemberNames()) {
    if (!(*root)["network"][key].isString()) return std::nullopt;
    value.network_details[key] = (*root)["network"][key].asString();
  }
  value.settings_already_normalized = (*root)["settingsAlreadyNormalized"].asBool();
  if ((*root)["version"].asInt() == 3) {
    if (!(*root)["expectedJamiId"].isString()) return std::nullopt;
    value.expected_jami_id = (*root)["expectedJamiId"].asString();
    if (value.expected_jami_id.empty()) return std::nullopt;
  } else if (root->isMember("expectedJamiId")) return std::nullopt;
  if ((*root)["version"].asInt() == 2) {
    const auto& operation = (*root)["pairingOperation"];
    if (!operation.isIntegral() || !operation.isUInt() || !(*root)["pairingAcknowledged"].isBool())
      return std::nullopt;
    value.pairing_operation = operation.asUInt();
    value.pairing_acknowledged = (*root)["pairingAcknowledged"].asBool();
  } else if (root->isMember("pairingOperation") || root->isMember("pairingAcknowledged")) return std::nullopt;
  if (!value.pairing_operation) value.appear_offline = true;
  return EncodePending(value) ? std::optional<PendingRestore>(std::move(value)) : std::nullopt;
}

bool CanAdoptAccount(const std::string& account_id,
                     const std::optional<PendingRestore>& pending, bool unreadable_marker) {
  return !account_id.empty() && !unreadable_marker && (!pending || pending->account_id != account_id);
}

bool CanDiscard(const PendingRestore& pending, const std::string& selected_account,
                const std::vector<std::string>& accounts) {
  // Archive imports reserve exactly 16 random hex digits before creating an account.
  return !pending.pairing_operation && pending.account_id.size() == 16 &&
      std::all_of(pending.account_id.begin(), pending.account_id.end(), [](char c) {
        return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
      }) && pending.account_id != pending.previous_account_id &&
      pending.account_id != selected_account &&
      (selected_account.empty() || selected_account == pending.previous_account_id) &&
      std::all_of(accounts.begin(), accounts.end(), [&](const std::string& account) {
        return account == pending.account_id || account == pending.previous_account_id;
      }) &&
      archive::IsValidArchiveSecret(pending.token);
}

PendingRestoreStore::PendingRestoreStore(std::filesystem::path path) : path_(std::move(path)) {}

std::optional<std::filesystem::path> PendingRestoreStore::DefaultPath() {
  const auto secret = archive::ArchiveSecretStore::DefaultPath();
  if (!secret) return std::nullopt;
  return secret->parent_path() / L"identity_restore.dpapi";
}

namespace {
LoadResult LoadPendingUnlocked(const std::filesystem::path& path) {
  if (path.empty()) return {};
  Handle file;
  file.value = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                          OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file.value == INVALID_HANDLE_VALUE) {
    const DWORD error = GetLastError();
    return {error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND ? LoadStatus::kAbsent :
        LoadStatus::kError, std::nullopt};
  }
  const auto bytes = Read(file.value, kMaxPendingBytes);
  if (!bytes) return {};
  auto clear = win32::Win32DpapiProtector(kPurpose).Unprotect(*bytes);
  if (!clear) return {};
  auto record = DecodePending(*clear);
  SecureZeroMemory(clear->data(), clear->size());
  return record ? LoadResult{LoadStatus::kLoaded, std::move(record)} : LoadResult{};
}
}  // namespace

LoadResult PendingRestoreStore::Load() const {
  if (path_.empty()) return {};
  Handle lock;
  lock.value = CreateFileW((path_.wstring() + L".lock").c_str(), GENERIC_READ | GENERIC_WRITE,
                          0, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_HIDDEN, nullptr);
  return lock.value != INVALID_HANDLE_VALUE ? LoadPendingUnlocked(path_) : LoadResult{};
}

bool PendingRestoreStore::Save(const PendingRestore& value, bool disabled_reprepare) const {
  if (path_.empty()) return false;
  Handle lock;
  lock.value = CreateFileW((path_.wstring() + L".lock").c_str(), GENERIC_READ | GENERIC_WRITE,
                          0, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_HIDDEN, nullptr);
  if (lock.value == INVALID_HANDLE_VALUE) return false;
  const auto existing = LoadPendingUnlocked(path_);
  if (existing.value && value.phase == Phase::kRollingBack) {
    auto expected = *existing.value;
    expected.phase = Phase::kRollingBack;
    if (EncodePending(expected) != EncodePending(value)) return false;
  }
  const bool reprepare = disabled_reprepare && existing.value &&
      existing.value->phase == Phase::kPrivacyCommitted && value.phase == Phase::kPrepared &&
      value.settings_already_normalized &&
      (value.pairing_operation ? (value.pairing_acknowledged &&
       value.normalized_document == existing.value->normalized_document) : value.normalized_document.empty()) &&
      value.settings_document == existing.value->normalized_document &&
      value.previous_account_id == existing.value->previous_account_id &&
      value.network_details == existing.value->network_details &&
      value.appear_offline == existing.value->appear_offline;
  if (existing.status == LoadStatus::kError ||
      (existing.value && (existing.value->token != value.token ||
          existing.value->account_id != value.account_id ||
          existing.value->pairing_operation.has_value() != value.pairing_operation.has_value() ||
          (existing.value->pairing_operation && *existing.value->pairing_operation != 0 &&
           existing.value->pairing_operation != value.pairing_operation) ||
          (existing.value->pairing_acknowledged && !value.pairing_acknowledged) ||
          (static_cast<int>(existing.value->phase) > static_cast<int>(value.phase) && !reprepare)))) return false;
  auto clear = EncodePending(value);
  if (!clear) return false;
  const auto sealed = win32::Win32DpapiProtector(kPurpose).Protect(*clear);
  SecureZeroMemory(clear->data(), clear->size());
  return sealed && WriteDurably(path_, *sealed);
}

bool PendingRestoreStore::Clear(const std::string& expected_token) const {
  if (path_.empty() || expected_token.empty()) return false;
  Handle lock;
  lock.value = CreateFileW((path_.wstring() + L".lock").c_str(), GENERIC_READ | GENERIC_WRITE,
                          0, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_HIDDEN, nullptr);
  if (lock.value == INVALID_HANDLE_VALUE) return false;
  const auto existing = LoadPendingUnlocked(path_);
  if (existing.status == LoadStatus::kAbsent) return true;
  return existing.value && existing.value->token == expected_token && DeleteFileW(path_.c_str());
}

CanonicalSettingsLease::CanonicalSettingsLease(void* handle) : handle_(handle) {}
CanonicalSettingsLease::~CanonicalSettingsLease() { CloseHandle(handle_); }

bool CanonicalSettingsLease::AllowsFriendHolograms(const std::string& account,
                                                const std::string& peer) const {
  const auto root = Object(document_, kMaxSettingsBytes);
  if (!root || appear_offline_ || account.empty() || peer.size() != 40 ||
      !(*root)["notifications"]["showMessage"].asBool()) return false;
  const auto& friends = (*root)["friendPreferences"];
  if ((*root)["schemaVersion"].asInt() >= 17) {
    if (friends["reviewRequired"].asBool()) return false;
    for (const auto& entry : friends["overrides"]) {
      auto canonical = entry["peerId"].asString();
      for (auto& ch : canonical) if (ch >= 'A' && ch <= 'F') ch = static_cast<char>(ch - 'A' + 'a');
      if (entry["accountId"].asString() != account || canonical != peer) continue;
      if (entry["holograms"].asString() == "allow") return true;
      if (entry["holograms"].asString() == "block") return false;
    }
  }
  return (*root)["notifications"]["hologramPresentationEnabled"].asBool();
}

std::unique_ptr<CanonicalSettingsLease> CanonicalSettingsLease::Acquire(
    const std::filesystem::path& path, const std::string& document) {
  if (path.empty() || !IsNormalizedSettings(document)) return {};
  auto lease = AcquireCurrent(path);
  if (!lease || lease->document_ != document) return {};
  return lease;
}

std::unique_ptr<CanonicalSettingsLease> CanonicalSettingsLease::AcquireCurrent(
    const std::filesystem::path& path, bool require_durable) {
  if (path.empty()) return {};
  Handle file;
  // No write or delete sharing: the exact checked bytes remain stable through
  // privacy commit and native account activation, including Dart cache writes.
  // Live presentation reads keep the same exclusion boundary, but must not
  // flush the preferences file on every animation frame. Restore still flushes.
  file.value = CreateFileW(path.c_str(), GENERIC_READ | (require_durable ? GENERIC_WRITE : 0), FILE_SHARE_READ,
                          nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file.value == INVALID_HANDLE_VALUE) return {};
  const auto bytes = Read(file.value, kMaxPreferencesBytes);
  const auto root = bytes ? Object(*bytes, kMaxPreferencesBytes) : std::nullopt;
  if (!root || !(*root)["flutter.appSettings"].isString()) return {};
  const auto document = (*root)["flutter.appSettings"].asString();
  const auto normalized = Object(document, kMaxSettingsBytes);
  if (!IsNormalizedSettings(document) ||
      !(*root)["flutter.appLockEnabled.v1"].isBool() || !normalized ||
      (*root)["flutter.appLockEnabled.v1"].asBool() != (*normalized)["appLock"]["enabled"].asBool() ||
      (root->isMember("flutter.appearOffline") && !(*root)["flutter.appearOffline"].isBool()) ||
      (require_durable && !FlushFileBuffers(file.value))) return {};
  auto lease = std::unique_ptr<CanonicalSettingsLease>(new CanonicalSettingsLease(file.value));
  lease->document_ = document;
  lease->appear_offline_ = (*root)["flutter.appearOffline"].isBool() && (*root)["flutter.appearOffline"].asBool();
  file.value = INVALID_HANDLE_VALUE;
  return lease;
}

std::optional<std::filesystem::path> CanonicalSettingsLease::DefaultPath() {
  // Storage identity is independent of executable branding. Match the pinned
  // shared_preferences_windows adapter for both restore and live policy reads.
  // Do not migrate, probe another product directory, or create a fallback root.
  PWSTR raw = nullptr;
  const HRESULT result = sybl::uat::KnownFolderPath(FOLDERID_RoamingAppData, KF_FLAG_DEFAULT, nullptr, &raw);
  const std::unique_ptr<wchar_t, decltype(&CoTaskMemFree)> directory(raw, CoTaskMemFree);
  if (FAILED(result) || !directory || *directory.get() == L'\0') return std::nullopt;
  return std::filesystem::path(directory.get()) / L"app.sybl" / L"sybl" / L"shared_preferences.json";
}

bool Finalize(PendingRestore& pending, const std::string& account_id,
              const std::string& token, const std::string& document,
              const FinalizeCallbacks& callbacks) {
  try {
    if ((pending.phase != Phase::kPrepared && pending.phase != Phase::kPrivacyCommitted) ||
        pending.account_id != account_id || pending.token != token ||
        (pending.pairing_operation && (!pending.pairing_acknowledged || *pending.pairing_operation == 0 ||
         !pending.settings_already_normalized || pending.normalized_document != document)) ||
        !IsNormalizedSettings(document) ||
        (!pending.normalized_document.empty() && pending.normalized_document != document) ||
        !callbacks.owns_operation() || !callbacks.lock_and_flush_settings(document) ||
        !callbacks.owns_operation()) return false;
    auto committed = pending;
    committed.phase = Phase::kPrivacyCommitted;
    committed.normalized_document = document;
    if (!callbacks.save_pending(committed)) return false;
    pending = std::move(committed);
    return callbacks.owns_operation() && callbacks.enable_and_select(!pending.appear_offline) &&
        callbacks.clear_pending();
  } catch (...) { return false; }
}

bool Rollback(PendingRestore& pending, const std::string& selected_account,
              const std::vector<std::string>& accounts,
              const RollbackCallbacks& callbacks) {
  try {
    if (!CanDiscard(pending, selected_account, accounts) || !callbacks.owns_operation()) return false;
    auto rollback = pending;
    rollback.phase = Phase::kRollingBack;
    if (!callbacks.save_pending(rollback)) return false;
    pending = std::move(rollback);
    return callbacks.owns_operation() && callbacks.remove_and_confirm_absent() &&
        callbacks.owns_operation() && callbacks.clear_journals();
  } catch (...) { return false; }
}

}  // namespace sybl::identity_restore
