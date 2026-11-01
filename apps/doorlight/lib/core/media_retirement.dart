/// Acknowledges playback release before an identity can be replaced.
final class MediaRetirement {
  static final Set<Future<bool> Function()> _owners = {};

  static void Function() register(Future<bool> Function() stop) {
    _owners.add(stop);
    return () => _owners.remove(stop);
  }

  static Future<bool> stopAll() async {
    final owners = _owners.toList(growable: false);
    final stopped = await Future.wait(
      owners.map((stop) async {
        try {
          return await stop().timeout(
            const Duration(seconds: 3),
            onTimeout: () => false,
          );
        } catch (_) {
          return false;
        }
      }),
    );
    return stopped.every((value) => value);
  }
}
