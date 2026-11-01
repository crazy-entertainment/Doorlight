import '../ui/notice.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../state/app_state.dart';
import '../theme.dart';

/// Diagnostics / debug mode — a live view of the connection state + a rolling log of "what it's trying"
/// (every daemon event + the actions we drive). Built to diagnose connectivity (e.g. why a profile won't
/// register). Native logging is separate: Windows disk/libjami console output is environment-gated while debugger
/// output remains available; Android/daemon output can appear in logcat outside this bounded in-app view.
class DebugScreen extends StatelessWidget {
  final AppState state;
  const DebugScreen({super.key, required this.state});

  String get _connectionStatus => state.appearOffline
      ? 'Network offline'
      : switch (state.registration) {
          'REGISTERED' => 'Network online',
          'TRYING' => 'Connecting to network',
          _ => 'Network offline',
        };

  String get _friendStatus => state.selectedFriend == null
      ? 'No friend selected'
      : switch (state.peerPresence) {
          PeerPresence.inApp => 'Doorlight open',
          PeerPresence.reachable => 'Reachable',
          PeerPresence.unreachable => 'Unreachable',
          PeerPresence.unknown => 'Not known yet',
        };

  Widget _detail(BuildContext context, String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(color: context.syblColors.muted, fontSize: 12),
        ),
        const SizedBox(height: 3),
        Text(value, style: const TextStyle(fontSize: 14)),
      ],
    ),
  );

  void _showConnectionDetails(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => AnimatedBuilder(
        animation: state,
        builder: (context, _) => AlertDialog(
          title: const Text('Status details'),
          scrollable: true,
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _detail(context, 'Messaging network', _connectionStatus),
              const Padding(
                padding: EdgeInsets.only(bottom: 14),
                child: Text(
                  'Network registration for this device. It does not confirm friend availability or message delivery.',
                  style: TextStyle(fontSize: 14),
                ),
              ),
              _detail(
                context,
                'Device discovery',
                state.ready ? 'Ready' : 'Not ready yet',
              ),
              _detail(context, 'Selected friend', _friendStatus),
              _detail(
                context,
                'Your Friend ID',
                state.jamiId.isEmpty ? 'Not available' : state.jamiId,
              ),
              _detail(context, 'Connection mode', state.connectionProfile),
              _detail(context, 'Registration code', state.registration),
              if (state.conversationTimeline?.lastError != null)
                _detail(
                  context,
                  'Chat history error',
                  'Chat history could not be loaded.',
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
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.syblColors.bg,
      appBar: AppBar(
        backgroundColor: context.syblColors.bg,
        foregroundColor: context.syblColors.ink,
        elevation: 0,
        title: const Text('Diagnostics', style: TextStyle(fontSize: 16)),
        actions: [
          IconButton(
            tooltip: 'Copy log',
            icon: Icon(Icons.copy, size: 18, color: context.syblColors.amber),
            onPressed: () {
              // Oldest→newest, easiest to read when pasted.
              Clipboard.setData(
                ClipboardData(text: state.debugLog.reversed.join('\n')),
              );
              showNotice(
                'Diagnostics copied',
                duration: const Duration(seconds: 1),
              );
            },
          ),
          IconButton(
            tooltip: 'Clear',
            icon: Icon(
              Icons.delete_outline,
              size: 18,
              color: context.syblColors.muted,
            ),
            onPressed: state.clearDebugLog,
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: state,
        builder: (context, _) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: SizedBox(
                  width: double.infinity,
                  child: Tooltip(
                    message: 'Connection details',
                    child: OutlinedButton(
                      key: const ValueKey('diagnostics-status'),
                      onPressed: () => _showConnectionDetails(context),
                      child: Row(
                        children: [
                          Expanded(child: Text(_connectionStatus)),
                          const SizedBox(width: 8),
                          const Icon(Icons.info_outline, size: 16),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(16, 2, 16, 6),
                child: Tooltip(
                  message: '→ Doorlight action\n· Connection update',
                  child: Text(
                    'Recent activity',
                    style: TextStyle(
                      color: context.syblColors.muted,
                      fontSize: 11,
                    ),
                  ),
                ),
              ),
              Expanded(
                child: Container(
                  key: const ValueKey('diagnostics-log'),
                  margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: context.syblColors.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: context.syblColors.line),
                  ),
                  child: state.debugLog.isEmpty
                      ? Center(
                          child: Text(
                            'No activity yet',
                            style: TextStyle(
                              color: context.syblColors.muted,
                              fontSize: 12,
                            ),
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.all(12),
                          itemCount: state.debugLog.length,
                          itemBuilder: (context, i) {
                            final line = state.debugLog[i];
                            final isAction = line.contains('→');
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2),
                              child: Text(
                                line,
                                style: TextStyle(
                                  color: isAction
                                      ? context.syblColors.amber
                                      : context.syblColors.muted,
                                  fontSize: 11,
                                  fontFamily: 'monospace',
                                  height: 1.3,
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
