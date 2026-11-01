#ifndef RUNNER_JAMI_BRIDGE_H_
#define RUNNER_JAMI_BRIDGE_H_

#include <cstdint>
#include <functional>
#include <map>
#include <optional>
#include <string>
#include <vector>

#include "known_device_policy.h"

#include "remote_control_ice.h"

// Plain C++ surface for the libjami (Jami daemon) engine bridge.
//
// Deliberately free of BOTH libjami and Flutter headers: the Flutter runner translation units are compiled
// with /WX (warnings-as-errors) and _HAS_EXCEPTIONS=0 (see windows/CMakeLists.txt apply_standard_settings),
// whereas jami-core.lib was built the normal way (exceptions ENABLED). The daemon-ABI code therefore lives in
// jami_bridge.cpp inside its own static library (exceptions on, default warning level) and the runner only
// ever sees these plain declarations (std::string / std::map / std::function only — no flutter::EncodableValue,
// no libjami type, ever). The EncodableValue<->plain translation AND the platform-thread marshaling both live in
// the runner (jami_channels.{h,cpp}); this lib stays Flutter-agnostic and Looper-agnostic.
namespace jami_bridge {

struct HistorySearchHit {
  std::string messageId, authorId, channelId, snippet;
  int64_t timestampSeconds;
  bool file;
};
struct HistorySearchReply {
  std::string accountId, peerId, conversationId;
  uint64_t accountRevision, privacyEpoch;
  bool truncated;
  std::vector<HistorySearchHit> hits;
};
void SearchHistory(const std::string& accountId, const std::string& peerId,
                   const std::string& conversationId, const std::string& literal, int limit,
                   std::function<void(std::optional<HistorySearchReply>)> done);
void RetireHistorySearch(const std::string& accountId);
bool HistorySearchReplyCurrent(const HistorySearchReply& reply);

// A JSON-shaped value; the runner maps it one-to-one onto flutter::EncodableValue.
struct WireValue {
  enum class Kind { kNull, kBool, kInt, kString, kList, kMap } kind = Kind::kNull;
  bool boolean = false;
  int64_t integer = 0;
  std::string text;
  std::vector<WireValue> list;
  std::vector<std::string> keys;  // kMap: keys[i] names values[i]
  std::vector<WireValue> values;
};
// One selected search result's fresh folded message. `item` is the ordinary timeline projection of the
// daemon's answer. `done` runs exactly once, off the platform thread; nullopt means unavailable.
struct SearchMessageReply {
  std::string accountId, peerId, conversationId, messageId;
  uint64_t accountRevision, privacyEpoch;
  WireValue item;
};
void LoadSearchMessage(const std::string& accountId, const std::string& peerId,
                       const std::string& conversationId, const std::string& messageId,
                       std::function<void(std::optional<SearchMessageReply>)> done);
bool SearchMessageReplyCurrent(const SearchMessageReply& reply);

// Boot the libjami daemon once, OFF the UI thread (init -> registerSignalHandlers -> start, autoloading any
// persisted account). Returns immediately; the work runs on a single dedicated worker thread.
// SINGLE-SHOT for the process: a second Start() after Stop() is a no-op (the daemon's Manager is a process
// singleton that cannot be re-init'd once fini'd — see jami_bridge.cpp). One long-lived window is the model.
void Start();

// Shut the daemon down cleanly (fini) and join the worker. Safe to call on window destroy / app exit, and safe
// to call when Start() was never called. Does NOT re-arm Start().
void Stop();

void LoadSendJournal(std::function<void(bool, std::optional<std::string>)> done);
void SaveSendJournal(const std::string& source, std::function<void(bool)> done);
void DiscardUnissuedStage(const std::string& path, std::function<void(bool)> done);

// ---- identity (unit c slice a): mirrors Android JamiCore.ensureAccount / myJamiId ----

struct DevicePairingState {
  std::string flowToken, accountId, ownerAccountId, role, status = "unavailable";
  std::string uri, code, peerId, peerDeviceId, deviceId, error;
  uint32_t operation = 0;
  bool terminal = false, recovery = false, invalidCode = false;
};

// The Syb-L account identity surfaced to the onboarding UI.
struct Account {
  std::string status = "error";  // "ok", "noAccount", or fail-closed "error"
  std::string accountId;
  std::string jamiId;       // the 40-hex Account.username (empty until the daemon populates it)
  std::string displayName;
  std::string avatarBase64;
  std::string settingsDocument;
  std::string restoreToken;
  std::string recoveryReason;
  std::string recoveryOwnerAccountId;
  bool canDiscard = false;
  std::string backupSourceAccountId;
  bool settingsAlreadyNormalized = false;
  bool devicePairing = false;
  std::optional<DevicePairingState> pendingPairing;
  bool announced = false;
  std::string registration = "UNREGISTERED";
  bool enabled = true;      // the PERSISTED Account.enable — false = appear-offline survived a restart
};

struct DevicePairingReply {
  DevicePairingState state;
  std::optional<Account> preparedIdentity;
  std::string ownerAccountId;
  uint64_t ownerRevision = 0, privacyEpoch = 0;
  bool peerOutcomeUnconfirmed = false;
};
void DevicePairingCommand(const std::string& action, const std::string& flowToken,
    const std::string& targetAccount, const std::string& uri, const std::string& code,
    const std::string& settingsDocument, const std::map<std::string, std::string>& network,
    bool appearOffline, const std::string& expectedAccountId,
    std::function<void(const DevicePairingReply&)> done);
bool DevicePairingReplyCurrent(const DevicePairingReply& reply);
void RetireDevicePairing();

// A daemon event marshaled up to the runner. `type` mirrors the Android EventChannel contract
// ("registrationState", "deviceAnnounced", ...). `data` is a flat string map; booleans travel as "true"/"false"
// strings and the runner restores the real bool type per key (e.g. "announced") for the Dart contract.
// INVOKED ON A DAEMON THREAD — the runner's sink implementation owns the hop to the platform thread.
using EventSink = std::function<void(const std::string& type,
                                     const std::map<std::string, std::string>& data)>;

// Register/replace the event sink (nullptr clears it). On (re)attach with a non-null sink, the latest cached
// registrationState/deviceAnnounced are replayed — the daemon often reaches REGISTERED before Dart's
// EventChannel onListen attaches, and EventChannel drops pre-onListen events (mirrors JamiCore.setEventSink).
void SetEventSink(EventSink sink);
bool ReplayPendingNativeEvents();

enum class ControlSignalType {
  kMessage,
  kCallEnded,
  kSourceChanged,
  kTrustReduced,
};

// Native-only remote-control ingress. A kMessage signal has already passed the
// bridge's signaling-account == certificate-account == admitted-call-peer
// conjunction. The device id is certificate-derived. This callback is never
// routed through Flutter and is invoked outside bridge locks.
struct ControlSignal {
  ControlSignalType type = ControlSignalType::kMessage;
  std::string accountId;
  std::string callId;
  std::string controllerAccountId;
  std::string controllerDeviceId;
  std::string payload;
  std::string sourceUri;
  uint64_t sourceRevision = 0;
  int sourceWidth = 0;
  int sourceHeight = 0;
  bool screenActive = false;
  sybl::remote::LocalIcePath localIcePath =
      sybl::remote::LocalIcePath::kUnknown;
  bool localLanProven = false;
  std::string localJamiId;
};
// Trust reduction returns true only after native control and saved consent
// retirement. Other signal results are informational.
using ControlSink = std::function<bool(const ControlSignal&)>;
void SetControlSink(ControlSink sink);
// Revalidate receiver-owned state against a native certificate snapshot whose
// age is strictly below 250 ms. Renewal runs on the daemon worker; input never
// performs synchronous daemon queries while holding host/runtime locks.
// A previously authenticated packet is not proof that the call, friend,
// certificate device, source geometry, or local identity is still current.
bool RevalidateControlAuthority(const ControlSignal& expected);
void RefreshControllerClipboardAuthority(const std::string& call_id,
    const std::string& peer_account, std::function<void(bool)> done);
bool WithControllerClipboardAuthority(const std::string& account_id,
    const std::string& call_id, const std::string& peer_account,
    const std::string& peer_device, const std::function<bool()>& apply);
// Return the native local account only for the current trusted direct call.
std::string ControlAccountForCall(const std::string& call_id,
                                  const std::string& peer_account);
std::string ControlPeerNameForCall(const std::string& account_id,
                                  const std::string& call_id,
                                  const std::string& peer_account);

// Queue the retryable post-init reconciliation phase. Safe to call from the runner's exception-disabled frame;
// completed init, callback-registration, and start phases are independently latched and never repeated.
void RetryBoot() noexcept;
void ResetDoorlight(const std::string& accountId, std::function<void(bool)> done);

// Ensure an account exists (adopt the persisted one, else create a RING account with the DHT proxy enabled) and
// report it once its 40-hex id is known. Runs on the daemon worker (after boot, FIFO); `done` is invoked on the
// WORKER thread — the runner marshals the reply to the platform thread.
void EnsureAccount(const std::string& displayName, const std::string& preferredAccountId,
                   const std::string& preferredPeerId, bool createIfMissing,
                   std::function<void(const Account&)> done);

// The current account's 40-hex Jami id ("" if none). Runs on the daemon worker; `done` on the WORKER thread.
void MyJamiId(std::function<void(const std::string&)> done);

// Legacy pure read of the first friend in the current immutable routing snapshot. Kept for rolling compatibility;
// it never refreshes or mutates routing. Daemon worker; `done` on the WORKER thread.
void PeerId(std::function<void(const std::string&)> done);

struct Friend {
  std::string peerJamiId;
  bool confirmed = false;
  std::string conversationId;
  std::string displayName;
  std::string avatarBase64;
};
struct FriendList {
  uint64_t revision = 0;
  std::vector<Friend> friends;
  struct GroupMember {
    std::string peerJamiId;
    std::string role;
    std::string displayName;
    std::string avatarBase64;
  };
  struct Group {
    std::string conversationId;
    std::string title;
    std::string description;
    int64_t memberCount = 0;
    bool canManageMembers = false;
    std::string localRole;
    std::vector<GroupMember> members;
  };
  std::vector<Group> groups;
};
void ListFriends(std::function<void(const FriendList&)> done);
using KnownDevice = sybl::known_device::Device;
using KnownDeviceList = std::vector<KnownDevice>;
void ListKnownDevices(std::function<void(const KnownDeviceList&)> done);
using DeviceRevocationResult = sybl::known_device::RevocationResult;
void RevokeKnownDevice(const std::string& accountId, const std::string& deviceId,
                       std::function<void(const DeviceRevocationResult&)> done);
// No daemon calls. The platform timer delivers completed/expired replies even
// when the daemon worker is busy. Teardown closes replies before channel disposal.
void PollKnownDeviceRevocations();
void CancelKnownDeviceRevocations();
void UpdateProfile(const std::string& displayName,
                   const std::string& avatarBase64,
                   const std::string& fileType, int flag,
                   const std::optional<std::string>& expectedAccountId,
                   std::function<void(bool)> done);
void AddFriend(const std::string& peerJamiId,
               const std::optional<std::string>& expectedAccountId,
               std::function<void(bool)> done);
void CreateGroup(const std::string& title,
                 const std::vector<std::string>& memberIds,
                 const std::optional<std::string>& expectedAccountId,
                 std::function<void(const std::string&)> done);
void AddGroupMembers(const std::string& conversationId,
                     const std::vector<std::string>& memberIds,
                     const std::optional<std::string>& expectedAccountId,
                     std::function<void(bool)> done);
void RemoveGroupMember(const std::string& conversationId,
                       const std::string& memberId,
                       const std::optional<std::string>& expectedAccountId,
                       std::function<void(bool)> done);
void RenameGroup(const std::string& conversationId,
                 const std::string& title,
                 const std::optional<std::string>& expectedAccountId,
                 std::function<void(bool)> done);
void UpdateGroupLayout(const std::string& conversationId,
                       const std::string& description,
                       const std::optional<std::string>& expectedAccountId,
                       std::function<void(bool)> done);
void LeaveGroup(const std::string& conversationId,
                const std::optional<std::string>& expectedAccountId,
                std::function<void(bool)> done);
void SetPresenceSubscriptions(const std::vector<std::string>& peerJamiIds,
                              std::function<void(bool)> done);

// Fire ONE non-swarm reachability probe to the peer and report the daemon's message id (as a string, "" on
// failure) so the UI can correlate the delivery-status event. A plain Jami id routes the P2P message channel
// (opening one if needed to wake a cold peer); never a git commit. Honest lifecycle: queued in the daemon's
// message engine, PERSISTED across restarts, retried until SENT or 20 cumulative retries (no cancel API) — the
// Dart side bounds the queue with a one-in-flight guard. Status arrives on the events channel as "messageStatus"
// {messageId, state}. Daemon worker; `done` on the WORKER thread.
void ProbeReachable(const std::string& peerJamiId, std::function<void(const std::string&)> done);

// One bounded direct-contact composer hint. Native requires raw buddy status
// CONNECTED; receiver timestamps discard delayed daemon retries.
void SendComposerActivity(const std::string& accountId,
                          const std::string& peerJamiId,
                          const std::string& conversationId,
                          const std::string& kind,
                          std::function<void(bool)> done);

// One short-lived image preview for an exact direct-contact file offer.
void SendFileThumbnail(const std::string& peerJamiId,
                       const std::string& conversationId,
                       const std::string& fileId,
                       const std::string& pngBase64,
                       std::function<void(bool)> done);

// Persistent direct-contact decision for one exact file offer.
// Capture native account/trust lifetime; callable from the popup's platform timer.
std::function<bool()> HologramPresentationAuthority(const std::string& accountId,
    const std::string& peerJamiId, const std::string& conversationId);
void SendHologramControl(const std::string& accountId, const std::string& peerJamiId,
                         const std::string& payload, std::function<void(bool)> done);
void SendFileDeclined(const std::string& peerJamiId,
                      const std::string& conversationId,
                      const std::string& fileId,
                      std::function<void(bool)> done);

// Send one short-lived request that asks a trusted direct contact to call.
// The payload has no chat content and does not enter swarm history.
void NotifyCallRequest(const std::string& peerJamiId,
                       std::function<void(bool)> done);

// ---- presence (unit c slice b) ----

// Legacy single-friend subscribe/unsubscribe adapter. It accepts only a friend already present in the immutable
// routing snapshot and never performs trust or selection; new code reconciles the full set with
// SetPresenceSubscriptions. The daemon's NewBuddyNotification is surfaced via Emit("presence",
// {peerJamiId, status}) with the raw tri-state (0=DISCONNECTED, 1=AVAILABLE, 2=CONNECTED). Fire-and-forget;
// runs on the daemon worker.
// ---- 1:1 voice (unit c slice c): mirrors Android JamiCore place/answer/hangUp/refuse + setMicMuted ----

// Place an outgoing 1:1 call. `initialAudioMuted` is written into the initial libjami media offer, before any
// CURRENT callback can race Dart policy setup. `cameraOn` reports whether camera media was actually offered
// (a requested video call falls back to audio if no capture device is available); callId is empty on failure.
void PlaceCall(const std::string& peerJamiId, bool withVideo,
               bool initialAudioMuted,
               std::function<void(const std::string& callId, bool cameraOn)> done);

struct GroupActiveCall {
  std::string conferenceId;
  std::string hostUri;
  std::string hostDevice;
};

struct GroupCallPlacement {
  std::string conferenceId;
  std::string callId;
  bool hosting = false;
};

void ListGroupCalls(const std::string& conversationId,
                    std::function<void(const std::vector<GroupActiveCall>&)> done);
void ReserveGroupCall(const std::string& accountId,
                      const std::string& conversationId,
                      const std::string& reservationId,
                      std::function<void(bool)> done);
void JoinGroupCall(const std::string& conversationId,
                   const std::string& conferenceId,
                   const std::string& reservationId,
                   const std::string& hostUri,
                   const std::string& hostDevice,
                   bool initialAudioMuted,
                   std::function<void(const GroupCallPlacement&)> done);
void LeaveGroupCall(const std::string& conferenceId, const std::string& reservationId,
                    std::function<void(bool)> done);
void SetGroupMicMuted(const std::string& conferenceId, bool muted,
                      std::function<void(bool)> done);
void SetGroupDeafened(const std::string& conferenceId, bool deafened,
                      std::function<void(bool)> done);
void SetGroupConferenceLayout(const std::string& conferenceId, int layout,
                              std::function<void(bool)> done);
void SetGroupActiveStream(const std::string& conferenceId,
                          const std::string& accountUri,
                          const std::string& deviceId,
                          const std::string& streamId, bool active,
                          std::function<void(bool)> done);
void MuteGroupParticipant(const std::string& conferenceId,
                          const std::string& accountUri,
                          const std::string& deviceId,
                          const std::string& streamId, bool muted,
                          std::function<void(bool)> done);
void DisconnectGroupParticipant(const std::string& conferenceId,
                                const std::string& accountUri,
                                const std::string& deviceId,
                                std::function<void(bool)> done);
void PublishGroupCallPresence(const std::string& conversationId,
                              const std::string& body,
                              std::function<void(bool)> done);

// Answer / hang up / refuse a call by id; `done` gets the daemon's bool result. AnswerCall mirrors the snapshotted
// incoming media offer (audio with our mute state; any video answered receive-only until the user enables camera).
void AnswerCall(const std::string& callId, bool initialAudioMuted,
                std::function<void(bool)> done);
void HangUp(const std::string& callId, std::function<void(bool)> done);
void Refuse(const std::string& callId, std::function<void(bool)> done);

// Audio output routing: daemon device names in index order, and selection by
// that same index (libjami getAudioOutputDeviceList/setAudioOutputDevice).
void AudioOutputs(std::function<void(std::vector<std::string>)> done);
void SetAudioOutput(int index, std::function<void(bool)> done);
void AudioInputs(std::function<void(std::vector<std::string>)> done);
void SetAudioInput(int index, std::function<void(bool)> done);

// M8: send an in-call side-channel message (the annotation draw protocol) to the peer on the live `callId`. Rides
// the call's SIP dialog as an in-dialog SIP MESSAGE over the established P2P transport (ephemeral, low-latency — not
// the DHT/swarm). Returns only whether the bounded packet was accepted onto
// the daemon worker for the current call; libjami's API has no delivery ACK.
// Inbound peer messages surface as the 'callMessage' event.
bool SendCallMessage(const std::string& callId, const std::string& payload,
                     const std::string& channel);

// Call-scoped local audio-sender mute. The id prevents a delayed control from changing a replacement call; `done`
// is false when the id is stale or libjami cannot apply the media change.
void SetMicMuted(const std::string& callId, bool muted, std::function<void(bool)> done);

// Select libjami's call-scoped sender gate (`open` or `voiceActivated`). The exact CURRENT winner owns the command;
// voice activation first enables/verifies libjami's existing VAD and fails instead of degrading to open.
void SetAudioTransmissionMode(const std::string& callId, const std::string& mode,
                              std::function<void(bool)> done);

// Diagnostic/display-only RMS meter. It is not a transmission authority.
void SetAudioMeterEnabled(bool enabled, std::function<void(bool)> done);

// ---- presence / appear-offline (M7): mirrors Android JamiCore.setAppearOffline ----
//
// Go dark: Jami has no connected-but-invisible state — online is a side effect of the account announcing on the
// DHT. "Appear offline" DISABLES the account via sendRegister(acc, !on) — the persisted `Account.enable`, so a
// daemon account config boots disabled in steady state; the separate Dart preference can still drift and is
// reconciled after boot work. Peers see us offline AND we are unreachable while dark;
// re-enabling re-announces. The request captures the selected account lifetime before queueing; a supplied
// expectedAccountId must match it. `done` is false if that owner changes before the command or the command throws.
void SetAppearOffline(bool on, const std::optional<std::string>& expectedAccountId,
                      std::function<void(bool)> done);

// presence v2: stamp OUR app's foreground state (Dart lifecycle) — rides every native ping/pong as the "fg"
// flag so the peer renders in-app (green) vs merely reachable (dim). Cheap atomic write; any thread.
void SetForeground(bool fg);
void PrepareVoiceRecording(const std::string& accountId, const std::string& peer,
                           const std::string& conversation,
                           std::function<void(std::string)> done);
bool RenewVoiceRecording(const std::string& path);
void SetPresenceMetadata(bool shareActivity, const std::string& color);

// presence v2 zombie-janitor: fire the daemon's connectivityChanged() — a 3 s-timeout beacon on every
// connected socket that kills dead (zombie) channels so NewBuddyNotification flips within ~3 s. Off-label
// (also resets DHT/ICE caches) — callers rate-limit. Fire-and-forget; on worker.
void ConnectivitySweep();

// ---- connection profile (M7): mirrors Android JamiCore.setConnectionProfile ----
//
// Switch HOW we reach the peer ('lan' | 'jami' | 'strict') — a selectable libjami account config, not a rebuild.
// Reads the full account details, overwrites the connection keys for [profile], and setAccountDetails (which
// re-registers the account automatically). Strict-mode host fields carry the founder's self-hosted dhtnode/coTURN
// (blank bootstrap is replaced with unreachable 192.0.2.1 and therefore fails closed). `done` runs after
// setAccountDetails and is false on no account/throw or if the captured account lifetime has changed.
void SetConnectionProfile(const std::string& profile, const std::string& dhtBootstrap,
                           const std::string& turnServer, const std::string& turnRealm,
                           const std::string& turnUser, const std::string& turnPassword,
                           const std::optional<std::string>& expectedAccountId,
                           std::function<void(bool)> done);

// ---- 1:1 video (unit c final slice): mirrors Android JamiCore video, but Windows video is DAEMON-CAPTURED ----
//
// Windows differs from Android: the daemon owns camera capture (MediaFoundation) AND decodes/scales frames, so the
// client does NOT push camera frames (Android's ManagedByClient model). Instead it (1) RENDERS the daemon's
// decoded sinks into Flutter textures via registerSinkTarget (a pull+push "transformed listener" whose pull-buffer
// is RGBA, so the daemon's own scaler converts for free), and (2) enables/disables its OWN camera in the call via
// requestMediaChange with SOURCE="camera://<deviceId>". The current negotiated camera SEND path uses VP8 and the
// local build removes libx264; however, the audited external artifact still contains HEVC hardware-encoder objects,
// so this header must not claim the entire binary is H.264/HEVC decode-only.

// A decoded RGBA frame for a role ("self" | "remote"), tightly packed (stride == width*4, 4 bytes/px, R,G,B,A).
// INVOKED ON A DAEMON DECODER THREAD — the runner copies it into the role's texture pixel-buffer and marks the
// Flutter frame available; the daemon-thread/raster-thread buffer race is the runner's to synchronize.
using VideoFrameSink = std::function<void(const std::string& role, const uint8_t* rgba, int width, int height)>;

// Register/replace the video-frame sink (nullptr clears it). Set by the runner; invoked from a daemon decoder
// thread whenever a self/remote sink delivers a frame. Cleared on teardown BEFORE the channels/textures are freed.
void SetVideoFrameSink(VideoFrameSink sink);

// Turn our camera ON/OFF in the active call (daemon-owned capture). StartVideo picks a camera via getDeviceList()
// and requestMediaChange's audio+video with SOURCE="camera://<deviceId>"; StopVideo disables the video entry.
// Both are scoped to the originating call ID so delayed work cannot change a replacement call. `done` gets the
// daemon bool (false on call mismatch / no camera / re-invite rejected). Runs on the worker.
void StartVideo(const std::string& expectedCallId, std::function<void(bool)> done);
void StopVideo(const std::string& expectedCallId, std::function<void(bool)> done);

// Flip to the next camera the host exposes (>=2 devices) by re-inviting with the next device's source; `done`
// gets false when there is no other camera. Runs on the worker. (Most desktops expose one camera → usually false.)
void SwitchCamera(const std::string& expectedCallId, std::function<void(bool)> done);

void SetOutgoingVideoSource(const std::string& expectedCallId, const std::string& kind,
                            const std::string& sourceUri, int width, int height,
                            std::function<void(bool)> done);

struct OwnedScreenSource {
  std::string uri;
  std::uint64_t revision = 0;
  int width = 0;
  int height = 0;
};

// Synchronous, read-only authority query for the platform-thread annotation
// projector. Returns only the exact current, settled, locally owned screen
// source for the authoritative call; stale Flutter snapshots cannot create a
// desktop overlay.
std::optional<OwnedScreenSource> ResolveOwnedScreenSource(
    const std::string& callId, std::uint64_t sourceRevision);

// ---- file transfer (M5): swarm-conversation P2P (mirrors Android JamiCore file ops) ----
//
// libjami exposes ONLY the swarm-conversation model (sendFile/downloadFile take a conversationId; there is no
// legacy per-peer transfer). The single Syb-L peer maps to its 1:1 contact conversation (auto-created by the
// mutual addContact). Files are never server-hosted — content moves P2P over the swarm. Incoming files arrive
// as data-transfer commits (SwarmMessageReceived) surfaced via Emit("incomingFile", ...); progress + completion
// via Emit("fileProgress", ...). The file PICKER is a runner concern (jami_channels) — this lib stays daemon-only.

// Byte progress for the Dart-side poller.
struct FileInfo {
  bool completed = false;
  int64_t transferred = 0;
  int64_t total = 0;
  std::string path;
};

// Send a local file to the peer over the resolved 1:1 conversation; `done` gets false if no conversation / not a
// regular file. Progress then arrives via Emit("fileProgress", {outgoing=true}). Runs on the worker.
void SendFile(const std::string& peerJamiId, const std::string& conversationId,
              const std::string& path, const std::string& name,
              const std::string& topicId, std::function<void(bool)> done);

// Accept an offered incoming file → downloadFile into the user's Downloads dir; `done` gets the daemon bool.
void AcceptFile(const std::string& peerJamiId, const std::string& conversationId,
                const std::string& interactionId, const std::string& fileId, const std::string& name,
                int64_t maxBytes, const std::string& attemptId, std::function<void(bool)> done);

// Open a completed incoming file with its registered Windows application.
// Fails closed unless the path is a regular file under Downloads\Syb-L Received.
void OpenReceivedFile(const std::string& path, std::function<void(bool)> done);

// Decline an offered file / cancel an in-flight transfer. `done` reports
// whether libjami accepted the asynchronous cancellation request.
void CancelFile(const std::string& peerJamiId, const std::string& conversationId,
                const std::string& fileId, const std::string& attemptId, std::function<void(bool)> done);

// Query byte progress for a transfer (fileTransferInfo); `done` on the worker thread.
void FileInfoQuery(const std::string& peerJamiId, const std::string& conversationId,
                   const std::string& fileId, std::function<void(const FileInfo&)> done);

// ---- file-keeping (M6): persistent shared folder over the swarm's data-transfer history ----
//
// Load the canonical 1:1 conversation's file history. The daemon replies on the SwarmLoaded signal; each
// data-transfer commit is surfaced via Emit("folderFile", {fileId, interactionId, conversationId, name, size,
// sha3, outgoing, downloaded, timestamp}). `keepLast` bounds the conversation commits scanned; only file commits
// among them are emitted, up to that limit. Fire-and-forget; runs on the worker.
// Safe to call repeatedly (e.g. on launch and again when the conversation first syncs / ConversationReady).
void LoadFolder(const std::string& peerJamiId, const std::string& conversationId, int keepLast,
                std::function<void(uint32_t)> done);

// ---- persistent direct chat (M11): the existing libjami swarm conversation ------------------------------
//
// Text is committed through libjami::sendMessage and history is paged with libjami::loadConversation. Syb-L
// does not own a parallel message database. Every operation carries the full friend/conversation owner tuple
// and fails closed if it is not present in the current immutable routing snapshot.
void SendChatMessage(const std::string& peerJamiId, const std::string& conversationId,
                     const std::string& body, const std::string& replyTo,
                     const std::string& topicId,
                     std::function<void(bool)> done);
  void SendDmTopicEvent(const std::string& peerJamiId,
                      const std::string& conversationId,
                      const std::string& body,
                        std::function<void(const std::string&)> done);
  void SendOwnedReaction(const std::string& accountId, const std::string& peerJamiId,
                        const std::string& conversationId, const std::string& messageId,
                        const std::string& removedId, const std::string& emoji,
                        const std::string& topicId, const std::string& roomId,
                        const std::string& operationId,
                        std::function<void(const std::string&)> done);
  void SendOwnedMessage(const std::string& accountId, const std::string& peerJamiId,
                        const std::string& conversationId, const std::string& mimeType,
                        const std::string& body, const std::string& replyTo,
                        const std::string& topicId, const std::string& roomId,
                        const std::string& operationId,
                        std::function<void(const std::string&)> done);
void SendOwnedFile(const std::string& accountId, const std::string& peerJamiId,
                   const std::string& conversationId, const std::string& path,
                   const std::string& name, const std::string& topicId,
                   const std::string& roomId, const std::string& media,
                   const std::string& operationId,
                   std::function<void(const std::string&)> done);
void AcknowledgeFileSeed(const std::string& accountId, const std::string& operationId,
                         const std::string& commitId, const std::string& conversationId,
                         std::function<void(bool)> done);
void SetMessageDisplayed(const std::string& peerJamiId,
                         const std::string& conversationId,
                         const std::string& messageId,
                         std::function<void(bool)> done);
void LoadChat(const std::string& peerJamiId, const std::string& conversationId,
              const std::string& fromMessage, int pageSize,
              std::function<void(uint32_t)> done);
void LoadDmTopicState(const std::string& peerJamiId,
                      const std::string& conversationId,
                      const std::string& fromMessage, int pageSize,
                      std::function<void(uint32_t)> done);
// Retire a Dart-abandoned chat load locally. libjami has no cancellation API;
// the daemon may still finish, but its late callback can no longer claim UI
// ownership and the random id remains quarantined for this process.
bool CancelChatLoad(uint32_t loadId);
bool CancelDmTopicStateLoad(uint32_t loadId);

// ---- inbound-trust gate + remove/block (M7.5 d): mirrors Android JamiCore accept/decline/removeContact ----
//
// Jami auto-clones a confirmed contact's one-to-one request before the callback. Every remaining friend/group
// request is surfaced as {conversationId, fromJamiId, isGroup} for an explicit decision. Friend accepts add contact
// trust; group accepts only join the group. Failed commands restore the pending request for replay/retry.
void AcceptConnect(const std::string& conversationId, std::function<void(bool)> done);
void DeclineConnect(const std::string& conversationId, const std::string& fromJamiId,
                    std::function<void(bool)> done);
void RemoveContact(const std::string& uri, bool ban,
                   std::function<void(bool)> done);

// ---- identity backup / restore (M7.5 a): mirrors Android JamiCore export/restore ----
//
// ExportAccount asks libjami for one serialized snapshot: read the live archive with the current-user DPAPI-sealed
// device secret and atomically write only the destination with the user's backup passphrase. It never re-keys the
// live archive and does not create a recovery journal. The destination path is chosen by the runner's Save dialog;
// `done` gets false on any validation or daemon failure. Runs on the worker.
struct BackupOwner {
  std::string accountId;
  uint64_t revision = 0;
};
std::optional<BackupOwner> CaptureBackupOwner(const std::optional<std::string>& expectedAccountId);
void ExportAccount(const BackupOwner& owner, const std::string& destinationPath, const std::string& passphrase,
                   const std::string& settingsDocument,
                   std::function<void(bool)> done);

// Restore an identity from a previously-exported backup file via addAccount{archivePath, archivePassword} — the
// daemon re-imports the archive's master keypair, so the restored account has the IDENTICAL 40-hex Jami id. `done`
// gets {accountId, jamiId, displayName}; an EMPTY jamiId means the passphrase/file was wrong (the unauthenticated
// account is removed so it doesn't linger). The daemon copies the archive into its own dir, so the source file
// can be deleted after. Runs on the worker.
void RestoreAccount(const std::string& filePath, const std::string& passphrase,
                    const std::string& connectionProfile,
                    const std::string& dhtBootstrap,
                    const std::string& turnServer,
                    const std::string& turnRealm,
                    const std::string& turnUser,
                    const std::string& turnPassword,
                    bool appearOffline,
                    const std::string& expectedJamiId,
                    const std::optional<std::string>& expectedAccountId,
                    std::function<void(const Account&)> done);
void GetPendingIdentityRestore(std::function<void(const Account&)> done);
void DiscardIdentityRestore(const std::string& accountId, const std::string& restoreToken,
                            const std::string& expectedAccountId, std::function<void(bool)> done);
void FinalizeIdentityRestore(const std::string& accountId, const std::string& restoreToken,
                             const std::string& settingsDocument,
                             std::function<void(const Account&)> done);

}  // namespace jami_bridge

#endif  // RUNNER_JAMI_BRIDGE_H_
