import 'dart:async';

import 'notice.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import '../core/invite_link.dart';
import '../core/jami_identity.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'account_share.dart';
import 'add_friend_dialog.dart';
import 'friend_qr_scanner.dart';
import 'gravity.dart';
import 'nearby_sheet.dart';
import 'onboarding_surface.dart';
import 'sybl_ui.dart';
import 'window_presentation.dart';

/// Connection choices share the existing explicit friend-confirmation path.
class AddFriendPane extends StatelessWidget {
  const AddFriendPane({
    super.key,
    required this.state,
    required this.onClose,
    required this.isCurrent,
    this.titleBarHeight = 0,
    this.openSonar = false,
  });
  final AppState state;
  final VoidCallback onClose;
  final bool Function() isCurrent;

  /// Opens Sonar on arrival, for the notification bell.
  final bool openSonar;

  /// Height reserved for desktop window controls above the content.
  final double titleBarHeight;

  // The warm, softly lit surface from setup, painted for this pane alone.
  @override
  Widget build(BuildContext context) {
    final content = OnboardingSurface(
      reuseAncestor: false,
      child: _AddFriendContent(
        state: state,
        onClose: onClose,
        isCurrent: isCurrent,
        titleBarHeight: titleBarHeight,
        openSonar: openSonar,
      ),
    );
    if (titleBarHeight == 0) return content;
    // Beside the desktop sidebar, Nearby and the add confirmation open inside
    // this pane instead of covering the whole window.
    return Navigator(
      onGenerateRoute: (_) =>
          PageRouteBuilder<void>(pageBuilder: (_, _, _) => content),
    );
  }
}

class _AddFriendContent extends StatefulWidget {
  const _AddFriendContent({
    required this.state,
    required this.onClose,
    required this.isCurrent,
    required this.titleBarHeight,
    required this.openSonar,
  });
  final AppState state;
  final VoidCallback onClose;
  final bool Function() isCurrent;
  final double titleBarHeight;
  final bool openSonar;
  @override
  State<_AddFriendContent> createState() => _AddFriendPaneState();
}

