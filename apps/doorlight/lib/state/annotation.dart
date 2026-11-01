import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Offset;
import 'outgoing_video.dart';

enum AnnotationTarget { mine, theirs }

/// A stroke uses normalized video-frame coordinates (0..1) so it aligns across
/// different surface sizes. Color and width travel with the stroke.
class Stroke {
  /// Sender-unique tag/counter used for merging and keyframe replacement.
  final String id;

  /// Local ownership determines clearMine scope; both sides render identically.
  final bool mine;
  final int color; // ARGB
  final double width;
  final List<Offset> points;
  bool done;

  Stroke({
    required this.id,
    required this.mine,
    required this.color,
    required this.width,
    List<Offset>? points,
    this.done = false,
  }) : points = points ?? [];
}

@immutable
class _SourceSession {
  final String owner;
  final int revision;

  const _SourceSession(this.owner, this.revision);

  @override
  bool operator ==(Object other) =>
      other is _SourceSession &&
      other.owner == owner &&
      other.revision == revision;

  @override
  int get hashCode => Object.hash(owner, revision);
}

class _KeyframeAssembly {
  _KeyframeAssembly(this.id, this.parts);

  final String id;
  final int parts;
  final Map<int, List<Stroke>> pages = <int, List<Stroke>>{};
  int pointCount = 0;
  int strokeCount = 0;
}

/// Call-scoped drawing state and protocol. Events use the in-call SIP MESSAGE
/// channel over the established ICE/TLS transport and are never saved to chat
/// history. Native `callMessage` events enter through [applyInbound]; [reset]
/// discards the in-memory state when the call ends.
///
/// Stroke mutations signal [repaint] to avoid rebuilding the call UI on every
/// pointer movement. [notifyListeners] reports structural toolbar/overlay changes.
class AnnotationController extends ChangeNotifier {
  /// Send a JSON-encodable draw event. Set by [AppState] to the in-call channel (gated on a connected call there,
  /// so events sent before CURRENT — which the daemon would queue/drop — are simply not emitted).
  void Function(Map<String, dynamic> json)? sender;

  /// Bumped on every stroke mutation (local or remote) so the [CustomPainter] repaints without rebuilding the
  /// in-call tree. The painter listens to `Listenable.merge([this, repaint])`.
  final ValueNotifier<int> repaint = ValueNotifier(0);

  /// The annotation palette preserves the warm-coral product style.
  /// Colour is per-stroke and travels on the wire, so the peer renders each stroke in the drawer's colour.
  static const List<int> palette = [
    0xFFF08A6C,
    0xFFF2B775,
    0xFF7FB069,
    0xFFEFE6DC,
  ];
  static const double strokeWidth = 3.5;

  /// Keep the overlay calm: bound retained strokes per side (drop the oldest). 80 short marks is generous for
  /// "point here", never unbounded. (The per-MESSAGE wire bound is [_kfByteBudget] — the in-call SIP MESSAGE
  /// packet is capped at PJSIP_MAX_PKT_LEN = 8000 bytes by the daemon build, headers included.)
  static const int _maxStrokes = 80;

  /// Drop a new point nearer than this (normalized) to the last — coalesces a held/slow finger so a stroke's
  /// point count tracks its PATH LENGTH, not its duration (a stationary finger adds nothing). Bounds wire + memory.
  static const double _minDist = 0.004;

  /// Hard per-stroke backstop so a single long mark can't grow unbounded (with [_minDist] this is rarely
  /// reached), sized so ONE stroke always fits ONE keyframe message: 300 pts ≈ 5.4 KB encoded, inside
  /// [_kfByteBudget] — the real channel cap is an 8000-byte SIP packet, not the ~64 KB once assumed.
  static const int _maxStrokePoints = 300;

  /// Keyframe payload budget in ESTIMATED ENCODED BYTES. The daemon caps a whole in-call SIP MESSAGE at
  /// PJSIP_MAX_PKT_LEN = 8000 bytes INCLUDING SIP headers (~1-1.5 KB), so keep the JSON body ≤ ~6 KB or the
  /// transport silently drops the resync.
  static const int _kfByteBudget = 6000;

  bool enabled = false; // draw mode on → the overlay captures pointers
  int color = palette.first;

