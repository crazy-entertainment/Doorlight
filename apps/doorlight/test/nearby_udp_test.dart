import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sybl/state/nearby.dart';

class _Socket extends Fake implements RawDatagramSocket {
  final events = StreamController<RawSocketEvent>();
  final destinations = <String>[];
  final blocked = <String>{};
  bool rejectJoin = false;
  bool rejectBroadcast = false;
  bool closed = false;
  bool broadcast = false;

  @override
  set multicastLoopback(bool value) {}

  @override
  set broadcastEnabled(bool value) {
    if (rejectBroadcast) throw const SocketException('Broadcast denied');
    broadcast = value;
  }

  @override
  void joinMulticast(InternetAddress group, [NetworkInterface? interface]) {
    if (rejectJoin) throw const SocketException('Multicast denied');
  }

  @override
  StreamSubscription<RawSocketEvent> listen(
    void Function(RawSocketEvent)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => events.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  int send(List<int> buffer, InternetAddress address, int port) {
    destinations.add(address.address);
    if (blocked.contains(address.address)) {
      throw const SocketException('Send denied');
    }
    return buffer.length;
  }

  @override
  void close() {
    closed = true;
    unawaited(events.close());
  }
}

void main() {
  final data = Uint8List.fromList([1, 2, 3]);
  late _Socket socket;
  late int locks;
  late int releases;

  UdpNearbyTransport transport({bool broadcast = true}) => UdpNearbyTransport(
    broadcast: broadcast,
    acquireMulticastLock: () async {
      locks++;
      return true;
    },
    releaseMulticastLock: () async => releases++,
    bindSocket:
        (
          host,
          port, {
          bool reuseAddress = true,
          bool reusePort = false,
          int ttl = 1,
        }) async => socket,
  );

  setUp(() {
    socket = _Socket();
    locks = 0;
    releases = 0;
  });

  test(
    'Sonar sends multicast and mask-independent limited broadcast',
    () async {
      final lan = transport();
      final stream = await lan.start();
      final subscription = stream.listen((_) {});
      await lan.send(data);
      expect(socket.broadcast, isTrue);
      expect(socket.destinations, [NearbyProtocol.group, '255.255.255.255']);
      await lan.stop();
      expect(socket.closed, isTrue);
      expect(locks, 1);
      expect(releases, 1);
      await subscription.cancel();
      await expectLater(lan.send(data), throwsStateError);
      expect(socket.destinations, hasLength(2));
    },
  );

  test('broadcast still works when multicast cannot join', () async {
    socket.rejectJoin = true;
    final lan = transport();
    await lan.start();
    await lan.send(data);
    expect(socket.destinations, ['255.255.255.255']);
    await lan.stop();
  });

  test('a multicast send failure does not skip broadcast', () async {
    socket.blocked.add(NearbyProtocol.group);
    final lan = transport();
    await lan.start();
    await lan.send(data);
    expect(socket.destinations, [NearbyProtocol.group, '255.255.255.255']);
    await lan.stop();
  });

  test('a broadcast send failure preserves successful multicast', () async {
    socket.blocked.add('255.255.255.255');
    final lan = transport();
    await lan.start();
    await lan.send(data);
    expect(socket.destinations, [NearbyProtocol.group, '255.255.255.255']);
    await lan.stop();
  });

  test('broadcast setup denial leaves multicast operational', () async {
    socket.rejectBroadcast = true;
    final lan = transport();
    await lan.start();
    await lan.send(data);
    expect(socket.destinations, [NearbyProtocol.group]);
    await lan.stop();
  });

  test('unavailable paths close the socket and release the lock', () async {
    socket.rejectBroadcast = true;
    socket.rejectJoin = true;
    final lan = transport();
    await expectLater(lan.start(), throwsA(isA<SocketException>()));
    expect(socket.closed, isTrue);
    expect(releases, 1);
    await lan.stop();
    expect(releases, 1);
  });

  test('device linking keeps its multicast-only behavior', () async {
    final lan = transport(broadcast: false);
    await lan.start();
    await lan.send(data);
    expect(socket.broadcast, isFalse);
    expect(socket.destinations, [NearbyProtocol.group]);
    await lan.stop();
  });
}
