import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/app_settings.dart';
import 'package:sybl/state/conversation_scope.dart';
import 'package:sybl/state/microphone_policy.dart';

void main() {
  final scope = ConversationScope(
    accountId: 'account',
    peerId: 'peer',
    conversationId: 'conversation',
  );

  MicrophoneDecision evaluate({
    MicrophoneMode mode = MicrophoneMode.open,
    bool sessionActive = true,
    bool privacySuspended = false,
    bool manuallyMuted = false,
    bool pushToTalkPressed = false,
  }) => MicrophonePolicy(
    effectiveMode: EffectiveMicrophoneMode(
      mode: mode,
      source: MicrophoneModeSource.globalDefault,
    ),
    sessionActive: sessionActive,
    privacySuspended: privacySuspended,
    manuallyMuted: manuallyMuted,
    pushToTalkPressed: pushToTalkPressed,
  ).evaluate();

  test('resolves the exact conversation override and reports its source', () {
    final settings = AppSettings(
      globalMicrophoneMode: MicrophoneMode.open,
      conversationMicrophoneModes: {scope: MicrophoneMode.voiceActivated},
    );
    final decision = MicrophonePolicy.forConversation(
      settings: settings,
      scope: scope,
      sessionActive: true,
    ).evaluate();

    expect(
      decision.effectiveMode,
      const EffectiveMicrophoneMode(
        mode: MicrophoneMode.voiceActivated,
        source: MicrophoneModeSource.conversationOverride,
      ),
    );
    expect(decision.muteCause, MicrophoneMuteCause.none);
    expect(decision.mayTransmit, isTrue);
  });

  test('open mode ignores the PTT transient input', () {
    for (final ptt in [false, true]) {
      expect(
        evaluate(mode: MicrophoneMode.open, pushToTalkPressed: ptt).muteCause,
        MicrophoneMuteCause.none,
      );
    }
  });

  test('push-to-talk transmits only while held', () {
    expect(
      evaluate(mode: MicrophoneMode.pushToTalk).muteCause,
      MicrophoneMuteCause.pushToTalkReleased,
    );
    expect(
      evaluate(
        mode: MicrophoneMode.pushToTalk,
        pushToTalkPressed: true,
      ).muteCause,
      MicrophoneMuteCause.none,
    );
  });

  test('voice activation does not masquerade as explicit mute', () {
    expect(
      evaluate(mode: MicrophoneMode.voiceActivated).muteCause,
      MicrophoneMuteCause.none,
    );
  });

  test('mute precedence is inactive, privacy, manual, then mode gate', () {
    for (final mode in MicrophoneMode.values) {
      expect(
        evaluate(
          mode: mode,
          sessionActive: false,
          privacySuspended: true,
          manuallyMuted: true,
        ).muteCause,
        MicrophoneMuteCause.inactiveSession,
      );
      expect(
        evaluate(
          mode: mode,
          privacySuspended: true,
          manuallyMuted: true,
        ).muteCause,
        MicrophoneMuteCause.privacySuspended,
      );
      expect(
        evaluate(
          mode: mode,
          manuallyMuted: true,
          pushToTalkPressed: false,
        ).muteCause,
        MicrophoneMuteCause.manualMute,
      );
    }
  });

  test('mustMute and mayTransmit are exact opposites', () {
    for (final cause in MicrophoneMuteCause.values) {
      final decision = MicrophoneDecision(
        effectiveMode: const EffectiveMicrophoneMode(
          mode: MicrophoneMode.open,
          source: MicrophoneModeSource.globalDefault,
        ),
        muteCause: cause,
      );
      expect(decision.mustMute, !decision.mayTransmit);
      expect(decision.mustMute, cause != MicrophoneMuteCause.none);
    }
  });
}
