enum ConversationKind { direct, group }

/// The complete owner tuple for one direct or group conversation.
///
/// None of these identifiers is process-global. Keeping them together prevents
/// state for equal conversation or peer ids from crossing accounts.
final class ConversationScope {
  ConversationScope({
    required this.accountId,
    required this.peerId,
    required this.conversationId,
    ConversationKind? kind,
  }) {
    _requireIdentifier(accountId, 'accountId');
    _requireIdentifier(peerId, 'peerId');
    _requireIdentifier(conversationId, 'conversationId');
    this.kind =
        kind ??
        (peerId.startsWith('group:')
            ? ConversationKind.group
            : ConversationKind.direct);
  }

  final String accountId;
  final String peerId;
  final String conversationId;
  late final ConversationKind kind;

  bool get isGroup => kind == ConversationKind.group;

  Map<String, Object?> toMap() => {
    'accountId': accountId,
    'peerId': peerId,
    'conversationId': conversationId,
    'kind': kind.name,
  };

  static ConversationScope? tryParse(Object? value) {
    if (value is! Map) return null;
    final accountId = value['accountId'];
    final peerId = value['peerId'];
    final conversationId = value['conversationId'];
    if (accountId is! String ||
        peerId is! String ||
        conversationId is! String ||
        accountId.isEmpty ||
        peerId.isEmpty ||
        conversationId.isEmpty) {
      return null;
    }
    return ConversationScope(
      accountId: accountId,
      peerId: peerId,
      conversationId: conversationId,
      kind: value['kind'] == 'group'
          ? ConversationKind.group
          : value['kind'] == 'direct'
          ? ConversationKind.direct
          : null,
    );
  }

  static void _requireIdentifier(String value, String name) {
    if (value.isEmpty) {
      throw ArgumentError.value(value, name, 'must not be empty');
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConversationScope &&
          accountId == other.accountId &&
          peerId == other.peerId &&
          conversationId == other.conversationId &&
          kind == other.kind;

  @override
  int get hashCode => Object.hash(accountId, peerId, conversationId, kind);

  @override
  String toString() =>
      'ConversationScope(accountId: $accountId, peerId: $peerId, '
      'conversationId: $conversationId, kind: ${kind.name})';
}
