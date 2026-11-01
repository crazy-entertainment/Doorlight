import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/app_state.dart';
import '../state/remote_control.dart';
import '../state/video_viewport.dart';
import '../theme.dart';
import 'sybl_ui.dart';

/// Input layer for the peer's selected screen.
///
/// Desktop captures pointer + keyboard while focused. In view-only mode touch
/// keeps the screen inspectable with native pinch/pan; once control is granted,
/// one touch pointer preserves down/move/up as normalized mouse input. The
/// child and hit-testing use the same contained source geometry, so black
/// letterbox bars never map into the controlled display.
class RemoteControlSurface extends StatefulWidget {
  const RemoteControlSurface({
    super.key,
    required this.controller,
    required this.sourceSize,
    required this.child,
  });

  final RemoteControlController controller;
  final Size sourceSize;
  final Widget child;

  @override
  State<RemoteControlSurface> createState() => _RemoteControlSurfaceState();
}

class _RemoteControlSurfaceState extends State<RemoteControlSurface> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'remote-control');
  final TransformationController _transformation = TransformationController();
  int _mouseButtons = 0;
  int _physicalButtons = 0;
  int? _touchPointer;

  bool get _touchLayout =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void didUpdateWidget(covariant RemoteControlSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
    }
  }

  void _onControllerChanged() {
    if (!widget.controller.isControlling) {
      _mouseButtons = 0;
      _physicalButtons = 0;
      _touchPointer = null;
      _focusNode.unfocus();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _focusNode.dispose();
    _transformation.dispose();
    super.dispose();
  }

  Offset? _normalized(Offset local, Size viewport) => VideoViewport(
    viewport: viewport,
    source: widget.sourceSize,
  ).normalize(local);

  void _move(PointerEvent event, Size viewport) {
    final point = _normalized(event.localPosition, viewport);
    if (point != null) widget.controller.move(point.dx, point.dy);
    _syncButtons(event.buttons, allowPress: point != null);
  }

  void _syncButtons(int physical, {bool allowPress = false}) {
    // A press that began in a bar must stay rejected when dragged into the
    // image. Already admitted buttons still owe an up outside the image.
    final next =
        (_mouseButtons & physical) |
        (allowPress ? physical & ~_physicalButtons : 0);
    _physicalButtons = physical;
    const masks = <int, RemoteMouseButton>{
      kPrimaryMouseButton: RemoteMouseButton.left,
      kSecondaryMouseButton: RemoteMouseButton.right,
    };
    for (final entry in masks.entries) {
      final wasDown = (_mouseButtons & entry.key) != 0;
      final isDown = (next & entry.key) != 0;
      if (wasDown != isDown) {
        widget.controller.button(entry.value, down: isDown);
      }
    }
    _mouseButtons = next;
  }

  KeyEventResult _key(FocusNode _, KeyEvent event) {
    if (!widget.controller.isControlling) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    if (event.logicalKey == LogicalKeyboardKey.escape &&
        keyboard.isControlPressed &&
        keyboard.isAltPressed) {
      if (event is KeyDownEvent) {
        unawaited(widget.controller.stopControlling(reason: 'panic-shortcut'));
      }
      return KeyEventResult.handled;
    }
    final virtualKey = _windowsVirtualKey(event.logicalKey);
    if (virtualKey != null &&
        widget.controller.supportsCapability(
          RemoteControlCapability.keyboard,
        )) {
      widget.controller.key(
        virtualKey,
        down: event is KeyDownEvent || event is KeyRepeatEvent,
      );
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent &&
        widget.controller.supportsCapability(RemoteControlCapability.text) &&
        !keyboard.isControlPressed &&
        !keyboard.isAltPressed &&
        !keyboard.isMetaPressed) {
      final character = event.character;
      if (character != null && character.isNotEmpty) {
        widget.controller.text(character);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    if (_touchLayout) return _touch(context);
    return _desktop(context);
  }

  Widget _touch(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = constraints.biggest;
        if (widget.controller.isControlling) {
          return Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (event) {
              if (_touchPointer != null) return;
              final point = _normalized(event.localPosition, viewport);
              if (point == null) return;
              _touchPointer = event.pointer;
              widget.controller
                ..move(point.dx, point.dy)
                ..button(RemoteMouseButton.left, down: true);
            },
            onPointerMove: (event) {
              if (_touchPointer != event.pointer) return;
              final point = _normalized(event.localPosition, viewport);
              if (point != null) widget.controller.move(point.dx, point.dy);
            },
            onPointerUp: (event) {
              if (_touchPointer != event.pointer) return;
              final point = _normalized(event.localPosition, viewport);
              if (point != null) widget.controller.move(point.dx, point.dy);
              widget.controller.button(RemoteMouseButton.left, down: false);
              _touchPointer = null;
            },
            onPointerCancel: (event) {
              if (_touchPointer != event.pointer) return;
              widget.controller.button(RemoteMouseButton.left, down: false);
              _touchPointer = null;
            },
            child: widget.child,
          );
        }
        return InteractiveViewer(
          transformationController: _transformation,
          minScale: 1,
          maxScale: 4,
          panEnabled: true,
          scaleEnabled: true,
          clipBehavior: Clip.hardEdge,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (details) {
              final point = _normalized(details.localPosition, viewport);
              if (point == null) return;
              widget.controller
                ..move(point.dx, point.dy)
                ..click();
            },
            onLongPressStart: (details) {
              final point = _normalized(details.localPosition, viewport);
              if (point == null) return;
              widget.controller
                ..move(point.dx, point.dy)
                ..click(RemoteMouseButton.right);
            },
            child: SizedBox.fromSize(size: viewport, child: widget.child),
          ),
        );
      },
    );
  }

  Widget _desktop(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = constraints.biggest;
        return Focus(
          focusNode: _focusNode,
          onKeyEvent: _key,
          onFocusChange: (focused) {
            if (!focused) {
              final physical = _physicalButtons;
              _syncButtons(0);
              _physicalButtons = physical;
              widget.controller.releaseHeldInputs();
            }
          },
          child: MouseRegion(
            cursor: SystemMouseCursors.precise,
            onEnter: (_) => _focusNode.requestFocus(),
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerHover: (event) => _move(event, viewport),
              onPointerMove: (event) => _move(event, viewport),
              onPointerDown: (event) {
                _focusNode.requestFocus();
                _move(event, viewport);
              },
              onPointerUp: (event) => _move(event, viewport),
              onPointerCancel: (_) {
                _syncButtons(0);
              },
              onPointerSignal: (event) {
                if (event is! PointerScrollEvent) return;
                final point = _normalized(event.localPosition, viewport);
                if (point == null) return;
                final delta = (-event.scrollDelta.dy).round();
                if (delta != 0) {
                  widget.controller
                    ..move(point.dx, point.dy)
                    ..wheel(delta);
                }
              },
              child: widget.child,
            ),
          ),
        );
      },
    );
  }
}

