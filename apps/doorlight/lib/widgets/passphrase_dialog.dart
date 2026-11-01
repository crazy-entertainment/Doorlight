import 'package:flutter/material.dart';
import 'dart:async';

import '../theme.dart';
import '../ui/gravity.dart';
import '../ui/sybl_ui.dart';

const int archivePassphraseMaxCharacters = 1024;

/// Collects a passphrase for identity backup or restore.
///
/// [confirm]=true asks twice (setting a NEW backup password — the two entries must match); false asks once
/// (restoring). [allowEmpty] permits an unprotected export only after the timed warning. Returns the entered
/// passphrase, an empty string after that confirmation, or null if cancelled.
Future<String?> showPassphraseDialog(
  BuildContext context, {
  required String title,
  required String subtitle,
  required String actionLabel,
  bool confirm = false,
  bool allowEmpty = false,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _PassphraseDialog(
      title: title,
      subtitle: subtitle,
      actionLabel: actionLabel,
      confirm: confirm,
      allowEmpty: allowEmpty,
    ),
  );
}

class _PassphraseDialog extends StatefulWidget {
  final String title, subtitle, actionLabel;
  final bool confirm;
  final bool allowEmpty;
  const _PassphraseDialog({
    required this.title,
    required this.subtitle,
    required this.actionLabel,
    required this.confirm,
    required this.allowEmpty,
  });
  @override
  State<_PassphraseDialog> createState() => _PassphraseDialogState();
}

