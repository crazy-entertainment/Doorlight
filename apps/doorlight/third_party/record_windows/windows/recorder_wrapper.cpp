#include "recorder_wrapper.h"

#include <flutter/standard_method_codec.h>

using namespace flutter;

namespace record_windows
{
	RecorderWrapper::RecorderWrapper(BinaryMessenger* messenger, const std::string& recorderId, PlatformThread& platform)
		: m_recorderId(recorderId), m_platform(platform),
		m_dispatcher(std::make_shared<RecorderDispatcher>())
	{
		m_captureLifetime->owner = this;
		m_stateEventHandler = new EventStreamHandler<>();
		m_stateEventChannel = std::make_unique<EventChannel<EncodableValue>>(
			messenger, "com.llfbandit.record/events/" + recorderId,
			&StandardMethodCodec::GetInstance());
		m_stateEventChannel->SetStreamHandler(
			std::unique_ptr<StreamHandler<EncodableValue>>(m_stateEventHandler));

		m_configChangedChannel = std::make_unique<MethodChannel<EncodableValue>>(
			messenger, "com.llfbandit.record/configChanged/" + recorderId,
			&StandardMethodCodec::GetInstance());

		auto alive = m_alive;
		auto* stateHandler = m_stateEventHandler;
		auto* configChannel = m_configChangedChannel.get();

		RecorderCallbacks callbacks;
		callbacks.onState = [this, alive, stateHandler](RecordState state) {
			m_platform.Post([alive, stateHandler, state] {
				if (*alive) stateHandler->Success(std::make_unique<EncodableValue>(state));
			});
		};
		callbacks.onConfigChanged = [this, alive, configChannel](const RecordConfig& cfg) {
			EncodableMap args = cfg.rawArgs;
			args[EncodableValue("bitRate")]     = EncodableValue(cfg.bitRate);
			args[EncodableValue("sampleRate")]  = EncodableValue(cfg.sampleRate);
			args[EncodableValue("numChannels")] = EncodableValue(cfg.numChannels);
			m_platform.Post([alive, configChannel, args = std::move(args)]() mutable {
				if (*alive) configChannel->InvokeMethod("onConfigChanged",
					std::make_unique<EncodableValue>(EncodableMap(std::move(args))));
			});
		};

		m_recorder = std::make_unique<Recorder>(m_dispatcher, std::move(callbacks));
	}

	RecorderWrapper::~RecorderWrapper()
	{
		{ std::lock_guard<std::mutex> lock(m_captureLifetime->mutex); m_captureLifetime->owner = nullptr; }
		Teardown(nullptr);
		m_dispatcher->Join();
		*m_alive = false;
	}

	// Tears down on the recorder's thread; a no-op once that already happened.
	void RecorderWrapper::Teardown(Reply done)
	{
		bool posted = m_dispatcher->Post([this, done] {
			const HRESULT result = m_recorder->Dispose();
			ReportRelease(result);
			// Answered once the thread has stopped, so the join that follows never waits.
			std::function<void()> onExit;
			if (done) onExit = [this, done, result] { m_platform.Post([done, result] { done(result); }); };
			m_dispatcher->Shutdown(std::move(onExit));
		});
		// Already disposed: still answer so the Dart future settles.
		if (!posted && done) m_platform.Post([done] { done(E_ABORT); });
	}

	// Runs block on the dispatcher; its value reaches reply on the platform thread.
	template <typename R, typename F>
	void RecorderWrapper::Run(std::function<void(R)> reply, R fallback, F&& block)
	{
		bool posted = m_dispatcher->Post([this, reply, block = std::forward<F>(block)]() mutable {
			R value = block();
			m_platform.Post([reply, value] { reply(value); });
		});
		if (!posted) m_platform.Post([reply, fallback] { reply(fallback); });
	}

