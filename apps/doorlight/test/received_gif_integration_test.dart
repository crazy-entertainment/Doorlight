import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/state/composer_media.dart';
import 'package:sybl/state/conversation_timeline.dart';
import 'package:sybl/state/gif_library_store.dart';
import 'app_state_test.dart' as fixture;
import 'gif_validation_test.dart' show gif;

class _Native extends fixture.FakeJami {
  _Native(this.library);
  final String library;
  Future<Map<String, dynamic>> Function()? receipt;
  @override
  Future<String?> gifLibraryDirectory() async => library;
  @override
  Future<Map<String, dynamic>> fileInfo(
    String peer,
    String conversation,
    String file,
  ) async => receipt == null ? {} : receipt!();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final variant in [
    'valid',
    'ordinary GIF',
    'bundled',
    'no receipt',
    'wrong path',
    'wrong size',
    'outgoing',
    'lock during receipt',
    'replaced after decode',
    'removed before publish',
    'wrong metadata',
    'invalid bytes',
    'corrupt library',
  ]) {
    test(
      'saving received GIF keeps owned source and native authority: $variant',
      () async {
        final scratch = await Directory(
          '../../local/tmp',
        ).createTemp('received-gif-');
        addTearDown(() => scratch.delete(recursive: true));
        SharedPreferences.setMockInitialValues({
          'displayName': 'Me',
          'accountId': 'acc1',
        });
        final native = _Native('${scratch.path}/library');
        final peer = 'b' * 40;
        final conversation = 'e' * 40;
        native.daemonFriends[peer] = JamiFriend(
          peerJamiId: peer,
          confirmed: true,
          conversationId: conversation,
        );
        final state = AppState(native, await SharedPreferences.getInstance());
        addTearDown(state.dispose);
        await state.init();
        await state.selectFriend(peer);
        final file = await File('${scratch.path}/owned-received.gif')
            .writeAsBytes(
              variant == 'bundled'
                  ? await File('assets/gifs/doorlight/hello.gif').readAsBytes()
                  : gif(frames: 3),
            );
        final source = await file.readAsBytes();
        final size = source.length;
        final stage = (await validateComposerGif(file.path, size))!;
        if (variant == 'invalid bytes') {
          await file.writeAsBytes(List.filled(size, 0));
        }
        if (variant == 'corrupt library') {
          await Directory(native.library).create();
          await File('${native.library}/index.json').writeAsString('{broken');
        }
        native.push('chatMessage', {
          'accountId': 'acc1',
          'peerJamiId': peer,
          'conversationId': conversation,
          'item': {
            'accountId': 'acc1',
            'peerId': peer,
            'conversationId': conversation,
            'daemonId': 'd' * 40,
            'versionId': 'd' * 40,
            'mimeType': TimelineWireContract.fileMimeType,
            'authorId': variant == 'outgoing' ? state.jamiId : peer,
            'timestampSeconds': 1700000000,
            'mediaMetadata': variant == 'ordinary GIF'
                ? null
                : variant == 'wrong metadata'
                ? '{"v":1,"kind":"gif","width":1,"height":1,"frames":2,"cycleMs":40}'
                : stage.mediaMetadata,
            'body': {
              'fileId': 'gif-file',
              'displayName': 'hello.gif',
              'totalBytes': size,
              'downloaded': true,
            },
          },
        });
        await Future<void>.delayed(Duration.zero);
        final item = state.conversationTimeline!.items
            .whereType<TimelineFileItem>()
            .single;
        var reads = 0;
        native.receipt = () async {
          reads++;
          if (variant == 'lock during receipt') {
            state.setProtectedSurfaceLocked(true);
          }
          if (variant == 'replaced after decode' && reads >= 2 ||
              variant == 'removed before publish' && reads >= 3) {
            return {};
          }
          return {
            'completed': variant != 'no receipt',
            'path': variant == 'wrong path' ? '${file.path}.other' : file.path,
            'total': size + (variant == 'wrong size' ? 1 : 0),
          };
        };
        final result = await state.saveReceivedGif(item, file.path);
        if (variant == 'valid' || variant == 'ordinary GIF') {
          expect(result, GifLibraryResult.saved);
          expect(reads, 3);
          expect(
            await state.saveReceivedGif(item, file.path),
            GifLibraryResult.saved,
          );
          expect(state.gifLibrary.index.entries, hasLength(1));
          final hash = state.gifLibrary.index.entries.keys.single;
          expect(await state.gifLibrary.read(hash), source);
          expect(await state.gifLibrary.remove(hash), GifLibraryResult.removed);
        } else if (variant == 'bundled') {
          expect(result, GifLibraryResult.alreadyBundled);
          expect(state.gifLibrary.index.entries, isEmpty);
          expect(reads, 2);
        } else {
          expect(result, isNot(GifLibraryResult.saved));
          expect(state.gifLibrary.index.entries, isEmpty);
        }
        expect(await file.exists(), isTrue);
        if (variant != 'invalid bytes') {
          expect(await file.readAsBytes(), source);
        }
        if (variant == 'corrupt library') {
          expect(
            await File('${native.library}/index.json').readAsString(),
            '{broken',
          );
        }
      },
    );
  }
}
