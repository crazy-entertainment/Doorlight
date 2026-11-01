import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue, reason: 'missing contract source: $path');
  return file.readAsStringSync();
}

String _section(
  String source,
  String start,
  String end, {
  required String owner,
}) {
  final from = source.indexOf(start);
  expect(from, greaterThanOrEqualTo(0), reason: '$owner lost `$start`');
  final to = source.indexOf(end, from + start.length);
  expect(to, greaterThan(from), reason: '$owner lost boundary `$end`');
  return source.substring(from, to);
}

String _dispatch(
  String source,
  String marker,
  RegExp next, {
  required String owner,
}) {
  final from = source.indexOf(marker);
  expect(from, greaterThanOrEqualTo(0), reason: '$owner lost `$marker`');
  final afterMarker = from + marker.length;
  final boundary = next.firstMatch(source.substring(afterMarker));
  expect(boundary, isNotNull, reason: '$owner lost the next dispatch boundary');
  return source.substring(from, afterMarker + boundary!.start);
}

void _expectAll(String owner, String source, Iterable<String> contracts) {
  final semanticSource = source.replaceAll(RegExp(r'\s+'), ' ');
  for (final contract in contracts) {
    final semanticContract = contract.replaceAll(RegExp(r'\s+'), ' ');
    expect(
      semanticSource,
      contains(semanticContract),
      reason: '$owner lost `$contract`',
    );
  }
}

void _expectMatch(String owner, String source, RegExp contract) {
  expect(
    contract.hasMatch(source),
    isTrue,
    reason: '$owner no longer matches $contract',
  );
}

void _expectOrdered(String owner, String source, Iterable<String> contracts) {
  final semanticSource = source.replaceAll(RegExp(r'\s+'), ' ');
  var cursor = -1;
  for (final contract in contracts) {
    final semanticContract = contract.replaceAll(RegExp(r'\s+'), ' ');
    final next = semanticSource.indexOf(semanticContract, cursor + 1);
    expect(
      next,
      greaterThan(cursor),
      reason: '$owner lost ordering at `$contract`',
    );
    cursor = next;
  }
}

