// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert' show json;

import 'package:file/file.dart';
import 'package:file/local.dart';
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:path/path.dart' as path;
import 'package:path_provider_windows/path_provider_windows.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

const String _defaultFileName = 'shared_preferences';

const String _defaultPrefix = 'flutter.';

/// The Windows implementation of [SharedPreferencesStorePlatform].
///
/// This class implements the `package:shared_preferences` functionality for Windows.
class SharedPreferencesWindows extends SharedPreferencesStorePlatform {
  /// Deprecated instance of [SharedPreferencesWindows].
  /// Use [SharedPreferencesStorePlatform.instance] instead.
  @Deprecated('Use `SharedPreferencesStorePlatform.instance` instead.')
  static SharedPreferencesWindows instance = SharedPreferencesWindows();

  /// Registers the Windows implementation.
  static void registerWith() {
    SharedPreferencesStorePlatform.instance = SharedPreferencesWindows();
    // A temporary work-around for having two plugins contained in a single package.
    SharedPreferencesAsyncWindows.registerWith();
  }

  /// File system used to store to disk. Exposed for testing only.
  @visibleForTesting
  FileSystem fs = const LocalFileSystem();

  /// The path_provider_windows instance used to find the support directory.
  @visibleForTesting
  PathProviderWindows pathProvider = PathProviderWindows();

  /// Read the canonical file; failed writes never become cached state.
  Future<Map<String, Object>> _readPreferences() async {
    return _readFromFile(
      _defaultFileName,
      fs: fs,
      pathProvider: pathProvider,
    );
  }

  @override
  Future<bool> clear() async {
    return clearWithParameters(
      ClearParameters(
        filter: PreferencesFilter(prefix: _defaultPrefix),
      ),
    );
  }

  @override
  Future<bool> clearWithPrefix(String prefix) async {
    return clearWithParameters(
        ClearParameters(filter: PreferencesFilter(prefix: prefix)));
  }

  @override
  Future<bool> clearWithParameters(ClearParameters parameters) async {
    final PreferencesFilter filter = parameters.filter;

    return _updatePreferences(
      _defaultFileName,
      (preferences) => preferences.removeWhere((String key, _) =>
          key.startsWith(filter.prefix) &&
          (filter.allowList == null || filter.allowList!.contains(key))),
      fs: fs,
      pathProvider: pathProvider,
    );
  }

  @override
  Future<Map<String, Object>> getAll() async {
    return getAllWithParameters(
      GetAllParameters(
        filter: PreferencesFilter(prefix: _defaultPrefix),
      ),
    );
  }

  @override
  Future<Map<String, Object>> getAllWithPrefix(String prefix) async {
    return getAllWithParameters(
        GetAllParameters(filter: PreferencesFilter(prefix: prefix)));
  }

  @override
  Future<Map<String, Object>> getAllWithParameters(
      GetAllParameters parameters) async {
    final PreferencesFilter filter = parameters.filter;
    final Map<String, Object> withPrefix =
        Map<String, Object>.from(await _readPreferences());
    withPrefix.removeWhere((String key, _) => !(key.startsWith(filter.prefix) &&
        (filter.allowList?.contains(key) ?? true)));
    return withPrefix;
  }

  @override
  Future<bool> remove(String key) async {
    return _updatePreferences(
      _defaultFileName,
      (preferences) {
        preferences.remove(key);
      },
      fs: fs,
      pathProvider: pathProvider,
    );
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    return _updatePreferences(
      _defaultFileName,
      (preferences) {
        preferences[key] = value;
      },
      fs: fs,
      pathProvider: pathProvider,
    );
  }
}

