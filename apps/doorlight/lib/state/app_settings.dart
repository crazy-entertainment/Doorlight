export 'appearance_preset.dart';

import 'appearance_preset.dart';
import 'conversation_scope.dart';
import 'identity_color.dart';
import 'friend_preferences.dart';

export 'friend_preferences.dart';

enum AmbientVibe { none, rain, snow, halloween }

enum WindowEdgeSpacing { close, floating }

enum WindowCloseAnimation {
  tray,
  door,
  warp,
  fade,
  none,
  foldRight,
  foldUp,
  foldDown;

  bool get isFold =>
      this == door || this == foldRight || this == foldUp || this == foldDown;
}

enum MicrophoneMode {
  open('open'),
  pushToTalk('pushToTalk'),
  voiceActivated('voiceActivated');

  const MicrophoneMode(this.storageValue);

  final String storageValue;

  static MicrophoneMode? tryParse(Object? value) {
    if (value is! String) return null;
    for (final mode in values) {
      if (mode.storageValue == value) return mode;
    }
    return null;
  }
}

enum MicrophoneModeSource { globalDefault, conversationOverride }

enum UnreadBadgePlacement {
  avatar('avatar'),
  trailing('trailing');

  const UnreadBadgePlacement(this.storageValue);

  final String storageValue;

  static UnreadBadgePlacement? tryParse(Object? value) {
    if (value is! String) return null;
    for (final placement in values) {
      if (placement.storageValue == value) return placement;
    }
    return null;
  }
}

enum GroupHeaderPlacement {
  conversation('conversation'),
  fullWidth('fullWidth');

  const GroupHeaderPlacement(this.storageValue);

  final String storageValue;

  static GroupHeaderPlacement? tryParse(Object? value) {
    if (value is! String) return null;
    for (final placement in values) {
      if (placement.storageValue == value) return placement;
    }
    return null;
  }
}

enum MobileGroupNavigation {
  inline('inline'),
  roomsFirst('roomsFirst');

  const MobileGroupNavigation(this.storageValue);

  final String storageValue;

  static MobileGroupNavigation? tryParse(Object? value) {
    if (value is! String) return null;
    for (final navigation in values) {
      if (navigation.storageValue == value) return navigation;
    }
    return null;
  }
}

enum TopicStripSurfaceCoverage {
  topics('topics'),
  fullWidth('fullWidth'),
  off('off');

  const TopicStripSurfaceCoverage(this.storageValue);

  final String storageValue;

  static TopicStripSurfaceCoverage? tryParse(Object? value) {
    if (value is! String) return null;
    for (final coverage in values) {
      if (coverage.storageValue == value) return coverage;
    }
    return null;
  }
}

final class TopicStripSurfaceSettings {
  const TopicStripSurfaceSettings({
    this.coverage = TopicStripSurfaceCoverage.topics,
    this.strength = 42,
    this.blur = 2,
    this.solidReach = 5,
    this.lowerFade = 15,
    this.rightFade = 14,
  }) : assert(strength >= 0 && strength <= maxStrength),
       assert(blur >= 0 && blur <= maxBlur),
       assert(solidReach >= 0 && solidReach <= maxSolidReach),
       assert(lowerFade >= 0 && lowerFade <= maxLowerFade),
       assert(rightFade >= 0 && rightFade <= maxRightFade);

  static const int maxStrength = 100;
  static const int maxBlur = 40;
  static const int maxSolidReach = 80;
  static const int maxLowerFade = 120;
  static const int maxRightFade = 120;

  final TopicStripSurfaceCoverage coverage;
  final int strength;
  final int blur;
  final int solidReach;
  final int lowerFade;
  final int rightFade;

  TopicStripSurfaceSettings copyWith({
    TopicStripSurfaceCoverage? coverage,
    int? strength,
    int? blur,
    int? solidReach,
    int? lowerFade,
    int? rightFade,
  }) => TopicStripSurfaceSettings(
    coverage: coverage ?? this.coverage,
    strength: strength ?? this.strength,
    blur: blur ?? this.blur,
    solidReach: solidReach ?? this.solidReach,
    lowerFade: lowerFade ?? this.lowerFade,
    rightFade: rightFade ?? this.rightFade,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TopicStripSurfaceSettings &&
          coverage == other.coverage &&
          strength == other.strength &&
          blur == other.blur &&
          solidReach == other.solidReach &&
          lowerFade == other.lowerFade &&
          rightFade == other.rightFade;

  @override
  int get hashCode =>
      Object.hash(coverage, strength, blur, solidReach, lowerFade, rightFade);
}

enum MessageTimestampStyle {
  inward('inward'),
  below('below'),
  discord('discord'),
  whatsapp('whatsapp'),
  messenger('messenger'),
  apple('apple');

  const MessageTimestampStyle(this.storageValue);

  final String storageValue;

  static MessageTimestampStyle? tryParse(Object? value) {
    if (value is! String) return null;
    for (final style in values) {
      if (style.storageValue == value) return style;
    }
    return null;
  }
}

enum MessageReceiptStyle {
  whatsapp('whatsapp'),
  sybl('sybl'),
  messenger('messenger');

  const MessageReceiptStyle(this.storageValue);

  final String storageValue;

  static MessageReceiptStyle? tryParse(Object? value) {
    if (value is! String) return null;
    for (final style in values) {
      if (style.storageValue == value) return style;
    }
    return null;
  }
}

enum MessageReceiptVisibility {
  always('always'),
  afterPause('afterPause');

  const MessageReceiptVisibility(this.storageValue);

  final String storageValue;

  static MessageReceiptVisibility? tryParse(Object? value) {
    if (value is! String) return null;
    for (final visibility in values) {
      if (visibility.storageValue == value) return visibility;
    }
    return null;
  }
}

final class EffectiveMicrophoneMode {
  const EffectiveMicrophoneMode({required this.mode, required this.source});

  final MicrophoneMode mode;
  final MicrophoneModeSource source;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EffectiveMicrophoneMode &&
          mode == other.mode &&
          source == other.source;

