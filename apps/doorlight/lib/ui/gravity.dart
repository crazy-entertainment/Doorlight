import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:forge2d/forge2d.dart' as f2;

import '../theme.dart';
import 'windows_chrome.dart';

/// Session-only easter egg, toggled by sending `/gravity` from the composer.
final gravityMode = ValueNotifier<bool>(false)..addListener(_toggled);

/// Whether the reset button is due: 3 s after gravity turned on.
final _resetDue = ValueNotifier<bool>(false);
Timer? _resetTimer;

void _toggled() {
  _resetTimer?.cancel();
  _resetDue.value = false;
  if (gravityMode.value) {
    _resetTimer = Timer(const Duration(seconds: 3), () {
      _resetDue.value = true;
      // A piece may already rest where the button shows.
      for (final world in _World._worlds.values) {
        world._wake();
      }
    });
  }
}

/// How a piece joins the pile once [gravityMode] is on.
enum GravityEntry {
  /// Holds still briefly, then drops from its layout spot.
  drop,

  /// When built while gravity is already on, rises from below the window
  /// and shoves the pile up (new chat messages).
  fromBelow,

  /// When built while gravity is already on, squeezes out of the top of the
  /// [GravityPlatform.spout] (the composer) and shoves the pile up (the
  /// user's own new messages). Without a spout it enters [fromBelow].
  fromComposer,

  /// When built while gravity is already on, drops in from above the window
  /// (incoming messages).
  fromAbove,
}

/// Plays one impact sound. Tests replace it to stay off the audio plugin.
@visibleForTesting
void Function(String asset, double volume) gravityImpactSound = _playImpact;

/// Replaces the source of drop delays so a test's pile is reproducible.
@visibleForTesting
set gravityRandom(math.Random random) => _GravityState._random = random;

/// Feeds one device sample (screen axes, y down, m/s²) as the sensor would:
/// the pull of gravity and the device's own acceleration.
@visibleForTesting
void gravitySensorSample(double x, double y, [double ax = 0, double ay = 0]) {
  _World._tilt(x, y);
  _World._jolt(ax, ay);
}

/// Reports the window's position on screen, in logical pixels, as the
/// desktop runner would while it moves.
@visibleForTesting
void gravityWindowAt(Offset at) => _World._moved(at);

/// How loud an impact of [impulse] (N·s) between bodies of masses [a] and
/// [b] (0: fixed) sounds, from 0 (silent) to 1.
@visibleForTesting
double gravityImpactVolume(double impulse, double a, double b) =>
    _World._volume(impulse, a, b);

/// Live world counters for tests.
@visibleForTesting
({
  int bodies,
  int awake,
  int steps,
  int stepMicros,
  Map<Key, double> masses,
  List<List<Offset>> shapes,
  List<({double damage, int cracks, int shards, double left})> platforms,
  int held,
  Map<Key, double> damage,
  int broken,
  int chunks,
  int pins,
})
gravityDebug() {
  final bodies = [for (final world in _World._worlds.values) ...world.pieces];
  final broken = [for (final world in _World._worlds.values) ...world.broken];
  return (
    damage: {
      for (final piece in [...bodies, ...broken])
        if (piece.widget.key != null) piece.widget.key!: piece._damage,
    },
    broken: broken.length,
    chunks: broken.fold(0, (n, piece) => n + piece._burst!.chunks.length),
    pins: bodies.fold(0, (n, piece) => n + piece._pins.length),
    platforms: [
      for (final world in _World._worlds.values)
        for (final platform in world.platforms)
          (
            damage: platform._damage,
            cracks: platform._cracks.length,
            shards: platform._shards.length,
            left: platform._left,
          ),
    ],
    held: [for (final world in _World._worlds.values) ...world.held].length,
    bodies: bodies.length,
    awake: bodies.where((piece) => piece._body!.isAwake).length,
    steps: _World.steps,
    stepMicros: _World.stepMicros,
    masses: {
      for (final piece in bodies)
        if (piece.widget.key != null) piece.widget.key!: piece._body!.mass,
    },
    // Each body's fixture corners in overlay pixels.
    shapes: [
      for (final piece in bodies)
        for (final fixture in piece._body!.fixtures)
          [
            for (final v in (fixture.shape as f2.PolygonShape).vertices)
              Offset(
                piece._body!.worldPoint(v).x * _ppm,
                piece._body!.worldPoint(v).y * _ppm,
              ),
          ],
    ],
  );
}

/// A [GlobalKey] equal to every other with the same [value]: a piece keyed
/// by what it shows keeps its body when the tree around it is rebuilt (a
/// message moving into a longer block) instead of entering a second time.
class GravityKey extends GlobalKey<State<Gravity>> {
  const GravityKey(this.value) : super.constructor();

  final Object value;

  @override
  bool operator ==(Object other) => other is GravityKey && other.value == value;

  @override
  int get hashCode => Object.hash(GravityKey, value);
}

/// One visible piece that becomes a rigid body in a shared 2D world while
/// [gravityMode] is on. The child is lifted into the root overlay so it is
/// neither clipped by nor outside the hit-test bounds of its parents, and it
/// keeps its state and stays usable while fallen.
class Gravity extends StatefulWidget {
  const Gravity({
    super.key,
    this.weight,
    this.entry = GravityEntry.drop,
    this.resetHere = false,
    required this.child,
  });

  /// Density; mass is density × area. Null infers it from the child: text is
  /// light, images heavy, everything else 1.
  final double? weight;
  final GravityEntry entry;

  /// The reset button shows where this piece is laid out, in the window
  /// close button's look: the real close button falls with everything else.
  final bool resetHere;

  final Widget child;

  @override
  State<Gravity> createState() => _GravityState();
}

class _GravityState extends State<Gravity> {
  static math.Random _random = math.Random();

  final _childKey = GlobalKey();
  Timer? _delay;
  OverlayEntry? _entry;
  CapturedThemes? _themes;
  _World? _world;
  f2.Body? _body;
  f2.MouseJoint? _grip;
  Size _size = Size.zero;
  late GravityEntry? _entering =
      gravityMode.value && widget.entry != GravityEntry.drop
      ? widget.entry
      : null;
  // How the body is still entering (kinematic) once lifted, if it is.
  GravityEntry? _coming;
  // While squeezing out of the spout: the shown share of the height.
  double _squash = 1;
  // World time of the last throw; only thrown pieces can break platforms.
  double _thrownAt = -1e9;
  // Platform bodies this piece started inside and passes through until it is
  // out of them.
  final _ghosts = <f2.Body>{};
  // Its centre while flying home: a body holds only float precision, which
  // would shift the last frame off the pixels of the laid-out child.
  Offset? _homeAt;
  // Held still inside a platform until a hard hit knocks it loose, as a
  // static body standing on [_held].
  bool _loose = false;
  Rect _held = Rect.zero;
  // The platform it is held inside, if any: its controls fall with its line.
  _GravityPlatformState? _shelf;
  // The scroll position it waits on while scrolled out of view.
  ScrollPosition? _watched;
  bool _looking = false;
  // Pins holding a piece that came into view by its top corners, each with
  // the world time it lets go.
  final _pins = <(f2.Joint, double)>[];
  // Contact impulse this frame, the filtered load in N, and crush damage
  // (it shatters at 1).
  double _press = 0, _load = 0, _damage = 0;
  bool _breaking = false;
  // Its chunks once shattered; the piece itself is hidden meanwhile.
  _Burst? _burst;
  // Captures what it paints once it is damaged, for its chunks.
  final _snapKey = GlobalKey();

  double get _density =>
      widget.weight ??
      switch (widget.child) {
        Text() || RichText() || SelectableText() => .5,
        Image() => 3,
        _ => 1,
      };

  @override
  void initState() {
    super.initState();
    gravityMode.addListener(_sync);
    _sync();
  }

  @override
  void didUpdateWidget(covariant Gravity oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The lifted child lives in another subtree, which may not be marked
    // dirty from inside this build: refresh it right after the frame.
    if (_entry == null) return;
    SchedulerBinding.instance.addPostFrameCallback(
      (_) => _entry?.markNeedsBuild(),
    );
  }

  @override
  void dispose() {
    gravityMode.removeListener(_sync);
    _reset(rebuild: false);
    super.dispose();
  }

  void _sync() {
    if (!gravityMode.value) return _reset();
    if (_delay != null || _entry != null || _body != null) return;
    // A piece inside another piece rides along with it instead of falling.
    if (context.getInheritedWidgetOfExactType<_Piece>() != null) return;
    // On a platform it holds still, once laid out, until hit hard.
    if (context.getInheritedWidgetOfExactType<_Shelf>() case final shelf?) {
      _shelf = shelf.platform;
      SchedulerBinding.instance
        ..addPostFrameCallback((_) => _hold())
        ..ensureVisualUpdate();
      return;
    }
    // A new message enters as soon as it is laid out; everything else holds
    // still briefly, then drops in random order within 3 s.
    final wait = _entering != null ? 0 : 300 + _random.nextInt(2700);
    _delay = Timer(Duration(milliseconds: wait), _lift);
  }

  void _reset({bool rebuild = true}) {
    _delay?.cancel();
    _delay = null;
    _entering = null;
    _coming = null;
    _squash = 1;
    _ghosts.clear();
    _homeAt = null;
    _loose = false;
    _held = Rect.zero;
    _unwatch();
    // Destroying the body also destroys its joints.
    _grip = null;
    _world?.remove(this);
    _world = null;
    _body = null;
    _pins.clear();
    _press = _load = _damage = 0;
    _breaking = false;
    _entry
      ?..remove()
      ..dispose();
    _entry = null;
    if (rebuild && mounted) setState(() {});
  }

  void _hold() {
    if (!mounted || !gravityMode.value || _body != null || _entry != null) {
      return;
    }
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    _world = _World.of(overlay)..hold(this);
  }