  Stroke? _active; // the local stroke being drawn
  _SourceSession? _activeSource;
  int _strokeCounter = 0;
  String _tag =
      'me'; // short, per-device id prefix so stroke ids don't collide across the two peers
  String _localOwner = 'me';
  String _peerOwner = 'peer';
  _SourceSession? _ownedSource;
  _SourceSession? _peerSource;
  OutgoingVideoKind _ownedKind = OutgoingVideoKind.off;
  OutgoingVideoKind _peerKind = OutgoingVideoKind.off;
  OutgoingVideoKind _peerSourceKind = OutgoingVideoKind.off;
  String _peerPlatform = '';
  int _highestPeerRevision = -1;
  AnnotationTarget? target;

  final Map<_SourceSession, Map<String, Stroke>> _mineBySource = {};
  final Map<_SourceSession, Map<String, Stroke>> _peerBySource = {};
  final Map<_SourceSession, LinkedHashSet<int>> _seenPointSeqs = {};
  static const int _maxSeenPointSeqs = 512;
  static const int _maxKeyframeParts = _maxStrokes;
  static const int _maxKeyframePoints = _maxStrokes * _maxStrokePoints;
  final Map<_SourceSession, _KeyframeAssembly> _keyframeAssemblies = {};
  int _keyframeSnapshotCounter = 0;

  _SourceSession? get _targetSource => switch (target) {
    AnnotationTarget.mine => _ownedSource,
    AnnotationTarget.theirs => _peerSource,
    null => null,
  };
  bool get canTargetMine => _ownedSource != null;
  bool get canTargetTheirs => _peerKind != OutgoingVideoKind.off;

  /// The peer-announced media coordinate-space revision. Remote control reuses
  /// this M8 source handshake so its request is bound to the exact screen the
  /// user can see; no parallel source-discovery protocol is introduced.
  int? get peerSourceRevision => _peerSource?.revision;
  String? get peerSourceOwner => _peerSource?.owner;
  OutgoingVideoKind get peerSourceKind => _peerSourceKind;
  String get peerPlatform => _peerPlatform;
  bool get available => canTargetMine || canTargetTheirs;
  bool get ready => _targetSource != null;
  Iterable<Stroke> get mineStrokes => _targetSource == null
      ? const <Stroke>[]
      : (_mineBySource[_targetSource]?.values ?? const <Stroke>[]);
  Iterable<Stroke> get peerStrokes => _targetSource == null
      ? const <Stroke>[]
      : (_peerBySource[_targetSource]?.values ?? const <Stroke>[]);

  /// Immutable projection for Android's system-level annotation overlay.
  ///
  /// This deliberately addresses the locally owned *screen* source rather
  /// than the currently selected Flutter tile. It therefore keeps the same
  /// marks visible after Doorlight is backgrounded without accidentally painting
  /// camera annotations over unrelated Android applications.
  Map<String, Object?> ownedScreenOverlaySnapshot(String callId) {
    final source = _ownedSource;
    if (source == null ||
        _ownedKind != OutgoingVideoKind.screen ||
        callId.isEmpty) {
      return const <String, Object?>{'active': false};
    }
    final strokes = <Stroke>[
      ...?_mineBySource[source]?.values,
      ...?_peerBySource[source]?.values,
    ];
    return <String, Object?>{
      'active': true,
      'callId': callId,
      'sourceRevision': source.revision,
      'strokes': <Object?>[
        for (final stroke in strokes)
          <String, Object?>{
            'color': stroke.color,
            'width': stroke.width,
            'points': <Object?>[
              for (final point in stroke.points) <double>[point.dx, point.dy],
            ],
          },
      ],
    };
  }

  Map<String, Stroke> _mineFor(_SourceSession source) =>
      _mineBySource.putIfAbsent(source, () => <String, Stroke>{});
  Map<String, Stroke> _peerFor(_SourceSession source) =>
      _peerBySource.putIfAbsent(source, () => <String, Stroke>{});

