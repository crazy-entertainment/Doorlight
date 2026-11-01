enum AppLockLatchStatus { absent, disabled, enabled, corrupt }

/// Minimal durable boundary for the security-sensitive app-lock latch.
///
/// The latch intentionally does not share the versioned appearance/settings
/// document: an unsupported cosmetic schema must never disable a lock.
abstract interface class AppLockLatchStore {
  bool contains();

  Object? read();

  Future<bool> write(bool enabled);
}

/// Strict, read-after-write repository for the independent app-lock latch.
final class AppLockLatchRepository {
  const AppLockLatchRepository(this.store);

  final AppLockLatchStore store;

  AppLockLatchStatus read() {
    try {
      if (!store.contains()) return AppLockLatchStatus.absent;
      return switch (store.read()) {
        true => AppLockLatchStatus.enabled,
        false => AppLockLatchStatus.disabled,
        _ => AppLockLatchStatus.corrupt,
      };
    } catch (_) {
      return AppLockLatchStatus.corrupt;
    }
  }

  Future<void> save(bool enabled) async {
    if (!await store.write(enabled)) {
      throw StateError('app-lock latch write was rejected');
    }
    final persisted = read();
    final expected = enabled
        ? AppLockLatchStatus.enabled
        : AppLockLatchStatus.disabled;
    if (persisted != expected) {
      throw StateError('app-lock latch read-after-write mismatch');
    }
  }
}

/// Resolve boot state conservatively.
///
/// A valid dedicated latch always wins. During one-time migration, a valid
/// legacy settings value is retained. A present but unreadable settings
/// document or corrupt latch resolves to locked; absence on a clean install
/// remains disabled.
bool resolveAppLockAtBoot({
  required AppLockLatchStatus latch,
  required bool settingsDocumentPresent,
  required bool settingsDocumentLoaded,
  required bool legacySettingsEnabled,
}) {
  return switch (latch) {
    AppLockLatchStatus.enabled => true,
    AppLockLatchStatus.disabled => false,
    AppLockLatchStatus.corrupt => true,
    AppLockLatchStatus.absent when settingsDocumentLoaded =>
      legacySettingsEnabled,
    AppLockLatchStatus.absent when settingsDocumentPresent => true,
    AppLockLatchStatus.absent => false,
  };
}
