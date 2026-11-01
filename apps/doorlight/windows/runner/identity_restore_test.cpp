#ifdef NDEBUG
#undef NDEBUG
#endif

#include "identity_restore.h"

#define NOMINMAX
#include <windows.h>
#include <shlobj.h>

#include <cassert>
#include <algorithm>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
namespace restore = sybl::identity_restore;
const std::string kSettings = R"({"schemaVersion":16,"microphone":{"globalDefault":"pushToTalk","conversationOverrides":[],"reviewRequired":false},"appLock":{"enabled":true},"notifications":{"showMessage":true,"hologramPresentationEnabled":true}})";

restore::PendingRestore Prepared() {
  restore::PendingRestore pending;
  pending.token = std::string(64, 'a');
  pending.account_id = "imported";
  pending.previous_account_id = "previous";
  pending.phase = restore::Phase::kPrepared;
  pending.settings_document = R"({"schemaVersion":14,"microphone":{"globalDefault":"ptt","conversationOverrides":[]}})";
  pending.network_details = {{"connectionProfile", "strict"}, {"dhtBootstrap", "bootstrap.invalid"},
      {"turnServer", "turn.invalid"}, {"turnRealm", "fixture"}, {"turnUser", "synthetic"}, {"turnPassword", "fixture-only"}};
  return pending;
}

void CanonicalPathPreservesInstalledStorageIdentity() {
  // Resolve only the known folder. Never open or modify the owner's preferences.
  PWSTR roaming = nullptr;
  assert(SUCCEEDED(SHGetKnownFolderPath(FOLDERID_RoamingAppData, KF_FLAG_DEFAULT, nullptr, &roaming)));
  assert(roaming);
  const auto expected = std::filesystem::path(roaming) / L"app.sybl" / L"sybl" / L"shared_preferences.json";
  CoTaskMemFree(roaming);
  const auto actual = restore::CanonicalSettingsLease::DefaultPath();
  assert(actual && *actual == expected);
}

void PreparedIdentityRequiresInactivity() {
  for (const auto* enabled : {"", "true", "false", "FALSE"}) {
    for (const auto* active : {"", "true", "false", "FALSE"}) {
      assert(restore::PreparedIdentityClosed(enabled, active) ==
          (std::string(enabled) == "false" && std::string(active) == "false"));
    }
  }
}

void ExportOwner() {
  const auto stamped = restore::StampBackupSettings(Prepared().settings_document, "native-owner");
  assert(stamped.has_value());
  assert(stamped->find("\"sourceAccountId\":\"native-owner\"") != std::string::npos);
  assert(restore::BackupSourceAccount(*stamped) == "native-owner");
  assert(stamped->find("\"globalDefault\":\"ptt\"") != std::string::npos);
  const auto replaced = restore::StampBackupSettings(*stamped, "replacement-owner");
  assert(replaced && restore::BackupSourceAccount(*replaced) == "replacement-owner");
  assert(replaced->find("native-owner") == std::string::npos);
}

void ExportRejectsMalformedAndOversized() {
  for (const auto& malformed : std::vector<std::string>{"", "[]", "null", "{} {}", "{/*comment*/}",
      "{\"same\":1,\"same\":2}", std::string(restore::kMaxSettingsBytes + 1, ' '),
      std::string(30, '[') + "0" + std::string(30, ']'), std::string("{\"x\":\"") + char(0xff) + "\"}"})
    assert(!restore::StampBackupSettings(malformed, "owner"));
  const std::string atLimit = "{\"x\":\"" + std::string(restore::kMaxSettingsBytes - 8, 'a') + "\"}";
  assert(atLimit.size() == restore::kMaxSettingsBytes);
  assert(!restore::StampBackupSettings(atLimit, "owner"));
  assert(!restore::StampBackupSettings("{}", ""));
  assert(restore::BackupSourceAccount("{}").empty());
  assert(restore::BackupSourceAccount(R"({"syblBackup":{"version":1.0,"sourceAccountId":"owner"}})").empty());
  assert(restore::BackupSourceAccount(R"({"syblBackup":{"version":1,"sourceAccountId":"owner","extra":true}})").empty());
  assert(restore::BackupSourceAccount(R"({"syblBackup":{"version":9223372036854775807,"sourceAccountId":"owner"}})").empty());
}

