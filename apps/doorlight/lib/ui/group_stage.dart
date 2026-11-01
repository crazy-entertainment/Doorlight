import 'hologram_anchor.dart';
import 'dart:async';

import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../state/conversation_timeline.dart';
import '../state/composer_commands.dart';
import '../state/group_topics.dart';
import '../theme.dart';
import 'onboarding_surface.dart';
import 'chat_stage.dart';
import 'friend_rail.dart';
import 'group_call_dock.dart';
import 'group_dialogs.dart';
import 'sybl_ui.dart';
import 'topic_strip_surface.dart';
import 'window_presentation.dart';
import 'group_room_activity.dart';
import 'gravity.dart';

class GroupStage extends StatefulWidget {
  static const mobileHeaderHeight = 58.0;
  static const inlineTopicRowHeight = 50.0;

  const GroupStage({
    super.key,
    required this.state,
    required this.group,
    this.onBack,
    required this.onOpenCall,
    required this.onOpenSettings,
    this.onConversationVisibilityChanged,
    this.requestedTopicId,
    this.navigationToken,
  });

  final AppState state;
  final GroupState group;
  final VoidCallback? onBack;
  final VoidCallback onOpenCall;
  final VoidCallback onOpenSettings;
  final ValueChanged<String?>? onConversationVisibilityChanged;
  final String? requestedTopicId;
  final Object? navigationToken;

  @override
  State<GroupStage> createState() => _GroupStageState();
}

class _GroupStageState extends State<GroupStage> {
  String _roomId = 'general';
  String? _browsedVoiceRoomId;
  bool _mobileRoomOpen = false;
  bool _headerMembersHovered = false;
  String? _reportedVisibleTopicId;
  final Set<String> _collapsedCollections = {};
  final GlobalKey _inlineTopicRowKey = GlobalKey();
  final GlobalKey _inlineLastTopicKey = GlobalKey();
  final ScrollController _inlineTopicScroll = ScrollController();
  double? _inlineTopicEndpoint;

  Future<bool> _send(String body) =>
      widget.state.sendText(GroupTopicCodec.encode(_roomId, body));

  GroupLayout get _layout => widget.group.layout;

  @override
  void initState() {
    super.initState();
    _inlineTopicScroll.addListener(_measureInlineTopicEndpoint);
    _roomId = widget.state.selectedGroupTopicId(widget.group);
    _applyRequestedTopic();
  }

  @override
  void dispose() {
    _inlineTopicScroll
      ..removeListener(_measureInlineTopicEndpoint)
      ..dispose();
    super.dispose();
  }

  void _applyRequestedTopic() {
    final topic = widget.requestedTopicId;
    if (topic == null || _layout.room(topic)?.kind != GroupRoomKind.text) {
      return;
    }
    _roomId = topic;
    _mobileRoomOpen = true;
  }

  void _selectRoom(String roomId, {bool? openConversation}) {
    setState(() {
      _roomId = roomId;
      if (openConversation != null) _mobileRoomOpen = openConversation;
    });
    unawaited(
      widget.state.selectGroupTopic(widget.group.conversationId, roomId),
    );
  }

