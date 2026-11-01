import 'package:flutter/material.dart';

import '../state/app_settings.dart';
import '../theme.dart';
import 'ambient_vibe.dart';
import 'topic_strip_surface.dart';

class SettingsHeading extends StatelessWidget {
  const SettingsHeading(this.title, {super.key});
  final String title;

  @override
  Widget build(BuildContext context) => Text(
    title,
    style: TextStyle(color: context.syblColors.ink, fontSize: 14),
  );
}

/// Shrink previews before scrolling; labels and hit targets keep their scale.
class SettingsPreviewRow extends StatelessWidget {
  const SettingsPreviewRow({
    super.key,
    required this.count,
    required this.minTileWidth,
    required this.maxTileWidth,
    required this.spacing,
    required this.children,
  });

  final int count;
  final double minTileWidth;
  final double maxTileWidth;
  final double spacing;
  final List<Widget> Function(double width) children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = ((constraints.maxWidth - spacing * (count - 1)) / count)
          .clamp(minTileWidth, maxTileWidth);
      return ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          primary: false,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: spacing,
            children: children(width),
          ),
        ),
      );
    },
  );
}

class SettingsChoices<T> extends StatelessWidget {
  const SettingsChoices({
    super.key,
    required this.title,
    required this.values,
    required this.value,
    required this.label,
    required this.preview,
    required this.onChanged,
    required this.enabled,
    this.maxTileWidth = 240,
    this.previewHeight = 64,
    this.allPreviews = false,
    this.singleRow = false,
    this.trailing,
    this.trailingBesideChoices = false,
  });
  final String title;
  final List<T> values;
  final T value;
  final String Function(T) label;
  final Widget Function(T) preview;
  final ValueChanged<T> onChanged;
  final bool enabled;
  final double maxTileWidth;
  final double previewHeight;
  final bool allPreviews;
  final bool singleRow;
  final Widget? trailing;
  final bool trailingBesideChoices;

