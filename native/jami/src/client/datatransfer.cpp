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

#include "datatransfer_interface.h"

#include "manager.h"
#include "jamidht/jamiaccount.h"
#include "jamidht/conversation.h"

namespace libjami {

void
registerDataXferHandlers(const std::map<std::string, std::shared_ptr<CallbackWrapperBase>>& handlers)
{
    registerSignalHandlers(handlers);
}

void
sendFile(const std::string& accountId,
         const std::string& conversationId,
         const std::string& path,
         const std::string& displayName,
         const std::string& replyTo,
         const std::string& syblTopic) noexcept
{
    if (!jami::isValidSybLTopicId(syblTopic, true))
        return;
    if (auto acc = jami::Manager::instance().getAccount<jami::JamiAccount>(accountId)) {
        acc->sendFile(conversationId, path, displayName, replyTo, syblTopic);
    }
}

std::string
sendSybLFile(const std::string& accountId, const std::string& conversationId,
             const std::string& path, const std::string& displayName,
             const std::string& syblTopic, const std::string& syblRoom,
             const std::string& syblMedia, const std::string& operationId)
{
    if (!jami::isValidSybLOperationId(operationId)
        || !jami::isValidSybLTopicId(syblTopic, true)
        || !jami::isValidSybLRoomId(syblRoom, true)
        || (!syblTopic.empty() && !syblRoom.empty())
        || (!syblMedia.empty() && !jami::isValidSybLMediaBody(syblMedia))
        || path.empty() || path.size() > 32768 || displayName.size() > 1024)
        return "failed-before-commit";
    auto acc = jami::Manager::instance().getAccount<jami::JamiAccount>(accountId);
    if (!acc || !acc->convModule(true)) return "failed-before-commit";
    try {
        return acc->sendFile(conversationId, path, displayName, "", syblTopic,
                             syblRoom, syblMedia, operationId);
    } catch (...) {
        return "unknown";
    }
}

bool
repairSybLFileSeed(const std::string& accountId, const std::string& conversationId,
                  const std::string& operationId, const std::string& commitId,
                  const std::string& sourcePath) noexcept
{
    if (!jami::isValidSybLOperationId(operationId) || commitId.size() != 40
        || commitId.find_first_not_of("0123456789abcdef") != std::string::npos
        || sourcePath.size() > 32768) return false;
    try {
        const auto account = jami::Manager::instance().getAccount<jami::JamiAccount>(accountId);
        const auto module = account ? account->convModule(true) : nullptr;
        const auto conversation = module ? module->getConversation(conversationId) : nullptr;
        if (!conversation) return false;
        const auto commit = conversation->getCommit(commitId);
        if (!commit || commit->authorId != account->getUsername()
            || commit->commitMsg.type != jami::CommitType::DATA_TRANSFER
            || commit->commitMsg.syblOperation != operationId) return false;
        const auto transfer = account->dataTransfer(conversationId);
        if (!transfer) return false;
        const auto& message = commit->commitMsg;
        const auto file = jami::getFileId(commitId, message.tid, message.displayName);
        std::string path;
        int64_t total = 0;
        if (transfer->completed(file, message.sha3sum, message.totalSize, path, total)) return true;
        return !sourcePath.empty() && transfer->recordCompleted(file, commitId, sourcePath,
                                                               message.totalSize, message.sha3sum);
    } catch (...) { return false; }
}

bool
downloadFile(const std::string& accountId,
             const std::string& conversationId,
             const std::string& interactionId,
             const std::string& fileId,
             const std::string& path) noexcept
{
    if (auto acc = jami::Manager::instance().getAccount<jami::JamiAccount>(accountId))
        if (auto* convModule = acc->convModule(true))
            return convModule->downloadFile(conversationId, interactionId, fileId, path);
    return {};
}

bool
downloadSybLFile(const std::string& accountId, const std::string& conversationId,
                 const std::string& interactionId, const std::string& fileId,
                 const std::string& path, const std::string& attemptId) noexcept
{
    if (!jami::isValidSybLOperationId(attemptId)) return false;
    try {
        if (auto acc = jami::Manager::instance().getAccount<jami::JamiAccount>(accountId))
            if (auto* module = acc->convModule(true))
                return module->downloadFile(conversationId, interactionId, fileId, path, attemptId);
    } catch (...) {}
    return false;
}

DataTransferError
cancelSybLFile(const std::string& accountId, const std::string& conversationId,
               const std::string& fileId, const std::string& attemptId) noexcept
{
    if (!jami::isValidSybLOperationId(attemptId)) return DataTransferError::invalid_argument;
    try {
        if (auto acc = jami::Manager::instance().getAccount<jami::JamiAccount>(accountId))
            if (auto transfer = acc->dataTransfer(conversationId))
                if (transfer->cancel(fileId, attemptId)) return DataTransferError::success;
    } catch (...) {}
    return DataTransferError::invalid_argument;
}

DataTransferError
cancelDataTransfer(const std::string& accountId, const std::string& conversationId, const std::string& fileId) noexcept
{
    if (auto acc = jami::Manager::instance().getAccount<jami::JamiAccount>(accountId)) {
        if (auto dt = acc->dataTransfer(conversationId))
            return dt->cancel(fileId) ? libjami::DataTransferError::success
                                      : libjami::DataTransferError::invalid_argument;
    }
    return libjami::DataTransferError::invalid_argument;
}

DataTransferError
fileTransferInfo(const std::string& accountId,
                 const std::string& conversationId,
                 const std::string& fileId,
                 std::string& path,
                 int64_t& total,
                 int64_t& progress) noexcept
{
    if (auto acc = jami::Manager::instance().getAccount<jami::JamiAccount>(accountId)) {
        if (auto dt = acc->dataTransfer(conversationId))
            return dt->info(fileId, path, total, progress) ? libjami::DataTransferError::success
                                                           : libjami::DataTransferError::invalid_argument;
    }
    return libjami::DataTransferError::invalid_argument;
}

bool
fileTransferCompleted(const std::string& accountId, const std::string& conversationId,
                      const std::string& fileId, std::string& path, int64_t& total) noexcept
{
    path.clear(); total = 0;
    try {
        if (auto acc = jami::Manager::instance().getAccount<jami::JamiAccount>(accountId)) {
            auto module = acc->convModule(true);
            const auto separator = fileId.find('_');
            if (!module || separator != 40) return false;
            auto conversation = module->getConversation(conversationId);
            if (!conversation) return false;
            const auto commit = conversation->getCommit(fileId.substr(0, separator));
            if (!commit || commit->commitMsg.type != jami::CommitType::DATA_TRANSFER ||
                fileId != jami::getFileId(commit->id, commit->commitMsg.tid, commit->commitMsg.displayName))
                return false;
            if (auto dt = acc->dataTransfer(conversationId))
                return dt->completed(fileId, commit->commitMsg.sha3sum, commit->commitMsg.totalSize,
                                     path, total);
        }
    } catch (...) {}
    return false;
}

} // namespace libjami
