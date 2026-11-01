import 'package:flutter/material.dart';

import '../theme.dart';
import 'settings_previews.dart';

class SenderLabelSettings extends StatelessWidget {
  const SenderLabelSettings({
    super.key,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.syblColors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SettingsHeading('Name and picture'),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) {
              final columns =
                  constraints.maxWidth >=
                      2 * MediaQuery.textScalerOf(context).scale(120) + 8
                  ? 2
                  : 1;
              final width =
                  (constraints.maxWidth - (columns - 1) * 8) / columns;
              return Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final repeat in [true, false])
                    SizedBox(
                      width: width,
                      child: Semantics(
                        label: repeat ? 'After a pause' : 'On sender change',
                        checked: value == repeat,
                        enabled: enabled,
                        inMutuallyExclusiveGroup: true,
                        onTap: enabled ? () => onChanged(repeat) : null,
                        child: Material(
                          color: colors.surface,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                            side: BorderSide(
                              color: value == repeat
                                  ? colors.amber
                                  : colors.line,
                            ),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            key: ValueKey('sender-label-$repeat'),
                            onTap: enabled ? () => onChanged(repeat) : null,
                            excludeFromSemantics: true,
                            child: ExcludeSemantics(
                              child: Padding(
                                padding: const EdgeInsets.all(10),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    MediaQuery(
                                      data: MediaQuery.of(context).copyWith(
                                        textScaler: TextScaler.noScaling,
                                      ),
                                      child: SizedBox(
                                        height: 88,
                                        child: RepeatAuthorPreview(repeat),
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    ConstrainedBox(
                                      constraints: BoxConstraints(
                                        minHeight: MediaQuery.textScalerOf(
                                          context,
                                        ).scale(32),
                                      ),
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              repeat
                                                  ? 'After a pause'
                                                  : 'On sender change',
                                              style: TextStyle(
                                                fontSize: 12,
                                                height: 1.2,
                                                color: enabled
                                                    ? colors.ink
                                                    : colors.faint,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 4),
                                          Icon(
                                            value == repeat
                                                ? Icons
                                                      .radio_button_checked_rounded
                                                : Icons
                                                      .radio_button_unchecked_rounded,
                                            size: 16,
                                            color: value == repeat
                                                ? colors.amber
                                                : colors.muted,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
