import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:sybl/core/image_bounds.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/ui/friend_qr_scanner.dart';
import 'package:sybl/ui/profile_picture_editor.dart';

Uint8List _jpegHeader({int width = 4097, int height = 2, int samples = 0x11}) =>
    Uint8List.fromList([
      0xff,
      0xd8,
      0xff,
      0xc0,
      0,
      11,
      8,
      height >> 8,
      height & 255,
      width >> 8,
      width & 255,
      1,
      1,
      samples,
      0,
      0xff,
      0xda,
      0,
      8,
      1,
      1,
      0,
      0,
      63,
      0,
      0xff,
      0xd9,
    ]);

Uint8List _chunk(String type, List<int> body) {
  final payload = [...ascii.encode(type), ...body];
  var crc = 0xffffffff;
  for (final byte in payload) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc >> 1) ^ ((crc & 1) == 0 ? 0 : 0xedb88320);
    }
  }
  final result = Uint8List(body.length + 12);
  ByteData.sublistView(result)
    ..setUint32(0, body.length)
    ..setUint32(result.length - 4, crc ^ 0xffffffff);
  result.setRange(4, result.length - 4, payload);
  return result;
}

void main() {
  test('static supported images retain decode and avatar compatibility', () {
    final pixels = image.Image(width: 8, height: 8)
      ..clear(image.ColorRgb8(40, 80, 120));
    for (final bytes in [
      image.encodePng(pixels),
      image.encodeJpg(pixels),
      image.encodeGif(pixels),
      image.encodeBmp(pixels),
    ]) {
      expect(ProfileWireContract.isBoundedAvatarBytes(bytes), isTrue);
      expect(decodeBoundedRaster(bytes, maxEncodedBytes: 100000)?.width, 8);
      expect(decodeProfileImage(bytes)?.pixels.height, 8);
    }
  });

  test(
    'JPEG dimensions and sampling are rejected before header decoder allocation',
    () {
      for (final bytes in [
        _jpegHeader(),
        _jpegHeader(width: 2049, height: 2048),
        _jpegHeader(width: 2, samples: 0),
        _jpegHeader(width: 2, samples: 0xff),
      ]) {
        expect(boundedRasterDecoder(bytes, maxEncodedBytes: 100000), isNull);
        expect(ProfileWireContract.decodeAvatar(base64Encode(bytes)), isNull);
        expect(friendInviteFromQrImage(bytes), isNull);
      }
    },
  );

  test('encoded bounds and animation reject before frame decoding', () {
    final pixels = image.Image(width: 2, height: 2);
    final png = image.encodePng(pixels);
    expect(boundedRasterDecoder(png, maxEncodedBytes: png.length - 1), isNull);
    pixels.addFrame(image.Image(width: 2, height: 2));
    expect(
      boundedRasterDecoder(image.encodeGif(pixels), maxEncodedBytes: 100000),
      isNull,
    );
    expect(
      friendInviteFromQrImage(Uint8List(maxFriendQrImageBytes + 1)),
      isNull,
    );
  });

  test('BMP palette count is bounded before metadata decoder allocation', () {
    final ordinary = image.encodeBmp(image.Image(width: 1, height: 1));
    for (final count in [257, 0x10000000]) {
      final hostile = Uint8List.fromList(ordinary);
      ByteData.sublistView(hostile)
        ..setUint16(28, 8, Endian.little)
        ..setUint32(46, count, Endian.little);
      expect(boundedRasterDecoder(hostile, maxEncodedBytes: 100000), isNull);
      expect(ProfileWireContract.decodeAvatar(base64Encode(hostile)), isNull);
      expect(friendInviteFromQrImage(hostile), isNull);
    }
    final indexed = image.Image(
      width: 2,
      height: 2,
      numChannels: 1,
      format: image.Format.uint8,
      withPalette: true,
    );
    final encoded = image.encodeBmp(indexed);
    expect(decodeBoundedRaster(encoded, maxEncodedBytes: 100000)?.width, 2);
  });

  test('small PNG dimensions cannot hide excess IDAT expansion', () {
    final ordinary = image.encodePng(image.Image(width: 1, height: 1));
    final hostile = Uint8List.fromList([
      ...ordinary.sublist(0, 33), // Valid signature and IHDR from the encoder.
      ..._chunk('IDAT', zlib.encode(Uint8List(70000))),
      ..._chunk('IEND', []),
    ]);
    expect(boundedRasterDecoder(hostile, maxEncodedBytes: 100000), isNotNull);
    expect(decodeBoundedRaster(hostile, maxEncodedBytes: 100000), isNull);
    expect(decodeProfileImage(hostile), isNull);
    expect(friendInviteFromQrImage(hostile), isNull);
  });

  test('compressed PNG color metadata cannot reach profile JPEG export', () {
    final ordinary = image.encodePng(image.Image(width: 1, height: 1));
    final withProfile = Uint8List.fromList([
      ...ordinary.sublist(0, 33),
      ..._chunk('iCCP', [
        ...ascii.encode('profile'),
        0,
        0,
        ...zlib.encode(Uint8List(70000)),
      ]),
      ...ordinary.sublist(33),
    ]);
    final decoded = decodeProfileImage(withProfile);
    expect(decoded, isNotNull);
    expect(decoded!.pixels.iccProfile, isNull);
    expect(image.encodeJpg(decoded.pixels).length, lessThan(5000));
  });
}