/// The Windows implementation of [SharedPreferencesAsyncPlatform].
///
/// This class implements the `package:shared_preferences` functionality for Windows.
base class SharedPreferencesAsyncWindows
    extends SharedPreferencesAsyncPlatform {
  /// Registers the Windows implementation.
  static void registerWith() {
    SharedPreferencesAsyncPlatform.instance = SharedPreferencesAsyncWindows();
  }

  /// File system used to store to disk. Exposed for testing only.
  @visibleForTesting
  FileSystem fs = const LocalFileSystem();

  /// The path_provider_windows instance used to find the support directory.
  @visibleForTesting
  PathProviderWindows pathProvider = PathProviderWindows();

  @override
  Future<Set<String>> getKeys(
    GetPreferencesParameters parameters,
    SharedPreferencesOptions options,
  ) async {
    return (await getPreferences(parameters, options)).keys.toSet();
  }

  @override
  Future<void> setString(
    String key,
    String value,
    SharedPreferencesOptions options,
  ) {
    return _setValue(key, value, options);
  }

  @override
  Future<void> setBool(
    String key,
    bool value,
    SharedPreferencesOptions options,
  ) {
    return _setValue(key, value, options);
  }

  @override
  Future<void> setDouble(
    String key,
    double value,
    SharedPreferencesOptions options,
  ) {
    return _setValue(key, value, options);
  }

  @override
  Future<void> setInt(
    String key,
    int value,
    SharedPreferencesOptions options,
  ) {
    return _setValue(key, value, options);
  }

  @override
  Future<void> setStringList(
    String key,
    List<String> value,
    SharedPreferencesOptions options,
  ) {
    return _setValue(key, value, options);
  }

  @override
  Future<String?> getString(
    String key,
    SharedPreferencesOptions options,
  ) async {
    final Map<String, Object> data = await _readAll(<String>{key}, options);
    return data[key] as String?;
  }

  @override
  Future<bool?> getBool(
    String key,
    SharedPreferencesOptions options,
  ) async {
    final Map<String, Object> data = await _readAll(<String>{key}, options);
    return data[key] as bool?;
  }

  @override
  Future<double?> getDouble(
    String key,
    SharedPreferencesOptions options,
  ) async {
    final Map<String, Object> data = await _readAll(<String>{key}, options);
    return data[key] as double?;
  }

  @override
  Future<int?> getInt(
    String key,
    SharedPreferencesOptions options,
  ) async {
    final Map<String, Object> data = await _readAll(<String>{key}, options);
    return data[key] as int?;
  }

  @override
  Future<List<String>?> getStringList(
    String key,
    SharedPreferencesOptions options,
  ) async {
    final Map<String, Object> data = await _readAll(<String>{key}, options);
    return (data[key] as List<Object?>?)?.cast<String>().toList();
  }

  @override
  Future<void> clear(ClearPreferencesParameters parameters,
      SharedPreferencesOptions options) async {
    final SharedPreferencesWindowsOptions windowsOptions =
        SharedPreferencesWindowsOptions.fromSharedPreferencesOptions(options);
    final PreferencesFilters filter = parameters.filter;
    if (!await _updatePreferences(
      windowsOptions.fileName,
      (preferences) => preferences.removeWhere((String key, _) =>
          filter.allowList == null || filter.allowList!.contains(key)),
      fs: fs,
      pathProvider: pathProvider,
    )) {
      throw StateError('Unable to persist preferences');
    }
  }

  @override
  Future<Map<String, Object>> getPreferences(
    GetPreferencesParameters parameters,
    SharedPreferencesOptions options,
  ) async {
    return _readAll(parameters.filter.allowList, options);
  }

  /// Validates that the canonical preferences can be read.
  @visibleForTesting
  Future<void> reload(
    SharedPreferencesWindowsOptions options,
  ) async {
    await _readPreferences(options.fileName);
  }

  Future<Map<String, Object>> _readAll(
    Set<String>? allowList,
    SharedPreferencesOptions options,
  ) async {
    final SharedPreferencesWindowsOptions windowsOptions =
        SharedPreferencesWindowsOptions.fromSharedPreferencesOptions(options);
    final Map<String, Object> prefs = Map<String, Object>.from(
        await _readPreferences(windowsOptions.fileName));
    prefs.removeWhere((String key, _) => !(allowList?.contains(key) ?? true));
    return prefs;
  }

  Future<void> _setValue(
      String key, Object value, SharedPreferencesOptions options) async {
    final SharedPreferencesWindowsOptions windowsOptions =
        SharedPreferencesWindowsOptions.fromSharedPreferencesOptions(options);
    if (!await _updatePreferences(
      windowsOptions.fileName,
      (preferences) {
        preferences[key] = value;
      },
      fs: fs,
      pathProvider: pathProvider,
    )) {
      throw StateError('Unable to persist preferences');
    }
  }

  /// Read the canonical file; failed writes never become cached state.
  Future<Map<String, Object>> _readPreferences(String fileName) async {
    return _readFromFile(
      fileName,
      fs: fs,
      pathProvider: pathProvider,
    );
  }
}

/// Gets the file where the preferences are stored.
Future<File> _getLocalDataFile(
  String fileName, {
  FileSystem fs = const LocalFileSystem(),
  PathProviderWindows? pathProvider,
}) async {
  pathProvider = pathProvider ?? PathProviderWindows();
  // Doorlight compatibility: ProductName is presentation, not storage identity.
  // The installed application used CompanyName=app.sybl, ProductName=sybl.
  // FOLDERID_RoamingAppData. The analyzer selects path_provider's non-FFI
  // stub, which lacks the constants and incorrectly declares a non-null result.
  // The real Windows implementation can return null when resolution fails.
  // ignore: unnecessary_nullable_for_final_variable_declarations
  final String? roaming = await pathProvider.getPath(
    '{3EB685DB-65F9-4CF6-A03A-E3EF65729F3D}',
  );
  final String? directory = roaming == null || roaming.isEmpty
      ? null
      : path.join(roaming, 'app.sybl', 'sybl');
  if (directory == null) {
    throw StateError('Windows preferences location is unavailable');
  }
  final String fileLocation = path.join(directory, '$fileName.json');
  return fs.file(fileLocation);
}

