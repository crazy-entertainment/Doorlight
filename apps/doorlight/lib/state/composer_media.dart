import 'dart:io';

import 'package:crypto/crypto.dart';

import '../core/jami.dart';
import 'composer_draft.dart';
import 'gif_validation.dart';
import 'rich_content.dart';
import 'voice_validation.dart';

Future<ComposerMediaStage?> validateComposerVoice(String path, int size) async {
  if (size <= 0 || size > ValidatedVoice.maximumBytes) return null;
  final file = await File(path).open();
  try {
    if (await file.length() != size) return null;
    final bytes = await file.read(size);
    if (bytes.length != size) return null;
    final voice = ValidatedVoice.parse(bytes);
    if (voice == null) return null;
    return ComposerMediaStage(
      kind: ComposerMediaKind.voice,
      label: 'Voice message.m4a',
      encodedBytes: size,
      path: path,
      mediaMetadata: VoiceMediaContent(voice.durationMilliseconds).encode(),
    );
  } finally {
    await file.close();
  }
}

Future<ComposerMediaStage?> validateComposerGif(
  String path,
  int size, {
  String? expectedHash,
}) async {
  if (size <= 0 || size > ValidatedGif.maximumBytes) return null;
  final file = await File(path).open();
  try {
    if (await file.length() != size) return null;
    final bytes = await file.read(size);
    if (bytes.length != size) return null;
    if (expectedHash != null &&
        sha256.convert(bytes).toString() != expectedHash) {
      return null;
    }
    final gif = await validateGifDecode(bytes);
    if (gif == null) return null;
    return ComposerMediaStage(
      kind: ComposerMediaKind.gif,
      contentHash: sha256.convert(bytes).toString(),
      label: path.split(RegExp(r'[/\\]')).last,
      encodedBytes: size,
      path: path,
      mediaMetadata: GifMediaContent(
        gif.width,
        gif.height,
        gif.frames,
        gif.cycleMilliseconds,
      ).encode(),
    );
  } finally {
    await file.close();
  }
}

enum ComposerPreparationResult { staged, cancelled, stale, invalid }

/// All native media producers return private staging paths. Ownership is
/// checked on both sides of validation; no preparation publishes a message.
final class ComposerMediaPreparer {
  ComposerMediaPreparer({
    required this.discard,
    Future<int?> Function(String path)? inspect,
  }) : inspect = inspect ?? _inspect;

  final Future<void> Function(String path) discard;
  final Future<int?> Function(String path) inspect;

  static Future<int?> _inspect(String path) async {
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.file) {
      return null;
    }
    return File(path).length();
  }

  Future<ComposerPreparationResult> prepare({
    required ComposerDraftSession draft,
    required ComposerOperation operation,
    required Future<String?> Function() produce,
    bool Function()? isCurrent,
    Future<ComposerMediaStage?> Function(String path, int bytes)? validate,
    ComposerMediaKind kind = ComposerMediaKind.file,
    int maxBytes = JamiClient.maxPickedFileBytes,
  }) async {
    bool owns() => draft.owns(operation) && (isCurrent?.call() ?? true);
    if (!owns() || draft.blocked(ComposerOperationKind.sendMedia)) {
      return ComposerPreparationResult.stale;
    }
    String? candidate;
    var adopted = false;
    try {
      candidate = await produce();
      if (candidate == null || candidate.isEmpty) {
        return ComposerPreparationResult.cancelled;
      }
      if (!owns()) return ComposerPreparationResult.stale;
      final bytes = await inspect(candidate);
      if (!owns()) return ComposerPreparationResult.stale;
      if (bytes == null || bytes < 0 || bytes > maxBytes) {
        return ComposerPreparationResult.invalid;
      }
      final previous = draft.media;
      final discardPrevious =
          previous != null && draft.mayDiscardStage(previous);
      // Producers must allocate a fresh path, never reuse a retained draft's
      // seed. Refuse aliasing without deleting the already-owned file.
      if (previous?.path == candidate) {
        candidate = null;
        return ComposerPreparationResult.invalid;
      }
      final stage = validate != null
          ? await validate(candidate, bytes)
          : ComposerMediaStage(
              kind: kind,
              label: candidate.split(RegExp(r'[/\\]')).last,
              encodedBytes: bytes,
              path: candidate,
            );
      if (!owns()) return ComposerPreparationResult.stale;
      if (stage == null ||
          stage.path != candidate ||
          stage.encodedBytes != bytes) {
        return ComposerPreparationResult.invalid;
      }
      adopted = draft.replaceMedia(operation, stage);
      if (!adopted) return ComposerPreparationResult.stale;
      if (discardPrevious && previous.path != null) {
        await discard(previous.path!);
      }
      return ComposerPreparationResult.staged;
    } finally {
      draft.finishPreparation(operation);
      if (!adopted &&
          candidate != null &&
          candidate.isNotEmpty &&
          candidate != draft.media?.path) {
        await discard(candidate);
      }
    }
  }
}