void main() {
  late String dartBridge;
  late String appState;
  late String androidChannel;
  late String androidCore;
  late String androidPresence;
  late String androidGate;
  late String androidDirectorGuard;
  late String androidMessageNotifications;
  late String androidBoundedFileCopy;
  late String androidFileOwnership;
  late String androidJniInterface;
  late String androidJniConversation;
  late String androidJniDataTransfer;
  late String androidGeneratedService;
  late String windowsChannel;
  late String windowsBridge;
  late String windowsHeader;
  late String windowsHostHeader;
  late String windowsMain;
  late String windowsCmake;
  late String windowsPresenceHeader;
  late String windowsPresence;
  late String windowsGate;
  late String windowsPickedFileHeader;
  late String windowsPickedFile;
  late String avatarUi;
  late String profileEditor;

  setUpAll(() {
    dartBridge = _read('lib/core/jami.dart');
    appState = _read('lib/state/app_state.dart');
    androidChannel = _read(
      'android/app/src/main/kotlin/app/sybl/sybl/MainActivity.kt',
    );
    androidCore = _read(
      'android/app/src/main/kotlin/app/sybl/sybl/JamiCore.kt',
    );
    androidPresence = _read(
      'android/app/src/main/kotlin/app/sybl/sybl/PresenceWire.kt',
    );
    androidGate = _read(
      'android/app/src/main/kotlin/app/sybl/sybl/PendingRequestGate.kt',
    );
    androidDirectorGuard = _read(
      'android/app/src/main/kotlin/app/sybl/sybl/DirectorCallbackGuard.kt',
    );
    androidMessageNotifications = _read(
      'android/app/src/main/kotlin/app/sybl/sybl/MessageNotifications.kt',
    );
    androidBoundedFileCopy = _read(
      'android/app/src/main/kotlin/app/sybl/sybl/BoundedFileCopy.kt',
    );
    androidFileOwnership = _read(
      'android/app/src/main/kotlin/app/sybl/sybl/FileOwnership.kt',
    );
    androidJniInterface = _read(
      '../../native/jami/bin/jni/jni_interface.i',
    );
    androidJniConversation = _read(
      '../../native/jami/bin/jni/conversation.i',
    );
    androidJniDataTransfer = _read(
      '../../native/jami/bin/jni/datatransfer.i',
    );
    androidGeneratedService = _read(
      'android/app/src/main/java/net/jami/daemon/JamiService.java',
    );
    windowsChannel = _read('windows/runner/jami_channels.cpp');
    windowsBridge = _read('windows/runner/jami_bridge.cpp');
    windowsHeader = _read('windows/runner/jami_bridge.h');
    windowsHostHeader = _read('windows/runner/remote_control_host.h');
    windowsMain = _read('windows/runner/main.cpp');
    windowsCmake = _read('windows/CMakeLists.txt');
    windowsPresenceHeader = _read('windows/runner/presence_wire.h');
    windowsPresence = _read('windows/runner/presence_wire.cpp');
    windowsGate = _read('windows/runner/pending_request_gate.h');
    windowsPickedFileHeader = _read('windows/runner/picked_file_staging.h');
    windowsPickedFile = _read('windows/runner/picked_file_staging.cpp');
    avatarUi = _read('lib/ui/sybl_ui.dart');
    profileEditor = _read('lib/ui/profile_picture_editor.dart');
  });

  test('Android secure-frame deadline fails closed', () {
    final sensitiveSurface = _section(
      androidChannel,
      '"setAndroidSensitiveSurface" ->',
      '"setAnnotationOverlay",',
      owner: 'Android sensitive surface',
    );
    expect(
      sensitiveSurface,
      contains('registerFrameCommitCallback { main.post(answer) }'),
    );
    expect(sensitiveSurface, isNot(contains('postDelayed(answer')));
    _expectOrdered('Android secure-frame deadline', sensitiveSurface, const [
      'main.postDelayed({',
      'if (!answered)',
      'answered = true',
      'result.success(false)',
    ]);
  });

  test('Android topic API stays identical across SWIG and Java', () {
    const sendMessage =
        'sendMessageWithId(const std::string& accountId, const std::string& conversationId, const std::string& message, const std::string& replyTo, const std::string& syblTopic)';
    const sendEvent =
        'sendSybLTopicEventWithId(const std::string& accountId, const std::string& conversationId, const std::string& body)';
    const sendFile =
        'sendFile(const std::string& accountId, const std::string& conversationId, const std::string& path, const std::string& displayName, const std::string& replyTo, const std::string& syblTopic)';
    _expectAll('Android conversation SWIG', androidJniConversation, const [
      sendMessage,
      sendEvent,
    ]);
    _expectAll('Android file SWIG', androidJniDataTransfer, const [sendFile]);
    _expectAll('Android generated service', androidGeneratedService, const [
      'sendMessageWithId(accountId, conversationId, message, replyTo, syblTopic)',
      'sendSybLTopicEventWithId(accountId, conversationId, body)',
      'sendFile(accountId, conversationId, path, displayName, replyTo, syblTopic)',
    ]);
  });

  test('startup adopts only and surfaces explicit status or failure', () {
    final dartEnsure = _section(
      dartBridge,
      'Future<Map<String, dynamic>> ensureAccount(',
      'Future<String> myJamiId()',
      owner: 'Dart ensureAccount',
    );
    _expectAll('Dart ensureAccount', dartEnsure, const [
      'bool createIfMissing = false',
      "'createIfMissing': createIfMissing",
    ]);

    final boot = _section(
      appState,
      'Future<void> _boot() async',
      'Future<void> setAppearOffline(',
      owner: 'Dart boot',
    );
    _expectAll('Dart boot', boot, const [
      'await _adoptAccount(',
      'Screen.onboarding',
    ]);
    expect(
      boot,
      isNot(contains('createIfMissing: true')),
      reason: 'boot must never create an identity implicitly',
    );
    final adoption = _section(
      appState,
      'Future<bool> _adoptAccount(',
      'Future<void> _installAccountResult(',
      owner: 'Dart account adoption',
    );
    _expectAll('Dart account adoption', adoption, const [
      'bool createIfMissing = false',
      'createIfMissing: createIfMissing',
      "if (_asString(r['status']) == 'noAccount') {",
      'accountId = null',
      "['accountId', 'peerId']",
      'await prefs.remove(key)',
    ]);
    final onboarding = _section(
      appState,
      'Future<void> onboard(',
      'Future<String?> pickProfileImage()',
      owner: 'Dart onboarding',
    );
    _expectAll('Dart onboarding', onboarding, const ['createIfMissing: true']);
    final guardedBoot = _section(
      appState,
      'Future<void> _bootGuarded()',
      'Future<void> retryBoot()',
      owner: 'Dart guarded boot',
    );
    _expectAll('Dart guarded boot', guardedBoot, const [
      'catch (e)',
      "profileProtectionUnavailable = e is PlatformException && e.code == 'archive_protection_failed'",
      'bootError = profileProtectionUnavailable',
      '? "Couldn\'t open the saved profile."',
      ': pendingIdentityRecovery',
      '? identityRecoveryTitle',
      ': "Couldn\'t start the engine."',
    ]);

    final androidDispatch = _dispatch(
      androidChannel,
      '"ensureAccount" -> {',
      RegExp(r'\n\s*"[^"]+"\s*->'),
      owner: 'Android ensureAccount dispatch',
    );
    _expectAll('Android ensureAccount dispatch', androidDispatch, const [
      'call.argument<Boolean>("createIfMissing") ?: false',
      'JamiCore.start()',
      'JamiCore.ensureAccount(',
      'createIfMissing,',
      'result.success(response)',
      'result.error("native_startup_failed"',
    ]);
    final androidEnsure = _section(
      androidCore,
      'fun ensureAccount(',
      'private fun createAccount(',
      owner: 'Android ensureAccount',
    );
    _expectAll('Android ensureAccount', androidEnsure, const [
      'createIfMissing: Boolean = false',
      'existing == null && !createIfMissing',
      'mapOf("status" to "noAccount")',
      '"status" to "ok"',
    ]);

    final windowsDispatch = _dispatch(
      windowsChannel,
      'if (method == "ensureAccount") {',
      RegExp(r'\n\s*} else if \(method == "[^"]+"\)'),
      owner: 'Windows ensureAccount dispatch',
    );
    _expectAll('Windows ensureAccount dispatch', windowsDispatch, const [
      'ArgBool(call, "createIfMissing", false)',
      'jami_bridge::RetryBoot()',
      'create_if_missing,',
      'if (a.status == "error")',
      'res->Error("native_startup_failed"',
      'EncodableValue("status")',
    ]);
    final windowsEnsure = _section(
      windowsBridge,
      'void EnsureAccount(',
      'void MyJamiId(',
      owner: 'Windows ensureAccount',
    );
    _expectAll('Windows ensureAccount', windowsEnsure, const [
      'bool createIfMissing',
      'list.empty() && !createIfMissing',
      'acc.status = "noAccount"',
      'acc.status = "ok"',
      'done(Account{})',
    ]);
    _expectAll('Windows account failure status', windowsHeader, const [
      'std::string status = "error"',
    ]);

    final androidBoot = _section(
      androidCore,
      'fun start() {',
      '/** Run a daemon op on the worker thread;',
      owner: 'Android daemon boot',
    );
    _expectAll('Android daemon boot', androidBoot, const [
      'if (started) return@execute',
      'if (!daemonInitAttempted)',
      'daemonInitAttempted = true',
      'daemonInitSucceeded = JamiService.init(cfg, call, pres, data, video, conv, net)',
      'check(daemonInitSucceeded)',
      'if (!daemonStartAttempted)',
      'daemonStartAttempted = true',
      'daemonStartSucceeded = JamiService.start()',
      'check(daemonStartSucceeded)',
      'check(initializeArchiveProtection(list))',
      'pinCallPolicy(picked)',
      'refreshRoutingSnapshot(picked)',
      'started = false',
    ]);
    _expectOrdered('Android daemon readiness', androidBoot, const [
      'if (!daemonInitAttempted)',
      'daemonInitAttempted = true',
      'daemonInitSucceeded = JamiService.init(cfg, call, pres, data, video, conv, net)',
      'check(daemonInitSucceeded)',
      'if (!daemonStartAttempted)',
      'daemonStartAttempted = true',
      'daemonStartSucceeded = JamiService.start()',
      'check(daemonStartSucceeded)',
      'var list = JamiService.getAccountList()',
      'check(initializeArchiveProtection(list))',
      'refreshRoutingSnapshot(picked)',
      'started = true',
    ]);
    final androidNativeInit = _section(
      androidJniInterface,
      'bool init(',
      'bool start()',
      owner: 'Android native daemon init',
    );
    _expectAll('Android native daemon init', androidNativeInit, const [
      'if (!libjami::init(',
      'return false',
      'registerSignalHandlers(callEvHandlers)',
      'registerSignalHandlers(networkServiceEvHandlers)',
      'return true',
    ]);
    expect(
      androidNativeInit,
      isNot(contains('libjami::start()')),
      reason:
          'native init must not hide or duplicate the independently retryable start phase',
    );
    _expectAll('Android native daemon start', androidJniInterface, const [
      'bool start() { return libjami::start(); }',
    ]);
    expect(
      androidEnsure.indexOf('check(started)'),
      greaterThanOrEqualTo(0),
      reason: 'Android account adoption must wait for successful daemon init',
    );

    final windowsBoot = _section(
      windowsBridge,
      'void BootDaemon() {',
      'void Start() {',
      owner: 'Windows daemon boot',
    );
    _expectAll('Windows daemon boot', windowsBoot, const [
      'g_daemonReady.store(false)',
      'if (!g_daemonInitialized.load())',
      'g_daemonInitAttempted.exchange(true)',
      'if (!g_signalHandlersRegistered.load())',
      'if (!g_daemonStarted.load())',
      'g_daemonStartAttempted.exchange(true)',
      'libjami::init(',
      'libjami::start()',
      'InitializeArchiveProtection(list)',
      'RefreshRoutingSnapshot(picked)',
      'g_daemonReady.store(true)',
    ]);
    _expectOrdered('Windows daemon readiness', windowsBoot, const [
      'if (!g_daemonInitialized.load())',
      'g_daemonInitAttempted.exchange(true)',
      'libjami::init(',
      'g_daemonInitialized.store(true)',
      'Log("init=OK")',
      'if (!g_signalHandlersRegistered.load())',
      'g_signalHandlersRegistered.store(true)',
      'Log("signal handlers registered")',
      'if (!g_daemonStarted.load())',
      'g_daemonStartAttempted.exchange(true)',
      'libjami::start()',
      'g_daemonStarted.store(true)',
      'Log("start=OK")',
      'InitializeArchiveProtection(list)',
      'RefreshRoutingSnapshot(picked)',
      'g_daemonReady.store(true)',
    ]);
    final windowsRetryBoot = _section(
      windowsBridge,
      'void RetryBoot() noexcept',
      'void Start()',
      owner: 'Windows daemon retry',
    );
    _expectOrdered('Windows worker startup retry', windowsRetryBoot, const [
      'needsStart = !g_everStarted',
      'if (needsStart)',
      'Start()',
      'return',
      'Post(BootDaemon)',
    ]);
    expect(
      windowsRetryBoot,
      contains('try { Log("BootDaemon retry post failed"); } catch (...) {}'),
      reason:
          'the noexcept retry boundary must not terminate while reporting resource exhaustion',
    );
    expect(
      windowsEnsure,
      contains('!g_daemonReady.load()'),
      reason: 'Windows account adoption must wait for successful daemon init',
    );
    _expectAll('Windows process boundary', windowsMain, const [
      'SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_APPLICATION_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32)',
      'sybl::uat::KnownFolderPath(FOLDERID_LocalAppData',
      'directory += L"\\\\Syb-L"',
      'FILE_ATTRIBUTE_REPARSE_POINT',
      'GENERIC_READ | GENERIC_WRITE',
      '0, nullptr, OPEN_ALWAYS',
      'CloseHandle(instance_lock)',
    ]);
    expect(
      windowsMain,
      isNot(contains('CreateMutexW')),
      reason: 'the identity lock must cross Windows logon sessions',
    );
    _expectAll('Windows pre-entry DLL boundary', windowsCmake, const [
      'add_link_options("/DEPENDENTLOADFLAG:0xA00")',
    ]);
    final androidEnsureSuccess = androidEnsure.substring(
      androidEnsure.lastIndexOf('"status" to "ok"'),
    );

    const projection = [
      'status',
      'accountId',
      'jamiId',
      'displayName',
      'avatarBase64',
      'enabled',
      'announced',
      'registration',
    ];
    for (final key in projection) {
      expect(
        androidEnsureSuccess,
        contains('"$key" to'),
        reason: 'Android startup projection lost $key',
      );
      expect(
        windowsDispatch,
        contains('EncodableValue("$key")'),
        reason: 'Windows startup projection lost $key',
      );
    }
  });

  test('restore forwards local policy and returns the full projection', () {
    final dartRestore = dartBridge.substring(
      dartBridge.indexOf('Future<Map<String, dynamic>> restoreIdentity('),
    );
    final stateRestore = _section(
      appState,
      'Future<String?> restoreIdentity(',
      'Future<void> _refreshFriendsFromDaemon()',
      owner: 'Dart restore adoption',
    );
    const policyKeys = [
      'connectionProfile',
      'dhtBootstrap',
      'turnServer',
      'turnRealm',
      'turnUser',
      'turnPassword',
      'appearOffline',
    ];
    for (final key in policyKeys) {
      expect(
        dartRestore,
        contains("'$key':"),
        reason: 'Dart restore payload lost $key',
      );
      expect(
        stateRestore,
        contains('$key:'),
        reason: 'Dart restore adoption stopped forwarding $key',
      );
    }
    _expectAll('Dart restore adoption', stateRestore, const [
      r'expectedAccountId: owner.$1',
      "prepared['enabled'] != false",
      'await jami.finalizeIdentityRestore(',
      'final installing = _installAccountResult(',
      'finalized,',
      'await installing;',
      'screen = Screen.loading',
      'bootError = "Couldn\'t finish restoring the identity. Please try again."',
      'rethrow',
    ]);

    final install = _section(
      appState,
      'Future<void> _installAccountResult(',
      'Future<void> onboard(',
      owner: 'Dart account projection install',
    );
    const projection = [
      'status',
      'accountId',
      'jamiId',
      'displayName',
      'avatarBase64',
      'enabled',
      'announced',
      'registration',
    ];
    for (final key in projection) {
      expect(
        install,
        contains("r['$key']"),
        reason: 'Dart account projection stopped consuming $key',
      );
    }

    final androidDispatch = _section(
      androidChannel,
      '"restoreIdentity" -> {',
      'else -> result.notImplemented()',
      owner: 'Android restore dispatch',
    );
    final windowsDispatch = _dispatch(
      windowsChannel,
      '} else if (method == "restoreIdentity") {',
      RegExp(r'\n\s*} else if \(method == "[^"]+"\)'),
      owner: 'Windows restore dispatch',
    );
    for (final key in policyKeys) {
      expect(
        androidDispatch,
        contains('"$key"'),
        reason: 'Android restore dispatch lost $key',
      );
      expect(
        windowsDispatch,
        contains('"$key"'),
        reason: 'Windows restore dispatch lost $key',
      );
    }
    _expectAll('Android restore dispatch', androidDispatch, const [
      'JamiCore.restoreAccount(',
      'result.success(it)',
    ]);
    _expectAll('Windows restore dispatch', windowsDispatch, const [
      'jami_bridge::RestoreAccount(',
      'appear_offline,',
    ]);

    final androidRestore = _section(
      androidCore,
      'fun restoreAccount(',
      'private fun disablePendingRestoredAccount(',
      owner: 'Android restore',
    );
    _expectAll('Android restore policy', androidRestore, const [
      '"Account.enable" to "false"',
      'DENY_SECOND_CALL_KEY to "true"',
      '"DHT.PublicInCalls" to "false"',
      '"Account.peerDiscovery" to "false"',
      '"Account.accountDiscovery" to "false"',
      '"Account.accountPublish" to "false"',
      'applyConnectionProfile(',
      'if (!accountAuthority.owns(scope)) return fail',
      'completePendingRestorePreparation(bound)',
      'return pendingRestoreResult(checkNotNull(pendingIdentityRestore))',
    ]);
    final windowsRestore = _section(
      windowsBridge,
      'void RestoreAccount(',
      'void GetPendingIdentityRestore(',
      owner: 'Windows restore',
    );
    _expectAll('Windows restore policy', windowsRestore, const [
      '{"Account.enable", "false"}',
      'ConfProperties::DENYSECONDCALL, "true"',
      'ConfProperties::DHT::PUBLIC_IN_CALLS, "false"',
      'ConfProperties::DHT_PEER_DISCOVERY, "false"',
      'ConfProperties::ACCOUNT_PEER_DISCOVERY, "false"',
      'ConfProperties::ACCOUNT_PUBLISH, "false"',
      'CaptureRestoreOwner(expectedAccountId)',
      'ApplyRestoreNetwork(pending)',
      'result = RestoreProjection(pending, true)',
    ]);

    final androidCleanup = _section(
      androidCore,
      'private fun discardFailedRestore(',
      '/** Restore an identity from an exported backup file',
      owner: 'Android failed-restore cleanup',
    );
    _expectAll('Android failed-restore cleanup', androidCleanup, const [
      'it.accountId == id && it.previousAccountId == previousAccount.orEmpty()',
      'if (!completeArchiveRestoreRollback(record))',
      'archiveRecoveryBlocked = true',
      'archiveProtectionReady = false',
    ]);
    final androidRollback = _section(
      androidCore,
      'private fun completeArchiveRestoreRollback(',
      'internal fun discardIdentityRestore(',
      owner: 'Android journal-owned restore rollback',
    );
    _expectOrdered(
      'Android journal-owned restore rollback',
      androidRollback,
      const [
        'IdentityRestoreJournal.load(appContext)',
        'sealed != record || !canDiscardArchiveRestore(record, accountId)',
        'rollbackArchiveRestore(record, accountId,',
        'IdentityRestoreJournal.save(appContext, rollback)',
        'IdentityRestoreJournal.load(appContext) != rollback',
        'rekey.accountId == record.accountId',
        'accounts.get(it) in record.previousAccounts',
        'disablePendingRestoredAccount(record.accountId)',
        'JamiService.removeAccount(record.accountId)',
        '!JamiService.getAccountList().contains(record.accountId)',
        'java.nio.file.LinkOption.NOFOLLOW_LINKS',
        'ArchiveRecoveryJournal.clear(appContext)',
        'IdentityRestoreJournal.clear(appContext)',
        'identityRestoreRecoveryFailed = false',
        'archiveRecoveryBlocked = false',
      ],
    );
    final androidDisable = _section(
      androidCore,
      'private fun disablePendingRestoredAccount(',
      'private fun completePendingRestorePreparation(',
      owner: 'Android pending restore disable',
    );
    _expectOrdered('Android pending restore disable', androidDisable, const [
      'details["Account.enable"] = "false"',
      'JamiService.setAccountDetails(id, StringMap.toSwig(details))',
      'JamiService.sendRegister(id, false)',
      'JamiService.setAccountActive(id, false, false)',
      'check(preparedIdentityClosed(',
    ]);
    final androidDiscard = _section(
      androidCore,
      'internal fun discardIdentityRestore(',
      'private fun discardFailedRestore(',
      owner: 'Android explicit restore discard',
    );
    _expectOrdered('Android explicit restore discard', androidDiscard, const [
      '!accountAuthority.owns(scope)',
      'IdentityRestoreJournal.load(appContext)',
      'record.accountId != restoredAccountId || record.token != token',
      '!canDiscardArchiveRestore(record, accountId)',
      'stopRecorderBeforeCall() && completeArchiveRestoreRollback(record)',
      'return cleared',
    ]);
    final windowsDiscard = _dispatch(
      windowsChannel,
      'if (method == "discardIdentityRestore") {',
      RegExp(r'\n\s*if \(method == "remoteControlHostAuthority"'),
      owner: 'Windows restore discard dispatch',
    );
    _expectAll('Windows restore discard acknowledgment', windowsDiscard, const [
      'jami_bridge::DiscardIdentityRestore(ArgString(call, "accountId", "")',
      'ArgString(call, "restoreToken", ""), ArgString(call, "expectedAccountId", "")',
      'res->Success(flutter::EncodableValue(removed))',
    ]);
    _expectOrdered('Android restore commit boundary', androidRestore, const [
      '"Account.enable" to "false"',
      'val imported = runReservedRestoreImport(',
      'saveJournal = { IdentityRestoreJournal.save(appContext, it) }',
      'nativeImport = { reserved -> JamiService.addAccount(details, reserved) }',
      'ArchiveRecoveryJournal.save(',
      'val jamiId = awaitRestoredUsername(id)',
      'recoverInterruptedArchiveRekey(',
      'completePendingRestorePreparation(bound)',
      'return pendingRestoreResult(',
    ]);
    expect(
      androidRestore,
      isNot(contains('addAccount(details)')),
      reason: 'Android restore imports without the reserved account id',
    );
    final restoreSequence = _read(
      'android/app/src/main/kotlin/app/sybl/sybl/IdentityRestoreSequence.kt',
    );
    final reservedImport = restoreSequence.substring(
      restoreSequence.indexOf('internal fun runReservedRestoreImport('),
    );
    _expectOrdered('Android reserved import sequence', reservedImport, const [
      'if (!saveJournal(record)) return RestoreImportOutcome.JournalNotSaved',
      'nativeImport(reserved)',
      'returned == reserved',
    ]);
    _expectAll('Android restore rollback', androidRestore, const [
      'catch (e: Throwable)',
      'discardFailedRestore(id, previousAccount)',
      'return fail',
    ]);

    _expectOrdered('Windows restore commit boundary', windowsRestore, const [
      '!store.Save(pending)',
      'SaveArchiveRecovery({pending.account_id, secret, passphrase})',
      '{"Account.enable", "false"}',
      'libjami::addAccount(details, pending.account_id)',
      'AwaitRestoredUsername(pending.account_id)',
      'RecoverInterruptedArchiveRekey(',
      'ApplyRestoreNetwork(pending)',
      'pending.phase = RestorePhase::kPrepared',
      '!store.Save(pending)',
      'RestoreProjection(pending, true)',
    ]);
    _expectAll(
      'Windows uncertain import stays disabled',
      windowsRestore,
      const [
        'if (!AccountExists(g_pendingRestore->account_id))',
        'if (FinishIdentityRestoreRollback(owner))',
        'DisablePreparedAccount(g_pendingRestore->account_id)',
      ],
    );
    final windowsRollback = _section(
      windowsBridge,
      'bool FinishIdentityRestoreRollback(',
      'void RestoreAccount(',
      owner: 'Windows journal-owned restore rollback',
    );
    _expectOrdered(
      'Windows journal-owned restore rollback',
      windowsRollback,
      const [
        'loaded.value->token != g_pendingRestore->token',
        'loaded.value->account_id != g_pendingRestore->account_id',
        'sybl::identity_restore::CanDiscard(pending, captured.accountId, libjami::getAccountList())',
        'owner->revision != captured.revision',
        'sybl::identity_restore::Rollback(',
        'store.Save(rollback)',
        'RecordWindowsSybLRevokeAndWait(3000)',
        'DisablePreparedAccount(pending.account_id)',
        'libjami::removeAccount(pending.account_id)',
        'return absent()',
        '!RestoreArchiveJournalOwned(pending.account_id) || !absent() || !ClearArchiveRecovery()',
        'store.Clear(pending.token)',
        'store.Load().status == sybl::identity_restore::LoadStatus::kAbsent',
        'if (!removed) return false',
        'g_pendingRestore.reset()',
      ],
    );

    final androidFinalize = _section(
      androidCore,
      'internal fun finalizeIdentityRestore(',
      'private fun awaitRestoredUsername(',
      owner: 'Android privacy finalization',
    );
    _expectOrdered('Android privacy precedes activation', androidFinalize, const [
      'admittedRecord.accountId != restoredAccountId || admittedRecord.token != token',
      'incomingMicrophoneSettings.prepareSave(document)',
      'commitRestoredPrivacy(document, localLock, save,',
      'MessageNotifications.setPolicy(appContext, showMessage, lock)',
      'IdentityRestoreJournal.save(appContext, committedRecord)',
      'details["Account.enable"] = (!record.appearOffline).toString()',
      'JamiService.sendRegister(record.accountId, !record.appearOffline)',
      'selectAccount(record.accountId)',
      'IdentityRestoreJournal.clear(appContext)',
      '"status" to "ok"',
    ]);
    expect(
      androidFinalize,
      contains('disablePendingRestoredAccount(record.accountId)'),
    );
    final windowsFinalize = _section(
      windowsBridge,
      'void FinalizeIdentityRestore(',
      'void PlaceCall(',
      owner: 'Windows privacy finalization',
    );
    _expectOrdered(
      'Windows privacy precedes activation',
      windowsFinalize,
      const [
        'loaded.value->account_id != accountId',
        'loaded.value->token != restoreToken',
        'sybl::identity_restore::Finalize(',
        'CanonicalSettingsLease::Acquire(*settingsPath, document)',
        'store.Save(committed)',
        'libjami::sendRegister(accountId, enabled)',
        'SelectAccountLocked(accountId)',
        'store.Clear(pending.token)',
      ],
    );
    expect(windowsFinalize, contains('DisablePreparedAccount(accountId)'));
    final androidRestoreSuccess = _section(
      androidCore,
      'private fun pendingRestoreResult(',
      'fun getPendingIdentityRestore(',
      owner: 'Android prepared restore projection',
    );
    final windowsProjection = _section(
      windowsChannel,
      'flutter::EncodableValue IdentityRestoreValue(',
      '// UTF-16',
      owner: 'Windows restore projection',
    );
    expect(windowsDispatch, contains('res->Success(IdentityRestoreValue(a))'));
    _expectAll('Windows restore projection encoding', windowsProjection, const [
      'result[flutter::EncodableValue(entry.first)] = flutter::EncodableValue(entry.second)',
      '{"recoveryReason", value.recoveryReason}',
      '{"recoveryOwnerAccountId", value.recoveryOwnerAccountId}',
      'result[flutter::EncodableValue("canDiscard")] = flutter::EncodableValue(value.canDiscard)',
    ]);
    for (final key in projection) {
      expect(
        androidRestoreSuccess,
        contains('"$key" to'),
        reason: 'Android restore projection lost $key',
      );
      expect(
        windowsProjection,
        contains(
          key == 'enabled' || key == 'announced'
              ? 'EncodableValue("$key")] = flutter::EncodableValue(value.$key)'
              : '{"$key", value.$key}',
        ),
        reason: 'Windows restore projection lost $key',
      );
    }
  });

  test('encrypted identity backup carries one bounded settings document', () {
    final androidBackup = _section(
      androidCore,
      'fun exportToTempFile(',
      'private fun discardFailedRestore',
      owner: 'Android settings backup',
    );
    final windowsBackup = _section(
      windowsBridge,
      'void ExportAccount(',
      '// Restore an identity',
      owner: 'Windows settings backup',
    );
    _expectAll('Android settings backup', androidBackup, const [
      'MAX_SETTINGS_DOCUMENT_BYTES',
      '"Account.uiCustomization"',
      'exportWithRestoredAccountDetails(previousDetails, exportDetails',
      'setDetails = { JamiService.setAccountDetails(acc, StringMap.toSwig(it)) }',
      'exportTemporaryArchiveSnapshot',
    ]);
    _expectAll('Windows settings backup', windowsBackup, const [
      'kMaxSettingsDocumentBytes',
      'ConfProperties::UI_CUSTOMIZATION',
      'libjami::setAccountDetails(acc, previousDetails)',
      'ExportWithRestoredAccountDetails(',
    ]);
    expect(androidCore, contains('"settingsDocument" to document'));
    expect(
      windowsChannel,
      contains('{"settingsDocument", value.settingsDocument}'),
    );
    expect(appState, contains("prepared['settingsDocument']"));
  });

  test('security mutations acknowledge their actual boolean result', () {
    final requireTrue = _section(
      dartBridge,
      'Future<void> _requireTrue(',
      'class JamiClient {',
      owner: 'Dart acknowledgement guard',
    );
    _expectAll('Dart acknowledgement guard', requireTrue, const [
      'invokeMethod<bool>(method, arguments) != true',
      "throw StateError('\$method was rejected')",
    ]);

    const methods = {
      'setPresenceSubscriptions': (
        android: 'setPresenceSubscriptions',
        windows: 'SetPresenceSubscriptions',
      ),
      'answerCall': (android: 'answerCall', windows: 'AnswerCall'),
      'hangUp': (android: 'hangUp', windows: 'HangUp'),
      'refuse': (android: 'refuse', windows: 'Refuse'),
      'removeContact': (android: 'removeContact', windows: 'RemoveContact'),
    };
    for (final entry in methods.entries) {
      _expectMatch(
        'Dart ${entry.key}',
        dartBridge,
        RegExp(
          "Future<void>\\s+${entry.key}\\b[\\s\\S]*?_requireTrue\\(_core,\\s*'${entry.key}'",
        ),
      );
      final androidDispatch = _dispatch(
        androidChannel,
        '"${entry.key}" -> {',
        RegExp(r'\n\s*"[^"]+"\s*->'),
        owner: 'Android ${entry.key} dispatch',
      );
      expect(
        androidDispatch,
        contains('JamiCore.${entry.value.android}'),
        reason: 'Android ${entry.key} stopped dispatching its mutation',
      );
      _expectMatch(
        'Android ${entry.key} acknowledgement',
        androidDispatch,
        RegExp(r'result\.success\(\s*it(?:\s*==\s*true)?\s*\)'),
      );

      final windowsDispatch = _dispatch(
        windowsChannel,
        '} else if (method == "${entry.key}") {',
        RegExp(r'\n\s*} else if \(method == "[^"]+"\)'),
        owner: 'Windows ${entry.key} dispatch',
      );
      _expectAll('Windows ${entry.key} acknowledgement', windowsDispatch, [
        'jami_bridge::${entry.value.windows}',
        '(bool ok)',
        'Success(flutter::EncodableValue(ok))',
      ]);
    }

    final androidTruth = <String, (String, List<String>)>{
      'setPresenceSubscriptions': (
        _section(
          androidCore,
          'fun setPresenceSubscriptions(',
          'private fun isTrustedPeer(',
          owner: 'Android setPresenceSubscriptions',
        ),
        [
          'val normalized = peers.map(::bareJamiId)',
          'if (normalized.any(String::isEmpty))',
          'throw IllegalArgumentException("Invalid presence subscription peer")',
          'val desired = normalized.toSet()',
          'if (desired.any { !routingSnapshot.isTrusted(it) })',
          'throw IllegalArgumentException("Presence subscription requested for an untrusted peer")',
          'return reconcilePresenceSubscriptions(acc, desired)',
        ],
      ),
      'answerCall': (
        _section(
          androidCore,
          'fun answerCall(',
          'fun refuse(',
          owner: 'Android answerCall',
        ),
        [
          'return answerRetainedIncomingCall(',
          'val ok = JamiService.acceptWithMedia(',
          'return@answerRetainedIncomingCall ok',
        ],
      ),
      'refuse': (
        _section(
          androidCore,
          'fun refuse(',
          'fun hangUp(',
          owner: 'Android refuse',
        ),
        ['val ok = JamiService.refuse(', 'return ok'],
      ),
      'hangUp': (
        _section(
          androidCore,
          'fun hangUp(',
          'fun sendCallMessage(',
          owner: 'Android hangUp',
        ),
        ['val ok = JamiService.hangUp(', 'return ok'],
      ),
      'removeContact': (
        _section(
          androidCore,
          'fun removeContact(',
          '// ---- identity backup / restore',
          owner: 'Android removeContact',
        ),
        [
          'JamiService.removeContact(',
          'return false',
          'return !routingSnapshot.isTrusted(bare)',
        ],
      ),
    };
    for (final entry in androidTruth.entries) {
      _expectAll('Android ${entry.key} truth', entry.value.$1, entry.value.$2);
    }

    final windowsTruth = <String, (String, List<String>)>{
      'setPresenceSubscriptions': (
        _section(
          windowsBridge,
          'void SetPresenceSubscriptions(',
          'void ProbeReachable(',
          owner: 'Windows setPresenceSubscriptions',
        ),
        ['ok = ReconcilePresenceSubscriptions(', 'done(ok)', 'done(false)'],
      ),
      'answerCall': (
        _section(
          windowsBridge,
          'void AnswerCall(',
          'void HangUp(',
          owner: 'Windows answerCall',
        ),
        [
          'ok = RecordWindowsSybLRevokeAndWait(3000) && libjami::acceptWithMedia(',
          'done(ok)',
          'done(false)',
        ],
      ),
      'hangUp': (
        _section(
          windowsBridge,
          'void HangUp(',
          'void Refuse(',
          owner: 'Windows hangUp',
        ),
        ['ok = libjami::hangUp(', 'done(ok)', 'done(false)'],
      ),
      'refuse': (
        _section(
          windowsBridge,
          'void Refuse(',
          'void SetMicMuted(',
          owner: 'Windows refuse',
        ),
        ['ok = libjami::refuse(', 'done(ok)', 'done(false)'],
      ),
      'removeContact': (
        _section(
          windowsBridge,
          'void RemoveContact(',
          'void ExportAccount(',
          owner: 'Windows removeContact',
        ),
        [
          'libjami::removeContact(',
          'ok = !IsTrustedPeer(',
          'done(ok)',
          'done(false)',
        ],
      ),
    };
    for (final entry in windowsTruth.entries) {
      _expectAll('Windows ${entry.key} truth', entry.value.$1, entry.value.$2);
    }
  });

  test('optional background wake has one Android bridge contract', () {
    _expectAll('Dart background wake bridge', dartBridge, const [
      "'backgroundWakeAvailability'",
      "'setReliableBackgroundNotifications'",
      "'enabled': enabled",
      "'connectionProfile': connectionProfile",
    ]);
    _expectAll('Android background wake bridge', androidChannel, const [
      '"backgroundWakeAvailability" ->',
      'JamiCore.backgroundWakeAvailability()',
      '"setReliableBackgroundNotifications" ->',
      'JamiCore.setReliableBackgroundNotifications(',
    ]);
  });

  test(
    'presence is strict, fresh, and metadata-free probes are never evidence',
    () {
      _expectAll('Android presence parser', androidPresence, const [
        'const val VERSION = 3',
        'const val MAX_BODY_BYTES = 512',
        'const val MAX_CLOCK_DELTA_MS = 60_000L',
        'if (body == "1") return PresencePacket(0, "ping", -1, 0, "", "", "", "")',
        'if (version !in 0..VERSION) return null',
        'val value = decodeObject(body) ?: return null',
        'values.containsKey(key)',
        'if (value.keys != expected) return null',
        'readInteger(input)',
        'readString(input)',
        'type != "ping" && type != "pong"',
        '(it == 0 || it == 1)',
        'val timestamp = (value["ts"] as? Long)?.takeIf { it > 0 } ?: return null',
        'nowMs - timestamp > MAX_CLOCK_DELTA_MS',
        'timestamp - nowMs > MAX_CLOCK_DELTA_MS',
        'it == "android" || it == "windows"',
        'IdentityColorWire.valid',
      ]);
      _expectAll('Windows presence parser', windowsPresenceHeader, const [
        'inline constexpr int kVersion = 3',
        'inline constexpr std::size_t kMaxBodyBytes = 512',
        'inline constexpr std::int64_t kMaxClockDeltaMs = 60000',
        'Decode(std::string_view body, std::int64_t now_ms)',
      ]);
      _expectAll('Windows presence parser', windowsPresence, const [
        'if (body == "1") return Packet{0, "ping", -1, 0, "", "", "", ""}',
        'Json::CharReaderBuilder::strictMode(&builder.settings_)',
        'version < 0 || version > kVersion',
        '!ExactKeys(root, version)',
        '!root["t"].isString() || !Integer(root["fg"]) || !root["fg"].isInt()',
        'value.type() == Json::intValue || value.type() == Json::uintValue',
        '!Integer(root["ts"])',
        '!root["ts"].isInt64()',
        'packet.type != "ping" && packet.type != "pong"',
        'packet.foreground != 0 && packet.foreground != 1',
        'packet.timestamp_ms <= 0',
        'now_ms - packet.timestamp_ms > kMaxClockDeltaMs',
        'packet.timestamp_ms - now_ms > kMaxClockDeltaMs',
        'packet.platform != "android" && packet.platform != "windows"',
        'identity_color_wire::Index',
      ]);

      final dartPresence = _section(
        appState,
        "case 'presenceMsg':",
        "case 'inviteLink':",
        owner: 'Dart presence evidence',
      );
      _expectAll('Dart presence evidence', dartPresence, const [
        'version == 2',
        'version == 1',
        "(type == 'ping' || type == 'pong')",
        '(foreground == 0 || foreground == 1)',
        'timestamp > 0',
        'platform.isNotEmpty',
        'version == 0',
        'if (!current && !strict && !legacy) break',
        '_friendPresenceEvidence(',
      ]);

      final androidDispatch = _section(
        androidCore,
        'internal fun onAccountMessage(',
        'fun connectivitySweep()',
        owner: 'Android presence dispatch',
      );
      expect(androidCore, contains('PresenceWire.encode('));
      _expectAll('Android presence dispatch', androidDispatch, const [
        'PresenceWire.decode(body) ?: return',
        'if (presence.version == 0 && presence.timestampMs == 0L) return',
        '"type" to "presenceMsg"',
      ]);
      _expectOrdered('Android legacy presence hint', androidDispatch, const [
        'if (t == "ping")',
        'if (presence.version == 0 && presence.timestampMs == 0L) return',
        '"type" to "presenceMsg"',
      ]);

      final windowsDispatch = _section(
        windowsBridge,
        'void OnAccountMessage(',
        'void BootDaemon()',
        owner: 'Windows presence dispatch',
      );
      expect(windowsBridge, contains('sybl::presence_wire::Encode('));
      _expectAll('Windows presence dispatch', windowsDispatch, const [
        'sybl::presence_wire::Decode(it->second, now)',
        'if (packet->version == 0 && packet->timestamp_ms == 0) return',
        'Emit("presenceMsg"',
      ]);
      _expectOrdered('Windows legacy presence hint', windowsDispatch, const [
        'if (packet->type == "ping")',
        'if (packet->version == 0 && packet->timestamp_ms == 0) return',
        'Emit("presenceMsg"',
      ]);
    },
  );

  test('requests and cold-start calls replay only after Dart installs trust', () {
    _expectMatch(
      'Dart replay acknowledgement',
      dartBridge,
      RegExp(
        r"Future<void> replayPendingNativeEvents\(\)\s*=>\s*_requireTrue\(_core,\s*'replayPendingNativeEvents'",
      ),
    );
    final refresh = _section(
      appState,
      'Future<void> _refreshFriendsFromDaemon() async',
      'ConversationScope? _scopeForPeer(',
      owner: 'Dart trust hydration',
    );
    _expectOrdered('Dart post-handshake replay', refresh, const [
      'final snapshot = await jami.listFriends()',
      '_friends ..clear() ..addAll(next)',
      'await jami.setPresenceSubscriptions(_friends.keys)',
      'await jami.replayPendingNativeEvents()',
    ]);

    final androidSetSink = _section(
      androidCore,
      'fun setEventSink(',
      'internal fun emit(',
      owner: 'Android listener attach',
    );
    expect(androidSetSink, isNot(contains('"type" to "connectRequest"')));
    expect(androidSetSink, isNot(contains('"type" to "incomingCall"')));
    final androidReplay = _section(
      androidCore,
      'fun replayPendingNativeEvents(): Boolean',
      '/** Boot the daemon once.',
      owner: 'Android native replay',
    );
    _expectAll('Android native replay', androidReplay, const [
      'val selected = accountId ?: return false',
      'if (eventSink == null) return false',
      'pendingConnect.entries',
      'it.value.accountId == selected',
      '"type" to "connectRequest"',
      'incomingCalls.snapshot()',
      'pending.accountId != selected',
      '"type" to "incomingCall"',
      'return isActiveAccount(selected)',
    ]);
    _expectOrdered('Android persisted request recovery', androidReplay, const [
      'worker.execute(DaemonOperation.REPLAY_CONNECT_REQUESTS)',
      'JamiService.getConversationRequests(selected)',
      'onConversationRequest(',
    ]);
    expect(
      androidReplay,
      isNot(contains('JamiService.acceptConversationRequest')),
    );
    expect(
      androidChannel,
      contains(
        '"replayPendingNativeEvents" -> result.success(JamiCore.replayPendingNativeEvents())',
      ),
    );

    final windowsSetSink = _section(
      windowsBridge,
      'void SetEventSink(',
      'void SetControlSink(',
      owner: 'Windows listener attach',
    );
    expect(windowsSetSink, isNot(contains('sink("connectRequest"')));
    expect(windowsSetSink, isNot(contains('sink("incomingCall"')));
    final windowsReplay = _section(
      windowsBridge,
      'bool ReplayPendingNativeEvents()',
      'bool RevalidateControlAuthority(',
      owner: 'Windows native replay',
    );
    _expectAll('Windows native replay', windowsReplay, const [
      'if (!g_sink || g_accountId.empty()) return false',
      'g_pendingConnect',
      'owner->second != accountId',
      'g_incomingOffers',
      'g_callPeers',
      'Emit("connectRequest"',
      'Emit("incomingCall"',
      'return IsActiveAccount(accountId)',
    ]);
    _expectOrdered('Windows persisted request recovery', windowsReplay, const [
      'Post([accountId] {',
      'libjami::getConversationRequests(accountId)',
      'OnConversationRequest(accountId,',
    ]);
    expect(
      windowsReplay,
      isNot(contains('libjami::acceptConversationRequest')),
    );
    _expectAll('Windows replay dispatch', windowsChannel, const [
      'method == "replayPendingNativeEvents"',
      'jami_bridge::ReplayPendingNativeEvents()',
    ]);
  });

  test('Android director callbacks are contained and failures are counted', () {
    _expectAll(
      'Android director failure accounting',
      androidDirectorGuard,
      const [
        'private val total = AtomicLong()',
        'total.updateAndGet { if (it == Long.MAX_VALUE) it else it + 1 }',
        'fun count(): Long = total.get()',
        'onFailure: (Throwable) -> Unit = DirectorCallbackFailures::record',
        'block()',
        'catch (failure: Throwable)',
        'onFailure(failure)',
        'clear()',
        'catch (_: Throwable)',
      ],
    );
    expect(
      androidDirectorGuard,
      isNot(contains('throw failure')),
      reason: 'Android director failures must never cross JNI',
    );

    final callbackRegion = androidCore.substring(
      androidCore.indexOf('private class ConfigCb'),
    );
    final overrides = RegExp(
      r'\boverride fun\b',
    ).allMatches(callbackRegion).length;
    final guards = RegExp(
      r'\bguardDirector(?:Fill)?Callback\b',
    ).allMatches(callbackRegion).length;
    expect(overrides, greaterThan(0));
    expect(
      guards,
      overrides,
      reason: 'every SWIG director override must enter a containment guard',
    );
    _expectMatch(
      'Android conversation request director dispatch',
      callbackRegion,
      RegExp(
        r'override fun conversationRequestReceived\([\s\S]*?\)\s*\{\s*guardDirectorCallback\s*\{[\s\S]*?JamiCore\.onConversationRequest\(',
      ),
    );
  });

  test('locked Android notifications never expose message or reply data', () {
    final dartPolicy = _section(
      dartBridge,
      'Future<void> setMessageNotificationPreview(',
      'Future<void> dismissMessageNotification(',
      owner: 'Dart notification policy bridge',
    );
    _expectAll('Dart notification policy bridge', dartPolicy, const [
      'required bool appLockEnabled',
      "_requireTrue(_core, 'setMessageNotificationPreview'",
      "'showMessage': showMessage",
      "'appLockEnabled': appLockEnabled",
    ]);

    final statePolicy = _section(
      appState,
      'Future<void> setAppLockEnabled(bool enabled)',
      'Future<bool> setFolderHistoryLimit(',
      owner: 'Dart app-lock persistence',
    );
    _expectOrdered('Dart app-lock enable ordering', statePolicy, const [
      'if (enabled)',
      'appLockEnabled: true',
      'await _appLockLatchRepository.save(true)',
      'appSettings = next',
    ]);
    _expectOrdered('Dart app-lock disable ordering', statePolicy, const [
      '} else {',
      'await _settingsRepository.save(next)',
      'await _appLockLatchRepository.save(false)',
      'appSettings = next',
      'appLockEnabled: false',
    ]);

    final androidDispatch = _dispatch(
      androidChannel,
      '"setMessageNotificationPreview" -> {',
      RegExp(r'\n\s*"[^"]+"\s*->'),
      owner: 'Android notification policy dispatch',
    );
    _expectAll('Android notification policy dispatch', androidDispatch, const [
      'call.argument<Boolean>("showMessage") ?: true',
      'call.argument<Boolean>("appLockEnabled") ?: true',
      'JamiCore.submit(DaemonOperation.GENERIC',
      'JamiCore.setMessageNotificationPreview(',
      'result.success(it == true)',
    ]);

    final policy = _section(
      androidMessageNotifications,
      'internal object MessageNotificationPolicy',
      '/** Android',
      owner: 'Android message notification policy',
    );
    _expectAll('Android message notification policy', policy, const [
      'preferred && !appLockEnabled',
      'fun allowReply(appLockEnabled: Boolean): Boolean = !appLockEnabled',
      'values.filter { it.startsWith("conversation:") }.distinct()',
    ]);
    final setPolicy = _section(
      androidMessageNotifications,
      'fun setPolicy(',
      'fun showMessage(',
      owner: 'Android locked-policy commit',
    );
    _expectAll('Android locked-policy commit', setPolicy, const [
      '.putBoolean(SHOW_MESSAGE, showMessage)',
      '.putBoolean(APP_LOCK_ENABLED, appLockEnabled)',
      '.commit()',
      'val notificationsSanitized = !appLockEnabled || cancelActiveNotifications(context)',
      'val shortcutsSanitized = !appLockEnabled || sanitizeConversationShortcuts(context)',
      'conversations.values.toList().forEach { post(context, it, alert = false) }',
      'return saved && notificationsSanitized && shortcutsSanitized',
    ]);
    final shortcutPolicy = _section(
      androidMessageNotifications,
      'private fun sanitizeConversationShortcuts(',
      'private fun post(',
      owner: 'Android locked shortcut sanitization',
    );
    _expectAll('Android locked shortcut sanitization', shortcutPolicy, const [
      'ShortcutManagerCompat.FLAG_MATCH_DYNAMIC',
      'ShortcutManagerCompat.FLAG_MATCH_PINNED',
      'ShortcutManagerCompat.FLAG_MATCH_CACHED',
      'ShortcutManagerCompat.getShortcuts(context, flags)',
      '.setShortLabel("Doorlight")',
      '.setLongLabel("Unlock Doorlight")',
      '.setPerson(genericPerson)',
      'ShortcutManagerCompat.updateShortcuts(',
      'ShortcutManagerCompat.removeLongLivedShortcuts(context, ids)',
      'ShortcutManagerCompat.removeDynamicShortcuts(context, ids)',
      'catch (_: RuntimeException)',
    ]);
    final post = _section(
      androidMessageNotifications,
      'private fun post(',
      'class MessageNotificationActionReceiver',
      owner: 'Android message notification rendering',
    );
    _expectAll('Android locked notification rendering', post, const [
      'appLockEnabled -> "New message"',
      '.setContentTitle(if (appLockEnabled) "Doorlight" else conversation.title)',
      'if (preview) line.text else "New message"',
      'if (!appLockEnabled)',
      'action = ACTION_REPLY_TO_MESSAGE',
      '.addAction(',
    ]);
    final receiver = androidMessageNotifications.substring(
      androidMessageNotifications.indexOf(
        'class MessageNotificationActionReceiver',
      ),
    );
    _expectOrdered('Android inline-reply revalidation', receiver, const [
      'if (intent.action != ACTION_REPLY_TO_MESSAGE) return',
      'if (!MessageNotifications.repliesAllowed(context)) return',
      'JamiCore.resolveMessageAction(token) ?: return',
      'if (!route.replyAllowed || route.startCall) return',
      'MessageNotificationPolicy.replyText(',
      'JamiCore.submit(',
      'MessageNotifications.repliesAllowed(context) && JamiCore.consumeMessageAction(token, route)',
      'JamiCore.sendNotificationReply(route, text)',
    ]);
    expect(receiver, isNot(contains('MessageNotificationPolicy.replyRoute(')));
  });

  test('SAF copies and avatar decoding stay inside explicit resource bounds', () {
    _expectAll('Dart picker bounds', dartBridge, const [
      'static const int maxPickedFileBytes = 2 * 1024 * 1024 * 1024',
      'static const int maxBackupImportBytes = 16 * 1024 * 1024',
      'static const int maxProfileImageBytes = 12 * 1024 * 1024',
      "'maxBytes': maxBytes",
    ]);
    _expectAll('Dart bounded picker callers', appState, const [
      'mimeType: \'image/*\'',
      'maxBytes: JamiClient.maxProfileImageBytes',
      'jami.pickFile(maxBytes: JamiClient.maxBackupImportBytes)',
    ]);

    final androidPicker = _section(
      androidChannel,
      '"pickFile" -> {',
      '"discardPickedFile" -> {',
      owner: 'Android SAF picker dispatch',
    );
    expect(
      androidChannel,
      contains(
        'private const val MAX_PICK_COPY_BYTES = 2L * 1024 * 1024 * 1024',
      ),
    );
    _expectAll('Android SAF picker dispatch', androidPicker, const [
      'call.argument<Number>("maxBytes")?.toLong() ?: MAX_PICK_COPY_BYTES',
      'if (maxBytes !in 1..MAX_PICK_COPY_BYTES)',
      'pendingPickMaxBytes = maxBytes',
    ]);
    final androidPickerResult = _section(
      androidChannel,
      'if (requestCode != PICK_FILE_REQ) return',
      'private fun copyToOutgoingStore(',
      owner: 'Android SAF picker completion',
    );
    _expectAll('Android SAF picker completion', androidPickerResult, const [
      'val maxBytes = pendingPickMaxBytes',
      'val path = copyToOutgoingStore(uri, maxBytes)',
      'pendingPickMaxBytes = MAX_PICK_COPY_BYTES',
    ]);
    final androidCopy = _section(
      androidChannel,
      'private fun copyToOutgoingStore(',
      'private fun safeOutgoingLeaf(',
      owner: 'Android SAF persistent copy',
    );
    _expectOrdered('Android atomic picker staging', androidCopy, const [
      'Files.createTempDirectory(dir.toPath(), "picked-")',
      'File(stage, safeOutgoingLeaf(queryName(uri) ?: "file"))',
      'copyBoundedToFile(input, dest, maxBytes)',
      'if (!complete)',
      'dest.delete()',
      'stage.delete()',
    ]);
    expect(
      androidChannel,
      isNot(contains('private fun uniqueOutgoingFile(')),
      reason: 'picker destinations must be atomically reserved',
    );
    _expectAll('Android picker ownership', androidFileOwnership, const [
      'Files.isRegularFile(candidate.toPath(), LinkOption.NOFOLLOW_LINKS)',
      '!Files.isSymbolicLink(candidate.toPath())',
      'directory.name.startsWith("picked-")',
      'directory.parentFile == root.canonicalFile',
      'deleteOwnedPickerStagingFile',
      '!candidate.delete() && candidate.exists()',
      'directory.delete() || !directory.exists()',
    ]);
    _expectAll('Android bounded stream copy', androidBoundedFileCopy, const [
      'require(maxBytes >= 0)',
      'val read = input.read(buffer)',
      'if (read.toLong() > maxBytes - total) return false',
      'output.write(buffer, 0, read)',
      'if (total == maxBytes) return false',
      'complete = true',
      'if (!complete) destination.delete()',
    ]);
    _expectOrdered(
      'Android copy overflow check',
      androidBoundedFileCopy,
      const [
        'if (read.toLong() > maxBytes - total) return false',
        'output.write(buffer, 0, read)',
        'total += read',
      ],
    );
    final androidTransferEvent = _section(
      androidCore,
      'internal fun onDataTransferEvent(',
      '/** A new swarm message:',
      owner: 'Android outgoing staging completion',
    );
    _expectOrdered(
      'Android outgoing staging completion',
      androidTransferEvent,
      const [
        'if (code == 1 || code == 2)',
        'if (!isOutgoingPickerCopy(fileId)) return',
        'if (ownedFileOperations.ownsPath(fileId)) return',
        'if (code != 1)',
        'if (!deleteOwnedPickerStagingFile(',
        'return',
        'val owner = ownerForConversation(acc, conversationId) ?: return',
        'val key = TransferKey(owner, conversationId, fileId)',
      ],
    );

    final windowsPicker = _dispatch(
      windowsChannel,
      '} else if (method == "pickFile") {',
      RegExp(r'\n\s*} else if \(method == "[^"]+"\)'),
      owner: 'Windows picker dispatch',
    );
    _expectOrdered('Windows bounded picker dispatch', windowsPicker, const [
      'const auto max_bytes = ArgInt64(call, "maxBytes", 0)',
      'if (!sybl::picked_file::IsAllowedMaxBytes(max_bytes))',
      'GetOpenFileNameW(&ofn)',
      'sybl::picked_file::DefaultStagingRoot()',
      'sybl::picked_file::Stage(',
      'WideToUtf8(staged->wstring())',
    ]);
    expect(
      windowsPicker,
      isNot(contains('WideToUtf8(buf)')),
      reason: 'Windows must never return the mutable selected path',
    );
    final windowsDiscard = _dispatch(
      windowsChannel,
      '} else if (method == "discardPickedFile") {',
      RegExp(r'\n\s*} else if \(method == "[^"]+"\)'),
      owner: 'Windows staged-file discard dispatch',
    );
    _expectAll('Windows staged-file discard dispatch', windowsDiscard, const [
      'jami_bridge::DiscardUnissuedStage(ArgString(call, "path", "")',
    ]);
    final protectedDiscard = _section(
      windowsBridge,
      'void DiscardUnissuedStage(',
      'void SaveSendJournal(',
      owner: 'Windows durable stage ownership',
    );
    _expectOrdered('Windows durable stage ownership', protectedDiscard, const [
      'StageRegistryLocked()',
      '!registry.OwnsIssued(path)',
      'sybl::picked_file::Discard(candidate, *root)',
      'registry.Forget(path)',
    ]);
    final windowsSendDispatch = _dispatch(
      windowsChannel,
      '} else if (method == "sendFile") {',
      RegExp(r'\n\s*} else if \(method == "[^"]+"\)'),
      owner: 'Windows send-file dispatch',
    );
    _expectAll('Windows picker handoff cleanup', windowsSendDispatch, const [
      'jami_bridge::SendFile(',
      'if (ok)',
      'sybl::picked_file::Discard(',
    ]);
    _expectAll('Windows picker byte cap', windowsPickedFileHeader, const [
      'kMaxPickedFileBytes = 2LL * 1024 * 1024 * 1024',
      'return value >= 1 && value <= kMaxPickedFileBytes',
    ]);
    _expectAll('Windows stable picker copy', windowsPickedFile, const [
      'return root / L"Syb-L Picker Staging"',
      'FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT',
      'attributes.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT',
      'GetFileType(file) != FILE_TYPE_DISK',
      'FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DEVICE',
      'SamePath(expected_path, *final)',
      'GENERIC_READ, FILE_SHARE_READ',
      'FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_SEQUENTIAL_SCAN',
      'source_size > static_cast<std::uint64_t>(max_bytes)',
      'std::filesystem::create_directories(staging_root, error)',
      'BCryptGenRandom(',
      'selected.filename()',
      'CREATE_NEW',
      'ReadFile(source.Get()',
      'static_cast<std::uint64_t>(max_bytes) - total',
      'WriteFile(output.Get()',
      'if (total != source_size) return std::nullopt',
      '!output.Commit()',
      'return destination',
    ]);
    final windowsSend = _section(
      windowsBridge,
      'void SendFile(',
      'void AcceptFile(',
      owner: 'Windows outgoing-file ownership handoff',
    );
    _expectAll('Windows outgoing display name', windowsSend, const [
      'if (display.empty())',
      'auto slash = path.find_last_of("/\\\\")',
      'display = (slash == std::string::npos) ? path : path.substr(slash + 1)',
      'const auto staged = StageOutgoingFile(path)',
      'g_outgoingStagingPaths.insert(staged_utf8)',
      'sybl::picked_file::Discard(staged, OutgoingDir())',
    ]);
    final windowsStageOutgoing = _section(
      windowsBridge,
      'std::filesystem::path StageOutgoingFile(',
      '// A non-clobbering UTF-8 destination path',
      owner: 'Windows bounded outgoing staging',
    );
    _expectAll('Windows bounded outgoing staging', windowsStageOutgoing, const [
      'sybl::picked_file::Stage(',
      'std::filesystem::u8path(source_path)',
      'sybl::picked_file::kMaxPickedFileBytes',
    ]);
    expect(
      windowsStageOutgoing,
      isNot(contains('std::filesystem::copy_file')),
      reason: 'the daemon handoff must retain the locked-source byte bound',
    );
    final windowsTransferEvent = _section(
      windowsBridge,
      'void OnDataTransferEvent(',
      '// SwarmMessageReceived',
      owner: 'Windows outgoing staging completion',
    );
    _expectOrdered(
      'Windows outgoing staging completion',
      windowsTransferEvent,
      const [
        'if (code == 1 || code == 2)',
        'g_outgoingStagingPaths.find(fileId)',
        'sybl::picked_file::Discard(',
        'if (removed)',
        'g_outgoingStagingPaths.erase(fileId)',
        'return',
        'if (!IsOwnedConversation(acc, conversationId)) return',
      ],
    );
    _expectOrdered('Windows copy overflow check', windowsPickedFile, const [
      'if (static_cast<std::uint64_t>(read) > static_cast<std::uint64_t>(max_bytes) - total)',
      'WriteFile(output.Get()',
      'total += read',
    ]);
    _expectAll('Windows partial cleanup', windowsPickedFile, const [
      '~PartialOutput()',
      'if (file_) MarkForDeletion(file_.Get())',
      '~PartialDirectory()',
      'if (directory_) MarkForDeletion(directory_.Get())',
      'SetFileInformationByHandle(file, FileDispositionInfo',
    ]);
    _expectAll('Windows safe staged-file discard', windowsPickedFile, const [
      'candidate.is_absolute()',
      'IsStagedDirectoryName(staged_directory_path)',
      'SamePath(staged_directory_path.parent_path().wstring(), root_path)',
      'DELETE | FILE_READ_ATTRIBUTES',
      '(remove ? DELETE : 0) | FILE_READ_ATTRIBUTES, 0',
      'FILE_FLAG_OPEN_REPARSE_POINT',
      'MarkForDeletion(file.Get())',
      'MarkForDeletion(staged_directory.Get())',
    ]);
    expect(
      windowsPickedFile,
      isNot(contains('DeleteFileW')),
      reason: 'discard must delete the validated handle, never a raced path',
    );

    final avatarContract = _section(
      dartBridge,
      'abstract final class ProfileWireContract',
      '/// Bounded optional metadata',
      owner: 'Dart avatar wire contract',
    );
    _expectAll('Dart avatar wire contract', avatarContract, const [
      'maxAvatarBytes = 256 * 1024',
      'maxAvatarBase64Chars = 350 * 1024',
      'maxAvatarDimension = 4096',
      'maxAvatarPixels = 4 * 1024 * 1024',
      'value.length > maxAvatarBase64Chars',
      'bytes.length > maxEncodedBytes',
      'boundedRasterDecoder( bytes,',
      'maxDimension: maxAvatarDimension',
      'maxPixels: maxAvatarPixels',
    ]);
    _expectAll('Avatar widget bounded decode', avatarUi, const [
      'ProfileWireContract.decodeAvatar(value)',
      '.clamp(1, ProfileWireContract.maxAvatarDimension)',
      'cacheWidth: decodeSize',
      'cacheHeight: decodeSize',
    ]);
    _expectOrdered('Profile editor bounded decode', profileEditor, const [
      'ProfileWireContract.isBoundedAvatarBytes(',
      'maxEncodedBytes: JamiClient.maxProfileImageBytes',
      'decodeBoundedRaster(',
    ]);
  });

  test('conversation requests cross a bounded, replay-safe firewall', () {
    _expectAll('Android pending request gate', androidGate, const [
      'maxPending: Int = 64',
      'maxAdmissionsPerWindow: Int = 16',
      'windowMs: Long = 60_000L',
      'ids.size >= maxPending || admittedAt.size >= maxAdmissionsPerWindow',
      'fun contains(id: String): Boolean = id in ids',
      'id in ids || (ids.size < maxPending && ids.add(id))',
    ]);
    _expectOrdered('Android duplicate admission', androidGate, const [
      'if (id in ids) return PendingRequestAdmission.DUPLICATE',
      'ids.size >= maxPending || admittedAt.size >= maxAdmissionsPerWindow',
      'return PendingRequestAdmission.REJECTED',
      'return PendingRequestAdmission.NEW',
    ]);
    _expectAll('Windows pending request gate', windowsGate, const [
      'max_pending = 64',
      'max_per_window = 16',
      'window_ms = 60000',
      'ids_.size() >= max_pending_ || admitted_at_.size() >= max_per_window_',
      'bool Contains(const std::string& id) const',
      'ids_.size() < max_pending_ && ids_.insert(id).second',
    ]);
    _expectOrdered('Windows duplicate admission', windowsGate, const [
      'if (ids_.find(id) != ids_.end()) return PendingRequestAdmission::kDuplicate',
      'ids_.size() >= max_pending_ || admitted_at_.size() >= max_per_window_',
      'return PendingRequestAdmission::kRejected',
      'return PendingRequestAdmission::kNew',
    ]);

    final androidQueue = _section(
      androidCore,
      'private val rejectedConnectQueue',
      'internal fun onConversationRequest(',
      owner: 'Android rejected-request drain',
    );
    _expectAll('Android rejected-request bounds', androidQueue, const [
      'ArrayDeque<RejectedConnect>()',
      'LinkedHashSet<String>()',
      'LinkedHashSet<RejectedConnect>()',
      'MAX_REJECTED_CONNECT_QUEUE = 64',
      'MAX_REJECTED_CONNECT_RESCAN_ACCOUNTS = 16',
      'MAX_REJECTED_CONNECT_RESCAN_RETRIES = 3',
      'MAX_REJECTED_CONNECT_TOMBSTONES = 128',
      'while (rejectedConnectTombstones.size > MAX_REJECTED_CONNECT_TOMBSTONES)',
      'rejectedConnectTombstones.remove(rejectedConnectTombstones.first())',
      'request in rejectedConnectTombstones',
      'request in rejectedConnectKeys',
      'rejectedConnectQueue.size >= MAX_REJECTED_CONNECT_QUEUE',
      'rejectedConnectRescanAccounts.size < MAX_REJECTED_CONNECT_RESCAN_ACCOUNTS',
      'if (rejectedConnectDrainScheduled',
      'worker.execute(DaemonOperation.DECLINE_CONNECT)',
      'JamiService.getConversationRequests(owner)',
      'accountId == owner && pendingConnectGate.contains(conversationId)',
      'if (admitted) continue',
      'JamiService.declineConversationRequest(owner, conversationId)',
      'JamiService.declineConversationRequest(next.accountId, next.conversationId)',
      'rejectedConnectRescanFailures[owner] = failures',
      'main.postDelayed(::scheduleRejectedConnectDrain, 250L)',
    ]);
    final androidRequest = _section(
      androidCore,
      'internal fun onConversationRequest(',
      'internal fun takePending(',
      owner: 'Android conversation request admission',
    );
    _expectAll('Android exact request admission', androidRequest, const [
      "modeValue.singleOrNull()?.takeIf { it in '0'..'3' }?.let { it - '0' }",
      'if (!validConversation || from.isEmpty() || mode == null)',
      'val isGroup = mode != 0',
      'RejectedConnect(account, conversationId) in rejectedConnectTombstones',
      'account in rejectedConnectRescanAccounts',
      'pendingConnectGate.admit(conversationId, monotonicMs())',
      'if (it == PendingRequestAdmission.NEW)',
      'pendingConnect[conversationId] = PendingConnect(account, from, isGroup, name)',
      'if (admission == PendingRequestAdmission.REJECTED)',
      'declineUnadmittedRequest(account, conversationId)',
      'if (admission == PendingRequestAdmission.DUPLICATE) return',
      '"type" to "connectRequest"',
    ]);
    final androidSelection = _section(
      androidCore,
      'private fun selectAccount(',
      'fun attach(context: Context)',
      owner: 'Android request ownership switch',
    );
    _expectAll('Android request ownership switch', androidSelection, const [
      'synchronized(pendingConnectLock)',
      'rejectedConnectRescanAccounts += previousAccount',
      'accountId = id',
      'pendingConnect.clear()',
      'pendingConnectGate.clear()',
      'JamiService.declineConversationRequest(previousAccount, conversationId)',
      'rememberRejectedConnect(RejectedConnect(previousAccount, conversationId))',
      'scheduleRejectedConnectDrain()',
    ]);

    _expectAll('Windows rejected-request bounds', windowsBridge, const [
      'kMaxRejectedConnectQueue = 64',
      'kMaxRejectedConnectRescanAccounts = 16',
      'kMaxRejectedConnectRescanRetries = 3',
      'kMaxRejectedConnectTombstones = 128',
    ]);
    final windowsQueue = _section(
      windowsBridge,
      'void QueueRejectedConversationRequest(',
      '// Jami consumes a trusted contact',
      owner: 'Windows rejected-request drain',
    );
    _expectAll('Windows rejected-request drain', windowsQueue, const [
      'g_rejectedConnectTombstones.find(key)',
      'g_rejectedConnectQueue.size() < kMaxRejectedConnectQueue',
      'g_rejectedConnectRescanAccounts.size() < kMaxRejectedConnectRescanAccounts',
      'if (!g_rejectedConnectDrainScheduled)',
      'Post(DrainRejectedConnects)',
      'while (g_rejectedConnectTombstoneOrder.size() > kMaxRejectedConnectTombstones)',
      'g_rejectedConnectTombstones.erase(',
      'libjami::getConversationRequests(rescanAccount)',
      'g_accountId == rescanAccount && g_pendingConnectGate.Contains(id->second)',
      'if (admitted) continue',
      'libjami::declineConversationRequest(rescanAccount, id->second)',
      'RememberRejectedConnectLocked(key)',
      '++g_rejectedConnectRescanFailures[rescanAccount]',
      'g_tasks.emplace_back(DrainRejectedConnects)',
    ]);
    final windowsRequest = _section(
      windowsBridge,
      'void OnConversationRequest(',
      'void OnAccountMessage(',
      owner: 'Windows conversation request admission',
    );
    _expectAll('Windows exact request admission', windowsRequest, const [
      "modeValue.size() == 1 && modeValue.front() >= '0' && modeValue.front() <= '3'",
      'const bool isGroup = validMode && modeValue != "0"',
      'g_rejectedConnectRescanAccounts.find(accountId)',
      'g_rejectedConnectTombstones.find(key)',
      'g_pendingConnectGate.Admit(conversationId, now)',
      'if (admission == sybl::PendingRequestAdmission::kNew)',
      'g_pendingConnect[conversationId] = from',
      'if (admission == sybl::PendingRequestAdmission::kRejected)',
      'QueueRejectedConversationRequest(accountId, conversationId)',
      'if (admission == sybl::PendingRequestAdmission::kDuplicate) return',
      'Emit("connectRequest"',
    ]);
    final windowsSelection = _section(
      windowsBridge,
      'void SelectAccountLocked(',
      'bool IsTrustedPeer(',
      owner: 'Windows request ownership switch',
    );
    _expectAll('Windows request ownership switch', windowsSelection, const [
      'g_rejectedConnectRescanAccounts.insert(g_accountId)',
      'g_tasks.emplace_back(DrainRejectedConnects)',
      'g_pendingConnect.clear()',
      'g_pendingConnectAccount.clear()',
      'g_pendingConnectIsGroup.clear()',
      'g_pendingConnectGate.Clear()',
      'g_accountId = accountId',
    ]);
    final windowsCallback = _section(
      windowsBridge,
      'exportable_callback<libjami::ConversationSignal::ConversationRequestReceived>',
      'Log("signal handlers registered")',
      owner: 'Windows conversation request callback',
    );
    _expectAll('Windows conversation request callback', windowsCallback, const [
      'try {',
      'OnConversationRequest(',
      'catch (...)',
    ]);
    expect(
      windowsCallback,
      isNot(contains('throw;')),
      reason: 'Windows daemon callback must not rethrow into libjami',
    );
  });

  test(
    'Windows video source transition is taken only by its admitting ticket',
    () {
      // Comments must not satisfy or hide a contract.
      final setSource = _section(
        windowsBridge,
        'void SetOutgoingVideoSource(',
        'void StartVideo(',
        owner: 'Windows outgoing video source request',
      ).replaceAll(RegExp(r'//[^\n]*'), '');
      final allowedAccess = RegExp(
        r'g_sourceTransition\s*\.\s*Admit\(|'
        r'g_sourceTransition\s*\.\s*Take\(ticket\)|'
        r'g_sourceTransition\s*->\s*done\s*=\s*std::move\(reply\)\s*;|'
        r'\|\|\s*g_sourceTransition\s*\)',
      );
      expect(
        setSource.replaceAll(allowedAccess, '').contains('g_sourceTransition'),
        isFalse,
        reason:
            'the request may only Admit, Take(ticket), test busy, and '
            'attach its own reply to g_sourceTransition',
      );
      expect(
        allowedAccess.allMatches(setSource).length,
        5,
        reason:
            'expected one Admit, two Take(ticket), one busy test and one '
            'done attachment',
      );
      _expectAll('Windows outgoing video source request', setSource, const [
        'std::uint64_t ticket = 0;',
        'ticket = g_sourceTransition.Admit(',
        'g_sourceTransition.Take(ticket)',
      ]);
      expect(
        setSource,
        isNot(contains('g_sourceTransition->source.requested.call_id')),
        reason: 'a request must not take a pending transition by call id alone',
      );
      expect(
        setSource,
        isNot(contains('g_sourceTransition.reset()')),
        reason: 'only a ticket Take may clear the pending transition here',
      );
      expect(
        RegExp(r'g_sourceTransition\.Take\(').allMatches(setSource).length,
        RegExp(
          r'g_sourceTransition\.Take\(ticket\)',
        ).allMatches(setSource).length,
        reason:
            'every take inside the request must present this invocation ticket',
      );
    },
  );

  test('Windows host clipboard send carries the captured session binding', () {
    final dispatch =
        _dispatch(
              windowsChannel,
              '} else if (method == "remoteClipboardHostSend") {',
              RegExp(r'\n\s*} else if \(method == "[^"]+"\)'),
              owner: 'Windows host clipboard send dispatch',
            )
            .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
            .replaceAll(RegExp(r'//[^\n]*'), '');
    _expectOrdered('Windows host clipboard send dispatch', dispatch, const [
      'ArgInt64(call, "sourceRevision", 0)',
      'ArgInt64(call, "hostGeneration", 0)',
      'remote_control_->SendClipboard(',
      'ArgString(call, "text", "")',
      'ArgString(call, "callId", "")',
      'ArgString(call, "peerJamiId", "")',
      'ArgString(call, "controllerDeviceId", "")',
      'revision > 0 ? static_cast<uint64_t>(revision) : 0',
      'generation > 0 ? static_cast<uint64_t>(generation) : 0',
    ]);
    _expectAll('Windows host clipboard send header', windowsHostHeader, const [
      'LocalControlResult SendClipboard(const std::string& utf8,',
      'std::uint64_t source_revision,',
      'std::uint64_t host_generation);',
    ]);
    _expectAll('Dart host clipboard send', dartBridge, const [
      "'controllerDeviceId': controllerDeviceId",
      "'hostGeneration': hostGeneration",
    ]);
  });

  test('Windows second launch and focus request a covered reveal', () {
    String strip(String source) => source
        .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
        .replaceAll(RegExp(r'//[^\n]*'), '');
    // Whitelist: every statement of the branch must be one of these, in order.
    const allowedSecondLaunch = [
      '#ifndef SYBL_VISUAL_UAT if (HWND existing = sybl::invite_link::FindMainWindow())',
      'sybl::invite_link::ForwardAndRequestReveal(existing, invite)',
      '#endif #ifdef SYBL_VISUAL_UAT return EXIT_FAILURE',
      '#else return EXIT_SUCCESS',
      '#endif',
    ];
    List<String> secondLaunchStatements(String mainSource) {
      final section = strip(
        _section(
          mainSource,
          'if (instance_lock == INVALID_HANDLE_VALUE) {',
          'RegisterCurrentExecutable();',
          owner: 'Windows second launch branch',
        ),
      );
      final open = section.indexOf('{');
      var depth = 0;
      var close = -1;
      for (var i = open; i < section.length && close < 0; i++) {
        if (section[i] == '{') depth++;
        if (section[i] == '}' && --depth == 0) close = i;
      }
      expect(
        close,
        greaterThan(open),
        reason: 'second launch branch unbalanced',
      );
      return section
          .substring(open + 1, close)
          .split(RegExp(r'[;{}]'))
          .map((statement) => statement.replaceAll(RegExp(r'\s+'), ' ').trim())
          .where((statement) => statement.isNotEmpty)
          .toList();
    }

    bool isWhitelisted(List<String> statements) =>
        statements.length == allowedSecondLaunch.length &&
        [
          for (var i = 0; i < statements.length; i++)
            statements[i] == allowedSecondLaunch[i],
        ].every((same) => same);

    expect(
      secondLaunchStatements(windowsMain),
      allowedSecondLaunch,
      reason:
          'second launch may only look up the window, ask it to reveal '
          'itself, and return',
    );
    const forwardCall =
        'sybl::invite_link::ForwardAndRequestReveal(existing, invite);';
    expect(windowsMain, contains(forwardCall));
    final openIconMutant = windowsMain.replaceFirst(
      forwardCall,
      '$forwardCall ::OpenIcon(existing); ::BringWindowToTop(existing);',
    );
    final oldBodyMutant = windowsMain.replaceFirst(
      forwardCall,
      '::ShowWindow(existing, SW_SHOW); ::SetForegroundWindow(existing);',
    );
    expect(openIconMutant, isNot(windowsMain));
    expect(oldBodyMutant, isNot(windowsMain));
    expect(isWhitelisted(secondLaunchStatements(windowsMain)), isTrue);
    expect(isWhitelisted(secondLaunchStatements(openIconMutant)), isFalse);
    expect(isWhitelisted(secondLaunchStatements(oldBodyMutant)), isFalse);

    // A preprocessor directive can rewrite the whitelisted call without
    // changing any statement inside the branch.
    bool hasDirective(String mainSource) => RegExp(
      r'^[ \t]*#[ \t]*(define|undef)\b',
      multiLine: true,
    ).hasMatch(strip(mainSource));
    expect(
      hasDirective(windowsMain),
      isFalse,
      reason: 'main.cpp must not define or undefine macros',
    );
    final macroMutant = windowsMain.replaceFirst(
      'int APIENTRY wWinMain(',
      '#define ForwardAndRequestReveal(window, invite) '
          '::ShowWindow(window, SW_SHOW)\nint APIENTRY wWinMain(',
    );
    expect(macroMutant, isNot(windowsMain));
    expect(isWhitelisted(secondLaunchStatements(macroMutant)), isTrue);
    expect(hasDirective(macroMutant), isTrue);

    final flutterWindow = strip(_read('windows/runner/flutter_window.cpp'));
    final focus = _section(
      flutterWindow,
      'if (command == "focus") {',
      'SendDiagnosticCommand(command)',
      owner: 'Windows diagnostic focus command',
    );
    _expectAll('Windows diagnostic focus command', focus, const [
      'RevealCovered()',
    ]);
    expect(focus, isNot(contains('ShowWindow')));
    expect(focus, isNot(contains('SetForegroundWindow')));
    _expectOrdered('Windows reveal request dispatch', flutterWindow, const [
      'DispatchRevealRequest(',
      'BeginPrivacyCoveredRestore()',
      'FinishPrivacyCoveredRestore()',
      '&revealed',
    ]);
    _expectAll('Windows covered reveal', flutterWindow, const [
      'RunCoveredReveal(sybl::window::WindowRevealOperations(',
      'bool FlutterWindow::RevealMinimized(HWND)',
    ]);
  });

  test('Windows covered reveals apply the deferred presentation', () {
    String strip(String source) => source
        .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
        .replaceAll(RegExp(r'//[^\n]*'), '');
    final flutterWindow = strip(_read('windows/runner/flutter_window.cpp'));
    expect(
      RegExp(r'ApplyDeferredPresentation\(\)').allMatches(flutterWindow).length,
      2,
      reason: 'tray/focus reveal and reveal request must both apply it',
    );
    _expectOrdered('Windows reveal routine', flutterWindow, const [
      'RunCoveredReveal(sybl::window::WindowRevealOperations(',
      'FinishPrivacyCoveredRestore(); },',
      'ApplyDeferredPresentation()',
    ]);
    _expectOrdered('Windows reveal request', flutterWindow, const [
      'DispatchRevealRequest(',
      'FinishPrivacyCoveredRestore(); },',
      'ApplyDeferredPresentation()',
      '&revealed',
    ]);
    final helper = strip(_read('windows/runner/window_presentation.h'));
    _expectOrdered('Windows show step', helper, const [
      '::ShowWindow(window,',
      'apply_deferred()',
    ]);
  });

  test('Windows tray restore uses the one covered reveal', () {
    String strip(String source) => source
        .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
        .replaceAll(RegExp(r'//[^\n]*'), '');
    // The text of RestoreWindow before this change: it assembled its own
    // reveal operations without the deferred presentation step.
    const preChangeTray = '''
void SystemTray::RestoreWindow() noexcept {
  if (!owner_ || !::IsWindow(owner_)) {
    return;
  }
  sybl::window::RunCoveredReveal(sybl::window::WindowRevealOperations(
      owner_,
      [this]() { return prepare_restore_ && prepare_restore_(); },
      [this]() { finish_restore_(); }));
}
''';
    // Every WindowRevealOperations( call must be in RevealCovered or the
    // reveal-request dispatch and carry the deferred-apply argument.
    bool singleReveal(String flutterWindow, String tray) {
      if (tray.contains('WindowRevealOperations(')) return false;
      final calls = 'WindowRevealOperations('
          .allMatches(flutterWindow)
          .toList();
      if (calls.length != 2) return false;
      final reveal = flutterWindow.indexOf(
        'bool FlutterWindow::RevealCovered()',
      );
      final revealEnd = flutterWindow.indexOf('RevealMinimized', reveal);
      final dispatch = flutterWindow.indexOf('DispatchRevealRequest(');
      final dispatchEnd = flutterWindow.indexOf('&revealed', dispatch);
      if (reveal < 0 ||
          revealEnd < reveal ||
          dispatch < 0 ||
          dispatchEnd < dispatch) {
        return false;
      }
      var inReveal = 0;
      var inDispatch = 0;
      for (final call in calls) {
        final close = flutterWindow.indexOf(RegExp(r'\}\)\)?[,;]'), call.start);
        final body = flutterWindow.substring(
          call.start,
          close < 0 ? flutterWindow.length : close,
        );
        if (!body.contains('ApplyDeferredPresentation()')) return false;
        if (call.start > reveal && call.start < revealEnd) inReveal++;
        if (call.start > dispatch && call.start < dispatchEnd) inDispatch++;
      }
      return inReveal == 1 && inDispatch == 1;
    }

    final flutterWindow = strip(_read('windows/runner/flutter_window.cpp'));
    final tray = strip(_read('windows/runner/system_tray.cpp'));
    expect(singleReveal(flutterWindow, tray), isTrue);
    expect(singleReveal(flutterWindow, strip(preChangeTray)), isFalse);
    // A third assembly of the operations, or a missing deferred step, fails.
    final extra =
        '$flutterWindow\nvoid X() { sybl::window::WindowRevealOperations(h, a, b); }';
    expect(singleReveal(extra, tray), isFalse);
    final noDeferred = flutterWindow.replaceFirst(
      '[this]() { ApplyDeferredPresentation(); }',
      '',
    );
    expect(noDeferred, isNot(flutterWindow));
    expect(singleReveal(noDeferred, tray), isFalse);
    // The one Initialize call, with its whole argument list, is the contract;
    // the lambda text elsewhere (dead code) does not count.
    const trayCall = 'system_tray_.Initialize(';
    const trayArguments =
        'GetHandle(), IDI_APP_ICON, L"Doorlight", [this]() { return RevealCovered(); }';
    String? trayInitializeArguments(String source) {
      if (trayCall.allMatches(source).length != 1) return null;
      final open = source.indexOf(trayCall) + trayCall.length;
      var depth = 1;
      for (var i = open; i < source.length; i++) {
        if (source[i] == '(') depth++;
        if (source[i] == ')' && --depth == 0) {
          return source
              .substring(open, i)
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim();
        }
      }
      return null;
    }

    expect(trayInitializeArguments(flutterWindow), trayArguments);
    final ownLambda = flutterWindow.replaceFirst(
      '[this]() { return RevealCovered(); });',
      '[this]() { return true; });\n'
          'auto dead = [this]() { return RevealCovered(); };',
    );
    expect(ownLambda, isNot(flutterWindow));
    expect(ownLambda, contains('[this]() { return RevealCovered(); }'));
    expect(trayInitializeArguments(ownLambda), isNot(trayArguments));
    expect(
      trayInitializeArguments('$flutterWindow\n$trayCall a, b);'),
      isNull,
      reason: 'a second Initialize call must fail',
    );
    expect(tray, contains('reveal_()'));
  });

  test('Windows window commands never reveal a hidden window', () {
    String strip(String source) => source
        .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
        .replaceAll(RegExp(r'//[^\n]*'), '');
    final commands = strip(
      _section(
        windowsChannel,
        '} else if (command == "minimize") {',
        '} else if (command == "close") {',
        owner: 'Windows minimize/maximize commands',
      ),
    );
    _expectAll('Windows minimize/maximize commands', commands, const [
      '::IsWindowVisible(owner_) && !::IsIconic(owner_)',
      '::PostMessageW(owner_, WM_SYSCOMMAND, SC_MINIMIZE, 0)',
      'ToggleMaximizeWithoutReveal(owner,',
      'RevealRequestMessage()',
    ]);
    expect(commands, isNot(contains('::ShowWindow(')));
    final win32Window = strip(_read('windows/runner/win32_window.cpp'));
    expect(
      win32Window,
      contains(
        'if ((wparam & 0xfff0) == SC_MINIMIZE && !IsWindowVisible(hwnd)) return 0;',
      ),
      reason: 'Queued minimize must recheck visibility at native dispatch',
    );
    final flutterWindow = strip(_read('windows/runner/flutter_window.cpp'));
    expect(
      flutterWindow,
      contains('sybl::window::MinimizeWithoutReveal(GetHandle());'),
      reason: 'An exit completion must not reveal a source hidden meanwhile',
    );
    final presentation = _section(
      win32Window,
      'bool Win32Window::SetPresentation(',
      'void Win32Window::Destroy()',
      owner: 'Windows presentation command',
    );
    _expectAll('Windows presentation command', presentation, const [
      'if (!IsWindowVisible(hwnd)) { deferred_presentation_mode_ = mode; deferred_reset_position_ = reset_position; return true; }',
      'RevealMinimized(hwnd)',
      'restored.showCmd = SW_SHOWNORMAL;',
    ]);
    expect(presentation, isNot(contains('SW_HIDE')));
  });

  String stripComments(String source) => source
      .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
      .replaceAll(RegExp(r'//[^\n]*'), '');
  String normalize(String source) =>
      source.replaceAll(RegExp(r'\s+'), ' ').trim();

  test('Windows identity data root resolves only the established store', () {
    final profile = normalize(
      stripComments(_read('windows/runner/uat_profile.h')),
    );
    expect(
      profile,
      endsWith(
        '#else inline HRESULT KnownFolderPath(REFKNOWNFOLDERID folder, DWORD flags, HANDLE token, PWSTR* output) { return SHGetKnownFolderPath(folder, flags, token, output); } #endif }',
      ),
      reason:
          'Production known-folder lookup must delegate unchanged to Windows',
    );
    final bridge = stripComments(windowsBridge);
    final setup = normalize(
      _section(
        bridge,
        'bool SetupDataDirs() {',
        'struct ArchiveRecoveryRecord',
        owner: 'Windows data directory setup',
      ),
    );
    expect(setup, isNot(contains('GetTempPath')));
    expect(setup, isNot(contains('TEMP')));
    expect(setup, isNot(contains(r'L".\\"')));
    expect(RegExp(r'\bSetupDataDirs\(').allMatches(bridge).length, 2);
    // The resolver is the only source of the root; a mismatch between the
    // environment value and the known folder, or an unresolved root, ends
    // setup before the global or any variable is changed.
    expect(
      RegExp(
        r'const auto root = sybl::archive::ResolveIdentityDataRoot\(environment, known, sybl::archive::IsSameDirectory\); '
        r'if \(root\.outcome == sybl::archive::IdentityRootOutcome::kMismatch\) \{ Log\("[^"]*"\); return false; \} '
        r'if \(root\.outcome != sybl::archive::IdentityRootOutcome::kResolved\) \{ Log\("[^"]*"\); return false; \} '
        r'const std::wstring& base = root\.root;',
      ).hasMatch(setup),
      isTrue,
      reason: 'setup no longer takes its root from the resolver and stops',
    );
    expect(
      RegExp(
        r'const bool set = '
        r'SetEnvironmentVariableW\(L"JAMI_DATA_HOME", base\.c_str\(\)\) && '
        r'SetEnvironmentVariableW\(L"JAMI_CONFIG_HOME", base\.c_str\(\)\) && '
        r'SetEnvironmentVariableW\(L"JAMI_CACHE_HOME", cache\.c_str\(\)\); '
        r'if \(!set\) \{ Log\("[^"]*"\); return false; \}',
      ).hasMatch(setup),
      isTrue,
      reason: 'a failed environment write no longer fails setup',
    );
    // Whole-body whitelist: any added, removed, reordered or altered
    // statement (including whatever fills `environment` and `known`) fails.
    List<String> statementsOf(String body) => RegExp(r'[^;{}]*[;{}]')
        .allMatches(body)
        .map((m) => m.group(0)!.trim())
        .where((statement) => statement.isNotEmpty)
        .toList();
    const expectedStatements = <String>[
      'bool SetupDataDirs() {',
      'std::optional<std::wstring> environment;',
      'const DWORD needed = GetEnvironmentVariableW(L"LOCALAPPDATA", nullptr, 0);',
      'if (needed > 0) {',
      'std::wstring value(needed, L\'\\0\');',
      'const DWORD n = GetEnvironmentVariableW(L"LOCALAPPDATA", value.data(), needed);',
      'if (n > 0 && n < needed) {',
      'value.resize(n);',
      'environment = std::move(value);',
      '}',
      '}',
      'std::optional<std::wstring> known;',
      'PWSTR knownPath = nullptr;',
      'if (SUCCEEDED(sybl::uat::KnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &knownPath)) && knownPath) known = std::wstring(knownPath);',
      'if (knownPath) CoTaskMemFree(knownPath);',
      'const auto root = sybl::archive::ResolveIdentityDataRoot(environment, known, sybl::archive::IsSameDirectory);',
      'if (root.outcome == sybl::archive::IdentityRootOutcome::kMismatch) {',
      'Log("data dirs refused: LOCALAPPDATA and the LocalAppData known folder are different directories");',
      'return false;',
      '}',
      'if (root.outcome != sybl::archive::IdentityRootOutcome::kResolved) {',
      'Log("data dirs unresolved: refusing to boot without the established identity root");',
      'return false;',
      '}',
      'const std::wstring& base = root.root;',
      'const std::wstring cache = base + L"\\\\cache";',
      'g_jamiDataDir = std::filesystem::path(base) / L"jami";',
      'const bool set = SetEnvironmentVariableW(L"JAMI_DATA_HOME", base.c_str()) && SetEnvironmentVariableW(L"JAMI_CONFIG_HOME", base.c_str()) && SetEnvironmentVariableW(L"JAMI_CACHE_HOME", cache.c_str());',
      'if (!set) {',
      'Log("data dirs could not be configured");',
      'return false;',
      '}',
      'Log("data dirs -> %LOCALAPPDATA%\\\\Syb-L (data/config in \\\\jami, cache in \\\\cache)");',
      'return true;',
      '}',
    ];
    expect(
      statementsOf(setup),
      expectedStatements,
      reason: 'SetupDataDirs body differs from the reviewed statements',
    );
    final resolverCall =
        'const auto root = sybl::archive::ResolveIdentityDataRoot(environment, known, sybl::archive::IsSameDirectory);';
    final mismatchReturn = RegExp(
      r'if \(root\.outcome == sybl::archive::IdentityRootOutcome::kMismatch\) \{ Log\("[^"]*"\); return false; \} ',
    );
    final mismatchBlock = mismatchReturn.firstMatch(setup)!.group(0)!;
    final withoutMismatch = setup.replaceFirst(mismatchBlock, '');
    final earlyReturn = RegExp(
      r'if \(root\.outcome != sybl::archive::IdentityRootOutcome::kResolved\) \{ Log\("[^"]*"\); return false; \} ',
    );
    const globalWrite =
        'g_jamiDataDir = std::filesystem::path(base) / L"jami"; ';
    const environmentWrites =
        'SetEnvironmentVariableW(L"JAMI_CACHE_HOME", cache.c_str()); ';
    final wrongBodies = <String, String>{
      'environment never assigned': setup.replaceFirst(
        'environment = std::move(value);',
        '',
      ),
      'fallback helper feeds known': setup.replaceFirst(
        resolverCall,
        'if (!known) known = SyblFallbackRoot(); $resolverCall',
      ),
      'GetTempPathW added': setup.replaceFirst(
        '{',
        '{ wchar_t tmp[MAX_PATH]; GetTempPathW(MAX_PATH, tmp);',
      ),
      'environment and known swapped': setup.replaceFirst(
        '(environment, known,',
        '(known, environment,',
      ),
      'early return removed': setup.replaceFirst(earlyReturn, ''),
      'mismatch check removed': withoutMismatch,
      'mismatch check after the global is assigned': withoutMismatch
          .replaceFirst(globalWrite, '$globalWrite$mismatchBlock'),
      'mismatch check after the environment writes': withoutMismatch
          .replaceFirst(environmentWrites, '$environmentWrites$mismatchBlock'),
      'environment written before the mismatch check': setup.replaceFirst(
        mismatchBlock,
        'SetEnvironmentVariableW(L"JAMI_DATA_HOME", L""); $mismatchBlock',
      ),
      'same-directory check replaced by a constant': setup.replaceFirst(
        'sybl::archive::IsSameDirectory)',
        '[](const std::wstring&, const std::wstring&) { return true; })',
      ),
    };
    wrongBodies.forEach((name, body) {
      expect(body, isNot(setup), reason: '$name: mutation did not apply');
      expect(
        statementsOf(body),
        isNot(expectedStatements),
        reason: '$name: whitelist accepted a wrong SetupDataDirs body',
      );
    });
    expect(setup, endsWith('return true; }'));
    // The boot call site consumes the result before the first libjami call.
    final boot = normalize(
      _section(
        bridge,
        'if (!g_daemonInitialized.load()) {',
        'Log("--- Syb-L libjami boot ---");',
        owner: 'Windows boot data directory call',
      ),
    );
    expect(
      boot,
      'if (!g_daemonInitialized.load()) { if (!SetupDataDirs()) return;',
    );
    expect(
      bridge.indexOf('if (!SetupDataDirs()) return;'),
      lessThan(bridge.indexOf('libjami::init(')),
    );
  });

  test('Windows archive reconciliation keeps a failing account result', () {
    final bridge = stripComments(windowsBridge);
    final protection = normalize(
      _section(
        bridge,
        'bool InitializeArchiveProtection(',
        'static std::string AwaitRestoredUsername(',
        owner: 'Windows archive protection initialisation',
      ),
    );
    expect(
      RegExp(r'\breconciled\s*=(?!=)').allMatches(protection).length,
      1,
      reason: 'the overall result must be assigned exactly once',
    );
    expect(
      protection,
      contains(
        'const bool reconciled = sybl::archive::ReconcileAccounts( '
        'accounts, [&](const std::string& candidateAccount) {',
      ),
    );
    expect(
      RegExp(r'\bbreak;|\bcontinue;').hasMatch(protection),
      isFalse,
      reason: 'ordering and stopping belong to ReconcileAccounts',
    );
    expect(
      RegExp(
        r'g_pendingRestore->account_id == candidateAccount\) '
        r'return Outcome::kSkipped;',
      ).hasMatch(protection),
      isTrue,
    );
    expect(
      RegExp(
        r'archive protection state is missing or malformed"\); '
        r'return Outcome::kIndeterminate; \}',
      ).hasMatch(protection),
      isTrue,
    );
    expect(
      RegExp(
        r'return sybl::archive::ReconcileArchiveProtection\( '
        r'candidateAccount, stored->secret, '
        r'hasPassword->second == "true", callbacks\) '
        r'\? Outcome::kHealthy : Outcome::kFailed; \} \}\);',
      ).hasMatch(protection),
      isTrue,
    );
    expect(
      protection,
      contains(
        'g_archiveProtectionReady = reconciled; '
        'g_archiveRecoveryBlocked = !reconciled;',
      ),
    );
  });

  // Removes `//` and `/* */` comments, but never inside a string or character
  // literal, so a literal holding `/*` cannot swallow code.
  int skipCppLiteral(String source, int at) {
    final quote = source[at];
    var i = at + 1;
    while (i < source.length && source[i] != quote) {
      if (source[i] == r'\') i++;
      i++;
    }
    return i + 1;
  }

  String stripCppComments(String source) {
    final out = StringBuffer();
    var i = 0;
    while (i < source.length) {
      final c = source[i];
      final next = i + 1 < source.length ? source[i + 1] : '';
      if (c == '/' && next == '/') {
        while (i < source.length && source[i] != '\n') {
          i++;
        }
      } else if (c == '/' && next == '*') {
        final end = source.indexOf('*/', i + 2);
        i = end < 0 ? source.length : end + 2;
        out.write(' ');
      } else if (c == '"' || c == "'") {
        final end = skipCppLiteral(source, i);
        out.write(source.substring(i, end));
        i = end;
      } else {
        out.write(c);
        i++;
      }
    }
    return out.toString();
  }

  // Every top-level function definition (name at column 0), by name.
  Map<String, List<String>> cppFunctions(String source) {
    final definition = RegExp(
      r'^[A-Za-z_][\w:<>,*& ]*?\b([A-Za-z_]\w*)\((?:[^;{}()]|\([^()]*\)|\{\})*\)\s*(?:const\s*)?\{',
      multiLine: true,
    );
    final functions = <String, List<String>>{};
    for (final match in definition.allMatches(source)) {
      var depth = 0;
      var i = match.end - 1;
      while (i < source.length) {
        final c = source[i];
        if (c == '"' || c == "'") {
          i = skipCppLiteral(source, i);
          continue;
        }
        if (c == '{') depth++;
        if (c == '}' && --depth == 0) break;
        i++;
      }
      functions
          .putIfAbsent(match.group(1)!, () => [])
          .add(source.substring(match.start, i + 1));
    }
    return functions;
  }

  // The reviewed Windows selected-result path. Each list joins with single
  // spaces into the comment-stripped, whitespace-normalised source.
  const searchMessageFunctions = <String, List<String>>{
    'SearchMessageReplyCurrent': [
      r'bool SearchMessageReplyCurrent(const SearchMessageReply& reply) {',
      r'const sybl::history_search::MessageLoadTicket ticket{reply.accountId, reply.peerId, reply.conversationId, reply.messageId, reply.accountRevision, reply.privacyEpoch};',
      r'return sybl::history_search::MessageLoadCurrent(ticket, SearchMessageFacts(ticket));',
      r'}',
    ],
    'LoadSearchMessage': [
      r'void LoadSearchMessage(const std::string& accountId, const std::string& peerId, const std::string& conversationId, const std::string& messageId, std::function<void(std::optional<SearchMessageReply>)> done) {',
      r'try {',
      r'const auto owner = CaptureAccountCommandOwner(accountId);',
      r'if (!owner) {',
      r'if (done) done(std::nullopt);',
      r'return;',
      r'}',
      r'uint64_t epoch;',
      r'{',
      r'std::lock_guard<std::mutex> lock(g_mutex);',
      r'epoch = g_historySearchEpoch;',
      r'}',
      r'Post([ticket = sybl::history_search::MessageLoadTicket{owner->accountId, peerId, conversationId, messageId, owner->revision, epoch}, done]() mutable {',
      r'try {',
      r'ticket.peer_id = NormalizeOwnerKey(ticket.peer_id);',
      r'std::lock_guard<std::mutex> registrationLock(g_loadRegistrationMutex);',
      r'const auto facts = SearchMessageFacts(ticket);',
      r'bool canStart = false;',
      r'{',
      r'std::lock_guard<std::mutex> lock(g_mutex);',
      r'canStart = g_conversationLoads.CanStart();',
      r'}',
      r'if (sybl::history_search::AdmitMessageLoad(ticket, facts, canStart)) {',
      r'const auto loadId = libjami::loadSybLMessage(ticket.account_id, ticket.conversation_id, ticket.message_id);',
      r'std::lock_guard<std::mutex> lock(g_mutex);',
      r'if (loadId != 0 && g_searchMessageLoads.Register( g_conversationLoads, loadId, sybl::conversation::PendingLoad{sybl::conversation::LoadKind::kSearchMessage, ticket.peer_id, ticket.conversation_id, ticket.message_id, 1}, SearchMessageRequest{ticket, done})) return;',
      r'}',
      r'}',
      r'catch (...) {',
      r'Log("loadSearchMessage threw");',
      r'}',
      r'try {',
      r'if (done) done(std::nullopt);',
      r'}',
      r'catch (...) {}',
      r'});',
      r'}',
      r'catch (...) {',
      r'try {',
      r'if (done) done(std::nullopt);',
      r'}',
      r'catch (...) {}',
      r'}',
      r'}',
    ],
    'CompleteSearchMessage': [
      r'void CompleteSearchMessage(const SearchMessageRequest& request, const std::string& accountId, const std::string& conversationId, const std::vector<libjami::SwarmMessage>& messages) {',
      r'std::optional<SearchMessageReply> reply;',
      r'try {',
      r'sybl::history_search::DispatchMessageLoad( sybl::history_search::CompleteMessageLoad(request.ticket, accountId, conversationId, SearchMessageFacts(request.ticket), messages), {.project = [&](std::size_t index) {',
      r'reply = SearchMessageReplyFor(request.ticket, TimelineItemJson(request.ticket.account_id, request.ticket.peer_id, request.ticket.conversation_id, messages[index], false));',
      r'}, .unavailable = [&] {',
      r'reply.reset();',
      r'}});',
      r'}',
      r'catch (...) {',
      r'reply.reset();',
      r'}',
      r'try {',
      r'if (request.done) request.done(std::move(reply));',
      r'}',
      r'catch (...) {}',
      r'}',
    ],
    'SearchMessageReplyFor': [
      r'std::optional<SearchMessageReply> SearchMessageReplyFor(const sybl::history_search::MessageLoadTicket& ticket, const std::optional<std::string>& itemJson) {',
      r'if (!itemJson) return std::nullopt;',
      r'Json::CharReaderBuilder builder;',
      r'builder["rejectDupKeys"] = true;',
      r'builder["failIfExtra"] = true;',
      r'builder["allowComments"] = false;',
      r'const std::unique_ptr<Json::CharReader> reader(builder.newCharReader());',
      r'Json::Value parsed;',
      r'std::string errors;',
      r'if (!reader->parse(itemJson->data(), itemJson->data() + itemJson->size(), &parsed, &errors) || !parsed.isObject() || !parsed["daemonId"].isString() || parsed["daemonId"].asString() != ticket.message_id) return std::nullopt;',
      r'auto item = WireValueFromJson(parsed);',
      r'if (!item) return std::nullopt;',
      r'return SearchMessageReply{ticket.account_id, ticket.peer_id, ticket.conversation_id, ticket.message_id, ticket.account_revision, ticket.epoch, std::move(*item)};',
      r'}',
    ],
    // Retirement advances the epoch only; a selected-result load keeps its
    // lease until the daemon answers it.
    'RetireSearchLocked': [
      r'void RetireSearchLocked() {',
      r'if (g_historySearchEpoch != std::numeric_limits<uint64_t>::max()) ++g_historySearchEpoch;',
      r'if (g_historySearch) g_historySearch->request->Retire();',
      r'}',
    ],
    'SearchMessageFacts': [
      r'sybl::history_search::MessageLoadFacts SearchMessageFacts(const sybl::history_search::MessageLoadTicket& ticket) {',
      r'sybl::history_search::MessageLoadFacts facts;',
      r'const auto routing = RoutingSnapshot();',
      r'facts.routing_owns = routing && routing->account_id == ticket.account_id && routing->Owns(ticket.peer_id, ticket.conversation_id);',
      r'std::lock_guard<std::mutex> lock(g_mutex);',
      r'if (g_running && g_daemonReady.load() && g_accountRevision != std::numeric_limits<uint64_t>::max()) {',
      r'facts.account_id = g_accountId;',
      r'facts.account_revision = g_accountRevision;',
      r'}',
      r'facts.epoch = g_historySearchEpoch;',
      r'facts.restore_pending = g_identityActivationPending || g_pendingRestoreBlocked;',
      r'return facts;',
      r'}',
    ],
    'WireValueFromJson': [
      r'std::optional<WireValue> WireValueFromJson(const Json::Value& value) {',
      r'WireValue wire;',
      r'if (value.isNull()) return wire;',
      r'if (value.isBool()) {',
      r'wire.kind = WireValue::Kind::kBool;',
      r'wire.boolean = value.asBool();',
      r'}',
      r'else if (value.isInt64()) {',
      r'wire.kind = WireValue::Kind::kInt;',
      r'wire.integer = value.asInt64();',
      r'}',
      r'else if (value.isString()) {',
      r'wire.kind = WireValue::Kind::kString;',
      r'wire.text = value.asString();',
      r'}',
      r'else if (value.isArray()) {',
      r'wire.kind = WireValue::Kind::kList;',
      r'for (const auto& entry : value) {',
      r'auto converted = WireValueFromJson(entry);',
      r'if (!converted) return std::nullopt;',
      r'wire.list.push_back(std::move(*converted));',
      r'}',
      r'}',
      r'else if (value.isObject()) {',
      r'wire.kind = WireValue::Kind::kMap;',
      r'for (const auto& key : value.getMemberNames()) {',
      r'auto converted = WireValueFromJson(value[key]);',
      r'if (!converted) return std::nullopt;',
      r'wire.keys.push_back(key);',
      r'wire.values.push_back(std::move(*converted));',
      r'}',
      r'}',
      r'else {',
      r'return std::nullopt;',
      r'}',
      r'return wire;',
      r'}',
    ],
  };
  const searchMessageSwarmLoaded = [
    r'pendingLoad = g_conversationLoads.Take(loadId);',
    r'if (pendingLoad && pendingLoad->kind == sybl::conversation::LoadKind::kSearchMessage) searchMessage = g_searchMessageLoads.Complete(loadId);',
    r'}',
    r'if (pendingLoad && pendingLoad->kind == sybl::conversation::LoadKind::kSearchMessage) {',
    r'if (searchMessage) CompleteSearchMessage(*searchMessage, accountId, conversationId, messages);',
    r'return;',
    r'}',
  ];
  const searchMessageToEncodable = [
    r'flutter::EncodableValue ToEncodableValue(const jami_bridge::WireValue& value) {',
    r'using Kind = jami_bridge::WireValue::Kind;',
    r'switch (value.kind) {',
    r'case Kind::kBool: return flutter::EncodableValue(value.boolean);',
    r'case Kind::kInt: return flutter::EncodableValue(value.integer);',
    r'case Kind::kString: return flutter::EncodableValue(value.text);',
    r'case Kind::kList: {',
    r'flutter::EncodableList list;',
    r'for (const auto& entry : value.list) list.push_back(ToEncodableValue(entry));',
    r'return flutter::EncodableValue(std::move(list));',
    r'}',
    r'case Kind::kMap: {',
    r'flutter::EncodableMap map;',
    r'for (std::size_t i = 0;',
    r'i < value.keys.size() && i < value.values.size();',
    r'++i) map[flutter::EncodableValue(value.keys[i])] = ToEncodableValue(value.values[i]);',
    r'return flutter::EncodableValue(std::move(map));',
    r'}',
    r'case Kind::kNull: default: return flutter::EncodableValue();',
    r'}',
    r'}',
  ];
  const searchMessageBranch = [
    r'} else if (method == "loadSearchMessage") {',
    r'std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> res(std::move(result));',
    r'jami_bridge::LoadSearchMessage( ArgString(call, "accountId", ""), ArgString(call, "peerJamiId", ""), ArgString(call, "conversationId", ""), ArgString(call, "messageId", ""), [this, res](std::optional<jami_bridge::SearchMessageReply> reply) {',
    r'PostToPlatform([res, reply = std::move(reply)] {',
    r'if (!reply || !jami_bridge::SearchMessageReplyCurrent(*reply)) {',
    r'res->Success();',
    r'return;',
    r'}',
    r'using V = flutter::EncodableValue;',
    r'res->Success(V(flutter::EncodableMap{',
    r'{V("accountId"), V(reply->accountId)}, {V("peerId"), V(reply->peerId)}, {V("conversationId"), V(reply->conversationId)}, {V("kind"), V(reply->peerId.rfind("group:", 0) == 0 ? "group" : "direct")}, {V("messageId"), V(reply->messageId)}, {V("items"), V(flutter::EncodableList{ToEncodableValue(reply->item)})}}));',
    r'});',
    r'});',
  ];

  // Every reason the Windows selected-result path differs from the reviewed
  // one. Empty means the contract holds.
  List<String> searchMessageProblems(
    String bridgeSource,
    String channelSource,
  ) {
    String flat(String source) => source.replaceAll(RegExp(r'\s+'), ' ').trim();
    final problems = <String>[];
    final bridge = stripCppComments(bridgeSource);
    final channel = stripCppComments(channelSource);

    const marker = '} else if (method == "loadSearchMessage") {';
    final at = channel.indexOf(marker);
    if (at < 0 || channel.indexOf(marker, at + 1) >= 0) {
      problems.add('channel: not exactly one loadSearchMessage branch');
    } else {
      final end = RegExp(
        r'\n\s*} else if \(method == "[^"]+"\)',
      ).firstMatch(channel.substring(at + marker.length));
      final branch = end == null
          ? channel.substring(at)
          : channel.substring(at, at + marker.length + end.start);
      if (flat(branch) != searchMessageBranch.join(' ')) {
        problems.add('channel: loadSearchMessage branch differs');
      }
    }
    final channelFunctions = cppFunctions(channel);
    final toEncodable = channelFunctions['ToEncodableValue'];
    if (toEncodable == null ||
        toEncodable.length != 1 ||
        flat(toEncodable.single) != searchMessageToEncodable.join(' ')) {
      problems.add('channel: ToEncodableValue differs');
    }

    final functions = cppFunctions(bridge);
    searchMessageFunctions.forEach((name, expected) {
      final bodies = functions[name];
      if (bodies == null || bodies.length != 1) {
        problems.add('$name: not exactly one definition');
      } else if (flat(bodies.single) != expected.join(' ')) {
        problems.add('$name differs');
      }
    });
    const hookStart = 'pendingLoad = g_conversationLoads.Take(loadId);';
    const hookEnd =
        'if (!pendingLoad || pendingLoad->conversation_id != conversationId ||';
    final hook = bridge.indexOf(hookStart);
    final hookStop = hook < 0 ? -1 : bridge.indexOf(hookEnd, hook);
    if (hook < 0 ||
        bridge.indexOf(hookStart, hook + 1) >= 0 ||
        hookStop < 0 ||
        flat(bridge.substring(hook, hookStop)) !=
            searchMessageSwarmLoaded.join(' ')) {
      problems.add('OnSwarmLoaded: selected-result dispatch differs');
    }
    final retire = functions['RetireSearchLocked'];
    if (retire != null &&
        retire.any(
          RegExp(
            r'g_searchMessageLoads|g_conversationLoads|\bdone\s*\(|AnswerRetiredSearchMessages|Cancel',
          ).hasMatch,
        )) {
      problems.add('RetireSearchLocked releases a selected-result load');
    }
    for (final entry in const {
      'WorkerLoop': 'if (searchMessagesDue) AnswerRetiredSearchMessages();',
      'Stop': 'pending = g_searchMessageLoads.TakeAll();',
    }.entries) {
      final bodies = functions[entry.key];
      if (bodies == null ||
          bodies.length != 1 ||
          !flat(bodies.single).contains(entry.value)) {
        problems.add('${entry.key}: selected-result answer path lost');
      }
    }

    // Nothing reachable in this file from the path may create read evidence,
    // echo a search snippet, or use the ordinary history load.
    final forbidden = {
      'setMessageDisplayed': RegExp(
        'setMessageDisplayed',
        caseSensitive: false,
      ),
      'snippet': RegExp('snippet', caseSensitive: false),
      'loadConversation': RegExp(r'\bloadConversation\b'),
    };
    final call = RegExp(r'(?<![\w.>:])([A-Za-z_]\w*)\s*\(');
    final reachable = <String>{};
    final pending = [
      'LoadSearchMessage',
      'CompleteSearchMessage',
      'SearchMessageReplyCurrent',
      'AnswerRetiredSearchMessages',
    ];
    while (pending.isNotEmpty) {
      final name = pending.removeLast();
      if (!functions.containsKey(name) || !reachable.add(name)) continue;
      for (final body in functions[name]!) {
        pending.addAll(call.allMatches(body).map((m) => m.group(1)!));
      }
    }
    for (final name in reachable) {
      for (final body in functions[name]!) {
        forbidden.forEach((label, pattern) {
          if (pattern.hasMatch(body)) problems.add('$name reaches $label');
        });
      }
    }
    return problems;
  }

  test('Windows selected search result loads one daemon-folded message', () {
    final bridge = windowsBridge.replaceAll('\r\n', '\n');
    final channel = windowsChannel.replaceAll('\r\n', '\n');
    expect(searchMessageProblems(bridge, channel), isEmpty);

    List<String> rejected(
      String name,
      String bridgeMutant,
      String channelMutant,
    ) {
      expect(
        bridgeMutant != bridge || channelMutant != channel,
        isTrue,
        reason: '$name: mutation did not apply',
      );
      final problems = searchMessageProblems(bridgeMutant, channelMutant);
      expect(problems, isNotEmpty, reason: '$name: accepted a wrong edit');
      return problems;
    }

    // A read receipt reached through a helper, directly and two calls deep
    // inside the unpinned timeline projection.
    const receiptHelper =
        'void MarkSearchMessageRead(const std::string& account, '
        'const std::string& conversation, const std::string& message) {\n'
        '  libjami::setMessageDisplayed(account, "swarm:" + conversation, message, 3);\n'
        '}\n\n';
    const answer =
        '  try { if (request.done) request.done(std::move(reply)); } catch (...) {}';
    expect(
      rejected(
        'helper read receipt',
        bridge
            .replaceFirst(
              'void CompleteSearchMessage(',
              '${receiptHelper}void CompleteSearchMessage(',
            )
            .replaceFirst(
              answer,
              '  MarkSearchMessageRead(accountId, conversationId, request.ticket.message_id);\n$answer',
            ),
        channel,
      ),
      containsAll([
        'CompleteSearchMessage differs',
        'MarkSearchMessageRead reaches setMessageDisplayed',
      ]),
    );
    const version =
        '  const std::string versionId = msg.latestEditionId.empty() ? msg.id : msg.latestEditionId;';
    expect(
      rejected(
        'projection read receipt',
        bridge
            .replaceFirst(
              'void CompleteSearchMessage(',
              '${receiptHelper}void CompleteSearchMessage(',
            )
            .replaceFirst(
              version,
              '  MarkSearchMessageRead(accountId, conversationId, msg.id);\n$version',
            ),
        channel,
      ),
      ['MarkSearchMessageRead reaches setMessageDisplayed'],
    );
    // A dead-code loadSybLMessage beside a live ordinary history load.
    expect(
      rejected(
        'dead loadSybLMessage',
        bridge.replaceFirst(
          'const auto loadId = libjami::loadSybLMessage(ticket.account_id, ticket.conversation_id, ticket.message_id);',
          'if (false) libjami::loadSybLMessage(ticket.account_id, ticket.conversation_id, ticket.message_id);\n'
              '          const auto loadId = libjami::loadConversation(ticket.account_id, ticket.conversation_id, "", 1);',
        ),
        channel,
      ),
      containsAll([
        'LoadSearchMessage differs',
        'LoadSearchMessage reaches loadConversation',
      ]),
    );
    // The project handler, or the reply it builds, always answering unavailable.
    expect(
      rejected(
        'project answers null',
        bridge.replaceFirst(
          '{.project = [&](std::size_t index) {',
          '{.project = [&](std::size_t index) { reply.reset(); return;',
        ),
        channel,
      ),
      ['CompleteSearchMessage differs'],
    );
    expect(
      rejected(
        'reply always null',
        bridge.replaceFirst(
          '  if (!itemJson) return std::nullopt;\n',
          '  return std::nullopt;\n',
        ),
        channel,
      ),
      ['SearchMessageReplyFor differs'],
    );
    // A forged returned-message list instead of the daemon's answer.
    expect(
      rejected(
        'forged returned ids',
        bridge
            .replaceFirst(
              '  std::optional<SearchMessageReply> reply;\n',
              '  std::optional<SearchMessageReply> reply;\n'
                  '  std::vector<libjami::SwarmMessage> forged(1);\n'
                  '  forged[0].id = request.ticket.message_id;\n',
            )
            .replaceFirst(
              'SearchMessageFacts(request.ticket), messages)',
              'SearchMessageFacts(request.ticket), forged)',
            ),
        channel,
      ),
      ['CompleteSearchMessage differs'],
    );
    // Retirement must not release a selected-result lease: the pre-change
    // body, which cancelled every held load, and any other release are
    // rejected; a release named only in a comment is not a call.
    const retireStart = 'void RetireSearchLocked() {';
    final retireAt = bridge.indexOf(retireStart);
    final retireEnd = bridge.indexOf('\n}\n', retireAt) + 3;
    expect(retireAt >= 0 && retireEnd > retireAt, isTrue);
    String withRetire(String body) =>
        bridge.replaceRange(retireAt, retireEnd, body);
    const preChangeRetire =
        'void RetireSearchLocked() {\n'
        '  if (g_historySearchEpoch != std::numeric_limits<uint64_t>::max()) ++g_historySearchEpoch;\n'
        '  if (g_historySearch) g_historySearch->request->Retire();\n'
        '  // Selected-result loads end too; the worker answers them unavailable outside g_mutex.\n'
        '  g_searchMessageLoads.CancelAll(g_conversationLoads, sybl::conversation::LoadRegistry::Clock::now());\n'
        '  g_cv.notify_one();\n'
        '}\n';
    expect(
      rejected('pre-change retirement', withRetire(preChangeRetire), channel),
      containsAll([
        'RetireSearchLocked differs',
        'RetireSearchLocked releases a selected-result load',
      ]),
    );
    for (final release in const [
      '  g_conversationLoads.ClearActive();\n',
      '  for (auto& r : g_searchMessageLoads.TakeAll()) r.done(std::nullopt);\n',
    ]) {
      expect(
        rejected(
          'retirement release',
          withRetire(
            preChangeRetire.replaceFirst(
              RegExp(r'  // Selected[^\n]*\n  g_search[^\n]*\n  g_cv[^\n]*\n'),
              release,
            ),
          ),
          channel,
        ),
        containsAll([
          'RetireSearchLocked differs',
          'RetireSearchLocked releases a selected-result load',
        ]),
      );
    }
    expect(
      searchMessageProblems(
        withRetire(
          bridge
              .substring(retireAt, retireEnd)
              .replaceFirst(
                '\n}\n',
                '\n  // g_searchMessageLoads.CancelAll(g_conversationLoads, now);\n}\n',
              ),
        ),
        channel,
      ),
      isEmpty,
    );

    // The channel: the branch missing (as before this change), hidden in a
    // comment, or passing a wrong argument key.
    final branchStart = channel.indexOf(
      '  } else if (method == "loadSearchMessage") {',
    );
    final branchEnd = channel.indexOf(
      '  } else if (method == "loadChat") {',
      branchStart,
    );
    final branch = channel.substring(branchStart, branchEnd);
    expect(
      rejected('no channel branch', bridge, channel.replaceFirst(branch, '')),
      ['channel: not exactly one loadSearchMessage branch'],
    );
    expect(
      rejected(
        'commented channel branch',
        bridge,
        channel.replaceFirst(branch, '/*\n$branch*/\n'),
      ),
      ['channel: not exactly one loadSearchMessage branch'],
    );
    expect(
      rejected(
        'wrong argument key',
        bridge,
        channel.replaceFirst(
          branch,
          branch.replaceFirst('"peerJamiId"', '"peerId"'),
        ),
      ),
      ['channel: loadSearchMessage branch differs'],
    );
  });

  test('Windows CURRENT winner rolls a cancelled source back before owning it', () {
    const start = '} else if (!staleCurrent) {';
    const end = 'g_localVideoSource.call_id = callId;';
    const winnerCancel =
        '} else if (!staleCurrent) { '
        'if (g_sourceTransition && '
        'g_sourceTransition->source.requested.call_id != callId) { '
        'RollBackCancelledTransitionLocked(*g_sourceTransition); '
        'cancelledSourceDone = std::move(g_sourceTransition->done); '
        'g_sourceTransition.reset(); '
        '} '
        'g_callPeers[callId] = from; '
        'g_currentWinnerCallId = callId;';
    List<String> problems(String bridgeSource) {
      final bridge = normalize(stripComments(bridgeSource));
      final found = <String>[];
      if (start.allMatches(bridge).length != 1) {
        return ['not exactly one CURRENT winner branch'];
      }
      final from = bridge.indexOf(start);
      final to = bridge.indexOf(end, from);
      if (to < 0) return ['winner branch lost the call-id handoff'];
      final branch = bridge.substring(from, to);
      if (!branch.startsWith(winnerCancel)) {
        found.add('winner cancel block differs');
      }
      final rollback = branch.indexOf('RollBackCancelledTransitionLocked(');
      if (rollback < 0 ||
          rollback > branch.indexOf('g_activeCallId = callId;')) {
        found.add('rollback does not precede the ownership handoff');
      }
      if (!bridge.contains(
        'void RollBackCancelledTransitionLocked(const PendingSourceTransition& pending) { '
        'const auto cancelled = screen_source::CancelTransition( '
        'g_localVideoSource, g_cameraIndex, pending.source, pending.previous_camera_index); '
        'g_localVideoSource = cancelled.source; '
        'g_cameraIndex = cancelled.camera_index; }',
      )) {
        found.add('rollback helper differs');
      }
      return found;
    }

    expect(problems(windowsBridge), isEmpty);

    // The pre-change block cancelled without rolling back, so the unconfirmed
    // requested source became the winner's reported truth.
    final current = RegExp(
      r'\r?\n[ \t]*RollBackCancelledTransitionLocked\(\*g_sourceTransition\);'
      r'(\r?\n[ \t]*cancelledSourceDone = std::move\(g_sourceTransition->done\);'
      r'\r?\n[ \t]*g_sourceTransition\.reset\(\);'
      r'\r?\n[ \t]*\}'
      r'\r?\n[ \t]*g_callPeers\[callId\] = from;)',
    );
    expect(current.allMatches(windowsBridge).length, 1);
    final preChange = windowsBridge.replaceFirstMapped(
      current,
      (m) => m.group(1)!,
    );
    expect(
      problems(preChange),
      containsAll([
        'winner cancel block differs',
        'rollback does not precede the ownership handoff',
      ]),
    );
    // Commenting the rollback out does not satisfy the contract.
    final commented = windowsBridge.replaceFirstMapped(
      current,
      (m) =>
          '\n// RollBackCancelledTransitionLocked(*g_sourceTransition);'
          '${m.group(1)}',
    );
    expect(problems(commented), contains('winner cancel block differs'));
    final blockCommented = windowsBridge.replaceFirstMapped(
      current,
      (m) =>
          '\n/* RollBackCancelledTransitionLocked(*g_sourceTransition); */'
          '${m.group(1)}',
    );
    expect(problems(blockCommented), contains('winner cancel block differs'));
    // Rolling back after the handoff is also rejected.
    final afterHandoff = preChange.replaceFirst(
      'g_localVideoSource.call_id = callId;',
      'g_localVideoSource.call_id = callId; '
          'RollBackCancelledTransitionLocked(*g_sourceTransition);',
    );
    expect(
      problems(afterHandoff),
      containsAll([
        'winner cancel block differs',
        'rollback does not precede the ownership handoff',
      ]),
    );

    // The other three cancel sites also roll back before the slot is reset.
    const call = 'RollBackCancelledTransitionLocked(*g_sourceTransition);';
    const reset = 'g_sourceTransition.reset();';
    String site(String owner, String doneTarget) =>
        'if (g_sourceTransition && '
        'g_sourceTransition->source.requested.call_id == $owner) { '
        '$call $doneTarget = std::move(g_sourceTransition->done); $reset';
    final sites = <String, String>{
      'negotiation status': site('ownerCallId', 'done'),
      'group call clear': site('conferenceId', 'cancelledVideo'),
      'terminal call state': site('callId', 'cancelledSourceDone'),
    };
    List<String> cancelSiteProblems(String bridgeSource) {
      final bridge = normalize(stripComments(bridgeSource));
      final found = <String>[];
      if (call.allMatches(bridge).length != 4) {
        found.add('rollback call count is not four');
      }
      sites.forEach((name, block) {
        if (block.allMatches(bridge).length != 1) {
          found.add('$name cancel block differs');
        }
      });
      return found;
    }

    expect(cancelSiteProblems(windowsBridge), isEmpty);
    final callAt = <int>[];
    for (
      var i = windowsBridge.indexOf(call);
      i >= 0;
      i = windowsBridge.indexOf(call, i + 1)
    ) {
      callAt.add(i);
    }
    expect(callAt.length, 4);
    // Occurrences in file order: negotiation status, group call clear,
    // terminal call state, CURRENT winner (pinned above).
    final names = sites.keys.toList();
    for (var n = 0; n < names.length; n++) {
      final at = callAt[n];
      final tail = at + call.length;
      final resetAt = windowsBridge.indexOf(reset, tail);
      final variants = <String, String>{
        'removed':
            windowsBridge.substring(0, at) + windowsBridge.substring(tail),
        'commented':
            '${windowsBridge.substring(0, at)}// $call${windowsBridge.substring(tail)}',
        'moved after reset':
            '${windowsBridge.substring(0, at)}'
            '${windowsBridge.substring(tail, resetAt + reset.length)}'
            ' $call${windowsBridge.substring(resetAt + reset.length)}',
      };
      variants.forEach((label, variant) {
        expect(variant, isNot(windowsBridge), reason: '${names[n]} $label');
        expect(
          cancelSiteProblems(variant),
          contains('${names[n]} cancel block differs'),
          reason: '${names[n]} $label',
        );
      });
    }
  });
}
