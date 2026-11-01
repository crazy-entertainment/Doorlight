import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/state/composer_media.dart';
import 'package:sybl/state/conversation_scope.dart';
import 'package:sybl/state/conversation_timeline.dart';
import 'package:sybl/state/gif_library_store.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/chat_stage.dart';
import 'package:sybl/ui/notice.dart';

class _State extends AppState {
  _State(super.jami, super.prefs);
  final result = Completer<GifLibraryResult>();
  int saves = 0;
  @override
  bool get canPlayMessageMedia => true;
  @override
  Future<bool> validateTimelineMedia(
    TimelineFileItem item,
    String path,
  ) async => true;
  @override
  Future<GifLibraryResult> saveReceivedGif(TimelineFileItem item, String path) {
    saves++;
    return result.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader('HankenGrotesk')
          ..addFont(rootBundle.load('assets/fonts/HankenGrotesk-Variable.ttf')))
        .load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    await (FontLoader(
      'Fraunces',
    )..addFont(rootBundle.load('assets/fonts/Fraunces-Variable.ttf'))).load();
  });
  for (final narrow in [false, true]) {
    testWidgets(
      'received GIF save control ${narrow ? 'mobile text200' : 'desktop'}',
      (tester) async {
        tester.view.physicalSize = narrow
            ? const Size(390, 500)
            : const Size(700, 360);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        SharedPreferences.setMockInitialValues({});
        final state = _State(
          JamiClient(),
          await SharedPreferences.getInstance(),
        )..accountId = 'account';
        state.seedEmptyRuntimeSnapshotForTesting(
          friends: [
            FriendState(
              peerId: 'friend',
              confirmed: true,
              conversationId: 'conversation',
              displayName: 'Mara',
            ),
          ],
          selectedPeerId: 'friend',
        );
        addTearDown(state.dispose);
        final file = File('assets/gifs/doorlight/hello.gif').absolute;
        final stage = await tester.runAsync(
          () async => validateComposerGif(file.path, await file.length()),
        );
        final scope = ConversationScope(
          accountId: 'account',
          peerId: 'friend',
          conversationId: 'conversation',
        );
        final item = TimelineFileItem(
          scope: scope,
          daemonId: 'message',
          versionId: 'message',
          authorId: 'friend',
          direction: TimelineDirection.incoming,
          createdAt: DateTime.utc(2026, 9, 21),
          fileId: 'gif-file',
          displayName: 'Hello.gif',
          totalBytes: stage!.encodedBytes,
          sha3: null,
          downloaded: true,
          mediaMetadata: stage.mediaMetadata,
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: Warm.theme(),
            builder: (context, child) => withNoticeHost(child!, state),
            home: MediaQuery(
              data: MediaQueryData(
                textScaler: TextScaler.linear(narrow ? 2 : 1),
                disableAnimations: true,
              ),
              child: RepaintBoundary(
                key: const ValueKey('received-gif'),
                child: Scaffold(
                  body: ConversationTimelineView(
                    state: state,
                    live: const [],
                    timeline: [item],
                    legacyFiles: [
                      FolderFile(
                        peerId: scope.peerId,
                        conversationId: scope.conversationId,
                        authorId: 'friend',
                        fileId: item.fileId,
                        interactionId: item.daemonId,
                        name: item.displayName,
                        size: stage.encodedBytes,
                        downloaded: true,
                        path: file.path,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        for (var i = 0; i < 50; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
          if (tester
              .widgetList<RawImage>(find.byType(RawImage))
              .any((image) => image.image != null)) {
            break;
          }
        }
        await tester.ensureVisible(find.text('Save to my GIFs'));
        await tester.pump(const Duration(milliseconds: 300));
        await expectLater(
          find.byKey(const ValueKey('received-gif')),
          matchesGoldenFile(
            'goldens/${narrow ? 'mobile' : 'desktop'}_received_gif_save.png',
          ),
        );
        await tester.tap(find.text('Save to my GIFs'));
        await tester.pump();
        expect(find.text('Saving GIF…'), findsOneWidget);
        expect(state.saves, 1);
        state.result.complete(GifLibraryResult.saved);
        await tester.pump();
        expect(find.text('Saved to your GIFs'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