  @override
  int get hashCode => Object.hash(mode, source);
}

/// Versioned user settings whose fields have an approved runtime meaning.
///
/// New settings should be added here only after their behavior is specified.
/// Secrets do not belong in this document.
final class AppSettings {
  AppSettings({
    this.globalMicrophoneMode = MicrophoneMode.open,
    this.microphoneReviewRequired = false,
    this.friendPreferencesReviewRequired = false,
    this.messageAlertsEnabled = true,
    Map<FriendPreferenceScope, FriendPreferences> friendPreferences = const {},
    Map<ConversationScope, MicrophoneMode> conversationMicrophoneModes =
        const {},
    this.appLockEnabled = false,
    this.folderHistoryLimit = defaultFolderHistoryLimit,
    this.maxIncomingFileBytes = defaultMaxIncomingFileBytes,
    this.appearancePreset = AppearancePreset.cozy,
    this.ambientVibe = AmbientVibe.none,
    this.vibeOpacity = 100,
    this.vibeIntensity = 100,
    this.rememberDefaultWindowPosition = false,
    this.windowEdgeSpacing = WindowEdgeSpacing.close,
    this.windowOpenAnimation = WindowCloseAnimation.tray,
    this.windowMinimizeAnimation = WindowCloseAnimation.tray,
    this.windowCloseAnimation = WindowCloseAnimation.tray,
    this.windowOpenDurationMs = defaultWindowAnimationDurationMs,
    this.windowMinimizeDurationMs = defaultWindowAnimationDurationMs,
    this.windowCloseDurationMs = defaultWindowAnimationDurationMs,
    this.windowsCaptureProtectionEnabled = true,
    this.shareActivityPresence = false,
    this.identityColor = IdentityColor.amber,
    this.identityColorManual = false,
    this.unreadBadgePlacement = UnreadBadgePlacement.avatar,
    this.showMessageInNotification = true,
    this.hologramPresentationEnabled = true,
    this.reliableBackgroundNotifications = false,
    this.groupHeaderPlacement = GroupHeaderPlacement.conversation,
    this.mobileGroupNavigation = MobileGroupNavigation.inline,
    this.chatMotionEnabled = true,
    this.chatActivityIndicatorsEnabled = true,
    this.messageTimestampStyle = MessageTimestampStyle.inward,
    this.messageReceiptStyle = MessageReceiptStyle.whatsapp,
    this.messageReceiptVisibility = MessageReceiptVisibility.always,
    this.repeatMessageAuthorAfterPause = true,
    this.topicStripSurfaceSettings = const TopicStripSurfaceSettings(),
  }) : friendPreferences = Map.unmodifiable(friendPreferences),
       conversationMicrophoneModes = Map.unmodifiable(
         conversationMicrophoneModes,
       ) {
    if (vibeIntensity < 0 || vibeIntensity > 100) {
      throw ArgumentError.value(
        vibeIntensity,
        'vibeIntensity',
        'must be 0..100',
      );
    }
    if (vibeOpacity < 0 || vibeOpacity > 100) {
      throw ArgumentError.value(vibeOpacity, 'vibeOpacity', 'must be 0..100');
    }
    if (friendPreferences.length > 256) {
      throw ArgumentError('too many friend preferences');
    }
    if (!isValidFolderHistoryLimit(folderHistoryLimit)) {
      throw ArgumentError.value(
        folderHistoryLimit,
        'folderHistoryLimit',
        'must be $minFolderHistoryLimit..$maxFolderHistoryLimit',
      );
    }
    if (!isValidMaxIncomingFileBytes(maxIncomingFileBytes)) {
      throw ArgumentError.value(
        maxIncomingFileBytes,
        'maxIncomingFileBytes',
        'must be 0..$maxAllowedIncomingFileBytes (0 disables the cap)',
      );
    }
    for (final duration in [
      windowOpenDurationMs,
      windowMinimizeDurationMs,
      windowCloseDurationMs,
    ]) {
      if (!isValidWindowAnimationDuration(duration)) {
        throw ArgumentError.value(
          duration,
          'windowAnimationDurationMs',
          'must be $minWindowAnimationDurationMs..$maxWindowAnimationDurationMs',
        );
      }
    }
  }

  static const int currentSchemaVersion = 24;
  static const int minFolderHistoryLimit = 1;
  static const int maxFolderHistoryLimit = 5000;
  static const int defaultFolderHistoryLimit = 200;
  static const int maxAllowedIncomingFileBytes = 1 << 40; // 1 TiB
  static const int defaultMaxIncomingFileBytes = 2 * 1024 * 1024 * 1024;
  static const int minWindowAnimationDurationMs = 100;
  static const int maxWindowAnimationDurationMs = 800;
  static const int defaultWindowAnimationDurationMs = 240;

  static bool isValidWindowAnimationDuration(int value) =>
      value >= minWindowAnimationDurationMs &&
      value <= maxWindowAnimationDurationMs;

  final MicrophoneMode globalMicrophoneMode;

  /// An old backup can contain overrides without a provable local owner.
  /// Preserve those settings, but require a global microphone choice before use.
  final bool microphoneReviewRequired;
  final bool friendPreferencesReviewRequired;
  final bool messageAlertsEnabled;
  final Map<FriendPreferenceScope, FriendPreferences> friendPreferences;
  final Map<ConversationScope, MicrophoneMode> conversationMicrophoneModes;
  final bool appLockEnabled;
  final int folderHistoryLimit;
  final int maxIncomingFileBytes;
  final AppearancePreset appearancePreset;
  final AmbientVibe ambientVibe;
  final int vibeOpacity;
  final int vibeIntensity;
  final bool rememberDefaultWindowPosition;
  final WindowEdgeSpacing windowEdgeSpacing;
  final WindowCloseAnimation windowOpenAnimation;
  final WindowCloseAnimation windowMinimizeAnimation;
  final WindowCloseAnimation windowCloseAnimation;
  final int windowOpenDurationMs;
  final int windowMinimizeDurationMs;
  final int windowCloseDurationMs;

  /// Windows-only desired preference: keep the app window excluded from
  /// screen capture. Nonsensitive intent, not native applied truth; a missing
  /// or unreadable value resolves conservatively to `true`. Android ignores
  /// this field — its `FLAG_SECURE` is unconditional.
  final bool windowsCaptureProtectionEnabled;

  /// Explicit opt-in for sharing when Doorlight is open. On Windows this also
  /// shares the friendly name of the foreground application; window titles
  /// are never shared. Android never inspects another app. False is the
  /// privacy-preserving migration/default.
  final bool shareActivityPresence;
  final IdentityColor identityColor;

  /// Explicit user choices stay fixed; existing saved colors migrate as manual.
  final bool identityColorManual;
  final UnreadBadgePlacement unreadBadgePlacement;
  final bool showMessageInNotification;
  final bool hologramPresentationEnabled;
  final bool reliableBackgroundNotifications;
  final GroupHeaderPlacement groupHeaderPlacement;
  final MobileGroupNavigation mobileGroupNavigation;
  final bool chatMotionEnabled;
  final bool chatActivityIndicatorsEnabled;
  final MessageTimestampStyle messageTimestampStyle;
  final MessageReceiptStyle messageReceiptStyle;
  final MessageReceiptVisibility messageReceiptVisibility;
  final bool repeatMessageAuthorAfterPause;
  final TopicStripSurfaceSettings topicStripSurfaceSettings;

  static bool isValidFolderHistoryLimit(int value) =>
      value >= minFolderHistoryLimit && value <= maxFolderHistoryLimit;

  static bool isValidMaxIncomingFileBytes(int value) =>
      value >= 0 && value <= maxAllowedIncomingFileBytes;

  EffectiveMicrophoneMode microphoneModeFor(ConversationScope scope) {
    final override = conversationMicrophoneModes[scope];
    return EffectiveMicrophoneMode(
      mode: override ?? globalMicrophoneMode,
      source: override == null
          ? MicrophoneModeSource.globalDefault
          : MicrophoneModeSource.conversationOverride,
    );
  }

  AppSettings withGlobalMicrophoneMode(MicrophoneMode mode) =>
      _copyWith(globalMicrophoneMode: mode);

  AppSettings withMicrophoneReviewRequired(bool required) =>
      _copyWith(microphoneReviewRequired: required);

  AppSettings withMessageAlertsEnabled(bool enabled) =>
      _copyWith(messageAlertsEnabled: enabled);

  /// Explicit recovery choice: discard ambiguous scopes without enabling alerts
  /// or live presentations. The user can choose fresh defaults afterward.
  AppSettings resetUnreviewedFriendPreferences() => _copyWith(
    friendPreferences: const {},
    friendPreferencesReviewRequired: false,
    messageAlertsEnabled: false,
    hologramPresentationEnabled: false,
  );

  AppSettings withFriendPreferences(
    FriendPreferenceScope scope,
    FriendPreferences preferences,
  ) {
    final next = Map<FriendPreferenceScope, FriendPreferences>.of(
      friendPreferences,
    );
    if (preferences.isDefault) {
      next.remove(scope);
    } else {
      next[scope] = preferences;
    }
    return _copyWith(friendPreferences: next);
  }

