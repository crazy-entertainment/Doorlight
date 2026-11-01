import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sybl/state/app_state.dart';
import 'package:sybl/state/overlay_bridge.dart';
import 'app_state_test.dart' show FakeJami;
import 'overlay_settings_test.dart' show MemoryOverlayStore;

class BridgeState extends AppState {
  BridgeState(super.jami, super.prefs);
  bool allowed = true;
  bool canSend = true;
  int commands = 0;
  int snapshotReads = 0;
  String outcome = 'pending';
  String? commandError;
  Map<String, Object?>? _chatSubmission;
  Map<String, Object?>? get chatSubmission => _chatSubmission;
  set chatSubmission(Map<String, Object?>? value) {
    _chatSubmission = value;
    notifyListeners();
  }

  void invalidateView() => notifyListeners();
  Completer<void>? commandBarrier;
  @override
  bool get appearanceBridgeReady => true;
  @override
  bool get appearanceBridgeWritable => allowed;
  @override
  Map<String, Object?> get widgetOverlaySnapshot {
    snapshotReads++;
    return {
      'chat': {
        'status': 'ready',
        'canSend': canSend,
        'token': 'conversation-A',
        'selected': 'conversation-A',
        'messages': [
          {'author': 'Private name', 'text': 'Private text'},
        ],
        if (chatSubmission != null) 'submission': chatSubmission,
      },
      'voice': {
        'participants': [
          {'name': 'Private name'},
        ],
        'offers': [
          {'id': 'voice-room-token', 'label': 'Private room'},
        ],
      },
    };
  }

  @override
  Future<Map<String, Object?>> handleWidgetOverlayCommand(
    String command,
    Map<String, dynamic> args,
  ) async {
    commands++;
    if (commandError case final error?) throw StateError(error);
    await commandBarrier?.future;
    return {'status': outcome, 'snapshot': widgetOverlaySnapshot};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('syb.l/overlay_bridge');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  Future<(BridgeState, OverlayBridge, MemoryOverlayStore)> boot({
    DateTime Function()? now,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final state = BridgeState(
      FakeJami(),
      await SharedPreferences.getInstance(),
    );
    final store = MemoryOverlayStore();
    final bridge = OverlayBridge(
      state,
      store: store,
      epoch: 'test-epoch',
      now: now,
    );
    messenger.setMockMethodCallHandler(channel, (_) async => true);
    addTearDown(() {
      bridge.dispose();
      state.dispose();
      messenger.setMockMethodCallHandler(channel, null);
    });
    return (state, bridge, store);
  }

  String command(
    OverlayBridge bridge,
    String name,
    Map<String, Object> args, {
    String id = 'request-1',
    String? epoch,
  }) => jsonEncode({
    'v': 1,
    'type': 'command',
    'id': id,
    'epoch': epoch ?? bridge.epoch,
    'command': name,
    'args': args,
  });
  Map<String, dynamic> decode(String frame) =>
      jsonDecode(frame) as Map<String, dynamic>;

  Future<void> input(Map<String, Object> event) =>
      messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('input', {'lease': 1, ...event}),
        ),
        (_) {},
      );

  test(
    'cursor bursts reuse the private projection and state changes invalidate it immediately',
    () async {
      var now = DateTime.utc(2026, 10, 20);
      final (state, bridge, _) = await boot(now: () => now);
      bridge.start();
      await input({'type': 'connection', 'connected': true});
      final initial = state.snapshotReads;
      expect(initial, 1);
      for (var i = 0; i < 12; i++) {
        await input({
          'type': 'cursor',
          'x': i,
          'y': i,
          'eligible': true,
          'mask': 0,
        });
      }
      expect(state.snapshotReads, initial);
      state.invalidateView();
      expect(state.snapshotReads, initial + 1);
      now = now.add(const Duration(milliseconds: 251));
      bridge.snapshot;
      expect(state.snapshotReads, initial + 2);
      state.allowed = false;
      expect((bridge.snapshot['chat'] as Map)['status'], 'locked');
      expect(jsonEncode(bridge.snapshot), isNot(contains('Private')));
      state.allowed = true;
      bridge.snapshot;
      expect(state.snapshotReads, initial + 3);
    },
  );

