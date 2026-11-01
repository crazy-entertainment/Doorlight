import 'notice.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';
import 'package:share_plus/share_plus.dart';

import '../core/invite_link.dart';
import '../core/jami_identity.dart';
import '../theme.dart';
import 'gravity.dart';
import 'sybl_ui.dart';

Future<void> showAccountShareDialog(
  BuildContext context, {
  required String jamiId,
  required String displayName,
  // One name for this surface wherever it opens from.
  String title = 'Invite a friend',
  String httpsOrigin = SyblInviteLink.configuredHttpsOrigin,
}) {
  if (Theme.of(context).platform == TargetPlatform.android ||
      Theme.of(context).platform == TargetPlatform.iOS) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => Scaffold(
          backgroundColor: context.syblColors.bg,
          appBar: AppBar(
            backgroundColor: context.syblColors.bg,
            title: Gravity(child: Text(title)),
          ),
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(28, 40, 28, 32),
              child: Center(
                child: AccountShareCard(
                  jamiId: jamiId,
                  displayName: displayName,
                  httpsOrigin: httpsOrigin,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Gravity(
        child: Text(
          title,
          style: context.syblColors.display.copyWith(fontSize: 19),
        ),
      ),
      content: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: AccountShareCard(
            jamiId: jamiId,
            displayName: displayName,
            httpsOrigin: httpsOrigin,
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

/// Shares the same public, untrusted invitation in the QR and system share sheet.
class AccountShareCard extends StatefulWidget {
  final String jamiId;
  final String displayName;
  final String httpsOrigin;

  const AccountShareCard({
    super.key,
    required this.jamiId,
    this.displayName = '',
    this.httpsOrigin = SyblInviteLink.configuredHttpsOrigin,
  });

  @override
  State<AccountShareCard> createState() => _AccountShareCardState();
}

class _AccountShareCardState extends State<AccountShareCard> {
  bool _showId = false;

  // The "copied link" of the invitation contract: the same invitation the QR
  // and Share carry, for any messenger.
  Future<void> _copyInvite(BuildContext context, String link) async {
    await Clipboard.setData(ClipboardData(text: link));
    if (!context.mounted) return;
    showNotice('Invite link copied', duration: const Duration(seconds: 1));
  }

  Future<void> _copyId(BuildContext context, String fingerprint) async {
    await Clipboard.setData(ClipboardData(text: fingerprint));
    if (!context.mounted) return;
    showNotice('Friend ID copied', duration: const Duration(seconds: 1));
  }

  @override
  Widget build(BuildContext context) {
    final fingerprint = JamiIdentity.fingerprint(widget.jamiId);
    final invite = SyblInviteLink.create(
      jamiId: widget.jamiId,
      displayName: widget.displayName,
    );
    if (fingerprint == null || invite == null) {
      return const SyblStatusPanel(
        key: ValueKey('jami-share-unavailable'),
        kind: SyblStatusKind.loading,
        title: 'Identity not ready',
        message: 'Your Friend ID will appear here after setup finishes.',
        compact: true,
      );
    }

    final mobile =
        Theme.of(context).platform == TargetPlatform.android ||
        Theme.of(context).platform == TargetPlatform.iOS;
    final compactHeight = MediaQuery.sizeOf(context).height < 700;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 340),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Same words on every platform; only the scale differs.
          Gravity(
            child: Text(
              'Show this to your friend',
              textAlign: TextAlign.center,
              style: context.syblColors.display.copyWith(
                fontSize: mobile ? 23 : 18,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Gravity(
            child: Text(
              'They can scan it in Add a friend.',
              textAlign: TextAlign.center,
              style: TextStyle(color: context.syblColors.muted, fontSize: 13),
            ),
          ),
          SizedBox(height: compactHeight ? 16 : 28),
          Gravity(
            child: Container(
              padding: EdgeInsets.all(mobile ? 14 : 0),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(mobile ? 20 : 0),
              ),
              child: Semantics(
                image: true,
                label: 'QR code for your Doorlight invitation',
                child: ExcludeSemantics(
                  child: FriendInviteQr(
                    invite: invite,
                    httpsOrigin: widget.httpsOrigin,
                    dimension: mobile && !compactHeight ? 216 : 176,
                  ),
                ),
              ),
            ),
          ),
          SizedBox(height: compactHeight ? 16 : 26),
          if (mobile) ...[
            SizedBox(
              width: double.infinity,
              child: Gravity(
                child: FilledButton.icon(
                  key: const ValueKey('share-friend-invitation'),
                  onPressed: () => SharePlus.instance.share(
                    ShareParams(
                      text: invite.shareUri(httpsOrigin: widget.httpsOrigin),
                    ),
                  ),
                  icon: const Icon(Icons.ios_share_rounded),
                  label: const Text('Share invitation'),
                ),
              ),
            ),
            const SizedBox(height: 10),
          ],
          SizedBox(
            width: double.infinity,
            child: Gravity(
              child: OutlinedButton.icon(
                key: const ValueKey('copy-friend-invite-link'),
                onPressed: () => _copyInvite(
                  context,
                  invite.shareUri(httpsOrigin: widget.httpsOrigin),
                ),
                icon: const Icon(Icons.link_rounded, size: 18),
                label: const Text('Copy invite link'),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Gravity(
            child: TextButton(
              key: const ValueKey('reveal-shared-jami-id'),
              onPressed: () => setState(() => _showId = !_showId),
              child: Text(_showId ? 'Hide Friend ID' : 'Show Friend ID'),
            ),
          ),
          if (_showId) ...[
            const SizedBox(height: 8),
            Gravity(
              child: Text(
                fingerprint,
                key: const ValueKey('share-jami-id'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: context.syblColors.muted,
                  fontFamily: 'monospace',
                  fontSize: 12,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Gravity(
              child: OutlinedButton.icon(
                key: const ValueKey('copy-shared-jami-id'),
                onPressed: () => _copyId(context, fingerprint),
                icon: const Icon(Icons.copy_rounded, size: 18),
                label: const Text('Copy Friend ID'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class FriendInviteQr extends StatelessWidget {
  final SyblInviteLink invite;
  final String httpsOrigin;
  final double dimension;

  const FriendInviteQr({
    super.key,
    required this.invite,
    this.httpsOrigin = SyblInviteLink.configuredHttpsOrigin,
    this.dimension = 176,
  });

  @override
  Widget build(BuildContext context) => _PublicQr(
    payload: invite.shareUri(httpsOrigin: httpsOrigin),
    qrKey: const ValueKey('friend-invite-qr'),
    dimension: dimension,
  );
}

/// The temporary device-link offer, scanned by the existing device.
class PairingOfferQr extends StatelessWidget {
  final String offer;
  final double dimension;

  const PairingOfferQr({super.key, required this.offer, this.dimension = 200});

  @override
  Widget build(BuildContext context) {
    final modules =
        QrCode.fromData(
          data: offer,
          errorCorrectLevel: QrErrorCorrectLevel.M,
        ).moduleCount +
        8;
    final ratio = MediaQuery.devicePixelRatioOf(context);
    // Include the four-module quiet zone on each side in the pixel grid.
    final pixelsPerModule = (dimension * ratio / modules).floor().clamp(
      1,
      1000,
    );
    return _PixelAlignedQr(
      ratio: ratio,
      child: _PublicQr(
        payload: offer,
        qrKey: const ValueKey('pairing-offer-qr'),
        dimension: pixelsPerModule * modules / ratio,
        quietZonePadding: 4 * pixelsPerModule / ratio,
      ),
    );
  }
}

class _PixelAlignedQr extends SingleChildRenderObjectWidget {
  const _PixelAlignedQr({required this.ratio, required super.child});
  final double ratio;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _PixelAlignedQrBox(ratio);

  @override
  void updateRenderObject(
    BuildContext context,
    _PixelAlignedQrBox renderObject,
  ) {
    renderObject.ratio = ratio;
    renderObject.markNeedsPaint();
  }
}

class _PixelAlignedQrBox extends RenderProxyBox {
  _PixelAlignedQrBox(this.ratio);
  double ratio;

  @override
  void paint(PaintingContext context, Offset offset) {
    final origin = localToGlobal(Offset.zero);
    final aligned = Offset(
      (origin.dx * ratio).round() / ratio,
      (origin.dy * ratio).round() / ratio,
    );
    super.paint(context, offset + aligned - origin);
  }
}

class _PublicQr extends StatelessWidget {
  final String payload;
  final Key qrKey;
  final double dimension;
  final double quietZonePadding;

  const _PublicQr({
    required this.payload,
    required this.qrKey,
    this.dimension = 176,
    this.quietZonePadding = 0,
  });

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      key: qrKey,
      child: SizedBox.square(
        dimension: dimension,
        child: ColoredBox(
          color: Colors.white,
          child: Padding(
            padding: EdgeInsets.all(quietZonePadding),
            child: PrettyQrView.data(
              data: payload,
              errorCorrectLevel: QrErrorCorrectLevel.M,
              decoration: PrettyQrDecoration(
                background: Colors.white,
                quietZone: quietZonePadding > 0
                    ? PrettyQrQuietZone.zero
                    : PrettyQrQuietZone.standard,
                shape: const PrettyQrSquaresSymbol(),
              ),
              errorBuilder: (context, error, stackTrace) => ColoredBox(
                color: Colors.white,
                child: Center(
                  child: Icon(
                    Icons.broken_image_outlined,
                    color: context.syblColors.danger,
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
