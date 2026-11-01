import 'app_settings.dart';
import 'conversation_scope.dart';

/// Ordered by safety precedence in [MicrophonePolicy.evaluate].
enum MicrophoneMuteCause {
  inactiveSession,
  privacySuspended,
  manualMute,
  pushToTalkReleased,
  none,
}

final class MicrophoneDecision {
  const MicrophoneDecision({
    required this.effectiveMode,
    required this.muteCause,
  });

  final EffectiveMicrophoneMode effectiveMode;
  final MicrophoneMuteCause muteCause;

  bool get mustMute => muteCause != MicrophoneMuteCause.none;
  bool get mayTransmit => !mustMute;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MicrophoneDecision &&
          effectiveMode == other.effectiveMode &&
          muteCause == other.muteCause;

  @override
  int get hashCode => Object.hash(effectiveMode, muteCause);
}

/// Pure projection of persisted preference plus transient call controls.
///
/// It does not issue media commands. The caller must serialize and generation-
/// bind any mute command derived from [evaluate].
final class MicrophonePolicy {
  const MicrophonePolicy({
    required this.effectiveMode,
    required this.sessionActive,
    required this.privacySuspended,
    required this.manuallyMuted,
    required this.pushToTalkPressed,
  });

  factory MicrophonePolicy.forConversation({
    required AppSettings settings,
    required ConversationScope scope,
    required bool sessionActive,
    bool privacySuspended = false,
    bool manuallyMuted = false,
    bool pushToTalkPressed = false,
  }) => MicrophonePolicy(
    effectiveMode: settings.microphoneModeFor(scope),
    sessionActive: sessionActive,
    privacySuspended: privacySuspended,
    manuallyMuted: manuallyMuted,
    pushToTalkPressed: pushToTalkPressed,
  );

  final EffectiveMicrophoneMode effectiveMode;
  final bool sessionActive;
  final bool privacySuspended;
  final bool manuallyMuted;
  final bool pushToTalkPressed;

  MicrophoneDecision evaluate() {
    final cause = switch ((
      sessionActive,
      privacySuspended,
      manuallyMuted,
      effectiveMode.mode,
    )) {
      (false, _, _, _) => MicrophoneMuteCause.inactiveSession,
      (_, true, _, _) => MicrophoneMuteCause.privacySuspended,
      (_, _, true, _) => MicrophoneMuteCause.manualMute,
      (_, _, _, MicrophoneMode.pushToTalk) when !pushToTalkPressed =>
        MicrophoneMuteCause.pushToTalkReleased,
      _ => MicrophoneMuteCause.none,
    };
    return MicrophoneDecision(effectiveMode: effectiveMode, muteCause: cause);
  }
}