  bool allowsFriendHolograms(FriendPreferenceScope scope) =>
      !friendPreferencesReviewRequired &&
      (friendPreferences[scope] ?? const FriendPreferences()).allowsHolograms(
        hologramPresentationEnabled,
      );

  bool allowsFriendMessageAlerts(FriendPreferenceScope scope) =>
      !friendPreferencesReviewRequired &&
      (friendPreferences[scope] ?? const FriendPreferences())
          .allowsMessageAlerts(messageAlertsEnabled);

  AppSettings forRestoredAccount({
    required String? sourceAccountId,
    required String accountId,
  }) {
    if (accountId.isEmpty) throw ArgumentError.value(accountId, 'accountId');
    if (conversationMicrophoneModes.isEmpty && friendPreferences.isEmpty) {
      return this;
    }
    if (sourceAccountId == null || sourceAccountId.isEmpty) {
      return _copyWith(
        microphoneReviewRequired:
            microphoneReviewRequired || conversationMicrophoneModes.isNotEmpty,
        friendPreferencesReviewRequired:
            friendPreferencesReviewRequired || friendPreferences.isNotEmpty,
      );
    }
    if (sourceAccountId == accountId) return this;
    final remapped = <ConversationScope, MicrophoneMode>{};
    for (final entry in conversationMicrophoneModes.entries) {
      final original = entry.key;
      final scope = original.accountId == sourceAccountId
          ? ConversationScope(
              accountId: accountId,
              peerId: original.peerId,
              conversationId: original.conversationId,
              kind: original.kind,
            )
          : original;
      // A collision cannot establish which recorded policy the user intended.
      // Keep every original scope for review instead of choosing either value.
      if (remapped.containsKey(scope)) {
        return _copyWith(
          microphoneReviewRequired: true,
          friendPreferencesReviewRequired:
              friendPreferencesReviewRequired || friendPreferences.isNotEmpty,
        );
      }
      remapped[scope] = entry.value;
    }
    final remappedFriends = <FriendPreferenceScope, FriendPreferences>{};
    for (final entry in friendPreferences.entries) {
      final scope = entry.key.accountId == sourceAccountId
          ? FriendPreferenceScope(
              accountId: accountId,
              peerId: entry.key.peerId,
            )
          : entry.key;
      if (remappedFriends.containsKey(scope)) {
        return _copyWith(
          conversationMicrophoneModes: remapped,
          friendPreferencesReviewRequired: true,
        );
      }
      remappedFriends[scope] = entry.value;
    }
    return _copyWith(
      conversationMicrophoneModes: remapped,
      friendPreferences: remappedFriends,
    );
  }

  AppSettings withConversationMicrophoneMode(
    ConversationScope scope,
    MicrophoneMode? mode,
  ) {
    final next = Map<ConversationScope, MicrophoneMode>.of(
      conversationMicrophoneModes,
    );
    if (mode == null) {
      next.remove(scope);
    } else {
      next[scope] = mode;
    }
    return _copyWith(conversationMicrophoneModes: next);
  }

  AppSettings withAppLockEnabled(bool enabled) =>
      _copyWith(appLockEnabled: enabled);

  AppSettings withFolderHistoryLimit(int value) =>
      _copyWith(folderHistoryLimit: value);

  AppSettings withMaxIncomingFileBytes(int value) =>
      _copyWith(maxIncomingFileBytes: value);

  AppSettings withAppearancePreset(AppearancePreset preset) =>
      _copyWith(appearancePreset: preset);

  AppSettings withAmbientVibe(AmbientVibe vibe) => _copyWith(ambientVibe: vibe);
  AppSettings withVibeIntensity(int intensity) =>
      _copyWith(vibeIntensity: intensity);
  AppSettings withVibeOpacity(int opacity) => _copyWith(vibeOpacity: opacity);

  AppSettings withRememberDefaultWindowPosition(bool remember) =>
      _copyWith(rememberDefaultWindowPosition: remember);

  AppSettings withWindowEdgeSpacing(WindowEdgeSpacing spacing) =>
      _copyWith(windowEdgeSpacing: spacing);

  AppSettings withWindowOpenAnimation(WindowCloseAnimation animation) =>
      _copyWith(windowOpenAnimation: animation);

  AppSettings withWindowMinimizeAnimation(WindowCloseAnimation animation) =>
      _copyWith(windowMinimizeAnimation: animation);

  AppSettings withWindowCloseAnimation(WindowCloseAnimation animation) =>
      _copyWith(windowCloseAnimation: animation);

  AppSettings withWindowOpenDurationMs(int duration) =>
      _copyWith(windowOpenDurationMs: duration);

  AppSettings withWindowMinimizeDurationMs(int duration) =>
      _copyWith(windowMinimizeDurationMs: duration);

  AppSettings withWindowCloseDurationMs(int duration) =>
      _copyWith(windowCloseDurationMs: duration);

  AppSettings withWindowsCaptureProtectionEnabled(bool enabled) =>
      _copyWith(windowsCaptureProtectionEnabled: enabled);

  AppSettings withShareActivityPresence(bool enabled) =>
      _copyWith(shareActivityPresence: enabled);

  AppSettings withIdentityColor(IdentityColor color) =>
      _copyWith(identityColor: color, identityColorManual: true);

  AppSettings withIdentityColorManual(bool manual) =>
      _copyWith(identityColorManual: manual);

  AppSettings withUnreadBadgePlacement(UnreadBadgePlacement placement) =>
      _copyWith(unreadBadgePlacement: placement);

  AppSettings withShowMessageInNotification(bool enabled) =>
      _copyWith(showMessageInNotification: enabled);

  AppSettings withHologramPresentationEnabled(bool enabled) =>
      _copyWith(hologramPresentationEnabled: enabled);

  AppSettings withReliableBackgroundNotifications(bool enabled) =>
      _copyWith(reliableBackgroundNotifications: enabled);

  AppSettings withGroupHeaderPlacement(GroupHeaderPlacement placement) =>
      _copyWith(groupHeaderPlacement: placement);

  AppSettings withMobileGroupNavigation(MobileGroupNavigation navigation) =>
      _copyWith(mobileGroupNavigation: navigation);

  AppSettings withChatMotionEnabled(bool enabled) =>
      _copyWith(chatMotionEnabled: enabled);

  AppSettings withChatActivityIndicatorsEnabled(bool enabled) =>
      _copyWith(chatActivityIndicatorsEnabled: enabled);

  AppSettings withMessageTimestampStyle(MessageTimestampStyle style) =>
      _copyWith(messageTimestampStyle: style);

  AppSettings withMessageReceiptStyle(MessageReceiptStyle style) =>
      _copyWith(messageReceiptStyle: style);

  AppSettings withMessageReceiptVisibility(
    MessageReceiptVisibility visibility,
  ) => _copyWith(messageReceiptVisibility: visibility);

  AppSettings withRepeatMessageAuthorAfterPause(bool enabled) =>
      _copyWith(repeatMessageAuthorAfterPause: enabled);

  AppSettings withTopicStripSurfaceSettings(
    TopicStripSurfaceSettings settings,
  ) => _copyWith(topicStripSurfaceSettings: settings);

