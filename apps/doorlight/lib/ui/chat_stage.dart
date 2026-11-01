import '../core/media_retirement.dart';
import 'hologram_anchor.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart';

import '../core/jami.dart';
import '../core/jami_identity.dart';
import '../state/app_state.dart';
import '../state/call_launch_policy.dart';
import '../state/composer_commands.dart';
import '../state/composer_draft.dart';
import '../state/composer_emoji.dart';
import '../state/composer_media.dart';
import '../state/conversation_timeline.dart';
import '../state/dm_topics.dart';
import '../state/group_topics.dart';
import '../state/file_transfer.dart' show transferKey;
import '../state/send_journal.dart';
import '../state/sticker_manifest.dart';
import '../state/starter_gifs.dart';
import '../state/gif_library_store.dart';
import '../state/voice_recorder.dart';
import '../state/voice_gesture.dart';
import '../state/rich_content.dart';
import '../state/message_reactions.dart';
import 'voice_review_player.dart';
import '../theme.dart';
import 'onboarding_surface.dart';
import 'friend_rail.dart';
import 'bounded_gif.dart';
import 'bounded_attachment_preview.dart';
import 'screen_share_action.dart';
import 'sticker_image.dart';
import 'composer_stickers.dart';
import 'gravity.dart';
import 'notice.dart';
import 'sybl_ui.dart';
import 'topic_strip_surface.dart';
import 'window_presentation.dart';
import 'pane_activity.dart';
import 'friend_options.dart';

const _dmTopicRowHeight = 44.0;
const _dmTopicPillHeight = 31.0;
const _dmTopicPillBottom = (_dmTopicRowHeight + _dmTopicPillHeight) / 2;

class ChatStage extends StatelessWidget {
  final AppState state;
  final FriendState friend;
  final VoidCallback? onBack;
  final VoidCallback? onOpenCall;
  final LayerLink? headerLayerLink;

  const ChatStage({
    super.key,
    required this.state,
    required this.friend,
    this.onBack,
    this.onOpenCall,
    this.headerLayerLink,
  });

