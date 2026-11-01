import 'microphone_press_target.dart';
import 'dart:async';

import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../state/outgoing_video.dart';
import '../theme.dart';
import 'audio_output_action.dart';
import 'gravity.dart';
import 'screen_share_action.dart';
import 'sybl_ui.dart';
import 'window_presentation.dart';
import 'group_room_activity.dart';

/// The one persistent control surface for an active group call.
class GroupCallDock extends StatelessWidget {
  const GroupCallDock({
    super.key,
    required this.state,
    required this.onOpenCall,
    required this.onOpenSettings,
    this.compactHud = false,
    this.onBack,
  });

  final AppState state;
  final VoidCallback? onOpenCall;
  final VoidCallback onOpenSettings;
  final bool compactHud;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    if (compactHud) {
      final call = state.groupCall;
      if (call == null) return const SizedBox.shrink();
      final group = state.groups[call.conversationId];
      return Column(
        children: [
          CompactHeader(
            title: group?.layout.room(call.roomId)?.name ?? 'Voice chat',
            onBack: onBack,
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(9),
              child: Column(
                children: [
                  if (group != null)
                    RoomParticipantAvatars(
                      state: state,
                      group: group,
                      roomId: call.roomId,
                      size: 31,
                      showNames: true,
                    ),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _GroupMicAction(state: state, call: call),
                      CompactIconButton(
                        label: call.deafened ? 'Undeafen' : 'Deafen',
                        icon: call.deafened ? Icons.headset_off : Icons.headset,
                        active: call.deafened,
                        onPressed: call.connected
                            ? () => state.setGroupDeafened(!call.deafened)
                            : null,
                      ),
                      CompactIconButton(
                        label: 'Output device',
                        icon: Icons.volume_up,
                        onPressed: () => showAudioOutputPicker(context, state),
                      ),
                      Gravity(
                        child: IconButton(
                          tooltip: 'Leave voice',
                          onPressed: state.leaveGroupVoice,
                          style: IconButton.styleFrom(
                            backgroundColor: context.syblColors.danger
                                .withValues(alpha: .2),
                            foregroundColor: context.syblColors.danger,
                            minimumSize: const Size(44, 34),
                          ),
                          icon: const Icon(Icons.call_end, size: 18),
                        ),
                      ),
                      CompactIconButton(
                        label: 'Camera',
                        icon: Icons.videocam_outlined,
                        onPressed: call.connected
                            ? () async {
                                await WindowPresentationScope.maybeOf(
                                  context,
                                )?.setCompact(false);
                                await state.toggleGroupCamera();
                              }
                            : null,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }
    final call = state.groupCall!;
    final group = state.groups[call.conversationId];
    final room = group?.layout.room(call.roomId);
    final mobile = SyblLayout.isCompact(context);
    final changingCamera =
        call.sourceChanging &&
        (call.sourceChangeKind == OutgoingVideoKind.camera ||
            (call.sourceChangeKind == null && !call.screenShare));
    final changingScreen =
        call.sourceChanging &&
        call.sourceChangeKind == OutgoingVideoKind.screen;
    final name = state.displayName.trim().isEmpty ? 'You' : state.displayName;
    final status = switch (call.phase) {
      GroupCallPhase.connected => 'Voice connected',
      GroupCallPhase.joining => 'Connecting',
      GroupCallPhase.recovering => 'Reconnecting',
      GroupCallPhase.leaving => 'Leaving',
      GroupCallPhase.failed => call.error ?? 'Connection ended',
    };

    return TweenAnimationBuilder<double>(
      key: const ValueKey('group-call-dock-transition'),
      tween: Tween(begin: 0, end: 1),
      duration: SyblMotion.duration(context, const Duration(milliseconds: 240)),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) => ClipRect(
        child: Align(
          alignment: Alignment.bottomCenter,
          heightFactor: value,
          child: Opacity(opacity: value, child: child),
        ),
      ),
      child: Material(
        key: const ValueKey('group-call-dock'),
        color: context.syblColors.surfaceTop,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: context.syblColors.line)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 5, 5),
                child: Row(
                  children: [
                    Expanded(
                      child: Gravity(
                        child: Tooltip(
                          message: 'Open call',
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              onTap: call.connected ? onOpenCall : null,
                              borderRadius: BorderRadius.circular(8),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 3,
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.cast_connected_rounded,
                                      size: 18,
                                      color: call.connected
                                          ? context.syblColors.online
                                          : context.syblColors.muted,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            status,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              color: call.connected
                                                  ? context.syblColors.online
                                                  : context.syblColors.muted,
                                              fontSize: 11,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                          Text(
                                            '${group?.displayTitle ?? 'Group'} / ${room?.name ?? 'voice'}',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              color: context.syblColors.faint,
                                              fontSize: 10,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Icon(
                                      Icons.open_in_full_rounded,
                                      size: 14,
                                      color: context.syblColors.faint,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 5),
                    Gravity(
                      child: IconButton(
                        key: const ValueKey('group-voice-leave'),
                        tooltip: call.phase == GroupCallPhase.failed
                            ? 'Retry'
                            : 'Leave voice',
                        visualDensity: VisualDensity.compact,
                        style: IconButton.styleFrom(
                          minimumSize: const Size.square(32),
                          backgroundColor: call.phase == GroupCallPhase.failed
                              ? context.syblColors.surfaceHi
                              : context.syblColors.danger.withValues(
                                  alpha: .14,
                                ),
                          foregroundColor: call.phase == GroupCallPhase.failed
                              ? context.syblColors.ink
                              : context.syblColors.danger,
                          side: BorderSide(
                            color: call.phase == GroupCallPhase.failed
                                ? context.syblColors.lineStrong
                                : context.syblColors.danger.withValues(
                                    alpha: .75,
                                  ),
                          ),
                        ),
                        onPressed: call.phase == GroupCallPhase.failed
                            ? state.retryGroupVoice
                            : state.leaveGroupVoice,
                        icon: Icon(
                          call.phase == GroupCallPhase.failed
                              ? Icons.refresh_rounded
                              : Icons.call_end_rounded,
                          size: 18,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (mobile && call.phase != GroupCallPhase.failed)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 7),
                  child: Row(
                    children: [
                      Expanded(
                        child: _DockAction(
                          tooltip: call.video ? 'Stop camera' : 'Start camera',
                          selected: call.video,
                          busy: changingCamera,
                          onPressed: call.connected && !call.sourceChanging
                              ? state.toggleGroupCamera
                              : null,
                          icon: Icons.videocam_rounded,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Expanded(
                        child: _DockAction(
                          tooltip: call.screenShare
                              ? 'Stop sharing'
                              : 'Share screen',
                          selected: call.screenShare,
                          busy: changingScreen,
                          onPressed: call.connected && !call.sourceChanging
                              ? () => unawaited(
                                  toggleGroupScreenShareWithPicker(
                                    context,
                                    state,
                                    call,
                                  ),
                                )
                              : null,
                          icon: call.screenShare
                              ? Icons.stop_screen_share_rounded
                              : Icons.screen_share_rounded,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Expanded(
                        child: _DockAction(
                          tooltip: call.speakerOn ? 'Speaker' : 'Earpiece',
                          selected: call.speakerOn,
                          onPressed: call.connected
                              ? state.toggleGroupSpeaker
                              : null,
                          icon: audioOutputIcon(
                            state,
                            speakerOn: call.speakerOn,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              Container(
                key: const ValueKey('group-call-dock-account'),
                height: 48,
                color: context.syblColors.surfaceHi,
                padding: const EdgeInsets.fromLTRB(8, 0, 4, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Gravity(
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: context.syblColors.ink,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    _GroupMicAction(state: state, call: call),
                    _DockIconButton(
                      key: const ValueKey('group-voice-deafen'),
                      tooltip: call.deafened ? 'Undeafen' : 'Deafen',
                      onPressed: call.connected
                          ? () => state.setGroupDeafened(!call.deafened)
                          : null,
                      icon: call.deafened
                          ? Icons.headset_off_rounded
                          : Icons.headphones_rounded,
                    ),
                    _DockIconButton(
                      key: const ValueKey('group-call-dock-settings'),
                      tooltip: 'Settings',
                      onPressed: onOpenSettings,
                      icon: Icons.settings_rounded,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _GroupMicMenuAction { open, pushToTalk, inputDevice }

class _GroupMicAction extends StatelessWidget {
  const _GroupMicAction({required this.state, required this.call});

  final AppState state;
  final GroupCallSession call;

  @override
  Widget build(BuildContext context) {
    final pushToTalk = call.micMode == MicrophoneMode.pushToTalk;
    final mic = MicrophonePressTarget(
      key: ValueKey(('group-voice-mic', call.conferenceId)),
      pushToTalk: pushToTalk,
      enabled: call.connected,
      onHold: (down) {
        if (state.groupCall?.conferenceId == call.conferenceId) {
          state.groupPushToTalk(down);
        }
      },
      onToggle: () => state.setGroupMicMuted(!call.micMuted),
      child: Tooltip(
        message: pushToTalk
            ? (call.pushToTalkPressed ? 'Talking' : 'Hold to talk')
            : (call.micMuted ? 'Unmute' : 'Mute'),
        child: SizedBox(
          width: 27,
          height: 28,
          child: Icon(
            call.micMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
            size: 17,
          ),
        ),
      ),
    );
    return Gravity(
      child: Material(
        key: const ValueKey('group-mic-split-control'),
        color: context.syblColors.surfaceTop,
        borderRadius: BorderRadius.circular(6),
        clipBehavior: Clip.antiAlias,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            mic,
            PopupMenuButton<_GroupMicMenuAction>(
              key: const ValueKey('group-mic-mode-chevron'),
              tooltip: 'Microphone options',
              initialValue: pushToTalk
                  ? _GroupMicMenuAction.pushToTalk
                  : _GroupMicMenuAction.open,
              color: context.syblColors.surfaceTop,
              onSelected: (action) {
                switch (action) {
                  case _GroupMicMenuAction.open:
                    unawaited(
                      state.setGroupMicrophoneMode(
                        call.conversationId,
                        MicrophoneMode.open,
                      ),
                    );
                  case _GroupMicMenuAction.pushToTalk:
                    unawaited(
                      state.setGroupMicrophoneMode(
                        call.conversationId,
                        MicrophoneMode.pushToTalk,
                      ),
                    );
                  case _GroupMicMenuAction.inputDevice:
                    unawaited(showAudioInputPicker(context, state));
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: _GroupMicMenuAction.open,
                  child: Text('Open mic'),
                ),
                const PopupMenuItem(
                  value: _GroupMicMenuAction.pushToTalk,
                  child: Text('Push to talk'),
                ),
                if (state.outputPickerAvailable) const PopupMenuDivider(),
                if (state.outputPickerAvailable)
                  const PopupMenuItem(
                    value: _GroupMicMenuAction.inputDevice,
                    child: Text('Microphone device…'),
                  ),
              ],
              child: const SizedBox(
                width: 15,
                height: 28,
                child: Icon(Icons.expand_more_rounded, size: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DockIconButton extends StatelessWidget {
  const _DockIconButton({
    super.key,
    required this.tooltip,
    required this.onPressed,
    required this.icon,
  });

  final String tooltip;
  final VoidCallback? onPressed;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Gravity(
    child: Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          width: 28,
          height: 28,
          child: Icon(
            icon,
            size: 17,
            color: onPressed == null
                ? context.syblColors.faint
                : context.syblColors.ink,
          ),
        ),
      ),
    ),
  );
}

class _DockAction extends StatelessWidget {
  const _DockAction({
    required this.tooltip,
    required this.onPressed,
    required this.icon,
    this.selected = false,
    this.busy = false,
  });

  final String tooltip;
  final VoidCallback? onPressed;
  final IconData icon;
  final bool selected;
  final bool busy;

  @override
  Widget build(BuildContext context) => Gravity(
    child: Tooltip(
      message: tooltip,
      child: Material(
        color: selected
            ? (context.syblColors.neutralButtonFill == null
                  ? context.syblColors.amber.withValues(alpha: .22)
                  : context.syblColors.accentFill)
            : (context.syblColors.neutralButtonFill ??
                  context.syblColors.surfaceHi),
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: onPressed,
          hoverColor: !selected ? context.syblColors.neutralButtonHover : null,
          highlightColor: !selected
              ? context.syblColors.neutralButtonPressed
              : null,
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            height: 31,
            child: busy
                ? Center(
                    child: SizedBox.square(
                      dimension: 15,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color:
                            selected &&
                                context.syblColors.neutralButtonFill != null
                            ? context.syblColors.onAccent
                            : (context.syblColors.neutralButtonForeground ??
                                  context.syblColors.amber),
                      ),
                    ),
                  )
                : Icon(
                    icon,
                    size: 17,
                    color: onPressed == null
                        ? context.syblColors.faint
                        : selected &&
                              context.syblColors.neutralButtonFill != null
                        ? context.syblColors.onAccent
                        : (context.syblColors.neutralButtonForeground ??
                              context.syblColors.ink),
                  ),
          ),
        ),
      ),
    ),
  );
}
