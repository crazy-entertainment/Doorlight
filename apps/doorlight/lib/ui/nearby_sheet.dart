import 'dart:async';

import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../state/nearby.dart';
import '../theme.dart';
import 'friend_connection_page.dart';
import 'gravity.dart';
import 'google_wake_choice.dart';
import 'notice.dart';
import 'nearby_stage.dart';
import 'sonar_warp.dart';

/// Opens Nearby and resolves to the person chosen to add, if any.
///
/// Opening it acknowledges a pending wave: its comet plays once and the bell
/// clears, and stays clear while Nearby is open.
///
/// With [add], Add sends the request from Nearby itself and the sheet resolves
/// to null once it is sent; a refused request still resolves to the person,
/// so the caller can explain why.
Future<NearbyPeer?> showNearbySheet(
  BuildContext context, {
  required AppState state,
  bool page = false,
  Future<bool> Function(NearbyPeer peer)? add,
}) {
  final nearby = state.nearby;
  if (nearby == null) return Future.value();
  final waved = nearby.pendingWave;
  nearby.watch();
  // One request at a time; a second Add while one is in flight is ignored.
  var adding = false;
  Future<bool?> onAdd(NearbyPeer peer) async {
    if (add == null) return false;
    if (adding) return null;
    adding = true;
    try {
      return await add(peer);
    } finally {
      adding = false;
    }
  }

  final child = _NearbySheet(
    state: state,
    nearby: nearby,
    waved: waved,
    page: page,
    add: onAdd,
  );
  final route = page
      ? friendConnectionRoute<NearbyPeer>(context, child)
      : DialogRoute<NearbyPeer>(context: context, builder: (_) => child);
  unawaited(Navigator.of(context).push(route));
  // Resolve only after the sheet has left, so the caller is the current route
  // again when it acts on the choice.
  return route.completed.whenComplete(nearby.unwatch);
}

class _NearbySheet extends StatelessWidget {
  const _NearbySheet({
    required this.state,
    required this.nearby,
    required this.waved,
    required this.add,
    this.page = false,
  });

  final AppState state;
  final NearbyController nearby;
  final bool waved;
  final bool page;
  final Future<bool?> Function(NearbyPeer peer) add;

  static bool _mobile(BuildContext context) =>
      switch (Theme.of(context).platform) {
        TargetPlatform.android || TargetPlatform.iOS => true,
        _ => false,
      };

  String? _status(NearbyController nearby) => switch (nearby.status) {
    NearbyStatus.listening when nearby.visible => 'Visible nearby.',
    NearbyStatus.listening => null,
    NearbyStatus.starting => 'Starting Nearby…',
    NearbyStatus.error => 'Nearby is unavailable. Check Wi-Fi or Bluetooth.',
    NearbyStatus.stopped => 'Go online to find people nearby.',
  };

  @override
  Widget build(BuildContext context) {
    final colors = context.syblColors;
    final small = MediaQuery.sizeOf(context).height < 600;
    final dialog = AlertDialog(
      backgroundColor: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: colors.amber.withValues(alpha: .3)),
      ),
      title: Gravity(
        child: Text(
          'Nearby',
          textAlign: TextAlign.center,
          style: colors.display.copyWith(fontSize: 21),
        ),
      ),
      content: SizedBox(
        width: page ? double.infinity : 360,
        child: ListenableBuilder(
          // Friend and request changes move a row between its four states.
          listenable: Listenable.merge([nearby, state]),
          builder: (context, _) {
            return LayoutBuilder(
              builder: (context, constraints) {
                final compactDesktop =
                    !_mobile(context) && constraints.maxHeight.isFinite;
                return SizedBox(
                  width: page ? double.infinity : 360,
                  child: ScrollConfiguration(
                    behavior: ScrollConfiguration.of(
                      context,
                    ).copyWith(scrollbars: false),
                    // Waves travel past the page edges instead of stopping at the
                    // header.
                    child: SingleChildScrollView(
                      physics: compactDesktop
                          ? const NeverScrollableScrollPhysics()
                          : null,
                      clipBehavior: Clip.none,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          NearbyStage(
                            state: state,
                            nearby: nearby,
                            waved: waved,
                            availableHeight: constraints.maxHeight,
                            sonarSize: compactDesktop
                                ? 64
                                : small
                                ? 72
                                : page
                                ? 128
                                : 96,
                            // A desktop page centres the sonar; a phone keeps it
                            // low, under the people arriving above it.
                            centered:
                                page && !_mobile(context) && !compactDesktop,
                            onAdd: (peer) async {
                              final route = ModalRoute.of(context);
                              final navigator = Navigator.of(context);
                              final sent = await add(peer);
                              if (sent == null || route?.isCurrent != true) {
                                return;
                              }
                              navigator.pop(sent ? null : peer);
                            },
                            // Empty while hidden, but kept so revealing never
                            // shifts the list.
                            // Tucked under the timer, and faded in with it.
                            status: Transform.translate(
                              offset: const Offset(0, -10),
                              child: Padding(
                                padding: EdgeInsets.only(
                                  bottom: small || compactDesktop ? 8 : 14,
                                ),
                                child: SonarWarp.revealSwitcher(
                                  context,
                                  revealed: nearby.visible,
                                  child: Gravity(
                                    key: ValueKey(_status(nearby)),
                                    child: Text(
                                      _status(nearby) ?? '',
                                      key: const ValueKey('nearby-status'),
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: colors.muted,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => showDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
              scrollable: true,
              title: const Text('Your visibility'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Revealing shares your name and ID with nearby devices. '
                    'On Windows, Bluetooth also reveals your PC’s Bluetooth name. '
                    'Listening over Bluetooth uses radio connections, but does not share your profile. '
                    '${Theme.of(context).platform == TargetPlatform.android ? 'If enabled, Google Nearby runs only while you are visible. Its SDK collects usage and device diagnostics under Google’s Usage & diagnostics setting; diagnostic uploads may happen later. If permissions are requested, hold again after granting them. ' : ''}'
                    'Finding someone does not add them as a friend.',
                  ),
                  if (Theme.of(context).platform == TargetPlatform.android)
                    ListenableBuilder(
                      listenable: state,
                      builder: (context, _) => SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Google Nearby'),
                        subtitle: Text(
                          state.googleNearbyAllowed
                              ? 'Also used when you reveal yourself.'
                              : 'Sonar uses local network & Bluetooth.',
                        ),
                        value: state.googleNearbyAllowed,
                        onChanged: state.settingsControlsEnabled
                            ? (enabled) async {
                                if (enabled) {
                                  unawaited(
                                    showGoogleNearbyChoice(context, state),
                                  );
                                } else {
                                  if (!await state.setGoogleNearbyAllowed(
                                        false,
                                      ) &&
                                      context.mounted &&
                                      state.settingsError != null) {
                                    showNotice(state.settingsError!);
                                  }
                                }
                              }
                            : null,
                      ),
                    ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Close'),
                ),
              ],
            ),
          ),
          child: const Text('Visibility'),
        ),
        Gravity(
          child: TextButton(
            key: const ValueKey('nearby-close'),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ),
      ],
    );
    if (!page) return dialog;
    return FriendConnectionPage(
      title: 'Nearby',
      maxWidth: double.infinity,
      actions: [dialog.actions!.first],
      child: dialog.content!,
    );
  }
}
