import 'package:flutter/material.dart';

import '../state/app_state.dart';

/// Place once above the app's routed content. It presents the one-time
/// explanation requested by the installed Game Bar widget without granting
/// consent in response to the widget's request itself.
final class WidgetChatConsentHost extends StatefulWidget {
  const WidgetChatConsentHost({
    super.key,
    required this.state,
    required this.child,
  });

  final AppState state;
  final Widget child;

  @override
  State<WidgetChatConsentHost> createState() => _WidgetChatConsentHostState();
}

final class _WidgetChatConsentHostState extends State<WidgetChatConsentHost> {
  int? _showingRequest;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_schedulePrompt);
    _schedulePrompt();
  }

  @override
  void didUpdateWidget(WidgetChatConsentHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.removeListener(_schedulePrompt);
      widget.state.addListener(_schedulePrompt);
      _showingRequest = null;
      _schedulePrompt();
    }
  }

  @override
  void dispose() {
    widget.state.removeListener(_schedulePrompt);
    super.dispose();
  }

  void _schedulePrompt() {
    final request = widget.state.widgetChatConsentRequest;
    if (!mounted || request == null || _showingRequest == request) return;
    _showingRequest = request;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _showPrompt(request);
    });
  }

  Future<void> _showPrompt(int request) async {
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Show chat in Game Bar?'),
        content: const Text(
          'Game Bar widgets can appear in screenshots, recordings, and streams. '
          'If you continue, chat names and messages can be visible there.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Show chat'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (accepted == true) {
      await widget.state.grantWidgetChatConsent(request);
    } else {
      widget.state.dismissWidgetChatConsent(request);
    }
    if (_showingRequest == request) _showingRequest = null;
    _schedulePrompt();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
