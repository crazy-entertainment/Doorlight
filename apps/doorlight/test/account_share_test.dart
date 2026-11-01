import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/account_share.dart';

const _fingerprint = 'abcdef0123456789abcdef0123456789abcdef01';

void main() {
  testWidgets('configured HTTPS QR carries the invitation', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme(),
        home: const Scaffold(
          body: AccountShareCard(
            jamiId: _fingerprint,
            displayName: 'Zoë & Mara',
            httpsOrigin: 'https://invites.example.test',
          ),
        ),
      ),
    );
    final qr = tester.widget<FriendInviteQr>(find.byType(FriendInviteQr));
    expect(
      qr.invite.shareUri(httpsOrigin: qr.httpsOrigin),
      'https://invites.example.test/invite/#v=1&id=$_fingerprint&name=Zo%C3%AB+%26+Mara',
    );
    expect(find.text('Show this to your friend'), findsOneWidget);
    expect(find.text(_fingerprint), findsNothing);
    expect(find.text('Copy invite link'), findsOneWidget);
  });

  testWidgets('Friend ID stays behind an optional disclosure', (tester) async {
    final clipboardWrites = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboardWrites.add((call.arguments as Map)['text'] as String);
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
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme(),
        // Both real hosts (dialog and mobile route) scroll the card.
        home: const Scaffold(
          body: SingleChildScrollView(
            child: AccountShareCard(jamiId: _fingerprint),
          ),
        ),
      ),
    );
    expect(
      find.bySemanticsLabel('QR code for your Doorlight invitation'),
      findsOneWidget,
    );
    expect(find.text(_fingerprint), findsNothing);
    await tester.tap(find.byKey(const ValueKey('reveal-shared-jami-id')));
    await tester.pumpAndSettle();
    expect(find.text(_fingerprint), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('copy-shared-jami-id')));
    await tester.pump();
    expect(clipboardWrites, [_fingerprint]);
    expect(tester, meetsGuideline(androidTapTargetGuideline));
    expect(tester, meetsGuideline(textContrastGuideline));
    semantics.dispose();
  });

  testWidgets('does not render a QR before the daemon identity is ready', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: Warm.theme(),
        home: const Scaffold(body: AccountShareCard(jamiId: '')),
      ),
    );
    expect(
      find.byKey(const ValueKey('jami-share-unavailable')),
      findsOneWidget,
    );
    expect(find.byType(FriendInviteQr), findsNothing);
  });
}
