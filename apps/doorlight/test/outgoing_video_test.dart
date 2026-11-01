import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/outgoing_video.dart';
import 'package:sybl/state/video_viewport.dart';

void main() {
  test(
    'explicit source fields take precedence over legacy and fallback kinds',
    () {
      const fallback = OutgoingVideoSource(
        kind: OutgoingVideoKind.screen,
        controlRevision: 9,
      );
      for (final fields in <Map<String, Object?>>[
        {'outgoingVideoKind': null, 'cameraOn': true},
        {'sourceKind': 'unknown', 'cameraOn': true},
        {'cameraOn': null},
      ]) {
        expect(
          OutgoingVideoSource.fromMap(fields, fallback: fallback).kind,
          OutgoingVideoKind.off,
        );
      }
      expect(
        OutgoingVideoSource.fromMap({}, fallback: fallback).kind,
        OutgoingVideoKind.screen,
      );
      expect(
        OutgoingVideoSource.fromMap({
          'outgoingVideoKind': null,
          'sourceKind': 'camera',
        }, fallback: fallback).kind,
        OutgoingVideoKind.camera,
      );
      expect(
        OutgoingVideoSource.fromMap({
          'outgoingVideoKind': 'camera',
          'sourceKind': 'screen',
        }, fallback: fallback).kind,
        OutgoingVideoKind.camera,
      );
    },
  );

  test(
    'control revision distinguishes absent, invalid and non-screen values',
    () {
      const fallback = OutgoingVideoSource(
        kind: OutgoingVideoKind.screen,
        controlRevision: 9,
      );
      expect(
        OutgoingVideoSource.fromMap({}, fallback: fallback).controlRevision,
        9,
      );
      for (final revision in [null, 'invalid']) {
        expect(
          OutgoingVideoSource.fromMap({
            'remoteControlSourceRevision': revision,
          }, fallback: fallback).controlRevision,
          0,
        );
      }
      expect(
        OutgoingVideoSource.fromMap({
          'outgoingVideoKind': 'camera',
          'remoteControlSourceRevision': 12,
        }, fallback: fallback).controlRevision,
        -1,
      );
      expect(
        OutgoingVideoSource.fromMap(
          {'outgoingVideoKind': 'screen'},
          fallback: const OutgoingVideoSource(
            kind: OutgoingVideoKind.camera,
            controlRevision: 9,
          ),
        ).controlRevision,
        -1,
      );
    },
  );

  test('typed source parses native scalar variants and geometry', () {
    final source = OutgoingVideoSource.fromMap({
      'outgoingVideoKind': 'screen',
      'outgoingVideoUri': 'display://:1+0,0 2560x1440',
      'outgoingVideoRevision': '12',
      'outgoingVideoWidth': 2560,
      'outgoingVideoHeight': '1440',
    });
    expect(source.kind, OutgoingVideoKind.screen);
    expect(source.revision, 12);
    expect(source.geometry, const Size(2560, 1440));
    expect(source.isCamera, isFalse);
  });

  test('legacy camera snapshot maps into the same typed value', () {
    final source = OutgoingVideoSource.fromMap({'cameraOn': 'true'});
    expect(source.kind, OutgoingVideoKind.camera);
  });

  test('Android control revision waits for a real projection packet', () {
    final opening = OutgoingVideoSource.fromMap({
      'outgoingVideoKind': 'screen',
      'outgoingVideoRevision': 12,
      'remoteControlSourceRevision': 0,
    });
    expect(opening.effectiveControlRevision, 0);
    final live = OutgoingVideoSource.fromMap({
      'outgoingVideoKind': 'screen',
      'outgoingVideoRevision': 12,
      'remoteControlSourceRevision': 19,
    }, fallback: opening);
    expect(live.effectiveControlRevision, 19);
    final windows = OutgoingVideoSource.fromMap({
      'outgoingVideoKind': 'screen',
      'outgoingVideoRevision': 12,
    });
    expect(windows.effectiveControlRevision, 12);
  });

  test('screen descriptors reject malformed and stale dimensions', () {
    expect(
      ScreenSource.fromMap({'id': '0', 'width': 0, 'height': 1080}),
      isNull,
    );
    final source = ScreenSource.fromMap({
      'id': '1',
      'label': 'Display 2',
      'primary': false,
      'left': 1920,
      'top': -200,
      'width': 2560,
      'height': 1440,
    });
    expect(source?.bounds, const Rect.fromLTWH(1920, -200, 2560, 1440));
  });

  test('landscape source is contained in portrait viewport', () {
    final viewport = VideoViewport(
      viewport: const Size(1080, 1920),
      source: const Size(1920, 1080),
    );
    expect(viewport.contentRect, const Rect.fromLTWH(0, 656.25, 1080, 607.5));
    expect(viewport.normalize(const Offset(540, 960)), const Offset(.5, .5));
    expect(viewport.normalize(const Offset(540, 100)), isNull);
    expect(
      viewport.denormalize(const Offset(1, 1)),
      const Offset(1080, 1263.75),
    );
  });

  test('portrait source is contained in landscape viewport', () {
    final viewport = VideoViewport(
      viewport: const Size(1920, 1080),
      source: const Size(1080, 1920),
    );
    expect(viewport.contentRect, const Rect.fromLTWH(656.25, 0, 607.5, 1080));
    expect(viewport.normalize(const Offset(100, 540)), isNull);
    expect(viewport.normalize(const Offset(960, 540)), const Offset(.5, .5));
  });
}
