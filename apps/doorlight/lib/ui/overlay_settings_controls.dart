import 'package:flutter/material.dart';

import '../state/app_state.dart';

/// Desktop controls use the same document and revision as the Game Bar editors.
class OverlaySettingsControls extends StatefulWidget {
  const OverlaySettingsControls({super.key, required this.state});
  final AppState state;
  @override
  State<OverlaySettingsControls> createState() =>
      _OverlaySettingsControlsState();
}

class _OverlaySettingsControlsState extends State<OverlaySettingsControls> {
  String? error;
  bool revoking = false;

  Future<void> _hideChat() async {
    if (revoking) return;
    setState(() => revoking = true);
    var hidden = false;
    try {
      hidden = await widget.state.revokeWidgetChatConsent();
    } on Object {
      // Privacy controls stay available for a retry after a failed save.
    }
    if (mounted) {
      setState(() {
        revoking = false;
        error = hidden ? null : 'Couldn’t hide chat. Try again.';
      });
    }
  }

  Future<void> _set(String key, Object value) async {
    final settings = widget.state.overlaySettings;
    final revision = settings.revision;
    final next = {...settings.values, key: value};
    var saved = false;
    try {
      saved = await settings.replace(next, expectedRevision: revision);
    } on Object {
      // Retain the last confirmed value and let the user retry.
    }
    if (mounted) {
      setState(
        () => error = saved ? null : 'Couldn’t save the change. Try again.',
      );
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.state.overlaySettings,
    builder: (context, _) {
      final settings = widget.state.overlaySettings;
      final enabled =
          settings.available &&
          !settings.busy &&
          widget.state.appearanceBridgeWritable;
      final values = settings.values;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 10),
          if (settings.imported)
            for (final option in const {
              'chat.names': 'Chat names',
              'chat.avatars': 'Chat avatars',
              'chat.text': 'Message text',
              'chat.writable': 'Quick chat',
            }.entries)
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: Text(option.value),
                value: values[option.key] != false,
                onChanged: enabled ? (value) => _set(option.key, value) : null,
              ),
          TextButton(
            onPressed: revoking ? null : _hideChat,
            child: const Text('Hide chat in Game Bar'),
          ),
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      );
    },
  );
}
