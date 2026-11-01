import 'dart:convert';

import 'package:flutter/services.dart';

/// Release destinations shared with the widget package. Null means unpublished.
final class CompanionLinks {
  const CompanionLinks({this.desktopDownloadUrl, this.widgetDownloadUrl});
  final String? desktopDownloadUrl;
  final String? widgetDownloadUrl;

  static String? _url(Object? value) {
    if (value == null) return null;
    if (value is! String ||
        value.length > 2048 ||
        RegExp(r'[\x00-\x20\x7f]').hasMatch(value)) {
      throw const FormatException('Invalid companion download URL');
    }
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException('Expected a public HTTPS download URL');
    }
    return value;
  }

  factory CompanionLinks.parse(String source) {
    final json = jsonDecode(source);
    if (json is! Map<String, dynamic> ||
        json.length != 3 ||
        json['version'] is! int ||
        json['version'] != 1 ||
        !json.containsKey('desktopDownloadUrl') ||
        !json.containsKey('widgetDownloadUrl')) {
      throw const FormatException('Invalid companion link configuration');
    }
    return CompanionLinks(
      desktopDownloadUrl: _url(json['desktopDownloadUrl']),
      widgetDownloadUrl: _url(json['widgetDownloadUrl']),
    );
  }

  static Future<CompanionLinks> load() async => CompanionLinks.parse(
    await rootBundle.loadString('assets/companion-links.json'),
  );
}
