#ifdef NDEBUG
#undef NDEBUG
#endif

#include "presence_wire.h"
#include "identity_color_wire.h"

#include <cassert>
#include <string>

int main() {
  using sybl::presence_wire::Decode;
  const auto encoded = sybl::presence_wire::Encode("ping", true, 42, "Editor", "sage");
  const auto packet = Decode(encoded, 42);
  assert(packet && packet->version == 3 && packet->type == "ping");
  assert(packet->foreground == 1 && packet->timestamp_ms == 42);
  assert(packet->platform == "windows" && packet->activity == "Editor");
  assert(packet->color == "sage");
  assert(packet->wake.empty());
  assert(sybl::identity_color_wire::Argb("sage") == 0xff8fbe83u);

  static_assert(sybl::identity_color_wire::kValues.size() == 24);
  for (const auto& color : sybl::identity_color_wire::kValues) {
    const auto body = sybl::presence_wire::Encode(
        "ping", false, 42, "", std::string(color.key));
    const auto round_trip = Decode(body, 42);
    assert(round_trip && round_trip->color == color.key);
    assert(sybl::identity_color_wire::Argb(color.key) == color.argb);
  }
  assert(sybl::identity_color_wire::Argb("blue") == 0xff6386e5u);

  const auto legacy = Decode("1", 42);
  assert(legacy && legacy->version == 0 && legacy->foreground == -1);
  assert(Decode(R"({"t":"pong","fg":0,"ts":7,"platform":"android","activity":""})", 7));

  assert(!Decode(R"({"v":2,"t":"ping","fg":1,"ts":1,"platform":"windows","activity":""})", 1));
  assert(!Decode(R"({"v":2,"t":"ping","fg":1,"ts":1,"platform":"windows","activity":"","color":"ultraviolet"})", 1));
  assert(!Decode(R"({"v":1,"t":"ping","fg":1,"ts":1,"platform":"windows","activity":"","color":"sage"})", 1));
  assert(!Decode(R"({"v":1,"t":"ping","fg":-1,"ts":1,"platform":"windows","activity":""})", 1));
  assert(!Decode(R"({"v":1,"t":"ping","fg":1.0,"ts":1,"platform":"windows","activity":""})", 1));
  assert(!Decode(R"({"v":1.0,"t":"ping","fg":1,"ts":1,"platform":"windows","activity":""})", 1));
  assert(!Decode(R"({"v":1,"t":"ping","fg":1,"ts":1.0,"platform":"windows","activity":""})", 1));
  assert(!Decode(R"({"v":1e0,"t":"ping","fg":1,"ts":1,"platform":"windows","activity":""})", 1));
  assert(!Decode(R"({"v":1,"t":"ping","fg":1e0,"ts":1,"platform":"windows","activity":""})", 1));
  assert(!Decode(R"({"v":1,"t":"ping","fg":1,"ts":1e0,"platform":"windows","activity":""})", 1));
  assert(!Decode(R"({"v":1,"t":"ping","fg":1,"ts":0,"platform":"windows","activity":""})", 1));
  assert(!Decode(R"({"v":1,"v":1,"t":"ping","fg":1,"ts":1,"platform":"windows","activity":""})", 1));
  assert(!Decode(R"({"v":1,"\u0076":1,"t":"ping","fg":1,"ts":1,"platform":"windows","activity":""})", 1));
  assert(!Decode(R"({'v':1,'t':'ping','fg':1,'ts':1,'platform':'windows','activity':''})", 1));
  assert(!Decode(R"({"v":1,"t":"ping","fg":1,"ts":1,"platform":"windows","activity":"",})", 1));
  assert(!Decode(R"({"v":1,"t":"ping","fg":1,"ts":1,"platform":"windows","activity":"","extra":1})", 1));
  assert(!Decode(R"({"v":1,"t":"ping","fg":1,"ts":1,"platform":"windows","activity":"\tEditor\t"})", 1));
  assert(!Decode(std::string(sybl::presence_wire::kMaxBodyBytes + 1, 'x'), 1));
  const auto fresh = std::string(R"({"v":1,"t":"pong","fg":1,"ts":100000,"platform":"windows","activity":""})");
  assert(Decode(fresh, 100000));
  assert(!Decode(fresh, 100000 + sybl::presence_wire::kMaxClockDeltaMs + 1));
  assert(!Decode(fresh, 100000 - sybl::presence_wire::kMaxClockDeltaMs - 1));
  const std::string handle(43, 'A');
  const auto wake = sybl::presence_wire::Encode(
      "wake", false, 200, "", "amber", handle);
  const auto wake_packet = Decode(wake, 200);
  assert(wake_packet && wake_packet->type == "wake" && wake_packet->wake == handle);
  auto bad_wake = wake;
  bad_wake.replace(bad_wake.find(handle), handle.size(), "bad");
  assert(!Decode(bad_wake, 200));
  return 0;
}
