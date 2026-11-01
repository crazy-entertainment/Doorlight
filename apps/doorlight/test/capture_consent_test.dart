import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/state/app_settings.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/capture_consent_gate.dart';
import 'package:sybl/ui/settings_pane.dart';

import 'app_state_test.dart' show FakeJami;

class _NativeConsentJami extends FakeJami {
  Completer<WindowCaptureProtectionStatus>? presentation;
  @override
  Future<WindowCaptureProtectionStatus> presentWindowsCapturePrompt() async {
    captureProtection =
        await (presentation?.future ??
            Future.value(WindowCaptureProtectionStatus.exclude));
    return captureProtection;
  }
}

/// Windows capture detection is best effort. Native reports only transitions
/// from OBS Studio's local process and log. Capture protection, not detection,
/// remains the privacy boundary: detection can open this data-free prompt, but
/// it can never expose the real window.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeJami jami;
  late AppState state;
  var ownsState = false;

  Map<String, Object> settingsDocument({required bool captureEnabled}) => {
    'appSettings': jsonEncode({
      ...const AppSettingsCodec().encode(AppSettings()),
      'windowsCaptureProtection': {'enabled': captureEnabled},
    }),
  };

  Future<void> boot(
    Map<String, Object> prefs, {
    void Function(FakeJami jami)? configure,
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    // Native launch truth: the data-free gate starts at WDA_NONE.
    jami = _NativeConsentJami()
      ..captureProtection = WindowCaptureProtectionStatus.none;
    configure?.call(jami);
    state = AppState(jami, await SharedPreferences.getInstance());
    ownsState = true;
    await state.init();
  }

  void usePlatform(TargetPlatform platform) {
    debugDefaultTargetPlatformOverride = platform;
  }

  void reportCapture(bool active) {
    jami.push('captureActivity', {'active': active, 'source': 'obsLog'});
  }

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    if (ownsState) state.dispose();
    ownsState = false;
  });

  group('boot resolution', () {
    setUp(() => usePlatform(TargetPlatform.windows));

    test(
      'default preference protects at boot without showing a prompt',
      () async {
        await boot({'displayName': 'Me'});

        expect(jami.captureApplyCalls, [true]);
        expect(
          state.windowCaptureProtection,
          WindowCaptureProtectionStatus.exclude,
        );
        expect(state.captureGateReady, isTrue);
        expect(state.captureGateVisible, isFalse);
        expect(state.captureConsent, WindowsCaptureConsent.protect);
      },
    );

    test('durable visibility opt-out is confirmed without the gate', () async {
      await boot({
        'displayName': 'Me',
        ...settingsDocument(captureEnabled: false),
      });

      expect(jami.captureApplyCalls, [false]);
      expect(state.windowCaptureProtection, WindowCaptureProtectionStatus.none);
      expect(state.windowsCaptureProtectionEnabled, isFalse);
      expect(state.captureGateVisible, isFalse);
    });

    test(
      'corrupt settings stay conservatively protected and read-only',
      () async {
        await boot({'displayName': 'Me', 'appSettings': '{not json'});

        expect(state.captureGateVisible, isFalse);
        expect(state.windowsCaptureProtectionEnabled, isTrue);
        expect(state.settingsWritable, isFalse);
        expect(jami.captureApplyCalls, [true]);
      },
    );

    test('failed boot protection keeps the data-free failure gate', () async {
      await boot(
        {'displayName': 'Me'},
        configure: (jami) {
          jami.captureApplyProtectedResult =
              WindowCaptureProtectionStatus.unavailable;
        },
      );

      expect(state.captureGateVisible, isTrue);
      expect(state.captureGateError, contains('could not be applied'));
      expect(
        state.windowCaptureProtection,
        WindowCaptureProtectionStatus.unavailable,
      );
    });

    test(
      'non-Windows platforms neither gate nor apply Windows affinity',
      () async {
        usePlatform(TargetPlatform.android);
        await boot({'displayName': 'Me'});

        expect(jami.captureApplyCalls, isEmpty);
        expect(state.captureGateVisible, isFalse);
        await state.setWindowsCaptureProtectionEnabled(false);
        expect(jami.captureApplyCalls, isEmpty);
      },
    );
  });

  group('gate decisions', () {
    setUp(() => usePlatform(TargetPlatform.windows));

    test(
      'only the data-free gate becomes capturable after presentation',
      () async {
        await boot({'displayName': 'Me'});
        final frame = Completer<WindowCaptureProtectionStatus>();
        (jami as _NativeConsentJami).presentation = frame;
        jami.push('captureActivity', {
          'active': true,
          'source': 'captureProductLog',
        });
        final pending = state.presentWindowsCapturePrompt(
          state.capturePromptGeneration,
        );
        expect(state.captureGateVisible, isTrue);
        expect(jami.captureApplyCalls, [true]);
        expect(state.windowCaptureProtection.isProtected, isTrue);
        frame.complete(WindowCaptureProtectionStatus.none);
        await pending;
        expect(state.captureGateVisible, isTrue);
        expect(state.captureConsent, WindowsCaptureConsent.pending);
        expect(
          state.windowCaptureProtection,
          WindowCaptureProtectionStatus.none,
        );
        await state.captureConsentShowThisSession();
        expect(jami.captureApplyCalls, [true, false]);
        expect(state.captureConsent, WindowsCaptureConsent.showThisSession);
        expect(state.windowsCaptureProtectionEnabled, isTrue);
      },
    );

    test(
      'capture stop during presentation re-protects before private content returns',
      () async {
        await boot({'displayName': 'Me'});
        final frame = Completer<WindowCaptureProtectionStatus>();
        (jami as _NativeConsentJami).presentation = frame;
        reportCapture(true);
        final pending = state.presentWindowsCapturePrompt(
          state.capturePromptGeneration,
        );
        reportCapture(false);
        expect(state.captureGateVisible, isTrue);
        frame.complete(WindowCaptureProtectionStatus.none);
        await pending;
        expect(jami.captureApplyCalls, [true, true]);
        expect(state.windowCaptureProtection.isProtected, isTrue);
        expect(state.captureGateVisible, isFalse);
        expect(state.windowsCaptureProtectionEnabled, isTrue);
      },
    );

    Future<void> bootAndDetect({
      void Function(FakeJami jami)? configure,
    }) async {
      await boot({'displayName': 'Me'}, configure: configure);
      jami.captureApplyCalls.clear();
      reportCapture(true);
      expect(state.captureGateVisible, isTrue);
    }

    test(
      'capture start opens the prompt only while protection is active',
      () async {
        await boot({'displayName': 'Me'});

        expect(state.captureGateVisible, isFalse);
        reportCapture(true);

        expect(state.captureGateVisible, isTrue);
        expect(state.captureConsent, WindowsCaptureConsent.pending);
        expect(state.windowCaptureProtection.isProtected, isTrue);
        expect(jami.captureApplyCalls, [true]);
      },
    );

    test('unapproved capture source cannot open or close prompt', () async {
      await boot({'displayName': 'Me'});

      jami.push('captureActivity', {
        'active': true,
        'source': 'processHeuristic',
      });
      expect(state.captureGateVisible, isFalse);

      reportCapture(true);
      expect(state.captureGateVisible, isTrue);

      jami.push('captureActivity', {
        'active': false,
        'source': 'processHeuristic',
      });
      expect(state.captureGateVisible, isTrue);
    });

    test('non-Boolean OBS activity cannot change prompt', () async {
      await bootAndDetect();

      jami.push('captureActivity', {'active': 'false', 'source': 'obsLog'});

      expect(state.captureGateVisible, isTrue);
      expect(state.captureConsent, WindowsCaptureConsent.pending);
    });

    test('Keep hidden resolves only on an actually protected result', () async {
      await bootAndDetect();

      await state.captureConsentHide();

      expect(jami.captureApplyCalls, [true]);
      expect(state.captureGateVisible, isFalse);
      expect(state.captureConsent, WindowsCaptureConsent.protect);
      expect(
        state.windowCaptureProtection,
        WindowCaptureProtectionStatus.exclude,
      );
      expect(state.windowsCaptureProtectionEnabled, isTrue);
    });

    test('Keep hidden accepts the documented monitor fallback', () async {
      await bootAndDetect(
        configure: (jami) {
          jami.captureApplyProtectedResult =
              WindowCaptureProtectionStatus.monitor;
        },
      );

      await state.captureConsentHide();

      expect(state.captureGateVisible, isFalse);
      expect(
        state.windowCaptureProtection,
        WindowCaptureProtectionStatus.monitor,
      );
    });

    test('Keep hidden fails closed and can be retried', () async {
      await bootAndDetect();
      jami.captureApplyProtectedResult =
          WindowCaptureProtectionStatus.unavailable;

      await state.captureConsentHide();
      expect(state.captureGateVisible, isTrue);
      expect(state.captureConsent, WindowsCaptureConsent.pending);
      expect(state.captureGateError, contains('could not be applied'));

      jami.captureApplyProtectedResult = WindowCaptureProtectionStatus.exclude;
      await state.captureConsentHide();
      expect(state.captureGateVisible, isFalse);
      expect(state.captureConsent, WindowsCaptureConsent.protect);
    });

    test('Show confirms WDA_NONE and persists nothing', () async {
      await bootAndDetect();

      await state.captureConsentShowThisSession();

      expect(jami.captureApplyCalls, [false]);
      expect(state.captureGateVisible, isFalse);
      expect(state.captureConsent, WindowsCaptureConsent.showThisSession);
      expect(state.windowCaptureProtection, WindowCaptureProtectionStatus.none);
      expect(state.windowsCaptureProtectionEnabled, isTrue);
      expect(state.prefs.getString('appSettings'), isNull);
    });

    test('Show always confirms WDA_NONE and persists the opt-out', () async {
      await bootAndDetect();

      await state.captureConsentShowAlways();

      expect(jami.captureApplyCalls, [false]);
      expect(state.windowsCaptureProtectionEnabled, isFalse);
      expect(state.windowCaptureProtection, WindowCaptureProtectionStatus.none);
      expect(state.captureGateVisible, isFalse);
      final stored =
          jsonDecode(state.prefs.getString('appSettings')!)
              as Map<String, dynamic>;
      expect(
        (stored['windowsCaptureProtection'] as Map<String, dynamic>)['enabled'],
        isFalse,
      );
    });

    test(
      'Show always fails closed when native does not confirm WDA_NONE',
      () async {
        await bootAndDetect(
          configure: (jami) {
            jami.captureApplyVisibleResult =
                WindowCaptureProtectionStatus.unavailable;
          },
        );

        await state.captureConsentShowAlways();

        expect(state.captureGateVisible, isTrue);
        expect(state.windowsCaptureProtectionEnabled, isTrue);
        expect(state.captureGateError, contains('could not be confirmed'));
      },
    );

    test('Keep hidden suppresses repeats until capture stops', () async {
      await bootAndDetect();
      await state.captureConsentHide();
      expect(state.captureGateVisible, isFalse);

      reportCapture(true);
      expect(state.captureGateVisible, isFalse);

      reportCapture(false);
      reportCapture(true);
      expect(state.captureGateVisible, isTrue);
    });

    test('capture stop closes an unanswered detected-capture prompt', () async {
      await bootAndDetect();

      reportCapture(false);

      expect(state.captureGateVisible, isFalse);
      expect(state.captureConsent, WindowsCaptureConsent.protect);
      expect(state.windowCaptureProtection.isProtected, isTrue);
    });

    test('durable opt-out ignores capture activity', () async {
      await boot({
        'displayName': 'Me',
        ...settingsDocument(captureEnabled: false),
      });

      reportCapture(true);

      expect(state.captureGateVisible, isFalse);
      expect(state.windowCaptureProtection, WindowCaptureProtectionStatus.none);
    });
  });

  group('settings transitions', () {
    setUp(() => usePlatform(TargetPlatform.windows));

    test(
      'disable applies WDA_NONE before persisting the durable opt-out',
      () async {
        await boot({'displayName': 'Me'});
        jami.captureApplyCalls.clear();

        await state.setWindowsCaptureProtectionEnabled(false);

        expect(jami.captureApplyCalls, [false]);
        expect(state.windowsCaptureProtectionEnabled, isFalse);
        expect(
          state.windowCaptureProtection,
          WindowCaptureProtectionStatus.none,
        );
      },
    );

    test('failed disable leaves the protected preference enabled', () async {
      await boot({'displayName': 'Me'});
      jami.captureApplyCalls.clear();
      jami.captureApplyVisibleResult =
          WindowCaptureProtectionStatus.unavailable;

      await state.setWindowsCaptureProtectionEnabled(false);

      expect(jami.captureApplyCalls, [false]);
      expect(state.windowsCaptureProtectionEnabled, isTrue);
      expect(state.captureSettingsNote, contains('Nothing changed'));
    });

    test(
      'enabling privacy applies protection without opening the prompt',
      () async {
        await boot({
          'displayName': 'Me',
          ...settingsDocument(captureEnabled: false),
        });
        jami.captureApplyCalls.clear();

        await state.setWindowsCaptureProtectionEnabled(true);

        expect(jami.captureApplyCalls, [true]);
        expect(state.captureGateVisible, isFalse);
        expect(state.captureConsent, WindowsCaptureConsent.protect);
        expect(
          state.windowCaptureProtection,
          WindowCaptureProtectionStatus.exclude,
        );
        expect(state.windowsCaptureProtectionEnabled, isTrue);
      },
    );

    test('enabling privacy during OBS capture opens the prompt', () async {
      await boot({
        'displayName': 'Me',
        ...settingsDocument(captureEnabled: false),
      });
      reportCapture(true);
      jami.captureApplyCalls.clear();

      await state.setWindowsCaptureProtectionEnabled(true);

      expect(jami.captureApplyCalls, [true]);
      expect(state.windowCaptureProtection.isProtected, isTrue);
      expect(state.captureGateVisible, isTrue);
    });

    test('Hide now reapplies protection after a session-only Show', () async {
      await boot({'displayName': 'Me'});
      reportCapture(true);
      await state.captureConsentShowThisSession();
      reportCapture(false);
      jami.captureApplyCalls.clear();

      await state.restoreWindowsCaptureProtection();

      expect(jami.captureApplyCalls, [true]);
      expect(
        state.windowCaptureProtection,
        WindowCaptureProtectionStatus.exclude,
      );
      expect(state.captureGateVisible, isFalse);
      expect(state.captureConsent, WindowsCaptureConsent.protect);
      expect(state.windowsCaptureProtectionEnabled, isTrue);
    });

    test(
      'Hide now covers private content until protection is confirmed',
      () async {
        await boot({'displayName': 'Me'});
        reportCapture(true);
        await state.captureConsentShowThisSession();
        reportCapture(false);
        final apply = Completer<WindowCaptureProtectionStatus>();
        jami.pendingCaptureApply = apply;

        final hiding = state.restoreWindowsCaptureProtection();
        expect(state.captureGateVisible, isTrue);
        expect(state.captureBusy, isTrue);
        apply.complete(WindowCaptureProtectionStatus.unavailable);
        await hiding;

        expect(state.captureGateVisible, isTrue);
        expect(state.captureGateError, contains('could not be applied'));
        jami.pendingCaptureApply = null;
        await state.captureConsentHide();
        expect(state.captureGateVisible, isFalse);
        expect(state.windowCaptureProtection.isProtected, isTrue);
      },
    );

    test('Hide now keeps the failure gate after a native exception', () async {
      await boot({'displayName': 'Me'});
      reportCapture(true);
      await state.captureConsentShowThisSession();
      jami.captureApplyError = StateError('native unavailable');

      await state.restoreWindowsCaptureProtection();

      expect(state.captureGateVisible, isTrue);
      expect(state.captureGateError, contains('could not be applied'));
      reportCapture(false);
      expect(state.captureGateVisible, isTrue);
    });

    test(
      'enable covers private content while native protection is pending',
      () async {
        await boot({
          'displayName': 'Me',
          ...settingsDocument(captureEnabled: false),
        });
        final apply = Completer<WindowCaptureProtectionStatus>();
        jami.pendingCaptureApply = apply;
        final enabling = state.setWindowsCaptureProtectionEnabled(true);
        // Let preference persistence finish before checking the native wait.
        await Future<void>.delayed(Duration.zero);

        expect(state.captureGateVisible, isTrue);
        apply.complete(WindowCaptureProtectionStatus.exclude);
        await enabling;
        expect(state.captureGateVisible, isFalse);
        expect(state.windowCaptureProtection.isProtected, isTrue);
      },
    );

    test('applied-state copy makes no automatic-capture claim', () {
      expect(
        windowCaptureProtectionDescription(
          WindowCaptureProtectionStatus.exclude,
        ),
        contains('Hidden from supported screenshot'),
      );
      expect(
        windowCaptureProtectionDescription(WindowCaptureProtectionStatus.none),
        'This app window appears in screenshots and screen sharing.',
      );
      expect(
        windowCaptureProtectionDescription(
          WindowCaptureProtectionStatus.none,
          showThisSession: true,
        ),
        contains('for this session'),
      );
      expect(
        windowCaptureProtectionDescription(
          WindowCaptureProtectionStatus.unavailable,
        ),
        contains('not protected'),
      );
    });
  });

  group('data-free launch surface', () {
    Future<void> pumpGate(
      WidgetTester tester, {
      required bool preferenceKnown,
      required bool protectionEnabled,
      String? error,
    }) async {
      SharedPreferences.setMockInitialValues(
        settingsDocument(captureEnabled: protectionEnabled),
      );
      jami = FakeJami();
      state = AppState(jami, await SharedPreferences.getInstance());
      ownsState = true;
      if (!protectionEnabled) {
        state.appSettings = state.appSettings
            .withWindowsCaptureProtectionEnabled(false);
      }
      state.seedCaptureStateForTesting(
        preferenceKnown: preferenceKnown,
        resolved: false,
        gateError: error,
        activityActive: error == null,
        applied: WindowCaptureProtectionStatus.unavailable,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: Warm.theme(),
          home: CaptureConsentGate(state: state),
        ),
      );
      await tester.pump();
    }

    testWidgets(
      'unresolved preference paints only a neutral preparing surface',
      (tester) async {
        await pumpGate(tester, preferenceKnown: false, protectionEnabled: true);

        expect(find.byType(CircularProgressIndicator), findsOne);
        expect(find.textContaining('capture detected'), findsNothing);
        expect(find.byType(FilledButton), findsNothing);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    testWidgets(
      'detected capture asks whether to show the protected window',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(800, 500);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        await pumpGate(tester, preferenceKnown: true, protectionEnabled: true);

        expect(
          find.text('Screen sharing or recording detected. Show Doorlight?'),
          findsOne,
        );
        expect(find.byKey(const ValueKey('capture-mock-avatar')), findsWidgets);
        expect(
          find.byKey(const ValueKey('capture-mock-message')),
          findsWidgets,
        );
        expect(find.byKey(const ValueKey('capture-consent-show')), findsOne);
        expect(
          find.byKey(const ValueKey('capture-consent-show-always')),
          findsOne,
        );
        expect(find.byKey(const ValueKey('capture-consent-hide')), findsOne);
        expect(find.textContaining('Windows does not'), findsNothing);
        expect(find.textContaining('stays blurred'), findsNothing);
        expect(find.textContaining('Show applies'), findsNothing);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    testWidgets(
      'Show always immediately persists capture visibility',
      (tester) async {
        await pumpGate(tester, preferenceKnown: true, protectionEnabled: true);

        await tester.tap(
          find.byKey(const ValueKey('capture-consent-show-always')),
        );
        await tester.pumpAndSettle();

        expect(find.text('Always show Doorlight in screen capture?'), findsNothing);
        expect(state.captureGateVisible, isFalse);
        expect(state.windowCaptureProtection, WindowCaptureProtectionStatus.none);
        expect(jami.captureApplyCalls, [false]);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  });
}
