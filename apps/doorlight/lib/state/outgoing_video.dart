import 'dart:ui';

enum OutgoingVideoKind {
  off,
  camera,
  screen;

  static OutgoingVideoKind parse(Object? value) {
    final text = value?.toString().toLowerCase();
    return switch (text) {
      'camera' => OutgoingVideoKind.camera,
      'screen' => OutgoingVideoKind.screen,
      _ => OutgoingVideoKind.off,
    };
  }
}

class OutgoingVideoSource {
  final OutgoingVideoKind kind;
  final String uri;
  final int revision;

  /// Coordinate-space authority used by remote control. Platforms that do not
  /// publish a separate revision fall back to the media source revision.
  final int controlRevision;
  final int width;
  final int height;

  const OutgoingVideoSource({
    required this.kind,
    this.uri = '',
    this.revision = 0,
    this.controlRevision = -1,
    this.width = 0,
    this.height = 0,
  });

  const OutgoingVideoSource.off({int revision = 0})
    : this(kind: OutgoingVideoKind.off, revision: revision);

  bool get active => kind != OutgoingVideoKind.off;
  bool get isCamera => kind == OutgoingVideoKind.camera;
  bool get isScreen => kind == OutgoingVideoKind.screen;
  int get effectiveControlRevision =>
      controlRevision >= 0 ? controlRevision : revision;
  Size? get geometry => width > 0 && height > 0
      ? Size(width.toDouble(), height.toDouble())
      : null;

  OutgoingVideoSource copyWith({
    OutgoingVideoKind? kind,
    String? uri,
    int? revision,
    int? controlRevision,
    int? width,
    int? height,
  }) => OutgoingVideoSource(
    kind: kind ?? this.kind,
    uri: uri ?? this.uri,
    revision: revision ?? this.revision,
    controlRevision: controlRevision ?? this.controlRevision,
    width: width ?? this.width,
    height: height ?? this.height,
  );

  static OutgoingVideoSource fromMap(
    Map<dynamic, dynamic> map, {
    OutgoingVideoSource fallback = const OutgoingVideoSource.off(),
  }) {
    final hasKind =
        map.containsKey('outgoingVideoKind') || map.containsKey('sourceKind');
    final OutgoingVideoKind kind;
    if (hasKind) {
      kind = OutgoingVideoKind.parse(
        map['outgoingVideoKind'] ?? map['sourceKind'],
      );
    } else if (map.containsKey('cameraOn')) {
      kind = parseBool(map['cameraOn'])
          ? OutgoingVideoKind.camera
          : OutgoingVideoKind.off;
    } else {
      kind = fallback.kind;
    }
    final revision = parseInt(
      map['outgoingVideoRevision'] ??
          map['sourceRevision'] ??
          map['sourceEpoch'],
      fallback.revision,
    );
    var controlRevision = -1;
    if (kind == OutgoingVideoKind.screen) {
      if (map.containsKey('remoteControlSourceRevision')) {
        controlRevision = parseInt(map['remoteControlSourceRevision'], 0);
      } else if (fallback.isScreen) {
        controlRevision = fallback.controlRevision;
      }
    }
    return OutgoingVideoSource(
      kind: kind,
      uri: (map['outgoingVideoUri'] ?? map['sourceUri'] ?? fallback.uri)
          .toString(),
      revision: revision,
      controlRevision: controlRevision,
      width: parseInt(
        map['outgoingVideoWidth'] ?? map['sourceWidth'],
        fallback.width,
      ),
      height: parseInt(
        map['outgoingVideoHeight'] ?? map['sourceHeight'],
        fallback.height,
      ),
    );
  }
}

class ScreenSource {
  final String id;
  final String label;
  final bool primary;
  final Rect bounds;

  const ScreenSource({
    required this.id,
    required this.label,
    required this.primary,
    required this.bounds,
  });

  int get width => bounds.width.round();
  int get height => bounds.height.round();

  static ScreenSource? fromMap(Object? value) {
    if (value is! Map) return null;
    final id = value['id']?.toString() ?? '';
    final width = parseInt(value['width'], 0);
    final height = parseInt(value['height'], 0);
    if (id.isEmpty || width <= 0 || height <= 0) return null;
    final left = parseInt(value['left'], 0);
    final top = parseInt(value['top'], 0);
    return ScreenSource(
      id: id,
      label: value['label']?.toString() ?? 'Screen',
      primary: parseBool(value['primary']),
      bounds: Rect.fromLTWH(
        left.toDouble(),
        top.toDouble(),
        width.toDouble(),
        height.toDouble(),
      ),
    );
  }
}

bool parseBool(Object? value) =>
    value == true || value?.toString().toLowerCase() == 'true';

int parseInt(Object? value, [int fallback = 0]) => value is num
    ? value.toInt()
    : int.tryParse(value?.toString() ?? '') ?? fallback;
