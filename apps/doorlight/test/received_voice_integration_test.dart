import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/state/composer_media.dart';
import 'package:sybl/state/conversation_timeline.dart';
import 'app_state_test.dart' as fixture;

class _Native extends fixture.FakeJami {
  Map<String, dynamic> receipt = {};
  Future<Map<String, dynamic>> Function()? readReceipt;
  @override
  Future<Map<String, dynamic>> fileInfo(
    String peer,
    String conversation,
    String file,
  ) async => readReceipt == null ? receipt : readReceipt!();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final variant in [
    'valid',
    'no receipt',
    'wrong path',
    'wrong size',
    'lock during receipt',
    'replacement during validation',
    'wrong metadata',
  ]) {
    test(
      'incoming voice checks actual format and native receipt: $variant',
      () async {
        SharedPreferences.setMockInitialValues({
          'displayName': 'Me',
          'accountId': 'acc1',
        });
        final native = _Native();
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
        final file = File('test/fixtures/voice-aac-lc.m4a').absolute;
        final size = await file.length();
        final stage = (await validateComposerVoice(file.path, size))!;
        final metadata = variant == 'wrong metadata'
            ? '{"v":1,"kind":"voice","codec":"aac-lc","container":"m4a","durationMs":120000}'
            : stage.mediaMetadata!;
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
            'authorId': peer,
            'timestampSeconds': 1700000000,
            'mediaMetadata': metadata,
            'body': {
              'fileId': 'voice-file',
              'displayName': 'Voice message.m4a',
              'totalBytes': size,
              'downloaded': true,
            },
          },
        });
        await Future<void>.delayed(Duration.zero);
        final item = state.conversationTimeline!.items
            .whereType<TimelineFileItem>()
            .single;
        native.receipt = {
          'completed': variant != 'no receipt',
          'path': variant == 'wrong path' ? '${file.path}.other' : file.path,
          'total': size + (variant == 'wrong size' ? 1 : 0),
        };
        var reads = 0;
        native.readReceipt = () async {
          reads++;
          if (variant == 'lock during receipt') {
            state.setProtectedSurfaceLocked(true);
          }
          if (variant == 'replacement during validation' && reads > 1) {
            return {};
          }
          return native.receipt;
        };
        expect(
          await state.validateTimelineMedia(item, file.path),
          variant == 'valid',
        );
        if (variant == 'valid' || variant == 'replacement during validation') {
          expect(reads, 2);
        }
      },
    );
  }
}
