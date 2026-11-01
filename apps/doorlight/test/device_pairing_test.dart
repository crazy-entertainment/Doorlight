import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/state/device_pairing.dart';

final _peer = 'a' * 40, _source = 'b' * 64, _device = 'c' * 64;
final _offer = 'jami-auth://${'d' * 64}/123456/doorlight-v1';
const _document = '{"version":1,"localPrivacy":"prepared"}';

class _PairingJami extends JamiClient {
  final commands = <Map<String, Object?>>[];
  String token = '', owner = '', target = 'reserved-destination';
  bool destination = true;
  String status = 'starting';
  Map<String, dynamic> pending = {'status': 'none'};
  Completer<Map<String, dynamic>>? admission, reading, recoveryRead, discarding;
  Map<String, dynamic>? nextReply;
  String? preparedDocument;
  bool refuseDiscard = false;
  Map<String, dynamic> prepared() => {
    'status': 'prepared',
    'restoreToken': token,
    'accountId': target,
    'jamiId': _peer,
    'enabled': false,
    'announced': false,
    'registration': 'UNREGISTERED',
    'displayName': 'Linked',
    'settingsAlreadyNormalized': true,
    'devicePairing': true,
    'settingsDocument': preparedDocument ?? _document,
  };
  Map<String, dynamic> projection({String? at, bool recovery = false}) {
    final phase = at ?? status;
    final identified = {
      'prepared',
      'confirming',
      'ready',
      'complete',
    }.contains(phase);
    return {
      'flowToken': token,
      'accountId': target,
      'ownerAccountId': owner,
      'operation': 123456,
      'role': destination ? 'destination' : 'source',
      'status': phase,
      'terminal': {'ready', 'complete', 'ended'}.contains(phase),
      'recovery': recovery,
      'uri': phase == 'waiting' ? _offer : '',
      'code': phase == 'codeIssued' ? '12345678' : '',
      'invalidCode': false,
      'peerId': identified ? _peer : '',
      'peerDeviceId': identified ? _source : '',
      'deviceId': identified ? _device : '',
      'error': '',
      if (phase == 'ready') 'preparedIdentity': prepared(),
    };
  }

  Map<String, dynamic> journal({bool acknowledged = false}) => {
    if (acknowledged) ...prepared() else 'status': 'pairing',
    'pairing': projection(at: 'unconfirmed', recovery: true),
  };
  @override
  Future<Map<String, dynamic>> devicePairing({
    required String action,
    required String flowToken,
    String accountId = '',
    String expectedAccountId = '',
    String uri = '',
    String code = '',
    String settingsDocument = '',
    Map<String, String> network = const {},
    bool appearOffline = false,
  }) async {
    commands.add({
      'action': action,
      'flowToken': flowToken,
      'accountId': accountId,
      'owner': expectedAccountId,
      'uri': uri,
      'code': code,
      'document': settingsDocument,
      'network': network,
      'offline': appearOffline,
    });
    if (action == 'begin' || action == 'connect') {
      token = flowToken;
      owner = expectedAccountId;
      destination = action == 'begin';
      if (!destination) target = owner;
      if (admission != null) return admission!.future;
      return projection();
    }
    if (action == 'discard') {
      if (discarding != null) return discarding!.future;
      return {
        'status': refuseDiscard ? 'unconfirmed' : 'discarded',
        'flowToken': token,
        'accountId': target,
      };
    }
    if (action == 'prepare') {
      preparedDocument = settingsDocument;
      status = 'ready';
    }
    if (action == 'read' && reading != null) return reading!.future;
    if (nextReply != null) return nextReply!;
    return projection();
  }

  @override
  Future<Map<String, dynamic>> getPendingIdentityRestore() async =>
      recoveryRead?.future ?? pending;
}

