import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/core/jami.dart';
import 'package:sybl/state/file_transfer.dart';

const _directPeer = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

class _FileJami extends JamiClient {
  final Queue<Completer<int>> loadReplies = Queue<Completer<int>>();
  Completer<bool>? acceptReply;
  Completer<bool>? cancelReply;
  bool throwCancel = false;
  bool fileDecisionResult = true;
  bool throwFileDecision = false;
  int fileInfoCalls = 0;
  Map<String, dynamic> fileInfoReply = const {};
  final Queue<Completer<Map<String, dynamic>>> pendingFileInfo = Queue();
  final Completer<void> thumbnailSent = Completer<void>();
  final List<
    ({String peerId, String conversationId, String fileId, Uint8List png})
  >
  sentThumbnails = [];
  final List<({String peerId, String conversationId, String fileId})>
  sentDeclines = [];
  final Completer<String?> pickedFile = Completer<String?>();
  final List<
    ({String peerId, String conversationId, String path, String topicId})
  >
  sentFiles = [];

  @override
  Future<String?> pickFile({
    String mimeType = '*/*',
    int maxBytes = JamiClient.maxPickedFileBytes,
  }) => pickedFile.future;

  @override
  Future<bool> sendFile(
    String peerJamiId,
    String conversationId,
    String path, {
    String? name,
    String topicId = '',
  }) async {
    sentFiles.add((
      peerId: peerJamiId,
      conversationId: conversationId,
      path: path,
      topicId: topicId,
    ));
    return true;
  }

  @override
  Future<int> loadFolder(
    String peerJamiId,
    String conversationId,
    int keepLast,
  ) {
    final reply = Completer<int>();
    loadReplies.add(reply);
    return reply.future;
  }

  @override
  Future<bool> acceptFile(
    String peerJamiId,
    String conversationId,
    String interactionId,
    String fileId,
    String name, {
    int maxBytes = 0,
    String attemptId = '',
  }) {
    final reply = Completer<bool>();
    acceptReply = reply;
    return reply.future;
  }

  @override
  Future<Map<String, dynamic>> fileInfo(
    String peerJamiId,
    String conversationId,
    String fileId,
  ) async {
    fileInfoCalls += 1;
    if (pendingFileInfo.isNotEmpty) return pendingFileInfo.removeFirst().future;
    return fileInfoReply;
  }

  @override
  Future<bool> cancelFile(
    String peerJamiId,
    String conversationId,
    String fileId, {
    String attemptId = '',
  }) {
    if (throwCancel) throw StateError('cancel failed');
    final reply = Completer<bool>();
    cancelReply = reply;
    return reply.future;
  }

  @override
  Future<bool> sendFileThumbnail(
    String peerJamiId,
    String conversationId,
    String fileId,
    Uint8List png,
  ) async {
    sentThumbnails.add((
      peerId: peerJamiId,
      conversationId: conversationId,
      fileId: fileId,
      png: Uint8List.fromList(png),
    ));
    if (!thumbnailSent.isCompleted) thumbnailSent.complete();
    return true;
  }

  @override
  Future<bool> sendFileDeclined(
    String peerJamiId,
    String conversationId,
    String fileId,
  ) async {
    sentDeclines.add((
      peerId: peerJamiId,
      conversationId: conversationId,
      fileId: fileId,
    ));
    if (throwFileDecision) throw StateError('decision failed');
    return fileDecisionResult;
  }
}

FileTransferController _controller(
  _FileJami jami, {
  Map<String, String> conversations = const {'peer-a': 'conv-a'},
  void Function(FileXfer transfer)? onCompletedTransfer,
}) => FileTransferController(
  jami: jami,
  accountId: () => 'account-a',
  ownsConversation: (peerId, conversationId) =>
      conversations[peerId] == conversationId,
  isOffline: () => false,
  maxIncomingFileBytes: () => 0,
  log: (_) {},
  onCompletedTransfer: onCompletedTransfer,
  pollInterval: const Duration(milliseconds: 1),
);

JamiEvent _incoming({
  String accountId = 'account-a',
  String peerId = 'peer-a',
  String conversationId = 'conv-a',
  String fileId = 'file-a',
  String authorId = 'peer-a',
  String? name,
  String topicId = 'main',
  bool topicTagged = false,
}) => JamiEvent('incomingFile', {
  'accountId': accountId,
  'peerJamiId': peerId,
  'conversationId': conversationId,
  'fileId': fileId,
  'interactionId': 'interaction-$fileId',
  'name': name ?? '$fileId.txt',
  'size': 12,
  'authorId': authorId,
  'topicId': topicId,
  'topicTagged': topicTagged,
});

Future<void> _accept(_FileJami jami, FileTransferController controller) async {
  final pending = controller.acceptFile(controller.transfers.values.single);
  jami.acceptReply!.complete(true);
  await pending;
}

