// Test-only entrypoint. Production builds continue to use lib/main.dart.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:sybl/main.dart' as production;
import 'visual_uat_windows.dart';

const _token = String.fromEnvironment('DOORLIGHT_UAT_TOKEN');
const _build = String.fromEnvironment('DOORLIGHT_UAT_BUILD');
const _port = int.fromEnvironment('DOORLIGHT_UAT_PORT', defaultValue: 43188);
bool _acting = false;
String? _profileRoot;

Future<void> main() async {
  if (_token.length < 32 || _build.isEmpty) {
    throw StateError('UAT build requires a private token and build identity');
  }
  await production.main(beforeAppStart: Platform.isWindows ? () async {
    _profileRoot = await initializeUatWindowsProfile();
  } : null);
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, _port);
  await for (final request in server) {
    unawaited(_handle(request));
  }
}

List<Element> _elements() {
  final result = <Element>[];
  void visit(Element element) {
    if (element.widget is Offstage && (element.widget as Offstage).offstage) return;
    result.add(element);
    element.visitChildren(visit);
  }
  final root = WidgetsBinding.instance.rootElement;
  if (root != null) visit(root);
  return result;
}

Rect? _bounds(Element element) {
  final render = element.findRenderObject();
  if (render is! RenderBox || !render.attached || !render.hasSize) return null;
  var rect = render.localToGlobal(Offset.zero) & render.size;
  RenderObject child = render;
  while (child.parent != null) {
    final parent = child.parent!;
    final clip = parent.describeApproximatePaintClip(child);
    if (clip != null) {
      rect = rect.intersect(MatrixUtils.transformRect(parent.getTransformTo(null), clip));
    }
    child = parent;
  }
  final view = WidgetsBinding.instance.platformDispatcher.views.first;
  rect = rect.intersect(Offset.zero & (view.physicalSize / view.devicePixelRatio));
  return rect.isEmpty ? null : rect;
}

String? _key(Element e) => e.widget.key is ValueKey ? (e.widget.key as ValueKey).value.toString() : null;
String? _text(Element e) => switch (e.widget) {
  Text(:final data, :final textSpan) => data ?? textSpan?.toPlainText(includePlaceholders: false),
  SelectableText(:final data, :final textSpan) => data ?? textSpan?.toPlainText(includePlaceholders: false),
  _ => null,
};

Element resolveUatTarget(Map<String, dynamic> selector) {
  final key = selector['key'];
  final text = selector['text'];
  final tooltip = selector['tooltip'];
  if ([key, text, tooltip].where((value) => value != null).length != 1) throw StateError('Choose exactly one key, text or tooltip');
  final matches = _elements().where((e) {
    if (_bounds(e) == null) return false;
    if (key != null && _key(e) != key) return false;
    if (text != null && _text(e) != text) return false;
    if (tooltip != null && !(e.widget is IconButton && (e.widget as IconButton).tooltip == tooltip)) return false;
    final scope = selector['within'];
    if (scope == null) return true;
    var found = false;
    e.visitAncestorElements((ancestor) {
      if (_key(ancestor) == scope) { found = true; return false; }
      return true;
    });
    return found;
  }).toList();
  if (matches.length != 1) throw StateError('Selector matched ${matches.length} visible controls; use a scoped key');
  return matches.single;
}

Map<String, dynamic> uatEditableState(Element element) {
  EditableText? editable;
  void visit(Element child) {
    if (child.widget case final EditableText field) {
      editable = field;
    } else {
      child.visitChildren(visit);
    }
  }
  if (element.widget is! TextField && element.widget is! EditableText) return {};
  visit(element);
  final field = editable;
  if (field == null) return {};
  return {
    'editable': true,
    'obscured': field.obscureText,
    if (!field.obscureText) 'value': field.controller.text,
    'focused': field.focusNode.hasFocus,
    'readOnly': field.readOnly,
  };
}

