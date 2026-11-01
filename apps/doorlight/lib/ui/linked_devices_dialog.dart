import 'package:flutter/material.dart';

import '../core/jami.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'gravity.dart';
import 'device_pairing_dialog.dart';

Future<void> showLinkedDevicesDialog(
  BuildContext context, {
  required AppState state,
}) => showDialog<void>(
  context: context,
  builder: (context) => _LinkedDevicesDialog(state: state),
);

class _LinkedDevicesDialog extends StatefulWidget {
  const _LinkedDevicesDialog({required this.state});

  final AppState state;

  @override
  State<_LinkedDevicesDialog> createState() => _LinkedDevicesDialogState();
}

class _LinkedDevicesDialogState extends State<_LinkedDevicesDialog> {
  late final (String?, int) _owner;
  List<JamiKnownDevice> _devices = const [];
  int _loadRevision = 0;
  bool _retired = false;
  bool _loading = true;
  String? _error;
  String? _notice;
  String? _revokingId;

  @override
  void initState() {
    super.initState();
    _owner = widget.state.linkedDeviceOwner;
    widget.state.addListener(_onStateChanged);
    _load();
  }

  bool get _ownsAccount =>
      !_retired &&
      _owner.$1 != null &&
      _owner.$1!.isNotEmpty &&
      _owner == widget.state.linkedDeviceOwner;

  void _onStateChanged() {
    if (!_ownsAccount && !_retired) _retireOwner();
  }

  void _retireOwner() {
    if (!mounted) return;
    _loadRevision++;
    setState(() {
      _retired = true;
      _devices = const [];
      _loading = false;
      _revokingId = null;
      _notice = null;
      _error =
          'The identity changed. Close this dialog and open linked devices again.';
    });
  }

  @override
  void dispose() {
    widget.state.removeListener(_onStateChanged);
    super.dispose();
  }

  Future<void> _load() async {
    if (!_ownsAccount) {
      _retireOwner();
      return;
    }
    final revision = ++_loadRevision;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final devices = await widget.state.listKnownDevices();
      if (!mounted || revision != _loadRevision) return;
      if (!_ownsAccount) {
        _retireOwner();
        return;
      }
      setState(() {
        _devices = devices;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || revision != _loadRevision) return;
      if (!_ownsAccount) {
        _retireOwner();
        return;
      }
      setState(() {
        _loading = false;
        _error = 'Could not read linked devices.';
      });
    }
  }

  String _deviceLabel(JamiKnownDevice device) =>
      device.name.isEmpty ? 'Unnamed device' : device.name;

  String _shortId(String id) => id.length <= 24
      ? id
      : '${id.substring(0, 12)}…${id.substring(id.length - 8)}';

