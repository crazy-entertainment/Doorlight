import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:path_provider_windows/path_provider_windows.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_windows/shared_preferences_windows.dart';

class UatWindowsPaths extends PathProviderWindows {
  UatWindowsPaths(this.root);
  final String root;

  @override
  Future<String> getPath(String folderID) async {
    final child = switch (folderID.toUpperCase()) {
      '{3EB685DB-65F9-4CF6-A03A-E3EF65729F3D}' => 'RoamingAppData',
      '{F1B32785-6FBA-4FCF-9D55-7B8E7F157091}' => 'LocalAppData',
      '{FDD39AD0-238F-46AF-ADB4-6C85480369C7}' => 'Documents',
      '{374DE290-123F-4565-9164-39C4925E467B}' => 'Downloads',
      _ => throw StateError('Unknown test-profile folder: $folderID'),
    };
    return '$root\\$child';
  }

  @override
  Future<String> getTemporaryPath() async => '$root\\Temp';
  @override
  Future<String> getApplicationSupportPath() async => '$root\\RoamingAppData\\app.sybl\\sybl';
  @override
  Future<String> getApplicationCachePath() async => '$root\\LocalAppData\\Syb-L\\cache';
  @override
  Future<String> getApplicationDocumentsPath() async => '$root\\Documents';
  @override
  Future<String> getDownloadsPath() async => '$root\\Downloads';
}

Future<String> initializeUatWindowsProfile() async {
  final root = await const MethodChannel('doorlight/visual-uat-profile').invokeMethod<String>('root');
  if (root == null || root.isEmpty || !Directory(root).existsSync()) {
    throw StateError('Native host did not validate an isolated UAT profile');
  }
  final paths = UatWindowsPaths(root);
  PathProviderPlatform.instance = paths;
  final legacy = SharedPreferencesWindows();
  final asyncPreferences = SharedPreferencesAsyncWindows();
  // These plugin injection points are intentionally used only by this test entrypoint.
  // ignore: invalid_use_of_visible_for_testing_member
  legacy.pathProvider = paths;
  // ignore: invalid_use_of_visible_for_testing_member
  asyncPreferences.pathProvider = paths;
  SharedPreferencesStorePlatform.instance = legacy;
  SharedPreferencesAsyncPlatform.instance = asyncPreferences;
  return root;
}
