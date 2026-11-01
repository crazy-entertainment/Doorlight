// Release builds define NDEBUG, which turns assert() into a no-op and would let
// this test pass without checking anything. Keep the assertions.
#undef NDEBUG

#include "window_bounds.h"

#include <cassert>
#include <cstdio>
#include <vector>

using sybl::window::Bounds;
using sybl::window::ChooseRestoreBounds;
using sybl::window::WorkArea;

namespace {

constexpr int kMinWidth = 480;
constexpr int kMinHeight = 320;

// Primary at the origin, plus a second monitor placed to the LEFT of it, which
// is the negative-virtual-origin layout the remote-control mapping also has to
// survive.
std::vector<WorkArea> TwoMonitorsWithLeftPanel() {
  return {WorkArea{0, 0, 1920, 1040}, WorkArea{-1600, 0, 0, 860}};
}

void FullyVisibleBoundsSurviveUnchanged() {
  const Bounds saved{200, 150, 700, 500, false};
  const auto restored =
      ChooseRestoreBounds(saved, TwoMonitorsWithLeftPanel(), kMinWidth, kMinHeight);
  assert(restored && *restored == saved);
}

void BoundsOnANegativeOriginMonitorSurvive() {
  const Bounds saved{-1200, 80, 700, 500, false};
  const auto restored =
      ChooseRestoreBounds(saved, TwoMonitorsWithLeftPanel(), kMinWidth, kMinHeight);
  assert(restored && *restored == saved);
}

void MaximizedFlagIsPreserved() {
  const Bounds saved{100, 100, 700, 500, true};
  const auto restored =
      ChooseRestoreBounds(saved, TwoMonitorsWithLeftPanel(), kMinWidth, kMinHeight);
  assert(restored && restored->maximized);
}

void UnpluggedMonitorFallsBackToDefaultPlacement() {
  // The window was last on the left-hand panel; only the primary remains.
  const Bounds saved{-1200, 80, 700, 500, false};
  const std::vector<WorkArea> primary_only{WorkArea{0, 0, 1920, 1040}};
  assert(!ChooseRestoreBounds(saved, primary_only, kMinWidth, kMinHeight));
}

void PartiallyOffScreenBoundsAreClampedBackIntoView() {
  const Bounds saved{1800, 900, 700, 500, false};
  const std::vector<WorkArea> primary_only{WorkArea{0, 0, 1920, 1040}};
  const auto restored =
      ChooseRestoreBounds(saved, primary_only, kMinWidth, kMinHeight);
  assert(restored);
  assert(restored->x == 1920 - 700 && restored->y == 1040 - 500);
  assert(restored->width == 700 && restored->height == 500);
}

void WindowLargerThanTheMonitorIsShrunkToFit() {
  const Bounds saved{0, 0, 1800, 1000, false};
  const std::vector<WorkArea> small{WorkArea{0, 0, 1024, 768}};
  const auto restored = ChooseRestoreBounds(saved, small, kMinWidth, kMinHeight);
  assert(restored);
  assert(restored->width == 1024 && restored->height == 768);
  assert(restored->x == 0 && restored->y == 0);
}

void CorruptOrAbsurdSizesAreRejected() {
  const std::vector<WorkArea> areas = TwoMonitorsWithLeftPanel();
  assert(!ChooseRestoreBounds(Bounds{0, 0, 0, 0, false}, areas, kMinWidth, kMinHeight));
  assert(!ChooseRestoreBounds(Bounds{0, 0, -700, 500, false}, areas, kMinWidth,
                              kMinHeight));
  // Below the caller's declared minimum usable size.
  assert(!ChooseRestoreBounds(Bounds{0, 0, 100, 100, false}, areas, kMinWidth,
                              kMinHeight));
  // Absurdly large, e.g. a corrupt registry value.
  assert(!ChooseRestoreBounds(Bounds{0, 0, 900000, 500, false}, areas, kMinWidth,
                              kMinHeight));
}

void NoMonitorsAtAllFallsBackToDefaultPlacement() {
  assert(!ChooseRestoreBounds(Bounds{0, 0, 700, 500, false}, {}, kMinWidth,
                              kMinHeight));
  // A degenerate work area must not be selected either.
  const std::vector<WorkArea> degenerate{WorkArea{0, 0, 0, 0}};
  assert(!ChooseRestoreBounds(Bounds{0, 0, 700, 500, false}, degenerate, kMinWidth,
                              kMinHeight));
}

void MonitorTooSmallForTheMinimumIsRejected() {
  const std::vector<WorkArea> tiny{WorkArea{0, 0, 200, 150}};
  assert(!ChooseRestoreBounds(Bounds{0, 0, 700, 500, false}, tiny, kMinWidth,
                              kMinHeight));
}

void TheMostOverlappedMonitorWins() {
  // Mostly on the left panel, slightly crossing onto the primary.
  const Bounds saved{-400, 100, 700, 500, false};
  const auto restored =
      ChooseRestoreBounds(saved, TwoMonitorsWithLeftPanel(), kMinWidth, kMinHeight);
  assert(restored);
  // Clamped fully onto the left panel, whose right edge is 0.
  assert(restored->x == -700 && restored->width == 700);
}

}  // namespace

int main() {
  // Visible edges keep an equal gap at different DPI frame sizes, including DWM failure
  // (zero insets), negative monitor origins and windows larger than the work area.
  for (const int border : {0, 7, 11, 14}) {
    for (const WorkArea area : {WorkArea{0, 0, 1920, 1040},
                               WorkArea{-1600, -900, 0, -40}}) {
      for (const int gap : {0, 8, 12, 16}) {
        for (const int size : {700, 4000}) {
          const auto placed = sybl::window::ChooseDefaultBounds(
              area, size, size, {border, 0, border, border}, gap);
          assert(placed.x + placed.width - border == area.right - gap);
          assert(placed.y + placed.height - border == area.bottom - gap);
          assert(placed.x + border >= area.left + gap && placed.y >= area.top + gap);
          assert(placed.width <= size && placed.height <= size);
        }
      }
    }
  }
  FullyVisibleBoundsSurviveUnchanged();
  BoundsOnANegativeOriginMonitorSurvive();
  MaximizedFlagIsPreserved();
  UnpluggedMonitorFallsBackToDefaultPlacement();
  PartiallyOffScreenBoundsAreClampedBackIntoView();
  WindowLargerThanTheMonitorIsShrunkToFit();
  CorruptOrAbsurdSizesAreRejected();
  NoMonitorsAtAllFallsBackToDefaultPlacement();
  MonitorTooSmallForTheMinimumIsRejected();
  TheMostOverlappedMonitorWins();
  std::puts("window_bounds_test: ok");
  return 0;
}