	void RecorderWrapper::Start(std::unique_ptr<RecordConfig> config, std::wstring path, Reply reply)
	{
		Run(std::move(reply), E_ABORT, [this, config = std::move(config), path]() mutable {
			if (!config) return E_INVALIDARG;
			if (m_captureTicket) return E_ACCESSDENIED;
			const auto lifetime = m_captureLifetime;
			m_captureTicket = SybLRecordingBridge::Get().Begin(m_recorderId, *config, path,
				[lifetime](NativeRecordingLease::Completion done) {
					std::lock_guard<std::mutex> lock(lifetime->mutex);
					if (lifetime->owner) lifetime->owner->StopForAuthority(std::move(done));
					else done(false);
				});
			if (!m_captureTicket) return E_ACCESSDENIED;
			if (!SybLRecordingBridge::Get().Current(m_captureTicket)) { ReportRelease(S_OK); return E_ABORT; }
			const HRESULT result = m_recorder->Start(std::move(config), path);
			if (FAILED(result)) ReportRelease(m_recorder->Stop().hr);
			else if (!SybLRecordingBridge::Get().Current(m_captureTicket)) {
				ReportRelease(m_recorder->Stop().hr);
				return E_ABORT;
			}
			return result;
		});
	}

	void RecorderWrapper::StartStream(std::unique_ptr<RecordConfig> config, Reply reply)
	{
		Run(std::move(reply), E_ABORT, [this, config = std::move(config)]() mutable {
			return E_ACCESSDENIED; // Messaging grants authorize only a bounded M4A file.
		});
	}

	void RecorderWrapper::Pause(Reply reply)
	{
		Run(std::move(reply), E_ABORT, [this] { return m_recorder->Pause(); });
	}

	void RecorderWrapper::Resume(Reply reply)
	{
		Run(std::move(reply), E_ABORT, [this] {
			return SybLRecordingBridge::Get().Current(m_captureTicket) ? m_recorder->Resume() : E_ACCESSDENIED;
		});
	}

	void RecorderWrapper::Stop(std::function<void(StopResult)> reply)
	{
		Run(std::move(reply), StopResult{ E_ABORT, std::wstring() }, [this] {
			const auto result = m_recorder->Stop(); ReportRelease(result.hr); return result;
		});
	}

	void RecorderWrapper::Cancel(Reply reply)
	{
		Run(std::move(reply), E_ABORT, [this] {
			const auto result = m_recorder->Cancel(); ReportRelease(result); return result;
		});
	}

	void RecorderWrapper::IsPaused(std::function<void(bool)> reply)
	{
		Run(std::move(reply), false, [this] { return m_recorder->IsPaused(); });
	}

	void RecorderWrapper::IsRecording(std::function<void(bool)> reply)
	{
		Run(std::move(reply), false, [this] { return m_recorder->IsRecording(); });
	}

	void RecorderWrapper::GetAmplitude(std::function<void(std::map<std::string, double>)> reply)
	{
		Run(std::move(reply), std::map<std::string, double>(), [this] { return m_recorder->GetAmplitude(); });
	}

	void RecorderWrapper::ReportRelease(HRESULT result) {
		if (!m_captureTicket) return;
		SybLRecordingBridge::Get().Released(m_captureTicket, SUCCEEDED(result));
		if (SUCCEEDED(result)) m_captureTicket.reset();
	}

	void RecorderWrapper::StopForAuthority(NativeRecordingLease::Completion done) {
		if (!m_dispatcher->Post([this, done] {
			const auto result = m_recorder->Stop();
			ReportRelease(result.hr);
			done(SUCCEEDED(result.hr));
		})) done(false);
	}

	void RecorderWrapper::Dispose(Reply reply)
	{
		auto alive = m_alive;
		Teardown([this, alive, reply](HRESULT result) {
			// Not in the destructor: at engine shutdown the messenger is already detached.
			if (*alive)
			{
				m_stateEventChannel->SetStreamHandler(nullptr);
			}
			reply(result);
		});
	}
}
