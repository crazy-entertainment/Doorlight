import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/widgets.dart';

String _join(String parent, String name) =>
    parent + Platform.pathSeparator + name;

class UpdateRestartPolicy extends ChangeNotifier {
  UpdateRestartPolicy({Duration Function()? elapsed}) {
    final clock = Stopwatch()..start();
    _elapsed = elapsed ?? (() => clock.elapsed);
  }
  late final Duration Function() _elapsed;
  Duration _lastInput = Duration.zero;
  bool _startup = true;
  bool _inactive = false;
  int revision = 0;
  bool get automaticEligible =>
      _startup ||
      (_inactive && _elapsed() - _lastInput >= const Duration(minutes: 5));
  void activity() {
    _startup = false;
    _lastInput = _elapsed();
    revision++;
    notifyListeners();
  }

  void lifecycle(AppLifecycleState state) {
    final inactive = state != AppLifecycleState.resumed;
    if (!inactive && _inactive) {
      activity();
    }
    _inactive = inactive;
  }

  bool stillEligible(int capturedRevision) =>
      revision == capturedRevision && automaticEligible;
}

class UpdateRestartHandoff {
  UpdateRestartHandoff({
    required this.policy,
    required this.automatic,
    required this.reserve,
    required this.stillSafe,
    required this.prepare,
    required this.commit,
    required this.cancel,
    required this.release,
  });
  final UpdateRestartPolicy policy;
  final bool Function() automatic, reserve, stillSafe;
  final Future<bool> Function() prepare, commit, cancel;
  final VoidCallback release;