Map<String, dynamic> _snapshot() {
  final elements = _elements();
  final view = WidgetsBinding.instance.platformDispatcher.views.first;
  final app = elements.where((e) => e.widget is production.SyblApp).firstOrNull;
  final state = app == null ? null : (app.widget as production.SyblApp).state;
  return {
    'build': _build, 'pid': pid, 'platform': Platform.operatingSystem,
    'callGuardSupported': true,
    if (_profileRoot != null) 'profileRoot': _profileRoot,
    'os': Platform.operatingSystemVersion,
    'physical': {'width': view.physicalSize.width, 'height': view.physicalSize.height},
    'logical': {'width': view.physicalSize.width / view.devicePixelRatio, 'height': view.physicalSize.height / view.devicePixelRatio},
    'dpr': view.devicePixelRatio, 'keyboard': view.viewInsets.bottom / view.devicePixelRatio,
    'textScale': WidgetsBinding.instance.platformDispatcher.textScaleFactor,
    'account': state?.accountId,
    'jamiId': state?.jamiId,
    'selectedPeer': state?.peerId,
    'placingCall': state?.placing,
    'groupCallActive': state?.groupCall != null,
    'call': state?.call == null ? null : {
      'id': state!.call!.callId,
      'peerId': state.call!.peerId,
      'direction': state.call!.dir.name,
      'state': state.call!.state,
      'connected': state.call!.connected,
      'micMuted': state.call!.micMuted,
      'acknowledgedMicrophoneMuted': state.call!.acknowledgedMicrophoneMuted,
      'microphoneCommandsInFlight': state.call!.microphoneCommandsInFlight,
      'microphoneTeardownPending': state.call!.microphoneTeardownPending,
    },
    'pendingConnect': state?.pendingConnect == null ? null : {
      'conversationId': state!.pendingConnect!.convId,
      'fromJamiId': state.pendingConnect!.fromJamiId,
      'isGroup': state.pendingConnect!.isGroup,
    },
    'theme': state?.appearancePreset.name,
    'friends': state?.friends.keys.toList(),
    'friendDetails': [if (state != null) for (final friend in state.friends.values) {
      'peerId': friend.peerId,
      'confirmed': friend.confirmed,
      'conversationId': friend.conversationId,
    }],
    'controls': [for (final e in elements) if (_bounds(e) case final Rect rect) if (_key(e) != null || _text(e) != null || e.widget is EditableText || e.widget is IconButton) {
      'key': _key(e), 'type': e.widget.runtimeType.toString(),
      if (_text(e) != null) 'text': _text(e),
      ...uatEditableState(e),
      if (e.widget is IconButton && (e.widget as IconButton).tooltip != null) 'tooltip': (e.widget as IconButton).tooltip,
      'bounds': {'x': rect.left, 'y': rect.top, 'width': rect.width, 'height': rect.height},
    }],
  };
}

void validateUatCallGuard(Map<String, dynamic> expected, Map<String, dynamic> actual) {
  if (expected['account'] == null || expected['jamiId'] == null ||
      expected['account'] != actual['account'] || expected['jamiId'] != actual['jamiId'] ||
      actual['groupCallActive'] != false) {
    throw StateError('Call endpoint changed before input');
  }
  final wanted = expected['call'];
  final current = actual['call'];
  if (wanted == null) {
    if (current != null || actual['placingCall'] != false) throw StateError('Call slot changed before input');
  } else if (wanted is! Map || current is! Map ||
      wanted['id'] == null || wanted['peerId'] == null || wanted['direction'] == null ||
      wanted['id'] != current['id'] || wanted['peerId'] != current['peerId'] ||
      wanted['direction'] != current['direction']) {
    throw StateError('Call leg changed before input');
  }
}

