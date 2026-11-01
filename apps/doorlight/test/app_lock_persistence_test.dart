import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/app_lock_persistence.dart';

void main() {
  test('strict latch distinguishes absence, values, and corruption', () {
    final store = _MemoryLatchStore();
    final repository = AppLockLatchRepository(store);

    expect(repository.read(), AppLockLatchStatus.absent);
    store
      ..present = true
      ..value = 'true';
    expect(repository.read(), AppLockLatchStatus.corrupt);
    store.value = true;
    expect(repository.read(), AppLockLatchStatus.enabled);
    store.value = false;
    expect(repository.read(), AppLockLatchStatus.disabled);
  });

  test('save requires a successful read-after-write', () async {
    final store = _MemoryLatchStore();
    final repository = AppLockLatchRepository(store);

    await repository.save(true);
    expect(repository.read(), AppLockLatchStatus.enabled);

    store.rejectWrite = true;
    await expectLater(repository.save(false), throwsStateError);
    expect(repository.read(), AppLockLatchStatus.enabled);

    store
      ..rejectWrite = false
      ..corruptAfterWrite = true;
    await expectLater(repository.save(false), throwsStateError);
  });

  test('boot resolution fails closed only when prior state is ambiguous', () {
    expect(
      resolveAppLockAtBoot(
        latch: AppLockLatchStatus.enabled,
        settingsDocumentPresent: false,
        settingsDocumentLoaded: true,
        legacySettingsEnabled: false,
      ),
      isTrue,
    );
    expect(
      resolveAppLockAtBoot(
        latch: AppLockLatchStatus.disabled,
        settingsDocumentPresent: true,
        settingsDocumentLoaded: false,
        legacySettingsEnabled: true,
      ),
      isFalse,
    );
    expect(
      resolveAppLockAtBoot(
        latch: AppLockLatchStatus.absent,
        settingsDocumentPresent: true,
        settingsDocumentLoaded: true,
        legacySettingsEnabled: true,
      ),
      isTrue,
    );
    expect(
      resolveAppLockAtBoot(
        latch: AppLockLatchStatus.absent,
        settingsDocumentPresent: true,
        settingsDocumentLoaded: false,
        legacySettingsEnabled: false,
      ),
      isTrue,
    );
    expect(
      resolveAppLockAtBoot(
        latch: AppLockLatchStatus.corrupt,
        settingsDocumentPresent: false,
        settingsDocumentLoaded: true,
        legacySettingsEnabled: false,
      ),
      isTrue,
    );
    expect(
      resolveAppLockAtBoot(
        latch: AppLockLatchStatus.absent,
        settingsDocumentPresent: false,
        settingsDocumentLoaded: true,
        legacySettingsEnabled: false,
      ),
      isFalse,
    );
  });
}

final class _MemoryLatchStore implements AppLockLatchStore {
  bool present = false;
  Object? value;
  bool rejectWrite = false;
  bool corruptAfterWrite = false;

  @override
  bool contains() => present;

  @override
  Object? read() => value;

  @override
  Future<bool> write(bool enabled) async {
    if (rejectWrite) return false;
    present = true;
    value = corruptAfterWrite ? '$enabled' : enabled;
    return true;
  }
}