/// Call-screen chrome for both roles. The native Windows banner remains the
/// controllee's always-on-top kill surface; this in-app HUD is an additional
/// calm projection and the controller's always-visible local Stop.
class RemoteControlHud extends StatelessWidget {
  const RemoteControlHud({super.key, required this.state});

  static const controllerGutterWidth = 160.0;
  static const int _maxMobileTextBytes = 4096;

  final AppState state;

  bool get _touchLayout =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  String get _person {
    final callPeer = state.call?.peerId ?? '';
    return callPeer.isEmpty ? 'Your friend' : state.peerDisplayName(callPeer);
  }

  @override
  Widget build(BuildContext context) {
    final control = state.remoteControl;
    return IgnorePointer(
      ignoring: false,
      child: Stack(
        children: [
          if (control.isControlling)
            Positioned(
              top: 12,
              right: 12,
              child: SafeArea(child: _controllerBar(context)),
            )
          else if (control.phase == RemoteControlPhase.requesting)
            Positioned(
              bottom: _touchLayout ? 224 : 112,
              left: 0,
              right: 0,
              child: SafeArea(
                child: Center(child: _statusPill(context, 'Asking $_person…')),
              ),
            ),
          if (control.hostActive)
            Positioned(
              right: 12,
              bottom: _touchLayout ? 216 : 104,
              child: SafeArea(child: _hostControls(context)),
            ),
          if (state.remoteControlTrustWarning case final warning?)
            Positioned(
              top: 64,
              left: 16,
              right: 16,
              child: SafeArea(
                child: Semantics(
                  liveRegion: true,
                  child: Center(
                    child: KeyedSubtree(
                      key: const Key('remote-control-trust-warning'),
                      child: _statusPill(context, warning),
                    ),
                  ),
                ),
              ),
            ),
          if (defaultTargetPlatform == TargetPlatform.android &&
              state.call?.sharingScreen == true &&
              !control.hostActive)
            Positioned(
              left: 12,
              bottom: 260,
              child: SafeArea(
                child: OutlinedButton.icon(
                  key: const Key('remote-control-android-accessibility'),
                  onPressed: state.remoteControlAccessibilityEnabled
                      ? null
                      : () => _showAndroidSetup(context),
                  icon: Icon(
                    state.remoteControlAccessibilityEnabled
                        ? Icons.check_circle_outline_rounded
                        : Icons.accessibility_new_outlined,
                    size: 18,
                  ),
                  label: Text(
                    state.remoteControlAccessibilityEnabled
                        ? 'Remote help permission enabled'
                        : 'Set up remote help',
                  ),
                ),
              ),
            ),
          // Consent surfaces are modal trust boundaries. Paint them last so
          // no call or host control can overlap or intercept their actions.
          if (control.hostRequest != null)
            Positioned.fill(child: _hostPrompt(context, control.hostRequest!)),
          if (control.clipboardRequest != null)
            Positioned.fill(
              child: _clipboardPrompt(context, control.clipboardRequest!),
            ),
        ],
      ),
    );
  }

