import 'package:sybl/ui/notice.dart';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/core/invite_link.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/account_share.dart';
import 'package:sybl/ui/add_friend_pane.dart';
import 'package:sybl/ui/friend_connection_page.dart';

const _id = 'a7c42e0123456789abcdef0123456789ab91bd08';

void main() {
  for (final activation in ['Enter', 'Space', 'semantics']) {
    testWidgets('friend code opens persistently with $activation', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      SharedPreferences.setMockInitialValues({});
      final state =
          AppState(JamiClient(), await SharedPreferences.getInstance())
            ..jamiId = _id
            ..displayName = 'PC'
            ..accountId = 'fixture'
            ..screen = Screen.home
            ..seedCaptureStateForTesting(
              resolved: true,
              applied: WindowCaptureProtectionStatus.exclude,
            );
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: Warm.theme().copyWith(platform: TargetPlatform.windows),
          home: Scaffold(
            body: AddFriendPane(
              state: state,
              onClose: () {},
              isCurrent: () => true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('connection-code-field'));
      final fieldFocus = tester.widget<TextField>(field).focusNode!;
      expect(fieldFocus.canRequestFocus, isFalse);
      fieldFocus.requestFocus();
      await tester.pump();
      expect(fieldFocus.hasFocus, isFalse);
      if (activation == 'semantics') {
        final row = tester.getSemantics(
          find.bySemanticsLabel('Friend code or link'),
        );
        expect(
          row.getSemanticsData().hasAction(ui.SemanticsAction.tap),
          isTrue,
        );
        row.owner!.performAction(row.id, ui.SemanticsAction.tap);
      } else {
        final rowFocus = Focus.of(
          tester.element(find.text('Friend code or link')),
        );
        for (var i = 0; i < 12 && !rowFocus.hasFocus; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
          expect(fieldFocus.hasFocus, isFalse);
        }
        expect(rowFocus.hasFocus, isTrue);
        await tester.sendKeyEvent(
          activation == 'Enter'
              ? LogicalKeyboardKey.enter
              : LogicalKeyboardKey.space,
        );
      }
      await tester.pumpAndSettle();
      expect(fieldFocus.hasFocus, isTrue);
      await tester.pump(const Duration(seconds: 1));
      expect(fieldFocus.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(fieldFocus.hasFocus, isFalse);
      expect(fieldFocus.canRequestFocus, isFalse);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    });
  }

  setUpAll(() async {
    for (final font in {
      'HankenGrotesk': 'assets/fonts/HankenGrotesk-Variable.ttf',
      'Fraunces': 'assets/fonts/Fraunces-Variable.ttf',
      'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
      'monospace': 'assets/fonts/HankenGrotesk-Variable.ttf',
    }.entries) {
      await (FontLoader(font.key)..addFont(rootBundle.load(font.value))).load();
    }
  });
  for (final configuration in [
    // Desktop panes run under the 34px title bar; phones have none.
    (const Size(487, 500), 1.0, 34.0),
    (const Size(472, 494), 1.0, 34.0),
    (const Size(390, 844), 1.0, 0.0),
    (const Size(430, 932), 1.0, 0.0),
    (const Size(800, 900), 1.0, 34.0),
    (const Size(472, 494), 2.0, 34.0),
    (const Size(400, 500), 1.0, 34.0),
    (const Size(320, 720), 2.0, 0.0),
  ]) {
    final (size, textScale, titleBar) = configuration;
    testWidgets(
      'connection pane fits $size at ${textScale}x, copies full ID and enlarges same QR',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final state =
            AppState(JamiClient(), await SharedPreferences.getInstance())
              ..jamiId = _id
              ..displayName = 'PC'
              ..accountId = 'fixture'
              ..screen = Screen.home
              ..seedCaptureStateForTesting(
                resolved: true,
                applied: WindowCaptureProtectionStatus.exclude,
              );
        addTearDown(state.dispose);
        final copied = <String>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copied.add((call.arguments as Map)['text'] as String);
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: withNoticeHost(child!, state),
            ),
            theme: Warm.theme().copyWith(
              platform: titleBar == 0
                  ? TargetPlatform.android
                  : TargetPlatform.windows,
            ),
            home: Scaffold(
              body: RepaintBoundary(
                key: const ValueKey('capture'),
                child: AddFriendPane(
                  state: state,
                  onClose: () {},
                  isCurrent: () => true,
                  titleBarHeight: titleBar,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          tester.getTopLeft(find.byType(Scrollable).first).dy,
          greaterThanOrEqualTo(titleBar),
          reason: 'Scrolling content stays below the desktop drag region.',
        );
        expect(
          tester.getTopLeft(find.byKey(const ValueKey('add-friend-title'))).dy,
          titleBar + (titleBar > 0 ? 12 : 24),
          reason:
              'The page title sits below chrome with a modest content inset.',
        );
        expect(find.text('a7c4…bd08'), findsOneWidget);
        expect(find.byKey(const ValueKey('connection-nearby')), findsOneWidget);
        expect(find.text('Find people on your Wi-Fi'), findsNothing);
        expect(find.text('Friend code or link'), findsOneWidget);
        expect(find.text('Choose how you want to connect.'), findsNothing);
        expect(find.byTooltip('Close'), findsNothing);
        final identityHeading = find.text('Your Doorlight');
        expect(identityHeading, findsOneWidget);
        expect(
          find.ancestor(of: identityHeading, matching: find.byType(Material)),
          findsNWidgets(1),
        );
        expect(find.text('Add someone using their ID'), findsNothing);
        final actionKeys = [
          'connection-nearby',
          'connection-enter-id',
          'connection-scan-qr',
        ];
        final actionRects = actionKeys
            .map((key) => tester.getRect(find.byKey(ValueKey(key))))
            .toList();
        expect(
          tester.getTopLeft(find.byKey(const ValueKey('add-friend-title'))).dx,
          closeTo(actionRects.first.left, .01),
          reason:
              'The header follows the content column, including wide panes.',
        );
        expect(actionRects[0].bottom, lessThanOrEqualTo(actionRects[1].top));
        expect(actionRects[1].bottom, lessThanOrEqualTo(actionRects[2].top));
        expect(actionRects.map((rect) => rect.left).toSet(), hasLength(1));
        expect(
          tester
              .renderObject<RenderParagraph>(find.text('Sonar'))
              .getBoxesForSelection(
                const TextSelection(baseOffset: 0, extentOffset: 5),
              ),
          hasLength(1),
          reason: 'Nearby stays one readable word, including at 200% text.',
        );
        expect(
          tester
              .getRect(find.byKey(const ValueKey('connection-enlarge-qr')))
              .left,
          lessThan(tester.getRect(find.byType(FriendInviteQr)).right),
        );
        final copyRect = tester.getRect(
          find.byKey(const ValueKey('connection-copy-id')),
        );
        final idRect = tester.getRect(
          find.byKey(const ValueKey('connection-short-id')),
        );
        final shareRect = tester.getRect(
          find.byKey(const ValueKey('connection-share')),
        );
        // A Copy pill sits just after the code (wrapping below it on narrow
        // phones rather than truncating it); share keeps the bottom-right.
        expect(find.text('a7c4…bd08'), findsOneWidget);
        if (textScale == 1 && size.width >= 400) {
          expect(copyRect.left, greaterThanOrEqualTo(idRect.right));
          expect(copyRect.left - idRect.right, lessThan(16));
          expect(copyRect.center.dy, closeTo(idRect.center.dy, 1));
          expect(shareRect.left, greaterThanOrEqualTo(copyRect.right));
        } else {
          expect(copyRect.top, greaterThanOrEqualTo(idRect.top));
        }
        expect(
          tester
              .renderObject<RenderParagraph>(
                find.byKey(const ValueKey('connection-short-id')),
              )
              .didExceedMaxLines,
          isFalse,
          reason: 'The short code is never truncated further.',
        );
        expect(
          shareRect.width,
          lessThan(48),
          reason: 'Share is one small icon.',
        );
        if (textScale == 1 && titleBar > 0) {
          final qrRect = tester.getRect(find.byType(FriendInviteQr));
          final textRect = tester.getRect(
            find.byKey(const ValueKey('connection-identity-text')),
          );
          expect(textRect.center.dy, closeTo(qrRect.center.dy, 1));
          expect(shareRect.bottom, closeTo(qrRect.bottom, .001));
        }
        if (textScale == 1 && titleBar == 0) {
          final qrRect = tester.getRect(find.byType(FriendInviteQr));
          expect(qrRect.width, 164);
          expect(qrRect.center.dx, closeTo(size.width / 2, 1));
          expect(
            tester
                .getTopLeft(find.byKey(const ValueKey('add-friend-title')))
                .dy,
            24,
          );
        }
        expect(find.textContaining('ID'), findsNothing);
        expect(find.text('Copy'), findsNothing);
        expect(find.byTooltip('Copy friend code'), findsOneWidget);
        expect(find.text('Your name'), findsOneWidget);
        expect(find.text('Your friend code'), findsOneWidget);
        expect(find.byTooltip('Share invite'), findsOneWidget);
        expect(find.text('QR code'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('connection-qr-zoom')),
          findsOneWidget,
        );
        expect(
          tester.getTopLeft(find.byKey(const ValueKey('connection-name'))).dx,
          tester
              .getTopLeft(find.byKey(const ValueKey('connection-short-id')))
              .dx,
        );
        expect(
          tester.getTopLeft(find.byKey(const ValueKey('connection-name'))).dy,
          lessThan(
            tester
                .getTopLeft(find.byKey(const ValueKey('connection-short-id')))
                .dy,
          ),
        );
        if (textScale == 1 && size.height >= 494) {
          expect(
            tester
                .getRect(find.byKey(const ValueKey('connection-share')))
                .bottom,
            lessThan(size.height),
          );
          expect(
            tester
                .state<ScrollableState>(find.byType(Scrollable).first)
                .position
                .maxScrollExtent,
            0,
          );
        } else {
          expect(
            tester
                .state<ScrollableState>(find.byType(Scrollable).first)
                .position
                .maxScrollExtent,
            greaterThan(0),
            reason: 'Enlarged text scrolls to the identity card.',
          );
        }
        if (Platform.environment['DOORLIGHT_CAPTURE'] == '1') {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('capture')),
          );
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 2);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File(
              '${Platform.environment['DOORLIGHT_CAPTURE_DIR'] ?? '../../local/tmp/layout-captures'}/pane-${size.width.toInt()}.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.ensureVisible(
          find.byKey(const ValueKey('connection-copy-id')),
        );
        await tester.tap(find.byKey(const ValueKey('connection-copy-id')));
        await tester.pump();
        expect(copied, [_id]);
        if (titleBar > 0) {
          await tester.ensureVisible(
            find.byKey(const ValueKey('connection-share')),
          );
          await tester.tap(find.byKey(const ValueKey('connection-share')));
          await tester.pumpAndSettle();
          for (final item in [
            'Copy link',
            'WhatsApp',
            'Telegram',
            'Email',
            'More options…',
          ]) {
            expect(find.text(item), findsOneWidget);
          }
          await tester.tap(find.text('Copy link'));
          await tester.pumpAndSettle();
          expect(copied.last, contains(_id));
          expect(find.text('WhatsApp'), findsNothing);
        }
        final qr = tester.widget<FriendInviteQr>(find.byType(FriendInviteQr));
        expect(
          qr.invite.shareUri(),
          SyblInviteLink.create(jamiId: _id, displayName: 'PC')!.shareUri(),
        );
        await tester.ensureVisible(
          find.byKey(const ValueKey('connection-enlarge-qr')),
        );
        await tester.tap(find.byKey(const ValueKey('connection-enlarge-qr')));
        await tester.pumpAndSettle();
        expect(find.text('Your QR code'), findsOneWidget);
        expect(
          tester
              .widget<FriendInviteQr>(find.byType(FriendInviteQr).last)
              .invite
              .shareUri(),
          qr.invite.shareUri(),
        );
        await tester.tap(find.text('Done'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('connection-enter-id')),
        );
        // A click only peeks; a left swipe uncovers the field behind the row.
        final row = find.byKey(const ValueKey('connection-enter-id'));
        final rowRect = tester.getRect(row);
        await tester.tap(row);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));
        // The click hops the row left to show the field, then it settles back.
        expect(tester.getRect(row).left, lessThan(rowRect.left - 40));
        await tester.pumpAndSettle();
        expect(find.byType(FriendConnectionPage), findsNothing);
        expect(tester.getRect(row), rowRect);
        final field = find.byKey(const ValueKey('connection-code-field'));
        expect(
          tester
              .widget<IgnorePointer>(
                find
                    .ancestor(of: field, matching: find.byType(IgnorePointer))
                    .first,
              )
              .ignoring,
          isTrue,
        );
        await tester.drag(row, Offset(-rowRect.width * .6, 0));
        await tester.pumpAndSettle();
        expect(tester.getRect(row).right, lessThanOrEqualTo(rowRect.left + 1));
        expect(
          find.byKey(const ValueKey('connection-code-paste')),
          findsOneWidget,
        );
        await tester.enterText(field, 'not a code');
        await tester.testTextInput.receiveAction(TextInputAction.go);
        await tester.pump();
        expect(
          find.text('That isn’t a Doorlight link or friend code.'),
          findsOneWidget,
        );
        // The swiped row keeps its height while showing an error.
        expect(tester.getRect(row).height, rowRect.height);
        expect(find.byType(FriendConnectionPage), findsNothing);
        await tester.enterText(
          field,
          '0123456789abcdef0123456789abcdef01234567',
        );
        // The error notice overlays the narrow pane until it times out.
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('connection-code-go')));
        await tester.pumpAndSettle();
        expect(find.byType(FriendConnectionPage), findsOneWidget);
        expect(
          find.byKey(const ValueKey('friend-invite-confirmation')),
          findsOneWidget,
        );
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.text('Good chats start\nwith your people.'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        expect(find.byType(FriendConnectionPage), findsNothing);
        expect(find.byType(FriendInviteQr), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('connection-code-close')));
        await tester.pumpAndSettle();
        expect(tester.getRect(row), rowRect);
        expect(tester.widget<TextField>(field).controller!.text, isEmpty);
        if (titleBar > 0) {
          // Desktop QR: one viewfinder with the upload inside it, and no
          // code field until a QR is read.
          await tester.ensureVisible(
            find.byKey(const ValueKey('connection-scan-qr')),
          );
          await tester.tap(find.byKey(const ValueKey('connection-scan-qr')));
          await tester.pumpAndSettle();
          expect(find.text('Scan a QR code'), findsOneWidget);
          expect(
            find.byKey(const ValueKey('friend-qr-webcam')),
            findsOneWidget,
          );
          expect(find.text('Upload a QR image'), findsOneWidget);
          expect(find.byKey(const ValueKey('friend-id-field')), findsNothing);
          await tester.tap(find.byType(BackButton));
          await tester.pumpAndSettle();
        }
      },
    );
  }
}
