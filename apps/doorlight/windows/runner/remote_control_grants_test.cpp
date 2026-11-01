#ifdef NDEBUG
#undef NDEBUG
#endif

#include "remote_control_grants.h"

#include <cassert>
#include <optional>
#include <stdexcept>
#include <string>

using namespace sybl::remote;

namespace {

class MemoryStorage final : public GrantBlobStorage {
 public:
  std::unique_ptr<Transaction> BeginTransaction() override {
    if (fail_lock) return nullptr;
    return std::make_unique<Transaction>();
  }
  ReadResult Read() override {
    if (throw_read) throw std::runtime_error("fixture read failure");
    if (fail_read) return {};
    return bytes
        ? ReadResult{ReadStatus::kLoaded, *bytes}
        : ReadResult{ReadStatus::kAbsent, {}};
  }
  bool Write(const std::string& value) override {
    if (fail_write) return false;
    ++writes;
    bytes = value;
    return true;
  }
  bool Remove() override {
    if (fail_remove) return false;
    ++removes;
    bytes.reset();
    return true;
  }

  std::optional<std::string> bytes;
  bool fail_lock = false;
  bool fail_read = false;
  bool throw_read = false;
  bool fail_write = false;
  bool fail_remove = false;
  int writes = 0;
  int removes = 0;
};

class PrefixProtector final : public GrantBlobProtector {
 public:
  std::optional<std::string> Protect(const std::string& clear) override {
    last_clear = clear;
    return fail ? std::nullopt
                : std::optional<std::string>{"sealed:" + clear};
  }
  std::optional<std::string> Unprotect(const std::string& sealed) override {
    if (fail || sealed.rfind("sealed:", 0) != 0) return std::nullopt;
    return sealed.substr(7);
  }