  AppSettings _copyWith({
    MicrophoneMode? globalMicrophoneMode,
    bool? friendPreferencesReviewRequired,
    bool? messageAlertsEnabled,
    Map<FriendPreferenceScope, FriendPreferences>? friendPreferences,
    bool? microphoneReviewRequired,
    Map<ConversationScope, MicrophoneMode>? conversationMicrophoneModes,
    bool? appLockEnabled,
    int? folderHistoryLimit,
    int? maxIncomingFileBytes,
    AppearancePreset? appearancePreset,
    AmbientVibe? ambientVibe,
    int? vibeOpacity,
    int? vibeIntensity,
    bool? rememberDefaultWindowPosition,
    WindowEdgeSpacing? windowEdgeSpacing,
    WindowCloseAnimation? windowOpenAnimation,
    WindowCloseAnimation? windowMinimizeAnimation,
    WindowCloseAnimation? windowCloseAnimation,
    int? windowOpenDurationMs,
    int? windowMinimizeDurationMs,
    int? windowCloseDurationMs,
    bool? windowsCaptureProtectionEnabled,
    bool? shareActivityPresence,
    IdentityColor? identityColor,
    bool? identityColorManual,
    UnreadBadgePlacement? unreadBadgePlacement,
    bool? showMessageInNotification,
    bool? hologramPresentationEnabled,
    bool? reliableBackgroundNotifications,
    GroupHeaderPlacement? groupHeaderPlacement,
    MobileGroupNavigation? mobileGroupNavigation,
    bool? chatMotionEnabled,
    bool? chatActivityIndicatorsEnabled,
    MessageTimestampStyle? messageTimestampStyle,
    MessageReceiptStyle? messageReceiptStyle,
    MessageReceiptVisibility? messageReceiptVisibility,
    bool? repeatMessageAuthorAfterPause,
    TopicStripSurfaceSettings? topicStripSurfaceSettings,
  }) => AppSettings(
    globalMicrophoneMode: globalMicrophoneMode ?? this.globalMicrophoneMode,
    friendPreferencesReviewRequired:
        friendPreferencesReviewRequired ?? this.friendPreferencesReviewRequired,
    messageAlertsEnabled: messageAlertsEnabled ?? this.messageAlertsEnabled,
    friendPreferences: friendPreferences ?? this.friendPreferences,
    microphoneReviewRequired:
        microphoneReviewRequired ?? this.microphoneReviewRequired,
    conversationMicrophoneModes:
        conversationMicrophoneModes ?? this.conversationMicrophoneModes,
    appLockEnabled: appLockEnabled ?? this.appLockEnabled,
    folderHistoryLimit: folderHistoryLimit ?? this.folderHistoryLimit,
    maxIncomingFileBytes: maxIncomingFileBytes ?? this.maxIncomingFileBytes,
    appearancePreset: appearancePreset ?? this.appearancePreset,
    ambientVibe: ambientVibe ?? this.ambientVibe,
    vibeOpacity: vibeOpacity ?? this.vibeOpacity,
    vibeIntensity: vibeIntensity ?? this.vibeIntensity,
    rememberDefaultWindowPosition:
        rememberDefaultWindowPosition ?? this.rememberDefaultWindowPosition,
    windowEdgeSpacing: windowEdgeSpacing ?? this.windowEdgeSpacing,
    windowOpenAnimation: windowOpenAnimation ?? this.windowOpenAnimation,
    windowMinimizeAnimation:
        windowMinimizeAnimation ?? this.windowMinimizeAnimation,
    windowCloseAnimation: windowCloseAnimation ?? this.windowCloseAnimation,
    windowOpenDurationMs: windowOpenDurationMs ?? this.windowOpenDurationMs,
    windowMinimizeDurationMs:
        windowMinimizeDurationMs ?? this.windowMinimizeDurationMs,
    windowCloseDurationMs: windowCloseDurationMs ?? this.windowCloseDurationMs,
    windowsCaptureProtectionEnabled:
        windowsCaptureProtectionEnabled ?? this.windowsCaptureProtectionEnabled,
    shareActivityPresence: shareActivityPresence ?? this.shareActivityPresence,
    identityColor: identityColor ?? this.identityColor,
    identityColorManual: identityColorManual ?? this.identityColorManual,
    unreadBadgePlacement: unreadBadgePlacement ?? this.unreadBadgePlacement,
    showMessageInNotification:
        showMessageInNotification ?? this.showMessageInNotification,
    hologramPresentationEnabled:
        hologramPresentationEnabled ?? this.hologramPresentationEnabled,
    reliableBackgroundNotifications:
        reliableBackgroundNotifications ?? this.reliableBackgroundNotifications,
    groupHeaderPlacement: groupHeaderPlacement ?? this.groupHeaderPlacement,
    mobileGroupNavigation: mobileGroupNavigation ?? this.mobileGroupNavigation,
    chatMotionEnabled: chatMotionEnabled ?? this.chatMotionEnabled,
    chatActivityIndicatorsEnabled:
        chatActivityIndicatorsEnabled ?? this.chatActivityIndicatorsEnabled,
    messageTimestampStyle: messageTimestampStyle ?? this.messageTimestampStyle,
    messageReceiptStyle: messageReceiptStyle ?? this.messageReceiptStyle,
    messageReceiptVisibility:
        messageReceiptVisibility ?? this.messageReceiptVisibility,
    repeatMessageAuthorAfterPause:
        repeatMessageAuthorAfterPause ?? this.repeatMessageAuthorAfterPause,
    topicStripSurfaceSettings:
        topicStripSurfaceSettings ?? this.topicStripSurfaceSettings,
  );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! AppSettings ||
        friendPreferencesReviewRequired !=
            other.friendPreferencesReviewRequired ||
        messageAlertsEnabled != other.messageAlertsEnabled ||
        friendPreferences.length != other.friendPreferences.length ||
        globalMicrophoneMode != other.globalMicrophoneMode ||
        microphoneReviewRequired != other.microphoneReviewRequired ||
        appLockEnabled != other.appLockEnabled ||
        folderHistoryLimit != other.folderHistoryLimit ||
        maxIncomingFileBytes != other.maxIncomingFileBytes ||
        appearancePreset != other.appearancePreset ||
        ambientVibe != other.ambientVibe ||
        vibeOpacity != other.vibeOpacity ||
        vibeIntensity != other.vibeIntensity ||
        rememberDefaultWindowPosition != other.rememberDefaultWindowPosition ||
        windowEdgeSpacing != other.windowEdgeSpacing ||
        windowOpenAnimation != other.windowOpenAnimation ||
        windowMinimizeAnimation != other.windowMinimizeAnimation ||
        windowCloseAnimation != other.windowCloseAnimation ||
        windowOpenDurationMs != other.windowOpenDurationMs ||
        windowMinimizeDurationMs != other.windowMinimizeDurationMs ||
        windowCloseDurationMs != other.windowCloseDurationMs ||
        windowsCaptureProtectionEnabled !=
            other.windowsCaptureProtectionEnabled ||
        shareActivityPresence != other.shareActivityPresence ||
        identityColor != other.identityColor ||
        identityColorManual != other.identityColorManual ||
        unreadBadgePlacement != other.unreadBadgePlacement ||
        showMessageInNotification != other.showMessageInNotification ||
        hologramPresentationEnabled != other.hologramPresentationEnabled ||
        reliableBackgroundNotifications !=
            other.reliableBackgroundNotifications ||
        groupHeaderPlacement != other.groupHeaderPlacement ||
        mobileGroupNavigation != other.mobileGroupNavigation ||
        chatMotionEnabled != other.chatMotionEnabled ||
        chatActivityIndicatorsEnabled != other.chatActivityIndicatorsEnabled ||
        messageTimestampStyle != other.messageTimestampStyle ||
        messageReceiptStyle != other.messageReceiptStyle ||
        messageReceiptVisibility != other.messageReceiptVisibility ||
        repeatMessageAuthorAfterPause != other.repeatMessageAuthorAfterPause ||
        topicStripSurfaceSettings != other.topicStripSurfaceSettings ||
        conversationMicrophoneModes.length !=
            other.conversationMicrophoneModes.length) {
      return false;
    }
    for (final entry in conversationMicrophoneModes.entries) {
      if (other.conversationMicrophoneModes[entry.key] != entry.value) {
        return false;
      }
    }
    for (final entry in friendPreferences.entries) {
      if (other.friendPreferences[entry.key] != entry.value) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    Object.hash(
      globalMicrophoneMode,
      microphoneReviewRequired,
      friendPreferencesReviewRequired,
      messageAlertsEnabled,
      Object.hashAllUnordered(
        friendPreferences.entries.map(
          (entry) => Object.hash(entry.key, entry.value),
        ),
      ),
    ),
    appLockEnabled,
    folderHistoryLimit,
    maxIncomingFileBytes,
    Object.hash(
      appearancePreset,
      ambientVibe,
      vibeOpacity,
      vibeIntensity,
      rememberDefaultWindowPosition,
      windowEdgeSpacing,
      windowOpenAnimation,
      windowMinimizeAnimation,
      windowCloseAnimation,
      windowOpenDurationMs,
      windowMinimizeDurationMs,
      windowCloseDurationMs,
    ),
    windowsCaptureProtectionEnabled,
    shareActivityPresence,
    Object.hash(identityColor, identityColorManual),
    unreadBadgePlacement,
    Object.hash(
      showMessageInNotification,
      reliableBackgroundNotifications,
      hologramPresentationEnabled,
    ),
    groupHeaderPlacement,
    mobileGroupNavigation,
    chatMotionEnabled,
    chatActivityIndicatorsEnabled,
    messageTimestampStyle,
    messageReceiptStyle,
    messageReceiptVisibility,
    repeatMessageAuthorAfterPause,
    topicStripSurfaceSettings,
    Object.hashAllUnordered(
      conversationMicrophoneModes.entries.map(
        (entry) => Object.hash(entry.key, entry.value),
      ),
    ),
  );
}

