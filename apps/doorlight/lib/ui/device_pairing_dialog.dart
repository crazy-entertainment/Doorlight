import 'notice.dart';
import 'capture_sensitive_scope.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../state/app_state.dart';
import '../state/device_pairing.dart';
import '../state/device_link_rendezvous.dart';
import '../state/nearby.dart';
import '../theme.dart';
import 'account_share.dart';
import 'doorlight_brand.dart';
import 'gravity.dart';
import 'onboarding_surface.dart';
import 'friend_qr_scanner.dart';
import 'sybl_ui.dart';
import 'windows_chrome.dart';

Future<void> showDevicePairingDialog(
  BuildContext context, {
  required AppState state,
  required bool destination,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => CaptureSensitiveScope(
    protection: state.surfaceProtection,
    child: _DevicePairingDialog(state: state, destination: destination),
  ),
);

Future<void> showDevicePairingPage(
  BuildContext context, {
  required AppState state,
  bool destination = true,
}) => Navigator.of(context).push<void>(
  PageRouteBuilder<void>(
    transitionDuration: SyblMotion.duration(
      context,
      const Duration(milliseconds: 420),
    ),
    reverseTransitionDuration: SyblMotion.duration(
      context,
      const Duration(milliseconds: 420),
    ),
    pageBuilder: (_, _, _) => CaptureSensitiveScope(
      protection: state.surfaceProtection,
      child: WindowsChromeContent(
        onboarding: true,
        child: _DevicePairingDialog(
          state: state,
          destination: destination,
          page: true,
        ),
      ),
    ),
    transitionsBuilder: (context, animation, _, child) => OnboardingSurface(
      reuseAncestor: false,
      child: FadeTransition(
        opacity: animation.drive(CurveTween(curve: Curves.easeInOutCubic)),
        child: child,
      ),
    ),
  ),
);

class _DevicePairingDialog extends StatefulWidget {
  const _DevicePairingDialog({
    required this.state,
    required this.destination,
    this.page = false,
  });
  final AppState state;
  final bool destination, page;
  @override
  State<_DevicePairingDialog> createState() => _DevicePairingDialogState();
}

class _DevicePairingDialogState extends State<_DevicePairingDialog>
    with SingleTickerProviderStateMixin {
  final _uri = TextEditingController();
  final _code = TextEditingController();
  late final DevicePairingController _flow;
  late DeviceLinkRendezvous _local;
  late final (String?, int) _owner;
  bool _sendingOffer = false;
  bool _sentOffer = false;
  bool _localRetired = false;
  String? _error;
  bool _closing = false;
  bool _submitting = false;
  DevicePairingSnapshot? _closingSnapshot;
  bool _restarting = false;
  bool _showOffer = false;
  bool _showQr = false;
  Timer? _countdown;
  late final AnimationController _preparingLight;
  bool get _preparing =>
      widget.page &&
      !_closing &&
      _showQr &&
      widget.destination &&
      (_restarting ||
          (!_flow.needsRecovery &&
              _flow.error == null &&
              _error == null &&
              (_flow.snapshot == null ||
                  _flow.snapshot?.status == 'starting')));

  void _syncPreparingMotion() {
    if (_preparing && !MediaQuery.disableAnimationsOf(context)) {
      if (!_preparingLight.isAnimating) _preparingLight.repeat(reverse: true);
    } else {
      _preparingLight.stop();
      _preparingLight.value = 1;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPreparingMotion();
  }

  @override
  void initState() {
    super.initState();
    _flow = widget.state.devicePairing;
    _owner = widget.state.linkedDeviceOwner;
    _local = DeviceLinkRendezvous(
      role: widget.destination
          ? DeviceLinkRendezvousRole.destination
          : DeviceLinkRendezvousRole.source,
      transport: UdpNearbyTransport.forPlatform(widget.state.jami, port: 47322),
    )..addListener(_localChanged);
    widget.state.addListener(_stateChanged);
    if (widget.state.canUseDeviceLinkRendezvous) unawaited(_local.start());
    _preparingLight = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
      value: 1,
    );
    _flow.addListener(_changed);
    if (widget.page) {
      _countdown = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    }
    // The page starts with a choice; native preparation follows that choice.
    if (!widget.page &&
        widget.destination &&
        !_flow.hasVisit &&
        !_flow.needsRecovery &&
        !_flow.busy &&
        _flow.snapshot == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_begin());
      });
    }
  }

  bool get _canScan =>
      Theme.of(context).platform == TargetPlatform.android ||
      Theme.of(context).platform == TargetPlatform.iOS;

  void _stateChanged() {
    if (!widget.state.canUseDeviceLinkRendezvous ||
        widget.state.linkedDeviceOwner != _owner) {
      _localRetired = true;
      unawaited(_local.close());
    }
  }

  void _localChanged() {
    if (!mounted || _closing) return;
    setState(() {});
    unawaited(_sendOffer());
  }

  Future<void> _sendOffer() async {
    final offer = _flow.snapshot?.uri;
    if (!widget.destination ||
        _sentOffer ||
        _sendingOffer ||
        _local.selectedSourceToken == null ||
        offer == null ||
        !DevicePairingSnapshot.validOffer(offer) ||
        !widget.state.canUseDeviceLinkRendezvous ||
        widget.state.linkedDeviceOwner != _owner) {
      return;
    }
    _sendingOffer = true;
    final sent = await _local.sendOffer(
      offer: offer,
      name: widget.state.displayName.isEmpty
          ? 'New device'
          : widget.state.displayName,
    );
    _sendingOffer = false;
    if (mounted) setState(() => _sentOffer = sent);
  }

  Future<void> _scanSource() async {
    final raw = await scanQrText(
      context,
      title: 'Scan your other device',
      hint:
          'Open Settings → Devices → Link another device on your other device.',
      invalid: 'Use the device-link QR, not a friend QR.',
      accept: (value) => DeviceLinkRendezvous.sourceTokenFromQr(value) != null,
    );
    if (!mounted ||
        raw == null ||
        _closing ||
        ModalRoute.of(context)?.isCurrent != true ||
        !widget.state.canUseDeviceLinkRendezvous ||
        widget.state.linkedDeviceOwner != _owner) {
      return;
    }
    final token = DeviceLinkRendezvous.sourceTokenFromQr(raw)!;
    if (_local.status != DeviceLinkRendezvousStatus.ready) {
      await _local.close();
      if (!mounted ||
          _closing ||
          !widget.state.canUseDeviceLinkRendezvous ||
          widget.state.linkedDeviceOwner != _owner) {
        return;
      }
      _local.removeListener(_localChanged);
      _local.dispose();
      _local = DeviceLinkRendezvous(
        role: DeviceLinkRendezvousRole.destination,
        transport: UdpNearbyTransport.forPlatform(
          widget.state.jami,
          port: 47322,
        ),
      )..addListener(_localChanged);
      _localRetired = false;
      await _local.start();
      if (!mounted || _closing || !widget.state.canUseDeviceLinkRendezvous) {
        return;
      }
    }
    if (_local.selectSource(token)) {
      if (!_flow.hasVisit) await _begin();
      await _sendOffer();
    } else if (mounted) {
      setState(
        () => _error =
            'Could not connect locally. Check that both devices use the same Wi-Fi.',
      );
    }
  }

  Future<void> _scan() async {
    final offer = await scanQrText(
      context,
      title: 'Scan the link code',
      hint: 'Point your camera at the code on your new device.',
      invalid: 'This is not a Doorlight link code.',
      accept: DevicePairingSnapshot.validOffer,
    );
    if (!mounted || offer == null || _flow.hasVisit || _flow.busy) return;
    _uri.text = offer;
    await _begin();
  }

  Future<void> _copyOffer(String offer) async {
    await Clipboard.setData(ClipboardData(text: offer));
    if (!mounted) return;
    showNotice('Link code copied', duration: const Duration(seconds: 1));
  }

  void _changed() {
    if (!mounted || _closing) return;
    _syncPreparingMotion();
    if (widget.page &&
        widget.destination &&
        !_flow.hasVisit &&
        _flow.snapshot?.status == 'complete') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && ModalRoute.of(context)?.isCurrent == true) {
          Navigator.of(context).pop();
        }
      });
    }
    if (_flow.needsRecovery || _flow.snapshot?.terminal == true) {
      _uri.clear();
      _code.clear();
    }
    setState(() {});
    unawaited(_sendOffer());
  }

  Future<void> _begin() async {
    if (_submitting || _closing) return;
    setState(() {
      _error = null;
      _submitting = true;
    });
    final uri = _uri.text.trim();
    _uri.clear();
    final accepted = await widget.state.beginDevicePairing(
      destination: widget.destination,
      uri: uri,
      stillCurrent: () =>
          mounted &&
          !_closing &&
          widget.state.linkedDeviceOwner == _owner &&
          ModalRoute.of(context)?.isCurrent == true,
    );
    if (mounted) setState(() => _submitting = false);
    if (mounted && !accepted && _flow.error == null) {
      setState(
        () => _error =
            widget.state.devicePairingStartError ??
            'Could not begin linking. Try again.',
      );
    }
  }

  Future<void> _close() async {
    if (_closing) return;
    setState(() {
      _closingSnapshot = _flow.snapshot;
      _closing = true;
    });
    final closed = await _flow.cancel();
    unawaited(_local.close());
    if (!mounted) return;
    if (closed) {
      Navigator.of(context).pop();
    } else {
      setState(() => _closing = false);
    }
  }

  Future<void> _restart() async {
    if (_restarting || _flow.busy) return;
    setState(() {
      _restarting = true;
      _error = null;
    });
    _syncPreparingMotion();
    try {
      final cleared = await _flow.cancel();
      if (!mounted) return;
      if (cleared) {
        await _begin();
      } else {
        setState(() => _error = "Couldn't prepare a new link code. Try again.");
      }
    } finally {
      if (mounted) {
        setState(() => _restarting = false);
        _syncPreparingMotion();
      }
    }
  }

  @override
  void dispose() {
    _preparingLight.dispose();
    _countdown?.cancel();
    _flow.removeListener(_changed);
    widget.state.removeListener(_stateChanged);
    _local.removeListener(_localChanged);
    _local.dispose();
    if (_flow.hasVisit) _flow.retire();
    _uri.dispose();
    _code.dispose();
    super.dispose();
  }

  String _status(DevicePairingSnapshot? value) {
    if (_restarting) return 'Preparing your link code…';
    if (value == null) {
      if (_error != null || _flow.error != null) {
        return 'Linking could not start.';
      }
      return widget.destination
          ? 'Preparing your link code…'
          : 'Add your identity to another device.';
    }
    if (_flow.needsRecovery) {
      return "Couldn't prepare the link code.";
    }
    return switch (value.status) {
      'starting' => 'Preparing the secure device-link channel…',
      'waiting' =>
        'On your other Doorlight device, open\nSettings → Devices → Link another device\nand scan this code.',
      'connecting' => 'Contacting the destination device…',
      'consent' => 'Confirm this is your new device.',
      'codeIssued' => 'Enter this eight-digit code on the destination device.',
      'code' => 'Enter the eight-digit code displayed by your existing device.',
      'checking' => 'Checking the code with the source device…',
      'prepared' => 'Saving this installation’s privacy and microphone policy…',
      'confirming' ||
      'transferring' => 'Waiting for the secure exchange to finish…',
      'ready' => 'Ready to finish linking this device.',
      'complete' =>
        value.destination
            ? 'This device is linked.'
            : 'Finish linking on your new device.',
      'ended' => switch (value.error) {
        'timeout' => 'The five-minute offer expired.',
        'auth_error' => 'Code authentication failed. This link has ended.',
        'source_disabled' => 'The source was disabled. This link has ended.',
        'canceled' =>
          'The link was canceled. The other endpoint may need recovery.',
        _ =>
          'The link ended without success. Remove the inactive destination before trying again.',
      },
      _ => 'Link progress is unconfirmed. Use recovery before continuing.',
    };
  }

  String _expiryText() {
    final deadline = _flow.offerExpiresAt;
    if (deadline == null) return 'This code expires after five minutes.';
    final seconds = deadline.difference(DateTime.now()).inSeconds;
    if (seconds <= 0) return 'Check the link status';
    return 'Code expires in about ${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  Widget _linkStep(IconData icon, String title, String detail) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Gravity(
          child: Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: context.syblColors.amber.withValues(alpha: .08),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, size: 22, color: context.syblColors.amber),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Gravity(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Gravity(
                child: Text(
                  detail,
                  style: TextStyle(
                    color: context.syblColors.muted,
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final value = _closing ? _closingSnapshot : _flow.snapshot;
    final idle =
        !_submitting &&
        !_closing &&
        !_flow.hasVisit &&
        value?.status != 'complete';
    final viewport = MediaQuery.sizeOf(context);
    final wide =
        widget.page &&
        viewport.width >= 600 &&
        MediaQuery.textScalerOf(context).scale(1) <= 1.2;
    final qr = value?.uri.isNotEmpty == true
        ? Gravity(
            child: PairingOfferQr(
              offer: value!.uri,
              dimension: !widget.page
                  ? 200
                  : wide
                  ? (viewport.width * .4).clamp(260, 320)
                  : 280,
            ),
          )
        : null;
    final compact = wide && viewport.height < 600;
    final content = SizedBox(
      width: widget.page ? 390 : 480,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: widget.page && !wide
            ? CrossAxisAlignment.center
            : CrossAxisAlignment.start,
        children: [
          if (widget.page) ...[
            Align(
              alignment: wide ? Alignment.centerLeft : Alignment.center,
              child: Gravity(
                child: Text(
                  'Link this device',
                  style: context.syblColors.display.copyWith(
                    fontSize: compact ? 26 : 30,
                  ),
                ),
              ),
            ),
            SizedBox(height: compact ? 6 : 18),
          ],
          if (_preparing && (!widget.destination || _showQr)) ...[
            AnimatedBuilder(
              animation: _preparingLight,
              builder: (context, _) => Semantics(
                label: 'Preparing link code',
                child: Gravity(
                  child: DoorlightDoorMark(
                    size: 96,
                    illumination: .3 + .7 * _preparingLight.value,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (!(idle && !widget.destination) &&
              !(widget.destination &&
                  widget.page &&
                  !_showQr &&
                  (value == null ||
                      value.status == 'starting' ||
                      value.status == 'waiting')))
            Gravity(
              child: Text(
                _status(value),
                style: compact
                    ? const TextStyle(fontSize: 13, height: 1.3)
                    : null,
                textAlign: widget.page && !wide
                    ? TextAlign.center
                    : TextAlign.start,
              ),
            ),
          SizedBox(height: compact ? 8 : 16),
          if (widget.destination &&
              widget.page &&
              !_showQr &&
              (value == null ||
                  value.status == 'starting' ||
                  value.status == 'waiting')) ...[
            Gravity(
              child: Text(
                _sentOffer
                    ? 'Confirm this device on your other device.'
                    : 'Find your other device on the same Wi-Fi.',
                style: TextStyle(color: context.syblColors.muted),
              ),
            ),
            const SizedBox(height: 16),
            if (_canScan)
              Gravity(
                child: FilledButton.icon(
                  key: const ValueKey('pairing-scan-source'),
                  onPressed: _closing || _submitting || _sentOffer
                      ? null
                      : _scanSource,
                  icon: const Icon(Icons.qr_code_scanner_rounded, size: 28),
                  label: const Text('Scan QR code'),
                ),
              ),
            const SizedBox(height: 12),
            Gravity(child: const Text('Nearby devices')),
            for (final source in _local.sources)
              Gravity(
                child: ListTile(
                  leading: const Icon(Icons.radar_rounded),
                  title: Text(
                    source.name.isEmpty ? 'Doorlight device' : source.name,
                  ),
                  onTap: _sentOffer || _submitting
                      ? null
                      : () {
                          if (_local.selectSource(source.token)) {
                            unawaited(_begin());
                          }
                        },
                ),
              ),
            if (_local.sources.isEmpty)
              Gravity(
                child: Text(
                  'On your other device, choose Show link QR on the same Wi-Fi.',
                  style: TextStyle(color: context.syblColors.muted),
                ),
              ),
            Gravity(
              child: TextButton(
                key: const ValueKey('pairing-show-link-code'),
                onPressed: () {
                  setState(() => _showQr = true);
                  if (!_flow.hasVisit) unawaited(_begin());
                },
                child: Text(
                  _canScan ? 'Show this device’s code instead' : 'Show QR code',
                ),
              ),
            ),
          ],
          if (idle && !widget.destination) ...[
            Gravity(
              child: const Text(
                'Choose “Link this device” on your new device. Keep both open.',
              ),
            ),
            const SizedBox(height: 16),
            if (_local.qrText case final qrText?) ...[
              Center(
                child: Gravity(child: PairingOfferQr(offer: qrText)),
              ),
              const SizedBox(height: 8),
              Gravity(
                child: const Text(
                  'Scan with your new device, or choose this device in Nearby.',
                ),
              ),
              Gravity(
                child: TextButton(
                  onPressed: _local.hide,
                  child: const Text('Hide link QR'),
                ),
              ),
            ] else
              Gravity(
                child: OutlinedButton.icon(
                  key: const ValueKey('pairing-reveal-source'),
                  onPressed: _local.status == DeviceLinkRendezvousStatus.ready
                      ? () {
                          if (!_local.reveal(
                            widget.state.displayName.isEmpty
                                ? 'Doorlight device'
                                : widget.state.displayName,
                          )) {
                            setState(
                              () => _error =
                                  'Could not show a link QR. Reopen linking and try again.',
                            );
                          }
                        }
                      : null,
                  icon: const Icon(Icons.qr_code_rounded, size: 28),
                  label: const Text('Show link QR'),
                ),
              ),
            const SizedBox(height: 20),
            Gravity(
              child: Text(
                'Or use a code from your new device',
                style: TextStyle(color: context.syblColors.muted, fontSize: 13),
              ),
            ),
            const SizedBox(height: 12),
            for (final offer in _local.offers)
              Gravity(
                child: ListTile(
                  title: Text(offer.name.isEmpty ? 'New device' : offer.name),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () {
                    if (!_local.selectOffer(offer.nonce)) return;
                    _uri.text = offer.offer;
                    unawaited(_begin());
                  },
                ),
              ),
          ],
          if ((_flow.busy || _submitting) && !_preparing)
            const LinearProgressIndicator(),
          if (idle && !widget.destination && _canScan) ...[
            Gravity(
              child: FilledButton.icon(
                key: const ValueKey('pairing-scan'),
                onPressed: _flow.busy ? null : _scan,
                icon: const Icon(Icons.qr_code_scanner_rounded),
                label: const Text('Scan code'),
              ),
            ),
            const SizedBox(height: 8),
          ],
          if (idle && !widget.destination)
            Gravity(
              child: TextField(
                key: const ValueKey('pairing-offer-input'),
                controller: _uri,
                enabled: !_flow.busy,
                maxLength: 100,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'Link code from your new device',
                  hintText: 'Paste a device-link code',
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
          if (value != null &&
              value.uri.isNotEmpty &&
              (!widget.destination || !widget.page || _showQr)) ...[
            if (!wide) ...[Center(child: qr), const SizedBox(height: 16)],
            if (widget.page && value.status == 'waiting') ...[
              Gravity(
                child: Text(
                  'Waiting for your other device…',
                  style: TextStyle(
                    color: context.syblColors.muted,
                    fontSize: compact ? 13 : null,
                  ),
                ),
              ),
              SizedBox(height: compact ? 4 : 8),
              ExcludeSemantics(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var dot = 0; dot < 3; dot++)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Gravity(
                          child: Icon(
                            Icons.circle,
                            size: 5,
                            color: context.syblColors.amber,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              SizedBox(height: compact ? 6 : 16),
            ],
            if (!widget.page || _showOffer)
              Row(
                children: [
                  Expanded(
                    child: Gravity(
                      child: SelectableText(
                        value.uri,
                        key: const ValueKey('pairing-offer'),
                        maxLines: 2,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          color: context.syblColors.faint,
                        ),
                      ),
                    ),
                  ),
                  Gravity(
                    child: IconButton(
                      tooltip: 'Copy link code',
                      onPressed: () => _copyOffer(value.uri),
                      icon: const Icon(Icons.copy_rounded, size: 18),
                    ),
                  ),
                ],
              ),
            Gravity(
              child: Text(
                _expiryText(),
                style: TextStyle(
                  color: context.syblColors.muted,
                  fontSize: compact ? 13 : null,
                ),
              ),
            ),
            if (widget.page)
              Gravity(
                child: TextButton(
                  key: const ValueKey('pairing-show-link-code'),
                  style: compact
                      ? TextButton.styleFrom(
                          minimumSize: const Size(0, 40),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        )
                      : null,
                  onPressed: () => setState(() => _showOffer = !_showOffer),
                  child: Text(
                    _showOffer ? 'Hide link code' : 'Show link code instead',
                  ),
                ),
              ),
          ],
          if (value?.code.isNotEmpty == true)
            Gravity(
              child: SelectableText(
                value!.code,
                key: const ValueKey('pairing-code-display'),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 30),
              ),
            ),
          if (value?.peerId.isNotEmpty == true) ...[
            const SizedBox(height: 12),
            Gravity(child: const Text('Device identity')),
            Gravity(
              child: SelectableText(
                value!.peerId,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
          if (value?.status == 'code') ...[
            if (value!.invalidCode)
              Gravity(
                child: const Text(
                  'Incorrect code. Three attempts are allowed in total.',
                ),
              ),
            Gravity(
              child: TextField(
                key: const ValueKey('pairing-code-input'),
                controller: _code,
                enabled: !_flow.busy,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                maxLength: 8,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'Eight-digit linking code',
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
          ],
          if ((_flow.error != null || _error != null) &&
              (!widget.page || !_flow.needsRecovery))
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Gravity(
                child: Text(
                  _flow.error ?? _error!,
                  key: const ValueKey('pairing-error'),
                ),
              ),
            ),
          if (_local.error case final localError?)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Gravity(child: Text(localError)),
            ),
          if (_localRetired && !widget.destination)
            Gravity(
              child: const Text('Reopen linking to show a fresh QR code.'),
            ),
          if (_local.status == DeviceLinkRendezvousStatus.expired)
            Gravity(
              child: const Text(
                'Nearby linking expired. Reopen linking to try again.',
              ),
            ),
        ],
      ),
    );
    final waitingPage =
        widget.page && value?.status == 'waiting' && qr != null && _showQr;
    final instructions = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Gravity(
          child: Text(
            'Link this device',
            style: context.syblColors.display.copyWith(
              fontSize: wide ? 34 : 30,
            ),
          ),
        ),
        const SizedBox(height: 12),
        _linkStep(
          Icons.devices_rounded,
          'Open device settings',
          'Settings → Devices → Link another device',
        ),
        _linkStep(
          _showOffer
              ? Icons.content_paste_rounded
              : Icons.qr_code_scanner_rounded,
          _showOffer ? 'Paste this link code' : 'Scan this QR code',
          _showOffer
              ? 'Copy it to the link-code field on your other device.'
              : 'Use the scanner in Doorlight.',
        ),
        _linkStep(
          Icons.door_front_door_outlined,
          'Complete linking',
          'Approve linking, then enter its code here.',
        ),
      ],
    );
    final qrPanel = Container(
      width:
          (wide ? (viewport.width * .4).clamp(260, 320) : 280) +
          (compact ? 24 : 32),
      padding: EdgeInsets.all(compact ? 12 : 16),
      decoration: BoxDecoration(
        color: context.syblColors.surfaceHi,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: context.syblColors.muted.withValues(alpha: .22),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Gravity(
            child: SegmentedButton<bool>(
              key: const ValueKey('pairing-display-choice'),
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: false,
                  icon: Icon(Icons.qr_code_rounded),
                  label: Text('QR'),
                ),
                ButtonSegment(
                  value: true,
                  icon: Icon(Icons.text_snippet_outlined),
                  label: Text('Code', key: ValueKey('pairing-show-link-code')),
                ),
              ],
              selected: {_showOffer},
              onSelectionChanged: (selection) =>
                  setState(() => _showOffer = selection.single),
            ),
          ),
          if (!compact) ...[
            const SizedBox(height: 4),
            Gravity(
              child: Text(
                _showOffer
                    ? 'Paste on your other device'
                    : 'Scan on your other device',
                textAlign: TextAlign.center,
                style: TextStyle(color: context.syblColors.muted, fontSize: 13),
              ),
            ),
          ],
          SizedBox(height: compact ? 12 : 20),
          if (_showOffer && value != null) ...[
            Gravity(
              child: SelectableText(
                value.uri,
                key: const ValueKey('pairing-offer'),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              ),
            ),
            const SizedBox(height: 12),
            Gravity(
              child: OutlinedButton.icon(
                onPressed: () => _copyOffer(value.uri),
                icon: const Icon(Icons.copy_rounded, size: 18),
                label: const Text('Copy link code'),
              ),
            ),
          ] else
            ?qr,
          SizedBox(height: compact ? 12 : 16),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Gravity(
                child: Icon(
                  Icons.schedule_rounded,
                  size: 17,
                  color: context.syblColors.muted,
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Gravity(
                  child: Text(
                    _expiryText(),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: context.syblColors.muted,
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
    final waitingContent = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (wide)
          Row(
            key: const ValueKey('pairing-wide-layout'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: instructions),
              const SizedBox(width: 28),
              qrPanel,
            ],
          )
        else ...[
          instructions,
          const SizedBox(height: 20),
          Center(child: qrPanel),
        ],
      ],
    );
    final actions = <Widget>[
      if (!widget.page)
        Gravity(
          child: TextButton(
            key: const ValueKey('pairing-close'),
            onPressed: _closing ? null : _close,
            child: Text(
              _flow.hasVisit && value?.status != 'complete'
                  ? 'Cancel linking'
                  : 'Close',
            ),
          ),
        ),
      if (idle &&
          (!widget.destination || _error != null || _flow.error != null))
        Gravity(
          child: FilledButton(
            key: const ValueKey('pairing-begin'),
            onPressed:
                _flow.busy ||
                    (!widget.destination &&
                        !DevicePairingSnapshot.validOffer(_uri.text.trim()))
                ? null
                : _begin,
            child: Text(widget.destination ? 'Try again' : 'Connect'),
          ),
        ),
      if (value?.status == 'consent')
        Gravity(
          child: FilledButton(
            key: const ValueKey('pairing-approve'),
            onPressed: _flow.busy ? null : _flow.approve,
            child: const Text('Authorize device'),
          ),
        ),
      if (value?.status == 'code')
        Gravity(
          child: FilledButton(
            key: const ValueKey('pairing-submit-code'),
            onPressed:
                _flow.busy || !DevicePairingSnapshot.validCode(_code.text)
                ? null
                : () {
                    final code = _code.text;
                    _code.clear();
                    unawaited(_flow.submitCode(code));
                  },
            child: const Text('Verify code'),
          ),
        ),
      if (_flow.canActivate && (!widget.page || !_flow.needsRecovery))
        Gravity(
          child: FilledButton(
            key: const ValueKey('pairing-activate'),
            onPressed: () => unawaited(_flow.activate()),
            child: const Text('Activate device'),
          ),
        ),
      if (_flow.needsRecovery)
        if (widget.page)
          Gravity(
            child: FilledButton(
              key: const ValueKey('pairing-retry'),
              onPressed: _flow.busy || _restarting ? null : _restart,
              child: const Text('Try again'),
            ),
          )
        else
          Gravity(
            child: TextButton(
              key: const ValueKey('pairing-recover'),
              onPressed: _flow.busy ? null : _flow.recover,
              child: const Text('Check link status'),
            ),
          ),
    ];
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_close());
      },
      child: widget.page
          ? Scaffold(
              key: const ValueKey('pairing-page'),
              backgroundColor: Colors.transparent,
              body: SafeArea(
                child: SingleChildScrollView(
                  padding: EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: compact ? 0 : 24,
                  ),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: wide ? 820 : 390),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SetupBackButton(
                            buttonKey: const ValueKey('pairing-close'),
                            onPressed: _closing ? null : _close,
                            label: _closing ? 'Canceling…' : 'Back',
                          ),
                          SizedBox(height: compact ? 0 : 20),
                          if (waitingPage)
                            waitingContent
                          else if (wide && qr != null && _showQr)
                            Row(
                              key: const ValueKey('pairing-wide-layout'),
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(child: content),
                                const SizedBox(width: 28),
                                qr,
                              ],
                            )
                          else
                            content,
                          if (actions.isNotEmpty) ...[
                            const SizedBox(height: 20),
                            Wrap(
                              alignment: WrapAlignment.center,
                              spacing: 12,
                              runSpacing: 12,
                              children: actions,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            )
          : AlertDialog(
              title: Gravity(
                child: Text(
                  widget.destination
                      ? 'Link this device'
                      : 'Link another device',
                ),
              ),
              content: SingleChildScrollView(child: content),
              actions: actions,
            ),
    );
  }
}
