import 'package:flutter/material.dart';

import '../state/windows_update.dart';

class UpdateButton extends StatelessWidget {
  const UpdateButton({
    super.key,
    required this.update,
    required this.canRestart,
  });
  final WindowsUpdate update;
  final bool canRestart;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: update,
    builder: (context, _) {
      final busy = update.checking || update.starting;
      final available = update.availableVersion != null;
      final tooltip = !update.installed
          ? 'Updates are available in the installed version'
          : update.error ??
                (busy
                    ? 'Checking for updates'
                    : available
                    ? canRestart
                          ? 'Update to ${update.availableVersion}'
                          : 'Finish your call, transfer or draft to update'
                    : 'Check for updates');
      return IconButton(
        key: const ValueKey('doorlight-update'),
        tooltip: tooltip,
        visualDensity: VisualDensity.compact,
        iconSize: 19,
        onPressed: !update.installed || update.checking ? null : update.install,
        icon: Badge(
          isLabelVisible: available,
          smallSize: 6,
          child: Icon(
            available ? Icons.system_update_alt_rounded : Icons.update_rounded,
          ),
        ),
      );
    },
  );
}
