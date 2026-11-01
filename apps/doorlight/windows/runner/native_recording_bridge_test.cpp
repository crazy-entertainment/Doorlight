#ifdef NDEBUG
#undef NDEBUG
#endif
#include "../../third_party/record_windows/windows/sybl_recording_bridge.h"
#include <atomic>
#include <cassert>

namespace {
std::atomic<uint64_t> owner{1};
std::atomic<int> retired{0};
bool Current(uint64_t value) { return owner.load() == value; }
void Released(uint64_t) { ++retired; }
}

int main() {
  using namespace record_windows;
  auto& bridge = SybLRecordingBridge::Get();
  bridge.Configure(Current, Released);
  bridge.SetForeground(true);
  RecordConfig config(AudioEncoder::aacLc, "", 96000, 48000, 1, false, false, false, {});
  NativeRecordingLease::Completion complete;
  assert(!bridge.Begin("one", config, L"owned/voice.m4a", [](auto) {}));
  assert(bridge.Offer(1, L"owned/voice.m4a"));
  assert(!bridge.Begin("one", config, L"other/voice.m4a", [](auto) {}));
  auto first = bridge.Begin("one", config, L"owned/voice.m4a", [&](auto done) { complete = std::move(done); });
  assert(first && bridge.Current(first));
  assert(!bridge.Renew(L"other/voice.m4a"));
  assert(bridge.Renew(L"owned/voice.m4a"));
  bridge.SetForeground(false);
  assert(complete && !bridge.Current(first));
  assert(!bridge.RevokeAndWait(0));
  complete(true);
  assert(bridge.RevokeAndWait(1000));
  assert(retired.load() == 1);

  bridge.SetForeground(true);
  assert(bridge.Offer(1, L"owned/second.m4a"));
  auto second = bridge.Begin("two", config, L"owned/second.m4a", [](auto done) { done(true); });
  assert(second);
  bridge.Released(first, true);
  assert(bridge.Current(second));
  owner.store(2);
  for (int i = 0; i < 200 && retired.load() != 2; ++i) Sleep(10);
  assert(retired.load() == 2 && !bridge.Current(second));
  bridge.SetForeground(false);
  bridge.Configure(nullptr, nullptr);
  return 0;
}