void MarkerRetainsEveryPhaseAndOptions() {
  auto legacy = Prepared();
  legacy.appear_offline = false;
  const auto legacyBytes = restore::EncodePending(legacy);
  assert(legacyBytes);
  const auto conservative = restore::DecodePending(*legacyBytes);
  assert(conservative && conservative->appear_offline);
  for (const auto phase : {restore::Phase::kImporting, restore::Phase::kPrepared,
      restore::Phase::kPrivacyCommitted, restore::Phase::kRollingBack}) {
    auto pending = Prepared();
    pending.phase = phase;
    pending.appear_offline = true;
    if (phase == restore::Phase::kPrivacyCommitted) pending.normalized_document = kSettings;
    const auto bytes = restore::EncodePending(pending);
    assert(bytes);
    const auto recovered = restore::DecodePending(*bytes);
    assert(recovered && recovered->phase == phase && recovered->token == pending.token);
    assert(recovered->account_id == pending.account_id && recovered->previous_account_id == "previous");
    assert(recovered->settings_document == pending.settings_document);
    assert(recovered->normalized_document == pending.normalized_document);
    assert(recovered->network_details == pending.network_details && recovered->appear_offline);
  }
  auto invalid = Prepared();
  invalid.phase = restore::Phase::kPrivacyCommitted;
  assert(!restore::EncodePending(invalid));
  invalid = Prepared();
  invalid.settings_already_normalized = true;
  assert(!restore::EncodePending(invalid));
  assert(!restore::DecodePending("{}"));
}

void PendingCannotBecomeNormalBootAccount() {
  const auto pending = Prepared();
  assert(!restore::CanAdoptAccount("imported", pending, false));
  assert(restore::CanAdoptAccount("previous", pending, false));
  assert(restore::CanAdoptAccount("unrelated", pending, false));
  assert(!restore::CanAdoptAccount("previous", pending, true));
  assert(restore::CanAdoptAccount("imported", std::nullopt, false));
}

void RollbackRequiresBoundOwnerAndDurableDecision() {
  auto pending = Prepared();
  pending.account_id = "0123456789abcdef";
  assert(restore::CanDiscard(pending, "previous", {"previous", pending.account_id}));
  assert(restore::CanDiscard(pending, "", {}));
  assert(!restore::CanDiscard(pending, "", {"unexplained-account"}));
  assert(!restore::CanDiscard(pending, "previous", {"previous", pending.account_id, "another-import"}));
  assert(!restore::CanDiscard(pending, pending.account_id, {pending.account_id}));
  assert(!restore::CanDiscard(pending, "unrelated", {}));
  for (int invalid = 0; invalid < 4; ++invalid) {
    auto wrong = pending;
    if (invalid == 0) wrong.previous_account_id = wrong.account_id;
    if (invalid == 1) wrong.account_id = "../previous";
    if (invalid == 2) wrong.pairing_operation = 123456;
    if (invalid == 3) wrong.token = "invalid";
    assert(!restore::CanDiscard(wrong, "previous", {}));
  }
  for (int failedStage = 0; failedStage <= 4; ++failedStage) {
    auto candidate = pending;
    std::vector<std::string> calls;
    const bool result = restore::Rollback(candidate, "previous", {"previous", candidate.account_id}, {
        [&] { return failedStage != 0; },
        [&](const restore::PendingRestore& record) {
          calls.push_back("persist");
          assert(record.phase == restore::Phase::kRollingBack);
          assert(record.account_id == pending.account_id && record.token == pending.token);
          return failedStage != 1;
        },
        [&] {
          calls.push_back("remove");
          assert(candidate.phase == restore::Phase::kRollingBack);
          return failedStage != 2;
        },
        [&] { calls.push_back("clear"); return failedStage != 3; }});
    assert(result == (failedStage == 4));
    assert(calls.size() == static_cast<size_t>(std::min(failedStage, 3)));
    assert(candidate.phase == (failedStage <= 1 ? restore::Phase::kPrepared : restore::Phase::kRollingBack));
  }
  pending.phase = restore::Phase::kRollingBack;
  int ownerChecks = 0;
  bool removed = false;
  assert(!restore::Rollback(pending, "previous", {}, {
      [&] { return ++ownerChecks == 1; }, [](const auto&) { return true; },
      [&] { removed = true; return true; }, [] { return true; }}));
  assert(!removed && pending.phase == restore::Phase::kRollingBack);
  assert(!restore::Rollback(pending, "previous", {"unexpected"}, {
      [] { return true; }, [](const auto&) { return true; },
      [&] { removed = true; return true; }, [] { return true; }}));
  assert(!removed);
  bool activated = false;
  assert(!restore::Finalize(pending, pending.account_id, pending.token, kSettings,
      {[] { return true; }, [](const auto&) { return true; }, [](const auto&) { return true; },
       [&](bool) { activated = true; return true; }, [] { return true; }}));
  assert(!activated);
}

