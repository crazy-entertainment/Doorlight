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

#include "data_transfer.h"
#include "verified_received_seed.h"
#include "received_file_receipt.h"
#include <nettle/sha3.h>
#include <nettle/version.h>
#include <random>
#include <algorithm>
#include <set>

#include "base64.h"
#include "fileutils.h"
#include "manager.h"
#include "client/jami_signal.h"

#include <mutex>
#include <cstdlib> // mkstemp
#include <cstdint>
#include <filesystem>
#include <limits>

#include <opendht/rng.h>
#include <opendht/thread_pool.h>

namespace jami {
namespace {
struct ReceivedSeedDigest {
    sha3_512_ctx context;
    ReceivedSeedDigest() { sha3_512_init(&context); }
    void update(const unsigned char* data, unsigned size) {
        sha3_512_update(&context, size, data);
    }
    std::string finish() {
        unsigned char bytes[SHA3_512_DIGEST_SIZE];
#if NETTLE_VERSION_MAJOR >= 4
        sha3_512_digest(&context, bytes);
#else
        sha3_512_digest(&context, SHA3_512_DIGEST_SIZE, bytes);
#endif
        return dht::toHex(bytes, SHA3_512_DIGEST_SIZE);
    }
};
bool publishReceivedSeed(const std::filesystem::path& source,
                         const std::filesystem::path& seed,
                         int64_t size, const std::string& hash)
{
    if (size < 0) return false;
    try {
        std::random_device random;
        const auto temporary = seed.parent_path() /
            fmt::format(".received-seed-{:08x}{:08x}{:08x}{:08x}",
                        random(), random(), random(), random());
        return received_seed::publish<ReceivedSeedDigest>(source, seed, temporary,
                                                          uint64_t(size), hash);
    } catch (...) {
        JAMI_WARNING("Received seed publication failed");
        return false;
    }
}
bool recordReceivedCompletion(const std::filesystem::path& source,
                              const std::filesystem::path& seed,
                              const std::string& account, const std::string& conversation,
                              const std::string& commit, const std::string& file,
                              int64_t size, const std::string& hash,
                              const std::string& attempt = {})
{
    try {
        received_seed::Receipt receipt;
        receipt.account = account; receipt.conversation = conversation;
        receipt.commit = commit; receipt.file = file; receipt.hash = hash;
        receipt.attempt = attempt.empty() ? newTransferAttemptId() : attempt;
        if (size < 0) return false;
        receipt.size = uint64_t(size);
        if (!publishReceivedSeed(source, seed, size, hash)) return false;
        received_seed::File input(seed, false);
        receipt.identity = input.identity();
        if (!received_seed::readVerified<ReceivedSeedDigest>(input, receipt.size, hash)) return false;
        const auto destination = seed.parent_path() / (file + ".sybl-receipt");
        const auto temporary = seed.parent_path() / (".receipt-" + receipt.attempt);
        return received_seed::saveReceipt(destination, temporary, receipt);
    } catch (...) {
        JAMI_WARNING("Received completion receipt failed");
        return false;
    }
}
} // namespace

std::string newTransferAttemptId()
{
    std::random_device random;
    return fmt::format("{:08x}{:08x}{:08x}{:08x}",
                       random(), random(), random(), random());
}

libjami::DataTransferId
generateUID(std::mt19937_64& engine)
{
    return std::uniform_int_distribution<libjami::DataTransferId> {1, JAMI_ID_MAX_VAL}(engine);
}

std::string
getFileId(const std::string& commitId, const std::string& tid, const std::string& displayName)
{
    auto extension = fileutils::getFileExtension(displayName);
    if (extension.empty())
        return fmt::format("{}_{}", commitId, tid);
    return fmt::format("{}_{}.{}", commitId, tid, extension);
}

FileInfo::FileInfo(const std::shared_ptr<dhtnet::ChannelSocket>& channel,
                   const std::string& fileId,
                   const std::string& interactionId,
                   const libjami::DataTransferInfo& info)
    : fileId_(fileId)
    , interactionId_(interactionId)
    , info_(info)
    , channel_(channel)
{}

void
FileInfo::emit(libjami::DataTransferEventCode code)
{
    if (finishedCb_ && code >= libjami::DataTransferEventCode::finished)
        finishedCb_(uint32_t(code));
    if (interactionId_ != "") {
        // Else it's an internal transfer
        runOnMainThread([info = info_, iid = interactionId_, fid = fileId_, attempt = attemptId_, code]() {
            emitSignal<libjami::DataTransferSignal::DataTransferEvent>(info.accountId,
                                                                       info.conversationId,
                                                                       iid,
                                                                       fid,
                                                                       uint32_t(code));
            if (!attempt.empty())
                emitSignal<libjami::DataTransferSignal::DataTransferEventOwned>(
                    info.accountId, info.conversationId, iid, fid, attempt, uint32_t(code));
        });
    }
}

OutgoingFile::OutgoingFile(const std::shared_ptr<dhtnet::ChannelSocket>& channel,
                           const std::string& fileId,
                           const std::string& interactionId,
                           const libjami::DataTransferInfo& info,
                           size_t start,
                           size_t end)
    : FileInfo(channel, fileId, interactionId, info)
    , start_(start)
    , end_(end)
{
    std::filesystem::path fpath(info_.path);
    if (!std::filesystem::is_regular_file(fpath)) {
        dht::ThreadPool::io().run([channel = std::move(channel_)] { channel->shutdown(); });
        return;
    }
    stream_.open(fpath, std::ios::binary | std::ios::in);
    if (!stream_ || !stream_.is_open()) {
        dht::ThreadPool::io().run([channel = std::move(channel_)] { channel->shutdown(); });
        return;
    }
}

OutgoingFile::~OutgoingFile()
{
    if (stream_ && stream_.is_open())
        stream_.close();
    if (channel_) {
        dht::ThreadPool::io().run([channel = std::move(channel_)] { channel->shutdown(); });
    }
}

void
OutgoingFile::process()
{
    if (!channel_ or !stream_ or !stream_.is_open())
        return;
    auto correct = false;
    stream_.seekg(static_cast<long>(start_), std::ios::beg);
    try {
        std::vector<char> buffer(UINT16_MAX, 0);
        std::error_code ec;
        auto pos = start_;
        while (!stream_.eof()) {
            stream_.read(buffer.data(),
                         end_ > start_ ? static_cast<long>(std::min(end_ - pos, buffer.size()))
                                       : static_cast<long>(buffer.size()));
            auto gcount = stream_.gcount();
            pos += gcount;
            channel_->write(reinterpret_cast<const uint8_t*>(buffer.data()), gcount, ec);
            if (ec)
                break;
        }
        if (!ec)
            correct = true;
        stream_.close();
    } catch (const std::exception&) {
        JAMI_WARNING("Outgoing file read failed");
    }
    if (!isUserCancelled_) {
        // NOTE: emit(code) MUST be changed to improve handling of multiple destinations
        // But for now, we can just avoid to emit errors to the client, because for outgoing
        // transfer in a swarm, for outgoingFiles, we know that the file is ok. And the peer
        // will retry the transfer if they need, so we don't need to show errors.
        if (!interactionId_.empty() && !correct)
            return;
        auto code = correct ? libjami::DataTransferEventCode::finished : libjami::DataTransferEventCode::closed_by_peer;
        emit(code);
    }
}

void
OutgoingFile::cancel()
{
    // Remove link, not original file
    auto path = fileutils::get_data_dir() / "conversation_data" / info_.accountId / info_.conversationId / fileId_;
    if (std::filesystem::is_symlink(path))
        dhtnet::fileutils::remove(path);
    isUserCancelled_ = true;
    emit(libjami::DataTransferEventCode::closed_by_host);
}

IncomingFile::IncomingFile(const std::shared_ptr<dhtnet::ChannelSocket>& channel,
                           const libjami::DataTransferInfo& info,
                           const std::string& fileId,
                           const std::string& interactionId,
                           const std::string& sha3Sum,
                           const std::filesystem::path& seedPath,
                           const std::string& attemptId)
    : FileInfo(channel, fileId, interactionId, info)
    , sha3Sum_(sha3Sum)
    , path_(info.path + ".tmp")
    , seedPath_(seedPath)
{
    attemptId_ = attemptId;
    stream_ = std::make_unique<received_seed::File>(path_, received_seed::File::Mode::append);
    if (!stream_->valid()) {
        JAMI_ERROR("Receive file unavailable");
        failed_ = true;
        return;
    }

    const auto position = static_cast<std::streamoff>(stream_->size());
    if (position < 0
        || static_cast<std::uintmax_t>(position)
               > static_cast<std::uintmax_t>(std::numeric_limits<int64_t>::max())) {
        JAMI_ERROR("Receive position unavailable");
        failed_ = true;
        stream_->close();
        return;
    }

    const auto progress = static_cast<int64_t>(position);
    const auto profile = fileId_ == "profile.vcf";
    const auto sizeLimit = profile ? PROFILE_VCARD_MAX_BYTES : info_.totalSize;
    if ((profile || !interactionId_.empty())
        && (sizeLimit < 0 || info_.bytesProgress != progress || progress > sizeLimit)) {
        JAMI_WARNING("Receive resume position refused");
        failed_ = true;
        std::error_code ec;
        if (!stream_->removeOwned()) ec = std::make_error_code(std::errc::io_error);
        stream_->close();
        if (ec)
            JAMI_ERROR("Invalid partial receive cleanup failed");
        return;
    }
    info_.bytesProgress = progress;

    emit(libjami::DataTransferEventCode::ongoing);
}

IncomingFile::~IncomingFile()
{
    {
        std::lock_guard<std::mutex> lk(streamMtx_);
        if (stream_ && stream_->valid())
            stream_->close();
    }
    if (channel_)
        dht::ThreadPool::io().run([channel = std::move(channel_)] { channel->shutdown(); });
}

void
IncomingFile::cancel()
{
    // Cancellation and final publication have one linearization boundary.
    // Once cancellation returns, this attempt can no longer publish bytes.
    std::lock_guard<std::mutex> lock(streamMtx_);
    if (terminal_) return;
    terminal_ = true;
    isUserCancelled_ = true;
    if (stream_->valid()) {
        stream_->removeOwned();
        stream_->close();
    }
    emit(libjami::DataTransferEventCode::closed_by_peer);
    if (channel_)
        dht::ThreadPool::io().run([channel = channel_] { channel->shutdown(); });
}

void
IncomingFile::process()
{
    channel_->setOnRecv([w = weak_from_this()](const uint8_t* buf, size_t len) {
        if (auto shared = w.lock()) {
            std::lock_guard<std::mutex> lk(shared->streamMtx_);
            if (shared->isUserCancelled_ || shared->failed_ || !shared->stream_->valid())
                return static_cast<ssize_t>(-1);

            const auto progress = shared->info_.bytesProgress;
            const auto total = shared->info_.totalSize;
            const auto profile = shared->fileId_ == "profile.vcf";
            const auto sizeLimit = profile ? PROFILE_VCARD_MAX_BYTES : total;
            if (((profile || !shared->interactionId_.empty())
                 && (progress < 0 || sizeLimit < progress
                      || static_cast<std::uintmax_t>(len)
                             > static_cast<std::uintmax_t>(sizeLimit - progress)))
                || static_cast<std::uintmax_t>(len)
                       > static_cast<std::uintmax_t>(std::numeric_limits<std::streamsize>::max())
                || static_cast<std::uintmax_t>(len)
                       > static_cast<std::uintmax_t>(std::numeric_limits<ssize_t>::max())
                || progress < 0
                || static_cast<std::uintmax_t>(len)
                       > static_cast<std::uintmax_t>(std::numeric_limits<int64_t>::max() - progress)) {
                JAMI_WARNING("Incoming transfer size limit exceeded");
                shared->failed_ = true;
                return static_cast<ssize_t>(-1);
            }

            if (len > std::numeric_limits<unsigned>::max() ||
                !shared->stream_->write(buf, static_cast<unsigned>(len))) {
                JAMI_ERROR("Incoming file write failed");
                shared->failed_ = true;
                return static_cast<ssize_t>(-1);
            }

            const auto position = static_cast<std::streamoff>(shared->stream_->size());
            const auto expected = progress + static_cast<int64_t>(len);
            if (position < 0 || position != expected) {
                JAMI_ERROR("Incoming file position unavailable");
                shared->failed_ = true;
                return static_cast<ssize_t>(-1);
            }
            shared->info_.bytesProgress = static_cast<int64_t>(position);
            return static_cast<ssize_t>(len);
        }
        // Data received after destruction
        JAMI_ERROR("{} bytes received after IncomingFile destruction.", len);
        return static_cast<ssize_t>(-1);
    });
    channel_->onShutdown([w = weak_from_this()](const std::error_code& /*error_code*/) {
        auto shared = w.lock();
        if (!shared)
            return;
        std::unique_lock<std::mutex> finalization(shared->streamMtx_);
        if (shared->terminal_) return;
        shared->terminal_ = true;
        bool failed;
        {
            if (!shared->stream_->valid() || !shared->stream_->flush())
                shared->failed_ = true;
            failed = shared->failed_;
        }
        auto correct = !failed && shared->sha3Sum_.empty();
        std::error_code ec;
        if (failed) {
            if (!shared->stream_->removeOwned()) ec = std::make_error_code(std::errc::io_error);
        } else if (!correct) {
            if (shared->isUserCancelled_) {
                if (!shared->stream_->removeOwned()) ec = std::make_error_code(std::errc::io_error);
            } else if (shared->info_.bytesProgress < shared->info_.totalSize) {
                JAMI_WARNING("Incoming transfer interrupted before finalization");
            } else if (shared->info_.totalSize != 0 && shared->info_.bytesProgress > shared->info_.totalSize) {
                JAMI_WARNING("Incoming transfer exceeded announced size");
                if (!shared->stream_->removeOwned()) ec = std::make_error_code(std::errc::io_error);
            } else {
                const auto expectedSize = shared->fileId_ == "profile.vcf"
                    ? shared->stream_->size() : uint64_t(shared->info_.totalSize);
                const bool verified = received_seed::readVerified<ReceivedSeedDigest>(
                    *shared->stream_, expectedSize, shared->sha3Sum_);
                if (verified) {
                    JAMI_LOG("Incoming file hash verified");
                    correct = true;
                } else {
                    JAMI_WARNING("Incoming file hash verification failed");
                    if (!shared->stream_->removeOwned()) ec = std::make_error_code(std::errc::io_error);
                }
            }
            if (ec) {
                JAMI_ERROR("Partial receive cleanup failed");
            }
        }
        if (correct) {
            if (!shared->stream_->publishTo(shared->info_.path)) {
                JAMI_ERROR("Incoming file finalization failed");
                correct = false;
            }
        }
        shared->stream_->close();
        // A finished event promises that fileInfo and subsequent sharing can
        // resolve the received bytes without relying on Windows symlinks.
        if (correct && !shared->seedPath_.empty()) {
            correct = recordReceivedCompletion(shared->info_.path, shared->seedPath_,
                shared->info_.accountId, shared->info_.conversationId,
                shared->interactionId_, shared->fileId_, shared->info_.totalSize, shared->sha3Sum_,
                shared->attemptId_);
        }
        if (shared->isUserCancelled_)
            return;
        auto code = correct ? libjami::DataTransferEventCode::finished : libjami::DataTransferEventCode::closed_by_host;
        shared->emit(code);
        finalization.unlock();
        dht::ThreadPool::io().run([s = std::move(shared)] {});
    });

    bool failed;
    {
        std::lock_guard<std::mutex> lk(streamMtx_);
        failed = failed_;
    }
    if (failed)
        channel_->shutdown();
}

//==============================================================================

class TransferManager::Impl
{
public:
    Impl(const std::string& accountId, const std::string& accountUri, const std::string& to, const std::mt19937_64& rand)
        : accountId_(accountId)
        , accountUri_(accountUri)
        , to_(to)
        , rand_(rand)
    {
        if (!to_.empty()) {
            conversationDataPath_ = fileutils::get_data_dir() / accountId_ / "conversation_data" / to_;
            dhtnet::fileutils::check_dir(conversationDataPath_);
            waitingPath_ = conversationDataPath_ / "waiting";
        }
        profilesPath_ = fileutils::get_data_dir() / accountId_ / "profiles";
        accountProfilePath_ = fileutils::get_data_dir() / accountId / "profile.vcf";
        loadWaiting();
    }