class _Harness {
  final native = _PairingJami();
  (String?, int) owner = (null, 0);
  bool foreground = true,
      guarded = false,
      failPrivacy = false,
      failActivation = false;
  int privacyCalls = 0, activationCalls = 0;
  Completer<void>? privacyGate, activationGate;
  late final DevicePairingController controller = DevicePairingController(
    client: native,
    currentOwner: () => owner,
    foreground: () => foreground,
    guardChanged: (value) => guarded = value,
    pollInterval: const Duration(days: 1),
    preparePrivacy: (target, owns) async {
      privacyCalls++;
      await privacyGate?.future;
      if (!owns() || failPrivacy) throw StateError('synthetic policy refusal');
      expect(target, native.target);
      return _document;
    },
    activateIdentity: (prepared, owns) async {
      activationCalls++;
      await activationGate?.future;
      if (!owns() || failActivation) {
        throw StateError('synthetic activation refusal');
      }
      owner = (prepared['accountId'] as String, owner.$2 + 1);
      controller.reconcile();
    },
  );
  Future<void> ready() async {
    expect(await controller.begin(destination: true), isTrue);
    native.status = 'prepared';
    await controller.refresh();
    expect(controller.snapshot?.status, 'ready');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Harness h;
  setUp(() => h = _Harness());
  tearDown(() => h.controller.dispose());
  test(
    'reserved destination, prepared policy and explicit activation are ordered',
    () async {
      h.privacyGate = Completer<void>();
      expect(
        await h.controller.begin(
          destination: true,
          network: {
            'connectionProfile': 'strict',
            'dhtBootstrap': 'localhost:4222',
          },
          appearOffline: true,
        ),
        isTrue,
      );
      final admission = h.native.commands.single;
      expect(admission['accountId'], '');
      expect(admission['offline'], isTrue);
      expect(admission['network'], {
        'connectionProfile': 'strict',
        'dhtBootstrap': 'localhost:4222',
      });
      expect(
        DevicePairingSnapshot.validToken(admission['flowToken'] as String),
        isTrue,
      );
      expect(h.controller.snapshot?.accountId, h.native.target);
      expect(h.guarded, isTrue);
      h.native.status = 'prepared';
      final preparing = h.controller.refresh();
      await pumpEventQueue();
      expect(h.privacyCalls, 1);
      expect(h.native.commands.where((c) => c['action'] == 'prepare'), isEmpty);
      expect(await h.controller.activate(), isFalse);
      h.privacyGate!.complete();
      await preparing;
      final prepare = h.native.commands.singleWhere(
        (c) => c['action'] == 'prepare',
      );
      expect(prepare['accountId'], h.native.target);
      expect(prepare['flowToken'], admission['flowToken']);
      expect(prepare['document'], _document);
      expect(h.activationCalls, 0);
      expect(h.owner.$1, isNull);
      expect(h.controller.canActivate, isTrue);
      expect(await h.controller.activate(), isTrue);
      expect(h.owner.$1, h.native.target);
      expect(h.controller.snapshot?.status, 'complete');
      expect(h.controller.snapshot?.terminal, isTrue);
      expect(h.controller.hasVisit, isFalse);
      expect(h.guarded, isFalse);
      expect(await h.controller.activate(), isFalse);
    },
  );
  test(
    'failed durable policy never acknowledges or activates destination',
    () async {
      h.failPrivacy = true;
      expect(await h.controller.begin(destination: true), isTrue);
      h.native.status = 'prepared';
      await h.controller.refresh();
      expect(h.native.commands.where((c) => c['action'] == 'prepare'), isEmpty);
      expect(h.activationCalls, 0);
      expect(h.controller.needsRecovery, isTrue);
      expect(h.guarded, isTrue);
      expect(h.native.commands.last['action'], 'retire');
      expect(await h.controller.cancel(), isTrue);
      expect(h.native.commands.last['accountId'], h.native.target);
      expect(h.guarded, isFalse);
    },
  );
  for (final boundary in ['privacy', 'activation', 'admission', 'read']) {
    for (final change in ['lock', 'account', 'cancel']) {
      test('$change retires late $boundary completion', () async {
        if (boundary == 'admission') {
          h.native.admission = Completer<Map<String, dynamic>>();
        }
        Future<Object?> operation;
        if (boundary == 'admission') {
          operation = h.controller.begin(destination: true);
        } else {
          if (boundary == 'activation') {
            await h.ready();
            h.activationGate = Completer<void>();
            operation = h.controller.activate();
          } else {
            await h.controller.begin(destination: true);
            if (boundary == 'privacy') {
              h.privacyGate = Completer<void>();
              h.native.status = 'prepared';
            } else {
              h.native.reading = Completer<Map<String, dynamic>>();
            }
            operation = h.controller.refresh();
          }
        }
        await pumpEventQueue();
        if (change == 'lock') h.foreground = false;
        if (change == 'account') h.owner = ('replacement', 2);
        if (change == 'cancel') {
          expect(await h.controller.cancel(), isFalse);
        } else {
          h.controller.reconcile();
        }
        h.native.admission?.complete(h.native.projection(at: 'waiting'));
        h.native.reading?.complete(h.native.projection(at: 'code'));
        h.privacyGate?.complete();
        h.activationGate?.complete();
        await operation;
        expect(h.controller.needsRecovery, isTrue);
        expect(h.controller.canActivate, isFalse);
        expect(h.controller.snapshot?.uri ?? '', isEmpty);
        expect(h.controller.snapshot?.code ?? '', isEmpty);
        expect(h.owner.$1, isNot(h.native.target));
        expect(
          h.native.commands.where((c) => c['action'] == 'retire'),
          hasLength(1),
        );
      });
    }
  }
  test(
    'source approval and code issuance do not claim destination activation',
    () async {
      h.owner = ('source-account', 1);
      h.native.status = 'connecting';
      expect(await h.controller.begin(destination: false, uri: _offer), isTrue);
      h.native.status = 'consent';
      await h.controller.refresh();
      h.native.status = 'codeIssued';
      await h.controller.approve();
      expect(h.controller.snapshot?.code, '12345678');
      expect(h.native.commands.last['action'], 'approve');
      h.native.status = 'complete';
      await h.controller.refresh();
      expect(h.controller.canActivate, isFalse);
      expect(h.activationCalls, 0);
      expect(h.controller.snapshot?.terminal, isTrue);
      expect(h.controller.snapshot?.code, isEmpty);
      expect(await h.controller.cancel(), isTrue);
      expect(h.native.commands.where((c) => c['action'] == 'discard'), isEmpty);
      expect(h.owner.$1, 'source-account');
    },
  );
  test('a workhorse identity cannot be used as a destination', () async {
    h.owner = ('valuable-existing-account', 1);
    expect(await h.controller.begin(destination: true), isFalse);
    expect(h.native.commands, isEmpty);
    expect(h.owner.$1, 'valuable-existing-account');
  });
  test(
    'disabled source and incompatible offer cannot start a live link',
    () async {
      h.owner = ('source-account', 1);
      expect(
        await h.controller.begin(
          destination: false,
          uri: _offer,
          appearOffline: true,
        ),
        isFalse,
      );
      expect(
        await h.controller.begin(destination: false, uri: 'jami-auth://legacy'),
        isFalse,
      );
      expect(h.native.commands, isEmpty);
    },
  );
  test(
    'wrong code state retains native attempt authority and exhaustion is terminal',
    () async {
      await h.controller.begin(destination: true);
      h.native.status = 'code';
      await h.controller.refresh();
      final before = h.native.commands.length;
      await h.controller.submitCode('123');
      expect(h.native.commands.length, before);
      h.native.nextReply = {...h.native.projection(), 'invalidCode': true};
      await h.controller.submitCode('87654321');
      expect(h.controller.snapshot?.invalidCode, isTrue);
      expect(h.controller.canActivate, isFalse);
      h.native.nextReply = {
        ...h.native.projection(at: 'ended'),
        'error': 'auth_error',
      };
      await h.controller.submitCode('87654321');
      expect(h.controller.snapshot?.status, 'ended');
      final ended = h.native.commands.length;
      await h.controller.submitCode('12345678');
      await h.controller.refresh();
      expect(h.native.commands.length, ended);
      expect(h.activationCalls, 0);
    },
  );
  test('native ready cannot bypass application privacy preparation', () async {
    await h.controller.begin(destination: true);
    h.native.status = 'ready';
    await h.controller.refresh();
    expect(h.controller.needsRecovery, isTrue);
    expect(h.controller.canActivate, isFalse);
    expect(h.privacyCalls, 0);
    expect(h.activationCalls, 0);
  });
  test(
    'cleanup is not confirmed by a retired or failed native reply',
    () async {
      await h.controller.begin(destination: true);
      h.native.refuseDiscard = true;
      expect(await h.controller.cancel(), isFalse);
      expect(h.controller.hasVisit, isTrue);
      expect(h.guarded, isTrue);
      h.native.refuseDiscard = false;
      expect(await h.controller.cancel(), isTrue);
      expect(h.controller.hasVisit, isFalse);
      expect(h.guarded, isFalse);
    },
  );
  test(
    'acknowledged journal requires explicit activation after restart',
    () async {
      h.native.token = 'e' * 64;
      expect(
        h.controller.restoreFromJournal(h.native.journal(acknowledged: true)),
        isTrue,
      );
      expect(h.controller.canActivate, isTrue);
      expect(h.activationCalls, 0);
      expect(h.owner.$1, isNull);
      expect(await h.controller.activate(), isTrue);
      expect(h.controller.snapshot?.terminal, isTrue);
      expect(h.owner.$1, h.native.target);
    },
  );
  test('interrupted unacknowledged journal cannot guess adoption', () async {
    h.native.token = 'e' * 64;
    expect(h.controller.restoreFromJournal(h.native.journal()), isTrue);
    expect(h.controller.canActivate, isFalse);
    expect(await h.controller.activate(), isFalse);
    expect(h.native.commands, isEmpty);
    expect(await h.controller.cancel(), isTrue);
    expect(h.native.commands.last['accountId'], 'reserved-destination');
  });
  test(
    'same-process retirement cannot reacquire activation from its journal',
    () async {
      await h.ready();
      h.controller.retire();
      h.native.pending = h.native.journal(acknowledged: true);
      await h.controller.recover();
      expect(h.controller.canActivate, isFalse);
      expect(await h.controller.activate(), isFalse);
      expect(h.activationCalls, 0);
    },
  );
  for (final change in ['lock', 'account', 'dispose']) {
    test('late journal read cannot cross $change', () async {
      h.native.token = 'e' * 64;
      h.native.recoveryRead = Completer<Map<String, dynamic>>();
      final recovery = h.controller.recover();
      await pumpEventQueue();
      if (change == 'lock') h.foreground = false;
      if (change == 'account') h.owner = ('replacement', 1);
      if (change == 'dispose') h.controller.dispose();
      h.controller.reconcile();
      h.native.recoveryRead!.complete(h.native.journal(acknowledged: true));
      await recovery;
      expect(h.controller.hasVisit, isFalse);
      expect(h.controller.canActivate, isFalse);
      expect(h.activationCalls, 0);
    });
  }
  test(
    'different operation or reservation never replaces an existing journal owner',
    () async {
      await h.controller.begin(destination: true);
      final original = h.native.projection();
      h.native.nextReply = {...original, 'accountId': 'unrelated'};
      await h.controller.refresh();
      expect(h.controller.snapshot?.accountId, h.native.target);
      expect(h.controller.needsRecovery, isTrue);
      final pending = h.native.journal(acknowledged: true);
      pending['pairing'] = {
        ...pending['pairing'] as Map,
        'flowToken': 'f' * 64,
      };
      expect(
        () => h.controller.restoreFromJournal(pending),
        throwsFormatException,
      );
      expect(h.controller.snapshot?.accountId, h.native.target);
    },
  );
}