  Future<void> _showAndroidSetup(BuildContext context) async {
    final open = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remote help permission'),
        content: const SingleChildScrollView(
          child: Text(
            'In Android Accessibility settings, open Installed apps → '
            'Doorlight remote help and enable the service.\n\n'
            'This permission lets Doorlight attempt taps, scrolling, typing, '
            'Back, Home and Recents across this phone, including Settings, '
            'permission prompts and password fields. You still choose '
            'Allow once for each help session after sharing your screen. '
            'Android decides which actions are available.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Not now'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: const Icon(Icons.open_in_new_rounded, size: 18),
            label: const Text('Open settings'),
          ),
        ],
      ),
    );
    if (open == true && context.mounted) {
      await state.openAndroidRemoteControlSettings();
    }
  }

  Widget _controllerBar(BuildContext context) {
    final buttonSize = _touchLayout ? 40.0 : 32.0;
    return Material(
      key: const Key('remote-control-controller-hud'),
      color: context.syblColors.surfaceTop.withValues(alpha: .96),
      elevation: 8,
      borderRadius: BorderRadius.circular(24),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Tooltip(
              message: 'You are helping $_person — control is on',
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Icon(
                  key: const ValueKey('remote-control-target-icon'),
                  switch (state.remoteControlTargetPlatform) {
                    'android' => Icons.phone_android_outlined,
                    'windows' => Icons.desktop_windows_outlined,
                    _ => Icons.devices_outlined,
                  },
                  size: 17,
                  color: context.syblColors.online,
                ),
              ),
            ),
            if (state.remoteControl.grantedCapabilities.contains(
              RemoteControlCapability.clipboard,
            ))
              IconButton(
                tooltip: 'Send clipboard text',
                style: IconButton.styleFrom(
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
                constraints: BoxConstraints.tightFor(
                  width: buttonSize,
                  height: buttonSize,
                ),
                padding: EdgeInsets.zero,
                onPressed: state.sendRemoteClipboard,
                icon: const Icon(Icons.content_paste_go_outlined, size: 19),
              ),
            if (_touchLayout &&
                state.remoteControl.grantedCapabilities.contains(
                  RemoteControlCapability.text,
                ))
              IconButton(
                key: const Key('remote-control-keyboard'),
                tooltip: 'Type on their device',
                style: IconButton.styleFrom(
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
                constraints: BoxConstraints.tightFor(
                  width: buttonSize,
                  height: buttonSize,
                ),
                padding: EdgeInsets.zero,
                onPressed: () => _showTextEntry(context),
                icon: const Icon(Icons.keyboard_outlined, size: 19),
              ),
            if (RemoteGlobalAction.values.any(
              (action) => state.remoteControl.grantedCapabilities.contains(
                action.capability,
              ),
            ))
              SizedBox.square(
                dimension: buttonSize,
                child: PopupMenuButton<RemoteGlobalAction>(
                  key: const Key('remote-control-android-actions'),
                  tooltip: 'Phone controls',
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.phone_android_outlined, size: 19),
                  onSelected: state.remoteControl.action,
                  itemBuilder: (context) => [
                    for (final action in RemoteGlobalAction.values)
                      if (state.remoteControl.grantedCapabilities.contains(
                        action.capability,
                      ))
                        PopupMenuItem(
                          value: action,
                          child: Text(switch (action) {
                            RemoteGlobalAction.back => 'Back',
                            RemoteGlobalAction.home => 'Home',
                            RemoteGlobalAction.recents => 'Recents',
                          }),
                        ),
                  ],
                ),
              ),
            IconButton.filled(
              key: const Key('remote-control-stop'),
              tooltip: 'Stop control',
              style: IconButton.styleFrom(
                backgroundColor: context.syblColors.dangerFill,
                foregroundColor: context.syblColors.foregroundFor(
                  context.syblColors.dangerFill,
                ),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
              constraints: BoxConstraints.tightFor(
                width: buttonSize,
                height: buttonSize,
              ),
              padding: EdgeInsets.zero,
              onPressed: state.stopRemoteControl,
              icon: const Icon(Icons.stop_circle_outlined, size: 18),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showTextEntry(BuildContext context) async {
    var draft = '';
    var byteLength = 0;
    final text = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Type on $_person\u2019s device'),
          content: TextField(
            key: const Key('remote-control-text-field'),
            autofocus: SyblLayout.autofocusTextInput(context),
            maxLength: 1000,
            minLines: 1,
            maxLines: 4,
            textCapitalization: TextCapitalization.sentences,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              hintText: 'Text to type',
              helperText: byteLength <= _maxMobileTextBytes
                  ? 'Sent as keyboard input'
                  : null,
              errorText: byteLength > _maxMobileTextBytes
                  ? 'Keep text under $_maxMobileTextBytes UTF-8 bytes'
                  : null,
            ),
            onChanged: (value) {
              draft = value;
              byteLength = utf8.encode(value).length;
              setDialogState(() {});
            },
            onSubmitted: (value) {
              if (value.isNotEmpty && byteLength <= _maxMobileTextBytes) {
                Navigator.pop(dialogContext, value);
              }
            },
          ),
          actions: [
            TextButton(
              key: const Key('remote-control-text-cancel'),
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const Key('remote-control-text-send'),
              onPressed: draft.isEmpty || byteLength > _maxMobileTextBytes
                  ? null
                  : () => Navigator.pop(dialogContext, draft),
              child: const Text('Send'),
            ),
          ],
        ),
      ),
    );
    if (text != null && text.isNotEmpty) {
      state.remoteControl.text(text);
    }
  }

  Widget _hostControls(BuildContext context) {
    final control = state.remoteControl;
    final paused = control.hostPhase == RemoteControlHostPhase.suspended;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: (MediaQuery.sizeOf(context).width - 24).clamp(0, 320),
      ),
      child: Material(
        color: context.syblColors.surfaceTop,
        elevation: 8,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                liveRegion: true,
                child: Text(
                  paused
                      ? '$_person is helping — control is paused'
                      : '$_person is helping — control is on',
                ),
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                key: const Key('remote-control-host-stop'),
                style: FilledButton.styleFrom(
                  backgroundColor: context.syblColors.dangerFill,
                  foregroundColor: context.syblColors.foregroundFor(
                    context.syblColors.dangerFill,
                  ),
                ),
                onPressed: state.stopHostedRemoteControl,
                icon: const Icon(Icons.stop_circle_outlined, size: 18),
                label: const Text('Stop control'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _hostPrompt(BuildContext context, RemoteControlHostRequest request) {
    return ColoredBox(
      color: Colors.black.withValues(alpha: .58),
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Material(
                color: context.syblColors.surface,
                borderRadius: BorderRadius.circular(18),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.desktop_access_disabled_outlined,
                        color: context.syblColors.amber,
                        size: 32,
                      ),
                      const SizedBox(height: 14),
                      Text(
                        'Allow control of your computer?',
                        style: context.syblColors.display.copyWith(
                          fontSize: 22,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Authenticated account\n${request.controllerAccountId}\n'
                        'Device\n${request.controllerDeviceId}',
                        key: const Key('remote-control-authenticated-identity'),
                        textDirection: TextDirection.ltr,
                        style: TextStyle(color: context.syblColors.ink),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'They can use your mouse and keyboard in apps you’re signed '
                        'into. They’ll see only your shared screen; typing goes to '
                        'the focused app. This is for this session, and you can '
                        'stop control at any time.',
                        style: TextStyle(
                          color: context.syblColors.muted,
                          height: 1.45,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Some protected system screens can’t be controlled.',
                        style: TextStyle(
                          color: context.syblColors.muted,
                          height: 1.45,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        alignment: WrapAlignment.end,
                        children: [
                          TextButton(
                            key: const Key('remote-control-deny'),
                            autofocus: true,
                            onPressed: () => state.denyRemoteControl(request),
                            child: const Text('Not now'),
                          ),
                          FilledButton(
                            key: const Key('remote-control-allow-once'),
                            onPressed: () => state.allowRemoteControl(request),
                            child: const Text('Allow once'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _clipboardPrompt(
    BuildContext context,
    RemoteClipboardRequest request,
  ) {
    return ColoredBox(
      color: Colors.black.withValues(alpha: .58),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Material(
            color: context.syblColors.surface,
            borderRadius: BorderRadius.circular(18),
            child: Padding(
              padding: const EdgeInsets.all(22),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$_person wants to paste this',
                    style: context.syblColors.display.copyWith(fontSize: 20),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(maxHeight: 160),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: context.syblColors.surfaceHi,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: context.syblColors.line),
                    ),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        request.preview,
                        style: TextStyle(color: context.syblColors.ink),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${request.byteLength} UTF-8 bytes · text only',
                    style: TextStyle(
                      color: context.syblColors.faint,
                      fontSize: 11,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      // Both decisions carry the receiver-owned request object
                      // being drawn here. The peer's reusable wire id is not a
                      // consent identity.
                      TextButton(
                        key: const Key('remote-clipboard-reject'),
                        autofocus: true,
                        onPressed: () => state.rejectRemoteClipboard(request),
                        child: const Text('No'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        key: const Key('remote-clipboard-accept'),
                        onPressed: () => state.acceptRemoteClipboard(request),
                        child: const Text('Allow paste'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _statusPill(BuildContext context, String label) {
    return Material(
      color: context.syblColors.surfaceTop.withValues(alpha: .96),
      borderRadius: BorderRadius.circular(22),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Text(
          label,
          style: TextStyle(
            color: context.syblColors.muted,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

int? _windowsVirtualKey(LogicalKeyboardKey key) {
  final named = <LogicalKeyboardKey, int>{
    LogicalKeyboardKey.backspace: 0x08,
    LogicalKeyboardKey.tab: 0x09,
    LogicalKeyboardKey.enter: 0x0d,
    LogicalKeyboardKey.shiftLeft: 0x10,
    LogicalKeyboardKey.shiftRight: 0x10,
    LogicalKeyboardKey.controlLeft: 0x11,
    LogicalKeyboardKey.controlRight: 0x11,
    LogicalKeyboardKey.altLeft: 0x12,
    LogicalKeyboardKey.altRight: 0x12,
    LogicalKeyboardKey.pause: 0x13,
    LogicalKeyboardKey.capsLock: 0x14,
    LogicalKeyboardKey.escape: 0x1b,
    LogicalKeyboardKey.space: 0x20,
    LogicalKeyboardKey.pageUp: 0x21,
    LogicalKeyboardKey.pageDown: 0x22,
    LogicalKeyboardKey.end: 0x23,
    LogicalKeyboardKey.home: 0x24,
    LogicalKeyboardKey.arrowLeft: 0x25,
    LogicalKeyboardKey.arrowUp: 0x26,
    LogicalKeyboardKey.arrowRight: 0x27,
    LogicalKeyboardKey.arrowDown: 0x28,
    LogicalKeyboardKey.insert: 0x2d,
    LogicalKeyboardKey.delete: 0x2e,
    LogicalKeyboardKey.metaLeft: 0x5b,
    LogicalKeyboardKey.metaRight: 0x5c,
    LogicalKeyboardKey.numpad0: 0x60,
    LogicalKeyboardKey.numpad1: 0x61,
    LogicalKeyboardKey.numpad2: 0x62,
    LogicalKeyboardKey.numpad3: 0x63,
    LogicalKeyboardKey.numpad4: 0x64,
    LogicalKeyboardKey.numpad5: 0x65,
    LogicalKeyboardKey.numpad6: 0x66,
    LogicalKeyboardKey.numpad7: 0x67,
    LogicalKeyboardKey.numpad8: 0x68,
    LogicalKeyboardKey.numpad9: 0x69,
    LogicalKeyboardKey.numpadMultiply: 0x6a,
    LogicalKeyboardKey.numpadAdd: 0x6b,
    LogicalKeyboardKey.numpadSubtract: 0x6d,
    LogicalKeyboardKey.numpadDecimal: 0x6e,
    LogicalKeyboardKey.numpadDivide: 0x6f,
    LogicalKeyboardKey.f1: 0x70,
    LogicalKeyboardKey.f2: 0x71,
    LogicalKeyboardKey.f3: 0x72,
    LogicalKeyboardKey.f4: 0x73,
    LogicalKeyboardKey.f5: 0x74,
    LogicalKeyboardKey.f6: 0x75,
    LogicalKeyboardKey.f7: 0x76,
    LogicalKeyboardKey.f8: 0x77,
    LogicalKeyboardKey.f9: 0x78,
    LogicalKeyboardKey.f10: 0x79,
    LogicalKeyboardKey.f11: 0x7a,
    LogicalKeyboardKey.f12: 0x7b,
    LogicalKeyboardKey.numLock: 0x90,
    LogicalKeyboardKey.scrollLock: 0x91,
  };
  final direct = named[key];
  if (direct != null) return direct;
  final label = key.keyLabel;
  if (label.length != 1) return null;
  final code = label.toUpperCase().codeUnitAt(0);
  if ((code >= 0x30 && code <= 0x39) || (code >= 0x41 && code <= 0x5a)) {
    return code;
  }
  return const <String, int>{
    ';': 0xba,
    '=': 0xbb,
    ',': 0xbc,
    '-': 0xbd,
    '.': 0xbe,
    '/': 0xbf,
    '`': 0xc0,
    '[': 0xdb,
    '\\': 0xdc,
    ']': 0xdd,
    "'": 0xde,
  }[label];
}
