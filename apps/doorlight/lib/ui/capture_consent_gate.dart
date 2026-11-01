import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../theme.dart';

/// Outermost, data-free Windows capture-consent surface.
///
/// Rendered INSTEAD of every other application surface while a Windows
/// capture decision or protection failure is unresolved. The backdrop is a blurred MOCK of the
/// product layout, never the running app.
/// The mock intentionally keeps only the impression of avatar and
/// conversation shapes behind a moderate blur, but carries no real identity,
/// contact, message, presence, call, or notification data. Never swap it for
/// the real widget tree: blur is obfuscation, not redaction.
///
/// Capture-product recording/streaming detection is best effort and does not identify the
/// captured source. Detection only opens the prompt. The data-free frame is
/// presented before capture affinity is relaxed; private content stays absent
/// until the user chooses Show or native protection is restored.
///
/// There is no local dismiss path: Escape, closing to tray, re-opening, and
/// lifecycle changes leave the decision unresolved. The explicit actions, a
/// detected capture stop, or a persisted preference of "off" resolve it.
final class CaptureConsentGate extends StatefulWidget {
  const CaptureConsentGate({super.key, required this.state});

  final AppState state;

  @override
  State<CaptureConsentGate> createState() => _CaptureConsentGateState();
}

final class _CaptureConsentGateState extends State<CaptureConsentGate> {
  AppState get state => widget.state;
  int? _presentedGeneration;

  @override
  void initState() {
    super.initState();
    state.addListener(_refresh);
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(CaptureConsentGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != state) {
      oldWidget.state.removeListener(_refresh);
      state.addListener(_refresh);
      _presentedGeneration = null;
    }
  }