  void _measureInlineTopicEndpoint() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final row = _inlineTopicRowKey.currentContext?.findRenderObject();
      final last = _inlineLastTopicKey.currentContext?.findRenderObject();
      if (row is! RenderBox ||
          last is! RenderBox ||
          !row.hasSize ||
          !last.hasSize) {
        return;
      }
      final next = last
          .localToGlobal(Offset(last.size.width, 0), ancestor: row)
          .dx
          .clamp(0.0, row.size.width)
          .toDouble();
      if (_inlineTopicEndpoint != next) {
        setState(() => _inlineTopicEndpoint = next);
      }
    });
  }

  @override
  void didUpdateWidget(covariant GroupStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final groupChanged =
        oldWidget.group.conversationId != widget.group.conversationId;
    if (groupChanged) {
      _roomId = widget.state.selectedGroupTopicId(widget.group);
      _mobileRoomOpen = false;
    } else if (_layout.room(_roomId)?.kind != GroupRoomKind.text) {
      _roomId = _layout.initialTextRoom.id;
    }
    // A reused stage must reset the old group before applying the new search
    // destination, otherwise rooms-first navigation hides the selected result.
    if ((groupChanged || widget.navigationToken != oldWidget.navigationToken) &&
        widget.navigationToken != null) {
      _applyRequestedTopic();
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (WindowPresentationScope.isCompact(context)) {
        _reportConversationVisible(
          _browsedVoiceRoomId == null ? _roomId : null,
        );
        return _windowCompact(context);
      }
      // The outer people rail animates from 212 to 58 px. Basing this mode on
      // the changing inner width made the topic sidebar pop in halfway through
      // that animation.
      final desktop =
          Theme.of(context).platform == TargetPlatform.windows &&
          !SyblLayout.isCompact(context);
      final fullWidthHeader =
          widget.state.groupHeaderPlacement == GroupHeaderPlacement.fullWidth;
      final roomsFirst =
          !desktop &&
          widget.state.mobileGroupNavigation ==
              MobileGroupNavigation.roomsFirst;
      if (_layout.room(_roomId)?.kind != GroupRoomKind.text) {
        _roomId = _layout.initialTextRoom.id;
      }
      _reportConversationVisible(
        roomsFirst && !_mobileRoomOpen ? null : _roomId,
      );
      return OnboardingSurface(
        active: false,
        child: desktop
            ? fullWidthHeader
                  ? Column(
                      children: [
                        _header(context, desktop: true),
                        const Divider(height: 1),
                        Expanded(
                          child: Row(
                            children: [
                              SizedBox(
                                width: 200,
                                child: _topicSidebar(context),
                              ),
                              const VerticalDivider(width: 1),
                              Expanded(
                                child: _conversation(context, desktop: true),
                              ),
                            ],
                          ),
                        ),
                      ],
                    )
                  : Row(
                      children: [
                        SizedBox(width: 200, child: _topicSidebar(context)),
                        const VerticalDivider(width: 1),
                        Expanded(
                          child: Column(
                            children: [
                              _header(context, desktop: true),
                              const Divider(height: 1),
                              Expanded(
                                child: _conversation(context, desktop: true),
                              ),
                            ],
                          ),
                        ),
                      ],
                    )
            : roomsFirst
            ? _mobileRoomsFirst(context)
            : Column(
                children: [
                  _header(context, desktop: false),
                  const Divider(height: 1),
                  Expanded(child: _conversation(context, desktop: false)),
                  if (widget.state.groupCall != null) _groupCallDock(),
                ],
              ),
      );
    },
  );

  void _reportConversationVisible(String? topicId) {
    if (_reportedVisibleTopicId == topicId) return;
    _reportedVisibleTopicId = topicId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _reportedVisibleTopicId != topicId) return;
      widget.onConversationVisibilityChanged?.call(topicId);
    });
  }

  Widget _compactMenu(String entry) => Gravity(
    child: PopupMenuButton<String>(
      key: ValueKey('compact-group-menu-$entry'),
      tooltip: 'Topics and voice chats',
      padding: EdgeInsets.zero,
      color: context.syblColors.surfaceTop,
      constraints: const BoxConstraints(maxWidth: 280),
      itemBuilder: (context) => [
        const PopupMenuItem(enabled: false, height: 28, child: Text('Topics')),
        for (final room in _layout.rooms.where(
          (r) => r.kind == GroupRoomKind.text,
        ))
          PopupMenuItem(
            value: room.id,
            height: 34,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
              decoration: BoxDecoration(
                color: _roomId == room.id
                    ? context.syblColors.surfaceHi
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '# ${room.name}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        const PopupMenuItem(
          enabled: false,
          height: 28,
          child: Text('Voice chats'),
        ),
        for (final room in _layout.rooms.where(
          (r) => r.kind == GroupRoomKind.voice,
        ))
          PopupMenuItem(
            value: room.id,
            height: 36,
            child: Row(
              children: [
                const Icon(Icons.call_outlined, size: 16),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    room.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                RoomParticipantAvatars(
                  state: widget.state,
                  group: widget.group,
                  roomId: room.id,
                ),
              ],
            ),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem(value: '@settings', child: Text('Group settings')),
      ],
      onSelected: (value) async {
        if (value == '@settings') {
          await showGroupSettingsDialog(
            context,
            state: widget.state,
            group: widget.group,
          );
        } else if (_layout.room(value)?.kind == GroupRoomKind.voice) {
          setState(() => _browsedVoiceRoomId = value);
        } else {
          setState(() => _browsedVoiceRoomId = null);
          _selectRoom(value);
        }
      },
      child: SizedBox(
        width: 26,
        height: 28,
        child: Center(
          child: Text(
            '\u2026',
            style: TextStyle(
              fontFamily: Warm.sansFamily,
              fontSize: entry == 'topics' ? 11 : 13,
              fontWeight: FontWeight.w500,
              color: entry == 'topics'
                  ? context.syblColors.amber
                  : context.syblColors.muted,
            ),
          ),
        ),
      ),
    ),
  );

  Widget _windowCompact(BuildContext context) {
    final voiceRoom = _layout.room(_browsedVoiceRoomId ?? '');
    final call = widget.state.groupCall;
    return Column(
      children: [
        CompactHeader(
          title: widget.group.displayTitle,
          titleWidget: Align(
            alignment: Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: GroupRoomActivity(
                    state: widget.state,
                    group: widget.group,
                    child: Gravity(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: context.syblColors.surfaceHi,
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Text(
                          widget.group.displayTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                _compactMenu('header'),
              ],
            ),
          ),
          onBack: voiceRoom != null
              ? () => setState(() => _browsedVoiceRoomId = null)
              : widget.onBack,
          unreadElsewhere: widget.state.unreadOutsideConversation(
            widget.group.ownerKey,
          ),
          actions: [
            if (call != null)
              CompactIconButton(
                label: 'Return to call',
                icon: Icons.call,
                onPressed: widget.onOpenCall,
                active: true,
              ),
          ],
        ),
        if (voiceRoom == null) ...[
          SizedBox(
            height: 29,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    reverse: true,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final room in _layout.rooms.where(
                          (r) => r.kind == GroupRoomKind.text,
                        ))
                          Gravity(
                            child: TextButton(
                              style: TextButton.styleFrom(
                                minimumSize: const Size(0, 26),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                ),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                backgroundColor: _roomId == room.id
                                    ? context.syblColors.surfaceHi
                                    : null,
                              ),
                              onPressed: () => _selectRoom(room.id),
                              child: Text(
                                room.name,
                                style: const TextStyle(fontSize: 11),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                _compactMenu('topics'),
              ],
            ),
          ),
          Expanded(
            child: _conversation(
              context,
              desktop: false,
              showRoomPicker: false,
            ),
          ),
        ] else
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(18),
              child: Column(
                children: [
                  Gravity(
                    child: Text(
                      voiceRoom.name,
                      style: context.syblColors.display.copyWith(fontSize: 18),
                    ),
                  ),
                  const SizedBox(height: 18),
                  for (final participant in widget.state.groupVoiceParticipants(
                    widget.group.conversationId,
                    voiceRoom.id,
                  ))
                    _VoiceParticipantLine(
                      state: widget.state,
                      group: widget.group,
                      participant: participant,
                    ),
                  const SizedBox(height: 18),
                  Gravity(
                    child: FilledButton.icon(
                      icon: const Icon(Icons.call),
                      label: Text(
                        call?.roomId == voiceRoom.id &&
                                call?.conversationId ==
                                    widget.group.conversationId
                            ? 'Return to call'
                            : 'Join voice chat',
                      ),
                      onPressed: () async {
                        if (call?.roomId == voiceRoom.id &&
                            call?.conversationId ==
                                widget.group.conversationId) {
                          widget.onOpenCall();
                        } else {
                          await widget.state.joinGroupVoice(
                            widget.group,
                            voiceRoom,
                          );
                          if (mounted && widget.state.groupCall != null) {
                            widget.onOpenCall();
                          }
                        }
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _mobileRoomsFirst(BuildContext context) => _mobileRoomOpen
      ? Column(
          children: [
            _mobileTopicHeader(context),
            const Divider(height: 1),
            Expanded(
              child: _conversation(
                context,
                desktop: false,
                showRoomPicker: false,
              ),
            ),
            if (widget.state.groupCall != null) _groupCallDock(),
          ],
        )
      : Column(
          children: [
            _header(context, desktop: false),
            const Divider(height: 1),
            Expanded(child: _topicSidebar(context, openConversation: true)),
          ],
        );

  Widget _mobileTopicHeader(BuildContext context) {
    final room = _layout.room(_roomId) ?? _layout.initialTextRoom;
    return SizedBox(
      key: const ValueKey('mobile-group-topic-header'),
      height: GroupStage.mobileHeaderHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          children: [
            Gravity(
              child: IconButton(
                key: const ValueKey('mobile-group-topic-back'),
                tooltip: 'Back to group rooms',
                onPressed: () => setState(() => _mobileRoomOpen = false),
                icon: const Icon(Icons.arrow_back_rounded),
              ),
            ),
            const Gravity(child: Icon(Icons.tag_rounded, size: 20)),
            const SizedBox(width: 8),
            Expanded(
              child: Gravity(
                child: Text(
                  room.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.syblColors.display.copyWith(fontSize: 17),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context, {required bool desktop}) {
    final nonFriends = widget.group.memberIds
        .where(
          (id) =>
              id != widget.state.jamiId &&
              !widget.state.friends.containsKey(id),
        )
        .toList(growable: false);
    return AnimatedSize(
      duration: SyblMotion.duration(context),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(
            key: const ValueKey('group-header'),
            constraints: const BoxConstraints(
              minHeight: GroupStage.mobileHeaderHeight,
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: desktop ? 18 : 10),
              child: Row(
                children: [
                  if (widget.onBack != null)
                    Gravity(
                      child: HologramAnchor(
                        state: widget.state,
                        child: IconButton(
                          tooltip: 'Back to your friends',
                          onPressed: widget.onBack,
                          icon: const Icon(Icons.arrow_back_rounded),
                        ),
                      ),
                    ),
                  MouseRegion(
                    key: const ValueKey('group-header-avatar-hover'),
                    onEnter: desktop
                        ? (_) => setState(() => _headerMembersHovered = true)
                        : null,
                    onExit: desktop
                        ? (_) => setState(() => _headerMembersHovered = false)
                        : null,
                    child: GroupAvatar(
                      key: const ValueKey('group-header-avatar'),
                      state: widget.state,
                      group: widget.group,
                      size: 39,
                      expanded: desktop && _headerMembersHovered,
                    ),
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Gravity(
                      child: Tooltip(
                        message: widget.group.canManageMembers
                            ? 'Rename group'
                            : widget.group.displayTitle,
                        child: InkWell(
                          key: const ValueKey('rename-group-title'),
                          onTap: widget.group.canManageMembers
                              ? () => showRenameGroupDialog(
                                  context,
                                  state: widget.state,
                                  group: widget.group,
                                )
                              : null,
                          borderRadius: BorderRadius.circular(7),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 2),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        widget.group.displayTitle,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: context.syblColors.display
                                            .copyWith(
                                              fontSize: desktop ? 18 : 17,
                                            ),
                                      ),
                                    ),
                                    if (widget.group.canManageMembers) ...[
                                      const SizedBox(width: 5),
                                      Icon(
                                        Icons.edit_outlined,
                                        size: 14,
                                        color: context.syblColors.faint,
                                      ),
                                    ],
                                  ],
                                ),
                                Text(
                                  '${widget.group.memberCount} members',
                                  style: TextStyle(
                                    color: context.syblColors.faint,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  SyblPillIconButton(
                    key: const ValueKey('group-settings-button'),
                    label: 'Group settings',
                    icon: Icons.tune_rounded,
                    onPressed: () => showGroupSettingsDialog(
                      context,
                      state: widget.state,
                      group: widget.group,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (desktop && _headerMembersHovered && nonFriends.isNotEmpty)
            Container(
              key: ValueKey(
                'group-header-members-${widget.group.conversationId}',
              ),
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(18, 5, 18, 8),
              decoration: BoxDecoration(
                color: context.syblColors.surface,
                border: Border(top: BorderSide(color: context.syblColors.line)),
              ),
              child: Column(
                children: [
                  for (final memberId in nonFriends.take(6))
                    GroupMemberLine(
                      state: widget.state,
                      group: widget.group,
                      memberId: memberId,
                      invited: widget.group.invitedMemberIds.contains(memberId),
                    ),
                  if (nonFriends.length > 6)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Gravity(
                        child: Text(
                          '+${nonFriends.length - 6} more members',
                          style: TextStyle(
                            color: context.syblColors.faint,
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _topicSidebar(BuildContext context, {bool openConversation = false}) {
    final outside = _layout.rooms
        .where((room) => room.collectionId == null)
        .toList(growable: false);
    return ColoredBox(
      key: ValueKey(
        openConversation ? 'mobile-group-room-browser' : 'group-topic-sidebar',
      ),
      color: context.syblColors.surface,
      child: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
              children: [
                for (final room in outside)
                  _roomButton(
                    context,
                    room,
                    openConversation: openConversation,
                  ),
                for (final collection in _layout.collections) ...[
                  _CollectionHeader(
                    key: ValueKey('group-collection-${collection.id}'),
                    collection: collection,
                    collapsed: _collapsedCollections.contains(collection.id),
                    onPressed: () => setState(() {
                      if (!_collapsedCollections.add(collection.id)) {
                        _collapsedCollections.remove(collection.id);
                      }
                    }),
                  ),
                  if (!_collapsedCollections.contains(collection.id))
                    for (final room in _layout.rooms.where(
                      (room) => room.collectionId == collection.id,
                    ))
                      _roomButton(
                        context,
                        room,
                        openConversation: openConversation,
                      ),
                  const SizedBox(height: 8),
                ],
              ],
            ),
          ),
          if (widget.state.groupCall != null) _groupCallDock(),
        ],
      ),
    );
  }

  Widget _groupCallDock() => GroupCallDock(
    state: widget.state,
    onOpenCall: widget.onOpenCall,
    onOpenSettings: widget.onOpenSettings,
  );

  Widget _roomButton(
    BuildContext context,
    GroupRoom room, {
    required bool openConversation,
  }) {
    final voice = room.kind == GroupRoomKind.voice;
    final active =
        voice &&
        widget.state.groupCall?.conversationId == widget.group.conversationId &&
        widget.state.groupCall?.roomId == room.id;
    final participants = widget.state.groupVoiceParticipants(
      widget.group.conversationId,
      room.id,
    );
    return AnimatedSize(
      duration: SyblMotion.duration(context),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _RoomButton(
            key: ValueKey('group-topic-${room.id}'),
            room: room,
            selected:
                active || (!openConversation && !voice && _roomId == room.id),
            trailing: voice && participants.isNotEmpty
                ? Text(
                    '${participants.length}',
                    style: TextStyle(
                      color: context.syblColors.faint,
                      fontSize: 10,
                    ),
                  )
                : null,
            onPressed: () {
              if (voice) {
                unawaited(widget.state.joinGroupVoice(widget.group, room));
              } else {
                _selectRoom(room.id, openConversation: openConversation);
              }
            },
          ),
          if (voice)
            for (final participant in participants)
              _AnimatedVoiceParticipantLine(
                key: ValueKey(
                  'voice-participant-transition-${participant.accountId}',
                ),
                group: widget.group,
                state: widget.state,
                participant: participant,
              ),
        ],
      ),
    );
  }

  Widget _conversation(
    BuildContext context, {
    required bool desktop,
    bool showRoomPicker = true,
  }) {
    final room = _layout.room(_roomId) ?? _layout.initialTextRoom;
    if (room.id != _roomId) _roomId = room.id;
    final ownerKey = widget.group.ownerKey;
    final conversationId = widget.group.conversationId;
    final timeline = widget.state.conversationItems
        .where((item) {
          if (item is TimelineTextItem) {
            return (item.roomId ?? GroupTopicCodec.decode(item.text).topicId) ==
                room.id;
          }
          return (item is TimelineFileItem || item is TimelineStickerItem) &&
              (item.roomId ?? 'general') == room.id;
        })
        .toList(growable: false);
    final live = widget.state.transfers.values
        .where(
          (transfer) =>
              transfer.peerId == ownerKey &&
              transfer.conversationId == conversationId &&
              (transfer.roomId.isEmpty ? 'general' : transfer.roomId) ==
                  room.id,
        )
        .toList(growable: false);
    final liveKeys = live
        .map(
          (transfer) => (
            ownerId: transfer.authorId.isNotEmpty
                ? transfer.authorId
                : transfer.outgoing
                ? widget.state.jamiId
                : transfer.peerId,
            fileId: transfer.fileId,
          ),
        )
        .toSet();
    final legacyFiles =
        (widget.state.folder.values
            .where(
              (file) =>
                  file.peerId == ownerKey &&
                  file.conversationId == conversationId &&
                  (file.roomId.isEmpty ? 'general' : file.roomId) == room.id &&
                  !liveKeys.contains((
                    ownerId: file.authorId.isNotEmpty
                        ? file.authorId
                        : file.outgoing
                        ? widget.state.jamiId
                        : file.peerId,
                    fileId: file.fileId,
                  )),
            )
            .toList()
          ..sort((left, right) => left.timestamp.compareTo(right.timestamp)));
    final hasContent =
        timeline.isNotEmpty || live.isNotEmpty || legacyFiles.isNotEmpty;
    final inlineTopics = !desktop && showRoomPicker;
    if (inlineTopics) _measureInlineTopicEndpoint();
    return ColoredBox(
      key: const ValueKey('group-conversation-surface'),
      color: Colors.transparent,
      child: Column(
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                ConversationTimelineView(
                  key: ValueKey('group-messages-${room.id}'),
                  state: widget.state,
                  live: live,
                  timeline: timeline,
                  legacyFiles: legacyFiles,
                  group: widget.group,
                  textFor: (item) => GroupTopicCodec.decode(item.text).body,
                ),
                if (!hasContent)
                  widget.state.chatLoading
                      ? const Center(child: CircularProgressIndicator())
                      : widget.state.chatLoadError != null
                      ? SyblStatusPanel(
                          kind: SyblStatusKind.error,
                          title: 'Could not load this topic',
                          message:
                              'Your Jami history is still safe. Try again.',
                          compact: true,
                          action: Gravity(
                            child: OutlinedButton.icon(
                              onPressed: widget.state.refreshChat,
                              icon: const Icon(Icons.refresh_rounded, size: 18),
                              label: const Text('Try again'),
                            ),
                          ),
                        )
                      : SyblStatusPanel(
                          kind: SyblStatusKind.empty,
                          title: 'No messages here yet',
                          message: 'Start the conversation.',
                          compact: true,
                        ),
                if (inlineTopics) ...[
                  Positioned.fill(
                    child: TopicStripSurface(
                      settings: widget.state.topicStripSurfaceSettings,
                      endpoint: _inlineTopicEndpoint ?? double.infinity,
                      pillBottom: 42,
                    ),
                  ),
                  Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      key: _inlineTopicRowKey,
                      height: GroupStage.inlineTopicRowHeight,
                      child: ListView(
                        controller: _inlineTopicScroll,
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
                        children: [
                          for (
                            var index = 0;
                            index < _layout.rooms.length;
                            index++
                          )
                            KeyedSubtree(
                              key: index == _layout.rooms.length - 1
                                  ? _inlineLastTopicKey
                                  : null,
                              child: Padding(
                                padding: const EdgeInsets.only(right: 7),
                                child: Gravity(
                                  child: ChoiceChip(
                                    key: ValueKey(
                                      'group-topic-${_layout.rooms[index].id}',
                                    ),
                                    avatar: Icon(
                                      _layout.rooms[index].kind ==
                                              GroupRoomKind.voice
                                          ? Icons.volume_up_rounded
                                          : Icons.tag_rounded,
                                      size: 15,
                                    ),
                                    label: Text(_layout.rooms[index].name),
                                    selected:
                                        _layout.rooms[index].kind ==
                                            GroupRoomKind.text &&
                                        room.id == _layout.rooms[index].id,
                                    onSelected: (_) {
                                      final item = _layout.rooms[index];
                                      if (item.kind == GroupRoomKind.voice) {
                                        unawaited(
                                          widget.state.joinGroupVoice(
                                            widget.group,
                                            item,
                                          ),
                                        );
                                      } else {
                                        _selectRoom(item.id);
                                      }
                                    },
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          ConversationComposer(
            key: ValueKey('group-composer-${widget.group.conversationId}'),
            state: widget.state,
            hintText: 'Message #${room.name}',
            fileLabel: 'Share a file with ${widget.group.displayTitle}',
            onSend: _send,
            onSendOwned: (body, operation) => widget.state.sendOwnedContent(
              GroupTopicCodec.encode(room.id, body),
              operationId: operation.id,
              replyTo: operation.replyTo,
            ),
            groupTopicId: room.id,
            onCommandExecuted: (result) {
              if ((result.kind == ComposerResultKind.switchTopic ||
                      result.kind == ComposerResultKind.openChat) &&
                  result.ownerKey == widget.group.ownerKey) {
                _selectRoom(widget.state.selectedGroupTopicId(widget.group));
              }
            },
          ),
        ],
      ),
    );
  }
}

class _RoomButton extends StatelessWidget {
  const _RoomButton({
    super.key,
    required this.room,
    required this.selected,
    required this.onPressed,
    this.trailing,
  });

  final GroupRoom room;
  final bool selected;
  final VoidCallback onPressed;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Gravity(
    child: Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Material(
        color: selected ? context.syblColors.surfaceTop : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            child: Row(
              children: [
                Icon(
                  room.kind == GroupRoomKind.voice
                      ? Icons.volume_up_rounded
                      : Icons.tag_rounded,
                  size: 15,
                  color: selected
                      ? context.syblColors.ink
                      : context.syblColors.faint,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    room.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected
                          ? context.syblColors.ink
                          : context.syblColors.muted,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      fontSize: 12,
                    ),
                  ),
                ),
                ?trailing,
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _AnimatedVoiceParticipantLine extends StatelessWidget {
  const _AnimatedVoiceParticipantLine({
    super.key,
    required this.group,
    required this.state,
    required this.participant,
  });

  final GroupState group;
  final AppState state;
  final GroupRoomParticipant participant;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: SyblMotion.duration(context, const Duration(milliseconds: 220)),
    curve: Curves.easeOutCubic,
    builder: (context, value, child) => ClipRect(
      child: Align(
        alignment: Alignment.topCenter,
        heightFactor: value,
        child: Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, 6 * (1 - value)),
            child: child,
          ),
        ),
      ),
    ),
    child: _VoiceParticipantLine(
      group: group,
      state: state,
      participant: participant,
    ),
  );
}

class _VoiceParticipantLine extends StatelessWidget {
  const _VoiceParticipantLine({
    required this.group,
    required this.state,
    required this.participant,
  });

  final GroupState group;
  final AppState state;
  final GroupRoomParticipant participant;

  @override
  Widget build(BuildContext context) {
    final label = groupMemberLabel(state, group, participant.accountId);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 2, 5, 4),
      child: Row(
        children: [
          AnimatedContainer(
            duration: SyblMotion.duration(context),
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: participant.speaking
                    ? context.syblColors.online
                    : Colors.transparent,
                width: 2,
              ),
            ),
            child: SyblAvatar(
              label: label,
              imageBase64: groupMemberAvatar(
                state,
                group,
                participant.accountId,
              ),
              size: 23,
              color: context.syblColors.sage,
            ),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Gravity(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: context.syblColors.muted, fontSize: 11),
              ),
            ),
          ),
          if (participant.video)
            Gravity(
              child: Icon(
                Icons.videocam_rounded,
                size: 13,
                color: context.syblColors.faint,
              ),
            ),
          if (participant.deafened || participant.muted)
            Gravity(
              child: Icon(
                participant.deafened
                    ? Icons.headset_off_rounded
                    : Icons.mic_off_rounded,
                size: 13,
                color: context.syblColors.faint,
              ),
            ),
        ],
      ),
    );
  }
}

class _CollectionHeader extends StatelessWidget {
  const _CollectionHeader({
    super.key,
    required this.collection,
    required this.collapsed,
    required this.onPressed,
  });

  final GroupCollection collection;
  final bool collapsed;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Gravity(
    child: InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 5, 2, 5),
        child: Row(
          children: [
            Icon(
              collapsed
                  ? Icons.keyboard_arrow_right_rounded
                  : Icons.keyboard_arrow_down_rounded,
              size: 16,
              color: context.syblColors.faint,
            ),
            const SizedBox(width: 2),
            Expanded(
              child: Text(
                collection.name.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: context.syblColors.faint,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.05,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