    ~Impl()
    {
        std::lock_guard lk {mapMutex_};
        for (auto& [channel, _] : outgoings_) {
            dht::ThreadPool::io().run([c = std::move(channel)] { c->shutdown(); });
        }
        outgoings_.clear();
        for (const auto& [_, incoming] : incomings_) incoming->cancel();
        incomings_.clear();
        vcards_.clear();
    }

    void loadWaiting()
    {
        try {
            // read file
            auto file = fileutils::loadFile(waitingPath_);
            // load values
            msgpack::object_handle oh = msgpack::unpack((const char*) file.data(), file.size());
            std::lock_guard lk {mapMutex_};
            oh.get().convert(waitingIds_);
            for (const auto& [_, request] : waitingIds_) admittedAttempts_.insert(request.attemptId);
        } catch (const std::exception& e) {
            return;
        }
    }
    void saveWaiting()
    {
        std::ofstream file(waitingPath_, std::ios::trunc | std::ios::binary);
        msgpack::pack(file, waitingIds_);
    }

    std::string accountId_ {};
    std::string accountUri_ {};
    std::string to_ {};
    std::filesystem::path waitingPath_ {};
    std::filesystem::path profilesPath_ {};
    std::filesystem::path accountProfilePath_ {};
    std::filesystem::path conversationDataPath_ {};

