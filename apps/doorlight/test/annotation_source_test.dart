import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fake_async/fake_async.dart';
import 'package:sybl/state/annotation.dart';
import 'package:sybl/state/outgoing_video.dart';

Map<String, Object> point(String owner, int revision, String id) => {
  'v': 1,
  't': 'pt',
  'sourceOwner': owner,
  'sourceRevision': revision,
  'sid': id,
  'seq': id.hashCode & 0x7FFFFFFF,
  'color': 0xFFF08A6C,
  'w': 3.5,
  'p': [
    [0.25, 0.75],
  ],
  'last': true,
};

void bindLocalScreen(
  AnnotationController controller, {
  required String local,
  required String peer,
  required int revision,
}) {
  controller.syncSources(
    localOwner: local,
    peerOwner: peer,
    localRevision: revision,
    localKind: OutgoingVideoKind.screen,
    peerKind: OutgoingVideoKind.off,
  );
}

void main() {
  test('request flood cannot repeatedly serialize the whole board', () {
    final owner = AnnotationController();
    addTearDown(owner.dispose);
    bindLocalScreen(owner, local: 'alice', peer: 'bob', revision: 7);
    owner.setTarget(AnnotationTarget.mine);
    owner.setEnabled(true);
    owner.begin(const Offset(.2, .4));
    owner.end();
    owner.setEnabled(false);
    var replies = 0;
    owner.sender = (message) {
      if (message['t'] == 'kf') replies++;
    };
    final request = jsonEncode({
      'v': 1,
      't': 'req',
      'sourceOwner': 'alice',
      'sourceRevision': 7,
    });
    for (var i = 0; i < 1000; i++) {
      owner.applyInbound(request);
    }
    expect(replies, lessThanOrEqualTo(2));
    expect(replies, greaterThan(0));
    owner.applyInbound(' ' * 65537);
    expect(replies, lessThanOrEqualTo(2));
  });

  test('source owner announces the exact owner/revision to a viewer', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final owner = AnnotationController();
    final viewer = AnnotationController();
    addTearDown(owner.dispose);
    addTearDown(viewer.dispose);
    owner.sender = (message) => viewer.applyInbound(jsonEncode(message));
    viewer.sender = (message) => owner.applyInbound(jsonEncode(message));

    bindLocalScreen(owner, local: 'alice', peer: 'bob', revision: 7);
    viewer.syncSources(
      localOwner: 'bob',
      peerOwner: 'alice',
      localRevision: 0,
      localKind: OutgoingVideoKind.off,
      peerKind: OutgoingVideoKind.screen,
      peerSourceChanged: true,
    );
    viewer.setEnabled(true);

    // The revision-0 request makes the owner announce alice/7 before drawing
    // starts; stale or unowned input remains inert.
    expect(viewer.enabled, isTrue);
    viewer.applyInbound(jsonEncode(point('alice', 6, 'stale')));
    viewer.applyInbound(jsonEncode(point('mallory', 7, 'wrong-owner')));
    expect(viewer.peerStrokes, isEmpty);
    viewer.applyInbound(jsonEncode(point('alice', 7, 'current')));
    expect(viewer.peerStrokes.single.id, 'current');
    expect(viewer.peerPlatform, 'android');

    viewer.reset();
    expect(viewer.peerPlatform, isEmpty);
  });

  test('source discovery immediately recovers a board drawn before attach', () {
    final owner = AnnotationController();
    final viewer = AnnotationController();
    addTearDown(owner.dispose);
    addTearDown(viewer.dispose);
    owner.sender = (message) => viewer.applyInbound(jsonEncode(message));
    viewer.sender = (message) => owner.applyInbound(jsonEncode(message));

    bindLocalScreen(owner, local: 'alice', peer: 'bob', revision: 7);
    owner.setTarget(AnnotationTarget.mine);
    owner.setEnabled(true);
    owner.begin(const Offset(0.2, 0.4));
    owner.end();
    owner.setEnabled(false); // no periodic keyframe can rescue the viewer

    viewer.syncSources(
      localOwner: 'bob',
      peerOwner: 'alice',
      localRevision: 0,
      localKind: OutgoingVideoKind.off,
      peerKind: OutgoingVideoKind.screen,
      peerSourceChanged: true,
    );

    expect(viewer.peerStrokes, hasLength(1));
    expect(viewer.peerStrokes.single.points.single, const Offset(0.2, 0.4));
  });

  test('source discovery retries after a pre-CURRENT send is dropped', () {
    fakeAsync((clock) {
      final viewer = AnnotationController();
      var requests = 0;
      viewer.sender = (message) {
        if (message['t'] == 'req') requests++;
      };
      viewer.syncSources(
        localOwner: 'bob',
        peerOwner: 'alice',
        localRevision: 0,
        localKind: OutgoingVideoKind.off,
        peerKind: OutgoingVideoKind.screen,
        peerSourceChanged: true,
      );
      expect(requests, 1);
      clock.elapse(const Duration(milliseconds: 750));
      expect(requests, 2);
      viewer.applyInbound(
        jsonEncode({
          'v': 1,
          't': 'src',
          'sourceOwner': 'alice',
          'sourceRevision': 8,
          'sourceKind': 'screen',
        }),
      );
      clock.elapse(const Duration(seconds: 10));
      // Accepting the source sends one exact-board recovery request, then the
      // discovery timer is retired.
      expect(requests, 3);
      viewer.dispose();
    });
  });

  test('revision-zero screen announcement keeps source discovery active', () {
    fakeAsync((clock) {
      final viewer = AnnotationController();
      var requests = 0;
      viewer.sender = (message) {
        if (message['t'] == 'req') requests++;
      };
      viewer.syncSources(
        localOwner: 'bob',
        peerOwner: 'alice',
        localRevision: 0,
        localKind: OutgoingVideoKind.off,
        peerKind: OutgoingVideoKind.screen,
        peerSourceChanged: true,
      );

      viewer.applyInbound(
        jsonEncode({
          'v': 1,
          't': 'src',
          'sourceOwner': 'alice',
          'sourceRevision': 0,
          'sourceKind': 'screen',
          'platform': 'android',
        }),
      );

      expect(viewer.peerSourceRevision, isNull);
      clock.elapse(const Duration(milliseconds: 750));
      expect(requests, 2);
      viewer.dispose();
    });
  });

  test('live screen discovery survives the fast bootstrap window', () {
    fakeAsync((clock) {
      final viewer = AnnotationController();
      var requests = 0;
      viewer.sender = (message) {
        if (message['t'] == 'req') requests++;
      };
      viewer.syncSources(
        localOwner: 'bob',
        peerOwner: 'alice',
        localRevision: 0,
        localKind: OutgoingVideoKind.off,
        peerKind: OutgoingVideoKind.screen,
        peerSourceChanged: true,
      );

      // Eight fast requests are followed by a bounded five-second recovery
      // cadence instead of permanently abandoning a still-live screen.
      clock.elapse(const Duration(milliseconds: 5250));
      expect(requests, 8);
      clock.elapse(const Duration(seconds: 5));
      expect(requests, 9);

      viewer.applyInbound(
        jsonEncode({
          'v': 1,
          't': 'src',
          'sourceOwner': 'alice',
          'sourceRevision': 8,
          'sourceKind': 'screen',
        }),
      );
      expect(requests, 10); // exact-board recovery request
      clock.elapse(const Duration(seconds: 20));
      expect(requests, 10);
      viewer.dispose();
    });
  });

  test(
    'active video discovers a screen when libjami has no remote source kind',
    () {
      fakeAsync((clock) {
        final viewer = AnnotationController();
        var requests = 0;
        viewer.sender = (message) {
          if (message['t'] == 'req') requests++;
        };
        viewer.syncSources(
          localOwner: 'bob',
          peerOwner: 'alice',
          localRevision: 0,
          localKind: OutgoingVideoKind.off,
          // libjami reconstructs remote SDP without SOURCE. Its camera value is
          // only an active-video hint, not source-kind authority.
          peerKind: OutgoingVideoKind.camera,
          peerSourceChanged: true,
        );
        viewer.ensurePeerSourceDiscovery();

        expect(requests, 2);
        clock.elapse(const Duration(milliseconds: 750));
        expect(requests, 3);
        viewer.applyInbound(
          jsonEncode({
            'v': 1,
            't': 'src',
            'sourceOwner': 'alice',
            'sourceRevision': 8,
            'sourceKind': 'screen',
            'platform': 'android',
          }),
        );
        expect(viewer.peerSourceOwner, 'alice');
        expect(viewer.peerSourceRevision, 8);
        expect(viewer.peerSourceKind, OutgoingVideoKind.screen);
        expect(viewer.peerPlatform, 'android');
        expect(requests, 4); // exact-board recovery request

        viewer.syncSources(
          localOwner: 'bob',
          peerOwner: 'alice',
          localRevision: 0,
          localKind: OutgoingVideoKind.off,
          peerKind: OutgoingVideoKind.camera,
          peerSourceChanged: true,
        );
        viewer.ensurePeerSourceDiscovery();
        expect(viewer.peerSourceRevision, isNull);
        expect(viewer.peerSourceKind, OutgoingVideoKind.off);
        expect(requests, 6);
        clock.elapse(const Duration(milliseconds: 750));
        expect(requests, 7);
        viewer.dispose();
      });
    },
  );

  test(
    'screen discovery is independent of the simultaneous-share draw target',
    () {
      fakeAsync((clock) {
        final viewer = AnnotationController();
        var requests = 0;
        viewer.sender = (message) {
          if (message['t'] == 'req') requests++;
        };
        viewer.syncSources(
          localOwner: 'bob',
          peerOwner: 'alice',
          localRevision: 11,
          localKind: OutgoingVideoKind.screen,
          peerKind: OutgoingVideoKind.screen,
          peerSourceChanged: true,
        );
        viewer.setTarget(AnnotationTarget.mine);
        expect(viewer.target, AnnotationTarget.mine);
        expect(requests, 1);

        clock.elapse(const Duration(milliseconds: 750));
        expect(requests, 2);
        viewer.dispose();
      });
    },
  );

  test('source replacement clears strokes and rejects the older session', () {
    final controller = AnnotationController();
    addTearDown(controller.dispose);

    bindLocalScreen(controller, local: 'alice', peer: 'bob', revision: 3);
    controller.applyInbound(jsonEncode(point('alice', 3, 'old')));
    expect(controller.peerStrokes, hasLength(1));

    bindLocalScreen(controller, local: 'alice', peer: 'bob', revision: 4);
    expect(controller.peerStrokes, isEmpty);
    controller.applyInbound(jsonEncode(point('alice', 3, 'late')));
    expect(controller.peerStrokes, isEmpty);
  });

  test(
    'owned Android screen snapshot includes both drawers and excludes camera',
    () {
      final controller = AnnotationController();
      addTearDown(controller.dispose);
      bindLocalScreen(controller, local: 'alice', peer: 'bob', revision: 12);
      controller.setTarget(AnnotationTarget.mine);
      controller.setEnabled(true);
      controller.begin(const Offset(0.1, 0.2));
      controller.end();
      controller.applyInbound(jsonEncode(point('alice', 12, 'peer-mark')));

      final snapshot = controller.ownedScreenOverlaySnapshot('call-a');
      expect(snapshot['active'], isTrue);
      expect(snapshot['callId'], 'call-a');
      expect(snapshot['sourceRevision'], 12);
      final strokes = snapshot['strokes']! as List<Object?>;
      expect(strokes, hasLength(2));
      expect(
        ((strokes.first as Map<String, Object?>)['points']! as List<Object?>)
            .first,
        [0.1, 0.2],
      );

      controller.syncSources(
        localOwner: 'alice',
        peerOwner: 'bob',
        localRevision: 13,
        localKind: OutgoingVideoKind.camera,
        peerKind: OutgoingVideoKind.off,
      );
      expect(
        controller.ownedScreenOverlaySnapshot('call-a'),
        const <String, Object?>{'active': false},
      );
    },
  );

  test('late source announcement cannot roll a peer session backward', () {
    final controller = AnnotationController();
    addTearDown(controller.dispose);
    controller.syncSources(
      localOwner: 'bob',
      peerOwner: 'alice',
      localRevision: 0,
      localKind: OutgoingVideoKind.off,
      peerKind: OutgoingVideoKind.screen,
      peerSourceChanged: true,
    );

    controller.applyInbound(
      jsonEncode({
        'v': 1,
        't': 'src',
        'sourceOwner': 'alice',
        'sourceRevision': 8,
        'sourceKind': 'screen',
      }),
    );
    controller.syncSources(
      localOwner: 'bob',
      peerOwner: 'alice',
      localRevision: 0,
      localKind: OutgoingVideoKind.off,
      peerKind: OutgoingVideoKind.camera,
      peerSourceChanged: true,
    );
    controller.applyInbound(
      jsonEncode({
        'v': 1,
        't': 'src',
        'sourceOwner': 'alice',
        'sourceRevision': 7,
        'sourceKind': 'screen',
      }),
    );
    controller.applyInbound(jsonEncode(point('alice', 7, 'retired')));
    expect(controller.ready, isFalse);
    expect(controller.peerStrokes, isEmpty);

    controller.applyInbound(
      jsonEncode({
        'v': 1,
        't': 'src',
        'sourceOwner': 'alice',
        'sourceRevision': 9,
        'sourceKind': 'camera',
      }),
    );
    controller.applyInbound(jsonEncode(point('alice', 9, 'current')));
    expect(controller.ready, isTrue);
    expect(controller.peerStrokes.single.id, 'current');
  });

  test('duplicate point sequence is idempotent', () {
    final controller = AnnotationController();
    addTearDown(controller.dispose);
    bindLocalScreen(controller, local: 'alice', peer: 'bob', revision: 2);
    final packet = point('alice', 2, 'same')..['last'] = false;

    controller.applyInbound(jsonEncode(packet));
    controller.applyInbound(jsonEncode(packet));

    expect(controller.peerStrokes.single.points, hasLength(1));
  });

  test('periodic merge keyframe never deletes retained peer strokes', () {
    final controller = AnnotationController();
    addTearDown(controller.dispose);
    bindLocalScreen(controller, local: 'alice', peer: 'bob', revision: 2);
    controller.applyInbound(jsonEncode(point('alice', 2, 'older')));
    controller.applyInbound(jsonEncode(point('alice', 2, 'recent')));

    controller.applyInbound(
      jsonEncode({
        'v': 1,
        't': 'kf',
        'mode': 'merge',
        'sourceOwner': 'alice',
        'sourceRevision': 2,
        's': [
          {
            'sid': 'recent',
            'color': 0xFFF08A6C,
            'w': 3.5,
            'p': [
              [0.4, 0.6],
            ],
          },
        ],
      }),
    );

    expect(
      controller.peerStrokes.map((stroke) => stroke.id),
      containsAll(<String>['older', 'recent']),
    );
  });

  test('replacement keyframe commits atomically after every bounded page', () {
    final controller = AnnotationController();
    addTearDown(controller.dispose);
    bindLocalScreen(controller, local: 'alice', peer: 'bob', revision: 2);
    controller.applyInbound(jsonEncode(point('alice', 2, 'stale')));

    Map<String, Object?> page(int part, String id) => {
      'v': 1,
      't': 'kf',
      'mode': 'replace',
      'snapshot': 'alice-2-9',
      'part': part,
      'parts': 2,
      'sourceOwner': 'alice',
      'sourceRevision': 2,
      's': [
        {
          'sid': id,
          'color': 0xFFF08A6C,
          'w': 3.5,
          'p': [
            [0.2 + part * 0.2, 0.3],
          ],
        },
      ],
    };

    controller.applyInbound(jsonEncode(page(1, 'second')));
    controller.applyInbound(jsonEncode(page(1, 'second')));
    expect(controller.peerStrokes.single.id, 'stale');

    controller.applyInbound(jsonEncode(page(0, 'first')));
    expect(
      controller.peerStrokes.map((stroke) => stroke.id),
      orderedEquals(<String>['first', 'second']),
    );
  });

  test('explicit resync splits a large board below the wire budget', () {
    final owner = AnnotationController();
    addTearDown(owner.dispose);
    bindLocalScreen(owner, local: 'alice', peer: 'bob', revision: 7);
    owner.setTarget(AnnotationTarget.mine);
    owner.setEnabled(true);
    for (var stroke = 0; stroke < 6; stroke++) {
      final y = 0.1 + stroke * 0.1;
      owner.begin(Offset(0.01, y));
      for (var point = 1; point <= 200; point++) {
        owner.extend(Offset(0.01 + point * 0.0045, y));
      }
      owner.end();
    }
    owner.setEnabled(false);

    final packets = <Map<String, dynamic>>[];
    owner.sender = packets.add;
    owner.applyInbound(
      jsonEncode({
        'v': 1,
        't': 'req',
        'sourceOwner': 'alice',
        'sourceRevision': 7,
      }),
    );
    final pages = packets
        .where((packet) => packet['t'] == 'kf' && packet['mode'] == 'replace')
        .toList(growable: false);

    expect(pages.length, greaterThan(1));
    expect(
      pages.map((page) => page['part']),
      orderedEquals(List<int>.generate(pages.length, (index) => index)),
    );
    for (final page in pages) {
      expect(page['parts'], pages.length);
      expect(utf8.encode(jsonEncode(page)).length, lessThanOrEqualTo(6000));
    }
  });

  test(
    'simultaneous shares retain independent outgoing and target sessions',
    () {
      final alice = AnnotationController();
      final bob = AnnotationController();
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      alice.sender = (message) => bob.applyInbound(jsonEncode(message));
      bob.sender = (message) => alice.applyInbound(jsonEncode(message));

      alice.syncSources(
        localOwner: 'alice',
        peerOwner: 'bob',
        localRevision: 5,
        localKind: OutgoingVideoKind.screen,
        peerKind: OutgoingVideoKind.screen,
        peerSourceChanged: true,
      );
      bob.syncSources(
        localOwner: 'bob',
        peerOwner: 'alice',
        localRevision: 9,
        localKind: OutgoingVideoKind.screen,
        peerKind: OutgoingVideoKind.screen,
        peerSourceChanged: true,
      );
      alice.setEnabled(true);
      bob.setEnabled(true);

      // Replacing Alice's outgoing source does not overwrite Alice's target,
      // which remains Bob's independently-owned revision 9 session.
      alice.syncSources(
        localOwner: 'alice',
        peerOwner: 'bob',
        localRevision: 6,
        localKind: OutgoingVideoKind.screen,
        peerKind: OutgoingVideoKind.screen,
      );
      // Alice announces her independently-owned replacement even though her
      // own target remains Bob. Bob rejects the retired source session.
      bob.applyInbound(jsonEncode(point('alice', 5, 'retired-alice')));
      expect(bob.peerStrokes, isEmpty);
      bob.applyInbound(jsonEncode(point('alice', 6, 'current-alice')));
      expect(bob.peerStrokes.single.id, 'current-alice');

      alice.applyInbound(jsonEncode(point('alice', 6, 'not-target')));
      expect(alice.peerStrokes, isEmpty);
      alice.applyInbound(jsonEncode(point('bob', 9, 'bob-target')));
      expect(alice.peerStrokes.single.id, 'bob-target');
    },
  );

  test(
    'either endpoint can target either camera without losing the other board',
    () {
      final alice = AnnotationController();
      final bob = AnnotationController();
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      alice.sender = (message) => bob.applyInbound(jsonEncode(message));
      bob.sender = (message) => alice.applyInbound(jsonEncode(message));

      alice.syncSources(
        localOwner: 'alice',
        peerOwner: 'bob',
        localRevision: 2,
        localKind: OutgoingVideoKind.camera,
        peerKind: OutgoingVideoKind.camera,
        peerSourceChanged: true,
      );
      bob.syncSources(
        localOwner: 'bob',
        peerOwner: 'alice',
        localRevision: 4,
        localKind: OutgoingVideoKind.camera,
        peerKind: OutgoingVideoKind.camera,
        peerSourceChanged: true,
      );
      expect(alice.ready, isTrue);
      expect(bob.ready, isTrue);

      // Alice and Bob both draw on Alice's camera.
      alice.setTarget(AnnotationTarget.mine);
      alice.setEnabled(true);
      alice.begin(const Offset(0.2, 0.3));
      alice.end();
      bob.setEnabled(true); // Bob defaults to Alice ("theirs").
      bob.begin(const Offset(0.4, 0.5));
      bob.end();
      expect(alice.mineStrokes, hasLength(1));
      expect(alice.peerStrokes, hasLength(1));

      // Alice switches to Bob's camera and draws there. Bob can switch to his
      // own board and see the received stroke; Alice's board remains intact.
      alice.setTarget(AnnotationTarget.theirs);
      alice.setEnabled(true);
      alice.begin(const Offset(0.6, 0.7));
      alice.end();
      bob.setTarget(AnnotationTarget.mine);
      expect(bob.peerStrokes, hasLength(1));
      alice.setTarget(AnnotationTarget.mine);
      expect(alice.mineStrokes, hasLength(1));
      expect(alice.peerStrokes, hasLength(1));
    },
  );

  test('missing session is rejected and malformed keyframe is atomic', () {
    final controller = AnnotationController();
    addTearDown(controller.dispose);
    bindLocalScreen(controller, local: 'alice', peer: 'bob', revision: 2);
    controller.applyInbound(jsonEncode(point('alice', 2, 'kept')));

    final missingRevision = point('alice', 2, 'missing')
      ..remove('sourceRevision');
    controller.applyInbound(jsonEncode(missingRevision));
    controller.applyInbound(
      jsonEncode({...point('alice', 2, 'fractional'), 'sourceRevision': 2.5}),
    );
    controller.applyInbound(
      jsonEncode({...point('alice', 2, 'bad-points'), 'p': 'not-a-list'}),
    );
    controller.applyInbound(
      jsonEncode({
        'v': 1,
        't': 'kf',
        'sourceOwner': 'alice',
        'sourceRevision': 2,
        's': 'not-a-list',
      }),
    );
    expect(controller.peerStrokes.single.id, 'kept');
  });
}
