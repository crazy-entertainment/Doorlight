import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'playful_tap.dart';

/// A word that spins to the next one like a slot reel: the current word rolls
/// up and out while the next rolls in from below. The surrounding line glides
/// to its new width instead of jumping.
///
/// [words] loops while running. Reduced-motion users only see the first word.
class SpinningWord extends StatefulWidget {
  const SpinningWord({
    super.key,
    required this.words,
    required this.style,
    this.styles,
    this.strutStyle,
    this.interval = const Duration(milliseconds: 1700),
    this.running = true,
    this.alignment = Alignment.center,
    this.maxWidth,
    this.interactive = false,
  }) : assert(styles == null || styles.length == words.length);

  final List<String> words;
  final TextStyle style;

  /// One style per word, in place of [style], so each word can wear its own
  /// face and size.
  final List<TextStyle>? styles;

  /// Pins every word to one line box, so a taller face cannot push the
  /// surrounding lines around. Glyphs may then bleed above and below it.
  final StrutStyle? strutStyle;

  final Duration interval;
  final bool running;

  /// Where each word sits while the reel resizes; [Alignment.centerLeft]
  /// keeps the word's leading edge fixed for inline use.
  final Alignment alignment;

  /// Words wider than this shrink to fit instead of overflowing.
  final double? maxWidth;

  /// Tapping builds a temporary speed boost; idle time restores the usual pace.
  final bool interactive;

  @override
  State<SpinningWord> createState() => _SpinningWordState();
}

class _SpinningWordState extends State<SpinningWord> {
  static const _spin = Duration(milliseconds: 420);
  int _index = 0;
  Timer? _timer;
  Timer? _cooldown;
  double _boost = 0;

  Duration get _period => _boost == 0
      ? widget.interval
      : Duration(
          milliseconds:
              (widget.interval.inMilliseconds / math.pow(1.65, _boost))
                  .round()
                  .clamp(70, widget.interval.inMilliseconds),
        );

  Duration get _transition => _boost == 0
      ? _spin
      : Duration(
          milliseconds: math.min(420, (_period.inMilliseconds * .8).round()),
        );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(SpinningWord oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_index >= widget.words.length) _index = 0;
    _sync();
  }

  void _sync() {
    final run =
        widget.running &&
        widget.words.length > 1 &&
        !MediaQuery.disableAnimationsOf(context);
    if (!run) {
      _timer?.cancel();
      _timer = null;
      _cooldown?.cancel();
      _cooldown = null;
      _boost = 0;
      return;
    }
    _timer ??= Timer(_period, _advance);
  }

  void _advance() {
    _timer = null;
    if (!mounted) return;
    setState(() => _index = (_index + 1) % widget.words.length);
    _sync();
  }

  void _speedUp() {
    if (!widget.running || MediaQuery.disableAnimationsOf(context)) return;
    _timer?.cancel();
    _timer = null;
    _cooldown?.cancel();
    setState(() {
      _boost = math.min(6, _boost + .25);
    });
    _advance();
    _cooldown = Timer(const Duration(milliseconds: 900), _slowDown);
  }

  void _slowDown() {
    if (!mounted) return;
    _timer?.cancel();
    _timer = null;
    setState(() => _boost = math.max(0, _boost - 1));
    _sync();
    if (_boost > 0) {
      _cooldown = Timer(const Duration(milliseconds: 550), _slowDown);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _cooldown?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Keyed by position: a word may come round more than once.
    final key = ValueKey(_index);
    final text = Text(
      widget.words[_index],
      style: widget.styles?[_index] ?? widget.style,
      strutStyle: widget.strutStyle,
    );
    final reel = AnimatedSwitcher(
      duration: _transition,
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (current, previous) => Stack(
        alignment: widget.alignment,
        clipBehavior: Clip.none,
        children: [...previous, ?current],
      ),
      transitionBuilder: (child, animation) {
        final incoming = child.key == key;
        return SlideTransition(
          position: Tween<Offset>(
            begin: Offset(0, incoming ? 1 : -1),
            end: Offset.zero,
          ).animate(animation),
          child: FadeTransition(opacity: animation, child: child),
        );
      },
      child: widget.maxWidth == null
          ? KeyedSubtree(key: key, child: text)
          : ConstrainedBox(
              key: key,
              constraints: BoxConstraints(maxWidth: widget.maxWidth!),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                // Shrink toward roughly the baseline so the word stays
                // on the line instead of floating above it.
                alignment: Alignment(widget.alignment.x, .5),
                child: text,
              ),
            ),
    );
    Widget viewport = reel;
    if (widget.strutStyle != null) {
      // Keep the mask still as faces change. Resizing a clipped line during
      // its roll exposes a moving edge across the incoming glyphs.
      var width = 0.0;
      var height = 0.0;
      for (var i = 0; i < widget.words.length; i++) {
        final painter = TextPainter(
          text: TextSpan(
            text: widget.words[i],
            style: DefaultTextStyle.of(
              context,
            ).style.merge(widget.styles?[i] ?? widget.style),
          ),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          strutStyle: widget.strutStyle,
          maxLines: 1,
        )..layout();
        width = math.max(width, painter.width);
        height = math.max(height, painter.height);
        painter.dispose();
      }
      viewport = SizedBox(
        width: widget.maxWidth == null
            ? width
            : math.min(width, widget.maxWidth!),
        height: height,
        child: reel,
      );
    }
    final result = AnimatedSize(
      key: const ValueKey('spinning-word'),
      duration: _spin,
      curve: Curves.easeOutCubic,
      alignment: widget.alignment,
      clipBehavior: Clip.none,
      // A pinned line box lets tall faces overhang it; clip only the reel's
      // travel, not their ascenders and descenders.
      child: ClipRect(
        clipper: widget.strutStyle == null ? null : const _BleedClipper(),
        child: viewport,
      ),
    );
    return widget.interactive
        ? PlayfulTap(
            label: 'Spin the words faster',
            onTap: widget.running && !MediaQuery.disableAnimationsOf(context)
                ? _speedUp
                : null,
            child: result,
          )
        : result;
  }
}

class _BleedClipper extends CustomClipper<Rect> {
  const _BleedClipper();

  @override
  Rect getClip(Size size) => Rect.fromLTRB(
    -size.height * .5,
    -size.height * .35,
    size.width + size.height * .5,
    size.height * 1.35,
  );

  @override
  bool shouldReclip(_BleedClipper oldClipper) => false;
}
