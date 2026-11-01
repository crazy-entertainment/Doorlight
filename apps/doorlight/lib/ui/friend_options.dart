import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/app_settings.dart';
import '../state/app_state.dart';
import 'gravity.dart';

Future<void> showFriendOptions(
  BuildContext context,
  AppState state,
  String peer,
) {
  final owner = state.linkedDeviceOwner;
  return showDialog<void>(
    context: context,
    builder: (_) => FriendOptionsDialog(state: state, peer: peer, owner: owner),
  );
}

class FriendOptionsDialog extends StatefulWidget {
  FriendOptionsDialog({
    super.key,
    required this.state,
    required this.peer,
    Object? owner,
  }) : owner = owner ?? state.linkedDeviceOwner;
  final AppState state;
  final String peer;
  final Object owner;

  @override
  State<FriendOptionsDialog> createState() => _FriendOptionsDialogState();
}

class _FriendOptionsDialogState extends State<FriendOptionsDialog> {
  late final Object _owner;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _owner = widget.owner;
  }

  bool get _current =>
      _owner == widget.state.linkedDeviceOwner &&
      widget.state.canManageFriendPreferences &&
      widget.state.friends[widget.peer]?.confirmed == true;

  Future<void> _save(Future<bool> Function() action) async {
    if (!_current || _saving || !widget.state.settingsControlsEnabled) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    var saved = false;
    try {
      saved = await action();
    } catch (_) {
      /* Show a local retry error. */
    }
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (!saved && _current) {
        _error = 'Could not save this preference. Try again.';
      }
    });
  }

  Widget _choice<T>(
    String title,
    String helper,
    T value,
    List<T> values,
    String Function(T) label,
    Future<bool> Function(T) save, {
    bool enabled = true,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Gravity(
          child: Text(title, style: Theme.of(context).textTheme.titleSmall),
        ),
        const SizedBox(height: 4),
        Gravity(
          child: Text(helper, style: Theme.of(context).textTheme.bodySmall),
        ),
        const SizedBox(height: 8),
        Gravity(
          child: DropdownButtonFormField<T>(
            key: ValueKey('$title:$value'),
            initialValue: value,
            isExpanded: true,
            itemHeight: null,
            decoration: InputDecoration(
              labelText: title,
              border: const OutlineInputBorder(),
            ),
            items: [
              for (final item in values)
                DropdownMenuItem(value: item, child: Text(label(item))),
            ],
            onChanged:
                enabled &&
                    _current &&
                    !_saving &&
                    widget.state.settingsControlsEnabled
                ? (next) {
                    if (next != null) _save(() => save(next));
                  }
                : null,
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.state,
    builder: (context, _) {
      final state = widget.state;
      final friend = state.friends[widget.peer];
      final name = friend?.displayName.trim() ?? '';
      final preference = state.friendPreferencesFor(widget.peer);
      final microphone = state.microphoneModeForFriend(widget.peer);
      final micChoice = microphone.source == MicrophoneModeSource.globalDefault
          ? 'default'
          : microphone.mode == MicrophoneMode.pushToTalk
          ? 'ptt'
          : 'open';
      final review = state.appSettings.friendPreferencesReviewRequired;
      return AlertDialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        title: Gravity(
          child: Text(
            _current
                ? (name.isEmpty ? 'Friend options' : name)
                : 'Friend options unavailable',
          ),
        ),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: _current
                  ? [
                      const Gravity(
                        child: Text('These choices apply on this device.'),
                      ),
                      const SizedBox(height: 20),
                      if (review)
                        const Padding(
                          padding: EdgeInsets.only(bottom: 20),
                          child: Gravity(
                            child: Text(
                              'Restored friend preferences need review in Settings → Notifications. Message alerts and Holograms are paused.',
                            ),
                          ),
                        ),
                      _choice(
                        'Holograms',
                        'Live sticker surprises. Your privacy protections still apply.',
                        preference.holograms,
                        FriendHologramPreference.values,
                        (value) => switch (value) {
                          FriendHologramPreference.useGlobalDefault =>
                            'Use global default',
                          FriendHologramPreference.allow => 'Allow',
                          FriendHologramPreference.block => 'Block',
                        },
                        (value) => state.setFriendPreferences(
                          widget.peer,
                          preference.copyWith(holograms: value),
                        ),
                        enabled: !review,
                      ),
                      _choice(
                        'Message alerts',
                        'Muting messages does not mute calls or Holograms.',
                        preference.messageAlerts,
                        FriendMessageAlertPreference.values,
                        (value) => value == FriendMessageAlertPreference.mute
                            ? 'Mute'
                            : 'Use global default',
                        (value) => state.setFriendPreferences(
                          widget.peer,
                          preference.copyWith(messageAlerts: value),
                        ),
                        enabled: !review,
                      ),
                      _choice(
                        'Microphone',
                        'Used for calls with this friend.',
                        micChoice,
                        const ['default', 'open', 'ptt'],
                        (value) => switch (value) {
                          'open' => 'Open mic',
                          'ptt' => 'Push-to-talk',
                          _ => 'Use global default',
                        },
                        (value) => state.setFriendMicrophoneMode(
                          widget.peer,
                          switch (value) {
                            'open' => MicrophoneMode.open,
                            'ptt' => MicrophoneMode.pushToTalk,
                            _ => null,
                          },
                        ),
                      ),
                      if (_error != null)
                        Semantics(
                          liveRegion: true,
                          child: Gravity(
                            child: Text(
                              _error!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                        ),
                      const Gravity(child: Text('Friend ID')),
                      const SizedBox(height: 5),
                      Gravity(
                        child: SelectableText(
                          widget.peer,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ]
                  : [
                      const Gravity(
                        child: Text(
                          'The account or friend changed. Close this window and open their options again.',
                        ),
                      ),
                    ],
            ),
          ),
        ),
        actions: [
          if (_current)
            Gravity(
              child: TextButton.icon(
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: widget.peer)),
                icon: const Icon(Icons.copy_rounded, size: 17),
                label: const Text('Copy ID'),
              ),
            ),
          Gravity(
            child: FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Done'),
            ),
          ),
        ],
      );
    },
  );
}
