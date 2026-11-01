import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/jami.dart';
import '../theme.dart';
import 'gravity.dart';

abstract final class SyblLayout {
  static const desktopBreakpoint = 620.0;
  static const railWidth = 212.0;

  /// Keep the software keyboard closed until someone taps an input on phones.
  static bool autofocusTextInput(BuildContext context) =>
      Theme.of(context).platform != TargetPlatform.android &&
      Theme.of(context).platform != TargetPlatform.iOS;

  static bool isCompact(BuildContext context) =>
      MediaQuery.sizeOf(context).width < desktopBreakpoint;
}

abstract final class SyblMotion {
  static Duration duration(
    BuildContext context, [
    Duration normal = const Duration(milliseconds: 180),
  ]) => MediaQuery.disableAnimationsOf(context) ? Duration.zero : normal;
}

class SetupBackButton extends StatelessWidget {
  const SetupBackButton({
    super.key,
    this.buttonKey,
    required this.onPressed,
    this.label = 'Back',
  });
  final VoidCallback? onPressed;
  final Key? buttonKey;
  final String label;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: Gravity(
      child: TextButton.icon(
        key: buttonKey,
        onPressed: onPressed,
        icon: const Icon(Icons.arrow_back_rounded, size: 18),
        label: Text(label),
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
          foregroundColor: context.syblColors.muted,
        ),
      ),
    ),
  );
}

class SyblAvatar extends StatefulWidget {
  final String label;
  final Color? color;
  final Color? statusColor;
  final IconData? statusIcon;
  final String? statusLabel;
  final double size;
  final bool statusOnLeft;
  final double statusOpacity;
  final String? imageBase64;

  const SyblAvatar({
    super.key,
    required this.label,
    this.color,
    this.statusColor,
    this.statusIcon,
    this.statusLabel,
    this.size = 38,
    this.statusOnLeft = false,
    this.statusOpacity = 1,
    this.imageBase64,
  });

  @override
  State<SyblAvatar> createState() => _SyblAvatarState();
}

class _SyblAvatarState extends State<SyblAvatar> {
  Uint8List? _imageBytes;

  @override
  void initState() {
    super.initState();
    _decodeImage();
  }

