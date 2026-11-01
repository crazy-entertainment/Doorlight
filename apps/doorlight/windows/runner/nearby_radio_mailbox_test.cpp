#include "nearby_radio_mailbox.h"
#include <cassert>

int main() {
  using namespace sybl::nearby_radio;
  Mailbox mailbox;
  const auto now = Clock::now();
  Bytes out;
  assert(!mailbox.Put(Bytes{1}, false, now));
  assert(!mailbox.Put(Bytes(509, 1), true, now));
  assert(mailbox.Put(Bytes{10, 20, 30, 40}, true, now));
  assert(mailbox.Read(L"a", true, 0, 5, now, out) == 0);
  assert((out == Bytes{0, 0, 0, 1, 10}));
  assert(mailbox.Put(Bytes{50, 60, 70, 80}, true, now));
  assert(mailbox.Read(L"a", true, 5, 20, now, out) == 0);
  assert((out == Bytes{20, 30, 40}));
  assert(mailbox.Read(L"a", true, 9, 20, now, out) == 0x07);
  assert(mailbox.Read(L"b", true, 1, 20, now, out) == 0x07);
  for (const auto* id : {L"b", L"c", L"d"}) {
    assert(mailbox.Read(id, true, 0, 512, now, out) == 0);
  }
  assert(mailbox.Read(L"e", true, 0, 512, now, out) == 0x11);
  assert(mailbox.Read(L"e", true, 0, 512, now + std::chrono::seconds(4), out) == 0);
  assert(mailbox.Put(Bytes{77}, false, now));
  assert(mailbox.Read(L"e", false, 0, 512, now, out) == 0 && out.size() == 5);
  assert(mailbox.Put(Bytes{88}, false, now + std::chrono::seconds(3)));
  assert(mailbox.Read(L"e", false, 1, 512, now + std::chrono::seconds(3), out) == 0);
  assert(mailbox.Read(L"e", false, 1, 512, now + std::chrono::seconds(4), out) == 0x07);
  assert(mailbox.Put(Bytes{77}, false, now));
  assert(mailbox.Read(L"e", false, 0, 512, now + std::chrono::seconds(4), out) == 0 && out.empty());
  assert(mailbox.Read(L"e", false, 1, 512, now + std::chrono::seconds(4), out) == 0x07);
  mailbox.Hide();
  assert(mailbox.Read(L"e", true, 0, 512, now, out) == 0x02);

  // Routine presence must not overwrite a deliberate wave before discovery.
  Mailbox waves;
  assert(waves.Put(Bytes(60, 7), true, now, true));
  assert(waves.Put(Bytes{8}, true, now + std::chrono::seconds(1)));
  assert(waves.Read(L"a", true, 0, 22, now, out) == 0 && out.back() == 7);
  assert(waves.Read(L"a", true, 0, 22, now, out) == 0 && out.back() == 7);
  assert(waves.Read(L"a", true, 22, 512, now, out) == 0 && out.back() == 7);
  // A rejected platform response must leave the wave available for retry.
  assert(waves.Read(L"a", true, 0, 512, now, out) == 0 && out.back() == 7);
  waves.Served(L"a", now);
  assert(waves.Read(L"a", true, 0, 512, now, out) == 0 && out.back() == 8);
  assert(waves.Read(L"b", true, 0, 22, now, out) == 0 && out.back() == 7);
  // A new ping cannot replace an in-flight snapshot or be consumed by it.
  assert(waves.Put(Bytes{9}, true, now, true));
  assert(waves.Read(L"b", true, 22, 512, now, out) == 0 && out.back() == 7);
  assert(waves.Read(L"b", true, 0, 512, now, out) == 0 && out.back() == 9);
  assert(waves.Put(Bytes{77}, false, now));
  assert(waves.Read(L"a", false, 0, 512, now, out) == 0 && out.back() == 77);
  assert(waves.Read(L"a", true, 0, 512, now, out) == 0 && out.back() == 9);
  assert(waves.Read(L"late", true, 0, 512, now + std::chrono::seconds(30), out) == 0 && out.back() == 8);
  waves.Hide();
  assert(waves.Put(Bytes{10}, true, now));
  assert(waves.Read(L"a", true, 0, 512, now, out) == 0 && out.back() == 10);

  Mailbox expires;
  assert(expires.Put(Bytes(60, 7), true, now, true));
  assert(expires.Read(L"a", true, 0, 22, now + std::chrono::seconds(29), out) == 0);
  assert(expires.Read(L"a", true, 22, 512, now + std::chrono::seconds(30), out) == 0x07);
  assert(expires.Read(L"a", true, 0, 512, now + std::chrono::seconds(30), out) == 0 && out.empty());
}
