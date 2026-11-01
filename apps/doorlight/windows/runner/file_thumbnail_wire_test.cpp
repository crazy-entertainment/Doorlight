#undef NDEBUG

#include "file_thumbnail_wire.h"

#include <cassert>
#include <limits>
#include <string>

int main() {
  using namespace sybl::file_thumbnail_wire;

  constexpr std::int64_t now = 80'000;
  const Packet packet{"conversation", "file-id", now, "AQID"};
  const auto encoded = Encode(packet, now);
  assert(encoded);
  assert(*encoded == "SYBLTHUMB1\nconversation\nfile-id\n80000\nAQID");
  const auto decoded = Decode(*encoded, now);
  assert(decoded && decoded->conversation_id == packet.conversation_id &&
         decoded->file_id == packet.file_id &&
         decoded->timestamp_ms == packet.timestamp_ms &&
         decoded->png_base64 == packet.png_base64);

  assert(Decode(*encoded, now + kMaxAgeMs));
  assert(!Decode(*encoded, now + kMaxAgeMs + 1));
  assert(Encode(Packet{"c", "f", now + kMaxAgeMs, "AQ=="}, now));
  assert(!Encode(Packet{"c", "f", now + kMaxAgeMs + 1, "AQ=="}, now));
  assert(!Decode("SYBLTHUMB1\nc\nf\n9223372036854775808\nAQ==", now));

  assert(!Encode(Packet{"bad\nconversation", "f", now, "AQ=="}, now));
  assert(!Encode(Packet{"c", "bad\"file", now, "AQ=="}, now));
  assert(!Encode(Packet{"c", "bad\\file", now, "AQ=="}, now));
  assert(!Encode(Packet{"c", std::string("bad\x7f", 4), now, "AQ=="}, now));
  assert(!Encode(Packet{std::string(kMaxIdUtf8Bytes + 1, 'c'), "f", now,
                        "AQ=="},
                 now));
  assert(!Encode(Packet{std::string{"\xed\xa0\x80"}, "f", now, "AQ=="},
                 now));

  assert(Encode(Packet{"c", "f", now, "AQ=="}, now));
  assert(Encode(Packet{"c", "f", now, "AQI="}, now));
  assert(!Encode(Packet{"c", "f", now, "AQI"}, now));
  assert(!Encode(Packet{"c", "f", now, "AQ_I"}, now));
  assert(!Encode(Packet{"c", "f", now, "A=AA"}, now));
  assert(!Encode(Packet{"c", "f", now, ""}, now));
  assert(Encode(Packet{"c", "f", now,
                       std::string(kMaxBase64Chars, 'A')},
                now));
  assert(!Encode(Packet{"c", "f", now,
                        std::string(kMaxBase64Chars + 4, 'A')},
                 now));

  const Packet maximum{std::string(kMaxIdUtf8Bytes, 'c'),
                       std::string(kMaxIdUtf8Bytes, 'f'), now,
                       std::string(kMaxBase64Chars, 'A')};
  const auto maximum_encoded = Encode(maximum, now);
  assert(maximum_encoded && maximum_encoded->size() <= kMaxBodyBytes);
  assert(!Decode("SYBLTHUMB0\nc\nf\n80000\nAQID", now));
  assert(!Decode("SYBLTHUMB1\nc\nf\n80000\nAQID\n", now));
  assert(!Decode(std::string(kMaxBodyBytes + 1, 'x'), now));

  const DecisionPacket decision{"conversation", "file-id"};
  const auto declined = EncodeDeclined(decision);
  assert(declined && *declined == "SYBLDECLINED1\nconversation\nfile-id");
  const auto decoded_decision = DecodeDeclined(*declined);
  assert(decoded_decision &&
         decoded_decision->conversation_id == decision.conversation_id &&
         decoded_decision->file_id == decision.file_id);
  assert(!DecodeDeclined("SYBLDECLINED1\nconversation\nbad\nfile"));
  assert(!EncodeDeclined({"bad\nconversation", "file"}));
  const auto max_declined = EncodeDeclined({std::string(kMaxIdUtf8Bytes, 'c'), std::string(kMaxIdUtf8Bytes, 'f')});
  assert(max_declined && max_declined->size() == kMaxDeclinedBodyBytes);
  assert(DecodeDeclined(*max_declined));
  assert(!DecodeDeclined(*max_declined + "x"));
  assert(!DecodeDeclined("SYBLDECLINED1\n" + std::string(kMaxIdUtf8Bytes + 1, 'c') + "\nf"));
  assert(!DecodeDeclined(std::string(kMaxDeclinedBodyBytes + 1, '\n')));

  return 0;
}
