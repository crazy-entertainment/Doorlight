import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/doorlight_binding.dart';

class _Binding extends AutomatedTestWidgetsFlutterBinding
    with DoorlightMotionPolicy {}

void main() {
  final binding = _Binding();
  testWidgets(
    'Windows animations off keeps Doorlight controller timing intact',
    (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final controller = AnimationController(
        vsync: tester,
        duration: const Duration(milliseconds: 1000),
      );
      expect(binding.disableAnimations, isFalse);
      controller.forward();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(controller.value, closeTo(.3, .001));
      await tester.pump(const Duration(milliseconds: 700));
      expect(controller.value, 1);
      binding.animationsEnabled = false;
      expect(binding.disableAnimations, isTrue);
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: false);
      expect(binding.disableAnimations, isTrue);
      binding.animationsEnabled = true;
      expect(binding.disableAnimations, isFalse);
      controller.dispose();
    },
  );
}
