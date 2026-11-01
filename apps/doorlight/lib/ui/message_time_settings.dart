import 'package:flutter/material.dart';

import '../state/app_settings.dart';
import '../theme.dart';
import 'settings_previews.dart';

/// Keep the selected placement readable; compare samples inside the menu.
class MessageTimeSettings extends StatelessWidget {
  const MessageTimeSettings({
    super.key,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final MessageTimestampStyle value;
  final bool enabled;
  final ValueChanged<MessageTimestampStyle> onChanged;

  static const placements = [
    MessageTimestampStyle.inward,
    MessageTimestampStyle.below,
    MessageTimestampStyle.discord,
    MessageTimestampStyle.whatsapp,
    MessageTimestampStyle.messenger,
  ];

  static String label(MessageTimestampStyle style) => switch (style) {
    MessageTimestampStyle.inward => 'Beside the bubble',
    MessageTimestampStyle.below => 'Below the bubble',
    MessageTimestampStyle.discord => 'Beside the name',
    MessageTimestampStyle.whatsapp => 'Inside the bubble',
    MessageTimestampStyle.messenger ||
    MessageTimestampStyle.apple => 'Above message groups',
  };

  bool get _afterPause =>
      value == MessageTimestampStyle.messenger ||
      value == MessageTimestampStyle.apple;

  @override
  Widget build(BuildContext context) {
    final colors = context.syblColors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SettingsHeading('Message times'),
          const SizedBox(height: 8),
          Material(
            color: Colors.transparent,
            shape: RoundedRectangleBorder(
              side: BorderSide(color: colors.line),
              borderRadius: BorderRadius.circular(8),
            ),
            clipBehavior: Clip.antiAlias,
            child: Semantics(
              label: 'Message times',
              child: DropdownButtonHideUnderline(
                child: DropdownButton<MessageTimestampStyle>(
                  key: const ValueKey('message-time-placement'),
                  value: _afterPause ? MessageTimestampStyle.messenger : value,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  isExpanded: true,
                  selectedItemBuilder: (context) => [
                    for (final placement in placements)
                      Container(
                        alignment: Alignment.centerLeft,
                        constraints: const BoxConstraints(minHeight: 48),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          label(placement),
                          style: TextStyle(
                            color: enabled ? colors.ink : colors.faint,
                            fontSize: 13,
                          ),
                        ),
                      ),
                  ],
                  itemHeight: null,
                  menuMaxHeight: 440,
                  borderRadius: BorderRadius.circular(8),
                  dropdownColor: colors.surface,
                  icon: Icon(Icons.expand_more_rounded, color: colors.muted),
                  items: [
                    for (final placement in placements)
                      DropdownMenuItem(
                        value: placement,
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final caption = Text(
                              label(placement),
                              style: TextStyle(
                                color: enabled ? colors.ink : colors.faint,
                                fontSize: 13,
                              ),
                            );
                            final sample = ExcludeSemantics(
                              child: MediaQuery(
                                data: MediaQuery.of(
                                  context,
                                ).copyWith(textScaler: TextScaler.noScaling),
                                child: SizedBox(
                                  width: constraints.maxWidth < 310 ? 124 : 154,
                                  height: 72,
                                  child: MessageTimePreview(
                                    placement == MessageTimestampStyle.messenger
                                        ? (_afterPause ? value : placement)
                                        : placement,
                                  ),
                                ),
                              ),
                            );
                            final stacked =
                                constraints.maxWidth <
                                MediaQuery.textScalerOf(context).scale(90) +
                                    8 +
                                    (constraints.maxWidth < 310 ? 124 : 154);
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: stacked
                                  ? Column(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        caption,
                                        const SizedBox(height: 8),
                                        Align(
                                          alignment: Alignment.centerRight,
                                          child: sample,
                                        ),
                                      ],
                                    )
                                  : Row(
                                      children: [
                                        Expanded(child: caption),
                                        const SizedBox(width: 8),
                                        sample,
                                      ],
                                    ),
                            );
                          },
                        ),
                      ),
                  ],
                  onChanged: enabled
                      ? (placement) {
                          if (placement != null) {
                            onChanged(
                              placement == MessageTimestampStyle.messenger &&
                                      _afterPause
                                  ? value
                                  : placement,
                            );
                          }
                        }
                      : null,
                ),
              ),
            ),
          ),
          if (_afterPause)
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 4),
              child: Text(
                'At the start and after a gap of 15 minutes or more.',
                key: const ValueKey('message-time-explanation'),
                style: TextStyle(
                  color: colors.muted,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ),
          if (_afterPause)
            MergeSemantics(
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Bubble tails',
                      style: TextStyle(color: colors.ink),
                    ),
                  ),
                  Switch(
                    key: const ValueKey('message-time-bubble-tail'),
                    value: value == MessageTimestampStyle.apple,
                    onChanged: enabled
                        ? (tail) => onChanged(
                            tail
                                ? MessageTimestampStyle.apple
                                : MessageTimestampStyle.messenger,
                          )
                        : null,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
