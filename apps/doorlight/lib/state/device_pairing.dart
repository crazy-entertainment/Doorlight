import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import '../core/jami.dart';

/// Bounded projection of the existing native pairing flow. This is not a
/// pairing journal: only the native protected identity-restore journal owns
/// account reservation, crash recovery, protocol state and terminal evidence.
final class DevicePairingSnapshot {
  const DevicePairingSnapshot({
    required this.token,
    required this.accountId,
    required this.ownerAccountId,
    required this.destination,
    required this.status,
    this.operation = 0,
    this.terminal = false,
    this.recovery = false,
    this.invalidCode = false,
    this.uri = '',
    this.code = '',
    this.peerId = '',
    this.peerDeviceId = '',
    this.deviceId = '',
    this.error = '',
    this.preparedIdentity,
  });
  final String token, accountId, ownerAccountId, status;
  final bool destination, terminal, recovery, invalidCode;
  final int operation;
  final String uri, code, peerId, peerDeviceId, deviceId, error;
  final Map<String, dynamic>? preparedIdentity;
  static final _token = RegExp(r'^[0-9a-f]{64}$');
  static final _account = RegExp(r'^[A-Za-z0-9_-]{1,128}$');
  static final _identity = RegExp(r'^[0-9a-f]{40}$');
  static final _offer = RegExp(
    r'^jami-auth://[0-9a-f]{64}/[1-9][0-9]{5}/doorlight-v1$',
  );
  static bool validToken(String value) => _token.hasMatch(value);
  static bool validOffer(String value) =>
      value.length <= 100 && _offer.hasMatch(value);
  static bool validCode(String value) => RegExp(r'^[0-9]{8}$').hasMatch(value);
  static bool validAccount(String value) => _account.hasMatch(value);

  static DevicePairingSnapshot? fromWire(Object? value) {
    if (value is! Map || value.length > 24) return null;
    final token = value['flowToken'];
    final account = value['accountId'];
    final owner = value['ownerAccountId'];
    final role = value['role'];
    final operation = value['operation'];
    final status = value['status'];
    final terminal = value['terminal'];
    if (token is! String ||
        !validToken(token) ||
        account is! String ||
        !validAccount(account) ||
        owner is! String ||
        (owner.isNotEmpty && !validAccount(owner)) ||
        (role != 'source' && role != 'destination') ||
        operation is! int ||
        operation < 0 ||
        operation > 0x7fffffff ||
        status is! String ||
        !const {
          'starting',
          'waiting',
          'connecting',
          'consent',
          'codeIssued',
          'code',
          'checking',
          'transferring',
          'prepared',
          'confirming',
          'ready',
          'complete',
          'ended',
          'unconfirmed',
          'retired',
        }.contains(status) ||
        terminal is! bool) {
      return null;
    }
    final destination = role == 'destination';
    if (!destination && (owner.isEmpty || owner != account)) return null;
    if (destination &&
        operation != 0 &&
        (operation < 100000 || operation > 999999)) {
      return null;
    }
    String? bounded(String key, int limit) {
      final item = value[key];
      return item is String && item.length <= limit ? item : null;
    }

    final uri = bounded('uri', 100), code = bounded('code', 8);
    final peer = bounded('peerId', 40), source = bounded('peerDeviceId', 64);
    final device = bounded('deviceId', 64), error = bounded('error', 64);
    if (uri == null ||
        code == null ||
        peer == null ||
        source == null ||
        device == null ||
        error == null ||
        (uri.isNotEmpty && !validOffer(uri)) ||
        (code.isNotEmpty && !validCode(code)) ||
        (peer.isNotEmpty && !_identity.hasMatch(peer)) ||
        (source.isNotEmpty && !validToken(source)) ||
        (device.isNotEmpty && (!validToken(device) || device == source))) {
      return null;
    }
    if (value['invalidCode'] is! bool ||
        (value['recovery'] != null && value['recovery'] is! bool)) {
      return null;
    }
    if ((status == 'waiting' && (!destination || uri.isEmpty)) ||
        (status == 'codeIssued' && (destination || code.isEmpty)) ||
        (terminal && (uri.isNotEmpty || code.isNotEmpty))) {
      return null;
    }
    if (const {'prepared', 'ready', 'complete'}.contains(status) &&
        (peer.isEmpty || source.isEmpty || device.isEmpty)) {
      return null;
    }
    if ((status == 'complete' || status == 'ready' || status == 'ended') &&
        !terminal) {
      return null;
    }
    final prepared = value['preparedIdentity'];
    Map<String, dynamic>? preparedMap;
    if (prepared != null) {
      if (prepared is! Map ||
          prepared.length > 24 ||
          prepared.keys.any((key) => key is! String) ||
          !destination ||
          status != 'ready' ||
          !terminal ||
          prepared['status'] != 'prepared' ||
          prepared['enabled'] != false ||
          prepared['devicePairing'] != true ||
          prepared['settingsAlreadyNormalized'] != true ||
          prepared['accountId'] != account ||
          prepared['restoreToken'] != token ||
          prepared['jamiId'] != peer ||
          prepared['settingsDocument'] is! String ||
          utf8.encode(prepared['settingsDocument'] as String).length >
              JamiClient.maxSettingsDocumentBytes) {
        return null;
      }
      preparedMap = Map<String, dynamic>.unmodifiable(
        prepared.cast<String, dynamic>(),
      );
    }
    if (status == 'ready' && preparedMap == null) return null;
    return DevicePairingSnapshot(
      token: token,
      accountId: account,
      ownerAccountId: owner,
      destination: destination,
      operation: operation,
      status: status,
      terminal: terminal,
      recovery: value['recovery'] == true,
      invalidCode: value['invalidCode'] == true,
      uri: uri,
      code: code,
      peerId: peer,
      peerDeviceId: source,
      deviceId: device,
      error: error,
      preparedIdentity: preparedMap,
    );
  }

