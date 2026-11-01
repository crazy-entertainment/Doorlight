import 'package:flutter/material.dart';
import '../state/app_state.dart';
import '../state/group_topics.dart';
import '../theme.dart';
import 'friend_rail.dart';
import 'gravity.dart';
import 'sybl_ui.dart';

bool groupHasRoomActivity(AppState state, GroupState group) => group
    .layout
    .rooms
    .where((room) => room.kind == GroupRoomKind.voice)
    .any(
      (room) => state
          .groupVoiceParticipants(group.conversationId, room.id)
          .isNotEmpty,
    );

class GroupRoomActivity extends StatelessWidget {
  const GroupRoomActivity({
    super.key,
    required this.state,
    required this.group,
    required this.child,
  });
  final AppState state;
  final GroupState group;
  final Widget child;
  @override
  Widget build(BuildContext context) => Stack(
    clipBehavior: Clip.none,
    children: [
      child,
      if (groupHasRoomActivity(state, group))
        Positioned(
          right: -2,
          bottom: -2,
          child: Gravity(
            child: Tooltip(
              message: 'Voice room active',
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: context.syblColors.surfaceTop,
                  shape: BoxShape.circle,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: Icon(
                    Icons.call,
                    size: 11,
                    color: context.syblColors.online,
                  ),
                ),
              ),
            ),
          ),
        ),
    ],
  );
}

/// Uses the shared room-presence projection, including authenticated local
/// participation. Video stream counts are never an occupancy source.
class RoomParticipantAvatars extends StatelessWidget {
  const RoomParticipantAvatars({
    super.key,
    required this.state,
    required this.group,
    required this.roomId,
    this.size = 22,
    this.showNames = false,
  });
  final AppState state;
  final GroupState group;
  final String roomId;
  final double size;
  final bool showNames;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) => _participants(context),
  );

  Widget _participants(BuildContext context) {
    final participants = state.groupVoiceParticipants(
      group.conversationId,
      roomId,
    );
    final shown = participants.take(4).toList();
    if (showNames) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final participant in participants)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: SizedBox(
                  width: 48,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            width: 2,
                            color: participant.speaking
                                ? context.syblColors.online
                                : Colors.transparent,
                          ),
                        ),
                        child: SyblAvatar(
                          size: size - 4,
                          label: groupMemberLabel(
                            state,
                            group,
                            participant.accountId,
                          ),
                          imageBase64: groupMemberAvatar(
                            state,
                            group,
                            participant.accountId,
                          ),
                        ),
                      ),
                      Gravity(
                        child: Text(
                          groupMemberLabel(state, group, participant.accountId),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 10),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      );
    }
    return Semantics(
      label: '${participants.length} participants',
      child: SizedBox(
        width: shown.isEmpty ? 0 : size + (shown.length - 1) * size * .65,
        height: size,
        child: Stack(
          children: [
            for (var index = 0; index < shown.length; index++)
              Positioned(
                left: index * size * .65,
                child: Tooltip(
                  message: groupMemberLabel(
                    state,
                    group,
                    shown[index].accountId,
                  ),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: shown[index].speaking
                            ? context.syblColors.online
                            : context.syblColors.surfaceTop,
                        width: 2,
                      ),
                    ),
                    child: SyblAvatar(
                      size: size - 4,
                      label: groupMemberLabel(
                        state,
                        group,
                        shown[index].accountId,
                      ),
                      imageBase64: groupMemberAvatar(
                        state,
                        group,
                        shown[index].accountId,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
