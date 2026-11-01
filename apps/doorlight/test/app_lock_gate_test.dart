import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/app_lock.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/app_lock_gate.dart';

void main() {
  testWidgets(
    'locked gate removes protected content and unlocks through OS port',
    (tester) async {
      final controller = AppLockController(
        authenticator: _Authenticator(),
        initialEnabled: true,
        persistEnabled: (_) async {},
        observeLifecycle: false,
      );
      await controller.start(prompt: false);
      await tester.pumpWidget(
        MaterialApp(
          theme: Warm.theme(),
          home: AppLockGate(
            controller: controller,
            child: const Text(
              'protected conversation',
              key: ValueKey('protected-content'),
            ),
          ),
        ),
      );

      expect(find.byKey(const ValueKey('app-lock-surface')), findsOneWidget);
      expect(find.byKey(const ValueKey('protected-content')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('unlock-app-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('app-lock-surface')), findsNothing);
      expect(find.byKey(const ValueKey('protected-content')), findsOneWidget);
      controller.dispose();
    },
  );

  testWidgets('unavailable credentials expose explicit recovery', (
    tester,
  ) async {
    final writes = <bool>[];
    final controller = AppLockController(
      authenticator: _Authenticator(supported: false),
      initialEnabled: true,
      persistEnabled: (enabled) async => writes.add(enabled),
      observeLifecycle: false,
    );
    await controller.start(prompt: false);
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme(),
        home: AppLockGate(
          controller: controller,
          child: const Text('protected conversation'),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('recover-app-lock-button')));
    await tester.pumpAndSettle();

    expect(writes, [false]);
    expect(controller.enabled, isFalse);
    expect(find.text('protected conversation'), findsOneWidget);
    controller.dispose();
  });

  testWidgets('authenticator errors stay locked and never expose reset', (
    tester,
  ) async {
    final writes = <bool>[];
    final controller = AppLockController(
      authenticator: const _ThrowingAuthenticator(),
      initialEnabled: true,
      persistEnabled: (enabled) async => writes.add(enabled),
      observeLifecycle: false,
    );
    await controller.start();
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme(),
        home: AppLockGate(
          controller: controller,
          child: const Text('protected conversation'),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('app-lock-surface')), findsOneWidget);
    expect(find.byKey(const ValueKey('recover-app-lock-button')), findsNothing);
    expect(find.byKey(const ValueKey('unlock-app-button')), findsOneWidget);
    expect(find.textContaining('could not be reached'), findsOneWidget);
    expect(writes, isEmpty);
    controller.dispose();
  });

  testWidgets('unlock retries a failed availability check', (tester) async {
    final authenticator = _RecoveringAuthenticator();
    final controller = AppLockController(
      authenticator: authenticator,
      initialEnabled: true,
      persistEnabled: (_) async {},
      observeLifecycle: false,
    );
    await controller.start(prompt: false);
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme(),
        home: AppLockGate(
          controller: controller,
          child: const Text('protected conversation'),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('unlock-app-button')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('unlock-app-button')));
    await tester.pumpAndSettle();

    expect(authenticator.availabilityChecks, 2);
    expect(find.byKey(const ValueKey('app-lock-surface')), findsNothing);
    expect(find.text('protected conversation'), findsOneWidget);
    controller.dispose();
  });

  testWidgets('locked gate replaces dialogs and every navigator route', (
    tester,
  ) async {
    final controller = AppLockController(
      authenticator: _Authenticator(),
      initialEnabled: false,
      persistEnabled: (_) async {},
      observeLifecycle: false,
    );
    await controller.start(prompt: false);
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme(),
        builder: (context, child) =>
            AppLockGate(controller: controller, child: child!),
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => const AlertDialog(
                  content: Text(
                    'revealed recovery phrase',
                    key: ValueKey('protected-dialog-content'),
                  ),
                ),
              ),
              child: const Text('Reveal'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Reveal'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('protected-dialog-content')),
      findsOneWidget,
    );

    await controller.setEnabled(true);
    controller.lock();
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('app-lock-surface')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('protected-dialog-content')),
      findsNothing,
    );
    expect(find.text('Reveal'), findsNothing);
    controller.dispose();
  });
}

final class _Authenticator implements DeviceAuthenticator {
  const _Authenticator({this.supported = true});

  final bool supported;

  @override
  Future<DeviceAuthenticationOutcome> authenticate() async =>
      DeviceAuthenticationOutcome.authenticated;

  @override
  Future<void> cancel() async {}

  @override
  Future<bool> isSupported() async => supported;
}

final class _ThrowingAuthenticator implements DeviceAuthenticator {
  const _ThrowingAuthenticator();

  @override
  Future<DeviceAuthenticationOutcome> authenticate() async =>
      DeviceAuthenticationOutcome.error;

  @override
  Future<void> cancel() async {}

  @override
  Future<bool> isSupported() => Future<bool>.error(StateError('plugin down'));
}

final class _RecoveringAuthenticator implements DeviceAuthenticator {
  int availabilityChecks = 0;

  @override
  Future<DeviceAuthenticationOutcome> authenticate() async =>
      DeviceAuthenticationOutcome.authenticated;

  @override
  Future<void> cancel() async {}

  @override
  Future<bool> isSupported() async {
    availabilityChecks += 1;
    if (availabilityChecks == 1) {
      throw StateError('plugin starting');
    }
    return true;
  }
}
