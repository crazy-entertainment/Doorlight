import 'notice.dart';
import 'group_room_activity.dart';
import 'window_presentation.dart';
import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../state/chat_archive.dart';
import 'capture_sensitive_scope.dart';
import '../theme.dart';
import 'group_call_dock.dart';
import 'friend_options.dart';
import 'gravity.dart';
import 'hologram_anchor.dart';
import 'notification_bell.dart';
import 'sybl_ui.dart';

// The avatar badge footprint, row padding and call ring occupy 58 px together.
const _railRowMinExtent = 58.0;
const _railRowGap = 3.0;
const _railRowRadius = 9.0;

double _railLineExtent(
  BuildContext context,
  TextStyle style, {
  String text = 'Hg',
  double maxWidth = double.infinity,
  int? maxLines = 1,
}) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: maxLines,
  )..layout(maxWidth: maxWidth);
  final height = painter.height;
  painter.dispose();
  return height;
}

double _railRowExtent(
  BuildContext context, {
  GroupState? group,
  bool unread = false,
  double width = SyblLayout.railWidth - 9,
}) {
  final base = Theme.of(context).textTheme.bodyMedium!;
  final text =
      _railLineExtent(
        context,
        base.copyWith(fontSize: 13, fontWeight: FontWeight.w600),
      ) +
      2 +
      _railLineExtent(
        context,
        base.copyWith(fontSize: 11),
        text: group == null ? 'Hg' : '${group.memberCount} members',
        maxWidth: group == null
            ? double.infinity
            : (width - 18 - 38 - 10 - (unread ? 8 : 0)).clamp(
                1.0,
                double.infinity,
              ),
        maxLines: group == null ? 1 : null,
      );
  final extent = text + (group != null ? 14 : 11 + 2 * _callRingWidth);
  return extent > _railRowMinExtent ? extent : _railRowMinExtent;
}

String friendLabel(FriendState friend) {
  final displayName = friend.displayName.trim();
  if (displayName.isNotEmpty) return displayName;
  if (friend.nameHint.isNotEmpty) return friend.nameHint;
  final id = friend.peerId;
  return id.length >= 4 ? 'Friend · ${id.substring(0, 4)}' : 'Friend';
}

String groupMemberLabel(AppState state, GroupState group, String memberId) {
  if (memberId == state.jamiId) {
    return state.displayName.trim().isEmpty ? 'You' : state.displayName;
  }
  final friend = state.friends[memberId];
  if (friend != null) return friendLabel(friend);
  final profileName = group.memberDisplayNames[memberId]?.trim() ?? '';
  if (profileName.isNotEmpty) return profileName;
  return memberId.length > 10
      ? '${memberId.substring(0, 6)}…${memberId.substring(memberId.length - 4)}'
      : memberId;
}

String groupMemberAvatar(AppState state, GroupState group, String memberId) =>
    memberId == state.jamiId
    ? state.profileAvatarBase64
    : state.friends[memberId]?.avatarBase64 ??
          group.memberAvatars[memberId] ??
          '';

String friendPresenceLabel(AppState state, FriendState friend) {
  if (!friend.confirmed) return 'friend request pending';
  if (state.appearOffline) return 'presence hidden';
  if (friend.presenceActivity.isNotEmpty &&
      (friend.presence == PeerPresence.inApp ||
          friend.presence == PeerPresence.reachable)) {
    return 'Using ${friend.presenceActivity}';
  }
  return switch (friend.presence) {
    // Reachable means their Syb-L answers now; only an opted-in peer can say
    // they are looking at it, so both read as online.
    PeerPresence.inApp || PeerPresence.reachable => 'online',
    PeerPresence.unreachable || PeerPresence.unknown => 'offline',
  };
}

Color friendPresenceColor(
  BuildContext context,
  AppState state,
  FriendState friend,
) {
  if (!friend.confirmed) return context.syblColors.faint;
  if (state.appearOffline) return context.syblColors.faint;
  return switch (friend.presence) {
    PeerPresence.inApp || PeerPresence.reachable => context.syblColors.online,
    PeerPresence.unreachable => context.syblColors.faint,
    PeerPresence.unknown => context.syblColors.faint,
  };
}

IconData? friendPresenceIcon(FriendState friend) =>
    friend.presence == PeerPresence.unreachable
    ? Icons.circle_outlined
    : friend.presencePlatform == 'android'
    ? Icons.phone_iphone_rounded
    : null;

enum _PeopleAction { addFriend, createGroup, inviteFriend }

class FriendRail extends StatelessWidget {
  final AppState state;
  final ValueChanged<FriendState> onOpenFriend;
  final ValueChanged<GroupState> onOpenGroup;
  final VoidCallback? onOpenCall;
  final VoidCallback onAddFriend;
  final VoidCallback onCreateGroup;
  final VoidCallback onInviteFriend;
  final VoidCallback onOpenSettings;
  final VoidCallback? onSearch;
  final String? highlightedPeerId;
  final bool compact;
  final GlobalKey? profileAvatarAnchor;

  const FriendRail({
    super.key,
    required this.state,
    required this.onOpenFriend,
    required this.onOpenGroup,
    this.onOpenCall,
    required this.onAddFriend,
    required this.onCreateGroup,
    required this.onInviteFriend,
    required this.onOpenSettings,
    this.highlightedPeerId,
    this.onSearch,
    this.compact = false,
    this.profileAvatarAnchor,
  });

