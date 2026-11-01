import 'package:flutter/material.dart';

import '../state/app_lock.dart';
import '../theme.dart';
import 'windows_chrome.dart';

/// Replaces the application subtree while the OS-credential app lock is shut.
///
/// The protected UI is not painted, focused, or exposed to semantics while
/// locked. Platform capture protection is a separate defense-in-depth layer.
final class AppLockGate extends StatelessWidget {
  const AppLockGate({super.key, required this.controller, required this.child});

  final AppLockController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (!controller.locked) return child;
        return WindowsChromeContent(
          compactContentAvailable: false,
          child: _LockedSurface(controller: controller),
        );
      },
    );
  }
}

final class _LockedSurface extends StatelessWidget {
  const _LockedSurface({required this.controller});

  final AppLockController controller;

  @override
  Widget build(BuildContext context) {
    final unavailable =
        controller.failure == AppLockFailure.credentialsUnavailable ||
        controller.failure == AppLockFailure.unsupported;
    final message = switch (controller.failure) {
      AppLockFailure.none => 'Use your device credential to continue.',
      AppLockFailure.rejected =>
        'Doorlight stayed locked. Try again when ready.',
      AppLockFailure.canceled => 'Unlock was canceled.',
      AppLockFailure.temporarilyUnavailable =>
        'Device authentication is temporarily unavailable.',
      AppLockFailure.credentialsUnavailable || AppLockFailure.unsupported =>
        'This device no longer has an available unlock method.',
      AppLockFailure.deviceError =>
        'Device authentication could not be reached. Try again.',
      AppLockFailure.persistence =>
        'The lock setting could not be saved. Doorlight stayed locked.',
    };

    return Scaffold(
      key: const ValueKey('app-lock-surface'),
      backgroundColor: context.syblColors.bg,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Semantics(
                container: true,
                label: 'Doorlight is locked',
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: context.syblColors.surfaceHi,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: context.syblColors.lineStrong,
                        ),
                      ),
                      child: SizedBox.square(
                        dimension: 72,
                        child: Icon(
                          Icons.lock_outline_rounded,
                          color: context.syblColors.amber,
                          size: 30,
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'Doorlight is locked',
                      textAlign: TextAlign.center,
                      style: context.syblColors.display.copyWith(fontSize: 24),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      message,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: context.syblColors.muted,
                        fontSize: 13,
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 22),
                    if (controller.authenticating ||
                        controller.checkingAvailability)
                      const SizedBox.square(
                        dimension: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else ...[
                      FilledButton.icon(
                        key: const ValueKey('unlock-app-button'),
                        autofocus: true,
                        onPressed: unavailable
                            ? null
                            : () => controller.unlock(),
                        icon: const Icon(Icons.lock_open_rounded, size: 18),
                        label: const Text('Unlock'),
                      ),
                      if (unavailable) ...[
                        const SizedBox(height: 10),
                        TextButton(
                          key: const ValueKey('recover-app-lock-button'),
                          onPressed: () =>
                              controller.recoverByDisablingUnavailableLock(),
                          child: const Text('Turn off unavailable lock'),
                        ),
                      ],
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
