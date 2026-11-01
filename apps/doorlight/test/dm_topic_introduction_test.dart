import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/file_transfer.dart';

void main() {
  const first = (peerId: 'a', conversationId: 'first');
  const second = (peerId: 'b', conversationId: 'second');

  test('the third completion in one DM inside ten minutes triggers', () {
    var now = DateTime.utc(2026, 8, 6, 12);
    final tracker = DmTopicIntroductionTracker(now: () => now);

    expect(tracker.recordCompleted(first), isFalse);
    now = now.add(const Duration(minutes: 4));
    expect(tracker.recordCompleted(first), isFalse);
    now = now.add(const Duration(minutes: 4));
    expect(tracker.recordCompleted(first), isTrue);
  });

  test('different DMs and completions outside the window do not combine', () {
    var now = DateTime.utc(2026, 8, 6, 12);
    final tracker = DmTopicIntroductionTracker(now: () => now);

    expect(tracker.recordCompleted(first), isFalse);
    expect(tracker.recordCompleted(second), isFalse);
    now = now.add(const Duration(minutes: 11));
    expect(tracker.recordCompleted(first), isFalse);
    expect(tracker.recordCompleted(first), isFalse);
    expect(tracker.recordCompleted(second), isFalse);
  });

  test('tracking stays bounded during long-lived use', () {
    final tracker = DmTopicIntroductionTracker();

    for (
      var index = 0;
      index < DmTopicIntroductionTracker.trackedConversationLimit + 1;
      index++
    ) {
      expect(
        tracker.recordCompleted((peerId: '$index', conversationId: '$index')),
        isFalse,
      );
    }

    expect(tracker.recordCompleted(first), isFalse);
    expect(tracker.recordCompleted(first), isFalse);
    expect(tracker.recordCompleted(first), isTrue);
  });
}