class _AddFriendPaneState extends State<_AddFriendContent>
    with SingleTickerProviderStateMixin {
  late final _owner = widget.state.linkedDeviceOwner;
  bool _busy = false;
  bool get _mobile =>
      Theme.of(context).platform == TargetPlatform.android ||
      Theme.of(context).platform == TargetPlatform.iOS;
  bool _qrHover = false;
  bool get _owns =>
      mounted &&
      widget.isCurrent() &&
      _owner == widget.state.linkedDeviceOwner &&
      widget.state.canPresentInvite &&
      ModalRoute.of(context)?.isCurrent == true;

  // The friend-code row works like an iOS swipe row: drag it left and it
  // slides away to uncover a full-width field behind it. A plain click only
  // peeks, so nothing opens by accident and the row never changes height.
  final _code = TextEditingController();
  final _scroll = ScrollController();
  double? _scrollBeforeCode;
  late final _codeFocus = FocusNode()..addListener(_codeFocusChanged);
  // Slightly below zero so the peek's spring can overshoot its resting spot.
  late final _slide = AnimationController(
    vsync: this,
    lowerBound: -.05,
    value: 0,
    duration: const Duration(milliseconds: 240),
  );
  double _rowWidth = 1;

  @override
  void initState() {
    super.initState();
    if (widget.openSonar && widget.state.nearby != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_add(nearby: true));
      });
    }
  }

  @override
  void dispose() {
    _code.dispose();
    _scroll.dispose();
    _codeFocus.dispose();
    _slide.dispose();
    super.dispose();
  }

  void _codeFocusChanged() {
    if (!_codeFocus.hasFocus && _code.text.trim().isEmpty) _closeCode();
  }

  Future<void> _openCode() async {
    if (_scroll.hasClients) _scrollBeforeCode ??= _scroll.offset;
    try {
      await _slide.animateTo(1, curve: Curves.easeOutCubic).orCancel;
      await WidgetsBinding.instance.endOfFrame;
      if (mounted && _slide.value == 1) _codeFocus.requestFocus();
    } on TickerCanceled {
      // Closing or disposal can retire the reveal before it completes.
    }
  }

  void _closeCode() {
    final restore = _scrollBeforeCode;
    _scrollBeforeCode = null;
    _code.clear();
    _codeFocus.unfocus();
    _slide.animateBack(0, curve: Curves.easeOutCubic);
    if (restore != null) {
      // Text-field focus can scroll the pane; closing restores the original row.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        unawaited(
          _scroll.animateTo(
            restore.clamp(0, _scroll.position.maxScrollExtent),
            duration: SyblMotion.duration(
              context,
              const Duration(milliseconds: 200),
            ),
            curve: Curves.easeOutCubic,
          ),
        );
      });
    }
  }

  Future<void> _peekCode() async {
    if (_slide.value > .01 || MediaQuery.disableAnimationsOf(context)) return;
    // A quick hop left, then a springy settle back, like an iOS swipe row
    // showing what is behind it.
    await _slide.animateTo(
      .28,
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOutCubic,
    );
    if (mounted && !_codeFocus.hasFocus) {
      await _slide.animateBack(
        0,
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutBack,
      );
    }
  }

  void _dragCode(DragUpdateDetails details) {
    _slide.value = (_slide.value - details.primaryDelta! / _rowWidth).clamp(
      0,
      1,
    );
  }

  void _releaseCode(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity < -300 || (velocity <= 300 && _slide.value > .4)) {
      _openCode();
    } else {
      _closeCode();
    }
  }

  void _submitCode() {
    final raw = _code.text.trim();
    if (raw.isEmpty) return;
    final invite = raw.length > SyblInviteLink.maxLinkCharacters
        ? null
        : friendInviteFromQr(raw);
    if (invite == null) {
      _message('That isn’t a Doorlight link or friend code.');
      return;
    }
    _add(entered: invite);
  }

  Future<void> _pasteCode() async {
    try {
      final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
      if (!_owns || text == null || text.trim().isEmpty) return;
      _code
        ..text = text.trim()
        ..selection = TextSelection.collapsed(offset: text.trim().length);
      _submitCode();
    } catch (_) {
      _message('Could not read the clipboard.');
    }
  }

  Widget _codeRow() {
    final colors = context.syblColors;
    final none = const OutlineInputBorder(borderSide: BorderSide.none);
    final field = CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _closeCode},
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 4, 0),
        child: Row(
          children: [
            Icon(Icons.link_rounded, color: colors.amber, size: 19),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                key: const ValueKey('connection-code-field'),
                controller: _code,
                focusNode: _codeFocus,
                enabled: !_busy,
                maxLines: 1,
                autocorrect: false,
                enableSuggestions: false,
                textInputAction: TextInputAction.go,
                style: TextStyle(color: colors.ink, fontSize: 14),
                decoration: InputDecoration(
                  isDense: true,
                  filled: false,
                  contentPadding: EdgeInsets.zero,
                  border: none,
                  enabledBorder: none,
                  focusedBorder: none,
                  disabledBorder: none,
                  hintText: 'Paste a link or type a code',
                  hintStyle: TextStyle(color: colors.muted, fontSize: 14),
                ),
                onSubmitted: (_) => _submitCode(),
              ),
            ),
            // One slot: paste while empty, go once there is something.
            ListenableBuilder(
              listenable: _code,
              builder: (context, _) => _code.text.trim().isEmpty
                  ? IconButton(
                      key: const ValueKey('connection-code-paste'),
                      tooltip: 'Paste',
                      onPressed: _busy ? null : _pasteCode,
                      icon: Icon(
                        Icons.content_paste_rounded,
                        size: 19,
                        color: colors.muted,
                      ),
                    )
                  : IconButton(
                      key: const ValueKey('connection-code-go'),
                      tooltip: 'Continue',
                      onPressed: _busy ? null : _submitCode,
                      icon: Icon(
                        Icons.arrow_forward_rounded,
                        size: 20,
                        color: colors.amber,
                      ),
                    ),
            ),
            IconButton(
              key: const ValueKey('connection-code-close'),
              tooltip: 'Cancel',
              onPressed: _closeCode,
              icon: Icon(Icons.close_rounded, size: 18, color: colors.faint),
            ),
          ],
        ),
      ),
    );
    return LayoutBuilder(
      builder: (context, size) {
        _rowWidth = size.maxWidth;
        return ClipRect(
          child: Stack(
            children: [
              Positioned.fill(
                child: AnimatedBuilder(
                  animation: _slide,
                  // Hidden fields must not take focus or clicks.
                  builder: (context, child) => IgnorePointer(
                    ignoring: _slide.value < .5,
                    child: ExcludeSemantics(
                      excluding: _slide.value < 1,
                      child: ExcludeFocus(
                        excluding: _slide.value < 1,
                        child: Opacity(
                          // Fully visible by the time a peek uncovers it.
                          opacity: (_slide.value * 5).clamp(0, 1),
                          child: child,
                        ),
                      ),
                    ),
                  ),
                  child: field,
                ),
              ),
              AnimatedBuilder(
                animation: _slide,
                builder: (context, child) => Transform.translate(
                  offset: Offset(-_slide.value * size.maxWidth, 0),
                  child: ExcludeSemantics(
                    excluding: _slide.value == 1,
                    child: ExcludeFocus(
                      excluding: _slide.value == 1,
                      child: child!,
                    ),
                  ),
                ),
                child: GestureDetector(
                  onHorizontalDragUpdate: _busy ? null : _dragCode,
                  onHorizontalDragEnd: _busy ? null : _releaseCode,
                  child: Material(
                    color: colors.surface,
                    child: CallbackShortcuts(
                      bindings: {
                        const SingleActivator(LogicalKeyboardKey.enter): () {
                          if (!_busy) _openCode();
                        },
                        const SingleActivator(LogicalKeyboardKey.space): () {
                          if (!_busy) _openCode();
                        },
                      },
                      child: Semantics(
                        label: 'Friend code or link',
                        button: true,
                        enabled: !_busy,
                        excludeSemantics: true,
                        onTap: _busy ? null : _openCode,
                        child: _choice(
                          key: const ValueKey('connection-enter-id'),
                          icon: Icons.link_rounded,
                          title: 'Friend code or link',
                          trailing: Icons.chevron_left_rounded,
                          onPressed: _busy ? null : _peekCode,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _add({
    bool nearby = false,
    bool qr = false,
    SyblInviteLink? entered,
  }) async {
    if (!_owns || _busy) return;
    setState(() => _busy = true);
    try {
      SyblInviteLink? invite = entered;
      if (nearby) {
        // Pressing Add on a named nearby row is the one confirmation and
        // sends from Nearby, which then opens the new chat; only a refused
        // request comes back here, to the card that explains why.
        var sent = false;
        final peer = await showNearbySheet(
          context,
          state: widget.state,
          page: true,
          add: (peer) async =>
              sent = await widget.state.addFriend(peer.id, nameHint: peer.name),
        );
        if (sent) {
          if (_owns) widget.onClose();
          return;
        }
        if (!_owns || peer == null) return;
        invite = SyblInviteLink.create(jamiId: peer.id, displayName: peer.name);
        if (invite == null) return;
      } else if (qr && _mobile) {
        // Phones go straight to the camera, then to the confirmation.
        invite = await scanFriendQr(context);
        if (!_owns || invite == null) return;
      }
      if (!mounted || !_owns) return;
      final added = await showAddFriendDialog(
        context,
        state: widget.state,
        initialInvite: invite,
        manualEntry: invite == null && !qr,
        scanQr: invite == null && qr,
        page: true,
        chosen: invite != null,
        nearby: nearby,
      );
      if (_owns && added) widget.onClose();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _message(String text) {
    if (!_owns) return;
    // The newest note replaces any still showing instead of queueing.
    clearNotices();
    showNotice(text, duration: const Duration(seconds: 2));
  }

  Future<void> _copy(String value) async {
    if (!_owns) return;
    try {
      await Clipboard.setData(ClipboardData(text: value));
      _message('Friend code copied');
    } catch (_) {
      _message('Could not copy. Try again.');
    }
  }

  Future<void> _share(SyblInviteLink invite, BuildContext buttonContext) async {
    if (!_owns) return;
    try {
      final box = buttonContext.findRenderObject() as RenderBox;
      await SharePlus.instance.share(
        ShareParams(
          text:
              'Get Doorlight: https://doorlight.app/download\nAdd me: ${invite.shareUri()}',
          sharePositionOrigin: box.localToGlobal(Offset.zero) & box.size,
        ),
      );
    } catch (_) {
      _message('Could not share. Try again.');
    }
  }

  Future<void> _enlarge(SyblInviteLink invite) async {
    if (!_owns) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Gravity(child: const Text('Your QR code')),
        content: SizedBox(
          width: 280,
          child: AspectRatio(
            aspectRatio: 1,
            child: LayoutBuilder(
              builder: (context, size) => Gravity(
                child: FriendInviteQr(invite: invite, dimension: size.maxWidth),
              ),
            ),
          ),
        ),
        actions: [
          Gravity(
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Done'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _panel(Widget child) => Material(
    color: context.syblColors.surface,
    shape: RoundedRectangleBorder(
      side: BorderSide(color: context.syblColors.lineStrong),
      borderRadius: BorderRadius.circular(14),
    ),
    clipBehavior: Clip.antiAlias,
    child: child,
  );

  Widget _divider() => Divider(
    height: 1,
    thickness: 1,
    indent: 62,
    color: context.syblColors.line,
  );

  Widget _choice({
    required Key key,
    required IconData icon,
    required String title,
    required VoidCallback? onPressed,
    IconData trailing = Icons.chevron_right_rounded,
  }) {
    final colors = context.syblColors;
    return Gravity(
      child: Opacity(
        opacity: onPressed == null ? .5 : 1,
        child: InkWell(
          key: key,
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 11, 10, 11),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: colors.amber.withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: colors.amber, size: 19),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(trailing, color: colors.faint, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _section(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Gravity(
      child: Text(
        text,
        style: context.syblColors.display.copyWith(fontSize: 16),
      ),
    ),
  );

  String _inviteText(SyblInviteLink invite) =>
      'Get Doorlight: https://doorlight.app/download\nAdd me: ${invite.shareUri()}';

  Future<void> _copyLink(SyblInviteLink invite) async {
    if (!_owns) return;
    try {
      await Clipboard.setData(ClipboardData(text: invite.shareUri()));
      _message('Invite link copied');
    } catch (_) {
      _message('Could not copy. Try again.');
    }
  }

  Future<void> _open(Uri uri) async {
    if (!_owns) return;
    try {
      if (await UrlLauncherPlatform.instance.launchUrl(
        uri.toString(),
        const LaunchOptions(),
      )) {
        return;
      }
    } catch (_) {}
    _message('Could not open that app. Try Copy link instead.');
  }

  /// Phones already have a native share sheet listing WhatsApp and the rest;
  /// desktop gets the same choices as a menu.
  Widget _shareButton(SyblInviteLink invite, bool mobile) {
    final style = IconButton.styleFrom(
      fixedSize: const Size(38, 38),
      foregroundColor:
          context.syblColors.neutralButtonForeground ??
          context.syblColors.amber,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    const icon = Icon(Icons.open_in_new_rounded, size: 20);
    if (mobile) {
      return Builder(
        builder: (context) => Gravity(
          child: IconButton(
            key: const ValueKey('connection-share'),
            tooltip: 'Share invite',
            constraints: const BoxConstraints.tightFor(width: 38, height: 38),
            padding: EdgeInsets.zero,
            style: style,
            onPressed: () => _share(invite, context),
            icon: icon,
          ),
        ),
      );
    }
    final item = MenuItemButton.styleFrom(
      minimumSize: const Size(200, 40),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      iconColor: context.syblColors.amber,
    );
    late BuildContext anchor;
    final text = _inviteText(invite);
    return MenuAnchor(
      alignmentOffset: const Offset(0, 6),
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(context.syblColors.surface),
        elevation: const WidgetStatePropertyAll(0),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(vertical: 6),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            side: BorderSide(
              color: context.syblColors.amber.withValues(alpha: .24),
            ),
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      menuChildren: [
        MenuItemButton(
          key: const ValueKey('share-copy-link'),
          style: item,
          leadingIcon: const Icon(Icons.link_rounded),
          onPressed: () => _copyLink(invite),
          child: const Text('Copy link'),
        ),
        MenuItemButton(
          key: const ValueKey('share-whatsapp'),
          style: item,
          leadingIcon: const Icon(Icons.chat_outlined),
          onPressed: () => _open(Uri.https('wa.me', '/', {'text': text})),
          child: const Text('WhatsApp'),
        ),
        MenuItemButton(
          key: const ValueKey('share-telegram'),
          style: item,
          leadingIcon: const Icon(Icons.send_outlined),
          onPressed: () => _open(
            Uri.https('t.me', '/share/url', {
              'url': invite.shareUri(),
              'text': 'Add me on Doorlight',
            }),
          ),
          child: const Text('Telegram'),
        ),
        MenuItemButton(
          key: const ValueKey('share-email'),
          style: item,
          leadingIcon: const Icon(Icons.mail_outline_rounded),
          // Uri's query encoder writes spaces as '+', which mail apps show.
          onPressed: () => _open(
            Uri.parse(
              'mailto:?subject=${Uri.encodeComponent('Add me on Doorlight')}'
              '&body=${Uri.encodeComponent(text)}',
            ),
          ),
          child: const Text('Email'),
        ),
        const Divider(height: 8),
        MenuItemButton(
          key: const ValueKey('share-more'),
          style: item,
          leadingIcon: const Icon(Icons.more_horiz_rounded),
          onPressed: () => _share(invite, anchor),
          child: const Text('More options…'),
        ),
      ],
      builder: (context, controller, _) {
        anchor = context;
        return Gravity(
          child: IconButton(
            key: const ValueKey('connection-share'),
            tooltip: 'Share invite',
            constraints: const BoxConstraints.tightFor(width: 38, height: 38),
            padding: EdgeInsets.zero,
            style: style,
            onPressed: () =>
                controller.isOpen ? controller.close() : controller.open(),
            icon: icon,
          ),
        );
      },
    );
  }

  Widget _details(SyblInviteLink invite, String id, bool mobile) {
    final colors = context.syblColors;
    return _panel(
      Padding(
        padding: const EdgeInsets.all(12),
        child: LayoutBuilder(
          builder: (context, size) {
            final qrSize = mobile ? 164.0 : 100.0;
            final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
            final stacked = mobile || size.maxWidth < 300 || textScale > 1.4;
            Widget label(String text) => Gravity(
              child: Text(
                text,
                style: TextStyle(
                  color: colors.muted,
                  fontSize: 11,
                  height: 1.1,
                ),
              ),
            );
            final name = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                label('Your name'),
                Gravity(
                  child: Text(
                    widget.state.displayName.isEmpty
                        ? 'You'
                        : widget.state.displayName,
                    key: const ValueKey('connection-name'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: colors.display.copyWith(fontSize: 18, height: 1.15),
                  ),
                ),
              ],
            );
            final code = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                label('Your friend code'),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 10,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Gravity(
                      child: Text(
                        '${id.substring(0, 4)}…${id.substring(id.length - 4)}',
                        key: const ValueKey('connection-short-id'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 15, letterSpacing: .3),
                      ),
                    ),
                    Gravity(
                      child: Tooltip(
                        message: 'Copy friend code',
                        child: OutlinedButton(
                          key: const ValueKey('connection-copy-id'),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(40, 28),
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            visualDensity: VisualDensity.compact,
                            shape: context.syblColors.buttonShape,
                          ),
                          onPressed: () => _copy(id),
                          child: const Icon(Icons.copy_rounded, size: 14),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            );
            final share = _shareButton(invite, mobile);
            final qr = Gravity(
              child: Semantics(
                button: true,
                label: 'Enlarge QR code',
                // The magnifier lights up on hover instead of a tooltip.
                child: InkWell(
                  key: const ValueKey('connection-enlarge-qr'),
                  onTap: () => _enlarge(invite),
                  onHover: (hover) => setState(() => _qrHover = hover),
                  hoverColor: Colors.transparent,
                  child: Stack(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: FriendInviteQr(
                          invite: invite,
                          dimension: qrSize,
                        ),
                      ),
                      Positioned(
                        right: 4,
                        bottom: 4,
                        child: AnimatedContainer(
                          key: const ValueKey('connection-qr-zoom'),
                          duration: SyblMotion.duration(
                            context,
                            const Duration(milliseconds: 120),
                          ),
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: _qrHover
                                ? colors.accentFill
                                : colors.bg.withValues(alpha: .8),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.zoom_in_rounded,
                            size: 18,
                            color: _qrHover ? colors.onAccent : colors.amber,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
            if (stacked) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(child: qr),
                  const SizedBox(height: 16),
                  name,
                  const SizedBox(height: 8),
                  code,
                  const SizedBox(height: 8),
                  Align(alignment: Alignment.centerRight, child: share),
                ],
              );
            }
            // Name and code sit as one block centred on the QR; share keeps
            // the card's bottom-right corner.
            return IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(alignment: Alignment.centerLeft, child: qr),
                  const SizedBox(width: 18),
                  Expanded(
                    child: Column(
                      key: const ValueKey('connection-identity-text'),
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [name, const SizedBox(height: 14), code],
                    ),
                  ),
                  Align(alignment: Alignment.bottomRight, child: share),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mobile =
        Theme.of(context).platform == TargetPlatform.android ||
        Theme.of(context).platform == TargetPlatform.iOS;
    final id = JamiIdentity.fingerprint(widget.state.jamiId);
    final invite = SyblInviteLink.create(
      jamiId: widget.state.jamiId,
      displayName: widget.state.displayName,
    );
    final compact = WindowPresentationScope.isCompact(context);
    final header = widget.titleBarHeight;
    return LayoutBuilder(
      builder: (context, viewport) {
        final gutter = (viewport.maxWidth * .05).clamp(16.0, 32.0);
        Widget column(List<Widget> children) => Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        );
        final title = Gravity(
          child: Text(
            'Add a friend',
            key: const ValueKey('add-friend-title'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.syblColors.display.copyWith(
              fontSize: mobile ? 26 : 24,
              height: 1.1,
            ),
          ),
        );
        final body = ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: SingleChildScrollView(
            controller: _scroll,
            padding: EdgeInsets.fromLTRB(
              gutter,
              compact || header > 0 ? 12 : 24,
              gutter,
              24,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: (viewport.maxHeight - header - 48).clamp(
                  0,
                  double.infinity,
                ),
              ),
              child: column([
                if (!compact) ...[title, const SizedBox(height: 16)],
                // One grouped list reads lighter than three boxed cards.
                _panel(
                  Column(
                    children: [
                      _choice(
                        key: const ValueKey('connection-nearby'),
                        icon: Icons.wifi_tethering_rounded,
                        title: 'Sonar',
                        onPressed: _busy || widget.state.nearby == null
                            ? null
                            : () => _add(nearby: true),
                      ),
                      _divider(),
                      _codeRow(),
                      _divider(),
                      _choice(
                        key: const ValueKey('connection-scan-qr'),
                        icon: Icons.qr_code_scanner_rounded,
                        title: 'QR code',
                        onPressed: _busy ? null : () => _add(qr: true),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 22),
                _section('Your Doorlight'),
                if (invite != null && id != null)
                  _details(invite, id, mobile)
                else
                  Gravity(child: const Text('Your profile is not ready yet.')),
              ]),
            ),
          ),
        );
        if (compact) {
          return Column(
            children: [
              CompactHeader(title: 'Add a friend', onBack: widget.onClose),
              Expanded(child: body),
            ],
          );
        }
        return Padding(
          padding: EdgeInsets.only(top: header),
          child: body,
        );
      },
    );
  }
}