  DevicePairingSnapshot retired({String status = 'unconfirmed'}) =>
      DevicePairingSnapshot(
        token: token,
        accountId: accountId,
        ownerAccountId: ownerAccountId,
        destination: destination,
        operation: operation,
        status: status,
        terminal: status == 'complete' || terminal,
        recovery: destination && status != 'complete' && status != 'discarded',
      );

  bool follows(DevicePairingSnapshot previous) =>
      token == previous.token &&
      ownerAccountId == previous.ownerAccountId &&
      destination == previous.destination &&
      (previous.accountId.isEmpty || accountId == previous.accountId) &&
      (previous.operation == 0 || operation == previous.operation) &&
      (previous.peerId.isEmpty ||
          peerId.isEmpty ||
          peerId == previous.peerId) &&
      (previous.peerDeviceId.isEmpty ||
          peerDeviceId.isEmpty ||
          peerDeviceId == previous.peerDeviceId) &&
      (previous.deviceId.isEmpty ||
          deviceId.isEmpty ||
          deviceId == previous.deviceId);
  @override
  String toString() => 'DevicePairingSnapshot(<private>)';
}

/// Ephemeral UI lease over the native, sealed identity-restore journal.
/// Neither credentials nor a second durable pairing state are stored in Dart.
class DevicePairingController extends ChangeNotifier {
  DevicePairingController({
    required this.client,
    required this.currentOwner,
    required this.foreground,
    this.visible,
    required this.preparePrivacy,
    required this.activateIdentity,
    required this.guardChanged,
    this.pollInterval = const Duration(seconds: 1),
  });
  final JamiClient client;
  final (String?, int) Function() currentOwner;
  final bool Function() foreground;
  final bool Function()? visible;
  bool get _visible => visible?.call() ?? foreground();
  final Future<String> Function(String, bool Function()) preparePrivacy;
  final Future<void> Function(Map<String, dynamic>, bool Function())
  activateIdentity;
  final void Function(bool) guardChanged;
  final Duration pollInterval;
  DevicePairingSnapshot? snapshot;
  // Conservative display estimate anchored before native admission. Native
  // expiry remains authoritative; reopening a page cannot extend this offer.
  DateTime? _offerExpiresAt;
  DateTime? get offerExpiresAt => _offerExpiresAt;
  String? error;
  String? _token;
  String _nativeOwner = '';
  (String?, int)? _owner;
  bool _destination = false, _retired = false, _disposed = false;
  bool busy = false, _activating = false, _recovering = false;
  int _revision = 0;
  Timer? _poll;
  Map<String, dynamic>? _preparedRecovery;
  String? _localDocument;
  bool get hasVisit => _token != null;
  bool get needsRecovery =>
      hasVisit &&
      _destination &&
      (_retired || snapshot?.recovery == true || error != null);
  bool get canActivate =>
      !busy &&
      !_disposed &&
      foreground() &&
      !_retired &&
      (snapshot?.status == 'ready' || _preparedRecovery != null);
  bool _owns(int revision) =>
      !_disposed &&
      !_retired &&
      revision == _revision &&
      _owner == currentOwner() &&
      _visible;
  void reconcile() {
    if (_disposed) return;
    if (!hasVisit) {
      if (_recovering && (!foreground() || _owner != currentOwner())) {
        ++_revision;
        _owner = null;
      }
      return;
    }
    if (_retired) return;
    final installing = _activating && currentOwner().$1 == snapshot?.accountId;
    if (!_visible || (_owner != currentOwner() && !installing)) retire();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void _schedule() {
    _poll?.cancel();
    if (_owns(_revision) && snapshot?.terminal != true && error == null) {
      _poll = Timer(
        snapshot?.status == 'starting' &&
                pollInterval > const Duration(milliseconds: 250)
            ? const Duration(milliseconds: 250)
            : pollInterval,
        () => unawaited(refresh()),
      );
    }
  }

  Future<Map<String, dynamic>> _request(
    String action, {
    String uri = '',
    String code = '',
    String document = '',
    Map<String, String> network = const {},
    bool appearOffline = false,
  }) => client
      .devicePairing(
        action: action,
        flowToken: _token!,
        accountId: snapshot?.accountId ?? '',
        expectedAccountId: _nativeOwner,
        uri: uri,
        code: code,
        settingsDocument: document,
        network: network,
        appearOffline: appearOffline,
      )
      .timeout(const Duration(seconds: 30));
  void _accept(Map<String, dynamic> wire) {
    final next = DevicePairingSnapshot.fromWire(wire);
    if (next == null ||
        next.token != _token ||
        next.ownerAccountId != _nativeOwner ||
        next.destination != _destination ||
        (snapshot != null && !next.follows(snapshot!))) {
      throw const FormatException('Device-link owner changed');
    }
    if (next.status == 'ready' &&
        (_localDocument == null ||
            next.preparedIdentity?['settingsDocument'] != _localDocument)) {
      throw const FormatException('Device-link policy changed');
    }
    snapshot = next;
  }

  Future<bool> begin({
    required bool destination,
    String uri = '',
    Map<String, String> network = const {},
    bool appearOffline = false,
  }) async {
    if (hasVisit ||
        busy ||
        !foreground() ||
        (destination ? currentOwner().$1 != null : currentOwner().$1 == null) ||
        (!destination &&
            (!DevicePairingSnapshot.validOffer(uri) || appearOffline))) {
      return false;
    }
    _owner = currentOwner();
    _nativeOwner = _owner!.$1 ?? '';
    _destination = destination;
    _offerExpiresAt = destination
        ? DateTime.now().add(const Duration(minutes: 5))
        : null;
    _retired = false;
    error = null;
    snapshot = null;
    _preparedRecovery = null;
    _localDocument = null;
    final random = Random.secure();
    _token = List.generate(
      32,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final revision = ++_revision;
    busy = true;
    guardChanged(true);
    _changed();
    try {
      final wire = await _request(
        destination ? 'begin' : 'connect',
        uri: uri,
        network: network,
        appearOffline: appearOffline,
      );
      if (!_owns(revision)) return false;
      _accept(wire);
      return true;
    } catch (_) {
      if (_owns(revision)) {
        error =
            'Link admission is unconfirmed. Recover or cancel this operation; do not start another.';
        retire();
      }
      return false;
    } finally {
      if (revision == _revision || _retired) busy = false;
      _schedule();
      _changed();
    }
  }

  Future<void> refresh() => _command('read');
  Future<void> approve() => _command('approve');
  Future<void> submitCode(String code) async {
    if (!DevicePairingSnapshot.validCode(code) || snapshot?.status != 'code') {
      return;
    }
    await _command('code', code: code);
  }

  Future<void> _command(String action, {String code = ''}) async {
    if (!hasVisit || busy || !_owns(_revision) || snapshot?.terminal == true) {
      return;
    }
    if (action != 'read' && !foreground()) return;
    if (action == 'approve' && snapshot?.status != 'consent') return;
    final revision = _revision;
    busy = true;
    _poll?.cancel();
    error = null;
    _changed();
    try {
      final wire = await _request(action, code: code);
      if (!_owns(revision)) return;
      _accept(wire);
      if (snapshot!.destination &&
          snapshot!.status == 'prepared' &&
          foreground()) {
        final document = await preparePrivacy(
          snapshot!.accountId,
          () => _owns(revision) && foreground(),
        );
        if (!_owns(revision) || !foreground()) return;
        _localDocument = document;
        final prepared = await _request('prepare', document: document);
        if (!_owns(revision)) return;
        _accept(prepared);
      }
    } catch (_) {
      if (_owns(revision) && foreground()) {
        error =
            'Link progress is unconfirmed. The destination must remain inactive until recovery.';
        retire();
      }
    } finally {
      busy = false;
      _schedule();
      _changed();
    }
  }

  Future<bool> activate() async {
    if (!canActivate || !_owns(_revision)) return false;
    final prepared = _preparedRecovery ?? snapshot?.preparedIdentity;
    if (prepared == null ||
        prepared['accountId'] != snapshot?.accountId ||
        prepared['restoreToken'] != _token ||
        prepared['devicePairing'] != true ||
        prepared['settingsDocument'] != _localDocument) {
      return false;
    }
    final revision = _revision;
    busy = true;
    _activating = true;
    _poll?.cancel();
    _changed();
    try {
      await activateIdentity(prepared, () => _owns(revision) && foreground());
      if (_disposed ||
          _retired ||
          revision != _revision ||
          !foreground() ||
          currentOwner().$1 != snapshot!.accountId) {
        return false;
      }
      snapshot = snapshot!.retired(status: 'complete');
      _token = null;
      _preparedRecovery = null;
      _localDocument = null;
      guardChanged(false);
      return true;
    } catch (_) {
      if (!_disposed && revision == _revision) {
        error =
            'Activation was not confirmed. Recover the exact pending operation before continuing.';
        retire();
      }
      return false;
    } finally {
      _activating = false;
      busy = false;
      _changed();
    }
  }

  /// Retire UI authority immediately, even while native admission is queued.
  /// A cancellation command is not proof that the other endpoint rolled back.
  void retire() {
    if (!hasVisit || _retired) return;
    _retired = true;
    ++_revision;
    _poll?.cancel();
    snapshot = snapshot?.retired();
    _preparedRecovery = null;
    _localDocument = null;
    unawaited(_request('retire').then<void>((_) {}, onError: (Object _) {}));
    if (!_destination) guardChanged(false);
    _changed();
  }

  bool restoreFromJournal(Map<String, dynamic> pending) {
    if (pending['status'] != 'pairing' && pending['devicePairing'] != true) {
      return false;
    }
    final wire = pending['pairing'];
    if (wire is! Map) {
      throw const FormatException('Missing device-link recovery owner');
    }
    final next = DevicePairingSnapshot.fromWire(
      Map<String, dynamic>.from(wire),
    );
    if (next == null ||
        !next.destination ||
        !next.recovery ||
        (_token != null && _token != next.token) ||
        (snapshot != null && !next.follows(snapshot!))) {
      throw const FormatException('Device-link recovery owner changed');
    }
    final wasRetired = hasVisit && _retired;
    final tokenChanged = _token != next.token;
    ++_revision;
    _poll?.cancel();
    _owner = currentOwner();
    _nativeOwner = next.ownerAccountId;
    _token = next.token;
    _destination = true;
    if (tokenChanged) _offerExpiresAt = null;
    _retired = wasRetired;
    snapshot = next;
    _preparedRecovery = null;
    _localDocument = null;
    error = null;
    if (pending['status'] == 'prepared' &&
        pending['devicePairing'] == true &&
        pending['enabled'] == false &&
        pending['settingsAlreadyNormalized'] == true &&
        pending['accountId'] == next.accountId &&
        pending['restoreToken'] == next.token &&
        pending['settingsDocument'] is String &&
        (pending['settingsDocument'] as String).isNotEmpty &&
        utf8.encode(pending['settingsDocument'] as String).length <=
            JamiClient.maxSettingsDocumentBytes &&
        pending['jamiId'] is String &&
        RegExp(r'^[0-9a-f]{40}$').hasMatch(pending['jamiId'] as String)) {
      _preparedRecovery = Map<String, dynamic>.unmodifiable(pending);
      _localDocument = pending['settingsDocument'] as String;
    }
    guardChanged(true);
    _changed();
    return true;
  }

  Future<void> recover() async {
    if (busy || !foreground() || _disposed || (hasVisit && !needsRecovery)) {
      return;
    }
    final revision = _revision;
    final owner = currentOwner();
    final token = _token;
    _owner = owner;
    _recovering = true;
    bool current() =>
        !_disposed &&
        foreground() &&
        revision == _revision &&
        owner == currentOwner() &&
        token == _token;
    busy = true;
    _changed();
    try {
      final pending = await client.getPendingIdentityRestore().timeout(
        const Duration(seconds: 30),
      );
      if (!current()) return;
      if (pending['status'] == 'none') {
        _clear();
      } else if (!restoreFromJournal(pending)) {
        error = 'Native identity recovery is still required.';
      }
    } catch (_) {
      if (current()) {
        error =
            'Could not read the pending link. Its identity has not been adopted.';
      }
    } finally {
      _recovering = false;
      busy = false;
      _changed();
    }
  }

  Future<bool> cancel() async {
    if (!hasVisit) return true;
    retire();
    if (busy || !foreground() || _disposed) return false;
    if (!_destination) {
      _clear();
      _changed();
      return true;
    }
    if (snapshot == null) {
      await recover();
      if (!hasVisit) return true;
      if (snapshot == null) return false;
    }
    final revision = _revision;
    final owner = currentOwner();
    final token = _token;
    busy = true;
    _changed();
    try {
      final wire = await _request('discard');
      if (_disposed ||
          !foreground() ||
          revision != _revision ||
          owner != currentOwner() ||
          token != _token) {
        return false;
      }
      if (wire['status'] != 'discarded' ||
          wire['flowToken'] != _token ||
          wire['accountId'] != snapshot!.accountId) {
        error = 'Cleanup is unconfirmed. Keep this operation for recovery.';
        return false;
      }
      _clear();
      return true;
    } catch (_) {
      error =
          'Could not confirm removal of the inactive destination. Retry recovery.';
      return false;
    } finally {
      busy = false;
      _changed();
    }
  }

  void _clear() {
    ++_revision;
    _poll?.cancel();
    _token = null;
    _offerExpiresAt = null;
    _owner = null;
    _nativeOwner = '';
    _retired = true;
    snapshot = null;
    _preparedRecovery = null;
    _localDocument = null;
    error = null;
    guardChanged(false);
  }

  @override
  void dispose() {
    if (_disposed) return;
    retire();
    _poll?.cancel();
    _disposed = true;
    super.dispose();
  }
}
