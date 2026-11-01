import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/microphone_waveform.dart';

void main() {
  testWidgets('waveform samples real levels and clears immediately on mute', (
    tester,
  ) async {
    final level = ValueNotifier<double>(0);
    addTearDown(level.dispose);
    Future<void> show({bool muted = false, bool reduced = false}) =>
        tester.pumpWidget(
          MaterialApp(
            theme: Warm.theme(),
            home: MediaQuery(
              data: MediaQueryData(disableAnimations: reduced),
              child: Center(
                child: MicrophoneWaveform(level: level, muted: muted),
              ),
            ),
          ),
        );
    MicrophoneWaveformPainter painter() => tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((w) => w.painter)
        .whereType<MicrophoneWaveformPainter>()
        .single;
    await show();
    await tester.pump(const Duration(milliseconds: 100));
    expect(painter().samples.every((v) => v == 0), isTrue);
    level.value = .7;
    await tester.pump(const Duration(milliseconds: 50));
    expect(painter().samples.last, .7);
    await show(muted: true);
    expect(painter().samples.every((v) => v == 0), isTrue);
    await show(reduced: true);
    expect(painter().samples, [.7]);
    level.value = .2;
    await tester.pump();
    expect(painter().samples, [.2]);
    await tester.pumpWidget(const SizedBox());
  });
}
