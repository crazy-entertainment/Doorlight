import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';

/// Flutter's controllers also read the binding, independently of MediaQuery.
/// Keep their timing governed by the same in-app preference.
mixin DoorlightMotionPolicy on SemanticsBinding {
  bool animationsEnabled = true;

  @override
  bool get disableAnimations => !animationsEnabled;
}

class DoorlightBinding extends WidgetsFlutterBinding
    with DoorlightMotionPolicy {}