  /// Lifts the piece into the pile. A plain drop [check]s that it shows on
  /// screen first; otherwise it waits until it is scrolled into view and then
  /// [hang]s by its top corners before it falls.
  void _lift({bool check = true, bool hang = false}) {
    _delay = null;
    final entering = _entering;
    _entering = null;
    if (!mounted || _entry != null) return;
    final box = context.findRenderObject() as RenderBox?;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    final overlayBox = overlay?.context.findRenderObject() as RenderBox?;
    if (box == null ||
        !box.attached ||
        !box.hasSize ||
        box.size.width < 1 ||
        box.size.height < 1 ||
        overlay == null ||
        overlayBox == null) {
      return;
    }
    if (check && entering == null) {
      // Any visible sliver falls, or it would stay behind as a stray edge.
      if (_shown(box, overlayBox) <= 0) return _watch();
      hang |= _watched != null;
      _unwatch();
    }
    _size = box.size;
    final origin = box.localToGlobal(Offset.zero, ancestor: overlayBox);
    _themes = InheritedTheme.capture(from: context, to: overlay.context);
    _world = _World.of(overlay);
    _body = _world!.add(this, origin & _size, entering);
    if (hang) _world!.hang(this);
    _entry = OverlayEntry(builder: _fallen);
    // Under the reset button, which must stay on top.
    overlay.insert(_entry!, below: _world!._button);
    setState(() {});
  }

  /// Share of [box] that shows inside its ancestors' clips (scroll
  /// viewports, clipped boxes) and the window, from 0 to 1.
  static double _shown(RenderBox box, RenderBox overlayBox) {
    var rect = Offset.zero & box.size;
    RenderObject child = box;
    for (var parent = box.parent; parent != null; parent = parent.parent) {
      final transform = Matrix4.identity();
      parent.applyPaintTransform(child, transform);
      rect = MatrixUtils.transformRect(transform, rect);
      if (parent.describeApproximatePaintClip(child) case final clip?) {
        rect = rect.intersect(clip);
      }
      if (rect.isEmpty) return 0;
      if (parent == overlayBox) break;
      child = parent;
    }
    rect = rect.intersect(Offset.zero & overlayBox.size);
    if (rect.isEmpty) return 0;
    return rect.width * rect.height / (box.size.width * box.size.height);
  }

  // Off screen: look again whenever the nearest scrollable moves.
  void _watch() {
    final position = context
        .findAncestorStateOfType<ScrollableState>()
        ?.position;
    if (position == null || position == _watched) return;
    _unwatch();
    _watched = position..addListener(_scrolled);
  }

  void _unwatch() {
    _watched?.removeListener(_scrolled);
    _watched = null;
  }

