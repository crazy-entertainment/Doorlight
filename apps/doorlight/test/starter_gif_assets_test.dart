import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/gif_validation.dart';
import 'package:sybl/state/starter_gifs.dart';
import 'package:sybl/state/composer_media.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'bundled shelf loads offline and staged substitutions are rejected',
    () async {
      final entries = await bundledStarterGifs;
      expect(entries, hasLength(16));
      final first = entries.first;
      expect(await first.load(), isNotNull);
      final stage = await validateComposerGif(
        first.asset,
        first.length,
        expectedHash: first.hash,
      );
      expect(stage, isNotNull);
      expect(
        await validateComposerGif(
          first.asset,
          first.length,
          expectedHash: entries.last.hash,
        ),
        isNull,
      );
    },
  );

  test(
    'all 16 offline animations decode within the actual app limits',
    () async {
      final manifest =
          jsonDecode(
                File('assets/gifs/doorlight/manifest.json').readAsStringSync(),
              )
              as Map<String, dynamic>;
      final entries = manifest['assets'] as List<dynamic>;
      expect(entries, hasLength(16));
      final hashes = <String>{};
      final ids = <String>{};
      var total = 0;
      for (final raw in entries) {
        final entry = raw as Map<String, dynamic>;
        final id = entry['id'] as String;
        expect(ids.add(id), isTrue);
        expect(RegExp(r'^[a-z]+$').hasMatch(id), isTrue);
        expect(entry['asset'], 'assets/gifs/doorlight/$id.gif');
        final bytes = await File(entry['asset'] as String).readAsBytes();
        final hash = sha256.convert(bytes).toString();
        expect(hashes.add(hash), isTrue);
        expect(hash, entry['sha256']);
        expect(bytes.length, entry['bytes']);
        total += bytes.length;
        final decoded = await validateGifDecode(bytes);
        expect(decoded, isNotNull, reason: id);
        expect(decoded!.width, 256);
        expect(decoded.height, 256);
        expect(decoded.frames, entry['frames']);
        expect(decoded.cycleMilliseconds, 1920);
        expect(entry['redistributionLicense'], 'CC0-1.0');
        expect(entry['sourceCreator'], 'Kenney Vleugels (Kenney.nl)');
      }
      expect(total, lessThan(2 * 1024 * 1024));
    },
  );
}
