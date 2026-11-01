import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../theme.dart';
import 'gravity.dart';
import 'linked_devices_dialog.dart';
import 'sybl_ui.dart';

/// The same profile controls and palette on desktop and phones.
class SettingsProfile extends StatefulWidget {
  const SettingsProfile({
    super.key,
    required this.state,
    required this.onEditName,
    required this.onEditPicture,
    required this.onRemovePicture,
    required this.onCopyId,
    required this.onShareId,
    this.onAddFriend,
  });

  final AppState state;
  final VoidCallback onEditName;
  final VoidCallback onEditPicture;
  final VoidCallback onRemovePicture;
  final VoidCallback onCopyId;
  final VoidCallback onShareId;
  final VoidCallback? onAddFriend;

  @override
  State<SettingsProfile> createState() => _SettingsProfileState();
}

class _SettingsProfileState extends State<SettingsProfile> {
  final _palette = MenuController();
  (String?, int)? _owner;
  (String?, int)? _paletteOwner;
  int? _deviceCount;
  int _loadRevision = 0;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_stateChanged);
    _loadDevices();
  }

  @override
  void didUpdateWidget(SettingsProfile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.removeListener(_stateChanged);
      widget.state.addListener(_stateChanged);
      _palette.close();
      _loadDevices();
    }
  }

  void _stateChanged() {
    if (_owner != widget.state.linkedDeviceOwner) {
      _palette.close();
      _loadDevices();
    }
    if (mounted) setState(() {});
  }

  Future<void> _loadDevices() async {
    final owner = _owner = widget.state.linkedDeviceOwner;
    final revision = ++_loadRevision;
    _deviceCount = null;
    if (owner.$1 == null || owner.$1!.isEmpty) return;
    try {
      final devices = await widget.state.listKnownDevices();
      if (!mounted ||
          revision != _loadRevision ||
          owner != widget.state.linkedDeviceOwner) {
        return;
      }
      setState(() => _deviceCount = devices.length);
    } catch (_) {
      // The dialog owns retry/error recovery; unknown is not zero devices.
    }
  }

  @override
  void dispose() {
    widget.state.removeListener(_stateChanged);
    _loadRevision++;
    super.dispose();
  }

  Widget _action(
    String tooltip,
    IconData icon,
    VoidCallback? action, {
    Key? key,
  }) => Gravity(
    child: IconButton(
      key: key,
      tooltip: tooltip,
      onPressed: action,
      icon: Icon(icon, size: 19),
      style: IconButton.styleFrom(minimumSize: const Size(44, 48)),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final colors = context.syblColors;
    final friends = state.friendsByIdentityColor;
    final recommended = IdentityColor.recommended(
      friends.entries.expand((entry) => entry.value.map((_) => entry.key)),
      // Choosing a swatch must not reshuffle the suggestions underneath it.
      current: IdentityColor.automaticFor(state.jamiId),
    );
    final colorDuration = state.chatMotionEnabled
        ? const Duration(milliseconds: 220)
        : Duration.zero;
    final menuWidth = math.min(312.0, MediaQuery.sizeOf(context).width - 48);
    final enabled = state.settingsControlsEnabled;
    final colorEnabled = state.canSetIdentityColor;
    final id = state.jamiId;
    final shortId = id.length > 20
        ? '${id.substring(0, 8)}…${id.substring(id.length - 7)}'
        : id;
    return Column(
      key: const ValueKey('settings-profile'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: 80,
              height: 88,
              child: Stack(
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: SyblAvatar(
                      label: state.displayName,
                      color: colors.sage,
                      imageBase64: state.profileAvatarBase64,
                      size: 72,
                    ),
                  ),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: MenuAnchor(
                      menuChildren: [
                        MenuItemButton(
                          onPressed: state.changingProfileAvatar || !enabled
                              ? null
                              : widget.onEditPicture,
                          child: const Text('Change picture'),
                        ),
                        if (state.profileAvatarBase64.isNotEmpty)
                          MenuItemButton(
                            onPressed: state.changingProfileAvatar || !enabled
                                ? null
                                : widget.onRemovePicture,
                            child: const Text('Remove picture'),
                          ),
                      ],
                      builder: (context, controller, _) => IconButton(
                        tooltip: 'Choose and crop a profile picture',
                        onPressed: state.changingProfileAvatar || !enabled
                            ? null
                            : state.profileAvatarBase64.isEmpty
                            ? widget.onEditPicture
                            : () => controller.isOpen
                                  ? controller.close()
                                  : controller.open(),
                        style: IconButton.styleFrom(
                          backgroundColor: colors.surfaceHi,
                          side: BorderSide(color: colors.lineStrong),
                          minimumSize: const Size(44, 44),
                        ),
                        icon: const Icon(Icons.photo_camera_outlined, size: 18),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          state.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: colors.display.copyWith(fontSize: 22),
                        ),
                      ),
                      _action(
                        'Edit name',
                        Icons.edit_rounded,
                        state.changingDisplayName || !enabled
                            ? null
                            : widget.onEditName,
                        key: const ValueKey('edit-display-name'),
                      ),
                    ],
                  ),
                  MenuAnchor(
                    controller: _palette,
                    onOpen: () => _paletteOwner = state.linkedDeviceOwner,
                    style: MenuStyle(
                      alignment: AlignmentDirectional.bottomEnd,
                      shape: const WidgetStatePropertyAll(
                        RoundedRectangleBorder(
                          borderRadius: BorderRadius.all(Radius.circular(12)),
                        ),
                      ),
                      elevation: const WidgetStatePropertyAll(3),
                      backgroundColor: WidgetStatePropertyAll(colors.surface),
                      padding: const WidgetStatePropertyAll(EdgeInsets.all(12)),
                      side: WidgetStatePropertyAll(
                        BorderSide(color: colors.lineStrong),
                      ),
                    ),
                    menuChildren: [
                      SizedBox(
                        width: menuWidth,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxHeight: MediaQuery.sizeOf(context).height * .65,
                          ),
                          child: SingleChildScrollView(
                            primary: false,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    4,
                                    4,
                                    4,
                                    10,
                                  ),
                                  child: Text(
                                    'Your color',
                                    style: colors.display.copyWith(
                                      fontSize: 19,
                                    ),
                                  ),
                                ),
                                Wrap(
                                  key: const ValueKey('identity-color-palette'),
                                  runSpacing: 4,
                                  children: [
                                    for (final color in IdentityColor.palette)
                                      SizedBox(
                                        width: menuWidth / 6,
                                        height: 52,
                                        child: _ProfileColor(
                                          color: color,
                                          selected:
                                              color == state.identityColor,
                                          duration: colorDuration,
                                          friends: friends[color] ?? const [],
                                          onPressed: !colorEnabled
                                              ? null
                                              : () {
                                                  if (_paletteOwner !=
                                                          state
                                                              .linkedDeviceOwner ||
                                                      !state
                                                          .canSetIdentityColor) {
                                                    return;
                                                  }
                                                  _palette.close();
                                                  state.setIdentityColor(color);
                                                },
                                        ),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                    builder: (context, controller, _) => LayoutBuilder(
                      builder: (context, constraints) {
                        final width = math.min(320.0, constraints.maxWidth);
                        final moreWidth =
                            48 +
                            20 *
                                (MediaQuery.textScalerOf(context).scale(1) - 1);
                        final showMore = width >= 44 + moreWidth;
                        final separate =
                            showMore &&
                            !recommended.contains(state.identityColor);
                        final count =
                            ((width - moreWidth - (separate ? 61 : 0)) / 28)
                                .floor()
                                .clamp(separate ? 0 : 1, separate ? 5 : 6);
                        final shown = showMore
                            ? recommended.take(count).toList()
                            : [state.identityColor];
                        if (!separate && !shown.contains(state.identityColor)) {
                          shown[shown.length - 1] = state.identityColor;
                          shown.sort(
                            (a, b) => recommended
                                .indexOf(a)
                                .compareTo(recommended.indexOf(b)),
                          );
                        }
                        return SizedBox(
                          key: const ValueKey('identity-color-row'),
                          width: width,
                          child: AnimatedSwitcher(
                            duration: colorDuration,
                            switchInCurve: Curves.easeOutCubic,
                            switchOutCurve: Curves.easeInCubic,
                            layoutBuilder: (current, previous) => Stack(
                              alignment: Alignment.centerLeft,
                              children: [
                                for (final child in previous)
                                  Positioned(
                                    left: 0,
                                    top: 0,
                                    child: ExcludeFocus(
                                      child: ExcludeSemantics(
                                        child: IgnorePointer(child: child),
                                      ),
                                    ),
                                  ),
                                ?current,
                              ],
                            ),
                            child: SizedBox(
                              key: ValueKey(separate),
                              width: width,
                              child: Row(
                                children: [
                                  if (separate)
                                    SizedBox(
                                      width: 44,
                                      child: _ProfileColor(
                                        color: state.identityColor,
                                        selected: true,
                                        duration: colorDuration,
                                        friends: const [],
                                        compact: true,
                                        onPressed: !colorEnabled
                                            ? null
                                            : () => controller.isOpen
                                                  ? controller.close()
                                                  : controller.open(),
                                      ),
                                    ),
                                  if (separate && shown.isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                      ),
                                      child: SizedBox(
                                        key: const ValueKey(
                                          'identity-color-divider',
                                        ),
                                        width: 1,
                                        height: 20,
                                        child: ColoredBox(
                                          color: colors.lineStrong,
                                        ),
                                      ),
                                    ),
                                  for (final color in shown)
                                    Expanded(
                                      child: _ProfileColor(
                                        color: color,
                                        selected: color == state.identityColor,
                                        duration: colorDuration,
                                        friends: const [],
                                        compact: true,
                                        onPressed: !colorEnabled
                                            ? null
                                            : color == state.identityColor
                                            ? () => controller.isOpen
                                                  ? controller.close()
                                                  : controller.open()
                                            : () =>
                                                  state.setIdentityColor(color),
                                      ),
                                    ),
                                  if (showMore)
                                    TextButton(
                                      key: const ValueKey(
                                        'identity-color-more',
                                      ),
                                      onPressed: !colorEnabled
                                          ? null
                                          : () => controller.isOpen
                                                ? controller.close()
                                                : controller.open(),
                                      style: TextButton.styleFrom(
                                        foregroundColor: colors.muted,
                                        minimumSize: const Size(48, 48),
                                        padding: const EdgeInsets.only(left: 6),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Text(
                                            'More',
                                            style: TextStyle(fontSize: 12),
                                          ),
                                          const Icon(
                                            Icons.chevron_right_rounded,
                                            size: 16,
                                          ),
                                        ],
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Friend ID',
                    style: TextStyle(color: colors.ink, fontSize: 12),
                  ),
                  const SizedBox(height: 3),
                  Tooltip(
                    message: id,
                    child: Text(
                      id.isEmpty ? 'Waiting for your identity' : shortId,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.muted,
                        fontSize: 11,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ],
              ),
            ),
            _action(
              'Add friend',
              Icons.person_add_alt_1_outlined,
              widget.onAddFriend,
              key: const ValueKey('settings-add-friend'),
            ),
            _action(
              'Copy your Friend ID',
              Icons.copy_rounded,
              id.isEmpty ? null : widget.onCopyId,
            ),
            _action(
              'Show your invitation QR code',
              Icons.qr_code_2_rounded,
              id.isEmpty ? null : widget.onShareId,
              key: const ValueKey('show-jami-qr'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Semantics(
          button: true,
          child: Material(
            color: colors.surfaceHi.withValues(alpha: .5),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: BorderSide(color: colors.line),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: const ValueKey('manage-linked-devices'),
              onTap: id.isEmpty
                  ? null
                  : () async {
                      await showLinkedDevicesDialog(context, state: state);
                      if (mounted) _loadDevices();
                    },
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Icon(Icons.devices_rounded, color: colors.muted, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Devices',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: colors.ink),
                      ),
                    ),
                    if (_deviceCount != null)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: colors.surfaceTop,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          '$_deviceCount linked',
                          style: TextStyle(color: colors.muted, fontSize: 11),
                        ),
                      ),
                    const SizedBox(width: 4),
                    Icon(
                      Icons.chevron_right_rounded,
                      color: colors.muted,
                      size: 20,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ProfileColor extends StatelessWidget {
  const _ProfileColor({
    required this.color,
    required this.selected,
    required this.friends,
    required this.duration,
    this.compact = false,
    this.onPressed,
  });

  final IdentityColor color;
  final bool selected;
  final List<FriendState> friends;
  final bool compact;
  final Duration duration;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.syblColors;
    final fill = Color(color.argb);
    final label =
        '${color.label}${compact && selected ? '. Change color' : ''}'
        '${friends.isEmpty ? '' : '. Used by ${friends.map((friend) => friend.displayName).join(', ')}'}';
    final dot = SizedBox(
      height: 48,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AnimatedContainer(
            duration: duration,
            curve: Curves.easeOutCubic,
            width: compact ? 24 : 32,
            height: compact ? 24 : 32,
            decoration: BoxDecoration(
              color: fill,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? colors.ink : Colors.transparent,
                width: 1.5,
              ),
            ),
            child: AnimatedSwitcher(
              duration: duration,
              child: selected
                  ? Icon(
                      key: const ValueKey('color-selected'),
                      Icons.check_rounded,
                      color: colors.foregroundFor(fill),
                      size: compact ? 14 : 18,
                    )
                  : const SizedBox.shrink(),
            ),
          ),
          if (friends.isNotEmpty)
            Positioned(
              key: ValueKey('identity-color-used-${color.storageValue}'),
              right: 0,
              bottom: 0,
              child: ExcludeSemantics(
                child: SizedBox(
                  width: friends.length == 1 ? 16 : 27,
                  height: 16,
                  child: Stack(
                    children: [
                      for (
                        var index = 0;
                        index < math.min(2, friends.length);
                        index++
                      )
                        Positioned(
                          left: index * 11.0,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: colors.surface,
                                width: 1,
                              ),
                            ),
                            child: SyblAvatar(
                              label: friends[index].displayName,
                              imageBase64: friends[index].avatarBase64,
                              color: fill,
                              size: 14,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: label,
      selected: selected,
      child: Tooltip(
        message: label,
        child: InkResponse(
          key: ValueKey(
            'identity-color-${compact ? 'shortcut-' : ''}${color.storageValue}',
          ),
          onTap: onPressed,
          radius: 24,
          customBorder: const CircleBorder(),
          child: dot,
        ),
      ),
    );
  }
}
