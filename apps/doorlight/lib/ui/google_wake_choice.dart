import 'package:flutter/material.dart';

import '../state/app_state.dart';
import 'notice.dart';

Future<void> showGoogleWakeChoice(BuildContext context, AppState state) async {
  final owner = state.googleConsentOwner;
  if (owner == null) return;
  final android = Theme.of(context).platform == TargetPlatform.android;
  final action = state.captureConversationAction(
    isCurrent: () => context.mounted && state.googleConsentOwner == owner,
  );
  final choice = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(
        android
            ? 'Get alerts while Doorlight sleeps?'
            : 'Wake friends’ phones?',
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              android
                  ? 'Google can wake Doorlight when someone messages or calls. '
                        'It sees when alerts are sent, but not what they say.\n\n'
                        'Without it, Doorlight needs to keep running in the background.'
                  : 'Google can wake your friends’ phones when you message or call. '
                        'It sees when alerts are sent, but not what they say.',
            ),
            const ExpansionTile(
              title: Text('What gets shared?'),
              tilePadding: EdgeInsets.zero,
              children: [
                Text(
                  'Google receives an identifier for the receiving app installation and '
                  'a wake signal. Google and our Cloudflare relay also process '
                  'connection details, such as IP addresses and timing. '
                  'Your messages, photos and calls are not included in the signal.\n\n'
                  'On Android this allows both receiving and sending wake signals. '
                  'This does not enable Google Nearby discovery.',
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Keep Google off'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Use Google'),
        ),
      ],
    ),
  );
  if (choice == null ||
      !context.mounted ||
      !state.ownsConversationAction(action)) {
    return;
  }
  if (!await state.setReliableBackgroundNotifications(choice) &&
      context.mounted &&
      state.settingsError != null) {
    showNotice(state.settingsError!);
  }
}

Future<void> showGoogleNearbyChoice(
  BuildContext context,
  AppState state,
) async {
  final owner = state.googleConsentOwner;
  if (owner == null) return;
  final action = state.captureConversationAction(
    isCurrent: () => context.mounted && state.googleConsentOwner == owner,
  );
  final choice = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Let Google help Sonar?'),
      content: const Text(
        'Google Nearby adds another way to find people when you reveal yourself. '
        'Its SDK collects usage and device diagnostics.\n\n'
        'Keep it off to use local network and Bluetooth only.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Keep Google off'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Use Google Nearby'),
        ),
      ],
    ),
  );
  if (choice == null ||
      !context.mounted ||
      !state.ownsConversationAction(action)) {
    return;
  }
  if (!await state.setGoogleNearbyAllowed(choice) &&
      context.mounted &&
      state.settingsError != null) {
    showNotice(state.settingsError!);
  }
}
