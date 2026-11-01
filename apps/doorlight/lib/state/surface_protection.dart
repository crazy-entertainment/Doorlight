import 'dart:async';

import 'package:flutter/foundation.dart';

/// Android screen-capture scope: the native window is secure only while at
/// least one sensitive surface (chat, call, link code, history search) is
/// mounted. Each surface stays replaced by a neutral placeholder until native
/// confirms a secure frame, and protection is lifted only after frames without
/// sensitive content have been presented. Failure keeps the placeholder.
class SensitiveSurfaceProtection extends ChangeNotifier {
  SensitiveSurfaceProtection({
    required this._apply,
    required this._armed,
    required this._settle,
  });

  final Future<bool> Function(bool visible) _apply;
  final bool Function() _armed;
  final Future<void> Function() _settle;

  int _holders = 0;
  bool _secured = false;
  bool _failed = false;
  // Native starts with sensitive surfaces assumed visible; unknown until the
  // first report, so an idle boot still lifts protection once.
  bool? _reportedVisible;
  bool _pumping = false;
  // Completed by acquire so a new sensitive surface never waits out a settle.
  Completer<void>? _settleInterrupt;
  bool _disposed = false;

  bool get revealAllowed => !_armed() || _secured;
  bool get failed => _armed() && _failed;
  @visibleForTesting
  int get holders => _holders;

  void acquire() {
    _holders++;
    _settleInterrupt?.complete();
    _settleInterrupt = null;
    _pump();
  }

  void release() {
    assert(_holders > 0);
    if (_holders > 0) _holders--;
    _pump();
  }

  /// Re-establishes protection after the preference or a failure changed.
  void refresh() {
    _secured = false;
    _failed = false;
    _reportedVisible = null;
    _notify();
    _pump();
  }

  Future<void> _pump() async {
    if (_pumping || _disposed) return;
    _pumping = true;
    try {
      while (!_disposed && _armed()) {
        if (_holders > 0) {
          if (_secured || _failed) break;
          bool ok;
          try {
            ok = await _apply(true);
          } catch (_) {
            ok = false;
          }
          if (_disposed) return;
          _reportedVisible = true;
          if (_holders == 0) continue;
          _secured = ok;
          _failed = !ok;
          _notify();
          if (!ok) break;
        } else {
          if (_reportedVisible == false) break;
          // Lift protection only once frames without sensitive content
          // have replaced the last protected frame.
          final interrupt = _settleInterrupt = Completer<void>();
          await Future.any([_settle(), interrupt.future]);
          if (identical(_settleInterrupt, interrupt)) _settleInterrupt = null;
          if (_disposed) return;
          if (_holders > 0) continue;
          _secured = false;
          _failed = false;
          try {
            await _apply(false);
            _reportedVisible = false;
          } catch (_) {
            // Native stays secure; a later transition retries.
            break;
          }
        }
      }
    } finally {
      _pumping = false;
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
