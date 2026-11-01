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

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include "conversation_interface.h"

#include <cerrno>
#include <chrono>
#include <cstring>
#include <future>

#include "logger.h"
#include "manager.h"
#include "jami_signal.h"
#include "jamidht/jamiaccount.h"
#include "jamidht/conversation_module.h"

namespace libjami {

std::string
startConversation(const std::string& accountId)
{
    if (auto acc = jami::Manager::instance().getAccount<jami::JamiAccount>(accountId))
        if (auto* convModule = acc->convModule(true))
            return convModule->startConversation();
    return {};
}

void
acceptConversationRequest(const std::string& accountId, const std::string& conversationId)
{
    if (auto acc = jami::Manager::instance().getAccount<jami::JamiAccount>(accountId))
        if (auto* convModule = acc->convModule(true))
            convModule->acceptConversationRequest(conversationId);
}

void
declineConversationRequest(const std::string& accountId, const std::string& conversationId)
{
    if (auto acc = jami::Manager::instance().getAccount<jami::JamiAccount>(accountId))
        acc->declineConversationRequest(conversationId);
}

bool
removeConversation(const std::string& accountId, const std::string& conversationId)
{
    if (auto acc = jami::Manager::instance().getAccount<jami::JamiAccount>(accountId))
        if (auto* convModule = acc->convModule(true))
            return convModule->removeConversation(conversationId);
    return false;
}

std::vector<std::string>
getConversations(const std::string& accountId)
{
    if (auto acc = jami::Manager::instance().getAccount<jami::JamiAccount>(accountId))
        if (auto* convModule = acc->convModule(true))
            return convModule->getConversations();
    return {};
}

std::vector<std::map<std::string, std::string>>
getActiveCalls(const std::string& accountId, const std::string& conversationId)
{
    if (auto acc = jami::Manager::instance().getAccount<jami::JamiAccount>(accountId))
        if (auto* convModule = acc->convModule(true))
            return convModule->getActiveCalls(conversationId);
    return {};
}

std::vector<std::map<std::string, std::string>>
getConversationRequests(const std::string& accountId)
{
    if (auto acc = jami::Manager::instance().getAccount<jami::JamiAccount>(accountId))
        if (auto* convModule = acc->convModule(true))
            return convModule->getConversationRequests();
    return {};
}

void
updateConversationInfos(const std::string& accountId,
                        const std::string& conversationId,
                        const std::map<std::string, std::string>& infos)
{
    if (auto acc = jami::Manager::instance().getAccount<jami::JamiAccount>(accountId))
        if (auto* convModule = acc->convModule(true))
            convModule->updateConversationInfos(conversationId, infos);
}

std::map<std::string, std::string>
conversationInfos(const std::string& accountId, const std::string& conversationId)
{
    if (auto acc = jami::Manager::instance().getAccount<jami::JamiAccount>(accountId))
        if (auto* convModule = acc->convModule(true))
            return convModule->conversationInfos(conversationId);
    return {};
}

void
setConversationPreferences(const std::string& accountId,
                           const std::string& conversationId,
                           const std::map<std::string, std::string>& prefs)
{
    if (auto acc = jami::Manager::instance().getAccount<jami::JamiAccount>(accountId))
        if (auto* convModule = acc->convModule(true))
            convModule->setConversationPreferences(conversationId, prefs);
}

std::map<std::string, std::string>
getConversationPreferences(const std::string& accountId, const std::string& conversationId)
{
    if (auto acc = jami::Manager::instance().getAccount<jami::JamiAccount>(accountId))
        if (auto* convModule = acc->convModule(true))
            return convModule->getConversationPreferences(conversationId);
    return {};
}

// Member management
void
addConversationMember(const std::string& accountId, const std::string& conversationId, const std::string& contactUri)
{
    if (auto acc = jami::Manager::instance().getAccount<jami::JamiAccount>(accountId))
        if (auto* convModule = acc->convModule(true)) {
            dht::InfoHash h(contactUri);
            if (not h) {
                JAMI_ERROR("addConversationMember: invalid contact URI `{}`", contactUri);
                return;
            }
            convModule->addConversationMember(conversationId, h);
        }
}

void
removeConversationMember(const std::string& accountId, const std::string& conversationId, const std::string& contactUri)
{
    if (auto acc = jami::Manager::instance().getAccount<jami::JamiAccount>(accountId))
        if (auto* convModule = acc->convModule(true)) {
            dht::InfoHash h(contactUri);
            if (not h) {
                JAMI_ERROR("removeConversationMember: invalid contact URI `{}`", contactUri);
                return;
            }
            convModule->removeConversationMember(conversationId, h);
        }
}

std::vector<std::map<std::string, std::string>>
getConversationMembers(const std::string& accountId, const std::string& conversationId)
{
    if (auto acc = jami::Manager::instance().getAccount<jami::JamiAccount>(accountId))
        if (auto* convModule = acc->convModule(true))
            return convModule->getConversationMembers(conversationId, true);
    return {};
}

// Message send/load
void
sendMessage(const std::string& accountId,
            const std::string& conversationId,
            const std::string& message,
            const std::string& commitId,
            const int32_t& flag)
{
    if (auto acc = jami::Manager::instance().getAccount<jami::JamiAccount>(accountId))
        if (auto* convModule = acc->convModule(true)) {
            if (flag == 0 /* Reply or simple commit */) {
                convModule->sendMessage(conversationId, message, commitId);
            } else if (flag == 1 /* message edition */) {
                convModule->editMessage(conversationId, message, commitId);
            } else if (flag == 2 /* reaction */) {
                convModule->reactToMessage(conversationId, message, commitId);
            }
        }
}

std::string
sendMessageWithId(const std::string& accountId,
                  const std::string& conversationId,
                  const std::string& message,
                  const std::string& replyTo,
                  const std::string& syblTopic)
{
    if (!jami::isValidSybLTopicId(syblTopic, true))
        return {};
    auto acc = jami::Manager::instance().getAccount<jami::JamiAccount>(accountId);
    auto* convModule = acc ? acc->convModule(true) : nullptr;
    if (!convModule)
        return {};
    auto committed = std::make_shared<std::promise<std::string>>();
    auto result = committed->get_future();
    convModule->createCommit(conversationId,
                             jami::CommitMessage::text(message, replyTo, syblTopic),
                             true,
                             [committed](const std::string& id) { committed->set_value(id); });
    return result.wait_for(std::chrono::seconds(30)) == std::future_status::ready
               ? result.get()
               : std::string {};
}

std::string
sendSybLTopicEventWithId(const std::string& accountId,
                         const std::string& conversationId,
                         const std::string& body)
{
    if (!jami::isValidSybLTopicEventBody(body))
        return {};
    auto acc = jami::Manager::instance().getAccount<jami::JamiAccount>(accountId);
    auto* convModule = acc ? acc->convModule(true) : nullptr;
    if (!convModule)
        return {};
    auto committed = std::make_shared<std::promise<std::string>>();
    auto result = committed->get_future();
    convModule->createCommit(conversationId,
                             jami::CommitMessage::syblDmTopic(body),
                             true,
                             [committed](const std::string& id) { committed->set_value(id); });
    return result.wait_for(std::chrono::seconds(30)) == std::future_status::ready
               ? result.get()
               : std::string {};
}

std::string
sendSybLMessage(const std::string& accountId, const std::string& conversationId,
               const std::string& mimeType, const std::string& body,
               const std::string& replyTo, const std::string& syblTopic,
               const std::string& syblRoom, const std::string& operationId)
{
    if (!jami::isValidSybLOperationId(operationId)
        || !jami::isValidSybLTopicId(syblTopic, true)
        || !jami::isValidSybLRoomId(syblRoom, true)
        || (!syblTopic.empty() && !syblRoom.empty()) || replyTo.size() > 1024)
        return "failed-before-commit";
    if (mimeType == jami::CommitType::TEXT) {
        if (body.empty() || body.size() > 3 * 64 * 1024) return "failed-before-commit";
    } else if (mimeType == jami::CommitType::SYBL_STICKER) {
        if (!jami::isValidSybLStickerBody(body) || !replyTo.empty()) return "failed-before-commit";
    } else {
        return "failed-before-commit";
    }
    auto acc = jami::Manager::instance().getAccount<jami::JamiAccount>(accountId);
    auto* module = acc ? acc->convModule(true) : nullptr;
    if (!module) return "failed-before-commit";
    jami::CommitMessage message;
    message.type = mimeType;
    message.body = body;
    message.replyTo = replyTo;
    message.syblTopic = syblTopic;
    message.syblRoom = syblRoom;
    message.syblOperation = operationId;
    try {
        module->createCommit(conversationId, std::move(message), true,
            [accountId, conversationId, operationId](const std::string& id) {
                jami::emitSignal<ConversationSignal::SybLMessageCompleted>(
                    accountId, conversationId, operationId, id);
            });
        return "pending";
    } catch (...) {
        // An exception after issue is not evidence that no commit was made.
        return "unknown";
    }
}

std::string
sendSybLReaction(const std::string& accountId, const std::string& conversationId,
                 const std::string& messageId, const std::string& removedId,
                 const std::string& emoji, const std::string& topic,
                 const std::string& room, const std::string& operationId)
{
    auto acc = jami::Manager::instance().getAccount<jami::JamiAccount>(accountId);
    auto* module = acc ? acc->convModule(true) : nullptr;
    if (!module) return "failed-before-commit";
    try {
        const auto admitted = module->createOwnedReaction(conversationId, messageId, removedId,
            emoji, topic, room, operationId,
            [accountId, conversationId, operationId](const std::string& commitId) {
                jami::emitSignal<ConversationSignal::SybLMessageCompleted>(
                    accountId, conversationId, operationId, commitId);
            });
        return admitted ? "pending" : "failed-before-commit";
    } catch (...) {
        return "unknown";
    }
}

uint32_t
loadSybLMessage(const std::string& accountId,
                const std::string& conversationId,
                const std::string& messageId)
{
    if (accountId.empty())
        return 0;
    if (auto account = jami::Manager::instance().getAccount<jami::JamiAccount>(accountId))
        if (auto* module = account->convModule(true))
            return module->loadMessageSnapshot(conversationId, messageId);
    return 0;
}

uint32_t
loadConversation(const std::string& accountId,
                 const std::string& conversationId,
                 const std::string& fromMessage,
                 size_t n)
{
    if (auto acc = jami::Manager::instance().getAccount<jami::JamiAccount>(accountId))
        if (auto* convModule = acc->convModule(true))
            return convModule->loadConversation(conversationId, fromMessage, n);
    return 0;
}

uint32_t
loadSwarmUntil(const std::string& accountId,
               const std::string& conversationId,
               const std::string& fromMessage,
               const std::string& toMessage)
{
    if (auto acc = jami::Manager::instance().getAccount<jami::JamiAccount>(accountId))
        if (auto* convModule = acc->convModule(true))
            return convModule->loadSwarmUntil(conversationId, fromMessage, toMessage);
    return 0;
}

uint32_t
countInteractions(const std::string& accountId,
                  const std::string& conversationId,
                  const std::string& toId,
                  const std::string& fromId,
                  const std::string& authorUri)
{
    if (auto acc = jami::Manager::instance().getAccount<jami::JamiAccount>(accountId))
        if (auto* convModule = acc->convModule(true))
            return convModule->countInteractions(conversationId, toId, fromId, authorUri);
    return 0;
}

void
clearCache(const std::string& accountId, const std::string& conversationId)
{
    if (auto acc = jami::Manager::instance().getAccount<jami::JamiAccount>(accountId))
        if (auto* convModule = acc->convModule(true))
            convModule->clearCache(conversationId);
}

uint32_t
searchConversation(const std::string& accountId,
                   const std::string& conversationId,
                   const std::string& author,
                   const std::string& lastId,
                   const std::string& regexSearch,
                   const std::string& type,
                   const int64_t& after,
                   const int64_t& before,
                   const uint32_t& maxResult,
                   const int32_t& flag)
{
    uint32_t res = 0;
    jami::Filter filter {author, lastId, regexSearch, type, after, before, maxResult, flag != 0};
    for (const auto& accId : jami::Manager::instance().getAccountList()) {
        if (!accountId.empty() && accId != accountId)
            continue;
        if (auto acc = jami::Manager::instance().getAccount<jami::JamiAccount>(accId)) {
            // Zero means no account accepted the request; never assign it to
            // an actual worker whose callbacks need to be correlated.
            res = std::uniform_int_distribution<uint32_t>(1)(acc->rand);
            if (auto* convModule = acc->convModule(true)) {
                convModule->search(res, conversationId, filter);
            } else {
                jami::emitSignal<ConversationSignal::MessagesFound>(
                    res, accId, std::string {},
                    std::vector<std::map<std::string, std::string>> {
                        {{"sybl-search-error", "unavailable"}}});
                jami::emitSignal<ConversationSignal::MessagesFound>(
                    res, accId, std::string {},
                    std::vector<std::map<std::string, std::string>> {});
            }
        }
    }
    return res;
}

void
reloadConversationsAndRequests(const std::string& accountId)
{
    if (auto acc = jami::Manager::instance().getAccount<jami::JamiAccount>(accountId)) {
        acc->reloadContacts();
        if (auto* convModule = acc->convModule(true)) {
            convModule->reloadRequests();
            convModule->loadConversations();
        }
    }
}

} // namespace libjami
