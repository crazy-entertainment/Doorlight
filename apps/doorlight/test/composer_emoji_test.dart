import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/composer_emoji.dart';
import 'package:sybl/state/conversation_timeline.dart';

void main() {
  test('emoji inserts at the caret and ends the old composing range', () {
    final result = insertComposerEmoji(
      const TextEditingValue(
        text: 'hello',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 5),
      ),
      '😺',
    )!;
    expect(result.text, 'he😺llo');
    expect(result.selection.baseOffset, 4);
    expect(result.composing, TextRange.empty);
  });
  test('a caret inside a joined emoji never splits it', () {
    const joined = '👩🏽‍💻';
    final result = insertComposerEmoji(
      const TextEditingValue(
        text: '${joined}x',
        selection: TextSelection.collapsed(offset: 3),
      ),
      '❤️',
    )!;
    expect(result.text, '$joined❤️x');
  });
  test('partial grapheme selection expands before replacement', () {
    final result = insertComposerEmoji(
      const TextEditingValue(
        text: 'a👩🏽‍💻b',
        selection: TextSelection(baseOffset: 2, extentOffset: 4),
      ),
      '😺',
    )!;
    expect(result.text, 'a😺b');
  });
  test('oversized drafts and arbitrary inserted strings are refused', () {
    final value = TextEditingValue(
      text: 'x' * TimelineWireContract.maxTextCodeUnits,
    );
    expect(insertComposerEmoji(value, '😺'), isNull);
    expect(insertComposerEmoji(TextEditingValue.empty, 'arbitrary'), isNull);
  });
}