final class DecodedAppSettings {
  const DecodedAppSettings({
    required this.settings,
    required this.sourceVersion,
    required this.needsRewrite,
  });

  final AppSettings settings;
  final int sourceVersion;
  final bool needsRewrite;
}

final class UnsupportedSettingsVersion implements Exception {
  const UnsupportedSettingsVersion(this.version);

  final int version;

  @override
  String toString() =>
      'UnsupportedSettingsVersion($version; current is '
      '${AppSettings.currentSchemaVersion})';
}

/// Strict codec for the single settings document.
///
/// Version 1 stored only `microphoneMode` (`open` or `ptt`). Version 2 uses a
/// nested microphone object and exact-scope overrides. Version 3 adds app
/// lock, bounded file-view/safety knobs, and a functional appearance preset to
/// the same document; the operating system still owns lock credentials.
/// Version 4 adds the Windows-only capture-protection preference; older
/// documents migrate with the conservative `enabled: true` default. Version 5
/// adds the Windows-only active-app presence opt-in; older documents migrate
/// with the privacy-preserving `shareActiveApp: false` default. Version 6 adds
/// unread-badge placement; version 5 migrates to the existing avatar badges.
/// Version 7 adds the desktop group-header placement preference; version 6
/// migrates to the current conversation-column placement. Version 8 adds the
/// mobile group-navigation preference; version 7 migrates to the current
/// inline topic strip. Version 9 adds default-on chat motion and ephemeral
/// activity indicators. Version 10 adds message timestamp, receipt, and
/// author-repeat presentation preferences. Version 11 adds the Android message
/// preview preference; version 10 migrates to the default-on preview. Version
/// 12 adds the shared DM/mobile-group topic-strip surface controls; version 11
/// migrates to the shipped surface values. Version 13 adds the backed-up
/// identity color; version 12 migrates to amber. Version 14 adds the optional
/// Android background-wake choice. Legacy default-on values do not establish
/// Google consent; only an explicit consent marker permits wake. Version 15
/// retains an unresolved backup microphone owner as an explicit review state.
/// Version 16 adds live hologram presentation, gated by message previews and runtime privacy.
/// Version 17 adds account-scoped friend preferences, their restore-review state,
/// and the global message-alert preference. Version 18 distinguishes fixed
/// profile colors from automatic colors without guessing old user intent.
/// Version 19 adds ambient vibes and the default-window placement preference.
/// Version 20 adds edge spacing; version 21 adds bounded ambient-vibe opacity.
/// Version 22 adds independent bounded ambient-vibe intensity.
/// Version 23 adds the Windows close animation; older settings use Move.
/// Version 24 adds independent open, minimize, and close styles and durations.
/// Native readers share this document.
final class AppSettingsCodec {
  const AppSettingsCodec();

  DecodedAppSettings decode(Map<String, Object?> document) {
    final versionValue = document['schemaVersion'];
    final version = switch (versionValue) {
      int value => value,
      null when document.containsKey('microphoneMode') => 1,
      _ => throw const FormatException(
        'settings schemaVersion must be an integer',
      ),
    };
    if (version > AppSettings.currentSchemaVersion) {
      throw UnsupportedSettingsVersion(version);
    }
    if (version < 1) {
      throw FormatException('unsupported settings schemaVersion $version');
    }

    return DecodedAppSettings(
      settings: switch (version) {
        1 => _decodeVersion1(document),
        2 => _decodeVersion2(document),
        3 => _decodeVersion3(document),
        4 => _decodeVersion4(document),
        5 => _decodeVersion5(document),
        6 => _decodeVersion6(document),
        7 => _decodeVersion7(document),
        8 => _decodeVersion8(document),
        9 => _decodeVersion9(document),
        10 => _decodeVersion10(document),
        11 => _decodeVersion11(document),
        12 => _decodeVersion12(document),
        13 => _decodeVersion13(document),
        14 => _decodeVersion14(document),
        15 => _decodeVersion15(document),
        16 => _decodeVersion16(document),
        17 => _decodeVersion17(document),
        18 => _decodeVersion18(document),
        19 => _decodeVersion19(document),
        20 => _decodeVersion20(document),
        21 => _decodeVersion21(document),
        22 => _decodeVersion22(document),
        23 => _decodeVersion23(document),
        AppSettings.currentSchemaVersion => _decodeVersion24(document),
        _ => throw FormatException('missing migration from version $version'),
      },
      sourceVersion: version,
      needsRewrite:
          version != AppSettings.currentSchemaVersion ||
          (document['notifications'] is Map &&
              !(document['notifications'] as Map).containsKey(
                'googleWakeConsent',
              )),
    );
  }