  Widget _sample(
    BuildContext context,
    T option, [
    double? height,
  ]) => ExcludeSemantics(
    child: MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.noScaling),
      child: SizedBox(height: height ?? previewHeight, child: preview(option)),
    ),
  );

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: SettingsHeading(title)),
            if (!trailingBesideChoices) ?trailing,
          ],
        ),
        const SizedBox(height: 8),
        if (!allPreviews) ...[
          Align(
            alignment: Alignment.centerLeft,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxTileWidth),
              child: _sample(context, value),
            ),
          ),
          const SizedBox(height: 4),
        ],
        if (allPreviews && singleRow)
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: SettingsPreviewRow(
                  count: values.length,
                  minTileWidth:
                      64 *
                      MediaQuery.textScalerOf(context).scale(1).clamp(1, 2),
                  maxTileWidth:
                      maxTileWidth *
                      MediaQuery.textScalerOf(context).scale(1).clamp(1, 2),
                  spacing: 4,
                  children: (width) => [
                    for (final option in values) _tile(context, option, width),
                  ],
                ),
              ),
              if (trailingBesideChoices && trailing != null) ...[
                const SizedBox(width: 8),
                trailing!,
              ],
            ],
          )
        else
          Wrap(
            spacing: allPreviews ? 4 : 6,
            runSpacing: 4,
            children: [
              for (final option in values)
                if (allPreviews)
                  _tile(
                    context,
                    option,
                    maxTileWidth *
                        MediaQuery.textScalerOf(context).scale(1).clamp(1, 2),
                  )
                else
                  ChoiceChip(
                    key: ValueKey(
                      'choice-$title-${option is Enum ? option.name : option}',
                    ),
                    label: Text(
                      label(option),
                      style: const TextStyle(fontSize: 12),
                    ),
                    selected: option == value,
                    onSelected: enabled ? (_) => onChanged(option) : null,
                    showCheckmark: true,
                    selectedColor: context.syblColors.surfaceHi,
                    backgroundColor: Colors.transparent,
                    side: BorderSide(
                      color: option == value
                          ? context.syblColors.amber
                          : context.syblColors.line,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    visualDensity: const VisualDensity(
                      horizontal: -2,
                      vertical: -1,
                    ),
                  ),
            ],
          ),
      ],
    ),
  );

  Widget _tile(BuildContext context, T option, double width) => Semantics(
    button: true,
    selected: option == value,
    enabled: enabled,
    label: '$title: ${label(option)}',
    child: Material(
      color: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: option == value
              ? context.syblColors.amber
              : Colors.transparent,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ValueKey('choice-$title-${option is Enum ? option.name : option}'),
        onTap: enabled ? () => onChanged(option) : null,
        child: SizedBox(
          width: width,
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _sample(
                  context,
                  option,
                  previewHeight * (width / maxTileWidth).clamp(0, 1),
                ),
                const SizedBox(height: 5),
                Text(
                  label(option),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: enabled
                        ? context.syblColors.ink
                        : context.syblColors.faint,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class VibePreview extends StatelessWidget {
  const VibePreview(
    this.vibe, {
    super.key,
    this.animated = false,
    this.opacity = 1,
    this.intensity = 1,
  });
  final AmbientVibe vibe;
  final bool animated;
  final double opacity;
  final double intensity;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(8),
    child: ColoredBox(
      color: context.syblColors.surface,
      child: AmbientVibeSurface(
        vibe: vibe,
        opacity: opacity,
        intensity: intensity,
        preview: true,
        animationsEnabled: animated,
        child: vibe == AmbientVibe.none
            ? Center(
                child: Icon(
                  Icons.block_rounded,
                  size: 20,
                  color: context.syblColors.muted.withValues(alpha: .55),
                ),
              )
            : const SizedBox.expand(),
      ),
    ),
  );
}

class MessageTimePreview extends StatelessWidget {
  const MessageTimePreview(this.style, {super.key});
  final MessageTimestampStyle style;

  @override
  Widget build(BuildContext context) {
    final colors = context.syblColors;
    final session =
        style == MessageTimestampStyle.messenger ||
        style == MessageTimestampStyle.apple;
    Widget time(String value) => Text(
      value,
      style: TextStyle(fontSize: 11, height: 1.15, color: colors.amber),
    );
    Widget message(bool outgoing) {
      final clock = outgoing ? '14:33' : '14:32';
      final bubble = Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
        decoration: BoxDecoration(
          color: colors.surfaceHi,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(8),
            topRight: const Radius.circular(8),
            bottomLeft: Radius.circular(
              style == MessageTimestampStyle.apple && !outgoing ? 2 : 8,
            ),
            bottomRight: Radius.circular(
              style == MessageTimestampStyle.apple && outgoing ? 2 : 8,
            ),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                outgoing ? 'See you' : 'Hi',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, height: 1.15, color: colors.ink),
              ),
            ),
            if (style == MessageTimestampStyle.whatsapp) ...[
              const SizedBox(width: 5),
              time(clock),
            ],
          ],
        ),
      );
      return Column(
        crossAxisAlignment: outgoing
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          if (style == MessageTimestampStyle.discord)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (outgoing) ...[time(clock), const SizedBox(width: 5)],
                Text(
                  outgoing ? 'You' : 'Alex',
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.15,
                    color: colors.ink,
                  ),
                ),
                if (!outgoing) ...[const SizedBox(width: 5), time(clock)],
              ],
            ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (style == MessageTimestampStyle.inward && outgoing) ...[
                time(clock),
                const SizedBox(width: 5),
              ],
              Flexible(child: bubble),
              if (style == MessageTimestampStyle.inward && !outgoing) ...[
                const SizedBox(width: 5),
                time(clock),
              ],
            ],
          ),
          if (style == MessageTimestampStyle.below) time(clock),
        ],
      );
    }

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (session) Center(child: time('14:32')),
        Align(alignment: Alignment.centerLeft, child: message(false)),
        const SizedBox(height: 3),
        Align(alignment: Alignment.centerRight, child: message(true)),
      ],
    );
  }
}

