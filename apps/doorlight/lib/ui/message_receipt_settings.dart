import 'package:flutter/material.dart';

import '../state/app_settings.dart';
import '../theme.dart';
import 'settings_previews.dart';

class MessageReceiptSettings extends StatelessWidget {
  const MessageReceiptSettings({
    super.key,
    required this.style,
    required this.visibility,
    required this.enabled,
    required this.onStyleChanged,
    required this.onVisibilityChanged,
  });

  final MessageReceiptStyle style;
  final MessageReceiptVisibility visibility;
  final bool enabled;
  final ValueChanged<MessageReceiptStyle> onStyleChanged;
  final ValueChanged<MessageReceiptVisibility> onVisibilityChanged;

  static String label(MessageReceiptStyle value) => switch (value) {
    MessageReceiptStyle.whatsapp => 'Checks',
    MessageReceiptStyle.sybl => 'Arrows',
    MessageReceiptStyle.messenger => 'Circles & picture',
  };

  @override
  Widget build(BuildContext context) {
    final colors = context.syblColors;
    final wait = visibility == MessageReceiptVisibility.afterPause;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SettingsHeading('Message status'),
          const SizedBox(height: 8),
          Material(
            color: Colors.transparent,
            shape: RoundedRectangleBorder(
              side: BorderSide(color: colors.line),
              borderRadius: BorderRadius.circular(8),
            ),
            clipBehavior: Clip.antiAlias,
            child: Semantics(
              label: 'Message status symbols',
              child: DropdownButtonHideUnderline(
                child: DropdownButton<MessageReceiptStyle>(
                  key: const ValueKey('message-status-style'),
                  value: style,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  isExpanded: true,
                  itemHeight: null,
                  borderRadius: BorderRadius.circular(8),
                  dropdownColor: colors.surface,
                  icon: Icon(Icons.expand_more_rounded, color: colors.muted),
                  items: [
                    for (final option in MessageReceiptStyle.values)
                      DropdownMenuItem(
                        value: option,
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final title = Text(
                              label(option),
                              style: TextStyle(
                                fontSize: 13,
                                color: enabled ? colors.ink : colors.faint,
                              ),
                            );
                            final preview = ExcludeSemantics(
                              child: MediaQuery(
                                data: MediaQuery.of(
                                  context,
                                ).copyWith(textScaler: TextScaler.noScaling),
                                child: SizedBox(
                                  width: 156,
                                  height: 44,
                                  child: ReceiptPreview(option),
                                ),
                              ),
                            );
                            final stacked =
                                constraints.maxWidth <
                                188 +
                                    MediaQuery.textScalerOf(context).scale(60);
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              child: stacked
                                  ? Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        title,
                                        const SizedBox(height: 8),
                                        preview,
                                      ],
                                    )
                                  : Row(
                                      children: [
                                        Expanded(child: title),
                                        const SizedBox(width: 8),
                                        preview,
                                      ],
                                    ),
                            );
                          },
                        ),
                      ),
                  ],
                  onChanged: enabled
                      ? (value) {
                          if (value != null) onStyleChanged(value);
                        }
                      : null,
                ),
              ),
            ),
          ),
          Material(
            type: MaterialType.transparency,
            child: SwitchListTile.adaptive(
              key: const ValueKey('message-status-delay'),
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'Show status after 5 minutes',
                style: TextStyle(fontSize: 13),
              ),
              value: wait,
              onChanged: enabled
                  ? (value) => onVisibilityChanged(
                      value
                          ? MessageReceiptVisibility.afterPause
                          : MessageReceiptVisibility.always,
                    )
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}
