import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../state/app_settings.dart';
import '../theme.dart';

double topicStripSurfaceHeight(
  TopicStripSurfaceSettings settings, {
  required double pillBottom,
}) => pillBottom + settings.solidReach + settings.lowerFade;

class TopicStripSurface extends StatelessWidget {
  const TopicStripSurface({
    super.key,
    required this.settings,
    required this.endpoint,
    required this.pillBottom,
    this.surfaceKey,
    this.mainKey,
    this.rightFadeKey,
  });

  final TopicStripSurfaceSettings settings;
  final double endpoint;
  final double pillBottom;
  final Key? surfaceKey;
  final Key? mainKey;
  final Key? rightFadeKey;

  @override
  Widget build(BuildContext context) {
    if (settings.coverage == TopicStripSurfaceCoverage.off) {
      return const SizedBox.shrink(key: ValueKey('topic-strip-surface-off'));
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = settings.coverage == TopicStripSurfaceCoverage.fullWidth
            ? constraints.maxWidth
            : endpoint.clamp(0.0, constraints.maxWidth).toDouble();
        final height = topicStripSurfaceHeight(
          settings,
          pillBottom: pillBottom,
        );
        final rightFade = settings.rightFade.clamp(0.0, width).toDouble();
        final mainWidth = width - rightFade;
        final solidStop = height == 0
            ? 0.0
            : ((pillBottom + settings.solidReach) / height).clamp(0.0, 1.0);
        final color = context.syblColors.surface.withValues(
          alpha: settings.strength / 100,
        );
        Widget verticalSurface({required Widget child}) => ClipRect(
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(
              sigmaX: settings.blur.toDouble(),
              sigmaY: settings.blur.toDouble(),
              tileMode: TileMode.decal,
            ),
            child: child,
          ),
        );

        return Align(
          alignment: Alignment.topLeft,
          child: IgnorePointer(
            child: SizedBox(
              key: surfaceKey ?? const ValueKey('topic-strip-surface'),
              width: width,
              height: height,
              child: Stack(
                children: [
                  if (mainWidth > 0)
                    Positioned(
                      left: 0,
                      top: 0,
                      width: mainWidth,
                      height: height,
                      child: verticalSurface(
                        child: DecoratedBox(
                          key:
                              mainKey ??
                              const ValueKey('topic-strip-surface-main'),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [color, color, Colors.transparent],
                              stops: [0, solidStop, 1],
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (rightFade > 0)
                    Positioned(
                      key:
                          rightFadeKey ??
                          const ValueKey('topic-strip-surface-right-fade'),
                      left: mainWidth,
                      top: 0,
                      width: rightFade,
                      height: height,
                      child: verticalSurface(
                        child: ShaderMask(
                          blendMode: BlendMode.dstIn,
                          shaderCallback: (bounds) => LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: const [
                              Colors.black,
                              Colors.black,
                              Colors.transparent,
                            ],
                            stops: [0, solidStop, 1],
                          ).createShader(bounds),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.centerLeft,
                                end: Alignment.centerRight,
                                colors: [color, Colors.transparent],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