struct Fixture {
  restore::PendingRestore pending = Prepared();
  std::vector<std::string> calls;
  bool owner = true;
  bool settings_write = true;
  bool marker_write = true;
  bool enable = true;
  bool clear = true;
  bool retire_after_flush = false;
  bool retire_after_marker = false;
  restore::FinalizeCallbacks Callbacks() {
    return {[&] { return owner; },
        [&](const std::string& document) {
          calls.push_back("flush");
          assert(document == kSettings);
          if (retire_after_flush) owner = false;
          return settings_write;
        },
        [&](const restore::PendingRestore& record) {
          calls.push_back("privacyCommitted");
          assert(record.normalized_document == kSettings && record.phase == restore::Phase::kPrivacyCommitted);
          if (retire_after_marker) owner = false;
          return marker_write;
        },
        [&](bool enabled) {
          calls.push_back(enabled ? "enable" : "offline");
          assert(pending.phase == restore::Phase::kPrivacyCommitted);
          return enable;
        },
        [&] { calls.push_back("clear"); return clear; }};
  }
  bool Run(const std::string& account = "imported", const std::string& token = std::string(64, 'a')) {
    return restore::Finalize(pending, account, token, kSettings, Callbacks());
  }
};

void PairingMarkerRequiresAcknowledgedLocalPrivacy() {
  auto pending = Prepared();
  pending.phase = restore::Phase::kImporting;
  pending.pairing_operation = 0;
  auto bytes = restore::EncodePending(pending);
  assert(bytes && bytes->find("\"version\":2") != std::string::npos);
  auto restored = restore::DecodePending(*bytes);
  assert(restored && restored->pairing_operation == 0 && !restored->pairing_acknowledged);
  assert(!restore::CanAdoptAccount("imported", restored, false));
  assert(restore::CanAdoptAccount("previous", restored, false));
  auto legacy = *bytes;
  legacy.replace(legacy.find("\"version\":2"), std::string("\"version\":2").size(), "\"version\":1");
  assert(!restore::DecodePending(legacy));
  pending.pairing_operation = 123456;
  pending.settings_document = pending.normalized_document = kSettings;
  pending.settings_already_normalized = true;
  assert(restore::EncodePending(pending));
  pending.phase = restore::Phase::kPrepared;
  assert(!restore::EncodePending(pending));
  Fixture unacknowledged; unacknowledged.pending = pending;
  assert(!unacknowledged.Run() && unacknowledged.calls.empty());
  pending.pairing_acknowledged = true;
  bytes = restore::EncodePending(pending);
  assert(bytes);
  restored = restore::DecodePending(*bytes);
  assert(restored && restored->pairing_operation == 123456 && restored->pairing_acknowledged);
  Fixture ready; ready.pending = pending;
  assert(ready.Run());
  assert(ready.calls == std::vector<std::string>({"flush", "privacyCommitted", "enable", "clear"}));
  for (uint32_t invalid : {0u, 1u, 1000000u}) {
    auto bad = pending; bad.pairing_operation = invalid;
    assert(!restore::EncodePending(bad));
  }
  auto bad = pending; bad.pairing_operation.reset();
  assert(!restore::EncodePending(bad));
  bad = pending; bad.normalized_document.clear();
  assert(!restore::EncodePending(bad));
}