  Future<bool> run({
    required Future<void> Function() requestApply,
    required Future<String?> Function() helperState,
    required Future<void> Function() cancelApply,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final revision = policy.revision;
    if (!reserve()) return false;
    var requested = false;
    var committed = false;
    Future<bool>? cancellation;
    final revoked = Completer<bool>();
    bool eligible() =>
        stillSafe() && (!automatic() || policy.stillEligible(revision));
    void activity() {
      if (!automatic() ||
          policy.stillEligible(revision) ||
          cancellation != null) {
        return;
      }
      cancellation = Future.sync(cancel);
      cancellation!.then(
        (cancelled) => revoked.complete(!cancelled),
        onError: (Object error, StackTrace stack) =>
            revoked.completeError(error, stack),
      );
    }

    policy.addListener(activity);
    try {
      if (!await Future.any([prepare().timeout(timeout), revoked.future]) ||
          !eligible()) {
        return false;
      }
      await requestApply();
      requested = true;
      final clock = Stopwatch()..start();
      while (clock.elapsed < timeout) {
        final state = await Future.any([
          helperState().timeout(timeout - clock.elapsed),
          revoked.future.then((_) => 'cancelled'),
        ]);
        if (!eligible()) return false;
        if (state == 'error' || state == 'cancelled') return false;
        if (state == 'shutdownReady') {
          committed = await Future.any([
            commit().timeout(timeout),
            revoked.future,
          ]);
          return committed;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      return false;
    } finally {
      policy.removeListener(activity);
      // Native cancellation bypasses the worker FIFO and invalidates late work.
      // False means quit already committed: keep the helper armed for that exit.
      if (!committed && await (cancellation ?? cancel())) {
        try {
          if (requested) await cancelApply();
        } finally {
          release();
        }
      }
    }
  }
}

class VerifiedUpdateSelection {
  const VerifiedUpdateSelection(
    this.version,
    this.sequence,
    this.manifestSha256,
  );
  final String version, manifestSha256;
  final int sequence;
}

VerifiedUpdateSelection? verifiedUpdateSelection(
  Map<String, dynamic>? value,
  String current,
) {
  if (value == null ||
      value['schema'] != 1 ||
      value['workerPid'] is! int ||
      (value['workerPid'] as int) <= 0 ||
      value['state'] != 'checked' ||
      value['eligible'] is! bool) {
    throw const FormatException('Invalid verified update result');
  }
  if (value['eligible'] == false) return null;
  final version = value['version'];
  final sequence = value['releaseSequence'];
  final digest = value['manifestSha256'];
  if (version is! String ||
      !WindowsUpdate.newer(version, current) ||
      sequence is! int ||
      sequence <= 0 ||
      digest is! String ||
      !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(digest)) {
    throw const FormatException('Invalid verified release binding');
  }
  return VerifiedUpdateSelection(version, sequence, digest.toLowerCase());
}

class WindowsUpdate extends ChangeNotifier with WidgetsBindingObserver {
  WindowsUpdate({
    required this.canRestart,
    required this.reserveRestart,
    required this.restartStillSafe,
    required this.releaseRestart,
    required this.prepareNative,
    required this.cancelNative,
    required this.commitNative,
    required this.identity,
    required this.motion,
  });
  final bool Function() canRestart, reserveRestart, restartStillSafe;
  final VoidCallback releaseRestart;
  final Future<bool> Function() prepareNative, commitNative, cancelNative;
  final String Function() identity;
  final bool Function() motion;
  final policy = UpdateRestartPolicy();
  Timer? _checkTimer, _pollTimer;
  String? availableVersion, error;
  bool checking = false, starting = false, rejected = false;
  bool _automatic = false, _reserved = false, _polling = false;
  bool _disposed = false, _startupReported = false;
  int? _releaseSequence;
  String? _manifestSha256;
  int _checkFailures = 0;
  Directory? _session;
  DateTime? _sessionStarted;
  String _phase = '';
  static final _version = RegExp(r'^\d+\.\d+\.\d+$');
  static final _sessionId = RegExp(r'^[0-9a-f]{32}$');
  String get _local => Platform.environment['LOCALAPPDATA'] ?? '';
  String get _root => _join(_join(_local, 'Programs'), 'Doorlight');
  String get _helper => _join(_root, 'DoorlightUpdater.exe');
  String get _sessions => _join(_join(_local, 'Doorlight'), 'setup-sessions');
  String get _versionPath =>
      _join(File(Platform.resolvedExecutable).parent.path, 'Doorlight.version');
  bool get installed =>
      Platform.isWindows &&
      _local.isNotEmpty &&
      File(Platform.resolvedExecutable).parent.path.toLowerCase() ==
          _join(_root, 'current').toLowerCase() &&
      File(_helper).existsSync();

  void start() {
    if (!installed) return;
    WidgetsBinding.instance.addObserver(this);
    _scheduleCheck(initial: true);
  }

  void _scheduleCheck({bool initial = false}) {
    _checkTimer?.cancel();
    if (_disposed) return;
    final random = Random.secure();
    final seconds = initial
        ? random.nextInt(61)
        : _checkFailures > 0
        ? min(21600, 300 * (1 << min(_checkFailures - 1, 6))) +
              random.nextInt(301)
        : 18000 + random.nextInt(7201);
    _checkTimer = Timer(Duration(seconds: seconds), () async {
      await check();
      _scheduleCheck();
    });
  }

  String _newSessionId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  void activity() => policy.activity();
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      policy.lifecycle(state);

  static bool newer(String candidate, String current) {
    if (_version.stringMatch(candidate) != candidate ||
        _version.stringMatch(current) != current) {
      return false;
    }
    final a = candidate.split('.').map(int.parse).toList();
    final b = current.split('.').map(int.parse).toList();
    for (var i = 0; i < 3; i++) {
      if (a[i] != b[i]) return a[i] > b[i];
    }
    return false;
  }

  Future<Map<String, dynamic>?> _read(File file) async {
    if (!await file.exists()) return null;
    if (await file.length() > 16384) {
      throw const FormatException('Oversized setup message');
    }
    final value = jsonDecode(await file.readAsString());
    return value is Map<String, dynamic> ? value : null;
  }

  Future<void> _write(
    Directory directory,
    String name,
    Map<String, dynamic> value,
  ) async {
    final file = File(_join(directory.path, name));
    final temporary = File('${file.path}.app-new');
    await temporary.writeAsString(jsonEncode(value), flush: true);
    await temporary.rename(file.path);
  }

  Future<bool> _wasRejected(String version) async {
    final file = File(_join(_root, 'rejected-versions.json'));
    if (!await file.exists()) return false;
    if (await file.length() > 4096) return true;
    final versions = jsonDecode(await file.readAsString());
    if (versions is! List ||
        versions.length > 32 ||
        versions.any(
          (item) => item is! String || _version.stringMatch(item) != item,
        )) {
      return true;
    }
    return versions.contains(version);
  }

  Future<void> check({bool prepareAutomatically = true}) async {
    if (!installed || checking || starting) return;
    checking = true;
    error = null;
    notifyListeners();
    Directory? directory;
    try {
      final versionFile = File(_versionPath);
      if (await versionFile.length() > 64) {
        throw const FormatException('Invalid version file');
      }
      final current = (await versionFile.readAsString()).trim();
      if (_version.stringMatch(current) != current) {
        throw const FormatException('Invalid installed version');
      }
      final id = _newSessionId();
      directory = await Directory(_join(_sessions, id)).create(recursive: true);
      // The native helper owns signature verification and persistent rollback
      // protection. The app never chooses packages from hosting API responses.
      await Process.start(_helper, [
        '--check',
        '--session',
        id,
        '--current-version',
        current,
        if (!prepareAutomatically) '--manual',
      ], mode: ProcessStartMode.detached);
      final deadline = Stopwatch()..start();
      Map<String, dynamic>? result;
      while (!_disposed && deadline.elapsed < const Duration(seconds: 90)) {
        result = await _read(File(_join(directory.path, 'check.json')));
        if (result != null) break;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      if (_disposed) return;
      final selection = verifiedUpdateSelection(result, current);
      availableVersion = selection?.version;
      _releaseSequence = selection?.sequence;
      _manifestSha256 = selection?.manifestSha256;
      _checkFailures = 0;
      rejected =
          availableVersion != null && await _wasRejected(availableVersion!);
      if (availableVersion != null && !rejected && prepareAutomatically) {
        unawaited(_prepare(automatic: true));
      }
    } catch (_) {
      _checkFailures++;
      error = 'Could not check for updates. Click to retry.';
    } finally {
      // The worker remains responsible for bounded stale-session pruning. Do not
      // race its executable or erase persistent trust/cache state on failure.
      checking = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> install() async {
    if (!installed || _disposed) return;
    if (_session != null && starting) {
      _automatic = false;
      await _write(_session!, 'window-command.json', {
        'schema': 1,
        'action': 'show',
      });
      return;
    }
    if (_session != null) {
      try {
        await _write(_session!, 'window-command.json', {
          'schema': 1,
          'action': 'close',
        });
      } on FileSystemException {
        // A terminated worker may already have removed its session.
      }
      _session = null;
      _pollTimer?.cancel();
    }
    if (availableVersion == null) await check(prepareAutomatically: false);
    if (availableVersion != null) await _prepare(automatic: false);
  }

  Future<void> _prepare({required bool automatic}) async {
    if (!installed ||
        starting ||
        _disposed ||
        availableVersion == null ||
        (automatic && rejected)) {
      return;
    }
    starting = true;
    error = null;
    _automatic = automatic;
    _phase = 'preparing';
    notifyListeners();
    try {
      final id = _newSessionId();
      final directory = Directory(_join(_sessions, id));
      await directory.create(recursive: true);
      await _write(directory, 'request.json', {
        'schema': 1,
        'appPid': pid,
        'version': availableVersion,
        'installedVersion': (await File(_versionPath).readAsString()).trim(),
        'automatic': automatic,
        'identity': identity(),
        'motion': motion(),
        'retryRejected': !automatic,
        'releaseSequence': _releaseSequence,
        'manifestSha256': _manifestSha256,
      });
      _session = directory;
      _sessionStarted = DateTime.now();
      await Process.start(_helper, [
        '--update',
        '--session',
        id,
        if (automatic) '--silent',
        if (!motion()) '--no-motion',
      ], mode: ProcessStartMode.detached);
      _pollTimer?.cancel();
      _pollTimer = Timer.periodic(
        const Duration(milliseconds: 250),
        (_) => unawaited(_poll()),
      );
    } catch (_) {
      starting = false;
      error = 'Could not start the updater. Doorlight stayed open.';
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _poll() async {
    if (_polling || _disposed || _session == null) return;
    _polling = true;
    try {
      final file = File(_join(_session!.path, 'status.json'));
      final value = await _read(file);
      if (value == null) {
        if (_sessionStarted != null &&
            DateTime.now().difference(_sessionStarted!) >
                const Duration(seconds: 30)) {
          throw const FormatException('Updater did not start');
        }
        return;
      }
      if (value['schema'] != 1 ||
          value['workerPid'] is! int ||
          (value['workerPid'] as int) <= 0 ||
          value['version'] is! String ||
          (value['version'] != '' && value['version'] != availableVersion)) {
        throw const FormatException('Unexpected updater session');
      }
      if (DateTime.now().difference(await file.lastModified()) >
          const Duration(seconds: 15)) {
        throw const FormatException('Updater stopped responding');
      }
      _phase = value['state'] as String;
      if (_phase == 'ready') {
        starting = true;
        if (!_reserved &&
            canRestart() &&
            (!_automatic || policy.automaticEligible)) {
          await _restart();
        }
      } else if (_phase == 'error' || _phase == 'cancelled') {
        starting = false;
        error = _phase == 'error'
            ? 'The update could not finish. Click to retry.'
            : null;
        await _release();
      } else if (_phase == 'preparing' ||
          _phase == 'downloading' ||
          _phase == 'verifying') {
        starting = true;
        error = null;
      }
      if (!_disposed) notifyListeners();
    } catch (_) {
      starting = false;
      error = 'The updater stopped responding. Doorlight stayed open.';
      _pollTimer?.cancel();
      await _release();
      if (!_disposed) notifyListeners();
    } finally {
      _polling = false;
    }
  }

  Future<void> _restart() async {
    _reserved = true;
    try {
      await UpdateRestartHandoff(
        policy: policy,
        automatic: () => _automatic,
        reserve: reserveRestart,
        stillSafe: restartStillSafe,
        prepare: prepareNative,
        commit: commitNative,
        cancel: cancelNative,
        release: releaseRestart,
      ).run(
        requestApply: () {
          final currentIdentity = identity();
          if (RegExp(r'^[0-9a-f]{40}$').stringMatch(currentIdentity) !=
              currentIdentity) {
            throw const FormatException('Update identity is not ready');
          }
          return _write(_session!, 'command.json', {
            'schema': 1,
            'action': 'apply',
            'identity': currentIdentity,
          });
        },
        helperState: () async =>
            (await _read(File(_join(_session!.path, 'status.json'))))?['state']
                as String?,
        cancelApply: () => _write(_session!, 'command.json', {
          'schema': 1,
          'action': 'cancel',
        }),
      );
    } finally {
      _reserved = false;
    }
  }

  Future<void> _release() async {
    if (!_reserved) return;
    try {
      if (await cancelNative()) releaseRestart();
    } finally {
      _reserved = false;
    }
  }

  Future<void> reportStartup({
    required bool ready,
    required String identity,
  }) async {
    if (_startupReported || !ready || !Platform.isWindows) return;
    final id = Platform.environment['DOORLIGHT_SETUP_SESSION'];
    if (id == null || _sessionId.stringMatch(id) != id) return;
    _startupReported = true;
    try {
      await WidgetsBinding.instance.endOfFrame;
      if (await File(_versionPath).length() > 64) {
        throw const FormatException('Invalid startup version');
      }
      final directory = Directory(_join(_sessions, id));
      await _write(directory, 'ready.json', {
        'schema': 1,
        'pid': pid,
        'version': (await File(_versionPath).readAsString()).trim(),
        'identity': identity,
        'ready': true,
      });
    } catch (_) {
      _startupReported = false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _checkTimer?.cancel();
    _pollTimer?.cancel();
    policy.dispose();
    super.dispose();
  }
}
