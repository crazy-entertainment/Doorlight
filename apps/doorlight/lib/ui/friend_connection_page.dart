import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import 'gravity.dart';
import 'sybl_ui.dart';
import 'windows_chrome.dart';
import 'window_presentation.dart';

PageRoute<T> friendConnectionRoute<T>(BuildContext context, Widget child) =>
    PageRouteBuilder<T>(
      transitionDuration: SyblMotion.duration(
        context,
        const Duration(milliseconds: 280),
      ),
      reverseTransitionDuration: SyblMotion.duration(
        context,
        const Duration(milliseconds: 220),
      ),
      // A pane's own navigator already sits under the window's controls, so
      // its page starts below their drag strip instead.
      pageBuilder: (_, _, _) => InheritedTheme.captureAll(
        context,
        Navigator.of(context) == Navigator.of(context, rootNavigator: true)
            ? WindowsChromeContent(compactContentAvailable: true, child: child)
            : Builder(
                builder: (context) {
                  final media = MediaQuery.of(context);
                  return MediaQuery(
                    data: media.copyWith(
                      padding: media.padding.copyWith(
                        top: WindowsChrome.height,
                      ),
                    ),
                    child: child,
                  );
                },
              ),
      ),
      transitionsBuilder: (_, animation, _, child) {
        final eased = animation.drive(CurveTween(curve: Curves.easeOutCubic));
        return FadeTransition(
          opacity: eased,
          child: SlideTransition(
            position: eased.drive(
              Tween(begin: const Offset(.04, 0), end: Offset.zero),
            ),
            child: child,
          ),
        );
      },
    );

class FriendConnectionPage extends StatelessWidget {
  const FriendConnectionPage({
    super.key,
    required this.title,
    required this.child,
    this.actions = const [],
    this.maxWidth = 640,
  });
  final String title;
  final Widget child;
  final List<Widget> actions;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.escape): () =>
          Navigator.of(context).maybePop(),
    },
    child: Focus(
      autofocus: true,
      child: Scaffold(
        backgroundColor: context.syblColors.bg,
        body: SafeArea(
          child: Column(
            children: [
              if (WindowPresentationScope.isCompact(context))
                CompactHeader(
                  title: title,
                  onBack: () => Navigator.of(context).maybePop(),
                )
              else
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 24, 0),
                  child: Row(
                    children: [
                      const Gravity(child: BackButton()),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Gravity(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.syblColors.display.copyWith(
                              fontSize: 22,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: maxWidth),
                    child: SizedBox(
                      width: double.infinity,
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: child,
                      ),
                    ),
                  ),
                ),
              ),
              if (actions.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 12,
                    runSpacing: 8,
                    children: actions,
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}