void ArchiveMarkerBindsExpectedFriendId() {
  auto pending = Prepared();
  pending.expected_jami_id = std::string(40, 'a');
  const auto bytes = restore::EncodePending(pending);
  assert(bytes && bytes->find("\"version\":3") != std::string::npos);
  const auto restored = restore::DecodePending(*bytes);
  assert(restored && restored->expected_jami_id == pending.expected_jami_id);
  auto legacy = pending;
  legacy.expected_jami_id.clear();
  const auto legacy_bytes = restore::EncodePending(legacy);
  assert(legacy_bytes);
  const auto legacy_restored = restore::DecodePending(*legacy_bytes);
  assert(legacy_restored && legacy_restored->expected_jami_id.empty());
  for (const std::string invalid : {std::string(40, 'A'), std::string(40, 'z'), std::string(39, 'a')}) {
    pending.expected_jami_id = invalid;
    assert(!restore::EncodePending(pending));
  }
  pending.expected_jami_id = std::string(40, 'a');
  auto malformed = *bytes;
  malformed.replace(malformed.find("\"version\":3"), std::string("\"version\":3").size(), "\"version\":1");
  assert(!restore::DecodePending(malformed));
}

void FinalizeRequiresExactOwnerAndDocument() {
  for (int scenario = 0; scenario < 5; ++scenario) {
    Fixture fixture;
    if (scenario == 0) fixture.owner = false;
    if (scenario == 1) fixture.pending.phase = restore::Phase::kImporting;
    if (scenario == 2) fixture.pending.normalized_document = "{}";
    assert(!fixture.Run(scenario == 3 ? "unrelated" : "imported",
        scenario == 4 ? std::string(64, 'b') : std::string(64, 'a')));
    assert(fixture.calls.empty());
  }
  Fixture fixture;
  assert(!restore::Finalize(fixture.pending, "imported", fixture.pending.token,
      R"({"schemaVersion":14})", fixture.Callbacks()));
  assert(fixture.calls.empty());
}

void ActivationRejectsMalformedMicrophonePolicy() {
  assert(restore::IsNormalizedSettings(kSettings));
  auto invalid = kSettings;
  const auto mode = invalid.find("pushToTalk");
  invalid.replace(mode, std::string("pushToTalk").size(), "ptt");
  assert(!restore::IsNormalizedSettings(invalid));
  const std::string entry = R"({"accountId":"a","peerId":"p","conversationId":"c","kind":"direct","mode":"open"})";
  auto duplicate = kSettings;
  const auto list = duplicate.find("[]");
  duplicate.replace(list, 2, "[" + entry + "," + entry + "]");
  assert(!restore::IsNormalizedSettings(duplicate));
  auto valid = kSettings;
  valid.replace(valid.find("[]"), 2, "[" + entry + "]");
  assert(restore::IsNormalizedSettings(valid));

  auto current = kSettings;
  current.replace(current.find(":16"), 3, ":17");
  current.insert(current.find("\"showMessage\""), "\"messageAlertsEnabled\":true,");
  current.insert(1, "\"friendPreferences\":{\"reviewRequired\":false,\"overrides\":[]},");
  assert(restore::IsNormalizedSettings(current));
  const std::string friend_entry = "{\"accountId\":\"a\",\"peerId\":\"" + std::string(40, 'a') +
      "\",\"holograms\":\"block\",\"messageAlerts\":\"mute\"}";
  auto friend_valid = current;
  friend_valid.replace(friend_valid.find("[]"), 2, "[" + friend_entry + "]");
  assert(restore::IsNormalizedSettings(friend_valid));
  auto friend_duplicate = current;
  friend_duplicate.replace(friend_duplicate.find("[]"), 2, "[" + friend_entry + "," + friend_entry + "]");
  assert(!restore::IsNormalizedSettings(friend_duplicate));
  auto friend_invalid = friend_valid;
  friend_invalid.replace(friend_invalid.find("block"), 5, "unknown");
  assert(!restore::IsNormalizedSettings(friend_invalid));
  auto profile_colors = current;
  profile_colors.replace(profile_colors.find(":17"), 3, ":18");
  assert(restore::IsNormalizedSettings(profile_colors));
  auto profile_friend_valid = friend_valid;
  profile_friend_valid.replace(profile_friend_valid.find(":17"), 3, ":18");
  assert(restore::IsNormalizedSettings(profile_friend_valid));
  auto profile_friend_invalid = friend_invalid;
  profile_friend_invalid.replace(profile_friend_invalid.find(":17"), 3, ":18");
  assert(!restore::IsNormalizedSettings(profile_friend_invalid));
  auto appearance = profile_colors;
  appearance.replace(appearance.find(":18"), 3, ":19");
  assert(restore::IsNormalizedSettings(appearance));
  auto appearance_friend_valid = profile_friend_valid;
  appearance_friend_valid.replace(appearance_friend_valid.find(":18"), 3, ":19");
  assert(restore::IsNormalizedSettings(appearance_friend_valid));
  auto appearance_friend_invalid = profile_friend_invalid;
  appearance_friend_invalid.replace(appearance_friend_invalid.find(":18"), 3, ":19");
  assert(!restore::IsNormalizedSettings(appearance_friend_invalid));
  auto edge_spacing = appearance;
  edge_spacing.replace(edge_spacing.find(":19"), 3, ":20");
  assert(restore::IsNormalizedSettings(edge_spacing));
  auto edge_friend_valid = appearance_friend_valid;
  edge_friend_valid.replace(edge_friend_valid.find(":19"), 3, ":20");
  assert(restore::IsNormalizedSettings(edge_friend_valid));
  auto edge_friend_invalid = appearance_friend_invalid;
  edge_friend_invalid.replace(edge_friend_invalid.find(":19"), 3, ":20");
  assert(!restore::IsNormalizedSettings(edge_friend_invalid));
  auto opacity = edge_spacing;
  opacity.replace(opacity.find(":20"), 3, ":21");
  assert(restore::IsNormalizedSettings(opacity));
  auto intensity = opacity;
  intensity.replace(intensity.find(":21"), 3, ":22");
  assert(restore::IsNormalizedSettings(intensity));
  auto future = edge_spacing;
  future.replace(future.find(":20"), 3, ":23");
  assert(!restore::IsNormalizedSettings(future));
}

