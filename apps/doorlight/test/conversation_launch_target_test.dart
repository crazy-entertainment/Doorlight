import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/core/jami.dart';

void main() {
  const peer = '1111111111111111111111111111111111111111';

  test('call notification action keeps its explicit start-call intent', () {
    final target = ConversationLaunchTarget.tryParse({
      'ownerKey': peer,
      'conversationId': 'conversation-one',
      'topicId': 'main',
      'startCall': true,
    });

    expect(target, isNotNull);
    expect(target!.startCall, isTrue);
  });

  test('ordinary notification launch does not start a call', () {
    final target = ConversationLaunchTarget.tryParse({
      'ownerKey': peer,
      'conversationId': 'conversation-one',
      'topicId': 'main',
    });

    expect(target, isNotNull);
    expect(target!.startCall, isFalse);
  });
}
