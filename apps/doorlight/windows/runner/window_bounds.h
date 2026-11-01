#pragma once

#include <optional>
#include <vector>

namespace sybl::window {

// Physical-pixel window rectangle plus the maximized flag, as persisted between
// runs. Coordinates are virtual-desktop relative and may be negative when the
// window last lived on a monitor left of or above the primary one.
struct Bounds {
  int x = 0;
  int y = 0;
  int width = 0;
  int height = 0;
  bool maximized = false;

  bool operator==(const Bounds& other) const {
    return x == other.x && y == other.y && width == other.width &&
        height == other.height && maximized == other.maximized;
  }
};

struct WorkArea {
  int left = 0;
  int top = 0;
  int right = 0;
  int bottom = 0;
};

// Invisible resize frame surrounding the DWM-visible window, in physical pixels.
struct FrameInsets {
  int left = 0;
  int top = 0;
  int right = 0;
  int bottom = 0;
};

// Inset the visible bottom/right edges by a physical-pixel gap, shrinking if
// necessary. The gap is capped on very small work areas.
Bounds ChooseDefaultBounds(const WorkArea& area, int width, int height,
                           const FrameInsets& frame, int gap = 0);

// Decides where a previously saved window should reappear.
//
// Returns std::nullopt when the saved bounds must be discarded in favour of the
// caller's default placement: malformed sizes, or a monitor layout that no
// longer contains the saved rectangle at all (the display was unplugged or the
// arrangement changed). Otherwise the rectangle is clamped into the work area it
// overlaps most, so a window saved on a monitor that shrank, or on a display
// running a different scale, cannot come back off-screen or larger than the
// space available.
std::optional<Bounds> ChooseRestoreBounds(const Bounds& saved,
                                          const std::vector<WorkArea>& work_areas,
                                          int min_width,
                                          int min_height);

// HKCU\Software\Syb-L\Window. Window placement is ordinary per-user UI state,
// not a secret, so it deliberately does not go through the DPAPI-sealed
// LocalAppData stores used for the archive secret and remote-control grants.
std::optional<Bounds> LoadBounds();
bool SaveBounds(const Bounds& bounds);

}  // namespace sybl::window