  Future<void> _revoke(JamiKnownDevice device) async {
    if (device.current || _revokingId != null) return;
    if (!_ownsAccount) {
      _retireOwner();
      return;
    }
    final label = _deviceLabel(device);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Gravity(
          child: Text(
            'Revoke $label?',
            style: context.syblColors.display.copyWith(fontSize: 19),
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Gravity(
              child: const Text(
                'That device will lose access to this Jami identity. This does not delete files already downloaded there.',
              ),
            ),
            const SizedBox(height: 12),
            Gravity(
              child: SelectableText(
                device.id,
                style: TextStyle(
                  color: context.syblColors.faint,
                  fontFamily: 'monospace',
                  fontSize: 11,
                ),
              ),
            ),
          ],
        ),
        actions: [
          Gravity(
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
          ),
          Gravity(
            child: FilledButton(
              key: const ValueKey('confirm-device-revocation'),
              style: FilledButton.styleFrom(
                backgroundColor: context.syblColors.dangerFill,
                foregroundColor: context.syblColors.foregroundFor(
                  context.syblColors.dangerFill,
                ),
              ),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Revoke device'),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (!_ownsAccount) {
      _retireOwner();
      return;
    }
    setState(() {
      _revokingId = device.id;
      _error = null;
      _notice = null;
    });
    var status = JamiDeviceRevocationStatus.unavailable;
    try {
      status = await widget.state.revokeKnownDevice(device.id, owner: _owner);
    } catch (_) {}
    if (!mounted) return;
    if (!_ownsAccount || status == JamiDeviceRevocationStatus.accountChanged) {
      _retireOwner();
      return;
    }
    setState(() {
      _revokingId = null;
      if (status == JamiDeviceRevocationStatus.revoked) {
        _notice = 'Jami confirmed the device revocation.';
      } else {
        _error = switch (status) {
          JamiDeviceRevocationStatus.credentials =>
            'Jami could not unlock this identity to revoke the device.',
          JamiDeviceRevocationStatus.network =>
            'Jami could not finish revocation. Check your connection and try again.',
          JamiDeviceRevocationStatus.pending =>
            'An earlier revocation is still unresolved. Refresh to check again.',
          JamiDeviceRevocationStatus.refused =>
            'Jami refused this device revocation. Refresh the device list and try again.',
          _ =>
            'Revocation is not confirmed. It may still finish. Refresh to check the device list.',
        };
      }
    });
    if (status == JamiDeviceRevocationStatus.revoked) await _load();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Wrap(
        spacing: 16,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Gravity(
            child: Text(
              'Linked devices',
              style: context.syblColors.display.copyWith(fontSize: 20),
            ),
          ),
          Tooltip(
            message: 'Link another device',
            child: Gravity(
              child: OutlinedButton.icon(
                key: const ValueKey('link-another-device'),
                onPressed: !_ownsAccount || _revokingId != null
                    ? null
                    : () async {
                        await showDevicePairingDialog(
                          context,
                          state: widget.state,
                          destination: false,
                        );
                        if (mounted && _ownsAccount) await _load();
                      },
                icon: const Icon(Icons.add_link),
                label: const Text('Link'),
              ),
            ),
          ),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 520),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Gravity(
                child: Text(
                  'Identity and chats sync. Files, settings and permissions stay on each device.',
                  style: TextStyle(
                    color: context.syblColors.muted,
                    fontSize: 13,
                    height: 1.45,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              if (_loading)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(20),
                    child: CircularProgressIndicator(),
                  ),
                )
              else if (_devices.isEmpty && !_retired)
                Gravity(child: const Text('No devices were reported by Jami.'))
              else
                for (final device in _devices)
                  Container(
                    key: ValueKey('linked-device-${device.id}'),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: BorderSide(color: context.syblColors.line),
                      ),
                    ),
                    child: Row(
                      children: [
                        Gravity(
                          child: Icon(
                            device.current
                                ? Icons.laptop_windows_rounded
                                : Icons.devices_other_rounded,
                            size: 21,
                            color: device.current
                                ? context.syblColors.online
                                : context.syblColors.muted,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Gravity(
                                child: Text(
                                  _deviceLabel(device),
                                  style: TextStyle(
                                    color: context.syblColors.ink,
                                    fontSize: 13.5,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 2),
                              Gravity(
                                child: Text(
                                  device.current
                                      ? 'This device'
                                      : _shortId(device.id),
                                  style: TextStyle(
                                    color: device.current
                                        ? context.syblColors.online
                                        : context.syblColors.faint,
                                    fontFamily: device.current
                                        ? null
                                        : 'monospace',
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (!device.current)
                          Gravity(
                            child: TextButton(
                              key: ValueKey('revoke-device-${device.id}'),
                              onPressed: _revokingId == null && !_retired
                                  ? () => _revoke(device)
                                  : null,
                              child: _revokingId == device.id
                                  ? const SizedBox.square(
                                      dimension: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Text('Revoke'),
                            ),
                          ),
                      ],
                    ),
                  ),
              if (_notice case final notice?) ...[
                const SizedBox(height: 12),
                Gravity(
                  child: Text(
                    notice,
                    key: const ValueKey('linked-devices-notice'),
                    style: TextStyle(
                      color: context.syblColors.online,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
              if (_error case final error?) ...[
                const SizedBox(height: 12),
                Gravity(
                  child: Text(
                    error,
                    key: const ValueKey('linked-devices-error'),
                    style: TextStyle(
                      color: context.syblColors.danger,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        Gravity(
          child: TextButton(
            onPressed: _loading || _retired ? null : _load,
            child: const Text('Refresh'),
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
  }
}