  // Once the scroll has been laid out.
  void _scrolled() {
    if (_looking) return;
    _looking = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _looking = false;
      if (mounted && gravityMode.value && _watched != null) _lift();
    });
  }

  /// Where the child would be laid out right now, in overlay pixels.
  Rect? _spot() => switch (_world) {
    final world? => _laidOut(context, world.overlay),
    null => null,
  };

  // The lifted child leaves its ancestors, so carry over any pointer block
  // that applied at its original spot (disabled or hidden sections).
  bool _blocked() {
    for (
      RenderObject? node = context.findRenderObject();
      node != null;
      node = node.parent
    ) {
      if (node is RenderIgnorePointer && node.ignoring) return true;
      if (node is RenderAbsorbPointer && node.absorbing) return true;
    }
    return false;
  }

  // A drag picks the piece up by the grab point; a tap still reaches the child.
  void _grab(DragStartDetails details) {
    final body = _body;
    // A piece still entering from below is not in the pile yet.
    if (body == null ||
        body.bodyType != f2.BodyType.dynamic ||
        _world!._homing != null) {
      return;
    }
    _grip = _world!.grab(body, details.globalPosition);
  }

  void _carry(DragUpdateDetails details) =>
      _grip?.setTarget(_world!.point(details.globalPosition));

  void _letGo([DragEndDetails? details]) {
    final grip = _grip;
    _grip = null;
    if (grip == null) return;
    final velocity = details?.velocity.pixelsPerSecond;
    if (velocity != null && velocity.distance > _throwSpeed * _ppm) {
      _thrownAt = _world!._time;
    }
    _world!.release(grip, velocity);
  }

  Widget _fallen(BuildContext _) {
    final piece = _themes!.wrap(_Piece(key: _childKey, child: widget.child));
    final body = _body;
    final mend = _world?._mend ?? 1;
    // A squeezed body keeps its bottom edge; the child is squashed to fit.
    final shown = _size.height * _squash;
    final centre =
        _homeAt ??
        _burst?.at ??
        Offset(body!.position.x * _ppm, body.position.y * _ppm);
    return Positioned(
      left: centre.dx - _size.width / 2,
      top: centre.dy + shown / 2 - _size.height,
      width: _size.width,
      height: _size.height,
      // Transform keeps hit testing on the rotated body.
      // Shattering hides the existing subtree instead of reparenting its
      // keyed controls out of their semantics ancestors.
      child: Offstage(
        offstage: _burst != null,
        child: Transform(
          alignment: Alignment.center,
          transform: Matrix4.rotationZ(body?.angle ?? 0)
            ..multiply(
              Matrix4.diagonal3Values(1, _squash, 1)
                ..setTranslationRaw(0, _size.height * (1 - _squash) / 2, 0),
            ),
          child: Material(
            type: MaterialType.transparency,
            child: IgnorePointer(
              ignoring: _blocked(),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                dragStartBehavior: DragStartBehavior.down,
                onPanStart: _grab,
                onPanUpdate: _carry,
                onPanEnd: _letGo,
                onPanCancel: _letGo,
                // Once damaged it paints into its own layer, which its chunks
                // show when it shatters, with the cracks on top.
                child: _damage == 0
                    ? piece
                    : CustomPaint(
                        foregroundPainter: _damage < _crackFrom || mend == 0
                            ? null
                            : _PieceCrackPainter(
                                _damage,
                                identityHashCode(this),
                                _contrast(
                                  Theme.of(context).colorScheme.surface,
                                  .6,
                                ),
                                mend,
                              ),
                        child: RepaintBoundary(key: _snapKey, child: piece),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // The GlobalKey keeps the child's state while it moves into the overlay;
  // the placeholder holds its layout space.
  @override
  Widget build(BuildContext context) => _entry == null
      ? _Piece(key: _childKey, child: widget.child)
      : SizedBox.fromSize(size: _size);
}

/// A region whose top edge is a line while gravity is on: pieces pile on the
/// line, passive drops only leave hairlines in it and a few hard throws
/// shatter it into falling fragments until gravity is reset. The [Gravity]
/// pieces laid out inside hold still in place, so the region below the line
/// stays put; once the line is gone, falling pieces land on them and a hard
/// throw knocks one loose. The region itself never breaks. With [spout] it
/// is the composer the user's own new messages squeeze out of.
class GravityPlatform extends StatefulWidget {
  const GravityPlatform({
    super.key,
    this.spout = false,
    required this.color,
    required this.builder,
  });

  final bool spout;

  /// The line's color, for its fragments.
  final Color color;

  /// Builds the region; once [broken] it must leave its top line out (but
  /// keep its width, so nothing below moves), since the fragments show it.
  final Widget Function(BuildContext context, bool broken) builder;

  @override
  State<GravityPlatform> createState() => _GravityPlatformState();
}

class _GravityPlatformState extends State<GravityPlatform> {
  static final _all = <_GravityPlatformState>{};

  /// The spout laid out in [overlay], in its pixels.
  static Rect? _spout(OverlayState overlay) {
    for (final platform in _all) {
      if (!platform.widget.spout) continue;
      if (platform._rect(overlay) case final rect?) return rect;
    }
    return null;
  }

  _World? _world;
  // The intact line: a static body along the top of [_placed], the whole
  // region in overlay pixels.
  f2.Body? _body;
  Rect _placed = Rect.zero;
  double _damage = 0;
  // Hit points in the region's own pixels, with their strength from 0 to 1.
  final _cracks = <(Offset, double)>[];
  bool _cracked = false;
  List<_Shard> _shards = const [];
  // What the region painted when it broke, for its shards.
  ui.Image? _image;
  bool _breaking = false;
  OverlayEntry? _debris;
  // Share of the damage still showing: it heals away on the trip home.
  double _left = 1;

  bool get _broken => _shards.isNotEmpty && _left > 0;

  void _redraw() => setState(() {});

  Rect? _rect(OverlayState overlay) =>
      mounted && Overlay.maybeOf(context, rootOverlay: true) == overlay
      ? _laidOut(context, overlay)
      : null;

  @override
  void initState() {
    super.initState();
    _all.add(this);
    gravityMode.addListener(_sync);
    _sync();
  }

  @override
  void dispose() {
    gravityMode.removeListener(_sync);
    _leave(rebuild: false);
    _all.remove(this);
    super.dispose();
  }

  void _sync() {
    if (!gravityMode.value) return _leave();
    // Joins once laid out, and never from inside a build.
    SchedulerBinding.instance
      ..addPostFrameCallback((_) => _join())
      ..ensureVisualUpdate();
  }

  void _join() {
    if (!mounted || !gravityMode.value || _world != null) return;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    _world = _World.of(overlay)..join(this);
  }

  void _leave({bool rebuild = true}) {
    _world?.leave(this);
    _world = null;
    _body = null;
    _placed = Rect.zero;
    _damage = 0;
    _cracks.clear();
    _cracked = false;
    _shards = const [];
    _image?.dispose();
    _image = null;
    _breaking = false;
    _left = 1;
    if (rebuild && mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => CustomPaint(
    foregroundPainter: _cracks.isEmpty || _broken || _left == 0
        ? null
        : _CrackPainter(
            List.of(_cracks),
            _contrast(Theme.of(context).colorScheme.surface, .55),
            _left,
          ),
    child: _Shelf(platform: this, child: widget.builder(context, _broken)),
  );
}

/// Marks the inside of a [GravityPlatform], where pieces hold still.
class _Shelf extends InheritedWidget {
  const _Shelf({required this.platform, required super.child});

  final _GravityPlatformState platform;

  @override
  bool updateShouldNotify(_Shelf oldWidget) => false;
}

/// One falling fragment of a shattered [GravityPlatform] line.
class _Shard {
  _Shard(this.body, this.outline, this.home);

  final f2.Body body;

  /// Corners around the body's origin, in pixels; the first two are the
  /// line's own stretch.
  final List<Offset> outline;

  /// The body's origin within the region, in pixels.
  final Offset home;
}

/// Jagged breaks along the line from each hit point, the same for the same
/// hits; [left] of each stroke shows while it heals.
class _CrackPainter extends CustomPainter {
  _CrackPainter(this.cracks, this.color, this.left);

  final List<(Offset, double)> cracks;
  final Color color;
  final double left;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Rect.fromLTRB(0, -2, size.width, _lineDepth));
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: color.a * left);
    for (final (i, (at, strength)) in cracks.indexed) {
      final random = math.Random(Object.hash(i, at.dx.round(), at.dy.round()));
      paint.strokeWidth = .6 + strength * 1.2;
      for (var arm = 0; arm < 2 + (strength * 4).round(); arm++) {
        // Mostly along the line, either way.
        var angle =
            (random.nextBool() ? 0 : math.pi) + (random.nextDouble() - .5) * .6;
        var p = Offset(at.dx, .5);
        final path = Path()..moveTo(p.dx, p.dy);
        for (var bend = 0; bend < 2 + (strength * 4).round(); bend++) {
          angle += (random.nextDouble() - .5) * .8;
          p += Offset.fromDirection(
            angle,
            (3 + random.nextDouble() * (5 + strength * 16)) * left,
          );
          path.lineTo(p.dx, p.dy);
        }
        canvas.drawPath(path, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_CrackPainter old) =>
      old.cracks.length != cracks.length ||
      old.color != color ||
      old.left != left;
}

/// The fragments of one shattered line, in overlay pixels.
class _DebrisPainter extends CustomPainter {
  _DebrisPainter(this.platform);

  final _GravityPlatformState platform;

  @override
  void paint(Canvas canvas, Size size) {
    // Mended: the region shows its own line again.
    if (platform._left == 0) return;
    final line = Paint()..color = platform.widget.color;
    final image = platform._image;
    for (final shard in platform._shards) {
      final body = shard.body;
      final [a, b, c, ...] = shard.outline;
      canvas
        ..save()
        ..translate(body.position.x * _ppm, body.position.y * _ppm)
        ..rotate(body.angle);
      // Its stretch of what the region painted, or else a bare line.
      if (image != null) {
        final dst = Rect.fromPoints(a, c);
        final ratio = image.width / platform._placed.width;
        canvas.drawImageRect(
          image,
          _scale(dst.shift(shard.home), ratio),
          dst,
          Paint()..filterQuality = FilterQuality.medium,
        );
      } else {
        canvas.drawRect(Rect.fromLTRB(a.dx, a.dy, b.dx, a.dy + 1), line);
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_DebrisPainter old) => true;
}

Color _contrast(Color surface, double alpha) =>
    (surface.computeLuminance() > .4 ? Colors.black : Colors.white).withValues(
      alpha: alpha,
    );

/// Where [context] is laid out in [overlay], in its pixels.
Rect? _laidOut(BuildContext context, OverlayState overlay) {
  final box = context.findRenderObject() as RenderBox?;
  final overlayBox = overlay.context.findRenderObject() as RenderBox?;
  if (box == null || !box.attached || !box.hasSize || overlayBox == null) {
    return null;
  }
  return box.localToGlobal(Offset.zero, ancestor: overlayBox) & box.size;
}

Rect _scale(Rect rect, double by) => Rect.fromLTRB(
  rect.left * by,
  rect.top * by,
  rect.right * by,
  rect.bottom * by,
);

/// What [box] painted last frame, at [ratio] pixels per logical pixel, cut
/// out of the nearest repaint boundary at or above it; null if there is none
/// or it has not been painted.
ui.Image? _snapshot(RenderBox box, double ratio) {
  RenderObject? node = box;
  while (node != null && node is! RenderRepaintBoundary) {
    node = node.parent;
  }
  if (node is! RenderRepaintBoundary || !box.hasSize || box.size.isEmpty) {
    return null;
  }
  try {
    final whole = node.toImageSync(pixelRatio: ratio);
    final at = box.localToGlobal(Offset.zero, ancestor: node);
    final size = box.size * ratio;
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawImageRect(
      whole,
      _scale(at & box.size, ratio),
      Offset.zero & size,
      Paint(),
    );
    final picture = recorder.endRecording();
    final image = picture.toImageSync(size.width.ceil(), size.height.ceil());
    whole.dispose();
    picture.dispose();
    return image;
  } catch (_) {
    // A boundary that still needs paint cannot be captured; plain fragments
    // stand in.
    return null;
  }
}

/// A boundary that [Gravity] pieces never cross while [gravityMode] is on:
/// an unbreakable wall through the child's width, as tall as the usable area,
/// that follows the child's layout (a sidebar's divider).
class GravityWall extends StatefulWidget {
  const GravityWall({super.key, required this.child});

  final Widget child;

  @override
  State<GravityWall> createState() => _GravityWallState();
}

class _GravityWallState extends State<GravityWall> {
  _World? _world;
  f2.Body? _body;
  Rect _placed = Rect.zero;
  // Per piece: whether it keeps to the left.
  var _west = Expando<bool>();

  @override
  void initState() {
    super.initState();
    gravityMode.addListener(_sync);
    _sync();
  }

  @override
  void dispose() {
    gravityMode.removeListener(_sync);
    _leave();
    super.dispose();
  }

  void _sync() {
    if (!gravityMode.value) return _leave();
    SchedulerBinding.instance
      ..addPostFrameCallback((_) => _join())
      ..ensureVisualUpdate();
  }

  void _join() {
    if (!mounted || !gravityMode.value || _world != null) return;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    _world = _World.of(overlay)..wall(this);
    _follow(Duration.zero);
  }

  // A settled world sleeps; wake it when the layout moves the wall. Checked
  // after frames that happen anyway, never asking for one.
  void _follow(Duration _) {
    final world = _world;
    if (world == null || !mounted) return;
    final rect = _laidOut(context, world.overlay);
    if (rect != null && (rect.left - _placed.left).abs() > .5) world._wake();
    SchedulerBinding.instance.addPostFrameCallback(_follow);
  }

  void _leave() {
    _world?.unwall(this);
    _world = null;
    _body = null;
    _placed = Rect.zero;
    _west = Expando<bool>();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The chunks of one shattered piece.
class _Burst {
  _Burst(this.chunks, this.image, this.size, this.born, this.at, this.color);

  /// Each body with its cell of the piece, in the piece's own pixels.
  final List<(f2.Body, Rect)> chunks;

  /// What the piece painted, or null: chunks are then [color].
  ui.Image? image;
  final Size size;
  final double born;

  /// The piece's centre when it shattered, in overlay pixels.
  final Offset at;
  final Color color;
  OverlayEntry? entry;

  /// Share of the chunks still showing as they fade out.
  double shown = 1;
}

/// The chunks of a shattered piece, each its own cut of the piece's paint.
class _ChunkPainter extends CustomPainter {
  _ChunkPainter(this.burst);

  final _Burst burst;

  @override
  void paint(Canvas canvas, Size size) {
    final image = burst.image;
    final paint = Paint()
      ..filterQuality = FilterQuality.medium
      ..color = (image == null ? burst.color : Colors.black).withValues(
        alpha: burst.shown * (image == null ? burst.color.a : 1),
      );
    for (final (body, cell) in burst.chunks) {
      final local = cell.shift(-cell.center);
      canvas
        ..save()
        ..translate(body.position.x * _ppm, body.position.y * _ppm)
        ..rotate(body.angle);
      if (image != null) {
        final ratio = image.width / burst.size.width;
        canvas.drawImageRect(image, _scale(cell, ratio), local, paint);
      } else {
        canvas.drawRect(local, paint);
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_ChunkPainter old) => true;
}

/// Damage showing on a piece as jagged cracks, more and longer as it grows,
/// the same each frame for the same [seed]; [mend] of each stroke shows.
class _PieceCrackPainter extends CustomPainter {
  _PieceCrackPainter(this.damage, this.seed, this.color, this.mend);

  final double damage;
  final int seed;
  final Color color;
  final double mend;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    final random = math.Random(seed);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = .8
      ..color = color.withValues(alpha: color.a * mend);
    final reach = math.max(size.width, size.height) * damage * mend;
    for (var crack = 0; crack < 1 + (damage * 4).floor(); crack++) {
      var p = Offset(
        random.nextDouble() * size.width,
        random.nextDouble() * size.height,
      );
      var angle = random.nextDouble() * 2 * math.pi;
      final path = Path()..moveTo(p.dx, p.dy);
      for (var bend = 0; bend < 4; bend++) {
        angle += (random.nextDouble() - .5) * 1.2;
        p += Offset.fromDirection(
          angle,
          reach / 4 * (.5 + random.nextDouble()),
        );
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_PieceCrackPainter old) =>
      old.damage != damage || old.color != color || old.mend != mend;
}

/// Marks a lifted-or-liftable subtree so nested [Gravity] pieces stay put.
class _Piece extends InheritedWidget {
  const _Piece({super.key, required super.child});

  @override
  bool updateShouldNotify(_Piece oldWidget) => false;
}

/// Pixels per metre; keeps typical pieces in Box2D's 0.1–10 m sweet spot.
const _ppm = 100.0;

/// How fast an entering message climbs into the pile, in m/s.
const _rise = 3.0;

/// Gravity strength in m/s² with the device upright.
const _g = 26.0;

/// Share of full gravity in the screen plane below which (~3° of tilt) the
/// device lies flat and keeps its last direction, and the least share a
/// tilted device pulls with so the pile never feels dead.
const _flat = .05, _minPull = .25;

/// Device acceleration in m/s² from which a shake jostles the pile, the share
/// of it each piece takes as a speed change, and the top change in m/s.
const _shakeFloor = 4.0, _shakeGain = .25, _shakeKick = 8.0;

/// Speed change in m/s per pixel the window moves, its top per move, and the
/// largest move in pixels that is still a drag rather than a jump.
const _windowGain = .08, _windowKick = 10.0, _windowJump = 300.0;

/// Impact speed in m/s below which a contact is silent, and from which it is
/// at full volume.
const _quietHit = 1.2, _loudHit = 8.0;

/// Top speed of a thrown piece, in m/s.
const _throw = 30.0;

/// Half-length of each wall edge, in m: far beyond any window.
const _far = 1000.0;

/// How long the trip home after a reset takes, in seconds.
const _homeSeconds = .8;

/// How long a message takes to squeeze out of the spout, in seconds, and
/// the share of its height showing at first.
const _squeezeSeconds = .35, _squeezeStart = .1;

/// Release speed in m/s above which a dragged piece counts as thrown, and
/// impact speed in m/s from which a thrown piece damages a platform.
const _throwSpeed = 3.0, _hardHit = 6.0;

/// Damage a platform can take from pieces that merely fall on it; it breaks
/// at 1.
const _crackCap = .45;

/// Physics step, in seconds.
const _h = 1 / 120;

/// How deep a platform's line is as a body, in pixels: enough that a fast
/// throw cannot tunnel through it.
const _lineDepth = 4.0;

/// Top speed of a moving wall (keyboard, resize), in m/s.
const _wallSpeed = 15.0;

/// Sustained squeeze in N from which a piece is being crushed (far beyond
/// any calm pile: messages shoving the pile into the ceiling, a heavy piece
/// pressed down), the damage per second it then takes at that squeeze
/// (more under more), and how long the squeeze is averaged over, in s.
const _crush = 1500.0, _crushRate = .5, _loadWindow = .25;

/// Damage per second of a piece resting over the reset button, and the
/// speed in m/s under which it rests.
const _coverRate = .8, _resting = .5;

/// Damage from which cracks show; a piece shatters at 1.
const _crackFrom = .2;

/// How long the chunks of a shattered piece last, in s, the last of which
/// they fade, and the most chunks alive at once (the oldest go first).
const _chunkLife = 5.0, _chunkFade = 1.0, _maxChunks = 600;

/// Least time a piece that came into view hangs by each corner, and the
/// random extra, in s.
const _hangLeast = .6, _hangExtra = .9;

/// The first piece back lands this many seconds into the trip home, the
/// last at its end; landing sounds are at least [_landGap] s apart.
const _landFirst = .5, _landGap = .03;

/// One physics world per root overlay. Four walls enclose the usable part of
/// the window (inside system bars and above the keyboard) and follow it live.
class _World extends f2.ContactListener with WidgetsBindingObserver {
  _World(this.overlay) {
    world
      ..setContactListener(this)
      ..setContactFilter(_Ghosts());
    world.gravity = _down * _pull;
    if (_worlds.isEmpty) _sense(true);
    WidgetsBinding.instance.addObserver(this);
    overlay.insert(_button);
  }

  static final _worlds = <OverlayState, _World>{};
  static int steps = 0, stepMicros = 0;
  static final _clock = Stopwatch()..start();
  static int _lastSound = -1000000, _lastJolt = -1000000;

  /// Unit "down" in screen axes and its strength; the Android gravity sensor
  /// steers both.
  static final _down = f2.Vector2(0, 1);
  static final _woke = f2.Vector2(0, 1);
  static double _pull = _g;

  /// The window's last position on screen while the desktop runner reports
  /// it.
  static Offset? _window;
  static const _sensor = MethodChannel('syb.l/gravity');

  static _World of(OverlayState overlay) =>
      _worlds[overlay] ??= _World(overlay);

  // Speaks the EventChannel protocol directly so a missing plugin (tests)
  // is a caught error instead of a reported one. Android streams the device's
  // gravity and acceleration; Windows the window's position on screen.
  static void _sense(bool on) {
    final windows = defaultTargetPlatform == TargetPlatform.windows;
    if (kIsWeb || !windows && defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    _window = null;
    ServicesBinding.instance.defaultBinaryMessenger.setMessageHandler(
      _sensor.name,
      on
          ? (data) async {
              try {
                final v = [
                  for (final n in _sensor.codec.decodeEnvelope(data!)! as List)
                    (n as num).toDouble(),
                ];
                if (windows) {
                  // In physical pixels.
                  final ratio = WidgetsBinding
                      .instance
                      .platformDispatcher
                      .implicitView
                      ?.devicePixelRatio;
                  _moved(Offset(v[0], v[1]) / (ratio ?? 1));
                } else {
                  _tilt(v[0], v[1]);
                  if (v.length >= 4) _jolt(v[2], v[3]);
                }
              } catch (_) {}
              return null;
            }
          : null,
    );
    unawaited(
      _sensor.invokeMethod<void>(on ? 'listen' : 'cancel').catchError((_) {}),
    );
  }

  /// Steers gravity by the device's pull in the screen plane: its direction,
  /// and its strength by how far the device is tilted up from flat.
  static void _tilt(double x, double y) {
    final length = math.sqrt(x * x + y * y);
    final share = math.min(1.0, length / 9.81);
    // Lying flat: keep the last direction, at the weakest pull.
    if (share >= _flat) _down.setValues(x / length, y / length);
    _pull = _g * math.max(_minPull, share);
    for (final world in _worlds.values) {
      world.world.gravity = _down * _pull;
    }
    // Sensor noise steers awake bodies but does not wake the pile.
    if (_down.dot(_woke) > math.cos(1.5 * math.pi / 180)) return;
    _woke.setFrom(_down);
    for (final world in _worlds.values) {
      world._shake();
    }
  }

  /// A shake: the pieces lag behind the device's acceleration [ax], [ay]
  /// (screen axes, m/s²), at most ~10 times a second.
  static void _jolt(double ax, double ay) {
    final kick = f2.Vector2(-ax, -ay);
    if (kick.length < _shakeFloor) return;
    final now = _clock.elapsedMicroseconds;
    if (now - _lastJolt < 100000) return;
    _lastJolt = now;
    kick.scale(_shakeGain);
    if (kick.length > _shakeKick) kick.scale(_shakeKick / kick.length);
    for (final world in _worlds.values) {
      world._push(kick, jostle: true);
    }
  }

  /// The window moved on screen to [at]: the pieces stay where they were, so
  /// they slide the other way inside it.
  static void _moved(Offset at) {
    final last = _window;
    _window = at;
    if (last == null) return;
    final moved = at - last;
    // A jump (another screen, maximize) is not a drag.
    if (moved == Offset.zero || moved.distance > _windowJump) return;
    final kick = f2.Vector2(-moved.dx, -moved.dy)..scale(_windowGain);
    if (kick.length > _windowKick) kick.scale(_windowKick / kick.length);
    for (final world in _worlds.values) {
      world._push(kick);
    }
  }

  /// How loud an impact of [hit] is by the speed change of the lighter
  /// moving body: by impulse alone, a heavy piece nudged into its neighbour
  /// at a crawl made the same faint thud over and over.
  static double _volume(double hit, double a, double b) {
    final mass = a > 0 && b > 0 ? math.min(a, b) : math.max(a, b);
    if (mass <= 0) return 0;
    final speed = hit / mass;
    return speed < _quietHit ? 0 : math.min(1, speed / _loudHit);
  }

  final OverlayState overlay;
  final world = f2.World(f2.Vector2(0, _g));
  final pieces = <_GravityState>{};
  final platforms = <_GravityPlatformState>{};
  // Pieces held still inside a platform, each a static body on its spot.
  final held = <_GravityState>{};
  // Shattered pieces, shown by their chunks until the trip home.
  final broken = <_GravityState>{};
  final walls = <_GravityWallState>{};
  final _fresh = <f2.Contact>{};
  final _manifold = f2.WorldManifold();
  // Seconds of simulated time.
  double _time = 0;
  late final _ticker = Ticker(_tick, debugLabel: 'gravity');
  // Kinematic, so a moving wall shoves the pile instead of passing through.
  late final _floor = _wall(vertical: false);
  late final _ceiling = _wall(vertical: false);
  late final _left = _wall(vertical: true);
  late final _right = _wall(vertical: true);
  Rect _area = Rect.zero;
  Duration _last = Duration.zero;
  double _owed = 0;
  // Fixtureless anchor for drag joints; the walls would stop colliding.
  late final _ground = world.createBody(f2.BodyDef());
  late final _button = OverlayEntry(builder: _resetButton);
  // The spot of the piece the reset button replaces, once it has fallen.
  Rect? _seat;

  /// Seconds into the trip home, or null while the pile is live.
  double? _homing;
  // Per body: where it set off, its upright-bound angle, where home is now
  // (null: stay), how to show it, and when it lands (null: with the platform
  // mending, silently).
  final _trips =
      <
        (
          f2.Body,
          Offset,
          double,
          Offset? Function(),
          void Function(Offset),
          double?,
        )
      >[];
  // Share of the pieces' cracks still showing: they heal on the trip home.
  double _mend = 1;
  double _lastLand = -1;

  Widget _resetButton(BuildContext context) {
    final size = (overlay.context.findRenderObject()! as RenderBox).size;
    final colors = Theme.of(context).extension<SyblColors>();
    final button = ValueListenableBuilder(
      valueListenable: _resetDue,
      builder: (context, due, _) => !due
          ? const SizedBox.shrink()
          : Semantics(
              button: true,
              label: 'Put everything back',
              // The minimize and maximize buttons' look, not close's red.
              child: windowButtonFace(
                key: const ValueKey('gravity-reset'),
                icon: Icons.restart_alt_rounded,
                color:
                    colors?.muted ??
                    Theme.of(context).colorScheme.onSurfaceVariant,
                hover: colors == null
                    ? Theme.of(context).hoverColor
                    : windowButtonHover(colors),
                onPressed: _goHome,
              ),
            ),
    );
    // In the close button's spot, or else the usable area's top-right corner.
    return switch (_seat) {
      final seat? => Positioned.fromRect(rect: seat, child: button),
      null => Positioned(
        top: _area.top + 3.5,
        right: size.width - _area.right + 3,
        child: button,
      ),
    };
  }

  /// Carries every piece back to its live layout spot, then ends gravity.
  void _goHome() {
    if (_homing != null) return;
    if (MediaQuery.maybeDisableAnimationsOf(overlay.context) ?? false) {
      gravityMode.value = false;
      return;
    }
    _homing = 0;
    _lastLand = -1;
    // Shattered pieces gather whole where they broke and fly home too.
    for (final piece in [...broken]) {
      final burst = piece._burst!;
      final at = burst.chunks.isEmpty
          ? burst.at
          : burst.chunks
                    .map(
                      (chunk) => Offset(
                        chunk.$1.position.x * _ppm,
                        chunk.$1.position.y * _ppm,
                      ),
                    )
                    .reduce((a, b) => a + b) /
                burst.chunks.length.toDouble();
      _shed(piece);
      broken.remove(piece);
      piece
        .._burst = null
        .._body = world.createBody(
          f2.BodyDef(
            userData: piece,
            position: f2.Vector2(at.dx, at.dy) / _ppm,
          ),
        );
      pieces.add(piece);
    }
    // Overlapping pieces were lifted in random order; stack them as the
    // layout paints them before they set off, so overlaps are right all the
    // way and the hand-back changes no pixel.
    final order = <OverlayEntry>[];
    void visit(Element element) {
      if (element case StatefulElement(
        state: final _GravityState piece,
      ) when pieces.contains(piece)) {
        order.add(piece._entry!);
      }
      element.visitChildElements(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildElements(visit);
    for (final entry in order) {
      entry.remove();
    }
    overlay.insertAll(order, below: _button);
    void trip(
      f2.Body body,
      Offset? Function() home,
      void Function(Offset at) show, [
      double? lands,
    ]) => _trips.add((
      body,
      Offset(body.position.x * _ppm, body.position.y * _ppm),
      // The shorter way round to upright.
      math.atan2(math.sin(body.angle), math.cos(body.angle)),
      home,
      show,
      lands,
    ));
    // Pieces land one after another in a random order, each with a click.
    final landing = [...pieces]..shuffle(_GravityState._random);
    for (final (i, piece) in landing.indexed) {
      piece._letGo();
      piece._squash = 1;
      trip(
        piece._body!,
        () => piece._spot()?.center,
        (at) {
          piece._homeAt = at;
          piece._entry?.markNeedsBuild();
        },
        _landFirst + (_homeSeconds - _landFirst) * (i + 1) / landing.length,
      );
    }
    for (final platform in platforms) {
      for (final shard in platform._shards) {
        trip(
          shard.body,
          () => switch (platform._rect(overlay)) {
            final rect? => rect.topLeft + shard.home,
            null => null,
          },
          (_) => platform._debris?.markNeedsBuild(),
        );
      }
    }
    _wake();
  }

  /// One frame of the trip home: a curved, eased path that ends exactly on
  /// each piece's spot; the frame after arriving hands the pieces back.
  void _homeStep(double dt) {
    if (_homing! >= _homeSeconds) {
      gravityMode.value = false;
      return;
    }
    final before = _homing!;
    _homing = math.min(_homing! + dt, _homeSeconds);
    final t = Curves.easeInOut.transform(_homing! / _homeSeconds);
    _mend = 1 - t;
    for (final platform in platforms) {
      platform._left = 1 - t;
      if (platform._cracks.isNotEmpty || platform._shards.isNotEmpty) {
        platform._redraw();
      }
    }
    for (final (body, from, angle, home, show, lands) in _trips) {
      final t = Curves.easeInOut.transform(
        math.min(1, _homing! / (lands ?? _homeSeconds)),
      );
      if (lands != null && before < lands && _homing! >= lands) _land();
      final to = home() ?? from;
      // Arc over both ends, like a toss back into place.
      final lift = Offset(
        (from.dx + to.dx) / 2,
        math.min(from.dy, to.dy) - (to - from).distance * .3,
      );
      final at =
          from * ((1 - t) * (1 - t)) + lift * (2 * (1 - t) * t) + to * (t * t);
      body.setTransform(
        f2.Vector2(at.dx / _ppm, at.dy / _ppm),
        angle * (1 - t),
      );
      show(at);
    }
  }

  /// A piece touches down at home: a soft click, a little different each
  /// time, at most every [_landGap] s so a big pile patters.
  void _land() {
    if (_homing! - _lastLand < _landGap) return;
    _lastLand = _homing!;
    final random = _GravityState._random;
    gravityImpactSound(
      'sounds/gravity_land_${1 + random.nextInt(3)}.wav',
      .3 + random.nextDouble() * .2,
    );
  }

  f2.Body _wall({required bool vertical}) {
    final body = world.createBody(f2.BodyDef(type: f2.BodyType.kinematic));
    body.createFixture(
      f2.FixtureDef(
        f2.EdgeShape()..set(
          vertical ? f2.Vector2(0, -_far) : f2.Vector2(-_far, 0),
          vertical ? f2.Vector2(0, _far) : f2.Vector2(_far, 0),
        ),
        friction: .6,
      ),
    );
    return body;
  }

  /// The window minus system bars, cutouts and keyboard, in overlay pixels.
  /// Read from the view, since widgets above the overlay may strip insets.
  Rect _usable() {
    final box = overlay.context.findRenderObject()! as RenderBox;
    final view = MediaQueryData.fromView(View.of(overlay.context));
    final pad = view.viewPadding;
    final usable = Rect.fromLTRB(
      pad.left,
      pad.top,
      view.size.width - pad.right,
      view.size.height - math.max(pad.bottom, view.viewInsets.bottom),
    );
    final local = Rect.fromPoints(
      box.globalToLocal(usable.topLeft),
      box.globalToLocal(usable.bottomRight),
    ).intersect(Offset.zero & box.size);
    return local.isEmpty ? Offset.zero & box.size : local;
  }

  @override
  void didChangeMetrics() => _wake();

  f2.Body add(_GravityState piece, Rect rect, GravityEntry? entry) {
    _fit(0);
    final area = _area;
    final spout = entry == GravityEntry.fromComposer
        ? _GravityPlatformState._spout(overlay)
        : null;
    final coming = entry == GravityEntry.fromComposer && spout == null
        ? GravityEntry.fromBelow
        : entry;
    piece._coming = coming;
    if (spout != null) piece._squash = _squeezeStart;
    // Start inside the walls (a squeezed message inside the spout's span);
    // an entering message starts just outside the wall it comes through.
    final span = spout ?? area;
    final left = rect.width < span.width
        ? rect.left.clamp(span.left, span.right - rect.width)
        : spout != null
        ? spout.center.dx - rect.width / 2
        : rect.left;
    final height = rect.height * piece._squash;
    final top = switch (coming) {
      GravityEntry.fromBelow => area.bottom,
      GravityEntry.fromAbove => area.top - height,
      GravityEntry.fromComposer => spout!.top - height,
      _ =>
        rect.height < area.height
            ? rect.top.clamp(area.top, area.bottom - rect.height)
            : rect.top,
    };
    final body = world.createBody(
      f2.BodyDef(
        // Kinematic bodies ignore the walls and shove the pile with
        // unlimited force until they are inside the window.
        type: coming == null ? f2.BodyType.dynamic : f2.BodyType.kinematic,
        userData: piece,
        position: f2.Vector2(
          (left + rect.width / 2) / _ppm,
          (top + height / 2) / _ppm,
        ),
        linearVelocity: f2.Vector2(0, switch (coming) {
          GravityEntry.fromBelow => -_rise,
          GravityEntry.fromAbove => _rise,
          _ => 0,
        }),
      ),
    );
    _shape(body, piece, height);
    // A piece laid out across a platform's line (a control knocked loose)
    // passes through it until it is out.
    final spawn = Rect.fromLTWH(left, top, rect.width, height).deflate(.5);
    for (final platform in platforms) {
      if (platform._body case final bar?
          when _line(platform._placed).overlaps(spawn)) {
        piece._ghosts.add(bar);
      }
      // Controls falling with their broken line start among its shards.
      for (final shard in platform._shards) {
        if (_aabb(shard.body).overlaps(spawn)) piece._ghosts.add(shard.body);
      }
    }
    pieces.add(piece);
    if (piece.widget.resetHere) {
      _seat = rect;
      _button.markNeedsBuild();
    }
    _wake();
    return body;
  }

  void join(_GravityPlatformState platform) {
    platforms.add(platform);
    _fit(0);
    _place(platform);
    _wake();
  }

  /// Keeps an intact platform's line on its live layout rect.
  void _place(_GravityPlatformState platform) {
    if (platform._shards.isNotEmpty) return;
    final rect = platform._rect(overlay);
    if (rect == null || rect.width < 1 || rect.height < 1) return;
    final bar = _stand(
      platform._body,
      _line(platform._placed),
      _line(rect),
      platform,
    );
    // Shards and cracks stay relative to the whole region.
    platform._placed = rect;
    if (bar == null) return;
    if (platform._body case final old?) {
      for (final piece in pieces) {
        if (piece._ghosts.remove(old)) piece._ghosts.add(bar);
      }
      _destroy(old);
    }
    platform._body = bar;
  }

  /// Keeps a held piece's static body on its live layout rect.
  void _keep(_GravityState piece) {
    final rect = piece._spot();
    if (rect == null || rect.width < 1 || rect.height < 1) return;
    final body = _stand(piece._body, piece._held, rect, piece);
    if (body == null) return;
    piece._held = rect;
    if (piece._body case final old?) _destroy(old);
    piece._body = body;
  }

  /// The line along the top of a platform's region [rect].
  static Rect _line(Rect rect) => Rect.fromLTWH(
    rect.left,
    rect.top,
    rect.width,
    math.min(_lineDepth, rect.height),
  );

  /// A new static box on [rect], or null while [old], standing on [at],
  /// is still within half a pixel of it.
  f2.Body? _stand(f2.Body? old, Rect at, Rect rect, Object owner) {
    if (old != null &&
        (rect.topLeft - at.topLeft).distance < .5 &&
        (rect.bottomRight - at.bottomRight).distance < .5) {
      return null;
    }
    final body = world.createBody(
      f2.BodyDef(
        userData: owner,
        position: f2.Vector2(rect.center.dx / _ppm, rect.center.dy / _ppm),
      ),
    );
    body.createFixture(
      f2.FixtureDef(
        f2.PolygonShape()
          ..setAsBoxXY(rect.width / 2 / _ppm, rect.height / 2 / _ppm),
        friction: .6,
      ),
    );
    return body;
  }

  void hold(_GravityState piece) {
    held.add(piece);
    _keep(piece);
    _wake();
  }

  /// Lets a held piece fall: it joins the pile from where it is laid out.
  void _free(_GravityState piece) {
    held.remove(piece);
    if (piece._body case final body?) _destroy(body);
    piece
      .._body = null
      .._world = null
      .._loose = false
      .._press = 0
      .._lift(check: false);
  }

  /// Pins a piece that just came into view by both top corners; one corner
  /// lets go after a while, so it swings from the other, then that one too.
  void hang(_GravityState piece) {
    final body = piece._body!;
    final random = _GravityState._random;
    final w = piece._size.width / 2 / _ppm, h = piece._size.height / 2 / _ppm;
    final first = _time + _hangLeast + random.nextDouble() * _hangExtra;
    final second = first + _hangLeast + random.nextDouble() * _hangExtra;
    final corners = [
      body.worldPoint(f2.Vector2(-w, -h)),
      body.worldPoint(f2.Vector2(w, -h)),
    ];
    if (random.nextBool()) corners.setAll(0, [corners[1], corners[0]]);
    for (final (corner, at) in [(corners[0], first), (corners[1], second)]) {
      final joint = f2.RevoluteJoint(
        f2.RevoluteJointDef()..initialize(_ground, body, corner),
      );
      world.createJoint(joint);
      piece._pins.add((joint, at));
    }
    _wake();
  }

  void wall(_GravityWallState wall) {
    walls.add(wall);
    _fit(0);
    _fence(wall);
    _wake();
  }

  void unwall(_GravityWallState wall) {
    if (!walls.remove(wall)) return;
    if (wall._body case final body?) _destroy(body);
    _retire();
  }

  /// Keeps a wall on its child's live span, the usable area's full height.
  void _fence(_GravityWallState wall) {
    if (!wall.mounted) return;
    final rect = _laidOut(wall.context, overlay);
    if (rect == null) return;
    final span = Rect.fromLTRB(
      rect.left,
      _area.top,
      math.max(rect.right, rect.left + 1),
      _area.bottom,
    );
    final body = _stand(wall._body, wall._placed, span, wall);
    if (body == null) return;
    wall._placed = span;
    if (wall._body case final old?) _destroy(old);
    wall._body = body;
  }

  /// [body]'s bounds in overlay pixels.
  static Rect _aabb(f2.Body body) {
    var rect = Rect.zero;
    for (final (i, fixture) in body.fixtures.indexed) {
      final box = fixture.getAABB(0);
      final r = Rect.fromLTRB(
        box.lowerBound.x * _ppm,
        box.lowerBound.y * _ppm,
        box.upperBound.x * _ppm,
        box.upperBound.y * _ppm,
      );
      rect = i == 0 ? r : rect.expandToInclude(r);
    }
    return rect;
  }

  /// The reset button's spot, in overlay pixels, while it shows.
  Rect? _buttonRect() => !_resetDue.value
      ? null
      : _seat ?? Rect.fromLTWH(_area.right - 3 - 40, _area.top + 3.5, 40, 27);

  /// Breaks a crushed piece into 6-14 chunks, each a small body showing its
  /// cut of what the piece painted; the piece hides until the trip home.
  void _split(_GravityState piece) {
    piece._breaking = false;
    if (!pieces.contains(piece) || _homing != null || !piece.mounted) return;
    final body = piece._body!;
    final size = piece._size;
    final ratio = View.of(overlay.context).devicePixelRatio;
    final snap = piece._snapKey.currentContext?.findRenderObject();
    final image = snap is RenderBox ? _snapshot(snap, ratio) : null;
    final random = _GravityState._random;
    final count = 6 + random.nextInt(9);
    var cols = math
        .sqrt(count * size.width / size.height)
        .round()
        .clamp(1, count);
    var rows = math.max(1, (count / cols).round());
    while (cols * rows > 14) {
      rows > 1 ? rows-- : cols--;
    }
    while (cols * rows < 6) {
      size.width >= size.height ? cols++ : rows++;
    }
    List<double> cuts(int n, double length) => [
      for (var i = 0; i <= n; i++)
        i == 0 || i == n
            ? i / n * length
            : (i + (random.nextDouble() - .5) * .6) / n * length,
    ];
    final xs = cuts(cols, size.width), ys = cuts(rows, size.height);
    final chunks = <(f2.Body, Rect)>[];
    for (var row = 0; row < rows; row++) {
      for (var col = 0; col < cols; col++) {
        final cell = Rect.fromLTRB(xs[col], ys[row], xs[col + 1], ys[row + 1]);
        final local =
            f2.Vector2(
              cell.center.dx - size.width / 2,
              cell.center.dy - size.height / 2,
            ) /
            _ppm;
        final chunk = world.createBody(
          f2.BodyDef(
            type: f2.BodyType.dynamic,
            position: body.worldPoint(local),
            angle: body.angle,
            angularVelocity: (random.nextDouble() - .5) * 6,
            linearVelocity:
                body.linearVelocityFromLocalPoint(local) +
                f2.Vector2(
                  (random.nextDouble() - .5) * 3,
                  -random.nextDouble() * 2,
                ),
          ),
        );
        chunk.createFixture(
          f2.FixtureDef(
            f2.PolygonShape()..setAsBoxXY(
              math.max(cell.width, 1) / 2 / _ppm,
              math.max(cell.height, 1) / 2 / _ppm,
            ),
            density: piece._density,
            friction: .6,
            restitution: .1,
          ),
        );
        chunks.add((chunk, cell));
      }
    }
    final burst = _Burst(
      chunks,
      image,
      size,
      _time,
      Offset(body.position.x * _ppm, body.position.y * _ppm),
      _contrast(Theme.of(overlay.context).colorScheme.surface, .5),
    );
    // Its pins and grip go with its body.
    _destroy(body);
    piece
      .._pins.clear()
      .._grip = null
      .._body = null
      .._burst = burst;
    pieces.remove(piece);
    broken.add(piece);
    burst.entry = OverlayEntry(
      builder: (_) => Positioned.fill(
        child: IgnorePointer(child: CustomPaint(painter: _ChunkPainter(burst))),
      ),
    );
    overlay.insert(burst.entry!, below: _button);
    piece._entry?.markNeedsBuild();
    // Too many chunks about: the oldest go first.
    var alive = broken.fold(0, (n, p) => n + p._burst!.chunks.length);
    final oldest = [...broken]
      ..sort((a, b) => a._burst!.born.compareTo(b._burst!.born));
    for (final old in oldest) {
      if (alive <= _maxChunks || old == piece) break;
      alive -= old._burst!.chunks.length;
      _shed(old, keep: true);
    }
    gravityImpactSound('sounds/gravity_crack.wav', .7);
    _wake();
  }

  /// Removes a shattered piece's chunks; [keep] leaves the piece hidden
  /// until the trip home.
  void _shed(_GravityState piece, {bool keep = false}) {
    final burst = piece._burst!;
    for (final (body, _) in burst.chunks) {
      _destroy(body);
    }
    burst.chunks.clear();
    burst.image?.dispose();
    burst.image = null;
    burst.entry
      ?..remove()
      ..dispose();
    burst.entry = null;
    if (!keep) piece._burst = null;
  }

  void leave(_GravityPlatformState platform) {
    if (!platforms.remove(platform)) return;
    if (platform._body case final bar?) _destroy(bar);
    for (final shard in platform._shards) {
      _destroy(shard.body);
    }
    platform._debris
      ?..remove()
      ..dispose();
    platform._debris = null;
    _retire();
  }

  /// Breaks a platform's line into 3–6 falling shards at cuts seeded by
  /// where it was hit, so the same hits break it the same way.
  void _shatter(_GravityPlatformState platform) {
    platform._breaking = false;
    final bar = platform._body;
    if (bar == null || !platforms.contains(platform) || _homing != null) {
      return;
    }
    final rect = _line(platform._placed);
    platform._body = null;
    // Its shards show what it painted there, when that can be captured.
    if (platform.context.findRenderObject() case final RenderBox box) {
      platform._image = _snapshot(
        box,
        View.of(overlay.context).devicePixelRatio,
      );
    }
    final random = math.Random(
      Object.hashAll([for (final (at, _) in platform._cracks) at]),
    );
    final count = 3 + random.nextInt(4);
    final cuts = [
      for (var i = 0; i <= count; i++)
        i == 0 || i == count
            ? i / count * rect.width
            : (i + (random.nextDouble() - .5) * .6) / count * rect.width,
    ];
    final shards = <_Shard>[];
    for (var i = 0; i < count; i++) {
      // Straight cuts: a slanted one leaves a sliver too thin for a body.
      final corners = [
        Offset(cuts[i], 0),
        Offset(cuts[i + 1], 0),
        Offset(cuts[i + 1], rect.height),
        Offset(cuts[i], rect.height),
      ];
      final centre = Offset((cuts[i] + cuts[i + 1]) / 2, rect.height / 2);
      final at = rect.topLeft + centre;
      final body = world.createBody(
        f2.BodyDef(
          type: f2.BodyType.dynamic,
          position: f2.Vector2(at.dx / _ppm, at.dy / _ppm),
          angularVelocity: (random.nextDouble() - .5) * 4,
          linearVelocity: f2.Vector2(
            (random.nextDouble() - .5) * 3,
            -random.nextDouble(),
          ),
        ),
      );
      body.createFixture(
        f2.FixtureDef(
          f2.PolygonShape()..setAsBoxXY(
            (cuts[i + 1] - cuts[i]) / 2 / _ppm,
            rect.height / 2 / _ppm,
          ),
          density: 2,
          friction: .6,
          restitution: .1,
        ),
      );
      shards.add(
        _Shard(body, [for (final corner in corners) corner - centre], centre),
      );
    }
    // Pieces passing through the bar pass through its shards instead.
    for (final piece in pieces) {
      if (piece._ghosts.remove(bar)) {
        piece._ghosts.addAll([for (final shard in shards) shard.body]);
      }
    }
    _destroy(bar);
    platform
      .._shards = shards
      .._debris = OverlayEntry(
        builder: (_) => Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(painter: _DebrisPainter(platform)),
          ),
        ),
      )
      .._redraw();
    overlay.insert(platform._debris!, below: _button);
    gravityImpactSound('sounds/gravity_crack.wav', 1);
    // Nothing holds its controls any more: they all fall at once.
    for (final piece in [...held]) {
      if (piece._shelf == platform) _free(piece);
    }
    _wake();
  }

  /// Destroys [body], waking whatever rested on it: Box2D leaves neighbours
  /// asleep.
  void _destroy(f2.Body body) {
    for (final contact in body.contacts) {
      contact.getOtherBody(body).setAwake(true);
    }
    world.destroyBody(body);
    _trips.removeWhere((trip) => trip.$1 == body);
    for (final piece in pieces) {
      piece._ghosts.remove(body);
    }
  }

  /// Gives [body] one box fixture of the piece's width and [height] pixels.
  void _shape(f2.Body body, _GravityState piece, double height) {
    for (final fixture in [...body.fixtures]) {
      body.destroyFixture(fixture);
    }
    body.createFixture(
      f2.FixtureDef(
        f2.PolygonShape()
          ..setAsBoxXY(piece._size.width / 2 / _ppm, height / 2 / _ppm),
        density: piece._density,
        friction: .6,
        restitution: .1,
      ),
    );
  }

  /// Grows a squeezing piece by [dt] seconds, its bottom edge held still.
  void _squeeze(_GravityState piece, double dt) {
    final body = piece._body!;
    final h = piece._size.height;
    final bottom = body.position.y * _ppm + h * piece._squash / 2;
    piece._squash = math.min(1, piece._squash + dt / _squeezeSeconds);
    _shape(body, piece, h * piece._squash);
    body.setTransform(
      f2.Vector2(body.position.x, (bottom - h * piece._squash / 2) / _ppm),
      0,
    );
    if (piece._squash < 1) return;
    piece._coming = null;
    body.setType(f2.BodyType.dynamic);
  }

  /// [global] in world metres, kept inside the walls.
  f2.Vector2 point(Offset global) {
    final box = overlay.context.findRenderObject()! as RenderBox;
    final at = box.globalToLocal(global);
    return f2.Vector2(
      at.dx.clamp(_area.left, _area.right) / _ppm,
      at.dy.clamp(_area.top, _area.bottom) / _ppm,
    );
  }

  /// Pins [body] at [global] to a target that the pointer then moves.
  f2.MouseJoint grab(f2.Body body, Offset global) {
    final joint = f2.MouseJoint(
      f2.MouseJointDef()
        ..bodyA = _ground
        ..bodyB = body
        ..target.setFrom(point(global))
        ..maxForce = 1000 * body.mass,
    );
    world.createJoint(joint);
    body
      ..setSleepingAllowed(false)
      ..setAwake(true);
    _wake();
    return joint;
  }

  /// Lets go; a throw carries the pointer's [velocity] in pixels per second.
  void release(f2.MouseJoint joint, Offset? velocity) {
    final body = joint.bodyB;
    world.destroyJoint(joint);
    body.setSleepingAllowed(true);
    if (velocity != null) {
      final speed = f2.Vector2(velocity.dx, velocity.dy) / _ppm;
      if (speed.length > _throw) speed.scale(_throw / speed.length);
      body.linearVelocity = speed;
    }
    body.setAwake(true);
    _wake();
  }

  void remove(_GravityState piece) {
    final shattered = broken.remove(piece);
    if (shattered) _shed(piece);
    if (!pieces.remove(piece) && !held.remove(piece) && !shattered) return;
    if (piece.widget.resetHere) _seat = null;
    if (piece._body case final body?) _destroy(body);
    _retire();
  }

  /// Ends this world once nothing is left in it.
  void _retire() {
    if (pieces.isNotEmpty ||
        platforms.isNotEmpty ||
        held.isNotEmpty ||
        broken.isNotEmpty ||
        walls.isNotEmpty) {
      return _wake();
    }
    _ticker.dispose();
    _button
      ..remove()
      ..dispose();
    WidgetsBinding.instance.removeObserver(this);
    _worlds.remove(overlay);
    if (_worlds.isNotEmpty) return;
    _sense(false);
    _down.setValues(0, 1);
    _woke.setValues(0, 1);
    _pull = _g;
  }

  /// Steers the walls onto the usable area over the next step of [dt]
  /// seconds (at once when 0); returns whether any wall is still moving.
  bool _fit(double dt) {
    final area = _usable();
    final jump = _area.isEmpty || dt == 0;
    if (area != _area) {
      _area = area;
      for (final piece in pieces) {
        if (piece.widget.resetHere) _seat = piece._spot() ?? _seat;
      }
      _button.markNeedsBuild();
      for (final piece in pieces) {
        piece._body!.setAwake(true);
      }
    }
    var moving = false;
    for (final (wall, target) in [
      (_floor, f2.Vector2(0, area.bottom / _ppm)),
      (_ceiling, f2.Vector2(0, area.top / _ppm)),
      (_left, f2.Vector2(area.left / _ppm, 0)),
      (_right, f2.Vector2(area.right / _ppm, 0)),
    ]) {
      final gap = target - wall.position;
      if (jump) {
        wall.setTransform(target, 0);
      } else if (gap.length < 1e-4) {
        wall.linearVelocity = f2.Vector2.zero();
      } else {
        final velocity = gap / dt;
        if (velocity.length > _wallSpeed) {
          velocity.scale(_wallSpeed / velocity.length);
        }
        wall.linearVelocity = velocity;
        moving = true;
      }
    }
    return moving;
  }

  void _shake() {
    for (final piece in pieces) {
      piece._body!.setAwake(true);
    }
    _wake();
  }

  /// Adds [kick] (m/s) to every loose piece and shard and wakes it; [jostle]
  /// varies it per body so a shake tumbles the pile instead of carrying it.
  void _push(f2.Vector2 kick, {bool jostle = false}) {
    if (_homing != null) return;
    for (final body in [
      for (final piece in pieces)
        if (piece._grip == null) piece._body!,
      for (final platform in platforms)
        for (final shard in platform._shards) shard.body,
    ]) {
      if (body.bodyType != f2.BodyType.dynamic) continue;
      final share = jostle ? .6 + _GravityState._random.nextDouble() * .8 : 1;
      final speed = body.linearVelocity + kick * share.toDouble();
      if (speed.length > _throw) speed.scale(_throw / speed.length);
      body
        ..linearVelocity = speed
        ..setAwake(true);
    }
    _wake();
  }

  void _wake() {
    if (_ticker.isActive) return;
    _last = Duration.zero;
    _owed = 0;
    _ticker.start();
  }

  void _tick(Duration elapsed) {
    // Fixed steps: one long step of a slow frame lets small fast pieces sink
    // into each other and jitter there forever. A frame slower than 1/30 s
    // drops the rest of its time (slow motion) instead of piling up steps.
    final frame = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    if (_homing != null) return _homeStep(math.min(frame, 1 / 30));
    _owed = math.min(_owed + frame, 1 / 30);
    final count = (_owed / _h + 1e-6).floor();
    _owed -= count * _h;
    // No step this frame: leave the walls be and look again next frame.
    final moving = count == 0 || _fit(count * _h);
    for (final piece in pieces) {
      if (piece._squash < 1 && count > 0) _squeeze(piece, count * _h);
    }
    for (final platform in platforms) {
      _place(platform);
    }
    for (final piece in held) {
      _keep(piece);
    }
    for (final wall in walls) {
      _fence(wall);
    }
    if (count > 0) {
      final started = _clock.elapsedMicroseconds;
      for (var i = 0; i < count; i++) {
        world.stepDt(_h);
      }
      stepMicros += _clock.elapsedMicroseconds - started;
      steps += count;
      _time += count * _h;
    }
    var awake = moving;
    for (final piece in [...held]) {
      if (piece._loose) _free(piece);
    }
    if (count > 0) awake |= _wear(count * _h);
    for (final piece in [...broken]) {
      final burst = piece._burst!;
      if (burst.chunks.isEmpty) continue;
      final age = _time - burst.born;
      burst.shown = ((_chunkLife - age) / _chunkFade).clamp(0, 1);
      if (age >= _chunkLife) {
        _shed(piece, keep: true);
        continue;
      }
      awake = true;
      burst.entry?.markNeedsBuild();
    }
    for (final platform in [...platforms]) {
      // Bodies cannot change while the world steps, so damage lands here,
      // after this frame's paint, which the shards show.
      if (platform._damage >= 1 &&
          platform._body != null &&
          !platform._breaking) {
        platform._breaking = true;
        SchedulerBinding.instance.addPostFrameCallback(
          (_) => _shatter(platform),
        );
      }
      if (platform._cracked) {
        platform
          .._cracked = false
          .._redraw();
      }
      for (final shard in platform._shards) {
        awake |= shard.body.isAwake;
      }
      platform._debris?.markNeedsBuild();
    }
    for (final piece in pieces) {
      final body = piece._body!;
      final at = Offset(body.position.x * _ppm, body.position.y * _ppm);
      if (body.bodyType == f2.BodyType.kinematic) {
        final inside = switch (piece._coming) {
          GravityEntry.fromBelow =>
            at.dy + piece._size.height / 2 <= _area.bottom,
          GravityEntry.fromAbove => at.dy - piece._size.height / 2 >= _area.top,
          _ => false,
        };
        if (inside) {
          piece._coming = null;
          body.setType(f2.BodyType.dynamic);
        }
      } else if (!_area.contains(at)) {
        // Escaped past a fast wall: put it back just inside.
        final w = math.min(piece._size.width, _area.width) / 2;
        final h = math.min(piece._size.height, _area.height) / 2;
        body.setTransform(
          f2.Vector2(
            at.dx.clamp(_area.left + w, _area.right - w) / _ppm,
            at.dy.clamp(_area.top + h, _area.bottom - h) / _ppm,
          ),
          body.angle,
        );
        body.linearVelocity = f2.Vector2.zero();
      }
      if (body.bodyType == f2.BodyType.dynamic) _side(piece);
      awake |= body.isAwake;
      piece._entry?.markNeedsBuild();
      if (piece._ghosts.isNotEmpty) _unghost(piece);
    }
    // Everything settled: let the CPU idle until something changes.
    if (!awake) _ticker.stop();
  }

  /// Puts a piece pushed past a wall's middle back on the side it started.
  void _side(_GravityState piece) {
    final body = piece._body!;
    for (final wall in walls) {
      final span = wall._placed;
      if (wall._body == null || span.isEmpty) continue;
      final x = body.position.x * _ppm, middle = span.center.dx;
      // The side it is first seen on, which it keeps as the wall moves.
      final west = wall._west[piece] ??= x < middle;
      if (west == x < middle) continue;
      final half = _aabb(body).width / 2;
      body
        ..setTransform(
          f2.Vector2(
            (west ? span.left - half : span.right + half) / _ppm,
            body.position.y,
          ),
          body.angle,
        )
        ..linearVelocity = f2.Vector2.zero();
    }
  }

  /// Releases due pins and wears pieces down over [dt] seconds of steps:
  /// a sustained squeeze far beyond a calm pile, or resting over the reset
  /// button. Returns whether anything must keep the world running.
  bool _wear(double dt) {
    var busy = false;
    final keep = math.exp(-dt / _loadWindow);
    final button = _buttonRect()?.deflate(2);
    for (final piece in pieces) {
      final body = piece._body!;
      piece._pins.removeWhere((pin) {
        if (_time < pin.$2) return false;
        world.destroyJoint(pin.$1);
        return true;
      });
      busy |= piece._pins.isNotEmpty;
      // Every contact pushes on it from both sides: half is the squeeze.
      piece._load = piece._load * keep + piece._press / 2 / dt * (1 - keep);
      piece._press = 0;
      var hurt = 0.0;
      if (piece._load > _crush) {
        hurt += _crushRate * piece._load / _crush * dt;
        // A crushed pile must not doze off half-broken.
        body.setAwake(true);
      }
      if (button != null &&
          body.linearVelocity.length < _resting &&
          _aabb(body).overlaps(button)) {
        hurt += _coverRate * dt;
        busy = true;
      }
      if (hurt == 0) continue;
      piece._damage = math.min(1, piece._damage + hurt);
      if (piece._damage < 1 || piece._breaking) continue;
      // After this frame's paint, which its chunks show.
      piece._breaking = true;
      SchedulerBinding.instance.addPostFrameCallback((_) => _split(piece));
    }
    return busy;
  }

  /// Lets a piece collide with the platforms it has fully left.
  void _unghost(_GravityState piece) {
    final fixture = piece._body!.fixtures.first;
    final box = fixture.getAABB(0);
    final left = piece._ghosts
        .where(
          (ghost) => !ghost.fixtures.any(
            (other) => f2.AABB.testOverlap(box, other.getAABB(0)),
          ),
        )
        .toList();
    if (left.isEmpty) return;
    piece._ghosts.removeAll(left);
    fixture.refilter();
  }

  /// Wears a platform down where a piece hits it: anything merely falling
  /// on it leaves hairlines up to [_crackCap]; thrown pieces hitting hard
  /// crack it further until it breaks at 1.
  void _hurt(f2.Contact contact, double hit) {
    final a = contact.bodyA, b = contact.bodyB;
    final (bar, other) = a.userData is _GravityPlatformState ? (a, b) : (b, a);
    final platform = bar.userData, piece = other.userData;
    if (platform is! _GravityPlatformState || piece is! _GravityState) return;
    if (platform._damage >= 1) return;
    // The change in the piece's speed, in m/s.
    final speed = hit / other.mass;
    final before = platform._damage;
    final hard = _thrown(piece) && speed >= _hardHit;
    platform._damage = hard
        ? before + .12 + (speed - _hardHit) * .01
        : math.max(before, math.min(_crackCap, before + speed * .01));
    if (platform._damage <= before || speed < 1) return;
    contact.getWorldManifold(_manifold);
    final at = _manifold.points[0];
    platform._cracks.add((
      Offset(at.x * _ppm, at.y * _ppm) - platform._placed.topLeft,
      hard ? math.min(1, speed / _throw) : .15,
    ));
    platform._cracked = true;
  }

  bool _thrown(_GravityState piece) =>
      piece._grip != null || _time - piece._thrownAt < 1.5;

  /// A thrown piece hitting a held one hard knocks it loose.
  void _knock(f2.Contact contact, double hit) {
    for (final (still, other) in [
      (contact.bodyA, contact.bodyB),
      (contact.bodyB, contact.bodyA),
    ]) {
      final piece = still.userData, by = other.userData;
      if (piece is _GravityState &&
          held.contains(piece) &&
          by is _GravityState &&
          _thrown(by) &&
          hit / other.mass >= _hardHit) {
        piece._loose = true;
      }
    }
  }

  @override
  void beginContact(f2.Contact contact) => _fresh.add(contact);

  @override
  void endContact(f2.Contact contact) => _fresh.remove(contact);

  // Only the first solve of a new contact carries the impact.
  @override
  void postSolve(f2.Contact contact, f2.ContactImpulse impulse) {
    var push = 0.0;
    for (var i = 0; i < impulse.count; i++) {
      push += impulse.normalImpulses[i];
    }
    for (final body in [contact.bodyA, contact.bodyB]) {
      if (body.userData case final _GravityState piece) piece._press += push;
    }
    if (!_fresh.remove(contact)) return;
    var hit = 0.0;
    for (var i = 0; i < impulse.count; i++) {
      hit = math.max(hit, impulse.normalImpulses[i]);
    }
    _hurt(contact, hit);
    _knock(contact, hit);
    final mass = math.max(contact.bodyA.mass, contact.bodyB.mass);
    final volume = _volume(hit, contact.bodyA.mass, contact.bodyB.mass);
    if (volume == 0) return;
    // At most ~12 sounds a second so an avalanche stays a patter. Measured in
    // simulated time, which is what the viewer sees, not wall-clock time.
    final now = (_World.steps * _h * 1e6).round();
    if (now - _lastSound < 85000) return;
    _lastSound = now;
    gravityImpactSound(
      mass > 1
          ? 'sounds/gravity_thud.wav'
          : mass > .2
          ? 'sounds/gravity_knock.wav'
          : 'sounds/gravity_tick.wav',
      volume,
    );
  }
}

/// Keeps pieces out of contact with the platforms they started inside.
class _Ghosts extends f2.ContactFilter {
  @override
  bool shouldCollide(f2.Fixture fixtureA, f2.Fixture fixtureB) {
    final a = fixtureA.body, b = fixtureB.body;
    return !(a.userData is _GravityState &&
            (a.userData! as _GravityState)._ghosts.contains(b)) &&
        !(b.userData is _GravityState &&
            (b.userData! as _GravityState)._ghosts.contains(a));
  }
}

final _impactPlayers = <String, AudioPlayer>{};
final _impactContext = AudioContextConfig(
  focus: AudioContextConfigFocus.mixWithOthers,
).build();

void _playImpact(String asset, double volume) {
  try {
    final player = _impactPlayers.putIfAbsent(asset, AudioPlayer.new);
    unawaited(
      player
          .play(AssetSource(asset), volume: volume, ctx: _impactContext)
          .catchError((Object _) {}),
    );
  } catch (_) {
    // A missing output device must not break the easter egg.
  }
}
