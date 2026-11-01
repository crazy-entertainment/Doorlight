/* Copyright (C) 2026 Doorlight contributors
 * SPDX-License-Identifier: GPL-3.0-or-later */
#pragma once
#include <gnutls/crypto.h>
#include <array>
#include <stdexcept>
#include <string>
#include <string_view>

namespace jami::pairing {
// This commitment supplements the existing confidential, certificate-bound
// Jami channel; it is not a password exchange for an unauthenticated transport.
// The source commits BEFORE receiving the entered code. Its 256-bit random
// opening stays secret until the source checks that code. Publishing the opening
// with the commitment would expose an offline oracle for the eight-digit code.
// The destination freezes the commitment for all attempts and verifies its
// opening BEFORE parsing/importing any archive. This also prevents a substituted
// source from learning the entered code and then claiming it had chosen it.
inline std::string freshOpening()
{
    std::string opening(32, '\0');
    if (gnutls_rnd(GNUTLS_RND_RANDOM, opening.data(), opening.size()) != 0)
        throw std::runtime_error("Pairing randomness unavailable");
    return opening;
}

inline std::string codeCommitment(std::string_view code, std::string_view opening,
                                  std::string_view sourceDevice,
                                  std::string_view temporaryDevice, uint32_t operation)
{
    if (code.size() != 8 || opening.size() != 32 || sourceDevice.size() != 64 ||
        temporaryDevice.size() != 64)
        throw std::runtime_error("Invalid pairing commitment input");
    // Fixed-width IDs/code/opening and delimited decimal operation are
    // unambiguous. The distinct prefix binds this credential-separated version.
    std::string transcript = "doorlight-code-commitment-v1:";
    transcript.append(sourceDevice).append(":").append(temporaryDevice).append(":")
        .append(std::to_string(operation)).append(":").append(code).append(":").append(opening);
    std::array<unsigned char, 32> digest;
    if (gnutls_hash_fast(GNUTLS_DIG_SHA256, transcript.data(), transcript.size(), digest.data()) != 0)
        throw std::runtime_error("Pairing commitment unavailable");
    constexpr char hex[] = "0123456789abcdef";
    std::string result;
    for (auto byte : digest) { result += hex[byte >> 4]; result += hex[byte & 15]; }
    return result;
}

inline bool verifyOpening(std::string_view commitment, std::string_view code,
                           std::string_view opening, std::string_view sourceDevice,
                           std::string_view temporaryDevice, uint32_t operation)
{
    if (commitment.size() != 64 || opening.size() != 32) return false;
    const auto expected = codeCommitment(code, opening, sourceDevice, temporaryDevice, operation);
    unsigned difference = 0;
    for (size_t i = 0; i < expected.size(); ++i)
        difference |= static_cast<unsigned>(expected[i] ^ commitment[i]);
    return difference == 0;
}
} // namespace jami::pairing
