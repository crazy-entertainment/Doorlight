/* Copyright (C) 2026 Doorlight contributors
 * SPDX-License-Identifier: GPL-3.0-or-later */
#include "jamidht/device_pairing_wire.h"
#include "jamidht/device_pairing_commitment.h"
#include <iostream>
#include <stdexcept>

using jami::pairing::Message;
static void requireAt(bool condition, int line) {
    if (!condition) throw std::runtime_error("Pairing wire assertion failed at line " + std::to_string(line));
}
#define require(condition) requireAt((condition), __LINE__)
static ssize_t feed(dhtnet::ChannelSocket::RecvCb& reader, const msgpack::sbuffer& packet)
{
    return reader(reinterpret_cast<const uint8_t*>(packet.data()), packet.size());
}
int main()
{
    try {
        // The opening is withheld until the source checks a code. These tests
        // also cover a substituted source's inability to open a frozen
        // commitment for a different code or certificate-bound operation.
        const std::string source(64, 'a'), destination(64, 'b');
        const std::string opening(32, 'x');
        auto commitment = jami::pairing::codeCommitment("12345678", opening, source, destination, 123456);
        // Independently reproduced with Python hashlib.sha256.
        require(commitment == "3bbd7560454ddb9f2137a97d07c47e7e8af187c69981c5b73733fc694d60c532");
        require(jami::pairing::verifyOpening(commitment, "12345678", opening, source, destination, 123456));
        require(!jami::pairing::verifyOpening(commitment, "12345679", opening, source, destination, 123456));
        require(!jami::pairing::verifyOpening(commitment, "12345678", std::string(32, 'y'), source, destination, 123456));
        require(!jami::pairing::verifyOpening(commitment, "12345678", opening, destination, source, 123456));
        require(!jami::pairing::verifyOpening(commitment, "12345678", opening, source, destination, 123457));
        require(!jami::pairing::verifyOpening(commitment, "12345678", opening.substr(1), source, destination, 123456));
        require(jami::pairing::freshOpening() != jami::pairing::freshOpening());
        Message challenge;
        challenge.payload["code"] = "12345678";
        msgpack::sbuffer packet;
        msgpack::pack(packet, challenge);
        unsigned calls = 0;
        auto fragmented = Message::reader([&](Message&& message) {
            ++calls;
            require(message.schemeId == 1 && message.only({"code"}) && message.at("code") == "12345678");
            return true;
        });
        for (size_t i = 0; i < packet.size(); ++i)
            require(fragmented(reinterpret_cast<const uint8_t*>(packet.data() + i), 1) == 1);
        require(calls == 1);

        // A map must not silently collapse repeated authentication fields.
        msgpack::sbuffer duplicate;
        msgpack::packer<msgpack::sbuffer> pack(duplicate);
        pack.pack_map(2); pack.pack("schemeId"); pack.pack(1); pack.pack("payload");
        pack.pack_map(2); pack.pack("code"); pack.pack("12345678"); pack.pack("code"); pack.pack("87654321");
        unsigned malformedCalls = 0;
        auto malformed = Message::reader([&](Message&&) { ++malformedCalls; return true; });
        require(feed(malformed, duplicate) < 0);
        require(malformedCalls == 0);
        require(feed(malformed, packet) < 0); // terminal failure cannot resume

        // An incomplete string does not dispatch. Once its body arrives, the
        // object-size limit rejects it before the application sees the value.
        msgpack::sbuffer oversized;
        msgpack::packer<msgpack::sbuffer> huge(oversized);
        huge.pack_map(2); huge.pack("schemeId"); huge.pack(1); huge.pack("payload");
        huge.pack_map(1); huge.pack("accData"); huge.pack_str(jami::pairing::maxArchiveBytes + 1);
        unsigned oversizedCalls = 0;
        auto bounded = Message::reader([&](Message&&) { ++oversizedCalls; return true; });
        require(feed(bounded, oversized) == static_cast<ssize_t>(oversized.size()));
        require(oversizedCalls == 0);
        const std::vector<uint8_t> body(jami::pairing::maxArchiveBytes + 1, 'x');
        require(bounded(body.data(), body.size()) < 0);
        require(oversizedCalls == 0);
        auto totalBound = Message::reader([](Message&&) { return true; });
        const uint8_t dummy = 0;
        require(totalBound(&dummy, jami::pairing::maxWireBytes + 1) < 0);

        // Peer arrays and nesting are not part of this protocol.
        msgpack::sbuffer nested;
        msgpack::packer<msgpack::sbuffer> arrays(nested);
        arrays.pack_array(1); arrays.pack_array(1); arrays.pack_array(1); arrays.pack_nil();
        auto depth = Message::reader([](Message&&) { return true; });
        require(feed(depth, nested) < 0);

        auto burst = Message::reader([](Message&&) { return true; });
        for (unsigned i = 0; i < 12; ++i) require(feed(burst, packet) == static_cast<ssize_t>(packet.size()));
        require(feed(burst, packet) < 0);
        auto refused = Message::reader([](Message&&) { return false; });
        require(feed(refused, packet) < 0);
        require(feed(refused, packet) < 0);
        std::cout << "Pairing wire: fragmentation, duplicates, allocation bounds, nesting and terminal refusal passed\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