  Map<String, Object?> encode(AppSettings settings) {
    final overrides = settings.conversationMicrophoneModes.entries.toList()
      ..sort((left, right) {
        final account = left.key.accountId.compareTo(right.key.accountId);
        if (account != 0) return account;
        final peer = left.key.peerId.compareTo(right.key.peerId);
        if (peer != 0) return peer;
        return left.key.conversationId.compareTo(right.key.conversationId);
      });
    final friendOverrides = settings.friendPreferences.entries.toList()
      ..sort((left, right) {
        final account = left.key.accountId.compareTo(right.key.accountId);
        return account != 0
            ? account
            : left.key.peerId.compareTo(right.key.peerId);
      });
    return {
      'schemaVersion': AppSettings.currentSchemaVersion,
      'friendPreferences': {
        'reviewRequired': settings.friendPreferencesReviewRequired,
        'overrides': [
          for (final entry in friendOverrides)
            {...entry.key.toMap(), ...entry.value.toMap()},
        ],
      },
      'microphone': {
        'globalDefault': settings.globalMicrophoneMode.storageValue,
        'reviewRequired': settings.microphoneReviewRequired,
        'conversationOverrides': [
          for (final entry in overrides)
            {...entry.key.toMap(), 'mode': entry.value.storageValue},
        ],
      },
      'appLock': {'enabled': settings.appLockEnabled},
      'files': {
        'folderHistoryLimit': settings.folderHistoryLimit,
        'maxIncomingFileBytes': settings.maxIncomingFileBytes,
      },
      'appearance': {
        'vibe': settings.ambientVibe.name,
        'vibeOpacity': settings.vibeOpacity,
        'vibeIntensity': settings.vibeIntensity,
        'rememberDefaultWindowPosition': settings.rememberDefaultWindowPosition,
        'windowEdgeSpacing': settings.windowEdgeSpacing.name,
        'windowOpenAnimation': settings.windowOpenAnimation.name,
        'windowMinimizeAnimation': settings.windowMinimizeAnimation.name,
        'windowCloseAnimation': settings.windowCloseAnimation.name,
        'windowOpenDurationMs': settings.windowOpenDurationMs,
        'windowMinimizeDurationMs': settings.windowMinimizeDurationMs,
        'windowCloseDurationMs': settings.windowCloseDurationMs,
        'preset': settings.appearancePreset.storageValue,
        'groupHeaderPlacement': settings.groupHeaderPlacement.storageValue,
        'mobileGroupNavigation': settings.mobileGroupNavigation.storageValue,
        'chatMotionEnabled': settings.chatMotionEnabled,
        'chatActivityIndicatorsEnabled': settings.chatActivityIndicatorsEnabled,
        'messageTimestampStyle': settings.messageTimestampStyle.storageValue,
        'messageReceiptStyle': settings.messageReceiptStyle.storageValue,
        'messageReceiptVisibility':
            settings.messageReceiptVisibility.storageValue,
        'repeatMessageAuthorAfterPause': settings.repeatMessageAuthorAfterPause,
        'topicStripSurface': {
          'coverage': settings.topicStripSurfaceSettings.coverage.storageValue,
          'strength': settings.topicStripSurfaceSettings.strength,
          'blur': settings.topicStripSurfaceSettings.blur,
          'solidReach': settings.topicStripSurfaceSettings.solidReach,
          'lowerFade': settings.topicStripSurfaceSettings.lowerFade,
          'rightFade': settings.topicStripSurfaceSettings.rightFade,
        },
      },
      'windowsCaptureProtection': {
        'enabled': settings.windowsCaptureProtectionEnabled,
      },
      'presence': {'shareActiveApp': settings.shareActivityPresence},
      'profile': {
        'identityColor': settings.identityColor.storageValue,
        'identityColorManual': settings.identityColorManual,
      },
      'notifications': {
        'messageAlertsEnabled': settings.messageAlertsEnabled,
        'unreadBadgePlacement': settings.unreadBadgePlacement.storageValue,
        'showMessage': settings.showMessageInNotification,
        'hologramPresentationEnabled': settings.hologramPresentationEnabled,
        'reliableBackground': settings.reliableBackgroundNotifications,
        'googleWakeConsent': settings.reliableBackgroundNotifications,
      },
    };
  }

  AppSettings _decodeVersion1(Map<String, Object?> document) {
    final legacy = document['microphoneMode'];
    final mode = switch (legacy) {
      'open' => MicrophoneMode.open,
      'ptt' => MicrophoneMode.pushToTalk,
      _ => throw const FormatException(
        'version 1 microphoneMode must be open or ptt',
      ),
    };
    return AppSettings(globalMicrophoneMode: mode);
  }

  AppSettings _decodeVersion2(Map<String, Object?> document) =>
      _decodeMicrophone(document, appLockEnabled: false);

  AppSettings _decodeVersion3(
    Map<String, Object?> document, {
    bool windowsCaptureProtectionEnabled = true,
    bool shareActivityPresence = false,
  }) {
    final appLockValue = document['appLock'];
    if (appLockValue is! Map || appLockValue['enabled'] is! bool) {
      throw const FormatException('appLock.enabled must be a boolean');
    }
    final filesValue = document['files'];
    final folderHistoryLimit = filesValue is Map
        ? filesValue['folderHistoryLimit']
        : null;
    final maxIncomingFileBytes = filesValue is Map
        ? filesValue['maxIncomingFileBytes']
        : null;
    if (folderHistoryLimit is! int ||
        !AppSettings.isValidFolderHistoryLimit(folderHistoryLimit)) {
      throw const FormatException('files.folderHistoryLimit is invalid');
    }
    if (maxIncomingFileBytes is! int ||
        !AppSettings.isValidMaxIncomingFileBytes(maxIncomingFileBytes)) {
      throw const FormatException('files.maxIncomingFileBytes is invalid');
    }
    final appearanceValue = document['appearance'];
    final appearancePreset = appearanceValue is Map
        ? AppearancePreset.tryParse(appearanceValue['preset'])
        : null;
    if (appearancePreset == null) {
      throw const FormatException('appearance.preset is invalid');
    }
    return _decodeMicrophone(
      document,
      appLockEnabled: appLockValue['enabled'] as bool,
      folderHistoryLimit: folderHistoryLimit,
      maxIncomingFileBytes: maxIncomingFileBytes,
      appearancePreset: appearancePreset,
      windowsCaptureProtectionEnabled: windowsCaptureProtectionEnabled,
      shareActivityPresence: shareActivityPresence,
    );
  }

  AppSettings _decodeVersion4(Map<String, Object?> document) {
    final captureValue = document['windowsCaptureProtection'];
    if (captureValue is! Map || captureValue['enabled'] is! bool) {
      throw const FormatException(
        'windowsCaptureProtection.enabled must be a boolean',
      );
    }
    return _decodeVersion3(
      document,
      windowsCaptureProtectionEnabled: captureValue['enabled'] as bool,
    );
  }

  AppSettings _decodeVersion5(Map<String, Object?> document) {
    final presenceValue = document['presence'];
    if (presenceValue is! Map || presenceValue['shareActiveApp'] is! bool) {
      throw const FormatException('presence.shareActiveApp must be a boolean');
    }
    final captureValue = document['windowsCaptureProtection'];
    if (captureValue is! Map || captureValue['enabled'] is! bool) {
      throw const FormatException(
        'windowsCaptureProtection.enabled must be a boolean',
      );
    }
    return _decodeVersion3(
      document,
      windowsCaptureProtectionEnabled: captureValue['enabled'] as bool,
      shareActivityPresence: presenceValue['shareActiveApp'] as bool,
    );
  }

  AppSettings _decodeVersion6(Map<String, Object?> document) {
    final notificationsValue = document['notifications'];
    final placement = notificationsValue is Map
        ? UnreadBadgePlacement.tryParse(
            notificationsValue['unreadBadgePlacement'],
          )
        : null;
    if (placement == null) {
      throw const FormatException(
        'notifications.unreadBadgePlacement is invalid',
      );
    }
    return _decodeVersion5(document).withUnreadBadgePlacement(placement);
  }

  AppSettings _decodeVersion7(Map<String, Object?> document) {
    final appearanceValue = document['appearance'];
    final placement = appearanceValue is Map
        ? GroupHeaderPlacement.tryParse(appearanceValue['groupHeaderPlacement'])
        : null;
    if (placement == null) {
      throw const FormatException('appearance.groupHeaderPlacement is invalid');
    }
    return _decodeVersion6(document).withGroupHeaderPlacement(placement);
  }

