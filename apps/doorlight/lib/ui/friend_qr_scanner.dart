import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image/image.dart' as img;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:zxing2/qrcode.dart'
    show
        BinaryBitmap,
        DecodeHintType,
        DecodeHints,
        GlobalHistogramBinarizer,
        HybridBinarizer,
        QRCodeReader,
        ReaderException,
        RGBLuminanceSource;

import '../core/invite_link.dart';
import '../core/image_bounds.dart';
import '../core/jami_identity.dart';
import '../theme.dart';
import 'gravity.dart';

Future<SyblInviteLink?> scanFriendQr(BuildContext context) {
  final route = MaterialPageRoute<SyblInviteLink>(
    builder: (_) => const _QrScanner<SyblInviteLink>(
      title: 'Scan a friend’s QR code',
      hint: 'Point your camera at your friend’s invitation QR.',
      invalid: 'This is not a Doorlight friend QR code.',
      resolve: friendInviteFromQr,
    ),
  );
  Navigator.of(context).push(route);
  // The caller must regain route authority before confirming this result.
  return route.completed;
}

/// Scans a QR code and returns its text once [accept] recognises it.
Future<String?> scanQrText(
  BuildContext context, {
  required String title,
  required String hint,
  required String invalid,
  required bool Function(String value) accept,
}) {
  final route = MaterialPageRoute<String>(
    builder: (_) => _QrScanner<String>(
      title: title,
      hint: hint,
      invalid: invalid,
      resolve: (raw) {
        final value = raw.trim();
        return accept(value) ? value : null;
      },
    ),
  );
  Navigator.of(context).push(route);
  return route.completed;
}

SyblInviteLink? friendInviteFromQr(String raw) {
  final invite = SyblInviteLink.tryParse(raw);
  if (invite != null) return invite;
  final fingerprint = JamiIdentity.fingerprint(raw);
  return fingerprint == null ? null : SyblInviteLink(jamiId: fingerprint);
}

class _QrScanner<T extends Object> extends StatefulWidget {
  const _QrScanner({
    required this.title,
    required this.hint,
    required this.invalid,
    required this.resolve,
  });

  final String title;
  final String hint;
  final String invalid;
  final T? Function(String raw) resolve;

  @override
  State<_QrScanner<T>> createState() => _QrScannerState<T>();
}

class _QrScannerState<T extends Object> extends State<_QrScanner<T>> {
  final _camera = MobileScannerController(formats: [BarcodeFormat.qrCode]);
  bool _found = false;
  String? _error;

  @override
  void dispose() {
    _camera.dispose();
    super.dispose();
  }