void main() {
  test(
    'outgoing publication cannot issue a receive-attempt cancellation',
    () async {
      final jami = _FileJami();
      final controller = _controller(jami);
      addTearDown(controller.dispose);
      controller.handleEvent(
        JamiEvent('fileProgress', {
          ..._incoming().data,
          'outgoing': true,
          'status': 'ongoing',
          'authorId': 'account-a',
        }),
      );
      final transfer = controller.transfers.values.single;
      expect(transfer.outgoing, isTrue);
      await controller.declineFile(transfer);
      expect(jami.cancelReply, isNull);
      expect(jami.sentDeclines, isEmpty);
      expect(transfer.status, XferStatus.ongoing);
    },
  );

  test(
    'group receive progress and completion retain the canonical room',
    () async {
      final jami = _FileJami();
      final controller = _controller(
        jami,
        conversations: const {'group:conv-a': 'conv-a'},
      );
      addTearDown(controller.dispose);
      final offer = {
        ..._incoming(peerId: 'group:conv-a').data,
        'roomId': 'games',
      };
      controller.handleEvent(JamiEvent('incomingFile', offer));
      final transfer = controller.transfers.values.single;
      expect(transfer.roomId, 'games');
      await _accept(jami, controller);
      final progress = {
        ...offer,
        'attemptId': transfer.attemptId,
        'status': 'finished',
        'total': 12,
        'transferred': 12,
        'outgoing': false,
      };
      controller.handleEvent(
        JamiEvent('fileProgress', {...progress, 'roomId': 'general'}),
      );
      expect(transfer.status, XferStatus.ongoing);
      controller.handleEvent(JamiEvent('fileProgress', progress));
      expect(transfer.status, XferStatus.finished);
      expect(controller.folder.values.single.roomId, 'games');
      controller.handleEvent(
        JamiEvent('folderFile', {...offer, 'roomId': '../outside'}),
      );
      expect(controller.folder.values.single.roomId, 'games');
    },
  );

  test('retired accept completion cannot unlock a replacement start', () async {
    final jami = _FileJami();
    final controller = _controller(jami);
    addTearDown(controller.dispose);
    controller.handleEvent(_incoming());
    final first = controller.acceptFile(controller.transfers.values.single);
    final firstReply = jami.acceptReply!;
    controller.retirePeer('peer-a');
    controller.handleEvent(_incoming());
    final replacement = controller.transfers.values.single;
    final second = controller.acceptFile(replacement);
    final secondReply = jami.acceptReply!;
    final attempt = replacement.attemptId;
    firstReply.complete(true);
    await first;
    replacement.status =
        XferStatus.error; // native terminal event beat the second method reply
    await controller.acceptFile(replacement);
    expect(jami.acceptReply, same(secondReply));
    expect(replacement.attemptId, attempt);
    secondReply.complete(true);
    await second;
  });

  test(
    'accepting an already active receive preserves its native attempt',
    () async {
      final jami = _FileJami();
      final controller = _controller(jami);
      addTearDown(controller.dispose);
      controller.handleEvent(_incoming());
      await _accept(jami, controller);
      final transfer = controller.transfers.values.single;
      final attempt = transfer.attemptId;
      final reply = jami.acceptReply;
      await controller.acceptFile(transfer);
      expect(jami.acceptReply, same(reply));
      expect(transfer.attemptId, attempt);
      expect(transfer.status, XferStatus.ongoing);
    },
  );

  test(
    'late or unowned receive callbacks cannot finish a retried transfer',
    () async {
      final jami = _FileJami();
      final controller = _controller(jami);
      addTearDown(controller.dispose);
      controller.handleEvent(_incoming());
      await _accept(jami, controller);
      final transfer = controller.transfers.values.single;
      final oldAttempt = transfer.attemptId;
      JamiEvent progress(String attempt, String status) =>
          JamiEvent('fileProgress', {
            'accountId': 'account-a',
            'peerJamiId': 'peer-a',
            'conversationId': 'conv-a',
            'fileId': 'file-a',
            'interactionId': 'interaction-file-a',
            'name': 'file-a.txt',
            'authorId': 'peer-a',
            'outgoing': false,
            'attemptId': attempt,
            'status': status,
            'total': 12,
            'transferred': 12,
            'topicId': 'main',
            'topicTagged': false,
          });
      controller.handleEvent(progress(oldAttempt, 'error'));
      expect(transfer.status, XferStatus.error);
      await _accept(jami, controller);
      expect(transfer.attemptId, isNot(oldAttempt));
      controller.handleEvent(progress('', 'finished'));
      controller.handleEvent(progress(oldAttempt, 'finished'));
      expect(transfer.status, XferStatus.ongoing);
      controller.handleEvent(progress(transfer.attemptId, 'finished'));
      expect(transfer.status, XferStatus.finished);
    },
  );

  for (final size in [0, 12]) {
    testWidgets('native receipt recovers missed completion for $size bytes', (
      tester,
    ) async {
      final jami = _FileJami();
      final completed = <FileXfer>[];
      final controller = _controller(jami, onCompletedTransfer: completed.add);
      addTearDown(controller.dispose);
      controller.handleEvent(_incoming());
      await _accept(jami, controller);
      await tester.pump();
      jami.fileInfoReply = {
        'completed': true,
        'path': '/verified/seed',
        'total': size,
        'transferred': size,
      };
      controller.handleEvent(
        JamiEvent('fileProgress', {
          'accountId': 'account-a',
          'peerJamiId': 'peer-a',
          'conversationId': 'conv-a',
          'fileId': 'file-a',
          'interactionId': 'interaction-file-a',
          'name': 'file-a.txt',
          'authorId': 'peer-a',
          'attemptId': controller.transfers.values.single.attemptId,
          'status': 'ongoing',
          'outgoing': false,
          'total': size,
          'transferred': size,
          'topicId': 'main',
          'topicTagged': false,
        }),
      );
      await tester.pump(const Duration(milliseconds: 2));
      expect(controller.transfers.values.single.status, XferStatus.finished);
      expect(controller.transfers.values.single.path, '/verified/seed');
      expect(controller.folder.values.single.downloaded, isTrue);
      expect(completed, hasLength(1));
      await tester.pump(const Duration(milliseconds: 10));
      expect(completed, hasLength(1));
    });
  }

  testWidgets(
    'full byte progress cannot preempt final hash or cancellation evidence',
    (tester) async {
      final jami = _FileJami()
        ..fileInfoReply = {
          'total': 12,
          'transferred': 12,
          'path': '/synthetic/receiving.tmp',
        };
      final completed = <FileXfer>[];
      final controller = _controller(jami, onCompletedTransfer: completed.add);
      addTearDown(controller.dispose);
      controller.handleEvent(_incoming());
      await _accept(jami, controller);
      Map<String, Object?> progress(String status) => {
        'accountId': 'account-a',
        'peerJamiId': 'peer-a',
        'conversationId': 'conv-a',
        'fileId': 'file-a',
        'interactionId': 'interaction-file-a',
        'name': 'file-a.txt',
        'authorId': 'peer-a',
        'attemptId': controller.transfers.values.single.attemptId,
        'status': status,
        'outgoing': false,
        'total': 12,
        'transferred': 12,
        'topicId': 'main',
        'topicTagged': false,
      };
      controller.handleEvent(JamiEvent('fileProgress', progress('ongoing')));
      await tester.pump(const Duration(milliseconds: 2));
      expect(jami.fileInfoCalls, greaterThan(0));
      expect(controller.transfers.values.single.status, XferStatus.ongoing);
      expect(completed, isEmpty);
      expect(controller.transfers.values.single.path, isNull);
      controller.handleEvent(JamiEvent('fileProgress', progress('error')));
      expect(controller.transfers.values.single.status, XferStatus.error);
      expect(completed, isEmpty);
    },
  );

  for (final status in ['ongoing', 'canceling', 'finished']) {
    testWidgets(
      'folder projections do not turn $status progress into availability',
      (tester) async {
        final jami = _FileJami();
        final controller = _controller(jami);
        addTearDown(controller.dispose);
        const owner = (peerId: 'peer-a', conversationId: 'conv-a');
        final row = <String, Object>{
          'accountId': 'account-a',
          'peerJamiId': owner.peerId,
          'conversationId': owner.conversationId,
          'fileId': 'file-a',
          'interactionId': 'interaction-file-a',
          'name': 'file-a.txt',
          'size': 12,
          'authorId': 'peer-a',
          'outgoing': false,
          'downloaded': false,
          'topicId': 'main',
          'topicTagged': false,
        };
        controller.handleEvent(_incoming());
        await _accept(jami, controller);
        controller.handleEvent(
          JamiEvent('fileProgress', {
            ...row,
            'attemptId': controller.transfers.values.single.attemptId,
            'status': 'ongoing',
          }),
        );
        if (status == 'canceling') {
          unawaited(controller.declineFile(controller.transfers.values.single));
        } else if (status == 'finished') {
          controller.handleEvent(
            JamiEvent('fileProgress', {
              ...row,
              'attemptId': controller.transfers.values.single.attemptId,
              'status': 'finished',
            }),
          );
        }
        controller.handleEvent(JamiEvent('folderFile', row));
        controller.handleEvent(JamiEvent('folderFile', row));
        expect(
          controller.folder.values.single.downloaded,
          status == 'finished',
        );
        controller.loadFolder(owner, keepLast: 200);
        jami.loadReplies.removeFirst().complete(123);
        await tester.pump();
        controller.handleEvent(
          JamiEvent('folderSnapshot', {
            ...row,
            'loadId': 123,
            'files': [row],
          }),
        );
        expect(
          controller.folder.values.single.downloaded,
          status == 'finished',
        );
        controller.dispose();
      },
    );
  }

  testWidgets('an old poll cannot release a replacement query busy guard', (
    tester,
  ) async {
    final jami = _FileJami();
    final old = Completer<Map<String, dynamic>>();
    final replacement = Completer<Map<String, dynamic>>();
    final controller = _controller(jami);
    addTearDown(controller.dispose);
    Future<void> receive(Completer<Map<String, dynamic>> reply) async {
      controller.handleEvent(_incoming());
      await _accept(jami, controller);
      await tester.pump(); // Finish the separate preview-path query.
      jami.pendingFileInfo.add(reply);
      controller.handleEvent(
        JamiEvent('fileProgress', {
          'accountId': 'account-a',
          'peerJamiId': 'peer-a',
          'conversationId': 'conv-a',
          'fileId': 'file-a',
          'interactionId': 'interaction-file-a',
          'name': 'file-a.txt',
          'authorId': 'peer-a',
          'outgoing': false,
          'attemptId': controller.transfers.values.single.attemptId,
          'status': 'ongoing',
        }),
      );
    }

    await receive(old);
    await tester.pump(const Duration(milliseconds: 2));
    expect(jami.fileInfoCalls, 2);
    controller.retirePeer('peer-a');
    await receive(replacement);
    await tester.pump(const Duration(milliseconds: 2));
    expect(jami.fileInfoCalls, 4);
    old.complete({'transferred': 11, 'total': 12, 'path': 'old-owner'});
    await tester.pump(const Duration(milliseconds: 5));
    expect(jami.fileInfoCalls, 4);
    expect(controller.transfers.values.single.transferred, 0);
    replacement.complete({
      'transferred': 4,
      'total': 12,
      'path': 'current-owner',
    });
    await tester.pump();
    expect(controller.transfers.values.single.transferred, 4);
    controller.dispose();
  });

  test(
    'send captures the selected topic before the file picker returns',
    () async {
      final jami = _FileJami();
      final controller = _controller(jami);
      addTearDown(controller.dispose);
      const owner = (peerId: 'peer-a', conversationId: 'conv-a');
      const topicId = '0123456789abcdef0123456789abcdef';

      final send = controller.sendFile(owner, topicId: topicId);
      jami.pickedFile.complete('picked.txt');
      await send;

      expect(jami.sentFiles, [
        (
          peerId: owner.peerId,
          conversationId: owner.conversationId,
          path: 'picked.txt',
          topicId: topicId,
        ),
      ]);
    },
  );

  test('native file projections keep one validated topic', () async {
    final jami = _FileJami();
    final controller = _controller(jami);
    addTearDown(controller.dispose);
    const owner = (peerId: 'peer-a', conversationId: 'conv-a');
    const topicId = '0123456789abcdef0123456789abcdef';

    controller.handleEvent(_incoming(topicId: topicId, topicTagged: true));
    var transfer = controller.transfers.values.single;
    expect((transfer.topicId, transfer.topicTagged), (topicId, true));

    controller.handleEvent(
      JamiEvent('fileProgress', {
        'accountId': 'account-a',
        'peerJamiId': owner.peerId,
        'conversationId': owner.conversationId,
        'fileId': 'file-a',
        'interactionId': 'interaction-file-a',
        'name': 'file-a.txt',
        'authorId': 'peer-a',
        'status': 'ongoing',
        'outgoing': false,
        'total': 12,
        'transferred': 4,
        'topicId': topicId,
        'topicTagged': true,
      }),
    );
    transfer = controller.transfers.values.single;
    expect((transfer.topicId, transfer.topicTagged), (topicId, true));

    controller.handleEvent(
      JamiEvent('folderFile', {
        'accountId': 'account-a',
        'peerJamiId': owner.peerId,
        'conversationId': owner.conversationId,
        'fileId': 'file-a',
        'interactionId': 'interaction-file-a',
        'name': 'file-a.txt',
        'size': 12,
        'authorId': 'peer-a',
        'outgoing': false,
        'timestamp': 100,
        'live': true,
        'topicId': topicId,
        'topicTagged': true,
      }),
    );
    expect(
      (
        controller.folder.values.single.topicId,
        controller.folder.values.single.topicTagged,
      ),
      (topicId, true),
    );

    controller.loadFolder(owner, keepLast: 200);
    jami.loadReplies.removeFirst().complete(61);
    await pumpEventQueue();
    controller.handleEvent(
      JamiEvent('folderSnapshot', {
        'accountId': 'account-a',
        'peerJamiId': owner.peerId,
        'conversationId': owner.conversationId,
        'loadId': 61,
        'files': const [
          {
            'fileId': 'file-a',
            'interactionId': 'interaction-file-a',
            'name': 'file-a.txt',
            'size': 12,
            'authorId': 'peer-a',
            'topicId': topicId,
            'topicTagged': true,
          },
        ],
      }),
    );
    expect(
      (
        controller.folder.values.single.topicId,
        controller.folder.values.single.topicTagged,
      ),
      (topicId, true),
    );
  });

  test(
    'malformed topic ownership cannot replace a folder projection',
    () async {
      final jami = _FileJami();
      final controller = _controller(jami);
      addTearDown(controller.dispose);
      const owner = (peerId: 'peer-a', conversationId: 'conv-a');
      controller.seedEmptyFolderProjectionForTesting([
        FolderFile(
          peerId: owner.peerId,
          conversationId: owner.conversationId,
          fileId: 'safe',
          interactionId: 'interaction-safe',
          name: 'safe.txt',
          size: 1,
        ),
      ]);

      controller.loadFolder(owner, keepLast: 200);
      jami.loadReplies.removeFirst().complete(62);
      await pumpEventQueue();
      controller.handleEvent(
        JamiEvent('folderSnapshot', {
          'accountId': 'account-a',
          'peerJamiId': owner.peerId,
          'conversationId': owner.conversationId,
          'loadId': 62,
          'files': const [
            {
              'fileId': 'bad',
              'interactionId': 'interaction-bad',
              'name': 'bad.txt',
              'size': 1,
              'topicId': 'not-a-topic',
              'topicTagged': true,
            },
          ],
        }),
      );

      expect(controller.folder.values.single.fileId, 'safe');
    },
  );

  test('completion reports the exact transfer and topic once', () async {
    final jami = _FileJami();
    final completed = <FileXfer>[];
    final controller = _controller(jami, onCompletedTransfer: completed.add);
    addTearDown(controller.dispose);
    const topicId = '0123456789abcdef0123456789abcdef';
    controller.handleEvent(_incoming(topicId: topicId, topicTagged: true));
    await _accept(jami, controller);

    Map<String, dynamic> progress(String status) => {
      'accountId': 'account-a',
      'peerJamiId': 'peer-a',
      'conversationId': 'conv-a',
      'fileId': 'file-a',
      'interactionId': 'interaction-file-a',
      'name': 'file-a.txt',
      'authorId': 'peer-a',
      'attemptId': controller.transfers.values.single.attemptId,
      'status': status,
      'outgoing': false,
      'total': 12,
      'transferred': 12,
      'topicId': topicId,
      'topicTagged': true,
    };

    controller.handleEvent(JamiEvent('fileProgress', progress('finished')));
    controller.handleEvent(JamiEvent('fileProgress', progress('finished')));

    expect(completed, hasLength(1));
    expect(completed.single, same(controller.transfers.values.single));
    expect(
      (
        completed.single.peerId,
        completed.single.conversationId,
        completed.single.topicId,
      ),
      ('peer-a', 'conv-a', topicId),
    );
  });

  test('a history download starts in the file topic', () async {
    final jami = _FileJami();
    final controller = _controller(jami);
    addTearDown(controller.dispose);
    const owner = (peerId: 'peer-a', conversationId: 'conv-a');
    const topicId = '0123456789abcdef0123456789abcdef';

    final download = controller.downloadFile(
      owner: owner,
      fileId: 'history-file',
      interactionId: 'interaction-history-file',
      name: 'history.txt',
      size: 12,
      downloaded: false,
      operation: 'testDownload',
      topicId: topicId,
      topicTagged: true,
    );
    jami.acceptReply!.complete(true);

    expect(await download, isTrue);
    final transfer = controller.transfers.values.single;
    expect((transfer.topicId, transfer.topicTagged), (topicId, true));
  });

  test('public transfer and folder maps are live read-only views', () {
    final transferJami = _FileJami();
    final transferController = _controller(transferJami);
    addTearDown(transferController.dispose);
    final transferView = transferController.transfers;

    expect(
      () =>
          transferView[(
            peerId: 'peer-a',
            conversationId: 'conv-a',
            fileId: 'injected',
          )] = FileXfer(
            peerId: 'peer-a',
            conversationId: 'conv-a',
            fileId: 'injected',
            interactionId: 'injected',
            name: 'injected.txt',
            size: 1,
            outgoing: false,
          ),
      throwsUnsupportedError,
    );
    transferController.handleEvent(_incoming());
    expect(
      transferView,
      contains((peerId: 'peer-a', conversationId: 'conv-a', fileId: 'file-a')),
      reason: 'the read-only facade must remain live as native events arrive',
    );

    final folderJami = _FileJami();
    final folderController = _controller(folderJami);
    addTearDown(folderController.dispose);
    final folderView = folderController.folder;
    folderController.seedEmptyFolderProjectionForTesting([
      FolderFile(
        peerId: 'peer-a',
        conversationId: 'conv-a',
        fileId: 'folder-a',
        interactionId: 'interaction-folder-a',
        name: 'folder-a.txt',
        size: 1,
      ),
    ]);
    expect(folderView, hasLength(1));
    expect(() => folderView.clear(), throwsUnsupportedError);
  });

  test('a committed file time replaces receiver-arrival time', () {
    final jami = _FileJami();
    final controller = _controller(jami);
    addTearDown(controller.dispose);

    controller.handleEvent(_incoming());
    controller.handleEvent(
      JamiEvent('folderFile', {
        'accountId': 'account-a',
        'peerJamiId': 'peer-a',
        'conversationId': 'conv-a',
        'fileId': 'file-a',
        'interactionId': 'interaction-file-a',
        'name': 'file-a.txt',
        'size': 12,
        'authorId': 'peer-a',
        'outgoing': false,
        'timestamp': 100,
        'live': true,
      }),
    );

    expect(
      controller.transfers.values.single.createdAt,
      DateTime.fromMillisecondsSinceEpoch(100000, isUtc: true),
    );
  });

  test('file callbacks require the exact friend conversation owner', () {
    final jami = _FileJami();
    final controller = _controller(jami);
    addTearDown(controller.dispose);

    controller.handleEvent(_incoming());
    controller.handleEvent(
      _incoming(accountId: 'old-account', fileId: 'wrong-account'),
    );
    controller.handleEvent(
      JamiEvent('incomingFile', {
        'peerJamiId': 'peer-a',
        'conversationId': 'conv-a',
        'fileId': 'missing-account',
        'interactionId': 'interaction-missing-account',
        'name': 'missing-account.txt',
        'size': 12,
      }),
    );
    controller.handleEvent(
      _incoming(conversationId: 'stale-conversation', fileId: 'wrong-conv'),
    );
    controller.handleEvent(_incoming(peerId: 'stranger', fileId: 'stranger'));

    expect(controller.transfers.keys, {
      (peerId: 'peer-a', conversationId: 'conv-a', fileId: 'file-a'),
    });
  });

  test('group file projections preserve the exact remote author', () async {
    final jami = _FileJami();
    final controller = _controller(
      jami,
      conversations: const {'group:conv-group': 'conv-group'},
    );
    addTearDown(controller.dispose);
    const owner = (peerId: 'group:conv-group', conversationId: 'conv-group');
    const author = 'member-author';

    controller.handleEvent(
      _incoming(
        peerId: owner.peerId,
        conversationId: owner.conversationId,
        fileId: 'group-file',
        authorId: author,
      ),
    );
    expect(controller.transfers.values.single.authorId, author);

    controller.handleEvent(
      JamiEvent('fileProgress', {
        'accountId': 'account-a',
        'peerJamiId': owner.peerId,
        'conversationId': owner.conversationId,
        'fileId': 'group-file',
        'interactionId': 'interaction-group-file',
        'name': 'group-file.txt',
        'authorId': author,
        'status': 'waiting',
        'outgoing': false,
        'total': 12,
      }),
    );
    expect(controller.transfers.values.single.authorId, author);

    controller.loadFolder(owner, keepLast: 200);
    jami.loadReplies.removeFirst().complete(51);
    await pumpEventQueue();
    controller.handleEvent(
      JamiEvent('folderSnapshot', {
        'accountId': 'account-a',
        'peerJamiId': owner.peerId,
        'conversationId': owner.conversationId,
        'loadId': 51,
        'files': const [
          {
            'fileId': 'group-file',
            'interactionId': 'interaction-group-file',
            'name': 'group-file.txt',
            'size': 12,
            'authorId': author,
          },
        ],
      }),
    );
    expect(controller.folder.values.single.authorId, author);
  });

  test(
    'folder snapshots are correlated when callback beats load reply',
    () async {
      final jami = _FileJami();
      final controller = _controller(jami);
      addTearDown(controller.dispose);
      const owner = (peerId: 'peer-a', conversationId: 'conv-a');
      var notifications = 0;
      controller.addListener(() => notifications += 1);

      controller.loadFolder(owner, keepLast: 200);
      expect(jami.loadReplies, hasLength(1));
      controller.handleEvent(
        JamiEvent('folderSnapshot', {
          'accountId': 'account-a',
          'peerJamiId': owner.peerId,
          'conversationId': owner.conversationId,
          'loadId': 41,
          'files': [
            {
              'fileId': 'early',
              'interactionId': 'interaction-early',
              'name': 'early.txt',
              'size': 10,
              'downloaded': false,
            },
          ],
        }),
      );
      expect(controller.folder, isEmpty);
      final notificationsBeforeReply = notifications;

      jami.loadReplies.removeFirst().complete(41);
      await pumpEventQueue();

      expect(notifications, greaterThan(notificationsBeforeReply));
      expect(
        controller.folder,
        contains((
          peerId: owner.peerId,
          conversationId: owner.conversationId,
          fileId: 'early',
        )),
      );
    },
  );

  test('a failed reload invalidates the previous native load id', () async {
    final jami = _FileJami();
    final controller = _controller(jami);
    addTearDown(controller.dispose);
    const owner = (peerId: 'peer-a', conversationId: 'conv-a');

    controller.loadFolder(owner, keepLast: 200);
    jami.loadReplies.removeFirst().complete(41);
    await pumpEventQueue();
    controller.handleEvent(
      JamiEvent('folderSnapshot', {
        'accountId': 'account-a',
        'peerJamiId': owner.peerId,
        'conversationId': owner.conversationId,
        'loadId': 41,
        'files': [
          {
            'fileId': 'authoritative',
            'interactionId': 'interaction-authoritative',
            'name': 'authoritative.txt',
            'size': 10,
          },
        ],
      }),
    );
    expect(controller.folder.values.single.fileId, 'authoritative');

    controller.loadFolder(owner, keepLast: 200);
    jami.loadReplies.removeFirst().complete(0);
    await pumpEventQueue();
    controller.handleEvent(
      JamiEvent('folderSnapshot', {
        'accountId': 'account-a',
        'peerJamiId': owner.peerId,
        'conversationId': owner.conversationId,
        'loadId': 41,
        'files': [
          {
            'fileId': 'stale',
            'interactionId': 'interaction-stale',
            'name': 'stale.txt',
            'size': 10,
          },
        ],
      }),
    );

    expect(controller.folder.values.single.fileId, 'authoritative');
  });

  test(
    'a malformed folder snapshot cannot replace the prior projection',
    () async {
      final jami = _FileJami();
      final controller = _controller(jami);
      addTearDown(controller.dispose);
      const owner = (peerId: 'peer-a', conversationId: 'conv-a');

      controller.loadFolder(owner, keepLast: 200);
      jami.loadReplies.removeFirst().complete(41);
      await pumpEventQueue();
      controller.handleEvent(
        JamiEvent('folderSnapshot', {
          'accountId': 'account-a',
          'peerJamiId': owner.peerId,
          'conversationId': owner.conversationId,
          'loadId': 41,
          'files': [
            {
              'fileId': 'authoritative',
              'interactionId': 'interaction-authoritative',
              'name': 'authoritative.txt',
              'size': 10,
            },
          ],
        }),
      );
      expect(controller.folder.values.single.fileId, 'authoritative');

      controller.loadFolder(owner, keepLast: 200);
      jami.loadReplies.removeFirst().complete(42);
      await pumpEventQueue();
      controller.handleEvent(
        JamiEvent('folderSnapshot', {
          'accountId': 'account-a',
          'peerJamiId': owner.peerId,
          'conversationId': owner.conversationId,
          'loadId': 42,
          'files': [
            {
              'fileId': 'plausible-prefix',
              'interactionId': 'interaction-prefix',
              'name': 'prefix.txt',
              'size': 10,
            },
            {
              'fileId': 'malformed-tail',
              'interactionId': 42,
              'name': 'tail.txt',
              'size': 10,
            },
          ],
        }),
      );

      expect(controller.folder.values.single.fileId, 'authoritative');
    },
  );

  test(
    'peer retirement invalidates an in-flight accept before polling',
    () async {
      final jami = _FileJami();
      final controller = _controller(jami);
      addTearDown(controller.dispose);
      controller.handleEvent(_incoming());
      final transfer = controller.transfers.values.single;
      final previewQueries = jami.fileInfoCalls;

      final accepting = controller.acceptFile(transfer);
      expect(transfer.status, XferStatus.ongoing);
      controller.retirePeer('peer-a');
      expect(controller.transfers, isEmpty);

      jami.acceptReply!.complete(true);
      await accepting;
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(jami.fileInfoCalls, previewQueries);
    },
  );

  test(
    'an offered-file decline is sent to the exact peer and resolves locally',
    () async {
      final jami = _FileJami();
      final controller = _controller(
        jami,
        conversations: const {_directPeer: 'conv-a'},
      );
      addTearDown(controller.dispose);
      controller.handleEvent(_incoming(peerId: _directPeer));
      final transfer = controller.transfers.values.single;

      final cancel = controller.declineFile(transfer);
      expect(transfer.status, XferStatus.canceling);
      // The native offer is already known even when no byte stream exists;
      // the direct decision wire is the sender-facing half of the contract.
      jami.cancelReply!.complete(false);
      await cancel;
      expect(transfer.status, XferStatus.declined);
      expect(jami.sentDeclines, [
        (peerId: _directPeer, conversationId: 'conv-a', fileId: 'file-a'),
      ]);

      controller.handleEvent(
        JamiEvent('fileProgress', {
          'accountId': 'account-a',
          'peerJamiId': _directPeer,
          'conversationId': 'conv-a',
          'fileId': 'file-a',
          'status': 'canceled',
        }),
      );
      expect(transfer.status, XferStatus.declined);
    },
  );

  test('a rejected cancel and decision keep the offer retryable', () async {
    final jami = _FileJami()..fileDecisionResult = false;
    final controller = _controller(
      jami,
      conversations: const {_directPeer: 'conv-a'},
    );
    addTearDown(controller.dispose);
    controller.handleEvent(_incoming(peerId: _directPeer));
    final transfer = controller.transfers.values.single;

    final decline = controller.declineFile(transfer);
    jami.cancelReply!.complete(false);
    await decline;

    expect(transfer.status, XferStatus.offered);
  });

  test('cancel exception restores the prior retryable state', () async {
    final jami = _FileJami()
      ..throwCancel = true
      ..fileDecisionResult = false;
    final controller = _controller(jami);
    addTearDown(controller.dispose);
    controller.handleEvent(_incoming());
    final transfer = controller.transfers.values.single;

    await controller.declineFile(transfer);

    expect(transfer.status, XferStatus.offered);
  });

  test('a peer decline may arrive before its outgoing file event', () {
    final jami = _FileJami();
    final controller = _controller(
      jami,
      conversations: const {_directPeer: 'conv-a'},
    );
    addTearDown(controller.dispose);

    controller.handleEvent(
      JamiEvent('fileDeclined', {
        'accountId': 'account-a',
        'peerJamiId': _directPeer,
        'conversationId': 'conv-a',
        'fileId': 'sent-file',
      }),
    );
    expect(controller.transfers, isEmpty);

    controller.handleEvent(
      JamiEvent('folderFile', {
        'accountId': 'account-a',
        'peerJamiId': _directPeer,
        'conversationId': 'conv-a',
        'fileId': 'sent-file',
        'interactionId': 'sent-interaction',
        'name': 'sent.txt',
        'size': 12,
        'authorId': 'me',
        'outgoing': true,
        'timestamp': 100,
        'live': true,
      }),
    );

    expect(controller.transfers.values.single.status, XferStatus.declined);
  });

  test('an offered file uses a native preview path when one exists', () async {
    final jami = _FileJami()
      ..fileInfoReply = const {
        'completed': true,
        'path': 'received/.preview/photo.jpg',
      };
    final controller = _controller(jami);
    addTearDown(controller.dispose);

    controller.handleEvent(_incoming(fileId: 'photo'));
    await pumpEventQueue();

    expect(controller.transfers.values.single.path, endsWith('photo.jpg'));
  });

  test('a bounded thumbnail may safely beat its exact image offer', () {
    final jami = _FileJami();
    final controller = _controller(
      jami,
      conversations: const {_directPeer: 'conv-a'},
    );
    addTearDown(controller.dispose);
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
      'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );

    controller.handleEvent(
      JamiEvent('fileThumbnail', {
        'accountId': 'account-a',
        'peerJamiId': _directPeer,
        'conversationId': 'conv-a',
        'fileId': 'photo',
        'pngBase64': base64Encode(png),
      }),
    );
    expect(controller.transfers, isEmpty);

    controller.handleEvent(
      _incoming(peerId: _directPeer, fileId: 'photo', name: 'photo.png'),
    );
    expect(controller.transfers.values.single.previewBytes, png);

    final oversized = Uint8List.fromList(png)
      ..setRange(16, 20, const [0, 0, 1, 0]);
    controller.handleEvent(
      JamiEvent('fileThumbnail', {
        'accountId': 'account-a',
        'peerJamiId': _directPeer,
        'conversationId': 'conv-a',
        'fileId': 'oversized',
        'pngBase64': base64Encode(oversized),
      }),
    );
    controller.handleEvent(
      _incoming(
        peerId: _directPeer,
        fileId: 'oversized',
        name: 'oversized.png',
      ),
    );
    expect(
      controller.transfers.values
          .singleWhere((transfer) => transfer.fileId == 'oversized')
          .previewBytes,
      isNull,
      reason: 'the advertised IHDR dimensions are bounded before rendering',
    );

    controller.handleEvent(
      JamiEvent('fileThumbnail', {
        'accountId': 'old-account',
        'peerJamiId': _directPeer,
        'conversationId': 'conv-a',
        'fileId': 'other',
        'pngBase64': base64Encode(png),
      }),
    );
    controller.handleEvent(
      _incoming(peerId: _directPeer, fileId: 'other', name: 'other.png'),
    );
    expect(
      controller.transfers.values
          .singleWhere((transfer) => transfer.fileId == 'other')
          .previewBytes,
      isNull,
    );
  });

  test('thumbnail side-channel stays direct-contact-only', () {
    const peer = 'group:conv-group';
    final controller = _controller(
      _FileJami(),
      conversations: const {peer: 'conv-group'},
    );
    addTearDown(controller.dispose);
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
      'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );

    controller.handleEvent(
      JamiEvent('fileThumbnail', {
        'accountId': 'account-a',
        'peerJamiId': peer,
        'conversationId': 'conv-group',
        'fileId': 'photo',
        'pngBase64': base64Encode(png),
      }),
    );
    controller.handleEvent(
      _incoming(
        peerId: peer,
        conversationId: 'conv-group',
        fileId: 'photo',
        name: 'photo.png',
      ),
    );

    expect(controller.transfers.values.single.previewBytes, isNull);
  });

  test(
    'a live outgoing image sends one generated bounded PNG preview',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'sybl-thumbnail-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final source = File(
        '${directory.path}${Platform.pathSeparator}photo.png',
      );
      await source.writeAsBytes(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
          'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        ),
      );
      final preview = Completer<Map<String, dynamic>>();
      final jami = _FileJami()..pendingFileInfo.add(preview);
      final controller = _controller(
        jami,
        conversations: const {_directPeer: 'conv-a'},
      );
      addTearDown(controller.dispose);

      controller.handleEvent(
        JamiEvent('folderFile', {
          'accountId': 'account-a',
          'peerJamiId': _directPeer,
          'conversationId': 'conv-a',
          'fileId': 'sent-photo',
          'interactionId': 'sent-interaction',
          'name': 'photo.png',
          'size': await source.length(),
          'authorId': 'me',
          'outgoing': true,
          'timestamp': 100,
          'live': true,
        }),
      );
      controller.handleEvent(
        JamiEvent('fileProgress', {
          'accountId': 'account-a',
          'peerJamiId': _directPeer,
          'conversationId': 'conv-a',
          'fileId': 'sent-photo',
          'status': 'waiting',
          'outgoing': true,
        }),
      );
      preview.complete({'completed': true, 'path': source.path});
      await pumpEventQueue();
      expect(controller.transfers.values.single.path, source.path);
      await jami.thumbnailSent.future.timeout(const Duration(seconds: 2));

      expect(jami.sentThumbnails, hasLength(1));
      final sent = jami.sentThumbnails.single;
      expect(sent.peerId, _directPeer);
      expect(sent.conversationId, 'conv-a');
      expect(sent.fileId, 'sent-photo');
      expect(sent.png.length, lessThanOrEqualTo(24 * 1024));
      expect(sent.png.take(8), [
        0x89,
        0x50,
        0x4e,
        0x47,
        0x0d,
        0x0a,
        0x1a,
        0x0a,
      ]);
    },
  );

  test('a live outgoing file exposes peer decision states immediately', () {
    final jami = _FileJami();
    final controller = _controller(jami);
    addTearDown(controller.dispose);

    controller.handleEvent(
      JamiEvent('folderFile', {
        'accountId': 'account-a',
        'peerJamiId': 'peer-a',
        'conversationId': 'conv-a',
        'fileId': 'sent-file',
        'interactionId': 'sent-interaction',
        'name': 'sent.txt',
        'size': 12,
        'authorId': 'me',
        'outgoing': true,
        'timestamp': 100,
        'live': true,
      }),
    );
    final transfer = controller.transfers.values.single;
    expect(transfer.status, XferStatus.waiting);

    controller.handleEvent(
      JamiEvent('fileProgress', {
        'accountId': 'account-a',
        'peerJamiId': 'peer-a',
        'conversationId': 'conv-a',
        'fileId': 'sent-file',
        'status': 'ongoing',
        'outgoing': true,
      }),
    );
    expect(transfer.status, XferStatus.ongoing);

    controller.handleEvent(
      JamiEvent('fileProgress', {
        'accountId': 'account-a',
        'peerJamiId': 'peer-a',
        'conversationId': 'conv-a',
        'fileId': 'sent-file',
        'status': 'declined',
        'outgoing': true,
      }),
    );
    expect(transfer.status, XferStatus.declined);
  });

  test(
    'evicted native callback labels retain exact outgoing topic ownership',
    () {
      final controller = _controller(_FileJami());
      addTearDown(controller.dispose);
      const topicId = '0123456789abcdef0123456789abcdef';
      controller.handleEvent(
        JamiEvent('folderFile', {
          'accountId': 'account-a',
          'peerJamiId': 'peer-a',
          'conversationId': 'conv-a',
          'fileId': 'sent-file',
          'interactionId': 'signed-commit',
          'name': 'sent.txt',
          'size': 12,
          'authorId': 'me',
          'outgoing': true,
          'timestamp': 100,
          'live': true,
          'topicId': topicId,
          'topicTagged': true,
        }),
      );
      final transfer = controller.transfers.values.single;
      final progress = JamiEvent('fileProgress', {
        'accountId': 'account-a',
        'peerJamiId': 'peer-a',
        'conversationId': 'conv-a',
        'fileId': 'sent-file',
        'interactionId': 'signed-commit',
        'metadataKnown': false,
        'status': 'ongoing',
        'outgoing': true,
        'topicId': 'main',
        'topicTagged': false,
      });
      controller.handleEvent(progress);
      expect(transfer.status, XferStatus.ongoing);
      expect((transfer.topicId, transfer.topicTagged), (topicId, true));
      controller.handleEvent(
        JamiEvent('fileProgress', {
          ...progress.data,
          'interactionId': 'different-commit',
          'status': 'finished',
        }),
      );
      expect(transfer.status, XferStatus.ongoing);
    },
  );
}
