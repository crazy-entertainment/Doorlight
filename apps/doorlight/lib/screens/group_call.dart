import '../ui/gravity.dart';
import '../ui/hologram_anchor.dart';
import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../state/outgoing_video.dart';
import '../theme.dart';
import '../ui/audio_output_action.dart';
import '../ui/screen_share_action.dart';
import '../ui/sybl_ui.dart';
import '../ui/window_presentation.dart';
import '../ui/group_call_dock.dart';

class GroupCallScreen extends StatelessWidget {
  const GroupCallScreen({super.key, required this.state, this.onMinimize});

  final AppState state;
  final VoidCallback? onMinimize;

  @override
  Widget build(BuildContext context) {
    final call = state.groupCall;
    if (call == null) return const SizedBox.shrink();
    if (WindowPresentationScope.isCompact(context) && !call.hasVideo) {
      return GroupCallDock(
        state: state,
        onOpenCall: null,
        onOpenSettings: () {},
        compactHud: true,
        onBack: onMinimize,
      );
    }
    final group = state.groups[call.conversationId];
    final room = group?.layout.room(call.roomId);
    final ratio = call.videoAspectRatio.clamp(.35, 2.4).toDouble();
    final changingCamera =
        call.sourceChanging &&
        (call.sourceChangeKind == OutgoingVideoKind.camera ||
            (call.sourceChangeKind == null && !call.screenShare));
    final changingScreen =
        call.sourceChanging &&
        call.sourceChangeKind == OutgoingVideoKind.screen;
    return Scaffold(
      key: const ValueKey('group-call-screen'),
      backgroundColor: context.syblColors.bg,
      body: Stack(
        children: [
          Positioned.fill(
            child: call.videoTextureId != null
                ? Center(
                    child: AspectRatio(
                      aspectRatio: ratio,
                      child: Texture(textureId: call.videoTextureId!),
                    ),
                  )
                : _GroupCallFallback(state: state, call: call),
          ),
          Positioned(
            left: 10,
            top: 10,
            child: SafeArea(
              child: Row(
                children: [
                  if (onMinimize != null)
                    Gravity(
                      child: HologramAnchor(
                        state: state,
                        child: IconButton(
                          tooltip: 'Back to the group',
                          onPressed: onMinimize,
                          style: IconButton.styleFrom(
                            backgroundColor: context.syblColors.accentFill,
                            foregroundColor: context.syblColors.foregroundFor(
                              context.syblColors.accentFill,
                              preferred: Colors.black,
                            ),
                          ),
                          icon: const Icon(Icons.arrow_back_rounded),
                        ),
                      ),
                    ),
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Gravity(
                        child: Text(
                          group?.displayTitle ?? 'Group call',
                          style: context.syblColors.display.copyWith(
                            fontSize: 16,
                          ),
                        ),
                      ),
                      Gravity(
                        child: Text(
                          '${room?.name ?? 'Voice'} · ${call.hasVideo ? 'Video connected' : 'Voice connected'}',
                          style: TextStyle(
                            color: context.syblColors.muted,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (call.video || call.focusedStreamKey != null)
            Positioned(
              right: 10,
              top: 10,
              child: SafeArea(
                child: Wrap(
                  spacing: 8,
                  children: [
                    if (call.focusedStreamKey != null)
                      Gravity(
                        child: ActionChip(
                          key: const ValueKey('group-call-grid-control'),
                          avatar: const Icon(Icons.grid_view_rounded),
                          label: const Text('Grid'),
                          onPressed: () => state.setGroupFocus(null),
                        ),
                      ),
                    if (call.video)
                      Gravity(
                        child: ActionChip(
                          avatar: const Icon(Icons.cameraswitch_outlined),
                          label: const Text('Flip'),
                          onPressed: call.sourceChanging
                              ? null
                              : state.switchGroupCamera,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          Positioned(
            top: 76,
            left: 12,
            right: 12,
            child: SafeArea(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: changingCamera || changingScreen
                    ? Center(
                        child: Gravity(
                          child: DecoratedBox(
                            key: const ValueKey('group-media-change-status'),
                            decoration: BoxDecoration(
                              color: context.syblColors.surfaceTop,
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(
                                color: context.syblColors.lineStrong,
                              ),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 7,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  SizedBox.square(
                                    dimension: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: context.syblColors.amber,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    changingScreen
                                        ? call.screenShare
                                              ? 'Stopping screen share\u2026'
                                              : 'Starting screen share\u2026'
                                        : call.video
                                        ? 'Stopping camera\u2026'
                                        : 'Starting camera\u2026',
                                    style: TextStyle(
                                      color: context.syblColors.ink,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ),
          ),
          if (call.conference.videoStreams.isNotEmpty)
            Positioned(
              left: 12,
              right: 12,
              bottom: 88,
              child: SafeArea(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final stream in call.conference.videoStreams) ...[
                        _GroupStreamChip(
                          state: state,
                          call: call,
                          stream: stream,
                        ),
                        const SizedBox(width: 8),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          Positioned(
            left: 12,
            right: 12,
            bottom: 14,
            child: SafeArea(
              child: Wrap(
                alignment: WrapAlignment.center,
                spacing: 12,
                runSpacing: 8,
                children: [
                  _GroupCallControl(
                    key: const ValueKey('group-call-mic-control'),
                    tooltip: call.micMuted ? 'Unmute' : 'Mute',
                    icon: call.micMuted
                        ? Icons.mic_off_rounded
                        : Icons.mic_rounded,
                    active: !call.micMuted,
                    onPressed: () => state.setGroupMicMuted(!call.micMuted),
                  ),
                  _GroupCallControl(
                    key: const ValueKey('group-call-camera-control'),
                    tooltip: call.video ? 'Stop camera' : 'Start camera',
                    icon: call.video
                        ? Icons.videocam_rounded
                        : Icons.videocam_off_rounded,
                    active: call.video,
                    busy: changingCamera,
                    onPressed: call.sourceChanging
                        ? null
                        : state.toggleGroupCamera,
                  ),
                  _GroupCallControl(
                    tooltip: call.deafened ? 'Undeafen' : 'Deafen',
                    icon: call.deafened
                        ? Icons.headset_off_rounded
                        : Icons.headphones_rounded,
                    active: !call.deafened,
                    onPressed: () => state.setGroupDeafened(!call.deafened),
                  ),
                  _GroupCallControl(
                    key: const ValueKey('group-call-output-control'),
                    tooltip: state.speakerControlAvailable
                        ? (call.speakerOn ? 'Speaker' : 'Earpiece')
                        : 'Output',
                    icon: audioOutputIcon(state, speakerOn: call.speakerOn),
                    active: call.speakerOn,
                    onPressed: state.speakerControlAvailable
                        ? state.toggleGroupSpeaker
                        : () => showAudioOutputPicker(context, state),
                  ),
                  _GroupCallControl(
                    key: const ValueKey('group-call-share-control'),
                    tooltip: call.screenShare ? 'Stop sharing' : 'Share screen',
                    icon: call.screenShare
                        ? Icons.stop_screen_share_rounded
                        : Icons.screen_share_rounded,
                    active: call.screenShare,
                    busy: changingScreen,
                    onPressed: call.sourceChanging
                        ? null
                        : () => toggleGroupScreenShareWithPicker(
                            context,
                            state,
                            call,
                          ),
                  ),
                  _GroupCallControl(
                    key: const ValueKey('group-call-leave-control'),
                    tooltip: 'Leave voice',
                    icon: Icons.call_end_rounded,
                    danger: true,
                    onPressed: state.leaveGroupVoice,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GroupStreamChip extends StatelessWidget {
  const _GroupStreamChip({
    required this.state,
    required this.call,
    required this.stream,
  });

  final AppState state;
  final GroupCallSession call;
  final GroupConferenceStream stream;

  @override
  Widget build(BuildContext context) {
    final selected = call.focusedStreamKey == stream.key;
    final label = state.peerDisplayName(stream.accountId);
    final canManage =
        (state.groups[call.conversationId]?.canManageMembers ?? call.hosting) &&
        stream.accountId != state.jamiId;
    return GestureDetector(
      key: ValueKey('group-call-stream-${stream.key}'),
      onLongPress: canManage ? () => _showActions(context) : null,
      onSecondaryTap: canManage ? () => _showActions(context) : null,
      child: ActionChip(
        avatar: SyblAvatar(
          label: label,
          imageBase64: state.friends[stream.accountId]?.avatarBase64,
          size: 22,
          color: context.syblColors.sage,
        ),
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label),
            if (stream.moderatorAudioMuted) ...[
              const SizedBox(width: 5),
              const Icon(Icons.mic_off_rounded, size: 14),
            ],
          ],
        ),
        side: BorderSide(
          color: selected
              ? context.syblColors.amber
              : context.syblColors.lineStrong,
        ),
        onPressed: () => state.setGroupFocus(stream),
      ),
    );
  }

  Future<void> _showActions(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    backgroundColor: context.syblColors.surface,
    builder: (sheetContext) => SafeArea(
      child: Wrap(
        children: [
          ListTile(
            leading: Icon(
              stream.moderatorAudioMuted
                  ? Icons.mic_rounded
                  : Icons.mic_off_rounded,
            ),
            title: Text(
              stream.moderatorAudioMuted ? 'Allow microphone' : 'Mute',
            ),
            onTap: () {
              Navigator.pop(sheetContext);
              state.muteGroupParticipant(stream, !stream.moderatorAudioMuted);
            },
          ),
          ListTile(
            leading: Icon(
              Icons.person_remove_rounded,
              color: sheetContext.syblColors.danger,
            ),
            title: const Text('Disconnect'),
            onTap: () {
              Navigator.pop(sheetContext);
              state.disconnectGroupParticipant(stream);
            },
          ),
        ],
      ),
    ),
  );
}

class _GroupCallFallback extends StatelessWidget {
  const _GroupCallFallback({required this.state, required this.call});

  final AppState state;
  final GroupCallSession call;

  @override
  Widget build(BuildContext context) {
    final participants = state.groupVoiceParticipants(
      call.conversationId,
      call.roomId,
    );
    return Center(
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 18,
        runSpacing: 18,
        children: [
          for (final participant in participants)
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SyblAvatar(
                  label: state.peerDisplayName(participant.accountId),
                  imageBase64:
                      state.friends[participant.accountId]?.avatarBase64,
                  size: 88,
                  color: context.syblColors.surfaceHi,
                  statusColor: participant.speaking
                      ? context.syblColors.online
                      : null,
                  statusLabel: participant.speaking ? 'speaking' : null,
                ),
                const SizedBox(height: 8),
                Gravity(
                  child: Text(
                    state.peerDisplayName(participant.accountId),
                    style: TextStyle(color: context.syblColors.ink),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _GroupCallControl extends StatelessWidget {
  const _GroupCallControl({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.active = false,
    this.danger = false,
    this.busy = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool active;
  final bool danger;
  final bool busy;

  @override
  Widget build(BuildContext context) => Gravity(
    child: Tooltip(
      message: tooltip,
      child: IconButton(
        onPressed: onPressed,
        style:
            IconButton.styleFrom(
              minimumSize: const Size.square(52),
              backgroundColor: danger
                  ? context.syblColors.dangerFill
                  : active
                  ? context.syblColors.accentFill
                  : context.syblColors.surfaceTop,
              foregroundColor: danger
                  ? context.syblColors.foregroundFor(
                      context.syblColors.dangerFill,
                    )
                  : active
                  ? context.syblColors.onAccent
                  : context.syblColors.ink,
              side: BorderSide(color: context.syblColors.lineStrong),
            ).merge(
              !danger && !active && context.syblColors.neutralButtonFill != null
                  ? context.syblColors.secondaryButtonStyle.copyWith(
                      minimumSize: const WidgetStatePropertyAll(
                        Size.square(52),
                      ),
                    )
                  : null,
            ),
        icon: busy
            ? SizedBox.square(
                dimension: 21,
                child: CircularProgressIndicator(
                  strokeWidth: 2.3,
                  color: danger
                      ? context.syblColors.foregroundFor(
                          context.syblColors.dangerFill,
                        )
                      : active
                      ? context.syblColors.onAccent
                      : (context.syblColors.neutralButtonForeground ??
                            context.syblColors.amber),
                ),
              )
            : Icon(icon, size: 23),
      ),
    ),
  );
}
