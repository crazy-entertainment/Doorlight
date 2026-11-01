import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/pane_reveal_switcher.dart';
import 'package:sybl/ui/pane_activity.dart';

void main() {
  testWidgets(
    'pages reveal without blending and interruption preserves visible pixels',
    (tester) async {
      final capture = GlobalKey();
      late StateSetter update;
      var page = 0;
      var oldClicks = 0;
      var newClicks = 0;
      var hostActive = true;
      final activity = <int, bool>{};
      const colors = [Color(0xffff0000), Color(0xff0000ff), Color(0xff00ff00)];
      await tester.pumpWidget(
        MaterialApp(
          theme: Warm.theme(),
          home: Center(
            child: SizedBox(
              width: 100,
              height: 60,
              child: RepaintBoundary(
                key: capture,
                child: StatefulBuilder(
                  builder: (_, setState) {
                    update = setState;
                    final owner = page;
                    return PaneActivityScope(
                      active: hostActive,
                      child: PaneRevealSwitcher(
                        child: GestureDetector(
                          key: ValueKey(owner),
                          onTap: () => owner == 0 ? oldClicks++ : newClicks++,
                          child: Builder(
                            builder: (context) {
                              activity[owner] = PaneActivityScope.isActive(
                                context,
                              );
                              return ColoredBox(color: colors[owner]);
                            },
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Future<List<int>> pixels() async => (await tester.runAsync(() async {
        final shot = await tester
            .renderObject<RenderRepaintBoundary>(find.byKey(capture))
            .toImage();
        final bytes = (await shot.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        shot.dispose();
        return [
          for (final x in [5, 50, 95])
            (bytes.getUint8((30 * 100 + x) * 4) << 16) |
                (bytes.getUint8((30 * 100 + x) * 4 + 1) << 8) |
                bytes.getUint8((30 * 100 + x) * 4 + 2),
        ];
      }))!;
      update(() => page = 1);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(await pixels(), [0x0000ff, 0xff0000, 0xff0000]);
      expect(activity[0], isFalse);
      expect(activity[1], isFalse);
      // The outgoing page is still visible here, but must not accept input.
      final bounds = tester.getRect(find.byKey(capture));
      await tester.tapAt(bounds.topLeft + const Offset(95, 30));
      expect(oldClicks, 0);
      expect(newClicks, 0);
      final before = await pixels();
      update(() => page = 2);
      await tester.pump();
      expect(
        await pixels(),
        before,
        reason: 'retargeting cannot reveal more of the outgoing page',
      );
      await tester.pumpAndSettle();
      expect(await pixels(), [0x00ff00, 0x00ff00, 0x00ff00]);
      await tester.tapAt(bounds.center);
      expect(newClicks, 1);
      expect(activity[2], isTrue);
      update(() => hostActive = false);
      await tester.pump();
      expect(
        activity[2],
        isFalse,
        reason: 'a page cannot override a hidden parent pane',
      );
      await tester.tapAt(bounds.center);
      expect(
        newClicks,
        1,
        reason: 'hidden parent panes also fence pointer input',
      );
      expect(tester.takeException(), isNull);
    },
  );
}
