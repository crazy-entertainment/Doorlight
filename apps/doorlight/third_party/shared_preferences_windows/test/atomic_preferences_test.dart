import 'dart:convert';
import 'dart:io' as io;

import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider_windows/path_provider_windows.dart';
import 'package:shared_preferences_windows/shared_preferences_windows.dart';

class FixturePaths extends PathProviderWindows {
  FixturePaths(this.root);
  final String root;
  @override
  Future<String> getPath(String folderID) async => root;
}

class _NullPaths implements PathProviderWindows {
  @override
  dynamic noSuchMethod(Invocation invocation) => Future<String?>.value(null);
}

class _FaultFileSystem extends ForwardingFileSystem {
  _FaultFileSystem(super.delegate);
  String? failure;
  bool sawFlush = false;
  @override
  File file(dynamic path) => _FaultFile(super.file(path), this);
}

class _FaultFile implements File {
  _FaultFile(this.delegate, this.owner);
  final File delegate;
  final _FaultFileSystem owner;
  @override
  FileSystem get fileSystem => owner;
  @override
  String get path => delegate.path;
  @override
  Directory get parent => delegate.parent;
  @override
  bool existsSync() =>
      owner.failure == 'read-denied' ? false : delegate.existsSync();
  @override
  void deleteSync({bool recursive = false}) =>
      delegate.deleteSync(recursive: recursive);
  @override
  String readAsStringSync({Encoding encoding = utf8}) {
    if (owner.failure == 'path-not-found' &&
        path.endsWith('shared_preferences.json')) {
      throw const io.FileSystemException(
          'Synthetic path not found', '', io.OSError('Path not found', 3));
    }
    if (owner.failure == 'read-denied') {
      throw const io.FileSystemException(
          'Synthetic access denied', '', io.OSError('Access denied', 5));
    }
    return delegate.readAsStringSync(encoding: encoding);
  }

  @override
  void writeAsStringSync(String contents,
      {FileMode mode = FileMode.write,
      Encoding encoding = utf8,
      bool flush = false}) {
    owner.sawFlush = flush;
    if (owner.failure == 'write') {
      delegate.writeAsStringSync('{partial');
      throw const io.FileSystemException('Injected partial write');
    }
    delegate.writeAsStringSync(contents,
        mode: mode, encoding: encoding, flush: flush);
    if (owner.failure == 'flush') {
      throw const io.FileSystemException('Injected flush failure');
    }
  }

