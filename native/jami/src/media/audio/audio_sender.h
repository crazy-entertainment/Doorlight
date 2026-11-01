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

#include "audio_transmission_gate.h"
#include "media_buffer.h"
#include "media_codec.h"
#include "noncopyable.h"
#include "observer.h"
#include "socket_pair.h"

#include <atomic>
#include <deque>
#include <mutex>

namespace jami {

class AudioInput;
class MediaEncoder;
class MediaIOHandle;
class Resampler;

class AudioSender : public Observer<std::shared_ptr<MediaFrame>>
{
public:
    AudioSender(const std::string& dest,
                const MediaDescription& args,
                SocketPair& socketPair,
                const uint16_t seqVal,
                const uint16_t mtu);
    ~AudioSender();

    uint16_t getLastSeqValue();
    int setPacketLoss(uint64_t pl);

    void setVoiceCallback(std::function<void(bool)> cb);
    void setTransmissionMode(AudioTransmissionMode mode) noexcept;

    void update(Observable<std::shared_ptr<jami::MediaFrame>>*, const std::shared_ptr<jami::MediaFrame>&) override;

private:
    NON_COPYABLE(AudioSender);

    bool setup(SocketPair& socketPair);
    void encode(const std::shared_ptr<AudioFrame>& frame);
    void discard(const std::shared_ptr<AudioFrame>& frame);

    std::string dest_;
    MediaDescription args_;
    std::unique_ptr<MediaEncoder> audioEncoder_;
    std::unique_ptr<MediaIOHandle> muxContext_;

    uint64_t sent_samples = 0;

    const uint16_t seqVal_;
    uint16_t mtu_;

    // last voice activity state
    bool voice_ {false};
    std::mutex voiceCallbackMutex_;
    std::function<void(bool)> voiceCallback_;

    std::atomic<AudioTransmissionMode> requestedTransmissionMode_ {AudioTransmissionMode::OPEN};
    AudioTransmissionGate transmissionGate_;
    std::deque<std::shared_ptr<AudioFrame>> preRoll_;
};

} // namespace jami