  /// Reconcile independently-owned local and remote media sessions. Camera and
  /// screen are equally drawable; source revision, not a process-global flag,
  /// invalidates stale packets. The selected annotation target also drives the
  /// large video tile, so drawing and presentation cannot disagree.
  void syncSources({
    required String localOwner,
    required String peerOwner,
    required int localRevision,
    required OutgoingVideoKind localKind,
    required OutgoingVideoKind peerKind,
    bool peerSourceChanged = false,
  }) {
    if (localOwner.isNotEmpty) _localOwner = localOwner;
    if (peerOwner.isNotEmpty && peerOwner != _peerOwner) {
      final retiredPeer = _peerSource;
      if (retiredPeer != null) {
        _mineBySource.remove(retiredPeer);
        _peerBySource.remove(retiredPeer);
      }
      _peerOwner = peerOwner;
      _peerSource = null;
      _peerSourceKind = OutgoingVideoKind.off;
      _peerPlatform = '';
      _highestPeerRevision = -1;
      _seenPointSeqs.clear();
      _keyframeAssemblies.clear();
    }

    final previousOwned = _ownedSource;
    final previousTarget = _targetSource;
    final nextOwned = localKind != OutgoingVideoKind.off
        ? _SourceSession(_localOwner, localRevision)
        : null;
    if (previousOwned != nextOwned && previousOwned != null) {
      _mineBySource.remove(previousOwned);
      _peerBySource.remove(previousOwned);
      _seenPointSeqs.remove(previousOwned);
      _keyframeAssemblies.remove(previousOwned);
    }
    _ownedSource = nextOwned;
    _ownedKind = localKind;

    if (peerSourceChanged || peerKind == OutgoingVideoKind.off) {
      final previousPeer = _peerSource;
      if (previousPeer != null) {
        _mineBySource.remove(previousPeer);
        _peerBySource.remove(previousPeer);
        _seenPointSeqs.remove(previousPeer);
        _keyframeAssemblies.remove(previousPeer);
      }
      _peerSource = null;
      _peerSourceKind = OutgoingVideoKind.off;
      _peerPlatform = '';
    }
    _peerKind = peerKind;

    if (target == null ||
        (target == AnnotationTarget.mine && !canTargetMine) ||
        (target == AnnotationTarget.theirs && !canTargetTheirs)) {
      target = canTargetTheirs
          ? AnnotationTarget.theirs
          : (canTargetMine ? AnnotationTarget.mine : null);
    }
    if (previousTarget != _targetSource) {
      // A media replacement retires the old coordinate space immediately.
      // Do not flush a final packet for a source that no longer exists.
      _stopDrawing(disable: true, flush: false);
    }

    if (previousOwned != nextOwned && nextOwned != null) {
      _sendSource();
    }
    if (_peerDiscoveryNeeded) {
      _schedulePeerDiscovery();
    } else {
      _stopPeerDiscovery();
    }
    notifyListeners();
  }

  // Throttled send of the active stroke's new points (~25 Hz). gate: coalesce pointer samples, never one msg/move.
  Timer? _flush;
  int _sent = 0; // points of [_active] already sent
  int _seq =
      0; // monotonic per-message sequence (idempotent append on the peer)
  Timer?
  _keyframe; // periodic full-state resend → re-syncs a peer whose UI lifecycle dropped events

  Timer? _sourceDiscovery;
  int _sourceDiscoveryAttempts = 0;
  static const int _fastSourceDiscoveryAttempts = 8;
  static const Duration _fastSourceDiscoveryInterval = Duration(
    milliseconds: 750,
  );
  static const Duration _slowSourceDiscoveryInterval = Duration(seconds: 5);

  /// Tag stroke ids with our identity so a keyframe merge / replace never confuses the two sides' strokes.
  void bind(String jamiId) {
    if (jamiId.isNotEmpty) _localOwner = jamiId;
    _tag = jamiId.length >= 6
        ? jamiId.substring(0, 6)
        : (jamiId.isEmpty ? 'me' : jamiId);
  }

  void setEnabled(bool on) {
    if (enabled == on) return;
    if (on && _targetSource == null) {
      _schedulePeerDiscovery();
      return;
    }
    enabled = on;
    if (on) {
      if (_ownedSource != null) _sendSource();
      _keyframe ??= Timer.periodic(const Duration(seconds: 3), (_) {
        final source = _targetSource;
        if (source != null && (_mineBySource[source]?.isNotEmpty ?? false)) {
          _sendKeyframe(source);
        }
      });
    } else {
      _stopDrawing();
      _keyframe
          ?.cancel(); // stop the periodic resync when we leave draw mode (marks persist; a peer 'req' still replies)
      _keyframe = null;
    }
    notifyListeners();
  }