class ReceiptPreview extends StatelessWidget {
  const ReceiptPreview(this.style, {super.key});
  final MessageReceiptStyle style;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.spaceAround,
    children: [
      for (var stage = 0; stage < 3; stage++)
        Flexible(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (style == MessageReceiptStyle.messenger && stage == 2)
                CircleAvatar(
                  radius: 10,
                  backgroundColor: context.syblColors.sage,
                  child: Text(
                    'A',
                    style: TextStyle(
                      fontSize: 10,
                      color: context.syblColors.bg,
                    ),
                  ),
                )
              else
                Icon(
                  switch (style) {
                    MessageReceiptStyle.whatsapp =>
                      stage == 0 ? Icons.check_rounded : Icons.done_all_rounded,
                    MessageReceiptStyle.sybl =>
                      stage == 0
                          ? Icons.north_east_rounded
                          : Icons.multiple_stop_rounded,
                    MessageReceiptStyle.messenger =>
                      stage == 0
                          ? Icons.radio_button_unchecked_rounded
                          : Icons.check_circle_outline_rounded,
                  },
                  size: 20,
                  color: stage == 2
                      ? context.syblColors.online
                      : context.syblColors.muted,
                ),
              const SizedBox(height: 8),
              Text(
                ['Sent', 'Delivered', 'Read'][stage],
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 9, color: context.syblColors.muted),
              ),
            ],
          ),
        ),
    ],
  );
}

class RepeatAuthorPreview extends StatelessWidget {
  const RepeatAuthorPreview(this.repeat, {super.key});
  final bool repeat;

  @override
  Widget build(BuildContext context) {
    final colors = context.syblColors;
    Widget header(String time, bool showAuthor) => SizedBox(
      height: 16,
      child: Row(
        children: [
          if (showAuthor) ...[
            CircleAvatar(
              radius: 7,
              backgroundColor: colors.rose,
              child: Text('A', style: TextStyle(fontSize: 8, color: colors.bg)),
            ),
            const SizedBox(width: 4),
            Text('Alex', style: TextStyle(fontSize: 10, color: colors.ink)),
          ],
          const Spacer(),
          Text(time, style: TextStyle(fontSize: 9, color: colors.muted)),
        ],
      ),
    );
    return DefaultTextStyle.merge(
      style: const TextStyle(height: 1.15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          header('14:32', true),
          const SizedBox(height: 3),
          _SampleMessage('On my way'),
          const SizedBox(height: 8),
          header('14:38', repeat),
          const SizedBox(height: 3),
          _SampleMessage('I’m here'),
        ],
      ),
    );
  }
}

class GroupHeaderPreview extends StatelessWidget {
  const GroupHeaderPreview(this.placement, {super.key});
  final GroupHeaderPlacement placement;

