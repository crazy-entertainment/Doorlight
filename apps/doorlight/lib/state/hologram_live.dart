import 'dart:convert';

/// Account-message control only. This wire value never enters chat history,
/// unread counters, presence, notification, or wake handling.
final class HologramPacket {
  const HologramPacket(
    this.type,
    this.conversation,
    this.operation, {
    this.nonce,
    this.commit,
  });
  static const mime = 'application/x-sybl-hologram-live+json';
  static final _id = RegExp(r'^[0-9a-f]{40}$');
  static final _random = RegExp(r'^[0-9a-f]{32}$');
  final String type, conversation, operation;
  final String? nonce, commit;
  String encode() => jsonEncode({
    'v': 1,
    't': type,
    'conversation': conversation,
    'op': operation,
    if (nonce != null) 'nonce': nonce,
    if (commit != null) 'commit': commit,
  });

  static HologramPacket? parse(String source) {
    if (source.length > 1024 ||
        utf8.encode(source).length > 1024 ||
        source.contains(r'\')) {
      return null;
    }
    try {
      final value = jsonDecode(source);
      if (value is! Map<String, dynamic> ||
          value['v'] is! int ||
          value['v'] != 1 ||
          value['conversation'] is! String ||
          !_id.hasMatch(value['conversation'] as String) ||
          value['op'] is! String ||
          !_random.hasMatch(value['op'] as String)) {
        return null;
      }
      final fields = switch (value['t']) {
        'prepare' => {'v', 't', 'conversation', 'op'},
        'ready' => {'v', 't', 'conversation', 'op', 'nonce'},
        'present' => {'v', 't', 'conversation', 'op', 'nonce', 'commit'},
        _ => <String>{},
      };
      if (fields.isEmpty ||
          value.length != fields.length ||
          !value.keys.every(fields.contains)) {
        return null;
      }
      // Hex/string-only fields make a bounded key-token count sufficient to
      // reject duplicate and escaped-key aliases hidden by jsonDecode.
      if (RegExp(
            r'"(?:v|t|conversation|op|nonce|commit)"\s*:',
          ).allMatches(source).length !=
          fields.length) {
        return null;
      }
      if (fields.contains('nonce') &&
          (value['nonce'] is! String ||
              !_random.hasMatch(value['nonce'] as String))) {
        return null;
      }
      if (fields.contains('commit') &&
          (value['commit'] is! String ||
              !_id.hasMatch(value['commit'] as String))) {
        return null;
      }
      return HologramPacket(
        value['t'] as String,
        value['conversation'] as String,
        value['op'] as String,
        nonce: value['nonce'] as String?,
        commit: value['commit'] as String?,
      );
    } on FormatException {
      return null;
    }
  }
}

typedef _Key = ({String peer, String conversation, String operation});

final class _Pending {
  _Pending(this.nonce, this.deadline);
  final String nonce;
  final int deadline;
  String? requestedCommit, observedCommit, asset;
}

final class _Intent {
  _Intent(this.conversation, this.recipients, this.opened);
  final String conversation;
  final Set<String> recipients;
  final int opened;
  bool frozen = false;
  final Map<String, String> readiness = {};
}

final class HologramPresentation {
  const HologramPresentation(
    this.peer,
    this.conversation,
    this.commit,
    this.asset,
    this.nonce,
    this.generation,
    this.until,
  );
  final String peer, conversation, commit, asset, nonce;
  final int generation, until;
}

/// Process-local freshness authority. Its caller supplies monotonic milliseconds
/// and only authenticated live commits/control packets from the native bridge.
/// There is deliberately no persistence, history scan, or presentation queue.
final class HologramLive {
  HologramLive({
    required this.now,
    required this.randomNonce,
    required this.eligible,
    required this.assetEligible,
    required this.send,
    required this.show,
  });
  final int Function() now;
  final String Function() randomNonce;
  final bool Function(String peer, String conversation) eligible;
  final bool Function(String asset) assetEligible;
  final void Function(String peer, HologramPacket packet) send;
  final void Function(HologramPresentation presentation) show;
  final Map<_Key, _Pending> _pending = {};
  final Map<String, _Intent> _intents = {};
  final Map<String, int> _senderCooldowns = {};
  int _globalCooldown = 0, _generation = 0;
  HologramPresentation? _active;
  HologramPresentation? get active => _active;

  void _prune() {
    final time = now();
    _pending.removeWhere((_, value) => time >= value.deadline);
    _intents.removeWhere((_, value) => time >= value.opened + 5000);
    _senderCooldowns.removeWhere((_, until) => time >= until);
    if (_active != null && !isCurrent(_active!)) _active = null;
  }

