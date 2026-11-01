import 'notice.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/invite_link.dart';
import '../core/jami_identity.dart';
import '../state/app_state.dart';
import '../state/pending_invite.dart';
import '../theme.dart';
import 'gravity.dart';
import 'account_share.dart';
import 'friend_qr_scanner.dart';
import 'friend_connection_page.dart';
import 'nearby_sheet.dart';
import 'sybl_ui.dart';

Future<bool> showAddFriendDialog(
  BuildContext context, {
  required AppState state,
  SyblInviteLink? initialInvite,
  PendingInvite? continuation,
  bool manualEntry = false,
  bool pasteOnOpen = false,
  bool scanQr = false,
  bool page = false,
  bool chosen = false,
  bool nearby = false,
}) async {
  final owner = state.linkedDeviceOwner;
  final child = _AddFriendDialog(
    state: state,
    initialInvite: initialInvite,
    continuation: continuation,
    manualEntry: manualEntry,
    pasteOnOpen: pasteOnOpen,
    scanQr: scanQr,
    page: page,
    chosen: chosen,
    nearby: nearby,
  );
  final route = page
      ? friendConnectionRoute<bool>(context, child)
      : DialogRoute<bool>(context: context, builder: (_) => child);
  // A page opens inside the pane's own navigator, sliding in like Nearby.
  unawaited(Navigator.of(context, rootNavigator: !page).push(route));
  // `popped` can stay pending when a privacy gate disposes the navigator.
  // TransitionRoute.completed also settles on teardown, releasing this owner.
  final added = await route.completed;
  // Back/dismiss means Not now. Privacy teardown preserves the continuation.
  if (continuation != null &&
      context.mounted &&
      state.canPresentInvite &&
      owner == state.linkedDeviceOwner &&
      identical(state.inviteContinuation.pending, continuation)) {
    await state.inviteContinuation.discard(continuation);
  }
  return added ?? false;
}

class _AddFriendDialog extends StatefulWidget {
  final AppState state;
  final SyblInviteLink? initialInvite;
  final PendingInvite? continuation;
  final bool manualEntry;
  final bool pasteOnOpen;

  /// Desktop QR page: webcam and QR image only; the code field appears once
  /// a QR is read.
  final bool scanQr;
  final bool page;

  /// The person was just picked in the Add a friend pane, so the choice plus
  /// the Add button is the one confirmation; no "invited you" question.
  final bool chosen;
  final bool nearby;

  const _AddFriendDialog({
    required this.state,
    this.initialInvite,
    this.continuation,
    this.manualEntry = false,
    this.pasteOnOpen = false,
    this.scanQr = false,
    this.page = false,
    this.chosen = false,
    this.nearby = false,
  });

  @override
  State<_AddFriendDialog> createState() => _AddFriendDialogState();
}

class _AddFriendDialogState extends State<_AddFriendDialog> {
  late final TextEditingController _controller;
  SyblInviteLink? _invite;
  bool _manualEntry = false;
  bool _working = false;
  bool _issued = false;
  late final (String?, int) _owner;
  // Decided once on open so the title never swaps while the dialog is up.
  late final bool _firstFriend =
      widget.state.friends.isEmpty &&
      !widget.manualEntry &&
      !widget.scanQr &&
      widget.initialInvite == null &&
      widget.continuation == null;
  String? _error;

