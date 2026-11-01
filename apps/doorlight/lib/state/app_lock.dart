import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:local_auth/local_auth.dart';

enum DeviceAuthenticationOutcome {
  authenticated,
  rejected,
  canceled,
  temporarilyUnavailable,
  credentialsUnavailable,
  unsupported,
  error,
}

/// Small testable port around the platform-owned device credential prompt.
///
/// Doorlight deliberately does not keep an application PIN or biometric secret.
abstract interface class DeviceAuthenticator {
  Future<bool> isSupported();

  Future<DeviceAuthenticationOutcome> authenticate();

  Future<void> cancel();
}

final class LocalAuthDeviceAuthenticator implements DeviceAuthenticator {
  LocalAuthDeviceAuthenticator([LocalAuthentication? authentication])
    : _authentication = authentication ?? LocalAuthentication();

  final LocalAuthentication _authentication;

  @override
  Future<bool> isSupported() => _authentication.isDeviceSupported();

  @override
  Future<DeviceAuthenticationOutcome> authenticate() async {
    try {
      final authenticated = await _authentication.authenticate(
        localizedReason: 'Unlock Doorlight',
        biometricOnly: false,
        sensitiveTransaction: true,
        persistAcrossBackgrounding: true,
      );
      return authenticated
          ? DeviceAuthenticationOutcome.authenticated
          : DeviceAuthenticationOutcome.rejected;
    } on LocalAuthException catch (error) {
      return switch (error.code) {
        LocalAuthExceptionCode.userCanceled ||
        LocalAuthExceptionCode.systemCanceled ||
        LocalAuthExceptionCode.timeout => DeviceAuthenticationOutcome.canceled,
        LocalAuthExceptionCode.authInProgress ||
        LocalAuthExceptionCode.uiUnavailable ||
        LocalAuthExceptionCode.biometricHardwareTemporarilyUnavailable ||
        LocalAuthExceptionCode.temporaryLockout ||
        LocalAuthExceptionCode.biometricLockout ||
        LocalAuthExceptionCode.userRequestedFallback =>
          DeviceAuthenticationOutcome.temporarilyUnavailable,
        LocalAuthExceptionCode.noCredentialsSet ||
        LocalAuthExceptionCode.noBiometricsEnrolled =>
          DeviceAuthenticationOutcome.credentialsUnavailable,
        LocalAuthExceptionCode.noBiometricHardware =>
          DeviceAuthenticationOutcome.unsupported,
        _ => DeviceAuthenticationOutcome.error,
      };
    } catch (_) {
      return DeviceAuthenticationOutcome.error;
    }
  }

  @override
  Future<void> cancel() async {
    try {
      await _authentication.stopAuthentication();
    } catch (_) {
      // Cancellation is best-effort during disposal. The platform owns the
      // prompt and may already have closed it.
    }
  }
}

enum AppLockAvailability { unknown, available, unavailable }

enum AppLockFailure {
  none,
  rejected,
  canceled,
  temporarilyUnavailable,
  credentialsUnavailable,
  unsupported,
  deviceError,
  persistence,
}

