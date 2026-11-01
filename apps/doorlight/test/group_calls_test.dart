import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/group_calls.dart';

void main() {
  group('GroupConferenceAddress', () {
    test('creates and parses a room conference id', () {
      final address = GroupConferenceAddress.create(
        roomId: 'voice-chat',
        randomSuffix: '1844674407370955161',
      );

      expect(address.conferenceId, 'syblv1-voice-chat-1844674407370955161');
      expect(
        GroupConferenceAddress.tryParse(address.conferenceId)?.roomId,
        'voice-chat',
      );
    });

    test('rejects malformed or foreign conference ids', () {
      for (final value in [
        '',
        '123',
        'syblv2-voice-1',
        'syblv1-Voice-1',
        'syblv1-voice-0',
        'syblv1-voice-not-a-number',
        'syblv1-${'a' * 33}-1',
      ]) {
        expect(GroupConferenceAddress.tryParse(value), isNull, reason: value);
      }
    });

    test('uses Jami active-call order and skips failed calls', () {
      const calls = [
        GroupActiveCall(
          conferenceId: 'syblv1-games-9',
          hostUri: 'c',
          hostDevice: '1',
        ),
        GroupActiveCall(
          conferenceId: 'syblv1-voice-8',
          hostUri: 'a',
          hostDevice: '3',
        ),
        GroupActiveCall(
          conferenceId: 'syblv1-voice-9',
          hostUri: 'b',
          hostDevice: '2',
        ),
        GroupActiveCall(
          conferenceId: 'ordinary-jami-call',
          hostUri: 'a',
          hostDevice: '1',
        ),
      ];

      expect(
        GroupConferenceAddress.chooseCanonical(calls, roomId: 'voice'),
        const GroupActiveCall(
          conferenceId: 'syblv1-voice-9',
          hostUri: 'b',
          hostDevice: '2',
        ),
      );
      expect(
        GroupConferenceAddress.chooseCanonical(
          calls,
          roomId: 'voice',
          excludedConferenceIds: const {'syblv1-voice-9'},
        ),
        const GroupActiveCall(
          conferenceId: 'syblv1-voice-8',
          hostUri: 'a',
          hostDevice: '3',
        ),
      );
    });
  });

  group('GroupCallPresence', () {
    final joined = GroupCallPresence(
      conversationId: 'a' * 40,
      roomId: 'voice',
      conferenceId: 'syblv1-voice-42',
      accountId: 'b' * 40,
      sessionId: 'device-session-1',
      sequence: 3,
      joined: true,
      muted: true,
      deafened: false,
      video: false,
      screenShare: false,
      speaking: false,
    );

    test('round trips a bounded trusted message', () {
      expect(
        GroupCallPresence.decode(
          joined.encode(),
          senderAccountId: 'b' * 40,
          conversationId: 'a' * 40,
          voiceRoomIds: const {'voice'},
        ),
        joined,
      );
    });

    test('rejects the wrong sender group room or conference', () {
      expect(
        GroupCallPresence.decode(
          joined.encode(),
          senderAccountId: 'c' * 40,
          conversationId: 'a' * 40,
          voiceRoomIds: const {'voice'},
        ),
        isNull,
      );
      expect(
        GroupCallPresence.decode(
          joined.encode(),
          senderAccountId: 'b' * 40,
          conversationId: 'c' * 40,
          voiceRoomIds: const {'voice'},
        ),
        isNull,
      );
      expect(
        GroupCallPresence.decode(
          joined.encode(),
          senderAccountId: 'b' * 40,
          conversationId: 'a' * 40,
          voiceRoomIds: const {'games'},
        ),
        isNull,
      );
      expect(
        GroupCallPresence.decode(
          joined.copyWith(conferenceId: 'syblv1-games-42').encode(),
          senderAccountId: 'b' * 40,
          conversationId: 'a' * 40,
          voiceRoomIds: const {'voice'},
        ),
        isNull,
      );
    });

    test('rejects malformed and oversized messages', () {
      expect(
        GroupCallPresence.decode(
          '{}',
          senderAccountId: 'b' * 40,
          conversationId: 'a' * 40,
          voiceRoomIds: const {'voice'},
        ),
        isNull,
      );
      expect(
        GroupCallPresence.decode(
          'x' * (GroupCallPresence.maxPayloadBytes + 1),
          senderAccountId: 'b' * 40,
          conversationId: 'a' * 40,
          voiceRoomIds: const {'voice'},
        ),
        isNull,
      );
    });
  });

  group('GroupCallPresenceBook', () {
    GroupCallPresence presence({
      required String session,
      required int sequence,
      String? conversationId,
      String? accountId,
      bool joined = true,
      bool muted = false,
    }) => GroupCallPresence(
      conversationId: conversationId ?? 'a' * 40,
      roomId: 'voice',
      conferenceId: 'syblv1-voice-42',
      accountId: accountId ?? 'b' * 40,
      sessionId: session,
      sequence: sequence,
      joined: joined,
      muted: muted,
      deafened: false,
      video: false,
      screenShare: false,
      speaking: false,
    );

    test('one member cannot fill the book with new session identifiers', () {
      final book = GroupCallPresenceBook();
      for (var i = 0; i < 32; i++) {
        expect(
          book.accept(presence(session: 'session-$i', sequence: 1), 100),
          isTrue,
        );
      }
      expect(
        book.accept(presence(session: 'session-overflow', sequence: 1), 100),
        isFalse,
      );
      expect(
        book.accept(
          presence(session: 'session-0', sequence: 2, joined: false),
          101,
        ),
        isTrue,
      );
      expect(
        book.accept(presence(session: 'session-0', sequence: 1), 102),
        isFalse,
      );
      expect(
        book.accept(presence(session: 'session-overflow', sequence: 1), 102),
        isFalse,
      );
      expect(
        book.accept(
          presence(session: 'other-member', sequence: 1, accountId: 'c' * 40),
          101,
        ),
        isTrue,
      );
      expect(
        book.accept(presence(session: 'session-overflow', sequence: 1), 45102),
        isTrue,
      );
      expect(book.participants('a' * 40, 'voice', nowMs: 45102), hasLength(1));
    });

    test(
      'aggregate session limit preserves updates and rejects new members until expiry',
      () {
        final book = GroupCallPresenceBook();
        for (var i = 0; i < 1024; i++) {
          expect(
            book.accept(
              presence(
                session: 'session-$i',
                sequence: 1,
                accountId: i.toRadixString(16).padLeft(40, '0'),
              ),
              100,
            ),
            isTrue,
          );
        }
        expect(
          book.accept(presence(session: 'overflow', sequence: 1), 100),
          isFalse,
        );
        expect(
          book.accept(
            presence(
              session: 'session-0',
              sequence: 2,
              accountId: '0' * 40,
              joined: false,
            ),
            101,
          ),
          isTrue,
        );
        expect(
          book.accept(presence(session: 'overflow', sequence: 1), 45102),
          isTrue,
        );
        expect(
          book.participants('a' * 40, 'voice', nowMs: 45102),
          hasLength(1),
        );
      },
    );

    test('ignores old sequence values and expires by arrival time', () {
      final book = GroupCallPresenceBook();
      expect(
        book.accept(presence(session: 'session-1', sequence: 2), 100),
        isTrue,
      );
      expect(
        book.accept(presence(session: 'session-1', sequence: 1), 101),
        isFalse,
      );
      expect(book.participants('a' * 40, 'voice', nowMs: 45100).length, 1);
      expect(book.participants('a' * 40, 'voice', nowMs: 45101), isEmpty);
    });

    test('a leave removes only its session for the account', () {
      final book = GroupCallPresenceBook();
      book.accept(presence(session: 'session-1', sequence: 1), 100);
      book.accept(
        presence(session: 'session-2', sequence: 1, muted: true),
        101,
      );
      book.accept(
        presence(session: 'session-1', sequence: 2, joined: false),
        102,
      );

      final participants = book.participants('a' * 40, 'voice', nowMs: 110);
      expect(participants, hasLength(1));
      expect(participants.single.accountId, 'b' * 40);
      expect(participants.single.muted, isTrue);
    });

    test('same-named rooms keep participants inside their group', () {
      final book = GroupCallPresenceBook();
      book.accept(
        presence(session: 'group-a', sequence: 1, accountId: 'b' * 40),
        100,
      );
      book.accept(
        presence(
          session: 'group-c',
          sequence: 1,
          conversationId: 'c' * 40,
          accountId: 'd' * 40,
        ),
        101,
      );

      final groupA = book.participants('a' * 40, 'voice', nowMs: 110);
      final groupC = book.participants('c' * 40, 'voice', nowMs: 110);
      expect(groupA.map((item) => item.accountId), ['b' * 40]);
      expect(groupC.map((item) => item.accountId), ['d' * 40]);
    });

    test('prune reports when the last remote session expires', () {
      final book = GroupCallPresenceBook();
      book.accept(presence(session: 'session-1', sequence: 1), 10);

      expect(book.prune(nowMs: 45010), isFalse);
      expect(book.prune(nowMs: 45011), isTrue);
      expect(book.isEmpty, isTrue);
    });
  });

  group('GroupCallRecovery', () {
    test('uses a stable account based recovery delay', () {
      expect(
        GroupCallRecovery.delayMs('01234567${'a' * 32}', 1),
        GroupCallRecovery.delayMs('01234567${'a' * 32}', 1),
      );
      expect(
        GroupCallRecovery.delayMs('0' * 40, 0),
        inInclusiveRange(250, 999),
      );
      expect(
        GroupCallRecovery.delayMs('f' * 40, 2),
        inInclusiveRange(2250, 2999),
      );
    });
  });

  group('GroupConferenceSnapshot', () {
    test(
      'rejects oversized and duplicate metadata without partial participants',
      () {
        final row = <String, String>{
          'uri': 'a' * 40,
          'device': 'b' * 64,
          'sinkId': 'video',
        };
        expect(GroupConferenceSnapshot.fromWire([row]).streams, hasLength(1));
        expect(GroupConferenceSnapshot.fromWire([row, row]).streams, isEmpty);
        expect(
          GroupConferenceSnapshot.fromWire([
            row,
            {...row, 'uri': 'jami:${'a' * 40}@ring.dht'},
          ]).streams,
          isEmpty,
        );
        for (final records in [
          List.filled(129, row),
          [
            {...row, 'name': 'x' * 1025},
          ],
          [
            {...row, 'name': '界' * 400},
          ],
          List.generate(
            3,
            (_) => {for (var i = 0; i < 32; i++) 'k$i': 'x' * 1024},
          ),
          [
            {for (var i = 0; i < 33; i++) 'k$i': 'x'},
          ],
        ]) {
          expect(GroupConferenceSnapshot.fromWire(records).streams, isEmpty);
        }
      },
    );

    test('uses stable stream keys and rejects malformed entries', () {
      final snapshot = GroupConferenceSnapshot.fromWire([
        {
          'uri': '${'b' * 40}@ring.dht',
          'device': 'd' * 64,
          'sinkId': 'leg-video_0',
          'w': '1280',
          'h': '720',
          'videoMuted': 'false',
          'voiceActivity': 'true',
          'active': 'true',
        },
        {'uri': 'bad', 'device': '', 'sinkId': ''},
      ]);

      expect(snapshot.streams, hasLength(1));
      expect(
        snapshot.streams.single.key,
        '${'b' * 40}\u0000${'d' * 64}\u0000leg-video_0',
      );
      expect(snapshot.streams.single.hasVideo, isTrue);
      expect(snapshot.streams.single.aspectRatio, closeTo(16 / 9, .001));
      expect(snapshot.primary?.accountId, 'b' * 40);
    });

    test('orders active video, speaking video, then stable identity', () {
      Map<String, String> stream(
        String account, {
        bool active = false,
        bool speaking = false,
        bool muted = false,
      }) => {
        'uri': account,
        'device': account.substring(0, 8),
        'sinkId': '$account-video_0',
        'w': '640',
        'h': '480',
        'videoMuted': '$muted',
        'voiceActivity': '$speaking',
        'active': '$active',
      };

      final snapshot = GroupConferenceSnapshot.fromWire([
        stream('c' * 40),
        stream('b' * 40, speaking: true),
        stream('a' * 40, active: true),
        stream('d' * 40, active: true, muted: true),
      ]);

      expect(snapshot.videoStreams.map((item) => item.accountId), [
        'a' * 40,
        'b' * 40,
        'c' * 40,
      ]);
      expect(snapshot.primary?.accountId, 'a' * 40);
    });
  });
}