  void setTarget(AnnotationTarget next) {
    if (next == target ||
        (next == AnnotationTarget.mine && !canTargetMine) ||
        (next == AnnotationTarget.theirs && !canTargetTheirs)) {
      return;
    }
    _stopDrawing(disable: true);
    target = next;
    if (next == AnnotationTarget.theirs && _peerSource == null) {
      _schedulePeerDiscovery();
    }
    repaint.value++;
    notifyListeners();
  }

  void setColor(int c) {
    color = c;
    notifyListeners();
  }

  // ---- local drawing (coords already normalized 0..1 by the overlay) ----

  void begin(Offset n) {
    final source = _targetSource;
    if (source == null) return;
    final s = Stroke(
      id: '$_tag-${_strokeCounter++}',
      mine: true,
      color: color,
      width: strokeWidth,
      points: [n],
    );
    _active = s;
    _activeSource = source;
    _sent = 0;
    _put(_mineFor(source), s);
    repaint.value++;
    // Send the stroke header + first point now so the peer sees the mark begin within ~RTT; the timer streams the rest.
    _flushActive();
    _flush ??= Timer.periodic(
      const Duration(milliseconds: 40),
      (_) => _flushActive(),
    );
  }

  void extend(Offset n) {
    final a = _active;
    if (a == null || a.points.length >= _maxStrokePoints) return;
    final last = a.points.last;
    if ((n.dx - last.dx).abs() < _minDist &&
        (n.dy - last.dy).abs() < _minDist) {
      return; // coalesce near-duplicates
    }
    a.points.add(n);
    repaint.value++;
  }

  void end() {
    final a = _active;
    if (a == null) return;
    a.done = true;
    _flushActive(last: true); // flush the tail + mark complete on the peer
    _active = null;
    _activeSource = null;
    _flush?.cancel();
    _flush = null;
    repaint.value++;
  }

  /// Clear only OUR marks (and tell the peer to drop them). Each side owns its own annotations — clearing yours
  /// never wipes theirs, which keeps a two-way "point here" exchange calm and predictable.
  void clearMine() {
    final source = _targetSource;
    if (source == null) return;
    _mineBySource[source]?.clear();
    _stopDrawing();
    _sendFor(source, {'v': 1, 't': 'clear'});
    repaint.value++;
  }

  // ---- inbound (one decoded 'callMessage' payload from the peer) ----

  final _inboundClock = Stopwatch()..start();
  int? _lastKeyframeReplyMs;
  double _keyframeReplyTokens = 2;