void FinalizeNeverEnablesBeforeDurability() {
  for (int scenario = 0; scenario < 4; ++scenario) {
    Fixture fixture;
    if (scenario == 0) fixture.settings_write = false;
    if (scenario == 1) fixture.retire_after_flush = true;
    if (scenario == 2) fixture.marker_write = false;
    if (scenario == 3) fixture.retire_after_marker = true;
    assert(!fixture.Run());
    assert(fixture.calls == (scenario < 2 ? std::vector<std::string>{"flush"} :
        std::vector<std::string>{"flush", "privacyCommitted"}));
  }
}

void FinalizePreservesOfflineAndRetryIdentity() {
  Fixture fixture;
  fixture.pending.appear_offline = true;
  fixture.clear = false;
  assert(!fixture.Run());
  assert(fixture.calls == std::vector<std::string>({"flush", "privacyCommitted", "offline", "clear"}));
  assert(fixture.pending.phase == restore::Phase::kPrivacyCommitted);
  assert(fixture.pending.normalized_document == kSettings);
  fixture.calls.clear();
  fixture.clear = true;
  assert(fixture.Run());
  assert(fixture.calls == std::vector<std::string>({"flush", "privacyCommitted", "offline", "clear"}));
}

void ThrowingBoundaryCannotEnable() {
  Fixture fixture;
  auto callbacks = fixture.Callbacks();
  callbacks.lock_and_flush_settings = [](const std::string&) -> bool { throw std::runtime_error("fixture"); };
  assert(!restore::Finalize(fixture.pending, "imported", fixture.pending.token, kSettings, callbacks));
  assert(fixture.calls.empty());
}

std::string ReadFile(const std::filesystem::path& path) {
  std::ifstream file(path, std::ios::binary);
  return {std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>()};
}
void WriteFile(const std::filesystem::path& path, const std::string& value) {
  // OPEN_ALWAYS preserves an existing fixture's hidden attribute. CREATE_ALWAYS
  // (used by fstream truncation) can refuse the production DPAPI hidden file.
  const HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr,
      OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  assert(file != INVALID_HANDLE_VALUE);
  LARGE_INTEGER start{};
  assert(SetFilePointerEx(file, start, nullptr, FILE_BEGIN));
  assert(SetEndOfFile(file));
  DWORD written = 0;
  assert(::WriteFile(file, value.data(), static_cast<DWORD>(value.size()), &written, nullptr));
  assert(written == value.size());
  assert(FlushFileBuffers(file));
  assert(CloseHandle(file));
}
std::string Quote(const std::string& text) {
  std::string result = "\"";
  for (char ch : text) {
    if (ch == '\\' || ch == '"') result += '\\';
    result += ch;
  }
  return result + "\"";
}

