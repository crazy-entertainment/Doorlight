// This test ships in the Release configuration, which defines NDEBUG and would compile every
// assert out — leaving a test that can never fail. Keep the asserts armed.
#undef NDEBUG

#include "screen_source.h"

#include <cassert>
#include <string>
#include <type_traits>

int main() {
  using namespace screen_source;
  const std::vector<Monitor> monitors{
      {0, R"(\\.\DISPLAY1|0,0,1920,1080)", "Primary", true, 0, 0, 1920, 1080},
      {1, R"(\\.\DISPLAY2|1920,-200,2560,1440)", "Second", false, 1920, -200, 2560, 1440},
  };
  assert(DisplayMrl(monitors[0]).value() == "display://:0+0,0 1920x1080");
  assert(DisplayMrl(monitors[1]).value() == "display://:1+0,0 2560x1440");
  assert(FindMonitor(monitors, R"(\\.\DISPLAY2|1920,-200,2560,1440)") == &monitors[1]);
  assert(FindMonitor(monitors, "1") == nullptr);
  assert(FindMonitor(monitors, R"(\\.\DISPLAY2|0,0,2560,1440)") == nullptr);
  assert(FindMonitor(monitors, "") == nullptr);
  assert(Classify("camera://device") == Kind::Camera);
  assert(Classify("camera://desktop") == Kind::Screen);
  assert(Classify("display://:0+0,0 1920x1080") == Kind::Screen);
  assert(Classify("") == Kind::Off);
  const Outgoing current{Kind::Screen, "display://:0+0,0 1920x1080", "call-a", 7, 1920, 1080};
  assert(AcceptsCompletion(current, "call-a", 7));
  assert(!AcceptsCompletion(current, "call-b", 7));
  assert(!AcceptsCompletion(current, "call-a", 6));
  const CaptureProof liveProof{current.uri, "call-a", 7, true};
  assert(OwnsCaptureProof(current, "call-a", liveProof));
  assert(!OwnsCaptureProof(current, "call-a",
                           CaptureProof{current.uri, "call-a", 7, false}));
  assert(!OwnsCaptureProof(current, "call-a",
                           CaptureProof{current.uri, "call-a", 6, true}));
  assert(!OwnsCaptureProof(current, "call-a",
                           CaptureProof{"display://:1+0,0 2560x1440",
                                        "call-a", 7, true}));
  assert(!OwnsCaptureProof(current, "call-b", liveProof));

  const Outgoing previous{Kind::Camera, "camera://front", "call-a", 6, 1280, 720};
  const Transition transition{previous, current};
  assert(OwnsTransition(current, "call-a", transition));
  assert(ResolveTransition(current, "call-a", transition, true).kind == Kind::Screen);
  const auto rolledBack = ResolveTransition(current, "call-a", transition, false);
  assert(rolledBack.uri == "camera://front");
  assert(rolledBack.epoch == 8);
  const Outgoing replacement{Kind::Screen, "display://:1+0,0 2560x1440", "call-b", 8, 2560, 1440};
  assert(!OwnsTransition(replacement, "call-b", transition));
  assert(ResolveTransition(replacement, "call-b", transition, false).uri == replacement.uri);
  assert(ShouldReassertAfterPeerAnswer(current, "call-a", "call-a", true, false));
  assert(!ShouldReassertAfterPeerAnswer(current, "call-a", "call-a", false, false));
  assert(!ShouldReassertAfterPeerAnswer(current, "call-a", "call-a", true, true));
  assert(!ShouldReassertAfterPeerAnswer(current, "call-b", "call-a", true, false));
  assert(!ShouldReassertAfterPeerAnswer(Outgoing{}, "call-a", "call-a", true, false));

  // A transition cancelled without a confirmed outcome (another call became CURRENT, the call
  // ended, or the target moved) returns to its previous source before ownership moves.
  {
    // Camera-off requested on call X over a live camera; winner Y cancels it.
    const Outgoing cameraBefore{Kind::Camera, "camera://back", "call-x", 4, 0, 0};
    const Outgoing offRequested{Kind::Off, "", "call-x", 5, 0, 0};
    const Transition cameraOff{cameraBefore, offRequested};
    auto cancelled = CancelTransition(offRequested, 1, cameraOff, 1);
    assert(cancelled.source.kind == Kind::Camera);
    assert(cancelled.source.uri == "camera://back");
    assert(cancelled.source.call_id == "call-x");
    assert(cancelled.source.epoch == 6);
    assert(cancelled.source.epoch > offRequested.epoch);
    assert(cancelled.camera_index == 1);
    cancelled.source.call_id = "call-y";  // the winner then takes ownership
    assert(cancelled.source.kind == Kind::Camera && cancelled.source.call_id == "call-y");

    // Screen requested while previously off: the result is off, never the screen.
    const Outgoing offBefore{Kind::Off, "", "call-x", 2, 0, 0};
    const Outgoing screenRequested{Kind::Screen, "display://:0+0,0 1920x1080", "call-x", 3,
                                   1920, 1080};
    const auto screenCancelled =
        CancelTransition(screenRequested, 0, Transition{offBefore, screenRequested}, 0);
    assert(screenCancelled.source.kind == Kind::Off);
    assert(screenCancelled.source.uri.empty());
    assert(screenCancelled.source.epoch == 4);

    // Camera switch: the unconfirmed camera index returns to the previous one.
    const Outgoing frontRequested{Kind::Camera, "camera://front", "call-x", 5, 0, 0};
    const auto switchCancelled =
        CancelTransition(frontRequested, 2, Transition{cameraBefore, frontRequested}, 1);
    assert(switchCancelled.source.uri == "camera://back");
    assert(switchCancelled.camera_index == 1);

    // The state no longer belongs to the transition: leave source and index untouched.
    const Outgoing newer{Kind::Screen, "display://:1+0,0 2560x1440", "call-x", 9, 2560, 1440};
    const auto untouched = CancelTransition(newer, 2, Transition{cameraBefore, frontRequested}, 1);
    assert(untouched.source.kind == newer.kind && untouched.source.uri == newer.uri);
    assert(untouched.source.call_id == newer.call_id && untouched.source.epoch == newer.epoch);
    assert(untouched.camera_index == 2);
    const Outgoing otherCall{Kind::Off, "", "call-z", 5, 0, 0};
    const auto otherUntouched = CancelTransition(otherCall, 2, cameraOff, 1);
    assert(otherUntouched.source.call_id == "call-z" && otherUntouched.source.epoch == 5);
    assert(otherUntouched.camera_index == 2);
  }

  // F6: only the invocation that admitted a transition may take it by ticket.
  {
    struct Pending {
      std::string call_id;
      int* done_calls;
    };
    int aDone = 0, bReply = 0, cDone = 0;
    TransitionSlot<Pending> slot;
    static_assert(!std::is_copy_assignable_v<TransitionSlot<Pending>>,
                  "slot = {} would clear a pending value without a ticket");
    static_assert(!std::is_move_assignable_v<TransitionSlot<Pending>>,
                  "slot = {} would reset the ticket counter");
    static_assert(!std::is_copy_constructible_v<TransitionSlot<Pending>>);
    const auto a = slot.Admit(Pending{"call-a", &aDone});
    assert(a != 0);
    // B for the same call is rejected busy; A's pending value is untouched.
    assert(slot.Admit(Pending{"call-a", &bReply}) == 0);
    assert(slot && slot->call_id == "call-a" && slot->done_calls == &aDone);
    // B never held a ticket: guessed and stale tickets take nothing.
    assert(!slot.Take(0).has_value());
    assert(!slot.Take(a + 1).has_value());
    assert(!slot.Take(a - 1).has_value());
    assert(slot && slot->done_calls == &aDone);
    ++bReply;  // B's own reply completes exactly once, with false
    assert(bReply == 1 && aDone == 0);
    // A completes exactly once; a second take yields nothing.
    auto taken = slot.Take(a);
    assert(taken.has_value());
    ++*taken->done_calls;
    assert(!slot && aDone == 1);
    assert(!slot.Take(a).has_value());
    // A-B-A: A's ticket cannot take a later transition C for the same call id.
    const auto c = slot.Admit(Pending{"call-a", &cDone});
    assert(c != 0 && c != a);
    assert(!slot.Take(a).has_value());
    assert(slot && slot->done_calls == &cDone);
    assert(slot.Take(c).has_value());
    // Call-ID completion (no ticket) still reads and clears the current value.
    const auto d = slot.Admit(Pending{"call-a", &cDone});
    assert(d != 0 && slot && slot->call_id == "call-a");
    slot.reset();
    assert(!slot && !slot.Take(d).has_value());
  }
}
