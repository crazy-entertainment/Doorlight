import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/core/invite_link.dart';

void main() {
  const id = 'abcdef0123456789abcdef0123456789abcdef01';
  const origin = 'https://invites.example.test';

  test(
    'configured HTTPS share link keeps public material only in its fragment',
    () {
      final invite = SyblInviteLink.create(
        jamiId: id,
        displayName: 'Zoë & Mara',
      )!;
      final link = invite.shareUri(httpsOrigin: origin);
      expect(link, '$origin/invite/#v=1&id=$id&name=Zo%C3%AB+%26+Mara');
      expect(SyblInviteLink.tryParse(link, httpsOrigin: origin), invite);
      expect(SyblInviteLink.tryParse(link), isNull);
      expect(invite.shareUri(httpsOrigin: ''), invite.canonicalUri);
      for (final invalid in [
        'http://example.test',
        '$origin/path',
        '$origin?',
        '$origin#',
        '$origin:443',
        'https://bad..test',
      ]) {
        expect(invite.shareUri(httpsOrigin: invalid), invite.canonicalUri);
      }
    },
  );

  test('HTTPS wrappers reject other origins and ambiguous fragment fields', () {
    const link = '$origin/invite/#v=1&id=$id';
    for (final bad in [
      '$link&id=$id',
      '$link&%69d=$id',
      '$link&other=true',
      '$link&name=a&name=b',
      '$link&name',
      '$link&name=%FF',
      '$link&name=%C0%AF',
      '$link&name=%',
      '$link&name=%GG',
      '$link&name=a b',
      '$link\n',
      '$link&name=${'x' * 1025}',
      link.replaceFirst('v=1', 'v=2'),
      link.replaceFirst(id, 'not-an-id'),
      link.replaceFirst('/invite/', '/other/'),
      link.replaceFirst('/invite/#', '/invite/?#'),
      link.replaceFirst('/invite/#', '/invite/?id=$id#'),
      link.replaceFirst(
        'invites.example.test',
        'invites.example.test.evil.test',
      ),
      link.replaceFirst('https://', 'http://'),
      link.replaceFirst('https://', 'https://user@'),
      link.replaceFirst('example.test/', 'example.test:444/'),
    ]) {
      expect(
        SyblInviteLink.tryParse(bad, httpsOrigin: origin),
        isNull,
        reason: bad,
      );
    }
  });

  test('personalized invite round-trips to one canonical public identity', () {
    final invite = SyblInviteLink.create(
      jamiId: 'JAMI:${id.toUpperCase()}',
      displayName: '  Mara  ',
    )!;
    expect(invite.jamiId, id);
    expect(invite.displayName, 'Mara');
    expect(SyblInviteLink.tryParse(invite.canonicalUri), invite);
    expect(invite.canonicalUri, 'sybl://add/$id?name=Mara');
  });

  test(
    'unknown shape, duplicate fields, and malformed identity fail closed',
    () {
      expect(SyblInviteLink.tryParse('https://example.test/$id'), isNull);
      expect(SyblInviteLink.tryParse('sybl://remove/$id'), isNull);
      expect(SyblInviteLink.tryParse('sybl://add/not-an-id'), isNull);
      expect(SyblInviteLink.tryParse('sybl://add/$id?name=a&name=b'), isNull);
      expect(SyblInviteLink.tryParse('sybl://add/$id?admin=true'), isNull);
      expect(SyblInviteLink.tryParse('x' * 1025), isNull);
    },
  );

  test('untrusted display copy is optional and strictly bounded', () {
    expect(
      SyblInviteLink.tryParse('sybl://add/$id?name=${'x' * 65}')?.displayName,
      isEmpty,
    );
    expect(
      SyblInviteLink.tryParse('sybl://add/$id?name=%0Aprivate')?.displayName,
      isEmpty,
    );
  });

  for (final scheme in ['sybl', 'doorlight']) {
    test('$scheme invitations retain the compatible fallback', () {
      final invite = SyblInviteLink.tryParse('$scheme://add/$id?name=Mara')!;
      expect(invite.jamiId, id);
      expect(invite.displayName, 'Mara');
      expect(invite.canonicalUri, 'sybl://add/$id?name=Mara');
    });

    test(
      '$scheme rejects malformed and ambiguous invitations without throwing',
      () {
        for (final suffix in [
          '?name=a&name=b',
          '?name=a&%6eame=b',
          '?name=%FF',
          '?name=%C0%AF',
          '?admin=true',
          '/extra',
          '#',
          '#fragment',
        ]) {
          expect(SyblInviteLink.tryParse('$scheme://add/$id$suffix'), isNull);
        }
        for (final authority in ['user@add', 'add:443', 'other']) {
          expect(SyblInviteLink.tryParse('$scheme://$authority/$id'), isNull);
        }
      },
    );
  }
}