  void applyInbound(String payload) {
    if (payload.length > 65536 || utf8.encode(payload).length > 65536) return;
    try {
      final d = jsonDecode(payload);
      if (d is! Map) return;
      final m = Map<String, dynamic>.from(d);
      if (m['v'] != 1) return;
      final type = m['t'];
      if (type == 'src') {
        final announced = _messageSession(m);
        final announcedKind = OutgoingVideoKind.parse(m['sourceKind']);
        final announcedPlatform = switch (m['platform']) {
          'android' => 'android',
          'windows' => 'windows',
          _ => '',
        };
        if (announced == null ||
            announced.owner != _peerOwner ||
            announcedKind == OutgoingVideoKind.off ||
            (announcedKind == OutgoingVideoKind.screen &&
                announced.revision == 0)) {
          return;
        }
        final previous = _peerSource;
        if (announced.revision < _highestPeerRevision ||
            (announced.revision == _highestPeerRevision &&
                announced != previous)) {
          return;
        }
        if (announced == previous) {
          if (_peerPlatform.isEmpty && announcedPlatform.isNotEmpty) {
            _peerPlatform = announcedPlatform;
            notifyListeners();
          }
          return;
        }
        if (previous != announced && previous != null) {
          _mineBySource.remove(previous);
          _peerBySource.remove(previous);
          _seenPointSeqs.remove(previous);
          _keyframeAssemblies.remove(previous);
        }
        _peerSource = announced;
        _peerSourceKind = announcedKind;
        _peerPlatform = announcedPlatform;
        _stopPeerDiscovery();
        _peerKind = announcedKind;
        _highestPeerRevision = announced.revision;
        target ??= AnnotationTarget.theirs;
        if (target == AnnotationTarget.theirs) {
          _stopDrawing(disable: true, flush: false);
        }
        // The discovery request used revision 0 because the peer's revision
        // was not known yet. Now request the exact board once so marks made
        // before this controller attached are recovered even when the owner
        // has already left draw mode and stopped periodic keyframes.
        _sendRequestFor(announced);
        repaint.value++;
        notifyListeners();
        return;
      }
      if (type == 'req') {
        final now = _inboundClock.elapsedMilliseconds;
        if (_lastKeyframeReplyMs != null) {
          _keyframeReplyTokens =
              (_keyframeReplyTokens +
                      (now - _lastKeyframeReplyMs!).clamp(0, 2000) / 1000)
                  .clamp(0, 2);
        }
        _lastKeyframeReplyMs = now;
        // Discovery asks for the source, then its exact revision. Permit that
        // pair while bounding repeated full-board serialization.
        if (_keyframeReplyTokens < 1) return;
        _keyframeReplyTokens--;
        final requestedOwner = m['sourceOwner'] is String
            ? m['sourceOwner'] as String
            : '';
        if (_ownedSource != null &&
            (requestedOwner.isEmpty || requestedOwner == _ownedSource!.owner)) {
          _sendSource();
        }
        final requested = _messageSession(m);
        if (requested != null &&
            (requested == _ownedSource || requested == _peerSource)) {
          _sendKeyframe(requested, replace: true);
        }
        return;
      }
      final session = _messageSession(m);
      if (session == null ||
          (session != _ownedSource && session != _peerSource)) {
        return;
      }
      final peerStrokes = _peerFor(session);

      switch (type) {
        case 'pt':
          final sid = m['sid'] as String? ?? '';
          if (sid.isEmpty || sid.length > 128) return;
          final seq = _nonNegativeInt(m['seq']);
          if (seq == null ||
              (_seenPointSeqs[session]?.contains(seq) ?? false)) {
            return;
          }
          final rawPoints = m['p'];
          if (rawPoints is! List) return;
          final points = _decodePoints(rawPoints);
          final existing = peerStrokes[sid];
          if (existing == null && points.isEmpty ||
              rawPoints.isNotEmpty && points.isEmpty) {
            return;
          }
          final s =
              existing ??
              _put(
                peerStrokes,
                Stroke(
                  id: sid,
                  mine: false,
                  color: _asColor(m['color']),
                  width: _asWidth(m['w']),
                ),
              );
          final room = _maxStrokePoints - s.points.length;
          if (room > 0) s.points.addAll(points.take(room));
          if (m['last'] == true) s.done = true;
          _rememberPointSeq(session, seq);
          repaint.value++;
          break;
        case 'clear':
          peerStrokes.clear();
          repaint.value++;
          break;
        case 'kf':
          final rawStrokes = m['s'];
          if (rawStrokes is! List) return;
          final page = _parseKeyframePage(rawStrokes);
          if (page == null) return;
          final mode = m['mode'];
          if (mode == 'merge') {
            for (final stroke in page) {
              _put(peerStrokes, stroke);
            }
            repaint.value++;
            break;
          }
          if (mode == 'replace') {
            _applyReplacementKeyframePage(session, m, page, peerStrokes);
            break;
          }
          // Rolling compatibility: a v1 peer without an explicit mode sent one
          // complete-or-truncated replacement keyframe.
          final replacement = <String, Stroke>{
            for (final stroke in page) stroke.id: stroke,
          };
          peerStrokes
            ..clear()
            ..addAll(replacement);
          repaint.value++;
          break;
      }
    } catch (_) {
      // Malformed remote payload — ignore (a draw event is never worth crashing the event pump).
    }
  }