  @override
  void initState() {
    super.initState();
    _owner = widget.state.linkedDeviceOwner;
    _invite = widget.initialInvite;
    _manualEntry = widget.manualEntry || widget.initialInvite != null;
    _controller = TextEditingController(text: _invite?.jamiId ?? '');
    if (widget.pasteOnOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _ownsSurface) unawaited(_paste());
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _setError(String message) {
    setState(() {
      _working = false;
      _error = message;
    });
  }

  Future<void> _paste() async {
    if (_working || _issued) return;
    final previousText = _controller.text;
    try {
      final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
      if (!_ownsSurface ||
          _controller.text != previousText ||
          _working ||
          _issued) {
        return;
      }
      final value = clipboard?.text?.trim() ?? '';
      if (value.length > SyblInviteLink.maxLinkCharacters) {
        _setError(
          'This invitation is too long. Ask your friend to share it again.',
        );
        return;
      }
      if (value.isEmpty) {
        _setError(
          'Clipboard is empty. Copy your friend’s link or code, then try again.',
        );
        return;
      }
      final invite = SyblInviteLink.tryParse(value);
      final fieldValue = invite?.jamiId ?? value;
      _controller
        ..text = fieldValue
        ..selection = TextSelection.collapsed(offset: fieldValue.length);
      setState(() {
        _invite = invite;
        _manualEntry = invite == null;
        _error = null;
      });
    } catch (_) {
      if (!_ownsSurface) return;
      _setError('Doorlight could not read the clipboard.');
    }
  }

  Future<void> _scan() async {
    if (_working || _issued) return;
    _acceptQr(await scanFriendQr(context));
  }

  Future<void> _openQrImage() async {
    if (_working || _issued) return;
    try {
      _acceptQr(await pickFriendQrImage());
    } on FormatException catch (error) {
      if (_ownsSurface) _setError(error.message);
    } catch (_) {
      if (_ownsSurface) _setError('Doorlight could not open that image.');
    }
  }

  void _acceptQr(SyblInviteLink? invite) {
    if (!_ownsSurface || invite == null) return;
    _controller.text = invite.jamiId;
    setState(() {
      _invite = invite;
      _manualEntry = false;
      _error = null;
    });
  }

  Future<void> _openNearby() async {
    if (_working || _issued) return;
    final peer = await showNearbySheet(context, state: widget.state);
    if (!_ownsSurface || peer == null) return;
    // The announced name is an unverified hint, exactly like an invite link's.
    final invite = SyblInviteLink.create(
      jamiId: peer.id,
      displayName: peer.name,
    );
    if (invite == null) return;
    _controller.text = invite.jamiId;
    setState(() {
      _invite = invite;
      _manualEntry = false;
      _error = null;
    });
  }

  Future<void> _showMyQr() async {
    if (_working || _issued) return;
    await showAccountShareDialog(
      context,
      jamiId: widget.state.jamiId,
      displayName: widget.state.displayName,
    );
  }

  Future<void> _submit() async {
    if (_working || _issued) return;
    if (!_ownsSurface) {
      _setError(
        'Your profile changed. Close this invitation and open it again.',
      );
      return;
    }
    final fingerprint =
        SyblInviteLink.tryParse(_controller.text)?.jamiId ??
        JamiIdentity.fingerprint(_controller.text);
    if (fingerprint == null) {
      _setError('Scan or paste your friend’s invitation.');
      return;
    }
    if (fingerprint == JamiIdentity.fingerprint(widget.state.jamiId)) {
      _setError('That is your own friend code.');
      return;
    }
    if (widget.state.isRemovalPending(fingerprint)) {
      _setError('Finishing removal… Try again in a moment.');
      return;
    }
    if (widget.state.friends.containsKey(fingerprint)) {
      final friend = widget.state.friends[fingerprint]!;
      _setError(
        friend.confirmed
            ? 'This person is already in your people.'
            : 'Your request is already waiting for their acceptance.',
      );
      return;
    }

    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final continuation = widget.continuation;
      if (continuation != null) {
        if (!identical(widget.state.inviteContinuation.pending, continuation) ||
            continuation.invite.jamiId != fingerprint) {
          _setError(
            'This invitation expired or changed. Open the invitation again.',
          );
          return;
        }
        if (!await widget.state.inviteContinuation.discard(continuation)) {
          if (mounted) {
            _setError(
              'Could not save your choice. No request was sent. Try again.',
            );
          }
          return;
        }
      }
      if (!_ownsSurface) return;
      _issued = true;
      final added = await widget.state.addFriend(
        fingerprint,
        nameHint: _invite?.jamiId == fingerprint ? _invite!.displayName : null,
      );
      if (!mounted || !_ownsSurface) return;
      if (added) {
        showNotice(
          widget.state.friends[fingerprint]?.confirmed == true
              ? 'You are connected.'
              : 'Friend request sent. Waiting for their acceptance.',
        );
        Navigator.of(context).pop(true);
      } else {
        _setError(
          'The request outcome is not confirmed. Check your people before trying again.',
        );
      }
    } catch (_) {
      if (!_ownsSurface) return;
      _setError(
        'The request outcome is not confirmed. Check your people before trying again.',
      );
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  bool get _mobile =>
      Theme.of(context).platform == TargetPlatform.android ||
      Theme.of(context).platform == TargetPlatform.iOS;

  bool get _ownsSurface =>
      mounted &&
      _owner == widget.state.linkedDeviceOwner &&
      widget.state.canPresentInvite &&
      ModalRoute.of(context)?.isCurrent == true;

  @override
  Widget build(BuildContext context) {
    final titleStyle = context.syblColors.display.copyWith(fontSize: 19);
    final dialog = AlertDialog(
      // Give the first connection a welcome; later additions stay task-focused.
      title: _firstFriend
          ? null
          : Gravity(
              child: Text(
                widget.pasteOnOpen
                    ? 'Paste a friend link'
                    : widget.scanQr
                    ? 'Scan a QR code'
                    : widget.manualEntry
                    ? 'Friend code or link'
                    : 'Add a friend',
                style: titleStyle,
              ),
            ),
      content: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 390),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_firstFriend) ...[
                Column(
                  key: const ValueKey('first-friend-title'),
                  children: [
                    Gravity(
                      child: Text(
                        'Add a friend',
                        textAlign: TextAlign.center,
                        style: titleStyle.copyWith(fontSize: 22),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
              ],
              if (!widget.manualEntry &&
                  !widget.scanQr &&
                  widget.initialInvite == null &&
                  _invite == null) ...[
                if (Theme.of(context).platform == TargetPlatform.android ||
                    Theme.of(context).platform == TargetPlatform.iOS) ...[
                  SizedBox(
                    width: double.infinity,
                    child: Gravity(
                      child: FilledButton.icon(
                        key: const ValueKey('scan-friend-qr'),
                        onPressed: _scan,
                        icon: const Icon(Icons.qr_code_scanner_rounded),
                        label: const Text('Scan friend’s QR code'),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ] else ...[
                  SizedBox(
                    width: double.infinity,
                    child: Gravity(
                      child: FilledButton.icon(
                        key: const ValueKey('paste-friend-invite'),
                        onPressed: _paste,
                        icon: const Icon(Icons.content_paste_rounded),
                        label: const Text('Paste invitation'),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                if (widget.state.nearby case final nearby?) ...[
                  SizedBox(
                    width: double.infinity,
                    child: ListenableBuilder(
                      listenable: nearby,
                      builder: (context, _) => Gravity(
                        child: OutlinedButton.icon(
                          key: const ValueKey('open-nearby'),
                          onPressed: _openNearby,
                          icon: Badge(
                            isLabelVisible: nearby.pendingWave,
                            smallSize: 8,
                            child: const Icon(Icons.radar_rounded),
                          ),
                          label: const Text('Find people nearby'),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                SizedBox(
                  width: double.infinity,
                  child: Gravity(
                    child: OutlinedButton.icon(
                      key: const ValueKey('show-my-friend-qr'),
                      onPressed: _showMyQr,
                      icon: const Icon(Icons.qr_code_2_rounded),
                      label: const Text('Show my QR code'),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Gravity(
                  child: TextButton(
                    key: const ValueKey('enter-friend-id'),
                    onPressed: () =>
                        setState(() => _manualEntry = !_manualEntry),
                    child: Text(
                      _manualEntry
                          ? 'Hide friend code field'
                          : 'Add by friend code',
                    ),
                  ),
                ),
              ],
              if (_manualEntry || _invite != null)
                _EnterIdentityPane(
                  invite: _invite,
                  linkEntry: widget.pasteOnOpen,
                  chosen: widget.chosen,
                  nearby: widget.nearby,
                  controller: _controller,
                  enabled: !_working && !_issued && widget.continuation == null,
                  error: _error,
                  onChanged: () {
                    final parsed = SyblInviteLink.tryParse(_controller.text);
                    final next =
                        parsed ??
                        (JamiIdentity.fingerprint(_controller.text) ==
                                _invite?.jamiId
                            ? _invite
                            : null);
                    if (_error != null || next != _invite) {
                      setState(() {
                        _invite = next;
                        _error = null;
                      });
                    }
                  },
                  onPaste: _paste,
                  onSubmit: _submit,
                ),
              if (widget.scanQr && _invite == null) ...[
                if (Theme.of(context).platform == TargetPlatform.windows)
                  DesktopQrCamera(
                    key: const ValueKey('friend-qr-webcam'),
                    onInvite: _acceptQr,
                    onUpload: _openQrImage,
                  )
                else
                  SizedBox(
                    width: double.infinity,
                    child: Gravity(
                      child: OutlinedButton.icon(
                        key: const ValueKey('friend-qr-button'),
                        onPressed: _mobile ? _scan : _openQrImage,
                        icon: Icon(
                          _mobile
                              ? Icons.qr_code_scanner_rounded
                              : Icons.image_outlined,
                        ),
                        label: Text(
                          _mobile ? 'Scan their QR code' : 'Open a QR image',
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
              ],
              if (_error != null && (_invite != null || !_manualEntry))
                Gravity(
                  child: Text(
                    _error!,
                    style: TextStyle(color: context.syblColors.danger),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        Gravity(
          child: TextButton(
            onPressed: _working ? null : () => Navigator.of(context).pop(false),
            child: Text(
              widget.initialInvite == null || widget.chosen
                  ? 'Cancel'
                  : 'Not now',
            ),
          ),
        ),
        if (_manualEntry || _invite != null)
          Gravity(
            child: FilledButton(
              key: const ValueKey('confirm-add-friend-button'),
              onPressed: _working || _issued ? null : _submit,
              child: Text(
                _working
                    ? 'Adding\u2026'
                    : _invite?.displayName.isNotEmpty == true
                    ? 'Add ${_invite!.displayName}'
                    : 'Add',
              ),
            ),
          ),
      ],
    );
    if (!widget.page) return dialog;
    return FriendConnectionPage(
      title: widget.pasteOnOpen
          ? 'Invite link'
          : widget.scanQr
          ? 'Scan a QR code'
          : widget.manualEntry
          ? 'Friend code or link'
          : 'Add a friend',
      actions: dialog.actions!,
      child: dialog.content!,
    );
  }
}

class _EnterIdentityPane extends StatelessWidget {
  final SyblInviteLink? invite;
  final bool linkEntry;
  final bool chosen;
  final bool nearby;
  final TextEditingController controller;
  final bool enabled;
  final String? error;
  final VoidCallback onChanged;
  final VoidCallback onPaste;
  final VoidCallback onSubmit;

  const _EnterIdentityPane({
    required this.invite,
    this.linkEntry = false,
    this.chosen = false,
    this.nearby = false,
    required this.controller,
    required this.enabled,
    required this.error,
    required this.onChanged,
    required this.onPaste,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (invite case final value?) ...[
          // A person, not an ID: the invite reads as someone reaching out.
          Row(
            key: const ValueKey('friend-invite-confirmation'),
            children: [
              SyblAvatar(
                label: value.displayName.isEmpty ? '?' : value.displayName,
                size: 48,
                color: context.syblColors.amber,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Gravity(
                      child: Text(
                        value.displayName.isEmpty
                            ? 'You have a friend invite'
                            : chosen
                            ? value.displayName
                            : '${value.displayName} invited you',
                        style: context.syblColors.display.copyWith(
                          fontSize: 18,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Gravity(
                      child: Text(
                        chosen
                            ? 'They’ll get a request to accept.'
                            : 'Add them as a friend? They’ll get a request to accept.',
                        style: TextStyle(
                          color: context.syblColors.muted,
                          fontSize: 13,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (value.displayName.isNotEmpty) ...[
            const SizedBox(height: 8),
            Gravity(
              child: Text(
                nearby
                    ? 'The name comes from their device nearby.'
                    : 'The name comes from the invite link.',
                style: TextStyle(color: context.syblColors.faint, fontSize: 11),
              ),
            ),
          ],
        ],
        const SizedBox(height: 14),
        if (invite == null)
          Gravity(
            child: TextField(
              key: const ValueKey('friend-id-field'),
              controller: controller,
              autofocus: SyblLayout.autofocusTextInput(context),
              enabled: enabled,
              maxLength: SyblInviteLink.maxLinkCharacters,
              autocorrect: false,
              enableSuggestions: false,
              textCapitalization: TextCapitalization.none,
              textInputAction: TextInputAction.done,
              style: TextStyle(
                color: context.syblColors.ink,
                fontFamily: 'monospace',
                fontSize: 13,
              ),
              decoration: InputDecoration(
                labelText: linkEntry ? 'Friend link' : 'Friend code or link',
                hintText: linkEntry
                    ? 'Doorlight link'
                    : 'Link or 40-character code',
                errorText: error,
                counterText: '',
                suffixIcon: IconButton(
                  key: const ValueKey('paste-friend-id'),
                  tooltip: 'Paste',
                  onPressed: enabled ? onPaste : null,
                  icon: const Icon(Icons.content_paste_rounded, size: 19),
                ),
              ),
              onChanged: (_) => onChanged(),
              onSubmitted: (_) => onSubmit(),
            ),
          ),
      ],
    );
  }
}
