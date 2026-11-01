import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/app_settings.dart';
import 'package:sybl/state/conversation_scope.dart';

void main() {
  test(
    'encoded overrides sort by account then peer without reordering settings',
    () {
      final owners = [
        FriendPreferenceScope(accountId: 'b', peerId: 'a' * 40),
        FriendPreferenceScope(accountId: 'a', peerId: 'b' * 40),
        FriendPreferenceScope(accountId: 'a', peerId: 'a' * 40),
      ];
      var settings = AppSettings();
      for (final owner in owners) {
        settings = settings.withFriendPreferences(
          owner,
          const FriendPreferences(
            messageAlerts: FriendMessageAlertPreference.mute,
          ),
        );
      }
      final encoded = const AppSettingsCodec().encode(settings);
      final preferences = encoded['friendPreferences'] as Map;
      final overrides = preferences['overrides'] as List;
      expect(
        overrides.map((entry) => FriendPreferenceScope.fromMap(entry)),
        owners.reversed,
      );
      expect(settings.friendPreferences.keys, owners);
    },
  );

  test(
    'account owners preserve the canonical Unicode and control boundary',
    () {
      for (final account in [
        '',
        ' owner',
        'owner ',
        'ow\u0001ner',
        'owner\u007f',
        '\u0085owner',
        '\u00a0owner',
        'owner\ufeff',
        'a' * 129,
      ]) {
        expect(
          () => FriendPreferenceScope(accountId: account, peerId: 'a' * 40),
          throwsArgumentError,
        );
      }
      for (final account in ['a' * 128, '\u00e9' * 128]) {
        final scope = FriendPreferenceScope(
          accountId: account,
          peerId: 'a' * 40,
        );
        final original = AppSettings().withFriendPreferences(
          scope,
          const FriendPreferences(
            holograms: FriendHologramPreference.block,
            messageAlerts: FriendMessageAlertPreference.mute,
          ),
        );
        final decoded = const AppSettingsCodec()
            .decode(const AppSettingsCodec().encode(original))
            .settings;
        expect(decoded.allowsFriendHolograms(scope), isFalse);
        expect(decoded.allowsFriendMessageAlerts(scope), isFalse);
      }
    },
  );

  test(
    'explicit review reset clears ambiguous scopes while keeping both defaults off',
    () {
      final original =
          AppSettings(
            friendPreferencesReviewRequired: true,
            globalMicrophoneMode: MicrophoneMode.pushToTalk,
          ).withFriendPreferences(
            FriendPreferenceScope(accountId: 'old', peerId: 'a' * 40),
            const FriendPreferences(holograms: FriendHologramPreference.allow),
          );
      final reset = original.resetUnreviewedFriendPreferences();
      expect(reset.friendPreferencesReviewRequired, isFalse);
      expect(reset.friendPreferences, isEmpty);
      expect(reset.messageAlertsEnabled, isFalse);
      expect(reset.hologramPresentationEnabled, isFalse);
      expect(reset.globalMicrophoneMode, MicrophoneMode.pushToTalk);
    },
  );
  final peer = 'a' * 40;
  FriendPreferenceScope scope(String owner) =>
      FriendPreferenceScope(accountId: owner, peerId: peer);
  const blocked = FriendPreferences(
    holograms: FriendHologramPreference.block,
    messageAlerts: FriendMessageAlertPreference.mute,
  );
  const allowed = FriendPreferences(holograms: FriendHologramPreference.allow);
  const codec = AppSettingsCodec();

  test('all Hologram and message alert choices resolve independently', () {
    for (final global in [false, true]) {
      for (final holograms in FriendHologramPreference.values) {
        for (final alerts in FriendMessageAlertPreference.values) {
          final preference = FriendPreferences(
            holograms: holograms,
            messageAlerts: alerts,
          );
          expect(preference.allowsHolograms(global), switch (holograms) {
            FriendHologramPreference.useGlobalDefault => global,
            FriendHologramPreference.allow => true,
            FriendHologramPreference.block => false,
          });
          expect(
            preference.allowsMessageAlerts(global),
            global && alerts == FriendMessageAlertPreference.useGlobalDefault,
          );
        }
      }
    }
  });

  test('canonical peer scopes never cross account owners', () {
    expect(
      scope('a'),
      FriendPreferenceScope(accountId: 'a', peerId: peer.toUpperCase()),
    );
    expect(scope('a'), isNot(scope('b')));
    for (final invalid in [
      '',
      'group:$peer',
      'jami:$peer',
      '$peer ',
      'g' * 40,
    ]) {
      expect(
        () => FriendPreferenceScope(accountId: 'a', peerId: invalid),
        throwsArgumentError,
      );
    }
    final settings = AppSettings().withFriendPreferences(scope('a'), blocked);
    expect(settings.allowsFriendHolograms(scope('a')), isFalse);
    expect(settings.allowsFriendHolograms(scope('b')), isTrue);
    expect(settings.allowsFriendMessageAlerts(scope('a')), isFalse);
    expect(settings.allowsFriendMessageAlerts(scope('b')), isTrue);
  });

  test('settings preserve overrides and reset removes them', () {
    final settings = AppSettings(messageAlertsEnabled: false)
        .withFriendPreferences(scope('a'), allowed)
        .withFriendPreferences(scope('b'), blocked);
    final decoded = codec.decode(codec.encode(settings));
    expect(decoded.settings, settings);
    expect(decoded.settings.hashCode, settings.hashCode);
    expect(decoded.needsRewrite, isFalse);
    expect(
      settings
          .withFriendPreferences(scope('a'), const FriendPreferences())
          .friendPreferences
          .containsKey(scope('a')),
      isFalse,
    );
    expect(() => settings.friendPreferences.clear(), throwsUnsupportedError);
  });

  test(
    'schema 16 migrates to prior defaults without importing future fields',
    () {
      final document = codec.encode(
        AppSettings().withFriendPreferences(scope('a'), blocked),
      )..['schemaVersion'] = 16;
      final decoded = codec.decode(document);
      expect(decoded.needsRewrite, isTrue);
      expect(decoded.settings.friendPreferences, isEmpty);
      expect(decoded.settings.messageAlertsEnabled, isTrue);
    },
  );

  test(
    'corrupt or duplicate overrides do not fall back to permissive defaults',
    () {
      for (final entries in [
        [
          {'accountId': 'a', 'peerId': peer, 'holograms': 'allow'},
        ],
        [
          {
            'accountId': 'a',
            'peerId': peer,
            'holograms': 'unknown',
            'messageAlerts': 'mute',
          },
        ],
        [
          {...scope('a').toMap(), ...allowed.toMap()},
          {
            ...scope('a').toMap(),
            'peerId': peer.toUpperCase(),
            ...blocked.toMap(),
          },
        ],
        List.filled(257, {...scope('a').toMap(), ...allowed.toMap()}),
      ]) {
        final document = codec.encode(AppSettings());
        document['friendPreferences'] = {
          'reviewRequired': false,
          'overrides': entries,
        };
        expect(() => codec.decode(document), throwsFormatException);
      }
    },
  );

  test(
    'restore remaps only an established source even without microphone overrides',
    () {
      final restored = AppSettings()
          .withFriendPreferences(scope('source'), blocked)
          .withFriendPreferences(scope('unrelated'), allowed)
          .forRestoredAccount(
            sourceAccountId: 'source',
            accountId: 'destination',
          );
      expect(restored.friendPreferences[scope('destination')], blocked);
      expect(restored.friendPreferences[scope('unrelated')], allowed);
      expect(restored.friendPreferences.containsKey(scope('source')), isFalse);
      expect(restored.friendPreferencesReviewRequired, isFalse);
    },
  );

  test(
    'ambiguous owner and collisions preserve entries and suppress presentation and alerts',
    () {
      final original = AppSettings()
          .withFriendPreferences(scope('source'), blocked)
          .withFriendPreferences(scope('destination'), allowed);
      for (final source in <String?>[null, '', 'source']) {
        final restored = original.forRestoredAccount(
          sourceAccountId: source,
          accountId: 'destination',
        );
        expect(restored.friendPreferences, original.friendPreferences);
        expect(restored.friendPreferencesReviewRequired, isTrue);
        expect(restored.allowsFriendHolograms(scope('destination')), isFalse);
        expect(restored.allowsFriendMessageAlerts(scope('new-owner')), isFalse);
        expect(codec.decode(codec.encode(restored)).settings, restored);
      }
    },
  );

  test(
    'microphone owner collision also prevents unreviewed friend policy admission',
    () {
      final settings = AppSettings(
        conversationMicrophoneModes: {
          ConversationScope(
            accountId: 'source',
            peerId: peer,
            conversationId: 'c',
          ): MicrophoneMode.open,
          ConversationScope(
            accountId: 'destination',
            peerId: peer,
            conversationId: 'c',
          ): MicrophoneMode.pushToTalk,
        },
      ).withFriendPreferences(scope('destination'), allowed);
      final restored = settings.forRestoredAccount(
        sourceAccountId: 'source',
        accountId: 'destination',
      );
      expect(restored.microphoneReviewRequired, isTrue);
      expect(restored.friendPreferencesReviewRequired, isTrue);
      expect(restored.allowsFriendHolograms(scope('destination')), isFalse);
    },
  );
}
