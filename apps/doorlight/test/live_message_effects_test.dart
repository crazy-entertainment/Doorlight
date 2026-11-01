import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/conversation_scope.dart';
import 'package:sybl/state/live_message_effects.dart';

void main() {
  final scope = ConversationScope(
    accountId: 'account',
    peerId: 'peer',
    conversationId: 'conversation',
  );

  test('new messages continue after the bounded deduplication window fills', () {
    final effects = LiveMessageEffects();
    for (var i = 0; i <= LiveMessageEffects.capacity; i++) {
      expect(effects.admit(scope, '$i'), isTrue);
    }
    expect(effects.admit(scope, '${LiveMessageEffects.capacity}'), isFalse);
    expect(effects.admit(scope, '1'), isFalse);
    // Only the oldest entry expired; this window is not permanent replay storage.
    expect(effects.admit(scope, '0'), isTrue);
  });

  test('deduplication is scoped and can retire an account lifetime', () {
    final effects = LiveMessageEffects();
    expect(effects.admit(scope, 'same'), isTrue);
    expect(effects.admit(scope, 'same'), isFalse);
    expect(
      effects.admit(
        ConversationScope(
          accountId: 'other',
          peerId: 'peer',
          conversationId: 'conversation',
        ),
        'same',
      ),
      isTrue,
    );
    effects.clear();
    expect(effects.admit(scope, 'same'), isTrue);
  });
}
