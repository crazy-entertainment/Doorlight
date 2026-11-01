import 'dart:convert';

import 'conversation_scope.dart';
import 'dm_topics.dart';
import 'gif_validation.dart';

abstract final class RichContentWire {
  static const stickerMime = 'application/x-sybl-sticker+json';
  static const mediaField = 'sybl-media-v1';
  static const roomField = 'sybl-room-v1';
  static const operationField = 'sybl-op-v1';
  static const maximumBytes = 1024;
  static final _operation = RegExp(r'^[0-9a-f]{32}$');
  static final _room = RegExp(r'^[a-z0-9][a-z0-9-]{0,31}$');
  static final _asset = RegExp(r'^[a-z0-9]+(?:[.-][a-z0-9]+)*$');

  static bool validOperation(Object? value) =>
      value is String && _operation.hasMatch(value);
  static bool validRoom(Object? value) =>
      value is String && _room.hasMatch(value);
  static bool validAsset(Object? value) =>
      value is String && value.length <= 128 && _asset.hasMatch(value);

  static Map<String, dynamic>? object(Object? value) {
    if (value is! String ||
        value.isEmpty ||
        value.length > maximumBytes ||
        utf8.encode(value).length > maximumBytes) {
      return null;
    }
    try {
      final decoded = jsonDecode(value);
      return decoded is Map<String, dynamic> &&
              decoded['v'] is int &&
              decoded['v'] == 1
          ? decoded
          : null;
    } on FormatException {
      return null;
    }
  }
}

enum StickerPresentation { inline, hologram }

final class StickerContent {
  const StickerContent(this.assetId, this.presentation);
  final String assetId;
  final StickerPresentation presentation;

  String encode() => jsonEncode({
    'v': 1,
    'assetId': assetId,
    'presentation': presentation.name,
  });

  static StickerContent? parse(Object? body) {
    final value = RichContentWire.object(body);
    if (value == null ||
        value.length != 3 ||
        !RichContentWire.validAsset(value['assetId'])) {
      return null;
    }
    final presentation = switch (value['presentation']) {
      'inline' => StickerPresentation.inline,
      'hologram' => StickerPresentation.hologram,
      _ => null,
    };
    return presentation == null
        ? null
        : StickerContent(value['assetId'] as String, presentation);
  }
}

sealed class FileMediaContent {
  const FileMediaContent();
  Map<String, Object> toMap();
  String encode() => jsonEncode(toMap());

  static FileMediaContent? parse(Object? source) {
    final value = RichContentWire.object(source);
    if (value == null) return null;
    if (value['kind'] == 'gif') {
      final width = value['width'];
      final height = value['height'];
      final frames = value['frames'];
      final cycle = value['cycleMs'];
      if (value.length != 6 ||
          width is! int ||
          height is! int ||
          frames is! int ||
          cycle is! int ||
          width < 1 ||
          width > 512 ||
          height < 1 ||
          height > 512 ||
          width > height * 4 ||
          height > width * 4 ||
          frames < 1 ||
          frames > 120 ||
          cycle < frames * 20 ||
          cycle > 10000 ||
          width * height * frames > ValidatedGif.maximumCanvasWork) {
        return null;
      }
      return GifMediaContent(width, height, frames, cycle);
    }
    if (value['kind'] == 'voice') {
      final duration = value['durationMs'];
      if (value.length != 5 ||
          value['codec'] != 'aac-lc' ||
          value['container'] != 'm4a' ||
          duration is! int ||
          duration < 300 ||
          duration > 120000) {
        return null;
      }
      return VoiceMediaContent(duration);
    }
    return null;
  }
}

final class GifMediaContent extends FileMediaContent {
  const GifMediaContent(
    this.width,
    this.height,
    this.frames,
    this.cycleMilliseconds,
  );
  final int width;
  final int height;
  final int frames;
  final int cycleMilliseconds;
  @override
  Map<String, Object> toMap() => {
    'v': 1,
    'kind': 'gif',
    'width': width,
    'height': height,
    'frames': frames,
    'cycleMs': cycleMilliseconds,
  };
}

final class VoiceMediaContent extends FileMediaContent {
  const VoiceMediaContent(this.durationMilliseconds);
  final int durationMilliseconds;
  @override
  Map<String, Object> toMap() => {
    'v': 1,
    'kind': 'voice',
    'codec': 'aac-lc',
    'container': 'm4a',
    'durationMs': durationMilliseconds,
  };
}

/// Parsed independently from content. Signed native commit scope remains the
/// authority; a group room must never become a DM custom topic identifier.
final class RichContentRoute {
  const RichContentRoute._({this.dmTopicId, this.groupRoomId});
  final String? dmTopicId;
  final String? groupRoomId;

  static RichContentRoute? parse(
    ConversationScope scope,
    Map<String, Object?> fields,
  ) {
    final topic = fields[DmTopicWire.itemField];
    final room = fields[RichContentWire.roomField];
    if (scope.isGroup) {
      if (topic != null || (room != null && !RichContentWire.validRoom(room))) {
        return null;
      }
      return RichContentRoute._(groupRoomId: room as String?);
    }
    if (room != null ||
        (topic != null &&
            topic != DmTopicWire.mainId &&
            !DmTopicWire.isCustomId(topic is String ? topic : null))) {
      return null;
    }
    return RichContentRoute._(
      dmTopicId: topic as String? ?? DmTopicWire.mainId,
    );
  }
}