  AppSettings _decodeVersion8(Map<String, Object?> document) {
    final appearanceValue = document['appearance'];
    final navigation = appearanceValue is Map
        ? MobileGroupNavigation.tryParse(
            appearanceValue['mobileGroupNavigation'],
          )
        : null;
    if (navigation == null) {
      throw const FormatException(
        'appearance.mobileGroupNavigation is invalid',
      );
    }
    return _decodeVersion7(document).withMobileGroupNavigation(navigation);
  }

  AppSettings _decodeVersion9(Map<String, Object?> document) {
    final appearanceValue = document['appearance'];
    if (appearanceValue is! Map ||
        appearanceValue['chatMotionEnabled'] is! bool ||
        appearanceValue['chatActivityIndicatorsEnabled'] is! bool) {
      throw const FormatException(
        'appearance chat experience settings must be booleans',
      );
    }
    return _decodeVersion8(document)
        .withChatMotionEnabled(appearanceValue['chatMotionEnabled'] as bool)
        .withChatActivityIndicatorsEnabled(
          appearanceValue['chatActivityIndicatorsEnabled'] as bool,
        );
  }

  AppSettings _decodeVersion10(Map<String, Object?> document) {
    final appearanceValue = document['appearance'];
    final timestampStyle = appearanceValue is Map
        ? MessageTimestampStyle.tryParse(
            appearanceValue['messageTimestampStyle'],
          )
        : null;
    final receiptStyle = appearanceValue is Map
        ? MessageReceiptStyle.tryParse(appearanceValue['messageReceiptStyle'])
        : null;
    final receiptVisibility = appearanceValue is Map
        ? MessageReceiptVisibility.tryParse(
            appearanceValue['messageReceiptVisibility'],
          )
        : null;
    if (appearanceValue is! Map ||
        timestampStyle == null ||
        receiptStyle == null ||
        receiptVisibility == null ||
        appearanceValue['repeatMessageAuthorAfterPause'] is! bool) {
      throw const FormatException(
        'appearance message presentation settings are invalid',
      );
    }
    return _decodeVersion9(document)
        .withMessageTimestampStyle(timestampStyle)
        .withMessageReceiptStyle(receiptStyle)
        .withMessageReceiptVisibility(receiptVisibility)
        .withRepeatMessageAuthorAfterPause(
          appearanceValue['repeatMessageAuthorAfterPause'] as bool,
        );
  }

  AppSettings _decodeVersion11(Map<String, Object?> document) {
    final notificationsValue = document['notifications'];
    if (notificationsValue is! Map ||
        notificationsValue['showMessage'] is! bool) {
      throw const FormatException(
        'notifications.showMessage must be a boolean',
      );
    }
    return _decodeVersion10(
      document,
    ).withShowMessageInNotification(notificationsValue['showMessage'] as bool);
  }

  AppSettings _decodeVersion12(Map<String, Object?> document) {
    final appearanceValue = document['appearance'];
    final surfaceValue = appearanceValue is Map
        ? appearanceValue['topicStripSurface']
        : null;
    if (surfaceValue is! Map) {
      throw const FormatException(
        'appearance.topicStripSurface must be an object',
      );
    }
    final coverage = TopicStripSurfaceCoverage.tryParse(
      surfaceValue['coverage'],
    );
    final strength = surfaceValue['strength'];
    final blur = surfaceValue['blur'];
    final solidReach = surfaceValue['solidReach'];
    final lowerFade = surfaceValue['lowerFade'];
    final rightFade = surfaceValue['rightFade'];
    if (coverage == null ||
        strength is! int ||
        strength < 0 ||
        strength > TopicStripSurfaceSettings.maxStrength ||
        blur is! int ||
        blur < 0 ||
        blur > TopicStripSurfaceSettings.maxBlur ||
        solidReach is! int ||
        solidReach < 0 ||
        solidReach > TopicStripSurfaceSettings.maxSolidReach ||
        lowerFade is! int ||
        lowerFade < 0 ||
        lowerFade > TopicStripSurfaceSettings.maxLowerFade ||
        rightFade is! int ||
        rightFade < 0 ||
        rightFade > TopicStripSurfaceSettings.maxRightFade) {
      throw const FormatException(
        'appearance.topicStripSurface values are invalid',
      );
    }
    return _decodeVersion11(document).withTopicStripSurfaceSettings(
      TopicStripSurfaceSettings(
        coverage: coverage,
        strength: strength,
        blur: blur,
        solidReach: solidReach,
        lowerFade: lowerFade,
        rightFade: rightFade,
      ),
    );
  }

  AppSettings _decodeVersion13(Map<String, Object?> document) {
    final profileValue = document['profile'];
    final identityColor = profileValue is Map
        ? IdentityColor.tryParse(profileValue['identityColor'])
        : null;
    if (identityColor == null) {
      throw const FormatException('profile.identityColor is invalid');
    }
    return _decodeVersion12(document).withIdentityColor(identityColor);
  }

  AppSettings _decodeVersion14(Map<String, Object?> document) {
    final notificationsValue = document['notifications'];
    if (notificationsValue is! Map ||
        notificationsValue['reliableBackground'] is! bool) {
      throw const FormatException(
        'notifications.reliableBackground must be a boolean',
      );
    }
    return _decodeVersion13(document).withReliableBackgroundNotifications(
      notificationsValue['reliableBackground'] == true &&
          notificationsValue['googleWakeConsent'] == true,
    );
  }

  AppSettings _decodeVersion15(Map<String, Object?> document) {
    final microphone = document['microphone'];
    if (microphone is! Map || microphone['reviewRequired'] is! bool) {
      throw const FormatException(
        'microphone.reviewRequired must be a boolean',
      );
    }
    return _decodeVersion14(
      document,
    ).withMicrophoneReviewRequired(microphone['reviewRequired'] as bool);
  }

  AppSettings _decodeVersion16(Map<String, Object?> document) {
    final notifications = document['notifications'];
    if (notifications is! Map ||
        notifications['hologramPresentationEnabled'] is! bool) {
      throw const FormatException(
        'notifications.hologramPresentationEnabled must be a boolean',
      );
    }
    return _decodeVersion15(document).withHologramPresentationEnabled(
      notifications['hologramPresentationEnabled'] as bool,
    );
  }

  AppSettings _decodeVersion17(Map<String, Object?> document) {
    final friends = document['friendPreferences'];
    final notifications = document['notifications'];
    if (friends is! Map ||
        friends['reviewRequired'] is! bool ||
        friends['overrides'] is! List ||
        notifications is! Map ||
        notifications['messageAlertsEnabled'] is! bool) {
      throw const FormatException('invalid friend preferences');
    }
    final entries = friends['overrides'] as List;
    if (entries.length > 256) {
      throw const FormatException('too many friend preferences');
    }
    final overrides = <FriendPreferenceScope, FriendPreferences>{};
    for (final entry in entries) {
      if (entry is! Map) {
        throw const FormatException('invalid friend preference');
      }
      final scope = FriendPreferenceScope.fromMap(entry);
      if (overrides.containsKey(scope)) {
        throw const FormatException('duplicate friend preference owner');
      }
      overrides[scope] = FriendPreferences.fromMap(entry);
    }
    return _decodeVersion16(document)._copyWith(
      friendPreferences: overrides,
      friendPreferencesReviewRequired: friends['reviewRequired'] as bool,
      messageAlertsEnabled: notifications['messageAlertsEnabled'] as bool,
    );
  }

  AppSettings _decodeVersion23(Map<String, Object?> document) {
    final appearance = document['appearance'];
    final animation = WindowCloseAnimation.values.where(
      (value) =>
          value != WindowCloseAnimation.fade &&
          appearance is Map &&
          value.name == appearance['windowCloseAnimation'],
    );
    if (animation.isEmpty) {
      throw const FormatException('invalid window close animation');
    }
    return _decodeVersion22(
      document,
    ).withWindowCloseAnimation(animation.single);
  }

