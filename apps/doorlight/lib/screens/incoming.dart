import '../ui/gravity.dart';
import '../ui/hologram_anchor.dart';
import 'package:flutter/material.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../ui/sybl_ui.dart';

/// Full-screen incoming ring with Accept / Decline actions.
class IncomingScreen extends StatelessWidget {
  final AppState state;
  final VoidCallback? onMinimize;
  const IncomingScreen({super.key, required this.state, this.onMinimize});

  @override
  Widget build(BuildContext context) {
    final c = state.call;
    final from = c?.peerId ?? '';
    final name = state.peerDisplayName(from);
    final isVideo =
        c?.peerVideo ==
        true; // the caller offered video → tell the callee it's a video call
    return Scaffold(
      backgroundColor: context.syblColors.bg,
      body: Stack(
        children: [
          SafeArea(
            child: Column(
              children: [
                const Spacer(),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (isVideo) ...[
                      Gravity(
                        child: Icon(
                          Icons.videocam,
                          color: context.syblColors.amber,
                          size: 18,
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Gravity(
                      child: Text(
                        isVideo ? 'incoming video call' : 'incoming call',
                        style: TextStyle(
                          color: context.syblColors.muted,
                          fontSize: 15,
                          letterSpacing: 1,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                SyblAvatar(
                  label: name,
                  imageBase64: state.friends[from]?.avatarBase64,
                  size: 112,
                  color: context.syblColors.surfaceHi,
                ),
                const SizedBox(height: 18),
                Gravity(
                  child: Text(
                    name,
                    style: context.syblColors.display.copyWith(fontSize: 22),
                  ),
                ),
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 40,
                    vertical: 40,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _RoundAction(
                        color: context.syblColors.dangerFill,
                        icon: Icons.call_end,
                        label: 'Decline',
                        onTap: c == null ? null : () => state.decline(c),
                      ),
                      _RoundAction(
                        color: context.syblColors.onlineFill,
                        icon: isVideo ? Icons.videocam : Icons.call,
                        label: 'Accept',
                        onTap: c == null ? null : () => state.answer(c),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (onMinimize != null)
            Positioned(
              left: 8,
              top: 8,
              child: SafeArea(
                child: Gravity(
                  child: HologramAnchor(
                    state: state,
                    child: IconButton(
                      key: const ValueKey('minimize-call-button'),
                      tooltip: 'Back to your friends',
                      onPressed: onMinimize,
                      style: IconButton.styleFrom(
                        backgroundColor: context.syblColors.accentFill,
                        foregroundColor: context.syblColors.foregroundFor(
                          context.syblColors.accentFill,
                          preferred: Colors.black,
                        ),
                      ),
                      icon: const Icon(Icons.arrow_back_rounded),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _RoundAction extends StatelessWidget {
  final Color color;
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  const _RoundAction({
    required this.color,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Gravity(
          child: IconButton(
            tooltip: label,
            onPressed: onTap,
            style: IconButton.styleFrom(
              fixedSize: const Size(72, 72),
              backgroundColor: color,
              shape: const CircleBorder(),
            ),
            icon: Icon(
              icon,
              color: context.syblColors.foregroundFor(color),
              size: 32,
            ),
          ),
        ),
        const SizedBox(height: 10),
        Gravity(
          child: Text(
            label,
            style: TextStyle(color: context.syblColors.muted, fontSize: 13),
          ),
        ),
      ],
    );
  }
}
