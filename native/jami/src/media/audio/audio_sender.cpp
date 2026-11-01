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

#include "audio_sender.h"
#include "libav_deps.h"
#include "logger.h"
#include "media_encoder.h"
#include "media_io_handle.h"
#include "media_stream.h"
#include "resampler.h"

#include <chrono>
#include <memory>

namespace jami {

AudioSender::AudioSender(const std::string& dest,
                         const MediaDescription& args,
                         SocketPair& socketPair,
                         const uint16_t seqVal,
                         const uint16_t mtu)
    : dest_(dest)
    , args_(args)
    , seqVal_(seqVal)
    , mtu_(mtu)
{
    setup(socketPair);
}

AudioSender::~AudioSender()
{
    audioEncoder_.reset();
    muxContext_.reset();
}

bool
AudioSender::setup(SocketPair& socketPair)
{
    audioEncoder_.reset(new MediaEncoder);
    muxContext_.reset(socketPair.createIOContext(mtu_));

    try {
        /* Encoder setup */
        JAMI_LOG("audioEncoder_->openOutput {}", dest_);
        audioEncoder_->openOutput(dest_, "rtp");
        audioEncoder_->setOptions(args_);
        auto codec = std::static_pointer_cast<SystemAudioCodecInfo>(args_.codec);
        auto ms = MediaStream("audio sender", codec->audioformat);
        audioEncoder_->setOptions(ms);
        audioEncoder_->addStream(*args_.codec);
        audioEncoder_->setInitSeqVal(seqVal_);
        audioEncoder_->setIOContext(muxContext_->getContext());
    } catch (const MediaEncoderException& e) {
        JAMI_ERROR("{}", e.what());
        return false;
    }
#ifdef DEBUG_SDP
    audioEncoder_->print_sdp();
#endif

    return true;
}

void
AudioSender::update(Observable<std::shared_ptr<jami::MediaFrame>>* /*obs*/,
                    const std::shared_ptr<jami::MediaFrame>& framePtr)
{
    auto audioFrame = std::dynamic_pointer_cast<AudioFrame>(framePtr);
    if (!audioFrame) {
        JAMI_ERROR("AudioSender received a non-audio frame");
        return;
    }

    // check for change in voice activity, if so, call callback
    const bool hasVoice = audioFrame->has_voice;
    if (hasVoice != voice_) {
        voice_ = hasVoice;
        std::function<void(bool)> callback;
        {
            std::lock_guard lock(voiceCallbackMutex_);
            callback = voiceCallback_;
        }
        if (callback) {
            callback(voice_);
        } else {
            JAMI_ERROR("AudioSender no voice callback!");
        }
    }

    const auto sampleRate = audioFrame->getFormat().sample_rate;
    const auto frameDuration = sampleRate == 0
                                   ? std::chrono::microseconds::zero()
                                   : std::chrono::microseconds(
                                       static_cast<int64_t>(audioFrame->getFrameSize()) * 1'000'000
                                       / sampleRate);
    const auto decision = transmissionGate_.observe(requestedTransmissionMode_.load(std::memory_order_acquire),
                                                    hasVoice,
                                                    frameDuration);

    for (std::size_t i = 0; i < decision.discardBuffered && !preRoll_.empty(); ++i) {
        discard(preRoll_.front());
        preRoll_.pop_front();
    }

    if (decision.bufferCurrent)
        preRoll_.emplace_back(std::move(audioFrame));

    if (decision.releaseBuffered > 0) {
        if (decision.releaseBuffered != preRoll_.size()) {
            JAMI_ERROR("Audio transmission pre-roll state diverged (policy: {}, frames: {})",
                       decision.releaseBuffered,
                       preRoll_.size());
            for (const auto& buffered : preRoll_)
                discard(buffered);
            preRoll_.clear();
        } else {
            while (!preRoll_.empty()) {
                auto buffered = std::move(preRoll_.front());
                preRoll_.pop_front();
                encode(buffered);
            }
        }
    }

    if (decision.transmitCurrent)
        encode(audioFrame);
}

void
AudioSender::setVoiceCallback(std::function<void(bool)> cb)
{
    if (cb) {
        std::lock_guard lock(voiceCallbackMutex_);
        voiceCallback_ = std::move(cb);
    } else {
        JAMI_ERROR("AudioSender attempting to set invalid voice callback");
    }
}

void
AudioSender::setTransmissionMode(AudioTransmissionMode mode) noexcept
{
    requestedTransmissionMode_.store(mode, std::memory_order_release);
}

void
AudioSender::encode(const std::shared_ptr<AudioFrame>& frame)
{
    if (!frame)
        return;

    auto* avFrame = frame->pointer();
    avFrame->pts = static_cast<int64_t>(sent_samples);
    sent_samples += avFrame->nb_samples;
    if (audioEncoder_->encodeAudio(*frame) < 0)
        JAMI_ERROR("encoding failed");
}

void
AudioSender::discard(const std::shared_ptr<AudioFrame>& frame)
{
    if (!frame)
        return;

    const auto frameSamples = frame->pointer()->nb_samples;
    if (frameSamples <= 0)
        return;
    const auto samples = static_cast<unsigned>(frameSamples);
    sent_samples += samples;
    audioEncoder_->advanceAudioSamples(samples);
}

uint16_t
AudioSender::getLastSeqValue()
{
    return audioEncoder_->getLastSeqValue();
}

int
AudioSender::setPacketLoss(uint64_t pl)
{
    // The encoder may be destroy during a bitrate change
    // when a codec parameter like auto quality change
    if (!audioEncoder_)
        return -1; // NOK

    return audioEncoder_->setPacketLoss(pl);
}

} // namespace jami
