import 'dart:async';
import 'dart:io';

class WakeRelayConfig {
  const WakeRelayConfig._();

  static const baseUrl = String.fromEnvironment('SYBL_WAKE_RELAY_URL');

  static bool validBaseUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        uri.scheme == 'https' &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        !uri.hasQuery &&
        !uri.hasFragment &&
        (uri.path.isEmpty || uri.path == '/');
  }
}

typedef WakeRelayPost = Future<void> Function(Uri uri);

class WakeRelay {
  WakeRelay({String baseUrl = WakeRelayConfig.baseUrl, WakeRelayPost? post})
    : _baseUrl = baseUrl.replaceFirst(RegExp(r'/$'), ''),
      _post = post ?? _httpPost;

  static final _handle = RegExp(r'^[A-Za-z0-9_-]{43}$');
  final String _baseUrl;
  final WakeRelayPost _post;

  Future<void> wake(Iterable<String> handles) async {
    if (!WakeRelayConfig.validBaseUrl(_baseUrl)) return;
    await Future.wait(
      handles.where(_handle.hasMatch).toSet().map((handle) async {
        try {
          await _post(Uri.parse('$_baseUrl/v1/wakes/$handle'));
        } catch (_) {
          // A wake is an optional hint. Jami remains the delivery path.
        }
      }),
    );
  }

  static Future<void> _httpPost(Uri uri) async {
    final client = HttpClient()..userAgent = 'Syb-L wake/1';
    try {
      final request = await client
          .postUrl(uri)
          .timeout(const Duration(seconds: 3));
      request.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      final response = await request.close().timeout(
        const Duration(seconds: 3),
      );
      await response.drain<void>().timeout(const Duration(seconds: 3));
    } finally {
      client.close(force: true);
    }
  }
}
