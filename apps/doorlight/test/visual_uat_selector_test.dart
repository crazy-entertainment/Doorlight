import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../test_driver/visual_uat.dart';

void main() {
  test('UAT call guard rejects replacement legs, changed endpoints and occupied slots', () {
    final leg = {'id': 'call1', 'peerId': 'peer', 'direction': 'outgoing'};
    final state = <String, dynamic>{'account': 'account', 'jamiId': 'identity', 'call': leg, 'groupCallActive': false, 'placingCall': false};
    validateUatCallGuard(state, state);
    for (final patch in [
      {'account': 'other'}, {'jamiId': 'other'}, {'groupCallActive': true},
      {'call': {...leg, 'id': 'call2'}}, {'call': {...leg, 'peerId': 'other'}},
      {'call': {...leg, 'direction': 'incoming'}}, {'call': null},
    ]) {
      expect(() => validateUatCallGuard(state, {...state, ...patch}), throwsStateError);
    }
    final idle = {...state, 'call': null};
    validateUatCallGuard(idle, idle);
    expect(() => validateUatCallGuard(idle, state), throwsStateError);
    expect(() => validateUatCallGuard(idle, {...idle, 'placingCall': true}), throwsStateError);
  });
  testWidgets('UAT observes live composer values without exposing obscured fields', (tester) async {
    final draft = TextEditingController(text: 'Draft');
    final secret = TextEditingController(text: 'private passphrase');
    addTearDown(draft.dispose);
    addTearDown(secret.dispose);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Column(children: [
      TextField(key: const ValueKey('composer'), controller: draft),
      TextField(key: const ValueKey('secret'), controller: secret, obscureText: true),
    ]))));
    Map<String, dynamic> observe(String key) => uatEditableState(resolveUatTarget({'key': key}));
    expect(observe('composer')['value'], 'Draft');
    await tester.enterText(find.byKey(const ValueKey('composer')), 'Updated draft');
    expect(observe('composer')['value'], 'Updated draft');
    expect(observe('composer')['focused'], isTrue);
    expect(observe('secret').containsKey('value'), isFalse);
    expect(observe('secret')['obscured'], isTrue);
    for (final element in find.byType(EditableText).evaluate()) {
      if ((element.widget as EditableText).obscureText) {
        expect(uatEditableState(element).containsKey('value'), isFalse);
      }
    }
  });

  testWidgets('UAT finds selectable message text without inline widget placeholders', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Column(children: [
      SelectableText('Plain message'),
      SelectableText.rich(TextSpan(children: [TextSpan(text: 'Received message'), WidgetSpan(child: Text('12:34'))])),
    ])));
    expect(resolveUatTarget({'text': 'Plain message'}).widget, isA<SelectableText>());
    expect(resolveUatTarget({'text': 'Received message'}).widget, isA<SelectableText>());
    expect(() => resolveUatTarget({'text': 'Received message\uFFFC'}), throwsStateError);
  });

  testWidgets('UAT tooltip targets remain unique, scoped and visible', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Column(children: [
      SizedBox(key: const ValueKey('first'), child: IconButton(tooltip: 'Compact', onPressed: () {}, icon: const Icon(Icons.close))),
      SizedBox(key: const ValueKey('second'), child: IconButton(tooltip: 'Compact', onPressed: () {}, icon: const Icon(Icons.close))),
      Offstage(child: IconButton(tooltip: 'Expand', onPressed: () {}, icon: const Icon(Icons.close))),
    ])));
    expect(() => resolveUatTarget({'tooltip': 'Compact'}), throwsStateError);
    expect(resolveUatTarget({'tooltip': 'Compact', 'within': 'second'}).widget, isA<IconButton>());
    expect(() => resolveUatTarget({'tooltip': 'Expand'}), throwsStateError);
    expect(() => resolveUatTarget({'tooltip': 'Compact', 'key': 'first'}), throwsStateError);
  });

  testWidgets('UAT selectors refuse duplicate labels and select the exact scope', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Column(children: [
      SizedBox(key: ValueKey('peer-a'), child: Text('Accept')),
      SizedBox(key: ValueKey('peer-b'), child: Text('Accept')),
    ])));
    expect(() => resolveUatTarget({'text': 'Accept'}), throwsStateError);
    final target = resolveUatTarget({'text': 'Accept', 'within': 'peer-b'});
    expect(target.widget, isA<Text>());
    expect(() => resolveUatTarget({'text': 'Accept', 'within': 'missing'}), throwsStateError);
    expect(() => resolveUatTarget({'key': 'peer-a', 'text': 'Accept'}), throwsStateError);
  });

  testWidgets('UAT inspection excludes offstage controls', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Column(children: [
      Offstage(child: Text('Hidden', key: ValueKey('hidden'))),
      Text('Visible', key: ValueKey('visible')),
    ])));
    expect(() => resolveUatTarget({'key': 'hidden'}), throwsStateError);
    expect(resolveUatTarget({'key': 'visible'}).widget, isA<Text>());
  });

  testWidgets('UAT inspection excludes children outside a scroll clip', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Align(alignment: Alignment.topLeft,
      child: SizedBox(width: 200, height: 80, child: SingleChildScrollView(child: Column(children: [
        const SizedBox(height: 120),
        const Text('Below viewport', key: ValueKey('clipped')),
      ]))),
    )));
    expect(() => resolveUatTarget({'key': 'clipped'}), throwsStateError);
  });
}
