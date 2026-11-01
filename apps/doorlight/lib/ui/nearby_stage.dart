import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../state/app_state.dart';
import '../state/nearby.dart';
import '../theme.dart';
import 'gravity.dart';
import 'sonar_button.dart';
import 'sonar_combat_painter.dart';
import 'sonar_warp.dart';
import 'sybl_ui.dart';

/// Nearby as a small scene: your picture sits low and sends a sonar ripple
/// for every announcement while you are revealed, and each person who turns
/// up steps out through a door above it. A ripple echoes off whoever its
/// front reaches; a ping ripples out of its sender and lands on you.
///
/// Sonar combat: tapping a person's picture charges a missile at them; the
/// rocket arcs across, and one fired at you arcs in from its shooter.
///
/// One ticker drives everything and only runs while something moves; reduced
/// motion shows every final state at once.
class NearbyStage extends StatefulWidget {
  const NearbyStage({
    super.key,
    required this.state,
    required this.nearby,
    required this.waved,
    required this.sonarSize,
    this.availableHeight,
    required this.status,
    required this.onAdd,
    this.centered = false,
  });

  final AppState state;
  final NearbyController nearby;

  /// Someone waved before Nearby opened; their ripple plays once they arrive.
  final bool waved;
  final double sonarSize;
  final double? availableHeight;

  /// Shown between the stage and the overflow list.
  final Widget status;
  final ValueChanged<NearbyPeer> onAdd;

  /// Balances the space under your picture with the row reserved above it,
  /// so the sonar sits in the middle of a desktop page.
  final bool centered;

  /// People placed on the stage; the rest wait in a compact list below it.
  static const slots = 6;

  @override
  State<NearbyStage> createState() => _NearbyStageState();
}

class _Arrival {
  _Arrival(this.slot, this.at);
  final int slot;
  final double at;
}

/// A sonar ripple. A null source is you; [top] is the stage's top edge, for a
/// sender who is not on it.
class _Ring {
  _Ring(this.from, this.at, {this.top = false});
  final String? from;
  final double at;
  final bool top;
  bool landed = false;
  bool get mine => from == null && !top;
}

/// A missile in flight. A null end is you; [top] stands in for a shooter
/// who is not on the stage.
class _Missile {
  _Missile(this.from, this.to, this.at, int level, {this.top = false})
    : flight =
          (SonarCombat.flight(level) - SonarCombat.prefire).inMicroseconds /
          1e6,
      bow = SonarCombat.bow(level);
  final String? from;
  final String? to;
  final double at;
  final double flight;
  final double bow;
  final bool top;
  bool landed = false;
  Offset? detonation;
  double? resolvedAt;
  bool lost = false;
  bool surfaceHit = false;
  double get end =>
      resolvedAt == null ? at + flight : resolvedAt! + (lost ? 2.25 : 0);
}

/// Someone who just left the stage, kept briefly so they can sink.
typedef _Departed = ({Rect rect, String name, double at});

// Timeline, in seconds from a person's arrival.
const _frameIn = .3;
const _openFrom = .15;
const _openTime = .4;
const _emergeFrom = .35;
const _emerge = .6;
const _shutFrom = 1.15;
const _shutTime = .35;
const _fadeFrom = 1.45;
const _fadeTime = .55;
const _labelFrom = .75;
const _labelFade = .4;
const _arrival = _labelFrom + _labelFade;
// The door has closed behind a newcomer and faded.
const _settled = 2.0;
const _burst = .6;
const _shake = .45;
const _ringLife = 3.6;
// Ripple fronts travel at one speed, so an echo comes when the front arrives.
const _rippleSpeed = 180.0;
const _echo = .4;
const _blast = .8;
const _sink = 1.6;
// Roughly the status line under the stage, for [NearbyStage.centered].
const _statusHeight = 24.0;

