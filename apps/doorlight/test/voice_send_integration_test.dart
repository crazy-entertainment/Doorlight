import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/state/composer_draft.dart';
import 'package:sybl/state/composer_media.dart';

class _NativePublication extends JamiClient {
  final submissions = <Map<String, String>>[];

  @override
  Future<String> sendOwnedFile({
    required String accountId,
    required String peerJamiId,
    required String conversationId,
    required String path,
    required String operationId,
    String name = '',
    String topicId = '',
    String roomId = '',
    String media = '',
  }) async {
    submissions.add({
      'account': accountId,
      'peer': peerJamiId,
      'conversation': conversationId,
      'path': path,
      'operation': operationId,
      'topic': topicId,
      'room': roomId,
      'media': media,
    });
    // Exercise real AppState admission/journaling without claiming a daemon commit.
    return 'failed-before-commit';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final variant in [
    'valid',
    'wrong metadata',
    'wrong size',
    'missing file',
  ]) {
    test('real voice send validates completed media: $variant', () async {
      SharedPreferences.setMockInitialValues({});
      final native = _NativePublication();
      final state = AppState(native, await SharedPreferences.getInstance())
        ..accountId = 'account'
        ..jamiId = 'a' * 40;
      addTearDown(state.dispose);
      state.seedEmptyRuntimeSnapshotForTesting(
        friends: const [],
        groups: const [
          GroupState(
            conversationId: 'group',
            title: 'Group',
            memberCount: 1,
            canManageMembers: true,
            memberIds: [],
            activeMemberIds: {},
            invitedMemberIds: {},
          ),
        ],
        selectedFixtureGroupId: 'group',
      );
      final file = File('test/fixtures/voice-aac-lc.m4a').absolute;
      final validated = (await validateComposerVoice(
        file.path,
        await file.length(),
      ))!;
      final stage = ComposerMediaStage(
        kind: ComposerMediaKind.voice,
        label: validated.label,
        encodedBytes:
            validated.encodedBytes + (variant == 'wrong size' ? 1 : 0),
        path: variant == 'missing file' ? '${file.path}.missing' : file.path,
        mediaMetadata: variant == 'wrong metadata'
            ? '{}'
            : validated.mediaMetadata,
      );
      final owner = Object();
      final draft = ComposerDraftSession(
        ComposerDraftKey(state.selectedConversationScope!, 'general'),
      )..activate(owner);
      draft.updateText(owner, const TextEditingValue(text: 'retain my text'));
      final preparation = draft.begin(ComposerOperationKind.recording, owner)!;
      expect(draft.replaceMedia(preparation, stage), isTrue);
      final operation = draft.begin(ComposerOperationKind.sendMedia, owner)!;
      final result = await state.sendComposerFile(draft, operation);
      expect(draft.text.text, 'retain my text');
      if (variant == 'valid') {
        expect(native.submissions, hasLength(1));
        expect(native.submissions.single['media'], validated.mediaMetadata);
        expect(native.submissions.single['room'], 'general');
        expect(native.submissions.single['topic'], '');
        expect(native.submissions.single['operation'], operation.id);
        expect(result?.status, ComposerSendStatus.failedBeforeCommit);
      } else {
        expect(native.submissions, isEmpty);
        expect(state.sendJournal.record(operation.id), isNull);
        expect(result, isNull);
      }
    });
  }
}