  bool fail = false;
  std::string last_clear;
};

PersistentGrantKey Key(char device = '1') {
  return {std::string(40, 'a'), std::string(40, 'b'),
          std::string(64, device)};
}

void DeviceBindingAndBothExpiryClocksFailClosed() {
  MemoryStorage storage;
  PrefixProtector protector;
  PersistentGrantStore grants(storage, protector);
  constexpr std::uint64_t start = 100000;
  assert(grants.Save(Key(), start));
  assert(protector.last_clear.find("00112233445566778899aabbccddeeff") ==
         std::string::npos);  // session tokens have no storage field
  assert(!grants.Matches(Key('2'), start + 1));
  assert(grants.Matches(Key(), start + 1));
  assert(grants.Touch(Key(), start + 1));
  assert(grants.Matches(Key(), start + kPersistentGrantTtlMs - 1));
  assert(grants.Touch(Key(), start + kPersistentGrantTtlMs - 1));
  // Absolute grantedAt TTL wins even though the prior match refreshed use.
  assert(!grants.Matches(Key(), start + kPersistentGrantTtlMs));
  assert(!storage.bytes);

  assert(grants.Save(Key(), start + kPersistentGrantTtlMs + 10));
  // Clock rollback is treated as invalid/expired, never as an extended grant.
  assert(!grants.Matches(Key(), start));
}

void CorruptionAndProtectionFailureDeleteAuthority() {
  MemoryStorage storage;
  PrefixProtector protector;
  PersistentGrantStore grants(storage, protector);
  storage.bytes = "not-dpapi";
  assert(!grants.Matches(Key(), 1000));
  assert(storage.removes == 1);
  assert(!storage.bytes);

  assert(grants.Save(Key(), 2000));
  storage.bytes->push_back('x');
  assert(!grants.Matches(Key(), 2001));
  assert(storage.removes == 2);

  protector.fail = true;
  assert(!grants.Save(Key(), 3000));
  assert(!grants.Matches(Key(), 3001));
}

void ProductionTouchCannotRenewExpiredOrRolledBackAuthority() {
  MemoryStorage storage;
  PrefixProtector protector;
  PersistentGrantStore grants(storage, protector);
  constexpr std::uint64_t start = 100000;
  assert(grants.Save(Key(), start));
  assert(grants.Touch(Key(), start + kPersistentGrantTtlMs - 1));
  const auto before = storage.bytes;
  assert(!grants.Touch(Key(), start + kPersistentGrantTtlMs));
  assert(!grants.Touch(Key(), start + kPersistentGrantTtlMs + 1));
  assert(storage.bytes == before);
  assert(!grants.Matches(Key(), start + kPersistentGrantTtlMs));
  assert(!storage.bytes);
  assert(grants.Save(Key(), start));
  assert(grants.Touch(Key(), start + 10));
  assert(!grants.Touch(Key(), start + 9));
  assert(!grants.Matches(Key(), start + 9));
  assert(!storage.bytes);
}

void ProductionSavePrunesExpiredRecordsAndNeedsFreshConsentToRenew() {
  MemoryStorage storage;
  PrefixProtector protector;
  PersistentGrantStore grants(storage, protector);
  constexpr std::uint64_t start = 100000;
  assert(grants.Save(Key(), start));
  assert(grants.Save(Key('2'), start + 10));
  assert(grants.Save(Key('3'), start + kPersistentGrantTtlMs));
  assert(!grants.Matches(Key(), start + kPersistentGrantTtlMs));
  assert(grants.Matches(Key('2'), start + kPersistentGrantTtlMs));
  assert(grants.Matches(Key('3'), start + kPersistentGrantTtlMs));
  // Save is called only after new consent. Touch alone cannot extend age.
  assert(grants.Save(Key(), start + kPersistentGrantTtlMs));
  assert(grants.Matches(Key(), start + 2 * kPersistentGrantTtlMs - 1));
  assert(!grants.Matches(Key(), start + 2 * kPersistentGrantTtlMs));
}

void InvalidAndChangedIdentitiesNeverMatch() {
  MemoryStorage storage;
  PrefixProtector protector;
  PersistentGrantStore grants(storage, protector);
  auto invalid = Key();
  invalid.controller_device.clear();
  assert(!grants.Save(invalid, 1000));
  // CanStore is the UI's honesty gate: the "skip next time" button may only
  // be offered for a key Save could accept. A 16-hex internal daemon account
  // id is deliberately rejected; production now supplies the stable 40-hex
  // local Jami identity instead.
  assert(grants.CanStore(Key()));
  assert(!grants.CanStore(invalid));
  auto daemon_id_local = Key();
  daemon_id_local.local_account = "0ebb8331115bab6b";  // 16 hex, not 40
  assert(!grants.CanStore(daemon_id_local));
  assert(grants.Save(Key(), 1000));
  auto other_account = Key();
  other_account.controller_account = std::string(40, 'c');
  assert(!grants.Matches(other_account, 1001));
  auto other_local = Key();
  other_local.local_account = std::string(40, 'd');
  assert(!grants.Matches(other_local, 1001));
  assert(grants.Remove(Key()));
  assert(!storage.bytes);
}

void MatchDoesNotTouchAndTouchFailureIsReported() {
  MemoryStorage storage;
  PrefixProtector protector;
  PersistentGrantStore grants(storage, protector);
  assert(grants.Save(Key(), 1000));
  assert(storage.writes == 1);
  assert(grants.Matches(Key(), 1001));
  assert(storage.writes == 1);

  storage.fail_write = true;
  assert(!grants.Touch(Key(), 1002));
  storage.fail_write = false;
  assert(grants.Matches(Key(), 1001));  // Failed Touch did not advance the clock.
  assert(grants.Matches(Key(), 1003));
  assert(storage.writes == 1);
  assert(grants.Touch(Key(), 1003));
  assert(storage.writes == 2);
}

void RevocationAndStorageFailuresFailClosed() {
  MemoryStorage storage;
  PrefixProtector protector;
  PersistentGrantStore grants(storage, protector);
  assert(grants.Save(Key(), 1000));

  storage.fail_remove = true;
  assert(!grants.Remove(Key()));
  assert(storage.bytes);
  storage.fail_remove = false;
  assert(grants.Remove(Key()));
  assert(!storage.bytes);

  // Failed revocation disables saved consent for this process, even after a
  // successful retry. It must not silently revive a previously saved record.
  assert(!grants.CanStore(Key()));
  assert(!grants.Save(Key(), 2000));
  PersistentGrantStore reopened(storage, protector);
  assert(reopened.Save(Key(), 2000));
  storage.fail_lock = true;
  assert(!reopened.Matches(Key(), 2001));
  assert(!reopened.Touch(Key(), 2001));
  assert(!reopened.Remove(Key()));
  storage.fail_lock = false;

  PersistentGrantStore healthy(storage, protector);
  const auto saved_bytes = storage.bytes;
  storage.fail_read = true;
  assert(!healthy.Matches(Key(), 2002));
  assert(storage.bytes == saved_bytes);
  storage.fail_read = false;
  assert(healthy.Matches(Key(), 2003));
  assert(!reopened.Matches(Key(), 2003));
}

void PeerRemovalIsExactIdempotentAndVerified() {
  MemoryStorage storage;
  PrefixProtector protector;
  PersistentGrantStore grants(storage, protector);
  auto other_peer = Key();
  other_peer.controller_account = std::string(40, 'c');
  auto other_local = Key();
  other_local.local_account = std::string(40, 'd');
  assert(grants.Save(Key(), 1000));
  assert(grants.Save(Key('2'), 1000));
  assert(grants.Save(other_peer, 1000));
  assert(grants.Save(other_local, 1000));
  assert(grants.RemovePeer(Key().local_account, Key().controller_account));
  assert(grants.RemovePeer(Key().local_account, Key().controller_account));
  assert(!grants.Matches(Key(), 1001));
  assert(!grants.Matches(Key('2'), 1001));
  assert(grants.Matches(other_peer, 1001));
  assert(grants.Matches(other_local, 1001));
}

void PeerRemovalReadFailureNeverFabricatesAbsence() {
  MemoryStorage storage;
  PrefixProtector protector;
  PersistentGrantStore grants(storage, protector);
  assert(grants.Save(Key(), 1000));
  const auto before = storage.bytes;
  storage.throw_read = true;
  assert(!grants.RemovePeer(Key().local_account, Key().controller_account));
  storage.throw_read = false;
  assert(storage.bytes == before);
  assert(!grants.Matches(Key(), 1001));
  assert(!grants.Save(Key(), 1002));
  assert(grants.RemovePeer(Key().local_account, Key().controller_account));
  assert(!storage.bytes);
}

void RealDpapiRoundTripIsCurrentUserBound() {
  Win32GrantDpapiProtector protector;
  const std::string clear = "device-bound grant record";
  const auto sealed = protector.Protect(clear);
  assert(sealed && *sealed != clear);
  assert(protector.Unprotect(*sealed) ==
         std::optional<std::string>{clear});
  std::string corrupt = *sealed;
  corrupt[corrupt.size() / 2] ^= 0x5a;
  assert(!protector.Unprotect(corrupt));

  sybl::win32::Win32DpapiProtector archive_secret(
      "identity archive secret v1");
  assert(!archive_secret.Unprotect(*sealed));
  const auto archive_sealed = archive_secret.Protect(clear);
  assert(archive_sealed && *archive_sealed != clear);
  assert(archive_secret.Unprotect(*archive_sealed) ==
         std::optional<std::string>{clear});
  assert(!protector.Unprotect(*archive_sealed));
}

}  // namespace

int main() {
  DeviceBindingAndBothExpiryClocksFailClosed();
  ProductionTouchCannotRenewExpiredOrRolledBackAuthority();
  ProductionSavePrunesExpiredRecordsAndNeedsFreshConsentToRenew();
  CorruptionAndProtectionFailureDeleteAuthority();
  InvalidAndChangedIdentitiesNeverMatch();
  MatchDoesNotTouchAndTouchFailureIsReported();
  RevocationAndStorageFailuresFailClosed();
  PeerRemovalIsExactIdempotentAndVerified();
  PeerRemovalReadFailureNeverFabricatesAbsence();
  RealDpapiRoundTripIsCurrentUserBound();
}