/// Gets the preferences from the stored file.
Future<Map<String, Object>> _readFromFile(
  String fileName, {
  FileSystem fs = const LocalFileSystem(),
  PathProviderWindows? pathProvider,
}) async {
  final File localDataFile = await _getLocalDataFile(
    fileName,
    fs: fs,
    pathProvider: pathProvider,
  );
  return _readLocalPreferences(localDataFile);
}

Map<String, Object> _readLocalPreferences(File file) {
  final type = file.fileSystem.typeSync(file.path, followLinks: false);
  if (type != FileSystemEntityType.file &&
      type != FileSystemEntityType.notFound) {
    throw FileSystemException('Preferences must be a regular file', file.path);
  }
  final String contents;
  try {
    contents = file.readAsStringSync();
  } on FileSystemException catch (error) {
    // Only a known-path absent file is a fresh install. existsSync also hides read failures.
    if (error.osError?.errorCode == 2 || error.osError?.errorCode == 3) {
      if (file.fileSystem.typeSync(file.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        rethrow;
      }
      // A missing child below a file is damaged storage, not an absent installation.
      var parent = file.parent;
      while (true) {
        final parentType = file.fileSystem.typeSync(parent.path);
        if (parentType != FileSystemEntityType.notFound &&
            parentType != FileSystemEntityType.directory) {
          rethrow;
        }
        final next = parent.parent;
        if (next.path == parent.path ||
            parentType == FileSystemEntityType.directory) {
          break;
        }
        parent = next;
      }
      return <String, Object>{};
    }
    rethrow;
  }
  if (contents.isEmpty) throw const FormatException('Preferences are empty');
  final Object? data = json.decode(contents);
  if (data is! Map) {
    throw const FormatException('Preferences must be an object');
  }
  return Map<String, Object>.from(data);
}

Future<bool> _updatePreferences(
  String fileName,
  void Function(Map<String, Object>) update, {
  required FileSystem fs,
  required PathProviderWindows pathProvider,
}) async {
  Directory? staging;
  try {
    final File canonical = await _getLocalDataFile(
      fileName,
      fs: fs,
      pathProvider: pathProvider,
    );
    // No await between reading and publication: concurrent adapter operations in
    // this isolate cannot overwrite each other's changes or cache failed writes.
    final type = fs.typeSync(canonical.path, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.file) {
      return false;
    }
    final preferences = _readLocalPreferences(canonical);
    update(preferences);
    final contents = json.encode(preferences);
    canonical.parent.createSync(recursive: true);
    staging = canonical.parent.createTempSync('.preferences-');
    final staged = fs.file(path.join(staging.path, 'staged.json'));
    staged.writeAsStringSync(contents, flush: true);
    // Dart 3.12.2 file_win.cc uses MoveFileExW(REPLACE_EXISTING | WRITE_THROUGH)
    // for regular files. Never delete the canonical file before replacement.
    staged.renameSync(canonical.path);
    return true;
  } catch (error) {
    // Error codes identify storage failures without logging keys, values, or
    // private paths from the preferences document.
    final code = error is FileSystemException ? error.osError?.errorCode : null;
    debugPrint('Unable to persist preferences (${error.runtimeType}, code=$code).');
    return false;
  } finally {
    // Only this operation's private staging directory is eligible for cleanup.
    try {
      staging?.deleteSync(recursive: true);
    } catch (_) {
      debugPrint('Unable to remove preferences staging directory.');
    }
  }
}

/// Windows specific SharedPreferences Options.
class SharedPreferencesWindowsOptions extends SharedPreferencesOptions {
  /// Constructor for SharedPreferencesWindowsOptions.
  const SharedPreferencesWindowsOptions({
    this.fileName = 'shared_preferences', // Same as current defaults.
  });

  /// The name of the file to store preferences in.
  final String fileName;

  /// Returns a new instance of [SharedPreferencesWindowsOptions] from an existing
  /// [SharedPreferencesOptions].
  static SharedPreferencesWindowsOptions fromSharedPreferencesOptions(
      SharedPreferencesOptions options) {
    if (options is SharedPreferencesWindowsOptions) {
      return options;
    }
    return const SharedPreferencesWindowsOptions();
  }
}