Future<void> _gesture(Offset start, Offset end, int milliseconds, {VoidCallback? guard}) async {
  final binding = GestureBinding.instance;
  const pointer = 71;
  binding.handlePointerEvent(PointerAddedEvent(pointer: pointer, position: start));
  binding.handlePointerEvent(PointerDownEvent(pointer: pointer, position: start));
  var last = start;
  var completed = false;
  try {
    final steps = (milliseconds / 16).ceil().clamp(1, 120);
    for (var i = 1; i <= steps; i++) {
      await Future<void>.delayed(Duration(milliseconds: milliseconds ~/ steps));
      final point = Offset.lerp(start, end, i / steps)!;
      binding.handlePointerEvent(PointerMoveEvent(pointer: pointer, position: point, delta: point - last));
      last = point;
    }
    guard?.call();
    completed = true;
  } finally {
    binding.handlePointerEvent(completed ? PointerUpEvent(pointer: pointer, position: last) : PointerCancelEvent(pointer: pointer, position: last));
    binding.handlePointerEvent(PointerRemovedEvent(pointer: pointer, position: last));
  }
}

Future<void> _input(Map<String, dynamic> command) async {
  void guard() {
    if (command['callGuard'] case final Map expected) {
      validateUatCallGuard(Map<String, dynamic>.from(expected), _snapshot());
    }
  }
  guard();
  if (command['action'] == 'back') {
    await WidgetsBinding.instance.handlePopRoute();
    return;
  }
  final target = resolveUatTarget(Map<String, dynamic>.from(command['selector'] as Map));
  final rect = _bounds(target)!;
  final hit = HitTestResult();
  final view = WidgetsBinding.instance.platformDispatcher.views.first;
  WidgetsBinding.instance.hitTestInView(hit, rect.center, view.viewId);
  if (!hit.path.any((entry) => entry.target == target.findRenderObject())) {
    throw StateError('Target is occluded or not hit-testable');
  }
  switch (command['action']) {
    case 'tap':
      await _gesture(rect.center, rect.center, 32, guard: guard);
    case 'longPress':
      await _gesture(rect.center, rect.center, 800);
    case 'swipe':
      final dx = (command['dx'] as num).toDouble();
      final dy = (command['dy'] as num).toDouble();
      final end = rect.center + Offset(dx, dy);
      if (!rect.contains(end)) throw StateError('Swipe must stay within the target');
      await _gesture(rect.center, end, 500);
    case 'text':
      final value = command['text'];
      if (value is! String || value.length > 70000) throw StateError('Invalid text');
      await _gesture(rect.center, rect.center, 32);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final focused = _elements().whereType<StatefulElement>().where((e) => e.state is EditableTextState && (e.widget as EditableText).focusNode.hasFocus).toList();
      if (focused.length != 1) throw StateError('No unique focused editable control');
      var ownsFocus = focused.single == target;
      focused.single.visitAncestorElements((ancestor) {
        if (ancestor == target) { ownsFocus = true; return false; }
        return true;
      });
      if (!ownsFocus) throw StateError('Focused editable does not belong to the selected control');
      final editable = focused.single.state as EditableTextState;
      editable.updateEditingValue(TextEditingValue(text: value, selection: TextSelection.collapsed(offset: value.length)));
      editable.requestKeyboard();
    default:
      throw StateError('Unsupported input');
  }
  WidgetsBinding.instance.scheduleFrame();
  await WidgetsBinding.instance.endOfFrame.timeout(const Duration(seconds: 3));
}

Future<void> _handle(HttpRequest request) async {
  try {
    if (request.headers.value('authorization') != 'Bearer $_token' || request.headers.value('origin') != null) {
      request.response.statusCode = HttpStatus.forbidden;
      return;
    }
    Object result;
    if (request.method == 'GET' && request.uri.path == '/state') {
      result = _snapshot();
    } else if (request.method == 'POST' && request.uri.path == '/input') {
      if (_acting) throw StateError('Input already in progress');
      _acting = true;
      try {
        var size = 0;
        final bytes = <int>[];
        await for (final part in request) {
          size += part.length;
          if (size > 500000) throw StateError('Input too large');
          bytes.addAll(part);
        }
        await _input(jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>);
        result = _snapshot();
      } finally { _acting = false; }
    } else {
      request.response.statusCode = HttpStatus.notFound;
      result = {'error': 'Unknown route'};
    }
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(result));
  } catch (error) {
    request.response.statusCode = HttpStatus.badRequest;
    request.response.write(jsonEncode({'error': error.toString()}));
  } finally { await request.response.close(); }
}
