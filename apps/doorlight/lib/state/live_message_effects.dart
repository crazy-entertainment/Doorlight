import 'conversation_scope.dart';

/// A bounded recent-event window, not a permanent history or trust decision.
class LiveMessageEffects {
  static const capacity = 32768;
  final _recent = <(ConversationScope, String)>{};

  bool admit(ConversationScope scope, String messageId) {
    final key = (scope, messageId);
    if (!_recent.add(key)) return false;
    if (_recent.length > capacity) _recent.remove(_recent.first);
    return true;
  }

  void clear() => _recent.clear();
}
