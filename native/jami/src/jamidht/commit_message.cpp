/*
 * Copyright (C) 2004-2026 Savoir-faire Linux Inc.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

#include "commit_message.h"

#include "string_utils.h"

#include <algorithm>

namespace jami {

Json::Value
CommitMessage::toJson() const
{
    Json::Value value;
    value[CommitKey::TYPE] = type;
    if (type == CommitType::TEXT || type == CommitType::EDITED_MESSAGE
        || type == CommitType::SYBL_DM_TOPIC || type == CommitType::SYBL_STICKER) {
        value[CommitKey::BODY] = body;
    }
    if (!syblTopic.empty()) {
        value[CommitKey::SYBL_TOPIC_V1] = syblTopic;
    }
    if (!syblRoom.empty()) value[CommitKey::SYBL_ROOM_V1] = syblRoom;
    if (!syblMedia.empty()) value[CommitKey::SYBL_MEDIA_V1] = syblMedia;
    if (!syblOperation.empty()) value[CommitKey::SYBL_OP_V1] = syblOperation;
    if (!replyTo.empty()) {
        value[CommitKey::REPLY_TO] = replyTo;
    }
    if (!reactTo.empty()) {
        value[CommitKey::REACT_TO] = reactTo;
    }
    if (!editedId.empty()) {
        value[CommitKey::EDIT] = editedId;
    }
    if (!action.empty()) {
        value[CommitKey::ACTION] = action;
    }
    if (!uri.empty()) {
        value[CommitKey::URI] = uri;
    }
    if (!device.empty()) {
        value[CommitKey::DEVICE] = device;
    }
    if (!confId.empty()) {
        value[CommitKey::CONF_ID] = confId;
    }
    if (!to.empty()) {
        value[CommitKey::TO] = to;
    }
    if (!reason.empty()) {
        value[CommitKey::REASON] = reason;
    }
    if (!duration.empty()) {
        value[CommitKey::DURATION] = duration;
    }
    if (type == CommitType::DATA_TRANSFER) {
        value[CommitKey::TID] = tid;
    }
    if (!displayName.empty()) {
        value[CommitKey::DISPLAY_NAME] = displayName;
    }
    if (totalSize >= 0) {
        value[CommitKey::TOTAL_SIZE] = std::to_string(totalSize);
    }
    if (!sha3sum.empty()) {
        value[CommitKey::SHA3SUM] = sha3sum;
    }
    if (mode >= 0) {
        value[CommitKey::MODE] = mode;
    }
    if (!invited.empty()) {
        value[CommitKey::INVITED] = invited;
    }
    return value;
}

std::string
CommitMessage::toString() const
{
    if (type == CommitType::MERGE) {
        return body;
    }
    return json::toString(toJson());
}

std::optional<CommitMessage>
CommitMessage::fromString(const std::string& str)
{
    if (str.starts_with("Merge commit")) {
        CommitMessage msg;
        msg.type = CommitType::MERGE;
        msg.body = str;
        return msg;
    }
    Json::Value value;
    if (!json::parse(str, value) || !value.isObject()) {
        return std::nullopt;
    }

    CommitMessage msg;
    try {
        msg.type = value.get(CommitKey::TYPE, "").asString();
        msg.body = value.get(CommitKey::BODY, "").asString();
        msg.replyTo = value.get(CommitKey::REPLY_TO, "").asString();
        msg.reactTo = value.get(CommitKey::REACT_TO, "").asString();
        msg.editedId = value.get(CommitKey::EDIT, "").asString();
        msg.action = value.get(CommitKey::ACTION, "").asString();
        msg.uri = value.get(CommitKey::URI, "").asString();
        msg.device = value.get(CommitKey::DEVICE, "").asString();
        msg.confId = value.get(CommitKey::CONF_ID, "").asString();
        msg.to = value.get(CommitKey::TO, "").asString();
        msg.reason = value.get(CommitKey::REASON, "").asString();
        msg.duration = value.get(CommitKey::DURATION, "").asString();
        msg.tid = value.get(CommitKey::TID, "").asString();
        msg.displayName = value.get(CommitKey::DISPLAY_NAME, "").asString();
        msg.totalSize = to_int<int64_t>(value.get(CommitKey::TOTAL_SIZE, "-1").asString());
        msg.sha3sum = value.get(CommitKey::SHA3SUM, "").asString();
        msg.mode = value.get(CommitKey::MODE, -1).asInt();
        msg.invited = value.get(CommitKey::INVITED, "").asString();
        msg.syblTopic = value.get(CommitKey::SYBL_TOPIC_V1, "").asString();
        msg.syblRoom = value.get(CommitKey::SYBL_ROOM_V1, "").asString();
        msg.syblMedia = value.get(CommitKey::SYBL_MEDIA_V1, "").asString();
        msg.syblOperation = value.get(CommitKey::SYBL_OP_V1, "").asString();
    } catch (const std::exception&) {
        // Parser exceptions can embed the offending value. Neither the raw
        // commit nor exception text is safe diagnostic material.
        JAMI_ERROR("Invalid commit message field type");
        return std::nullopt;
    }
    return msg;
}

bool
isValidSybLTopicId(std::string_view topicId, bool allowEmpty)
{
    if (topicId.empty())
        return allowEmpty;
    if (topicId == "main")
        return true;
    if (topicId.size() != 32)
        return false;
    return std::all_of(topicId.begin(), topicId.end(), [](char value) {
        return (value >= '0' && value <= '9') || (value >= 'a' && value <= 'f');
    });
}

bool
isValidSybLOperationId(std::string_view value)
{
    return value.size() == 32 && std::all_of(value.begin(), value.end(), [](char c) {
        return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
    });
}

bool
isValidSybLRoomId(std::string_view value, bool allowEmpty)
{
    if (value.empty()) return allowEmpty;
    if (value.size() > 32 || value.front() == '-') return false;
    return std::all_of(value.begin(), value.end(), [](char c) {
        return (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-';
    });
}

bool
isValidSybLStickerBody(std::string_view body)
{
    if (body.empty() || body.size() > 1024) return false;
    Json::Value value;
    if (!json::parse(body, value) || !value.isObject() || value.size() != 3
        || value["v"].type() != Json::intValue || value["v"].asInt() != 1
        || !value["assetId"].isString() || !value["presentation"].isString()) return false;
    const auto id = value["assetId"].asString();
    const auto mode = value["presentation"].asString();
    if (id.empty() || id.size() > 128 || (mode != "inline" && mode != "hologram")) return false;
    bool separator = true;
    for (char c : id) {
        if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) {
            separator = false;
        } else if ((c == '.' || c == '-') && !separator) {
            separator = true;
        } else {
            return false;
        }
    }
    return !separator;
}

bool
isValidSybLMediaBody(std::string_view body)
{
    if (body.empty() || body.size() > 1024) return false;
    Json::Value value;
    if (!json::parse(body, value) || !value.isObject()
        || value["v"].type() != Json::intValue || value["v"].asInt() != 1 || !value["kind"].isString()) return false;
    if (value["kind"].asString() == "voice") {
        return value.size() == 5 && value["codec"].isString() && value["codec"].asString() == "aac-lc"
            && value["container"].isString() && value["container"].asString() == "m4a"
            && (value["durationMs"].type() == Json::intValue) && value["durationMs"].asInt() >= 300
            && value["durationMs"].asInt() <= 120000;
    }
    if (value["kind"].asString() != "gif" || value.size() != 6
        || value["width"].type() != Json::intValue || value["height"].type() != Json::intValue
        || value["frames"].type() != Json::intValue || value["cycleMs"].type() != Json::intValue) return false;
    const auto width = value["width"].asInt();
    const auto height = value["height"].asInt();
    const auto frames = value["frames"].asInt();
    const auto cycle = value["cycleMs"].asInt();
    return width >= 1 && width <= 512 && height >= 1 && height <= 512
        && width <= height * 4 && height <= width * 4 && frames >= 1 && frames <= 120
        && width * height * frames <= 16777216 && cycle >= frames * 20 && cycle <= 10000;
}

bool
isValidSybLTopicEventBody(std::string_view body)
{
    if (body.empty() || body.size() > 4096)
        return false;
    Json::Value value;
    if (!json::parse(body, value) || !value.isObject() || value.size() > 7
        || !value.isMember("v") || !value["v"].isInt() || value["v"].asInt() != 1
        || !value.isMember("op") || !value["op"].isString()
        || !value.isMember("topic") || !value["topic"].isString()
        || !value.isMember("revision") || !value["revision"].isInt()
        || value["revision"].asInt() < 1) {
        return false;
    }
    const auto operation = value["op"].asString();
    const auto topicId = value["topic"].asString();
    if (operation == "read") {
        return value.size() == 5 && isValidSybLTopicId(topicId)
               && value.isMember("message") && value["message"].isString()
               && !value["message"].asString().empty() && value["message"].asString().size() <= 128;
    }
    if (operation == "left")
        return value.size() == 4 && topicId == "main" && value["revision"].asInt() == 1;
    if (!isValidSybLTopicId(topicId) || topicId == "main")
        return false;
    if (operation == "create") {
        return value.size() == 6 && value.isMember("name") && value["name"].isString()
               && !value["name"].asString().empty() && value["name"].asString().size() <= 64
               && value.isMember("order") && value["order"].isInt() && value["order"].asInt() >= 0;
    }
    if (operation == "rename") {
        return value.size() == 5 && value.isMember("name") && value["name"].isString()
               && !value["name"].asString().empty() && value["name"].asString().size() <= 64;
    }
    if (operation == "archive")
        return value.size() == 5 && value.isMember("archived") && value["archived"].isBool();
    return false;
}

} // namespace jami