void FriendOwnersUseTheCanonicalSettingsContract() {
  auto document = [](const std::string& account_json) {
    auto value = kSettings;
    value.replace(value.find(":16"), 3, ":17");
    value.insert(value.find("\"showMessage\""), "\"messageAlertsEnabled\":true,");
    value.insert(1, "\"friendPreferences\":{\"reviewRequired\":false,\"overrides\":[{\"accountId\":" +
        account_json + ",\"peerId\":\"" + std::string(40, 'a') +
        "\",\"holograms\":\"block\",\"messageAlerts\":\"mute\"}]},");
    return value;
  };
  for (const auto* invalid : {R"("")", R"(" owner")", R"("owner ")",
      R"("ow\u0001ner")", R"("owner\u007f")", R"("\u0085owner")",
      R"("\u00a0owner")", R"("owner\ufeff")"}) {
    assert(!restore::IsNormalizedSettings(document(invalid)));
  }
  assert(restore::IsNormalizedSettings(document(Quote(std::string(128, 'a')))));
  assert(!restore::IsNormalizedSettings(document(Quote(std::string(129, 'a')))));
  std::string unicode;
  for (int i = 0; i < 128; ++i) unicode += "\xc3\xa9";
  assert(restore::IsNormalizedSettings(document(Quote(unicode))));
  unicode += "\xc3\xa9";
  assert(!restore::IsNormalizedSettings(document(Quote(unicode))));
}