  List<Stroke>? _parseKeyframePage(List<dynamic> rawStrokes) {
    if (rawStrokes.length > _maxStrokes) return null;
    final parsed = <Stroke>[];
    var pointCount = 0;
    for (final rawStroke in rawStrokes) {
      if (rawStroke is! Map) return null;
      final stroke = Map<String, dynamic>.from(rawStroke);
      final sid = stroke['sid'];
      final rawPoints = stroke['p'];
      if (sid is! String ||
          sid.isEmpty ||
          sid.length > 128 ||
          rawPoints is! List ||
          rawPoints.isEmpty) {
        return null;
      }
      final points = _decodePoints(rawPoints);
      if (points.length != rawPoints.length) return null;
      pointCount += points.length;
      if (pointCount > _maxKeyframePoints) return null;
      parsed.add(
        Stroke(
          id: sid,
          mine: false,
          color: _asColor(stroke['color']),
          width: _asWidth(stroke['w']),
          points: points,
          done: true,
        ),
      );
    }
    return parsed;
  }

  void _applyReplacementKeyframePage(
    _SourceSession session,
    Map<String, dynamic> message,
    List<Stroke> page,
    Map<String, Stroke> peerStrokes,
  ) {
    final snapshotId = message['snapshot'];
    final part = _nonNegativeInt(message['part']);
    final parts = _nonNegativeInt(message['parts']);
    if (snapshotId is! String ||
        snapshotId.isEmpty ||
        snapshotId.length > 128 ||
        part == null ||
        parts == null ||
        parts < 1 ||
        parts > _maxKeyframeParts ||
        part >= parts) {
      return;
    }
    var assembly = _keyframeAssemblies[session];
    if (assembly == null ||
        assembly.id != snapshotId ||
        assembly.parts != parts) {
      assembly = _KeyframeAssembly(snapshotId, parts);
      _keyframeAssemblies[session] = assembly;
    }
    if (assembly.pages.containsKey(part)) return;
    final nextStrokeCount = assembly.strokeCount + page.length;
    final nextPointCount =
        assembly.pointCount +
        page.fold<int>(0, (total, stroke) => total + stroke.points.length);
    if (nextStrokeCount > _maxStrokes || nextPointCount > _maxKeyframePoints) {
      _keyframeAssemblies.remove(session);
      return;
    }
    assembly.pages[part] = page;
    assembly.strokeCount = nextStrokeCount;
    assembly.pointCount = nextPointCount;
    if (assembly.pages.length != parts) return;

    final replacement = <String, Stroke>{};
    for (var index = 0; index < parts; index++) {
      final strokes = assembly.pages[index];
      if (strokes == null) {
        _keyframeAssemblies.remove(session);
        return;
      }
      for (final stroke in strokes) {
        replacement[stroke.id] = stroke;
      }
    }
    _keyframeAssemblies.remove(session);
    peerStrokes
      ..clear()
      ..addAll(replacement);
    repaint.value++;
  }

  _SourceSession? _messageSession(Map<String, dynamic> message) {
    final revision = _nonNegativeInt(message['sourceRevision']);
    if (revision == null) return null;
    final rawOwner = message['sourceOwner'];
    final owner = rawOwner is String && rawOwner.isNotEmpty ? rawOwner : '';
    if (owner.isEmpty) return null;
    return _SourceSession(owner, revision);
  }

  int? _nonNegativeInt(dynamic value) {
    if (value is! num ||
        !value.isFinite ||
        value.toInt() < 0 ||
        value.toDouble() != value.toInt().toDouble()) {
      return null;
    }
    return value.toInt();
  }

  void _rememberPointSeq(_SourceSession source, int seq) {
    final seen = _seenPointSeqs.putIfAbsent(source, LinkedHashSet<int>.new);
    seen.add(seq);
    if (seen.length > _maxSeenPointSeqs) seen.remove(seen.first);
  }

  List<Offset> _decodePoints(dynamic raw) {
    if (raw is! List) return const [];
    final points = <Offset>[];
    for (final p in raw) {
      if (points.length >= _maxStrokePoints) break;
      if (p is List && p.length == 2 && p[0] is num && p[1] is num) {
        final x = (p[0] as num).toDouble(), y = (p[1] as num).toDouble();
        if (!x.isFinite || !y.isFinite || x < 0 || x > 1 || y < 0 || y > 1) {
          continue;
        }
        points.add(Offset(x, y));
      }
    }
    return points;
  }

