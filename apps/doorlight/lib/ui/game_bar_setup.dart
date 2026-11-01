import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import '../state/companion_links.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'gravity.dart';
import 'settings_previews.dart';
import 'overlay_settings_controls.dart';

/// Optional, contextual setup: never blocks normal desktop use.
class GameBarSetup extends StatefulWidget {
  const GameBarSetup({super.key, this.state});
  final AppState? state;

  @override
  State<GameBarSetup> createState() => _GameBarSetupState();
}

class _GameBarSetupState extends State<GameBarSetup>
    with WidgetsBindingObserver {
  static const _channel = MethodChannel('syb.l/core');
  static const _widgetUri =
      'ms-gamebar://launch/activate/'
      'DoorlightOverlayProto_ygmhnd3vvdymm_App_Helper';
  static const _gameBarStore = 'https://apps.microsoft.com/detail/9NZKPSTSNW4P';
  bool? _widgetInstalled;
  bool? _gameBarInstalled;
  bool _checking = true;
  bool _opening = false;
  String? _error;
  CompanionLinks _links = const CompanionLinks();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_checking) _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _checking = true;
      _error = null;
    });
    bool? widgetInstalled;
    bool? gameBarInstalled;
    var links = const CompanionLinks();
    try {
      final status = await _channel.invokeMapMethod<String, dynamic>(
        'widgetCompanionStatus',
      );
      widgetInstalled = status?['widgetInstalled'] as bool?;
      gameBarInstalled = status?['gameBarInstalled'] as bool?;
    } on Object {
      // Unknown is shown separately from a missing installation.
    }
    try {
      links = await CompanionLinks.load();
    } on Object {
      // Invalid release configuration must never enable an install destination.
    }
    if (!mounted) return;
    setState(() {
      _widgetInstalled = widgetInstalled;
      _gameBarInstalled = gameBarInstalled;
      _links = links;
      _checking = false;
    });
  }

  Future<void> _open(String destination) async {
    setState(() {
      _opening = true;
      _error = null;
    });
    var opened = false;
    var refreshed = false;
    try {
      // Recheck native registration before launching a package that may have
      // been removed since this settings surface opened.
      if (destination == _widgetUri) {
        final status = await _channel.invokeMapMethod<String, dynamic>(
          'widgetCompanionStatus',
        );
        if (status?['widgetInstalled'] != true ||
            status?['gameBarInstalled'] != true) {
          await _refresh();
          refreshed = true;
          return;
        }
      }
      opened = await UrlLauncherPlatform.instance.launchUrl(
        destination,
        const LaunchOptions(mode: PreferredLaunchMode.externalApplication),
      );
    } on Object {
      opened = false;
    } finally {
      if (mounted) {
        setState(() {
          _opening = false;
          if (!opened && !refreshed) {
            _error = 'Could not open. Check the installation and try again.';
          }
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ready = _widgetInstalled == true && _gameBarInstalled == true;
    final missingGameBar = _gameBarInstalled == false;
    final unknown =
        !missingGameBar &&
        (_widgetInstalled == null || _gameBarInstalled == null);
    final destination = ready
        ? _widgetUri
        : missingGameBar
        ? _gameBarStore
        : _links.widgetDownloadUrl;
    final label = ready
        ? 'Open widget'
        : missingGameBar
        ? 'Install Game Bar'
        : 'Install widget';
    final description = _checking
        ? 'Checking installation…'
        : unknown
        ? 'Could not check the installation. Try again.'
        : ready
        ? 'Open Doorlight in Game Bar.'
        : missingGameBar
        ? 'Install Xbox Game Bar, then add the Doorlight widget.'
        : 'Add Doorlight to Game Bar to use widgets while you play.';
    final busy = _checking || _opening;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SettingsHeading('Game Bar widget'),
        const SizedBox(height: 8),
        Text(description, style: TextStyle(color: context.syblColors.muted)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            Gravity(
              child: FilledButton(
                onPressed: busy || unknown || destination == null
                    ? null
                    : () => _open(destination),
                child: Text(_opening ? 'Opening…' : label),
              ),
            ),
            Gravity(
              child: TextButton(
                onPressed: busy ? null : _refresh,
                child: const Text('Check again'),
              ),
            ),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 6),
          Text(_error!, style: TextStyle(color: context.syblColors.ink)),
        ],
        if (widget.state case final state?)
          OverlaySettingsControls(state: state),
      ],
    );
  }
}