void IsolatedStoreAndCanonicalLease(const std::filesystem::path& root) {
  assert(root.is_absolute());
  std::filesystem::create_directories(root);
  const auto token = restore::RandomToken();
  assert(token && token->size() == 64);
  const auto directory = root / ("identity-restore-" + *token);
  assert(std::filesystem::create_directory(directory));
  const auto marker = directory / "pending.dpapi";
  const auto canonical = directory / "shared_preferences.json";
  restore::PendingRestoreStore store(marker);
  assert(store.Load().status == restore::LoadStatus::kAbsent);
  auto pending = Prepared();
  assert(store.Save(pending));
  auto loaded = store.Load();
  assert(loaded.status == restore::LoadStatus::kLoaded && loaded.value->token == pending.token);
  assert(loaded.value->appear_offline);
  pending = *loaded.value;  // Continue with the migrated conservative archive policy.
  const auto original = ReadFile(marker);
  WriteFile(marker, "invalid sealed record");
  assert(store.Load().status == restore::LoadStatus::kError);
  assert(!store.Save(pending));
  assert(ReadFile(marker) == "invalid sealed record");
  WriteFile(marker, original);
  assert(store.Load().status == restore::LoadStatus::kLoaded);
  pending.phase = restore::Phase::kPrivacyCommitted;
  pending.normalized_document = kSettings;
  assert(store.Save(pending));
  auto resumed = pending;
  resumed.phase = restore::Phase::kPrepared;
  resumed.settings_document = pending.normalized_document;
  resumed.normalized_document.clear();
  resumed.settings_already_normalized = true;
  assert(!store.Save(resumed));
  assert(store.Save(resumed, true));
  loaded = store.Load();
  assert(loaded.value && loaded.value->settings_already_normalized);
  assert(loaded.value->phase == restore::Phase::kPrepared);
  assert(loaded.value->settings_document == kSettings);
  assert(loaded.value->normalized_document.empty());

  const std::string preferences = "{\"flutter.appSettings\":" + Quote(kSettings) +
      ",\"flutter.appLockEnabled.v1\":true,\"flutter.unrelated\":\"retain\"}";
  WriteFile(canonical, preferences);
  {
    const auto lease = restore::CanonicalSettingsLease::Acquire(canonical, kSettings);
    assert(lease);
    const HANDLE writer = CreateFileW(canonical.c_str(), GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    assert(writer == INVALID_HANDLE_VALUE && GetLastError() == ERROR_SHARING_VIOLATION);
    assert(ReadFile(canonical) == preferences);
  }
  assert(!restore::CanonicalSettingsLease::Acquire(canonical, kSettings + " "));
  {
    const auto current = restore::CanonicalSettingsLease::AcquireCurrent(canonical);
    assert(current && !current->appear_offline());
    assert(current->AllowsFriendHolograms("owner", std::string(40, 'a')));
  }
  for (const bool global : {false, true}) {
    for (const auto* choice : {"useGlobalDefault", "allow", "block"}) {
      auto policy = kSettings;
      policy.replace(policy.find(":16"), 3, ":17");
      policy.insert(policy.find("\"showMessage\""), "\"messageAlertsEnabled\":false,");
      if (!global) policy.replace(policy.find("\"hologramPresentationEnabled\":true"),
          std::string("\"hologramPresentationEnabled\":true").size(), "\"hologramPresentationEnabled\":false");
      policy.insert(1, "\"friendPreferences\":{\"reviewRequired\":false,\"overrides\":[{\"accountId\":\"owner\",\"peerId\":\"" +
          std::string(40, 'a') + "\",\"holograms\":\"" + choice + "\",\"messageAlerts\":\"mute\"}]},");
      WriteFile(canonical, "{\"flutter.appSettings\":" + Quote(policy) + ",\"flutter.appLockEnabled.v1\":true}");
      {
        const auto current = restore::CanonicalSettingsLease::AcquireCurrent(canonical);
        assert(current);
        const bool expected = std::string(choice) == "allow" || (global && std::string(choice) != "block");
        assert(current->AllowsFriendHolograms("owner", std::string(40, 'a')) == expected);
        assert(current->AllowsFriendHolograms("other", std::string(40, 'a')) == global);
      }
      policy.replace(policy.find("\"reviewRequired\":false"), std::string("\"reviewRequired\":false").size(),
          "\"reviewRequired\":true");
      WriteFile(canonical, "{\"flutter.appSettings\":" + Quote(policy) + ",\"flutter.appLockEnabled.v1\":true}");
      const auto current = restore::CanonicalSettingsLease::AcquireCurrent(canonical);
      assert(current && !current->AllowsFriendHolograms("owner", std::string(40, 'a')));
    }
  }
  WriteFile(canonical, "{\"flutter.appSettings\":" + Quote(kSettings) +
      ",\"flutter.appLockEnabled.v1\":true,\"flutter.appearOffline\":true}");
  {
    const auto current = restore::CanonicalSettingsLease::AcquireCurrent(canonical);
    assert(current && current->appear_offline());
  }
  WriteFile(canonical, "{\"flutter.appSettings\":" + Quote(kSettings) +
      ",\"flutter.appLockEnabled.v1\":true,\"flutter.appearOffline\":\"false\"}");
  assert(!restore::CanonicalSettingsLease::AcquireCurrent(canonical));
  for (const auto& latch : std::vector<std::string>{"", ",\"flutter.appLockEnabled.v1\":\"true\"",
      ",\"flutter.appLockEnabled.v1\":false", ",\"flutter.appLockEnabled.v1\":null"}) {
    WriteFile(canonical, "{\"flutter.appSettings\":" + Quote(kSettings) + latch + "}");
    assert(!restore::CanonicalSettingsLease::Acquire(canonical, kSettings));
  }
  std::string unlocked = kSettings;
  const auto enabled = unlocked.find("\"enabled\":true");
  assert(enabled != std::string::npos);
  unlocked.replace(enabled, std::string("\"enabled\":true").size(), "\"enabled\":false");
  WriteFile(canonical, "{\"flutter.appSettings\":" + Quote(unlocked) + ",\"flutter.appLockEnabled.v1\":false}");
  { const auto lease = restore::CanonicalSettingsLease::Acquire(canonical, unlocked); assert(lease); }
  WriteFile(canonical, "{\"flutter.appSettings\":" + Quote(kSettings) + ",\"flutter.appSettings\":" + Quote(kSettings) + "}");
  assert(!restore::CanonicalSettingsLease::Acquire(canonical, kSettings));
  assert(!restore::CanonicalSettingsLease::Acquire(directory / "absent.json", kSettings));
  auto other = pending;
  other.token = std::string(64, 'b');
  assert(!store.Save(other));
  assert(!store.Clear(other.token));
  auto rollback = *store.Load().value;
  rollback.phase = restore::Phase::kRollingBack;
  auto wrongRollback = rollback;
  wrongRollback.previous_account_id = "unrelated";
  assert(!store.Save(wrongRollback));
  assert(store.Save(rollback));
  assert(store.Load().value->phase == restore::Phase::kRollingBack);
  assert(!store.Save(resumed, true));
  assert(!store.Save(pending));
  assert(store.Save(rollback));
  assert(store.Clear(pending.token));
  assert(store.Load().status == restore::LoadStatus::kAbsent);
  // A crash after enabling but before journal retirement must retain the
  // acknowledged document when re-preparing the same now-disabled link.
  auto link = Prepared();
  link.token = std::string(64, 'c');
  link.pairing_operation = 123456;
  link.pairing_acknowledged = true;
  link.settings_already_normalized = true;
  link.settings_document = link.normalized_document = kSettings;
  link.phase = restore::Phase::kPrivacyCommitted;
  assert(store.Save(link));
  auto recoveredLink = link;
  recoveredLink.phase = restore::Phase::kPrepared;
  assert(!store.Save(recoveredLink));
  for (int change = 0; change < 7; ++change) {
    auto wrong = recoveredLink;
    if (change == 0) wrong.normalized_document.clear();
    if (change == 1) wrong.pairing_operation = 123457;
    if (change == 2) wrong.pairing_acknowledged = false;
    if (change == 3) wrong.account_id = "unrelated";
    if (change == 4) wrong.appear_offline = !link.appear_offline;
    if (change == 5) wrong.network_details["connectionProfile"] = "lan";
    if (change == 6) wrong.previous_account_id = "unrelated";
    assert(!store.Save(wrong, true));
    assert(store.Load().value->phase == restore::Phase::kPrivacyCommitted);
  }
  assert(store.Save(recoveredLink, true));
  loaded = store.Load();
  assert(loaded.value && loaded.value->phase == restore::Phase::kPrepared);
  assert(loaded.value->normalized_document == kSettings && loaded.value->pairing_acknowledged);
  assert(loaded.value->pairing_operation == link.pairing_operation);
  assert(store.Clear(link.token));
  assert(store.Load().status == restore::LoadStatus::kAbsent);
  assert(std::filesystem::remove(canonical));
  assert(std::filesystem::remove(std::filesystem::path(marker.wstring() + L".lock")));
  assert(std::filesystem::remove(directory));
}

}  // namespace

