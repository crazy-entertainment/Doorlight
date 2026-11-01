import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sybl/state/app_state.dart';
import 'package:sybl/theme.dart';
import 'package:sybl/ui/settings_pane.dart';

import 'app_state_test.dart' show FakeJami;

typedef _NodeUpdate = ({int id, List<int> children});

class _SemanticsAuditBinding extends AutomatedTestWidgetsFlutterBinding {
  final _SerializedTreeAudit audit = _SerializedTreeAudit();

  @override
  ui.SemanticsUpdateBuilder createSemanticsUpdateBuilder() =>
      _SemanticsUpdateBuilder(audit);
}

class _SerializedTreeAudit {
  final Map<int, List<int>> _nodes = {};
  final List<List<int>> batches = [];

  void apply(List<_NodeUpdate> updates) {
    if (updates.isEmpty) return;
    for (final update in updates) {
      _nodes[update.id] = update.children;
    }
    final reachable = <int>{};
    void visit(int id) {
      if (!reachable.add(id)) {
        throw StateError('duplicate or cyclic semantics node $id');
      }
      final children = _nodes[id];
      if (children == null) {
        throw StateError('semantics node $id has no serialized parent path');
      }
      for (final child in children) {
        visit(child);
      }
    }

    if (_nodes.containsKey(0)) visit(0);
    final orphaned = updates
        .map((update) => update.id)
        .where((id) => !reachable.contains(id))
        .toSet();
    if (orphaned.isNotEmpty) {
      throw StateError(
        'semantics update serialized unreachable node IDs: $orphaned',
      );
    }
    _nodes.removeWhere((id, _) => !reachable.contains(id));
    batches.add(updates.map((update) => update.id).toList());
  }
}

class _SemanticsUpdateBuilder implements ui.SemanticsUpdateBuilder {
  _SemanticsUpdateBuilder(this.audit);

  final _SerializedTreeAudit audit;
  final ui.SemanticsUpdateBuilder _builder = ui.SemanticsUpdateBuilder();
  final List<_NodeUpdate> _updates = [];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #updateNode) {
      final args = invocation.namedArguments;
      _updates.add((
        id: args[#id] as int,
        children: (args[#childrenInTraversalOrder] as Iterable<int>).toList(),
      ));
      return Function.apply(
        _builder.updateNode,
        invocation.positionalArguments,
        invocation.namedArguments,
      );
    }
    if (invocation.memberName == #build) {
      audit.apply(_updates);
      return Function.apply(_builder.build, invocation.positionalArguments);
    }
    if (invocation.memberName == #updateCustomAction) {
      return Function.apply(
        _builder.updateCustomAction,
        invocation.positionalArguments,
        invocation.namedArguments,
      );
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  final binding = _SemanticsAuditBinding();

  testWidgets(
    'window animation slider semantics stay rooted during dialog updates',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final state = AppState(FakeJami(), await SharedPreferences.getInstance());
      await state.init();
      addTearDown(state.dispose);
      tester.view
        ..devicePixelRatio = 1
        ..physicalSize = const Size(800, 600);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final semantics = tester.ensureSemantics();

      await tester.pumpWidget(
        MaterialApp(
          theme: Warm.theme().copyWith(platform: TargetPlatform.windows),
          home: Scaffold(
            body: SettingsPane(
              state: state,
              onClose: () {},
              onOpenDiagnostics: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final edit = find.byKey(const ValueKey('window-animations-settings'));
      await tester.ensureVisible(edit);
      await tester.pumpAndSettle();

      for (var cycle = 0; cycle < 2; cycle++) {
        await tester.tap(edit);
        await tester.pump();
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);

        final openSlider = find.byKey(const ValueKey('window-open-duration'));
        final openSemantics = tester.getSemantics(openSlider);
        openSemantics.owner!.performAction(
          openSemantics.id,
          ui.SemanticsAction.increase,
        );
        await tester.pump();
        await tester.drag(openSlider, const Offset(28, 0));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(binding.audit.batches, isNotEmpty);

        await tester.tap(find.byKey(const ValueKey('window-animations-done')));
        await tester.pump();
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(tester.takeException(), isNull);
      }
      semantics.dispose();
    },
  );
}
