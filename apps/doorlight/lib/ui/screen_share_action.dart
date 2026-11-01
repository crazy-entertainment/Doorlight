import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../state/outgoing_video.dart';
import '../theme.dart';

/// Starts or stops screen sharing for [call] while preserving call identity.
///
/// Windows exposes libjami's monitor list before changing the outgoing media
/// source. Touch platforms delegate source selection to their native capture
/// consent flow. Keeping this in one presentation helper prevents the compact
/// Windows call strip and the immersive call surface from drifting apart.
Future<void> toggleScreenShareWithPicker(
  BuildContext context,
  AppState state,
  CallSession call,
) async {
  bool stillCurrent() {
    final current = state.call;
    return identical(current, call) &&
        current?.callId == call.callId &&
        current?.connected == true;
  }

  if (call.sharingScreen ||
      Theme.of(context).platform != TargetPlatform.windows) {
    await state.toggleScreenShare(expectedCallId: call.callId);
    return;
  }

  final sources = await state.listScreenSources(expectedCallId: call.callId);
  if (!context.mounted || !stillCurrent() || sources.isEmpty) return;

  final selected = await _chooseScreen(context, sources);

  if (selected != null && stillCurrent()) {
    await state.toggleScreenShare(
      expectedCallId: call.callId,
      sourceId: selected.id,
    );
  }
}

Future<void> toggleGroupScreenShareWithPicker(
  BuildContext context,
  AppState state,
  GroupCallSession call,
) async {
  bool stillCurrent() => identical(state.groupCall, call) && call.connected;

  if (call.screenShare ||
      Theme.of(context).platform != TargetPlatform.windows) {
    await state.toggleGroupScreenShare();
    return;
  }
  final sources = await state.listGroupScreenSources();
  if (!context.mounted || !stillCurrent() || sources.isEmpty) return;
  final selected = await _chooseScreen(context, sources);
  if (selected != null && stillCurrent()) {
    await state.toggleGroupScreenShare(sourceId: selected.id);
  }
}

Future<ScreenSource?> _chooseScreen(
  BuildContext context,
  List<ScreenSource> sources,
) async {
  if (sources.length == 1) return sources.single;
  return showModalBottomSheet<ScreenSource>(
    context: context,
    backgroundColor: context.syblColors.surface,
    builder: (sheetContext) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.7,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  'Choose a screen',
                  style: sheetContext.syblColors.display.copyWith(fontSize: 17),
                ),
              ),
              for (final source in sources)
                ListTile(
                  minVerticalPadding: 10,
                  leading: Icon(
                    source.primary
                        ? Icons.desktop_windows_outlined
                        : Icons.monitor_outlined,
                    color: sheetContext.syblColors.amber,
                  ),
                  title: Text(
                    source.label,
                    style: TextStyle(color: sheetContext.syblColors.ink),
                  ),
                  subtitle: Text(
                    '${source.width} × ${source.height}',
                    style: TextStyle(color: sheetContext.syblColors.muted),
                  ),
                  onTap: () => Navigator.pop(sheetContext, source),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}