/// Owns the app-lock state machine; the operating system owns authentication.
///
/// Enabling and disabling are both credential-gated. An enabled lock closes as
/// soon as the app is hidden, paused or detached. If credentials were removed outside
/// Doorlight, [recoverByDisablingUnavailableLock] provides an explicit non-bricking
/// recovery path; changing device credentials already requires device access.
final class AppLockController extends ChangeNotifier
    with WidgetsBindingObserver {
  AppLockController({
    required this.authenticator,
    required bool initialEnabled,
    required this.persistEnabled,
    this.observeLifecycle = true,
  }) : _enabled = initialEnabled,
       _locked = initialEnabled,
       _foreground =
           !observeLifecycle ||
           WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed {
    if (observeLifecycle) {
      WidgetsBinding.instance.addObserver(this);
    }
  }

  final DeviceAuthenticator authenticator;
  final Future<void> Function(bool enabled) persistEnabled;
  final bool observeLifecycle;

  bool _enabled;
  bool _locked;
  bool _authenticating = false;
  bool _started = false;
  bool _disposed = false;
  bool _foreground;
  int _foregroundGeneration = 0;
  Future<bool>? _unlockInFlight;
  Future<void>? _availabilityCheckInFlight;
  AppLockAvailability _availability = AppLockAvailability.unknown;
  AppLockFailure _failure = AppLockFailure.none;

  bool get enabled => _enabled;
  bool get locked => _enabled && _locked;
  bool get authenticating => _authenticating;
  bool get checkingAvailability => _availabilityCheckInFlight != null;
  AppLockAvailability get availability => _availability;
  AppLockFailure get failure => _failure;

  Future<void> start({bool prompt = true}) async {
    if (_started || _disposed) return;
    _started = true;
    await _refreshAvailability();
    if (_enabled && prompt && _foreground && !_disposed) {
      await unlock();
    }
  }

  Future<bool> unlock() {
    final inFlight = _unlockInFlight;
    if (inFlight != null) return inFlight;
    final attempt = _performUnlock();
    _unlockInFlight = attempt;
    return attempt.whenComplete(() {
      if (identical(_unlockInFlight, attempt)) {
        _unlockInFlight = null;
      }
    });
  }

  Future<bool> _performUnlock() async {
    if (_disposed) return false;
    if (!_enabled) {
      _setLocked(false);
      return true;
    }
    if (_authenticating) return false;
    final foregroundGeneration = _foregroundGeneration;
    if (!_isCurrentForeground(foregroundGeneration) ||
        !await _ensureAvailable() ||
        !_isCurrentForeground(foregroundGeneration)) {
      return false;
    }

    final outcome = await _authenticate();
    if (outcome == DeviceAuthenticationOutcome.authenticated &&
        _isCurrentForeground(foregroundGeneration)) {
      _failure = AppLockFailure.none;
      _setLocked(false);
      return true;
    }
    _failure = _failureFor(outcome);
    _setLocked(true);
    _notify();
    return false;
  }

  void lock() {
    if (!_enabled || _locked) return;
    _locked = true;
    _notify();
  }

  /// Changes the setting transactionally: state changes only after the
  /// credential check and durable settings write both succeed.
  Future<bool> setEnabled(bool value) async {
    if (_disposed || value == _enabled || _authenticating) {
      return value == _enabled;
    }
    final foregroundGeneration = _foregroundGeneration;
    if (!_isCurrentForeground(foregroundGeneration) ||
        !await _ensureAvailable() ||
        !_isCurrentForeground(foregroundGeneration)) {
      return false;
    }
    final outcome = await _authenticate();
    if (outcome != DeviceAuthenticationOutcome.authenticated) {
      _failure = _failureFor(outcome);
      _notify();
      return false;
    }
    if (!_isCurrentForeground(foregroundGeneration)) {
      _setLocked(_enabled);
      return false;
    }
    try {
      await persistEnabled(value);
    } catch (_) {
      _failure = AppLockFailure.persistence;
      _notify();
      return false;
    }
    _enabled = value;
    _locked = value && !_isCurrentForeground(foregroundGeneration);
    _failure = AppLockFailure.none;
    _notify();
    return true;
  }

  /// Avoids permanently locking out a user whose OS credentials were removed.
  ///
  /// This is intentionally available only after the authenticator positively
  /// reports that device authentication cannot be used.
  Future<bool> recoverByDisablingUnavailableLock() async {
    if (_disposed || !_enabled) return !_enabled;
    if (_failure != AppLockFailure.credentialsUnavailable &&
        _failure != AppLockFailure.unsupported) {
      await _refreshAvailability();
    }
    final recoverable =
        _failure == AppLockFailure.credentialsUnavailable ||
        _failure == AppLockFailure.unsupported;
    if (!recoverable) return false;
    try {
      await persistEnabled(false);
    } catch (_) {
      _failure = AppLockFailure.persistence;
      _notify();
      return false;
    }
    _enabled = false;
    _locked = false;
    _failure = AppLockFailure.none;
    _notify();
    return true;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    if (state == AppLifecycleState.resumed) {
      final shouldPrompt = !_foreground && _enabled && _locked;
      _foreground = true;
      if (shouldPrompt && !_authenticating) {
        unawaited(unlock());
      }
      return;
    }
    // Desktop focus loss and transient system UI can report `inactive` while
    // the app remains visible. Lock only when Flutter says the app is actually
    // hidden, paused, or detached.
    if (state == AppLifecycleState.inactive) return;
    if (_foreground) _foregroundGeneration++;
    _foreground = false;
    lock();
  }

  bool _isCurrentForeground(int generation) =>
      !_disposed && _foreground && generation == _foregroundGeneration;

  Future<bool> _ensureAvailable() async {
    if (_availability == AppLockAvailability.unknown) {
      await _refreshAvailability();
    }
    if (_availability == AppLockAvailability.available) return true;
    if (_availability == AppLockAvailability.unavailable) {
      _failure = AppLockFailure.unsupported;
    }
    _setLocked(_enabled);
    _notify();
    return false;
  }

  Future<void> _refreshAvailability() {
    final inFlight = _availabilityCheckInFlight;
    if (inFlight != null) return inFlight;

    final attempt = _performAvailabilityCheck();
    _availabilityCheckInFlight = attempt;
    _notify();
    return attempt.whenComplete(() {
      if (identical(_availabilityCheckInFlight, attempt)) {
        _availabilityCheckInFlight = null;
        _notify();
      }
    });
  }

  Future<void> _performAvailabilityCheck() async {
    try {
      final supported = await authenticator.isSupported();
      _availability = supported
          ? AppLockAvailability.available
          : AppLockAvailability.unavailable;
      if (!supported) {
        _failure = AppLockFailure.unsupported;
      } else if (_failure == AppLockFailure.unsupported ||
          _failure == AppLockFailure.deviceError) {
        _failure = AppLockFailure.none;
      }
    } catch (_) {
      // A plugin/platform exception is not proof that credentials were
      // removed. Keep the lock closed and offer Retry, never an
      // unauthenticated reset.
      _availability = AppLockAvailability.unknown;
      _failure = AppLockFailure.deviceError;
    }
    _notify();
  }

  Future<DeviceAuthenticationOutcome> _authenticate() async {
    _authenticating = true;
    _failure = AppLockFailure.none;
    _notify();
    try {
      return await authenticator.authenticate();
    } finally {
      _authenticating = false;
      _notify();
    }
  }

  static AppLockFailure _failureFor(DeviceAuthenticationOutcome outcome) {
    return switch (outcome) {
      DeviceAuthenticationOutcome.authenticated => AppLockFailure.none,
      DeviceAuthenticationOutcome.rejected => AppLockFailure.rejected,
      DeviceAuthenticationOutcome.canceled => AppLockFailure.canceled,
      DeviceAuthenticationOutcome.temporarilyUnavailable =>
        AppLockFailure.temporarilyUnavailable,
      DeviceAuthenticationOutcome.credentialsUnavailable =>
        AppLockFailure.credentialsUnavailable,
      DeviceAuthenticationOutcome.unsupported => AppLockFailure.unsupported,
      DeviceAuthenticationOutcome.error => AppLockFailure.deviceError,
    };
  }

  void _setLocked(bool value) {
    if (_locked == value) return;
    _locked = value;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (observeLifecycle) {
      WidgetsBinding.instance.removeObserver(this);
    }
    unawaited(authenticator.cancel());
    super.dispose();
  }
}
