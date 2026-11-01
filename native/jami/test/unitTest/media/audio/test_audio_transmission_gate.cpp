/*
 *  Copyright (C) 2004-2026 Savoir-faire Linux Inc.
 *
 *  This program is free software: you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation, either version 3 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

#include "media/audio/audio_transmission_gate.h"

#include <chrono>
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <string_view>

namespace {

void
require(bool condition, std::string_view message)
{
    if (!condition)
        throw std::runtime_error(std::string(message));
}

void
testOpenIsUnconditional()
{
    jami::AudioTransmissionGate gate;
    const auto silence = gate.observe(jami::AudioTransmissionMode::OPEN,
                                      false,
                                      std::chrono::milliseconds(20));
    require(silence.transmitCurrent, "open mode dropped silence");
    require(!silence.bufferCurrent, "open mode buffered a frame");
    require(silence.releaseBuffered == 0, "open mode released unexpected pre-roll");

    const auto speech = gate.observe(jami::AudioTransmissionMode::OPEN,
                                     true,
                                     std::chrono::milliseconds(20));
    require(speech.transmitCurrent, "open mode dropped speech");
    require(gate.transmitting(), "open mode did not report transmission");
}

void
testVoiceActivatedUsesBoundedPreRoll()
{
    jami::AudioTransmissionGate gate;
    for (int i = 0; i < 16; ++i) {
        const auto decision = gate.observe(jami::AudioTransmissionMode::VOICE_ACTIVATED,
                                           false,
                                           std::chrono::milliseconds(20));
        require(decision.bufferCurrent, "voice mode did not retain pre-roll");
        require(!decision.transmitCurrent, "voice mode transmitted without stabilized voice");
        require(decision.releaseBuffered == 0, "voice mode released pre-roll before voice");
    }

    require(gate.bufferedFrames() == 15, "pre-roll did not enforce its 300 ms bound");
    require(gate.bufferedDuration().count() == 300'000, "pre-roll duration is not 300 ms");

    const auto speech = gate.observe(jami::AudioTransmissionMode::VOICE_ACTIVATED,
                                     true,
                                     std::chrono::milliseconds(20));
    require(speech.releaseBuffered == 15, "speech did not release the complete bounded pre-roll");
    require(speech.transmitCurrent, "speech frame was not transmitted");
    require(!speech.bufferCurrent, "speech frame was incorrectly retained");
    require(gate.bufferedFrames() == 0, "released pre-roll remained buffered");
    require(gate.transmitting(), "voice mode did not report active transmission");
}

void
testModeSwitchAndReset()
{
    jami::AudioTransmissionGate gate;
    for (int i = 0; i < 3; ++i)
        gate.observe(jami::AudioTransmissionMode::VOICE_ACTIVATED,
                     false,
                     std::chrono::milliseconds(20));

    const auto open = gate.observe(jami::AudioTransmissionMode::OPEN,
                                   false,
                                   std::chrono::milliseconds(20));
    require(open.discardBuffered == 3, "switching to open did not discard stale pre-roll");
    require(open.transmitCurrent, "switching to open did not transmit immediately");
    require(gate.bufferedFrames() == 0, "switching to open left buffered frames");

    gate.observe(jami::AudioTransmissionMode::VOICE_ACTIVATED,
                 false,
                 std::chrono::milliseconds(20));
    require(gate.reset() == 1, "reset did not report its discarded frame");
    require(gate.mode() == jami::AudioTransmissionMode::OPEN, "reset did not restore open mode");
    require(gate.transmitting(), "reset did not restore transmission");
}

void
testTrustsProcessorHangover()
{
    jami::AudioTransmissionGate gate;
    gate.observe(jami::AudioTransmissionMode::VOICE_ACTIVATED,
                 true,
                 std::chrono::milliseconds(20));

    // The upstream WebRTC/Speex processor already applies its own hangover.
    // Once its stabilized flag becomes false, this gate must close instead of
    // inventing a second, harder-to-reason-about timer.
    const auto silence = gate.observe(jami::AudioTransmissionMode::VOICE_ACTIVATED,
                                      false,
                                      std::chrono::milliseconds(20));
    require(!silence.transmitCurrent, "gate added a second hangover");
    require(silence.bufferCurrent, "first post-speech frame was not retained as pre-roll");
    require(!gate.transmitting(), "gate stayed open after stabilized voice ended");
}

void
testMalformedDurationStillBounded()
{
    jami::AudioTransmissionGate gate;
    for (std::size_t i = 0; i < jami::AudioTransmissionGate::MAX_PRE_ROLL_FRAMES + 5; ++i)
        gate.observe(jami::AudioTransmissionMode::VOICE_ACTIVATED,
                     false,
                     std::chrono::microseconds::zero());

    require(gate.bufferedFrames() == jami::AudioTransmissionGate::MAX_PRE_ROLL_FRAMES,
            "malformed frame durations bypassed the frame-count bound");
}

} // namespace

int
main()
{
    try {
        testOpenIsUnconditional();
        testVoiceActivatedUsesBoundedPreRoll();
        testModeSwitchAndReset();
        testTrustsProcessorHangover();
        testMalformedDurationStillBounded();
    } catch (const std::exception& e) {
        std::cerr << "audio transmission gate test failed: " << e.what() << '\n';
        return 1;
    }
    return 0;
}
