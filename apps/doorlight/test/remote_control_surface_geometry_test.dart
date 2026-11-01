import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/remote_control.dart';
import 'package:sybl/ui/remote_control_surface.dart';

class _UnusedTransport implements RemoteControlTransport {
  @override
  bool get nativeHostAuthority => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Controller extends RemoteControlController {
  _Controller() : super(_UnusedTransport());
  final events = <String>[];
  @override
  bool get isControlling => true;
  @override
  void move(double x, double y) => events.add('move:$x,$y');
  @override
  void button(RemoteMouseButton button, {required bool down}) =>
      events.add('${button.name}:$down');
  @override
  void wheel(int delta) => events.add('wheel:$delta');
  @override
  void releaseHeldInputs() => events.add('release');
}

void main() {
  for (final source in [const Size(400, 200), const Size(200, 400)]) {
    testWidgets(
      'bars reject presses and wheel for $source',
      (tester) async {
        final controller = _Controller();
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: SizedBox(
                width: 200,
                height: 200,
                child: RemoteControlSurface(
                  controller: controller,
                  sourceSize: source,
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ),
        );
        final listener = tester.widget<Listener>(
          find.descendant(
            of: find.byType(RemoteControlSurface),
            matching: find.byType(Listener),
          ),
        );
        // Includes the exclusive bottom/right content edges and both bars.
        final bars = source.width > source.height
            ? [
                const Offset(100, 0),
                const Offset(100, 49.9),
                const Offset(100, 150),
                const Offset(100, 199),
              ]
            : [
                const Offset(0, 100),
                const Offset(49.9, 100),
                const Offset(150, 100),
                const Offset(199, 100),
              ];
        for (final point in bars) {
          controller.events.clear();
          listener.onPointerDown!(
            PointerDownEvent(
              position: point,
              kind: PointerDeviceKind.mouse,
              buttons: kPrimaryMouseButton,
            ),
          );
          listener.onPointerSignal!(
            PointerScrollEvent(
              position: point,
              scrollDelta: const Offset(0, 120),
            ),
          );
          expect(controller.events, isEmpty);
          listener.onPointerMove!(
            const PointerMoveEvent(
              position: Offset(100, 100),
              buttons: kPrimaryMouseButton,
            ),
          );
          expect(controller.events, ['move:0.5,0.5']);
          listener.onPointerUp!(PointerUpEvent(position: point));
          expect(controller.events, ['move:0.5,0.5']);
        }
        // A new in-image press remains usable after a rejected gesture.
        controller.events.clear();
        listener.onPointerDown!(
          const PointerDownEvent(
            position: Offset(100, 100),
            buttons: kPrimaryMouseButton,
          ),
        );
        expect(controller.events, ['move:0.5,0.5', 'left:true']);
        listener.onPointerMove!(
          PointerMoveEvent(
            position: bars.first,
            buttons: kPrimaryMouseButton | kSecondaryMouseButton,
          ),
        );
        expect(controller.events, ['move:0.5,0.5', 'left:true']);
        listener.onPointerUp!(PointerUpEvent(position: bars.first));
        expect(controller.events.last, 'left:false');
        expect(controller.events, isNot(contains('right:true')));

        controller.events.clear();
        listener.onPointerSignal!(
          const PointerScrollEvent(
            position: Offset(100, 100),
            scrollDelta: Offset(0, 120),
          ),
        );
        expect(controller.events, ['move:0.5,0.5', 'wheel:-120']);
        final corners = source.width > source.height
            ? [
                const Offset(0, 50),
                const Offset(199.9, 50),
                const Offset(0, 149.9),
                const Offset(199.9, 149.9),
              ]
            : [
                const Offset(50, 0),
                const Offset(149.9, 0),
                const Offset(50, 199.9),
                const Offset(149.9, 199.9),
              ];
        for (final point in corners) {
          controller.events.clear();
          listener.onPointerDown!(
            PointerDownEvent(position: point, buttons: kPrimaryMouseButton),
          );
          listener.onPointerUp!(PointerUpEvent(position: point));
          expect(
            controller.events.where((e) => e == 'left:true'),
            hasLength(1),
          );
          expect(
            controller.events.where((e) => e == 'left:false'),
            hasLength(1),
          );
        }
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  }

  testWidgets(
    'cancel and focus loss release once without re-press on drag',
    (tester) async {
      final controller = _Controller();
      await tester.pumpWidget(
        MaterialApp(
          home: RemoteControlSurface(
            controller: controller,
            sourceSize: const Size(800, 600),
            child: const SizedBox.expand(),
          ),
        ),
      );
      final surface = find.byType(RemoteControlSurface);
      final listener = tester.widget<Listener>(
        find.descendant(of: surface, matching: find.byType(Listener)),
      );
      final focus = tester.widget<Focus>(
        find.descendant(of: surface, matching: find.byType(Focus)),
      );
      const point = Offset(400, 300);
      listener.onPointerDown!(
        const PointerDownEvent(position: point, buttons: kPrimaryMouseButton),
      );
      focus.onFocusChange!(false);
      listener.onPointerMove!(
        const PointerMoveEvent(position: point, buttons: kPrimaryMouseButton),
      );
      listener.onPointerUp!(const PointerUpEvent(position: point));
      expect(controller.events.where((e) => e == 'left:true'), hasLength(1));
      expect(controller.events.where((e) => e == 'left:false'), hasLength(1));
      expect(controller.events, contains('release'));
      controller.events.clear();
      listener.onPointerDown!(
        const PointerDownEvent(position: point, buttons: kSecondaryMouseButton),
      );
      listener.onPointerCancel!(const PointerCancelEvent());
      listener.onPointerUp!(const PointerUpEvent(position: point));
      expect(controller.events.where((e) => e == 'right:true'), hasLength(1));
      expect(controller.events.where((e) => e == 'right:false'), hasLength(1));
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
