// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include "commit_message.h"
#include <algorithm>
#include <optional>
#include <string_view>

namespace jami {
inline bool reactionCommitId(std::string_view value)
{
    return value.size() == 40 && std::all_of(value.begin(), value.end(), [](char c) {
        return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
    });
}

inline bool syblReactionEmoji(std::string_view value)
{
    return value == "\xf0\x9f\x91\x8d" || value == "\xe2\x9d\xa4\xef\xb8\x8f"
        || value == "\xf0\x9f\x98\x82" || value == "\xf0\x9f\x98\xae"
        || value == "\xf0\x9f\x98\xa2" || value == "\xf0\x9f\x99\x8f";
}

inline std::string reactionTargetRoom(const CommitMessage& target)
{
    if (!target.syblRoom.empty()) return target.syblRoom;
    if (target.type == CommitType::TEXT && target.body.compare(0, 2, "[#") == 0) {
        const auto end = target.body.find("] ", 2);
        if (end != std::string::npos && end <= 34) {
            const auto room = target.body.substr(2, end - 2);
            if (isValidSybLRoomId(room, false)) return room;
        }
    }
    return "general";
}

inline bool validOwnedReactionRequest(const std::string& targetId,
    const std::string& removedId, const std::string& emoji,
    const std::string& topic, const std::string& room, const std::string& operation)
{
    return reactionCommitId(targetId) && isValidSybLOperationId(operation)
        && (topic.empty() != room.empty()) && isValidSybLTopicId(topic, true)
        && isValidSybLRoomId(room, true)
        && (removedId.empty() ? syblReactionEmoji(emoji)
                              : (reactionCommitId(removedId) && removedId != targetId && emoji.empty()));
}

// The caller supplies authenticated commits from this exact conversation and
// checks current membership. No sender-supplied quote or claimed author is used.
inline std::optional<CommitMessage> prepareOwnedReaction(
    const CommitMessage& target, const std::string& targetId,
    const CommitMessage* removed, const std::string& removedId,
    const std::string& removedAuthor, const std::string& localAuthor,
    const std::string& emoji, const std::string& topic, const std::string& room,
    const std::string& operation)
{
    if (!validOwnedReactionRequest(targetId, removedId, emoji, topic, room, operation)
        || !reactionCommitId(localAuthor) || !target.reactTo.empty() || !target.editedId.empty()
        || (target.type != CommitType::TEXT && target.type != CommitType::DATA_TRANSFER
            && target.type != CommitType::SYBL_STICKER)) return std::nullopt;
    if (!topic.empty()) {
        if (!target.syblRoom.empty() || topic != (target.syblTopic.empty() ? "main" : target.syblTopic))
            return std::nullopt;
    } else if (!target.syblTopic.empty() || room != reactionTargetRoom(target)) {
        return std::nullopt;
    }
    CommitMessage result;
    if (removedId.empty()) {
        if (removed || !syblReactionEmoji(emoji)) return std::nullopt;
        result = CommitMessage::reaction(emoji, targetId);
    } else {
        if (!removed || !reactionCommitId(removedId) || removedId == targetId || !emoji.empty()
            || removedAuthor != localAuthor || removed->type != CommitType::TEXT
            || removed->reactTo != targetId || !removed->editedId.empty()) return std::nullopt;
        result = CommitMessage::edit("", removedId);
        result.syblTopic = removed->syblTopic;
        result.syblRoom = removed->syblRoom;
    }
    result.syblOperation = operation;
    return result;
}
} // namespace jami
