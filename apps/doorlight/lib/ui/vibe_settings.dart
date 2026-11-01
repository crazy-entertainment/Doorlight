import 'package:flutter/material.dart';

import '../state/app_settings.dart';
import '../theme.dart';
import 'ambient_vibe.dart';
import 'settings_previews.dart';

class VibeSettings extends StatefulWidget {
  const VibeSettings({
    super.key,
    required this.value,
    required this.opacity,
    required this.intensity,
    required this.animated,
    required this.enabled,
    required this.onChanged,
    required this.onOpacityChanged,
    required this.onIntensityChanged,
  });

  final AmbientVibe value;
  final int opacity;
  final int intensity;
  final bool animated;
  final bool enabled;
  final ValueChanged<AmbientVibe> onChanged;
  final Future<bool> Function(int) onOpacityChanged;
  final Future<bool> Function(int) onIntensityChanged;

  @override
  State<VibeSettings> createState() => _VibeSettingsState();
}

class _VibeSettingsState extends State<VibeSettings>
    with WidgetsBindingObserver {
  double? _draft;
  double? _intensityDraft;
  final _opacityFocus = FocusNode();
  final _intensityFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeMetrics() {
    // Resizing dismisses the popup, so discard its uncommitted preview too.
    setState(() {
      _draft = null;
      _intensityDraft = null;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _opacityFocus.dispose();
    _intensityFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final opacity = _draft ?? widget.opacity.toDouble();
    final textScale = MediaQuery.textScalerOf(context).scale(1).clamp(1, 2);
    const adjustmentsWidth = 44.0;
    final choiceGaps = 4.0 * (AmbientVibe.values.length - 1);
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth:
              68 * textScale * AmbientVibe.values.length +
              choiceGaps +
              8 +
              adjustmentsWidth,
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final beside =
                constraints.maxWidth >=
                64 * textScale * AmbientVibe.values.length +
                    choiceGaps +
                    8 +
                    adjustmentsWidth;
            return SettingsChoices<AmbientVibe>(
              title: 'Vibe',
              trailingBesideChoices: beside,
              trailing: Column(
                key: const ValueKey('vibe-adjustments'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  _adjustment(
                    focusNode: _intensityFocus,
                    icon: Icons.blur_on_rounded,
                    label: 'Intensity',
                    value: _intensityDraft ?? widget.intensity.toDouble(),
                    onChanged: (value) =>
                        setState(() => _intensityDraft = value),
                    onClose: () => setState(() => _intensityDraft = null),
                    onChangeEnd: (value) async {
                      await widget.onIntensityChanged(value.round());
                      if (mounted) setState(() => _intensityDraft = null);
                    },
                  ),
                  _adjustment(
                    focusNode: _opacityFocus,
                    icon: Icons.opacity_rounded,
                    label: 'Opacity',
                    value: opacity,
                    onChanged: (value) => setState(() => _draft = value),
                    onClose: () => setState(() => _draft = null),
                    onChangeEnd: (value) async {
                      await widget.onOpacityChanged(value.round());
                      if (mounted) setState(() => _draft = null);
                    },
                  ),
                ],
              ),
              allPreviews: true,
              singleRow: true,
              previewHeight: 56,
              maxTileWidth: 68,
              values: AmbientVibe.values,
              value: widget.value,
              label: vibeLabel,
              preview: (vibe) => VibePreview(
                vibe,
                opacity: opacity / 100,
                intensity:
                    (_intensityDraft ?? widget.intensity.toDouble()) / 100,
                animated: widget.animated && vibe == widget.value,
              ),
              enabled: widget.enabled,
              onChanged: widget.onChanged,
            );
          },
        ),
      ),
    );
  }

  Widget _adjustment({
    required FocusNode focusNode,
    required IconData icon,
    required String label,
    required double value,
    required ValueChanged<double> onChanged,
    required ValueChanged<double> onChangeEnd,
    required VoidCallback onClose,
  }) => MenuAnchor(
    childFocusNode: focusNode,
    onClose: onClose,
    style: MenuStyle(
      backgroundColor: WidgetStatePropertyAll(context.syblColors.surface),
      padding: const WidgetStatePropertyAll(EdgeInsets.fromLTRB(12, 8, 12, 2)),
      shape: const WidgetStatePropertyAll(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
      ),
      side: WidgetStatePropertyAll(
        BorderSide(color: context.syblColors.lineStrong),
      ),
      elevation: const WidgetStatePropertyAll(0),
    ),
    builder: (context, controller, _) => Semantics(
      label: label,
      value: '${value.round()} percent',
      child: IconButton(
        key: ValueKey('vibe-${label.toLowerCase()}-button'),
        focusNode: focusNode,
        tooltip: '$label · ${value.round()}%',
        onPressed: widget.enabled
            ? () => controller.isOpen ? controller.close() : controller.open()
            : null,
        style: IconButton.styleFrom(
          minimumSize: const Size(44, 44),
          maximumSize: const Size(44, 44),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        icon: Icon(icon, size: 18),
      ),
    ),
    menuChildren: [
      SizedBox(
        width: (MediaQuery.sizeOf(context).width - 48).clamp(0, 196),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      color: context.syblColors.ink,
                      fontSize: 12,
                    ),
                  ),
                ),
                Text(
                  '${value.round()}%',
                  style: TextStyle(
                    color: context.syblColors.ink,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            SizedBox(
              height: 44,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  showValueIndicator: ShowValueIndicator.never,
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 5,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 10,
                  ),
                ),
                child: Slider(
                  key: ValueKey('vibe-${label.toLowerCase()}-slider'),
                  autofocus: true,
                  value: value,
                  min: 0,
                  max: 100,
                  divisions: 100,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  semanticFormatterCallback: (value) =>
                      'Vibe $label ${value.round()} percent',
                  onChanged: widget.enabled ? onChanged : null,
                  onChangeEnd: widget.enabled ? onChangeEnd : null,
                ),
              ),
            ),
          ],
        ),
      ),
    ],
  );
}
