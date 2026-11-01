/* SPDX-License-Identifier: GPL-3.0-or-later */
#pragma once

#include <functional>
#include <mutex>
#include <utility>

namespace jami {

// A DHT run owns one certificate-publication sequence. Duplicate/late callbacks
// cannot start another retry, complete twice, or revive a retired account run.
class IdentityAnnouncement
{
public:
    static constexpr unsigned maximumRetries = 4;
    enum class Action { Ignore, Published, Retry, Exhausted };
    struct Outcome {
        Action action {Action::Ignore};
        unsigned attempt {};
    };

    // One-shot observation of a real failed publication completion in the
    // isolated wire fixture. It cannot turn a failure into publication.
    static void setRetryHookForTesting(std::function<void()> hook)
    {
        std::lock_guard lock(retryHookMutex());
        retryHook() = std::move(hook);
    }

    Outcome finish(unsigned attempt, bool published)
    {
        std::unique_lock lock(mutex_);
        if (retired_ || finished_ || attempt != attempt_)
            return {};
        if (published) {
            finished_ = true;
            return {Action::Published, attempt};
        }
        if (attempt == maximumRetries) {
            finished_ = true;
            return {Action::Exhausted, attempt};
        }
        const auto next = ++attempt_;
        lock.unlock();
        std::function<void()> hook;
        {
            std::lock_guard hookLock(retryHookMutex());
            hook = std::exchange(retryHook(), {});
        }
        if (hook)
            hook();
        return {Action::Retry, next};
    }

    void retire()
    {
        std::lock_guard lock(mutex_);
        retired_ = true;
    }

private:
    static std::mutex& retryHookMutex()
    {
        static std::mutex mutex;
        return mutex;
    }
    static std::function<void()>& retryHook()
    {
        static std::function<void()> hook;
        return hook;
    }
    std::mutex mutex_;
    unsigned attempt_ {};
    bool finished_ {};
    bool retired_ {};
};

} // namespace jami