  bool begin(
    String operation,
    String conversation,
    Iterable<String> recipients,
  ) {
    _prune();
    if (!HologramPacket._random.hasMatch(operation) ||
        !HologramPacket._id.hasMatch(conversation) ||
        _intents.length >= 4 ||
        _intents.containsKey(operation)) {
      return false;
    }
    final peers = recipients
        .take(128)
        .where(HologramPacket._id.hasMatch)
        .toSet();
    _intents[operation] = _Intent(conversation, peers, now());
    for (final peer in peers) {
      send(peer, HologramPacket('prepare', conversation, operation));
    }
    return true;
  }

  /// Called before durable publication, after at most one second of collection.
  void freeze(String operation) {
    _prune();
    _intents[operation]?.frozen = true;
  }

  void abandon(String operation) {
    _intents.remove(operation);
  }

  void committed(String operation, String commit) {
    _prune();
    final intent = _intents.remove(operation);
    if (intent == null ||
        !intent.frozen ||
        !HologramPacket._id.hasMatch(commit)) {
      return;
    }
    for (final entry in intent.readiness.entries) {
      send(
        entry.value,
        HologramPacket(
          'present',
          intent.conversation,
          operation,
          nonce: entry.key,
          commit: commit,
        ),
      );
    }
  }

  void receive(String authenticatedPeer, HologramPacket packet) {
    _prune();
    if (!HologramPacket._id.hasMatch(authenticatedPeer)) return;
    if (packet.type == 'ready') {
      final intent = _intents[packet.operation];
      if (intent == null ||
          intent.frozen ||
          now() >= intent.opened + 1000 ||
          intent.conversation != packet.conversation ||
          !intent.recipients.contains(authenticatedPeer) ||
          intent.readiness.length >= 4 ||
          packet.nonce == null) {
        return;
      }
      intent.readiness.putIfAbsent(packet.nonce!, () => authenticatedPeer);
      return;
    }
    final key = (
      peer: authenticatedPeer,
      conversation: packet.conversation,
      operation: packet.operation,
    );
    if (!eligible(authenticatedPeer, packet.conversation)) {
      _pending.remove(key);
      return;
    }
    if (packet.type == 'prepare') {
      if (_active != null ||
          now() < _globalCooldown ||
          _senderCooldowns.containsKey(authenticatedPeer)) {
        return;
      }
      final existing = _pending[key];
      if (existing != null) {
        send(
          authenticatedPeer,
          HologramPacket(
            'ready',
            packet.conversation,
            packet.operation,
            nonce: existing.nonce,
          ),
        );
        return;
      }
      if (_pending.length >= 16 || _senderCooldowns.length >= 128) return;
      final nonce = randomNonce();
      if (!HologramPacket._random.hasMatch(nonce)) return;
      _pending[key] = _Pending(nonce, now() + 5000);
      send(
        authenticatedPeer,
        HologramPacket(
          'ready',
          packet.conversation,
          packet.operation,
          nonce: nonce,
        ),
      );
    } else if (packet.type == 'present') {
      final pending = _pending[key];
      if (pending == null ||
          pending.nonce != packet.nonce ||
          packet.commit == null) {
        return;
      }
      if (pending.requestedCommit != null &&
          pending.requestedCommit != packet.commit) {
        _pending.remove(key);
        return;
      }
      pending.requestedCommit = packet.commit;
      _present(key, pending);
    }
  }

  void liveCommit({
    required String author,
    required String conversation,
    required String operation,
    required String commit,
    required String asset,
    required bool hologram,
  }) {
    _prune();
    final key = (
      peer: author,
      conversation: conversation,
      operation: operation,
    );
    final pending = _pending[key];
    if (pending == null ||
        !hologram ||
        !assetEligible(asset) ||
        !HologramPacket._id.hasMatch(commit) ||
        !eligible(author, conversation)) {
      return;
    }
    if (pending.observedCommit != null && pending.observedCommit != commit) {
      _pending.remove(key);
      return;
    }
    pending.observedCommit = commit;
    pending.asset = asset;
    _present(key, pending);
  }

  void _present(_Key key, _Pending pending) {
    if (pending.requestedCommit == null ||
        pending.requestedCommit != pending.observedCommit) {
      return;
    }
    _pending.remove(key); // Consume before invoking any presentation code.
    final time = now();
    if (time >= pending.deadline ||
        _active != null ||
        time < _globalCooldown ||
        _senderCooldowns.containsKey(key.peer) ||
        !eligible(key.peer, key.conversation)) {
      return;
    }
    _globalCooldown = time + 4000;
    _senderCooldowns[key.peer] = time + 10000;
    final presentation = HologramPresentation(
      key.peer,
      key.conversation,
      pending.observedCommit!,
      pending.asset!,
      pending.nonce,
      _generation,
      time + 3350,
    );
    _active = presentation;
    show(presentation);
  }

  bool isCurrent(HologramPresentation value) =>
      identical(_active, value) &&
      value.generation == _generation &&
      now() < value.until &&
      eligible(value.peer, value.conversation);

  void cancelPresentation() {
    _active = null;
  }

  void invalidate() {
    _generation++;
    _pending.clear();
    _intents.clear();
    _active = null;
  }
}
