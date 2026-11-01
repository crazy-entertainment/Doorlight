#ifdef NDEBUG
#undef NDEBUG
#endif

#include "annotation_overlay.h"

#include <cassert>
#include <cmath>
#include <limits>

int main() {
  using sybl::annotation::IsValid;
  using sybl::annotation::Point;
  using sybl::annotation::ProjectPoint;
  using sybl::annotation::Snapshot;
  using sybl::annotation::Stroke;
  using sybl::annotation::Surface;

  const Surface surface{-1920, 0, 1920, 1080};
  Snapshot valid{"call-a", 7, {{0xfff08a6c, 3.5, {{0, 0}, {1, 1}}}}};
  assert(IsValid(valid, surface));
  assert(ProjectPoint({0, 0}, surface) == std::make_pair(0, 0));
  assert(ProjectPoint({1, 1}, surface) == std::make_pair(1919, 1079));
  assert(ProjectPoint({0.5, 0.5}, surface) == std::make_pair(960, 540));

  Snapshot invalid = valid;
  invalid.call_id.clear();
  assert(!IsValid(invalid, surface));
  invalid = valid;
  invalid.source_revision = 0;
  assert(!IsValid(invalid, surface));
  invalid = valid;
  invalid.strokes[0].width = std::numeric_limits<double>::quiet_NaN();
  assert(!IsValid(invalid, surface));
  invalid = valid;
  invalid.strokes[0].points[0].x = 1.01;
  assert(!IsValid(invalid, surface));
  invalid = valid;
  invalid.strokes[0].points.clear();
  assert(!IsValid(invalid, surface));

  Snapshot too_many{"call-a", 7, {}};
  too_many.strokes.resize(sybl::annotation::kMaxStrokes + 1,
                          Stroke{0xffffffff, 1, {{0.5, 0.5}}});
  assert(!IsValid(too_many, surface));

  return 0;
}