  void _detected(BarcodeCapture capture) {
    if (_found) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null) continue;
      final resolved = widget.resolve(raw);
      if (resolved == null) {
        if (_error == null) {
          setState(() => _error = widget.invalid);
        }
        continue;
      }
      _found = true;
      Navigator.of(context).pop(resolved);
      return;
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: context.syblColors.bg,
    appBar: AppBar(title: Gravity(child: Text(widget.title))),
    body: SafeArea(
      child: Column(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: MobileScanner(
                  controller: _camera,
                  onDetect: _detected,
                  errorBuilder: (context, error) => Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Gravity(
                        child: Text(
                          'Camera unavailable. Allow camera access, then try again.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: context.syblColors.ink),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Gravity(
              child: Text(
                _error ?? widget.hint,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _error == null
                      ? context.syblColors.muted
                      : context.syblColors.danger,
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// Encoded input cap; the decoder separately bounds dimensions and expansion.
const maxFriendQrImageBytes = 20 * 1024 * 1024;

/// Desktop has no camera scanner, so a friend's QR arrives as a screenshot or
/// photo. Returns null when the picker is cancelled and throws
/// [FormatException] when the image holds no Doorlight friend QR.
Future<SyblInviteLink?> pickFriendQrImage() async {
  final file = await openFile(
    acceptedTypeGroups: const [
      XTypeGroup(
        label: 'Images',
        extensions: ['png', 'jpg', 'jpeg', 'bmp', 'gif', 'webp'],
      ),
    ],
  );
  if (file == null) return null;
  if (await file.length() > maxFriendQrImageBytes) {
    throw const FormatException('This image is too large.');
  }
  final buffer = BytesBuilder(copy: false);
  await for (final chunk in file.openRead(0, maxFriendQrImageBytes + 1)) {
    if (buffer.length + chunk.length > maxFriendQrImageBytes) {
      throw const FormatException('This image is too large.');
    }
    buffer.add(chunk);
  }
  final bytes = buffer.takeBytes();
  final invite = await Isolate.run(() => friendInviteFromQrImage(bytes));
  if (invite == null) {
    throw const FormatException('No Doorlight friend QR code in this image.');
  }
  return invite;
}

SyblInviteLink? friendInviteFromQrImage(Uint8List bytes) {
  img.Image? image;
  try {
    image = decodeBoundedRaster(bytes, maxEncodedBytes: maxFriendQrImageBytes);
  } catch (_) {
    return null; // Corrupt or truncated files throw instead of returning null.
  }
  if (image == null) return null;
  return _friendInviteFromImage(image);
}

/// Decodes one raw RGBA frame, such as a webcam preview snapshot.
SyblInviteLink? friendInviteFromRgba(Uint8List rgba, int width, int height) =>
    _friendInviteFromImage(
      img.Image.fromBytes(
        width: width,
        height: height,
        bytes: rgba.buffer,
        numChannels: 4,
      ),
    );

SyblInviteLink? _friendInviteFromImage(img.Image image) {
  // Large photos decode slowly without helping the finder patterns.
  if (image.width > 1600 || image.height > 1600) {
    image = image.width >= image.height
        ? img.copyResize(image, width: 1600)
        : img.copyResize(image, height: 1600);
  }
  final source = RGBLuminanceSource(
    image.width,
    image.height,
    image
        .convert(numChannels: 4)
        .getBytes(order: img.ChannelOrder.abgr)
        .buffer
        .asInt32List(),
  );
  final hints = DecodeHints()..put(DecodeHintType.tryHarder);
  for (final binarizer in [
    HybridBinarizer(source),
    GlobalHistogramBinarizer(source),
  ]) {
    try {
      final text = QRCodeReader().decode(BinaryBitmap(binarizer), hints: hints);
      return friendInviteFromQr(text.text);
    } on ReaderException {
      continue;
    }
  }
  return null;
}

/// A live webcam view for desktop that reports the first Doorlight friend QR
/// it sees. Frames are read from the on-screen preview in memory; the Windows
/// camera plugin's picture capture would write them into the user's Pictures.
class DesktopQrCamera extends StatefulWidget {
  const DesktopQrCamera({
    super.key,
    required this.onInvite,
    required this.onUpload,
  });

  final ValueChanged<SyblInviteLink> onInvite;

  /// Opens a QR screenshot or photo instead; offered inside the viewfinder.
  final VoidCallback onUpload;

  @override
  State<DesktopQrCamera> createState() => _DesktopQrCameraState();
}

class _DesktopQrCameraState extends State<DesktopQrCamera> {
  final _frame = GlobalKey();
  int? _cameraId;
  double _aspect = 4 / 3;
  String? _message;
  Timer? _scan;
  bool _decoding = false;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    final camera = CameraPlatform.instance;
    int? id;
    try {
      final cameras = await camera.availableCameras();
      if (cameras.isEmpty) {
        if (!_disposed) setState(() => _message = 'No webcam found');
        return;
      }
      id = await camera.createCameraWithSettings(
        cameras.first,
        const MediaSettings(resolutionPreset: ResolutionPreset.medium),
      );
      final ready = camera.onCameraInitialized(id).first;
      await camera.initializeCamera(id);
      final size = await ready;
      if (_disposed) {
        await camera.dispose(id);
        return;
      }
      setState(() {
        _cameraId = id;
        if (size.previewWidth > 0 && size.previewHeight > 0) {
          _aspect = size.previewWidth / size.previewHeight;
        }
      });
      _scan = Timer.periodic(const Duration(milliseconds: 400), (_) => _read());
    } catch (_) {
      if (id != null) unawaited(camera.dispose(id).catchError((_) {}));
      if (!_disposed) {
        setState(
          () => _message =
              'Webcam unavailable. Check camera access in Windows settings.',
        );
      }
    }
  }

  Future<void> _read() async {
    final boundary = _frame.currentContext?.findRenderObject();
    if (_decoding || boundary is! RenderRepaintBoundary) return;
    _decoding = true;
    try {
      final image = await boundary.toImage();
      final width = image.width, height = image.height;
      final bytes = await image.toByteData();
      image.dispose();
      if (bytes == null || _disposed) return;
      final rgba = bytes.buffer.asUint8List();
      final invite = await Isolate.run(
        () => friendInviteFromRgba(rgba, width, height),
      );
      if (invite != null && !_disposed) {
        _scan?.cancel();
        widget.onInvite(invite);
      }
    } catch (_) {
      // A dropped frame is retried on the next tick.
    } finally {
      _decoding = false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _scan?.cancel();
    if (_cameraId case final id?) {
      unawaited(CameraPlatform.instance.dispose(id).catchError((_) {}));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.syblColors;
    final id = _cameraId;
    final feed = id != null
        ? RepaintBoundary(
            key: _frame,
            child: CameraPlatform.instance.buildPreview(id),
          )
        : Center(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 56),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Gravity(
                    child: Icon(
                      _message == null
                          ? Icons.videocam_outlined
                          : Icons.videocam_off_outlined,
                      size: 30,
                      color: colors.faint,
                    ),
                  ),
                  if (_message case final message?) ...[
                    const SizedBox(height: 8),
                    Gravity(
                      child: Text(
                        message,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: colors.muted, fontSize: 12),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
    // One viewfinder: the webcam (or why there is none) with the image
    // upload tucked inside it.
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 260),
        child: AspectRatio(
          aspectRatio: _aspect,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(color: Colors.black.withValues(alpha: .35)),
                feed,
                IgnorePointer(
                  child: CustomPaint(painter: _ViewfinderCorners(colors.amber)),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 12,
                  child: Center(
                    child: Gravity(
                      child: FilledButton.icon(
                        key: const ValueKey('friend-qr-button'),
                        style: FilledButton.styleFrom(
                          backgroundColor: colors.bg.withValues(alpha: .78),
                          foregroundColor:
                              colors.neutralButtonForeground ?? colors.amber,
                          minimumSize: const Size(0, 36),
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          shape: colors.buttonShape.copyWith(
                            side: BorderSide(
                              color:
                                  colors.neutralButtonBorder ??
                                  colors.amber.withValues(alpha: .35),
                            ),
                          ),
                        ),
                        onPressed: widget.onUpload,
                        icon: const Icon(Icons.upload_rounded, size: 18),
                        label: const Text('Upload a QR image'),
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

/// Amber corner brackets framing the scan area.
class _ViewfinderCorners extends CustomPainter {
  _ViewfinderCorners(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    const inset = 14.0, arm = 22.0;
    final r = Rect.fromLTRB(
      inset,
      inset,
      size.width - inset,
      size.height - inset,
    );
    for (final (corner, dx, dy) in [
      (r.topLeft, 1.0, 1.0),
      (r.topRight, -1.0, 1.0),
      (r.bottomLeft, 1.0, -1.0),
      (r.bottomRight, -1.0, -1.0),
    ]) {
      canvas.drawPath(
        Path()
          ..moveTo(corner.dx, corner.dy + dy * arm)
          ..lineTo(corner.dx, corner.dy)
          ..lineTo(corner.dx + dx * arm, corner.dy),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_ViewfinderCorners old) => old.color != color;
}
