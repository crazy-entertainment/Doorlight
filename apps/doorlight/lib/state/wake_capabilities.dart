import 'dart:convert';

class WakeCapabilities {
  WakeCapabilities([Map<String, Iterable<String>> values = const {}]) {
    for (final entry in values.entries) {
      for (final handle in entry.value) {
        record(entry.key, handle);
      }
    }
  }

  static const maxHandlesPerPeer = 8;
  static final _peer = RegExp(r'^[0-9a-f]{40}$');
  static final _handle = RegExp(r'^[A-Za-z0-9_-]{43}$');
  final Map<String, List<String>> _values = {};

  factory WakeCapabilities.decode(String? source) {
    if (source == null || source.isEmpty) return WakeCapabilities();
    try {
      final value = jsonDecode(source);
      if (value is! Map) return WakeCapabilities();
      return WakeCapabilities({
        for (final entry in value.entries)
          if (entry.key is String && entry.value is List)
            entry.key as String: (entry.value as List).whereType<String>(),
      });
    } catch (_) {
      return WakeCapabilities();
    }
  }

  bool record(String peerId, String handle) {
    if (!_peer.hasMatch(peerId) || !_handle.hasMatch(handle)) return false;
    final handles = _values.putIfAbsent(peerId, () => []);
    handles.remove(handle);
    handles.add(handle);
    if (handles.length > maxHandlesPerPeer) handles.removeAt(0);
    return true;
  }

  Set<String> handlesFor(Iterable<String> peerIds) => {
    for (final peer in peerIds)
      if (_peer.hasMatch(peer)) ...?_values[peer],
  };

  bool trim(Set<String> authorizedPeerIds) {
    final before = _values.length;
    _values.removeWhere((peer, _) => !authorizedPeerIds.contains(peer));
    return before != _values.length;
  }

  String encode() => jsonEncode(_values);
}