  @override
  void dispose() {
    state.removeListener(_refresh);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (state.captureGateVisible &&
        state.captureGateReady &&
        state.captureActivityActive &&
        !state.captureBusy &&
        _presentedGeneration != state.capturePromptGeneration) {
      final generation = state.capturePromptGeneration;
      _presentedGeneration = generation;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        final accepted = await state.presentWindowsCapturePrompt(generation);
        if (mounted && !accepted) _presentedGeneration = null;
      });
    }
    if (!state.captureGateReady) {
      // Preference loading is itself sensitive control state. Do not paint
      // the question before the saved choice is known: a durable "show"
      // preference must never flash a prompt that will immediately disappear.
      return Scaffold(
        key: const ValueKey('capture-consent-gate'),
        backgroundColor: context.syblColors.bg,
        body: Stack(
          fit: StackFit.expand,
          children: [
            const ExcludeSemantics(child: _BlurredMockSurface()),
            ColoredBox(color: context.syblColors.bg.withValues(alpha: .54)),
            Center(
              child: Semantics(
                container: true,
                label: 'Preparing private app surface',
                child: const SizedBox.square(
                  dimension: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          ],
        ),
      );
    }
    final error = state.captureGateError;
    final busy = state.captureBusy;
    final title = state.captureActivityActive && error == null
        ? 'Screen sharing or recording detected. Show Doorlight?'
        : 'Screen-capture protection needs your choice.';
    return Scaffold(
      key: const ValueKey('capture-consent-gate'),
      backgroundColor: context.syblColors.bg,
      body: Stack(
        fit: StackFit.expand,
        children: [
          const ExcludeSemantics(child: _BlurredMockSurface()),
          // The mock is intentionally recognizable as layout, but this scrim
          // keeps the privacy choice dominant and legible.
          ColoredBox(color: context.syblColors.bg.withValues(alpha: .62)),
          SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Semantics(
                    container: true,
                    label: title,
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            title,
                            textAlign: TextAlign.center,
                            style: context.syblColors.display.copyWith(
                              fontSize: 20,
                            ),
                          ),
                          if (error != null) ...[
                            const SizedBox(height: 14),
                            Text(
                              error,
                              key: const ValueKey('capture-consent-error'),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: context.syblColors.danger,
                                fontSize: 12.5,
                                height: 1.4,
                              ),
                            ),
                          ],
                          const SizedBox(height: 22),
                          if (busy)
                            const SizedBox.square(
                              dimension: 24,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          else ...[
                            Wrap(
                              spacing: 10,
                              runSpacing: 10,
                              alignment: WrapAlignment.center,
                              children: [
                                FilledButton(
                                  key: const ValueKey('capture-consent-show'),
                                  onPressed: () =>
                                      state.captureConsentShowThisSession(),
                                  child: const Text(
                                    'Show',
                                    style: TextStyle(
                                      fontFamily: Warm.sansFamily,
                                      fontFamilyFallback: Warm.sansFallback,
                                    ),
                                  ),
                                ),
                                OutlinedButton(
                                  key: const ValueKey(
                                    'capture-consent-show-always',
                                  ),
                                  onPressed: state.captureConsentShowAlways,
                                  child: const Text('Show always'),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            TextButton(
                              key: const ValueKey('capture-consent-hide'),
                              onPressed: () => state.captureConsentHide(),
                              child: Text(
                                error == null
                                    ? 'Keep it hidden from capture'
                                    : 'Retry keeping it hidden',
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A blurred, data-free impression of the product layout.
///
/// Deliberately built from plain boxes rather than the real widgets: it must
/// stay impossible for this to render live state, because it is painted while
/// the window is capturable.
final class _BlurredMockSurface extends StatelessWidget {
  const _BlurredMockSurface();

  @override
  Widget build(BuildContext context) {
    final colors = context.syblColors;
    Widget bar(double width, double height, {Color? color}) => Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: color ?? colors.muted.withValues(alpha: .42),
        borderRadius: BorderRadius.circular(height / 2),
      ),
    );

    final avatarColors = [colors.rose, colors.sky, colors.sage];

    Widget avatar(int index, {double size = 34}) => Container(
      key: const ValueKey('capture-mock-avatar'),
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: avatarColors[index % avatarColors.length],
        shape: BoxShape.circle,
      ),
      child: Icon(
        Icons.person_rounded,
        size: size * .58,
        color: colors.bg.withValues(alpha: .62),
      ),
    );

    Widget contactRow(int index) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      child: Row(
        children: [
          avatar(index),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              bar(72 + (index * 8), 9),
              const SizedBox(height: 6),
              bar(
                48 + (index * 7),
                7,
                color: colors.faint.withValues(alpha: .3),
              ),
            ],
          ),
        ],
      ),
    );

    Widget messageRow({
      required int index,
      required bool outgoing,
      required double width,
    }) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 7),
      child: Row(
        mainAxisAlignment: outgoing
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!outgoing) ...[avatar(index, size: 28), const SizedBox(width: 8)],
          Container(
            key: const ValueKey('capture-mock-message'),
            width: width,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: outgoing
                  ? colors.amber.withValues(alpha: .56)
                  : colors.surfaceTop,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                bar(width * .68, 8, color: colors.ink.withValues(alpha: .34)),
                const SizedBox(height: 7),
                bar(width * .42, 8, color: colors.ink.withValues(alpha: .24)),
              ],
            ),
          ),
        ],
      ),
    );

    final mock = ImageFiltered(
      imageFilter: ui.ImageFilter.blur(sigmaX: 6, sigmaY: 6),
      child: ColoredBox(
        color: colors.bg,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 210,
              child: ColoredBox(
                color: colors.surface,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 18),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      child: bar(60, 10),
                    ),
                    const SizedBox(height: 10),
                    contactRow(0),
                    contactRow(1),
                    contactRow(2),
                    contactRow(3),
                  ],
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 22),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Row(
                      children: [
                        avatar(1, size: 38),
                        const SizedBox(width: 11),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            bar(112, 11),
                            const SizedBox(height: 6),
                            bar(
                              68,
                              7,
                              color: colors.online.withValues(alpha: .52),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  messageRow(index: 1, outgoing: false, width: 210),
                  messageRow(index: 0, outgoing: true, width: 180),
                  messageRow(index: 2, outgoing: false, width: 235),
                  const Spacer(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 0, 18, 20),
                    child: Container(
                      height: 40,
                      decoration: BoxDecoration(
                        color: colors.surfaceHi,
                        borderRadius: BorderRadius.circular(20),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    // The decorative canvas keeps its layout on narrow or short windows.
    // Crop only the mock; the consent controls above remain responsive.
    return LayoutBuilder(
      builder: (context, constraints) => ClipRect(
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: constraints.maxWidth.clamp(560, double.infinity),
          maxWidth: constraints.maxWidth.clamp(560, double.infinity),
          minHeight: constraints.maxHeight.clamp(400, double.infinity),
          maxHeight: constraints.maxHeight.clamp(400, double.infinity),
          child: mock,
        ),
      ),
    );
  }
}