class _PassphraseDialogState extends State<_PassphraseDialog> {
  final _passwordController = TextEditingController();
  final _confirmationController = TextEditingController();
  bool _obscure = true;
  bool _protected = true;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _passwordController.addListener(_refreshFields);
    _confirmationController.addListener(_refreshFields);
  }

  void _refreshFields() => setState(() {});

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmationController.dispose();
    super.dispose();
  }

  bool get _ownsRoute => mounted && ModalRoute.of(context)?.isCurrent == true;

  void _cancel() {
    if (_submitting || !_ownsRoute) return;
    _submitting = true;
    Navigator.of(context).pop();
  }

  Future<void> _submit() async {
    if (_submitting || !_ownsRoute) return;
    final password = _passwordController.text;
    final confirmation = _confirmationController.text;
    if (widget.confirm && password != confirmation) {
      setState(() => _error = "The two passwords don't match");
      return;
    }
    if (password.isNotEmpty) {
      _submitting = true;
      Navigator.of(context).pop(password);
      return;
    }
    if (!widget.allowEmpty || _protected) {
      setState(() => _error = 'Enter a password');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => const _UnprotectedBackupWarning(),
      );
      if (!mounted || confirmed != true || !_ownsRoute) return;
      // Autofill or a delayed controller update cannot authorize an old empty
      // password snapshot after the user has supplied protection.
      if (_protected ||
          _passwordController.text != password ||
          _confirmationController.text != confirmation) {
        setState(
          () => _error = 'The password changed. Review it before continuing.',
        );
        return;
      }
      Navigator.of(context).pop('');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  InputDecoration _fieldDecoration(
    String hint,
    TextEditingController controller,
  ) => InputDecoration(
    labelText: hint,
    labelStyle: TextStyle(color: context.syblColors.muted, fontSize: 13),
    isDense: true,
    filled: true,
    fillColor: context.syblColors.bg,
    suffixIcon: controller.text.isEmpty
        ? null
        : IconButton(
            tooltip: _obscure ? 'Show passwords' : 'Hide passwords',
            onPressed: _submitting
                ? null
                : () => setState(() => _obscure = !_obscure),
            icon: Icon(
              _obscure
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
            ),
            color: context.syblColors.muted,
          ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: context.syblColors.surfaceHi),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: context.syblColors.amber),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: context.syblColors.surface,
      title: Gravity(
        child: Text(
          widget.title,
          style: TextStyle(color: context.syblColors.ink, fontSize: 18),
        ),
      ),
      scrollable: true,
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Gravity(
              child: Text(
                widget.subtitle,
                style: TextStyle(
                  color: context.syblColors.muted,
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
            ),
            const SizedBox(height: 8),
            if (widget.allowEmpty)
              SwitchListTile.adaptive(
                key: const ValueKey('backup-password-protection'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                visualDensity: VisualDensity.compact,
                title: const Text('Protect with a password'),
                value: _protected,
                onChanged: _submitting
                    ? null
                    : (value) => setState(() {
                        _protected = value;
                        _passwordController.clear();
                        _confirmationController.clear();
                        _error = null;
                      }),
              ),
            if (_protected) ...[
              Gravity(
                child: TextField(
                  controller: _passwordController,
                  enabled: !_submitting,
                  obscureText: _obscure,
                  maxLength: archivePassphraseMaxCharacters,
                  autofocus: SyblLayout.autofocusTextInput(context),
                  style: TextStyle(color: context.syblColors.ink),
                  cursorColor: context.syblColors.amber,
                  decoration: _fieldDecoration(
                    widget.confirm ? 'Password' : 'Backup password',
                    _passwordController,
                  ).copyWith(counterText: ''),
                  onSubmitted: (_) => widget.confirm ? null : _submit(),
                ),
              ),
              if (widget.confirm) ...[
                const SizedBox(height: 10),
                Gravity(
                  child: TextField(
                    controller: _confirmationController,
                    enabled: !_submitting,
                    obscureText: _obscure,
                    maxLength: archivePassphraseMaxCharacters,
                    style: TextStyle(color: context.syblColors.ink),
                    cursorColor: context.syblColors.amber,
                    decoration: _fieldDecoration(
                      'Confirm password',
                      _confirmationController,
                    ).copyWith(counterText: ''),
                    onSubmitted: (_) => _submit(),
                  ),
                ),
              ],
            ],
            if (_error != null)
              Gravity(
                child: Text(
                  _error!,
                  style: TextStyle(
                    color: context.syblColors.danger,
                    fontSize: 12,
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        Gravity(
          child: TextButton(
            onPressed: _submitting ? null : _cancel,
            child: Text(
              'Cancel',
              style: TextStyle(color: context.syblColors.muted),
            ),
          ),
        ),
        Gravity(
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: context.syblColors.accentFill,
              foregroundColor: context.syblColors.onAccent,
            ),
            onPressed: _submitting ? null : _submit,
            child: Text(widget.actionLabel),
          ),
        ),
      ],
    );
  }
}

class _UnprotectedBackupWarning extends StatefulWidget {
  const _UnprotectedBackupWarning();

  @override
  State<_UnprotectedBackupWarning> createState() =>
      _UnprotectedBackupWarningState();
}

class _UnprotectedBackupWarningState extends State<_UnprotectedBackupWarning> {
  int _remaining = 5;
  bool _finished = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() => _remaining--);
      if (_remaining == 0) timer.cancel();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _finish(bool confirmed) {
    if (_finished ||
        !mounted ||
        (confirmed && _remaining != 0) ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    _finished = true;
    _timer?.cancel();
    Navigator.of(context).pop(confirmed);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Gravity(child: const Text('Create an unprotected backup?')),
    content: Gravity(
      child: const Text(
        'This backup contains the keys to your Doorlight identity, along with your contacts and settings. Anyone who gets the file can use your identity and appear as you.\n\nMessages and received files are not included.',
      ),
    ),
    actions: [
      Gravity(
        child: TextButton(
          key: const ValueKey('cancel-unprotected-backup'),
          onPressed: () => _finish(false),
          child: const Text('Cancel'),
        ),
      ),
      Gravity(
        child: FilledButton(
          key: const ValueKey('confirm-unprotected-backup'),
          onPressed: _remaining == 0 ? () => _finish(true) : null,
          child: Text(
            _remaining == 0
                ? 'Create unprotected backup'
                : 'Create unprotected backup ($_remaining)',
          ),
        ),
      ),
    ],
  );
}
