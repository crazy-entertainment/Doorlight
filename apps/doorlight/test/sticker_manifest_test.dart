import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:sybl/state/sticker_manifest.dart';

void main() {
  test('native hologram derivative is pinned to the same bundled sticker', () {
    final source = jsonDecode(File('windows/runner/resources/hologram_angry.provenance.json').readAsStringSync()) as Map;
    expect(sha256.convert(File(source['source'] as String).readAsBytesSync()).toString(), source['sourceSha256']);
    final bytes = File(source['derivative'] as String).readAsBytesSync();
    expect(sha256.convert(bytes).toString(), source['derivativeSha256']);
    final decoded = image.decodePng(bytes)!;
    expect(decoded.width, 512); expect(decoded.height, 512); expect(decoded.numFrames, 1);
    expect(sha256.convert(decoded.getBytes(order: image.ChannelOrder.rgba)).toString(), source['decodedRgbaSha256']);
  });

  test(
    'every bundled manifest entry matches its real static encoded bytes',
    () {
      final manifest = StickerManifest.parse(
        File(StickerManifest.assetPath).readAsStringSync(),
      )!;
      for (final entry in manifest.entries) {
        final bytes = File(entry.path).readAsBytesSync();
        expect(bytes.length, entry.encodedBytes);
        expect(sha256.convert(bytes).toString(), entry.sha256);
        final decoded = image.decodeImage(bytes)!;
        expect(decoded.width, entry.width);
        expect(decoded.height, entry.height);
        expect(decoded.numFrames, 1);
      }
      final angry = manifest.byId('sybl.chubby-cats.angry.v1')!;
      expect(angry.encodedBytes, 81282);
      expect(
        angry.sha256,
        '724f416e8d8e63548c981626e1e76600a875350fb2fd51f4d0214e6f873df78d',
      );
    },
  );

  test(
    'manifest rejects paths, duplicates, animation and bounds violations',
    () {
      final source = File(StickerManifest.assetPath).readAsStringSync();
      for (final change in <String, Object>{
        'path': '../angry.webp',
        'frames': 2,
        'bytes': 1048577,
        'width': 513,
        'sha256': 'bad',
        'label': '',
        'mime': 'image/gif',
      }.entries) {
        final value = jsonDecode(source);
        value['stickers'][0][change.key] = change.value;
        expect(
          StickerManifest.parse(jsonEncode(value)),
          isNull,
          reason: change.key,
        );
      }
      final value = jsonDecode(source);
      value['stickers'].add(value['stickers'][0]);
      expect(StickerManifest.parse(jsonEncode(value)), isNull);
      expect(StickerManifest.parse(' ' * 65537), isNull);
    },
  );
}