  int _asColor(dynamic v) =>
      v is num && v.isFinite ? v.toInt() & 0xFFFFFFFF : color;
  double _asWidth(dynamic v) {
    if (v is! num || !v.isFinite) return strokeWidth;
    return v.toDouble().clamp(1.0, 12.0);
  }

  /// Drop all annotation state — call this when the call ends (nothing is ever persisted).
  void reset() {
    _lastKeyframeReplyMs = null;
    _keyframeReplyTokens = 2;
    _stopPeerDiscovery();
    _ownedSource = null;
    _peerSource = null;
    _ownedKind = OutgoingVideoKind.off;
    _peerKind = OutgoingVideoKind.off;
    _peerSourceKind = OutgoingVideoKind.off;
    _peerPlatform = '';
    _highestPeerRevision = -1;
    target = null;
    _mineBySource.clear();
    _peerBySource.clear();
    _seenPointSeqs.clear();
    _keyframeAssemblies.clear();
    _stopDrawing(disable: true, flush: false);
    _seq = 0;
    _strokeCounter = 0;
    _keyframeSnapshotCounter = 0;
    repaint.value++;
    notifyListeners();
  }

  void _stopDrawing({bool disable = false, bool flush = true}) {
    if (flush && _active != null) _flushActive(last: true);
    _active = null;
    _activeSource = null;
    if (disable) enabled = false;
    _sent = 0;
    _flush?.cancel();
    _flush = null;
    if (disable) {
      _keyframe?.cancel();
      _keyframe = null;
    }
  }

  // ---- internals ----

  Stroke _put(Map<String, Stroke> into, Stroke s) {
    into[s.id] = s;
    if (into.length > _maxStrokes) {
      into.remove(
        into.keys.first,
      ); // bound memory + keyframe size (drop oldest)
    }
    return s;
  }

  void _flushActive({bool last = false}) {
    final a = _active;
    final source = _activeSource;
    if (a == null || source == null) return;
    if (a.points.length <= _sent && !last) return; // nothing new this tick
    final fresh = a.points.sublist(_sent);
    _sent = a.points.length;
    _sendFor(source, {
      'v': 1,
      't': 'pt',
      'sid': a.id,
      'color': a.color,
      'w': a.width,
      'seq': _seq++,
      'last': last,
      'p': [
        for (final o in fresh) [_r(o.dx), _r(o.dy)],
      ],
    });
  }

  void _sendKeyframe(_SourceSession source, {bool replace = false}) {
    final encoded = <Map<String, dynamic>>[
      for (final stroke in _mineBySource[source]?.values ?? const <Stroke>[])
        {
          'sid': stroke.id,
          'color': stroke.color,
          'w': stroke.width,
          'p': [
            for (final point in stroke.points) [_r(point.dx), _r(point.dy)],
          ],
        },
    ];
    if (!replace) {
      // Periodic recovery is additive. Replacing the peer board with a
      // size-limited recent subset made still-current strokes disappear.
      final page = <Map<String, dynamic>>[];
      for (final stroke in encoded.reversed) {
        final candidate = <Map<String, dynamic>>[stroke, ...page];
        if (page.isNotEmpty &&
            _keyframeWireBytes(source, {
                  'v': 1,
                  't': 'kf',
                  'mode': 'merge',
                  's': candidate,
                }) >
                _kfByteBudget) {
          break;
        }
        page
          ..clear()
          ..addAll(candidate);
      }
      _sendFor(source, {'v': 1, 't': 'kf', 'mode': 'merge', 's': page});
      return;
    }

    // Explicit resync commits as replacement only after every bounded page
    // arrives. Old peers end on the newest page, matching their previous
    // truncated-snapshot behavior; updated peers recover the complete board.
    final snapshot = '$_tag-${source.revision}-${_keyframeSnapshotCounter++}';
    final pages = <List<Map<String, dynamic>>>[];
    var page = <Map<String, dynamic>>[];
    for (final stroke in encoded) {
      final candidate = <Map<String, dynamic>>[...page, stroke];
      if (page.isNotEmpty &&
          _keyframeWireBytes(source, {
                'v': 1,
                't': 'kf',
                'mode': 'replace',
                'snapshot': snapshot,
                'part': _maxKeyframeParts - 1,
                'parts': _maxKeyframeParts,
                's': candidate,
              }) >
              _kfByteBudget) {
        pages.add(page);
        page = <Map<String, dynamic>>[stroke];
      } else {
        page = candidate;
      }
    }
    pages.add(page);
    for (var index = 0; index < pages.length; index++) {
      _sendFor(source, {
        'v': 1,
        't': 'kf',
        'mode': 'replace',
        'snapshot': snapshot,
        'part': index,
        'parts': pages.length,
        's': pages[index],
      });
    }
  }

