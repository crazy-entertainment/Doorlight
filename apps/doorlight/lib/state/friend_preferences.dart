/// Local preferences use a native account owner and a canonical Jami peer.
/// They do not create a contact, conversation, or trust relationship.
final class FriendPreferenceScope {
  FriendPreferenceScope({required this.accountId, required String peerId})
    : peerId = peerId.toLowerCase() {
    if (accountId.isEmpty ||
        accountId.length > 128 ||
        accountId.trim() != accountId ||
        accountId.runes.any((value) => value < 32 || value == 127)) {
      throw ArgumentError.value(accountId, 'accountId');
    }
    if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(this.peerId)) {
      throw ArgumentError.value(peerId, 'peerId');
    }
  }

  final String accountId;
  final String peerId;

  Map<String, Object?> toMap() => {'accountId': accountId, 'peerId': peerId};

  static FriendPreferenceScope fromMap(Map value) {
    final account = value['accountId'];
    final peer = value['peerId'];
    if (account is! String || peer is! String) {
      throw const FormatException('invalid friend preference owner');
    }
    try {
      return FriendPreferenceScope(accountId: account, peerId: peer);
    } on ArgumentError {
      throw const FormatException('invalid friend preference owner');
    }
  }

  @override
  bool operator ==(Object other) =>
      other is FriendPreferenceScope &&
      accountId == other.accountId &&
      peerId == other.peerId;

  @override
  int get hashCode => Object.hash(accountId, peerId);
}

enum FriendHologramPreference { useGlobalDefault, allow, block }

enum FriendMessageAlertPreference { useGlobalDefault, mute }

final class FriendPreferences {
  const FriendPreferences({
    this.holograms = FriendHologramPreference.useGlobalDefault,
    this.messageAlerts = FriendMessageAlertPreference.useGlobalDefault,
  });

  final FriendHologramPreference holograms;
  final FriendMessageAlertPreference messageAlerts;

  bool get isDefault =>
      holograms == FriendHologramPreference.useGlobalDefault &&
      messageAlerts == FriendMessageAlertPreference.useGlobalDefault;

  /// This resolves only the user's preference, never runtime presentation authority.
  bool allowsHolograms(bool globalDefault) => switch (holograms) {
    FriendHologramPreference.useGlobalDefault => globalDefault,
    FriendHologramPreference.allow => true,
    FriendHologramPreference.block => false,
  };

  bool allowsMessageAlerts(bool globalDefault) =>
      globalDefault && messageAlerts != FriendMessageAlertPreference.mute;

  FriendPreferences copyWith({
    FriendHologramPreference? holograms,
    FriendMessageAlertPreference? messageAlerts,
  }) => FriendPreferences(
    holograms: holograms ?? this.holograms,
    messageAlerts: messageAlerts ?? this.messageAlerts,
  );

  Map<String, Object?> toMap() => {
    'holograms': holograms.name,
    'messageAlerts': messageAlerts.name,
  };

  static FriendPreferences fromMap(Map value) {
    final holograms = switch (value['holograms']) {
      'useGlobalDefault' => FriendHologramPreference.useGlobalDefault,
      'allow' => FriendHologramPreference.allow,
      'block' => FriendHologramPreference.block,
      _ => throw const FormatException('invalid friend Hologram preference'),
    };
    final alerts = switch (value['messageAlerts']) {
      'useGlobalDefault' => FriendMessageAlertPreference.useGlobalDefault,
      'mute' => FriendMessageAlertPreference.mute,
      _ => throw const FormatException(
        'invalid friend message alert preference',
      ),
    };
    return FriendPreferences(holograms: holograms, messageAlerts: alerts);
  }

  @override
  bool operator ==(Object other) =>
      other is FriendPreferences &&
      holograms == other.holograms &&
      messageAlerts == other.messageAlerts;

  @override
  int get hashCode => Object.hash(holograms, messageAlerts);
}
