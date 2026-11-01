import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/app_state.dart';
import '../theme.dart';
import 'gravity.dart';
import 'sonar_warp.dart';
import 'sybl_ui.dart';

/// Bumped to ask the home screen to open Sonar; the home screen owns panes.
final ValueNotifier<int> sonarOpenRequests = ValueNotifier(0);

/// In-app notifications. A received sonar rings it: it shakes, sends the
/// sonar wave out from itself, and keeps a dot until Sonar is opened.
/// Never an OS notification (Architecture: Doorlight Nearby).
class NotificationBell extends StatefulWidget {
  const NotificationBell({super.key, required this.state, this.large = false});

  final AppState state;

  /// Phone header size instead of the desktop title bar size.
  final bool large;

  @override
  State<NotificationBell> createState() => _NotificationBellState();
}

class _NotificationBellState extends State<NotificationBell>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shake;
  StreamSubscription<String>? _sonar;

  @override
  void initState() {
    super.initState();
    _shake = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _sonar = widget.state.nearby?.sonarReceived.listen((_) {
      // Sonar on screen shows the ping itself.
      if (!mounted || widget.state.nearby?.watching == true) return;
      if (!MediaQuery.disableAnimationsOf(context)) _shake.forward(from: 0);
      unawaited(HapticFeedback.mediumImpact());
    });
  }

  @override
  void dispose() {
    unawaited(_sonar?.cancel());
    _shake.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final nearby = widget.state.nearby;
    if (nearby == null) return const SizedBox.shrink();
    final colors = context.syblColors;
    return ListenableBuilder(
      listenable: nearby,
      builder: (context, _) {
        final pinged = nearby.pendingWave;
        return Gravity(
          child: PopupMenuButton<bool>(
            key: const ValueKey('notification-bell'),
            tooltip: 'Notifications',
            position: PopupMenuPosition.under,
            color: colors.surfaceTop,
            padding: EdgeInsets.zero,
            onSelected: (_) => sonarOpenRequests.value++,
            itemBuilder: (context) => [
              if (pinged)
                const PopupMenuItem<bool>(
                  key: ValueKey('notification-sonar-ping'),
                  value: true,
                  child: ListTile(
                    leading: Icon(Icons.wifi_tethering_rounded),
                    title: Text('A device is pinging you'),
                    subtitle: Text('Open Sonar to see who'),
                  ),
                )
              else
                const PopupMenuItem<bool>(
                  enabled: false,
                  child: Text('No notifications'),
                ),
            ],
            child: SonarTarget(
              child: SizedBox(
                width: widget.large ? 48 : 26,
                height: widget.large ? 48 : 28,
                child: AnimatedBuilder(
                  animation: _shake,
                  builder: (context, child) {
                    // A damped swing from the top, like a struck bell.
                    final t = _shake.value;
                    return Transform.rotate(
                      alignment: Alignment.topCenter,
                      angle: math.sin(t * math.pi * 8) * .35 * (1 - t),
                      child: child,
                    );
                  },
                  child: Stack(
                    alignment: Alignment.center,
                    clipBehavior: Clip.none,
                    children: [
                      Icon(
                        pinged
                            ? Icons.notifications_active_rounded
                            : Icons.notifications_none_rounded,
                        size: widget.large ? 20 : 16,
                        color: pinged ? colors.amber : colors.muted,
                      ),
                      Positioned(
                        top: widget.large ? 12 : 4,
                        right: widget.large ? 12 : 3,
                        child: AnimatedScale(
                          key: const ValueKey('nearby-wave-badge'),
                          duration: SyblMotion.duration(
                            context,
                            const Duration(milliseconds: 320),
                          ),
                          curve: Curves.easeOutBack,
                          scale: pinged ? 1 : 0,
                          child: Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: colors.amber,
                              border: Border.all(color: colors.bg, width: 1.5),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
