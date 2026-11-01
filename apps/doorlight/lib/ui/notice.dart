import 'dart:async';

import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../theme.dart';
import 'sybl_ui.dart';
import 'window_presentation.dart';

/// One transient message. Replaces SnackBars: shown top-right, where the
/// incoming-call card sits, by the single [NoticeHost] above the Navigator.
class Notice {
  Notice(
    this.text, {
    this.icon,
    this.actionLabel,
    this.onAction,
    this.duration,
  });
  final String text;
  final IconData? icon;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Duration? duration;
}

/// Newest first, at most [noticeLimit].
final ValueNotifier<List<Notice>> notices = ValueNotifier(const []);
const noticeLimit = 3;

void showNotice(
  String text, {
  IconData? icon,
  String? actionLabel,
  VoidCallback? onAction,
  Duration? duration,
}) {
  notices.value = [
    Notice(
      text,
      icon: icon,
      actionLabel: actionLabel,
      onAction: onAction,
      duration: duration,
    ),
    ...notices.value.where((e) => e.text != text),
  ].take(noticeLimit).toList();
}

void clearNotices() => notices.value = const [];

void _dismiss(Notice n) =>
    notices.value = notices.value.where((e) => e != n).toList();

/// Mounts the host above [page]; used by the app shell and tests.
Widget withNoticeHost(Widget page, AppState state) => Stack(
  fit: StackFit.expand,
  children: [
    Positioned.fill(child: page),
    NoticeHost(state: state),
  ],
);

class NoticeHost extends StatefulWidget {
  const NoticeHost({super.key, required this.state});
  final AppState state;

  @override
  State<NoticeHost> createState() => _NoticeHostState();
}

class _NoticeHostState extends State<NoticeHost> {
  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    // The list is global; a fresh host (app start, after the capture gate)
    // must not resurrect old messages.
    notices.value = const [];
  }

  @override
  Widget build(BuildContext context) {
    final compact = WindowPresentationScope.isCompact(context);
    return ListenableBuilder(
      listenable: Listenable.merge([notices, state]),
      builder: (context, _) {
        final list = notices.value;
        if (list.isEmpty) return const SizedBox.shrink();
        final call = state.call;
        final ringing =
            call?.dir == CallDir.incoming && call?.state == 'RINGING';
        // Mirrors the incoming-call card's slot in home.dart; below it when ringing.
        final top =
            (compact ? (state.selectedGroup != null ? 76.0 : 43.0) : 10.0) +
            (ringing ? (compact ? 44.0 : 76.0) : 0) +
            MediaQuery.viewPaddingOf(context).top;
        return Stack(
          children: [
            Positioned(
              top: top,
              right: compact ? 8 : 10,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final n in list)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _NoticeCard(key: ObjectKey(n), notice: n),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _NoticeCard extends StatefulWidget {
  const _NoticeCard({super.key, required this.notice});
  final Notice notice;

  @override
  State<_NoticeCard> createState() => _NoticeCardState();
}

class _NoticeCardState extends State<_NoticeCard> {
  Timer? _timer;

  Notice get n => widget.notice;

  @override
  void initState() {
    super.initState();
    _arm();
  }

  void _arm() {
    _timer?.cancel();
    _timer = Timer(
      n.duration ?? Duration(seconds: n.actionLabel == null ? 4 : 7),
      () => _dismiss(n),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.syblColors;
    final compact = WindowPresentationScope.isCompact(context);
    return Dismissible(
      key: ObjectKey(n),
      direction: DismissDirection.horizontal,
      onDismissed: (_) => _dismiss(n),
      child: MouseRegion(
        onEnter: (_) => _timer?.cancel(),
        onExit: (_) => _arm(),
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: SyblMotion.duration(
            context,
            const Duration(milliseconds: 320),
          ),
          curve: Curves.easeOutCubic,
          builder: (context, progress, child) => Transform.translate(
            offset: Offset((1 - progress) * 48, 0),
            child: Opacity(opacity: progress, child: child),
          ),
          child: Semantics(
            liveRegion: true,
            container: true,
            child: Material(
              color: colors.surfaceTop.withValues(alpha: compact ? .94 : 1),
              elevation: compact ? 3 : 12,
              shadowColor: Colors.black.withValues(alpha: .55),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(compact ? 10 : 18),
                side: BorderSide(
                  color: compact
                      ? colors.lineStrong
                      : colors.amber.withValues(alpha: .7),
                  width: compact ? 1 : 1.5,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => _dismiss(n),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: compact
                        ? MediaQuery.sizeOf(context).width - 16
                        : 360,
                  ),
                  child: Padding(
                    padding: compact
                        ? const EdgeInsets.fromLTRB(11, 7, 8, 7)
                        : const EdgeInsets.all(12),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (n.icon != null) ...[
                          Icon(n.icon, size: 16, color: colors.amber),
                          const SizedBox(width: 8),
                        ],
                        Flexible(
                          child: Text(
                            n.text,
                            style: TextStyle(
                              color: colors.ink,
                              fontSize: compact ? 12 : 13,
                            ),
                          ),
                        ),
                        if (n.actionLabel != null) ...[
                          const SizedBox(width: 8),
                          TextButton(
                            onPressed: () {
                              n.onAction?.call();
                              _dismiss(n);
                            },
                            child: Text(n.actionLabel!),
                          ),
                        ],
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
}
