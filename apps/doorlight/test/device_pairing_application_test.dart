import 'package:sybl/ui/notice.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:ui' show ViewFocusDirection, ViewFocusEvent, ViewFocusState;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/screens/onboarding.dart';
import 'package:sybl/state/app_settings.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/device_pairing_dialog.dart';
import 'app_state_test.dart' show FakeJami;

const _codec = AppSettingsCodec();
final _peer = 'e' * 40;
final _offer = 'jami-auth://${'b' * 64}/123456/doorlight-v1';

class _NativeLink extends FakeJami {
  final commands = <Map<String, Object?>>[];
  String token = 'a' * 64, owner = '', phase = 'waiting', document = '';
  final target = 'reserved-linked-account';
  bool destination = true, rejectPrepare = false, failFinalize = false;
  bool nativeStore = false, rejectSettings = false, retired = false;
  Completer<void>? settingsGate;
  @override
  bool get usesNativeAppSettingsStore => nativeStore;
  @override
  Future<void> saveAppSettingsDocument(String document) async {
    if (rejectSettings) throw StateError('synthetic durable settings refusal');
    await settingsGate?.future;
    await (await SharedPreferences.getInstance()).setString(
      'appSettings',
      document,
    );
  }

  bool rejectDiscard = false;
  Completer<void>? activationGate;
  void Function(String)? policyAtPrepare, policyAtActivation;
  Map<String, dynamic> prepared() => {
    'status': 'prepared',
    'restoreToken': token,
    'accountId': target,
    'jamiId': _peer,
    'enabled': false,
    'announced': false,
    'registration': 'UNREGISTERED',
    'settingsAlreadyNormalized': true,
    'devicePairing': true,
    'settingsDocument': document,
    'displayName': 'Disposable linked identity',
    'avatarBase64': '',
  };
  Map<String, dynamic> projection({bool recovery = false}) => {
    'flowToken': token,
    'accountId': destination ? target : owner,
    'ownerAccountId': owner,
    'role': destination ? 'destination' : 'source',
    'operation': 123456,
    'status': recovery ? 'unconfirmed' : phase,
    'terminal': !recovery && {'ready', 'complete', 'ended'}.contains(phase),
    'recovery': recovery,
    'uri': !recovery && phase == 'waiting' ? _offer : '',
    'code': !recovery && phase == 'codeIssued' ? '12345678' : '',
    'peerId': recovery ? '' : _peer,
    'peerDeviceId': recovery ? '' : 'c' * 64,
    'deviceId': recovery ? '' : 'd' * 64,
    'error': '',
    'invalidCode': false,
    if (!recovery && phase == 'ready') 'preparedIdentity': prepared(),
  };
  Map<String, dynamic> journal({required bool acknowledged}) => {
    if (acknowledged) ...prepared() else 'status': 'pairing',
    'pairing': projection(recovery: true),
  };
  @override
  Future<Map<String, dynamic>> devicePairing({
    required String action,
    required String flowToken,
    String accountId = '',
    String expectedAccountId = '',
    String uri = '',
    String code = '',
    String settingsDocument = '',
    Map<String, String> network = const {},
    bool appearOffline = false,
  }) async {
    commands.add({
      'action': action,
      'accountId': accountId,
      'flowToken': flowToken,
      'owner': expectedAccountId,
      'network': network,
      'offline': appearOffline,
    });
    if (action == 'begin' || action == 'connect') {
      token = flowToken;
      owner = expectedAccountId;
      destination = action == 'begin';
      phase = destination ? 'waiting' : 'consent';
    }
    if (action == 'retire') retired = true;
    if (action == 'approve') phase = 'codeIssued';
    if (action == 'code') {
      expect(code, '12345678');
      phase = 'prepared';
    }
    if (action == 'prepare') {
      policyAtPrepare?.call(settingsDocument);
      if (rejectPrepare) throw StateError('synthetic preparation refusal');
      document = settingsDocument;
      phase = 'ready';
      pendingIdentityRestore = journal(acknowledged: true);
    }
    if (action == 'discard') {
      if (rejectDiscard) throw StateError('synthetic cleanup refusal');
      expect(accountId, target);
      expect(flowToken, token);
      pendingIdentityRestore = null;
      return {'status': 'discarded', 'flowToken': token, 'accountId': target};
    }
    return projection();
  }

