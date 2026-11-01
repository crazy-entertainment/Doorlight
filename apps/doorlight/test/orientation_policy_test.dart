import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/orientation_policy.dart';

void main() {
  test('screen content permits landscape without excluding portrait', () {
    expect(orientationsFor(SyblOrientationPolicy.screenContent), const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  });

  test('platform writes remain ordered when an older write is slow', () async {
    final first = Completer<void>();
    final applied = <List<DeviceOrientation>>[];
    var calls = 0;
    final coordinator = PreferredOrientationCoordinator(
      apply: (value) async {
        applied.add(value);
        calls += 1;
        if (calls == 1) await first.future;
      },
    );

    final screen = coordinator.setPolicy(SyblOrientationPolicy.screenContent);
    final portrait = coordinator.setPolicy(SyblOrientationPolicy.portrait);
    await Future<void>.delayed(Duration.zero);
    expect(applied, hasLength(1));

    first.complete();
    await Future.wait([screen, portrait]);

    expect(applied, [
      orientationsFor(SyblOrientationPolicy.screenContent),
      orientationsFor(SyblOrientationPolicy.portrait),
    ]);
  });
}