  @override
  File renameSync(String newPath) {
    if (owner.failure == 'rename') {
      throw const io.FileSystemException('Injected replacement failure');
    }
    return delegate.renameSync(newPath);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final root = io.Platform.isWindows ? r'C:\fixture' : '/fixture';
  final directory = path.join(root, 'app.sybl', 'sybl');
  final canonical = path.join(directory, 'shared_preferences.json');
  const original = '{"flutter.lock":true,"flutter.keep":"old"}';
  late _FaultFileSystem fs;
  late SharedPreferencesWindows adapter;
  setUp(() {
    fs = _FaultFileSystem(MemoryFileSystem(
        style: io.Platform.isWindows
            ? FileSystemStyle.windows
            : FileSystemStyle.posix));
    fs.directory(directory).createSync(recursive: true);
    fs.file(canonical).writeAsStringSync(original);
    adapter = SharedPreferencesWindows()
      ..fs = fs
      ..pathProvider = FixturePaths(root);
  });
  for (final nullPath in [false, true]) {
    test('unavailable preference location is a read failure: null=$nullPath',
        () async {
      adapter.pathProvider = nullPath ? _NullPaths() : FixturePaths('');
      await expectLater(adapter.getAll(), throwsStateError);
      expect(await adapter.setValue('Bool', 'flutter.lock', false), false);
      expect(fs.file(canonical).readAsStringSync(), original);
    });
  }
  test('known-path absent canonical file remains a fresh install', () async {
    fs.file(canonical).deleteSync();
    expect(await adapter.getAll(), isEmpty);
    expect(await adapter.setValue('Bool', 'flutter.lock', true), true);
    expect((await adapter.getAll())['flutter.lock'], true);
  });
  test('a hidden access failure is not an empty installation', () async {
    fs.failure = 'read-denied';
    await expectLater(adapter.getAll(), throwsA(isA<io.FileSystemException>()));
    expect(await adapter.setValue('Bool', 'flutter.lock', false), false);
  });
  test('canonical directory is not an empty installation', () async {
    fs.file(canonical).deleteSync();
    fs.directory(canonical).createSync();
    await expectLater(adapter.getAll(), throwsA(isA<io.FileSystemException>()));
    expect(await adapter.setValue('Bool', 'flutter.lock', false), false);
  });
  for (final dangling in [false, true]) {
    test('canonical link is not an empty installation: dangling=$dangling',
        () async {
      fs.file(canonical).deleteSync();
      final target = path.join(directory, 'other.json');
      if (!dangling) fs.file(target).writeAsStringSync(original);
      fs.link(canonical).createSync(target);
      await expectLater(
          adapter.getAll(), throwsA(isA<io.FileSystemException>()));
      expect(await adapter.setValue('Bool', 'flutter.lock', false), false);
    });
  }
  test('a non-directory parent is not an empty installation', () async {
    fs.directory(directory).deleteSync(recursive: true);
    fs.file(directory).writeAsStringSync('retained');
    fs.failure = 'path-not-found';
    await expectLater(adapter.getAll(), throwsA(isA<io.FileSystemException>()));
    expect(fs.file(directory).readAsStringSync(), 'retained');
  });
  for (final failure in ['write', 'flush', 'rename']) {
    test('$failure failure preserves canonical and adapter reads', () async {
      expect((await adapter.getAll())['flutter.lock'], true);
      fs.failure = failure;
      expect(await adapter.setValue('Bool', 'flutter.lock', false), false);
      expect(fs.file(canonical).readAsStringSync(), original);
      expect((await adapter.getAll())['flutter.lock'], true);
      expect(fs.sawFlush, true);
      expect(fs.directory(directory).listSync().length, 1);
      fs.failure = null;
      expect(await adapter.setValue('String', 'flutter.new', 'saved'), true);
      final reopened = SharedPreferencesWindows()
        ..fs = fs
        ..pathProvider = FixturePaths(root);
      expect(await reopened.getAll(), {
        'flutter.lock': true,
        'flutter.keep': 'old',
        'flutter.new': 'saved',
      });
    });
  }
  test('overlapping adapters preserve all successful updates', () async {
    final second = SharedPreferencesWindows()
      ..fs = fs
      ..pathProvider = FixturePaths(root);
    await Future.wait([adapter.getAll(), second.getAll()]);
    expect(
        await Future.wait([
          adapter.setValue('String', 'flutter.a', 'A'),
          second.setValue('String', 'flutter.b', 'B'),
          adapter.remove('flutter.keep'),
        ]),
        everyElement(true));
    expect(await second.getAll(), {
      'flutter.lock': true,
      'flutter.a': 'A',
      'flutter.b': 'B',
    });
  });
  test('failed remove and clear preserve the complete document', () async {
    fs.failure = 'rename';
    expect(await adapter.remove('flutter.lock'), false);
    expect(await adapter.clear(), false);
    expect(fs.file(canonical).readAsStringSync(), original);
    expect((await adapter.getAll())['flutter.lock'], true);
  });
  test('async adapter reports publication failure and reads old state',
      () async {
    final modern = SharedPreferencesAsyncWindows()
      ..fs = fs
      ..pathProvider = FixturePaths(root);
    const options = SharedPreferencesWindowsOptions();
    fs.failure = 'rename';
    await expectLater(
        modern.setBool('flutter.lock', false, options), throwsStateError);
    expect(await modern.getBool('flutter.lock', options), true);
    expect(fs.file(canonical).readAsStringSync(), original);
  });
  for (final corrupt in ['', '{partial', '[]']) {
    test('corrupt canonical stays unchanged: ${corrupt.length}', () async {
      fs.file(canonical).writeAsStringSync(corrupt);
      await expectLater(adapter.getAll(), throwsFormatException);
      expect(await adapter.setValue('Bool', 'flutter.lock', false), false);
      expect(fs.file(canonical).readAsStringSync(), corrupt);
    });
  }
}
