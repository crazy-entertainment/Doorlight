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

#include "audio_transmission_gate.h"

#include <algorithm>

namespace jami {

AudioTransmissionDecision
AudioTransmissionGate::observe(AudioTransmissionMode mode,
                               bool hasVoice,
                               std::chrono::microseconds frameDuration)
{
    AudioTransmissionDecision decision;

    if (mode != mode_) {
        decision.discardBuffered = clearBuffered();
        voiceActive_ = false;
        mode_ = mode;
    }

    if (mode_ == AudioTransmissionMode::OPEN) {
        decision.transmitCurrent = true;
        return decision;
    }

    if (hasVoice) {
        voiceActive_ = true;
        decision.releaseBuffered = bufferedDurations_.size();
        bufferedDurations_.clear();
        bufferedDuration_ = std::chrono::microseconds::zero();
        decision.transmitCurrent = true;
        return decision;
    }

    voiceActive_ = false;
    decision.bufferCurrent = true;
    decision.discardBuffered += retain(frameDuration);
    return decision;
}

std::size_t
AudioTransmissionGate::reset() noexcept
{
    voiceActive_ = false;
    mode_ = AudioTransmissionMode::OPEN;
    return clearBuffered();
}

std::size_t
AudioTransmissionGate::clearBuffered() noexcept
{
    const auto count = bufferedDurations_.size();
    bufferedDurations_.clear();
    bufferedDuration_ = std::chrono::microseconds::zero();
    return count;
}

std::size_t
AudioTransmissionGate::retain(std::chrono::microseconds frameDuration)
{
    // Audio frames are expected to have a positive duration. Treat malformed
    // metadata as zero rather than allowing it to defeat the time bound.
    frameDuration = std::max(frameDuration, std::chrono::microseconds::zero());
    bufferedDurations_.emplace_back(frameDuration);
    bufferedDuration_ += frameDuration;

    std::size_t discard = 0;
    while (bufferedDurations_.size() > 1
           && (bufferedDuration_ > PRE_ROLL || bufferedDurations_.size() > MAX_PRE_ROLL_FRAMES)) {
        bufferedDuration_ -= bufferedDurations_.front();
        bufferedDurations_.pop_front();
        ++discard;
    }
    return discard;
}

} // namespace jami
