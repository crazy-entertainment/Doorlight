#include "annotation_ingress.h"

#include <cassert>

int main() {
  sybl::AnnotationIngress stalled;
  for (int i = 0; i < 128; ++i) assert(stalled.Admit(100, 0));
  assert(!stalled.Admit(100, 100000));
  for (int i = 0; i < 128; ++i) stalled.Delivered(100);
  assert(stalled.Admit(100, 100000));

  sybl::AnnotationIngress flood;
  for (int i = 0; i < 128; ++i) {
    assert(flood.Admit(100, 0));
    flood.Delivered(100);
  }
  assert(!flood.Admit(100, 0));
  assert(flood.Admit(100, 1000));
  assert(!flood.Admit(65537, 1000));

  sybl::AnnotationIngress bytes;
  for (int i = 0; i < 16; ++i) assert(bytes.Admit(65536, 0));
  assert(!bytes.Admit(1, 1000));
  for (int i = 0; i < 16; ++i) bytes.Delivered(65536);
  assert(bytes.Admit(6000, 1000));
}