    std::mutex mapMutex_ {};
    std::map<std::string, WaitingRequest> waitingIds_ {};
    std::set<std::string> admittedAttempts_ {};
    std::map<std::shared_ptr<dhtnet::ChannelSocket>, std::shared_ptr<OutgoingFile>> outgoings_ {};
    std::map<std::string, std::shared_ptr<IncomingFile>> incomings_ {};
    std::map<std::pair<std::string, std::string>, std::shared_ptr<IncomingFile>> vcards_ {};

    std::mt19937_64 rand_;
};

TransferManager::TransferManager(const std::string& accountId,
                                 const std::string& accountUri,
                                 const std::string& to,
                                 const std::mt19937_64& rand)
    : pimpl_ {std::make_unique<Impl>(accountId, accountUri, to, rand)}
{}

TransferManager::~TransferManager() {}

void
TransferManager::transferFile(const std::shared_ptr<dhtnet::ChannelSocket>& channel,
                              const std::string& fileId,
                              const std::string& interactionId,
                              const std::string& path,
                              size_t start,
                              size_t end,
                              OnFinishedCb onFinished)
{
    std::lock_guard lk {pimpl_->mapMutex_};
    if (pimpl_->outgoings_.find(channel) != pimpl_->outgoings_.end())
        return;
    libjami::DataTransferInfo info;
    info.accountId = pimpl_->accountId_;
    info.conversationId = pimpl_->to_;
    info.path = path;
    auto f = std::make_shared<OutgoingFile>(channel, fileId, interactionId, info, start, end);
    f->onFinished([w = weak(), channel, onFinished = std::move(onFinished)](uint32_t code) {
        if (code == uint32_t(libjami::DataTransferEventCode::finished) && onFinished) {
            onFinished();
        }
        // schedule destroy outgoing transfer as not needed
        dht::ThreadPool().computation().run([w, channel] {
            if (auto sthis_ = w.lock()) {
                auto& pimpl = sthis_->pimpl_;
                std::lock_guard lk {pimpl->mapMutex_};
                auto itO = pimpl->outgoings_.find(channel);
                if (itO != pimpl->outgoings_.end())
                    pimpl->outgoings_.erase(itO);
            }
        });
    });
    auto [outFile, _] = pimpl_->outgoings_.emplace(channel, std::move(f));
    dht::ThreadPool::io().run([w = std::weak_ptr<OutgoingFile>(outFile->second)] {
        if (auto of = w.lock())
            of->process();
    });
}

bool
TransferManager::cancel(const std::string& fileId, const std::string& expectedAttempt)
{
    std::lock_guard lk {pimpl_->mapMutex_};
    // Compare and retire under one lock: a delayed cancel cannot cancel B.
    auto itW = pimpl_->waitingIds_.find(fileId);
    if (!expectedAttempt.empty() && (itW == pimpl_->waitingIds_.end() ||
        itW->second.attemptId != expectedAttempt)) return false;
    const bool waiting = itW != pimpl_->waitingIds_.end();
    if (waiting) {
        pimpl_->waitingIds_.erase(itW);
        JAMI_LOG("Cancel {}", fileId);
        pimpl_->saveWaiting();
    }
    auto itC = pimpl_->incomings_.find(fileId);
    if (itC == pimpl_->incomings_.end())
        return waiting;
    itC->second->cancel();
    pimpl_->incomings_.erase(itC);
    return true;
}

bool
TransferManager::recordCompleted(const std::string& fileId, const std::string& interactionId,
                                const std::string& source, int64_t size, const std::string& hash,
                                const std::string& expectedAttempt)
{
    if (!received_seed::leaf(fileId) || interactionId.size() != 40 ||
        fileId.compare(0, 41, interactionId + "_") != 0) return false;
    std::lock_guard lock(pimpl_->mapMutex_);
    if (pimpl_->incomings_.count(fileId)) return false;
    const auto owned = pimpl_->waitingIds_.find(fileId);
    if (!expectedAttempt.empty() && (owned == pimpl_->waitingIds_.end() ||
        owned->second.attemptId != expectedAttempt)) return false;
    const bool completed = recordReceivedCompletion(source, path(fileId), pimpl_->accountId_, pimpl_->to_,
                                                   interactionId, fileId, size, hash, expectedAttempt);
    if (completed) {
        const auto waiting = pimpl_->waitingIds_.find(fileId);
        if (waiting != pimpl_->waitingIds_.end() && waiting->second.interactionId == interactionId &&
            waiting->second.sha3sum == hash && waiting->second.totalSize == uint64_t(size)) {
            pimpl_->waitingIds_.erase(waiting);
            pimpl_->saveWaiting();
        }
    }
    return completed;
}

bool
TransferManager::completed(const std::string& fileId, const std::string& expectedHash, int64_t expectedSize,
                           std::string& output, int64_t& size) const noexcept
{
    output.clear(); size = 0;
    try {
        if (!received_seed::leaf(fileId)) return false;
        received_seed::Receipt receipt;
        const auto root = pimpl_->conversationDataPath_;
        if (!received_seed::loadReceipt(root / (fileId + ".sybl-receipt"), receipt) ||
            expectedSize < 0 || receipt.size != uint64_t(expectedSize) || receipt.hash != expectedHash ||
            !received_seed::verifyReceipt<ReceivedSeedDigest>(root, receipt,
                pimpl_->accountId_, pimpl_->to_, fileId)) return false;
        output = (root / fileId).string();
        size = int64_t(receipt.size);
        return true;
    } catch (...) { return false; }
}

bool
TransferManager::info(const std::string& fileId, std::string& path, int64_t& total, int64_t& progress) const noexcept
{
    std::unique_lock lk {pimpl_->mapMutex_};
    if (pimpl_->to_.empty())
        return false;

    auto itI = pimpl_->incomings_.find(fileId);
    auto itW = pimpl_->waitingIds_.find(fileId);
    path = this->path(fileId).string();
    if (itI != pimpl_->incomings_.end()) {
        total = itI->second->info().totalSize;
        progress = itI->second->info().bytesProgress;
        return true;
    } else if (std::filesystem::is_regular_file(path)) {
        std::ifstream transfer(path, std::ios::binary);
        transfer.seekg(0, std::ios::end);
        progress = transfer.tellg();
        if (itW != pimpl_->waitingIds_.end()) {
            total = static_cast<int64_t>(itW->second.totalSize);
        } else {
            // If not waiting it's finished
            total = progress;
        }
        return true;
    } else if (itW != pimpl_->waitingIds_.end()) {
        total = static_cast<int64_t>(itW->second.totalSize);
        progress = 0;
        return true;
    }
    // Else we don't know infos there.
    progress = 0;
    return false;
}

std::string
TransferManager::waitForTransfer(const std::string& fileId,
                                 const std::string& interactionId,
                                 const std::string& sha3sum,
                                 const std::string& path,
                                 std::size_t total, const std::string& attemptId)
{
    if (!attemptId.empty() && (attemptId.size() != 32 ||
        !std::all_of(attemptId.begin(), attemptId.end(), [](char c) {
            return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
        }))) return {};
    std::unique_lock lk(pimpl_->mapMutex_);
    auto itW = pimpl_->waitingIds_.find(fileId);
    if (itW != pimpl_->waitingIds_.end()) {
        const auto& current = itW->second;
        if (attemptId.empty() || current.attemptId == attemptId)
            return current.interactionId == interactionId && current.sha3sum == sha3sum &&
                current.path == path && current.totalSize == total ? current.attemptId : std::string{};
    }
    WaitingRequest request {fileId, interactionId, sha3sum, path, total};
    if (!attemptId.empty()) request.attemptId = attemptId;
    const auto admitted = request.attemptId;
    // Never recycle a retired client token. A fresh explicit retry may replace
    // interrupted waiting work, while the old request/channel stays retired.
    if (pimpl_->admittedAttempts_.size() >= 32768 ||
        !pimpl_->admittedAttempts_.insert(admitted).second) return {};
    auto incoming = pimpl_->incomings_.find(fileId);
    if (incoming != pimpl_->incomings_.end()) {
        incoming->second->cancel();
        pimpl_->incomings_.erase(incoming);
    }
    pimpl_->waitingIds_[fileId] = std::move(request);
    pimpl_->saveWaiting();
    return admitted;
}

void
TransferManager::onIncomingFileTransfer(const std::string& fileId,
                                        const std::shared_ptr<dhtnet::ChannelSocket>& channel,
                                        size_t start, const std::string& attemptId)
{
    std::lock_guard lk(pimpl_->mapMutex_);
    // Check if not already an incoming file for this id and that we are waiting this file
    auto itC = pimpl_->incomings_.find(fileId);
    if (itC != pimpl_->incomings_.end()) {
        dht::ThreadPool().io().run([channel] { channel->shutdown(); });
        return;
    }
    auto itW = pimpl_->waitingIds_.find(fileId);
    if (itW == pimpl_->waitingIds_.end() || attemptId.empty() ||
        itW->second.attemptId != attemptId || !received_seed::leaf(fileId) ||
        itW->second.interactionId.size() != 40 ||
        fileId.compare(0, 41, itW->second.interactionId + "_") != 0) {
        dht::ThreadPool().io().run([channel] { channel->shutdown(); });
        return;
    }

    libjami::DataTransferInfo info;
    info.accountId = pimpl_->accountId_;
    info.conversationId = pimpl_->to_;
    info.path = itW->second.path;
    info.totalSize = static_cast<int64_t>(itW->second.totalSize);
    info.bytesProgress = static_cast<int64_t>(start);

    // Publish an independent verified seed only after the receive completes.
    auto filePath = path(fileId);
    if (info.path.empty())
        info.path = filePath.string();

    auto ifile = std::make_shared<IncomingFile>(std::move(channel),
                                                info,
                                                fileId,
                                                itW->second.interactionId,
                                                itW->second.sha3sum,
                                                filePath, attemptId);
    auto res = pimpl_->incomings_.emplace(fileId, std::move(ifile));
    if (res.second) {
        res.first->second->onFinished([w = weak(), fileId, attemptId, attempt = std::weak_ptr<IncomingFile>(res.first->second)](uint32_t code) {
            // schedule destroy transfer as not needed
            dht::ThreadPool().computation().run([w, fileId, code, attempt, attemptId] {
                if (auto sthis_ = w.lock()) {
                    auto& pimpl = sthis_->pimpl_;
                    std::lock_guard lk {pimpl->mapMutex_};
                    auto itO = pimpl->incomings_.find(fileId);
                    // A delayed cleanup must not erase a replacement attempt.
                    if (itO == pimpl->incomings_.end() || itO->second != attempt.lock()) return;
                    pimpl->incomings_.erase(itO);
                    if (code == uint32_t(libjami::DataTransferEventCode::finished)) {
                        auto itW = pimpl->waitingIds_.find(fileId);
                        if (itW != pimpl->waitingIds_.end() && itW->second.attemptId == attemptId) {
                            pimpl->waitingIds_.erase(itW);
                            pimpl->saveWaiting();
                        }
                    }
                }
            });
        });
        res.first->second->process();
    }
}

std::string
TransferManager::waitingAttempt(const std::string& fileId) const
{
    std::lock_guard lock(pimpl_->mapMutex_);
    const auto waiting = pimpl_->waitingIds_.find(fileId);
    return waiting == pimpl_->waitingIds_.end() ? std::string{} : waiting->second.attemptId;
}

std::filesystem::path
TransferManager::path(const std::string& fileId) const
{
    return pimpl_->conversationDataPath_ / fileId;
}

unsigned
TransferManager::reserveChannelRetry(const std::string& fileId, const std::string& attemptId)
{
    std::lock_guard lock(pimpl_->mapMutex_);
    auto it = pimpl_->waitingIds_.find(fileId);
    if (attemptId.empty() || it == pimpl_->waitingIds_.end() ||
        it->second.attemptId != attemptId || pimpl_->incomings_.count(fileId) ||
        it->second.channelRetryPending || it->second.channelRetries >= 8) return 0;
    auto& request = it->second;
    request.channelRetryPending = true;
    return 250u << std::min(request.channelRetries++, 4u);
}

bool
TransferManager::consumeChannelRetry(const std::string& fileId, const std::string& attemptId)
{
    std::lock_guard lock(pimpl_->mapMutex_);
    auto it = pimpl_->waitingIds_.find(fileId);
    if (attemptId.empty() || it == pimpl_->waitingIds_.end() ||
        it->second.attemptId != attemptId || !it->second.channelRetryPending) return false;
    it->second.channelRetryPending = false;
    return !pimpl_->incomings_.count(fileId);
}

void
TransferManager::onIncomingProfile(const std::shared_ptr<dhtnet::ChannelSocket>& channel, const std::string& sha3Sum)
{
    if (!channel)
        return;

    auto chName = channel->name();
    std::string_view name = chName;
    auto sep = name.find_last_of('?');
    if (sep != std::string::npos)
        name = name.substr(0, sep);

    auto lastSep = name.find_last_of('/');
    auto fileId = name.substr(lastSep + 1);

    auto deviceId = channel->deviceId().toString();
    auto cert = channel->peerCertificate();
    if (!cert || !cert->issuer || fileId.find(".vcf") == std::string::npos)
        return;

    auto uri = fileId == "profile.vcf" ? cert->issuer->getId().toString()
                                       : std::string(fileId.substr(0, fileId.size() - 4 /*.vcf*/));

    std::lock_guard lk(pimpl_->mapMutex_);
    auto idx = std::make_pair(deviceId, uri);
    // Check if not already an incoming file for this id and that we are waiting this file
    auto itV = pimpl_->vcards_.find(idx);
    if (itV != pimpl_->vcards_.end()) {
        dht::ThreadPool().io().run([channel] { channel->shutdown(); });
        return;
    }

    auto tid = generateUID(pimpl_->rand_);
    libjami::DataTransferInfo info;
    info.accountId = pimpl_->accountId_;
    info.conversationId = pimpl_->to_;

    auto recvDir = fileutils::get_cache_dir() / pimpl_->accountId_ / "vcard";
    dhtnet::fileutils::recursive_mkdir(recvDir);
    info.path = (recvDir / fmt::format("{:s}_{:s}_{}", deviceId, uri, tid)).string();

    auto ifile = std::make_shared<IncomingFile>(std::move(channel), info, "profile.vcf", "", sha3Sum);
    auto res = pimpl_->vcards_.emplace(idx, std::move(ifile));
    if (res.second) {
        res.first->second->onFinished([w = weak(),
                                       uri = std::move(uri),
                                       deviceId = std::move(deviceId),
                                       accountId = pimpl_->accountId_,
                                       cert = std::move(cert),
                                       path = info.path](uint32_t code) {
            dht::ThreadPool().computation().run([w,
                                                 uri = std::move(uri),
                                                 deviceId = std::move(deviceId),
                                                 accountId = std::move(accountId),
                                                 path = std::move(path),
                                                 code] {
                if (auto sthis_ = w.lock()) {
                    auto& pimpl = sthis_->pimpl_;

                    auto destPath = sthis_->profilePath(uri);
                    const auto finished = code == uint32_t(libjami::DataTransferEventCode::finished);
                    // A failed receive never produced the verified profile file.
                    if (finished) try {
                        // Move profile to destination path
                        std::lock_guard lock(dhtnet::fileutils::getFileLock(destPath));
                        dhtnet::fileutils::recursive_mkdir(destPath.parent_path());
                        std::filesystem::rename(path, destPath);
                        if (!pimpl->accountUri_.empty() && uri == pimpl->accountUri_) {
                            // If this is the account profile, link or copy it to the account profile path
                            if (!fileutils::createFileLink(pimpl->accountProfilePath_, destPath)) {
                                std::error_code ec;
                                std::filesystem::copy_file(destPath, pimpl->accountProfilePath_, ec);
                            }
                        }
                    } catch (const std::exception& e) {
                        JAMI_ERROR("{}", e.what());
                    }

                    std::lock_guard lk {pimpl->mapMutex_};
                    auto itO = pimpl->vcards_.find({deviceId, uri});
                    if (itO != pimpl->vcards_.end())
                        pimpl->vcards_.erase(itO);
                    if (finished) {
                        emitSignal<libjami::ConfigurationSignal::ProfileReceived>(accountId, uri, destPath.string());
                    }
                }
            });
        });
        res.first->second->process();
    }
}

std::filesystem::path
TransferManager::profilePath(const std::string& contactId) const
{
    return pimpl_->profilesPath_ / fmt::format("{}.vcf", base64::encode(contactId));
}

std::vector<WaitingRequest>
TransferManager::waitingRequests() const
{
    std::vector<WaitingRequest> res;
    std::lock_guard lk(pimpl_->mapMutex_);
    for (const auto& [fileId, req] : pimpl_->waitingIds_) {
        auto itC = pimpl_->incomings_.find(fileId);
        if (itC == pimpl_->incomings_.end())
            res.emplace_back(req);
    }
    return res;
}

bool
TransferManager::isWaiting(const std::string& fileId) const
{
    std::lock_guard lk(pimpl_->mapMutex_);
    return pimpl_->waitingIds_.find(fileId) != pimpl_->waitingIds_.end();
}

} // namespace jami
