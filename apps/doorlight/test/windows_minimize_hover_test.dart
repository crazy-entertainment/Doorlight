import 'dart:typed_data';
import 'dart:ui' show ImageByteFormat, PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/state/appearance_preset.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/windows_chrome.dart';

Future<Uint8List> grab(WidgetTester tester) async {
  await tester.pumpAndSettle();
  final bytes = await tester.runAsync(() async {
    final rb = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('shot')),
    );
    final image = await rb.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ImageByteFormat.rawRgba);
    final result = Uint8List.fromList(
      data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
    image.dispose();
    return result;
  });
  return bytes!;
}

int changes(Uint8List a, Uint8List b, Rect r, int w) {
  var n = 0;
  for (var y = r.top.floor(); y < r.bottom.ceil(); y++) {
    for (var x = r.left.floor(); x < r.right.ceil(); x++) {
      final i = (y * w + x) * 4;
      if (a[i] != b[i] ||
          a[i + 1] != b[i + 1] ||
          a[i + 2] != b[i + 2] ||
          a[i + 3] != b[i + 3]) {
        n++;
      }
    }
  }
  return n;
}

List<int> pixel(Uint8List a, Offset p, int w) {
  final i = (p.dy.floor() * w + p.dx.floor()) * 4;
  return a.sublist(i, i + 4);
}

void main() {
  testWidgets('Disaccord minimize hover visibly differs from home background', (
    tester,
  ) async {
    const size = Size(800, 600);
    await tester.binding.setSurfaceSize(size);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final colors = Warm.palette(AppearancePreset.disaccord);
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('shot'),
        child: MaterialApp(
          theme: Warm.theme(
            AppearancePreset.disaccord,
          ).copyWith(platform: TargetPlatform.windows),
          builder: (context, child) => WindowsChrome(
            jami: JamiClient(),
            child: ColoredBox(color: colors.bg, child: child),
          ),
          home: const Scaffold(body: SizedBox.expand()),
        ),
      ),
    );
    final icon = find.byIcon(Icons.horizontal_rule_rounded);
    final button = find.ancestor(of: icon, matching: find.byType(IconButton));
    final rect = tester.getRect(button);
    final before = await grab(tester);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: const Offset(-20, -20));
    await tester.pump();
    await gesture.moveTo(rect.center);
    await tester.pump(const Duration(milliseconds: 250));
    final after = await grab(tester);
    final ink = tester.widget<InkWell>(
      find.descendant(of: button, matching: find.byType(InkWell)),
    );
    final overlay = ink.overlayColor?.resolve({WidgetState.hovered});
    final sample = Offset(rect.left + 8, rect.top + 8);
    final beforePixel = pixel(before, sample, 800),
        afterPixel = pixel(after, sample, 800);
    final count = changes(before, after, rect, 800);
    expect(overlay, isNotNull);
    expect(afterPixel[0] - beforePixel[0], greaterThanOrEqualTo(20));
    expect(count, greaterThan(0));
  });
}
