import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/state/device_pairing.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/device_pairing_dialog.dart';
import 'package:sybl/ui/doorlight_brand.dart';
import 'package:sybl/ui/windows_chrome.dart';
import 'app_state_test.dart' show FakeJami;

final _offer = 'jami-auth://${'b' * 64}/123456/doorlight-v1';

class _Link extends FakeJami {
  _Link() {
    accountExists = false;
  }
  Completer<void>? cleanup;
  int begins = 0;
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
    if (action == 'begin') begins++;
    if (action == 'discard') {
      await cleanup?.future;
      return {
        'status': 'discarded',
        'flowToken': flowToken,
        'accountId': 'new-account',
      };
    }
    return {
      'flowToken': flowToken,
      'accountId': 'new-account',
      'ownerAccountId': '',
      'role': 'destination',
      'operation': 123456,
      'status': 'waiting',
      'terminal': false,
      'uri': _offer,
      'code': '',
      'peerId': '',
      'peerDeviceId': '',
      'deviceId': '',
      'error': '',
      'invalidCode': false,
    };
  }
}

void main() {
  setUpAll(() async {
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
  for (final size in [const Size(675, 490), const Size(390, 844)]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'link page reveals code and awaits cleanup at $size scale $scale',
        (tester) async {
          tester.view
            ..physicalSize = size
            ..devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final boundary = GlobalKey();
          SharedPreferences.setMockInitialValues({});
          final native = _Link();
          late AppState state;
          await tester.runAsync(() async {
            state = AppState(native, await SharedPreferences.getInstance());
            await state.init();
          });
          addTearDown(state.dispose);
          state.didChangeAppLifecycleState(AppLifecycleState.resumed);
          await tester.pumpWidget(
            MaterialApp(
              theme: Warm.theme().copyWith(
                platform: size.width >= 600
                    ? TargetPlatform.windows
                    : TargetPlatform.android,
              ),
              builder: (context, child) => RepaintBoundary(
                key: boundary,
                child: MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: size.width >= 600
                      ? WindowsChrome(
                          jami: native,
                          onboarding: true,
                          renderControls: false,
                          child: child!,
                        )
                      : child!,
                ),
              ),
              home: Builder(
                builder: (context) => Scaffold(
                  backgroundColor: Colors.green,
                  body: TextButton(
                    onPressed: () =>
                        unawaited(showDevicePairingPage(context, state: state)),
                    child: const Text('Open link'),
                  ),
                ),
              ),
            ),
          );
          await tester.runAsync(() async {
            await tester.tap(find.text('Open link'));
            await tester.pump();
            await tester.pump();
            await pumpEventQueue();
          });
          // Cover the old route before the incoming content fades in.
          await tester.runAsync(() async {
            final image =
                await (boundary.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary)
                    .toImage();
            try {
              final pixels = await image.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              );
              final offset = (image.height ~/ 2 * image.width + 10) * 4;
              expect(
                pixels!.getUint8(offset),
                greaterThan(pixels.getUint8(offset + 1)),
              );
            } finally {
              image.dispose();
            }
          });
          await tester.pumpAndSettle();
          expect(native.begins, 0);
          if (size.width < 600) {
            expect(
              find.byKey(const ValueKey('pairing-scan-source')),
              findsOneWidget,
            );
          }
          expect(find.byKey(const ValueKey('pairing-offer-qr')), findsNothing);
          await tester.ensureVisible(
            find.byKey(const ValueKey('pairing-show-link-code')),
          );
          await tester.pumpAndSettle();
          await tester.runAsync(() async {
            await tester.tap(
              find.byKey(const ValueKey('pairing-show-link-code')),
            );
            await pumpEventQueue();
          });
          await tester.pumpAndSettle();
          final waiting = state.devicePairing.snapshot!;
          state.devicePairing.snapshot = DevicePairingSnapshot(
            token: waiting.token,
            accountId: waiting.accountId,
            ownerAccountId: waiting.ownerAccountId,
            destination: true,
            status: 'starting',
            terminal: false,
          );
          state.devicePairing.notifyListeners();
          await tester.pump();
          final lightBefore = tester
              .widget<DoorlightDoorMark>(find.byType(DoorlightDoorMark))
              .illumination;
          await tester.pump(const Duration(milliseconds: 300));
          expect(
            tester
                .widget<DoorlightDoorMark>(find.byType(DoorlightDoorMark))
                .illumination,
            isNot(lightBefore),
          );
          state.devicePairing.snapshot = waiting;
          state.devicePairing.notifyListeners();
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsNothing);
          expect(find.byKey(const ValueKey('pairing-page')), findsOneWidget);
          expect(find.text('Open device settings'), findsOneWidget);
          expect(find.byKey(const ValueKey('pairing-offer')), findsNothing);
          final qr = find.byKey(const ValueKey('pairing-offer-qr'));
          expect(tester.getSize(qr).width, greaterThanOrEqualTo(240));
          if (size.width >= 600 && scale == 1) {
            expect(
              find.byKey(const ValueKey('pairing-wide-layout')),
              findsOneWidget,
            );
            expect(
              tester.getRect(find.text('Link this device')).right,
              lessThan(tester.getRect(qr).left),
            );
          } else {
            expect(
              find.byKey(const ValueKey('pairing-wide-layout')),
              findsNothing,
            );
            expect(
              tester.getRect(qr).top,
              greaterThan(tester.getRect(find.text('Link this device')).bottom),
            );
          }
          if (size.width >= 600) {
            await tester.runAsync(() async {
              final image =
                  await (boundary.currentContext!.findRenderObject()!
                          as RenderRepaintBoundary)
                      .toImage();
              try {
                final pixels = await image.toByteData(
                  format: ui.ImageByteFormat.rawRgba,
                );
                final red = pixels!.getUint8(
                  (50 * image.width + image.width ~/ 2) * 4,
                );
                expect(
                  red,
                  greaterThan((Warm.cozy.bg.r * 255).round() + 10),
                  reason: 'the link route must retain the shared warm glow',
                );
              } finally {
                image.dispose();
              }
            });
          }
          if (Platform.environment['DOORLIGHT_LINK_UI_CAPTURE'] == '1') {
            await tester.runAsync(() async {
              final image =
                  await (boundary.currentContext!.findRenderObject()!
                          as RenderRepaintBoundary)
                      .toImage();
              final data = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              image.dispose();
              final file = File(
                '../../local/tmp/doorlight-link-ui/link-${size.width.toInt()}-${scale.toInt()}.png',
              );
              await file.parent.create(recursive: true);
              await file.writeAsBytes(data!.buffer.asUint8List());
            });
          }
          final deadline = state.devicePairing.offerExpiresAt;
          expect(deadline, isNotNull);
          expect(await state.beginDevicePairing(destination: true), isFalse);
          expect(state.devicePairing.offerExpiresAt, deadline);
          expect(find.textContaining('Code expires in about '), findsOneWidget);
          await tester.pump(const Duration(seconds: 3));
          await state.devicePairing.refresh();
          expect(state.devicePairing.offerExpiresAt, deadline);
          expect(native.begins, 1);
          state.devicePairing.retire();
          await tester.pumpAndSettle();
          expect(find.textContaining('Linking was interrupted'), findsNothing);
          expect(find.byKey(const ValueKey('pairing-recover')), findsNothing);
          await tester.ensureVisible(
            find.byKey(const ValueKey('pairing-retry')),
          );
          await tester.runAsync(() async {
            await tester.tap(find.byKey(const ValueKey('pairing-retry')));
            await pumpEventQueue();
          });
          await tester.pumpAndSettle();
          expect(native.begins, 2);
          expect(state.devicePairing.needsRecovery, isFalse);
          final renewedDeadline = state.devicePairing.offerExpiresAt;
          final renewedOffer = state.devicePairing.snapshot!.uri;
          expect(
            find.byKey(const ValueKey('pairing-display-choice')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('pairing-offer-qr')),
            findsOneWidget,
          );
          await tester.ensureVisible(
            find.byKey(const ValueKey('pairing-show-link-code')),
          );
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const ValueKey('pairing-show-link-code')),
          );
          await tester.pump();
          expect(find.byKey(const ValueKey('pairing-offer')), findsOneWidget);
          expect(find.byKey(const ValueKey('pairing-offer-qr')), findsNothing);
          expect(find.text('Copy link code'), findsOneWidget);
          expect(find.text('Paste this link code'), findsOneWidget);
          await tester.tap(find.text('QR'));
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('pairing-offer')), findsNothing);
          expect(
            find.byKey(const ValueKey('pairing-offer-qr')),
            findsOneWidget,
          );
          expect(find.text('Scan this QR code'), findsOneWidget);
          expect(native.begins, 2);
          expect(state.devicePairing.offerExpiresAt, renewedDeadline);
          expect(state.devicePairing.snapshot!.uri, renewedOffer);
          await tester.tap(find.text('Code'));
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('pairing-offer')), findsOneWidget);
          expect(find.byKey(const ValueKey('pairing-offer-qr')), findsNothing);
          native.cleanup = Completer<void>();
          await tester.ensureVisible(
            find.byKey(const ValueKey('pairing-close')),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('pairing-close')));
          await tester.pump();
          expect(find.byKey(const ValueKey('pairing-page')), findsOneWidget);
          expect(find.text('Canceling…'), findsOneWidget);
          native.cleanup!.complete();
          await tester.pump();
          expect(find.byType(DoorlightDoorMark), findsNothing);
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('pairing-page')), findsNothing);
          expect(state.devicePairing.hasVisit, isFalse);
          expect(state.devicePairing.offerExpiresAt, isNull);
          // Only the acknowledged activation result dismisses the destination page.
          state.devicePairing.snapshot = const DevicePairingSnapshot(
            token: '',
            accountId: 'new-account',
            ownerAccountId: '',
            destination: true,
            status: 'complete',
            terminal: true,
          );
          await tester.tap(find.text('Open link'));
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('pairing-page')), findsOneWidget);
          state.devicePairing.notifyListeners();
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('pairing-page')), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
