/* Copyright (C) 2026 Doorlight contributors
 * SPDX-License-Identifier: GPL-3.0-or-later */
#pragma once
#include <dhtnet/channel_socket.h>
#include <msgpack.hpp>
#include <cstring>
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <string_view>

namespace jami::pairing {
inline constexpr size_t maxArchiveBytes = 16 * 1024 * 1024;
inline constexpr size_t maxWireBytes = maxArchiveBytes + 64 * 1024;
struct Message {
    uint8_t schemeId {1};
    std::map<std::string, std::string> payload;
    MSGPACK_DEFINE_MAP(schemeId, payload)

    bool only(std::initializer_list<std::string_view> fields) const
    {
        if (payload.size() != fields.size()) return false;
        for (auto field : fields) if (!payload.count(std::string(field))) return false;
        return true;
    }
    const std::string& at(std::string_view key) const { return payload.at(std::string(key)); }

    bool send(const std::shared_ptr<dhtnet::ChannelSocket>& channel) const
    {
        if (!channel) return false;
        try {
            msgpack::sbuffer buffer;
            msgpack::pack(buffer, *this);
            if (buffer.size() > maxWireBytes) return false;
            std::error_code error;
            auto written = channel->write(reinterpret_cast<const uint8_t*>(buffer.data()), buffer.size(), error);
            return !error && written == buffer.size();
        } catch (...) { return false; }
    }

    static dhtnet::ChannelSocket::RecvCb reader(std::function<bool(Message&&)> callback)
    {
        // Decoder limits apply before object conversion. The separate total
        // byte/message budget bounds fragmented and concatenated input buffers.
        auto unpacker = std::make_shared<msgpack::unpacker>(nullptr, nullptr, 512,
            msgpack::unpack_limit(0, 8, maxArchiveBytes, 0, 0, 4));
        return [unpacker, callback = std::move(callback), bytes = size_t(0), messages = unsigned(0), failed = false]
               (const uint8_t* data, size_t size) mutable -> ssize_t {
            auto reject = [&]() -> ssize_t { failed = true; return static_cast<ssize_t>(-1); };
            if (failed || size > maxWireBytes - bytes) return reject();
            bytes += size;
            try {
                unpacker->reserve_buffer(size);
                std::memcpy(unpacker->buffer(), data, size);
                unpacker->buffer_consumed(size);
                msgpack::object_handle object;
                while (unpacker->next(object)) {
                    if (++messages > 12) return reject();
                    const auto& root = object.get();
                    if (root.type != msgpack::type::MAP || root.via.map.size != 2) return reject();
                    Message message;
                    bool version = false, fields = false;
                    for (uint32_t i = 0; i < root.via.map.size; ++i) {
                        const auto& entry = root.via.map.ptr[i];
                        if (entry.key.type != msgpack::type::STR) return reject();
                        const std::string key = entry.key.as<std::string>();
                        if (key == "schemeId" && !version) {
                            if (entry.val.type != msgpack::type::POSITIVE_INTEGER || entry.val.via.u64 > 255) return reject();
                            message.schemeId = static_cast<uint8_t>(entry.val.via.u64);
                            version = true;
                        } else if (key == "payload" && !fields) {
                            if (entry.val.type != msgpack::type::MAP || entry.val.via.map.size > 6) return reject();
                            for (uint32_t j = 0; j < entry.val.via.map.size; ++j) {
                                const auto& field = entry.val.via.map.ptr[j];
                                if (field.key.type != msgpack::type::STR || field.val.type != msgpack::type::STR ||
                                    field.key.via.str.size > 32) return reject();
                                auto name = field.key.as<std::string>();
                                if (field.val.via.str.size > (name == "accData" ? maxArchiveBytes : 32768)) return reject();
                                if (!message.payload.emplace(name, field.val.as<std::string>()).second) return reject();
                            }
                            fields = true;
                        } else return reject();
                    }
                    if (!version || !fields || !callback(std::move(message))) return reject();
                }
                return static_cast<ssize_t>(size);
            } catch (...) { return reject(); }
        };
    }
};

} // namespace jami::pairing
