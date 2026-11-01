import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../theme.dart';

IconData audioOutputIcon(AppState state, {required bool speakerOn}) =>
    state.speakerControlAvailable && !speakerOn
    ? Icons.hearing_rounded
    : Icons.volume_up_rounded;

// The daemon marks the system default with a translation token. The device
// index stays untouched; only the shared user-facing label is translated.
String audioOutputLabel(String name) =>
    name.replaceAll('{{Default}}', 'System default');

Future<void> showAudioOutputPicker(BuildContext context, AppState state) async {
  final devices = await state.audioOutputs();
  if (!context.mounted) return;
  final index = await _showAudioDeviceMenu(
    context,
    devices.map(audioOutputLabel).toList(),
  );
  if (index != null) await state.selectAudioOutput(index);
}

Future<void> showAudioInputPicker(BuildContext context, AppState state) async {
  final devices = await state.audioInputs();
  if (!context.mounted) return;
  final index = await _showAudioDeviceMenu(context, devices);
  if (index != null) await state.selectAudioInput(index);
}

Future<int?> _showAudioDeviceMenu(
  BuildContext context,
  List<String> devices,
) async {
  if (!context.mounted || devices.isEmpty) return null;
  final box = context.findRenderObject() as RenderBox?;
  final origin = box == null
      ? Offset.zero
      : box.localToGlobal(const Offset(0, -8));
  final screen = MediaQuery.sizeOf(context);
  return showMenu<int>(
    context: context,
    color: context.syblColors.surfaceTop,
    position: RelativeRect.fromLTRB(
      origin.dx,
      (origin.dy - 48.0 * devices.length).clamp(24, screen.height),
      (screen.width - origin.dx).clamp(0, screen.width),
      (screen.height - origin.dy).clamp(0, screen.height),
    ),
    items: [
      for (var index = 0; index < devices.length; index++)
        PopupMenuItem(
          value: index,
          child: Text(
            devices[index],
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
    ],
  );
}
