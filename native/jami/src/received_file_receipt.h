// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include "verified_received_seed.h"
#include <charconv>
#include <vector>

namespace jami::received_seed {

struct Receipt {
    std::string account, conversation, commit, file, attempt, hash, identity;
    uint64_t size = 0;
};

inline bool hex(const std::string& text, size_t minimum, size_t maximum) {
    if (text.size() < minimum || text.size() > maximum) return false;
    for (const auto c : text)
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
    return true;
}

inline bool leaf(const std::string& text) {
    if (text.empty() || text.size() > 255 || text == "." || text == "..") return false;
    for (const auto c : text)
        if (static_cast<unsigned char>(c) < 32 || c == 127 || c == '/' || c == '\\' || c == ':')
            return false;
    return true;
}

inline bool valid(const Receipt& value) {
    if (!hex(value.account, 1, 128) || !hex(value.conversation, 40, 40) ||
        !hex(value.commit, 40, 40) || !leaf(value.file) ||
        value.file.compare(0, value.commit.size() + 1, value.commit + "_") != 0 ||
        !hex(value.attempt, 32, 32) || !hex(value.hash, 128, 128) ||
        value.size > 2ULL * 1024 * 1024 * 1024 || value.identity.empty() ||
        value.identity.size() > 80) return false;
    for (const auto c : value.identity)
        if ((c < '0' || c > '9') && c != ':') return false;
    return true;
}

inline std::string encode(const Receipt& value) {
    if (!valid(value)) return {};
    std::string result = "SYBLRF1\n";
    for (const auto& field : {value.account, value.conversation, value.commit,
            value.file, value.attempt, value.hash, std::to_string(value.size), value.identity})
        result += std::to_string(field.size()) + ":" + field;
    return result;
}

inline bool decode(const std::string& data, Receipt& result) {
    if (data.size() > 2048 || data.compare(0, 8, "SYBLRF1\n") != 0) return false;
    std::vector<std::string> fields;
    size_t cursor = 8;
    for (unsigned index = 0; index < 8; ++index) {
        const auto colon = data.find(':', cursor);
        if (colon == std::string::npos || colon == cursor || colon - cursor > 4) return false;
        size_t length = 0;
        const auto parsed = std::from_chars(data.data() + cursor, data.data() + colon, length);
        if (parsed.ec != std::errc{} || parsed.ptr != data.data() + colon ||
            length > data.size() - colon - 1) return false;
        fields.push_back(data.substr(colon + 1, length));
        cursor = colon + 1 + length;
    }
    if (cursor != data.size()) return false;
    Receipt value;
    value.account = fields[0]; value.conversation = fields[1]; value.commit = fields[2];
    value.file = fields[3]; value.attempt = fields[4]; value.hash = fields[5];
    value.identity = fields[7];
    const auto parsed = std::from_chars(fields[6].data(), fields[6].data() + fields[6].size(), value.size);
    if (fields[6].empty() || parsed.ec != std::errc{} ||
        parsed.ptr != fields[6].data() + fields[6].size() || !valid(value)) return false;
    result = std::move(value);
    return true;
}

inline bool loadReceipt(const std::filesystem::path& path, Receipt& result) {
    File input(path, false);
    if (!input.valid() || input.size() > 2048) return false;
    std::array<unsigned char, 2049> bytes {};
    unsigned count = 0;
    while (count < bytes.size()) {
        const int read = input.read(bytes.data() + count, unsigned(bytes.size() - count));
        if (read < 0) return false;
        if (!read) break;
        count += unsigned(read);
    }
    if (count != input.size() || count > 2048) return false;
    return decode(std::string(reinterpret_cast<const char*>(bytes.data()), count), result);
}

// A receipt stores only an owned relative seed name, never an arbitrary path.
// Replacement of an identically sized file is rejected before its bytes are read.
template<class Digest>
bool verifyReceipt(const std::filesystem::path& root, const Receipt& receipt,
                   const std::string& account, const std::string& conversation,
                   const std::string& file) {
    if (!valid(receipt) || receipt.account != account || receipt.conversation != conversation ||
        receipt.file != file) return false;
    File seed(root / receipt.file, false);
    return seed.identity() == receipt.identity &&
        readVerified<Digest>(seed, receipt.size, receipt.hash);
}

inline bool saveReceipt(const std::filesystem::path& destination,
                        const std::filesystem::path& temporary, const Receipt& receipt) {
    const auto data = encode(receipt);
    if (data.empty() || destination == temporary ||
        destination.parent_path() != temporary.parent_path()) return false;
    File output(temporary, true);
    if (!output.valid()) return false;
    const bool written = output.write(reinterpret_cast<const unsigned char*>(data.data()),
                                      unsigned(data.size())) && output.flush();
    const bool published = written && output.publishTo(destination, true);
    if (!published) output.removeOwned();
    output.close();
    return published;
}
} // namespace jami::received_seed
