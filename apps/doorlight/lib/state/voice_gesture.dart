enum VoiceGesturePhase {
  idle,
  pressPending,
  startingHeld,
  held,
  startingLocked,
  locked,
  stopping,
  review,
}

enum VoiceGestureEffect { none, start, stopToReview, stopAndSend, discard }

/// Input intent only. Hardware ownership and confirmed release remain native.
/// Async completions must carry [activation] and the composer operation owner.
final class VoiceGesture {
  VoiceGesturePhase phase = VoiceGesturePhase.idle;
  Object? activation;
  bool _pointer = false;
  bool _cancelled = false;
  bool _releaseEligible = false;

  VoiceGestureEffect press() {
    if (phase != VoiceGesturePhase.idle) return VoiceGestureEffect.none;
    activation = Object();
    _pointer = true;
    _cancelled = false;
    _releaseEligible = true;
    phase = VoiceGesturePhase.pressPending;
    return VoiceGestureEffect.none;
  }

  VoiceGestureEffect accessibleStart() {
    if (phase != VoiceGesturePhase.idle) return VoiceGestureEffect.none;
    activation = Object();
    _pointer = false;
    _cancelled = false;
    _releaseEligible = false;
    phase = VoiceGesturePhase.startingLocked;
    return VoiceGestureEffect.start;
  }

  VoiceGestureEffect holdThreshold(Object token) {
    if (!identical(token, activation) ||
        !_pointer ||
        _cancelled ||
        phase != VoiceGesturePhase.pressPending) {
      return VoiceGestureEffect.none;
    }
    phase = VoiceGesturePhase.startingHeld;
    return VoiceGestureEffect.start;
  }

  VoiceGestureEffect drag({required bool left, required bool up}) {
    if (!_pointer ||
        phase == VoiceGesturePhase.stopping ||
        phase == VoiceGesturePhase.review) {
      return VoiceGestureEffect.none;
    }
    if (left) {
      _cancelled = true;
      _releaseEligible = false;
      final started = phase != VoiceGesturePhase.pressPending;
      phase = started ? VoiceGesturePhase.stopping : VoiceGesturePhase.idle;
      _pointer = false;
      return started ? VoiceGestureEffect.discard : VoiceGestureEffect.none;
    }
    if (up && !_cancelled) {
      _releaseEligible = false;
      if (phase == VoiceGesturePhase.pressPending) {
        phase = VoiceGesturePhase.startingLocked;
        return VoiceGestureEffect.start;
      }
      if (phase == VoiceGesturePhase.startingHeld) {
        phase = VoiceGesturePhase.startingLocked;
      }
      if (phase == VoiceGesturePhase.held) phase = VoiceGesturePhase.locked;
    }
    return VoiceGestureEffect.none;
  }

  VoiceGestureEffect release() {
    if (!_pointer) return VoiceGestureEffect.none;
    _pointer = false;
    if (_cancelled) return VoiceGestureEffect.none;
    if (phase == VoiceGesturePhase.pressPending) {
      _releaseEligible = false;
      phase = VoiceGesturePhase.startingLocked;
      return VoiceGestureEffect.start;
    }
    if (phase == VoiceGesturePhase.held && _releaseEligible) {
      phase = VoiceGesturePhase.stopping;
      _releaseEligible = false;
      return VoiceGestureEffect.stopAndSend;
    }
    // Releasing before the asynchronous native start completes cannot send.
    // Stop any eventual capture into review rather than reviving the gesture.
    if (phase == VoiceGesturePhase.startingHeld) return interrupt();
    return VoiceGestureEffect.none;
  }

  VoiceGestureEffect started(Object token) {
    if (!identical(token, activation) || _cancelled) {
      return VoiceGestureEffect.discard;
    }
    if (phase == VoiceGesturePhase.startingHeld) {
      phase = VoiceGesturePhase.held;
      return VoiceGestureEffect.none;
    }
    if (phase == VoiceGesturePhase.startingLocked) {
      phase = VoiceGesturePhase.locked;
      return VoiceGestureEffect.none;
    }
    return VoiceGestureEffect.stopToReview;
  }

  /// Permission/lifecycle changes, call transitions, Stop, Escape and the
  /// duration guard all disarm pointer release before requesting native stop.
  VoiceGestureEffect interrupt() {
    _pointer = false;
    _releaseEligible = false;
    if (phase == VoiceGesturePhase.idle ||
        phase == VoiceGesturePhase.review ||
        phase == VoiceGesturePhase.stopping) {
      return VoiceGestureEffect.none;
    }
    if (phase == VoiceGesturePhase.pressPending) {
      phase = VoiceGesturePhase.idle;
      activation = null;
      return VoiceGestureEffect.none;
    }
    phase = VoiceGesturePhase.stopping;
    return VoiceGestureEffect.stopToReview;
  }

  bool stopped(Object token, {required bool validReview}) {
    if (!identical(token, activation) || phase != VoiceGesturePhase.stopping) {
      return false;
    }
    phase = validReview && !_cancelled
        ? VoiceGesturePhase.review
        : VoiceGesturePhase.idle;
    activation = null;
    return true;
  }
}
