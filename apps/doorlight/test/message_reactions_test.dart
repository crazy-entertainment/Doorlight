import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/message_reactions.dart';

void main() {
  final message = 'a' * 40;
  final me = 'b' * 40;
  final friend = 'c' * 40;
  Map<String, Object> reaction(
    String id,
    String author, [
    String emoji = '👍',
  ]) => {'commitId': id * 40, 'authorId': author, 'emoji': emoji};
  MessageReactions? parse(
    List<Object> entries, {
    bool complete = true,
    String? target,
  }) => MessageReactions.fromWire({
    'messageId': target ?? message,
    'entries': entries,
    'complete': complete,
  }, messageId: message);

  test('reaction changes distinguish additions from removals', () {
    final added = ReactionChange.fromWire({
      'messageId': message,
      'reaction': reaction('1', me),
    })!;
    expect(added.messageId, message);
    expect(added.added!.commitId, '1' * 40);
    expect(added.removedId, isNull);
    final removed = ReactionChange.fromWire({
      'messageId': message,
      'removedId': '1' * 40,
    })!;
    expect(removed.messageId, message);
    expect(removed.added, isNull);
    expect(removed.removedId, '1' * 40);
  });

  test('ambiguous and malformed reaction changes are rejected', () {
    for (final value in <Object?>[
      null,
      'invalid',
      {'messageId': 'invalid', 'removedId': '1' * 40},
      {'messageId': message},
      {
        'messageId': message,
        'reaction': reaction('1', me),
        'removedId': '2' * 40,
      },
      {'messageId': message, 'reaction': reaction('a', me)},
      {'messageId': message, 'reaction': reaction('1', 'invalid')},
      {'messageId': message, 'removedId': message},
      {'messageId': message, 'removedId': 'invalid'},
    ]) {
      expect(ReactionChange.fromWire(value), isNull, reason: '$value');
    }
  });

  test('counts people and retains exact own commits for removal', () {
    final own = reaction('1', me);
    final value = parse([
      own,
      own,
      reaction('2', me),
      reaction('3', friend),
      reaction('4', me, '❤️'),
    ])!;
    expect(value.count('👍'), 2);
    expect(value.count('❤️'), 1);
    expect(value.removalCommitIds(me, '👍'), ['1' * 40, '2' * 40]);
    expect(value.removalCommitIds(friend, '👍'), ['3' * 40]);
    expect(value.removalCommitIds(me, '😢'), isEmpty);
    expect(() => value.entries.clear(), throwsUnsupportedError);
  });

  test(
    'rejects cross-message projections and conflicting or malformed commits',
    () {
      expect(parse([reaction('1', me)], target: 'd' * 40), isNull);
      expect(parse([reaction('a', me)]), isNull);
      expect(parse([reaction('1', me), reaction('1', friend)]), isNull);
      expect(parse([reaction('1', me), reaction('1', me, '❤️')]), isNull);
      expect(parse([reaction('1', 'not-authenticated')]), isNull);
      expect(parse([reaction('1', me, 'peer-supplied text')]), isNull);
      expect(
        parse(List.filled(ReactionWire.maximumEntries + 1, reaction('1', me))),
        isNull,
      );
    },
  );

  test('incomplete history never supplies a full-removal claim', () {
    final value = parse([reaction('1', me)], complete: false)!;
    expect(value.count('👍'), 1);
    expect(value.complete, isFalse);
    expect(value.removalCommitIds(me, '👍'), isNull);
    expect(
      MessageReactions.fromWire(null, messageId: message),
      MessageReactions.empty,
    );
  });

  test('snapshot equality ignores native vector order', () {
    expect(
      parse([reaction('1', me), reaction('2', friend)]),
      parse([reaction('2', friend), reaction('1', me)]),
    );
  });
}
