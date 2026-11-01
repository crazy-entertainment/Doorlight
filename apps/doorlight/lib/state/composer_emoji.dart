import 'package:characters/characters.dart';
import 'package:flutter/services.dart';

import 'conversation_timeline.dart';

const composerEmoji = [
  '😀',
  '😄',
  '😂',
  '🥰',
  '😍',
  '😎',
  '🤔',
  '😴',
  '😭',
  '😡',
  '🥳',
  '😺',
  '😸',
  '😹',
  '😻',
  '😾',
  '❤️',
  '💔',
  '🔥',
  '✨',
  '🎉',
  '👍',
  '👎',
  '👏',
  '🙏',
  '👋',
  '🤝',
  '💪',
  '👀',
  '✅',
  '☕',
  '🌻',
];

/// Expand malformed/platform selections to grapheme boundaries. A collapsed
/// caret inside a ZWJ cluster inserts after it without destroying that cluster.
TextEditingValue? insertComposerEmoji(TextEditingValue value, String emoji) {
  if (!composerEmoji.contains(emoji)) return null;
  final selection = value.selection;
  var start = selection.isValid
      ? selection.start.clamp(0, value.text.length)
      : value.text.length;
  var end = selection.isValid
      ? selection.end.clamp(0, value.text.length)
      : value.text.length;
  var offset = 0;
  for (final grapheme in value.text.characters) {
    final next = offset + grapheme.length;
    if (start > offset && start < next) {
      start = selection.isCollapsed ? next : offset;
    }
    if (end > offset && end < next) end = next;
    offset = next;
  }
  final text = value.text.replaceRange(start, end, emoji);
  if (text.length > TimelineWireContract.maxTextCodeUnits) return null;
  return TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: start + emoji.length),
  );
}