  int _keyframeWireBytes(_SourceSession source, Map<String, dynamic> message) =>
      utf8
          .encode(
            jsonEncode({
              ...message,
              'sourceOwner': source.owner,
              'sourceRevision': source.revision,
            }),
          )
          .length;

  void _sendSource() {
    final owned = _ownedSource;
    if (owned == null) return;
    final platform = switch (defaultTargetPlatform) {
      TargetPlatform.android => 'android',
      TargetPlatform.windows => 'windows',
      _ => '',
    };
    _sendFor(owned, {
      'v': 1,
      't': 'src',
      'sourceKind': _ownedKind.name,
      'platform': platform,
    });
  }

  void _sendRequest() {
    if (!_peerDiscoveryNeeded) return;
    _sendRequestFor(_peerSource ?? _SourceSession(_peerOwner, 0));
  }

  /// Re-arm discovery when the decoder proves that peer video is producing
  /// frames. The first media offer can precede CURRENT, in which
  /// case its best-effort request is correctly dropped by the call transport.
  void ensurePeerSourceDiscovery() {
    if (_peerKind == OutgoingVideoKind.off || _peerSource != null) return;
    _schedulePeerDiscovery(retryUnknownKind: true);
  }

  bool get _peerDiscoveryNeeded => _peerSource == null && canTargetTheirs;

  void _schedulePeerDiscovery({bool retryUnknownKind = false}) {
    if (!_peerDiscoveryNeeded || _sourceDiscovery != null) {
      return;
    }
    _sourceDiscoveryAttempts = 1;
    _sendRequest();
    // libjami does not transmit the remote SOURCE through SDP. Retry for every
    // active peer video until the authenticated source announcement identifies
    // the exact camera or screen session.
    if (!retryUnknownKind && _peerKind != OutgoingVideoKind.screen) {
      _sourceDiscoveryAttempts = 0;
      return;
    }
    _armPeerDiscoveryRetry();
  }

  void _armPeerDiscoveryRetry() {
    if (!_peerDiscoveryNeeded) {
      _stopPeerDiscovery();
      return;
    }
    final delay = _sourceDiscoveryAttempts < _fastSourceDiscoveryAttempts
        ? _fastSourceDiscoveryInterval
        : _slowSourceDiscoveryInterval;
    _sourceDiscovery = Timer(delay, () {
      _sourceDiscovery = null;
      if (!_peerDiscoveryNeeded || _peerSource != null) {
        _stopPeerDiscovery();
        return;
      }
      _sourceDiscoveryAttempts++;
      _sendRequest();
      _armPeerDiscoveryRetry();
    });
  }

  void _stopPeerDiscovery() {
    _sourceDiscovery?.cancel();
    _sourceDiscovery = null;
    _sourceDiscoveryAttempts = 0;
  }

  void _sendRequestFor(_SourceSession source) =>
      _sendFor(source, {'v': 1, 't': 'req'});

  void _sendFor(_SourceSession session, Map<String, dynamic> json) {
    json['sourceOwner'] = session.owner;
    json['sourceRevision'] = session.revision;
    sender?.call(json);
  }

  // Round normalized coords to ~1e-4 (sub-pixel at any sane resolution) to shrink the payload.
  double _r(double v) => (v * 10000).roundToDouble() / 10000;

  @override
  void dispose() {
    _flush?.cancel();
    _keyframe?.cancel();
    _sourceDiscovery?.cancel();
    repaint.dispose();
    super.dispose();
  }
}
