import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/app_settings.dart';
import 'package:sybl/state/conversation_scope.dart';
import 'package:sybl/state/identity_color.dart';

void main() {
  test('close animation migrates to tray and round trips every style', () {
    const codec = AppSettingsCodec();
    final original = AppSettings();
    final previous = codec.encode(original)..['schemaVersion'] = 22;
    (previous['appearance']! as Map).remove('windowCloseAnimation');
    final migrated = codec.decode(previous);
    expect(migrated.needsRewrite, isTrue);
    expect(migrated.settings.windowCloseAnimation, WindowCloseAnimation.tray);
    for (final animation in WindowCloseAnimation.values) {
      final changed = original.withWindowCloseAnimation(animation);
      expect(codec.decode(codec.encode(changed)).settings, changed);
      expect(
        changed.withChatMotionEnabled(false).windowCloseAnimation,
        animation,
      );
    }
    expect(
      original.withWindowCloseAnimation(WindowCloseAnimation.door),
      isNot(original),
    );
    for (final invalid in [null, 'unknown', 1]) {
      final document = codec.encode(original);
      document['appearance'] = <String, Object?>{
        ...document['appearance']! as Map,
        'windowCloseAnimation': invalid,
      };
      expect(() => codec.decode(document), throwsFormatException);
    }
  });

  test(
    'window animation settings migrate, round trip, and validate bounds',
    () {
      const codec = AppSettingsCodec();
      final changed = AppSettings()
          .withWindowOpenAnimation(WindowCloseAnimation.fade)
          .withWindowMinimizeAnimation(WindowCloseAnimation.warp)
          .withWindowCloseAnimation(WindowCloseAnimation.door)
          .withWindowOpenDurationMs(100)
          .withWindowMinimizeDurationMs(425)
          .withWindowCloseDurationMs(800);
      final encoded = codec.encode(changed);
      expect(encoded['schemaVersion'], 24);
      expect(codec.decode(encoded).settings, changed);
      expect(codec.decode(encoded).settings.hashCode, changed.hashCode);

      final version23 = codec.encode(
        AppSettings().withWindowCloseAnimation(WindowCloseAnimation.door),
      )..['schemaVersion'] = 23;
      (version23['appearance']! as Map)
        ..remove('windowOpenAnimation')
        ..remove('windowMinimizeAnimation')
        ..remove('windowOpenDurationMs')
        ..remove('windowMinimizeDurationMs')
        ..remove('windowCloseDurationMs');
      final migrated = codec.decode(version23);
      expect(migrated.needsRewrite, isTrue);
      expect(migrated.settings.windowOpenAnimation, WindowCloseAnimation.tray);
      expect(
        migrated.settings.windowMinimizeAnimation,
        WindowCloseAnimation.tray,
      );
      expect(migrated.settings.windowCloseAnimation, WindowCloseAnimation.door);
      expect(migrated.settings.windowOpenDurationMs, 240);
      expect(migrated.settings.windowMinimizeDurationMs, 240);
      expect(migrated.settings.windowCloseDurationMs, 240);

      for (final invalid in [99, 801, 300.5, null, '240']) {
        for (final key in [
          'windowOpenDurationMs',
          'windowMinimizeDurationMs',
          'windowCloseDurationMs',
        ]) {
          final document = codec.encode(changed);
          final appearance = Map<String, Object?>.from(
            document['appearance']! as Map,
          )..[key] = invalid;
          document['appearance'] = appearance;
          expect(() => codec.decode(document), throwsFormatException);
        }
      }
      for (final key in [
        'windowOpenAnimation',
        'windowMinimizeAnimation',
        'windowCloseAnimation',
      ]) {
        final document = codec.encode(changed);
        (document['appearance']! as Map)[key] = 'unrecognized';
        expect(() => codec.decode(document), throwsFormatException);
      }
      expect(
        () => AppSettings().withWindowOpenDurationMs(99),
        throwsArgumentError,
      );
      expect(
        () => AppSettings().withWindowCloseDurationMs(801),
        throwsArgumentError,
      );
    },
  );

  test('vibe opacity migrates, round trips, and rejects invalid values', () {
    const codec = AppSettingsCodec();
    final original = AppSettings();
    final previous = codec.encode(original)..['schemaVersion'] = 20;
    (previous['appearance']! as Map).remove('vibeOpacity');
    final migrated = codec.decode(previous);
    expect(migrated.needsRewrite, isTrue);
    expect(migrated.settings.vibeOpacity, 100);
    for (final opacity in [0, 35, 100]) {
      final changed = original.withVibeOpacity(opacity);
      expect(codec.decode(codec.encode(changed)).settings, changed);
      expect(changed.withAmbientVibe(AmbientVibe.rain).vibeOpacity, opacity);
    }
    expect(original.withVibeOpacity(35), isNot(original));
    expect(
      original.withVibeOpacity(35).hashCode,
      original.withVibeOpacity(35).hashCode,
    );
    for (final invalid in [-1, 101, 30.5, null, '30']) {
      final document = codec.encode(original);
      document['appearance'] = Map<String, Object?>.from(
        document['appearance']! as Map,
      )..['vibeOpacity'] = invalid;
      expect(() => codec.decode(document), throwsFormatException);
    }
    expect(() => original.withVibeOpacity(-1), throwsArgumentError);
    expect(() => original.withVibeOpacity(101), throwsArgumentError);
  });
  test(
    'vibe intensity migrates independently of opacity and validates bounds',
    () {
      const codec = AppSettingsCodec();
      final original = AppSettings().withVibeOpacity(40);
      final old = codec.encode(original)..['schemaVersion'] = 21;
      (old['appearance']! as Map).remove('vibeIntensity');
      final migrated = codec.decode(old);
      expect(migrated.settings.vibeIntensity, 100);
      expect(migrated.settings.vibeOpacity, 40);
      expect(migrated.needsRewrite, isTrue);
      for (final value in [0, 35, 100]) {
        final changed = original.withVibeIntensity(value);
        expect(codec.decode(codec.encode(changed)).settings, changed);
        expect(changed.withAmbientVibe(AmbientVibe.snow).vibeIntensity, value);
        expect(changed.vibeOpacity, 40);
      }
      expect(original.withVibeIntensity(35), isNot(original));
      for (final invalid in [-1, 101, 30.5, null, '30']) {
        final document = codec.encode(original);
        document['appearance'] = Map<String, Object?>.from(
          document['appearance']! as Map,
        )..['vibeIntensity'] = invalid;
        expect(() => codec.decode(document), throwsFormatException);
      }
      expect(() => original.withVibeIntensity(-1), throwsArgumentError);
      expect(() => original.withVibeIntensity(101), throwsArgumentError);
    },
  );
  final scopeA = ConversationScope(
    accountId: 'account',
    peerId: 'peer-a',
    conversationId: 'conversation',
  );
  final scopeB = ConversationScope(
    accountId: 'account',
    peerId: 'peer-b',
    conversationId: 'conversation',
  );

  test(
    'manual identity colors persist and automatic defaults remain automatic',
    () {
      const codec = AppSettingsCodec();
      final automatic = AppSettings();
      expect(automatic.identityColorManual, isFalse);
      expect(codec.decode(codec.encode(automatic)).settings, automatic);
      final manual = automatic.withIdentityColor(IdentityColor.blue);
      expect(manual.identityColorManual, isTrue);
      expect(codec.decode(codec.encode(manual)).settings, manual);
      expect(manual.withChatMotionEnabled(false).identityColorManual, isTrue);
      expect(manual.withIdentityColorManual(false), isNot(manual));
    },
  );

  test('schemas 13 through 17 preserve saved colors as manual', () {
    const codec = AppSettingsCodec();
    for (var version = 13; version <= 17; version++) {
      for (final color in [IdentityColor.amber, IdentityColor.sky]) {
        final document = codec.encode(AppSettings(identityColor: color))
          ..['schemaVersion'] = version;
        (document['profile']! as Map).remove('identityColorManual');
        final decoded = codec.decode(document);
        expect(decoded.settings.identityColor, color);
        expect(decoded.settings.identityColorManual, isTrue);
        expect(decoded.needsRewrite, isTrue);
      }
    }
    final legacy = codec.encode(AppSettings())..['schemaVersion'] = 12;
    legacy.remove('profile');
    expect(codec.decode(legacy).settings.identityColorManual, isFalse);
  });

  test('current schema rejects missing or non-boolean color mode', () {
    const codec = AppSettingsCodec();
    for (final mode in [null, 'true', 1]) {
      final document = codec.encode(AppSettings());
      final profile = document['profile']! as Map;
      if (mode == null) {
        profile.remove('identityColorManual');
      } else {
        profile['identityColorManual'] = mode;
      }
      expect(() => codec.decode(document), throwsFormatException);
    }
  });

  group('ConversationScope', () {
    test('uses the complete account, peer, conversation tuple', () {
      expect(scopeA, isNot(scopeB));
      expect(ConversationScope.tryParse(scopeA.toMap()), scopeA);
      expect(
        ConversationScope.tryParse({
          'accountId': 'account',
          'peerId': 'peer-a',
          'conversationId': '',
        }),
        isNull,
      );
    });

    test('rejects empty identifiers without normalizing opaque values', () {
      expect(
        () => ConversationScope(
          accountId: '',
          peerId: 'peer',
          conversationId: 'conversation',
        ),
        throwsArgumentError,
      );
      final whitespace = ConversationScope(
        accountId: ' account ',
        peerId: ' peer ',
        conversationId: ' conversation ',
      );
      expect(whitespace.accountId, ' account ');
    });
  });

  group('AppSettings', () {
    test('defaults to open and resolves exact-scope overrides', () {
      final defaults = AppSettings();
      expect(defaults.appLockEnabled, isFalse);
      expect(
        defaults.windowsCaptureProtectionEnabled,
        isTrue,
        reason: 'capture protection is conservative-on by default',
      );
      expect(
        defaults.shareActivityPresence,
        isFalse,
        reason: 'active-app sharing is privacy-preserving opt-in',
      );
      expect(defaults.unreadBadgePlacement, UnreadBadgePlacement.avatar);
      expect(defaults.groupHeaderPlacement, GroupHeaderPlacement.conversation);
      expect(defaults.mobileGroupNavigation, MobileGroupNavigation.inline);
      expect(defaults.chatMotionEnabled, isTrue);
      expect(defaults.chatActivityIndicatorsEnabled, isTrue);
      expect(
        defaults.topicStripSurfaceSettings,
        const TopicStripSurfaceSettings(),
      );
      expect(
        defaults.folderHistoryLimit,
        AppSettings.defaultFolderHistoryLimit,
      );
      expect(
        defaults.maxIncomingFileBytes,
        AppSettings.defaultMaxIncomingFileBytes,
      );
      expect(defaults.appearancePreset, AppearancePreset.cozy);
      expect(defaults.identityColor, IdentityColor.amber);
      expect(
        defaults.microphoneModeFor(scopeA),
        const EffectiveMicrophoneMode(
          mode: MicrophoneMode.open,
          source: MicrophoneModeSource.globalDefault,
        ),
      );

      final settings = defaults
          .withGlobalMicrophoneMode(MicrophoneMode.voiceActivated)
          .withConversationMicrophoneMode(scopeA, MicrophoneMode.pushToTalk);
      expect(
        settings.microphoneModeFor(scopeA),
        const EffectiveMicrophoneMode(
          mode: MicrophoneMode.pushToTalk,
          source: MicrophoneModeSource.conversationOverride,
        ),
      );
      expect(
        settings.microphoneModeFor(scopeB),
        const EffectiveMicrophoneMode(
          mode: MicrophoneMode.voiceActivated,
          source: MicrophoneModeSource.globalDefault,
        ),
      );
    });

    test('removes overrides without mutating the prior value', () {
      final original = AppSettings().withConversationMicrophoneMode(
        scopeA,
        MicrophoneMode.pushToTalk,
      );
      final removed = original.withConversationMicrophoneMode(scopeA, null);
      expect(original.conversationMicrophoneModes, contains(scopeA));
      expect(removed.conversationMicrophoneModes, isEmpty);
      expect(
        () =>
            original.conversationMicrophoneModes[scopeB] = MicrophoneMode.open,
        throwsUnsupportedError,
      );
    });

    test('value equality includes every override', () {
      expect(
        AppSettings(
          globalMicrophoneMode: MicrophoneMode.voiceActivated,
          conversationMicrophoneModes: {scopeA: MicrophoneMode.pushToTalk},
        ),
        AppSettings(
          globalMicrophoneMode: MicrophoneMode.voiceActivated,
          conversationMicrophoneModes: {scopeA: MicrophoneMode.pushToTalk},
        ),
      );
      expect(
        AppSettings(
          conversationMicrophoneModes: {scopeA: MicrophoneMode.pushToTalk},
        ),
        isNot(
          AppSettings(
            conversationMicrophoneModes: {scopeB: MicrophoneMode.pushToTalk},
          ),
        ),
      );
      expect(AppSettings(), isNot(AppSettings(appLockEnabled: true)));
      expect(AppSettings(), isNot(AppSettings(shareActivityPresence: true)));
      expect(
        AppSettings(),
        isNot(AppSettings(identityColor: IdentityColor.sky)),
      );
      expect(
        AppSettings(),
        isNot(AppSettings(unreadBadgePlacement: UnreadBadgePlacement.trailing)),
      );
      expect(
        AppSettings(),
        isNot(
          AppSettings(groupHeaderPlacement: GroupHeaderPlacement.fullWidth),
        ),
      );
      expect(
        AppSettings(),
        isNot(
          AppSettings(mobileGroupNavigation: MobileGroupNavigation.roomsFirst),
        ),
      );
      expect(AppSettings(), isNot(AppSettings(chatMotionEnabled: false)));
      expect(
        AppSettings(),
        isNot(AppSettings(chatActivityIndicatorsEnabled: false)),
      );
      expect(
        AppSettings(),
        isNot(AppSettings(messageTimestampStyle: MessageTimestampStyle.apple)),
      );
    });

    test('rejects file settings outside their bounded domains', () {
      expect(() => AppSettings(folderHistoryLimit: 0), throwsArgumentError);
      expect(
        () => AppSettings(
          maxIncomingFileBytes: AppSettings.maxAllowedIncomingFileBytes + 1,
        ),
        throwsArgumentError,
      );
      expect(
        AppSettings(maxIncomingFileBytes: 0).maxIncomingFileBytes,
        0,
        reason: 'zero explicitly disables the incoming-size cap',
      );
    });
  });

  group('AppSettingsCodec', () {
    const codec = AppSettingsCodec();

    test('round-trips schema 14 and writes overrides deterministically', () {
      final settings = AppSettings(
        globalMicrophoneMode: MicrophoneMode.voiceActivated,
        conversationMicrophoneModes: {
          scopeB: MicrophoneMode.open,
          scopeA: MicrophoneMode.pushToTalk,
        },
        appLockEnabled: true,
        folderHistoryLimit: 321,
        maxIncomingFileBytes: 0,
        appearancePreset: AppearancePreset.midnight,
        windowsCaptureProtectionEnabled: false,
        shareActivityPresence: true,
        identityColor: IdentityColor.violet,
        unreadBadgePlacement: UnreadBadgePlacement.trailing,
        showMessageInNotification: false,
        reliableBackgroundNotifications: false,
        groupHeaderPlacement: GroupHeaderPlacement.fullWidth,
        mobileGroupNavigation: MobileGroupNavigation.roomsFirst,
        chatMotionEnabled: false,
        chatActivityIndicatorsEnabled: false,
        messageTimestampStyle: MessageTimestampStyle.whatsapp,
        messageReceiptStyle: MessageReceiptStyle.sybl,
        messageReceiptVisibility: MessageReceiptVisibility.afterPause,
        repeatMessageAuthorAfterPause: false,
        topicStripSurfaceSettings: const TopicStripSurfaceSettings(
          coverage: TopicStripSurfaceCoverage.fullWidth,
          strength: 73,
          blur: 19,
          solidReach: 31,
          lowerFade: 62,
          rightFade: 87,
        ),
      );
      final encoded = codec.encode(settings);
      expect(encoded['schemaVersion'], AppSettings.currentSchemaVersion);
      final microphone = encoded['microphone']! as Map<String, Object?>;
      final overrides = microphone['conversationOverrides']! as List<Object?>;
      expect((overrides.first as Map)['peerId'], 'peer-a');
      expect((overrides.last as Map)['peerId'], 'peer-b');
      expect((encoded['appLock']! as Map)['enabled'], isTrue);
      expect((encoded['files']! as Map)['folderHistoryLimit'], 321);
      expect((encoded['files']! as Map)['maxIncomingFileBytes'], 0);
      expect((encoded['appearance']! as Map)['preset'], 'midnight');
      expect(
        (encoded['appearance']! as Map)['groupHeaderPlacement'],
        'fullWidth',
      );
      expect(
        (encoded['appearance']! as Map)['mobileGroupNavigation'],
        'roomsFirst',
      );
      expect((encoded['appearance']! as Map)['chatMotionEnabled'], isFalse);
      expect(
        (encoded['appearance']! as Map)['chatActivityIndicatorsEnabled'],
        isFalse,
      );
      expect(
        (encoded['appearance']! as Map)['messageTimestampStyle'],
        'whatsapp',
      );
      expect(
        (encoded['windowsCaptureProtection']! as Map)['enabled'],
        isFalse,
        reason: 'an explicit off choice must round-trip',
      );
      expect((encoded['presence']! as Map)['shareActiveApp'], isTrue);
      expect((encoded['profile']! as Map)['identityColor'], 'violet');
      expect(
        (encoded['notifications']! as Map)['unreadBadgePlacement'],
        'trailing',
      );
      expect((encoded['notifications']! as Map)['showMessage'], isFalse);
      expect((encoded['notifications']! as Map)['reliableBackground'], isFalse);
      expect((encoded['appearance']! as Map)['topicStripSurface'], {
        'coverage': 'fullWidth',
        'strength': 73,
        'blur': 19,
        'solidReach': 31,
        'lowerFade': 62,
        'rightFade': 87,
      });

      final decoded = codec.decode(encoded);
      expect(decoded.settings, settings);
      expect(decoded.settings.windowsCaptureProtectionEnabled, isFalse);
      expect(decoded.settings.shareActivityPresence, isTrue);
      expect(decoded.settings.identityColor, IdentityColor.violet);
      expect(
        decoded.settings.unreadBadgePlacement,
        UnreadBadgePlacement.trailing,
      );
      expect(decoded.settings.showMessageInNotification, isFalse);
      expect(decoded.settings.reliableBackgroundNotifications, isFalse);
      expect(
        decoded.settings.groupHeaderPlacement,
        GroupHeaderPlacement.fullWidth,
      );
      expect(
        decoded.settings.mobileGroupNavigation,
        MobileGroupNavigation.roomsFirst,
      );
      expect(decoded.settings.chatMotionEnabled, isFalse);
      expect(decoded.settings.chatActivityIndicatorsEnabled, isFalse);
      expect(
        decoded.settings.messageReceiptVisibility,
        MessageReceiptVisibility.afterPause,
      );
      expect(decoded.settings.repeatMessageAuthorAfterPause, isFalse);
      expect(
        decoded.settings.topicStripSurfaceSettings,
        settings.topicStripSurfaceSettings,
      );
      expect(decoded.sourceVersion, AppSettings.currentSchemaVersion);
      expect(decoded.needsRewrite, isFalse);
    });

    test('migrates schema 13 without opting into Google wake', () {
      final version13 = codec.encode(AppSettings())..['schemaVersion'] = 13;
      (version13['notifications']! as Map).remove('reliableBackground');

      final decoded = codec.decode(version13);

      expect(decoded.sourceVersion, 13);
      expect(decoded.needsRewrite, isTrue);
      expect(decoded.settings.reliableBackgroundNotifications, isFalse);
    });

    test('legacy default-on wake is not explicit Google consent', () {
      final document = codec.encode(
        AppSettings(reliableBackgroundNotifications: true),
      );
      (document['notifications']! as Map).remove('googleWakeConsent');
      final decoded = codec.decode(document);
      expect(decoded.settings.reliableBackgroundNotifications, isFalse);
      expect(decoded.needsRewrite, isTrue);
    });

    test('explicit Google wake choice survives a settings round trip', () {
      expect(AppSettings().reliableBackgroundNotifications, isFalse);
      final decoded = codec.decode(
        codec.encode(AppSettings(reliableBackgroundNotifications: true)),
      );
      expect(decoded.settings.reliableBackgroundNotifications, isTrue);
      expect(decoded.needsRewrite, isFalse);
    });

    test('migrates schema 12 to the shipped identity color', () {
      final version12 = {...codec.encode(AppSettings()), 'schemaVersion': 12}
        ..remove('profile');

      final decoded = codec.decode(version12);

      expect(decoded.sourceVersion, 12);
      expect(decoded.needsRewrite, isTrue);
      expect(decoded.settings.identityColor, IdentityColor.amber);
    });

    test('rejects an unknown identity color in the current schema', () {
      final valid = codec.encode(AppSettings());

      expect(
        () => codec.decode({
          ...valid,
          'profile': {'identityColor': 'ultraviolet'},
        }),
        throwsFormatException,
      );
    });

    test('migrates schema 3 with the conservative capture default', () {
      final version3 = {
        'schemaVersion': 3,
        'microphone': {
          'globalDefault': 'open',
          'conversationOverrides': <Object?>[],
        },
        'appLock': {'enabled': true},
        'files': {'folderHistoryLimit': 77, 'maxIncomingFileBytes': 1024},
        'appearance': {'preset': 'cozy'},
      };
      final decoded = codec.decode(version3);
      expect(decoded.sourceVersion, 3);
      expect(decoded.needsRewrite, isTrue);
      expect(decoded.settings.windowsCaptureProtectionEnabled, isTrue);
      expect(decoded.settings.shareActivityPresence, isFalse);
      expect(decoded.settings.appLockEnabled, isTrue);
      expect(decoded.settings.folderHistoryLimit, 77);
      expect(decoded.settings.appearancePreset, AppearancePreset.cozy);
    });

    test('migrates schema 4 with active-app sharing disabled', () {
      final version4 = {
        ...codec.encode(AppSettings(windowsCaptureProtectionEnabled: false)),
        'schemaVersion': 4,
      }..remove('presence');
      final decoded = codec.decode(version4);
      expect(decoded.sourceVersion, 4);
      expect(decoded.needsRewrite, isTrue);
      expect(decoded.settings.windowsCaptureProtectionEnabled, isFalse);
      expect(decoded.settings.shareActivityPresence, isFalse);
    });

    test('migrates schema 5 with avatar badges', () {
      final version5 = {
        ...codec.encode(AppSettings(shareActivityPresence: true)),
        'schemaVersion': 5,
      }..remove('notifications');
      final decoded = codec.decode(version5);
      expect(decoded.sourceVersion, 5);
      expect(decoded.needsRewrite, isTrue);
      expect(decoded.settings.shareActivityPresence, isTrue);
      expect(
        decoded.settings.unreadBadgePlacement,
        UnreadBadgePlacement.avatar,
      );
    });

    test('migrates schema 6 with the current group-header placement', () {
      final version6 = {
        ...codec.encode(AppSettings()),
        'schemaVersion': 6,
        'appearance': {'preset': 'calm'},
      };
      final decoded = codec.decode(version6);
      expect(decoded.sourceVersion, 6);
      expect(decoded.needsRewrite, isTrue);
      expect(
        decoded.settings.groupHeaderPlacement,
        GroupHeaderPlacement.conversation,
      );
    });

    test('migrates schema 7 with inline mobile group navigation', () {
      final version7 = {
        ...codec.encode(AppSettings()),
        'schemaVersion': 7,
        'appearance': {
          'preset': 'calm',
          'groupHeaderPlacement': 'conversation',
        },
      };
      final decoded = codec.decode(version7);
      expect(decoded.sourceVersion, 7);
      expect(decoded.needsRewrite, isTrue);
      expect(
        decoded.settings.mobileGroupNavigation,
        MobileGroupNavigation.inline,
      );
    });

    test('migrates schema 8 with chat motion and activity enabled', () {
      final version8 = {
        ...codec.encode(AppSettings()),
        'schemaVersion': 8,
        'appearance': {
          'preset': 'calm',
          'groupHeaderPlacement': 'conversation',
          'mobileGroupNavigation': 'inline',
        },
      };
      final decoded = codec.decode(version8);
      expect(decoded.sourceVersion, 8);
      expect(decoded.needsRewrite, isTrue);
      expect(decoded.settings.chatMotionEnabled, isTrue);
      expect(decoded.settings.chatActivityIndicatorsEnabled, isTrue);
    });

    test('migrates schema 9 with current message presentation defaults', () {
      final version9 = codec.encode(AppSettings());
      version9['schemaVersion'] = 9;
      final appearance = version9['appearance']! as Map<String, Object?>;
      appearance
        ..remove('messageTimestampStyle')
        ..remove('messageReceiptStyle')
        ..remove('messageReceiptVisibility')
        ..remove('repeatMessageAuthorAfterPause');

      final decoded = codec.decode(version9);
      expect(decoded.sourceVersion, 9);
      expect(decoded.needsRewrite, isTrue);
      expect(
        decoded.settings.messageTimestampStyle,
        MessageTimestampStyle.inward,
      );
      expect(
        decoded.settings.messageReceiptStyle,
        MessageReceiptStyle.whatsapp,
      );
      expect(decoded.settings.repeatMessageAuthorAfterPause, isTrue);
    });

    test('migrates schema 10 with message previews enabled', () {
      final version10 = codec.encode(AppSettings())..['schemaVersion'] = 10;
      (version10['notifications']! as Map).remove('showMessage');

      final decoded = codec.decode(version10);

      expect(decoded.settings.showMessageInNotification, isTrue);
      expect(decoded.needsRewrite, isTrue);
    });

    test('migrates schema 11 with shipped topic surface defaults', () {
      final version11 = codec.encode(AppSettings())..['schemaVersion'] = 11;
      (version11['appearance']! as Map).remove('topicStripSurface');

      final decoded = codec.decode(version11);

      expect(
        decoded.settings.topicStripSurfaceSettings,
        const TopicStripSurfaceSettings(),
      );
      expect(decoded.needsRewrite, isTrue);
    });

    test('rejects malformed current topic surface settings', () {
      final valid = codec.encode(AppSettings());
      final invalidValues = <String, Object?>{
        'coverage': 'wide',
        'strength': 101,
        'blur': 41,
        'solidReach': 81,
        'lowerFade': 121,
        'rightFade': 121,
      };
      for (final entry in invalidValues.entries) {
        final appearance = Map<String, Object?>.from(
          valid['appearance']! as Map,
        );
        final surface = Map<String, Object?>.from(
          appearance['topicStripSurface']! as Map,
        )..[entry.key] = entry.value;
        expect(
          () => codec.decode({
            ...valid,
            'appearance': {...appearance, 'topicStripSurface': surface},
          }),
          throwsFormatException,
          reason: entry.key,
        );
      }
    });

    test('rejects a malformed current capture-protection object', () {
      final valid = codec.encode(AppSettings());
      expect(
        () => codec.decode({...valid}..remove('windowsCaptureProtection')),
        throwsFormatException,
      );
      expect(
        () => codec.decode({
          ...valid,
          'windowsCaptureProtection': {'enabled': 'true'},
        }),
        throwsFormatException,
      );
      expect(
        () => codec.decode({...valid, 'windowsCaptureProtection': 'on'}),
        throwsFormatException,
      );
    });

    test('rejects malformed current active-app presence settings', () {
      final valid = codec.encode(AppSettings());
      expect(
        () => codec.decode({...valid}..remove('presence')),
        throwsFormatException,
      );
      expect(
        () => codec.decode({
          ...valid,
          'presence': {'shareActiveApp': 'yes'},
        }),
        throwsFormatException,
      );
      expect(
        () => codec.decode({...valid, 'presence': false}),
        throwsFormatException,
      );
    });

    test('rejects malformed current notification settings', () {
      final valid = codec.encode(AppSettings());
      expect(
        () => codec.decode({...valid}..remove('notifications')),
        throwsFormatException,
      );
      expect(
        () => codec.decode({
          ...valid,
          'notifications': {'unreadBadgePlacement': 'somewhere'},
        }),
        throwsFormatException,
      );
      expect(
        () => codec.decode({
          ...valid,
          'notifications': {
            'unreadBadgePlacement': 'avatar',
            'showMessage': 'yes',
          },
        }),
        throwsFormatException,
      );
      expect(
        () => codec.decode({
          ...valid,
          'notifications': {
            'unreadBadgePlacement': 'avatar',
            'showMessage': true,
            'reliableBackground': 'yes',
          },
        }),
        throwsFormatException,
      );
    });

    test('rejects malformed current group-header placement', () {
      final valid = codec.encode(AppSettings());
      expect(
        () => codec.decode({
          ...valid,
          'appearance': {'preset': 'calm'},
        }),
        throwsFormatException,
      );
      expect(
        () => codec.decode({
          ...valid,
          'appearance': {
            'preset': 'calm',
            'groupHeaderPlacement': 'floating',
            'mobileGroupNavigation': 'inline',
          },
        }),
        throwsFormatException,
      );
    });

    test('rejects malformed current mobile group navigation', () {
      final valid = codec.encode(AppSettings());
      expect(
        () => codec.decode({
          ...valid,
          'appearance': {
            'preset': 'calm',
            'groupHeaderPlacement': 'conversation',
          },
        }),
        throwsFormatException,
      );
      expect(
        () => codec.decode({
          ...valid,
          'appearance': {
            'preset': 'calm',
            'groupHeaderPlacement': 'conversation',
            'mobileGroupNavigation': 'teleport',
          },
        }),
        throwsFormatException,
      );
    });

    test('rejects malformed current chat experience settings', () {
      final valid = codec.encode(AppSettings());
      final appearance = Map<String, Object?>.from(valid['appearance']! as Map);
      final missingActivity = Map<String, Object?>.of(appearance)
        ..remove('chatActivityIndicatorsEnabled');
      expect(
        () => codec.decode({
          ...valid,
          'appearance': {...appearance, 'chatMotionEnabled': 'yes'},
        }),
        throwsFormatException,
      );
      expect(
        () => codec.decode({...valid, 'appearance': missingActivity}),
        throwsFormatException,
      );
    });

    test('migrates explicit and pre-versioned schema 1 documents', () {
      for (final document in [
        <String, Object?>{'schemaVersion': 1, 'microphoneMode': 'ptt'},
        <String, Object?>{'microphoneMode': 'ptt'},
      ]) {
        final decoded = codec.decode(document);
        expect(
          decoded.settings.globalMicrophoneMode,
          MicrophoneMode.pushToTalk,
        );
        expect(decoded.settings.conversationMicrophoneModes, isEmpty);
        expect(decoded.sourceVersion, 1);
        expect(decoded.needsRewrite, isTrue);
      }
    });

    test('migrates schema 2 with safe defaults for all new fields', () {
      final decoded = codec.decode({
        'schemaVersion': 2,
        'microphone': {
          'globalDefault': 'voiceActivated',
          'conversationOverrides': <Object?>[],
        },
      });

      expect(decoded.sourceVersion, 2);
      expect(decoded.needsRewrite, isTrue);
      expect(decoded.settings.appLockEnabled, isFalse);
      expect(decoded.settings.windowsCaptureProtectionEnabled, isTrue);
      expect(
        decoded.settings.folderHistoryLimit,
        AppSettings.defaultFolderHistoryLimit,
      );
      expect(
        decoded.settings.maxIncomingFileBytes,
        AppSettings.defaultMaxIncomingFileBytes,
      );
      expect(decoded.settings.appearancePreset, AppearancePreset.disaccord);
    });

    test('rejects future, missing, and malformed schemas', () {
      expect(
        () => codec.decode({
          'schemaVersion': AppSettings.currentSchemaVersion + 1,
        }),
        throwsA(isA<UnsupportedSettingsVersion>()),
      );
      expect(() => codec.decode({}), throwsFormatException);
      expect(() => codec.decode({'schemaVersion': '2'}), throwsFormatException);
      expect(() => codec.decode({'schemaVersion': 0}), throwsFormatException);
      expect(
        () =>
            codec.decode({'schemaVersion': 1, 'microphoneMode': 'pushToTalk'}),
        throwsFormatException,
      );
    });

    test('rejects malformed current microphone data atomically', () {
      Map<String, Object?> document(Object? microphone) => {
        'schemaVersion': AppSettings.currentSchemaVersion,
        'microphone': microphone,
        'appLock': {'enabled': false},
        'files': {
          'folderHistoryLimit': AppSettings.defaultFolderHistoryLimit,
          'maxIncomingFileBytes': AppSettings.defaultMaxIncomingFileBytes,
        },
        'appearance': {
          'preset': 'calm',
          'groupHeaderPlacement': 'conversation',
          'mobileGroupNavigation': 'inline',
          'chatMotionEnabled': true,
          'chatActivityIndicatorsEnabled': true,
        },
        'windowsCaptureProtection': {'enabled': true},
        'presence': {'shareActiveApp': false},
        'notifications': {'unreadBadgePlacement': 'avatar'},
      };

      expect(() => codec.decode(document(null)), throwsFormatException);
      expect(
        () => codec.decode(
          document({
            'globalDefault': 'ptt',
            'conversationOverrides': <Object?>[],
          }),
        ),
        throwsFormatException,
      );
      expect(
        () => codec.decode(
          document({
            'globalDefault': 'open',
            'conversationOverrides': 'not-a-list',
          }),
        ),
        throwsFormatException,
      );
      expect(
        () => codec.decode(
          document({
            'globalDefault': 'open',
            'conversationOverrides': [
              {...scopeA.toMap(), 'mode': 'invalid'},
            ],
          }),
        ),
        throwsFormatException,
      );
      expect(
        () => codec.decode(
          document({
            'globalDefault': 'open',
            'conversationOverrides': [
              {...scopeA.toMap(), 'mode': 'open'},
              {...scopeA.toMap(), 'mode': 'voiceActivated'},
            ],
          }),
        ),
        throwsFormatException,
      );
    });

    test('rejects malformed current app lock, files, and appearance', () {
      final valid = codec.encode(AppSettings());
      expect(
        () => codec.decode({
          ...valid,
          'appLock': {'enabled': 'true'},
        }),
        throwsFormatException,
      );
      expect(
        () => codec.decode({
          ...valid,
          'files': {
            'folderHistoryLimit': 0,
            'maxIncomingFileBytes': AppSettings.defaultMaxIncomingFileBytes,
          },
        }),
        throwsFormatException,
      );
      expect(
        () => codec.decode({
          ...valid,
          'files': {
            'folderHistoryLimit': AppSettings.defaultFolderHistoryLimit,
            'maxIncomingFileBytes': -1,
          },
        }),
        throwsFormatException,
      );
      expect(
        () => codec.decode({
          ...valid,
          'appearance': {
            'preset': 'neon',
            'groupHeaderPlacement': 'conversation',
            'mobileGroupNavigation': 'inline',
          },
        }),
        throwsFormatException,
      );
    });
  });

  group('VersionedAppSettingsRepository', () {
    test('returns defaults without writing when no document exists', () async {
      final store = _MemoryDocumentStore();
      final repository = VersionedAppSettingsRepository(store);

      expect(await repository.load(), AppSettings());
      expect(store.writes, isEmpty);
    });

    test('rewrites a migrated document once in the current schema', () async {
      final store = _MemoryDocumentStore({
        'schemaVersion': 1,
        'microphoneMode': 'ptt',
      });
      final repository = VersionedAppSettingsRepository(store);

      final settings = await repository.load();
      expect(settings.globalMicrophoneMode, MicrophoneMode.pushToTalk);
      expect(store.writes, hasLength(1));
      expect(
        store.writes.single['schemaVersion'],
        AppSettings.currentSchemaVersion,
      );

      await repository.load();
      expect(store.writes, hasLength(1));
    });

    test('save delegates one canonical versioned document', () async {
      final store = _MemoryDocumentStore();
      final repository = VersionedAppSettingsRepository(store);
      final settings = AppSettings().withConversationMicrophoneMode(
        scopeA,
        MicrophoneMode.voiceActivated,
      );

      await repository.save(settings);

      expect(store.writes, hasLength(1));
      expect(await repository.load(), settings);
    });

    test('does not overwrite corrupt or future documents', () async {
      for (final document in [
        <String, Object?>{
          'schemaVersion': 2,
          'microphone': {
            'globalDefault': 'corrupt',
            'conversationOverrides': <Object?>[],
          },
        },
        <String, Object?>{'schemaVersion': 99},
      ]) {
        final store = _MemoryDocumentStore(document);
        final repository = VersionedAppSettingsRepository(store);
        await expectLater(repository.load(), throwsA(anything));
        expect(store.writes, isEmpty);
      }
    });
  });
}

final class _MemoryDocumentStore implements AppSettingsDocumentStore {
  _MemoryDocumentStore([Map<String, Object?>? initial]) : document = initial;

  Map<String, Object?>? document;
  final List<Map<String, Object?>> writes = [];

  @override
  Future<Map<String, Object?>?> readDocument() async => document;

  @override
  Future<void> writeDocument(Map<String, Object?> value) async {
    document = value;
    writes.add(value);
  }
}
