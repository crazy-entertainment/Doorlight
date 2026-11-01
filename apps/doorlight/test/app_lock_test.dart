import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/app_lock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'enabled lock starts closed and opens only after OS authentication',
    () async {
      final authenticator = _FakeAuthenticator(
        outcomes: [DeviceAuthenticationOutcome.authenticated],
      );
      final writes = <bool>[];
      final controller = AppLockController(
        authenticator: authenticator,
        initialEnabled: true,
        persistEnabled: (value) async => writes.add(value),
        observeLifecycle: false,
      );

      expect(controller.locked, isTrue);
      await controller.start();

      expect(controller.locked, isFalse);
      expect(authenticator.authenticateCalls, 1);
      expect(writes, isEmpty);
      controller.dispose();
    },
  );

  test('rejected authentication fails closed', () async {
    final controller = AppLockController(
      authenticator: _FakeAuthenticator(
        outcomes: [DeviceAuthenticationOutcome.rejected],
      ),
      initialEnabled: true,
      persistEnabled: (_) async {},
      observeLifecycle: false,
    );

    await controller.start();

    expect(controller.locked, isTrue);
    expect(controller.failure, AppLockFailure.rejected);
    controller.dispose();
  });

  test(
    'enabling is authenticated and persisted before state changes',
    () async {
      final writes = <bool>[];
      final controller = AppLockController(
        authenticator: _FakeAuthenticator(
          outcomes: [DeviceAuthenticationOutcome.authenticated],
        ),
        initialEnabled: false,
        persistEnabled: (value) async => writes.add(value),
        observeLifecycle: false,
      );
      await controller.start();

      expect(await controller.setEnabled(true), isTrue);
      expect(writes, [true]);
      expect(controller.enabled, isTrue);
      expect(controller.locked, isFalse);
      controller.dispose();
    },
  );

  test('failed settings write does not partially enable the lock', () async {
    final controller = AppLockController(
      authenticator: _FakeAuthenticator(
        outcomes: [DeviceAuthenticationOutcome.authenticated],
      ),
      initialEnabled: false,
      persistEnabled: (_) => Future<void>.error(StateError('disk full')),
      observeLifecycle: false,
    );
    await controller.start();

    expect(await controller.setEnabled(true), isFalse);
    expect(controller.enabled, isFalse);
    expect(controller.failure, AppLockFailure.persistence);
    controller.dispose();
  });

  test('disabling an available lock also requires authentication', () async {
    final authenticator = _FakeAuthenticator(
      outcomes: [DeviceAuthenticationOutcome.authenticated],
    );
    final writes = <bool>[];
    final controller = AppLockController(
      authenticator: authenticator,
      initialEnabled: true,
      persistEnabled: (value) async => writes.add(value),
      observeLifecycle: false,
    );
    await controller.start(prompt: false);

    expect(await controller.setEnabled(false), isTrue);
    expect(authenticator.authenticateCalls, 1);
    expect(writes, [false]);
    expect(controller.enabled, isFalse);
    expect(controller.locked, isFalse);
    controller.dispose();
  });

  test(
    'leaving foreground locks immediately and resume prompts once',
    () async {
      final authenticator = _FakeAuthenticator(
        outcomes: [
          DeviceAuthenticationOutcome.authenticated,
          DeviceAuthenticationOutcome.authenticated,
        ],
      );
      final controller = AppLockController(
        authenticator: authenticator,
        initialEnabled: true,
        persistEnabled: (_) async {},
        observeLifecycle: false,
      );
      await controller.start();
      expect(controller.locked, isFalse);

      controller.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(controller.locked, isTrue);
      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);

      expect(controller.locked, isFalse);
      expect(authenticator.authenticateCalls, 2);
      controller.dispose();
    },
  );

  test('a lock created while paused waits for the next resume', () async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    final authenticator = _FakeAuthenticator(
      outcomes: [DeviceAuthenticationOutcome.authenticated],
    );
    final controller = AppLockController(
      authenticator: authenticator,
      initialEnabled: true,
      persistEnabled: (_) async {},
    );
    addTearDown(() {
      controller.dispose();
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });

    await controller.start();
    expect(controller.locked, isTrue);
    expect(authenticator.authenticateCalls, 0);

    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await pumpEventQueue();

    expect(authenticator.authenticateCalls, 1);
    expect(controller.locked, isFalse);
  });

  test('desktop focus loss does not lock a still-visible app', () async {
    final controller = AppLockController(
      authenticator: _FakeAuthenticator(
        outcomes: [DeviceAuthenticationOutcome.authenticated],
      ),
      initialEnabled: true,
      persistEnabled: (_) async {},
      observeLifecycle: false,
    );
    await controller.start();

    controller.didChangeAppLifecycleState(AppLifecycleState.inactive);

    expect(controller.locked, isFalse);
    controller.dispose();
  });

  test(
    'unsupported authenticator stays locked until explicit recovery',
    () async {
      final writes = <bool>[];
      final controller = AppLockController(
        authenticator: _FakeAuthenticator(supported: false),
        initialEnabled: true,
        persistEnabled: (value) async => writes.add(value),
        observeLifecycle: false,
      );
      await controller.start();

      expect(controller.locked, isTrue);
      expect(controller.availability, AppLockAvailability.unavailable);
      expect(await controller.recoverByDisablingUnavailableLock(), isTrue);
      expect(writes, [false]);
      expect(controller.enabled, isFalse);
      expect(controller.locked, isFalse);
      controller.dispose();
    },
  );

  test('concurrent unlock requests show only one platform prompt', () async {
    final pending = Completer<DeviceAuthenticationOutcome>();
    final authenticator = _FakeAuthenticator(pendingOutcome: pending.future);
    final controller = AppLockController(
      authenticator: authenticator,
      initialEnabled: true,
      persistEnabled: (_) async {},
      observeLifecycle: false,
    );
    await controller.start(prompt: false);

    final first = controller.unlock();
    final second = controller.unlock();
    pending.complete(DeviceAuthenticationOutcome.authenticated);

    expect(await first, isTrue);
    expect(await second, isTrue);
    expect(authenticator.authenticateCalls, 1);
    controller.dispose();
  });

  test(
    'authentication success from an earlier foreground stays locked',
    () async {
      final pending = Completer<DeviceAuthenticationOutcome>();
      final authenticator = _FakeAuthenticator(pendingOutcome: pending.future);
      final controller = AppLockController(
        authenticator: authenticator,
        initialEnabled: true,
        persistEnabled: (_) async {},
        observeLifecycle: false,
      );
      await controller.start(prompt: false);

      final unlock = controller.unlock();
      await Future<void>.delayed(Duration.zero);
      controller.didChangeAppLifecycleState(AppLifecycleState.paused);
      pending.complete(DeviceAuthenticationOutcome.authenticated);

      expect(await unlock, isFalse);
      expect(controller.locked, isTrue);

      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);

      expect(authenticator.authenticateCalls, 2);
      expect(controller.locked, isFalse);
      controller.dispose();
    },
  );

  test('enabling in an earlier foreground commits locked', () async {
    final persisted = Completer<void>();
    final writes = <bool>[];
    final authenticator = _FakeAuthenticator(
      outcomes: [
        DeviceAuthenticationOutcome.authenticated,
        DeviceAuthenticationOutcome.authenticated,
      ],
    );
    final controller = AppLockController(
      authenticator: authenticator,
      initialEnabled: false,
      persistEnabled: (value) {
        writes.add(value);
        return persisted.future;
      },
      observeLifecycle: false,
    );
    await controller.start();

    final enabling = controller.setEnabled(true);
    await Future<void>.delayed(Duration.zero);
    controller.didChangeAppLifecycleState(AppLifecycleState.paused);
    persisted.complete();

    expect(await enabling, isTrue);
    expect(writes, [true]);
    expect(controller.enabled, isTrue);
    expect(controller.locked, isTrue);

    controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await Future<void>.delayed(Duration.zero);

    expect(authenticator.authenticateCalls, 2);
    expect(controller.locked, isFalse);
    controller.dispose();
  });

  test(
    'authenticator exceptions stay locked without recovery bypass',
    () async {
      final writes = <bool>[];
      final controller = AppLockController(
        authenticator: _ThrowingAuthenticator(),
        initialEnabled: true,
        persistEnabled: (value) async => writes.add(value),
        observeLifecycle: false,
      );

      await controller.start();

      expect(controller.locked, isTrue);
      expect(controller.failure, AppLockFailure.deviceError);
      expect(controller.availability, AppLockAvailability.unknown);
      expect(await controller.recoverByDisablingUnavailableLock(), isFalse);
      expect(controller.enabled, isTrue);
      expect(writes, isEmpty);
      controller.dispose();
    },
  );
}

final class _FakeAuthenticator implements DeviceAuthenticator {
  _FakeAuthenticator({
    this.supported = true,
    List<DeviceAuthenticationOutcome> outcomes = const [],
    this.pendingOutcome,
  }) : _outcomes = List.of(outcomes);

  final bool supported;
  final List<DeviceAuthenticationOutcome> _outcomes;
  final Future<DeviceAuthenticationOutcome>? pendingOutcome;
  int authenticateCalls = 0;

  @override
  Future<DeviceAuthenticationOutcome> authenticate() async {
    authenticateCalls++;
    if (pendingOutcome case final pending?) return pending;
    return _outcomes.removeAt(0);
  }

  @override
  Future<void> cancel() async {}

  @override
  Future<bool> isSupported() async => supported;
}

final class _ThrowingAuthenticator implements DeviceAuthenticator {
  @override
  Future<DeviceAuthenticationOutcome> authenticate() =>
      Future<DeviceAuthenticationOutcome>.error(StateError('plugin failed'));

  @override
  Future<void> cancel() async {}

  @override
  Future<bool> isSupported() => Future<bool>.error(StateError('plugin failed'));
}