  @override
  void didUpdateWidget(covariant SyblAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageBase64 != widget.imageBase64) _decodeImage();
  }

  void _decodeImage() {
    final value = widget.imageBase64;
    if (value == null || value.isEmpty) {
      _imageBytes = null;
      return;
    }
    try {
      _imageBytes = ProfileWireContract.decodeAvatar(value) == null
          ? null
          : base64Decode(value);
    } on FormatException {
      _imageBytes = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final trimmed = widget.label.trim();
    final phoneStatus = widget.statusIcon == Icons.phone_iphone_rounded;
    final initial = trimmed.isEmpty
        ? '?'
        : trimmed.characters.first.toUpperCase();
    final background = widget.color ?? context.syblColors.rose;
    final foreground = context.syblColors.foregroundFor(background);
    final placeholder = DecoratedBox(
      decoration: BoxDecoration(color: background),
      child: Center(
        child: Text(
          initial,
          style: context.syblColors.display.copyWith(
            color: foreground,
            fontSize: widget.size * .42,
          ),
        ),
      ),
    );
    final decodeSize = (widget.size * MediaQuery.devicePixelRatioOf(context))
        .ceil()
        .clamp(1, ProfileWireContract.maxAvatarDimension)
        .toInt();
    return Gravity(
      weight: 3,
      child: Semantics(
        container: true,
        image: true,
        label: widget.statusLabel == null
            ? '${widget.label} avatar'
            : '${widget.label}, ${widget.statusLabel}',
        child: ExcludeSemantics(
          child: SizedBox.square(
            dimension: widget.size,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                ClipOval(
                  child: SizedBox.square(
                    dimension: widget.size,
                    child: _imageBytes == null
                        ? placeholder
                        : Image.memory(
                            _imageBytes!,
                            fit: BoxFit.cover,
                            gaplessPlayback: true,
                            cacheWidth: decodeSize,
                            cacheHeight: decodeSize,
                            errorBuilder: (_, _, _) => placeholder,
                          ),
                  ),
                ),
                if (widget.statusColor != null)
                  Positioned(
                    right: widget.statusOnLeft ? null : -1,
                    left: widget.statusOnLeft ? -1 : null,
                    bottom: -1,
                    child: Opacity(
                      opacity: widget.statusOpacity,
                      child: DecoratedBox(
                        key: ValueKey(
                          phoneStatus
                              ? 'phone-presence-badge'
                              : 'round-presence-badge',
                        ),
                        decoration: BoxDecoration(
                          shape: phoneStatus
                              ? BoxShape.rectangle
                              : BoxShape.circle,
                          borderRadius: phoneStatus
                              ? BorderRadius.circular(4.5)
                              : null,
                          color: widget.statusIcon == null
                              ? widget.statusColor
                              : context.syblColors.bg,
                          border: Border.all(
                            color: context.syblColors.bg,
                            width: 2,
                          ),
                        ),
                        child: SizedBox(
                          width: phoneStatus ? 13 : 11,
                          height: phoneStatus ? 16 : 11,
                          child: widget.statusIcon == null
                              ? null
                              : Icon(
                                  widget.statusIcon,
                                  size: phoneStatus ? 11 : 9,
                                  color: widget.statusColor,
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

enum SyblStatusKind { empty, loading, error }

class SyblStatusPanel extends StatelessWidget {
  final SyblStatusKind kind;
  final String title;
  final String message;
  final Widget? action;
  final bool compact;

  const SyblStatusPanel({
    super.key,
    required this.kind,
    required this.title,
    this.message = '',
    this.action,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final icon = switch (kind) {
      SyblStatusKind.empty => Icons.people_outline_rounded,
      SyblStatusKind.loading => Icons.hourglass_empty_rounded,
      SyblStatusKind.error => Icons.error_outline_rounded,
    };
    final color = kind == SyblStatusKind.error
        ? context.syblColors.danger
        : context.syblColors.faint;
    return Center(
      child: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: Padding(
            padding: EdgeInsets.all(compact ? 16 : 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Gravity(
                  child: Icon(icon, size: compact ? 28 : 34, color: color),
                ),
                const SizedBox(height: 10),
                Gravity(
                  child: Text(
                    title,
                    textAlign: TextAlign.center,
                    style: context.syblColors.display.copyWith(
                      fontSize: compact ? 16 : 18,
                    ),
                  ),
                ),
                if (message.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  Gravity(
                    child: Text(
                      message,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: context.syblColors.muted,
                        fontSize: 12,
                        height: 1.45,
                      ),
                    ),
                  ),
                ],
                if (action != null) ...[const SizedBox(height: 14), action!],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class SyblSectionLabel extends StatelessWidget {
  final String text;

  const SyblSectionLabel(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Gravity(
    child: Text(
      text.toUpperCase(),
      style: TextStyle(
        color: context.syblColors.faint,
        fontSize: 11,
        letterSpacing: .65,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

class SyblPillIconButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool emphasized;

  const SyblPillIconButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.emphasized = false,
  });

  @override
  Widget build(BuildContext context) {
    return Gravity(
      child: Semantics(
        button: true,
        enabled: onPressed != null,
        label: label,
        child: Tooltip(
          message: label,
          child: SizedBox.square(
            dimension: 48,
            child: IconButton(
              onPressed: onPressed,
              style: context.syblColors.neutralButtonFill != null
                  ? context.syblColors.secondaryButtonStyle
                  : IconButton.styleFrom(
                      foregroundColor: emphasized
                          ? context.syblColors.onAccent
                          : context.syblColors.amber,
                      backgroundColor: emphasized
                          ? context.syblColors.accentFill
                          : Colors.transparent,
                      side: BorderSide(
                        color: onPressed == null
                            ? context.syblColors.line
                            : context.syblColors.amber,
                      ),
                    ),
              icon: Icon(icon, size: 19),
            ),
          ),
        ),
      ),
    );
  }
}