  for (final status in ['pending', 'unknown']) {
    test(
      'canonical $status blocks quick chat without any transient bridge send',
      () async {
        final (state, bridge, _) = await boot();
        state.chatSubmission = {
          'operationId': 'previous-connection-send',
          'status': status,
        };
        final configurations = <Map>[];
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'configure') {
            configurations.add(call.arguments as Map);
          }
          return true;
        });
        bridge.start();
        await input({'type': 'connection', 'connected': true});
        await bridge.handle(
          command(bridge, 'chat.surface', {
            'token': 'conversation-A',
            'visible': true,
          }),
        );
        expect((bridge.snapshot['input'] as Map)['submission'], isEmpty);
        expect(configurations.last['quickChatAllowed'], false);
        await input({
          'type': 'compose',
          'owner': 'conversation-A',
          'text': 'do not capture',
        });
        await input({
          'type': 'submit',
          'owner': 'conversation-A',
          'text': 'do not duplicate',
        });
        expect(state.commands, 0);
        expect((bridge.snapshot['input'] as Map)['compose'], isEmpty);
        state.chatSubmission = null;
        state.canSend = false;
        state.invalidateView();
        await pumpEventQueue();
        expect(configurations.last['quickChatAllowed'], false);
        state.canSend = true;
        state.invalidateView();
        await pumpEventQueue();
        expect(configurations.last['quickChatAllowed'], true);
      },
    );
  }

  test(
    'hotkey capture cannot create a canonical document before legacy import',
    () async {
      final (_, bridge, store) = await boot();
      var captures = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'capture') captures++;
        return true;
      });
      bridge.start();
      await input({'type': 'connection', 'connected': true});
      final invalidImport = decode(
        await bridge.handle(
          command(bridge, 'settings.import', {
            'revision': 0,
            'values': {'clock.unsupported': true},
          }, id: 'refused-import'),
        ),
      );
      expect(invalidImport['ok'], false);
      final refused = decode(
        await bridge.handle(
          command(bridge, 'input.capture', {'action': 'chat.quick'}),
        ),
      );
      expect(refused['error'], 'unavailable');
      expect(captures, 0);
      await input({
        'type': 'capture',
        'action': 'chat.quick',
        'text': 'Ctrl+Alt+Q',
      });
      expect(bridge.settings.imported, false);
      expect(bridge.settings.values, isEmpty);
      expect(store.document, null);
      store.barrier = Completer<void>();
      final importing = bridge.handle(
        command(bridge, 'settings.import', {
          'revision': 0,
          'values': {'cross.style': 't', 'clock.name': 'Legacy clock'},
        }, id: 'legacy-import'),
      );
      await pumpEventQueue();
      await input({
        'type': 'capture',
        'action': 'chat.quick',
        'text': 'Ctrl+Alt+W',
      });
      expect(bridge.settings.imported, false);
      store.barrier!.complete();
      final imported = decode(await importing);
      expect(imported['ok'], true);
      await input({
        'type': 'capture',
        'action': 'chat.quick',
        'text': 'Ctrl+Alt+Q',
      });
      expect(bridge.settings.values, {
        'cross.style': 't',
        'clock.name': 'Legacy clock',
        'hotkey.chat.quick': 'Ctrl+Alt+Q',
      });
      expect(bridge.settings.revision, 2);
    },
  );

  test(
    'native capture refusal is not acknowledged as a successful command',
    () async {
      final (_, bridge, _) = await boot();
      await bridge.settings.replace({}, expectedRevision: 0, importing: true);
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => call.method != 'capture',
      );
      final refused = decode(
        await bridge.handle(
          command(bridge, 'input.capture', {'action': 'chat.quick'}),
        ),
      );
      expect(refused['error'], 'unavailable');
    },
  );

  test(
    'name privacy includes voice participants and user-defined room labels',
    () async {
      final (state, bridge, _) = await boot();
      expect(jsonEncode(bridge.snapshot['voice']), contains('Private name'));
      await bridge.settings.replace(
        {'chat.names': false},
        expectedRevision: 0,
        importing: true,
      );
      final snapshot = bridge.snapshot;
      expect((snapshot['chat'] as Map)['messages'], [
        {'author': '', 'text': 'Private text'},
      ]);
      final voice = snapshot['voice'] as Map;
      expect(voice['participants'], [
        {'name': ''},
      ]);
      expect(voice['offers'], [
        {'id': 'voice-room-token', 'label': 'Voice chat'},
      ]);
      expect(jsonEncode(voice), isNot(contains('Private')));
      expect(
        jsonEncode(state.widgetOverlaySnapshot['voice']),
        contains('Private room'),
      );
    },
  );

  test(
    'unknown send outcome remains explicitly unknown in an error receipt',
    () async {
      final (state, bridge, _) = await boot();
      state.commandError = 'unknown';
      final receipt = decode(
        await bridge.handle(
          command(bridge, 'chat.send', {
            'token': 'conversation-A',
            'text': 'hello',
          }),
        ),
      );
      expect(receipt['ok'], false);
      expect(receipt['error'], 'unknown');
    },
  );

  test(
    'prompt quick-chat admission follows its later durable journal outcome',
    () async {
      final (state, bridge, _) = await boot();
      state.outcome = 'pending';
      final configurations = <Map>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'configure') {
          configurations.add(call.arguments as Map);
        }
        return true;
      });
      bridge.start();
      await input({'type': 'connection', 'connected': true});
      await bridge.handle(
        command(bridge, 'chat.surface', {
          'token': 'conversation-A',
          'visible': true,
        }),
      );
      await input({
        'type': 'submit',
        'owner': 'conversation-A',
        'text': 'keep until committed',
      });
      final pending = Map<String, Object?>.from(
        (bridge.snapshot['input'] as Map)['submission'] as Map,
      );
      expect(pending['status'], 'pending');
      expect(configurations.last['quickChatAllowed'], false);
      state.chatSubmission = {
        'operationId': 'unrelated-operation',
        'status': 'committed',
      };
      expect((bridge.snapshot['input'] as Map)['submission'], pending);
      state.chatSubmission = {
        'operationId': pending['operationId'],
        'status': 'committed',
      };
      bridge.refresh();
      await pumpEventQueue();
      expect((bridge.snapshot['input'] as Map)['submission'], {
        ...pending,
        'status': 'committed',
      });
      expect(configurations.last['quickChatAllowed'], true);
      state.chatSubmission = {
        'operationId': pending['operationId'],
        'status': 'failedBeforeCommit',
      };
      expect(
        ((bridge.snapshot['input'] as Map)['submission'] as Map)['status'],
        'failedBeforeCommit',
      );
    },
  );

  test(
    'quick chat requires a visible surface lease and expires independently of settings',
    () async {
      SharedPreferences.setMockInitialValues({});
      final state = BridgeState(
        FakeJami(),
        await SharedPreferences.getInstance(),
      );
      var now = DateTime.utc(2026, 10, 20);
      final bridge = OverlayBridge(
        state,
        store: MemoryOverlayStore(),
        epoch: 'surface',
        now: () => now,
      );
      final configurations = <Map>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'configure') {
          configurations.add(call.arguments as Map);
        }
        return true;
      });
      addTearDown(() {
        bridge.dispose();
        state.dispose();
        messenger.setMockMethodCallHandler(channel, null);
      });
      bridge.start();
      await input({'type': 'connection', 'connected': true});
      await pumpEventQueue();
      expect(configurations.last['quickChatAllowed'], false);
      expect(configurations.last['crossHold'], 'off');
      expect(
        (configurations.last['hotkeys'] as Map)['chat.quick'],
        'Ctrl+Alt+C',
      );
      expect(
        decode(
          await bridge.handle(
            command(bridge, 'chat.surface', {
              'token': 'conversation-A',
              'visible': true,
            }),
          ),
        )['ok'],
        true,
      );
      expect(configurations.last['quickChatAllowed'], true);
      now = now.add(const Duration(seconds: 3));
      await bridge.tick();
      expect(configurations.last['quickChatAllowed'], false);
      await bridge.settings.replace({
        'hotkey.chat.quick': '',
      }, expectedRevision: 0);
      await pumpEventQueue();
      expect((configurations.last['hotkeys'] as Map)['chat.quick'], '');
    },
  );

  test(
    'cursor coalescing cannot erase a pending submission or its receipt',
    () async {
      final (state, bridge, _) = await boot();
      state.outcome = 'committed';
      state.commandBarrier = Completer<void>();
      bridge.start();
      await input({'type': 'connection', 'connected': true});
      await bridge.handle(
        command(bridge, 'chat.surface', {
          'token': 'conversation-A',
          'visible': true,
        }),
      );
      await input({
        'type': 'compose',
        'owner': 'conversation-A',
        'text': 'hello',
      });
      final submit = input({
        'type': 'submit',
        'owner': 'conversation-A',
        'text': 'hello',
      });
      await pumpEventQueue();
      final pending = Map<String, dynamic>.from(
        (bridge.snapshot['input'] as Map)['submission'] as Map,
      );
      expect(pending['status'], 'pending');
      await input({
        'type': 'cursor',
        'x': 1,
        'y': 2,
        'eligible': true,
        'mask': 0,
      });
      expect((bridge.snapshot['input'] as Map)['submission'], pending);
      state.commandBarrier!.complete();
      await submit;
      final completed = (bridge.snapshot['input'] as Map)['submission'] as Map;
      expect(completed['operationId'], pending['operationId']);
      expect(completed['status'], 'committed');
      await input({
        'type': 'submit',
        'owner': 'old-conversation',
        'text': 'never send',
      });
      expect(state.commands, 1);
    },
  );

  test(
    'unknown quick-chat outcome blocks native re-engagement and duplicate submission',
    () async {
      final (state, bridge, _) = await boot();
      state.outcome = 'unknown';
      bridge.start();
      await input({'type': 'connection', 'connected': true});
      await input({
        'type': 'submit',
        'owner': 'conversation-A',
        'text': 'invisible',
      });
      expect(state.commands, 0);
      await bridge.handle(
        command(bridge, 'chat.surface', {
          'token': 'conversation-A',
          'visible': true,
        }),
      );
      await input({
        'type': 'submit',
        'owner': 'conversation-A',
        'text': 'hello',
      });
      expect(state.commands, 1);
      final original = (bridge.snapshot['input'] as Map)['submission'];
      await input({
        'type': 'compose',
        'owner': 'conversation-A',
        'text': 'hello',
      });
      await input({
        'type': 'submit',
        'owner': 'conversation-A',
        'text': 'hello',
      });
      expect(state.commands, 1);
      expect((bridge.snapshot['input'] as Map)['submission'], original);
    },
  );

  test(
    'invalid, foreign epoch and stale settings commands make no durable change',
    () async {
      final (_, bridge, store) = await boot();
      expect(
        decode(
          await bridge.handle(
            command(bridge, 'settings.import', {
              'revision': 0,
              'values': <String, Object>{},
            }, epoch: 'old'),
          ),
        )['error'],
        'stale',
      );
      expect(
        decode(
          await bridge.handle(
            command(bridge, 'settings.import', {
              'revision': 2,
              'values': <String, Object>{},
            }),
          ),
        )['error'],
        'stale',
      );
      expect(decode(await bridge.handle('{"v":1}'))['error'], 'invalid');
      expect(store.document, null);
      final accepted = decode(
        await bridge.handle(
          command(bridge, 'settings.import', {
            'revision': 0,
            'values': {'chat.names': false},
          }),
        ),
      );
      expect(accepted['ok'], true);
      expect(
        (accepted['snapshot']['chat']['messages'] as List).single['author'],
        '',
      );
    },
  );

  test('durable commit owns ack and rejects concurrent replacement', () async {
    final (_, bridge, store) = await boot();
    store.barrier = Completer<void>();
    final pending = bridge.handle(
      command(bridge, 'settings.import', {
        'revision': 0,
        'values': {'chat.names': false},
      }),
    );
    await pumpEventQueue();
    expect(bridge.settings.values, isEmpty);
    expect(
      decode(
        await bridge.handle(
          command(bridge, 'settings.replace', {
            'revision': 0,
            'values': <String, Object>{},
          }, id: 'request-2'),
        ),
      )['error'],
      'busy',
    );
    store.barrier!.complete();
    expect(decode(await pending)['ok'], true);
    expect(bridge.settings.revision, 1);
  });

  test(
    'duplicate command is not dispatched twice and cannot replay private snapshots',
    () async {
      final (state, bridge, _) = await boot();
      final frame = command(bridge, 'chat.send', {
        'token': 'conversation-A',
        'text': 'hello',
      });
      final first = decode(await bridge.handle(frame));
      final repeat = decode(await bridge.handle(frame));
      expect(state.commands, 1);
      expect(first['result'], {'status': 'pending'});
      expect(repeat['result'], {'status': 'pending'});
      state.allowed = false;
      final locked = decode(await bridge.handle(frame));
      expect(locked['ok'], false);
      expect(jsonEncode(locked), isNot(contains('Private')));
      expect(locked['snapshot']['chat']['status'], 'locked');
    },
  );

  test(
    'a queued private publication is superseded by lock revocation',
    () async {
      final (state, bridge, _) = await boot();
      final first = Completer<bool>();
      final snapshots = <Map<String, dynamic>>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'publish') return null;
        snapshots.add(decode(call.arguments as String));
        return snapshots.length == 1 ? first.future : true;
      });
      bridge.start();
      await pumpEventQueue();
      state.allowed = false;
      bridge.refresh();
      first.complete(true);
      await pumpEventQueue();
      expect(snapshots.last['chat']['status'], 'locked');
      expect(jsonEncode(snapshots.last), isNot(contains('Private')));
    },
  );
}
