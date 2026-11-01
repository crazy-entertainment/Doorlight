import 'dart:async';

import 'package:flutter/services.dart';

/// App-level orientation intent. Camera and audio surfaces stay portrait;
/// screen content permits the user to rotate without tying policy to a
/// transient interaction such as remote-control consent.
enum SyblOrientationPolicy { portrait, screenContent }

List<DeviceOrientation> orientationsFor(SyblOrientationPolicy policy) =>
    switch (policy) {
      SyblOrientationPolicy.portrait => const [DeviceOrientation.portraitUp],
      SyblOrientationPolicy.screenContent => const [
        DeviceOrientation.portraitUp,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ],
    };

/// Serializes platform orientation writes so a slow older request cannot
/// complete after and overwrite a newer screen policy.
final class PreferredOrientationCoordinator {
  PreferredOrientationCoordinator({
    Future<void> Function(List<DeviceOrientation>)? apply,
  }) : _apply = apply ?? SystemChrome.setPreferredOrientations;

  final Future<void> Function(List<DeviceOrientation>) _apply;
  Future<void> _tail = Future<void>.value();
  SyblOrientationPolicy? _queued;

  Future<void> setPolicy(SyblOrientationPolicy policy) {
    if (_queued == policy) return _tail;
    _queued = policy;
    _tail = _tail
        .catchError((_) {
          // An OS refusal must not poison all later policy changes.
        })
        .then((_) => _apply(orientationsFor(policy)))
        .catchError((_) {
          // Orientation is a presentation preference, not a correctness or
          // security boundary. A later policy change can still be applied.
        });
    return _tail;
  }
}