  Widget _peopleActions(BuildContext context) {
    final windowCompact = WindowPresentationScope.isCompact(context);
    return Gravity(
      child: Tooltip(
        message: 'Add people',
        child: PopupMenuButton<_PeopleAction>(
          key: const ValueKey('people-actions-button'),
          tooltip: '',
          position: PopupMenuPosition.under,
          offset: const Offset(0, 6),
          color: context.syblColors.surfaceTop,
          onSelected: (action) => switch (action) {
            _PeopleAction.addFriend => onAddFriend(),
            _PeopleAction.createGroup => onCreateGroup(),
            _PeopleAction.inviteFriend => onInviteFriend(),
          },
          itemBuilder: (context) => const [
            PopupMenuItem(
              key: ValueKey('people-action-add-friend'),
              value: _PeopleAction.addFriend,
              child: ListTile(
                leading: Icon(Icons.person_add_alt_1_rounded),
                title: Text('Add a friend'),
              ),
            ),
            PopupMenuItem(
              key: ValueKey('people-action-create-group'),
              value: _PeopleAction.createGroup,
              child: ListTile(
                leading: Icon(Icons.group_add_rounded),
                title: Text('Create a group'),
              ),
            ),
            PopupMenuItem(
              key: ValueKey('people-action-invite-friend'),
              value: _PeopleAction.inviteFriend,
              child: ListTile(
                leading: Icon(Icons.ios_share_rounded),
                title: Text('Invite a friend'),
              ),
            ),
          ],
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: windowCompact
                  ? Colors.transparent
                  : context.syblColors.accentFill,
            ),
            child: SizedBox.square(
              dimension: windowCompact
                  ? 26
                  : compact
                  ? 48
                  : 36,
              child: Icon(
                Icons.person_add_alt_1_rounded,
                size: 19,
                color: windowCompact
                    ? context.syblColors.muted
                    : context.syblColors.foregroundFor(
                        context.syblColors.accentFill,
                        preferred: Colors.black,
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _windowHeader(BuildContext context, {required bool hasRows}) {
    final window = WindowPresentationScope.maybeOf(context)!;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: window.compact ? 1 : 0, end: window.compact ? 1 : 0),
      duration: SyblMotion.duration(
        context,
        WindowPresentation.animationDuration,
      ),
      curve: WindowPresentation.animationCurve,
      builder: (context, progress, _) {
        Widget reveal(Widget child, double amount) => ClipRect(
          child: Align(
            widthFactor: amount,
            heightFactor: amount,
            child: Opacity(
              opacity: amount,
              child: ExcludeFocus(
                excluding: amount < 1,
                child: IgnorePointer(
                  ignoring: amount < 1,
                  child: ExcludeSemantics(excluding: amount < 1, child: child),
                ),
              ),
            ),
          ),
        );
        final compactStyle = TextStyle(
          color: context.syblColors.ink,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        );
        return Container(
          constraints: BoxConstraints(minHeight: 36 * progress),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: context.syblColors.line.withValues(alpha: progress),
                width: progress,
              ),
            ),
          ),
          padding: EdgeInsets.lerp(
            const EdgeInsets.fromLTRB(14, 12, 8, 8),
            const EdgeInsets.fromLTRB(4, 3, 4, 3),
            progress,
          ),
          child: Row(
            children: [
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (_) => window.command('drag'),
                  onSecondaryTapUp: (_) => window.command('systemMenu'),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Gravity(
                      child: HologramAnchor(
                        state: state,
                        child: Text(
                          'Your people',
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle.lerp(
                            context.syblColors.display.copyWith(fontSize: 16),
                            compactStyle,
                            progress,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (onSearch != null && hasRows)
                reveal(
                  Gravity(
                    child: IconButton(
                      key: const ValueKey('open-history-search'),
                      tooltip: 'Search history',
                      onPressed: onSearch,
                      constraints: const BoxConstraints.tightFor(
                        width: 36,
                        height: 36,
                      ),
                      padding: EdgeInsets.zero,
                      style: IconButton.styleFrom(
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      iconSize: 20,
                      icon: const Icon(Icons.search_rounded),
                    ),
                  ),
                  1 - progress,
                ),
              if (hasRows) _peopleActions(context),
              reveal(
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    NotificationBell(state: state),
                    if (state.call != null || state.groupCall != null)
                      CompactIconButton(
                        label: 'Return to call',
                        icon: Icons.call,
                        active: true,
                        onPressed: onOpenCall,
                      ),
                    const WindowModeButtons(),
                  ],
                ),
                progress,
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final windowCompact = WindowPresentationScope.isCompact(context);
    final compact = this.compact && !windowCompact;
    final friends = state.visibleFriends.toList(growable: false);
    final groups = state.groups.values.toList(growable: false);
    final chatCount = friends.length + groups.length;
    final hasRows = chatCount > 0 || state.pendingConnect != null;
    return DecoratedBox(
      decoration: BoxDecoration(color: context.syblColors.desk),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (WindowPresentationScope.maybeOf(context) != null && !compact)
            _windowHeader(context, hasRows: hasRows)
          else if (windowCompact)
            CompactHeader(
              title: 'Your people',
              titleWidget: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Flexible(
                    child: Gravity(
                      child: Text(
                        'Your people',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 5),
                  if (hasRows) _peopleActions(context),
                ],
              ),
              actions: [
                NotificationBell(state: state),
                if (state.call != null || state.groupCall != null)
                  CompactIconButton(
                    label: 'Return to call',
                    icon: Icons.call,
                    active: true,
                    onPressed: onOpenCall,
                  ),
              ],
            )
          else
            Padding(
              padding: EdgeInsets.fromLTRB(
                compact ? 18 : 14,
                compact ? 10 : 12,
                compact ? 12 : 8,
                compact ? 12 : 8,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Gravity(
                          child: HologramAnchor(
                            state: state,
                            child: Text(
                              'Your people',
                              maxLines: 1,
                              softWrap: false,
                              overflow: TextOverflow.ellipsis,
                              style: context.syblColors.display.copyWith(
                                fontSize: compact ? 22 : 16,
                              ),
                            ),
                          ),
                        ),
                        if (compact)
                          Gravity(
                            child: Text(
                              chatCount == 0
                                  ? 'No conversations yet'
                                  : '$chatCount ${chatCount == 1 ? 'conversation' : 'conversations'}',
                              style: TextStyle(
                                color: context.syblColors.faint,
                                fontSize: 11.5,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  // On Windows the bell sits in the title bar.
                  if (WindowPresentationScope.maybeOf(context) == null)
                    NotificationBell(state: state, large: compact),
                  if (onSearch != null && hasRows)
                    Gravity(
                      child: IconButton(
                        key: const ValueKey('open-history-search'),
                        tooltip: 'Search history',
                        onPressed: onSearch,
                        constraints: BoxConstraints.tight(
                          Size.square(compact ? 48 : 36),
                        ),
                        padding: EdgeInsets.zero,
                        style: IconButton.styleFrom(
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        iconSize: 20,
                        icon: const Icon(Icons.search_rounded),
                      ),
                    ),
                  if (hasRows) _peopleActions(context),
                ],
              ),
            ),
          Expanded(
            child: !hasRows
                ? Align(
                    alignment: compact
                        ? const Alignment(0, -.18)
                        : Alignment.center,
                    child: ScrollConfiguration(
                      behavior: ScrollConfiguration.of(
                        context,
                      ).copyWith(scrollbars: false),
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Gravity(
                              child: Text(
                                'Your friends\nwill be here',
                                textAlign: TextAlign.center,
                                style: context.syblColors.display.copyWith(
                                  fontSize: compact ? 26 : 16,
                                  height: 1.3,
                                ),
                              ),
                            ),
                            const SizedBox(height: 18),
                            Gravity(
                              child: OutlinedButton(
                                key: const ValueKey('add-first-friend'),
                                onPressed: onAddFriend,
                                style: OutlinedButton.styleFrom(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: compact ? 24 : 12,
                                    vertical: 12,
                                  ),
                                ),
                                child: const Text(
                                  'Add a friend',
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  )
                : ListView(
                    key: const ValueKey('friend-list'),
                    padding: EdgeInsets.only(
                      left: windowCompact || compact ? 8 : 1,
                      right: 8,
                    ),
                    children: [
                      for (final friend in friends)
                        Padding(
                          padding: const EdgeInsets.only(bottom: _railRowGap),
                          child: FriendRailRow(
                            state: state,
                            friend: friend,
                            highlightedPeerId: highlightedPeerId,
                            onPressed: () => onOpenFriend(friend),
                            onOpenCall:
                                compact && state.call?.peerId == friend.peerId
                                ? onOpenCall
                                : null,
                          ),
                        ),
                      for (final group in groups)
                        Padding(
                          padding: const EdgeInsets.only(bottom: _railRowGap),
                          child: GroupRailRow(
                            state: state,
                            group: group,
                            onPressed: () => onOpenGroup(group),
                          ),
                        ),
                      AnimatedSwitcher(
                        duration: SyblMotion.duration(context),
                        transitionBuilder: (child, animation) => SizeTransition(
                          sizeFactor: CurvedAnimation(
                            parent: animation,
                            curve: Curves.easeOutCubic,
                          ),
                          alignment: Alignment.topLeft,
                          child: FadeTransition(
                            opacity: animation,
                            child: child,
                          ),
                        ),
                        child: state.pendingConnect == null
                            ? const SizedBox(
                                key: ValueKey('no-pending-request'),
                              )
                            : Padding(
                                key: ValueKey(
                                  'pending-request-${state.pendingConnect!.convId}',
                                ),
                                padding: const EdgeInsets.only(
                                  top: 3,
                                  bottom: 3,
                                ),
                                child: _PendingRequestRow(
                                  state: state,
                                  compact: compact,
                                ),
                              ),
                      ),
                      if (state.archivedChats.isNotEmpty)
                        ArchivedChatsSection(state: state),
                    ],
                  ),
          ),
          if (!windowCompact &&
              state.groupCall != null &&
              state.selectedGroup == null)
            GroupCallDock(
              state: state,
              onOpenCall: onOpenCall,
              onOpenSettings: onOpenSettings,
            )
          else if (windowCompact || state.groupCall == null)
            Padding(
              padding: EdgeInsets.fromLTRB(
                compact ? 12 : 10,
                compact ? 6 : 7,
                compact ? 12 : 10,
                compact ? 12 : 10,
              ),
              child: _AccountRow(
                state: state,
                onPressed: onOpenSettings,
                compact: compact && !windowCompact,
                avatarAnchor: profileAvatarAnchor,
              ),
            ),
        ],
      ),
    );
  }
}

/// One portrait above the two pieces of rail chrome. Geometry is read during
/// paint, after both slots have been laid out, without a post-frame jump.
class RailProfileAvatar extends StatefulWidget {
  const RailProfileAvatar({
    super.key,
    required this.state,
    required this.start,
    required this.end,
    required this.progress,
  });

  final AppState state;
  final GlobalKey start;
  final GlobalKey end;
  final double progress;

  @override
  State<RailProfileAvatar> createState() => _RailProfileAvatarState();
}

class _RailProfileAvatarState extends State<RailProfileAvatar> {
  final _origin = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final status = state.appearOffline
        ? 'appearing offline'
        : state.registered
        ? 'online'
        : state.registration.toLowerCase();
    return IgnorePointer(
      child: ExcludeSemantics(
        child: Flow(
          key: _origin,
          clipBehavior: Clip.none,
          delegate: _RailProfileFlight(
            origin: _origin,
            start: widget.start,
            end: widget.end,
            progress: widget.progress,
          ),
          children: [
            SyblAvatar(
              key: const ValueKey('desktop-shared-profile-avatar'),
              label: state.displayName.trim().isEmpty
                  ? 'You'
                  : state.displayName,
              imageBase64: state.profileAvatarBase64,
              size: 38,
              color: context.syblColors.sage,
              statusColor: !state.appearOffline && state.registered
                  ? context.syblColors.online
                  : context.syblColors.faint,
              statusLabel: status,
              statusOpacity: 1 - widget.progress,
            ),
          ],
        ),
      ),
    );
  }
}

class _RailProfileFlight extends FlowDelegate {
  _RailProfileFlight({
    required this.origin,
    required this.start,
    required this.end,
    required this.progress,
  });

  final GlobalKey origin;
  final GlobalKey start;
  final GlobalKey end;
  final double progress;

  RenderBox? box(GlobalKey key) {
    final render = key.currentContext?.findRenderObject();
    return render is RenderBox && render.attached && render.hasSize
        ? render
        : null;
  }

  @override
  BoxConstraints getConstraintsForChild(int i, BoxConstraints constraints) =>
      const BoxConstraints.tightFor(width: 38, height: 38);

  @override
  void paintChildren(FlowPaintingContext context) {
    final from = box(start);
    final to = box(end);
    final root = box(origin);
    if (root == null || (from == null && (to == null || progress == 0))) return;
    Rect rect(RenderBox b) => b.localToGlobal(Offset.zero) & b.size;
    final target = Rect.lerp(rect(from ?? to!), rect(to ?? from!), progress)!;
    final offset = target.topLeft - root.localToGlobal(Offset.zero);
    context.paintChild(
      0,
      // A call dock can replace the source card. Only a genuinely new portrait
      // fades in; a portrait with both anchors always stays fully painted.
      opacity: from == null
          ? progress
          : to == null
          ? 1 - progress
          : 1,
      transform: Matrix4.identity()
        ..translateByDouble(offset.dx, offset.dy, 0, 1)
        ..scaleByDouble(target.width / 38, target.height / 38, 1, 1),
    );
  }

  @override
  bool shouldRepaint(covariant _RailProfileFlight oldDelegate) => true;
}

class GroupMiniRail extends StatelessWidget {
  const GroupMiniRail({
    super.key,
    required this.state,
    required this.onOpenPeople,
    this.onSearch,
    required this.onOpenFriend,
    required this.onOpenGroup,
    required this.onOpenSettings,
    this.profileAvatarAnchor,
  });

  final AppState state;
  final VoidCallback onOpenPeople;
  final VoidCallback? onSearch;
  final ValueChanged<FriendState> onOpenFriend;
  final ValueChanged<GroupState> onOpenGroup;
  final VoidCallback onOpenSettings;
  final GlobalKey? profileAvatarAnchor;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = ((constraints.maxWidth - 58) / (SyblLayout.railWidth - 58))
            .clamp(0.0, 1.0);
        final friendExtent = _railRowExtent(context);
        final groupExtents = {
          for (final group in state.groups.values)
            group.conversationId: _railRowExtent(
              context,
              group: group,
              unread: state.groupHasUnread(group.conversationId),
            ),
        };
        final headerTextExtent = _railLineExtent(
          context,
          Theme.of(context).textTheme.bodyMedium!.merge(
            context.syblColors.display.copyWith(fontSize: 16),
          ),
        );
        final headerGrowth = headerTextExtent > 36
            ? headerTextExtent - 36
            : 0.0;
        const groupSelectionInset = 6.0;
        Widget column(Widget child) => Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(width: 58, child: child),
        );
        return ColoredBox(
          // Navigation stays darker than topics. Selection uses the same fill
          // in the full people list and the narrow rail.
          color: context.syblColors.desk,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                column(
                  Gravity(
                    child: Tooltip(
                      message: 'Your people',
                      child: HologramAnchor(
                        state: state,
                        child: IconButton(
                          key: const ValueKey('group-mini-home'),
                          onPressed: onOpenPeople,
                          constraints: BoxConstraints.tight(
                            const Size.square(48),
                          ),
                          padding: EdgeInsets.zero,
                          icon: const Icon(Icons.home_outlined),
                        ),
                      ),
                    ),
                  ),
                ),
                SizedBox(height: 3 + headerGrowth),
                Expanded(
                  child: ListView(
                    padding: EdgeInsets.zero,
                    children: [
                      for (final friend in state.visibleFriends)
                        column(
                          Padding(
                            padding: EdgeInsets.fromLTRB(
                              5,
                              (friendExtent - _railRowMinExtent) / 2,
                              5,
                              13 + (friendExtent - _railRowMinExtent) / 2,
                            ),
                            child: Tooltip(
                              message: friendLabel(friend),
                              child: InkWell(
                                key: ValueKey('friend-mini-${friend.peerId}'),
                                onTap: () => onOpenFriend(friend),
                                customBorder: const CircleBorder(),
                                child: _CallActivityFrame(
                                  key: ValueKey(
                                    'friend-mini-call-ring-${friend.peerId}',
                                  ),
                                  connecting:
                                      state.call?.peerId == friend.peerId &&
                                      state.call?.connected != true,
                                  connected:
                                      state.call?.peerId == friend.peerId &&
                                      state.call?.connected == true,
                                  circular: true,
                                  child: AnimatedContainer(
                                    key: ValueKey(
                                      'friend-mini-ring-${friend.peerId}',
                                    ),
                                    duration: SyblMotion.duration(context),
                                    // 0.5 keeps avatar, selection ring and call ring
                                    // inside the 48 px the rail rows are laid out for.
                                    padding: const EdgeInsets.all(.5),
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: context.syblColors.surface,
                                      border: Border.all(
                                        color:
                                            state.selectedFriend?.peerId ==
                                                friend.peerId
                                            ? context.syblColors.amber
                                            : Colors.transparent,
                                        width: 2,
                                      ),
                                    ),
                                    child: HologramAnchor(
                                      state: state,
                                      peerId: friend.peerId,
                                      child: SyblAvatar(
                                        label: friendLabel(friend),
                                        imageBase64: friend.avatarBase64,
                                        size: 38,
                                        statusColor: friendPresenceColor(
                                          context,
                                          state,
                                          friend,
                                        ),
                                        statusIcon: friendPresenceIcon(friend),
                                        statusLabel: friendPresenceLabel(
                                          state,
                                          friend,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      for (final group in state.groups.values)
                        Padding(
                          padding: const EdgeInsets.only(
                            bottom: _railRowGap + 12,
                          ),
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              // The selection spans the shrinking rail, rather
                              // than compositing a separate 58 px avatar strip.
                              Positioned(
                                left: wide,
                                right: 8 * wide,
                                top: -groupSelectionInset + 1,
                                bottom: -groupSelectionInset - 1,
                                child: DecoratedBox(
                                  key: ValueKey(
                                    'group-mini-selection-${group.conversationId}',
                                  ),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.lerp(
                                      const BorderRadius.horizontal(
                                        left: Radius.circular(_railRowRadius),
                                      ),
                                      BorderRadius.circular(_railRowRadius),
                                      wide,
                                    ),
                                    color:
                                        state.selectedGroupId ==
                                            group.conversationId
                                        ? context.syblColors.surface
                                        : Colors.transparent,
                                  ),
                                ),
                              ),
                              column(
                                Tooltip(
                                  message: group.displayTitle,
                                  child: InkWell(
                                    key: ValueKey(
                                      'group-mini-${group.conversationId}',
                                    ),
                                    onTap: () => onOpenGroup(group),
                                    borderRadius: const BorderRadius.horizontal(
                                      left: Radius.circular(_railRowRadius),
                                    ),
                                    child: Container(
                                      width: double.infinity,
                                      height:
                                          groupExtents[group.conversationId]! -
                                          12,
                                      alignment: Alignment.center,
                                      child: Transform.translate(
                                        offset: const Offset(0, 1),
                                        child: SizedBox.square(
                                          dimension: 38,
                                          child: GroupAvatar(
                                            state: state,
                                            group: group,
                                            size: 38,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                if (onSearch != null)
                  column(
                    Gravity(
                      child: IconButton(
                        key: const ValueKey('mini-open-history-search'),
                        tooltip: 'Search history',
                        onPressed: onSearch,
                        icon: const Icon(Icons.search_rounded),
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                column(
                  SizedBox(
                    height: _accountRowExtent(context),
                    child: Center(
                      child: Tooltip(
                        message: 'Settings',
                        child: IconButton(
                          key: const ValueKey('group-mini-settings'),
                          onPressed: onOpenSettings,
                          constraints: BoxConstraints.tight(
                            const Size.square(48),
                          ),
                          padding: EdgeInsets.zero,
                          icon: _CallActivityFrame(
                            key: const ValueKey('group-mini-self-ring'),
                            connecting:
                                state.call != null &&
                                state.call?.connected != true,
                            connected: state.call?.connected == true,
                            circular: true,
                            child: profileAvatarAnchor != null
                                ? SizedBox.square(
                                    key: profileAvatarAnchor,
                                    dimension: 38,
                                  )
                                : SyblAvatar(
                                    label: state.displayName.trim().isEmpty
                                        ? 'You'
                                        : state.displayName,
                                    imageBase64: state.profileAvatarBase64,
                                    size: 38,
                                    color: context.syblColors.sage,
                                  ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class GroupRailRow extends StatelessWidget {
  const GroupRailRow({
    super.key,
    required this.state,
    required this.group,
    required this.onPressed,
  });

  final AppState state;
  final GroupState group;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final state = this.state;
    final group = this.group;
    final selected = state.selectedGroupId == group.conversationId;
    final unread = state.groupHasUnread(group.conversationId);
    return Semantics(
      button: true,
      selected: selected,
      label:
          '${group.displayTitle}, ${group.memberCount} members${unread ? ', unread messages' : ''}',
      child: Material(
        key: ValueKey('group-row-background-${group.conversationId}'),
        color: selected ? context.syblColors.surface : Colors.transparent,
        borderRadius: BorderRadius.circular(_railRowRadius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('group-${group.conversationId}'),
          onTap: onPressed,
          child: LayoutBuilder(
            builder: (context, constraints) => ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: _railRowExtent(
                  context,
                  group: group,
                  unread: unread,
                  width: constraints.maxWidth,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
                child: Row(
                  children: [
                    GroupAvatar(state: state, group: group, size: 38),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ExcludeSemantics(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Gravity(
                              child: Text(
                                group.displayTitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: context.syblColors.ink,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Gravity(
                              child: Text(
                                '${group.memberCount} members',
                                style: TextStyle(
                                  color: context.syblColors.faint,
                                  fontSize: 11,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (unread)
                      Container(
                        key: ValueKey('group-unread-${group.conversationId}'),
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: context.syblColors.sage,
                          shape: BoxShape.circle,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class GroupMemberLine extends StatelessWidget {
  const GroupMemberLine({
    super.key,
    required this.state,
    required this.group,
    required this.memberId,
    required this.invited,
  });

  final AppState state;
  final GroupState group;
  final String memberId;
  final bool invited;

  @override
  Widget build(BuildContext context) {
    final self = memberId == state.jamiId;
    final label = groupMemberLabel(state, group, memberId);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SyblAvatar(
            label: label,
            imageBase64: groupMemberAvatar(state, group, memberId),
            size: 24,
            color: context.syblColors.sage,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Gravity(
              child: Text(
                self ? '$label (you)' : label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: context.syblColors.muted, fontSize: 11),
              ),
            ),
          ),
          Gravity(
            child: Text(
              invited ? 'Invited' : 'Member',
              style: TextStyle(
                color: invited
                    ? context.syblColors.amber
                    : context.syblColors.faint,
                fontSize: 10,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class GroupAvatar extends StatelessWidget {
  const GroupAvatar({
    super.key,
    required this.state,
    required this.group,
    this.size = 42,
    this.expanded = false,
  });

  final AppState state;
  final GroupState group;
  final double size;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final collapsedIds = <String>{
      ...group.activeMemberIds,
      ...group.invitedMemberIds,
    }.toList(growable: false);
    final collapsedShown = collapsedIds.take(2).toList(growable: false);
    final collapsedHidden = (group.memberCount - collapsedShown.length).clamp(
      0,
      999,
    );
    final collapsedAvatarSize = size * .68;

    Widget memberAvatar(String? memberId, Color color, double avatarSize) {
      final label = memberId == null
          ? group.displayTitle
          : groupMemberLabel(state, group, memberId);
      return Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: context.syblColors.bg, width: 2),
        ),
        child: SyblAvatar(
          label: label,
          imageBase64: memberId == null
              ? ''
              : groupMemberAvatar(state, group, memberId),
          size: avatarSize,
          color: color,
        ),
      );
    }

    Widget withSemantics(Widget child) => Semantics(
      image: true,
      label:
          '${group.displayTitle} group, ${group.memberCount} ${group.memberCount == 1 ? 'member' : 'members'}',
      child: GroupRoomActivity(
        state: state,
        group: group,
        child: ExcludeSemantics(child: child),
      ),
    );

    if (!expanded) {
      return withSemantics(
        SizedBox.square(
          dimension: size,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                top: 0,
                left: 0,
                child: memberAvatar(
                  collapsedShown.isEmpty ? null : collapsedShown.first,
                  context.syblColors.amber,
                  collapsedAvatarSize,
                ),
              ),
              Positioned(
                right: 0,
                bottom: 0,
                child: memberAvatar(
                  collapsedShown.length < 2 ? null : collapsedShown[1],
                  context.syblColors.sage,
                  collapsedAvatarSize,
                ),
              ),
              if (collapsedHidden > 0)
                Positioned(
                  right: -2,
                  bottom: -2,
                  child: _GroupOverflowBadge(
                    key: ValueKey(
                      'group-avatar-overflow-${group.conversationId}',
                    ),
                    value: collapsedHidden,
                    size: size,
                  ),
                ),
            ],
          ),
        ),
      );
    }

    final remoteIds = <String>{
      ...collapsedIds,
      ...group.memberIds,
    }.toList(growable: false);
    final members = <String?>[...remoteIds];
    if (state.jamiId.isNotEmpty &&
        !remoteIds.contains(state.jamiId) &&
        group.memberCount > remoteIds.length) {
      members.add(state.jamiId);
    }
    if (members.length < 2) {
      members.addAll(List.filled(2 - members.length, null));
    }
    final shown = members.take(6).toList(growable: false);
    final expandedShown = shown.whereType<String>().length;
    final expandedHidden = (group.memberCount - expandedShown).clamp(0, 999);
    final expandedAvatarSize = size * .86;
    const gap = 4.0;
    final badgeSize = size * .42;
    final expandedWidth =
        shown.length * expandedAvatarSize +
        (shown.length - 1) * gap +
        (expandedHidden > 0 ? badgeSize + gap : 0);

    return withSemantics(
      TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: SyblMotion.duration(context),
        curve: Curves.easeOutCubic,
        builder: (context, progress, _) {
          final avatarSize =
              collapsedAvatarSize +
              (expandedAvatarSize - collapsedAvatarSize) * progress;
          final width = size + (expandedWidth - size) * progress;
          final collapsedBadgeSize = size * .42;
          return SizedBox(
            width: width,
            height: size,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                for (var index = 0; index < shown.length; index++)
                  Positioned(
                    left:
                        (index == 0 ? 0 : size - collapsedAvatarSize) +
                        (index * (expandedAvatarSize + gap) -
                                (index == 0 ? 0 : size - collapsedAvatarSize)) *
                            progress,
                    top:
                        (index == 0 ? 0 : size - collapsedAvatarSize) +
                        ((size - expandedAvatarSize) / 2 -
                                (index == 0 ? 0 : size - collapsedAvatarSize)) *
                            progress,
                    child: Opacity(
                      opacity: index < 2 ? 1 : progress,
                      child: Tooltip(
                        message: shown[index] == null
                            ? group.displayTitle
                            : groupMemberLabel(state, group, shown[index]!),
                        child: memberAvatar(
                          shown[index],
                          index.isEven
                              ? context.syblColors.amber
                              : context.syblColors.sage,
                          avatarSize,
                        ),
                      ),
                    ),
                  ),
                if (collapsedHidden > 0 || expandedHidden > 0)
                  Positioned(
                    left:
                        size -
                        collapsedBadgeSize +
                        2 +
                        (shown.length * (expandedAvatarSize + gap) -
                                (size - collapsedBadgeSize + 2)) *
                            progress,
                    top:
                        size -
                        collapsedBadgeSize +
                        2 +
                        ((size - badgeSize) / 2 -
                                (size - collapsedBadgeSize + 2)) *
                            progress,
                    child: Opacity(
                      opacity: expandedHidden > 0 ? 1 : 1 - progress,
                      child: _GroupOverflowBadge(
                        key: ValueKey(
                          'group-avatar-overflow-${group.conversationId}',
                        ),
                        value: progress < .5 ? collapsedHidden : expandedHidden,
                        size: size,
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _GroupOverflowBadge extends StatelessWidget {
  const _GroupOverflowBadge({
    super.key,
    required this.value,
    required this.size,
  });

  final int value;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    constraints: BoxConstraints(minWidth: size * .42, minHeight: size * .42),
    padding: const EdgeInsets.symmetric(horizontal: 3.5, vertical: 1),
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: context.syblColors.accentFill,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: context.syblColors.bg, width: 1.5),
    ),
    child: Text(
      '+$value',
      style: TextStyle(
        color: context.syblColors.foregroundFor(
          context.syblColors.accentFill,
          preferred: Colors.black,
        ),
        fontSize: (size * .24).clamp(10, 13),
        height: 1.1,
        fontWeight: FontWeight.w800,
      ),
    ),
  );
}

class FriendRailRow extends StatelessWidget {
  final AppState state;
  final FriendState friend;
  final String? highlightedPeerId;
  final VoidCallback onPressed;
  final VoidCallback? onOpenCall;

  const FriendRailRow({
    super.key,
    required this.state,
    required this.friend,
    this.highlightedPeerId,
    required this.onPressed,
    this.onOpenCall,
  });

  Future<void> _confirmRemoval(BuildContext context, String action) async {
    final blocking = action == 'block';
    final label = friendLabel(friend);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Gravity(
          child: Text(
            blocking ? 'Block $label?' : 'Remove $label?',
            style: context.syblColors.display.copyWith(fontSize: 19),
          ),
        ),
        content: Gravity(
          child: Text(
            blocking
                ? 'They will be removed and blocked from reconnecting.'
                : 'They will be removed from your people. You can add them again later with their friend ID.',
            style: TextStyle(
              color: context.syblColors.muted,
              fontSize: 13,
              height: 1.45,
            ),
          ),
        ),
        actions: [
          Gravity(
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
          ),
          Gravity(
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: blocking
                    ? context.syblColors.dangerFill
                    : context.syblColors.accentFill,
                foregroundColor: blocking
                    ? context.syblColors.foregroundFor(
                        context.syblColors.dangerFill,
                      )
                    : context.syblColors.onAccent,
              ),
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(blocking ? 'Block' : 'Remove'),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final result = await state.removeFriend(friend.peerId, block: blocking);
    if (result.warning != null) showNotice(result.warning!);
  }

  Future<void> _confirmLeftChat(BuildContext context) async {
    final label = friendLabel(friend);
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Gravity(
          child: Text(
            'Remove $label?',
            style: context.syblColors.display.copyWith(fontSize: 19),
          ),
        ),
        content: Gravity(
          child: Text(
            'They removed you. Archive keeps a read-only copy on this device; Delete removes the chat.',
            style: TextStyle(
              color: context.syblColors.muted,
              fontSize: 13,
              height: 1.45,
            ),
          ),
        ),
        actions: [
          Gravity(
            child: TextButton(
              key: const ValueKey('left-chat-cancel'),
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
          ),
          Gravity(
            child: TextButton(
              key: const ValueKey('left-chat-delete'),
              onPressed: () => Navigator.of(context).pop('delete'),
              child: const Text('Delete'),
            ),
          ),
          Gravity(
            child: FilledButton(
              key: const ValueKey('left-chat-archive'),
              style: FilledButton.styleFrom(
                backgroundColor: context.syblColors.accentFill,
              ),
              onPressed: () => Navigator.of(context).pop('archive'),
              child: const Text('Archive'),
            ),
          ),
        ],
      ),
    );
    if (choice == null || !context.mounted) return;
    final result = choice == 'archive'
        ? await state.archiveLeftChat(friend.peerId)
        : await state.deleteLeftChat(friend.peerId);
    if (result.warning != null) showNotice(result.warning!);
  }

  Future<void> _showManagementMenu(
    BuildContext context, [
    Offset? globalPosition,
  ]) async {
    final owner = state.linkedDeviceOwner;
    final box = context.findRenderObject() as RenderBox?;
    final origin =
        globalPosition ??
        (box == null
            ? const Offset(0, 0)
            : box.localToGlobal(Offset(box.size.width, box.size.height / 2)));
    final screen = MediaQuery.sizeOf(context);
    final action = await showMenu<String>(
      context: context,
      color: context.syblColors.surfaceTop,
      position: RelativeRect.fromLTRB(
        origin.dx,
        origin.dy,
        (screen.width - origin.dx).clamp(0, screen.width),
        (screen.height - origin.dy).clamp(0, screen.height),
      ),
      items: const [
        PopupMenuItem(value: 'details', child: Text('Friend options')),
        PopupMenuItem(value: 'remove', child: Text('Remove')),
        PopupMenuItem(value: 'block', child: Text('Block')),
      ],
    );
    if (action == null ||
        !context.mounted ||
        owner != state.linkedDeviceOwner) {
      return;
    }
    if (action == 'details') {
      await showFriendOptions(context, state, friend.peerId);
      return;
    }
    await _confirmRemoval(context, action);
  }

  @override
  Widget build(BuildContext context) {
    final selected = (highlightedPeerId ?? state.peerId) == friend.peerId;
    final displayName = friendLabel(friend);
    final left = state.peerLeft(friend.peerId);
    final presence = left ? 'removed you' : friendPresenceLabel(state, friend);
    final activity = state.friendActivity(friend.peerId);
    final call = state.call;
    final inCall = call?.peerId == friend.peerId;
    final connected = inCall && call!.connected;
    return Semantics(
      button: true,
      selected: selected,
      label: '$displayName, $presence',
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onLongPress: () => _showManagementMenu(context),
        onSecondaryTapDown: (details) =>
            _showManagementMenu(context, details.globalPosition),
        child: Stack(
          children: [
            Positioned.fill(
              child: Gravity(
                key: ValueKey('friend-row-background-${friend.peerId}'),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: selected
                        ? context.syblColors.surfaceTop
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(_railRowRadius),
                  ),
                ),
              ),
            ),
            _CallActivityFrame(
              key: ValueKey('friend-call-ring-${friend.peerId}'),
              connecting: inCall && !connected,
              connected: connected,
              childRadius: _railRowRadius,
              // Mask the filled gradient inside the frame, including its fadeout.
              child: Stack(
                children: [
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: selected
                            ? context.syblColors.surfaceTop
                            : context.syblColors.desk,
                        borderRadius: BorderRadius.circular(_railRowRadius),
                      ),
                    ),
                  ),
                  Material(
                    type: MaterialType.transparency,
                    child: InkWell(
                      key: ValueKey('friend-${friend.peerId}'),
                      onTap: onPressed,
                      borderRadius: BorderRadius.circular(_railRowRadius),
                      child: ConstrainedBox(
                        // The frame's ring comes out of the row's own padding, so the
                        // avatar and text stay exactly where they were without it.
                        constraints: BoxConstraints(
                          minHeight:
                              _railRowExtent(context) - 2 * _callRingWidth,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(
                            6.5,
                            5.5,
                            6.5,
                            5.5,
                          ),
                          child: Row(
                            children: [
                              HologramAnchor(
                                state: state,
                                peerId: friend.peerId,
                                child: _FriendAvatarWithActivity(
                                  label: displayName,
                                  imageBase64: friend.avatarBase64,
                                  activity: activity,
                                  showActivity:
                                      state.unreadBadgePlacement ==
                                      UnreadBadgePlacement.avatar,
                                  statusColor: friendPresenceColor(
                                    context,
                                    state,
                                    friend,
                                  ),
                                  statusIcon: friendPresenceIcon(friend),
                                  statusLabel: presence,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: ExcludeSemantics(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Gravity(
                                        child: Text(
                                          displayName,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: context.syblColors.ink,
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Gravity(
                                        child: Text(
                                          presence,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: context.syblColors.faint,
                                            fontSize: 11,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              if (left)
                                Gravity(
                                  child: IconButton(
                                    key: ValueKey(
                                      'friend-left-remove-${friend.peerId}',
                                    ),
                                    tooltip: 'Remove $displayName',
                                    onPressed: () => _confirmLeftChat(context),
                                    iconSize: 18,
                                    icon: const Icon(Icons.close_rounded),
                                  ),
                                )
                              else
                                _FriendActivityTrailing(
                                  activity: activity,
                                  onOpenCall: onOpenCall,
                                  showUnread:
                                      state.unreadBadgePlacement ==
                                      UnreadBadgePlacement.trailing,
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FriendActivityTrailing extends StatelessWidget {
  const _FriendActivityTrailing({
    required this.activity,
    required this.onOpenCall,
    required this.showUnread,
  });

  final FriendActivity activity;
  final VoidCallback? onOpenCall;
  final bool showUnread;

  @override
  Widget build(BuildContext context) {
    if (onOpenCall != null) {
      return Gravity(
        child: Tooltip(
          message: 'Open call',
          child: Material(
            key: const ValueKey('return-to-call-button'),
            color: context.syblColors.surfaceHi,
            shape: context.syblColors.buttonShape.copyWith(
              side: BorderSide(color: context.syblColors.online, width: 1.5),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onOpenCall,
              customBorder: context.syblColors.buttonShape,
              child: SizedBox(
                width: 68,
                height: 38,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.arrow_forward_rounded,
                      size: 17,
                      color: context.syblColors.online,
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      Icons.phone_in_talk_rounded,
                      size: 20,
                      color: context.syblColors.online,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    final age = _relativeAge(activity.lastActivityAt);
    final unread = activity.unreadTotal;
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 34),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showUnread && unread > 0)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (activity.unreadFiles > 0) ...[
                  Icon(
                    Icons.attach_file_rounded,
                    size: 14,
                    color: context.syblColors.amber,
                  ),
                  const SizedBox(width: 3),
                ],
                _AvatarUnreadBadge(
                  key: const ValueKey('trailing-unread-badge'),
                  count: unread,
                  prominent: true,
                ),
              ],
            )
          else if (age.isNotEmpty)
            Gravity(
              child: Text(
                age,
                style: TextStyle(color: context.syblColors.faint, fontSize: 10),
              ),
            ),
        ],
      ),
    );
  }
}

class _FriendAvatarWithActivity extends StatelessWidget {
  const _FriendAvatarWithActivity({
    required this.label,
    required this.imageBase64,
    required this.activity,
    required this.showActivity,
    required this.statusColor,
    required this.statusIcon,
    required this.statusLabel,
  });

  final String label;
  final String imageBase64;
  final FriendActivity activity;
  final bool showActivity;
  final Color statusColor;
  final IconData? statusIcon;
  final String statusLabel;

  @override
  Widget build(BuildContext context) {
    final unread = activity.unreadTotal;
    return SizedBox.square(
      dimension: 42,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: 0,
            top: 2,
            child: SyblAvatar(
              label: label,
              imageBase64: imageBase64,
              size: 38,
              statusColor: statusColor,
              statusIcon: statusIcon,
              statusLabel: statusLabel,
              statusOnLeft: showActivity && unread > 0,
            ),
          ),
          if (showActivity && activity.unreadFiles > 0)
            Positioned(
              right: -1,
              top: -1,
              child: _AvatarActivityIcon(icon: Icons.attach_file_rounded),
            ),
          if (showActivity && unread > 0)
            Positioned(
              right: -2,
              bottom: -1,
              child: _AvatarUnreadBadge(
                key: const ValueKey('avatar-unread-badge'),
                count: unread,
              ),
            ),
        ],
      ),
    );
  }
}

class _AvatarActivityIcon extends StatelessWidget {
  const _AvatarActivityIcon({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: context.syblColors.accentFill,
        border: Border.all(color: context.syblColors.bg, width: 2),
      ),
      child: SizedBox.square(
        dimension: 17,
        child: Icon(icon, size: 10, color: context.syblColors.onAccent),
      ),
    );
  }
}

class _AvatarUnreadBadge extends StatelessWidget {
  const _AvatarUnreadBadge({
    super.key,
    required this.count,
    this.prominent = false,
  });

  final int count;
  final bool prominent;

  @override
  Widget build(BuildContext context) {
    final value = count > 99 ? '99+' : '$count';
    return Container(
      constraints: BoxConstraints(
        minWidth: prominent ? 24 : 18,
        minHeight: prominent ? 22 : 18,
      ),
      padding: EdgeInsets.symmetric(horizontal: prominent ? 6 : 4),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: context.syblColors.dangerFill,
        borderRadius: BorderRadius.circular(prominent ? 11 : 10),
        border: Border.all(color: context.syblColors.bg, width: 2),
      ),
      child: Text(
        value,
        style: TextStyle(
          color: context.syblColors.foregroundFor(
            context.syblColors.dangerFill,
          ),
          fontSize: prominent ? 10.5 : 9,
          height: 1,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

String _relativeAge(DateTime? value) {
  if (value == null) return '';
  final elapsed = DateTime.now().difference(value.toLocal());
  if (elapsed.isNegative || elapsed.inMinutes < 1) return 'now';
  if (elapsed.inHours < 1) return '${elapsed.inMinutes}m';
  if (elapsed.inDays < 1) return '${elapsed.inHours}h';
  if (elapsed.inDays < 7) return '${elapsed.inDays}d';
  if (elapsed.inDays < 365) return '${(elapsed.inDays / 7).floor()}w';
  return '${(elapsed.inDays / 365).floor()}y';
}

class _PendingRequestRow extends StatelessWidget {
  final AppState state;
  final bool compact;

  const _PendingRequestRow({required this.state, required this.compact});

  @override
  Widget build(BuildContext context) {
    final request = state.pendingConnect;
    if (request == null) return const SizedBox.shrink();
    final known = state.friends[request.fromJamiId];
    // The profile name arrives after the request itself. Until it does, show
    // one steady placeholder, then fade the name in, instead of stepping
    // through generic labels.
    final profileName = known?.displayName.trim() ?? '';
    final id = request.fromJamiId;
    // A request's own name is the sender's claim, used only as a label.
    final hint = profileName.isEmpty && !request.isGroup
        ? state.nameHint(id) ?? ''
        : '';
    final name = profileName.isNotEmpty ? profileName : hint;
    final sender = name.isNotEmpty
        ? name
        : request.isGroup
        ? 'Group invitation'
        : 'Friend request';
    final contextLabel = request.isGroup
        ? 'Join group?'
        : 'wants to be friends';
    return Semantics(
      container: true,
      label: '$sender, $contextLabel',
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(9),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
          child: Row(
            children: [
              SyblAvatar(
                label: name.isEmpty ? '?' : name,
                imageBase64: known?.avatarBase64,
                size: 40,
                color: context.syblColors.amber,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ExcludeSemantics(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Gravity(
                        child: AnimatedSwitcher(
                          duration: SyblMotion.duration(
                            context,
                            const Duration(milliseconds: 260),
                          ),
                          layoutBuilder: (current, previous) => Stack(
                            alignment: Alignment.centerLeft,
                            children: [...previous, ?current],
                          ),
                          child: Column(
                            key: ValueKey(name),
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Gravity(
                                child: Text(
                                  sender,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: context.syblColors.ink,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 2),
                              Gravity(
                                child: Text(
                                  contextLabel,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: context.syblColors.faint,
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Gravity(
                child: IconButton.outlined(
                  key: const ValueKey('deny-friend-request'),
                  tooltip: 'Decline',
                  constraints: BoxConstraints.tight(
                    Size.square(compact ? 48 : 36),
                  ),
                  onPressed: state.handlingConnect
                      ? null
                      : () => state.ignoreConnect(),
                  icon: const Icon(Icons.close_rounded, size: 19),
                ),
              ),
              const SizedBox(width: 5),
              Gravity(
                child: IconButton.filled(
                  key: const ValueKey('accept-friend-request'),
                  tooltip: 'Accept',
                  constraints: BoxConstraints.tight(
                    Size.square(compact ? 48 : 36),
                  ),
                  style: IconButton.styleFrom(
                    backgroundColor: context.syblColors.accentFill,
                    foregroundColor: context.syblColors.foregroundFor(
                      context.syblColors.accentFill,
                      preferred: Colors.black,
                    ),
                  ),
                  onPressed: state.handlingConnect
                      ? null
                      : () => state.allowConnect(),
                  icon: state.handlingConnect
                      ? SizedBox.square(
                          dimension: 15,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: context.syblColors.foregroundFor(
                              context.syblColors.accentFill,
                              preferred: Colors.black,
                            ),
                          ),
                        )
                      : const Icon(Icons.check_rounded, size: 19),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Match the expanded card's natural row height, including large text, so the
// profile portrait and its settings hit area keep one vertical baseline.
double _accountRowExtent(BuildContext context) {
  final base = Theme.of(context).textTheme.bodyMedium!;
  final text =
      _railLineExtent(
        context,
        base.copyWith(fontSize: 14, fontWeight: FontWeight.w600),
      ) +
      _railLineExtent(context, base.copyWith(fontSize: 11));
  return (text > 38 ? text : 38) + 16 + 2 * _callRingWidth;
}

class _AccountRow extends StatelessWidget {
  final AppState state;
  final VoidCallback onPressed;
  final bool compact;
  final GlobalKey? avatarAnchor;

  const _AccountRow({
    required this.state,
    required this.onPressed,
    required this.compact,
    this.avatarAnchor,
  });

  @override
  Widget build(BuildContext context) {
    final name = state.displayName.trim().isEmpty ? 'You' : state.displayName;
    final call = state.call;
    final connected = call?.connected == true;
    final connecting = call != null && !connected;
    final registration = state.appearOffline
        ? 'appearing offline'
        : call != null
        ? connected
              ? 'in call with ${state.peerDisplayName(call.peerId)}'
              : call.dir == CallDir.outgoing
              ? 'calling ${state.peerDisplayName(call.peerId)}…'
              : 'connecting with ${state.peerDisplayName(call.peerId)}…'
        : state.registered
        ? 'online'
        : state.registration.toLowerCase();
    final inCall = call != null;
    return Semantics(
      button: true,
      label: 'Your profile. $name, $registration',
      child: _CallActivityFrame(
        key: const ValueKey('account-card'),
        connecting: connecting,
        connected: connected,
        childRadius: 16.5,
        // Under gravity pieces pile on the card's top edge until a few hard
        // throws break that edge; the card itself stays.
        child: GravityPlatform(
          color: context.syblColors.line,
          builder: (context, _) => Material(
            color: context.syblColors.surfaceHi,
            borderRadius: BorderRadius.circular(16.5),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: const ValueKey('account-menu-button'),
              onTap: () async {
                final action = state.captureConversationAction();
                final wasOffline = state.appearOffline;
                final box = context.findRenderObject()! as RenderBox;
                final overlay =
                    Navigator.of(context).overlay!.context.findRenderObject()!
                        as RenderBox;
                final choice = await showMenu<String>(
                  context: context,
                  position: RelativeRect.fromRect(
                    box.localToGlobal(Offset.zero, ancestor: overlay) &
                        box.size,
                    Offset.zero & overlay.size,
                  ),
                  items: [
                    PopupMenuItem(
                      value: 'status',
                      enabled:
                          !state.changingAppearOffline &&
                          state.settingsControlsEnabled,
                      child: Text(
                        state.appearOffline ? 'Go online' : 'Go offline',
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'settings',
                      child: Text('Settings'),
                    ),
                  ],
                );
                if (!context.mounted || !state.ownsConversationAction(action)) {
                  return;
                }
                if (choice == 'status') {
                  if (!state.settingsControlsEnabled ||
                      state.changingAppearOffline ||
                      state.appearOffline != wasOffline) {
                    return;
                  }
                  await state.setAppearOffline(!wasOffline);
                } else if (choice == 'settings') {
                  onPressed();
                }
              },
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: compact ? 16 : 11,
                  vertical: compact ? 14 : 8,
                ),
                child: Row(
                  children: [
                    if (avatarAnchor != null)
                      SizedBox.square(
                        key: avatarAnchor,
                        dimension: compact ? 56 : 38,
                      )
                    else
                      SyblAvatar(
                        label: name,
                        imageBase64: state.profileAvatarBase64,
                        size: compact ? 56 : 38,
                        color: context.syblColors.sage,
                        statusColor: state.appearOffline
                            ? context.syblColors.faint
                            : state.registered
                            ? context.syblColors.online
                            : context.syblColors.faint,
                        statusLabel: registration,
                      ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ExcludeSemantics(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Gravity(
                              child: Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: context.syblColors.ink,
                                  fontSize: compact ? 18 : 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            Gravity(
                              child: Text(
                                registration,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: context.syblColors.faint,
                                  fontSize: compact ? 14 : 11,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (inCall) ...[
                      Gravity(child: _LiveMicrophone(state: state)),
                      const SizedBox(width: 6),
                    ],
                    Gravity(
                      child: IconButton(
                        key: const ValueKey('open-settings-button'),
                        tooltip: 'Settings',
                        onPressed: onPressed,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints.tightFor(
                          width: 38,
                          height: 38,
                        ),
                        style: IconButton.styleFrom(
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        icon: Icon(
                          Icons.settings_outlined,
                          color: context.syblColors.faint,
                          size: 19,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Width of the call outline every [_CallActivityFrame] reserves around its
/// child. The frame paints a filled shape and the child covers all but this
/// ring, so every child must paint an opaque background of its own.
const double _callRingWidth = 2.5;

class _CallActivityFrame extends StatefulWidget {
  const _CallActivityFrame({
    super.key,
    required this.connecting,
    required this.connected,
    required this.child,
    this.circular = false,
    this.childRadius = 0,
  });

  final bool connecting;
  final bool connected;
  final Widget child;
  final bool circular;

  /// Corner radius of the child's own rounded rectangle. The ring adds its own
  /// width on top so the outline stays parallel to the child it marks. Unused
  /// by [circular] callers.
  final double childRadius;

  @override
  State<_CallActivityFrame> createState() => _CallActivityFrameState();
}

class _CallActivityFrameState extends State<_CallActivityFrame>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant _CallActivityFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncAnimation();
  }

  void _syncAnimation() {
    final animate =
        widget.connecting && !MediaQuery.disableAnimationsOf(context);
    if (animate && !_spin.isAnimating) {
      _spin.repeat();
    } else if (!animate && _spin.isAnimating) {
      _spin.stop();
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      // The fill tween carries connecting -> connected -> gone; the spin is
      // applied directly to a plain DecoratedBox each tick. It must NOT go
      // through an implicit AnimatedContainer: retargeting one every frame
      // re-lerps the decoration with t << 0.5, where Gradient.lerp keeps the
      // OLD transform — on a real 60 fps device the segment froze solid
      // (test pumps use big steps, so tests never saw it).
      TweenAnimationBuilder<double>(
        tween: Tween(end: widget.connected ? 1.0 : 0.0),
        duration: SyblMotion.duration(context),
        child: widget.child,
        builder: (context, fill, child) => AnimatedBuilder(
          animation: _spin,
          child: child,
          builder: (context, child) {
            final online = context.syblColors.online;
            final active = widget.connecting || widget.connected || fill > 0;
            // The rest of the ring lights up as fill rises; on hangup the
            // whole ring (segment included) fades back out together.
            final edge = Color.lerp(Colors.transparent, online, fill)!;
            final segment = widget.connecting || widget.connected
                ? online
                : edge;
            return DecoratedBox(
              decoration: BoxDecoration(
                gradient: active
                    ? SweepGradient(
                        colors: [edge, edge, segment, edge],
                        stops: const [0, .72, .84, .9],
                        transform: GradientRotation(
                          _spin.value * 6.283185307179586,
                        ),
                      )
                    : null,
                shape: widget.circular ? BoxShape.circle : BoxShape.rectangle,
                borderRadius: widget.circular
                    ? null
                    : BorderRadius.circular(
                        widget.childRadius + _callRingWidth,
                      ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(_callRingWidth),
                child: child,
              ),
            );
          },
        ),
      );
}

class _LiveMicrophone extends StatelessWidget {
  const _LiveMicrophone({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final call = state.call;
    final muted = call?.micMuted != false;
    final enabled = call?.connected == true;
    final indicator = muted
        ? Icon(
            Icons.mic_off_rounded,
            size: 21,
            color: context.syblColors.danger,
          )
        : ValueListenableBuilder<double>(
            valueListenable: state.voiceMeter,
            builder: (context, level, _) => Semantics(
              label: 'Microphone level ${(level * 100).round()} percent',
              child: SizedBox.square(
                dimension: 23,
                child: Stack(
                  alignment: Alignment.bottomCenter,
                  children: [
                    Icon(
                      Icons.mic_none_rounded,
                      size: 22,
                      color: context.syblColors.faint,
                    ),
                    ClipRect(
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        heightFactor: level.clamp(0.04, 1.0),
                        child: Icon(
                          Icons.mic_rounded,
                          size: 22,
                          color: context.syblColors.online,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
    final label = muted ? 'Unmute microphone' : 'Mute microphone';
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: Tooltip(
        message: label,
        child: InkResponse(
          key: const ValueKey('account-microphone-control'),
          onTap: enabled ? state.toggleMute : null,
          radius: 18,
          child: SizedBox.square(
            dimension: 32,
            child: Center(child: indicator),
          ),
        ),
      ),
    );
  }
}

/// Collapsed list of read-only chats kept after a friend removed you.
class ArchivedChatsSection extends StatefulWidget {
  const ArchivedChatsSection({super.key, required this.state});

  final AppState state;

  @override
  State<ArchivedChatsSection> createState() => _ArchivedChatsSectionState();
}

class _ArchivedChatsSectionState extends State<ArchivedChatsSection> {
  bool _expanded = false;

  Future<void> _delete(ArchivedChatEntry entry) async {
    final label = entry.chat?.peerLabel ?? 'this archive';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Gravity(
          child: Text(
            'Delete $label?',
            style: context.syblColors.display.copyWith(fontSize: 19),
          ),
        ),
        content: Gravity(
          child: Text(
            'The archived chat is removed from this device for good.',
            style: TextStyle(color: context.syblColors.muted, fontSize: 13),
          ),
        ),
        actions: [
          Gravity(
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
          ),
          Gravity(
            child: FilledButton(
              key: const ValueKey('archived-chat-delete-confirm'),
              style: FilledButton.styleFrom(
                backgroundColor: context.syblColors.dangerFill,
                foregroundColor: context.syblColors.foregroundFor(
                  context.syblColors.dangerFill,
                ),
              ),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete'),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (!await widget.state.deleteArchivedChat(entry.id)) {
      showNotice('The archived chat could not be deleted.');
    }
  }

  Future<void> _open(ArchivedChat chat) => showDialog<void>(
    context: context,
    builder: (context) => CaptureSensitiveScope(
      protection: widget.state.surfaceProtection,
      child: AlertDialog(
        title: Gravity(
          child: Text(
            chat.peerLabel,
            style: context.syblColors.display.copyWith(fontSize: 19),
          ),
        ),
        content: SizedBox(
          width: 420,
          height: 420,
          child: chat.items.isEmpty
              ? const Center(child: Text('No messages were kept.'))
              : ListView.builder(
                  key: const ValueKey('archived-chat-items'),
                  itemCount: chat.items.length,
                  itemBuilder: (context, index) {
                    final item = chat.items[index];
                    final topic = item.topic == 'main'
                        ? null
                        : chat.topics[item.topic];
                    final body =
                        item.text ??
                        (item.stickerId != null
                            ? 'Sticker'
                            : 'File: ${item.fileName}'
                                  '${item.fileDownloaded ? '' : ' (not downloaded)'}');
                    return Align(
                      alignment: item.mine
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Text(
                          topic == null ? body : '#$topic  $body',
                          style: TextStyle(
                            color: item.mine
                                ? context.syblColors.ink
                                : context.syblColors.muted,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final entries = widget.state.archivedChats;
    return Column(
      key: const ValueKey('archived-chats-section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Gravity(
          child: TextButton.icon(
            key: const ValueKey('archived-chats-toggle'),
            style: TextButton.styleFrom(alignment: Alignment.centerLeft),
            onPressed: () => setState(() => _expanded = !_expanded),
            icon: Icon(
              _expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
              size: 18,
            ),
            label: Text('Archived (${entries.length})'),
          ),
        ),
        if (_expanded)
          for (final entry in entries)
            ListTile(
              key: ValueKey('archived-chat-${entry.id}'),
              dense: true,
              title: Text(
                entry.chat?.peerLabel ?? 'Archive unreadable',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: entry.chat == null ? null : () => _open(entry.chat!),
              trailing: IconButton(
                key: ValueKey('archived-chat-delete-${entry.id}'),
                tooltip: 'Delete',
                iconSize: 18,
                onPressed: () => _delete(entry),
                icon: const Icon(Icons.delete_outline_rounded),
              ),
            ),
      ],
    );
  }
}