  @override
  Future<Map<String, dynamic>> finalizeIdentityRestore({
    required String accountId,
    required String restoreToken,
    required String settingsDocument,
  }) async {
    restoreFinalizations++;
    policyAtActivation?.call(settingsDocument);
    await activationGate?.future;
    if (failFinalize || retired) return {'status': 'error'};
    expect(accountId, target);
    expect(restoreToken, token);
    expect(settingsDocument, document);
    accountExists = true;
    this.accountId = target;
    accountJamiId = _peer;
    pendingIdentityRestore = null;
    return {...prepared(), 'status': 'ok', 'enabled': true};
  }
}

Future<AppState> _boot(
  _NativeLink native, {
  AppSettings? settings,
  Map<String, Object> extra = const {},
}) async {
  SharedPreferences.setMockInitialValues({
    'appSettings': jsonEncode(_codec.encode(settings ?? AppSettings())),
    ...extra,
  });
  final state = AppState(native, await SharedPreferences.getInstance());
  addTearDown(state.dispose);
  await state.init();
  state.didChangeAppLifecycleState(AppLifecycleState.resumed);
  return state;
}

Future<void> _ready(AppState state, _NativeLink native) async {
  expect(await state.beginDevicePairing(destination: true), isTrue);
  native.phase = 'code';
  await state.devicePairing.refresh();
  await state.devicePairing.submitCode('12345678');
  expect(state.devicePairing.canActivate, isTrue);
  expect(state.accountId, isNull);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'leaving the link page during preflight cannot begin a native visit',
    () async {
      final native = _NativeLink()
        ..accountExists = false
        ..nativeStore = true;
      final state = await _boot(native);
      native.settingsGate = Completer<void>();
      var current = true;
      final pending = state.beginDevicePairing(
        destination: true,
        stillCurrent: () => current,
      );
      await pumpEventQueue();
      expect(native.commands, isEmpty);
      current = false;
      native.settingsGate!.complete();
      expect(await pending, isFalse);
      expect(native.commands, isEmpty);
      expect(state.devicePairingPending, isFalse);
    },
  );

  for (final acknowledged in [false, true]) {
    testWidgets(
      'unfinished linking uses the normal link choice ($acknowledged)',
      (tester) async {
        final native = _NativeLink()..accountExists = false;
        native.document = jsonEncode(_codec.encode(AppSettings()));
        native.pendingIdentityRestore = native.journal(
          acknowledged: acknowledged,
        );
        late AppState state;
        await tester.runAsync(() async {
          state = await _boot(native);
        });
        await tester.pumpWidget(
          MaterialApp(
            theme: Warm.theme(),
            builder: (context, child) => withNoticeHost(child!, state),
            home: OnboardingScreen(state: state),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('onboarding-create-choice')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('onboarding-existing-choice')),
          findsOneWidget,
        );
        expect(find.text('Continue linking'), findsNothing);
        expect(native.commands, isEmpty);
        await tester.tap(
          find.byKey(const ValueKey('onboarding-existing-choice')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('onboarding-pairing-recovery')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('onboarding-link-choice')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('onboarding-restore-choice')),
          findsNothing,
        );
        expect(native.pendingIdentityRestore, isNotNull);
        expect(native.commands, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final rejectDiscard in [false, true]) {
    testWidgets(
      'a fresh link requires confirmed cancellation ($rejectDiscard)',
      (tester) async {
        final native = _NativeLink()
          ..accountExists = false
          ..rejectDiscard = rejectDiscard;
        native.pendingIdentityRestore = native.journal(acknowledged: false);
        late AppState state;
        await tester.runAsync(() async {
          state = await _boot(native);
        });
        await tester.pumpWidget(
          MaterialApp(
            theme: Warm.theme(),
            builder: (context, child) => withNoticeHost(child!, state),
            home: OnboardingScreen(state: state),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('onboarding-existing-choice')),
        );
        await tester.pumpAndSettle();
        expect(find.text('Continue linking'), findsNothing);
        expect(find.text('Start a new link'), findsNothing);
        expect(native.commands, isEmpty);
        await tester.runAsync(() async {
          await tester.tap(
            find.byKey(const ValueKey('onboarding-link-choice')),
          );
          await pumpEventQueue();
        });
        await tester.pump();
        await tester.runAsync(() async {
          await pumpEventQueue();
        });
        await tester.pumpAndSettle();
        if (!rejectDiscard) {
          expect(
            native.commands.map((c) => c['action']),
            isNot(contains('begin')),
          );
          await tester.runAsync(() async {
            await tester.tap(
              find.byKey(const ValueKey('pairing-show-link-code')),
            );
            await pumpEventQueue();
          });
          await tester.pumpAndSettle();
        }
        final actions = native.commands.map((c) => c['action']).toList();
        expect(actions.where((a) => a == 'discard'), hasLength(1));
        if (rejectDiscard) {
          expect(actions, isNot(contains('begin')));
          expect(native.pendingIdentityRestore, isNotNull);
          expect(
            find.text(
              "Couldn't cancel the previous linking attempt. Try again.",
            ),
            findsOneWidget,
          );
        } else {
          expect(actions, contains('begin'));
          expect(
            actions.indexOf('discard'),
            lessThan(actions.indexOf('begin')),
          );
          expect(native.pendingIdentityRestore, isNull);
          expect(state.devicePairing.needsRecovery, isFalse);
        }
        expect(state.accountId, isNull);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
    testWidgets(
      'new profile requires confirmed pending-link removal ($rejectDiscard)',
      (tester) async {
        final native = _NativeLink()
          ..accountExists = false
          ..rejectDiscard = rejectDiscard;
        native.pendingIdentityRestore = native.journal(acknowledged: false);
        late AppState state;
        await tester.runAsync(() async {
          state = await _boot(native);
        });
        await tester.pumpWidget(
          MaterialApp(
            theme: Warm.theme(),
            builder: (context, child) => withNoticeHost(child!, state),
            home: OnboardingScreen(state: state),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('onboarding-create-choice')),
        );
        await tester.pumpAndSettle();
        expect(native.commands, isEmpty);
        expect(
          find.text(
            'Start fresh with a separate profile. The pending link on this device will be cancelled.',
          ),
          findsNothing,
        );
        await tester.enterText(
          find.byKey(const ValueKey('onboarding-name-field')),
          'New profile',
        );
        await tester.runAsync(() async {
          await tester.tap(
            find.byKey(const ValueKey('onboarding-create-submit')),
          );
          await pumpEventQueue();
        });
        await tester.pump();
        expect(
          native.commands.where((c) => c['action'] == 'discard'),
          hasLength(1),
        );
        if (rejectDiscard) {
          expect(native.pendingIdentityRestore, isNotNull);
          expect(state.accountId, isNull);
          expect(native.lastEnsureCreateIfMissing, isNull);
          expect(
            find.text(
              "Couldn't cancel the previous linking attempt. Try again.",
            ),
            findsOneWidget,
          );
        } else {
          expect(native.pendingIdentityRestore, isNull);
          expect(state.devicePairingPending, isFalse);
          expect(native.lastEnsureCreateIfMissing, isTrue);
          expect(state.screen, Screen.home);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
  test(
    'visible desktop keeps the QR offer while unfocused, but grants no authority',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final native = _NativeLink()..accountExists = false;
      final state = await _boot(native);
      expect(await state.beginDevicePairing(destination: true), isTrue);
      var focusNotifications = 0;
      state.addListener(() => focusNotifications++);
      expect(state.canUseDeviceLinkRendezvous, isTrue);
      state.didChangeViewFocus(
        const ViewFocusEvent(
          viewId: 0,
          state: ViewFocusState.unfocused,
          direction: ViewFocusDirection.undefined,
        ),
      );
      expect(focusNotifications, greaterThan(0));
      expect(state.canUseDeviceLinkRendezvous, isFalse);
      state.didChangeAppLifecycleState(AppLifecycleState.inactive);
      await state.devicePairing.refresh();
      expect(state.devicePairing.snapshot?.uri, _offer);
      expect(state.devicePairing.needsRecovery, isFalse);
      native.phase = 'code';
      await state.devicePairing.refresh();
      await state.devicePairing.submitCode('12345678');
      expect(native.commands.where((c) => c['action'] == 'code'), isEmpty);
      native.phase = 'prepared';
      await state.devicePairing.refresh();
      expect(native.commands.where((c) => c['action'] == 'prepare'), isEmpty);
      expect(await state.devicePairing.activate(), isFalse);
      expect(native.restoreFinalizations, 0);
      expect(native.commands.where((c) => c['action'] == 'retire'), isEmpty);
      state.didChangeAppLifecycleState(AppLifecycleState.hidden);
      expect(state.devicePairing.needsRecovery, isTrue);
      expect(state.devicePairing.snapshot?.uri, isEmpty);
      expect(
        native.commands.where((c) => c['action'] == 'retire'),
        hasLength(1),
      );
    },
  );
  test('mobile inactivity still retires the link offer', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final native = _NativeLink()..accountExists = false;
    final state = await _boot(native);
    expect(await state.beginDevicePairing(destination: true), isTrue);
    state.didChangeAppLifecycleState(AppLifecycleState.inactive);
    expect(state.devicePairing.needsRecovery, isTrue);
    expect(state.devicePairing.snapshot?.uri, isEmpty);
  });
  test(
    'confirmed native absence clears stale identity selection and permits linking',
    () async {
      final native = _NativeLink()..accountExists = false;
      final state = await _boot(
        native,
        extra: {
          'accountId': 'deleted-account',
          'peerId': _peer,
          'displayName': 'Old name',
        },
      );
      expect(state.screen, Screen.onboarding);
      expect(state.accountId, isNull);
      expect(state.prefs.containsKey('accountId'), isFalse);
      expect(state.prefs.containsKey('peerId'), isFalse);
      expect(await state.beginDevicePairing(destination: true), isTrue);
      expect(await state.devicePairing.cancel(), isTrue);
    },
  );
  setUpAll(() async {
    // Geometry must use the same bundled faces as the real application.
    // The default widget-test Ahem font has unrelated glyph metrics.
    for (final entry in {
      'HankenGrotesk': 'assets/fonts/HankenGrotesk-Variable.ttf',
      'Fraunces': 'assets/fonts/Fraunces-Variable.ttf',
      'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
    }.entries) {
      await (FontLoader(
        entry.key,
      )..addFont(rootBundle.load(entry.value))).load();
    }
  });
  testWidgets('desktop minimum shows both setup choices without scrolling', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(700, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final native = _NativeLink()..accountExists = false;
    late AppState state;
    await tester.runAsync(() async {
      state = await _boot(native);
    });
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme().copyWith(platform: TargetPlatform.windows),
        home: OnboardingScreen(state: state),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('onboarding-door-mark')));
    await tester.pumpAndSettle();
    for (final key in [
      'onboarding-create-choice',
      'onboarding-existing-choice',
    ]) {
      final choice = find.byKey(ValueKey(key));
      expect(choice.hitTestable(), findsOneWidget);
      final bounds = tester.getRect(choice);
      expect(bounds.top, greaterThanOrEqualTo(0));
      expect(bounds.bottom, lessThanOrEqualTo(500));
    }
    expect(tester.takeException(), isNull);
  });

  for (final nativeStore in [false, true]) {
    test(
      'local policy is durable before preparation and activation: native=$nativeStore',
      () async {
        final native = _NativeLink()
          ..accountExists = false
          ..nativeStore = nativeStore;
        final state = await _boot(
          native,
          settings: AppSettings(
            globalMicrophoneMode: MicrophoneMode.pushToTalk,
            showMessageInNotification: false,
            shareActivityPresence: false,
          ),
          extra: {
            'connectionProfile': 'strict',
            'strictBootstrap': '127.0.0.1:4222',
          },
        );
        void expectPolicy(String document) {
          expect(state.prefs.getString('appSettings'), document);
          final settings = _codec
              .decode(Map<String, Object?>.from(jsonDecode(document) as Map))
              .settings;
          expect(settings.globalMicrophoneMode, MicrophoneMode.pushToTalk);
          expect(settings.showMessageInNotification, isFalse);
          expect(settings.shareActivityPresence, isFalse);
          expect(state.accountId, isNull);
        }

        native.policyAtPrepare = expectPolicy;
        native.policyAtActivation = expectPolicy;
        await _ready(state, native);
        final admission = native.commands.first;
        expect((admission['network'] as Map)['connectionProfile'], 'strict');
        expect((admission['network'] as Map)['dhtBootstrap'], '127.0.0.1:4222');
        expect(native.restoreFinalizations, 0);
        expect(state.screen, Screen.onboarding);
        expect(await state.devicePairing.activate(), isTrue);
        expect(state.accountId, native.target);
        expect(state.jamiId, _peer);
        expect(state.screen, Screen.home);
        expect(state.prefs.getString('accountId'), native.target);
        expect(native.restoreFinalizations, 1);
        expect(state.devicePairingPending, isFalse);
      },
    );
  }
  test(
    'failed durable policy persistence cannot acknowledge or activate a link',
    () async {
      final native = _NativeLink()
        ..accountExists = false
        ..nativeStore = true;
      final state = await _boot(native);
      expect(await state.beginDevicePairing(destination: true), isTrue);
      native.rejectSettings = true;
      native.phase = 'prepared';
      await state.devicePairing.refresh();
      expect(native.commands.where((c) => c['action'] == 'prepare'), isEmpty);
      expect(
        native.commands.where((c) => c['action'] == 'retire'),
        hasLength(1),
      );
      expect(native.restoreFinalizations, 0);
      expect(state.devicePairing.needsRecovery, isTrue);
      expect(state.accountId, isNull);
      expect(await state.devicePairing.cancel(), isTrue);
      expect(native.commands.last['accountId'], native.target);
      expect(state.devicePairingPending, isFalse);
    },
  );
  test(
    'native preparation refusal never becomes success or account adoption',
    () async {
      final native = _NativeLink()
        ..accountExists = false
        ..rejectPrepare = true;
      final state = await _boot(native);
      expect(await state.beginDevicePairing(destination: true), isTrue);
      native.phase = 'prepared';
      await state.devicePairing.refresh();
      expect(state.devicePairing.needsRecovery, isTrue);
      expect(await state.devicePairing.activate(), isFalse);
      expect(native.restoreFinalizations, 0);
      expect(state.accountId, isNull);
      expect(await state.devicePairing.cancel(), isTrue);
    },
  );
  for (final acknowledged in [false, true]) {
    test(
      'restart keeps exact journal owner and requires explicit activation: acknowledged=$acknowledged',
      () async {
        final native = _NativeLink()..accountExists = false;
        final settings = AppSettings(
          globalMicrophoneMode: MicrophoneMode.pushToTalk,
        );
        native.document = jsonEncode(_codec.encode(settings));
        native.pendingIdentityRestore = native.journal(
          acknowledged: acknowledged,
        );
        final state = await _boot(native, settings: settings);
        expect(state.screen, Screen.onboarding);
        expect(state.accountId, isNull);
        expect(native.restoreFinalizations, 0);
        expect(state.devicePairing.snapshot?.accountId, native.target);
        expect(state.devicePairing.canActivate, acknowledged);
        expect(await state.beginDevicePairing(destination: true), isFalse);
        if (acknowledged) {
          expect(await state.devicePairing.activate(), isTrue);
          expect(state.accountId, native.target);
          expect(native.restoreFinalizations, 1);
        } else {
          expect(await state.devicePairing.activate(), isFalse);
          expect(await state.devicePairing.cancel(), isTrue);
          expect(native.restoreFinalizations, 0);
          expect(native.commands.last['accountId'], native.target);
        }
      },
    );
  }
  test(
    'a changed local policy cannot activate a stale acknowledged journal',
    () async {
      final native = _NativeLink()..accountExists = false;
      native.document = jsonEncode(_codec.encode(AppSettings()));
      native.pendingIdentityRestore = native.journal(acknowledged: true);
      final state = await _boot(
        native,
        settings: AppSettings(showMessageInNotification: false),
      );
      expect(await state.devicePairing.activate(), isFalse);
      expect(native.restoreFinalizations, 0);
      expect(state.accountId, isNull);
      expect(state.devicePairing.needsRecovery, isTrue);
    },
  );
  test(
    'native activation refusal preserves recovery instead of entering Home',
    () async {
      final native = _NativeLink()
        ..accountExists = false
        ..failFinalize = true;
      final state = await _boot(native);
      await _ready(state, native);
      expect(await state.devicePairing.activate(), isFalse);
      expect(state.accountId, isNull);
      expect(state.screen, Screen.onboarding);
      expect(state.devicePairing.needsRecovery, isTrue);
      expect(native.pendingIdentityRestore, isNotNull);
    },
  );
  test(
    'locking during finalization retires the exact native activation lease',
    () async {
      final native = _NativeLink()..accountExists = false;
      final state = await _boot(native);
      await _ready(state, native);
      native.activationGate = Completer<void>();
      final activation = state.devicePairing.activate();
      await pumpEventQueue();
      state.setProtectedSurfaceLocked(true);
      await pumpEventQueue();
      expect(native.retired, isTrue);
      native.activationGate!.complete();
      expect(await activation, isFalse);
      expect(native.accountExists, isFalse);
      expect(state.accountId, isNull);
      expect(state.devicePairing.needsRecovery, isTrue);
    },
  );
  test(
    'a selected independent identity is never admitted as a destination',
    () async {
      final native = _NativeLink();
      final state = await _boot(
        native,
        extra: {'accountId': 'acc1', 'displayName': 'Independent'},
      );
      expect(await state.beginDevicePairing(destination: true), isFalse);
      expect(native.commands, isEmpty);
      expect(state.accountId, 'acc1');
    },
  );
  testWidgets('onboarding exposes live linking separately from backup recovery', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final native = _NativeLink()..accountExists = false;
    late AppState state;
    await tester.runAsync(() async {
      state = await _boot(native);
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme(),
        home: OnboardingScreen(state: state),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('onboarding-existing-choice')));
    await tester.pumpAndSettle();
    // Linking opens with scan/discovery choices before preparing a fallback QR.
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('onboarding-link-choice')));
      await tester.pump();
      await tester.pump();
      await pumpEventQueue();
    });
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(); // Native confirms the sensitive surface.
    expect(find.text('Link this device'), findsWidgets);
    expect(find.byKey(const ValueKey('pairing-page')), findsOneWidget);
    expect(find.byKey(const ValueKey('pairing-offer')), findsNothing);
    expect(find.byKey(const ValueKey('pairing-scan-source')), findsOneWidget);
    expect(find.byKey(const ValueKey('pairing-offer-qr')), findsNothing);
    expect(native.commands, isEmpty);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('pairing-show-link-code')));
      await pumpEventQueue();
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('pairing-offer-qr')), findsOneWidget);
    await tester.ensureVisible(
      find.byKey(const ValueKey('pairing-show-link-code')),
    );
    await tester.tap(find.byKey(const ValueKey('pairing-show-link-code')));
    await tester.pump();
    expect(find.byKey(const ValueKey('pairing-offer')), findsOneWidget);
    expect(find.text(_offer), findsOneWidget);
    expect(native.pickFileCalls, 0);
    expect(native.restoreFinalizations, 0);
    await tester.ensureVisible(find.byKey(const ValueKey('pairing-close')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('pairing-close')));
      await pumpEventQueue();
    });
    await tester.pump(const Duration(milliseconds: 300));
    // The last link view persists through the reverse fade, without a preparing flash.
    expect(find.byKey(const ValueKey('pairing-offer')), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('pairing-offer')), findsNothing);
    expect(state.devicePairingPending, isFalse);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'source authorization displays native code but never a destination activation button',
    (tester) async {
      final native = _NativeLink();
      late AppState state;
      await tester.runAsync(() async {
        state = await _boot(
          native,
          extra: {'accountId': 'acc1', 'displayName': 'Independent'},
        );
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: Warm.theme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showDevicePairingDialog(
                  context,
                  state: state,
                  destination: false,
                ),
                child: const Text('Open source linking'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open source linking'));
      await tester.pump(const Duration(milliseconds: 300));
      // Boot ran in the real zone; let native confirm the sensitive surface.
      await tester.runAsync(pumpEventQueue);
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('pairing-offer-input')),
        _offer,
      );
      await tester.pump();
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('pairing-begin')));
        await pumpEventQueue();
      });
      await tester.pump();
      expect(find.byKey(const ValueKey('pairing-approve')), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('pairing-approve')));
        await pumpEventQueue();
      });
      await tester.pump();
      expect(find.text('12345678'), findsOneWidget);
      expect(find.byKey(const ValueKey('pairing-activate')), findsNothing);
      expect(native.restoreFinalizations, 0);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('pairing-close')));
        await pumpEventQueue();
      });
      await tester.pump(const Duration(milliseconds: 300));
      expect(native.commands.where((c) => c['action'] == 'discard'), isEmpty);
      expect(state.accountId, 'acc1');
      expect(tester.takeException(), isNull);
    },
  );
}
