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

#pragma once

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <deque>

namespace jami {

enum class AudioTransmissionMode : uint8_t {
    OPEN,
    VOICE_ACTIVATED,
};

/**
 * Queue operations to apply to the matching audio-frame pre-roll queue.
 *
 * AudioTransmissionGate deliberately owns only timing and state. The media
 * sender retains ownership of audio frames and executes these operations in
 * order on its single observer thread.
 */
struct AudioTransmissionDecision
{
    std::size_t discardBuffered {0};
    std::size_t releaseBuffered {0};
    bool bufferCurrent {false};
    bool transmitCurrent {false};
};

/**
 * Stateful policy for voice-activated transmission.
 *
 * The voice state supplied to observe() is the daemon audio processor's
 * stabilized WebRTC/Speex result. This class does not perform a second VAD or
 * add another hangover. It only retains a bounded pre-roll so the processor's
 * onset-confirmation window does not clip the beginning of speech.
 *
 * This object is single-threaded by design. AudioSender owns and drives it
 * from the audio observer thread; mode changes are delivered by AudioSender's
 * atomic requested-mode field on the next frame.
 */
class AudioTransmissionGate
{
public:
    static constexpr auto PRE_ROLL = std::chrono::milliseconds(300);
    static constexpr std::size_t MAX_PRE_ROLL_FRAMES = 30;

    AudioTransmissionDecision observe(AudioTransmissionMode mode,
                                      bool hasVoice,
                                      std::chrono::microseconds frameDuration);
    std::size_t reset() noexcept;

    AudioTransmissionMode mode() const noexcept { return mode_; }
    bool transmitting() const noexcept
    {
        return mode_ == AudioTransmissionMode::OPEN || voiceActive_;
    }
    std::size_t bufferedFrames() const noexcept { return bufferedDurations_.size(); }
    std::chrono::microseconds bufferedDuration() const noexcept { return bufferedDuration_; }

private:
    std::size_t clearBuffered() noexcept;
    std::size_t retain(std::chrono::microseconds frameDuration);

    AudioTransmissionMode mode_ {AudioTransmissionMode::OPEN};
    bool voiceActive_ {false};
    std::deque<std::chrono::microseconds> bufferedDurations_;
    std::chrono::microseconds bufferedDuration_ {0};
};

} // namespace jami
