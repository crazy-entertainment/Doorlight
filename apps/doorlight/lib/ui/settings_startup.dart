import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme.dart';

/// Keeps private app state unconstructed until persisted settings are readable.
class SettingsStartup extends StatefulWidget {
  const SettingsStartup({
    super.key,
    required this.load,
    required this.readyBuilder,
  });

  final Future<SharedPreferences> Function() load;
  final Widget Function(SharedPreferences) readyBuilder;

  @override
  State<SettingsStartup> createState() => _SettingsStartupState();
}

class _SettingsStartupState extends State<SettingsStartup> {
  bool _busy = false;
  bool _failed = false;
  bool _restartRequired = false;
  Widget? _ready;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_busy || _ready != null || _restartRequired) return;
    setState(() => _busy = true);
    final SharedPreferences preferences;
    try {
      preferences = await widget.load();
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _failed = true;
        });
      }
      return;
    }
    if (!mounted) return;
    final Widget ready;
    try {
      ready = widget.readyBuilder(preferences);
    } catch (_) {
      // Construction may have started subscriptions; do not construct it twice.
      setState(() {
        _busy = false;
        _failed = true;
        _restartRequired = true;
      });
      return;
    }
    setState(() {
      _busy = false;
      _ready = ready;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_ready case final ready?) return ready;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: Warm.theme(),
      home: Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _restartRequired
                          ? 'Doorlight could not start.'
                          : _failed
                          ? 'Doorlight could not read your settings.'
                          : 'Opening Doorlight…',
                      textAlign: TextAlign.center,
                    ),
                    if (_failed) ...[
                      const SizedBox(height: 12),
                      Text(
                        _restartRequired
                            ? 'Your settings have not been reset. Close and reopen Doorlight to try again.'
                            : 'Your settings have not been reset. Retry when your settings are available again.',
                        textAlign: TextAlign.center,
                      ),
                      if (!_restartRequired) ...[
                        const SizedBox(height: 20),
                        FilledButton(
                          onPressed: _busy ? null : _load,
                          child: Text(_busy ? 'Retrying…' : 'Retry'),
                        ),
                      ],
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