class _NearbyStageState extends State<NearbyStage>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final _clock = ValueNotifier<double>(0);
  final _staged = <String, _Arrival>{};
  final _rings = <_Ring>[];
  final _missiles = <_Missile>[];
  final _departed = <String, _Departed>{};
  final _sinking = <String, _Departed>{};
  final _rects = <String, Rect>{};
  final _names = <String, String>{};
  StreamSubscription<String>? _waves;
  StreamSubscription<void>? _announced;
  StreamSubscription<SonarEvent>? _combat;
  double _t = 0;
  double _base = 0;
  double _until = 0;
  bool _dirty = false;
  bool _started = false;
  int _cols = 2;
  double? _landedAt;
  double? _hitAt;
  String? _wavedBy;
  Offset? _own;
  double _width = 0;
  double _rowHeight = 156;
  double _tileAvatar = 56;
  double _tileTop = 72;

  bool get _still => MediaQuery.disableAnimationsOf(context);

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick);
    widget.nearby.addListener(_changed);
    _waves = widget.nearby.sonarReceived.listen((id) {
      if (!mounted) return;
      final arrival = _staged[id];
      setState(
        () => _waveIn(
          arrival == null ? null : id,
          math.max(_t, (arrival?.at ?? _t) + _arrival),
        ),
      );
    });
    // Ripples leave you only for announcements actually sent, so a hidden
    // device stays still.
    _announced = widget.nearby.announced.listen((_) {
      if (!mounted) return;
      // Every announcement sent is felt, even with motion reduced.
      unawaited(HapticFeedback.lightImpact());
      // A tap already rippled for the pulse it sent.
      if (_rings.any((ring) => ring.mine && _t - ring.at < .25)) return;
      _rippleOut();
    });
    _combat = widget.nearby.combat.listen(_onCombat);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _sync();
    if (widget.waved) {
      final first = widget.nearby.peers.firstOrNull;
      final arrival = first == null ? null : _staged[first.id];
      _waveIn(
        arrival == null ? null : first!.id,
        (arrival?.at ?? _t) + _arrival,
      );
    }
    _ensureTicker();
  }

  @override
  void dispose() {
    widget.nearby.removeListener(_changed);
    _waves?.cancel();
    _announced?.cancel();
    _combat?.cancel();
    _ticker.dispose();
    _clock.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(_sync);
  }

  static int _hash(String id) =>
      id.codeUnits.fold(0, (hash, unit) => (hash * 31 + unit) & 0x7fffffff);

  /// Keeps each staged person in the slot they arrived in; newcomers take the
  /// lowest row with room, at a column chosen from their ID.
  void _sync() {
    final peers = widget.nearby.peers;
    final ids = {for (final peer in peers) peer.id};
    _staged.removeWhere((id, _) {
      if (ids.contains(id)) return false;
      if ((_rects[id], _names[id]) case (final rect?, final name?)) {
        _departed[id] = (rect: rect, name: name, at: _t);
      }
      return true;
    });
    _departed.removeWhere((_, gone) => _t - gone.at > 2);
    var stagger = 0.0;
    var added = false;
    for (final peer in peers) {
      if (_staged.length >= NearbyStage.slots) break;
      if (_staged.containsKey(peer.id)) continue;
      final taken = {for (final arrival in _staged.values) arrival.slot};
      final cols = _cols;
      var slot = -1;
      for (var row = 0; slot < 0 && row * cols < NearbyStage.slots; row++) {
        for (var step = 0; step < cols; step++) {
          final index = row * cols + (_hash(peer.id) + step) % cols;
          if (index < NearbyStage.slots && !taken.contains(index)) {
            slot = index;
            break;
          }
        }
      }
      _staged[peer.id] = _Arrival(slot, _still ? -100 : _t + stagger);
      stagger += .18;
      added = true;
    }
    if (added) _kick(_t + stagger + _settled);
    // The charge brackets pulse for the whole window.
    if (widget.nearby.chargeTarget != null) {
      _kick(_t + SonarCombat.chargeWindow.inMicroseconds / 1e6);
    }
    _ensureTicker();
  }

  void _kick(double end) {
    _until = math.max(_until, end);
    _ensureTicker();
  }

  void _ensureTicker() {
    if (_still || _ticker.isActive || _t > _until) return;
    _base = _t;
    _ticker.start();
  }

  void _tick(Duration elapsed) {
    _t = _base + elapsed.inMicroseconds / 1e6;
    _land();
    _clock.value = _t;
    final busy = _t <= _until;
    // One more rebuild after the last movement settles every label.
    if (busy || _dirty) setState(() {});
    _dirty = busy;
    if (!busy) _ticker.stop();
  }

  Offset _point(String? id, {bool top = false}) {
    if (top) return Offset(_width / 2, 24);
    if (id == null) return _own ?? Offset.zero;
    final rect = _rects[id];
    return rect == null ? Offset(_width / 2, 24) : _face(rect);
  }

  Offset _face(Rect rect) =>
      Offset(rect.center.dx, rect.top + _tileTop - 6 - _tileAvatar / 2);

  /// When [ring]'s front reaches [target].
  double _reach(_Ring ring, Offset target) {
    final start = ring.mine ? widget.sonarSize / 2 + 9 : _tileAvatar / 2 + 2;
    final from = _point(ring.from, top: ring.top);
    final distance = math.max(0.0, (target - from).distance - start);
    return ring.at + math.min(distance / _rippleSpeed, _ringLife);
  }

  void _land() {
    if (_own case final own?) {
      for (final ring in _rings) {
        if (ring.mine || ring.landed || _t < _reach(ring, own)) continue;
        ring.landed = true;
        _arrived(ring.from);
      }
    }
    for (final missile in _missiles) {
      if (missile.landed || _t < missile.end) continue;
      missile.landed = true;
      if (missile.to == null) {
        if (!missile.lost && missile.detonation == null) {
          _hitAt = _t;
          unawaited(HapticFeedback.heavyImpact());
        }
      }
      if (missile.detonation case final point?) {
        final box = context.findRenderObject();
        if (box is RenderBox && !missile.surfaceHit) {
          missile.surfaceHit = true;
          SonarWarp.maybeOf(
            context,
          )?.reveal(box.localToGlobal(point), full: false);
        }
      }
    }
    _rings.removeWhere((ring) => _t > ring.at + _ringLife);
    _missiles.removeWhere((missile) => _t > missile.end + _blast);
    _sinking.removeWhere((_, sunk) => _t > sunk.at + _sink);
  }

  void _arrived(String? from) {
    unawaited(HapticFeedback.mediumImpact());
    _landedAt = _t;
    _wavedBy = from;
  }

  /// Someone waved: their ripple spreads and lands on you.
  void _waveIn(String? from, double at) {
    if (_still) return _arrived(from);
    _rings.add(_Ring(from, at, top: from == null));
    _kick(at + _ringLife);
  }

  /// Your own ripple; it echoes off everyone its front reaches.
  void _rippleOut() {
    if (_still) return;
    _rings.add(_Ring(null, _t));
    _kick(_t + _ringLife);
  }

  void _onCombat(SonarEvent event) {
    if (!mounted) return;
    final peer = event.peer;
    switch (event.cue) {
      case SonarCue.launched when peer != null:
        if (_still) return;
        final missile = _Missile(null, peer, _t + .5, event.level);
        setState(() => _missiles.add(missile));
        _kick(missile.end + _blast);
      case SonarCue.incoming when peer != null:
        if (_still) return;
        final staged = _staged.containsKey(peer);
        final missile = _Missile(
          peer,
          null,
          _t + .5,
          event.level,
          top: !staged,
        );
        setState(() => _missiles.add(missile));
        _kick(missile.end + _blast);
      case SonarCue.missileGone:
        setState(() => _missiles.removeWhere((m) => m.from == null));
      case SonarCue.targetLost:
        for (final missile in _missiles.where(
          (m) =>
              !m.landed &&
              m.resolvedAt == null &&
              (event.inbound ? m.from == peer : m.to == peer),
        )) {
          final from = _point(missile.from, top: missile.top),
              to = _point(missile.to);
          final q = ((_t - missile.at) / missile.flight).clamp(0.0, 1.0);
          final position = SonarCombatPainter.arc(from, to, missile.bow, q);
          missile
            ..lost = true
            ..resolvedAt = _t
            ..detonation =
                position +
                Offset(
                  (peer.hashCode.isEven ? 1 : -1) * math.min(100, _width / 4),
                  65,
                );
          _kick(missile.end + _blast);
        }
      case SonarCue.collision:
        final pair = _missiles
            .where(
              (m) =>
                  !m.landed &&
                  m.resolvedAt == null &&
                  (m.to == peer || m.from == peer),
            )
            .toList();
        if (pair.isEmpty) return;
        final positions = pair.map(
          (m) => SonarCombatPainter.arc(
            _point(m.from, top: m.top),
            _point(m.to),
            m.bow,
            ((_t - m.at) / m.flight).clamp(0.0, 1.0),
          ),
        );
        final point =
            positions.reduce((a, b) => a + b) / pair.length.toDouble();
        for (final missile in pair) {
          missile
            ..resolvedAt = _t
            ..detonation = point;
        }
        _kick(_t + _blast);
      case SonarCue.destroyed:
        final fatal = _missiles
            .where(
              (m) => m.to == null && m.from == peer && m.resolvedAt == null,
            )
            .lastOrNull;
        if (fatal != null) {
          fatal
            ..landed = false
            ..resolvedAt = _t + 1
            ..detonation = _point(null);
          _kick(fatal.end + _blast);
        }
        SonarWarp.maybeOf(context)?.death();
      case SonarCue.sunk when peer != null:
        final gone = _departed.remove(peer);
        if (gone == null || _still) return;
        setState(
          () => _sinking[peer] = (rect: gone.rect, name: gone.name, at: _t),
        );
        _kick(_t + _sink);
      default:
        break;
    }
  }

  void _aim(NearbyPeer peer) {
    if (widget.nearby.aim(peer.id)) {
      unawaited(HapticFeedback.selectionClick());
    }
  }

  static double _progress(double value, double from, double length) =>
      ((value - from) / length).clamp(0.0, 1.0);

  /// How strongly [id]'s picture pulses from a ripple echo right now.
  double _echoOf(String id) {
    final rect = _rects[id];
    if (rect == null) return 0;
    final face = _face(rect);
    var pulse = 0.0;
    for (final ring in _rings) {
      if (!ring.mine) continue;
      final age = _t - _reach(ring, face);
      if (age < 0 || age > _echo) continue;
      pulse = math.max(pulse, math.sin(math.pi * age / _echo));
    }
    return pulse;
  }

  /// A missile of yours landed on [id] just now.
  double _shakeOf(String id) {
    for (final missile in _missiles) {
      if (missile.to != id) continue;
      final age = _t - missile.end;
      if (age >= 0 && age < _shake) return age / _shake;
    }
    return 1;
  }

  Widget _tile(BuildContext context, NearbyPeer peer, _Arrival arrival) {
    final age = _t - arrival.at;
    // The picture steps forward out of the dark doorway.
    final emerge = Curves.easeOutBack.transform(
      _progress(age, _emergeFrom, _emerge),
    );
    final label = _progress(age, _labelFrom, _labelFade);
    final name = peer.name.isEmpty ? 'Unnamed' : peer.name;
    final echo = _echoOf(peer.id);
    final shake = _shakeOf(peer.id);
    return Column(
      key: ValueKey('nearby-peer-${peer.id}'),
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: _tileTop,
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Transform.translate(
              offset: Offset(
                math.sin(shake * math.pi * 8) * 6 * (1 - shake),
                (1 - emerge) * -6,
              ),
              child: Transform.scale(
                key: ValueKey('nearby-avatar-${peer.id}'),
                scale: (.35 + .65 * emerge) * (1 + .12 * echo),
                child: Opacity(
                  opacity: _progress(age, _emergeFrom, _emerge * .5),
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    // Tap to charge a missile at them; each tap adds power.
                    // Only a real tap counts: a scroll, drag or brush that
                    // starts on them loses the gesture and never fires, and
                    // nobody can be hit before they are through the door.
                    child: IgnorePointer(
                      ignoring: _progress(age, _emergeFrom, _emerge * .5) < 1,
                      child: Semantics(
                        button: true,
                        label: 'Fire at $name',
                        onTap: () => _aim(peer),
                        excludeSemantics: true,
                        child: Tooltip(
                          message: 'Fire at $name',
                          child: Material(
                            color: Colors.transparent,
                            child: InkResponse(
                              key: ValueKey('nearby-target-${peer.id}'),
                              onTap: () => _aim(peer),
                              radius: _tileAvatar / 2 + 6,
                              customBorder: const CircleBorder(),
                              child: SyblAvatar(
                                label: peer.name.isEmpty ? '?' : peer.name,
                                size: _tileAvatar,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        IgnorePointer(
          ignoring: label < 1,
          child: Opacity(
            opacity: label,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Gravity(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                _action(context, peer, name, tile: true),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Your sunk target slips under and fades.
  Widget _sunk(_Departed sunk) {
    final q = Curves.easeIn.transform(_progress(_t - sunk.at, 0, _sink));
    return Transform.translate(
      offset: Offset(0, q * 34),
      child: Transform.rotate(
        angle: q * .35,
        child: Opacity(
          opacity: 1 - q,
          child: Padding(
            padding: EdgeInsets.only(top: _tileTop - 6 - _tileAvatar),
            child: Center(
              child: SyblAvatar(
                label: sunk.name.isEmpty ? '?' : sunk.name,
                size: _tileAvatar,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(BuildContext context, NearbyPeer peer, {bool fire = false}) {
    final name = peer.name.isEmpty ? 'Unnamed' : peer.name;
    return ListTile(
      key: ValueKey('nearby-peer-${peer.id}'),
      contentPadding: EdgeInsets.zero,
      leading: fire
          ? Semantics(
              button: true,
              label: 'Fire at $name',
              onTap: () => _aim(peer),
              excludeSemantics: true,
              child: Tooltip(
                message: 'Fire at $name',
                child: InkResponse(
                  key: ValueKey('nearby-target-${peer.id}'),
                  onTap: () => _aim(peer),
                  radius: 26,
                  customBorder: const CircleBorder(),
                  child: SyblAvatar(
                    label: peer.name.isEmpty ? '?' : peer.name,
                    size: 40,
                  ),
                ),
              ),
            )
          : SyblAvatar(label: peer.name.isEmpty ? '?' : peer.name, size: 40),
      title: Gravity(
        child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      trailing: _action(context, peer, name),
    );
  }

  /// Friends / Request sent / Accept / Add, from daemon-backed state.
  Widget _action(
    BuildContext context,
    NearbyPeer peer,
    String name, {
    bool tile = false,
  }) {
    final state = widget.state;
    final friend = state.friends[peer.id];
    final label = friend == null
        ? null
        : !friend.confirmed
        ? 'Request sent'
        : state.peerLeft(peer.id) || state.isRemovalPending(peer.id)
        ? null
        : 'Friends';
    if (label != null) {
      final text = Text(
        label,
        key: ValueKey('nearby-state-${peer.id}'),
        style: TextStyle(color: context.syblColors.faint),
      );
      return Gravity(
        child: tile
            ? Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: text,
              )
            : text,
      );
    }
    final request = state.incomingRequestFrom(peer.id);
    return Gravity(
      child: request != null
          ? FilledButton(
              key: ValueKey('nearby-accept-${peer.id}'),
              onPressed: state.handlingConnect
                  ? null
                  : () => state.allowConnectFrom(request.convId),
              style: tile
                  ? FilledButton.styleFrom(
                      minimumSize: const Size(64, 36),
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                    )
                  : null,
              child: Text('Accept', semanticsLabel: 'Accept $name'),
            )
          : TextButton.icon(
              key: ValueKey('nearby-add-${peer.id}'),
              onPressed: () => widget.onAdd(peer),
              style: TextButton.styleFrom(
                foregroundColor: context.syblColors.amber,
                minimumSize: const Size(64, 44),
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              icon: const Icon(Icons.person_add_alt_1_rounded, size: 16),
              label: Text('Add', semanticsLabel: 'Add $name'),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.syblColors;
    final state = widget.state;
    final nearby = widget.nearby;
    final peers = nearby.peers;
    final size = widget.sonarSize;
    final compactDesktop =
        widget.availableHeight != null &&
        widget.availableHeight!.isFinite &&
        switch (Theme.of(context).platform) {
          TargetPlatform.android || TargetPlatform.iOS => false,
          _ => true,
        };
    final stagePeers = compactDesktop
        ? peers.where((peer) => _staged.containsKey(peer.id)).take(1).toList()
        : peers.where((peer) => _staged.containsKey(peer.id)).toList();
    final overflow = peers
        .where((peer) => !stagePeers.any((staged) => staged.id == peer.id))
        .toList();
    final stage = LayoutBuilder(
      builder: (context, constraints) {
        _tileAvatar = compactDesktop ? 36 : 56;
        _tileTop = compactDesktop ? 44 : 72;
        _rowHeight = compactDesktop ? 110 : 156;
        final width = _width = math.min(constraints.maxWidth, 520.0);
        final cols = _cols = compactDesktop
            ? 2
            : width >= 312
            ? 3
            : 2;
        final column = width / cols;
        final tile = math.min(column, 128.0);
        final textHeight = MediaQuery.textScalerOf(context).scale(14) * 1.4;
        final rowHeight = math.max(
          _rowHeight,
          _tileTop + 22 + textHeight + math.max(44, textHeight + 16),
        );
        final rows = stagePeers.isEmpty
            ? compactDesktop
                  ? 0
                  : 1
            : stagePeers
                      .map((peer) => _staged[peer.id]!.slot ~/ cols)
                      .reduce(math.max) +
                  1;
        // Three across make an arc: the outer two sit a little lower.
        double drop(int col) => cols == 3 && col != 1 ? 22 : 0;
        final sonarTop = compactDesktop
            ? 8.0
            : rows * rowHeight + (cols == 3 ? 22 : 0) + 8;
        final own = _own = Offset(
          compactDesktop ? width * .75 : width / 2,
          sonarTop + (size + 48) / 2,
        );
        _rects.clear();
        for (final peer in stagePeers) {
          final id = peer.id;
          final arrival = _staged[id]!;
          final row = compactDesktop ? 0 : arrival.slot ~/ cols;
          final col = compactDesktop ? 0 : arrival.slot % cols;
          _rects[id] = Rect.fromLTWH(
            col * column + (column - tile) / 2,
            row * rowHeight + drop(col),
            tile,
            rowHeight,
          );
        }
        for (final peer in peers) {
          _names[peer.id] = peer.name;
        }
        _names.removeWhere(
          (id, _) => !_rects.containsKey(id) && !_departed.containsKey(id),
        );
        final landed = _landedAt;
        final hit = _hitAt;
        final shaking = hit != null && _t - hit < _shake * 1.5
            ? _progress(_t - hit, 0, _shake * 1.5)
            : landed == null
            ? 1.0
            : _progress(_t - landed, 0, _shake);
        final shakeAmp = hit != null && _t - hit < _shake * 1.5 ? 10.0 : 5.0;
        final waver = _wavedBy == null
            ? null
            : peers.where((peer) => peer.id == _wavedBy).firstOrNull?.name;
        final height = compactDesktop
            ? sonarTop + math.max(rowHeight, size + 108)
            : sonarTop + size + 108;
        // Centred, the space under the status matches the space above your
        // picture, so the status stays tucked under the timer.
        final balance = widget.centered
            ? math.max(0.0, own.dy * 2 - height - _statusHeight)
            : 0.0;
        final lastHit = nearby.lastHit;
        final scene = SizedBox(
          width: width,
          height: height,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _StagePainter(
                      clock: _clock,
                      still: _still,
                      stage: this,
                      ownRadius: size / 2 + 9,
                      landedAt: landed,
                      color: colors.amber,
                      danger: colors.danger,
                      ink: colors.ink,
                      smoke: colors.muted,
                      charging: nearby.chargeTarget,
                      underFire: nearby.incoming > 0,
                    ),
                  ),
                ),
              ),
              for (final MapEntry(key: id, value: sunk) in _sinking.entries)
                Positioned(
                  key: ValueKey('nearby-sinking-$id'),
                  left: sunk.rect.left,
                  top: sunk.rect.top,
                  width: sunk.rect.width,
                  height: _tileTop + 40,
                  child: IgnorePointer(child: _sunk(sunk)),
                ),
              for (final peer in stagePeers)
                if (_rects[peer.id] case final rect?)
                  Positioned(
                    left: rect.left,
                    top: rect.top,
                    width: rect.width,
                    child: _tile(context, peer, _staged[peer.id]!),
                  ),
              Positioned(
                left: compactDesktop ? width / 2 : 0,
                right: 0,
                top: sonarTop,
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Transform.translate(
                    offset: Offset(
                      math.sin(shaking * math.pi * 6) *
                          shakeAmp *
                          (1 - shaking),
                      0,
                    ),
                    child: SonarButton(
                      size: size,
                      label: state.displayName,
                      imageBase64: state.profileAvatarBase64,
                      visibleUntil: nearby.visibleUntil,
                      window: NearbyController.defaultVisibleWindow,
                      enabled: nearby.listening,
                      hitAt: lastHit?.at,
                      hitLost: lastHit?.lost ?? Duration.zero,
                      rearmAt: nearby.rearmAt,
                      onHolding: state.chargeNearbyReveal,
                      onReveal: (origin) {
                        if (state.revealNearby()) {
                          SonarWarp.maybeOf(context)?.reveal(origin);
                        }
                      },
                      // A manual pulse is rings over the live app, never a
                      // frozen snapshot.
                      onPulse: (origin) {
                        if (state.pulseNearby()) {
                          SonarWarp.maybeOf(
                            context,
                          )?.reveal(origin, full: false);
                          _rippleOut();
                        }
                      },
                      onStop: nearby.shutdown,
                    ),
                  ),
                ),
              ),
              if (landed != null)
                Positioned.fromRect(
                  key: const ValueKey('nearby-wave-landed'),
                  rect: Rect.fromCircle(center: own, radius: size / 2),
                  child: Semantics(
                    liveRegion: true,
                    label: '${waver ?? 'Someone'} waved at you',
                    child: const SizedBox.expand(),
                  ),
                ),
            ],
          ),
        );
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            scene,
            widget.status,
            SizedBox(height: balance),
          ],
        );
      },
    );
    if (compactDesktop) {
      return SizedBox(
        height: widget.availableHeight,
        child: Column(
          children: [
            Center(child: stage),
            if (nearby.sendError != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Couldn’t send. Check Bluetooth or Wi-Fi and try again.',
                  key: const ValueKey('nearby-send-error'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: context.syblColors.danger,
                    fontSize: 12,
                  ),
                ),
              ),
            Expanded(
              child: ListView(
                key: const ValueKey('nearby-overflow-scroll'),
                padding: EdgeInsets.zero,
                children: [
                  for (final peer in overflow) _row(context, peer, fire: true),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Center(child: stage),
        if (nearby.sendError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 12),
            child: Text(
              'Couldn’t send. Check Bluetooth or Wi-Fi and try again.',
              textAlign: TextAlign.center,
              style: TextStyle(color: context.syblColors.danger, fontSize: 12),
            ),
          ),
        for (final peer in overflow) _row(context, peer),
      ],
    );
  }
}

class _StagePainter extends CustomPainter {
  _StagePainter({
    required this.clock,
    required this.still,
    required this.stage,
    required this.ownRadius,
    required this.landedAt,
    required this.color,
    required this.danger,
    required this.ink,
    required this.smoke,
    required this.charging,
    required this.underFire,
  }) : super(repaint: clock);

  final ValueNotifier<double> clock;
  final bool still;
  final _NearbyStageState stage;
  final double ownRadius;
  final double? landedAt;
  final Color color;
  final Color danger;
  final Color ink;
  final Color smoke;
  final String? charging;
  final bool underFire;

  @override
  void paint(Canvas canvas, Size size) {
    final t = clock.value;
    final own = stage._own ?? size.center(Offset.zero);
    if (!still) {
      for (final ring in stage._rings) {
        _ring(canvas, ring, t);
      }
    }
    for (final MapEntry(key: id, value: rect) in stage._rects.entries) {
      final arrival = stage._staged[id];
      if (arrival == null) continue;
      _door(canvas, rect, still ? 100.0 : t - arrival.at, id);
    }
    if (charging case final id?) {
      if (stage._rects[id] case final rect?) {
        SonarCombatPainter.brackets(
          canvas,
          stage._face(rect),
          stage._tileAvatar / 2 + 8,
          danger,
          still ? 0 : t,
          pairs: SonarCombat.brackets(stage.widget.nearby.chargeTaps),
        );
      }
    }
    if (underFire) {
      SonarCombatPainter.warning(canvas, own, ownRadius, danger, still ? 0 : t);
    }
    if (still) return;
    if (landedAt case final landed? when t - landed < _burst) {
      final r = (t - landed) / _burst;
      canvas.drawCircle(
        own,
        ownRadius + 16,
        Paint()
          ..color = color.withValues(alpha: (1 - r) * .45)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18),
      );
    }
    for (final missile in stage._missiles) {
      final from = stage._point(missile.from, top: missile.top);
      final to = stage._point(missile.to);
      final age = t - missile.at;
      if (age < 0) continue;
      if (missile.resolvedAt case final resolved?) {
        final point = missile.detonation!;
        final dt = t - resolved;
        if (dt < 0) continue;
        if (missile.lost && dt < 2.25) {
          final q = ((resolved - missile.at) / missile.flight).clamp(0.0, 1.0);
          final start = SonarCombatPainter.arc(from, to, missile.bow, q);
          SonarCombatPainter.rocket(
            canvas,
            from: start,
            to: point,
            bow: .4,
            progress: dt / 2.25,
            time: t,
            body: ink,
            flame: color,
            smoke: smoke,
          );
        } else {
          SonarCombatPainter.explosion(
            canvas,
            point,
            (t - missile.end) / _blast,
            color,
            danger,
            seed: missile.at.hashCode,
          );
        }
        continue;
      }
      if (age < missile.flight) {
        SonarCombatPainter.rocket(
          canvas,
          from: from,
          to: to,
          bow: missile.bow,
          progress: age / missile.flight,
          time: t,
          body: ink,
          flame: color,
          smoke: smoke,
          hostile: missile.to == null ? danger : null,
        );
      } else {
        SonarCombatPainter.explosion(
          canvas,
          to,
          (age - missile.flight) / _blast,
          color,
          danger,
          seed: missile.at.hashCode,
        );
      }
    }
  }

  void _ring(Canvas canvas, _Ring ring, double t) {
    final age = t - ring.at;
    final q = age / _ringLife;
    if (q < 0 || q >= 1) return;
    final start = ring.mine ? ownRadius : stage._tileAvatar / 2 + 2;
    final centre = stage._point(ring.from, top: ring.top);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = color.withValues(alpha: (1 - q) * .45);
    canvas.drawCircle(centre, start + age * _rippleSpeed, paint);
    if (!ring.mine) return;
    // A small echo bounces back off each person the front reaches.
    for (final rect in stage._rects.values) {
      final face = stage._face(rect);
      final echo = t - stage._reach(ring, face);
      if (echo < 0 || echo > _echo) continue;
      final e = echo / _echo;
      canvas.drawCircle(
        face,
        stage._tileAvatar / 2 + 2 + 18 * Curves.easeOut.transform(e),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2 * (1 - e) + .5
          ..color = color.withValues(alpha: .7 * (1 - e) * (1 - q)),
      );
    }
  }

  /// The brand mark come to life: an amber frame around a dark doorway, its
  /// dark panel swinging open on the left hinge so the person can step out,
  /// then shutting behind them before the whole door fades.
  void _door(Canvas canvas, Rect tile, double age, String id) {
    final face = stage._face(tile);
    final floor = Offset(face.dx, face.dy + stage._tileAvatar / 2 + 2);
    final frameIn = _NearbyStageState._progress(age, 0, _frameIn);
    // A faint glow stays where they came in.
    final glow = math.max(.25, 1 - _NearbyStageState._progress(age, 1.4, .6));
    canvas.drawOval(
      Rect.fromCenter(center: floor, width: 64, height: 12),
      Paint()
        ..color = color.withValues(alpha: .35 * glow * frameIn)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    final fade =
        frameIn * (1 - _NearbyStageState._progress(age, _fadeFrom, _fadeTime));
    if (fade == 0) return;
    final open =
        Curves.easeOutBack.transform(
          _NearbyStageState._progress(age, _openFrom, _openTime),
        ) *
        (1 -
            Curves.easeInCubic.transform(
              _NearbyStageState._progress(age, _shutFrom, _shutTime),
            ));
    final frame = Rect.fromLTWH(floor.dx - 20, floor.dy - 58, 40, 58);
    final dark = Color.lerp(Colors.black, color, .08)!;
    // Amber back panel and the dark doorway inside it.
    canvas
      ..drawRRect(
        RRect.fromRectAndRadius(frame.inflate(4), const Radius.circular(3)),
        Paint()..color = color.withValues(alpha: .9 * fade),
      )
      ..drawRect(frame, Paint()..color = dark.withValues(alpha: fade));
    // The panel swings toward you past its hinge; its far edge shortens in
    // perspective, as on the mark.
    final swing = open * math.pi * .72;
    final free = frame.left + frame.width * math.cos(swing);
    final lean = 7 * math.sin(swing);
    final panel = Path()
      ..moveTo(frame.left, frame.top)
      ..lineTo(free, frame.top + lean)
      ..lineTo(free, frame.bottom - lean)
      ..lineTo(frame.left, frame.bottom)
      ..close();
    canvas
      ..drawPath(panel, Paint()..color = dark.withValues(alpha: fade))
      ..drawPath(
        panel,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeJoin = StrokeJoin.round
          ..color = color.withValues(alpha: fade),
      )
      ..drawCircle(
        Offset(
          frame.left + (free - frame.left) * .82,
          frame.center.dy + lean * .1,
        ),
        2.4,
        Paint()..color = color.withValues(alpha: fade),
      );
  }

  @override
  bool shouldRepaint(_StagePainter old) => true;
}
