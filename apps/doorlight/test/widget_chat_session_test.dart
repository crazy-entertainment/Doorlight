import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/conversation_scope.dart';
import 'package:sybl/state/widget_chat_session.dart';

void main() {
  test('widget tokens are bounded opaque URL-safe handles', () {
    final first = createWidgetToken();
    final second = createWidgetToken();

    expect(first, hasLength(32));
    expect(first, matches(RegExp(r'^[A-Za-z0-9_-]{32}$')));
    expect(second, isNot(first));
  });

  test('conversation list records never serialize Jami routing identity', () {
    final entry = WidgetChatConversation(
      token: createWidgetToken(),
      scope: ConversationScope(
        accountId: 'account-secret',
        peerId: 'peer-secret',
        conversationId: 'conversation-secret',
      ),
      label: 'Sam',
      kind: 'direct',
      draftKey: createWidgetToken(),
    );

    expect(entry.toMap(), {
      'id': entry.token,
      'label': 'Sam',
      'kind': 'direct',
      'draftKey': entry.draftKey,
    });
    expect(entry.toMap().values, isNot(contains('account-secret')));
    expect(entry.toMap().values, isNot(contains('peer-secret')));
    expect(entry.toMap().values, isNot(contains('conversation-secret')));
  });

  test(
    'remote voice meter requires the current account call revision and stream',
    () {
      bool trusted({
        String account = 'account',
        String call = 'call-1',
        String revision = '7',
        String stream = 'call-1_AUDIO',
        double? level = .1,
      }) => isTrustedWidgetRemoteAudioMeter(
        expectedAccountId: 'account',
        eventAccountId: account,
        expectedCallId: 'call-1',
        eventCallId: call,
        expectedNativeRevision: '7',
        eventNativeRevision: revision,
        eventStreamId: stream,
        level: level,
      );

      expect(trusted(), isTrue);
      expect(trusted(account: 'other'), isFalse);
      expect(trusted(call: 'call-2'), isFalse);
      expect(trusted(revision: '8'), isFalse);
      expect(trusted(stream: 'call-1_AUDIO'), isTrue);
      expect(trusted(stream: 'other_AUDIO'), isFalse);
      expect(trusted(stream: 'call-1_audio/other'), isFalse);
      expect(trusted(level: double.nan), isFalse);
      expect(trusted(level: 1.01), isFalse);
      expect(isWidgetNativeRevision('123'), isTrue);
      expect(isWidgetNativeRevision('1;other'), isFalse);
    },
  );

  test(
    'remote voice speaking expires to unknown and uses the RMS threshold',
    () {
      final sampledAt = DateTime.utc(2026, 1, 1);

      expect(
        widgetRemoteSpeakingAt(
          level: .0199,
          sampledAt: sampledAt,
          now: sampledAt.add(const Duration(milliseconds: 999)),
        ),
        isFalse,
      );
      expect(
        widgetRemoteSpeakingAt(
          level: .02,
          sampledAt: sampledAt,
          now: sampledAt.add(const Duration(milliseconds: 999)),
        ),
        isTrue,
      );
      expect(
        widgetRemoteSpeakingAt(
          level: .8,
          sampledAt: sampledAt,
          now: sampledAt.add(const Duration(seconds: 1)),
        ),
        isNull,
      );
      expect(
        widgetRemoteSpeakingAt(
          level: .8,
          sampledAt: sampledAt,
          now: sampledAt.subtract(const Duration(milliseconds: 1)),
        ),
        isNull,
      );
    },
  );
}