  @override
  Widget build(BuildContext context) {
    final conversationId = friend.conversationId;
    final owner = state.conversationActionOwner;
    final topicScope = state.selectedConversationScope;
    final topicHistoryStatus = state.selectedDmTopicHistoryStatus;
    final topicState = state.selectedDmTopicState;
    final selectedTopicId = state.selectedDmTopicId;
    bool inSelectedTopic(String topicId) =>
        topicId == selectedTopicId &&
        (topicId == DmTopicWire.mainId || topicState?.topic(topicId) != null);
    final live = state.transfers.values
        .where(
          (transfer) =>
              transfer.peerId == friend.peerId &&
              transfer.conversationId == conversationId &&
              inSelectedTopic(transfer.topicId),
        )
        .toList(growable: false);
    final timeline = state.selectedDmTopicItems;
    final liveKeys = live
        .map(
          (transfer) => (
            ownerId: transfer.authorId.isNotEmpty
                ? transfer.authorId
                : transfer.outgoing
                ? state.jamiId
                : transfer.peerId,
            fileId: transfer.fileId,
          ),
        )
        .toSet();
    final legacyFiles =
        state.folder.values
            .where(
              (file) =>
                  file.peerId == friend.peerId &&
                  file.conversationId == conversationId &&
                  inSelectedTopic(file.topicId) &&
                  !liveKeys.contains((
                    ownerId: file.authorId.isNotEmpty
                        ? file.authorId
                        : file.outgoing
                        ? state.jamiId
                        : file.peerId,
                    fileId: file.fileId,
                  )),
            )
            .toList()
          ..sort((left, right) => left.timestamp.compareTo(right.timestamp));
    final hasConversationContent =
        timeline.isNotEmpty || live.isNotEmpty || legacyFiles.isNotEmpty;
    final selectedTopic = topicState?.topic(selectedTopicId);
    final peerArchivedSelectedTopic =
        selectedTopic != null &&
        selectedTopic.id != DmTopicWire.mainId &&
        !selectedTopic.archivedBy.contains(state.jamiId) &&
        selectedTopic.archivedBy.any((memberId) => memberId != state.jamiId);

    final header = _StageHeader(
      state: state,
      friend: friend,
      onBack: onBack,
      onOpenCall: onOpenCall,
    );
    return OnboardingSurface(
      active: false,
      child: Stack(
        children: [
          Positioned.fill(
            child: Column(
              children: [
                headerLayerLink == null
                    ? header
                    : CompositedTransformTarget(
                        link: headerLayerLink!,
                        child: header,
                      ),
                Expanded(
                  child: conversationId.isEmpty
                      ? const SyblStatusPanel(
                          kind: SyblStatusKind.loading,
                          title: 'Preparing your shared space',
                          message:
                              'Doorlight is waiting for the private conversation to be ready.',
                        )
                      : Stack(
                          fit: StackFit.expand,
                          children: [
                            ConversationTimelineView(
                              key: ValueKey((
                                accountId: state.accountId ?? '',
                                conversationId: conversationId,
                              )),
                              state: state,
                              live: live,
                              timeline: timeline,
                              legacyFiles: legacyFiles,
                            ),
                            // The splash fades in and out instead of
                            // popping when the first message lands.
                            AnimatedSwitcher(
                              duration: SyblMotion.duration(
                                context,
                                const Duration(milliseconds: 360),
                              ),
                              layoutBuilder: (current, previous) => Stack(
                                fit: StackFit.expand,
                                children: [...previous, ?current],
                              ),
                              child: hasConversationContent
                                  ? const SizedBox.shrink()
                                  : KeyedSubtree(
                                      key: ValueKey((
                                        state.chatLoading,
                                        state.chatPreparing,
                                        state.chatLoadError != null,
                                        friend.confirmed,
                                      )),
                                      child:
                                          state.chatLoading ||
                                              state.chatPreparing
                                          ? state.chatPreparing
                                                ? const SyblStatusPanel(
                                                    kind:
                                                        SyblStatusKind.loading,
                                                    title:
                                                        'Getting your conversation ready',
                                                    message:
                                                        'This takes a moment the first time you and a friend connect.',
                                                  )
                                                : const SyblStatusPanel(
                                                    kind:
                                                        SyblStatusKind.loading,
                                                    title:
                                                        'Loading your conversation',
                                                    message:
                                                        'Your messages and shared files appear here.',
                                                  )
                                          : state.chatLoadError != null
                                          ? SyblStatusPanel(
                                              kind: SyblStatusKind.error,
                                              title:
                                                  'Could not load this conversation',
                                              message:
                                                  'Your Jami history is still safe. Try again.',
                                              action: Gravity(
                                                child: OutlinedButton.icon(
                                                  onPressed: state.refreshChat,
                                                  icon: const Icon(
                                                    Icons.refresh_rounded,
                                                    size: 18,
                                                  ),
                                                  label: const Text(
                                                    'Try again',
                                                  ),
                                                ),
                                              ),
                                            )
                                          : !friend.confirmed
                                          ? SyblStatusPanel(
                                              kind: SyblStatusKind.empty,
                                              title:
                                                  'Waiting for ${friendLabel(friend)} to accept',
                                            )
                                          : const SyblStatusPanel(
                                              kind: SyblStatusKind.empty,
                                              title:
                                                  'Your conversation starts here',
                                            ),
                                    ),
                            ),
                            if (state.dmTopicRowVisible)
                              Positioned(
                                top: 0,
                                left: 0,
                                right: 0,
                                height: topicStripSurfaceHeight(
                                  state.topicStripSurfaceSettings,
                                  pillBottom: _dmTopicPillBottom,
                                ),
                                child: DmTopicStrip(state: state),
                              ),
                          ],
                        ),
                ),
                if (topicScope != null &&
                    (topicHistoryStatus == DmTopicHistoryStatus.failed ||
                        topicHistoryStatus == DmTopicHistoryStatus.tooLarge))
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 4, 14, 7),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            topicHistoryStatus == DmTopicHistoryStatus.tooLarge
                                ? 'Topic history is too large to load safely. Your messages have not been deleted.'
                                : 'Topic history could not load. Your messages have not been deleted.',
                          ),
                        ),
                        TextButton(
                          key: const ValueKey('retry-dm-topic-history'),
                          onPressed: state.canRetryDmTopicHistory
                              ? () => state.retryDmTopicHistory(
                                  scope: topicScope,
                                  owner: owner,
                                )
                              : null,
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                if (peerArchivedSelectedTopic)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 4, 14, 7),
                      child: Gravity(
                        child: OutlinedButton.icon(
                          key: const ValueKey('dm-topic-archive-for-me-too'),
                          onPressed: () {
                            if (state.conversationActionOwner == owner) {
                              unawaited(
                                state.setDmTopicArchived(selectedTopicId, true),
                              );
                            }
                          },
                          icon: const Icon(Icons.archive_outlined, size: 16),
                          label: const Text('Archive for me too'),
                        ),
                      ),
                    ),
                  ),
                // Jami names the conversation at request time; it opens on acceptance.
                if (state.peerLeft(friend.peerId))
                  _PeerLeftActions(state: state, friend: friend)
                else if (friend.confirmed && conversationId.isNotEmpty)
                  ConversationComposer(
                    key: ValueKey((
                      accountId: state.accountId ?? '',
                      peerId: friend.peerId,
                      conversationId: conversationId,
                    )),
                    state: state,
                    hintText: 'Message ${friendLabel(friend)}',
                    fileLabel: 'Share a file with ${friendLabel(friend)}',
                    onSend: state.sendText,
                    onSendOwned: (body, operation) => state.sendOwnedContent(
                      body,
                      operationId: operation.id,
                      replyTo: operation.replyTo,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class DmTopicStrip extends StatefulWidget {
  const DmTopicStrip({super.key, required this.state});

  final AppState state;

  @override
  State<DmTopicStrip> createState() => _DmTopicStripState();
}

class _DmTopicStripState extends State<DmTopicStrip> {
  final ScrollController _scroll = ScrollController();
  final Map<String, GlobalKey> _topicKeys = {};
  final GlobalKey _addKey = GlobalKey();
  bool _leftUnread = false;
  bool _rightUnread = false;
  double? _surfaceEnd;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_scheduleUnreadEdges);
  }

  @override
  void didUpdateWidget(covariant DmTopicStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scheduleUnreadEdges();
  }

  void _scheduleUnreadEdges() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureUnreadEdges());
  }

  void _measureUnreadEdges() {
    if (!mounted) return;
    final row = context.findRenderObject();
    if (row is! RenderBox || !row.hasSize) return;
    final rowTopLeft = row.localToGlobal(Offset.zero);
    final add = _addKey.currentContext?.findRenderObject();
    final surfaceEnd = add is RenderBox && add.hasSize
        ? (add.localToGlobal(Offset(add.size.width, 0)).dx - rowTopLeft.dx)
              .clamp(0.0, row.size.width)
              .toDouble()
        : row.size.width;
    final topics = widget.state.selectedDmTopicState?.visibleTopics(
      localMemberId: widget.state.jamiId,
      retainedTopicId: widget.state.selectedDmTopicId,
    );
    if (topics == null || topics.isEmpty) {
      if (_surfaceEnd != surfaceEnd) setState(() => _surfaceEnd = surfaceEnd);
      return;
    }
    final unread = widget.state.selectedDmTopicUnreadByTopic;
    final rowRect = rowTopLeft & Size(row.size.width, _dmTopicRowHeight);
    final visible = <int>[];
    final rects = <int, Rect>{};
    for (var index = 0; index < topics.length; index++) {
      final target = _topicKeys[topics[index].id]?.currentContext
          ?.findRenderObject();
      if (target is! RenderBox || !target.hasSize) continue;
      final rect = target.localToGlobal(Offset.zero) & target.size;
      rects[index] = rect;
      if (rect.overlaps(rowRect)) visible.add(index);
    }
    if (visible.isEmpty) {
      if (_surfaceEnd != surfaceEnd) setState(() => _surfaceEnd = surfaceEnd);
      return;
    }
    final first = visible.reduce((left, right) => left < right ? left : right);
    final last = visible.reduce((left, right) => left > right ? left : right);
    var leftUnread = false;
    var rightUnread = false;
    for (var index = 0; index < topics.length; index++) {
      if ((unread[topics[index].id] ?? 0) <= 0) continue;
      final rect = rects[index];
      if (rect != null && rect.right <= rowRect.left + 1 || index < first) {
        leftUnread = true;
      } else if (rect != null && rect.left >= rowRect.right - 1 ||
          index > last) {
        rightUnread = true;
      }
    }
    if (_surfaceEnd != surfaceEnd ||
        _leftUnread != leftUnread ||
        _rightUnread != rightUnread) {
      setState(() {
        _surfaceEnd = surfaceEnd;
        _leftUnread = leftUnread;
        _rightUnread = rightUnread;
      });
    }
  }

  @override
  void dispose() {
    _scroll
      ..removeListener(_scheduleUnreadEdges)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final owner = state.conversationActionOwner;
    final topicState = state.selectedDmTopicState;
    if (topicState == null || topicState.customTopics.isEmpty) {
      return const SizedBox.shrink();
    }
    final topics = topicState.visibleTopics(
      localMemberId: state.jamiId,
      retainedTopicId: state.selectedDmTopicId,
    );
    final unread = state.selectedDmTopicUnreadByTopic;
    _scheduleUnreadEdges();
    return LayoutBuilder(
      builder: (context, constraints) {
        final surfaceEnd = (_surfaceEnd ?? constraints.maxWidth).clamp(
          0.0,
          constraints.maxWidth,
        );
        final surfaceHeight = topicStripSurfaceHeight(
          state.topicStripSurfaceSettings,
          pillBottom: _dmTopicPillBottom,
        );
        return SizedBox(
          key: const ValueKey('dm-topic-strip'),
          height: surfaceHeight,
          child: Stack(
            children: [
              Positioned.fill(
                child: TopicStripSurface(
                  settings: state.topicStripSurfaceSettings,
                  endpoint: surfaceEnd,
                  pillBottom: _dmTopicPillBottom,
                  surfaceKey: const ValueKey('dm-topic-surface'),
                  mainKey: const ValueKey('dm-topic-surface-main-color'),
                  rightFadeKey: const ValueKey('dm-topic-surface-right-fade'),
                ),
              ),
              SizedBox(
                height: _dmTopicRowHeight,
                child: Stack(
                  children: [
                    ListView.separated(
                      key: const ValueKey('dm-topic-scroll'),
                      controller: _scroll,
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      itemCount: topics.length + 1,
                      separatorBuilder: (_, _) => const SizedBox(width: 7),
                      itemBuilder: (context, index) {
                        if (index == topics.length) {
                          final archived = topicState.customTopics
                              .where(
                                (topic) =>
                                    topic.archivedBy.contains(state.jamiId),
                              )
                              .toList(growable: false);
                          return KeyedSubtree(
                            key: _addKey,
                            child: _DmTopicPill(
                              key: const ValueKey('dm-topic-add'),
                              label: '+',
                              semanticsLabel: 'Topic actions',
                              selected: false,
                              onTap: () {},
                              openMenuOnTap: true,
                              menuActions: [
                                _DmTopicMenuAction(
                                  label: 'New topic',
                                  icon: Icons.add_rounded,
                                  onTap: () => _showDmTopicNameDialog(
                                    context,
                                    state: state,
                                    expectedOwner: owner,
                                    title: 'New topic',
                                    actionLabel: 'Create',
                                    onSubmit: state.createDmTopic,
                                  ),
                                ),
                                if (archived.isNotEmpty)
                                  _DmTopicMenuAction(
                                    label: 'Archived topics',
                                    icon: Icons.archive_outlined,
                                    onTap: () => _showArchivedDmTopics(
                                      context,
                                      state,
                                      archived,
                                      owner,
                                    ),
                                  ),
                              ],
                            ),
                          );
                        }
                        final topic = topics[index];
                        final peerArchived = topic.archivedBy.any(
                          (memberId) => memberId != state.jamiId,
                        );
                        final unreadCount = unread[topic.id] ?? 0;
                        final peerArchiveLabel = peerArchived
                            ? ', archived by ${state.peerDisplayName(topic.archivedBy.firstWhere((memberId) => memberId != state.jamiId))}'
                            : '';
                        return KeyedSubtree(
                          key: _topicKeys.putIfAbsent(topic.id, GlobalKey.new),
                          child: Opacity(
                            key: ValueKey('dm-topic-opacity:${topic.id}'),
                            opacity: peerArchived ? .55 : 1,
                            child: _DmTopicPill(
                              key: ValueKey('dm-topic-pill:${topic.id}'),
                              label: topic.name,
                              semanticsLabel: unreadCount > 0
                                  ? '${topic.name}, $unreadCount unread$peerArchiveLabel'
                                  : '${topic.name}$peerArchiveLabel',
                              selected: topic.id == state.selectedDmTopicId,
                              unreadCount: unreadCount,
                              onTap: () {
                                if (state.conversationActionOwner == owner) {
                                  unawaited(state.selectDmTopic(topic.id));
                                }
                              },
                              menuActions: topic.id == DmTopicWire.mainId
                                  ? const []
                                  : [
                                      _DmTopicMenuAction(
                                        label: 'Rename',
                                        icon: Icons.edit_outlined,
                                        onTap: () => _showDmTopicNameDialog(
                                          context,
                                          state: state,
                                          expectedOwner: owner,
                                          title: 'Rename topic',
                                          actionLabel: 'Rename',
                                          initialValue: topic.name,
                                          onSubmit: (name, {action}) => state
                                              .renameDmTopic(topic.id, name),
                                        ),
                                      ),
                                      _DmTopicMenuAction(
                                        label:
                                            topic.archivedBy.contains(
                                              state.jamiId,
                                            )
                                            ? 'Unarchive for me'
                                            : 'Archive for me',
                                        icon:
                                            topic.archivedBy.contains(
                                              state.jamiId,
                                            )
                                            ? Icons.unarchive_outlined
                                            : Icons.archive_outlined,
                                        onTap: () {
                                          if (state.conversationActionOwner ==
                                              owner) {
                                            unawaited(
                                              state.setDmTopicArchived(
                                                topic.id,
                                                !topic.archivedBy.contains(
                                                  state.jamiId,
                                                ),
                                              ),
                                            );
                                          }
                                          return null;
                                        },
                                      ),
                                    ],
                            ),
                          ),
                        );
                      },
                    ),
                    if (_leftUnread)
                      const _DmTopicUnreadEdge(
                        key: ValueKey('dm-topic-unread-edge-left'),
                        alignment: Alignment.centerLeft,
                      ),
                    if (_rightUnread)
                      const _DmTopicUnreadEdge(
                        key: ValueKey('dm-topic-unread-edge-right'),
                        alignment: Alignment.centerRight,
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _DmTopicUnreadEdge extends StatelessWidget {
  const _DmTopicUnreadEdge({super.key, required this.alignment});

  final Alignment alignment;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Align(
      alignment: alignment,
      child: Container(
        width: 7,
        height: 7,
        margin: const EdgeInsets.symmetric(horizontal: 2),
        decoration: BoxDecoration(
          color: context.syblColors.danger,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(color: context.syblColors.surface, spreadRadius: 2),
          ],
        ),
      ),
    ),
  );
}

final class _DmTopicMenuAction {
  const _DmTopicMenuAction({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final FutureOr<Object?> Function() onTap;
}

class _DmTopicPill extends StatefulWidget {
  const _DmTopicPill({
    super.key,
    required this.label,
    required this.semanticsLabel,
    required this.selected,
    required this.onTap,
    this.unreadCount = 0,
    this.menuActions = const [],
    this.openMenuOnTap = false,
  });

  final String label;
  final String semanticsLabel;
  final bool selected;
  final int unreadCount;
  final VoidCallback onTap;
  final List<_DmTopicMenuAction> menuActions;
  final bool openMenuOnTap;

  @override
  State<_DmTopicPill> createState() => _DmTopicPillState();
}

class _DmTopicPillState extends State<_DmTopicPill> {
  final LayerLink _link = LayerLink();
  final FocusNode _focus = FocusNode();
  OverlayEntry? _menu;

  void _openMenu() {
    if (widget.menuActions.isEmpty || _menu != null) return;
    _focus.requestFocus();
    final overlay = Overlay.of(context, rootOverlay: true);
    final duration = SyblMotion.duration(context);
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (overlayContext) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _closeMenu,
              child: ClipRect(
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: 2, sigmaY: 2),
                  child: const ColoredBox(color: Colors.transparent),
                ),
              ),
            ),
          ),
          CompositedTransformFollower(
            link: _link,
            showWhenUnlinked: false,
            targetAnchor: Alignment.bottomLeft,
            followerAnchor: Alignment.topLeft,
            offset: const Offset(0, 2),
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: duration,
              curve: Curves.easeOutCubic,
              builder: (context, value, child) => Opacity(
                opacity: value,
                child: Transform.translate(
                  offset: Offset(0, -8 * (1 - value)),
                  child: child,
                ),
              ),
              child: Material(
                key: const ValueKey('dm-topic-anchored-menu'),
                color: overlayContext.syblColors.surfaceTop,
                elevation: 10,
                shadowColor: Colors.black.withValues(alpha: .25),
                borderRadius: BorderRadius.circular(14),
                clipBehavior: Clip.antiAlias,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 164),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final action in widget.menuActions)
                        InkWell(
                          onTap: () {
                            _closeMenu();
                            final result = action.onTap();
                            if (result is Future) unawaited(result);
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(action.icon, size: 17),
                                const SizedBox(width: 9),
                                Text(action.label),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
    _menu = entry;
    overlay.insert(entry);
    setState(() {});
  }

  void _closeMenu() {
    _menu?.remove();
    _menu = null;
    if (mounted) {
      _focus.requestFocus();
      setState(() {});
    }
  }

  @override
  void dispose() {
    _menu?.remove();
    _menu = null;
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Gravity(
    child: Semantics(
      button: true,
      selected: widget.selected,
      label: widget.semanticsLabel,
      child: FocusableActionDetector(
        focusNode: _focus,
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.contextMenu):
              _OpenDmTopicMenuIntent(),
          SingleActivator(LogicalKeyboardKey.f10, shift: true):
              _OpenDmTopicMenuIntent(),
        },
        actions: {
          _OpenDmTopicMenuIntent: CallbackAction<_OpenDmTopicMenuIntent>(
            onInvoke: (_) {
              _openMenu();
              return null;
            },
          ),
        },
        child: CompositedTransformTarget(
          link: _link,
          child: AnimatedScale(
            scale: _menu == null ? 1 : 1.045,
            duration: SyblMotion.duration(context),
            curve: Curves.easeOutCubic,
            child: SizedBox(
              height: _dmTopicRowHeight,
              child: Center(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onSecondaryTapDown: widget.menuActions.isEmpty
                      ? null
                      : (_) => _openMenu(),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Material(
                        color: widget.selected
                            ? context.syblColors.amber.withValues(alpha: .24)
                            : Colors.transparent,
                        shape: context.syblColors.buttonShape.copyWith(
                          side: BorderSide(
                            color: widget.selected
                                ? context.syblColors.amber
                                : context.syblColors.lineStrong,
                          ),
                        ),
                        child: InkWell(
                          customBorder: context.syblColors.buttonShape,
                          onTap: () {
                            _focus.requestFocus();
                            widget.openMenuOnTap ? _openMenu() : widget.onTap();
                          },
                          onLongPress: widget.menuActions.isEmpty
                              ? null
                              : _openMenu,
                          child: Container(
                            height: _dmTopicPillHeight,
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            alignment: Alignment.center,
                            child: Text(
                              widget.label,
                              maxLines: 1,
                              style: TextStyle(
                                color: widget.selected
                                    ? context.syblColors.ink
                                    : context.syblColors.muted,
                                fontSize: 12.5,
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (widget.unreadCount > 0)
                        Positioned(
                          top: -4,
                          right: -5,
                          child: Container(
                            constraints: const BoxConstraints(minWidth: 16),
                            height: 16,
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: context.syblColors.danger,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              widget.unreadCount > 99
                                  ? '99+'
                                  : '${widget.unreadCount}',
                              style: TextStyle(
                                color: context.syblColors.surface,
                                fontSize: 9,
                                fontWeight: FontWeight.w700,
                              ),
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
      ),
    ),
  );
}

class _OpenDmTopicMenuIntent extends Intent {
  const _OpenDmTopicMenuIntent();
}

Future<bool> _showDmTopicNameDialog(
  BuildContext context, {
  required AppState state,
  Object? expectedOwner,
  ConversationAction? action,
  required String title,
  required String actionLabel,
  required Future<bool> Function(String name, {ConversationAction? action})
  onSubmit,
  String initialValue = '',
}) async {
  if (expectedOwner != null && state.conversationActionOwner != expectedOwner) {
    return false;
  }
  action ??= state.captureConversationAction();
  final name = await showDialog<String>(
    context: context,
    builder: (_) => _DmTopicNameDialog(
      title: title,
      actionLabel: actionLabel,
      initialValue: initialValue,
    ),
  );
  return name != null &&
      state.ownsConversationAction(action) &&
      await onSubmit(name, action: action);
}

class _DmTopicNameDialog extends StatefulWidget {
  const _DmTopicNameDialog({
    required this.title,
    required this.actionLabel,
    required this.initialValue,
  });
  final String title;
  final String actionLabel;
  final String initialValue;

  @override
  State<_DmTopicNameDialog> createState() => _DmTopicNameDialogState();
}

class _DmTopicNameDialogState extends State<_DmTopicNameDialog> {
  late final _controller = TextEditingController(text: widget.initialValue);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Gravity(child: Text(widget.title)),
    content: Gravity(
      child: TextField(
        key: const ValueKey('dm-topic-name-field'),
        controller: _controller,
        autofocus: SyblLayout.autofocusTextInput(context),
        maxLength: 64,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => Navigator.of(context).pop(_controller.text),
      ),
    ),
    actions: [
      Gravity(
        child: TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ),
      Gravity(
        child: FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(widget.actionLabel),
        ),
      ),
    ],
  );
}

Future<void> _showArchivedDmTopics(
  BuildContext context,
  AppState state,
  List<DmTopic> topics,
  Object owner,
) {
  if (state.conversationActionOwner != owner) return Future.value();
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Gravity(child: Text('Archived topics')),
      content: ConstrainedBox(
        constraints: const BoxConstraints(
          minWidth: 360,
          maxWidth: 360,
          maxHeight: 420,
        ),
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: topics.length,
          itemBuilder: (context, index) {
            final topic = topics[index];
            return ListTile(
              title: Gravity(child: Text(topic.name)),
              onTap: () {
                Navigator.of(dialogContext).pop();
                if (state.conversationActionOwner == owner) {
                  unawaited(state.selectDmTopic(topic.id));
                }
              },
              trailing: Gravity(
                child: IconButton(
                  tooltip: 'Unarchive ${topic.name}',
                  onPressed: () {
                    Navigator.of(dialogContext).pop();
                    if (state.conversationActionOwner == owner) {
                      unawaited(state.setDmTopicArchived(topic.id, false));
                    }
                  },
                  icon: const Icon(Icons.unarchive_outlined),
                ),
              ),
            );
          },
        ),
      ),
    ),
  );
}

class _StageHeader extends StatelessWidget {
  final AppState state;
  final FriendState friend;
  final VoidCallback? onBack;
  final VoidCallback? onOpenCall;

  const _StageHeader({
    required this.state,
    required this.friend,
    required this.onBack,
    required this.onOpenCall,
  });

  @override
  Widget build(BuildContext context) {
    final label = friendLabel(friend);
    final presence = friendPresenceLabel(state, friend);
    final activeCall = state.call?.peerId == friend.peerId ? state.call : null;
    final canCall =
        friend.confirmed &&
        !state.peerLeft(friend.peerId) &&
        state.registered &&
        !state.appearOffline &&
        state.call == null &&
        !state.placing;
    final unreadElsewhere = state.unreadOutsideConversation(friend.peerId);
    if (WindowPresentationScope.isCompact(context)) {
      return CompactHeader(
        title: label,
        onBack: onBack,
        unreadElsewhere: unreadElsewhere,
        leading: SyblAvatar(
          label: label,
          imageBase64: friend.avatarBase64,
          size: 22,
          statusColor: friendPresenceColor(context, state, friend),
          statusIcon: friendPresenceIcon(friend),
          statusLabel: presence,
        ),
        actions: [
          CompactIconButton(
            label: activeCall != null ? 'Return to call' : 'Call',
            icon: Icons.call_outlined,
            active: activeCall != null,
            onPressed: activeCall != null
                ? onOpenCall
                : canCall
                ? () => _launchCall(context)
                : null,
          ),
          Gravity(
            child: PopupMenuButton<String>(
              tooltip: 'More',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(maxWidth: 280),
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'video',
                  enabled: canCall,
                  child: const Text('Video call'),
                ),
                const PopupMenuItem(
                  value: 'options',
                  child: Text('Friend options'),
                ),
                const PopupMenuItem(
                  value: 'expand',
                  child: Text('Open full conversation'),
                ),
              ],
              onSelected: (value) {
                if (value == 'video') _launchCall(context, withVideo: true);
                if (value == 'options') {
                  showFriendOptions(context, state, friend.peerId);
                }
                if (value == 'expand') {
                  WindowPresentationScope.maybeOf(context)?.setCompact(false);
                }
              },
              child: const SizedBox(
                width: 24,
                height: 28,
                child: Icon(Icons.more_horiz, size: 16),
              ),
            ),
          ),
        ],
      );
    }
    // The divider is its own piece so it can fall with everything else.
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          key: const ValueKey('conversation-header'),
          constraints: const BoxConstraints(minHeight: 58),
          padding: EdgeInsets.fromLTRB(onBack == null ? 16 : 4, 5, 10, 5),
          child: Row(
            children: [
              if (onBack != null)
                Gravity(
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      HologramAnchor(
                        state: state,
                        child: IconButton(
                          key: const ValueKey('conversation-back-button'),
                          tooltip: unreadElsewhere == 0
                              ? 'Back to your friends'
                              : '$unreadElsewhere unread elsewhere',
                          onPressed: onBack,
                          constraints: BoxConstraints.tight(
                            const Size.square(32),
                          ),
                          padding: EdgeInsets.zero,
                          color: context.syblColors.amber,
                          icon: const Icon(Icons.arrow_back_rounded, size: 22),
                        ),
                      ),
                      if (unreadElsewhere > 0)
                        Positioned(
                          right: -3,
                          top: -3,
                          child: _HeaderUnreadBadge(count: unreadElsewhere),
                        ),
                    ],
                  ),
                ),
              SyblAvatar(
                label: label,
                imageBase64: friend.avatarBase64,
                size: onBack == null ? 32 : 40,
                statusColor: friendPresenceColor(context, state, friend),
                statusIcon: friendPresenceIcon(friend),
                statusLabel: presence,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Gravity(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.syblColors.display.copyWith(
                          fontSize: 16,
                        ),
                      ),
                    ),
                    Gravity(
                      child: Text(
                        activeCall == null
                            ? presence
                            : activeCall.connected
                            ? 'connected'
                            : activeCall.dir == CallDir.outgoing
                            ? 'Calling…'
                            : 'connecting…',
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
              AnimatedSwitcher(
                duration: SyblMotion.duration(context),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                child: activeCall == null
                    ? Row(
                        key: const ValueKey('start-call-actions'),
                        children: [
                          SyblPillIconButton(
                            key: const ValueKey('voice-call-button'),
                            label: state.placing
                                ? 'Connecting'
                                : 'Start voice call',
                            icon: state.placing
                                ? Icons.hourglass_top_rounded
                                : Icons.call_outlined,
                            onPressed: canCall
                                ? () => _launchCall(context)
                                : null,
                            emphasized: true,
                          ),
                          const SizedBox(width: 7),
                          SyblPillIconButton(
                            key: const ValueKey('video-call-button'),
                            label: 'Start video call',
                            icon: Icons.videocam_outlined,
                            onPressed: canCall
                                ? () => _launchCall(context, withVideo: true)
                                : null,
                          ),
                        ],
                      )
                    : onBack == null
                    ? _ActiveAudioCallStrip(state: state, call: activeCall)
                    : _MobileCallEntry(label: label, onPressed: onOpenCall),
              ),
            ],
          ),
        ),
        Gravity(
          child: ColoredBox(
            key: const ValueKey('conversation-header-divider'),
            color: context.syblColors.line,
            child: const SizedBox(height: 1),
          ),
        ),
      ],
    );
  }

  Future<void> _launchCall(
    BuildContext context, {
    bool withVideo = false,
  }) async {
    if (CallLaunchPolicy.forPresence(friend.presence) ==
        CallLaunchAction.ring) {
      await state.startCallTo(friend.peerId, withVideo: withVideo);
      if (context.mounted && WindowPresentationScope.isCompact(context)) {
        onOpenCall?.call();
      }
      return;
    }
    final choice = await showDialog<_ReachableCallChoice>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Gravity(child: Text('Call ${friendLabel(friend)}?')),
        content: const Gravity(
          child: Text('They may not have Doorlight open right now.'),
        ),
        actions: [
          Gravity(
            child: TextButton(
              key: const ValueKey('reachable-call-notify'),
              onPressed: () =>
                  Navigator.pop(dialogContext, _ReachableCallChoice.notify),
              child: const Text('Notify'),
            ),
          ),
          Gravity(
            child: FilledButton(
              key: const ValueKey('reachable-call-ring'),
              onPressed: () =>
                  Navigator.pop(dialogContext, _ReachableCallChoice.ring),
              child: const Text('Ring'),
            ),
          ),
        ],
      ),
    );
    if (!context.mounted) return;
    if (choice == _ReachableCallChoice.ring) {
      await state.startCallTo(friend.peerId, withVideo: withVideo);
    } else if (choice == _ReachableCallChoice.notify &&
        !await state.notifyCallRequest(friend.peerId) &&
        context.mounted) {
      showNotice('The notification could not be sent.');
    }
  }
}

enum _ReachableCallChoice { notify, ring }

class _MobileCallEntry extends StatelessWidget {
  const _MobileCallEntry({required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Gravity(
    child: Semantics(
      button: true,
      label: 'Open call with $label',
      child: Tooltip(
        message: 'Open call with $label',
        child: Material(
          key: const ValueKey('open-active-call-button'),
          color: context.syblColors.surfaceHi,
          shape: context.syblColors.buttonShape.copyWith(
            side: BorderSide(color: context.syblColors.online, width: 1.5),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            customBorder: context.syblColors.buttonShape,
            child: SizedBox(
              height: 44,
              width: 74,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.arrow_forward_rounded,
                    size: 18,
                    color: context.syblColors.online,
                  ),
                  const SizedBox(width: 5),
                  Icon(
                    Icons.phone_in_talk_rounded,
                    size: 21,
                    color: context.syblColors.online,
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

class _HeaderUnreadBadge extends StatelessWidget {
  const _HeaderUnreadBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        constraints: const BoxConstraints(minWidth: 17, minHeight: 17),
        padding: const EdgeInsets.symmetric(horizontal: 4),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: context.syblColors.dangerFill,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: context.syblColors.surface, width: 2),
        ),
        child: Text(
          count > 99 ? '99+' : '$count',
          style: TextStyle(
            color: context.syblColors.foregroundFor(
              context.syblColors.dangerFill,
            ),
            fontSize: 8.5,
            height: 1,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

class _ActiveAudioCallStrip extends StatelessWidget {
  const _ActiveAudioCallStrip({required this.state, required this.call});

  final AppState state;
  final CallSession call;

  @override
  Widget build(BuildContext context) {
    final pushToTalk = call.micMode == MicrophoneMode.pushToTalk;
    final micActive = pushToTalk ? call.pushToTalkPressed : !call.micMuted;
    final micLabel = pushToTalk
        ? (call.pushToTalkPressed ? 'Talking; release to stop' : 'Hold to talk')
        : call.micMuted
        ? 'Unmute'
        : 'Mute';

    return Row(
      key: const ValueKey('audio-call-strip'),
      mainAxisSize: MainAxisSize.min,
      children: [
        _CallStripAction(
          key: const ValueKey('audio-call-mic'),
          label: micLabel,
          icon: call.micMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
          active: micActive,
          enabled: call.connected,
          onPressed: pushToTalk ? null : state.toggleMute,
          onPressStart: pushToTalk ? () => state.pttHold(true) : null,
          onPressEnd: pushToTalk ? () => state.pttHold(false) : null,
        ),
        const SizedBox(width: 6),
        _CallStripAction(
          key: const ValueKey('audio-call-video'),
          label: call.cameraChanging ? 'Wait' : 'Video',
          icon: Icons.videocam_outlined,
          enabled: call.connected && !call.cameraChanging,
          onPressed: state.toggleCamera,
        ),
        const SizedBox(width: 6),
        _CallStripAction(
          key: const ValueKey('audio-call-share'),
          label: call.sourceChanging ? 'Wait' : 'Share',
          icon: Icons.screen_share_outlined,
          enabled: call.connected && !call.sourceChanging,
          onPressed: () => toggleScreenShareWithPicker(context, state, call),
        ),
        const SizedBox(width: 6),
        _CallStripAction(
          key: const ValueKey('audio-call-leave'),
          label: 'Leave',
          icon: Icons.call_end_rounded,
          danger: true,
          onPressed: state.hangUp,
        ),
      ],
    );
  }
}

class _CallStripAction extends StatelessWidget {
  const _CallStripAction({
    super.key,
    required this.label,
    required this.icon,
    this.active = false,
    this.danger = false,
    this.enabled = true,
    this.onPressed,
    this.onPressStart,
    this.onPressEnd,
  }) : assert(onPressed == null || onPressStart == null);

  final String label;
  final IconData icon;
  final bool active;
  final bool danger;
  final bool enabled;
  final VoidCallback? onPressed;
  final VoidCallback? onPressStart;
  final VoidCallback? onPressEnd;

  @override
  Widget build(BuildContext context) {
    final interactive = enabled && (onPressed != null || onPressStart != null);
    // Idle-but-clickable actions read as ink, not muted — muted looked
    // disabled next to the active/danger ones.
    final colors = context.syblColors;
    final themed = colors.neutralButtonFill != null;
    final background = danger
        ? (themed ? colors.dangerFill : colors.danger.withValues(alpha: .12))
        : active && themed
        ? colors.onlineFill
        : (colors.neutralButtonFill ?? colors.surfaceHi);
    final foreground = !interactive
        ? context.syblColors.faint
        : danger
        ? (themed ? colors.foregroundFor(background) : colors.danger)
        : active
        ? (themed ? colors.foregroundFor(background) : colors.online)
        : (colors.neutralButtonForeground ?? colors.ink);
    final border = danger
        ? context.syblColors.danger.withValues(alpha: .48)
        : active
        ? context.syblColors.online.withValues(alpha: .62)
        : context.syblColors.lineStrong;
    final action = Opacity(
      opacity: interactive ? 1 : .55,
      child: Material(
        color: background,
        shape: colors.buttonShape.copyWith(
          side: BorderSide(
            color: themed
                ? (colors.neutralButtonBorder ?? colors.lineStrong)
                : border,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: interactive ? onPressed : null,
          onTapDown: interactive && onPressStart != null
              ? (_) => onPressStart!()
              : null,
          onTapUp: interactive && onPressEnd != null
              ? (_) => onPressEnd!()
              : null,
          onTapCancel: interactive ? onPressEnd : null,
          customBorder: colors.buttonShape,
          hoverColor: !active && !danger ? colors.neutralButtonHover : null,
          highlightColor: !active && !danger
              ? colors.neutralButtonPressed
              : null,
          child: SizedBox.square(
            dimension: 48,
            child: Icon(icon, size: 18, color: foreground),
          ),
        ),
      ),
    );
    return Gravity(
      child: Semantics(
        button: true,
        enabled: interactive,
        label: label,
        child: onPressStart != null
            ? action
            : Tooltip(message: label, child: action),
      ),
    );
  }
}

class ConversationTimelineView extends StatefulWidget {
  final AppState state;
  final List<FileXfer> live;
  final List<ConversationTimelineItem> timeline;
  final List<FolderFile> legacyFiles;
  final GroupState? group;
  final String Function(TimelineTextItem)? textFor;

  const ConversationTimelineView({
    super.key,
    required this.state,
    required this.live,
    required this.timeline,
    required this.legacyFiles,
    this.group,
    this.textFor,
  });

  @override
  State<ConversationTimelineView> createState() =>
      _ConversationTimelineViewState();
}

class _ConversationTimelineViewState extends State<ConversationTimelineView>
    with TickerProviderStateMixin {
  final Set<String> _seenItemIds = {};
  // Messages new in this session that are still entering; each controller
  // outlives the rebuilds and regroupings that happen while it runs.
  final Map<String, _MessageEntry> _entering = {};
  Object? _scope;
  String? _tailItemId;
  bool _seeded = false;
  Timer? _receiptPauseTimer;
  String? _receiptPauseKey;
  String? _releasedReceiptKey;

  bool _receiptReady(Object item, AppState state) {
    if (state.messageReceiptVisibility != MessageReceiptVisibility.afterPause ||
        item is! ConversationTimelineItem ||
        item.direction != TimelineDirection.outgoing) {
      _receiptPauseTimer?.cancel();
      _receiptPauseTimer = null;
      _receiptPauseKey = null;
      _releasedReceiptKey = null;
      return true;
    }
    final key = _timelineItemId(item, state);
    if (_releasedReceiptKey == key) return true;
    final remaining = item.createdAt
        .add(_messageGroupWindow)
        .difference(DateTime.now());
    if (remaining <= Duration.zero) {
      _receiptPauseTimer?.cancel();
      _receiptPauseTimer = null;
      _receiptPauseKey = null;
      return true;
    }
    if (_receiptPauseKey != key || !(_receiptPauseTimer?.isActive ?? false)) {
      _receiptPauseTimer?.cancel();
      _receiptPauseKey = key;
      _receiptPauseTimer = Timer(remaining, () {
        if (!mounted || _receiptPauseKey != key) return;
        setState(() => _releasedReceiptKey = key);
      });
    }
    return false;
  }

  @override
  void dispose() {
    _receiptPauseTimer?.cancel();
    for (final entry in _entering.values) {
      entry.dispose();
    }
    super.dispose();
  }

  void _dropEntry(String id) {
    final entry = _entering.remove(id);
    if (entry == null) return;
    entry.motion.stop();
    // Widgets built this frame may still listen to it.
    WidgetsBinding.instance.addPostFrameCallback((_) => entry.dispose());
  }

  void _enter(String id, Object item, AppState state) {
    final text = item is TimelineTextItem
        ? (widget.group == null ? null : widget.textFor?.call(item)) ??
              item.text
        : null;
    // Incoming text streams in once it lands; own text just appears.
    final streamMs =
        text == null ||
            (item is TimelineTextItem &&
                item.direction == TimelineDirection.outgoing)
        ? 0
        : (text.characters.length * 24).clamp(180, 1600);
    final motion = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: _arriveMs + streamMs),
    );
    motion.addStatusListener((status) {
      if (status != AnimationStatus.completed ||
          !identical(_entering[id]?.motion, motion)) {
        return;
      }
      setState(() => _dropEntry(id));
    });
    _entering[id] = _MessageEntry(
      motion,
      settle: _arriveMs / (_arriveMs + streamMs),
    );
    motion.forward();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final live = widget.live;
    final timeline = widget.timeline;
    final legacyFiles = widget.legacyFiles;
    final group = widget.group;
    final textFor = widget.textFor;
    final scope = (
      accountId: state.accountId ?? '',
      conversationId:
          group?.conversationId ??
          state.selectedFriend?.conversationId ??
          'standalone',
    );
    if (_scope != scope) {
      _scope = scope;
      _seenItemIds.clear();
      _tailItemId = null;
      _seeded = false;
      _entering.keys.toList().forEach(_dropEntry);
      _receiptPauseTimer?.cancel();
      _receiptPauseTimer = null;
      _receiptPauseKey = null;
      _releasedReceiptKey = null;
    }
    final liveFileKeys = live
        .map(
          (transfer) => (
            ownerId: transfer.authorId.isNotEmpty
                ? transfer.authorId
                : transfer.outgoing
                ? state.jamiId
                : transfer.peerId,
            fileId: transfer.fileId,
          ),
        )
        .toSet();
    final timelineFileKeys = timeline
        .whereType<TimelineFileItem>()
        .map((item) => (ownerId: item.authorId, fileId: item.fileId))
        .toSet();
    final folderByOwnerFile = <({String ownerId, String fileId}), FolderFile>{
      for (final file in legacyFiles)
        (
          ownerId: file.authorId.isNotEmpty
              ? file.authorId
              : file.outgoing
              ? state.jamiId
              : file.peerId,
          fileId: file.fileId,
        ): file,
    };
    // Messages, files, and live offers are one chronological stream. Requests
    // are conversation items, not chrome pinned to the newest edge.
    var insertionOrder = 0;
    var timelineFloor = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    DateTime timelineAt(ConversationTimelineItem item) {
      if (item.createdAt.isAfter(timelineFloor)) timelineFloor = item.createdAt;
      return timelineFloor;
    }

    final entries = <({DateTime at, int insertionOrder, Object item})>[];
    for (final item in timeline) {
      if (item is TimelineFileItem &&
          item.media == null &&
          liveFileKeys.contains((
            ownerId: item.authorId,
            fileId: item.fileId,
          ))) {
        continue;
      }
      entries.add((
        at: timelineAt(item),
        insertionOrder: insertionOrder++,
        item: item,
      ));
    }
    for (final file in legacyFiles) {
      final ownerId = file.authorId.isNotEmpty
          ? file.authorId
          : file.outgoing
          ? state.jamiId
          : file.peerId;
      if (liveFileKeys.contains((ownerId: ownerId, fileId: file.fileId)) ||
          timelineFileKeys.contains((ownerId: ownerId, fileId: file.fileId))) {
        continue;
      }
      entries.add((
        at: DateTime.fromMillisecondsSinceEpoch(
          file.timestamp * 1000,
          isUtc: true,
        ),
        insertionOrder: insertionOrder++,
        item: file,
      ));
    }
    for (final transfer in live) {
      if (timeline.whereType<TimelineFileItem>().any(
        (item) =>
            item.media != null &&
            item.fileId == transfer.fileId &&
            item.authorId == transfer.authorId,
      )) {
        continue;
      }
      entries.add((
        at: transfer.createdAt,
        insertionOrder: insertionOrder++,
        item: transfer,
      ));
    }
    entries.sort((left, right) {
      final time = left.at.compareTo(right.at);
      return time != 0
          ? time
          : left.insertionOrder.compareTo(right.insertionOrder);
    });
    final entryIds = [
      for (final entry in entries) _timelineItemId(entry.item, state),
    ];
    final receiptReady = group != null || entries.isEmpty
        ? true
        : _receiptReady(entries.last.item, state);
    final animateIds = <String>{};
    if (_seeded) {
      final tailIndex = _tailItemId == null
          ? -1
          : entryIds.lastIndexOf(_tailItemId!);
      final firstNewIndex = _tailItemId == null ? 0 : tailIndex + 1;
      if (_tailItemId == null || tailIndex >= 0) {
        for (var index = firstNewIndex; index < entryIds.length; index++) {
          final id = entryIds[index];
          if (!_seenItemIds.contains(id)) animateIds.add(id);
        }
      }
    }
    _seenItemIds.addAll(entryIds);
    _tailItemId = entryIds.lastOrNull;
    // A conversation still loading its first page is history, not news.
    _seeded = _seeded || !state.chatLoading;
    final animate =
        state.chatMotionEnabled && !MediaQuery.disableAnimationsOf(context);
    // Under gravity, entry belongs to Gravity.
    if (animate && !gravityMode.value) {
      for (final entry in entries) {
        final id = _timelineItemId(entry.item, state);
        if (animateIds.contains(id) && !_entering.containsKey(id)) {
          _enter(id, entry.item, state);
        }
      }
    }
    final persistent = <Widget>[];
    final historyTarget = state.historyTimelineMessageId;
    bool isHistoryTarget(Object item) =>
        item is ConversationTimelineItem &&
        item.scope == state.selectedConversationScope &&
        item.daemonId == historyTarget;
    for (var i = 0; i < entries.length;) {
      if (entries[i].item case final TimelineDmTopicEventItem item) {
        final event = DmTopicEventCodec.decode(item.eventBody);
        final friend = state.selectedFriend;
        if (event?.operation == DmTopicOperation.left &&
            friend != null &&
            item.authorId == friend.peerId) {
          persistent.add(
            _PeerLeftMarker(
              key: ValueKey('dm-left-marker:${item.daemonId}'),
              name: friendLabel(friend),
            ),
          );
        } else if (event?.operation == DmTopicOperation.archive) {
          persistent.add(
            _DmTopicArchiveMarker(
              key: ValueKey('dm-topic-marker:${item.daemonId}'),
              author: item.authorId == state.jamiId
                  ? 'You'
                  : friend == null
                  ? 'They'
                  : friendLabel(friend),
              local: item.authorId == state.jamiId,
              archived: event!.archived!,
            ),
          );
        }
        i++;
        continue;
      }
      final block = <Object>[entries[i].item];
      var cursor = i + 1;
      while (cursor < entries.length &&
          !isHistoryTarget(block.first) &&
          !isHistoryTarget(entries[cursor].item) &&
          entries[cursor].item is! TimelineDmTopicEventItem &&
          _sameMessageGroup(block.last, entries[cursor].item, state)) {
        block.add(entries[cursor].item);
        cursor++;
      }
      final blockIds = {for (final item in block) _timelineItemId(item, state)};
      final showAuthor =
          state.repeatMessageAuthorAfterPause ||
          i == 0 ||
          _timelineAuthor(entries[i - 1].item, state) !=
              _timelineAuthor(block.first, state);
      // A wholly new block enters as one; otherwise each new item does.
      final blockEntry = blockIds.every(_entering.containsKey)
          ? _entering[blockIds.first]
          : null;
      final messageBlock = _MessageBlock(
        state: state,
        items: block,
        group: group,
        textFor: textFor,
        localFiles: folderByOwnerFile,
        animatedItemIds: animate ? animateIds : const {},
        entering: _entering,
        blockEntering: blockEntry != null,
        showAuthor: showAuthor,
        showReceipt:
            cursor == entries.length &&
            _timelineDirection(block.last) == TimelineDirection.outgoing &&
            receiptReady,
      );
      final timestampStyle = state.messageTimestampStyle;
      final showSessionDivider =
          timestampStyle == MessageTimestampStyle.messenger ||
          timestampStyle == MessageTimestampStyle.apple;
      if (showSessionDivider &&
          (i == 0 ||
              entries[i].at.difference(entries[i - 1].at).abs() >=
                  const Duration(minutes: 15))) {
        persistent.add(_SessionDivider(at: entries[i].at));
      }
      if (isHistoryTarget(block.first)) {
        persistent.add(
          Semantics(
            key: ValueKey<String>('history-message-highlight:$historyTarget'),
            selected: true,
            label: 'Historical search result',
            child: Focus(
              autofocus: true,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.primary.withValues(alpha: 0.08),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.primary,
                    width: 2,
                  ),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: messageBlock,
                ),
              ),
            ),
          ),
        );
      } else {
        persistent.add(
          KeyedSubtree(
            key: ValueKey(
              'message-block:${_timelineItemId(block.first, state)}:'
              '${_timelineItemId(block.last, state)}',
            ),
            child: blockEntry != null
                ? _ChatEntryMotion(
                    key: ValueKey('chat-entry-motion:${blockIds.first}'),
                    arrive: blockEntry.arrive,
                    child: messageBlock,
                  )
                : messageBlock,
          ),
        );
      }
      i = cursor;
    }
    // A reversed viewport is the native Flutter chat-list primitive: offset
    // zero is the newest edge, appending a live item stays visible, and adding
    // an older history page at the far edge does not change the reader's
    // offset. Build the logical ascending list once, then reverse only its
    // sliver order so visual/reading order remains oldest-to-newest.
    final ascending = <Widget>[
      if (state.chatHasMore || state.chatLoading || state.chatLoadError != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Center(
            child: state.chatLoading
                ? const SizedBox.square(
                    dimension: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Gravity(
                    child: TextButton.icon(
                      key: const ValueKey('load-older-chat-button'),
                      onPressed: state.loadOlderChat,
                      icon: Icon(
                        state.chatLoadError == null
                            ? Icons.history_rounded
                            : Icons.refresh_rounded,
                        size: 18,
                      ),
                      label: Text(
                        state.chatLoadError == null
                            ? 'Load earlier messages'
                            : 'Try loading earlier messages again',
                      ),
                    ),
                  ),
          ),
        ),
      ...persistent,
    ];
    final descending = ascending.reversed.toList(growable: false);
    final targetIndex = historyTarget == null
        ? -1
        : descending.indexWhere(
            (child) =>
                child.key ==
                ValueKey<String>('history-message-highlight:$historyTarget'),
          );
    final Widget viewport;
    if (targetIndex >= 0) {
      final center = ValueKey(('history-timeline-center', historyTarget));
      // Flutter's center sliver anchors an exact variable-height message without
      // estimated offsets, building all intervening widgets, or fake scrolling.
      // Newer history grows below it and older history above it, continuously.
      viewport = CustomScrollView(
        key: ValueKey(('history-timeline', state.historyTimelineGeneration)),
        primary: false,
        reverse: true,
        anchor: 0.5,
        center: center,
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            sliver: SliverList(
              delegate: SliverChildListDelegate(
                descending.take(targetIndex).toList().reversed.toList(),
              ),
            ),
          ),
          SliverPadding(
            key: center,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            sliver: SliverList(
              delegate: SliverChildListDelegate(
                descending.skip(targetIndex).toList(),
              ),
            ),
          ),
        ],
      );
    } else {
      viewport = ListView(
        key: const ValueKey('file-timeline'),
        reverse: true,
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: WindowPresentationScope.isCompact(context)
            ? const EdgeInsets.symmetric(horizontal: 8, vertical: 10)
            : const EdgeInsets.fromLTRB(18, 18, 18, 18),
        children: descending,
      );
    }
    if (!state.historyTimelineReadSuppressed) return viewport;
    return Column(
      children: [
        Material(
          key: const ValueKey('history-navigation-status'),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                Expanded(
                  child: Gravity(
                    child: Text(
                      state.historyTimelineBusy
                          ? 'Locating message · ${state.historyTimelineLoadedItems} messages loaded'
                          : state.historyTimelineUnavailable ||
                                historyTarget == null
                          ? 'The selected message is unavailable or changed.'
                          : 'Historical message · automatic read receipts are paused',
                    ),
                  ),
                ),
                Gravity(
                  child: TextButton(
                    key: const ValueKey('history-return-latest'),
                    onPressed: state.returnToLatestHistory,
                    child: Text(
                      state.historyTimelineBusy ? 'Cancel' : 'Back to latest',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(child: viewport),
      ],
    );
  }
}

class _PeerLeftMarker extends StatelessWidget {
  const _PeerLeftMarker({super.key, required this.name});

  final String name;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: "$name removed you. You can't send messages here anymore.",
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Gravity(
            child: Text(
              '$name removed you',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: context.syblColors.muted,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Gravity(
            child: Text(
              "You can't send messages here anymore.",
              textAlign: TextAlign.center,
              style: TextStyle(color: context.syblColors.faint, fontSize: 11),
            ),
          ),
        ],
      ),
    ),
  );
}

/// Replaces the composer once a friend removed you.
class _PeerLeftActions extends StatelessWidget {
  const _PeerLeftActions({required this.state, required this.friend});

  final AppState state;
  final FriendState friend;

  @override
  Widget build(BuildContext context) {
    final busy = state.archivingChat(friend.peerId);
    return Padding(
      key: const ValueKey('peer-left-actions'),
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Gravity(
            child: OutlinedButton.icon(
              key: const ValueKey('peer-left-archive'),
              onPressed: busy
                  ? null
                  : () async {
                      final result = await state.archiveLeftChat(friend.peerId);
                      if (result.warning != null) showNotice(result.warning!);
                    },
              icon: const Icon(Icons.archive_outlined, size: 16),
              label: const Text('Archive chat'),
            ),
          ),
          const SizedBox(width: 10),
          Gravity(
            child: OutlinedButton.icon(
              key: const ValueKey('peer-left-delete'),
              onPressed: busy
                  ? null
                  : () async {
                      final result = await state.deleteLeftChat(friend.peerId);
                      if (result.warning != null) showNotice(result.warning!);
                    },
              icon: const Icon(Icons.delete_outline_rounded, size: 16),
              label: const Text('Delete chat'),
            ),
          ),
        ],
      ),
    );
  }
}

class _DmTopicArchiveMarker extends StatelessWidget {
  const _DmTopicArchiveMarker({
    super.key,
    required this.author,
    required this.local,
    required this.archived,
  });

  final String author;
  final bool local;
  final bool archived;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: archived
        ? '$author archived this topic. '
              '${local ? 'You will' : 'They will'} not receive notifications here.'
        : '$author unarchived this topic. '
              '${local ? 'You will' : 'They will'} receive notifications here again.',
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Gravity(
            child: Text(
              '$author ${archived ? 'archived' : 'unarchived'} this topic',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: context.syblColors.muted,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Gravity(
            child: Text(
              '${local ? 'You will' : 'They will'} '
              '${archived ? 'not receive notifications here.' : 'receive notifications here again.'}',
              textAlign: TextAlign.center,
              style: TextStyle(color: context.syblColors.faint, fontSize: 11),
            ),
          ),
        ],
      ),
    ),
  );
}

class ConversationComposer extends StatefulWidget {
  final AppState state;
  final String hintText;
  final String fileLabel;
  final Future<bool> Function(String body) onSend;
  final Future<SendJournalRecord?> Function(
    String body,
    ComposerOperation operation,
  )?
  onSendOwned;
  final String? groupTopicId;
  final ValueChanged<ComposerResult>? onCommandExecuted;

  const ConversationComposer({
    super.key,
    required this.state,
    required this.hintText,
    required this.fileLabel,
    required this.onSend,
    this.onSendOwned,
    this.groupTopicId,
    this.onCommandExecuted,
  });

  @override
  State<ConversationComposer> createState() => _ConversationComposerState();
}

class _ConversationComposerState extends State<ConversationComposer>
    with WidgetsBindingObserver {
  static const _typingPause = Duration(milliseconds: 1500);

  final TextEditingController _controller = TextEditingController();
  Object _surfaceLifetime = Object();
  bool _paneActive = true;
  final _commandOverlay = OverlayPortalController();
  final _composerStackKey = GlobalKey();
  final _composerFieldKey = GlobalKey();
  late final FocusNode _focusNode;
  final FocusNode _recordingFocus = FocusNode();
  Timer? _typingPauseTimer;
  bool _submitting = false;
  bool _picking = false;
  bool _pickerOpen = false;
  String? _preparationError;
  ComposerDraftSession? _draft;
  Object? _draftOwner;
  bool _loadingDraft = false;
  String _visibleReplyTo = '';
  Object? _submissionToken;
  Object? _pendingCommand;
  int get _draftRevision => _draft?.revision ?? 0;
  int _selectedCommandIndex = 0;
  Object? _renderedOwner;
  VoiceRecorder? _voice;
  ComposerOperation? _voiceOperation;
  VoiceGesture _voiceGesture = VoiceGesture();
  Timer? _voiceHold;
  int? _voicePointer;
  Offset? _voiceOrigin;
  bool _voiceFinishing = false;
  int _voiceSendEpoch = 0;

  AppState get state => widget.state;
  Object get _composerOwner => (
    state,
    state.conversationActionOwner,
    widget.groupTopicId,
    _surfaceLifetime,
  );

  bool get _canSend =>
      _paneActive &&
      _voice == null &&
      _draft != null &&
      !_draft!.blocked(ComposerOperationKind.sendText) &&
      !_draft!.blocked(ComposerOperationKind.sendMedia) &&
      !_submitting &&
      !state.sendingChatMessage &&
      !state.appearOffline &&
      (_controller.text.trim().isNotEmpty ||
          (_draft!.media != null && !_draft!.mediaAlreadyCommitted));

  ComposerQueryResult get _commandQuery => state.resolveComposerQuery(
    _controller.text,
    groupTopicId: widget.groupTopicId,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _focusNode = FocusNode(onKeyEvent: _onComposerKeyEvent);
    _commandOverlay.show();
    _controller.addListener(_onDraftChanged);
    _focusNode.addListener(_onFocusChanged);
    _syncDraftSession();
  }

  @override
  void didUpdateWidget(covariant ConversationComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncDraftSession();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final active = PaneActivityScope.isActive(context);
    if (active == _paneActive) return;
    _paneActive = active;
    // Every return is a new authority lifetime; old async callbacks cannot
    // regain ownership simply because the same retained pane is shown again.
    _surfaceLifetime = Object();
    _pendingCommand = null;
    _submissionToken = null;
    _submitting = false;
    _picking = false;
    _syncDraftSession();
    if (!active) {
      _focusNode.unfocus();
      _recordingFocus.unfocus();
      unawaited(state.setLocalComposerActivity(ComposerActivityKind.idle));
    }
  }

  void _syncDraftSession() {
    final owner = _composerOwner;
    if (_draftOwner == owner) {
      if (_draft != null && _controller.value != _draft!.text) {
        _loadingDraft = true;
        _controller.value = _draft!.text;
        _loadingDraft = false;
      }
      if (_visibleReplyTo != (_draft?.replyTo ?? '')) {
        _visibleReplyTo = _draft?.replyTo ?? '';
        if (_visibleReplyTo.isNotEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted &&
                _composerOwner == owner &&
                SyblLayout.autofocusTextInput(context)) {
              _focusNode.requestFocus();
            }
          });
        }
      }
      return;
    }
    final previousOwner = _draftOwner;
    _voiceSendEpoch++;
    _detachVoice();
    _pickerOpen = false;
    _preparationError = null;
    if (previousOwner != null) _draft?.deactivate(previousOwner);
    _typingPauseTimer?.cancel();
    if (_pendingCommand == null) {
      _submissionToken = null;
      _submitting = false;
    }
    final scope = state.selectedConversationScope;
    _draft = scope == null
        ? null
        : state.composerDrafts.acquire(
            ComposerDraftKey(
              scope,
              scope.isGroup
                  ? widget.groupTopicId ?? 'general'
                  : state.selectedDmTopicId,
            ),
          );
    _draftOwner = _paneActive ? owner : null;
    if (_paneActive) _draft?.activate(owner);
    _visibleReplyTo = _draft?.replyTo ?? '';
    _loadingDraft = true;
    _controller.value = _draft?.text ?? TextEditingValue.empty;
    _loadingDraft = false;
    _selectedCommandIndex = 0;
  }

  void _onDraftChanged() {
    if (!_paneActive || _loadingDraft || _draftOwner != _composerOwner) return;
    if (_draft?.updateText(_composerOwner, _controller.value) != true) return;
    if (mounted) {
      setState(() => _selectedCommandIndex = 0);
    }
    _syncComposerActivity();
  }

  KeyEventResult _onComposerKeyEvent(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final owner = _renderedOwner;
    if (owner == null || owner != _composerOwner) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (_pickerOpen) {
        setState(() => _pickerOpen = false);
        return KeyEventResult.handled;
      }
      if (_voice != null) {
        _voiceGesture.interrupt();
        unawaited(_finishVoice(owner));
        return KeyEventResult.handled;
      }
    }
    final results = _commandQuery.results;
    if (results.isEmpty) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown ||
        event.logicalKey == LogicalKeyboardKey.arrowUp) {
      final delta = event.logicalKey == LogicalKeyboardKey.arrowDown ? 1 : -1;
      setState(() {
        _selectedCommandIndex =
            (_selectedCommandIndex + delta) % results.length;
      });
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      unawaited(_activateCommand(results[_selectedCommandIndex], owner));
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.tab) {
      final result = results[_selectedCommandIndex];
      // Tab completes a slash command's text; a chat or topic has none, so
      // it opens like Enter.
      if (!result.label.startsWith('/')) {
        unawaited(_activateCommand(result, owner));
        return KeyEventResult.handled;
      }
      final value = result.executable ? result.label : '${result.label} ';
      _controller.value = TextEditingValue(
        text: value,
        selection: TextSelection.collapsed(offset: value.length),
      );
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _activateCommand(ComposerResult result, Object owner) async {
    if (!_paneActive ||
        owner != _composerOwner ||
        _submitting ||
        state.appearOffline) {
      return;
    }
    if (result.kind == ComposerResultKind.gravity) {
      gravityMode.value = !gravityMode.value;
      _controller.clear();
      return;
    }
    if (!result.executable) {
      final value = '${result.label} ';
      _controller.value = TextEditingValue(
        text: value,
        selection: TextSelection.collapsed(offset: value.length),
      );
      return;
    }
    setState(() => _submitting = true);
    final submission = _pendingCommand = _submissionToken = Object();
    final paneLifetime = _surfaceLifetime;
    final draft = _draft!;
    final revision = draft.revision;
    final action = state.captureConversationAction(
      isCurrent: () =>
          _paneActive &&
          identical(paneLifetime, _surfaceLifetime) &&
          draft.revision == revision,
    );
    final actionState = state;
    var success = false;
    try {
      if (result.topicName == null &&
          (result.kind == ComposerResultKind.createTopic ||
              result.kind == ComposerResultKind.renameTopic)) {
        final create = result.kind == ComposerResultKind.createTopic;
        success = await _showDmTopicNameDialog(
          context,
          state: state,
          action: action,
          title: create ? 'New topic' : 'Rename topic',
          actionLabel: create ? 'Create' : 'Rename',
          initialValue: create
              ? ''
              : state.selectedDmTopicState
                        ?.topic(state.selectedDmTopicId)
                        ?.name ??
                    '',
          onSubmit: create
              ? state.createDmTopic
              : (name, {action}) => state.renameDmTopic(result.topicId, name),
        );
      } else {
        success = await state.executeComposerResult(result, action: action);
      }
    } catch (_) {
      state.dlog('Composer command failed');
    }
    if (!mounted || !identical(_submissionToken, submission)) return;
    final ownsDraft =
        _paneActive &&
        identical(paneLifetime, _surfaceLifetime) &&
        identical(state, actionState) &&
        state.ownsConversationAction(action) &&
        draft.revision == revision;
    setState(() {
      _submitting = false;
      _pendingCommand = null;
      if (success &&
          ownsDraft &&
          draft.clearExecutedCommand(revision) &&
          identical(_draft, draft)) {
        _loadingDraft = true;
        _controller.value = draft.text;
        _loadingDraft = false;
      }
    });
    if (success && ownsDraft) widget.onCommandExecuted?.call(result);
    if (ownsDraft) _focusNode.requestFocus();
  }

  void _syncComposerActivity() {
    _typingPauseTimer?.cancel();
    if (_loadingDraft || _draftOwner != _composerOwner) return;
    final typing = _focusNode.hasFocus && _controller.text.trim().isNotEmpty;
    unawaited(
      state.setLocalComposerActivity(
        typing ? ComposerActivityKind.typing : ComposerActivityKind.idle,
      ),
    );
    if (typing) {
      final owner = _composerOwner;
      _typingPauseTimer = Timer(_typingPause, () {
        _typingPauseTimer = null;
        if (!mounted || owner != _composerOwner) return;
        unawaited(state.setLocalComposerActivity(ComposerActivityKind.idle));
      });
    }
  }

  Future<void> _send(
    Object renderedOwner, {
    bool mediaOnly = false,
    bool asHologram = false,
  }) async {
    if (renderedOwner != _composerOwner || !_canSend) return;
    final draft = _draft!;
    final media = draft.media;
    final command = _commandQuery.isExactAction;
    if (draft.replyTo.isNotEmpty &&
        (mediaOnly || _controller.text.trim().isEmpty)) {
      setState(() {
        _preparationError =
            'Write a message to reply, or cancel the reply first.';
      });
      return;
    }
    if (!mediaOnly && _controller.text.trim().isNotEmpty) {
      if (!await _sendText(renderedOwner)) return;
      if (command) return;
    }
    if (!mounted ||
        renderedOwner != _composerOwner ||
        !identical(_draft, draft) ||
        (!mediaOnly && draft.text.text.trim().isNotEmpty) ||
        draft.blocked(ComposerOperationKind.sendText) ||
        media == null ||
        !identical(draft.media, media) ||
        _submitting) {
      return;
    }
    final operation = draft.begin(
      ComposerOperationKind.sendMedia,
      renderedOwner,
    );
    if (operation == null) return;
    final actionState = state;
    final submission = _submissionToken = Object();
    setState(() => _submitting = true);
    try {
      final result = await actionState.sendComposerFile(
        draft,
        operation,
        asHologram: asHologram,
      );
      final status = result?.status ?? ComposerSendStatus.failedBeforeCommit;
      draft.complete(operation, status, commitId: result?.commitId);
      if (status == ComposerSendStatus.committed ||
          status == ComposerSendStatus.failedBeforeCommit) {
        await actionState.sendJournal.acknowledge(operation.id);
      }
    } catch (_) {
      draft.complete(operation, ComposerSendStatus.unknown);
      actionState.dlog('Composer file publication outcome unknown');
    } finally {
      if (mounted && identical(_submissionToken, submission)) {
        setState(() => _submitting = false);
      }
    }
  }

  Future<bool> _sendText(Object renderedOwner) async {
    if (renderedOwner != _composerOwner || !_canSend) return false;
    final query = _commandQuery;
    if (query.results.isNotEmpty && query.isExactAction) {
      await _activateCommand(
        query.results[_selectedCommandIndex],
        renderedOwner,
      );
      return false;
    }
    if (!query.isSendableText) return false;
    final body = _controller.text.trim();
    final draft = _draft!;
    final operation = widget.onSendOwned == null
        ? null
        : draft.begin(ComposerOperationKind.sendText, renderedOwner);
    if (widget.onSendOwned != null && operation == null) return false;
    final owner = state.conversationActionOwner;
    final revision = _draftRevision;
    final topic = widget.groupTopicId;
    final actionState = state;
    setState(() => _submitting = true);
    final submission = _submissionToken = Object();
    _typingPauseTimer?.cancel();
    unawaited(state.setLocalComposerActivity(ComposerActivityKind.idle));
    var sent = false;
    try {
      if (operation == null) {
        sent = await widget.onSend(body);
      } else {
        final result = await widget.onSendOwned!(body, operation);
        final status = result?.status ?? ComposerSendStatus.failedBeforeCommit;
        draft.complete(operation, status, commitId: result?.commitId);
        sent = status == ComposerSendStatus.committed;
        if (result != null &&
            (sent || status == ComposerSendStatus.failedBeforeCommit)) {
          unawaited(actionState.sendJournal.acknowledge(operation.id));
        }
      }
    } catch (_) {
      if (operation != null) {
        draft.complete(operation, ComposerSendStatus.unknown);
      }
      actionState.dlog('Composer send failed');
    }
    if (!mounted || !identical(_submissionToken, submission)) return false;
    final ownsDraft =
        identical(state, actionState) &&
        state.conversationActionOwner == owner &&
        widget.groupTopicId == topic &&
        (operation == null
            ? _draftRevision == revision
            : identical(_draft, draft) && draft.text.text.isEmpty);
    setState(() {
      _submitting = false;
      if (sent && ownsDraft) {
        if (operation == null) {
          _controller.clear();
        } else {
          _controller.value = draft.text;
        }
      }
    });
    if (!sent) _syncComposerActivity();
    if (sent && ownsDraft) _focusNode.requestFocus();
    return sent && ownsDraft;
  }

  Future<void> _pickFile(
    Object owner, {
    bool gif = false,
    String? libraryHash,
    StarterGif? starterGif,
    bool photo = false,
  }) async {
    final draft = _draft;
    if (owner != _composerOwner || draft == null || _picking) return;
    final operation = draft.begin(
      photo ? ComposerOperationKind.camera : ComposerOperationKind.picker,
      owner,
    );
    if (operation == null) return;
    final actionState = state;
    setState(() {
      _picking = true;
      _preparationError = null;
    });
    _typingPauseTimer?.cancel();
    unawaited(state.setLocalComposerActivity(ComposerActivityKind.idle));
    try {
      final result = photo
          ? await actionState.prepareComposerPhoto(draft, operation)
          : await actionState.prepareComposerFile(
              draft,
              operation,
              gif: gif,
              libraryHash: libraryHash,
              starterGif: starterGif,
            );
      if (mounted &&
          owner == _composerOwner &&
          result == ComposerPreparationResult.invalid) {
        _preparationError = starterGif != null
            ? 'This Doorlight GIF could not be prepared. Try again.'
            : gif
            ? 'This GIF could not be added. Check its limits and the library’s available space (32 GIFs, 64 MiB).'
            : 'This attachment could not be prepared.';
      }
    } catch (_) {
      actionState.dlog('Composer attachment preparation failed');
    } finally {
      if (mounted) {
        setState(() => _picking = false);
        if (owner == _composerOwner) _syncComposerActivity();
      }
    }
  }

  Future<void> _removeMedia(Object owner, ComposerMediaStage media) async {
    final discard = _draft?.mayDiscardStage(media) ?? false;
    if (owner != _composerOwner || _draft?.removeMedia(owner, media) != true) {
      return;
    }
    final actionState = state;
    setState(() {});
    if (discard && media.path != null) {
      try {
        await actionState.jami.discardPickedFile(media.path!);
      } catch (_) {
        actionState.dlog('Composer attachment cleanup failed');
      }
    }
  }

  void _togglePicker(Object owner) {
    if (owner != _composerOwner || _draft == null) return;
    setState(() => _pickerOpen = !_pickerOpen);
    if (_pickerOpen) {
      _focusNode.unfocus();
      _typingPauseTimer?.cancel();
      unawaited(state.setLocalComposerActivity(ComposerActivityKind.idle));
    } else {
      _focusNode.requestFocus();
    }
  }

  void _onFocusChanged() {
    if (_focusNode.hasFocus && _pickerOpen && mounted) {
      setState(() => _pickerOpen = false);
    }
    _syncComposerActivity();
  }

  void _detachVoice() {
    _voiceHold?.cancel();
    _voicePointer = null;
    _voiceOrigin = null;
    final voice = _voice;
    _voice = null;
    voice?.removeListener(_onVoiceChange);
    voice?.dispose();
    _voiceOperation = null;
    _voiceGesture = VoiceGesture();
    _voiceFinishing = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    if (lifecycle != AppLifecycleState.resumed && _voice != null) {
      _voiceSendEpoch++;
      _voiceGesture.interrupt();
      unawaited(_finishVoice(_composerOwner));
    }
  }

  void _onVoiceChange() {
    final voice = _voice;
    if (!mounted || voice == null) return;
    setState(() {});
    if (!_voiceFinishing &&
        (voice.phase == VoiceRecorderPhase.stopped ||
            voice.phase == VoiceRecorderPhase.failed)) {
      _voiceGesture.interrupt();
      unawaited(_finishVoice(_composerOwner));
    }
  }

  void _voiceEffect(VoiceGestureEffect effect, Object owner) {
    switch (effect) {
      case VoiceGestureEffect.none:
        break;
      case VoiceGestureEffect.start:
        unawaited(_startVoice(owner));
      case VoiceGestureEffect.stopToReview:
        unawaited(_finishVoice(owner));
      case VoiceGestureEffect.stopAndSend:
        unawaited(_finishVoice(owner, send: true));
      case VoiceGestureEffect.discard:
        unawaited(_finishVoice(owner, discard: true));
    }
  }

  Future<void> _startVoice(Object owner) async {
    final draft = _draft;
    if (!_paneActive ||
        owner != _composerOwner ||
        draft == null ||
        _voice != null ||
        _picking ||
        !state.canRecordComposerVoice ||
        draft.blocked(ComposerOperationKind.sendMedia)) {
      return;
    }
    final operation = draft.begin(ComposerOperationKind.recording, owner);
    if (operation == null) return;
    final token = _voiceGesture.activation!;
    final voice = state.createComposerRecorder(draft, operation);
    setState(() {
      _voice = voice;
      _voiceOperation = operation;
      _preparationError = null;
      _pickerOpen = false;
    });
    voice.addListener(_onVoiceChange);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && identical(_voice, voice)) _recordingFocus.requestFocus();
    });
    final started = await voice.start();
    if (!mounted || !identical(_voice, voice) || owner != _composerOwner) {
      voice.dispose();
      return;
    }
    if (started) {
      _voiceEffect(_voiceGesture.started(token), owner);
    } else {
      _voiceGesture.interrupt();
      if (voice.permissionInterrupted) {
        setState(
          () => _preparationError =
              'Press the microphone again to start recording.',
        );
      }
      await _finishVoice(owner);
    }
  }

  Future<void> _finishVoice(
    Object owner, {
    bool send = false,
    bool discard = false,
  }) async {
    final voice = _voice;
    final operation = _voiceOperation;
    final draft = _draft;
    if (voice == null ||
        operation == null ||
        draft == null ||
        _voiceFinishing) {
      return;
    }
    _voiceFinishing = true;
    final sendEpoch = _voiceSendEpoch;
    _voiceHold?.cancel();
    final actionState = state;
    var staged = false;
    try {
      if (discard) {
        final path = await voice.stop();
        if (path != null) await actionState.jami.discardPickedFile(path);
        draft.finishPreparation(operation);
      } else {
        final result = await actionState.prepareComposerVoice(
          draft,
          operation,
          voice,
        );
        staged = result == ComposerPreparationResult.staged;
        if (!staged && mounted && identical(_voice, voice)) {
          setState(
            () => _preparationError ??= voice.phase == VoiceRecorderPhase.failed
                ? 'Microphone release could not be confirmed. Recording is unavailable.'
                : result == ComposerPreparationResult.invalid
                ? 'The recording is too short or could not be validated.'
                : null,
          );
        }
      }
    } catch (_) {
      draft.finishPreparation(operation);
      if (mounted && identical(_voice, voice)) {
        setState(
          () => _preparationError = 'The recording could not be prepared.',
        );
      }
    } finally {
      if (mounted && identical(_voice, voice)) {
        setState(_detachVoice);
      } else {
        voice.dispose();
      }
    }
    if (send &&
        sendEpoch == _voiceSendEpoch &&
        !voice.interrupted &&
        !voice.permissionInterrupted &&
        voice.elapsed < const Duration(seconds: 120) &&
        staged &&
        mounted &&
        owner == _composerOwner &&
        identical(_draft, draft)) {
      await _send(owner, mediaOnly: true);
    }
  }

  void _voiceDown(PointerDownEvent event, Object owner) {
    if (Theme.of(context).platform != TargetPlatform.android ||
        !state.canRecordComposerVoice ||
        _voice != null ||
        _picking) {
      return;
    }
    _voiceGesture.press();
    final token = _voiceGesture.activation;
    if (token == null) return;
    _voicePointer = event.pointer;
    _voiceOrigin = event.position;
    _voiceHold = Timer(const Duration(milliseconds: 350), () {
      if (mounted && owner == _composerOwner) {
        _voiceEffect(_voiceGesture.holdThreshold(token), owner);
      }
    });
  }

  void _voiceMove(PointerMoveEvent event) {
    if (event.pointer != _voicePointer || _voiceOrigin == null) return;
    final delta = event.position - _voiceOrigin!;
    _voiceEffect(
      _voiceGesture.drag(left: delta.dx <= -64, up: delta.dy <= -64),
      _composerOwner,
    );
  }

  void _voiceUp(PointerEvent event) {
    if (event.pointer != _voicePointer) return;
    _voiceHold?.cancel();
    _voicePointer = null;
    _voiceEffect(
      event is PointerCancelEvent
          ? _voiceGesture.interrupt()
          : _voiceGesture.release(),
      _composerOwner,
    );
  }

  Widget _recordingBar(Object owner, VoiceRecorder voice) {
    final level = voice.amplitudes.isEmpty
        ? 0.0
        : (voice.amplitudes.last + 60).clamp(0, 60) / 60;
    final seconds = voice.elapsed.inSeconds;
    return Row(
      key: const ValueKey('voice-recording-controls'),
      children: [
        Gravity(
          child: IconButton(
            tooltip: 'Discard recording',
            onPressed: _voiceFinishing
                ? null
                : () => _finishVoice(owner, discard: true),
            icon: const Icon(Icons.delete_outline),
          ),
        ),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Gravity(
                child: Text(
                  '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}',
                ),
              ),
              Semantics(
                label: 'Microphone level',
                value: '${(level * 100).round()} percent',
                child: LinearProgressIndicator(value: level),
              ),
            ],
          ),
        ),
        Gravity(
          child: IconButton(
            tooltip: 'Stop recording',
            onPressed: _voiceFinishing ? null : () => _finishVoice(owner),
            icon: const Icon(Icons.stop_rounded),
          ),
        ),
        Gravity(
          child: IconButton(
            tooltip: 'Send voice message',
            onPressed: _voiceFinishing
                ? null
                : () => _finishVoice(owner, send: true),
            icon: const Icon(Icons.arrow_upward),
          ),
        ),
      ],
    );
  }

  Widget _voiceReview(Object owner, ComposerMediaStage media) {
    final draft = _draft!;
    final content = FileMediaContent.parse(media.mediaMetadata);
    bool current() =>
        mounted &&
        owner == _composerOwner &&
        identical(_draft, draft) &&
        identical(draft.media, media) &&
        state.canPlayMessageMedia;
    return Row(
      key: const ValueKey('composer-media-preview'),
      children: [
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Gravity(
                child: Text(
                  media.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (media.path != null && content is VoiceMediaContent)
                VoiceReviewPlayer(
                  key: ObjectKey(media.identity),
                  path: media.path!,
                  duration: Duration(
                    milliseconds: content.durationMilliseconds,
                  ),
                  isCurrent: current,
                  validate: () async {
                    if (!current() ||
                        await FileSystemEntity.type(
                              media.path!,
                              followLinks: false,
                            ) !=
                            FileSystemEntityType.file) {
                      return false;
                    }
                    final verified = await validateComposerVoice(
                      media.path!,
                      media.encodedBytes,
                    );
                    return current() &&
                        verified?.mediaMetadata == media.mediaMetadata;
                  },
                ),
            ],
          ),
        ),
        Gravity(
          child: IconButton(
            tooltip: 'Delete voice message',
            onPressed: draft.blocked(ComposerOperationKind.sendMedia)
                ? null
                : () => _removeMedia(owner, media),
            icon: const Icon(Icons.delete_outline),
          ),
        ),
        Gravity(
          child: IconButton(
            tooltip: 'Send voice message',
            onPressed: _canSend ? () => _send(owner, mediaOnly: true) : null,
            icon: const Icon(Icons.arrow_upward),
          ),
        ),
      ],
    );
  }

  Future<void> _handleComposerBack(Object owner) async {
    if (!mounted ||
        owner != _composerOwner ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    if (_pickerOpen) {
      setState(() => _pickerOpen = false);
      _focusNode.requestFocus();
      return;
    }
    if (_voice != null) {
      _voiceSendEpoch++;
      _voiceGesture.interrupt();
      await _finishVoice(owner);
      return;
    }
    final draft = _draft;
    final media = draft?.media;
    if (draft == null ||
        media == null ||
        media.kind != ComposerMediaKind.voice ||
        !draft.mayDiscardStage(media)) {
      return;
    }
    var handled = false;
    void finish(BuildContext dialogContext, bool discard) {
      if (handled ||
          !dialogContext.mounted ||
          ModalRoute.of(dialogContext)?.isCurrent != true) {
        return;
      }
      handled = true;
      Navigator.of(dialogContext).pop(discard);
    }

    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard voice message?'),
        content: const Text('This recording has not been sent.'),
        actions: [
          TextButton(
            onPressed: () => finish(context, false),
            child: const Text('Keep recording'),
          ),
          TextButton(
            onPressed: () => finish(context, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (discard != true ||
        !mounted ||
        owner != _composerOwner ||
        !identical(_draft, draft) ||
        !identical(draft.media, media)) {
      return;
    }
    await _removeMedia(owner, media);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted &&
        owner == _composerOwner &&
        !identical(draft.media, media) &&
        ModalRoute.of(context)?.isCurrent == true) {
      await Navigator.of(context).maybePop();
    }
  }

  void _chooseEmoji(Object owner, String emoji) {
    if (owner != _composerOwner || _draft == null) return;
    final value = insertComposerEmoji(_controller.value, emoji);
    if (value != null) _controller.value = value;
  }

  Future<void> _chooseSticker(Object owner, BuiltInSticker sticker) async {
    final draft = _draft;
    if (owner != _composerOwner || draft == null) return;
    final operation = draft.begin(ComposerOperationKind.picker, owner);
    if (operation == null) return;
    final previous = draft.media;
    final discardPrevious = previous != null && draft.mayDiscardStage(previous);
    if (!draft.replaceMedia(
      operation,
      ComposerMediaStage(
        kind: ComposerMediaKind.sticker,
        label: sticker.label,
        encodedBytes: sticker.encodedBytes,
        assetId: sticker.id,
      ),
    )) {
      draft.finishPreparation(operation);
      return;
    }
    setState(() {});
    if (discardPrevious && previous.path != null) {
      try {
        await state.jami.discardPickedFile(previous.path!);
      } catch (_) {
        state.dlog('Replaced attachment cleanup failed');
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _detachVoice();
    final owner = _draftOwner;
    if (owner != null) _draft?.deactivate(owner);
    _typingPauseTimer?.cancel();
    if (owner == _composerOwner) {
      unawaited(state.setLocalComposerActivity(ComposerActivityKind.idle));
    }
    _controller
      ..removeListener(_onDraftChanged)
      ..dispose();
    _focusNode
      ..removeListener(_onFocusChanged)
      ..dispose();
    _recordingFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final compact = SyblLayout.isCompact(context);
    final windowCompact = WindowPresentationScope.isCompact(context);
    final owner = _renderedOwner = _composerOwner;
    final mobile = Theme.of(context).platform == TargetPlatform.android;
    final fileEnabled =
        _draft != null &&
        !_picking &&
        !state.sendingFile &&
        !state.appearOffline &&
        !_draft!.blocked(ComposerOperationKind.sendMedia);
    final fileLabel = _picking || state.sendingFile
        ? 'Choosing a file…'
        : state.appearOffline
        ? 'Go online to share a file'
        : widget.fileLabel;
    final attachment = IconButton(
      key: const ValueKey('send-file-button'),
      tooltip: fileLabel,
      onPressed: fileEnabled ? () => _pickFile(owner) : null,
      constraints: BoxConstraints.tight(const Size.square(48)),
      icon: Icon(
        _picking || state.sendingFile
            ? Icons.hourglass_top_rounded
            : Icons.attach_file_rounded,
      ),
    );
    final activity = state.remoteComposerActivity;
    final friend = state.selectedFriend;
    final activityText = friend == null || activity == null
        ? null
        : switch (activity) {
            ComposerActivityKind.typing => '${friendLabel(friend)} is typing…',
            ComposerActivityKind.idle => null,
          };
    final motionDuration = state.chatMotionEnabled
        ? SyblMotion.duration(context)
        : Duration.zero;
    final commandQuery = _commandQuery;
    final commandResults = commandQuery.results;
    if (_selectedCommandIndex >= commandResults.length) {
      _selectedCommandIndex = 0;
    }
    final exactCommand =
        commandResults.isNotEmpty && commandQuery.isExactAction;
    final voiceReview = _draft?.media;
    return PopScope(
      canPop:
          !_paneActive ||
          (!_pickerOpen &&
              _voice == null &&
              !(voiceReview?.kind == ComposerMediaKind.voice &&
                  _draft!.mayDiscardStage(voiceReview!))),
      onPopInvokedWithResult: (didPop, _) {
        if (_paneActive && !didPop) unawaited(_handleComposerBack(owner));
      },
      child: Focus(
        focusNode: _recordingFocus,
        onKeyEvent: _onComposerKeyEvent,
        child: Listener(
          onPointerMove: _voiceMove,
          onPointerUp: _voiceUp,
          onPointerCancel: _voiceUp,
          child: OverlayPortal.overlayChildLayoutBuilder(
            controller: _commandOverlay,
            overlayChildBuilder: (context, info) {
              if (!_paneActive || commandResults.isEmpty) {
                return const SizedBox.shrink();
              }
              final bounds = MatrixUtils.transformRect(
                info.childPaintTransform,
                Offset.zero & info.childSize,
              );
              final availableHeight =
                  bounds.bottom - 68 - MediaQuery.paddingOf(context).top;
              if (availableHeight <= 0) return const SizedBox.shrink();
              // Line the popup up with the text box itself, whatever buttons
              // sit beside it on this layout.
              final stackBox =
                  _composerStackKey.currentContext?.findRenderObject()
                      as RenderBox?;
              final fieldBox =
                  _composerFieldKey.currentContext?.findRenderObject()
                      as RenderBox?;
              final fieldLeft = stackBox != null && fieldBox != null
                  ? fieldBox.localToGlobal(Offset.zero).dx -
                        stackBox.localToGlobal(Offset.zero).dx
                  : (compact ? 114.0 : 108.0);
              final fieldWidth =
                  fieldBox?.size.width ?? bounds.width - (compact ? 132 : 122);
              return Positioned(
                left: bounds.left + fieldLeft,
                width: fieldWidth,
                bottom: info.overlaySize.height - bounds.bottom + 68,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: availableHeight),
                  child: _ComposerCommandPopup(
                    results: commandResults,
                    selectedIndex: _selectedCommandIndex,
                    onSelected: (result) => _activateCommand(result, owner),
                  ),
                ),
              );
            },
            child: Stack(
              key: _composerStackKey,
              clipBehavior: Clip.none,
              children: [
                // Under gravity pieces pile on the composer's top line and a
                // few hard throws break it; own new messages squeeze out of it.
                GravityPlatform(
                  spout: true,
                  color: context.syblColors.line,
                  builder: (context, broken) => Container(
                    key: const ValueKey('conversation-composer'),
                    constraints: BoxConstraints(
                      minHeight: windowCompact ? 46 : 68,
                    ),
                    padding: EdgeInsets.symmetric(
                      horizontal: windowCompact
                          ? 6
                          : compact
                          ? 12
                          : 8,
                      vertical: windowCompact ? 4 : 9,
                    ),
                    // A broken line keeps its width, so nothing below moves.
                    decoration: BoxDecoration(
                      border: Border(
                        top: BorderSide(
                          color: broken
                              ? Colors.transparent
                              : context.syblColors.line,
                        ),
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_draft == null &&
                            state.selectedConversationScope != null)
                          const Gravity(
                            child: Text(
                              'Draft limit reached. Send or clear an existing draft to start another.',
                            ),
                          ),
                        if (_draft?.replyTo.isNotEmpty == true)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: _ReplyPreview(
                              state: state,
                              target: state.replyTargetById(_draft!.replyTo),
                              onCancel: () {
                                if (_composerOwner != owner) return;
                                if (_draft?.setReply(owner, '') == true) {
                                  setState(() => _visibleReplyTo = '');
                                }
                              },
                            ),
                          ),
                        if (_draft?.media case final media?)
                          if (media.kind == ComposerMediaKind.voice)
                            _voiceReview(owner, media)
                          else
                            Row(
                              key: const ValueKey('composer-media-preview'),
                              children: [
                                if (media.kind == ComposerMediaKind.sticker)
                                  Gravity(
                                    child: StickerImage(
                                      assetId: media.assetId,
                                      extent: 64,
                                    ),
                                  )
                                else if (media.kind == ComposerMediaKind.gif)
                                  Gravity(
                                    child: BoundedGif(
                                      path: media.path,
                                      size: 64,
                                    ),
                                  )
                                else if (media.kind ==
                                        ComposerMediaKind.photo &&
                                    media.path != null)
                                  Gravity(
                                    child: Image.file(
                                      File(media.path!),
                                      width: 64,
                                      height: 64,
                                      fit: BoxFit.contain,
                                      cacheWidth: 128,
                                      errorBuilder: (_, _, _) => const Icon(
                                        Icons.broken_image_outlined,
                                      ),
                                    ),
                                  )
                                else
                                  const Gravity(
                                    child: Icon(
                                      Icons.insert_drive_file_outlined,
                                    ),
                                  ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Gravity(
                                    child: Text(
                                      media.label,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                                if (media.kind == ComposerMediaKind.sticker &&
                                    state.selectedConversationScope?.isGroup ==
                                        false)
                                  Gravity(
                                    child: IconButton(
                                      tooltip: 'Send as hologram',
                                      onPressed: _canSend
                                          ? () => _send(
                                              owner,
                                              mediaOnly: true,
                                              asHologram: true,
                                            )
                                          : null,
                                      icon: const Icon(Icons.auto_awesome),
                                    ),
                                  ),
                                Gravity(
                                  child: IconButton(
                                    tooltip: 'Remove attachment',
                                    onPressed:
                                        _draft!.blocked(
                                          ComposerOperationKind.sendMedia,
                                        )
                                        ? null
                                        : () => _removeMedia(owner, media),
                                    icon: const Icon(Icons.close),
                                  ),
                                ),
                              ],
                            ),
                        if ((_preparationError ?? state.chatError)
                            case final error?)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 7),
                            child: Semantics(
                              liveRegion: true,
                              child: Gravity(
                                child: Text(
                                  error,
                                  style: TextStyle(
                                    color: context.syblColors.danger,
                                    fontSize: 11.5,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        if (_voice case final voice?)
                          _recordingBar(owner, voice)
                        else
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              if (windowCompact)
                                CompactIconButton(
                                  label: 'Files, emoji and voice messages',
                                  icon: Icons.add,
                                  onPressed: () =>
                                      WindowPresentationScope.maybeOf(
                                        context,
                                      )?.setCompact(false),
                                )
                              else if (!mobile)
                                Gravity(child: attachment),
                              if (!windowCompact)
                                Gravity(
                                  child: IconButton(
                                    key: const ValueKey(
                                      'composer-picker-button',
                                    ),
                                    tooltip: _pickerOpen
                                        ? 'Keyboard'
                                        : 'Emoji and stickers',
                                    onPressed:
                                        _draft != null && !state.appearOffline
                                        ? () => _togglePicker(owner)
                                        : null,
                                    icon: Icon(
                                      _pickerOpen
                                          ? Icons.keyboard
                                          : Icons.emoji_emotions_outlined,
                                    ),
                                  ),
                                ),
                              SizedBox(width: compact ? 6 : 4),
                              Expanded(
                                child: KeyedSubtree(
                                  key: _composerFieldKey,
                                  child: Gravity(
                                    child: TextField(
                                      key: const ValueKey('chat-composer'),
                                      controller: _controller,
                                      focusNode: _focusNode,
                                      enabled:
                                          _draft != null &&
                                          !state.appearOffline,
                                      // One line, never two: the composer must not grow into the
                                      // conversation as you type.
                                      minLines: 1,
                                      maxLines: 1,
                                      maxLength:
                                          TimelineWireContract.maxTextCodeUnits,
                                      maxLengthEnforcement:
                                          MaxLengthEnforcement.enforced,
                                      buildCounter:
                                          (
                                            context, {
                                            required currentLength,
                                            required isFocused,
                                            required maxLength,
                                          }) => null,
                                      textCapitalization:
                                          TextCapitalization.sentences,
                                      textInputAction: TextInputAction.send,
                                      onSubmitted: (_) => _send(owner),
                                      decoration: InputDecoration(
                                        suffixIcon: windowCompact
                                            ? null
                                            : mobile
                                            ? Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  IconButton(
                                                    tooltip: 'Take photo',
                                                    onPressed:
                                                        fileEnabled &&
                                                            state
                                                                .canCaptureComposerPhoto
                                                        ? () => _pickFile(
                                                            owner,
                                                            photo: true,
                                                          )
                                                        : null,
                                                    icon: const Icon(
                                                      Icons.camera_alt_outlined,
                                                    ),
                                                  ),
                                                  attachment,
                                                ],
                                              )
                                            : IconButton(
                                                key: const ValueKey(
                                                  'voice-record-button',
                                                ),
                                                tooltip: 'Record voice message',
                                                onPressed:
                                                    state.canRecordComposerVoice &&
                                                        fileEnabled
                                                    ? () => _voiceEffect(
                                                        _voiceGesture
                                                            .accessibleStart(),
                                                        owner,
                                                      )
                                                    : null,
                                                icon: const Icon(
                                                  Icons.mic_none_rounded,
                                                ),
                                              ),
                                        hintText: state.appearOffline
                                            ? 'Go online to send a message'
                                            : widget.hintText,
                                        contentPadding: EdgeInsets.symmetric(
                                          horizontal: windowCompact ? 8 : 15,
                                          vertical: windowCompact ? 7 : 11,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              SizedBox(width: compact ? 8 : 6),
                              if (mobile &&
                                  _controller.text.trim().isEmpty &&
                                  _draft?.media == null)
                                Listener(
                                  onPointerDown: (event) =>
                                      _voiceDown(event, owner),
                                  child: IconButton.filled(
                                    key: const ValueKey('voice-record-button'),
                                    tooltip: 'Record voice message',
                                    onPressed:
                                        state.canRecordComposerVoice &&
                                            fileEnabled
                                        ? () => _voiceEffect(
                                            _voiceGesture.accessibleStart(),
                                            owner,
                                          )
                                        : null,
                                    // Same colours as Send: the theme's muted
                                    // icon colour made an enabled mic look
                                    // disabled.
                                    style: IconButton.styleFrom(
                                      backgroundColor:
                                          context.syblColors.accentFill,
                                      foregroundColor: context.syblColors
                                          .foregroundFor(
                                            context.syblColors.accentFill,
                                            preferred: Colors.black,
                                          ),
                                      disabledBackgroundColor:
                                          context.syblColors.surfaceTop,
                                      disabledForegroundColor:
                                          context.syblColors.faint,
                                    ),
                                    icon: const Icon(Icons.mic_rounded),
                                  ),
                                )
                              else
                                Gravity(
                                  child: IconButton.filled(
                                    key: const ValueKey('send-chat-button'),
                                    tooltip: 'Send message (Enter)',
                                    onPressed:
                                        _canSend &&
                                            (commandQuery.isSendableText ||
                                                exactCommand ||
                                                (_controller.text
                                                        .trim()
                                                        .isEmpty &&
                                                    _draft?.media != null))
                                        ? () => _send(owner)
                                        : null,
                                    style: IconButton.styleFrom(
                                      fixedSize: Size.square(
                                        windowCompact ? 32 : 48,
                                      ),
                                      minimumSize: Size.square(
                                        windowCompact ? 32 : 48,
                                      ),
                                      padding: EdgeInsets.zero,
                                      tapTargetSize: compact && !windowCompact
                                          ? MaterialTapTargetSize.padded
                                          : MaterialTapTargetSize.shrinkWrap,
                                      backgroundColor:
                                          context.syblColors.accentFill,
                                      foregroundColor: context.syblColors
                                          .foregroundFor(
                                            context.syblColors.accentFill,
                                            preferred: Colors.black,
                                          ),
                                      disabledBackgroundColor:
                                          context.syblColors.surfaceTop,
                                      disabledForegroundColor:
                                          context.syblColors.faint,
                                    ),
                                    icon:
                                        _submitting || state.sendingChatMessage
                                        ? SizedBox.square(
                                            dimension: 17,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: context.syblColors
                                                  .foregroundFor(
                                                    context
                                                        .syblColors
                                                        .accentFill,
                                                    preferred: Colors.black,
                                                  ),
                                            ),
                                          )
                                        : Icon(
                                            exactCommand
                                                ? Icons.check_rounded
                                                : Icons.arrow_upward_rounded,
                                            key: exactCommand
                                                ? const ValueKey(
                                                    'composer-command-submit',
                                                  )
                                                : null,
                                            size: 19,
                                            color: _canSend
                                                ? context.syblColors
                                                      .foregroundFor(
                                                        context
                                                            .syblColors
                                                            .accentFill,
                                                        preferred: Colors.black,
                                                      )
                                                : context.syblColors.faint,
                                          ),
                                  ),
                                ),
                            ],
                          ),
                        if (_pickerOpen)
                          SizedBox(
                            height: 200,
                            child: ComposerPicker(
                              gifLibrary: state.gifLibrary,
                              gifRevision: _draft?.media,
                              onStarterGif: fileEnabled
                                  ? (entry) => _pickFile(
                                      owner,
                                      gif: true,
                                      starterGif: entry,
                                    )
                                  : null,
                              onGif: fileEnabled
                                  ? (hash) => _pickFile(
                                      owner,
                                      gif: true,
                                      libraryHash: hash,
                                    )
                                  : null,
                              onSticker: (sticker) =>
                                  _chooseSticker(owner, sticker),
                              onEmoji: (emoji) => _chooseEmoji(owner, emoji),
                              onImportGif: fileEnabled
                                  ? () => _pickFile(owner, gif: true)
                                  : null,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  // Align with the field after the picker and attachment controls.
                  left: (compact ? 66 : 60) + (mobile ? 0 : 48),
                  right: compact ? 18 : 14,
                  top: -22,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: IgnorePointer(
                      child: AnimatedSwitcher(
                        duration: motionDuration,
                        reverseDuration: motionDuration,
                        transitionBuilder: (child, animation) {
                          final faded = FadeTransition(
                            opacity: animation,
                            child: child,
                          );
                          if (motionDuration == Duration.zero) return faded;
                          return SlideTransition(
                            position:
                                Tween<Offset>(
                                  begin: const Offset(0, .35),
                                  end: Offset.zero,
                                ).animate(
                                  CurvedAnimation(
                                    parent: animation,
                                    curve: Curves.easeOutCubic,
                                  ),
                                ),
                            child: faded,
                          );
                        },
                        child: activityText == null
                            ? const SizedBox(
                                key: ValueKey('remote-composer-idle'),
                                height: 18,
                              )
                            : Semantics(
                                key: ValueKey('remote-composer-$activity'),
                                liveRegion: true,
                                label: activityText,
                                child: Gravity(
                                  child: Text(
                                    activityText,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: context.syblColors.muted,
                                      fontSize: 11.5,
                                    ),
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
        ),
      ),
    );
  }
}

class _ComposerCommandPopup extends StatelessWidget {
  const _ComposerCommandPopup({
    required this.results,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<ComposerResult> results;
  final int selectedIndex;
  final ValueChanged<ComposerResult> onSelected;

  @override
  Widget build(BuildContext context) => Material(
    key: const ValueKey('composer-command-popup'),
    color: context.syblColors.surfaceTop,
    elevation: 8,
    borderRadius: BorderRadius.circular(12),
    clipBehavior: Clip.antiAlias,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 220),
      child: ListView.builder(
        padding: const EdgeInsets.all(4),
        shrinkWrap: true,
        itemCount: results.length,
        itemBuilder: (context, index) {
          final result = results[index];
          return InkWell(
            key: ValueKey('composer-command-result-$index'),
            onTap: () => onSelected(result),
            borderRadius: BorderRadius.circular(9),
            child: Container(
              height: 42,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: index == selectedIndex
                    ? context.syblColors.surfaceHi
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Row(
                children: [
                  if (result.showActionIcon) ...[
                    Gravity(
                      child: Icon(
                        switch (result.kind) {
                          ComposerResultKind.createTopic => Icons.add_rounded,
                          ComposerResultKind.gravity =>
                            Icons.vertical_align_bottom_rounded,
                          _ => Icons.edit_outlined,
                        },
                        key: const ValueKey('composer-command-action-icon'),
                        size: 18,
                        color: context.syblColors.amber,
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Gravity(
                      child: Text(
                        result.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                  if (result.description.isNotEmpty) ...[
                    const SizedBox(width: 12),
                    Flexible(
                      flex: 2,
                      child: Gravity(
                        child: Text(
                          result.description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: context.syblColors.muted,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                  ],
                  if (result.showChatIdentity) ...[
                    const SizedBox(width: 12),
                    SyblAvatar(
                      label: result.chatDisplayName,
                      size: 22,
                      imageBase64: result.avatarBase64,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Gravity(
                        child: Text(
                          result.chatDisplayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: context.syblColors.muted,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    ),
  );
}

/// Two deliberately different shapes, per the founder's 2026-07-28 direction.
///
/// Consecutive text and files from the same author inside the time window
/// share one avatar/name header and one trailing time.
const Duration _messageGroupWindow = Duration(minutes: 5);

bool _sameMessageGroup(Object earlier, Object later, AppState state) =>
    _timelineDirection(earlier) == _timelineDirection(later) &&
    _timelineAuthor(earlier, state) == _timelineAuthor(later, state) &&
    _timelineCreatedAt(later).difference(_timelineCreatedAt(earlier)).abs() <=
        _messageGroupWindow;

class _SessionDivider extends StatelessWidget {
  const _SessionDivider({required this.at});

  final DateTime at;

  @override
  Widget build(BuildContext context) {
    final local = at.toLocal();
    final now = DateTime.now();
    final today =
        local.year == now.year &&
        local.month == now.month &&
        local.day == now.day;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Center(
        child: Gravity(
          child: Text(
            '${today ? 'Today ' : ''}${_formatTime(at)}',
            style: TextStyle(color: context.syblColors.faint, fontSize: 11),
          ),
        ),
      ),
    );
  }
}

TimelineDirection _timelineDirection(Object item) => switch (item) {
  ConversationTimelineItem value => value.direction,
  FileXfer value =>
    value.outgoing ? TimelineDirection.outgoing : TimelineDirection.incoming,
  FolderFile value =>
    value.outgoing ? TimelineDirection.outgoing : TimelineDirection.incoming,
  _ => TimelineDirection.incoming,
};

String _timelineAuthor(Object item, AppState state) => switch (item) {
  ConversationTimelineItem value => value.authorId,
  FileXfer value when value.authorId.isNotEmpty => value.authorId,
  FileXfer value => value.outgoing ? state.jamiId : value.peerId,
  FolderFile value when value.authorId.isNotEmpty => value.authorId,
  FolderFile value => value.outgoing ? state.jamiId : value.peerId,
  _ => '',
};

DateTime _timelineCreatedAt(Object item) => switch (item) {
  ConversationTimelineItem value => value.createdAt,
  FileXfer value => value.createdAt,
  FolderFile value => DateTime.fromMillisecondsSinceEpoch(
    value.timestamp * 1000,
    isUtc: true,
  ),
  _ => DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
};

String _timelineItemId(Object item, AppState state) => switch (item) {
  TimelineTextItem value => value.daemonId,
  TimelineFileItem value => 'file:${value.authorId}:${value.fileId}',
  TimelineDmTopicEventItem value => 'topic-event:${value.daemonId}',
  TimelineStickerItem value => value.daemonId,
  FileXfer value => 'file:${_timelineAuthor(value, state)}:${value.fileId}',
  FolderFile value => 'file:${_timelineAuthor(value, state)}:${value.fileId}',
  _ => 'unknown',
};

/// How long a new message takes to land, and how it eases in.
const _arriveMs = 220;
const _arriveCurve = Curves.easeOutCubic;

final class _MessageEntry {
  _MessageEntry(this.motion, {required double settle})
    : arrive = CurvedAnimation(
        parent: motion,
        curve: Interval(0, settle, curve: _arriveCurve),
      ),
      stream = settle < 1
          ? CurvedAnimation(parent: motion, curve: Interval(settle, 1))
          : null;

  final AnimationController motion;

  /// Lands the message while the list glides up to make room.
  final CurvedAnimation arrive;

  /// Then reveals its text letter by letter, if it streams.
  final CurvedAnimation? stream;

  void dispose() {
    arrive.dispose();
    stream?.dispose();
    motion.dispose();
  }
}

/// A new message rises a little and fades in while the slot it opens grows
/// from the bottom, so everything above glides up by its height instead of
/// jumping.
class _ChatEntryMotion extends AnimatedWidget {
  const _ChatEntryMotion({
    super.key,
    required Animation<double> arrive,
    required this.child,
  }) : super(listenable: arrive);

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = (listenable as Animation<double>).value;
    return ClipRect(
      clipper: const _ClipAbove(),
      child: Align(
        alignment: Alignment.bottomCenter,
        widthFactor: 1,
        heightFactor: t,
        child: Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, 14 * (1 - t)),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Clips only what sticks out above the growing slot.
class _ClipAbove extends CustomClipper<Rect> {
  const _ClipAbove();

  @override
  Rect getClip(Size size) =>
      Rect.fromLTRB(-size.width, 0, size.width * 2, size.height + 64);

  @override
  bool shouldReclip(_ClipAbove oldClipper) => false;
}

class _StreamingText extends StatelessWidget {
  const _StreamingText({
    required this.messageId,
    required this.text,
    required this.style,
    this.progress,
    this.trailing,
    this.contextMenuBuilder,
  });

  final String messageId;
  final String text;
  final TextStyle style;

  /// Reveals the text while it keeps its full size, so the bubble never grows
  /// under it. Without it the text plays out on its own and grows.
  final Animation<double>? progress;
  final InlineSpan? trailing;
  final EditableTextContextMenuBuilder? contextMenuBuilder;

  @override
  Widget build(BuildContext context) {
    final graphemes = text.characters;
    Widget shown(int count, {required bool sized}) {
      final visible = graphemes.take(count).toString();
      final hidden = sized ? graphemes.skip(count).toString() : '';
      final rendered = trailing == null && hidden.isEmpty
          ? SelectableText(
              visible,
              style: style,
              contextMenuBuilder: contextMenuBuilder,
            )
          : SelectableText.rich(
              TextSpan(
                style: style,
                children: [
                  TextSpan(text: visible),
                  if (hidden.isNotEmpty)
                    TextSpan(
                      text: hidden,
                      style: const TextStyle(color: Colors.transparent),
                    ),
                  ?trailing,
                ],
              ),
              contextMenuBuilder: contextMenuBuilder,
            );
      return count == graphemes.length
          ? rendered
          : Semantics(label: text, excludeSemantics: true, child: rendered);
    }

    final progress = this.progress;
    if (progress != null) {
      return AnimatedBuilder(
        key: ValueKey('streaming-text:$messageId'),
        animation: progress,
        builder: (context, _) =>
            shown((graphemes.length * progress.value).floor(), sized: true),
      );
    }
    return TweenAnimationBuilder<int>(
      key: ValueKey('streaming-text:$messageId'),
      tween: IntTween(begin: 0, end: graphemes.length),
      duration: Duration(
        milliseconds: (graphemes.length * 24).clamp(180, 1600),
      ),
      builder: (context, count, _) => shown(count, sized: false),
    );
  }
}

/// Any item from the other author, or beyond the window, starts a new block.
class _ReplyPreview extends StatelessWidget {
  const _ReplyPreview({
    required this.state,
    required this.target,
    this.onCancel,
  });

  final AppState state;
  final ConversationTimelineItem? target;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final item = target;
    final group = state.selectedGroup;
    final friend = state.selectedFriend;
    final author = item == null
        ? 'Reply'
        : item.direction == TimelineDirection.outgoing
        ? 'You'
        : group != null
        ? groupMemberLabel(state, group, item.authorId)
        : friend == null
        ? 'Message'
        : friendLabel(friend);
    final preview = switch (item) {
      TimelineTextItem text =>
        text.scope.isGroup ? GroupTopicCodec.decode(text.text).body : text.text,
      TimelineFileItem file => file.displayName,
      TimelineStickerItem _ => 'Sticker',
      _ => 'Message unavailable',
    };
    return Container(
      key: const ValueKey('reply-preview'),
      constraints: const BoxConstraints(maxWidth: 520),
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: context.syblColors.amber, width: 3),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Gravity(
                  child: Text(
                    item == null ? 'Reply' : 'Replying to $author',
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                ),
                Gravity(
                  child: Text(
                    preview,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: context.syblColors.muted,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (onCancel != null)
            Gravity(
              child: IconButton(
                tooltip: 'Cancel reply',
                onPressed: onCancel,
                icon: const Icon(Icons.close, size: 18),
              ),
            ),
        ],
      ),
    );
  }
}

const _reactionLabels = ['Like', 'Love', 'Laugh', 'Surprised', 'Sad', 'Thanks'];

Future<void> _chooseReaction(
  BuildContext context,
  AppState state,
  ConversationTimelineItem target,
  Object owner,
) async {
  final current = state.replyTargetById(target.daemonId);
  if (state.conversationActionOwner != owner ||
      current == null ||
      current.scope != target.scope ||
      current.versionId != target.versionId) {
    return;
  }
  final author = JamiIdentity.fingerprint(state.jamiId);
  final available = current.reactions.complete && !state.reactionBusy(current);
  final selected = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Gravity(child: Text('React')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (var i = 0; i < ReactionWire.palette.length; i++)
                Gravity(
                  child: Semantics(
                    label: _reactionLabels[i],
                    child: FilterChip(
                      label: Text(
                        ReactionWire.palette[i],
                        style: const TextStyle(fontSize: 24),
                      ),
                      selected: current.reactions.entries.any(
                        (entry) =>
                            entry.authorId == author &&
                            entry.emoji == ReactionWire.palette[i],
                      ),
                      onSelected: available
                          ? (_) =>
                                Navigator.pop(context, ReactionWire.palette[i])
                          : null,
                    ),
                  ),
                ),
            ],
          ),
          if (!available)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Gravity(
                child: Text(
                  current.reactions.complete
                      ? 'A reaction is still waiting for confirmation.'
                      : 'Some reactions are not loaded yet. Refresh the conversation to try again.',
                ),
              ),
            ),
        ],
      ),
      actions: [
        Gravity(
          child: TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ),
      ],
    ),
  );
  if (selected != null) {
    await state.toggleReaction(target, selected, owner: owner);
  }
}

class _ReactionCounts extends StatelessWidget {
  const _ReactionCounts({
    required this.state,
    required this.item,
    required this.owner,
  });
  final AppState state;
  final ConversationTimelineItem item;
  final Object owner;

  @override
  Widget build(BuildContext context) {
    final author = JamiIdentity.fingerprint(state.jamiId);
    return Wrap(
      spacing: 5,
      runSpacing: 2,
      children: [
        for (var i = 0; i < ReactionWire.palette.length; i++)
          if (item.reactions.count(ReactionWire.palette[i]) > 0)
            Gravity(
              child: Tooltip(
                message: _reactionLabels[i],
                child: FilterChip(
                  label: Text(
                    '${ReactionWire.palette[i]} ${item.reactions.count(ReactionWire.palette[i])}${item.reactions.complete ? '' : '+'}',
                  ),
                  selected: item.reactions.entries.any(
                    (entry) =>
                        entry.authorId == author &&
                        entry.emoji == ReactionWire.palette[i],
                  ),
                  onSelected:
                      item.reactions.complete && !state.reactionBusy(item)
                      ? (_) => unawaited(
                          state.toggleReaction(
                            item,
                            ReactionWire.palette[i],
                            owner: owner,
                          ),
                        )
                      : null,
                ),
              ),
            ),
        if (!item.reactions.complete)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Gravity(child: Text('More reactions may be available')),
          ),
      ],
    );
  }
}

enum _MessageAction { reply, react, copy }

class _MessageActions extends StatefulWidget {
  const _MessageActions({
    super.key,
    required this.child,
    required this.onReply,
    required this.onReact,
    this.onCopy,
    required this.textSelection,
  });

  final Widget child;
  final VoidCallback onReply;
  final VoidCallback onReact;
  final VoidCallback? onCopy;
  final bool textSelection;

  @override
  State<_MessageActions> createState() => _MessageActionsState();
}

class _MessageActionsState extends State<_MessageActions> {
  final _anchor = GlobalKey();
  bool _focused = false;
  bool _openMenu = false;

  Future<void> _open() async {
    if (_openMenu) return;
    final box = _anchor.currentContext?.findRenderObject();
    final overlay = Overlay.of(context).context.findRenderObject();
    if (box is! RenderBox || overlay is! RenderBox) return;
    final reply = widget.onReply;
    final react = widget.onReact;
    final copy = widget.onCopy;
    _openMenu = true;
    try {
      final action = await showMenu<_MessageAction>(
        context: context,
        position: RelativeRect.fromRect(
          Rect.fromPoints(
            box.localToGlobal(Offset.zero, ancestor: overlay),
            box.localToGlobal(
              box.size.bottomRight(Offset.zero),
              ancestor: overlay,
            ),
          ),
          Offset.zero & overlay.size,
        ),
        items: [
          const PopupMenuItem(
            value: _MessageAction.reply,
            child: Text('Reply'),
          ),
          const PopupMenuItem(
            value: _MessageAction.react,
            child: Text('React'),
          ),
          if (copy != null)
            const PopupMenuItem(
              value: _MessageAction.copy,
              child: Text('Copy'),
            ),
        ],
      );
      if (!mounted) return;
      switch (action) {
        case _MessageAction.reply:
          reply();
        case _MessageAction.react:
          react();
        case _MessageAction.copy:
          copy?.call();
        case null:
          break;
      }
    } finally {
      _openMenu = false;
    }
  }

  @override
  Widget build(BuildContext context) => Focus(
    onFocusChange: (focused) => setState(() => _focused = focused),
    onKeyEvent: (_, event) {
      if (event is KeyDownEvent &&
          (event.logicalKey == LogicalKeyboardKey.contextMenu ||
              (event.logicalKey == LogicalKeyboardKey.f10 &&
                  HardwareKeyboard.instance.isShiftPressed))) {
        unawaited(_open());
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: Semantics(
      customSemanticsActions: {
        const CustomSemanticsAction(label: 'Message actions'): _open,
      },
      child: GestureDetector(
        onSecondaryTap: _open,
        onLongPress: widget.textSelection ? null : _open,
        child: Container(
          key: _anchor,
          foregroundDecoration: BoxDecoration(
            border: Border.all(
              color: _focused ? context.syblColors.amber : Colors.transparent,
            ),
            borderRadius: BorderRadius.circular(14),
          ),
          child: widget.child,
        ),
      ),
    ),
  );
}

class _MessageBlock extends StatelessWidget {
  const _MessageBlock({
    required this.items,
    required this.state,
    required this.localFiles,
    required this.animatedItemIds,
    required this.entering,
    required this.blockEntering,
    required this.showReceipt,
    required this.showAuthor,
    this.group,
    this.textFor,
  });

  final List<Object> items;
  final AppState state;
  final GroupState? group;
  final String Function(TimelineTextItem)? textFor;
  final Map<({String ownerId, String fileId}), FolderFile> localFiles;
  final Set<String> animatedItemIds;
  final Map<String, _MessageEntry> entering;

  /// The whole block is entering as one, not item by item.
  final bool blockEntering;
  final bool showReceipt;
  final bool showAuthor;

  @override
  Widget build(BuildContext context) {
    final outgoing =
        _timelineDirection(items.first) == TimelineDirection.outgoing;
    return Semantics(
      container: true,
      label: outgoing ? 'Sent by you' : 'Sent to you',
      child: outgoing ? _outgoing(context) : _incoming(context),
    );
  }

  Widget _outgoing(BuildContext context) {
    final name = state.displayName.trim().isEmpty ? 'You' : state.displayName;
    return Align(
      alignment: Alignment.centerRight,
      child: Padding(
        // Discord-like rhythm: tight lines inside a block, clear air between
        // speaker blocks.
        padding: EdgeInsets.only(
          bottom: WindowPresentationScope.isCompact(context) ? 8 : 16,
          left: WindowPresentationScope.isCompact(context) ? 10 : 48,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (showAuthor &&
                      !WindowPresentationScope.isCompact(context)) ...[
                    _authorHeader(context, name, outgoing: true),
                    const SizedBox(height: 4),
                  ],
                  for (var index = 0; index < items.length - 1; index++)
                    _motionContent(context, index, outgoing: true),
                  _lastContentWithTimestamp(context, outgoing: true),
                ],
              ),
            ),
            if (!WindowPresentationScope.isCompact(context)) ...[
              const SizedBox(width: 10),
              if (showAuthor)
                SyblAvatar(
                  label: name,
                  size: 34,
                  imageBase64: state.profileAvatarBase64,
                  color: context.syblColors.amber,
                )
              else
                const SizedBox(width: 34),
            ],
          ],
        ),
      ),
    );
  }

  Widget _incoming(BuildContext context) {
    final friend = state.selectedFriend;
    final authorId = group == null ? null : _timelineAuthor(items.first, state);
    final name = authorId == null
        ? friend == null
              ? 'Them'
              : friendLabel(friend)
        : groupMemberLabel(state, group!, authorId);
    final imageBase64 = authorId == null
        ? friend?.avatarBase64
        : groupMemberAvatar(state, group!, authorId);
    return Padding(
      padding: EdgeInsets.only(
        bottom: WindowPresentationScope.isCompact(context) ? 8 : 16,
        right: WindowPresentationScope.isCompact(context) ? 10 : 48,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!WindowPresentationScope.isCompact(context)) ...[
            if (showAuthor)
              SyblAvatar(
                label: name,
                size: 34,
                imageBase64: imageBase64,
                color: group == null ? null : context.syblColors.sage,
              )
            else
              const SizedBox(width: 34),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (showAuthor) ...[
                  _authorHeader(context, name, outgoing: false),
                  const SizedBox(height: 4),
                ],
                Align(
                  alignment: Alignment.centerLeft,
                  child: IntrinsicWidth(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var index = 0; index < items.length - 1; index++)
                          _motionContent(context, index, outgoing: false),
                        _lastContentWithTimestamp(context, outgoing: false),
                      ],
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

  Widget _lastContentWithTimestamp(
    BuildContext context, {
    required bool outgoing,
  }) {
    final alignment = outgoing ? Alignment.centerRight : Alignment.centerLeft;
    final content = _motionContent(
      context,
      items.length - 1,
      outgoing: outgoing,
    );
    final style = state.messageTimestampStyle;
    if (style == MessageTimestampStyle.whatsapp) {
      if (items.last is TimelineTextItem) {
        return Align(alignment: alignment, child: content);
      }
      return Align(
        alignment: alignment,
        child: Column(
          crossAxisAlignment: outgoing
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            content,
            const SizedBox(height: 3),
            _messageMeta(context, outgoing: outgoing),
          ],
        ),
      );
    }
    if (style == MessageTimestampStyle.below ||
        style == MessageTimestampStyle.messenger ||
        style == MessageTimestampStyle.apple ||
        style == MessageTimestampStyle.discord) {
      final sessionOnly =
          style == MessageTimestampStyle.messenger ||
          style == MessageTimestampStyle.apple;
      final receiptOnly = style == MessageTimestampStyle.discord || sessionOnly;
      return Align(
        alignment: alignment,
        child: Column(
          crossAxisAlignment: outgoing
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            content,
            if (!sessionOnly || (outgoing && showReceipt)) ...[
              const SizedBox(height: 3),
              receiptOnly
                  ? _receipt(context)
                  : _messageMeta(context, outgoing: outgoing),
            ],
          ],
        ),
      );
    }
    final meta = _messageMeta(context, outgoing: outgoing);
    if (MediaQuery.textScalerOf(context).scale(1) > 1.3) {
      return Align(
        alignment: alignment,
        child: Column(
          crossAxisAlignment: outgoing
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            content,
            const SizedBox(height: 3),
            Align(
              alignment: outgoing
                  ? Alignment.centerLeft
                  : Alignment.centerRight,
              child: meta,
            ),
          ],
        ),
      );
    }
    return Align(
      alignment: alignment,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: outgoing
            ? [meta, const SizedBox(width: 7), Flexible(child: content)]
            : [Flexible(child: content), const SizedBox(width: 7), meta],
      ),
    );
  }

  Widget _authorHeader(
    BuildContext context,
    String name, {
    required bool outgoing,
  }) {
    final nameWidget = Flexible(
      child: Gravity(
        child: Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.syblColors.display.copyWith(fontSize: 13.5),
        ),
      ),
    );
    final time = _timestamp(context, _timelineCreatedAt(items.first));
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: state.messageTimestampStyle != MessageTimestampStyle.discord
          ? [nameWidget]
          : outgoing
          ? [time, const SizedBox(width: 7), nameWidget]
          : [nameWidget, const SizedBox(width: 7), time],
    );
  }

  Widget _motionContent(
    BuildContext context,
    int index, {
    required bool outgoing,
  }) {
    final item = items[index];
    final id = _timelineItemId(item, state);
    final body = _content(context, index, outgoing: outgoing);
    final previewed =
        item is ConversationTimelineItem && item.replyTo.isNotEmpty
        ? Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _ReplyPreview(state: state, target: state.replyTargetFor(item)),
              body,
            ],
          )
        : body;
    final owner = state.conversationActionOwner;
    final content = item is ConversationTimelineItem
        ? _MessageActions(
            key: ValueKey(('message-actions', item.scope, item.daemonId)),
            textSelection: item is TimelineTextItem,
            onReply: () => state.beginReply(item, owner: owner),
            onReact: () =>
                unawaited(_chooseReaction(context, state, item, owner)),
            onCopy: item is TimelineTextItem
                ? () {
                    final current = state.replyTargetById(item.daemonId);
                    if (state.conversationActionOwner != owner ||
                        current is! TimelineTextItem ||
                        current.versionId != item.versionId) {
                      return;
                    }
                    unawaited(
                      Clipboard.setData(
                        ClipboardData(
                          text: current.scope.isGroup
                              ? GroupTopicCodec.decode(current.text).body
                              : current.text,
                        ),
                      ),
                    );
                  }
                : null,
            child: item.reactions.entries.isEmpty && item.reactions.complete
                ? previewed
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      previewed,
                      _ReactionCounts(state: state, item: item, owner: owner),
                    ],
                  ),
          )
        : previewed;
    return switch (entering[id]) {
      final entry? when !blockEntering => _ChatEntryMotion(
        key: ValueKey('chat-entry-motion:$id'),
        arrive: entry.arrive,
        child: content,
      ),
      _ => content,
    };
  }

  Widget _content(BuildContext context, int index, {required bool outgoing}) {
    final item = items[index];
    final first = index == 0;
    final last = index == items.length - 1;
    return switch (item) {
      // Topic messages share the DM bubble — bare text lines read as broken
      // next to every other conversation surface.
      TimelineTextItem text => _textBubble(
        context,
        text,
        first: first,
        last: last,
        outgoing: outgoing,
        // Entering incoming text streams; under gravity nothing enters here,
        // and new text plays out on its own.
        stream: switch (entering[text.daemonId]) {
          _? => !outgoing,
          null => animatedItemIds.contains(text.daemonId),
        },
        textOverride: group == null ? null : textFor?.call(text),
      ),
      TimelineFileItem file => _timelineFileCard(
        file,
        first: first,
        last: last,
      ),
      TimelineStickerItem sticker => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Gravity(child: StickerImage(assetId: sticker.sticker?.assetId)),
      ),
      FolderFile file => _folderFileCard(file, first: first, last: last),
      FileXfer transfer => _transferCard(
        context,
        transfer,
        first: first,
        last: last,
      ),
      _ => const SizedBox.shrink(),
    };
  }

  Widget _textBubble(
    BuildContext context,
    TimelineTextItem item, {
    required bool first,
    required bool last,
    required bool outgoing,
    required bool stream,
    String? textOverride,
  }) {
    const outer = Radius.circular(14);
    const joined = Radius.circular(5);
    final appleTail =
        last && state.messageTimestampStyle == MessageTimestampStyle.apple;
    final value = textOverride ?? item.text;
    final owner = state.conversationActionOwner;
    Widget messageMenu(BuildContext context, EditableTextState editable) {
      return AdaptiveTextSelectionToolbar.buttonItems(
        anchors: editable.contextMenuAnchors,
        buttonItems: [
          ContextMenuButtonItem(
            label: 'Reply',
            onPressed: () {
              editable.hideToolbar();
              state.beginReply(item, owner: owner);
            },
          ),
          ContextMenuButtonItem(
            label: 'React',
            onPressed: () {
              editable.hideToolbar();
              unawaited(_chooseReaction(context, state, item, owner));
            },
          ),
          ...editable.contextMenuButtonItems,
        ],
      );
    }

    final style = _messageTextStyle(context);
    final inlineMeta =
        last && state.messageTimestampStyle == MessageTimestampStyle.whatsapp;
    final meta = inlineMeta
        ? WidgetSpan(
            alignment: PlaceholderAlignment.bottom,
            child: Padding(
              padding: const EdgeInsets.only(left: 7, top: 2),
              child: _messageMeta(context, outgoing: outgoing, inline: true),
            ),
          )
        : null;
    final entry = entering[item.daemonId];
    Widget still(TextStyle style) => meta == null
        ? SelectableText(value, style: style, contextMenuBuilder: messageMenu)
        : SelectableText.rich(
            TextSpan(
              style: style,
              children: [
                TextSpan(text: value),
                meta,
              ],
            ),
            contextMenuBuilder: messageMenu,
          );
    final text = stream
        ? _StreamingText(
            messageId: item.daemonId,
            text: value,
            style: style,
            progress: entry?.stream,
            trailing: meta,
            contextMenuBuilder: messageMenu,
          )
        : still(style);
    const padding = EdgeInsets.symmetric(horizontal: 13, vertical: 9);
    final border = Border.all(color: context.syblColors.line);
    final marginBottom = last ? 0.0 : 2.0;
    final decoration = BoxDecoration(
      color: outgoing
          ? context.syblColors.surfaceTop
          : context.syblColors.surfaceHi,
      border: border,
      borderRadius: BorderRadius.only(
        topLeft: first ? outer : joined,
        topRight: first ? outer : joined,
        bottomLeft: appleTail && !outgoing
            ? const Radius.circular(2)
            : (last ? outer : joined),
        bottomRight: appleTail && outgoing
            ? const Radius.circular(2)
            : (last ? outer : joined),
      ),
    );
    final bubble = Container(
      key: ValueKey('message-bubble-${item.daemonId}'),
      constraints: const BoxConstraints(maxWidth: 520),
      margin: EdgeInsets.only(bottom: marginBottom),
      padding: padding,
      decoration: decoration,
      child: text,
    );
    return Gravity(
      // Keeps one body while the list regroups and rewraps the bubble.
      key: GravityKey(('message', item.scope, item.daemonId)),
      // Own messages squeeze out of the composer; others drop in from above.
      entry: outgoing ? GravityEntry.fromComposer : GravityEntry.fromAbove,
      child: bubble,
    );
  }

  TextStyle _messageTextStyle(BuildContext context) =>
      TextStyle(color: context.syblColors.ink, fontSize: 13.5, height: 1.45);

  Widget _timelineFileCard(
    TimelineFileItem item, {
    required bool first,
    required bool last,
  }) {
    final outgoing = item.direction == TimelineDirection.outgoing;
    final local = localFiles[(ownerId: item.authorId, fileId: item.fileId)];
    final transfer =
        state.transfers[transferKey(
          item.scope.peerId,
          item.scope.conversationId,
          item.fileId,
        )];
    final downloaded =
        item.downloaded ||
        local?.downloaded == true ||
        transfer?.status == XferStatus.finished;
    final path = transfer?.status == XferStatus.finished
        ? transfer?.path ?? local?.path
        : local?.path;
    final media = item.media;
    final owner = state.conversationActionOwner;
    return _AttachmentCard(
      key: ValueKey('attachment:${item.authorId}:${item.fileId}'),
      state: state,
      peerId: item.scope.peerId,
      conversationId: item.scope.conversationId,
      fileId: item.fileId,
      name: item.displayName,
      path: path,
      subtitle: item.totalBytes == null ? '' : _formatBytes(item.totalBytes!),
      outgoing: outgoing,
      first: first,
      last: last,
      allowAudio: media == null,
      preview: media is VoiceMediaContent
          ? const Gravity(
              child: SizedBox.square(dimension: 42, child: Icon(Icons.mic)),
            )
          : media is GifMediaContent
          ? downloaded && path != null
                ? Gravity(
                    child: BoundedGif(
                      key: ValueKey('gif:${item.daemonId}:$path'),
                      path: path,
                      size: 42,
                      isCurrent: () =>
                          state.canPlayMessageMedia &&
                          state.conversationActionOwner == owner,
                      validate: () => state.validateTimelineMedia(item, path),
                    ),
                  )
                : const Gravity(
                    child: SizedBox.square(
                      dimension: 42,
                      child: Icon(Icons.gif),
                    ),
                  )
          : null,
      footer: item.mayContainGif && downloaded && !outgoing && path != null
          ? _SaveReceivedGifButton(
              key: ValueKey('save-gif:${item.scope}:${item.daemonId}:$path'),
              state: state,
              item: item,
              path: path,
            )
          : media is VoiceMediaContent && downloaded && path != null
          ? VoiceReviewPlayer(
              key: ValueKey('voice:${item.scope}:${item.daemonId}:$path'),
              path: path,
              duration: Duration(milliseconds: media.durationMilliseconds),
              isCurrent: () =>
                  state.canPlayMessageMedia &&
                  state.conversationActionOwner == owner,
              validate: () => state.validateTimelineMedia(item, path),
            )
          : null,
      trailing: downloaded && !outgoing && media == null
          ? _OpenFileButton(name: item.displayName, path: path, state: state)
          : !downloaded && !outgoing
          ? _TransferIconButton(
              key: ValueKey('download-transfer:${item.fileId}'),
              tooltip: 'Download ${item.displayName}',
              icon: Icons.download_rounded,
              onPressed: state.appearOffline
                  ? null
                  : () => state.downloadTimelineFile(item),
            )
          : null,
    );
  }

  Widget _folderFileCard(
    FolderFile file, {
    required bool first,
    required bool last,
  }) => _AttachmentCard(
    key: ValueKey('attachment:${file.authorId}:${file.fileId}'),
    state: state,
    peerId: file.peerId,
    conversationId: file.conversationId,
    fileId: file.fileId,
    name: file.name,
    path: file.path,
    subtitle: _formatBytes(file.size),
    outgoing: file.outgoing,
    first: first,
    last: last,
    trailing: file.downloaded && !file.outgoing
        ? _OpenFileButton(name: file.name, path: file.path, state: state)
        : !file.outgoing
        ? _TransferIconButton(
            key: ValueKey('download-transfer:${file.fileId}'),
            tooltip: 'Download ${file.name}',
            icon: Icons.download_rounded,
            onPressed: state.appearOffline
                ? null
                : () => state.downloadFolderFile(file),
          )
        : null,
  );

  Widget _transferCard(
    BuildContext context,
    FileXfer transfer, {
    required bool first,
    required bool last,
  }) {
    final offered = transfer.status == XferStatus.offered;
    final progressing =
        transfer.status == XferStatus.ongoing ||
        transfer.status == XferStatus.canceling;
    final canCancel =
        !transfer.outgoing && transfer.status == XferStatus.ongoing;
    final actions = <Widget>[
      if (offered) ...[
        _TransferIconButton(
          key: ValueKey('decline-transfer:${transfer.fileId}'),
          tooltip: 'Decline file',
          icon: Icons.close_rounded,
          danger: true,
          onPressed: () => state.declineFile(transfer),
        ),
        const SizedBox(width: 4),
        _TransferIconButton(
          key: ValueKey('accept-transfer:${transfer.fileId}'),
          tooltip: 'Accept file',
          icon: Icons.check_rounded,
          onPressed: state.appearOffline
              ? null
              : () => state.acceptFile(transfer),
        ),
      ] else ...[
        // While bytes move, the subtitle + progress bar already narrate; a
        // second status icon next to the cancel button is noise.
        if ((transfer.outgoing || transfer.status != XferStatus.finished) &&
            !progressing)
          Gravity(
            child: Tooltip(
              message: _transferStatus(transfer),
              child: _TransferStatusIcon(transfer: transfer),
            ),
          ),
        if (transfer.status == XferStatus.finished && !transfer.outgoing)
          _OpenFileButton(
            name: transfer.name,
            path: transfer.path,
            state: state,
          ),
        if (canCancel)
          _TransferIconButton(
            key: ValueKey('cancel-transfer:${transfer.fileId}'),
            tooltip: 'Cancel transfer',
            icon: Icons.close_rounded,
            danger: true,
            onPressed: () => state.declineFile(transfer),
          ),
      ],
    ];
    return AnimatedSize(
      duration: state.chatMotionEnabled
          ? SyblMotion.duration(context)
          : Duration.zero,
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: _AttachmentCard(
        key: ValueKey('attachment:${transfer.authorId}:${transfer.fileId}'),
        state: state,
        peerId: transfer.peerId,
        conversationId: transfer.conversationId,
        fileId: transfer.fileId,
        name: transfer.name,
        path: transfer.path,
        previewBytes: transfer.previewBytes,
        subtitle: _transferStatus(transfer),
        outgoing: transfer.outgoing,
        first: first,
        last: last,
        trailing: Row(mainAxisSize: MainAxisSize.min, children: actions),
        footer: progressing
            ? Padding(
                padding: const EdgeInsets.only(top: 8),
                child: LinearProgressIndicator(
                  value: transfer.progress,
                  minHeight: 4,
                ),
              )
            : null,
      ),
    );
  }

  // [inline] marks the copy embedded in a text bubble, which already moves as
  // one piece.
  Widget _timestamp(
    BuildContext context,
    DateTime value, {
    bool inline = false,
  }) {
    final stamp = Tooltip(
      message: _formatExactTime(value),
      child: Text(
        _formatTime(value),
        style: TextStyle(color: context.syblColors.faint, fontSize: 10),
      ),
    );
    return inline ? stamp : Gravity(child: stamp);
  }

  Widget _messageMeta(
    BuildContext context, {
    required bool outgoing,
    bool inline = false,
  }) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      _timestamp(context, _timelineCreatedAt(items.last), inline: inline),
      if (outgoing && showReceipt) ...[
        const SizedBox(width: 4),
        _receipt(context, inline: inline),
      ],
    ],
  );

  Widget _receipt(BuildContext context, {bool inline = false}) {
    Widget piece(Widget child) => inline ? child : Gravity(child: child);
    if (!showReceipt || items.last is! ConversationTimelineItem) {
      return const SizedBox.shrink();
    }
    final delivery = (items.last as ConversationTimelineItem).deliveryState;
    if (group != null) {
      return piece(
        _GroupReceipt(
          delivery: delivery,
          readByMemberIds:
              (items.last as ConversationTimelineItem).readByMemberIds,
          activeMemberIds: group!.activeMemberIds,
          localAuthorId: state.jamiId,
        ),
      );
    }
    final read = delivery == TimelineDeliveryState.read;
    final label = switch (delivery) {
      TimelineDeliveryState.sent => 'Sent',
      TimelineDeliveryState.delivered => 'Delivered',
      TimelineDeliveryState.read => 'Read',
    };
    final friend = state.selectedFriend;
    if (read &&
        state.messageReceiptStyle == MessageReceiptStyle.messenger &&
        friend != null) {
      return Tooltip(
        message: label,
        child: Semantics(
          label: label,
          child: SyblAvatar(
            label: friendLabel(friend),
            imageBase64: friend.avatarBase64,
            size: 14,
          ),
        ),
      );
    }
    if (state.messageReceiptStyle == MessageReceiptStyle.messenger) {
      return piece(
        Tooltip(
          message: label,
          child: Semantics(
            label: label,
            child: _MessengerReceipt(delivery: delivery),
          ),
        ),
      );
    }
    final icon = switch (state.messageReceiptStyle) {
      // WhatsApp: ✓ sent · ✓✓ delivered · ✓✓ green read.
      MessageReceiptStyle.whatsapp =>
        delivery == TimelineDeliveryState.sent
            ? Icons.done_rounded
            : Icons.done_all_rounded,
      MessageReceiptStyle.sybl =>
        delivery == TimelineDeliveryState.sent
            ? Icons.north_east_rounded
            : Icons.multiple_stop_rounded,
      // Messenger is rendered by _MessengerReceipt above.
      MessageReceiptStyle.messenger => throw StateError('handled above'),
    };
    return piece(
      Tooltip(
        message: label,
        child: Semantics(
          label: label,
          child: Icon(
            icon,
            size: 14,
            color: read ? context.syblColors.online : context.syblColors.faint,
          ),
        ),
      ),
    );
  }
}

class _SaveReceivedGifButton extends StatefulWidget {
  const _SaveReceivedGifButton({
    super.key,
    required this.state,
    required this.item,
    required this.path,
  });
  final AppState state;
  final TimelineFileItem item;
  final String path;
  @override
  State<_SaveReceivedGifButton> createState() => _SaveReceivedGifButtonState();
}

class _SaveReceivedGifButtonState extends State<_SaveReceivedGifButton> {
  bool _saving = false;
  Future<void> _save() async {
    if (_saving) return;
    final state = widget.state;
    final owner = state.conversationActionOwner;
    setState(() => _saving = true);
    final result = await state.saveReceivedGif(widget.item, widget.path);
    if (!mounted) return;
    setState(() => _saving = false);
    if (!state.canPlayMessageMedia || owner != state.conversationActionOwner) {
      return;
    }
    final message = switch (result) {
      GifLibraryResult.saved => 'Saved to your GIFs',
      GifLibraryResult.alreadyBundled => 'Already available in Doorlight GIFs',
      GifLibraryResult.full =>
        'Your GIF library is full. Remove a GIF before saving another.',
      GifLibraryResult.unavailable =>
        'Your GIF library is unavailable. Try again later.',
      _ =>
        'This GIF is no longer available to save. Download it again and retry.',
    };
    showNotice(message);
  }

  @override
  Widget build(BuildContext context) => Gravity(
    child: TextButton.icon(
      onPressed: _saving || !widget.state.canPlayMessageMedia ? null : _save,
      icon: const Icon(Icons.add_photo_alternate_outlined),
      label: Text(_saving ? 'Saving GIF…' : 'Save to my GIFs'),
    ),
  );
}

class _GroupReceipt extends StatelessWidget {
  const _GroupReceipt({
    required this.delivery,
    required this.readByMemberIds,
    required this.activeMemberIds,
    required this.localAuthorId,
  });

  final TimelineDeliveryState delivery;
  final Set<String> readByMemberIds;
  final Set<String> activeMemberIds;
  final String localAuthorId;

  @override
  Widget build(BuildContext context) {
    final recipients = activeMemberIds
        .where((member) => member != localAuthorId)
        .toSet();
    final readCount = readByMemberIds.where(recipients.contains).length;
    final allRead = recipients.isNotEmpty && readCount == recipients.length;
    final label = readCount > 0
        ? 'Read by $readCount of ${recipients.length}'
        : delivery == TimelineDeliveryState.sent
        ? 'Sent'
        : 'Delivered';
    final hasTwoChecks = delivery != TimelineDeliveryState.sent;
    final receipt = SizedBox(
      key: const ValueKey('group-receipt'),
      width: readCount > 9 ? 26 : (readCount > 0 ? 22 : 16),
      height: 16,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: 0,
            top: 0,
            child: Icon(
              hasTwoChecks ? Icons.done_all_rounded : Icons.done_rounded,
              size: 16,
              color: allRead
                  ? context.syblColors.online
                  : context.syblColors.faint,
            ),
          ),
          if (readCount > 0)
            Positioned(
              left: 12,
              bottom: -1,
              child: Text(
                '$readCount',
                key: const ValueKey('group-receipt-count'),
                style: TextStyle(
                  color: context.syblColors.online,
                  fontSize: 8,
                  height: 1,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
        ],
      ),
    );
    return Tooltip(
      message: label,
      child: Semantics(label: label, child: receipt),
    );
  }
}

class _MessengerReceipt extends StatelessWidget {
  const _MessengerReceipt({required this.delivery});

  final TimelineDeliveryState delivery;

  @override
  Widget build(BuildContext context) {
    final checked = delivery != TimelineDeliveryState.sent;
    final filled = delivery == TimelineDeliveryState.read;
    return SizedBox.square(
      key: ValueKey('messenger-receipt-${delivery.name}'),
      dimension: 14,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Icon(
            filled ? Icons.circle_rounded : Icons.circle_outlined,
            size: 13,
            color: context.syblColors.faint,
          ),
          if (checked)
            Icon(
              Icons.check_rounded,
              size: 9,
              color: filled ? context.syblColors.bg : context.syblColors.faint,
            ),
        ],
      ),
    );
  }
}

String _formatExactTime(DateTime value) {
  final local = value.toLocal();
  String two(int part) => part.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

class _AttachmentCard extends StatelessWidget {
  const _AttachmentCard({
    super.key,
    required this.state,
    required this.peerId,
    required this.conversationId,
    required this.fileId,
    required this.name,
    required this.path,
    required this.subtitle,
    required this.outgoing,
    required this.first,
    required this.last,
    this.previewBytes,
    this.trailing,
    this.footer,
    this.allowAudio = true,
    this.preview,
  });

  final AppState state;
  final String peerId, conversationId, fileId;
  final String name;
  final String? path;
  final String subtitle;
  final bool outgoing;
  final bool first;
  final bool last;
  final Uint8List? previewBytes;
  final Widget? trailing;
  final Widget? footer;
  final bool allowAudio;
  final Widget? preview;

  @override
  Widget build(BuildContext context) {
    final owner = state.conversationActionOwner;
    const outer = Radius.circular(14);
    const joined = Radius.circular(5);
    return Container(
      constraints: const BoxConstraints(maxWidth: 400),
      margin: EdgeInsets.only(bottom: last ? 0 : 2),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: outgoing
            ? context.syblColors.surfaceTop
            : context.syblColors.surfaceHi,
        border: Border.all(color: context.syblColors.line),
        borderRadius: BorderRadius.only(
          topLeft: first ? outer : joined,
          topRight: first ? outer : joined,
          bottomLeft: last ? outer : joined,
          bottomRight: last ? outer : joined,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MediaQuery.textScalerOf(context).scale(1) > 1.3
                ? MainAxisSize.max
                : MainAxisSize.min,
            children: [
              preview ??
                  _FilePreview(
                    name: name,
                    path: path,
                    previewBytes: previewBytes,
                    size: 42,
                  ),
              const SizedBox(width: 9),
              Flexible(
                child: _FileIdentity(name: name, subtitle: subtitle),
              ),
              if (trailing != null) ...[const SizedBox(width: 6), trailing!],
            ],
          ),
          if (allowAudio &&
              _isAudioAttachment(name) &&
              _usableFile(path) != null)
            _AudioAttachmentPlayer(
              path: path!,
              isCurrent: () =>
                  state.canPlayMessageMedia &&
                  state.conversationActionOwner == owner,
              validate: () => state.validateCompletedAudio(
                peerId,
                conversationId,
                fileId,
                path!,
              ),
            ),
          ?footer,
        ],
      ),
    );
  }
}

class _TransferIconButton extends StatelessWidget {
  const _TransferIconButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.danger = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool danger;

  @override
  Widget build(BuildContext context) => Gravity(
    child: IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      style:
          IconButton.styleFrom(
            fixedSize: const Size.square(32),
            minimumSize: const Size.square(32),
            padding: EdgeInsets.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            foregroundColor: danger
                ? context.syblColors.danger
                : context.syblColors.amber,
            shape: context.syblColors.buttonShape,
            side: BorderSide(
              color:
                  (danger
                          ? context.syblColors.danger
                          : context.syblColors.amber)
                      .withValues(alpha: .58),
            ),
          ).merge(
            !danger && context.syblColors.neutralButtonFill != null
                ? context.syblColors.secondaryButtonStyle.copyWith(
                    minimumSize: const WidgetStatePropertyAll(Size.square(32)),
                  )
                : null,
          ),
      icon: Icon(icon, size: 18),
    ),
  );
}

class _TransferStatusIcon extends StatelessWidget {
  const _TransferStatusIcon({required this.transfer});

  final FileXfer transfer;

  @override
  Widget build(BuildContext context) {
    return switch (transfer.status) {
      XferStatus.waiting => Icon(
        Icons.schedule_rounded,
        key: const ValueKey('transfer-status-pending'),
        size: 19,
        color: context.syblColors.amber,
      ),
      XferStatus.ongoing => Icon(
        Icons.task_alt_rounded,
        key: const ValueKey('transfer-status-accepted'),
        size: 19,
        color: context.syblColors.amber,
      ),
      XferStatus.canceling => Icon(
        Icons.hourglass_top_rounded,
        key: const ValueKey('transfer-status-canceling'),
        size: 19,
        color: context.syblColors.muted,
      ),
      XferStatus.finished => Icon(
        Icons.check_circle_rounded,
        key: const ValueKey('transfer-status-complete'),
        size: 20,
        color: context.syblColors.online,
      ),
      XferStatus.declined => Icon(
        Icons.cancel_outlined,
        key: const ValueKey('transfer-status-declined'),
        size: 19,
        color: context.syblColors.danger,
      ),
      XferStatus.error => Icon(
        Icons.error_outline_rounded,
        key: const ValueKey('transfer-status-error'),
        size: 20,
        color: context.syblColors.danger,
      ),
      XferStatus.canceled => Icon(
        Icons.cancel_outlined,
        key: const ValueKey('transfer-status-canceled'),
        size: 19,
        color: context.syblColors.muted,
      ),
      XferStatus.offered => const SizedBox.shrink(),
    };
  }
}

class _FilePreview extends StatelessWidget {
  const _FilePreview({
    required this.name,
    required this.path,
    this.previewBytes,
    required this.size,
  });

  final String name;
  final String? path;
  final Uint8List? previewBytes;
  final double size;

  @override
  Widget build(BuildContext context) {
    final extension = name.split('.').last.toLowerCase();
    final image = const {
      'jpg',
      'jpeg',
      'png',
      'webp',
      'gif',
      'bmp',
    }.contains(extension);
    final fallback = DecoratedBox(
      decoration: BoxDecoration(
        color: context.syblColors.glowSoft,
        borderRadius: BorderRadius.circular(9),
      ),
      child: SizedBox.square(
        dimension: size,
        child: Icon(
          _fileIcon(extension),
          color: context.syblColors.amber,
          size: size * .52,
        ),
      ),
    );
    if (!image) return Gravity(child: fallback);
    return Gravity(
      child: BoundedAttachmentPreview(
        path: path,
        previewBytes: previewBytes,
        size: size,
        fallback: fallback,
      ),
    );
  }
}

IconData _fileIcon(String extension) => switch (extension) {
  'jpg' || 'jpeg' || 'png' || 'webp' || 'gif' || 'bmp' => Icons.image_outlined,
  'mp4' || 'mov' || 'mkv' || 'webm' || 'avi' => Icons.movie_outlined,
  'mp3' || 'wav' || 'ogg' || 'm4a' || 'flac' => Icons.audio_file_outlined,
  'zip' || 'rar' || '7z' || 'tar' || 'gz' => Icons.folder_zip_outlined,
  'pdf' => Icons.picture_as_pdf_outlined,
  _ => Icons.insert_drive_file_outlined,
};

bool _isAudioAttachment(String name) => const {
  'mp3',
  'wav',
  'ogg',
  'm4a',
  'flac',
}.contains(name.split('.').last.toLowerCase());

File? _usableFile(String? path) {
  if (path == null || path.trim().isEmpty) return null;
  final file = File(path);
  return file.existsSync() ? file : null;
}

class _AudioAttachmentPlayer extends StatefulWidget {
  const _AudioAttachmentPlayer({
    required this.path,
    required this.isCurrent,
    required this.validate,
  });

  final String path;
  final bool Function() isCurrent;
  final Future<bool> Function() validate;

  @override
  State<_AudioAttachmentPlayer> createState() => _AudioAttachmentPlayerState();
}

class _AudioAttachmentPlayerState extends State<_AudioAttachmentPlayer>
    with WidgetsBindingObserver {
  final _player = AudioPlayer();
  late final void Function() _unregisterMedia;
  Future<void>? _starting;
  Future<bool>? _retiring;
  late final List<StreamSubscription<Object?>> _subscriptions;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _expanded = false;
  bool _playing = false;
  bool _loaded = false;
  bool _busy = false;
  bool _failed = false;
  int _generation = 0;
  Timer? _watch;
  bool _foreground = true;
  bool _paneActive = true;
  bool get _current =>
      mounted && _foreground && _paneActive && widget.isCurrent();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final active = PaneActivityScope.isActive(context);
    if (active == _paneActive) return;
    _paneActive = active;
    if (!active) unawaited(_stop());
  }

  Future<void> _stop() async {
    await _retire();
  }

  Future<bool> _retire() {
    ++_generation;
    _watch?.cancel();
    _watch = null;
    _loaded = false;
    _playing = false;
    return _retiring ??= _release().whenComplete(() => _retiring = null);
  }

  Future<bool> _release() async {
    var stopped = false;
    final starting = _starting;
    if (starting != null) {
      try {
        await _player.stop();
      } catch (_) {}
      try {
        await starting;
      } catch (_) {}
    }
    try {
      await _player.stop();
      stopped = true;
    } catch (_) {
      _failed = true;
      try {
        await _player.dispose();
        stopped = true;
      } catch (_) {}
    }
    if (mounted) setState(() {});
    return stopped;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) unawaited(_stop());
  }

  @override
  void didUpdateWidget(_AudioAttachmentPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.path != oldWidget.path || !_current) unawaited(_stop());
  }

  @override
  void initState() {
    super.initState();
    _unregisterMedia = MediaRetirement.register(_retire);
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _subscriptions = [
      _player.onPositionChanged.listen(
        (value) {
          if (mounted) setState(() => _position = value);
        },
        onError: (_) {
          unawaited(_stop());
        },
      ),
      _player.onDurationChanged.listen(
        (value) {
          if (mounted) setState(() => _duration = value);
        },
        onError: (_) {
          unawaited(_stop());
        },
      ),
      _player.onPlayerStateChanged.listen(
        (value) {
          if (mounted) setState(() => _playing = value == PlayerState.playing);
        },
        onError: (_) {
          unawaited(_stop());
        },
      ),
      _player.onPlayerComplete.listen(
        (_) {
          if (mounted) {
            setState(() {
              _position = Duration.zero;
              _loaded = false;
            });
          }
        },
        onError: (_) {
          unawaited(_stop());
        },
      ),
    ];
  }

  Future<void> _toggle() async {
    if (_busy || _failed || !_current) return;
    _busy = true;
    final generation = ++_generation;
    bool current() => _current && generation == _generation;
    try {
      if (!_expanded) setState(() => _expanded = true);
      if (_playing) {
        await _player.pause();
      } else {
        if (!await widget.validate() || !current()) return;
        _watch ??= Timer.periodic(const Duration(milliseconds: 100), (_) {
          if (!_current) unawaited(_stop());
        });
        final starting = _loaded
            ? _player.resume()
            : _player.play(DeviceFileSource(widget.path));
        _starting = starting;
        try {
          await starting;
        } finally {
          if (identical(_starting, starting)) _starting = null;
        }
        if (!current()) {
          await _stop();
          return;
        }
        _loaded = true;
      }
    } catch (_) {
      _failed = true;
      await _stop();
    } finally {
      _busy = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _seek(double value) async {
    if (_busy || _failed || !_current) return;
    try {
      await _player.seek(Duration(milliseconds: value.round()));
      if (!_current) await _stop();
    } catch (_) {
      await _stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ++_generation;
    _watch?.cancel();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(() async {
      var stopped = await _retire();
      try {
        await _player.dispose();
        stopped = true;
      } catch (_) {}
      if (stopped) _unregisterMedia();
    }());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 7),
    child: AnimatedSize(
      duration: SyblMotion.duration(context),
      curve: Curves.easeOutCubic,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Gravity(
            child: IconButton(
              key: ValueKey('audio-attachment-play:${widget.path}'),
              tooltip: _playing ? 'Pause audio' : 'Play audio',
              onPressed: _failed || _busy ? null : _toggle,
              visualDensity: VisualDensity.compact,
              icon: Icon(
                _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                color: context.syblColors.amber,
              ),
            ),
          ),
          if (_expanded)
            Expanded(
              child: Column(
                children: [
                  Slider(
                    value: _duration.inMilliseconds == 0
                        ? 0
                        : _position.inMilliseconds
                              .clamp(0, _duration.inMilliseconds)
                              .toDouble(),
                    max: _duration.inMilliseconds <= 0
                        ? 1
                        : _duration.inMilliseconds.toDouble(),
                    onChanged: _duration.inMilliseconds <= 0 ? null : _seek,
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _AudioTime(value: _position),
                        _AudioTime(value: _duration),
                      ],
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

class _AudioTime extends StatelessWidget {
  const _AudioTime({required this.value});

  final Duration value;

  @override
  Widget build(BuildContext context) => Gravity(
    child: Text(
      _audioTime(value),
      style: TextStyle(
        color: context.syblColors.faint,
        fontSize: 11,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    ),
  );
}

String _audioTime(Duration value) {
  final minutes = value.inMinutes;
  final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

class _FileIdentity extends StatelessWidget {
  final String name;
  final String subtitle;

  const _FileIdentity({required this.name, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Gravity(
          child: Text(
            _middleEllipsis(name),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: context.syblColors.ink, fontSize: 13),
          ),
        ),
        const SizedBox(height: 2),
        Gravity(
          child: Text(
            subtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: context.syblColors.faint, fontSize: 11),
          ),
        ),
      ],
    );
  }
}

/// `cat-pictures-v0-m3k1howe3ijd1.jpeg` → `cat-pictures-v..3ijd1.jpeg`:
/// keep the meaningful head and the tail with the extension, so the name
/// line stays about as wide as the status line under it.
String _middleEllipsis(String name, {int max = 26}) {
  if (name.length <= max) return name;
  final head = name.substring(0, (max ~/ 2) - 1);
  final tail = name.substring(name.length - (max - head.length - 2));
  return '$head..$tail';
}

class _OpenFileButton extends StatelessWidget {
  const _OpenFileButton({
    required this.name,
    required this.path,
    required this.state,
  });

  final String name;
  final String? path;
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final canOpen = path != null && path!.trim().isNotEmpty;
    return Gravity(
      child: IconButton(
        key: ValueKey('open-received-file:$name'),
        tooltip: canOpen ? 'Open $name' : '$name is saved on this device',
        onPressed: canOpen
            ? () async {
                final opened = await state.openReceivedFile(path);
                if (!opened && context.mounted) {
                  showNotice('Could not open $name');
                }
              }
            : null,
        icon: Icon(
          Icons.open_in_new_rounded,
          color: canOpen ? context.syblColors.online : context.syblColors.faint,
        ),
      ),
    );
  }
}

String _transferStatus(FileXfer transfer) {
  final size = _formatBytes(transfer.size);
  final percent = '${((transfer.progress ?? 0) * 100).round()}%';
  final status = switch (transfer.status) {
    XferStatus.offered => 'wants to send',
    XferStatus.waiting => transfer.outgoing ? 'waiting' : 'ready to receive',
    XferStatus.ongoing =>
      transfer.outgoing ? 'accepted · $percent' : 'receiving · $percent',
    XferStatus.canceling => 'canceling',
    XferStatus.finished => transfer.outgoing ? 'sent' : 'received',
    XferStatus.error => 'failed',
    XferStatus.canceled => 'canceled',
    XferStatus.declined => 'declined',
  };
  return size.isEmpty ? status : '$size · $status';
}

String _formatBytes(int bytes) {
  if (bytes < 0) return '';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

String _formatTime(DateTime value) {
  final local = value.toLocal();
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}