int main(int argc, char** argv) {
  std::string selector;
  std::filesystem::path fixture_root;
  for (int i = 1; i < argc; ++i) {
    const std::string argument(argv[i]);
    if (argument.rfind("--fixture-root=", 0) == 0) fixture_root = std::filesystem::u8path(argument.substr(15));
    else if (selector.empty()) selector = argument;
    else return 2;
  }
  const std::vector<std::pair<std::string, void (*)()>> tests{
      {"canonical-path", CanonicalPathPreservesInstalledStorageIdentity},
      {"friend-owner-contract", FriendOwnersUseTheCanonicalSettingsContract},
      {"export-owner", ExportOwner}, {"export-bounds", ExportRejectsMalformedAndOversized},
      {"marker-phases", MarkerRetainsEveryPhaseAndOptions}, {"boot-owner", PendingCannotBecomeNormalBootAccount},
      {"pairing-admission", PairingMarkerRequiresAcknowledgedLocalPrivacy},
      {"archive-expected-id", ArchiveMarkerBindsExpectedFriendId},
      {"prepared-inactivity", PreparedIdentityRequiresInactivity},
      {"rollback-durability", RollbackRequiresBoundOwnerAndDurableDecision},
      {"finalize-owner", FinalizeRequiresExactOwnerAndDocument}, {"finalize-durability", FinalizeNeverEnablesBeforeDurability},
      {"activation-microphone", ActivationRejectsMalformedMicrophonePolicy},
      {"finalize-retry", FinalizePreservesOfflineAndRetryIdentity}, {"finalize-throw", ThrowingBoundaryCannotEnable}};
  int count = 0;
  for (const auto& test : tests) if (selector.empty() || selector == test.first) { test.second(); ++count; }
  if (selector.empty() || selector == "isolated-store") {
    if (fixture_root.empty()) { std::cerr << "isolated-store requires --fixture-root=<absolute scratch directory>\n"; return 2; }
    IsolatedStoreAndCanonicalLease(fixture_root);
    ++count;
  }
  if (count == 0) return 2;
  std::cout << count << " identity restore tests passed\n";
}