  @override
  Widget build(BuildContext context) {
    final colors = context.syblColors;
    Widget header() => Container(
      height: 18,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.only(left: 6),
      color: colors.surfaceHi,
      child: Text(
        'Weekend crew',
        style: TextStyle(fontSize: 9, color: colors.ink),
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Column(
        children: [
          if (placement == GroupHeaderPlacement.fullWidth) header(),
          Expanded(
            child: Row(
              children: [
                Container(
                  width: 38,
                  color: colors.desk,
                  padding: const EdgeInsets.all(5),
                  child: Column(
                    children: [
                      for (final name in ['Main', 'Plans'])
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 8, color: colors.muted),
                          ),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: ColoredBox(
                    color: colors.surface,
                    child: Column(
                      children: [
                        if (placement == GroupHeaderPlacement.conversation)
                          header(),
                        const Spacer(),
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 5),
                          child: _SampleMessage('Who’s coming?'),
                        ),
                        const Spacer(),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SampleMessage extends StatelessWidget {
  const _SampleMessage(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: context.syblColors.surfaceHi,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 10, color: context.syblColors.ink),
    ),
  );
}

class MobileGroupPreview extends StatelessWidget {
  const MobileGroupPreview(this.navigation, {super.key});
  final MobileGroupNavigation navigation;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: context.syblColors.surface,
    child: Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisAlignment: MainAxisAlignment.center,
        children: navigation == MobileGroupNavigation.roomsFirst
            ? [
                for (final room in ['Main', 'Plans', 'Voice room'])
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 1),
                    child: Row(
                      children: [
                        Icon(
                          room == 'Voice room'
                              ? Icons.volume_up_outlined
                              : Icons.tag_rounded,
                          size: 12,
                          color: context.syblColors.muted,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          room,
                          style: TextStyle(
                            fontSize: 10,
                            color: context.syblColors.ink,
                          ),
                        ),
                      ],
                    ),
                  ),
              ]
            : [
                Text(
                  'Main   Plans   +',
                  style: TextStyle(
                    fontSize: 10,
                    color: context.syblColors.muted,
                  ),
                ),
                const SizedBox(height: 4),
                const _SampleMessage('Who’s coming?'),
              ],
      ),
    ),
  );
}

class TopicBackgroundPreview extends StatelessWidget {
  const TopicBackgroundPreview(this.settings, {super.key});
  final TopicStripSurfaceSettings settings;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(8),
    child: ColoredBox(
      color: context.syblColors.surface,
      child: LayoutBuilder(
        builder: (context, constraints) => Stack(
          children: [
            Positioned(
              left: 8,
              top: 18,
              right: 8,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _SampleMessage('See you this weekend'),
                  const SizedBox(height: 12),
                  const Align(
                    alignment: Alignment.centerRight,
                    child: _SampleMessage('Sounds good!'),
                  ),
                ],
              ),
            ),
            Positioned.fill(
              child: TopicStripSurface(
                settings: settings,
                endpoint: constraints.maxWidth * .72,
                pillBottom: 30,
              ),
            ),
            Positioned(
              left: 6,
              top: 6,
              right: 6,
              child: Row(
                children: [
                  for (final name in ['Main', 'Plans'])
                    Padding(
                      padding: const EdgeInsets.only(right: 5),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: context.syblColors.surfaceHi,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: context.syblColors.lineStrong,
                          ),
                        ),
                        child: Text(
                          name,
                          style: TextStyle(
                            fontSize: 9,
                            color: context.syblColors.ink,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class WindowEdgeSpacingPreview extends StatelessWidget {
  const WindowEdgeSpacingPreview(this.spacing, {super.key});
  final WindowEdgeSpacing spacing;

  @override
  Widget build(BuildContext context) {
    final colors = context.syblColors;
    final gap = spacing == WindowEdgeSpacing.close ? 4.0 : 12.0;
    return SizedBox(
      height: 64,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceHi,
          borderRadius: BorderRadius.circular(5),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(5),
          child: Stack(
            children: [
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 10,
                child: ColoredBox(color: colors.lineStrong),
              ),
              Positioned(
                key: ValueKey('edge-spacing-window-${spacing.name}'),
                right: gap,
                bottom: 10 + gap,
                width: 64,
                height: 40,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.bg,
                    borderRadius: BorderRadius.circular(4),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: .25),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      SizedBox(
                        height: 10,
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: Icon(
                              Icons.close_rounded,
                              size: 6,
                              color: colors.muted,
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SizedBox(
                              width: 24,
                              child: ColoredBox(color: colors.surface),
                            ),
                            Expanded(
                              child: Center(
                                child: Icon(
                                  Icons.chat_bubble_outline_rounded,
                                  size: 13,
                                  color: colors.muted,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class UnreadBadgePreview extends StatelessWidget {
  const UnreadBadgePreview(this.placement, {super.key});
  final UnreadBadgePlacement placement;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Badge(
        label: const Text('2'),
        isLabelVisible: placement == UnreadBadgePlacement.avatar,
        child: CircleAvatar(
          radius: 16,
          backgroundColor: context.syblColors.sage,
          child: Text(
            'A',
            style: TextStyle(color: context.syblColors.bg, fontSize: 12),
          ),
        ),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Text(
          'Alex',
          style: TextStyle(color: context.syblColors.ink, fontSize: 12),
        ),
      ),
      if (placement == UnreadBadgePlacement.trailing)
        const Badge(label: Text('2'))
      else
        Text(
          '2m',
          style: TextStyle(color: context.syblColors.muted, fontSize: 10),
        ),
    ],
  );
}