  AppSettings _decodeVersion24(Map<String, Object?> document) {
    final appearance = document['appearance'];
    if (appearance is! Map) {
      throw const FormatException('invalid window animation settings');
    }
    final openAnimation = _decodeWindowAnimation(
      appearance,
      'windowOpenAnimation',
    );
    final minimizeAnimation = _decodeWindowAnimation(
      appearance,
      'windowMinimizeAnimation',
    );
    final closeAnimation = _decodeWindowAnimation(
      appearance,
      'windowCloseAnimation',
    );
    final openDuration = _decodeWindowAnimationDuration(
      appearance,
      'windowOpenDurationMs',
    );
    final minimizeDuration = _decodeWindowAnimationDuration(
      appearance,
      'windowMinimizeDurationMs',
    );
    final closeDuration = _decodeWindowAnimationDuration(
      appearance,
      'windowCloseDurationMs',
    );
    return _decodeVersion22(document)
        .withWindowCloseAnimation(closeAnimation)
        .withWindowOpenAnimation(openAnimation)
        .withWindowMinimizeAnimation(minimizeAnimation)
        .withWindowOpenDurationMs(openDuration)
        .withWindowMinimizeDurationMs(minimizeDuration)
        .withWindowCloseDurationMs(closeDuration);
  }

  WindowCloseAnimation _decodeWindowAnimation(Map appearance, String key) {
    final animation = WindowCloseAnimation.values.where(
      (value) => value.name == appearance[key],
    );
    if (animation.isEmpty) {
      throw FormatException('invalid $key');
    }
    return animation.single;
  }

  int _decodeWindowAnimationDuration(Map appearance, String key) {
    final duration = appearance[key];
    if (duration is! int ||
        !AppSettings.isValidWindowAnimationDuration(duration)) {
      throw FormatException('invalid $key');
    }
    return duration;
  }

  AppSettings _decodeVersion22(Map<String, Object?> document) {
    final appearance = document['appearance'];
    final intensity = appearance is Map ? appearance['vibeIntensity'] : null;
    if (intensity is! int || intensity < 0 || intensity > 100) {
      throw const FormatException('invalid vibe intensity');
    }
    return _decodeVersion21(document).withVibeIntensity(intensity);
  }

  AppSettings _decodeVersion21(Map<String, Object?> document) {
    final appearance = document['appearance'];
    final opacity = appearance is Map ? appearance['vibeOpacity'] : null;
    if (opacity is! int || opacity < 0 || opacity > 100) {
      throw const FormatException('invalid vibe opacity');
    }
    return _decodeVersion20(document).withVibeOpacity(opacity);
  }

  AppSettings _decodeVersion20(Map<String, Object?> document) {
    final appearance = document['appearance'];
    if (appearance is! Map) {
      throw const FormatException('invalid window edge spacing');
    }
    final spacing = WindowEdgeSpacing.values.where(
      (value) => value.name == appearance['windowEdgeSpacing'],
    );
    if (spacing.isEmpty) {
      throw const FormatException('invalid window edge spacing');
    }
    return _decodeVersion19(document).withWindowEdgeSpacing(spacing.single);
  }

  AppSettings _decodeVersion19(Map<String, Object?> document) {
    final appearance = document['appearance'];
    if (appearance is! Map ||
        appearance['rememberDefaultWindowPosition'] is! bool) {
      throw const FormatException('invalid window placement preference');
    }
    final vibe = AmbientVibe.values.where((v) => v.name == appearance['vibe']);
    if (vibe.isEmpty) throw const FormatException('invalid ambient vibe');
    return _decodeVersion18(document)
        .withAmbientVibe(vibe.single)
        .withRememberDefaultWindowPosition(
          appearance['rememberDefaultWindowPosition'] as bool,
        );
  }

  AppSettings _decodeVersion18(Map<String, Object?> document) {
    final profile = document['profile'];
    if (profile is! Map || profile['identityColorManual'] is! bool) {
      throw const FormatException(
        'profile.identityColorManual must be a boolean',
      );
    }
    return _decodeVersion17(
      document,
    ).withIdentityColorManual(profile['identityColorManual'] as bool);
  }

  AppSettings _decodeMicrophone(
    Map<String, Object?> document, {
    required bool appLockEnabled,
    int folderHistoryLimit = AppSettings.defaultFolderHistoryLimit,
    int maxIncomingFileBytes = AppSettings.defaultMaxIncomingFileBytes,
    AppearancePreset appearancePreset = AppearancePreset.disaccord,
    bool windowsCaptureProtectionEnabled = true,
    bool shareActivityPresence = false,
    IdentityColor identityColor = IdentityColor.amber,
  }) {
    final microphoneValue = document['microphone'];
    if (microphoneValue is! Map) {
      throw const FormatException('microphone settings must be an object');
    }
    final globalMode = MicrophoneMode.tryParse(
      microphoneValue['globalDefault'],
    );
    if (globalMode == null) {
      throw const FormatException('invalid microphone globalDefault');
    }
    final overridesValue = microphoneValue['conversationOverrides'];
    if (overridesValue is! List) {
      throw const FormatException(
        'microphone conversationOverrides must be a list',
      );
    }
    final overrides = <ConversationScope, MicrophoneMode>{};
    for (final value in overridesValue) {
      if (value is Map &&
          value.containsKey('kind') &&
          !const {'direct', 'group'}.contains(value['kind'])) {
        throw const FormatException('invalid microphone scope kind');
      }
      final scope = ConversationScope.tryParse(value);
      final mode = value is Map ? MicrophoneMode.tryParse(value['mode']) : null;
      if (scope == null || mode == null) {
        throw const FormatException('invalid microphone override');
      }
      if (overrides.containsKey(scope)) {
        throw FormatException('duplicate microphone override for $scope');
      }
      overrides[scope] = mode;
    }
    return AppSettings(
      globalMicrophoneMode: globalMode,
      conversationMicrophoneModes: overrides,
      appLockEnabled: appLockEnabled,
      folderHistoryLimit: folderHistoryLimit,
      maxIncomingFileBytes: maxIncomingFileBytes,
      appearancePreset: appearancePreset,
      windowsCaptureProtectionEnabled: windowsCaptureProtectionEnabled,
      shareActivityPresence: shareActivityPresence,
      identityColor: identityColor,
    );
  }
}

/// Minimal persistence port for the existing application settings backend.
///
/// A SharedPreferences adapter can implement this without introducing another
/// database or storage owner.
abstract interface class AppSettingsDocumentStore {
  Future<Map<String, Object?>?> readDocument();

  Future<void> writeDocument(Map<String, Object?> document);
}

final class VersionedAppSettingsRepository {
  const VersionedAppSettingsRepository(
    this.store, {
    this.codec = const AppSettingsCodec(),
  });

  final AppSettingsDocumentStore store;
  final AppSettingsCodec codec;

  /// A failed migration write does not discard settings that decoded correctly.
  /// The caller can report the write failure while it uses the saved policy.
  Future<AppSettings> load({
    void Function(Object error)? onMigrationWriteFailure,
  }) async {
    final document = await store.readDocument();
    if (document == null) return AppSettings();
    final decoded = codec.decode(document);
    if (decoded.needsRewrite) {
      try {
        await store.writeDocument(codec.encode(decoded.settings));
      } catch (error) {
        onMigrationWriteFailure?.call(error);
      }
    }
    return decoded.settings;
  }

  Future<void> save(AppSettings settings) =>
      store.writeDocument(codec.encode(settings));
}
