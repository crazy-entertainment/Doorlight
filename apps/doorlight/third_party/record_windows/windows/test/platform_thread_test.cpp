#include "platform_thread.h"

#include <gtest/gtest.h>

#include <atomic>
#include <cwchar>
#include <thread>
#include <vector>

namespace record_windows
{
	constexpr UINT kRunDelegateMessage = WM_USER + 101;
	constexpr wchar_t kPlatformThreadWindowClass[] = L"record_windows.PlatformThread";

	// Stands in for the runner's message loop.
	class PlatformThreadTest : public ::testing::Test
	{
	protected:
		// Tests count delivered messages, so start from an empty queue.
		void SetUp() override { PumpMessages(); }

		// DWM can queue non-client notifications to the message-only window; count only its wake.
		static int PumpMessages()
		{
			int count = 0;
			MSG msg;
			while (PeekMessage(&msg, nullptr, 0, 0, PM_REMOVE))
			{
				wchar_t className[128]{};
				if (msg.hwnd && msg.message == kRunDelegateMessage &&
					GetClassNameW(msg.hwnd, className, ARRAYSIZE(className)) > 0 &&
					std::wcscmp(className, kPlatformThreadWindowClass) == 0)
					count++;
				DispatchMessage(&msg);
			}
			return count;
		}
	};

	TEST_F(PlatformThreadTest, RunsCallbacksOnlyWhenPumped)
	{
		PlatformThread platform;
		bool ran = false;

		platform.Post([&ran] { ran = true; });
		EXPECT_FALSE(ran);

		PumpMessages();
		EXPECT_TRUE(ran);
	}

	// Recorder replies and state events reach Dart in dispatch order.
	TEST_F(PlatformThreadTest, RunsCallbacksInOrder)
	{
		PlatformThread platform;
		std::vector<int> order;

		for (int i = 0; i < 16; i++) platform.Post([&order, i] { order.push_back(i); });
		PumpMessages();

		ASSERT_EQ(order.size(), 16u);
		for (int i = 0; i < 16; i++) EXPECT_EQ(order[i], i);
	}

	// One wake-up covers the whole queue, however many callbacks are waiting.
	TEST_F(PlatformThreadTest, CoalescesWakeUps)
	{
		PlatformThread platform;
		int ran = 0;

		for (int i = 0; i < 16; i++) platform.Post([&ran] { ran++; });

		EXPECT_EQ(PumpMessages(), 1);
		EXPECT_EQ(ran, 16);
	}

	TEST_F(PlatformThreadTest, CountsOnlyPlatformThreadWakeMessages)
	{
		PlatformThread platform;
		int ran = 0;

		platform.Post([&ran] { ran++; });
		ASSERT_TRUE(PostThreadMessageW(GetCurrentThreadId(), WM_APP + 1, 0, 0));
		ASSERT_TRUE(PostThreadMessageW(GetCurrentThreadId(), kRunDelegateMessage, 0, 0));

		EXPECT_EQ(PumpMessages(), 1);
		EXPECT_EQ(ran, 1);
		EXPECT_EQ(PumpMessages(), 0);
	}

	// Without a re-arm, everything posted after the first drain would strand.
	TEST_F(PlatformThreadTest, ReArmsAfterDraining)
	{
		PlatformThread platform;
		int ran = 0;

		platform.Post([&ran] { ran++; });
		ASSERT_EQ(PumpMessages(), 1);
		ASSERT_EQ(ran, 1);

		platform.Post([&ran] { ran++; });
		EXPECT_EQ(PumpMessages(), 1);
		EXPECT_EQ(ran, 2);
	}

	// Replies and events arrive from every recorder's dispatcher thread.
	TEST_F(PlatformThreadTest, AcceptsPostsFromOtherThreads)
	{
		PlatformThread platform;
		std::atomic<int> ran{ 0 };

		std::vector<std::thread> posters;
		for (int i = 0; i < 4; i++)
		{
			posters.emplace_back([&platform, &ran] {
				for (int j = 0; j < 8; j++) platform.Post([&ran] { ran++; });
			});
		}
		for (auto& poster : posters) poster.join();

		PumpMessages();
		EXPECT_EQ(ran.load(), 32);
	}
}
