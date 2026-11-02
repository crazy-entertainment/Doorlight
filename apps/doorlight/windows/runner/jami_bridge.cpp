#include "native_authority_lease.h"
// libjami engine bridge — Windows. Compiled in its OWN static library (windows/runner/CMakeLists.txt) with
// exceptions enabled and the default warning level, so the daemon's STL-heavy headers stay clear of the
// Flutter runner's /WX + _HAS_EXCEPTIONS=0 settings.
//
// M3 unit (b): proved jami-core.lib links into the Flutter-Windows app AND that the daemon init()/start()s
// inside it. Unit (c) slice (a): the identity surface — ensureAccount/myJamiId + registrationState/
// deviceAnnounced — driven via ConfigurationManager + registerSignalHandlers, mirroring Android JamiCore.
// EVERYTHING below is exceptions-ON; because the runner that links us is _HAS_EXCEPTIONS=0, the exception
// FIREWALL lives HERE: every boundary function and every daemon callback is wrapped in try/catch(...) so a
// libjami throw can never unwind into an exceptions-disabled runner frame.
#define _CRT_SECURE_NO_WARNINGS

// Windows builds of Syb-L are RELEASE-ONLY: jami-core.lib is a Release /MD (_ITERATOR_DEBUG_LEVEL=0) static lib,
// so a Debug /MDd build dies at the final link with LNK2038 runtime/IDL mismatches. CMake defines
// SYBL_JAMI_DEBUG_UNSUPPORTED for the Debug config (see windows/runner/CMakeLists.txt) so we fail fast HERE with
// a clear message instead of a wall of linker errors. Build with: flutter run/build windows --release (or --profile).
#ifdef SYBL_JAMI_DEBUG_UNSUPPORTED
#error "Syb-L on Windows is Release-only (jami-core.lib is /MD Release). Build with --release or --profile, not Debug. (A Debug /MDd build mismatches the /MD CRT / _ITERATOR_DEBUG_LEVEL=0 of jami-core.lib and dies at link with LNK2038.)"
#endif

#include "jami_bridge.h"
#include "update_shutdown.h"
#include "control_message_admission.h"
#include "archive_path_policy.h"
#include "archive_protection.h"
#include "archive_secret_store.h"
#include "command_journal_store.h"
#include "stage_registry.h"
#include "call_policy.h"
#include "conversation_load_registry.h"
#include "dm_topic_wire.h"
#include "file_thumbnail_wire.h"
#include "friend_routing.h"
#include "hologram_wire.h"
#include "group_policy.h"
#include "group_call_wire.h"
#include "identity_color_wire.h"
#include "identity_restore.h"
#include "reset_doorlight.h"
#include "device_pairing.h"
#include "known_device_policy.h"
#include "pending_request_gate.h"
#include "picked_file_staging.h"
#include <record_windows/sybl_recording_api.h>
#include "profile_wire.h"
#include "presence_metadata.h"
#include "presence_wire.h"
#include "remote_control_lan.h"
#include "remote_control_protocol.h"
#include "remote_control_routing.h"
#include "screen_source.h"
#include "timeline_wire.h"
#include "rich_timeline.h"
#include "reaction_projection.h"
#include "history_search.h"
#include "video_frame_limits.h"
#include "win32_dpapi.h"

// The daemon public API. Warnings silenced for the vendored header region only.
#pragma warning(push, 0)
#include "jami.h"
#include "call_const.h"
#include "callmanager_interface.h"
#include "configurationmanager_interface.h"
#include "presencemanager_interface.h"
#include "videomanager_interface.h"
#include "datatransfer_interface.h"
#include "conversation_interface.h"
#include "account_const.h"
#include "base64.h"
// FFmpeg (libavutil) — to allocate the RGBA pull-buffer the daemon scaler converts into, and to read back the
// scaled frame's planes in push. Headers from the contrib ffmpeg build (include dir wired in CMakeLists.txt).
extern "C" {
#include <libavutil/frame.h>
#include <libavutil/pixfmt.h>
}
#pragma warning(pop)

#include <algorithm>
#include <atomic>
#include <chrono>
#include <charconv>
#include <cctype>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <cwctype>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <deque>
#include <filesystem>
#include <fstream>
#include <memory>
#include <functional>
#include <iterator>
#include <limits>
#include <map>
#include <mutex>
#include <optional>
#include <set>
#include <stdexcept>
#include <string>
#include <thread>
#include <tuple>
#include <vector>
#include <json/json.h>

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <shlobj.h>   // SHGetKnownFolderPath(FOLDERID_Downloads) — the received-file destination
#include "uat_profile.h"
#include <shellapi.h>

namespace jami_bridge {
namespace {

// ---- single daemon worker (mirrors Android JamiCore's single-thread executor) -----------------------------
// EVERY call INTO libjami runs on this one thread: it serializes daemon access and guarantees later ops run
// only after init()/start() have finished.
std::mutex g_mutex;
// libjami returns a load id and dispatches SwarmLoaded on its IO pool. Hold this narrow registration mutex across
// the call + pending-map insertion and at callback entry so a fast warm-cache result cannot beat correlation.
std::mutex g_loadRegistrationMutex;
std::condition_variable g_cv;
std::deque<std::function<void()>> g_tasks;
std::thread g_worker;
std::mutex g_callSignalMutex;         // serializes complete IncomingCall/StateChange reductions and emits
constexpr size_t kRecentTerminalCallLimit = 64;  // callback-overtake memory, not live/tombstoned call ownership
constexpr size_t kMaxArchivePassphraseBytes = 4096;
constexpr size_t kMaxSettingsDocumentBytes = 64 * 1024;
bool g_running = false;             // guarded by g_mutex — worker-thread lifecycle
bool g_everStarted = false;         // guarded by g_mutex — latches the ONE boot for the process (never reset)
std::atomic<bool> g_daemonInitAttempted{false};
std::atomic<bool> g_daemonInitialized{false};  // completed phases are never repeated by a visible retry
std::atomic<bool> g_signalHandlersRegistered{false};
std::atomic<bool> g_daemonStartAttempted{false};
std::atomic<bool> g_daemonStarted{false};
std::atomic<bool> g_daemonReady{false};  // complete init/start/archive-policy transaction
// ponytail: fileutils.h drags unavailable private dhtnet headers into this target;
// use its canonical get_data_dir() once libjami exposes a lightweight public accessor.
std::filesystem::path g_jamiDataDir;  // initialized before libjami resolves its process-global data path

// ---- channel/identity state (unit c) ----
EventSink g_sink;                              // guarded by g_mutex; the runner's event sink (may be null)
ControlSink g_controlSink;                     // guarded; native-only control ingress/lifecycle
struct VerifiedControlAuthority {
  ControlSignal signal;
  uint64_t account_revision = 0;
  uint64_t trust_epoch = 0;
};
sybl::NativeAuthorityLease<VerifiedControlAuthority> g_controlAuthorityLease; // g_mutex
sybl::NativeAuthorityLease<VerifiedControlAuthority> g_controllerClipboardLease; // g_mutex
sybl::remote::ControlMessageAdmission g_controlMessageAdmission; // g_mutex
bool g_controlAuthorityRefreshPending = false; // g_mutex
std::string g_accountId;                       // guarded by g_mutex; cached current account id
uint64_t g_accountRevision = 0;                // guarded; changes only with account selection, including A-B-A
sybl::known_device::RevocationRegistry g_deviceRevocations;
bool g_haveReg = false;                        // guarded by g_mutex
std::map<std::string, std::string> g_regData;  // guarded by g_mutex; last registrationState payload (for replay)
bool g_haveAnnounced = false;                  // guarded by g_mutex
std::map<std::string, std::string> g_announcedData;  // guarded by g_mutex; last deviceAnnounced payload (replay)
std::map<std::string, std::map<std::string, std::string>> g_regByAccount;  // guarded by g_mutex
std::map<std::string, std::map<std::string, std::string>> g_announcedByAccount;  // guarded by g_mutex

// ---- 1:1 voice state (unit c slice c) ----
// The incoming call's media offer, snapshotted by value the instant IncomingCall fires (the daemon-owned
// reference dangles after the handler returns) — mirrored back when we answer. Cleared on a terminal call state.
// Media offers are call-scoped: a second incoming leg must not overwrite the offer for the call the UI shows.
std::map<std::string, std::vector<std::map<std::string, std::string>>> g_incomingOffers;  // guarded by g_mutex
std::map<std::string, std::string> g_callPeers;  // guarded; daemon call id -> admitted trusted friend id
std::set<std::string> g_rejectedCallIds;         // guarded; unconfigured inbound calls awaiting terminal cleanup
std::set<std::string> g_recentTerminalCallIds;   // guarded; bounds terminal-before-CURRENT callback overtakes
std::deque<std::string> g_recentTerminalOrder;   // guarded; insertion order for kRecentTerminalCallLimit
std::atomic<bool> g_micMuted{false};  // desired mute of the active call's local audio sender
std::string g_reservedCallPeer;       // guarded; owns the one global slot before and after CURRENT
bool g_identityActivationPending = false;  // guarded; pending restore reserves privacy before Dart settings writes
sybl::update::ShutdownReservation g_updateShutdown;  // g_mutex
// Unlike g_xfers (which also contains historical files and incoming offers),
// these are actual native transfer lifetimes, recorded before the worker hop.
using ActiveTransferKey = std::tuple<std::string, std::string, std::string, std::string>;
std::set<ActiveTransferKey> g_updateActiveTransfers;  // account, conversation, file, attempt; g_mutex
std::set<std::pair<std::string, std::string>> g_updateDeviceRevocations;  // g_mutex
uint64_t g_networkPreparedRevision = 0; // guarded; first activation follows network policy

// Native Jami swarm conference state. The conference is the media authority;
// Syb-L presence messages only let members see the room before they join.
std::string g_activeGroupConferenceId;  // guarded
bool g_activeGroupHosting = false;       // guarded
std::string g_pendingGroupConferenceId; // guarded
std::string g_groupReservationId; // guarded; random preflight lifetime
std::map<std::string, uint64_t> g_retiredGroupLegs; // guarded, bounded
bool g_groupPlacementStarted = false; // guarded
std::map<std::pair<std::string, std::string>, uint64_t> g_detachedGroupReservations; // guarded, bounded
std::map<std::string, std::string> g_groupCallLegs; // conference id -> local call id
std::map<std::string, std::string> g_groupConversationByConference;
std::map<std::string, std::optional<std::string>> g_previousGroupHostPreference;
std::optional<double> g_previousGroupPlaybackVolume;

// ---- 1:1 video state (unit c final slice) ----
std::string g_activeCallId;            // guarded by g_mutex; the live call (the REMOTE decoded sink id == this)
std::string g_currentWinnerCallId;     // guarded; first admitted trusted-friend call that reached CURRENT
struct RemoteAudioMeterOwner {
  std::string account;
  uint64_t revision = 0;
  std::string call;
  std::set<std::string> streams;
};
RemoteAudioMeterOwner g_remoteAudioMeters;  // guarded by g_mutex
bool g_audioMeterRequested = false;         // guarded by g_mutex
ULONGLONG g_remoteMeterProbeAfter = 0;      // guarded by g_mutex
screen_source::Outgoing g_localVideoSource;  // guarded by g_mutex; one off/camera/screen ownership value
struct PendingSourceTransition {
  screen_source::Transition source;
  size_t previous_camera_index = 0;
  size_t requested_camera_index = 0;
  std::string account_id;
  std::function<void(bool)> done;
};
screen_source::TransitionSlot<PendingSourceTransition> g_sourceTransition;  // guarded; completed by media-negotiation truth
std::set<std::string> g_peerMediaAnswersPending;  // guarded; preserves our independent send source
bool g_placingOutgoing = false;         // guarded by g_mutex; callbacks may beat placeCallWithMedia's return
std::string g_winnerCallIdDuringPlacement;  // guarded; survives winner terminal until placement reply
std::set<std::string> g_terminalDuringPlacement;  // guarded by g_mutex
struct OutgoingPlacementBarrier {
  std::mutex mutex;
  std::condition_variable cv;
  bool completed = false;
};
std::shared_ptr<OutgoingPlacementBarrier> g_outgoingPlacementBarrier;  // guarded by g_mutex
size_t g_cameraIndex = 0;              // guarded by g_mutex; index into getDeviceList() for switchCamera
VideoFrameSink g_frameSink;            // guarded by g_mutex; the runner's RGBA frame sink (may be null)

// Per-sink render state, alive while the daemon sink target is registered. pull()/push() for ONE sink run on ONE
// daemon decoder thread, in sequence, so `pack` is single-threaded; width/height are refreshed from DecodingStarted
// (a resolution change re-fires it). The SinkTarget lambdas hold a weak_ptr, so erasing the map entry frees this
// (and any in-flight push momentarily pins it via lock()), never a UAF.
struct SinkRender {
  std::string role;                    // "self" | "remote"
  std::string callId;                  // owning call; empty only until an outgoing placement returns
  std::string sourceUri;                // immutable source identity captured when this sink starts
  std::uint64_t sourceRevision = 0;
  std::atomic<bool> framePublished{false};
  std::atomic<int> width{0};
  std::atomic<int> height{0};
  std::vector<uint8_t> pack;           // reused tightly-packed RGBA scratch (single decoder thread)
};
std::map<std::string, std::shared_ptr<SinkRender>> g_sinks;  // guarded by g_mutex; sinkId -> render state

// g_mutex must be held. Direct and group calls share one media slot.
std::string ActiveMediaTargetLocked() {
  return !g_activeCallId.empty() ? g_activeCallId : g_activeGroupConferenceId;
}

bool IsActiveMediaTargetLocked(const std::string& id) {
  return !id.empty() && ActiveMediaTargetLocked() == id;
}

// g_mutex must be held. Conference guests own media by conference id, but
// libjami negotiates their media on the local call leg.
std::string MediaSignalingTargetLocked(const std::string& owner) {
  if (owner != g_activeGroupConferenceId) return owner;
  const auto leg = g_groupCallLegs.find(owner);
  return sybl::group_call::MediaTarget(
      owner, leg == g_groupCallLegs.end() ? std::string{} : leg->second,
      g_activeGroupHosting);
}

// g_mutex must be held.
std::string MediaOwnerLocked(const std::string& signaling_target) {
  for (const auto& entry : g_groupCallLegs) {
    if (entry.second == signaling_target) return entry.first;
  }
  return signaling_target;
}

// g_mutex must be held. Negotiation alone is not capture authority: the exact
// self sink for this source revision must have produced a validated frame.
bool OwnsLiveScreenFrameLocked(const screen_source::Outgoing& source) {
  if (g_sourceTransition) return false;
  const auto found = g_sinks.find(source.uri);
  if (found == g_sinks.end() || !found->second) return false;
  const auto& sink = *found->second;
  return sink.role == "self" &&
      screen_source::OwnsCaptureProof(
          source, ActiveMediaTargetLocked(),
          screen_source::CaptureProof{
              sink.sourceUri, sink.callId, sink.sourceRevision,
              sink.framePublished.load(std::memory_order_acquire)});
}

// g_mutex must be held. A pending transition cancelled without a confirmed
// outcome was never adopted: restore its previous source and camera index.
void RollBackCancelledTransitionLocked(const PendingSourceTransition& pending) {
  const auto cancelled = screen_source::CancelTransition(
      g_localVideoSource, g_cameraIndex, pending.source, pending.previous_camera_index);
  g_localVideoSource = cancelled.source;
  g_cameraIndex = cancelled.camera_index;
}

// Decoder callbacks may arrive on different libjami media threads. Serialize registry mutation through event
// publication; g_mutex cannot cover Emit(), which deliberately invokes the runner callback outside g_mutex.
std::mutex g_videoSignalMutex;

// ---- immutable daemon-derived friend routing + owner-scoped file transfer state ----
std::shared_ptr<const sybl::routing::RoutingSnapshot> g_routingSnapshot =
    std::make_shared<const sybl::routing::RoutingSnapshot>();
uint64_t g_routingGeneration = 0;  // guarded; invalidates a gather when account/contact callbacks overtake it
// Only current trusted peers have entries. A removed/re-added peer gets a new
// process-local lifetime; unrelated routing edits preserve queued packets.
std::map<std::string, uint64_t> g_controlTrustEpochs;  // guarded by g_mutex
uint64_t g_nextControlTrustEpoch = 1;
std::set<std::string> g_subscribedPeers;  // guarded; subscriptions currently owned by this bridge
std::set<std::string> g_connectedPeers;  // guarded; raw buddy status 2 only
struct FileXferMeta {
  std::string interactionId;
  std::string name;
  std::string authorId;
  std::string topicId = sybl::dm_topic::kMain;
  int64_t size = -1;
  bool outgoing = false;
  bool topicTagged = false;
  std::string roomId;
};
struct FileKey {
  std::string peerId;
  std::string conversationId;
  std::string fileId;
  bool operator<(const FileKey& other) const {
    return std::tie(peerId, conversationId, fileId) <
           std::tie(other.peerId, other.conversationId, other.fileId);
  }
};
std::map<FileKey, FileXferMeta> g_xfers;
// Only daemon-authenticated commit metadata selects private rich-media storage.
// A present but invalid value remains marked private and is never downgraded
// to an ordinary public-directory download.
std::map<FileKey, std::string> g_fileMediaMetadata;
// Exact paths created by StageOutgoingFile. libjami returns the source path as fileId with CREATED/INVALID once
// its conversation_data handoff finishes; the exact-match set prevents a callback from deleting any other file.
std::set<std::string> g_outgoingStagingPaths;
// Authoritative sizes keyed by the exact owner tuple. Retained after terminal transfer so a history download can
// revalidate the signed swarm declaration; no selected/global-conversation fallback exists.
std::map<FileKey, int64_t> g_fileSizes;
std::map<FileKey, std::string> g_receiveDestByFile;
std::map<FileKey, std::string> g_receiveAttempts;
std::set<std::wstring> g_reservedReceivePaths;  // guarded; case-folded Windows paths
int g_folderKeepLast = 200;  // guarded by g_mutex; M6 retention knob (founder owns the value at M11)
// libjami allocates one process-wide loadConversation id namespace. A single tagged registry makes it impossible
// for a callback to be claimed by the wrong feature. Completed, expired, and cancelled random ids remain retired
// for the process lifetime, so a late callback cannot claim a later request that received the same id.
sybl::conversation::LoadRegistry g_conversationLoads;
// Selected search results (loadSearchMessage) keep their caller beside the registry entry, under its load id.
struct SearchMessageRequest {
  sybl::history_search::MessageLoadTicket ticket;
  std::function<void(std::optional<SearchMessageReply>)> done;
};
sybl::conversation::AnsweredLoads<SearchMessageRequest> g_searchMessageLoads;  // guarded by g_mutex
std::map<std::string, std::string> g_pendingConnect;  // guarded by g_mutex; convId -> requester uri (M7.5 d gate)
std::map<std::string, std::string> g_pendingConnectAccount;  // guarded; convId -> owning account
std::map<std::string, bool> g_pendingConnectIsGroup;  // guarded; convId -> non-1:1 request
std::map<std::string, std::string> g_pendingConnectName;  // guarded; convId -> unverified 1:1 request FN hint
sybl::PendingRequestGate g_pendingConnectGate;  // guarded; count/rate ceiling
struct RejectedConnect {
  std::string account_id;
  std::string conversation_id;
};
std::deque<RejectedConnect> g_rejectedConnectQueue;  // guarded; one bounded worker drain
std::set<std::pair<std::string, std::string>> g_rejectedConnectKeys;  // guarded; queue dedupe
std::set<std::string> g_rejectedConnectRescanAccounts;  // guarded; daemon-truth fallback on overflow/switch
std::map<std::string, std::size_t> g_rejectedConnectRescanFailures;  // guarded; bounded deferred retries
std::deque<std::pair<std::string, std::string>> g_rejectedConnectTombstoneOrder;  // guarded; late callbacks
std::set<std::pair<std::string, std::string>> g_rejectedConnectTombstones;  // guarded
bool g_rejectedConnectDrainScheduled = false;  // guarded
constexpr std::size_t kMaxRejectedConnectQueue = 64;
constexpr std::size_t kMaxRejectedConnectRescanAccounts = 16;
constexpr std::size_t kMaxRejectedConnectRescanRetries = 3;
constexpr std::size_t kMaxRejectedConnectTombstones = 128;
void DrainRejectedConnects();
// The libjami master-identity archive uses a random password sealed to the
// current Windows user with DPAPI. The purpose-separated recovery journal is a
// separate crash-consistency record for archive migration/restore re-keying.
// This does not encrypt the live device key, swarm repositories, or downloads.
// Guarded by g_mutex.
std::string g_archiveSecret;
bool g_archiveRecoveryBlocked = false;  // guarded by g_mutex; a present journal must be resolved before another re-key
bool g_archiveProtectionReady = false;  // guarded; false forbids create/import/export rather than downgrading
// Worker-owned privacy transaction. It is independent of archive rekey recovery.
std::optional<sybl::identity_restore::PendingRestore> g_pendingRestore;
bool g_pendingRestoreBlocked = false;
bool g_resetDoorlightPending = false;  // guarded by g_mutex; retired until process restart
bool DisablePreparedAccount(const std::string& id);

std::string ResetDoorlightMarker() {
  const auto path = sybl::identity_restore::CanonicalSettingsLease::DefaultPath();
  if (!path) throw std::runtime_error("preferences path unavailable");
  if (!std::filesystem::exists(*path)) return {};
  if (std::filesystem::file_size(*path) > 8 * 1024 * 1024)
    throw std::runtime_error("preferences exceed reset limit");
  std::ifstream input(*path, std::ios::binary);
  Json::Value root;
  Json::CharReaderBuilder builder;
  builder["rejectDupKeys"] = true;
  builder["failIfExtra"] = true;
  std::string errors;
  if (!input || !Json::parseFromStream(builder, input, &root, &errors) || !root.isObject())
    throw std::runtime_error("reset preferences unreadable");
  const auto& marker = root["flutter.resetDoorlight.pending.v1"];
  if (marker.isNull()) return {};
  if (!marker.isString() || marker.asString().empty() || marker.asString().size() > 128)
    throw std::runtime_error("reset ownership invalid");
  return marker.asString();
}

bool IsActiveAccount(const std::string& accountId) {
  std::lock_guard<std::mutex> lock(g_mutex);
  return !g_resetDoorlightPending && !accountId.empty() && accountId == g_accountId;
}

void RetireSearchLocked();
void RetirePairingLocked();

void SelectAccountLocked(const std::string& accountId) {
  g_deviceRevocations.SelectAccount(accountId);
  if (g_accountId != accountId) {
    RetireSearchLocked();
    RetirePairingLocked();
    // Saturation retires all account-scoped commands instead of reusing an old revision.
    if (g_accountRevision != std::numeric_limits<uint64_t>::max()) ++g_accountRevision;
    if (!g_accountId.empty() && !g_pendingConnect.empty() &&
        g_rejectedConnectRescanAccounts.size() <
            kMaxRejectedConnectRescanAccounts) {
      g_rejectedConnectRescanAccounts.insert(g_accountId);
      if (!g_rejectedConnectDrainScheduled && g_running) {
        g_rejectedConnectDrainScheduled = true;
        try {
          g_tasks.emplace_back(DrainRejectedConnects);
          g_cv.notify_one();
        } catch (...) {
          g_rejectedConnectDrainScheduled = false;
        }
      }
    }
    ++g_routingGeneration;
    auto empty = std::make_shared<sybl::routing::RoutingSnapshot>();
    empty->account_id = accountId;
    empty->revision = g_routingSnapshot ? g_routingSnapshot->revision + 1 : 1;
    g_routingSnapshot = std::move(empty);
    g_controlTrustEpochs.clear();
    g_subscribedPeers.clear();
    g_connectedPeers.clear();
    g_pendingConnect.clear();
    g_pendingConnectAccount.clear();
    g_pendingConnectIsGroup.clear();
    g_pendingConnectName.clear();
    g_pendingConnectGate.Clear();
    g_fileSizes.clear();
    g_fileMediaMetadata.clear();
    g_xfers.clear();
    g_receiveDestByFile.clear();
    g_receiveAttempts.clear();
    g_reservedReceivePaths.clear();
    // Do not clear the registry's remembered ids on account replacement:
    // libjami's load-id namespace is process-wide and an old account callback
    // may still arrive. Only active ownership is retired; a selected-result
    // load is held until its daemon answer, which the owner recheck makes unavailable.
    g_conversationLoads.ClearActive();
    g_callPeers.clear();
    g_peerMediaAnswersPending.clear();
    g_rejectedCallIds.clear();
    g_recentTerminalCallIds.clear();
    g_recentTerminalOrder.clear();
    g_currentWinnerCallId.clear();
    g_reservedCallPeer.clear();
    g_winnerCallIdDuringPlacement.clear();
    if (g_outgoingPlacementBarrier) {
      {
        std::lock_guard<std::mutex> barrierLock(g_outgoingPlacementBarrier->mutex);
        g_outgoingPlacementBarrier->completed = true;
      }
      g_outgoingPlacementBarrier->cv.notify_all();
      g_outgoingPlacementBarrier.reset();
    }
  }
  g_accountId = accountId;
  auto reg = g_regByAccount.find(accountId);
  g_haveReg = reg != g_regByAccount.end();
  g_regData = g_haveReg ? reg->second : std::map<std::string, std::string>{};
  auto announced = g_announcedByAccount.find(accountId);
  g_haveAnnounced = announced != g_announcedByAccount.end();
  g_announcedData = g_haveAnnounced ? announced->second : std::map<std::string, std::string>{};
}

struct AccountCommandOwner {
  std::string accountId;
  uint64_t revision;
};
struct ConferenceInfoRequest {
  AccountCommandOwner owner;
  std::string conferenceId;
  std::string daemonId;
  std::string reservation;
};
sybl::group_call::ConferenceInfoIngress<ConferenceInfoRequest> g_conferenceInfoIngress; // g_mutex
void ProcessConferenceInfoRequest(const ConferenceInfoRequest& request);
struct PairingEntry {
  AccountCommandOwner owner;
  std::shared_ptr<sybl::device_pairing::Flow> flow;
  uint64_t epoch;
  std::atomic_bool admitting{true};
  bool cancelIssued = false; // Daemon worker only.
};
std::shared_ptr<PairingEntry> g_pairing; // g_mutex
sybl::device_pairing::Visits g_pairingVisits;
void CancelPairingEntry(const std::shared_ptr<PairingEntry>& entry);
void OnDevicePairingSignal(const std::string& account, std::optional<uint32_t> sourceOperation,
    int state, const std::map<std::string, std::string>& details, bool destination);
void RetirePairingLocked() {
  g_pairingVisits.RetireAll();
  const auto entry = g_pairing;
  if (!entry) return;
  entry->flow->Retire();
  if (g_running) {
    try { g_tasks.emplace_back([entry] { CancelPairingEntry(entry); }); g_cv.notify_one(); }
    catch (...) { /* Private material is retired even if cancellation cannot be queued. */ }
  }
}

struct HistorySearchEntry {
  AccountCommandOwner owner;
  std::string peer, conversation;
  uint64_t epoch;
  std::shared_ptr<sybl::history_search::Request> request;
  uint32_t nativeId = 0; // g_mutex
  bool delivered = false; // daemon worker only
  std::function<void(std::optional<HistorySearchReply>)> done;
};
std::shared_ptr<HistorySearchEntry> g_historySearch; // g_mutex
uint64_t g_historySearchEpoch = 0; // g_mutex
void RetireSearchLocked() {
  if (g_historySearchEpoch != std::numeric_limits<uint64_t>::max()) ++g_historySearchEpoch;
  if (g_historySearch) g_historySearch->request->Retire();
  // Selected-result loads keep their lease until the daemon answers; the advanced epoch makes that answer
  // unavailable.
}

// Answers, unavailable and outside g_mutex, every selected-result load the registry no longer holds.
void AnswerRetiredSearchMessages() {
  std::vector<SearchMessageRequest> retired;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    retired = g_searchMessageLoads.Retired(g_conversationLoads, sybl::conversation::LoadRegistry::Clock::now());
  }
  for (const auto& request : retired) {
    try { if (request.done) request.done(std::nullopt); } catch (...) {}
  }
}

struct OwnedMessageOperation {
  AccountCommandOwner owner;
  std::string peer;
  std::string conversation;
};
std::map<std::string, OwnedMessageOperation> g_ownedMessages;  // g_mutex
struct OwnedFileOperation {
  OwnedMessageOperation command;
  std::string path;
  std::string commit;
  std::string file;
  bool ready = false;
};
std::map<std::string, OwnedFileOperation> g_ownedFiles;  // g_mutex
std::unique_ptr<sybl::stage::Registry> g_stageRegistry;  // g_mutex

sybl::stage::Registry& StageRegistryLocked() {
  if (!g_stageRegistry) {
    const auto root = sybl::archive::ArchiveSecretStore::DefaultPath();
    const auto path = root ? root->parent_path() / L"stages.dpapi" : std::filesystem::path{};
    const auto loaded = root ? sybl::journal::Load(path) : sybl::journal::ReadResult{};
    g_stageRegistry = std::make_unique<sybl::stage::Registry>(
        loaded.healthy ? loaded.source : std::optional<std::string>("corrupt"),
        [path](const std::string& source) { return !path.empty() && sybl::journal::Save(path, source); });
  }
  return *g_stageRegistry;
}

void CleanUnissuedRecordings() {
  std::lock_guard<std::mutex> lock(g_mutex);
  auto& registry = StageRegistryLocked();
  const auto root = sybl::picked_file::DefaultStagingRoot();
  if (!root || !registry.healthy()) return;
  const auto records = registry.records();
  for (const auto& [path, record] : records) {
    if (!record.recording || record.issued()) continue;
    std::error_code error;
    const auto candidate = std::filesystem::u8path(path);
    const auto status = std::filesystem::symlink_status(candidate, error);
    const bool absent = status.type() == std::filesystem::file_type::not_found &&
        (!error || error == std::errc::no_such_file_or_directory);
    if (absent || sybl::picked_file::Discard(candidate, *root)) {
      if (!registry.Forget(path)) return;
    }
  }
}
std::set<std::string> g_completedMessageIds;  // g_mutex
std::deque<std::string> g_completedMessageOrder;  // g_mutex

std::optional<OwnedMessageOperation> UpdateOwnedFileCommit(
    const std::string& account, const std::string& conversation,
    const std::string& operation, const std::string& commit) {
  std::lock_guard<std::mutex> lock(g_mutex);
  const auto found = g_ownedFiles.find(operation);
  if (found == g_ownedFiles.end()) return std::nullopt;
  auto& owned = found->second;
  if (owned.command.owner.accountId != account || owned.command.conversation != conversation ||
      commit.size() > 1024 || (!owned.commit.empty() && !commit.empty() && owned.commit != commit))
    return std::nullopt;
  if (!commit.empty()) owned.commit = commit;
  return owned.command;
}

std::optional<OwnedMessageOperation> CompleteOwnedMessage(
    const std::string& account, const std::string& conversation, const std::string& operation,
    bool terminalOutcome = true) {
  std::lock_guard<std::mutex> lock(g_mutex);
  const auto found = g_ownedMessages.find(operation);
  if (found == g_ownedMessages.end() || found->second.owner.accountId != account ||
      found->second.conversation != conversation) return std::nullopt;
  const auto owned = found->second;
  if (!terminalOutcome) return owned;
  g_ownedMessages.erase(found);
  g_completedMessageIds.insert(operation);
  g_completedMessageOrder.push_back(operation);
  if (g_completedMessageOrder.size() > 1024) {
    g_completedMessageIds.erase(g_completedMessageOrder.front());
    g_completedMessageOrder.pop_front();
  }
  return owned;
}
std::optional<AccountCommandOwner> g_pendingRestoreOwner;  // worker-owned
bool FinishIdentityRestoreRollback(const std::optional<AccountCommandOwner>& owner = std::nullopt);

std::optional<AccountCommandOwner> CaptureRestoreOwner(
    const std::optional<std::string>& expectedAccountId = std::nullopt) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (!g_running || !g_daemonReady.load() ||
      g_accountRevision == std::numeric_limits<uint64_t>::max() ||
      (expectedAccountId && *expectedAccountId != g_accountId))
    return std::nullopt;
  return AccountCommandOwner{g_accountId, g_accountRevision};
}

bool MediaSlotIdleLocked(bool ownsRestore = false) {
  return g_activeCallId.empty() && g_activeGroupConferenceId.empty() &&
      g_pendingGroupConferenceId.empty() && g_reservedCallPeer.empty() &&
      !g_placingOutgoing && g_callPeers.empty() && (ownsRestore || !g_identityActivationPending);
}

std::optional<AccountCommandOwner> CaptureAccountCommandOwner(
    const std::optional<std::string>& expectedAccountId) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (!g_running || !g_daemonReady.load() || g_resetDoorlightPending || g_accountId.empty() ||
      g_accountRevision == std::numeric_limits<uint64_t>::max() ||
      (expectedAccountId && *expectedAccountId != g_accountId))
    return std::nullopt;
  return AccountCommandOwner{g_accountId, g_accountRevision};
}

bool OwnsAccountCommand(const AccountCommandOwner& owner) {
  std::lock_guard<std::mutex> lock(g_mutex);
  return g_running && g_daemonReady.load() && !g_resetDoorlightPending && owner.accountId == g_accountId &&
         owner.revision == g_accountRevision &&
         g_accountRevision != std::numeric_limits<uint64_t>::max();
}

// A GUI app has no console, so the daemon's CONSOLE_LOG goes nowhere. Mirror diagnostics to the debugger and,
// only when SYBL_DEBUG_LOG is explicitly set, to %TEMP%\sybl_jami_boot.log.
void Log(const std::string& line) {
  // Serialize: Log() is reachable concurrently from the worker, the platform thread, and (via Emit / the video
  // decoder sinks) several daemon threads. std::localtime returns a shared static std::tm and the file append
  // is non-atomic, so without this the timestamps tear / interleave (localtime_s is the thread-safe variant).
  static std::mutex log_mutex;
  std::lock_guard<std::mutex> lock(log_mutex);
  // M7.5 (L2): the %TEMP%\sybl_jami_boot.log leaks account/peer/conversation IDs + untrusted filenames AND
  // survives uninstall, so it is OFF by default. Opt in for diagnostics by setting the SYBL_DEBUG_LOG env var
  // (checked once). The OutputDebugStringA mirror is visible only to an attached debugger, so it always runs.
  static const bool fileLog = GetEnvironmentVariableW(L"SYBL_DEBUG_LOG", nullptr, 0) > 0;
  if (fileLog) {
    wchar_t tmp[MAX_PATH];
    DWORD n = GetTempPathW(MAX_PATH, tmp);
    std::wstring path = (n ? std::wstring(tmp, n) : std::wstring()) + L"sybl_jami_boot.log";
    if (FILE* f = _wfopen(path.c_str(), L"a")) {
      std::time_t t = std::time(nullptr);
      std::tm tm{};
      char ts[32];
      if (localtime_s(&tm, &t) == 0)
        std::strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M:%S", &tm);
      else
        ts[0] = '\0';
      std::fprintf(f, "[%s] %s\n", ts, line.c_str());
      std::fclose(f);
    }
  }
  OutputDebugStringA(("[sybl/jami] " + line + "\n").c_str());
}

// Isolate Syb-L's daemon data from stock Jami's %LOCALAPPDATA%\jami namespace. On Windows the daemon reads
// these env vars via GetEnvironmentVariable (fileutils.cpp winGetEnv) — NOT the CRT _wgetenv — so SetEnvironment
// VariableW is the right setter. There is NO GetAppDataPath client callback on Windows (that signal is
// Android/iOS-only). The dirs resolve ONCE (static const in get_data_dir/get_config_dir), so this MUST run
// before the first libjami call. Result: data+config in <LOCALAPPDATA>\Syb-L\jami, cache in <LOCALAPPDATA>\Syb-L\cache.
// Returns false, before any environment change, when no established LocalAppData root can be resolved (the
// resolver never falls back to a temporary or relative directory), when a usable LOCALAPPDATA value and the
// LocalAppData known folder (where the lock, DPAPI secret and recovery journal live) are different directories,
// or when any variable cannot be set.
bool SetupDataDirs() {
  std::optional<std::wstring> environment;
  const DWORD needed = GetEnvironmentVariableW(L"LOCALAPPDATA", nullptr, 0);
  if (needed > 0) {
    std::wstring value(needed, L'\0');
    const DWORD n = GetEnvironmentVariableW(L"LOCALAPPDATA", value.data(), needed);
    if (n > 0 && n < needed) {
      value.resize(n);
      environment = std::move(value);
    }
  }
  std::optional<std::wstring> known;
  PWSTR knownPath = nullptr;
  if (SUCCEEDED(sybl::uat::KnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &knownPath)) && knownPath)
    known = std::wstring(knownPath);
  if (knownPath) CoTaskMemFree(knownPath);
  const auto root = sybl::archive::ResolveIdentityDataRoot(environment, known, sybl::archive::IsSameDirectory);
  if (root.outcome == sybl::archive::IdentityRootOutcome::kMismatch) {
    Log("data dirs refused: LOCALAPPDATA and the LocalAppData known folder are different directories");
    return false;
  }
  if (root.outcome != sybl::archive::IdentityRootOutcome::kResolved) {
    Log("data dirs unresolved: refusing to boot without the established identity root");
    return false;
  }
  const std::wstring& base = root.root;
  const std::wstring cache = base + L"\\cache";
  g_jamiDataDir = std::filesystem::path(base) / L"jami";
  const bool set = SetEnvironmentVariableW(L"JAMI_DATA_HOME", base.c_str()) &&
                   SetEnvironmentVariableW(L"JAMI_CONFIG_HOME", base.c_str()) &&
                   SetEnvironmentVariableW(L"JAMI_CACHE_HOME", cache.c_str());
  if (!set) {
    Log("data dirs could not be configured");
    return false;
  }
  Log("data dirs -> %LOCALAPPDATA%\\Syb-L (data/config in \\jami, cache in \\cache)");
  return true;
}

struct ArchiveRecoveryRecord {
  std::string accountId;
  std::string currentSecret;
  std::string transientPassphrase;
};

std::filesystem::path ArchiveRecoveryPath() {
  PWSTR local = nullptr;
  if (FAILED(sybl::uat::KnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_CREATE, nullptr, &local)) || !local)
    return {};
  std::filesystem::path dir(local);
  CoTaskMemFree(local);
  dir /= L"Syb-L";
  std::error_code ec;
  std::filesystem::create_directories(dir, ec);
  if (ec) return {};
  return dir / L"archive_recovery.bin";
}

void AppendRecoveryField(std::vector<uint8_t>& bytes, const std::string& value) {
  if (value.size() > 16 * 1024 * 1024) throw std::length_error("archive recovery field too large");
  const uint32_t size = static_cast<uint32_t>(value.size());
  for (int shift = 0; shift < 32; shift += 8) bytes.push_back(static_cast<uint8_t>(size >> shift));
  bytes.insert(bytes.end(), value.begin(), value.end());
}

bool ReadRecoveryField(const std::vector<uint8_t>& bytes, size_t& offset, std::string& value) {
  if (offset + 4 > bytes.size()) return false;
  uint32_t size = 0;
  for (int shift = 0; shift < 32; shift += 8) size |= static_cast<uint32_t>(bytes[offset++]) << shift;
  if (size > 16 * 1024 * 1024 || offset + size > bytes.size()) return false;
  value.assign(reinterpret_cast<const char*>(bytes.data() + offset), size);
  offset += size;
  return true;
}

bool SaveArchiveRecovery(const ArchiveRecoveryRecord& record) {
  std::vector<uint8_t> clear;
  std::string sealed;
  try {
    AppendRecoveryField(clear, record.accountId);
    AppendRecoveryField(clear, record.currentSecret);
    AppendRecoveryField(clear, record.transientPassphrase);
    if (clear.empty() || clear.size() > 16 * 1024 * 1024) {
      if (!clear.empty()) SecureZeroMemory(clear.data(), clear.size());
      return false;
    }
    std::string clearBytes(reinterpret_cast<const char*>(clear.data()), clear.size());
    SecureZeroMemory(clear.data(), clear.size());
    sybl::win32::Win32DpapiProtector protector("archive-recovery-v1");
    auto protectedBytes = protector.Protect(clearBytes);
    SecureZeroMemory(clearBytes.data(), clearBytes.size());
    if (!protectedBytes) return false;
    sealed = std::move(*protectedBytes);
    const auto path = ArchiveRecoveryPath();
    if (path.empty()) {
      SecureZeroMemory(sealed.data(), sealed.size());
      return false;
    }
    const auto temp = path.wstring() + L".tmp";
    HANDLE file = CreateFileW(temp.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                              FILE_ATTRIBUTE_HIDDEN | FILE_ATTRIBUTE_NOT_CONTENT_INDEXED, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
      SecureZeroMemory(sealed.data(), sealed.size());
      return false;
    }
    DWORD written = 0;
    const bool wrote = WriteFile(file, sealed.data(), static_cast<DWORD>(sealed.size()), &written, nullptr) &&
                       written == sealed.size() && FlushFileBuffers(file);
    CloseHandle(file);
    SecureZeroMemory(sealed.data(), sealed.size());
    if (!wrote || !MoveFileExW(temp.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
      DeleteFileW(temp.c_str());
      return false;
    }
    return true;
  } catch (...) {
    if (!clear.empty()) SecureZeroMemory(clear.data(), clear.size());
    if (!sealed.empty()) SecureZeroMemory(sealed.data(), sealed.size());
    return false;
  }
}

// Returns false only for a present-but-unreadable record. `present=false` is the clean, absent state.
bool LoadArchiveRecovery(ArchiveRecoveryRecord& record, bool& present) {
  present = false;
  const auto path = ArchiveRecoveryPath();
  if (path.empty()) return false;
  HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                            FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    const DWORD error = GetLastError();
    present = error != ERROR_FILE_NOT_FOUND && error != ERROR_PATH_NOT_FOUND;
    return !present;
  }
  present = true;
  LARGE_INTEGER size{};
  if (!GetFileSizeEx(file, &size) || size.QuadPart <= 0 || size.QuadPart > 16 * 1024 * 1024) {
    CloseHandle(file);
    return false;
  }
  std::string encrypted(static_cast<size_t>(size.QuadPart), '\0');
  DWORD read = 0;
  const bool readOk = ReadFile(file, encrypted.data(), static_cast<DWORD>(encrypted.size()), &read, nullptr) &&
                      read == static_cast<DWORD>(encrypted.size());
  CloseHandle(file);
  if (!readOk) {
    SecureZeroMemory(encrypted.data(), encrypted.size());
    return false;
  }
  sybl::win32::Win32DpapiProtector protector("archive-recovery-v1");
  auto clearBytes = protector.Unprotect(encrypted);
  SecureZeroMemory(encrypted.data(), encrypted.size());
  if (!clearBytes) return false;
  std::vector<uint8_t> clear(clearBytes->begin(), clearBytes->end());
  SecureZeroMemory(clearBytes->data(), clearBytes->size());
  size_t offset = 0;
  const bool ok = ReadRecoveryField(clear, offset, record.accountId) &&
                  ReadRecoveryField(clear, offset, record.currentSecret) &&
                  ReadRecoveryField(clear, offset, record.transientPassphrase) && offset == clear.size();
  SecureZeroMemory(clear.data(), clear.size());
  return ok && !record.accountId.empty();
}

bool ClearArchiveRecovery() {
  const auto path = ArchiveRecoveryPath();
  if (path.empty()) return false;
  DeleteFileW((path.wstring() + L".tmp").c_str());
  return DeleteFileW(path.c_str()) || GetLastError() == ERROR_FILE_NOT_FOUND;
}

// Snapshot the sink under the lock, cache replayable state, then invoke OUTSIDE the lock (the sink does a
// PostMessage hop; keep the daemon thread out of the runner's critical sections). try/catch is the firewall.
void Emit(const std::string& type, const std::map<std::string, std::string>& data) {
  EventSink sink;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (type == "registrationState") {
      g_haveReg = true;
      g_regData = data;
    } else if (type == "deviceAnnounced") {
      g_haveAnnounced = true;
      g_announcedData = data;
    }
    sink = g_sink;
  }
  if (sink) {
    try {
      sink(type, data);
    } catch (...) {
      Log("event sink threw for " + type);
    }
  }
}

void WorkerLoop() {
  for (;;) {
    std::function<void()> task;
    std::optional<ConferenceInfoRequest> conference;
    bool searchMessagesDue = false;
    {
      std::unique_lock<std::mutex> lock(g_mutex);
      while (g_tasks.empty() && g_running) {
        auto due = g_conferenceInfoIngress.Due();
        const auto searchDue = g_searchMessageLoads.Due(g_conversationLoads);
        if (searchDue && *searchDue <= sybl::conversation::LoadRegistry::Clock::now()) {
          searchMessagesDue = true;
          break;
        }
        if (searchDue && (!due || *searchDue < *due)) due = searchDue;
        if (due) g_cv.wait_until(lock, *due);
        else g_cv.wait(lock);
        if (g_conferenceInfoIngress.Ready(
                sybl::group_call::ConferenceInfoIngress<ConferenceInfoRequest>::Clock::now())) break;
      }
      // Exit ONLY when the queue is drained — the `|| !g_running` term merely WAKES us to drain+exit; it never
      // short-circuits a pending task (that is what makes the Stop()-posts-fini-after-BootDaemon race safe).
      if (!g_tasks.empty()) {
        task = std::move(g_tasks.front());
        g_tasks.pop_front();
      } else if (!g_running) {
        return;
      } else if (!searchMessagesDue) {
        conference = g_conferenceInfoIngress.Take(
            sybl::group_call::ConferenceInfoIngress<ConferenceInfoRequest>::Clock::now());
      }
    }
    if (searchMessagesDue) AnswerRetiredSearchMessages();
    if (conference) {
      try { ProcessConferenceInfoRequest(*conference); } catch (...) {}
      {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_conferenceInfoIngress.Finish(
            sybl::group_call::ConferenceInfoIngress<ConferenceInfoRequest>::Clock::now());
      }
      g_cv.notify_one();
    } else if (task) {
      task();
    }
  }
}

void Post(std::function<void()> task) {
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (!g_running) throw std::runtime_error("jami worker stopped");
    g_tasks.push_back(std::move(task));
  }
  g_cv.notify_one();
}

bool EmitControl(const ControlSignal& signal) {
  ControlSink sink;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    sink = g_controlSink;
  }
  if (sink) {
    try {
      return sink(signal);
    } catch (...) {
      Log("control sink threw");
    }
  }
  return false;
}

void CompleteOnWorker(std::function<void(bool)> done, bool value) {
  if (!done) return;
  auto fallback = done;
  try {
    Post([done = std::move(done), value]() {
      try {
        done(value);
      } catch (...) {
      }
    });
  } catch (...) {
    try {
      fallback(value);
    } catch (...) {
    }
  }
}

// Account.username = the 40-hex Jami ID; not populated the instant after create — poll briefly (mirrors
// Android JamiCore.awaitUsername: 50 x 100ms). Worker thread only.
std::string AwaitUsername(const std::string& id) {
  for (int i = 0; i < 50; ++i) {
    auto d = libjami::getAccountDetails(id);
    auto it = d.find(libjami::Account::ConfProperties::USERNAME);
    if (it != d.end() && !it->second.empty()) return it->second;
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
  }
  auto d = libjami::getAccountDetails(id);
  auto it = d.find(libjami::Account::ConfProperties::USERNAME);
  return it != d.end() ? it->second : std::string();
}

// True if `id` is still a live account. The daemon AUTO-REMOVES an account whose archive import fails auth
// (onAuthenticationError → Manager::removeAccount), so a vanished id is the fast "bad passphrase/file" signal.
static bool AccountExists(const std::string& id) {
  for (const auto& a : libjami::getAccountList())
    if (a == id) return true;
  return false;
}

// Finish an archive migration/restore re-key interrupted after the live archive changed password. Worker only.
bool RecoverInterruptedArchiveRekey(const std::vector<std::string>& accounts) {
  ArchiveRecoveryRecord record;
  bool present = false;
  if (!LoadArchiveRecovery(record, present)) {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_archiveRecoveryBlocked = present;
    if (present) Log("archive recovery journal could not be opened");
    return false;
  }
  if (!present) {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_archiveRecoveryBlocked = false;
    return true;
  }
  if (std::find(accounts.begin(), accounts.end(), record.accountId) == accounts.end()) {
    const bool cleared = ClearArchiveRecovery();
    std::lock_guard<std::mutex> lock(g_mutex);
    g_archiveRecoveryBlocked = !cleared;
    return cleared;
  }
  bool desiredIsValid = false;
  try {
    desiredIsValid =
        libjami::isPasswordValid(record.accountId, record.currentSecret);
    if (!desiredIsValid) {
      libjami::changeAccountPassword(record.accountId,
                                     record.transientPassphrase,
                                     record.currentSecret);
      desiredIsValid =
          libjami::isPasswordValid(record.accountId, record.currentSecret);
    }
  } catch (...) {
  }
  const bool recovered = desiredIsValid && ClearArchiveRecovery();
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (recovered) {
      g_archiveSecret = record.currentSecret;
      g_archiveRecoveryBlocked = false;
    } else {
      g_archiveRecoveryBlocked = true;
    }
  }
  if (recovered) {
    Log("completed interrupted archive re-key");
    return true;
  } else {
    Log("interrupted archive re-key could not be recovered");
    return false;
  }
}

// Load the current-user DPAPI-sealed working secret, finish any interrupted
// passphrase round-trip, and migrate every loaded plaintext archive once.
// Worker thread only. A failure blocks password-sensitive operations; an empty
// fallback here would be a silent security downgrade.
bool InitializeArchiveProtection(
    const std::vector<std::string>& accounts) {
  const auto path = sybl::archive::ArchiveSecretStore::DefaultPath();
  if (!path) {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_archiveRecoveryBlocked = true;
    g_archiveProtectionReady = false;
    Log("device archive secret path is unavailable");
    return false;
  }
  sybl::archive::ArchiveSecretStore store(*path);
  const auto stored = store.LoadOrCreate();
  if (!stored) {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_archiveRecoveryBlocked = true;
    g_archiveProtectionReady = false;
    Log("device archive secret could not be opened");
    return false;
  }
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_archiveSecret = stored->secret;
  }
  if (!RecoverInterruptedArchiveRekey(accounts)) {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_archiveProtectionReady = false;
    return false;
  }
  // A legacy journal can target the old empty working password. The DPAPI
  // secret remains authoritative once that transaction has been repaired.
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_archiveSecret = stored->secret;
  }

  const bool reconciled = sybl::archive::ReconcileAccounts(
      accounts, [&](const std::string& candidateAccount) {
    using Outcome = sybl::archive::AccountReconcileOutcome;
    // An unacknowledged link owns a disabled reservation, not a legacy archive
    // to migrate or an authenticated account to adopt. Other identities remain checked.
    if (g_pendingRestore && g_pendingRestore->pairing_operation && !g_pendingRestore->pairing_acknowledged &&
        g_pendingRestore->account_id == candidateAccount) return Outcome::kSkipped;
    const auto details = libjami::getAccountDetails(candidateAccount);
    const auto hasPassword =
        details.find(libjami::Account::ConfProperties::ARCHIVE_HAS_PASSWORD);
    if (hasPassword == details.end() ||
        (hasPassword->second != "true" && hasPassword->second != "false")) {
      Log("archive protection state is missing or malformed");
      return Outcome::kIndeterminate;
    }
    {
      const sybl::archive::ArchiveProtectionCallbacks callbacks{
          [&](const std::string& desired,
              const std::string& transient) {
            return SaveArchiveRecovery(
                {candidateAccount, desired, transient});
          },
          [&](const std::string& oldPassword,
              const std::string& newPassword) {
            try {
              return libjami::changeAccountPassword(
                  candidateAccount, oldPassword, newPassword);
            } catch (...) {
              return false;
            }
          },
          [&](const std::string& password) {
            try {
              const bool valid = libjami::isPasswordValid(candidateAccount, password);
              if (!valid) Log("archive password validation failed for account " + candidateAccount);
              return valid;
            } catch (...) {
              Log("archive password validation threw for account " + candidateAccount);
              return false;
            }
          },
          [] { return ClearArchiveRecovery(); },
          [&] {
            return RecoverInterruptedArchiveRekey(
                libjami::getAccountList());
          }};
      return sybl::archive::ReconcileArchiveProtection(
                 candidateAccount, stored->secret,
                 hasPassword->second == "true", callbacks)
                 ? Outcome::kHealthy
                 : Outcome::kFailed;
    }
  });
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_archiveProtectionReady = reconciled;
    g_archiveRecoveryBlocked = !reconciled;
  }
  Log(reconciled ? "device archive protection ready"
                 : "device archive protection could not be reconciled");
  return reconciled;
}

// Restore variant of AwaitUsername: poll Account.username AND account-existence. A wrong passphrase makes the
// daemon auth-fail + remove the account → fast empty return (no destroying a still-importing valid account); a
// valid import only needs LOCAL Argon2+keygen (no network) but can be slow on a cold/large archive, so allow a
// generous ~25s before giving up. Worker thread only.
static std::string AwaitRestoredUsername(const std::string& id) {
  for (int i = 0; i < 250; ++i) {
    if (!AccountExists(id)) return std::string();
    auto d = libjami::getAccountDetails(id);
    auto it = d.find(libjami::Account::ConfProperties::USERNAME);
    if (it != d.end() && !it->second.empty()) return it->second;
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
  }
  return std::string();
}

// Create a Jami (RING) account with the DHT proxy enabled (reachable while backgrounded — the real client does
// this for push). Keys come from account_const.h so a daemon rename can't silently drift. Worker thread only.
void PinCallPolicy(const std::string& accountId) {
  if (accountId.empty()) return;
  auto details = libjami::getAccountDetails(accountId);
  const auto key = libjami::Account::ConfProperties::DENYSECONDCALL;
  auto it = details.find(key);
  if (it != details.end() && it->second == "true") return;
  details[key] = "true";
  libjami::setAccountDetails(accountId, details);
  Log("pinCallPolicy(" + accountId + "): Account.denySecondCall=true");
}

void MarkRecentTerminalLocked(const std::string& callId) {
  if (callId.empty() || !g_recentTerminalCallIds.insert(callId).second) return;
  g_recentTerminalOrder.push_back(callId);
  while (g_recentTerminalOrder.size() > kRecentTerminalCallLimit) {
    g_recentTerminalCallIds.erase(g_recentTerminalOrder.front());
    g_recentTerminalOrder.pop_front();
  }
}

void ClearCallReservationIfIdleLocked(const std::string& peerId) {
  if (g_reservedCallPeer != peerId || g_placingOutgoing || !g_currentWinnerCallId.empty()) return;
  for (const auto& [unused, owner] : g_callPeers)
    if (owner == peerId) return;
  g_reservedCallPeer.clear();
}

std::string CreateAccount(const std::string& displayName) {
  std::string deviceSecret;
  bool protectionReady = false;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    deviceSecret = g_archiveSecret;
    protectionReady = g_archiveProtectionReady;
  }
  if (!protectionReady ||
      !sybl::archive::IsValidArchiveSecret(deviceSecret)) {
    throw std::runtime_error("device archive protection is unavailable");
  }
  std::map<std::string, std::string> details{
      {libjami::Account::ConfProperties::TYPE, libjami::Account::ProtocolNames::RING},
      {libjami::Account::ConfProperties::DISPLAYNAME, displayName},
      // Create archive.gz encrypted from birth; do not write a plaintext
      // identity archive and migrate it afterward.
      {libjami::Account::ConfProperties::ARCHIVE_PASSWORD_SCHEME, "password"},
      {libjami::Account::ConfProperties::ARCHIVE_PASSWORD, deviceSecret},
      {libjami::Account::ConfProperties::PROXY_ENABLED, "true"},
      // Glare has no CURRENT call, so libjami skips this gate and still arbitrates. Established second calls do not ring.
      {libjami::Account::ConfProperties::DENYSECONDCALL, "true"},
      // M7.5 (I2): pin OFF "anyone on the DHT can call me" — non-contacts are refused. It's the daemon default,
      // but set explicitly so the inbound-trust gate doesn't depend on a default that could drift.
      {libjami::Account::ConfProperties::DHT::PUBLIC_IN_CALLS, "false"},
      // M7.5 (L3): a NEW account defaults to the 'jami' profile (DHT-reached), so the cleartext LAN broadcast of
      // {accountId, displayName} is pure leak — pin it OFF at creation (not just in ApplyConnectionProfile, which
      // only runs on a manual profile switch). Selecting 'lan' re-enables it.
      {libjami::Account::ConfProperties::DHT_PEER_DISCOVERY, "false"},
      {libjami::Account::ConfProperties::ACCOUNT_PEER_DISCOVERY, "false"},
      {libjami::Account::ConfProperties::ACCOUNT_PUBLISH, "false"},
  };
  std::string id = libjami::addAccount(details);
  Log("addAccount -> " + id);
  return id;
}

// Pick the identity account deterministically. With MORE THAN ONE account present (a stray/duplicate can linger
// from an old onboarding blip), prefer the one that actually has a contact (your person) over whichever
// getAccountList() happens to order first — otherwise which identity loads is undefined. One account => front().
// Mirrors Android JamiCore.pickAccount. Worker thread only (touches libjami).
static std::string PickAccount(const std::vector<std::string>& list,
                               const std::string& preferredAccountId = std::string()) {
  if (list.empty() || g_pendingRestoreBlocked) return {};
  auto ids = list;
  ids.erase(std::remove_if(ids.begin(), ids.end(), [](const std::string& id) {
    return !sybl::identity_restore::CanAdoptAccount(id, g_pendingRestore, g_pendingRestoreBlocked);
  }), ids.end());
  if (ids.empty()) return {};
  std::sort(ids.begin(), ids.end());
  if (!preferredAccountId.empty() &&
      std::find(ids.begin(), ids.end(), preferredAccountId) != ids.end())
    return preferredAccountId;
  if (ids.size() == 1) return ids.front();
  for (const auto& id : ids) {
    try { if (!libjami::getContacts(id).empty()) return id; } catch (...) {}
  }
  return ids.front();
}

// The current account id: the cached one, else the daemon's identity account (and cache it). Mirrors Android's
// `accountId ?: pickAccount(getAccountList())` fallback so presence/Call ops are robust before the cache is warm.
// Worker thread only (touches libjami) — callers run inside the firewall.
std::string CurrentAccountId() {
  std::string id;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    id = g_accountId;
  }
  if (!id.empty()) return id;
  id = PickAccount(libjami::getAccountList());
  if (!id.empty()) {
    std::lock_guard<std::mutex> lock(g_mutex);
    SelectAccountLocked(id);
  }
  return id;
}

// M8: the MIME under which Syb-L's in-call side-channel JSON (annotation draw events) travels. A custom type so it
// passes straight through to CallSignal::IncomingMessage (not intercepted like confInfo/vcard). Mirrors Android's
// ANNOT_MIME.
static const char* kAnnotMime = "application/x-sybl-annotate";
static const char* kControlMime = "application/x-sybl-control";
constexpr std::size_t kMaxTypedCallMessageBytes = sybl::remote::kMaxPacketBytes;

// presence v2 (ping/pong): the custom MIME for the reachability ping/pong. Payload =
// {"t":"ping"|"pong","fg":0|1,"ts":<sender ms>} — a ping is auto-answered NATIVELY (the answer must never
// depend on the Dart layer being awake). The fg flag is 1 only after the user's
// activity-sharing opt-in, distinguishing in-app (green) from reachable (dim).
// Keep in lockstep with Android JamiCore's presenceJson.
static const char* kProbeMime = "application/x-sybl-presence";
static const char* kFileThumbnailMime =
    "application/x-sybl-file-thumbnail";
static const char* kFileDeclinedMime = "application/x-sybl-file-declined";
static const char* kCallRequestMime = "application/x-sybl-call-request";
// Local foreground truth also gates recording; only explicit activity sharing
// permits that truth onto the presence wire.
static std::atomic<bool> g_foreground{true};
static std::atomic<uint64_t> g_presenceProbeEpoch{0};
struct RecordingOwner {
  uint64_t id;
  AccountCommandOwner account;
  std::string peer;
  std::string conversation;
  std::filesystem::path output;
};
std::optional<RecordingOwner> g_recordingOwner;  // guarded by g_mutex
uint64_t g_recordingSequence = 0;
std::atomic<bool> g_recordingOffline{true};

bool RecordingDesktopCurrent() {
  DWORD process = 0;
  const auto window = GetForegroundWindow();
  if (!window || !GetWindowThreadProcessId(window, &process) ||
      process != GetCurrentProcessId()) return false;
  const auto desktop = OpenInputDesktop(0, FALSE, DESKTOP_READOBJECTS);
  if (!desktop) return false;
  wchar_t name[256]{};
  DWORD required = 0;
  const bool readable = GetUserObjectInformationW(
      desktop, UOI_NAME, name, sizeof(name), &required) != FALSE;
  CloseDesktop(desktop);
  return readable && required <= sizeof(name) &&
      _wcsicmp(name, L"Default") == 0;
}

bool RecordingOwnerCurrent(uint64_t id) {
  if (!g_foreground.load() || g_recordingOffline.load() ||
      !RecordingDesktopCurrent()) return false;
  std::lock_guard<std::mutex> lock(g_mutex);
  return g_recordingOwner && g_recordingOwner->id == id && g_running &&
      g_daemonReady.load() && MediaSlotIdleLocked() &&
      g_recordingOwner->account.accountId == g_accountId &&
      g_recordingOwner->account.revision == g_accountRevision &&
      g_routingSnapshot && g_routingSnapshot->account_id == g_accountId &&
      g_routingSnapshot->Owns(g_recordingOwner->peer,
                            g_recordingOwner->conversation);
}

void RecordingOwnerReleased(uint64_t id) {
  std::filesystem::path output;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (!g_recordingOwner || g_recordingOwner->id != id) return;
    output = g_recordingOwner->output;
    g_recordingOwner.reset();
  }
  // A completed clip belongs to review/publication. Only an unused empty
  // reservation can be removed by lease retirement.
  const auto root = sybl::picked_file::DefaultStagingRoot();
  std::error_code error;
  if (root && sybl::picked_file::IsOwned(output, *root) &&
      std::filesystem::file_size(output, error) == 0 && !error) {
    std::lock_guard<std::mutex> lock(g_mutex);
    const auto encoded = output.u8string();
    const std::string path(encoded.begin(), encoded.end());
    auto& registry = StageRegistryLocked();
    if (!registry.OwnsIssued(path) && sybl::picked_file::Discard(output, *root))
      registry.Forget(path);
  }
}
// Explicit local opt-in. This is presence metadata only; capture protection
// never consults this flag or any process information.
static std::atomic<bool> g_shareActivityPresence{false};
static std::atomic<std::size_t> g_identityColor{0};

std::string PresenceJson(const char* t) {
  const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                      std::chrono::system_clock::now().time_since_epoch())
                      .count();
  const std::string activity = g_shareActivityPresence.load()
      ? sybl::presence_metadata::ForegroundApplicationLabel(
            GetCurrentProcessId())
      : std::string();
  return sybl::presence_wire::Encode(
      t, g_shareActivityPresence.load() && g_foreground.load(), ms, activity,
      sybl::identity_color_wire::Key(g_identityColor.load()));
}

// Reduce a daemon peer URI ("jami:<hex>" or "<hex>@ring.dht") to the bare 40-hex the Dart layer stores and
// compares by exact equality (mirrors JamiCore's removePrefix("jami:") / substringBefore("@")).
std::string BareJamiId(std::string uri) {
  const std::string prefix = "jami:";
  if (uri.rfind(prefix, 0) == 0) uri.erase(0, prefix.size());
  auto at = uri.find('@');
  if (at != std::string::npos) uri.erase(at);
  if (uri.size() != 40) return {};
  for (char& ch : uri) {
    if (ch >= 'A' && ch <= 'F') ch = static_cast<char>(ch - 'A' + 'a');
    if (!((ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f'))) return {};
  }
  return uri;
}

// A StateChange can precede IncomingCall and the placeCallWithMedia reply. Resolve identity from the call itself;
// never attribute an unknown callback to whichever peer happens to be in a concurrent placement request.
std::string CallPeerFromDaemon(const std::string& accountId, const std::string& callId) {
  const auto details = libjami::getCallDetails(accountId, callId);
  const auto device = details.find(libjami::Call::Details::AUTHENTICATED_PEER_DEVICE_ID);
  if (device == details.end() || device->second.empty()) return {};
  const auto peer = details.find(libjami::Call::Details::AUTHENTICATED_PEER_ACCOUNT_ID);
  return peer != details.end() ? BareJamiId(peer->second) : std::string();
}

// ---- 1:1 voice media helpers (UPPERCASE keys/values per media_const.h; mirror Android JamiCore) ----

std::string MapGet(const std::map<std::string, std::string>& m, const std::string& key, const std::string& def) {
  auto it = m.find(key);
  return it != m.end() ? it->second : def;
}

// One audio media entry wrapped in a list — audio-only calls (no camera).
std::vector<std::map<std::string, std::string>> AudioMediaList(bool micMuted) {
  return {{
      {"MEDIA_TYPE", "MEDIA_TYPE_AUDIO"},
      {"ENABLED", "true"},
      {"MUTED", micMuted ? "true" : "false"},
      {"LABEL", "audio_0"},
      {"SOURCE", ""},
      {"HOLD", "false"},
  }};
}

// audio_0 + video_0 (UPPERCASE keys; video SOURCE = the "camera://<dev>" MRL the daemon opens + captures). Used to
// turn our camera on/off mid-call via requestMediaChange. The media COUNT stays 2 (audio+video) so a non-multistream
// peer doesn't reject the change (sipcall.cpp:2464). To actually RELEASE the daemon-captured camera (LED/battery)
// the video entry must be ENABLED=false: that makes the daemon stop + not restart the local video stream
// (sipcall.cpp:2041 skips a disabled stream; the prior stopAllMedia resets videoLocal_). A merely MUTED-but-enabled
// video keeps the camera capturing (stopSender only). videoMuted controls the SEND mute when the video IS enabled.
std::vector<std::map<std::string, std::string>> VideoMediaList(bool micMuted, bool videoEnabled, bool videoMuted,
                                                               const std::string& source) {
  return {
      {{"MEDIA_TYPE", "MEDIA_TYPE_AUDIO"}, {"ENABLED", "true"}, {"MUTED", micMuted ? "true" : "false"},
       {"LABEL", "audio_0"}, {"SOURCE", ""}, {"HOLD", "false"}},
      {{"MEDIA_TYPE", "MEDIA_TYPE_VIDEO"}, {"ENABLED", videoEnabled ? "true" : "false"},
       {"MUTED", videoMuted ? "true" : "false"}, {"LABEL", "video_0"}, {"SOURCE", source}, {"HOLD", "false"}},
  };
}

std::vector<std::map<std::string, std::string>> ReplaceVideoSource(
    std::vector<std::map<std::string, std::string>> media, bool enabled,
    const std::string& source) {
  bool found = false;
  for (auto& entry : media) {
    if (MapGet(entry, "MEDIA_TYPE", "") != "MEDIA_TYPE_VIDEO") continue;
    entry["ENABLED"] = enabled ? "true" : "false";
    entry["MUTED"] = enabled ? "false" : "true";
    entry["SOURCE"] = enabled ? source : "";
    entry["HOLD"] = "false";
    found = true;
  }
  if (!found) {
    media.push_back({{"MEDIA_TYPE", "MEDIA_TYPE_VIDEO"},
                     {"ENABLED", enabled ? "true" : "false"},
                     {"MUTED", enabled ? "false" : "true"},
                     {"LABEL", "video_0"},
                     {"SOURCE", enabled ? source : ""},
                     {"HOLD", "false"}});
  }
  return media;
}

void EmitOutgoingVideoSource(const std::string& accountId,
                             const screen_source::Outgoing& source) {
  EmitControl(ControlSignal{
      ControlSignalType::kSourceChanged,
      accountId,
      source.call_id,
      {},
      {},
      {},
      source.uri,
      source.epoch,
      source.width,
      source.height,
      source.kind == screen_source::Kind::Screen,
  });
  Emit("outgoingVideoSource",
       {{"accountId", accountId},
        {"callId", source.call_id},
        {"outgoingVideoKind", screen_source::KindName(source.kind)},
        {"outgoingVideoUri", source.uri},
        {"outgoingVideoRevision", std::to_string(source.epoch)},
        {"outgoingVideoWidth", std::to_string(source.width)},
        {"outgoingVideoHeight", std::to_string(source.height)},
        {"cameraOn", source.kind == screen_source::Kind::Camera ? "true" : "false"}});
}

struct NegotiatedVideo {
  bool active = false;
  std::string uri;
};

NegotiatedVideo ActiveLocalVideo(
    const std::vector<std::map<std::string, std::string>>& media) {
  for (const auto& entry : media) {
    if (MapGet(entry, "MEDIA_TYPE", "") == "MEDIA_TYPE_VIDEO" &&
        MapGet(entry, "ENABLED", "") == "true" &&
        MapGet(entry, "MUTED", "") == "false" &&
        MapGet(entry, "HOLD", "") == "false") {
      return {true, MapGet(entry, "SOURCE", "")};
    }
  }
  return {};
}

struct AuthenticatedCallPeer {
  std::string accountId;
  std::string deviceId;
  sybl::remote::LocalIcePath localIcePath =
      sybl::remote::LocalIcePath::kUnknown;
  bool localLanProven = false;
};

std::vector<sybl::remote::LocalAdapterPrefix> CachedLocalAdapterPrefixes() {
  static std::mutex cache_mutex;
  static std::vector<sybl::remote::LocalAdapterPrefix> cached;
  static ULONGLONG observed_at = 0;
  std::lock_guard<std::mutex> lock(cache_mutex);
  const auto now = GetTickCount64();
  if (observed_at == 0 || now - observed_at >= 5000) {
    cached = sybl::remote::CurrentLocalAdapterPrefixes();
    observed_at = now;
  }
  return cached;
}

AuthenticatedCallPeer AuthenticatedPeerFromDaemon(const std::string& accountId,
                                                   const std::string& callId) {
  const auto details = libjami::getCallDetails(accountId, callId);
  const auto account = details.find(
      libjami::Call::Details::AUTHENTICATED_PEER_ACCOUNT_ID);
  const auto device = details.find(
      libjami::Call::Details::AUTHENTICATED_PEER_DEVICE_ID);
  const auto sockets = details.find(libjami::Call::Details::SOCKETS);
  const auto ice = sockets == details.end()
      ? sybl::remote::LocalIceObservation{}
      : sybl::remote::ParseLocalIceObservation(sockets->second);
  const bool local_lan_proven =
      ice.path == sybl::remote::LocalIcePath::kHostToHost &&
      !ice.local_address.empty() && !ice.remote_address.empty() &&
      sybl::remote::IsProvenSameLan(
          ice, CachedLocalAdapterPrefixes());
  return {
      account == details.end() ? std::string() : BareJamiId(account->second),
      device == details.end() ? std::string() : device->second,
      ice.path,
      local_lan_proven,
  };
}

bool NegotiationMatches(const screen_source::Outgoing& source,
                        const NegotiatedVideo& negotiated) {
  if (source.kind == screen_source::Kind::Off) return !negotiated.active;
  return negotiated.active && !source.uri.empty() && negotiated.uri == source.uri;
}

bool MediaOwnsLocalVideoSource(
    const std::vector<std::map<std::string, std::string>>& media,
    const std::string& source) {
  return std::any_of(media.begin(), media.end(), [&source](const auto& entry) {
    return MapGet(entry, "MEDIA_TYPE", "") == "MEDIA_TYPE_VIDEO" &&
        MapGet(entry, "ENABLED", "") == "true" && MapGet(entry, "MUTED", "") == "false" &&
        MapGet(entry, "HOLD", "") == "false" && MapGet(entry, "SOURCE", "") == source;
  });
}

bool IsAuthoritativeCallLocked(const std::string& callId) {
  return !callId.empty() && g_activeCallId == callId && g_currentWinnerCallId == callId &&
      g_recentTerminalCallIds.find(callId) == g_recentTerminalCallIds.end();
}

// Runs only on the daemon worker. Ring IDs come from the admitted call's
// negotiated media, never a widget-supplied ID or an all-rings wildcard.
void RefreshRemoteAudioMeters() {
  try {
    RemoteAudioMeterOwner previous;
    RemoteAudioMeterOwner next;
    {
      std::lock_guard<std::mutex> lock(g_mutex);
      previous = g_remoteAudioMeters;
      if (g_audioMeterRequested && !g_identityActivationPending &&
          IsAuthoritativeCallLocked(g_activeCallId)) {
        next.account = g_accountId;
        next.revision = g_accountRevision;
        next.call = g_activeCallId;
      }
      // A callback cannot publish under the previous owner's authority while
      // the worker replaces or disables its meter subscription.
      g_remoteAudioMeters = {};
    }
    for (const auto& stream : previous.streams) {
      libjami::setAudioMeterState(stream, false);
    }
    if (!next.call.empty()) {
      for (const auto& media : libjami::currentMediaList(next.account, next.call)) {
        const auto label = MapGet(media, "LABEL", "");
        if (MapGet(media, "MEDIA_TYPE", "") != "MEDIA_TYPE_AUDIO" ||
            MapGet(media, "ENABLED", "") != "true" || label.empty() || label.size() > 128 ||
            !std::all_of(label.begin(), label.end(), [](unsigned char c) {
              return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                  (c >= '0' && c <= '9') || c == '_' || c == '-';
            })) continue;
        // Matched daemon sip_utils::streamId(callId,label). Receive rings may
        // be created after CURRENT, so unobserved rings remain unknown and a
        // bounded probe from capture-meter callbacks retries later.
        const auto stream = next.call + "_" + label;
        libjami::setAudioMeterState(stream, true);
        if (libjami::isAudioMeterActive(stream)) next.streams.insert(stream);
      }
    }
    bool current = false;
    {
      std::lock_guard<std::mutex> lock(g_mutex);
      current = g_audioMeterRequested && next.account == g_accountId &&
          next.revision == g_accountRevision && !g_identityActivationPending &&
          IsAuthoritativeCallLocked(next.call);
      if (current) g_remoteAudioMeters = next;
    }
    if (!current) for (const auto& stream : next.streams) {
      libjami::setAudioMeterState(stream, false);
    }
  } catch (...) {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_remoteAudioMeters = {};
  }
}

// A placement may share the same physical source with a call that became CURRENT while placeCall was pending.
// Retain it only when that authoritative call already owns the exact active source. Do not manufacture a media
// transfer here: requestMediaChange mutates currentMediaList optimistically and has no transaction-scoped result.
bool AdoptPlacementCameraIfOwned(const std::string& accountId, const std::string& winnerCallId,
                                 const std::string& source) {
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (!IsAuthoritativeCallLocked(winnerCallId)) return false;
  }
  try {
    const auto current = libjami::currentMediaList(accountId, winnerCallId);
    if (!MediaOwnsLocalVideoSource(current, source)) return false;
    std::lock_guard<std::mutex> lock(g_mutex);
    return IsAuthoritativeCallLocked(winnerCallId);
  } catch (...) {
    Log("placement camera ownership check threw");
    return false;
  }
}

void EmitOutgoingSourceIfAuthoritative(const std::string& accountId,
                                       const std::string& callId) {
  std::lock_guard<std::mutex> dispatch(g_callSignalMutex);
  screen_source::Outgoing source;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (!IsAuthoritativeCallLocked(callId)) return;
    source = g_localVideoSource;
    source.call_id = callId;
  }
  EmitOutgoingVideoSource(accountId, source);
}

// Echo an offered media list back as our answer (same order/count — the daemon expects that): audio carries our
// mute state; a video entry is answered receive-only (MUTED=true, no SOURCE) UNLESS our own camera is already on,
// in which case we send it back active with our camera MRL. Empty offer falls back to plain audio. Mirrors
// JamiCore.mirrorOffer (Android). cameraOn/localMrl let an answer / media-change keep our outgoing video alive.
std::vector<std::map<std::string, std::string>> MirrorOffer(
    const std::vector<std::map<std::string, std::string>>& offer, bool micMuted, bool cameraOn,
    const std::string& localMrl) {
  if (offer.empty()) return AudioMediaList(micMuted);
  std::vector<std::map<std::string, std::string>> out;
  out.reserve(offer.size());
  for (const auto& src : offer) {
    const std::string type = MapGet(src, "MEDIA_TYPE", "");
    bool muted;
    std::string source;
    if (type == "MEDIA_TYPE_AUDIO") {
      muted = micMuted;
    } else if (type == "MEDIA_TYPE_VIDEO") {
      muted = !cameraOn;                       // receive-only unless we are already sending video
      if (cameraOn) source = localMrl;
    } else {
      muted = MapGet(src, "MUTED", "false") == "true";
    }
    out.push_back({
        {"MEDIA_TYPE", type},
        {"ENABLED", "true"},
        {"MUTED", muted ? "true" : "false"},
        {"LABEL", MapGet(src, "LABEL", "")},
        {"SOURCE", source},
        {"HOLD", MapGet(src, "HOLD", "false")},
    });
  }
  return out;
}

bool ListHasActiveVideo(const std::vector<std::map<std::string, std::string>>& offer) {
  for (const auto& m : offer) {
    if (MapGet(m, "MEDIA_TYPE", "") == "MEDIA_TYPE_VIDEO" && MapGet(m, "MUTED", "") != "true" &&
        MapGet(m, "ENABLED", "") != "false")
      return true;
  }
  return false;
}

// Terminal call states (match app_state.dart `_terminal`): the call is over and any cached offer can be dropped.
bool IsTerminalCallState(const std::string& state) {
  return state == "HUNGUP" || state == "OVER" || state == "FAILURE" || state == "BUSY" || state == "PEER_BUSY";
}

void CompleteOutgoingPlacement(const std::shared_ptr<OutgoingPlacementBarrier>& barrier) {
  if (!barrier) return;
  {
    std::lock_guard<std::mutex> lock(barrier->mutex);
    barrier->completed = true;
  }
  barrier->cv.notify_all();
}

void WaitForOutgoingPlacement(const std::shared_ptr<OutgoingPlacementBarrier>& barrier) {
  if (!barrier) return;
  std::unique_lock<std::mutex> lock(barrier->mutex);
  barrier->cv.wait(lock, [&barrier]() { return barrier->completed; });
}

// ---- video render path: daemon decoded sinks -> RGBA -> the runner's frame sink -> Flutter textures ----
// In a 1:1 call there are exactly two sinks: the REMOTE one whose id == the callId, and our LOCAL camera input
// whose id == the "camera://<dev>" MRL. Route by that (mirrors Android onDecodingStarted/Stopped).
std::string RoleForSink(const std::string& sinkId) {
  std::lock_guard<std::mutex> lock(g_mutex);
  const auto owner = ActiveMediaTargetLocked();
  const auto leg = g_groupCallLegs.find(owner);
  if (sybl::group_call::OwnsMediaSink(
          owner, leg == g_groupCallLegs.end() ? std::string{} : leg->second,
          sinkId)) {
    return "remote";
  }
  if (!g_localVideoSource.uri.empty() && sinkId == g_localVideoSource.uri) return "self";
  return {};
}

// push() side (daemon decoder thread): the daemon's scaler already converted the frame INTO our RGBA pull-buffer.
// Repack to a tight stride (FlutterDesktopPixelBuffer has no stride field) and hand it to the runner's sink.
void EmitVideoFrame(SinkRender* sr, const AVFrame* frame) {
  VideoFrameSink sink;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    sink = g_frameSink;
  }
  if (!sink) return;
  const int w = frame->width, h = frame->height;
  const auto byteCount = sybl::video::DecodedRgbaByteCount(w, h);
  if (!byteCount || frame->format != AV_PIX_FMT_RGBA || !frame->data[0])
    return;
  const size_t dstStride = static_cast<size_t>(w) * 4;
  const uint8_t* src = frame->data[0];
  const int srcStride = frame->linesize[0];
  if (srcStride < 0 || static_cast<size_t>(srcStride) < dstStride) return;
  sr->pack.resize(*byteCount);
  if (srcStride == static_cast<int>(dstStride)) {
    std::memcpy(sr->pack.data(), src, *byteCount);
  } else {
    for (int y = 0; y < h; ++y)
      std::memcpy(sr->pack.data() + static_cast<size_t>(y) * dstStride,
                  src + static_cast<size_t>(y) * srcStride, dstStride);
  }
  sr->framePublished.store(true, std::memory_order_release);
  try {
    sink(sr->role, sr->pack.data(), w, h);
  } catch (...) {
    Log("video frame sink threw");
  }
}

void OnDecodingStopped(const std::string& id);

// DecodingStarted (daemon thread, fired by the sink's setFrameSize on negotiation/capture-start): register a
// TRANSFORMED listener (pull+push) so the daemon scales the decoded frame into our RGBA buffer, and tell Dart the
// role's sink is live. registerSinkTarget here runs on the same decoder/receive thread that owns the sink, so it
// only takes the sink's own mutex — no reentrancy with our worker.
void OnDecodingStarted(const std::string& id, int w, int h) {
  if (!sybl::video::IsSafeDecodedFrameSize(w, h)) {
    Log("decodingStarted rejected unsafe dimensions for sink " + id + ": " +
        std::to_string(w) + "x" + std::to_string(h));
    OnDecodingStopped(id);
    return;
  }
  std::lock_guard<std::mutex> signalLock(g_videoSignalMutex);
  std::string role = RoleForSink(id);
  if (role.empty()) {
    Log("decodingStarted ignored unknown sink " + id);
    return;
  }
  std::shared_ptr<SinkRender> sr = std::make_shared<SinkRender>();
  sr->role = role;
  sr->width = w;
  sr->height = h;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    sr->callId = ActiveMediaTargetLocked();
    if (role == "self" && g_localVideoSource.uri == id) {
      sr->sourceUri = id;
      sr->sourceRevision = g_localVideoSource.epoch;
    }
    g_sinks[id] = sr;
  }
  std::weak_ptr<SinkRender> wsr = sr;
  libjami::SinkTarget target;
  target.preferredFormat = AV_PIX_FMT_RGBA;
  // pull(): hand the daemon a fresh RGBA frame at the current size; its scaler converts the decoded frame into it.
  target.pull = [wsr]() -> libjami::FrameBuffer {
    auto sr = wsr.lock();
    if (!sr) return {};
    int pw = sr->width.load(), ph = sr->height.load();
    if (!sybl::video::IsSafeDecodedFrameSize(pw, ph)) return {};
    libjami::FrameBuffer f(av_frame_alloc());
    if (!f) return {};
    f->format = AV_PIX_FMT_RGBA;
    f->width = pw;
    f->height = ph;
    if (av_frame_get_buffer(f.get(), 32) < 0) return {};
    return f;
  };
  // push(): the scaled RGBA frame comes back here — repack + forward to the runner.
  target.push = [wsr](libjami::FrameBuffer frame) {
    auto sr = wsr.lock();
    if (sr && frame)
      EmitVideoFrame(sr.get(), frame.get());
  };
  libjami::registerSinkTarget(id, std::move(target));
  std::string accountId;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    accountId = g_accountId;
  }
  Emit("video", {{"accountId", accountId}, {"callId", sr->callId},
                  {"role", role}, {"active", "true"},
                  {"width", std::to_string(w)}, {"height", std::to_string(h)}});
  Log("decodingStarted(" + id + ") -> " + role + " " + std::to_string(w) + "x" + std::to_string(h));
}

// DecodingStopped (daemon thread): drop the render state (frees SinkRender once any in-flight push releases its
// lock()) + clear the daemon target, and tell Dart the sink went inactive.
void OnDecodingStopped(const std::string& id) {
  std::lock_guard<std::mutex> signalLock(g_videoSignalMutex);
  std::string role, callId, accountId;
  int replacementWidth = 0, replacementHeight = 0;
  bool known = false;
  bool roleStillActive = false;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    auto it = g_sinks.find(id);
    if (it != g_sinks.end()) {
      known = true;
      role = it->second->role;
      callId = it->second->callId;
    }
    accountId = g_accountId;
    g_sinks.erase(id);
    if (known) {
      for (const auto& [replacementId, replacement] : g_sinks) {
        if (replacementId != id && replacement->role == role && replacement->callId == callId) {
          roleStillActive = true;
          replacementWidth = replacement->width.load();
          replacementHeight = replacement->height.load();
          break;
        }
      }
    }
  }
  try {
    libjami::registerSinkTarget(id, libjami::SinkTarget{});  // detach (push/pull cleared)
  } catch (...) {
  }
  if (!known) {
    Log("decodingStopped ignored unknown sink " + id);
    return;
  }
  std::map<std::string, std::string> fields{
      {"accountId", accountId},
      {"callId", callId},
      {"role", role},
      {"active", roleStillActive ? "true" : "false"},
  };
  if (roleStillActive) {
    fields["width"] = std::to_string(replacementWidth);
    fields["height"] = std::to_string(replacementHeight);
  }
  Emit("video", fields);
  Log("decodingStopped(" + id + ") -> " + role +
      (roleStillActive ? " (replacement active)" : ""));
}

// MediaChangeRequested (daemon thread): the peer turned their camera on/off mid-call → mirror their offer and
// answer it (accept their video; ours stays receive-only unless our camera is on). Tell Dart about the peer's
// video. The answer touches the call's media negotiation, so POST it to the worker (mirrors Android
// postAnswerMediaChange) rather than calling deep into libjami from the signal-emit thread.
void OnMediaChangeRequested(const std::string& callId,
                            const std::vector<std::map<std::string, std::string>>& offer) {
  std::string accountId;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (!IsAuthoritativeCallLocked(callId)) return;
    accountId = g_accountId;
  }
  std::string peerSource;
  for (const auto& entry : offer) {
    if (MapGet(entry, "MEDIA_TYPE", "") == "MEDIA_TYPE_VIDEO" &&
        MapGet(entry, "ENABLED", "") == "true" &&
        MapGet(entry, "MUTED", "") == "false") {
      peerSource = MapGet(entry, "SOURCE", "");
      break;
    }
  }
  Emit("peerVideo", {{"accountId", accountId}, {"callId", callId},
                     {"on", ListHasActiveVideo(offer) ? "true" : "false"},
                     {"sourceKind", screen_source::KindName(screen_source::Classify(peerSource))}});
  Post([callId, offer]() {
    try {
      const std::string acc = CurrentAccountId();
      if (!acc.empty()) {
        std::string localMrl;
        {
          std::lock_guard<std::mutex> lock(g_mutex);
          if (!IsAuthoritativeCallLocked(callId) ||
              (g_localVideoSource.kind != screen_source::Kind::Off &&
               g_localVideoSource.call_id != callId)) {
            return;
          }
          localMrl = g_localVideoSource.uri;
        }
        // Build on the serialized worker after any earlier mute/unmute command, so renegotiation cannot apply a
        // stale audio MUTED value after the UI/latch moved on.
        auto answer = MirrorOffer(offer, g_micMuted.load(), !localMrl.empty(), localMrl);
        {
          std::lock_guard<std::mutex> lock(g_mutex);
          if (!IsAuthoritativeCallLocked(callId)) return;
          g_peerMediaAnswersPending.insert(callId);
        }
        bool ok = libjami::answerMediaChangeRequest(acc, callId, answer);
        if (!ok) {
          std::lock_guard<std::mutex> lock(g_mutex);
          g_peerMediaAnswersPending.erase(callId);
        }
        Log("answerMediaChangeRequest(" + callId + ") -> " + (ok ? "true" : "false"));
      }
    } catch (...) {
      std::lock_guard<std::mutex> lock(g_mutex);
      g_peerMediaAnswersPending.erase(callId);
      Log("answerMediaChangeRequest threw");
    }
  });
}

// requestMediaChange only reports that a renegotiation was accepted for
// processing. MediaNegotiationStatus carries the resulting media list and is
// therefore the commit boundary for an outgoing source transition.
void OnMediaNegotiationStatus(
    const std::string& callId,
    const std::string& event,
    const std::vector<std::map<std::string, std::string>>& media) {
  try {
    Post([callId, event, media]() {
      std::function<void(bool)> done;
      screen_source::Outgoing authoritative;
      std::string accountId;
      std::string ownerCallId;
      bool completed = false;
      bool accepted = false;
      bool emit = false;
      bool forceStop = false;
      bool reassertLocalSource = false;
      screen_source::Outgoing sourceToReassert;
      try {
        const auto negotiated = ActiveLocalVideo(media);
        {
          std::lock_guard<std::mutex> lock(g_mutex);
          accountId = g_accountId;
          ownerCallId = MediaOwnerLocked(callId);
          const bool followsPeerAnswer =
              g_peerMediaAnswersPending.erase(callId) != 0;
          if (!IsActiveMediaTargetLocked(ownerCallId)) {
            if (g_sourceTransition &&
                g_sourceTransition->source.requested.call_id == ownerCallId) {
              RollBackCancelledTransitionLocked(*g_sourceTransition);
              done = std::move(g_sourceTransition->done);
              g_sourceTransition.reset();
              completed = true;
            }
          } else if (g_sourceTransition &&
                     g_sourceTransition->source.requested.call_id == ownerCallId) {
            auto pending = std::move(*g_sourceTransition);
            g_sourceTransition.reset();
            done = std::move(pending.done);
            completed = true;

            const bool success = event == "NEGOTIATION_SUCCESS";
            if (screen_source::OwnsTransition(
                    g_localVideoSource, ActiveMediaTargetLocked(), pending.source)) {
              if (success &&
                  NegotiationMatches(pending.source.requested, negotiated)) {
                accepted = true;
                authoritative = screen_source::ResolveTransition(
                    g_localVideoSource, ActiveMediaTargetLocked(), pending.source, true);
                if (authoritative.kind == screen_source::Kind::Camera) {
                  g_cameraIndex = pending.requested_camera_index;
                }
              } else if (!success ||
                         NegotiationMatches(pending.source.previous,
                                            negotiated)) {
                authoritative = screen_source::ResolveTransition(
                    g_localVideoSource, ActiveMediaTargetLocked(), pending.source, false);
                g_cameraIndex = pending.previous_camera_index;
              } else {
                // A successful negotiation selected neither the requested
                // source nor the source we previously owned. Never adopt an
                // implicit daemon fallback (especially a camera) as truth.
                authoritative = {screen_source::Kind::Off, "", ownerCallId,
                                 pending.source.requested.epoch + 1, 0, 0};
                forceStop = negotiated.active;
              }
              g_localVideoSource = authoritative;
              emit = true;
            }
          } else if (event == "NEGOTIATION_SUCCESS" &&
                     g_localVideoSource.call_id == ownerCallId &&
                     !NegotiationMatches(g_localVideoSource, negotiated)) {
            if (screen_source::ShouldReassertAfterPeerAnswer(
                    g_localVideoSource, ActiveMediaTargetLocked(), ownerCallId,
                    followsPeerAnswer, false)) {
              // A peer starting/stopping its own source is not authority to
              // retire ours. Some non-multistream daemon paths momentarily
              // drop the local entry while applying the answer; reassert the
              // exact source intent as a separate local renegotiation.
              sourceToReassert = g_localVideoSource;
              reassertLocalSource = true;
            } else {
              // Truly unsolicited topology is still fail-closed.
              authoritative = {screen_source::Kind::Off, "", ownerCallId,
                               g_localVideoSource.epoch + 1, 0, 0};
              g_localVideoSource = authoritative;
              emit = true;
              forceStop = negotiated.active;
            }
          }
        }

        if (reassertLocalSource && !accountId.empty()) {
          const bool queued = libjami::requestMediaChange(
              accountId, callId,
              ReplaceVideoSource(media, true, sourceToReassert.uri));
          Log("peer media change dropped local source; reassert -> " +
              std::string(queued ? "true" : "false"));
          if (!queued) {
            std::lock_guard<std::mutex> lock(g_mutex);
            if (IsActiveMediaTargetLocked(ownerCallId) &&
                g_localVideoSource.epoch == sourceToReassert.epoch &&
                g_localVideoSource.uri == sourceToReassert.uri) {
              authoritative = {screen_source::Kind::Off, "", ownerCallId,
                               g_localVideoSource.epoch + 1, 0, 0};
              g_localVideoSource = authoritative;
              emit = true;
            }
          }
        }
        if (forceStop && !accountId.empty()) {
          const bool stopAccepted = libjami::requestMediaChange(
              accountId, callId, ReplaceVideoSource(media, false, ""));
          Log("unexpected negotiated video source; fail-closed stop -> " +
              std::string(stopAccepted ? "true" : "false"));
        }
        if (emit) {
          EmitOutgoingVideoSource(accountId, authoritative);
          if (accepted &&
              authoritative.kind == screen_source::Kind::Camera) {
            Emit("cameraFacing", {{"accountId", accountId},
                                  {"callId", callId},
                                  {"front", "true"}});
          }
        }
      } catch (...) {
        Log("media negotiation reconciliation threw");
      }
      if (completed && done) {
        try {
          done(accepted);
        } catch (...) {
        }
      }
    });
  } catch (...) {
    Log("media negotiation reconciliation post failed");
  }
}

// Build the "camera://<dev>" MRL for device index `idx` (clamped), or "" if the host exposes no camera, and set it
// as the daemon default. Worker thread only (touches getDeviceList/setDefaultDevice). *outIdx gets the used index.
std::string CameraMrl(size_t idx, size_t* outIdx) {
  auto devs = libjami::getDeviceList();
  if (devs.empty())
    return std::string();
  size_t i = idx < devs.size() ? idx : 0;
  if (outIdx)
    *outIdx = i;
  libjami::setDefaultDevice(devs[i]);
  return "camera://" + devs[i];
}

// ---- file transfer (M5): swarm-conversation send/download + the incoming/progress callbacks ----

// Our account's 40-hex username (to tell an outgoing swarm file commit from an incoming one). Worker/daemon thread.
std::string MyUsername(const std::string& acc) {
  if (acc.empty()) return std::string();
  auto d = libjami::getAccountDetails(acc);
  auto it = d.find(libjami::Account::ConfProperties::USERNAME);
  return it != d.end() ? it->second : std::string();
}

void PurgePeerTransferStateLocked(const std::string& peer_id);

bool ReconcilePresenceSubscriptions(
    const std::string& acc, const std::set<std::string>& desired) {
  std::set<std::string> previous;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (acc.empty() || acc != g_accountId) return false;
    previous = g_subscribedPeers;
  }
  bool ok = true;
  for (const auto& peer : previous) {
    if (desired.find(peer) != desired.end()) continue;
    try {
      libjami::subscribeBuddy(acc, peer, false);
      std::lock_guard<std::mutex> lock(g_mutex);
      if (acc == g_accountId) g_subscribedPeers.erase(peer);
    } catch (...) {
      ok = false;
      Log("unsubscribeBuddy threw");
    }
  }
  for (const auto& peer : desired) {
    if (previous.find(peer) != previous.end()) continue;
    try {
      libjami::subscribeBuddy(acc, peer, true);
      std::lock_guard<std::mutex> lock(g_mutex);
      if (acc == g_accountId) g_subscribedPeers.insert(peer);
    } catch (...) {
      ok = false;
      Log("subscribeBuddy threw");
    }
  }
  return ok;
}

// Rebuild the immutable multi-friend routing boundary from libjami truth. Worker thread only.
bool RetireControlTrust(const std::string& acc, const std::string& peer) {
  ControlSignal signal;
  signal.type = ControlSignalType::kTrustReduced;
  signal.accountId = acc;
  signal.controllerAccountId = peer;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (acc.empty() || peer.empty() || acc != g_accountId ||
        !g_routingSnapshot || g_routingSnapshot->account_id != acc)
      return false;
    signal.localJamiId = g_routingSnapshot->self_id;
    g_controlTrustEpochs.erase(peer);
    if (g_routingSnapshot->IsTrusted(peer)) {
      auto reduced = std::make_shared<sybl::routing::RoutingSnapshot>(
          *g_routingSnapshot);
      reduced->friends.erase(peer);
      for (auto it = reduced->peer_by_conversation.begin();
           it != reduced->peer_by_conversation.end();)
        it = it->second == peer ? reduced->peer_by_conversation.erase(it)
                                : std::next(it);
      ++reduced->revision;
      ++g_routingGeneration;
      g_routingSnapshot = std::move(reduced);
      PurgePeerTransferStateLocked(peer);
    }
  }
  // Native retirement is synchronous and runs outside the routing lock. The
  // contact callback can interrupt queued input before its worker refresh.
  return EmitControl(signal);
}

bool RefreshRoutingSnapshot(const std::string& acc) {
  uint64_t generation = 0;
  uint64_t revision = 1;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (acc.empty() || acc != g_accountId) return false;
    generation = ++g_routingGeneration;
    revision = g_routingSnapshot ? g_routingSnapshot->revision + 1 : 1;
  }
  const auto contacts = libjami::getContacts(acc);
  sybl::routing::ConversationMembers conversations;
  sybl::routing::ConversationInfos conversation_infos;
  for (const auto& id : libjami::getConversations(acc)) {
    conversations.emplace(id, libjami::getConversationMembers(acc, id));
    conversation_infos.emplace(id, libjami::conversationInfos(acc, id));
  }
  auto next = std::make_shared<const sybl::routing::RoutingSnapshot>(
      sybl::routing::BuildRoutingSnapshot(
          acc, revision, MyUsername(acc), contacts, conversations,
          conversation_infos));
  std::set<std::string> desiredSubscriptions;
  std::vector<std::string> removed_peers;
  for (const auto& [peerId, unused] : next->friends) desiredSubscriptions.insert(peerId);
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (acc != g_accountId || generation != g_routingGeneration) return false;
    if (g_routingSnapshot) {
      for (const auto& [peer_id, unused] : g_routingSnapshot->friends) {
        if (next->friends.find(peer_id) == next->friends.end()) {
          PurgePeerTransferStateLocked(peer_id);
          removed_peers.push_back(peer_id);
        }
      }
    }
    for (auto it = g_controlTrustEpochs.begin(); it != g_controlTrustEpochs.end();)
      it = next->IsTrusted(it->first) ? std::next(it) : g_controlTrustEpochs.erase(it);
    for (const auto& [peer, unused] : next->friends) {
      if (g_controlTrustEpochs.find(peer) == g_controlTrustEpochs.end() &&
          g_nextControlTrustEpoch != 0)
        g_controlTrustEpochs.emplace(peer, g_nextControlTrustEpoch++);
    }
    g_routingSnapshot = next;
  }
  bool retired = true;
  for (const auto& peer : removed_peers)
    retired = RetireControlTrust(acc, peer) && retired;
  ReconcilePresenceSubscriptions(acc, desiredSubscriptions);
  Emit("friendsChanged", {{"accountId", acc}, {"revision", std::to_string(next->revision)}});
  return retired;
}

std::shared_ptr<const sybl::routing::RoutingSnapshot> RoutingSnapshot() {
  std::lock_guard<std::mutex> lock(g_mutex);
  return g_routingSnapshot;
}

bool IsTrustedPeer(const std::string& accountId, const std::string& peer) {
  const auto snapshot = RoutingSnapshot();
  return snapshot && snapshot->account_id == accountId && snapshot->IsTrusted(peer);
}

std::string NormalizeOwnerKey(const std::string& value) {
  if (sybl::routing::GroupConversationId(value)) return value;
  return BareJamiId(value);
}

bool IsOwnedConversation(const std::string& accountId, const std::string& conversationId) {
  const auto snapshot = RoutingSnapshot();
  return snapshot && snapshot->account_id == accountId &&
         !snapshot->OwnerKey(conversationId).empty();
}

std::string ConversationOwner(const std::string& accountId, const std::string& conversationId) {
  const auto snapshot = RoutingSnapshot();
  if (!snapshot || snapshot->account_id != accountId) return {};
  return snapshot->OwnerKey(conversationId);
}

std::optional<sybl::profile_wire::Profile> ReadPeerProfile(
    const std::filesystem::path& path) {
  std::ifstream input(path, std::ios::binary | std::ios::ate);
  if (!input) return std::nullopt;
  const auto size = input.tellg();
  if (size < 0 ||
      static_cast<uint64_t>(size) > sybl::profile_wire::kMaxVCardBytes) {
    return std::nullopt;
  }
  std::string content(static_cast<size_t>(size), '\0');
  input.seekg(0);
  if (!content.empty() &&
      !input.read(content.data(), static_cast<std::streamsize>(content.size()))) {
    return std::nullopt;
  }
  return sybl::profile_wire::DecodeVCard(content);
}

std::optional<sybl::profile_wire::Profile> CachedPeerProfile(
    const std::string& account_id, const std::string& peer_id) {
  return ReadPeerProfile(
      g_jamiDataDir / account_id / "profiles" /
      (jami::base64::encode(peer_id) + ".vcf"));
}

void OnPeerProfile(const std::string& account_id,
                   const std::string& peer_id) {
  if (CurrentAccountId() != account_id) return;
  const auto peer = BareJamiId(peer_id);
  const auto snapshot = RoutingSnapshot();
  if (!snapshot || snapshot->account_id != account_id) return;
  const auto route = snapshot->Friend(peer);
  if (!route || route->canonical_conversation_id.empty()) return;
  const auto profile = CachedPeerProfile(account_id, peer);
  if (!profile) return;
  Emit("friendProfile",
       {{"accountId", account_id},
        {"peerJamiId", peer},
        {"conversationId", route->canonical_conversation_id},
        {"displayName", profile->display_name},
        {"avatarBase64", profile->avatar_base64}});
}

std::string ToUtf8(const std::wstring& w) {
  if (w.empty()) return std::string();
  int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), static_cast<int>(w.size()), nullptr, 0, nullptr, nullptr);
  std::string s(static_cast<size_t>(n), '\0');
  WideCharToMultiByte(CP_UTF8, 0, w.c_str(), static_cast<int>(w.size()), s.data(), n, nullptr, nullptr);
  return s;
}

// The user's Downloads folder (where received files land), wide. Falls back to %USERPROFILE%\Downloads.
std::wstring DownloadDirW() {
  PWSTR p = nullptr;
  std::wstring dir;
  if (SUCCEEDED(sybl::uat::KnownFolderPath(FOLDERID_Downloads, 0, nullptr, &p)) && p) dir = p;
  if (p) CoTaskMemFree(p);
  if (dir.empty()) {
    wchar_t up[MAX_PATH];
    DWORD n = GetEnvironmentVariableW(L"USERPROFILE", up, MAX_PATH);
    if (n > 0 && n < MAX_PATH) dir = std::wstring(up, n) + L"\\Downloads";
  }
  return dir;
}

std::wstring ReceiveDirW() {
  const auto downloads = DownloadDirW();
  return downloads.empty() ? std::wstring{} : downloads + L"\\Syb-L Received";
}

std::filesystem::path OutgoingDir() {
  PWSTR local = nullptr;
  if (FAILED(sybl::uat::KnownFolderPath(
          FOLDERID_LocalAppData, KF_FLAG_CREATE, nullptr, &local)) ||
      !local) {
    return {};
  }
  std::filesystem::path dir(local);
  CoTaskMemFree(local);
  return dir / L"Syb-L" / L"outgoing";
}

std::filesystem::path StageOutgoingFile(const std::string& source_path) {
  const auto dir = OutgoingDir();
  if (dir.empty()) return {};
  return sybl::picked_file::Stage(
             std::filesystem::u8path(source_path), dir,
             sybl::picked_file::kMaxPickedFileBytes)
      .value_or(std::filesystem::path{});
}

// A non-clobbering UTF-8 destination path under Downloads for an incoming file named `name` (UTF-8).
//
// `name` is the SENDER's displayName from the swarm commit — fully UNTRUSTED. Reduce it to a bare leaf via
// .filename() (which strips any directory components AND a drive/root on Windows), reject ./.. /empty, then join.
// Without this, an absolute displayName ("C:\\Windows\\Temp\\x.dll") would make `base / abs` DISCARD base, and a
// relative one ("..\\..\\Startup\\x.exe") would resolve outside Downloads at write time — an arbitrary-write /
// code-exec path reachable over the P2P channel. Defense-in-depth: assert the result stays under Downloads.
std::wstring ReceiveReservationKey(std::wstring path) {
  std::transform(path.begin(), path.end(), path.begin(), [](wchar_t c) { return std::towlower(c); });
  return path;
}

void ReleaseReceiveReservationLocked(const FileKey& file) {
  auto it = g_receiveDestByFile.find(file);
  if (it == g_receiveDestByFile.end()) return;
  g_reservedReceivePaths.erase(ReceiveReservationKey(std::filesystem::u8path(it->second).wstring()));
  g_receiveDestByFile.erase(it);
}

void PurgePeerTransferStateLocked(const std::string& peer_id) {
  for (auto it = g_receiveAttempts.begin(); it != g_receiveAttempts.end();)
    it = it->first.peerId == peer_id ? g_receiveAttempts.erase(it) : std::next(it);
  for (auto it = g_fileMediaMetadata.begin(); it != g_fileMediaMetadata.end();)
    it = it->first.peerId == peer_id ? g_fileMediaMetadata.erase(it) : std::next(it);
  for (auto it = g_xfers.begin(); it != g_xfers.end();)
    it = it->first.peerId == peer_id ? g_xfers.erase(it) : std::next(it);
  for (auto it = g_fileSizes.begin(); it != g_fileSizes.end();)
    it = it->first.peerId == peer_id ? g_fileSizes.erase(it) : std::next(it);
  for (auto it = g_receiveDestByFile.begin(); it != g_receiveDestByFile.end();) {
    if (it->first.peerId != peer_id) {
      ++it;
      continue;
    }
    g_reservedReceivePaths.erase(
        ReceiveReservationKey(std::filesystem::u8path(it->second).wstring()));
    it = g_receiveDestByFile.erase(it);
  }
  g_conversationLoads.RemovePeer(peer_id);
}

std::string ReceiveDestPath(const FileKey& file, const std::string& name) {
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    auto prior = g_receiveDestByFile.find(file);
    if (prior != g_receiveDestByFile.end()) return prior->second;
  }
  std::wstring dirW = ReceiveDirW();
  if (dirW.empty()) return std::string();
  std::error_code ec;
  std::filesystem::create_directories(dirW, ec);
  std::filesystem::path base(dirW);
  std::filesystem::path leaf = std::filesystem::u8path(name.empty() ? "file" : name).filename();
  if (leaf.empty() || leaf == "." || leaf == "..") leaf = std::filesystem::u8path("file");
  // .filename() strips path separators but NOT Windows-reserved chars — notably ':' (an NTFS Alternate Data Stream),
  // so a peer name like "foo.txt:evil.exe" would otherwise smuggle a hidden stream onto a Downloads file. Reject any
  // reserved char and fall back to a safe leaf (matches Android's effective ext4 safety; the under-Downloads guard
  // below still backstops traversal).
  if (leaf.wstring().find_first_of(L":<>\"|?*") != std::wstring::npos) leaf = std::filesystem::u8path("file");
  std::wstring leafW = leaf.wstring();
  leafW.erase(std::remove_if(leafW.begin(), leafW.end(), [](wchar_t c) {
    return c < 0x20 || c == 0x7f;
  }), leafW.end());
  while (!leafW.empty() && (leafW.back() == L'.' || leafW.back() == L' ')) leafW.pop_back();
  if (leafW.size() > 180) leafW.resize(180);
  std::wstring device = leafW.substr(0, leafW.find(L'.'));
  std::transform(device.begin(), device.end(), device.begin(), [](wchar_t c) { return std::towupper(c); });
  const bool dosDevice = device == L"CON" || device == L"PRN" || device == L"AUX" || device == L"NUL" ||
      (device.size() == 4 && (device.rfind(L"COM", 0) == 0 || device.rfind(L"LPT", 0) == 0) &&
       device[3] >= L'1' && device[3] <= L'9');
  if (leafW.empty() || dosDevice) leafW = L"file";
  leaf = std::filesystem::path(leafW);
  std::filesystem::path fname = leaf;
  std::filesystem::path dest = base / fname;
  const std::string stem = ToUtf8(fname.stem().wstring());
  const std::string ext = ToUtf8(fname.extension().wstring());
  int n = 1;
  for (;;) {
    const auto key = ReceiveReservationKey(dest.wstring());
    bool reserved;
    {
      std::lock_guard<std::mutex> lock(g_mutex);
      reserved = g_reservedReceivePaths.find(key) != g_reservedReceivePaths.end();
    }
    if (!std::filesystem::exists(dest, ec) && !reserved) break;
    dest = base / std::filesystem::u8path(stem + " (" + std::to_string(n) + ")" + ext);
    ++n;
  }
  // Defense-in-depth: the joined dest must remain inside Downloads (the sanitized leaf already guarantees it; this
  // catches any future regression). Fail CLOSED — reject if canonicalization errors, or dest isn't STRICTLY under
  // base (boundary-aware so a "Downloads2" sibling can't pass). weakly_canonical handles the not-yet-existent dest.
  std::error_code ecB, ecD;
  const std::wstring b = std::filesystem::weakly_canonical(base, ecB).wstring();
  const std::wstring d = std::filesystem::weakly_canonical(dest, ecD).wstring();
  const bool under = !ecB && !ecD && d.size() > b.size() && d.compare(0, b.size(), b) == 0 &&
                     (d[b.size()] == L'\\' || d[b.size()] == L'/');
  if (!under) {
    Log("ReceiveDestPath: rejected destination outside the receive directory");
    return std::string();
  }
  const std::string result = ToUtf8(dest.wstring());
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_reservedReceivePaths.insert(ReceiveReservationKey(dest.wstring()));
    g_receiveDestByFile[file] = result;
  }
  return result;
}

// Completion is native finalization evidence, including a revalidated file identity/hash.
bool FileDownloaded(const std::string& acc, const std::string& conv, const std::string& fileId) {
  std::string path;
  int64_t total = 0;
  return libjami::fileTransferCompleted(acc, conv, fileId, path, total);
}

// libjami DataTransferEventCode → a UI status string (see datatransfer_interface.h).
const char* FileCodeToStatus(int code) {
  switch (code) {
    case 1: case 3: case 4: return "waiting";  // created / wait_peer_acceptance / wait_host_acceptance
    case 5: return "ongoing";
    case 6: return "finished";
    case 7: return "canceled";                  // closed_by_host
    case 8: return "declined";                  // closed_by_peer
    default: return "error";
  }
}

std::string JsonString(const std::string& value);

std::optional<std::string> TimelineItemJson(const std::string& accountId,
                                            const std::string& peerId,
                                            const std::string& conversationId,
                                            const libjami::SwarmMessage& msg,
                                            bool liveUpdate);

std::optional<int64_t> ParseNonNegativeInt64(const std::string& value) {
  if (!sybl::timeline::IsRequiredUtf8(value, 64)) return std::nullopt;
  int64_t parsed = 0;
  const auto result =
      std::from_chars(value.data(), value.data() + value.size(), parsed);
  if (result.ec != std::errc{} ||
      result.ptr != value.data() + value.size() || parsed < 0) {
    return std::nullopt;
  }
  return parsed;
}

// DataTransferEvent (daemon thread): cache the conv, query bytes on the worker, forward status/progress to Dart.
void OnDataTransferEvent(const std::string& acc, const std::string& conversationId,
                         const std::string& interactionId, const std::string& fileId, int code,
                         const std::string& attemptId = {}) {
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (code >= 3) {
      const ActiveTransferKey key{acc, conversationId, fileId, attemptId};
      if (code == 3 || code == 4 || code == 5) {
        if (acc == g_accountId) {
          g_updateActiveTransfers.insert(key);
          g_updateShutdown.Interrupt();
        }
      } else {
        g_updateActiveTransfers.erase(key);
      }
    }
  }
  // CREATED/INVALID use fileId as the original source path, not a real transfer id. Consume only an exact path
  // created by this process. Only CREATED acknowledges an independent seed;
  // INVALID after a commit must retain the source for repairing that transfer.
  if (code == 1 || code == 2) {
    bool appOwnedStaging = false;
    {
      std::lock_guard<std::mutex> lock(g_mutex);
      appOwnedStaging = g_outgoingStagingPaths.find(fileId) !=
                        g_outgoingStagingPaths.end();
    }
    if (appOwnedStaging) {
      if (code != 1) {
        Log("outgoing seed handoff failed; source retained");
        return;
      }
      const bool removed = sybl::picked_file::Discard(
          std::filesystem::u8path(fileId), OutgoingDir());
      if (removed) {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_outgoingStagingPaths.erase(fileId);
      }
      Log(std::string("outgoing staging handoff ") +
          (code == 1 ? "completed" : "failed") +
          (removed ? "; source removed" : "; cleanup failed"));
      return;
    }
    // These codes carry a private source path, never a timeline file ID.
    return;
  }
  if (!IsOwnedConversation(acc, conversationId)) return;
  const auto peerId = ConversationOwner(acc, conversationId);
  if (peerId.empty()) return;
  const auto owner = CaptureAccountCommandOwner(acc);
  if (!owner) return;
  Post([acc, peerId, conversationId, interactionId, fileId, code, attemptId, owner = *owner]() {
    // Firewall the WHOLE body: WorkerLoop runs task() unguarded on a std::thread, so a throw escaping here
    // (the map initializer-list + std::to_string temporaries can bad_alloc — Emit takes the map by const ref,
    // so it is built at this call site, OUTSIDE Emit's own try) would reach std::terminate. Mirrors the siblings.
    try {
      if (!OwnsAccountCommand(owner) || !IsOwnedConversation(acc, conversationId)) return;
      const FileKey key{peerId, conversationId, fileId};
      const auto ownsAttemptLocked = [&]() {
        if (owner.accountId != g_accountId || owner.revision != g_accountRevision) return false;
        const auto attempt = g_receiveAttempts.find(key);
        const auto metadata = g_xfers.find(key);
        return attemptId.empty()
            ? metadata != g_xfers.end() && metadata->second.outgoing
            : attempt != g_receiveAttempts.end() && attempt->second == attemptId;
      };
      bool outgoing = false;
      std::string name;
      std::string authorId;
      std::string topicId = sybl::dm_topic::kMain;
      bool topicTagged = false;
      std::string roomId;
      {
        std::lock_guard<std::mutex> lock(g_mutex);
        if (!ownsAttemptLocked()) return;
        auto it = g_xfers.find(key);
        if (it != g_xfers.end()) {
          outgoing = it->second.outgoing;
          name = it->second.name;
          authorId = it->second.authorId;
          topicId = it->second.topicId;
          topicTagged = it->second.topicTagged;
          roomId = it->second.roomId;
        }
      }
      std::string path;
      int64_t total = 0, progress = 0;
      libjami::fileTransferInfo(acc, conversationId, fileId, path, total, progress);  // noexcept
      int64_t completedSize = 0;
      const bool completed = libjami::fileTransferCompleted(acc, conversationId, fileId, path, completedSize);
      if (completed) { total = completedSize; progress = completedSize; }
      const char* status = code == 6 && !completed ? "error" : FileCodeToStatus(code);
      {
        std::lock_guard<std::mutex> lock(g_mutex);
        if (!ownsAttemptLocked()) return;
      }
      Emit("fileProgress", {{"accountId", acc}, {"peerJamiId", peerId},
                            {"conversationId", conversationId}, {"fileId", fileId},
                            {"interactionId", interactionId}, {"attemptId", attemptId},
                            {"outgoing", outgoing ? "true" : "false"}, {"name", name},
                            {"authorId", authorId},
                            {"roomId", roomId}, {"topicId", topicId},
                            {"topicTagged", topicTagged ? "true" : "false"},
                            {"status", status}, {"completed", completed ? "true" : "false"}, {"transferred", std::to_string(progress)},
                            {"total", std::to_string(total)}, {"path", path}});
      // Release the metadata once terminal (not created/wait/ongoing) so g_xfers stays bounded over the long process.
      if (code != 1 && code != 3 && code != 4 && code != 5) {
        std::lock_guard<std::mutex> lock(g_mutex);
        if (!ownsAttemptLocked()) return;
        g_xfers.erase(key);
        if (!attemptId.empty()) {
          g_receiveAttempts.erase(key);
          ReleaseReceiveReservationLocked(key);
        }
      }
    } catch (...) {
      Log("onDataTransferEvent threw");
    }
  });
}

// SwarmMessageReceived (daemon thread): a file commit → record it + (incoming only) offer it to the UI. Read the
// message synchronously — the daemon-owned SwarmMessage is only valid for this callback.
void OnReaction(const std::string& accountId, const std::string& conversationId,
                const std::string& messageId,
                const std::map<std::string, std::string>* reaction,
                const std::string& removedId = {}) {
  if (!IsOwnedConversation(accountId, conversationId) || !sybl::reaction::Identity(messageId)) return;
  const auto owner = ConversationOwner(accountId, conversationId);
  const auto snapshot = RoutingSnapshot();
  if (owner.empty() || !snapshot || snapshot->account_id != accountId ||
      !snapshot->Owns(owner, conversationId)) return;
  const bool group = snapshot->Group(conversationId) != nullptr;
  std::string item = "{\"accountId\":" + JsonString(accountId) + ",\"peerId\":" + JsonString(owner) +
      ",\"conversationId\":" + JsonString(conversationId) + ",\"messageId\":" + JsonString(messageId) +
      ",\"authenticatedGroupHistory\":" + (group ? "true" : "false");
  if (reaction) {
    const auto me = MyUsername(accountId);
    const auto projection = sybl::reaction::Project(messageId, {*reaction}, BareJamiId,
        [&](const std::string& author) {
          return group || author == me || snapshot->AcceptsRemoteAuthor(owner, conversationId, author);
        });
    if (projection.entries.size() != 1) return;
    const auto& entry = projection.entries.front();
    item += ",\"reaction\":{\"commitId\":" + JsonString(entry.commit_id) +
        ",\"authorId\":" + JsonString(entry.author_id) + ",\"emoji\":" + JsonString(entry.emoji) + "}";
  } else {
    if (!sybl::reaction::Identity(removedId) || removedId == messageId) return;
    item += ",\"removedId\":" + JsonString(removedId);
  }
  item += '}';
  Emit("chatReaction", {{"accountId", accountId}, {"peerJamiId", owner},
      {"conversationId", conversationId}, {"itemJson", item}});
}

void OnSwarmMessage(const std::string& accountId, const std::string& conversationId,
                    const libjami::SwarmMessage& msg) {
  if (!IsOwnedConversation(accountId, conversationId)) return;
  const auto peerId = ConversationOwner(accountId, conversationId);
  if (peerId.empty()) return;
  if (const auto item = TimelineItemJson(
          accountId, peerId, conversationId, msg, false)) {
    Emit("chatMessage", {{"accountId", accountId}, {"peerJamiId", peerId},
                         {"conversationId", conversationId}, {"itemJson", *item}});
  }
  if (msg.type != "application/data-transfer+json") return;
  auto fit = msg.body.find("fileId");
  std::string fileId = fit != msg.body.end() ? fit->second : std::string();
  if (fileId.empty()) return;  // a delete/edit commit carries an empty fileId — ignore
  std::string interactionId = msg.id;
  std::string name = "file";
  if (auto it = msg.body.find("displayName"); it != msg.body.end()) name = it->second;
  int64_t size = -1;
  if (auto it = msg.body.find("totalSize"); it != msg.body.end()) {
    const auto parsed = ParseNonNegativeInt64(it->second);
    if (!parsed) return;
    size = *parsed;
  }
  std::string sha3;
  if (auto it = msg.body.find("sha3sum"); it != msg.body.end()) sha3 = it->second;
  std::string timestamp;
  if (auto it = msg.body.find("timestamp"); it != msg.body.end()) timestamp = it->second;
  std::string author;
  if (auto it = msg.body.find("author"); it != msg.body.end()) author = it->second;
  // File/folder events bypass TimelineItemJson, so apply the same strict
  // boundary before daemon-controlled strings reach Flutter.
  if (!sybl::timeline::IsRequiredUtf8(
          accountId, sybl::timeline::kMaxDaemonIdCodeUnits) ||
      !sybl::timeline::IsRequiredUtf8(
          peerId, sybl::timeline::kMaxAuthorIdCodeUnits) ||
      !sybl::timeline::IsRequiredUtf8(
          conversationId, sybl::timeline::kMaxDaemonIdCodeUnits) ||
      !sybl::timeline::IsRequiredUtf8(
          interactionId, sybl::timeline::kMaxDaemonIdCodeUnits) ||
      !sybl::timeline::IsRequiredUtf8(
          fileId, sybl::timeline::kMaxFileIdCodeUnits) ||
      !sybl::timeline::IsRequiredUtf8(
          name, sybl::timeline::kMaxDisplayNameCodeUnits) ||
      !sybl::timeline::IsOptionalUtf8(
          sha3, sybl::timeline::kMaxHashCodeUnits) ||
      !sybl::timeline::IsRequiredUtf8(
          author, sybl::timeline::kMaxAuthorIdCodeUnits) ||
      !sybl::timeline::IsRequiredUtf8(timestamp, 64)) {
    return;
  }
  if (!ParseNonNegativeInt64(timestamp)) return;
  const bool outgoing = BareJamiId(author) == MyUsername(accountId);
  if (!outgoing) {
    const auto snapshot = RoutingSnapshot();
    if (!snapshot ||
        !snapshot->AcceptsRemoteAuthor(peerId, conversationId, author)) {
      return;
    }
  }
  const auto rich = sybl::rich_timeline::Project(msg.body, sybl::routing::GroupConversationId(peerId).has_value());
  if (!rich) return;
  const auto room = rich->find("roomId");
  const std::string roomId = room == rich->end() ? std::string{} : room->second;
  const auto topicIt = msg.body.find(sybl::dm_topic::kItemField);
  const auto topic = sybl::dm_topic::NormalizeItemTopic(
      topicIt == msg.body.end() ? std::string{} : topicIt->second);
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    const FileKey key{peerId, conversationId, fileId};
    g_fileSizes[key] = size;
    if (const auto media = msg.body.find("sybl-media-v1"); media != msg.body.end())
      g_fileMediaMetadata[key] = sybl::rich_timeline::BoundedBody(media->second) ? media->second : std::string{};
    g_xfers.try_emplace(key,
        FileXferMeta{interactionId, name, BareJamiId(author), topic.topic_id,
                     size, outgoing, topic.tagged, roomId});
  }
  if (!outgoing) {
    Emit("incomingFile", {{"accountId", accountId}, {"peerJamiId", peerId},
                          {"conversationId", conversationId}, {"fileId", fileId},
                          {"interactionId", interactionId}, {"name", name},
                          {"size", std::to_string(size)},
                          {"authorId", BareJamiId(author)},
                          {"roomId", roomId}, {"topicId", topic.topic_id},
                          {"topicTagged", topic.tagged ? "true" : "false"}});
  }
  // Also surface it in the persistent shared folder (M6) so a file shared THIS session is kept without a restart.
  // live=true → an optimistic per-message emit; a reload (OnSwarmLoaded, live absent) is the authoritative scan.
  Emit("folderFile", {{"accountId", accountId}, {"peerJamiId", peerId}, {"fileId", fileId},
                      {"interactionId", interactionId}, {"conversationId", conversationId},
                      {"name", name}, {"size", std::to_string(size)}, {"sha3", sha3},
                      {"outgoing", outgoing ? "true" : "false"},
                      {"authorId", BareJamiId(author)},
                      {"roomId", roomId}, {"topicId", topic.topic_id},
                      {"topicTagged", topic.tagged ? "true" : "false"},
                      {"downloaded", FileDownloaded(accountId, conversationId, fileId) ? "true" : "false"},
                      {"timestamp", timestamp}, {"live", "true"}});
  Log("Authenticated swarm file projected");
}

void OnSwarmMessageUpdated(const std::string& accountId, const std::string& conversationId,
                           const libjami::SwarmMessage& msg) {
  if (!IsOwnedConversation(accountId, conversationId)) return;
  const auto peerId = ConversationOwner(accountId, conversationId);
  if (peerId.empty()) return;
  if (const auto item = TimelineItemJson(accountId, peerId, conversationId, msg, true)) {
    Emit("chatMessage", {{"accountId", accountId}, {"peerJamiId", peerId},
                         {"conversationId", conversationId}, {"itemJson", *item}});
  }
}

std::string JsonString(const std::string& value) {
  Json::StreamWriterBuilder writer;
  writer["indentation"] = "";
  writer["emitUTF8"] = true;
  return Json::writeString(writer, Json::Value(value));
}

std::string GroupCallsJson(
    const std::vector<std::map<std::string, std::string>>& calls) {
  std::string result{"["};
  bool first = true;
  for (const auto& call : calls) {
    const auto id = call.find("id");
    const auto uri = call.find("uri");
    const auto device = call.find("device");
    if (id == call.end() || uri == call.end() || device == call.end() ||
        sybl::group_call::RoomId(id->second).empty() || uri->second.empty() ||
        device->second.empty()) {
      continue;
    }
    if (!first) result += ',';
    first = false;
    result += "{\"conferenceId\":" + JsonString(id->second) +
              ",\"hostUri\":" + JsonString(BareJamiId(uri->second)) +
              ",\"hostDevice\":" + JsonString(device->second) + "}";
  }
  result += ']';
  return result;
}

std::string StringMapsJson(
    const std::vector<std::map<std::string, std::string>>& values) {
  std::string result{"["};
  bool firstValue = true;
  for (const auto& value : values) {
    if (!firstValue) result += ',';
    firstValue = false;
    result += '{';
    bool firstField = true;
    for (const auto& field : value) {
      if (!firstField) result += ',';
      firstField = false;
      result += JsonString(field.first) + ':' + JsonString(field.second);
    }
    result += '}';
  }
  result += ']';
  return result;
}

void ProcessConferenceInfoRequest(const ConferenceInfoRequest& request) {
  if (!OwnsAccountCommand(request.owner)) return;
  const auto infos = libjami::getConferenceInfos(request.owner.accountId, request.daemonId);
  if (!sybl::group_call::ConferenceInfoWithinBounds(infos)) return;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (request.owner.accountId != g_accountId || request.owner.revision != g_accountRevision ||
        g_groupReservationId != request.reservation ||
        (request.conferenceId != g_activeGroupConferenceId &&
         request.conferenceId != g_pendingGroupConferenceId)) return;
  }
  Emit("groupConferenceInfo", {{"accountId", request.owner.accountId},
      {"reservationId", request.reservation}, {"conferenceId", request.conferenceId},
      {"participantsJson", StringMapsJson(infos)}});
}

std::string GroupConferenceForCall(const std::string& accountId,
                                   const std::string& callId) {
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (accountId != g_accountId) return {};
    const auto retired = g_retiredGroupLegs.find(callId);
    if (retired != g_retiredGroupLegs.end() && retired->second == g_accountRevision) return {};
    for (const auto& entry : g_groupCallLegs) {
      if (entry.second == callId) return entry.first;
    }
  }
  std::string conferenceId;
  try { conferenceId = libjami::getConferenceId(accountId, callId); }
  catch (...) {}
  if (!sybl::group_call::RoomId(conferenceId).empty()) {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (accountId != g_accountId ||
        (conferenceId != g_activeGroupConferenceId &&
         conferenceId != g_pendingGroupConferenceId) ||
        g_groupConversationByConference.count(conferenceId) == 0) return {};
    const auto known = g_groupCallLegs.find(conferenceId);
    if (!g_activeGroupHosting && known != g_groupCallLegs.end() && known->second != callId) return {};
    if (!g_activeGroupHosting) g_groupCallLegs[conferenceId] = callId;
    return conferenceId;
  }
  return {};
}

bool ClearGroupCall(const std::string& accountId,
                    const std::string& conferenceId,
                    const std::string& expectedReservation = {},
                    uint64_t expectedRevision = 0) {
  std::string conversationId;
  std::optional<std::string> previous;
  std::function<void(bool)> cancelledVideo;
  bool hadPrevious = false;
  std::optional<double> playbackVolume;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (accountId != g_accountId ||
        (expectedRevision && expectedRevision != g_accountRevision) ||
        (!expectedReservation.empty() && expectedReservation != g_groupReservationId) ||
        (g_activeGroupConferenceId != conferenceId && g_pendingGroupConferenceId != conferenceId)) return false;
    playbackVolume = g_previousGroupPlaybackVolume;
    g_previousGroupPlaybackVolume.reset();
    if (g_activeGroupConferenceId == conferenceId || g_pendingGroupConferenceId == conferenceId) {
      if (!g_groupReservationId.empty()) {
        g_detachedGroupReservations[{conferenceId, g_groupReservationId}] = g_accountRevision;
        while (g_detachedGroupReservations.size() > 64) g_detachedGroupReservations.erase(g_detachedGroupReservations.begin());
      }
      g_groupReservationId.clear();
      g_groupPlacementStarted = false;
    }
    if (g_activeGroupConferenceId == conferenceId) {
      g_activeGroupConferenceId.clear();
      g_activeGroupHosting = false;
    }
    if (g_pendingGroupConferenceId == conferenceId) {
      g_pendingGroupConferenceId.clear();
      g_activeGroupHosting = false;
    }
    if (g_sourceTransition &&
        g_sourceTransition->source.requested.call_id == conferenceId) {
      RollBackCancelledTransitionLocked(*g_sourceTransition);
      cancelledVideo = std::move(g_sourceTransition->done);
      g_sourceTransition.reset();
    }
    if (g_localVideoSource.call_id == conferenceId) g_localVideoSource = {};
    const auto leg = g_groupCallLegs.find(conferenceId);
    if (leg != g_groupCallLegs.end()) {
      g_retiredGroupLegs[leg->second] = g_accountRevision;
      while (g_retiredGroupLegs.size() > 64) g_retiredGroupLegs.erase(g_retiredGroupLegs.begin());
      g_groupCallLegs.erase(leg);
    }
    const auto conversation = g_groupConversationByConference.find(conferenceId);
    if (conversation != g_groupConversationByConference.end()) {
      conversationId = conversation->second;
      g_groupConversationByConference.erase(conversation);
      const auto saved = g_previousGroupHostPreference.find(conversationId);
      if (saved != g_previousGroupHostPreference.end()) {
        previous = saved->second;
        hadPrevious = true;
        g_previousGroupHostPreference.erase(saved);
      }
    }
  }
  if (cancelledVideo) {
    try { cancelledVideo(false); } catch (...) {}
  }
  if (hadPrevious && !conversationId.empty()) {
    try {
      // libjami has no single-preference delete API. An absent original value
      // is restored to the mobile-safe false value.
      libjami::setConversationPreferences(
          accountId, conversationId,
          {{"hostConferences", previous.value_or("false")}});
    } catch (...) {}
  }
  if (playbackVolume) {
    try { libjami::setVolume("speaker", *playbackVolume); } catch (...) {}
  }
  return true;
}

std::optional<int64_t> CommitTimestampSeconds(const libjami::SwarmMessage& msg) {
  const auto timestamp = msg.body.find("timestamp");
  return timestamp == msg.body.end()
             ? std::nullopt
             : ParseNonNegativeInt64(timestamp->second);
}

// Normalize the daemon's current folded SwarmMessage into the bounded Dart timeline contract. The daemon remains
// the durable store and edition resolver; this is only transport normalization. A direct conversation may never
// surface a third author's content under either participant's identity.
std::optional<std::string> TimelineItemJson(const std::string& accountId,
                                            const std::string& peerId,
                                            const std::string& conversationId,
                                            const libjami::SwarmMessage& msg,
                                            bool liveUpdate) {
  if (!sybl::timeline::IsRequiredUtf8(
          accountId, sybl::timeline::kMaxDaemonIdCodeUnits) ||
      !sybl::timeline::IsRequiredUtf8(
          peerId, sybl::timeline::kMaxAuthorIdCodeUnits) ||
      !sybl::timeline::IsRequiredUtf8(
          conversationId, sybl::timeline::kMaxDaemonIdCodeUnits) ||
      !sybl::timeline::IsRequiredUtf8(
          msg.id, sybl::timeline::kMaxDaemonIdCodeUnits) ||
      (msg.type != "text/plain" &&
       msg.type != "application/data-transfer+json" &&
       msg.type != sybl::rich_timeline::kStickerMime &&
       msg.type != sybl::dm_topic::kEventMime)) {
    return std::nullopt;
  }
  const auto authorIt = msg.body.find("author");
  if (authorIt == msg.body.end() ||
      !sybl::timeline::IsRequiredUtf8(
          authorIt->second, sybl::timeline::kMaxAuthorIdCodeUnits)) {
    return std::nullopt;
  }
  const std::string author = BareJamiId(authorIt->second);
  const std::string localJamiId = MyUsername(accountId);
  const auto snapshot = RoutingSnapshot();
  if (!snapshot || snapshot->account_id != accountId ||
      !snapshot->Owns(peerId, conversationId)) return std::nullopt;
  const bool authenticatedGroupHistory = snapshot->Group(conversationId) != nullptr;
  if (!sybl::timeline::IsRequiredUtf8(
          author, sybl::timeline::kMaxAuthorIdCodeUnits) ||
      (author != localJamiId &&
       !authenticatedGroupHistory &&
       (!snapshot ||
        !snapshot->AcceptsRemoteAuthor(peerId, conversationId, author)))) {
    return std::nullopt;
  }
  const auto timestampSeconds = CommitTimestampSeconds(msg);
  if (!timestampSeconds) return std::nullopt;
  if (!sybl::timeline::IsOptionalUtf8(
          msg.linearizedParent, sybl::timeline::kMaxDaemonIdCodeUnits)) {
    return std::nullopt;
  }

  const auto topicIt = msg.body.find(sybl::dm_topic::kItemField);
  const auto richMetadata = sybl::rich_timeline::Project(
      msg.body, snapshot && snapshot->Group(conversationId));
  if (!richMetadata) return std::nullopt;
  const auto topic = sybl::dm_topic::NormalizeItemTopic(
      topicIt == msg.body.end() ? std::string{} : topicIt->second);

  if ((msg.type == sybl::dm_topic::kEventMime ||
       msg.type == sybl::rich_timeline::kStickerMime) &&
      (liveUpdate || !msg.latestEditionId.empty())) {
    return std::nullopt;
  }

  const std::string versionId = msg.latestEditionId.empty() ? msg.id : msg.latestEditionId;
  if (!sybl::timeline::IsRequiredUtf8(
          versionId, sybl::timeline::kMaxDaemonIdCodeUnits)) {
    return std::nullopt;
  }

  std::string result =
      "{\"accountId\":" + JsonString(accountId) +
      ",\"peerId\":" + JsonString(peerId) +
      ",\"conversationId\":" + JsonString(conversationId) +
      ",\"daemonId\":" + JsonString(msg.id) +
      ",\"versionId\":" + JsonString(versionId) +
      ",\"mimeType\":" + JsonString(msg.type) +
      ",\"authorId\":" + JsonString(author) +
      ",\"authenticatedGroupHistory\":" + (authenticatedGroupHistory ? "true" : "false") +
      ",\"linearizedParent\":" + JsonString(msg.linearizedParent) +
      ",\"topicId\":" + JsonString(topic.topic_id) +
      ",\"topicTagged\":" + (topic.tagged ? "true" : "false") +
      ",\"timestampSeconds\":" + std::to_string(*timestampSeconds);
  for (const auto& [key, value] : *richMetadata) {
    result += ',' + JsonString(key) + ':' + JsonString(value);
  }
  if (author == localJamiId) {
    int deliveryState = 1;
    if (const auto* group = snapshot ? snapshot->Group(conversationId) : nullptr) {
      const auto receipt = sybl::routing::FoldGroupReceipt(*group, msg.status);
      deliveryState = receipt.delivery_state;
      result += ",\"readByMemberIds\":[";
      bool first = true;
      for (const auto& member : receipt.read_by) {
        if (!first) result += ',';
        result += JsonString(member);
        first = false;
      }
      result += ']';
    } else if (const auto peerStatus = msg.status.find(peerId);
               peerStatus != msg.status.end()) {
      deliveryState = std::clamp(peerStatus->second, 1, 3);
    } else {
      for (const auto& [member, status] : msg.status) {
        if (BareJamiId(member) != localJamiId) {
          deliveryState = std::max(deliveryState, std::clamp(status, 1, 3));
        }
      }
    }
    result += ",\"deliveryState\":" + std::to_string(deliveryState);
  }
  if (liveUpdate) result += ",\"operation\":\"edit\"";

  if (msg.type != sybl::dm_topic::kEventMime) {
    const auto reactions = sybl::reaction::Project(msg.id, msg.reactions, BareJamiId,
        [&](const std::string& reaction_author) {
          return authenticatedGroupHistory || reaction_author == localJamiId ||
                 snapshot->AcceptsRemoteAuthor(peerId, conversationId, reaction_author);
        });
    result += ",\"reactions\":{\"messageId\":" + JsonString(msg.id) +
              ",\"complete\":" + (reactions.complete ? "true" : "false") + ",\"entries\":[";
    bool first_reaction = true;
    for (const auto& entry : reactions.entries) {
      if (!first_reaction) result += ',';
      first_reaction = false;
      result += "{\"commitId\":" + JsonString(entry.commit_id) +
                ",\"authorId\":" + JsonString(entry.author_id) +
                ",\"emoji\":" + JsonString(entry.emoji) + "}";
    }
    result += "]}";
  }

  if (msg.type == sybl::dm_topic::kEventMime) {
    const auto event = sybl::dm_topic::ProjectStateEnvelope(
        msg.id, msg.type, msg.linearizedParent, msg.body);
    if (!event) return std::nullopt;
    result += ",\"eventBody\":" + JsonString(event->event_body);
  } else if (msg.type == sybl::rich_timeline::kStickerMime) {
    const auto body = msg.body.find("body");
    if (body == msg.body.end() || !sybl::rich_timeline::BoundedBody(body->second)) {
      return std::nullopt;
    }
    result += ",\"body\":" + JsonString(body->second);
  } else if (msg.type == "text/plain") {
    const auto body = msg.body.find("body");
    if (body == msg.body.end() ||
        !sybl::timeline::IsOptionalUtf8(
            body->second, sybl::timeline::kMaxTextCodeUnits)) {
      return std::nullopt;
    }
    if (body->second.empty()) result += ",\"deleted\":true";
    result += ",\"body\":" + JsonString(body->second);
  } else {
    const auto fileId = msg.body.find("fileId");
    const bool deleted = fileId == msg.body.end() || fileId->second.empty();
    if (deleted) {
      result += ",\"deleted\":true,\"body\":{}}";
      return result;
    }
    // libjami file editions are removals. A non-empty replacement in an
    // update is not a state the daemon contract supports.
    if (liveUpdate) return std::nullopt;
    std::string displayName = "file";
    if (const auto it = msg.body.find("displayName"); it != msg.body.end()) displayName = it->second;
    int64_t totalBytes = -1;
    if (const auto it = msg.body.find("totalSize"); it != msg.body.end()) {
      const auto parsed = ParseNonNegativeInt64(it->second);
      if (!parsed) return std::nullopt;
      totalBytes = *parsed;
    }
    std::string sha3;
    if (const auto it = msg.body.find("sha3sum"); it != msg.body.end()) sha3 = it->second;
    const std::string concreteFileId = fileId->second;
    if (!sybl::timeline::IsRequiredUtf8(
            concreteFileId, sybl::timeline::kMaxFileIdCodeUnits) ||
        !sybl::timeline::IsRequiredUtf8(
            displayName, sybl::timeline::kMaxDisplayNameCodeUnits) ||
        !sybl::timeline::IsOptionalUtf8(
            sha3, sybl::timeline::kMaxHashCodeUnits)) {
      return std::nullopt;
    }
    {
      std::lock_guard<std::mutex> lock(g_mutex);
      if (accountId != g_accountId) return std::nullopt;
      const FileKey key{peerId, conversationId, concreteFileId};
      if (totalBytes >= 0) g_fileSizes[key] = totalBytes;
      if (const auto media = msg.body.find("sybl-media-v1"); media != msg.body.end())
        g_fileMediaMetadata[key] = sybl::rich_timeline::BoundedBody(media->second) ? media->second : std::string{};
    }
    const bool downloaded = FileDownloaded(accountId, conversationId, concreteFileId);
    result += ",\"body\":{\"fileId\":" + JsonString(concreteFileId) +
              ",\"displayName\":" + JsonString(displayName) +
              ",\"totalBytes\":" + (totalBytes >= 0 ? std::to_string(totalBytes) : "null") +
              ",\"sha3\":" + (sha3.empty() ? "null" : JsonString(sha3)) +
              ",\"downloaded\":" + (downloaded ? "true" : "false") + "}";
  }
  result += "}";
  return result;
}

// SwarmLoaded (daemon thread): the loadConversation reply for the shared folder. Turn the conversation's
// data-transfer commits into persistent folder items. Each load retains its own requested bound so overlapping
// friends cannot change one another's result size. Read the messages
// synchronously — the vector is only valid for this callback.
void OnHistorySearch(uint32_t id, const std::string& account, const std::string& conversation,
                     std::vector<std::map<std::string, std::string>> messages) {
  std::shared_ptr<HistorySearchEntry> entry;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    entry = g_historySearch;
    if (!entry || account != entry->owner.accountId ||
        (!conversation.empty() && conversation != entry->conversation) ||
        (entry->nativeId != 0 && entry->nativeId != id)) return;
  }
  bool oversized = messages.size() > 201;
  size_t remaining = 8 * 1024 * 1024;
  if (!oversized) for (const auto& row : messages) {
    for (const auto& field : row) {
      if (field.first.size() > remaining) { oversized = true; break; }
      remaining -= field.first.size();
      if (field.second.size() > remaining) { oversized = true; break; }
      remaining -= field.second.size();
    }
    if (oversized) break;
  }
  if (oversized) messages = {{{"sybl-search-error", "unavailable"}}};
  // Posting handles synchronous admission callbacks without taking a daemon
  // callback lock across searchConversation. All request IDs bind on the worker.
  Post([entry, id, account, conversation, oversized, messages = std::move(messages)] {
    {
      std::lock_guard<std::mutex> lock(g_mutex);
      if (g_historySearch != entry || entry->nativeId != id) return;
    }
    const auto routing = RoutingSnapshot();
    if (!OwnsAccountCommand(entry->owner) || !routing || !routing->Owns(entry->peer, entry->conversation))
      entry->request->Retire();
    entry->request->Accept(account, oversized ? "" : conversation, messages);
    if (!entry->request->terminal()) return;
    const auto result = entry->request->result();
    {
      std::lock_guard<std::mutex> lock(g_mutex);
      if (g_historySearch == entry) g_historySearch.reset();
    }
    if (entry->delivered) return;
    entry->delivered = true;
    std::optional<HistorySearchReply> reply;
    if (result) {
      reply = HistorySearchReply{entry->owner.accountId, entry->peer, entry->conversation,
          entry->owner.revision, entry->epoch, result->truncated, {}};
      for (const auto& hit : result->hits)
        reply->hits.push_back({hit.message_id, hit.author_id, hit.channel_id,
                              hit.snippet, hit.timestamp_seconds, hit.file});
    }
    try { if (entry->done) entry->done(std::move(reply)); } catch (...) {}
  });
}

sybl::history_search::MessageLoadFacts SearchMessageFacts(const sybl::history_search::MessageLoadTicket& ticket) {
  sybl::history_search::MessageLoadFacts facts;
  const auto routing = RoutingSnapshot();
  facts.routing_owns = routing && routing->account_id == ticket.account_id &&
      routing->Owns(ticket.peer_id, ticket.conversation_id);
  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_running && g_daemonReady.load() && g_accountRevision != std::numeric_limits<uint64_t>::max()) {
    facts.account_id = g_accountId;
    facts.account_revision = g_accountRevision;
  }
  facts.epoch = g_historySearchEpoch;
  facts.restore_pending = g_identityActivationPending || g_pendingRestoreBlocked;
  return facts;
}

std::optional<WireValue> WireValueFromJson(const Json::Value& value) {
  WireValue wire;
  if (value.isNull()) return wire;
  if (value.isBool()) {
    wire.kind = WireValue::Kind::kBool;
    wire.boolean = value.asBool();
  } else if (value.isInt64()) {
    wire.kind = WireValue::Kind::kInt;
    wire.integer = value.asInt64();
  } else if (value.isString()) {
    wire.kind = WireValue::Kind::kString;
    wire.text = value.asString();
  } else if (value.isArray()) {
    wire.kind = WireValue::Kind::kList;
    for (const auto& entry : value) {
      auto converted = WireValueFromJson(entry);
      if (!converted) return std::nullopt;
      wire.list.push_back(std::move(*converted));
    }
  } else if (value.isObject()) {
    wire.kind = WireValue::Kind::kMap;
    for (const auto& key : value.getMemberNames()) {
      auto converted = WireValueFromJson(value[key]);
      if (!converted) return std::nullopt;
      wire.keys.push_back(key);
      wire.values.push_back(std::move(*converted));
    }
  } else {
    return std::nullopt;
  }
  return wire;
}

// The timeline projection yields JSON text; the reply carries the same item in the channel's map form.
std::optional<SearchMessageReply> SearchMessageReplyFor(const sybl::history_search::MessageLoadTicket& ticket,
                                                        const std::optional<std::string>& itemJson) {
  if (!itemJson) return std::nullopt;
  Json::CharReaderBuilder builder;
  builder["rejectDupKeys"] = true;
  builder["failIfExtra"] = true;
  builder["allowComments"] = false;
  const std::unique_ptr<Json::CharReader> reader(builder.newCharReader());
  Json::Value parsed;
  std::string errors;
  if (!reader->parse(itemJson->data(), itemJson->data() + itemJson->size(), &parsed, &errors) ||
      !parsed.isObject() || !parsed["daemonId"].isString() ||
      parsed["daemonId"].asString() != ticket.message_id) return std::nullopt;
  auto item = WireValueFromJson(parsed);
  if (!item) return std::nullopt;
  return SearchMessageReply{ticket.account_id, ticket.peer_id, ticket.conversation_id, ticket.message_id,
                            ticket.account_revision, ticket.epoch, std::move(*item)};
}

// SwarmLoaded answer to loadSybLMessage (daemon thread). Content comes only from `messages`, projected by the
// ordinary timeline projection; nothing here marks, reads or notifies. The caller is answered exactly once.
void CompleteSearchMessage(const SearchMessageRequest& request, const std::string& accountId,
                           const std::string& conversationId,
                           const std::vector<libjami::SwarmMessage>& messages) {
  std::optional<SearchMessageReply> reply;
  try {
    sybl::history_search::DispatchMessageLoad(
        sybl::history_search::CompleteMessageLoad(request.ticket, accountId, conversationId,
                                                  SearchMessageFacts(request.ticket), messages),
        {.project = [&](std::size_t index) {
           reply = SearchMessageReplyFor(request.ticket,
                                         TimelineItemJson(request.ticket.account_id, request.ticket.peer_id,
                                                          request.ticket.conversation_id, messages[index], false));
         },
         .unavailable = [&] { reply.reset(); }});
  } catch (...) {
    reply.reset();
  }
  try { if (request.done) request.done(std::move(reply)); } catch (...) {}
}

void OnSwarmLoaded(uint32_t loadId, const std::string& accountId, const std::string& conversationId,
                   const std::vector<libjami::SwarmMessage>& messages) {
  std::optional<sybl::conversation::PendingLoad> pendingLoad;
  std::optional<SearchMessageRequest> searchMessage;
  {
    // Narrow registration critical section: it exists only to prevent a warm-cache callback from beating
    // loadConversation()+registration. Taking the ticket also purges expired
    // requests; history normalization and Emit never run under either lock.
    std::lock_guard<std::mutex> registrationLock(g_loadRegistrationMutex);
    std::lock_guard<std::mutex> lock(g_mutex);
    pendingLoad = g_conversationLoads.Take(loadId);
    if (pendingLoad && pendingLoad->kind == sybl::conversation::LoadKind::kSearchMessage)
      searchMessage = g_searchMessageLoads.Complete(loadId);
  }
  if (pendingLoad && pendingLoad->kind == sybl::conversation::LoadKind::kSearchMessage) {
    if (searchMessage) CompleteSearchMessage(*searchMessage, accountId, conversationId, messages);
    return;
  }
  if (!pendingLoad || pendingLoad->conversation_id != conversationId ||
      !sybl::timeline::IsRequiredUtf8(
          accountId, sybl::timeline::kMaxDaemonIdCodeUnits) ||
      !sybl::timeline::IsRequiredUtf8(
          conversationId, sybl::timeline::kMaxDaemonIdCodeUnits)) {
    return;
  }

  if (pendingLoad->kind == sybl::conversation::LoadKind::kDmTopicState) {
    const auto snapshot = RoutingSnapshot();
    if (!snapshot || snapshot->account_id != accountId ||
        !snapshot->Owns(pendingLoad->peer_id, conversationId) ||
        snapshot->Group(conversationId) ||
        !sybl::timeline::IsRequiredUtf8(
            pendingLoad->peer_id, sybl::timeline::kMaxAuthorIdCodeUnits) ||
        !sybl::timeline::IsOptionalUtf8(
            pendingLoad->cursor, sybl::timeline::kMaxDaemonIdCodeUnits)) {
      return;
    }
    const auto localJamiId = MyUsername(accountId);
    std::string itemsJson{"["};
    std::size_t itemCount = 0;
    std::size_t inspectedCount = 0;
    std::string nextCursor;
    bool bounded = false;
    for (const auto& msg : messages) {
      if (inspectedCount >= static_cast<std::size_t>(pendingLoad->limit)) {
        bounded = true;
        break;
      }
      if (!sybl::timeline::IsRequiredUtf8(
              msg.id, sybl::timeline::kMaxDaemonIdCodeUnits)) {
        return;
      }
      const auto envelope = sybl::dm_topic::ProjectStateEnvelope(
          msg.id, msg.type, msg.linearizedParent, msg.body,
          std::any_of(msg.status.begin(), msg.status.end(),
                      [&](const auto& entry) {
                        return BareJamiId(entry.first) == localJamiId &&
                               entry.second >= 3;
                      }));
      if (envelope) {
        const auto authorId = BareJamiId(envelope->author_id);
        if (authorId == localJamiId || snapshot->AcceptsRemoteAuthor(
                                            pendingLoad->peer_id,
                                            conversationId, authorId)) {
          std::string itemJson =
              "{\"commitId\":" + JsonString(envelope->commit_id) +
              ",\"authorId\":" + JsonString(authorId) +
              ",\"mimeType\":" + JsonString(envelope->mime_type) +
              ",\"topicId\":" + JsonString(envelope->topic_id) +
              ",\"topicTagged\":" +
              (envelope->topic_tagged ? "true" : "false") +
              ",\"daemonRead\":" +
              (envelope->daemon_read ? "true" : "false") +
              ",\"linearizedParent\":" +
              JsonString(envelope->linearized_parent);
          if (!envelope->event_body.empty()) {
            itemJson += ",\"eventBody\":" +
                        JsonString(envelope->event_body);
          }
          itemJson += '}';
          if (!sybl::timeline::CanAppendTimelineSnapshotItem(
                  itemCount, itemsJson.size(), itemJson.size())) {
            bounded = true;
            break;
          }
          if (itemCount > 0) itemsJson += ',';
          itemsJson += itemJson;
          ++itemCount;
        }
      }
      nextCursor = msg.id;
      ++inspectedCount;
    }
    itemsJson += ']';
    bool hasMore =
        (bounded || static_cast<int>(messages.size()) >= pendingLoad->limit) &&
        !nextCursor.empty() && nextCursor != pendingLoad->cursor;
    if (!hasMore) nextCursor.clear();
    Emit("dmTopicStatePage",
         {{"accountId", accountId},
          {"peerJamiId", pendingLoad->peer_id},
          {"conversationId", conversationId},
          {"loadId", std::to_string(loadId)},
          {"requestedCursor", pendingLoad->cursor},
          {"nextCursor", nextCursor},
          {"hasMore", hasMore ? "true" : "false"},
          {"itemsJson", itemsJson}});
    return;
  }

  if (pendingLoad->kind == sybl::conversation::LoadKind::kChat) {
    const auto snapshot = RoutingSnapshot();
    if (!snapshot || snapshot->account_id != accountId ||
        !snapshot->Owns(pendingLoad->peer_id, conversationId) ||
        !sybl::timeline::IsRequiredUtf8(
            pendingLoad->peer_id, sybl::timeline::kMaxAuthorIdCodeUnits) ||
        !sybl::timeline::IsOptionalUtf8(
            pendingLoad->cursor, sybl::timeline::kMaxDaemonIdCodeUnits)) {
      return;
    }
    std::string itemsJson{"["};
    std::size_t itemCount = 0;
    std::size_t inspectedCount = 0;
    std::string nextCursor;
    bool bounded = false;
    for (const auto& msg : messages) {
      if (inspectedCount >= sybl::timeline::kMaxTimelineSnapshotItems) {
        bounded = true;
        break;
      }
      if (!sybl::timeline::IsRequiredUtf8(
              msg.id, sybl::timeline::kMaxDaemonIdCodeUnits)) {
        // An invalid pagination cursor makes the rest of the page
        // unaddressable. Drop the atomic snapshot rather than publish a view
        // that can only loop or skip history.
        return;
      }
      const auto item = TimelineItemJson(
          accountId, pendingLoad->peer_id, conversationId, msg, false);
      if (item) {
        if (!sybl::timeline::CanAppendTimelineSnapshotItem(
                itemCount, itemsJson.size(), item->size())) {
          bounded = true;
          break;
        }
        if (itemCount > 0) itemsJson += ',';
        itemsJson += *item;
        ++itemCount;
      }
      nextCursor = msg.id;
      ++inspectedCount;
    }
    itemsJson += ']';
    bool hasMore =
        (bounded ||
         static_cast<int>(messages.size()) >= pendingLoad->limit) &&
        !nextCursor.empty() && nextCursor != pendingLoad->cursor;
    if (!hasMore) nextCursor.clear();
    Emit("chatSnapshot", {{"accountId", accountId}, {"peerJamiId", pendingLoad->peer_id},
                          {"conversationId", conversationId}, {"loadId", std::to_string(loadId)},
                          {"requestedCursor", pendingLoad->cursor},
                          {"nextCursor", nextCursor}, {"hasMore", hasMore ? "true" : "false"},
                          {"itemsJson", itemsJson}});
    return;
  }

  const std::string& peerId = pendingLoad->peer_id;
  const int keep = pendingLoad->limit;
  const auto snapshot = RoutingSnapshot();
  if (!snapshot || snapshot->account_id != accountId ||
      !snapshot->Owns(peerId, conversationId) ||
      !sybl::timeline::IsRequiredUtf8(
          peerId, sybl::timeline::kMaxAuthorIdCodeUnits)) {
    return;
  }
  struct Item {
    std::string fileId, iid, name, sha3, timestamp, authorId, roomId;
    std::optional<std::string> mediaMetadata;
    std::string topicId = sybl::dm_topic::kMain;
    int64_t size = -1, ts = 0;
    bool outgoing = false;
    bool topicTagged = false;
  };
  std::vector<Item> items;
  const std::string acc = accountId;
  const std::string me = MyUsername(acc);
  for (const auto& msg : messages) {
    if (items.size() >= static_cast<std::size_t>(keep)) break;
    if (msg.type != "application/data-transfer+json") continue;
    auto fit = msg.body.find("fileId");
    if (fit == msg.body.end() || fit->second.empty()) continue;
    Item it;
    it.fileId = fit->second;
    it.iid = msg.id;
    it.name = "file";
    if (auto b = msg.body.find("displayName"); b != msg.body.end()) it.name = b->second;
    if (auto b = msg.body.find("totalSize"); b != msg.body.end()) {
      const auto parsed = ParseNonNegativeInt64(b->second);
      if (!parsed) continue;
      it.size = *parsed;
    }
    if (auto b = msg.body.find("sha3sum"); b != msg.body.end()) it.sha3 = b->second;
    if (auto b = msg.body.find("timestamp"); b != msg.body.end()) {
      it.timestamp = b->second;
      const auto parsed = ParseNonNegativeInt64(b->second);
      if (!parsed) continue;
      it.ts = *parsed;
    }
    std::string author;
    if (auto b = msg.body.find("author"); b != msg.body.end()) author = b->second;
    if (!sybl::timeline::IsRequiredUtf8(
            it.fileId, sybl::timeline::kMaxFileIdCodeUnits) ||
        !sybl::timeline::IsRequiredUtf8(
            it.iid, sybl::timeline::kMaxDaemonIdCodeUnits) ||
        !sybl::timeline::IsRequiredUtf8(
            it.name, sybl::timeline::kMaxDisplayNameCodeUnits) ||
        !sybl::timeline::IsOptionalUtf8(
            it.sha3, sybl::timeline::kMaxHashCodeUnits) ||
        !sybl::timeline::IsRequiredUtf8(
            author, sybl::timeline::kMaxAuthorIdCodeUnits) ||
        !sybl::timeline::IsRequiredUtf8(it.timestamp, 64)) {
      continue;
    }
    it.authorId = BareJamiId(author);
    if (it.authorId.empty()) continue;
    it.outgoing = it.authorId == me;
    if (!it.outgoing &&
        !snapshot->AcceptsRemoteAuthor(peerId, conversationId, it.authorId)) {
      continue;
    }
    const auto rich = sybl::rich_timeline::Project(msg.body, sybl::routing::GroupConversationId(peerId).has_value());
    if (!rich) continue;
    if (const auto room = rich->find("roomId"); room != rich->end()) it.roomId = room->second;
    const auto topicIt = msg.body.find(sybl::dm_topic::kItemField);
    const auto topic = sybl::dm_topic::NormalizeItemTopic(
        topicIt == msg.body.end() ? std::string{} : topicIt->second);
    it.topicId = topic.topic_id;
    it.topicTagged = topic.tagged;
    if (const auto media = msg.body.find("sybl-media-v1"); media != msg.body.end())
      it.mediaMetadata = sybl::rich_timeline::BoundedBody(media->second) ? media->second : std::string{};
    items.push_back(std::move(it));
  }
  std::sort(items.begin(), items.end(), [](const Item& a, const Item& b) { return a.ts > b.ts; });  // newest first
  std::size_t emitted = 0;
  std::string filesJson{"["};
  for (const auto& it : items) {
    if (emitted >= static_cast<std::size_t>(keep)) break;
    const std::string itemJson =
        "{\"fileId\":" + JsonString(it.fileId) +
        ",\"interactionId\":" + JsonString(it.iid) +
        ",\"conversationId\":" + JsonString(conversationId) +
        ",\"name\":" + JsonString(it.name) +
        ",\"size\":" + std::to_string(it.size) +
        ",\"sha3\":" + JsonString(it.sha3) +
        ",\"outgoing\":" + (it.outgoing ? "true" : "false") +
        ",\"authorId\":" + JsonString(it.authorId) +
        ",\"roomId\":" + JsonString(it.roomId) +
        ",\"topicId\":" + JsonString(it.topicId) +
        ",\"topicTagged\":" + (it.topicTagged ? "true" : "false") +
        ",\"downloaded\":" +
        (FileDownloaded(acc, conversationId, it.fileId) ? "true" : "false") +
        ",\"timestamp\":" + JsonString(it.timestamp) + "}";
    const std::size_t separator = emitted == 0 ? 0 : 1;
    const std::size_t remaining =
        sybl::timeline::kMaxTimelineSnapshotBytes - filesJson.size();
    if (itemJson.size() + separator + 1 > remaining) break;
    {
      std::lock_guard<std::mutex> lock(g_mutex);
      g_fileSizes[FileKey{peerId, conversationId, it.fileId}] = it.size;
      g_xfers.try_emplace(FileKey{peerId, conversationId, it.fileId},
          FileXferMeta{it.iid, it.name, it.authorId, it.topicId, it.size, it.outgoing, it.topicTagged, it.roomId});
      if (it.mediaMetadata)
        g_fileMediaMetadata[FileKey{peerId, conversationId, it.fileId}] = *it.mediaMetadata;
    }
    if (emitted > 0) filesJson += ',';
    filesJson += itemJson;
    ++emitted;
  }
  filesJson += ']';
  Emit("folderSnapshot", {{"accountId", accountId}, {"peerJamiId", peerId},
                          {"conversationId", conversationId}, {"loadId", std::to_string(loadId)},
                          {"filesJson", filesJson}});
  Log("swarmLoaded(" + conversationId + ") " + std::to_string(items.size()) + " file(s) -> folder");
}

void OnConversationReady(const std::string& accountId, const std::string& conversationId) {
  if (!IsActiveAccount(accountId)) return;
  // Conversation readiness can publish/change the contact's canonical route. Rebuild routing and notify Dart;
  // Dart starts the folder load so it can correlate the returned load ID before accepting the snapshot.
  Post([accountId, conversationId]() {
    try {
      RefreshRoutingSnapshot(accountId);
    } catch (...) {
      Log("conversationReady routing refresh threw");
    }
  });
}

// Reduce a daemon "jami:<40hex>@ring.dht" uri to the bare 40-hex.
static std::string BareJamiUri(const std::string& uri) {
  return BareJamiId(uri);
}

void QueueRejectedConversationRequest(const std::string& accountId,
                                      const std::string& conversationId) {
  if (accountId.empty() || !sybl::timeline::IsRequiredUtf8(
                               conversationId,
                               sybl::timeline::kMaxDaemonIdCodeUnits)) {
    return;
  }
  bool schedule = false;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    const auto key = std::make_pair(accountId, conversationId);
    if (g_rejectedConnectTombstones.find(key) !=
        g_rejectedConnectTombstones.end()) {
      return;
    }
    if (g_rejectedConnectKeys.find(key) != g_rejectedConnectKeys.end()) {
      // Preserve the queued work after a failed drain and re-arm it below.
    } else if (g_rejectedConnectQueue.size() < kMaxRejectedConnectQueue) {
      g_rejectedConnectKeys.insert(key);
      g_rejectedConnectQueue.push_back({accountId, conversationId});
    } else if (g_rejectedConnectRescanAccounts.size() <
               kMaxRejectedConnectRescanAccounts) {
      // Queue saturation must not turn into daemon-owned request growth. One
      // account marker replaces arbitrarily many overflowed callback records.
      g_rejectedConnectRescanAccounts.insert(accountId);
    }
    if (!g_rejectedConnectDrainScheduled) {
      g_rejectedConnectDrainScheduled = true;
      schedule = true;
    }
  }
  if (!schedule) return;
  try {
    Post(DrainRejectedConnects);
  } catch (...) {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_rejectedConnectDrainScheduled = false;
    Log("decline unadmitted conversation request post failed");
  }
}

void RememberRejectedConnectLocked(
    const std::pair<std::string, std::string>& key) {
  if (!g_rejectedConnectTombstones.insert(key).second) return;
  g_rejectedConnectTombstoneOrder.push_back(key);
  while (g_rejectedConnectTombstoneOrder.size() >
         kMaxRejectedConnectTombstones) {
    g_rejectedConnectTombstones.erase(
        g_rejectedConnectTombstoneOrder.front());
    g_rejectedConnectTombstoneOrder.pop_front();
  }
}

void DrainRejectedConnects() {
  try {
    for (;;) {
      std::optional<RejectedConnect> next;
      std::string rescanAccount;
      {
        std::lock_guard<std::mutex> lock(g_mutex);
        if (!g_rejectedConnectQueue.empty()) {
          next = std::move(g_rejectedConnectQueue.front());
          g_rejectedConnectQueue.pop_front();
        } else if (!g_rejectedConnectRescanAccounts.empty()) {
          rescanAccount = *g_rejectedConnectRescanAccounts.begin();
        } else {
          g_rejectedConnectDrainScheduled = false;
          return;
        }
      }

      if (next) {
        const auto key =
            std::make_pair(next->account_id, next->conversation_id);
        try {
          libjami::declineConversationRequest(next->account_id,
                                              next->conversation_id);
          std::lock_guard<std::mutex> lock(g_mutex);
          g_rejectedConnectKeys.erase(key);
          RememberRejectedConnectLocked(key);
        } catch (...) {
          std::lock_guard<std::mutex> lock(g_mutex);
          g_rejectedConnectKeys.erase(key);
          if (g_rejectedConnectRescanAccounts.size() <
              kMaxRejectedConnectRescanAccounts) {
            g_rejectedConnectRescanAccounts.insert(next->account_id);
          }
          Log("decline unadmitted conversation request threw");
        }
        continue;
      }

      bool complete = true;
      try {
        const auto requests =
            libjami::getConversationRequests(rescanAccount);
        for (const auto& request : requests) {
          const auto id = request.find("id");
          if (id == request.end() ||
              !sybl::timeline::IsRequiredUtf8(
                  id->second, sybl::timeline::kMaxDaemonIdCodeUnits)) {
            complete = false;
            continue;
          }
          const auto key = std::make_pair(rescanAccount, id->second);
          bool admitted = false;
          {
            std::lock_guard<std::mutex> lock(g_mutex);
            const auto owner = g_pendingConnectAccount.find(id->second);
            admitted = owner != g_pendingConnectAccount.end() &&
                       owner->second == rescanAccount;
            admitted = admitted ||
                       (g_accountId == rescanAccount &&
                        g_pendingConnectGate.Contains(id->second));
          }
          if (admitted) continue;
          try {
            libjami::declineConversationRequest(rescanAccount, id->second);
            std::lock_guard<std::mutex> lock(g_mutex);
            g_rejectedConnectKeys.erase(key);
            RememberRejectedConnectLocked(key);
          } catch (...) {
            complete = false;
            Log("decline rescanned conversation request threw");
          }
        }
      } catch (...) {
        complete = false;
        Log("rescan unadmitted conversation requests threw");
      }
      bool retry = false;
      {
        std::lock_guard<std::mutex> lock(g_mutex);
        if (complete) {
          g_rejectedConnectRescanAccounts.erase(rescanAccount);
          g_rejectedConnectRescanFailures.erase(rescanAccount);
        } else {
          const auto failures = ++g_rejectedConnectRescanFailures[rescanAccount];
          retry = failures <= kMaxRejectedConnectRescanRetries && g_running;
          if (retry) {
            try {
              // Queue behind any user decision already waiting on the worker; bounded retries never spin inline.
              g_tasks.emplace_back(DrainRejectedConnects);
              g_cv.notify_one();
            } catch (...) {
              retry = false;
            }
          }
          g_rejectedConnectDrainScheduled = retry;
        }
      }
      if (!complete) return;
    }
  } catch (...) {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_rejectedConnectDrainScheduled = false;
  }
}

// Jami consumes a trusted contact's one-to-one request before this callback. Group invitations still arrive here
// when sent by an existing friend, so every callback remains an explicit user decision.
// `title` is the daemon's projection of the request payload's vCard FN: a peer claim, forwarded only for a 1:1
// request and only when it is valid bounded UTF-8. Dart strips controls/bidi and caps it before display.
void OnConversationRequest(const std::string& accountId, const std::string& conversationId,
                           const std::string& fromUri, const std::string& modeValue,
                           const std::string& title) {
  const std::string from = BareJamiUri(fromUri);
  const bool validConversation = sybl::timeline::IsRequiredUtf8(
      conversationId, sybl::timeline::kMaxDaemonIdCodeUnits);
  const bool validMode = modeValue.size() == 1 &&
                         modeValue.front() >= '0' && modeValue.front() <= '3';
  const bool isGroup = validMode && modeValue != "0";
  const std::string name =
      isGroup ? std::string{} : sybl::profile_wire::DecodeDisplayName(title).value_or(std::string{});
  auto admission = sybl::PendingRequestAdmission::kRejected;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    const auto key = std::make_pair(accountId, conversationId);
    if (!accountId.empty() && accountId == g_accountId && validConversation &&
        !from.empty() && validMode &&
        g_rejectedConnectRescanAccounts.find(accountId) ==
            g_rejectedConnectRescanAccounts.end() &&
        g_rejectedConnectTombstones.find(key) ==
            g_rejectedConnectTombstones.end()) {
      const auto now = std::chrono::duration_cast<std::chrono::milliseconds>(
                           std::chrono::steady_clock::now().time_since_epoch())
                           .count();
      admission = g_pendingConnectGate.Admit(conversationId, now);
    }
    if (admission == sybl::PendingRequestAdmission::kNew) {
      g_pendingConnect[conversationId] = from;
      g_pendingConnectAccount[conversationId] = accountId;
      g_pendingConnectIsGroup[conversationId] = isGroup;
      g_pendingConnectName[conversationId] = name;
    }
  }
  if (admission == sybl::PendingRequestAdmission::kRejected) {
    QueueRejectedConversationRequest(accountId, conversationId);
    return;
  }
  if (admission == sybl::PendingRequestAdmission::kDuplicate) return;
  Log("conversationRequest(" + conversationId + ") from=" + from +
      " group=" + (isGroup ? "true" : "false") + " -> gate");
  Emit("connectRequest", {{"accountId", accountId}, {"conversationId", conversationId},
                          {"fromJamiId", from}, {"isGroup", isGroup ? "true" : "false"},
                          {"name", name}});
}

// presence v2: an account (non-swarm) message arrived — the ping/pong path. A ping is auto-ponged natively,
// gated to YOUR person (never a reachability oracle for a stranger who has the hex); both ping and pong are
// forwarded to Dart as transport-verified presence evidence. Every gated ping is answered (no id-dedup: the
// channel path delivers messages with an EMPTY id — daemon jamiaccount.cpp:4768 passes id="" — and engine
// retries only redeliver after a failed write, so duplicates are rare + benign). Daemon callback thread →
// daemon work hops to the worker via Post; Emit is thread-safe.
void OnAccountMessage(const std::string& accountId, const std::string& fromBare,
                      const std::map<std::string, std::string>& payloads) {
  if (const auto found = payloads.find(sybl::hologram::kMime); found != payloads.end()) {
    const auto packet = sybl::hologram::Decode(found->second);
    const auto sender = BareJamiId(fromBare);
    const auto snapshot = RoutingSnapshot();
    if (!packet || !snapshot || !sybl::hologram::Authorized(*snapshot, accountId, sender, packet->conversation)) return;
    {
      static int64_t window = 0;
      static unsigned count = 0;
      const auto now = std::chrono::duration_cast<std::chrono::milliseconds>(
          std::chrono::steady_clock::now().time_since_epoch()).count();
      std::lock_guard<std::mutex> lock(g_mutex);
      if (accountId != g_accountId || g_identityActivationPending) return;
      if (now - window >= 1000) { window = now; count = 0; }
      if (count >= 64) return;
      ++count;
    }
    Emit("hologramControl", {{"accountId", accountId}, {"fromJamiId", sender},
                             {"payload", found->second}});
    return;
  }
  if (const auto presence = payloads.find(sybl::group_call::kPresenceMime);
      presence != payloads.end()) {
    const auto snapshot = RoutingSnapshot();
    if (snapshot && snapshot->account_id == accountId &&
        sybl::group_call::AcceptPresence(*snapshot, fromBare,
                                         presence->second)) {
      Emit("groupCallPresence",
           {{"accountId", accountId},
            {"fromJamiId", BareJamiId(fromBare)},
            {"payload", presence->second}});
    }
    return;
  }
  const auto sender = BareJamiId(fromBare);
  const bool trusted = IsTrustedPeer(accountId, sender);
  if (const auto declined = payloads.find(kFileDeclinedMime);
      declined != payloads.end()) {
    if (!trusted) return;
    const auto packet =
        sybl::file_thumbnail_wire::DecodeDeclined(declined->second);
    const auto snapshot = RoutingSnapshot();
    if (packet && snapshot && snapshot->account_id == accountId &&
        snapshot->Owns(fromBare, packet->conversation_id)) {
      Emit("fileDeclined",
           {{"accountId", accountId},
            {"peerJamiId", fromBare},
            {"conversationId", packet->conversation_id},
            {"fileId", packet->file_id}});
    }
    return;
  }
  if (const auto thumbnail = payloads.find(kFileThumbnailMime);
      thumbnail != payloads.end()) {
    if (!trusted) return;
    const auto now = std::chrono::duration_cast<std::chrono::milliseconds>(
                         std::chrono::system_clock::now().time_since_epoch())
                         .count();
    const auto packet =
        sybl::file_thumbnail_wire::Decode(thumbnail->second, now);
    const auto snapshot = RoutingSnapshot();
    if (packet && snapshot && snapshot->account_id == accountId &&
        snapshot->Owns(fromBare, packet->conversation_id)) {
      Emit("fileThumbnail",
           {{"accountId", accountId},
            {"peerJamiId", fromBare},
            {"conversationId", packet->conversation_id},
            {"fileId", packet->file_id},
            {"pngBase64", packet->png_base64}});
    }
    return;
  }
  auto it = payloads.find(kProbeMime);
  if (it == payloads.end()) return;  // not ours (vCard etc.) — ignore
  const auto now = std::chrono::duration_cast<std::chrono::milliseconds>(
                       std::chrono::system_clock::now().time_since_epoch())
                       .count();
  const auto packet = sybl::presence_wire::Decode(it->second, now);
  if (!packet) return;
  const auto snapshot = RoutingSnapshot();
  if (packet->type == "wake") {
    if (!snapshot || snapshot->account_id != accountId ||
        !snapshot->AcceptsWakePeer(sender)) return;
    Emit("wakeCapability", {{"accountId", accountId},
                             {"fromJamiId", sender},
                             {"handle", packet->wake}});
    return;
  }
  if (!trusted) return;
  if (!packet->wake.empty()) {
    Emit("wakeCapability", {{"accountId", accountId},
                             {"fromJamiId", sender},
                             {"handle", packet->wake}});
  }
  if (packet->type == "ping") {
    const auto epoch = g_presenceProbeEpoch.load();
    Post([accountId, sender, epoch]() {
      try {
        if (!IsActiveAccount(accountId) || sender.empty() || epoch != g_presenceProbeEpoch.load() ||
            g_recordingOffline.load() || libjami::getAccountDetails(accountId)["Account.enable"] != "true") return;
        // Pong only YOUR person. ponytail: single-peer gate; widen to contact membership when contacts go N>1.
        bool isPeer = false;
        for (const auto& c : libjami::getContacts(accountId)) {
          auto b = c.find("banned");
          if (b != c.end() && b->second == "true") continue;
          auto idIt = c.find("id");
          if (idIt != c.end() && BareJamiId(idIt->second) == sender) { isPeer = true; break; }
        }
        if (isPeer) {
          std::map<std::string, std::string> payload{{kProbeMime, PresenceJson("pong")}};
          libjami::sendAccountTextMessage(accountId, sender, payload, 0);
          Log("pong -> " + sender);
        }
      } catch (...) {
        Log("pong threw");
      }
    });
  }
  // Answer the pre-version probe for compatibility, but never promote a queued, metadata-free value into fresh
  // foreground evidence.
  if (packet->version == 0 && packet->timestamp_ms == 0) return;
  Emit("presenceMsg", {{"accountId", accountId}, {"fromJamiId", sender},
                        {"v", std::to_string(packet->version)},
                        {"t", packet->type},
                        {"fg", std::to_string(packet->foreground)},
                        {"ts", std::to_string(packet->timestamp_ms)},
                        {"platform", packet->platform},
                        {"activity", packet->activity},
                        {"color", packet->color},
                        {"wake", packet->wake}});
}

bool MatchesControlAuthorityLocked(const ControlSignal& expected) {
    const auto admitted = g_callPeers.find(expected.callId);
    const bool trusted = g_routingSnapshot &&
        g_routingSnapshot->account_id == expected.accountId &&
        g_routingSnapshot->self_id == expected.localJamiId &&
        g_routingSnapshot->IsTrusted(expected.controllerAccountId);
    return !g_identityActivationPending && expected.accountId == g_accountId &&
        IsAuthoritativeCallLocked(expected.callId) &&
        !g_sourceTransition && admitted != g_callPeers.end() &&
        admitted->second == expected.controllerAccountId && trusted &&
        g_localVideoSource.kind == screen_source::Kind::Screen &&
        g_localVideoSource.call_id == expected.callId &&
        g_localVideoSource.uri == expected.sourceUri &&
        g_localVideoSource.epoch == expected.sourceRevision &&
        g_localVideoSource.width == expected.sourceWidth &&
        g_localVideoSource.height == expected.sourceHeight &&
        OwnsLiveScreenFrameLocked(g_localVideoSource);
}
bool SameControlAuthority(const ControlSignal& a, const ControlSignal& b) {
  return a.accountId == b.accountId && a.callId == b.callId &&
      a.controllerAccountId == b.controllerAccountId && a.controllerDeviceId == b.controllerDeviceId &&
      a.sourceUri == b.sourceUri && a.sourceRevision == b.sourceRevision &&
      a.sourceWidth == b.sourceWidth && a.sourceHeight == b.sourceHeight &&
      a.localJamiId == b.localJamiId && a.localIcePath == b.localIcePath && a.localLanProven == b.localLanProven;
}
void RefreshControlAuthority(ControlSignal expected, uint64_t revision, uint64_t trustEpoch) {
  const auto started = GetTickCount64();
  try {
    const auto authenticated = AuthenticatedPeerFromDaemon(expected.accountId, expected.callId);
    std::lock_guard<std::mutex> lock(g_mutex);
    g_controlAuthorityRefreshPending = false;
    const auto trust = g_controlTrustEpochs.find(expected.controllerAccountId);
    if (revision != g_accountRevision || trust == g_controlTrustEpochs.end() || trust->second != trustEpoch ||
        authenticated.accountId != expected.controllerAccountId || authenticated.deviceId != expected.controllerDeviceId ||
        authenticated.localIcePath != expected.localIcePath || authenticated.localLanProven != expected.localLanProven ||
        !MatchesControlAuthorityLocked(expected)) {
      g_controlAuthorityLease.Clear();
      return;
    }
    expected.payload.clear();
    g_controlAuthorityLease.Publish({std::move(expected), revision, trustEpoch}, started, GetTickCount64());
  } catch (...) {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_controlAuthorityRefreshPending = false;
    g_controlAuthorityLease.Clear();
  }
}

bool ActivatePreparedAccount(const std::string& accountId) {
  try {
    uint64_t revision = 0;
    {
      std::lock_guard<std::mutex> lock(g_mutex);
      if (accountId != g_accountId || g_networkPreparedRevision != g_accountRevision ||
          g_identityActivationPending || g_pendingRestoreBlocked) return false;
      revision = g_accountRevision;
    }
    const auto path = sybl::identity_restore::CanonicalSettingsLease::DefaultPath();
    const auto privacy = path ? sybl::identity_restore::CanonicalSettingsLease::AcquireCurrent(*path) : nullptr;
    if (!privacy) return false;
    {
      std::lock_guard<std::mutex> lock(g_mutex);
      if (accountId != g_accountId || revision != g_accountRevision || g_identityActivationPending) return false;
    }
    if (privacy->appear_offline()) libjami::sendRegister(accountId, false);
    libjami::setAccountActive(accountId, true, false);
    const auto observed = libjami::getVolatileAccountDetails(accountId);
    const auto active = observed.find("Account.active");
    return active != observed.end() && active->second == "true";
  } catch (...) { return false; }
}

void BootDaemon() {
  g_daemonReady.store(false);
  // Outer firewall: BootDaemon runs on the worker thread, so an uncaught libjami throw here would not cross the
  // ABI edge but WOULD reach the std::thread entry -> std::terminate. Fail soft instead (the file's contract is
  // that every libjami-touching path is wrapped). The inner try/catch blocks stay for granular logging + so a
  // handler-registration failure doesn't block start().
  try {
  // Restore admission closes before daemon auto-load can deliver a call for
  // either the old account or the imported account.
  const auto pendingPath = sybl::identity_restore::PendingRestoreStore::DefaultPath();
  const auto pending = pendingPath ? sybl::identity_restore::PendingRestoreStore(*pendingPath).Load()
                                  : sybl::identity_restore::LoadResult{};
  g_pendingRestoreBlocked = pending.status == sybl::identity_restore::LoadStatus::kError;
  g_pendingRestore = pending.value;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_identityActivationPending = g_pendingRestoreBlocked || g_pendingRestore.has_value();
  }
  if (!g_daemonInitialized.load()) {
  // BEFORE any libjami call — the data/config dirs resolve once and cache. A failure leaves g_daemonReady false,
  // so EnsureAccount reports the explicit startup failure instead of noAccount; nothing is created or retried.
  if (!SetupDataDirs()) return;
  Log("--- Syb-L libjami boot ---");
  Log(std::string("version=") + libjami::version());
  Log("platform=" + std::string(libjami::platform()));
  Log("arch=" + std::string(libjami::arch()));

  // P3-B3 / L2: console logging rides the same opt-in as the boot file-log (a GUI app attaches no console, so
  // in release this was inert noise — keep the daemon quiet unless SYBL_DEBUG_LOG diagnostics are requested).
  const bool debugLog = GetEnvironmentVariableW(L"SYBL_DEBUG_LOG", nullptr, 0) > 0;
  // init() mutates process-global crypto/logger/manager state before every fallible step completes. Never invoke it
  // again after a failed attempt; recovery from a partial native initialization requires a clean process.
  if (g_daemonInitAttempted.exchange(true)) {
    Log("init previously failed; refusing unsafe retry");
    return;
  }
  const bool ok = libjami::init(
      static_cast<libjami::InitFlag>(libjami::LIBJAMI_FLAG_START_INACTIVE |
          (debugLog ? libjami::LIBJAMI_FLAG_CONSOLE_LOG : 0)));
  if (!ok) {
    Log("init=FAIL");
    return;
  }
  g_daemonInitialized.store(true);
  Log("init=OK");
  g_micMuted.store(false);
  try {
    // call.cpp applies this only while an incoming call is still RINGING;
    // connected calls have no client lifetime timer. The API has no disabled
    // value (zero/negative expire immediately), so use its maximum duration.
    constexpr auto kNoPracticalRingExpiry =
        std::numeric_limits<std::int32_t>::max();
    libjami::setRingingTimeout(kNoPracticalRingExpiry);
    Log("ringing timeout=INT32_MAX (effectively disabled)");
  } catch (...) {
    Log("setRingingTimeout(INT32_MAX) threw");
  }
  }

  // Register the daemon signal handlers AFTER init() and BEFORE start() so no early RegistrationState/Volatile
  // signal is missed. The daemon COPIES these wrappers into its own handler map (it owns their lifetime) — unlike
  // Android's SWIG directors we do not need to retain them. Each lambda is firewalled with try/catch.
  if (!g_signalHandlersRegistered.load()) {
  try {
    libjami::registerSignalHandlers({
        libjami::exportable_callback<libjami::ConfigurationSignal::DeviceAuthStateChanged>(
            [](const std::string& account, int state, const std::map<std::string, std::string>& details) {
              try { OnDevicePairingSignal(account, std::nullopt, state, details, true); } catch (...) {}
            }),
        libjami::exportable_callback<libjami::ConfigurationSignal::AddDeviceStateChanged>(
            [](const std::string& account, uint32_t operation, int state, const std::map<std::string, std::string>& details) {
              try { OnDevicePairingSignal(account, operation, state, details, false); } catch (...) {}
            }),
        libjami::exportable_callback<libjami::ConfigurationSignal::DeviceRevocationEnded>(
            [](const std::string& accountId, const std::string& deviceId, int status) {
              try {
                {
                  std::lock_guard<std::mutex> lock(g_mutex);
                  g_updateDeviceRevocations.erase({accountId, deviceId});
                }
                g_deviceRevocations.Ended(accountId, deviceId, status, GetTickCount64());
              } catch (...) { Log("device revocation callback failed"); }
            }),
        libjami::exportable_callback<libjami::ConfigurationSignal::RegistrationStateChanged>(
            [](const std::string& accountId, const std::string& state, int, const std::string&) {
              try {
                const std::map<std::string, std::string> data{{"accountId", accountId}, {"state", state}};
                bool active;
                {
                  std::lock_guard<std::mutex> lock(g_mutex);
                  g_regByAccount[accountId] = data;
                  active = accountId == g_accountId;
                }
                if (active) Emit("registrationState", data);
              } catch (...) {
              }
            }),
        libjami::exportable_callback<libjami::ConfigurationSignal::ContactAdded>(
            [](const std::string& accountId, const std::string&, bool) {
              try {
                Post([accountId]() {
                  try { RefreshRoutingSnapshot(accountId); }
                  catch (...) { Log("contactAdded routing refresh threw"); }
                });
              } catch (...) {}
            }),
        libjami::exportable_callback<libjami::ConfigurationSignal::ContactRemoved>(
            [](const std::string& accountId, const std::string& peer, bool) {
              try {
                if (!RetireControlTrust(accountId, BareJamiId(peer)))
                  Log("contact removal control retirement is incomplete");
                Post([accountId]() {
                  try { RefreshRoutingSnapshot(accountId); }
                  catch (...) { Log("contactRemoved routing refresh threw"); }
                });
              } catch (...) {}
            }),
        libjami::exportable_callback<libjami::ConfigurationSignal::ProfileReceived>(
            [](const std::string& accountId, const std::string& from,
               const std::string& /*path*/) {
              try {
                Post([accountId, from]() {
                  try {
                    OnPeerProfile(accountId, from);
                  } catch (...) {
                    Log("peer profile projection threw");
                  }
                });
              } catch (...) {
              }
            }),
        libjami::exportable_callback<libjami::ConfigurationSignal::VolatileDetailsChanged>(
            [](const std::string& accountId, const std::map<std::string, std::string>& details) {
              try {
                auto it = details.find(libjami::Account::VolatileProperties::DEVICE_ANNOUNCED);
                if (it != details.end()) {
                  const std::map<std::string, std::string> data{{"accountId", accountId},
                                                               {"announced", it->second}};
                  bool active;
                  {
                    std::lock_guard<std::mutex> lock(g_mutex);
                    g_announcedByAccount[accountId] = data;
                    active = accountId == g_accountId;
                  }
                  if (active) Emit("deviceAnnounced", data);
                }
              } catch (...) {
              }
            }),
        // Delivery status of an account (non-swarm) message — the reachability probe (presence). Forward the
        // message id + state so Dart resolves FAILURE=4 (unreachable) / DISPLAYED=3. NOTE: SENT=2 is a LOCAL
        // socket-write success, not a peer ack (daemon message_engine.cpp) — Dart no longer treats it as
        // liveness; the pong is the real end-to-end proof.
        libjami::exportable_callback<libjami::ConfigurationSignal::AccountMessageStatusChanged>(
            [](const std::string& accountId, const std::string& conversationId, const std::string& peer,
               const std::string& messageId, int state) {
              try {
                if (conversationId.empty() ? !IsTrustedPeer(accountId, peer)
                                           : !IsOwnedConversation(accountId, conversationId)) return;
                Emit("messageStatus", {{"accountId", accountId}, {"conversationId", conversationId},
                                        {"peerJamiId", BareJamiId(peer)},
                                        {"messageId", messageId},
                                        {"state", std::to_string(state)}});
              } catch (...) {
              }
            }),
        // presence v2: an account (non-swarm) message arrived — the ping/pong path. Daemon emit order
        // confirmed at sipaccountbase.cpp:282: (accountId, FROM, MESSAGE-ID, payloads); the id is "" on the
        // channel path (jamiaccount.cpp:4768), so it is deliberately unused.
        libjami::exportable_callback<libjami::ConfigurationSignal::ActiveCallsChanged>(
            [](const std::string& accountId, const std::string& conversationId,
               const std::vector<std::map<std::string, std::string>>& calls) {
              try {
                const auto snapshot = RoutingSnapshot();
                if (!snapshot || snapshot->account_id != accountId ||
                    !snapshot->Group(conversationId)) return;
                Emit("groupCallsChanged",
                     {{"accountId", accountId},
                      {"conversationId", conversationId},
                      {"callsJson", GroupCallsJson(calls)}});
              } catch (...) {}
            }),
        libjami::exportable_callback<libjami::ConfigurationSignal::NeedsHost>(
            [](const std::string& accountId, const std::string& conversationId) {
              try {
                const auto snapshot = RoutingSnapshot();
                if (!snapshot || snapshot->account_id != accountId ||
                    !snapshot->Group(conversationId)) return;
                Emit("groupNeedsHost",
                     {{"accountId", accountId},
                      {"conversationId", conversationId}});
              } catch (...) {}
            }),
        libjami::exportable_callback<libjami::ConfigurationSignal::IncomingAccountMessage>(
            [](const std::string& accountId, const std::string& from, const std::string& /*messageId*/,
               const std::map<std::string, std::string>& payloads) {
              try {
                OnAccountMessage(accountId, BareJamiId(from), payloads);
              } catch (...) {
              }
            }),
        // Presence: forward the RAW tri-state (0=DISCONNECTED, 1=AVAILABLE, 2=CONNECTED — daemon jamiaccount.h
        // PresenceState). 2 = a live authenticated P2P channel to the peer RIGHT NOW (truth). 1 = a DHT
        // DeviceAnnouncement record — on the jami.net profile that record is proxy-held for ~24 h and replayed on
        // every (re)subscribe, so it can be a day stale; Dart treats it as a hint to verify, never as "online".
        // Flattening 1/2 into one bool was the original stale-green bug. Uri normalized to bare hex (parity: the
        // Android head emits an Int; Dart's _asInt parses both).
        libjami::exportable_callback<libjami::PresenceSignal::NewBuddyNotification>(
            [](const std::string& accountId, const std::string& buddyUri, int status,
               const std::string& /*lineStatus*/) {
              try {
                const auto bare = BareJamiId(buddyUri);
                const bool trusted = IsTrustedPeer(accountId, bare);
                {
                  std::lock_guard<std::mutex> lock(g_mutex);
                  if (trusted && accountId == g_accountId && status >= 2)
                    g_connectedPeers.insert(bare);
                  else
                    g_connectedPeers.erase(bare);
                }
                if (!trusted) return;
                Emit("presence",
                     {{"accountId", accountId}, {"peerJamiId", bare},
                      {"status", std::to_string(status)}});
              } catch (...) {
              }
            }),
        // Incoming call: snapshot the media offer BY VALUE now (the daemon-owned reference dangles after this
        // returns) so AnswerCall can mirror it. Emit the bare-hex caller id + whether the offer carries live video.
        // Args confirmed at daemon manager.cpp: (accountId, callId, peerNumber, mediaList).
        libjami::exportable_callback<libjami::CallSignal::IncomingCall>(
             [](const std::string& accountId, const std::string& callId, const std::string& from,
                const std::vector<std::map<std::string, std::string>>& mediaList) {
              std::shared_ptr<OutgoingPlacementBarrier> placementBarrier;
              try {
                {
                std::lock_guard<std::mutex> dispatch(g_callSignalMutex);
                if (!GroupConferenceForCall(accountId, callId).empty()) return;
                AuthenticatedCallPeer authenticated;
                try { authenticated = AuthenticatedPeerFromDaemon(accountId, callId); } catch (...) {}
                const bool trusted = !authenticated.accountId.empty() && !authenticated.deviceId.empty() &&
                    authenticated.accountId == BareJamiId(from) && IsTrustedPeer(accountId, authenticated.accountId);
                if (!trusted) {
                  {
                    std::lock_guard<std::mutex> lock(g_mutex);
                    g_rejectedCallIds.insert(callId);
                  }
                  Post([accountId, callId]() { try { libjami::refuse(accountId, callId); } catch (...) {} });
                  return;
                }
                bool suppress = false;
                bool refuse = false;
                {
                   std::lock_guard<std::mutex> lock(g_mutex);
                   const std::string& bare = authenticated.accountId;
                   if (g_updateShutdown.reserved() || g_identityActivationPending || !g_activeGroupConferenceId.empty() ||
                       !g_pendingGroupConferenceId.empty()) {
                     g_rejectedCallIds.insert(callId);
                     suppress = true;
                     refuse = true;
                   }
                   const auto admission =
                       sybl::calls::AdmitIncoming(trusted, bare, g_reservedCallPeer);
                   const bool claimedEmptySlot =
                       admission == sybl::calls::IncomingAdmission::kAcceptFirst;
                   if (!suppress && claimedEmptySlot) {
                     g_reservedCallPeer = bare;
                   } else if (admission ==
                              sybl::calls::IncomingAdmission::kRejectCrossPeerBusy) {
                     g_rejectedCallIds.insert(callId);
                     suppress = true;
                     refuse = true;
                   }
                   const std::string effectiveWinner = !g_currentWinnerCallId.empty()
                       ? g_currentWinnerCallId : (g_placingOutgoing ? g_winnerCallIdDuringPlacement : std::string());
                   if (!suppress && g_recentTerminalCallIds.find(callId) != g_recentTerminalCallIds.end()) {
                    // The terminal callback overtook this signal. Do not recreate peer/offer/tombstone state.
                    suppress = true;
                    refuse = true;
                   } else if (!suppress && (g_rejectedCallIds.find(callId) != g_rejectedCallIds.end() ||
                       (!effectiveWinner.empty() && effectiveWinner != callId))) {
                    // A CURRENT winner already exists. Unlike pre-CURRENT glare, this ring is safe to refuse now.
                    g_callPeers[callId] = bare;
                    g_rejectedCallIds.insert(callId);
                    suppress = true;
                     refuse = true;
                   } else if (!suppress && effectiveWinner == callId) {
                    suppress = true;  // reordered duplicate for the already-established call
                   } else if (!suppress) {
                    g_callPeers[callId] = bare;
                    g_incomingOffers[callId] = mediaList;
                    // Hold only this callback's return until an already-started placement completes. The patched
                    // daemon then refreshes currentCall and performs its own crossed-call rule.
                     if (g_placingOutgoing && g_activeCallId.empty())
                       placementBarrier = g_outgoingPlacementBarrier;
                   }
                   if (suppress && claimedEmptySlot)
                     ClearCallReservationIfIdleLocked(bare);
                }
                if (suppress) {
                  if (refuse) {
                    Post([accountId, callId]() { try { libjami::refuse(accountId, callId); } catch (...) {} });
                  }
                  return;
                }
                Log("incomingCall(" + callId + ") from=" + BareJamiId(from) +
                    " withVideo=" + (ListHasActiveVideo(mediaList) ? "1" : "0"));
                Emit("incomingCall", {{"accountId", accountId}, {"callId", callId},
                                      {"fromJamiId", authenticated.accountId},
                                      {"withVideo", ListHasActiveVideo(mediaList) ? "true" : "false"}});
                }
                // placeCallWithMedia can synchronously emit StateChange, so never hold g_callSignalMutex here.
                // This is an event wait with no timeout; every placement exit completes the barrier.
                WaitForOutgoingPlacement(placementBarrier);
              } catch (...) {
              }
            }),
        // Call state: forward to Dart (callId/state/code). Windows audio is daemon-owned (PortAudio/WASAPI) — no
        // client audio routing or foreground service to drive, unlike Android. Drop the cached offer on terminal.
        // Args confirmed at daemon call.cpp: (accountId, callId, state, code).
        libjami::exportable_callback<libjami::CallSignal::StateChange>(
             [](const std::string& accountId, const std::string& callId, const std::string& state, int code) {
               try {
                std::lock_guard<std::mutex> dispatch(g_callSignalMutex);
                if (!IsActiveAccount(accountId)) return;
                const bool terminal = IsTerminalCallState(state);
                bool updateRejected = false;
                {
                  std::lock_guard<std::mutex> lock(g_mutex);
                  // StateChange can precede IncomingCall. Neither path may
                  // adopt a new call after the update owns the idle slot.
                  updateRejected = g_updateShutdown.reserved() && !terminal;
                  if (updateRejected) g_rejectedCallIds.insert(callId);
                }
                if (updateRejected) {
                  Post([accountId, callId]() { try { libjami::hangUp(accountId, callId); } catch (...) {} });
                  return;
                }
                uint64_t callAccountRevision = 0;
                {
                  std::lock_guard<std::mutex> lock(g_mutex);
                  if (accountId != g_accountId) return;
                  callAccountRevision = g_accountRevision;
                }
                auto groupConferenceId = GroupConferenceForCall(accountId, callId);
                if (!groupConferenceId.empty()) {
                  std::string reservation;
                  uint64_t revision = 0;
                  {
                    std::lock_guard<std::mutex> lock(g_mutex);
                    const auto leg = g_groupCallLegs.find(groupConferenceId);
                    if (accountId != g_accountId || g_activeGroupHosting ||
                        leg == g_groupCallLegs.end() || leg->second != callId ||
                        g_groupReservationId.empty()) return;
                    reservation = g_groupReservationId;
                    revision = g_accountRevision;
                    if (state == "CURRENT") {
                      g_activeGroupConferenceId = groupConferenceId;
                      g_pendingGroupConferenceId.clear();
                    }
                  }
                  auto publish = [accountId, reservation, groupConferenceId, callId, state, code]() {
                    Emit("groupCallLegState",
                       {{"accountId", accountId},
                        {"reservationId", reservation},
                        {"conferenceId", groupConferenceId},
                        {"callId", callId},
                        {"state", state},
                        {"code", std::to_string(code)}});
                  };
                  if (terminal) {
                    // Keep teardown and preference/volume restoration on the
                    // same worker as admission of the next media reservation.
                    Post([accountId, groupConferenceId, reservation, revision, publish]() {
                      if (ClearGroupCall(accountId, groupConferenceId, reservation, revision)) publish();
                    });
                  } else publish();
                  return;
                }
                {
                  std::lock_guard<std::mutex> lock(g_mutex);
                  // placeCall can signal before returning its exact leg ID.
                  // An unowned event must not enter the direct-call adopter.
                  // Reconcile only the returned leg after placement below.
                  if (g_groupPlacementStarted && !g_pendingGroupConferenceId.empty() &&
                      g_callPeers.find(callId) == g_callPeers.end()) return;
                }
                std::string from;
                 bool rejected = false;
                 bool peerVideo = false;
                 bool endedActiveControlCall = false;
                 std::function<void(bool)> cancelledSourceDone;
                {
                  std::lock_guard<std::mutex> lock(g_mutex);
                  rejected = g_rejectedCallIds.find(callId) != g_rejectedCallIds.end();
                  auto peer = g_callPeers.find(callId);
                  if (peer != g_callPeers.end()) from = peer->second;
                  if (terminal) {
                    MarkRecentTerminalLocked(callId);
                    if (g_placingOutgoing) g_terminalDuringPlacement.insert(callId);
                    auto offer = g_incomingOffers.find(callId);
                    peerVideo = offer != g_incomingOffers.end() && ListHasActiveVideo(offer->second);
                    g_incomingOffers.erase(callId);
                    g_peerMediaAnswersPending.erase(callId);
                    g_callPeers.erase(callId);
                    g_rejectedCallIds.erase(callId);
                     if (callId == g_activeCallId) {
                       endedActiveControlCall = true;
                      if (g_sourceTransition &&
                          g_sourceTransition->source.requested.call_id == callId) {
                        RollBackCancelledTransitionLocked(*g_sourceTransition);
                        cancelledSourceDone = std::move(g_sourceTransition->done);
                        g_sourceTransition.reset();
                      }
                      g_activeCallId.clear();
                      g_micMuted.store(false);
                      g_localVideoSource = {};
                      // Do NOT clear g_sinks here: the per-sink DecodingStopped events still fire on hangup and look
                      // up their self/remote role in g_sinks, then erase their own entry.
                    }
                    if (callId == g_currentWinnerCallId) g_currentWinnerCallId.clear();
                    if (!from.empty()) ClearCallReservationIfIdleLocked(from);
                  }
                 }
                 CompleteOnWorker(std::move(cancelledSourceDone), false);
                 if (terminal) Post([] { RefreshRemoteAudioMeters(); });
                 if (endedActiveControlCall) {
                   EmitControl(ControlSignal{
                       ControlSignalType::kCallEnded,
                       accountId,
                       callId,
                   });
                 }
                 if (from.empty() && !rejected) from = CallPeerFromDaemon(accountId, callId);
                if (!rejected && !from.empty() && !IsTrustedPeer(accountId, from)) {
                  rejected = true;
                  if (!terminal) {
                    std::lock_guard<std::mutex> lock(g_mutex);
                    g_rejectedCallIds.insert(callId);
                  }
                }
                // Empty identity fails closed. A later callback can be emitted once IncomingCall/placeCall has
                // populated g_callPeers; a stranger CURRENT is actively torn down before it owns bridge media.
                if (rejected || from.empty()) {
                  if (rejected && state == "CURRENT") {
                    Post([accountId, callId]() { try { libjami::hangUp(accountId, callId); } catch (...) {} });
                  }
                  if (rejected && terminal && !from.empty() && IsTrustedPeer(accountId, from)) {
                    // Let Dart release its matching glare tombstone; stranger calls remain completely hidden.
                    Emit("callState", {{"accountId", accountId}, {"accountRevision", std::to_string(callAccountRevision)}, {"callId", callId}, {"state", state},
                                       {"code", std::to_string(code)}, {"fromJamiId", from}});
                  }
                  return;
                }
                if (!terminal && state != "CURRENT") {
                  std::lock_guard<std::mutex> lock(g_mutex);
                  g_callPeers[callId] = from;
                }
                std::vector<std::pair<std::string, bool>> retiredSiblings;  // id, was incoming
                bool staleCurrent = false;
                bool secondCurrent = false;
                if (state == "CURRENT") {
                  {
                    std::lock_guard<std::mutex> lock(g_mutex);
                    staleCurrent = g_recentTerminalCallIds.find(callId) != g_recentTerminalCallIds.end();
                    if (staleCurrent && g_placingOutgoing && g_winnerCallIdDuringPlacement.empty())
                      g_winnerCallIdDuringPlacement = callId;
                    const std::string effectiveWinner = !g_currentWinnerCallId.empty()
                        ? g_currentWinnerCallId : (g_placingOutgoing ? g_winnerCallIdDuringPlacement : std::string());
                    secondCurrent = !staleCurrent &&
                        (g_rejectedCallIds.find(callId) != g_rejectedCallIds.end() ||
                         (!effectiveWinner.empty() && effectiveWinner != callId));
                    if (secondCurrent) {
                      g_callPeers[callId] = from;
                      g_rejectedCallIds.insert(callId);
                    } else if (!staleCurrent) {
                      if (g_sourceTransition &&
                          g_sourceTransition->source.requested.call_id != callId) {
                        RollBackCancelledTransitionLocked(*g_sourceTransition);
                        cancelledSourceDone = std::move(g_sourceTransition->done);
                        g_sourceTransition.reset();
                      }
                      g_callPeers[callId] = from;
                      g_currentWinnerCallId = callId;
                      g_reservedCallPeer = from;
                      g_activeCallId = callId;  // authoritative; the REMOTE decoded sink id == this
                      if (g_placingOutgoing && g_winnerCallIdDuringPlacement.empty())
                        g_winnerCallIdDuringPlacement = callId;
                      auto offer = g_incomingOffers.find(callId);
                      peerVideo = offer != g_incomingOffers.end() && ListHasActiveVideo(offer->second);
                      g_incomingOffers.erase(callId);
                      // A ring can predate a slow outgoing video placement and miss libjami's glare comparison.
                      // CURRENT is the safe boundary: tombstone and end every same-peer sibling now.
                      for (const auto& sibling : g_callPeers) {
                        if (sibling.first == callId) continue;
                        const bool wasIncoming = g_incomingOffers.erase(sibling.first) != 0;
                        g_rejectedCallIds.insert(sibling.first);
                        retiredSiblings.emplace_back(sibling.first, wasIncoming);
                      }
                      // The local camera sink survives a daemon-selected leg replacement; move its ownership too.
                      for (auto& sink : g_sinks) {
                        if (sink.second->role == "self") sink.second->callId = callId;
                      }
                      g_localVideoSource.call_id = callId;
                    }
                  }
                  CompleteOnWorker(std::move(cancelledSourceDone), false);
                  if (staleCurrent) {
                    Post([accountId, callId]() { try { libjami::hangUp(accountId, callId); } catch (...) {} });
                    return;
                  }
                  if (secondCurrent) {
                    Post([accountId, callId]() { try { libjami::hangUp(accountId, callId); } catch (...) {} });
                    return;
                  }
                  if (!retiredSiblings.empty()) {
                    Log("CURRENT winner " + callId + "; retiring " +
                        std::to_string(retiredSiblings.size()) + " glare sibling(s)");
                  }
                  for (const auto& sibling : retiredSiblings) {
                    Post([accountId, sibling]() {
                      try {
                        if (sibling.second) libjami::refuse(accountId, sibling.first);
                        else libjami::hangUp(accountId, sibling.first);
                      } catch (...) {}
                    });
                  }
                  if (g_micMuted.load()) {
                    Post([accountId, callId]() {
                      bool shouldMute = false;
                      {
                        std::lock_guard<std::mutex> lock(g_mutex);
                        shouldMute = g_activeCallId == callId && g_currentWinnerCallId == callId && g_micMuted.load();
                      }
                      if (!shouldMute) return;
                      try { libjami::muteLocalMedia(accountId, callId, "MEDIA_TYPE_AUDIO", true); }
                      catch (...) { Log("reapply mute to CURRENT threw"); }
                    });
                  }
                }
                bool cameraOn = false;
                bool selfActive = false;
                bool remoteActive = false;
                screen_source::Outgoing outgoing;
                {
                  std::lock_guard<std::mutex> lock(g_mutex);
                  outgoing = g_localVideoSource;
                  if (!outgoing.uri.empty()) outgoing.call_id = callId;
                  cameraOn = outgoing.kind == screen_source::Kind::Camera;
                  for (const auto& sink : g_sinks) {
                    if (sink.second->callId != callId) continue;
                    selfActive = selfActive || sink.second->role == "self";
                    remoteActive = remoteActive || sink.second->role == "remote";
                  }
                }
                Emit("callState",
                     {{"accountId", accountId}, {"accountRevision", std::to_string(callAccountRevision)}, {"callId", callId},
                      {"state", state}, {"code", std::to_string(code)}, {"fromJamiId", from},
                      {"cameraOn", cameraOn ? "true" : "false"},
                      {"outgoingVideoKind", screen_source::KindName(outgoing.kind)},
                      {"outgoingVideoUri", outgoing.uri},
                      {"outgoingVideoRevision", std::to_string(outgoing.epoch)},
                      {"outgoingVideoWidth", std::to_string(outgoing.width)},
                      {"outgoingVideoHeight", std::to_string(outgoing.height)},
                      {"micMuted", g_micMuted.load() ? "true" : "false"}, {"speakerOn", "false"},
                      {"peerVideo", peerVideo ? "true" : "false"},
                      {"selfActive", selfActive ? "true" : "false"},
                      {"remoteActive", remoteActive ? "true" : "false"}});
              } catch (...) {
              }
            }),
        // Syb-L's typed in-call side channels. Annotation retains its existing trusted-contact sender gate. Remote
        // control additionally requires account+device identity from the secure transport's peer certificate;
        // there is deliberately no signalling-metadata fallback.
        // Args per callmanager_interface.h: (accountId, callId, from, messages[mime→body]).
        libjami::exportable_callback<libjami::CallSignal::ConferenceCreated>(
            [](const std::string& accountId, const std::string& conversationId, const std::string& conferenceId) {
              try {
                const auto owner = CaptureAccountCommandOwner(accountId);
                if (!owner) return;
                std::string reservation;
                {
                  std::lock_guard<std::mutex> lock(g_mutex);
                  const auto owned = g_groupConversationByConference.find(conferenceId);
                  if (!g_groupPlacementStarted ||
                      (conferenceId != g_pendingGroupConferenceId && conferenceId != g_activeGroupConferenceId) ||
                      owned == g_groupConversationByConference.end() || owned->second != conversationId) return;
                  reservation = g_groupReservationId;
                }
                Post([owner = *owner, conversationId, conferenceId, reservation] {
                  try {
                    if (!OwnsAccountCommand(owner)) return;
                    const auto conferences = libjami::getConferenceList(owner.accountId);
                    if (std::find(conferences.begin(), conferences.end(), conferenceId) == conferences.end()) return;
                    {
                      std::lock_guard<std::mutex> lock(g_mutex);
                      const auto owned = g_groupConversationByConference.find(conferenceId);
                      if (owner.accountId != g_accountId || owner.revision != g_accountRevision ||
                          g_identityActivationPending || !g_groupPlacementStarted || g_groupReservationId != reservation ||
                          (conferenceId != g_pendingGroupConferenceId && conferenceId != g_activeGroupConferenceId) ||
                          owned == g_groupConversationByConference.end() || owned->second != conversationId) return;
                      g_activeGroupConferenceId = conferenceId;
                      g_pendingGroupConferenceId.clear();
                    }
                    Emit("groupConferenceCreated", {{"accountId", owner.accountId}, {"reservationId", reservation},
                         {"conversationId", conversationId}, {"conferenceId", conferenceId}});
                  } catch (...) {}
                });
              } catch (...) {}
            }),
        libjami::exportable_callback<libjami::CallSignal::ConferenceChanged>(
            [](const std::string& accountId, const std::string& conferenceId,
               const std::string& state) {
              try {
                if (!IsActiveAccount(accountId) ||
                    sybl::group_call::RoomId(conferenceId).empty()) return;
                Emit("groupConferenceChanged",
                     {{"accountId", accountId},
                      {"conferenceId", conferenceId},
                      {"state", state}});
              } catch (...) {}
            }),
        libjami::exportable_callback<libjami::CallSignal::ConferenceRemoved>(
            [](const std::string& accountId,
               const std::string& conferenceId) {
              try {
                if (!IsActiveAccount(accountId) ||
                    sybl::group_call::RoomId(conferenceId).empty()) return;
                std::string reservation, leg;
                uint64_t revision = 0;
                {
                  std::lock_guard<std::mutex> lock(g_mutex);
                  if (accountId != g_accountId || !g_groupPlacementStarted ||
                      (conferenceId != g_activeGroupConferenceId &&
                       conferenceId != g_pendingGroupConferenceId)) return;
                  reservation = g_groupReservationId;
                  revision = g_accountRevision;
                  const auto found = g_groupCallLegs.find(conferenceId);
                  if (found != g_groupCallLegs.end()) leg = found->second;
                }
                if (reservation.empty()) return;
                // The daemon signal has no placement generation. A reused
                // conference ID is not proof that the current placement ended.
                Post([accountId, conferenceId, reservation, revision, leg] {
                  try {
                    const auto calls = libjami::getCallList(accountId);
                    const auto conferences = libjami::getConferenceList(accountId);
                    if ((!leg.empty() && std::find(calls.begin(), calls.end(), leg) != calls.end()) ||
                        std::find(conferences.begin(), conferences.end(), conferenceId) != conferences.end()) return;
                    if (!ClearGroupCall(accountId, conferenceId, reservation, revision)) return;
                    Emit("groupConferenceRemoved",
                         {{"accountId", accountId}, {"reservationId", reservation},
                          {"conferenceId", conferenceId}});
                  } catch (...) {}
                });
              } catch (...) {}
            }),
        libjami::exportable_callback<libjami::CallSignal::OnConferenceInfosUpdated>(
            [](const std::string& conferenceOrCallId,
               const std::vector<std::map<std::string, std::string>>& incomingInfos) {
              try {
                if (!sybl::group_call::ConferenceInfoWithinBounds(incomingInfos)) return;
                const auto owner = CaptureAccountCommandOwner(std::nullopt);
                if (!owner) return;
                std::string conferenceId = conferenceOrCallId, reservation;
                {
                  std::lock_guard<std::mutex> lock(g_mutex);
                  if (sybl::group_call::RoomId(conferenceId).empty()) {
                    for (const auto& entry : g_groupCallLegs)
                      if (entry.second == conferenceOrCallId) { conferenceId = entry.first; break; }
                  }
                  if (!g_groupPlacementStarted ||
                      (conferenceId != g_activeGroupConferenceId && conferenceId != g_pendingGroupConferenceId) ||
                      !g_groupConversationByConference.count(conferenceId)) return;
                  reservation = g_groupReservationId;
                }
                {
                  std::lock_guard<std::mutex> lock(g_mutex);
                  if (!g_running) return;
                  g_conferenceInfoIngress.Offer(
                      ConferenceInfoRequest{*owner, conferenceId, conferenceOrCallId, reservation},
                      sybl::group_call::ConferenceInfoIngress<ConferenceInfoRequest>::Clock::now());
                }
                g_cv.notify_one();
              } catch (...) {}
            }),
        libjami::exportable_callback<libjami::CallSignal::IncomingMessage>(
            [](const std::string& accountId, const std::string& callId, const std::string& from,
               const std::map<std::string, std::string>& messages) {
              try {
                if (!IsTrustedPeer(accountId, from)) return;
                if (const auto it = messages.find(kAnnotMime); it != messages.end()) {
                  {
                    std::lock_guard<std::mutex> lock(g_mutex);
                    const auto admitted = g_callPeers.find(callId);
                    if (it->second.size() > 65536 || callId != g_activeCallId ||
                        callId != g_currentWinnerCallId || admitted == g_callPeers.end() ||
                        admitted->second != BareJamiId(from)) return;
                  }
                  Emit("callMessage", {{"accountId", accountId}, {"callId", callId},
                                       {"channel", "annotation"}, {"mimeType", kAnnotMime},
                                       {"fromJamiId", BareJamiId(from)}, {"payload", it->second}});
                }
                if (const auto it = messages.find(kControlMime); it != messages.end()) {
                  if (it->second.empty() || it->second.size() > kMaxTypedCallMessageBytes) return;
                  {
                    std::lock_guard<std::mutex> lock(g_mutex);
                    if (!g_controlMessageAdmission.Admit(accountId, callId, from,
                        it->second.size(), GetTickCount64())) return;
                  }
                  const auto observed = GetTickCount64();
                  uint64_t observedRevision = 0, observedTrust = 0;
                  const auto signaling = BareJamiId(from);
                  {
                    std::lock_guard<std::mutex> lock(g_mutex);
                    observedRevision = g_accountRevision;
                    const auto trust = g_controlTrustEpochs.find(signaling);
                    if (trust != g_controlTrustEpochs.end()) observedTrust = trust->second;
                  }
                  const auto authenticated = AuthenticatedPeerFromDaemon(accountId, callId);
                  if (authenticated.accountId.empty() || authenticated.deviceId.empty() ||
                      !IsTrustedPeer(accountId, authenticated.accountId)) {
                    return;
                  }
                  screen_source::Outgoing source;
                  std::string admittedPeer;
                  std::string localJamiId;
                  bool exactActiveCall = false;
                  bool localScreenActive = false;
                  {
                    std::lock_guard<std::mutex> lock(g_mutex);
                    const auto admitted = g_callPeers.find(callId);
                    if (admitted != g_callPeers.end()) admittedPeer = admitted->second;
                    exactActiveCall = accountId == g_accountId &&
                        IsAuthoritativeCallLocked(callId) &&
                        !g_sourceTransition;
                    source = g_localVideoSource;
                    localScreenActive =
                        exactActiveCall && OwnsLiveScreenFrameLocked(source) &&
                        source.call_id == callId && source.width > 0 &&
                        source.height > 0;
                    if (g_routingSnapshot &&
                        g_routingSnapshot->account_id == accountId) {
                      localJamiId = g_routingSnapshot->self_id;
                    }
                  }
                  if (!exactActiveCall ||
                      !sybl::remote::AuthenticatedControlPeerMatches(
                          signaling, authenticated.accountId,
                          authenticated.deviceId, admittedPeer)) {
                    return;
                  }
                  ControlSignal signal{
                      ControlSignalType::kMessage,
                      accountId,
                      callId,
                      authenticated.accountId,
                      authenticated.deviceId,
                      it->second,
                      localScreenActive ? source.uri : std::string(),
                      localScreenActive ? source.epoch : 0,
                      localScreenActive ? source.width : 0,
                      localScreenActive ? source.height : 0,
                      localScreenActive,
                      authenticated.localIcePath,
                      authenticated.localLanProven,
                      localJamiId,
                  };
                  {
                    std::lock_guard<std::mutex> lock(g_mutex);
                    const auto trust = g_controlTrustEpochs.find(signal.controllerAccountId);
                    if (observedRevision == g_accountRevision && trust != g_controlTrustEpochs.end() &&
                        observedTrust == trust->second &&
                        MatchesControlAuthorityLocked(signal)) {
                      auto authority = signal;
                      authority.payload.clear();
                      g_controlAuthorityLease.Publish({std::move(authority), observedRevision, trust->second}, observed, GetTickCount64());
                    }
                  }
                  EmitControl(signal);
                }
              } catch (...) {
              }
            }),
        // Mid-call media renegotiation: the peer toggled their camera → mirror + answer, surface peerVideo.
        libjami::exportable_callback<libjami::CallSignal::MediaChangeRequested>(
            [](const std::string& accountId, const std::string& callId,
               const std::vector<std::map<std::string, std::string>>& mediaList) {
              try {
                if (!IsActiveAccount(accountId)) return;
                OnMediaChangeRequested(callId, mediaList);
              } catch (...) {
              }
            }),
        libjami::exportable_callback<libjami::CallSignal::MediaNegotiationStatus>(
            [](const std::string& callId, const std::string& event,
               const std::vector<std::map<std::string, std::string>>& mediaList) {
              try {
                OnMediaNegotiationStatus(callId, event, mediaList);
              } catch (...) {
              }
            }),
        // Stabilized post-DSP voice truth from the active call's daemon audio
        // sender. Dart may display it but never feeds it back into media
        // control; transmission has already been decided in libjami.
        libjami::exportable_callback<libjami::CallSignal::LocalVoiceActivity>(
            [](const std::string& callId, bool active) {
              try {
                std::string accountId;
                {
                  std::lock_guard<std::mutex> lock(g_mutex);
                  if (!IsAuthoritativeCallLocked(callId)) return;
                  accountId = g_accountId;
                }
                if (accountId.empty()) return;
                Emit("localVoiceActivity",
                     {{"accountId", accountId},
                      {"callId", callId},
                      {"active", active ? "true" : "false"}});
              } catch (...) {
              }
            }),
        // Diagnostic/display-only capture-ring RMS meter. Capture, resampling,
        // and DSP stay in the daemon; it is not a transmission authority.
        libjami::exportable_callback<libjami::AudioSignal::AudioMeter>(
            [](const std::string& id, float level) {
              try {
                if (!std::isfinite(level)) return;
                const float bounded = std::clamp(level, 0.0f, 1.0f);
                if (id == "audiolayer_id") {
                  bool probe = false;
                  {
                    std::lock_guard<std::mutex> lock(g_mutex);
                    if (g_audioMeterRequested && g_remoteAudioMeters.streams.empty() &&
                        GetTickCount64() >= g_remoteMeterProbeAfter) {
                      g_remoteMeterProbeAfter = GetTickCount64() + 1000;
                      probe = true;
                    }
                  }
                  if (probe) Post([] { RefreshRemoteAudioMeters(); });
                  Emit("audioMeter", {{"id", id}, {"level", std::to_string(bounded)}});
                } else {
                  RemoteAudioMeterOwner owner;
                  {
                    std::lock_guard<std::mutex> lock(g_mutex);
                    if (!g_audioMeterRequested || g_identityActivationPending ||
                        g_remoteAudioMeters.revision != g_accountRevision ||
                        g_remoteAudioMeters.account != g_accountId ||
                        !IsAuthoritativeCallLocked(g_remoteAudioMeters.call) ||
                        !g_remoteAudioMeters.streams.count(id)) return;
                    owner = g_remoteAudioMeters;
                  }
                  Emit("remoteAudioMeter", {{"accountId", owner.account},
                      {"accountRevision", std::to_string(owner.revision)},
                      {"callId", owner.call}, {"streamId", id},
                      {"level", std::to_string(bounded)}});
                }
              } catch (...) {
              }
            }),
        // Video sinks decoded/stopped (both the remote stream == callId and our local camera == "camera://<dev>").
        // Args confirmed at videomanager_interface.h: DecodingStarted(id, shm, w, h, is_mixer) / Stopped(id, shm,
        // is_mixer).
        libjami::exportable_callback<libjami::VideoSignal::DecodingStarted>(
            [](const std::string& id, const std::string& /*shm*/, int w, int h, bool /*is_mixer*/) {
              try {
                OnDecodingStarted(id, w, h);
              } catch (...) {
              }
            }),
        libjami::exportable_callback<libjami::VideoSignal::DecodingStopped>(
            [](const std::string& id, const std::string& /*shm*/, bool /*is_mixer*/) {
              try {
                OnDecodingStopped(id);
              } catch (...) {
              }
            }),
        // File transfer (M5): a transfer changed state (created/ongoing/finished/closed).
        libjami::exportable_callback<libjami::DataTransferSignal::DataTransferEvent>(
            [](const std::string& accountId, const std::string& conversationId, const std::string& interactionId,
               const std::string& fileId, int eventCode) {
              try {
                OnDataTransferEvent(accountId, conversationId, interactionId, fileId, eventCode);
              } catch (...) {
              }
            }),
        libjami::exportable_callback<libjami::DataTransferSignal::DataTransferEventOwned>(
            [](const std::string& accountId, const std::string& conversationId,
               const std::string& interactionId, const std::string& fileId,
               const std::string& attemptId, int eventCode) {
              try {
                OnDataTransferEvent(accountId, conversationId, interactionId, fileId, eventCode, attemptId);
              } catch (...) {}
            }),
        // A new swarm message — a data-transfer commit is an incoming/outgoing file.
        libjami::exportable_callback<libjami::ConversationSignal::SwarmMessageReceived>(
            [](const std::string& accountId, const std::string& conversationId,
               const libjami::SwarmMessage& message) {
              try {
                OnSwarmMessage(accountId, conversationId, message);
              } catch (...) {
              }
            }),
        libjami::exportable_callback<libjami::ConversationSignal::ReactionAdded>(
            [](const std::string& account, const std::string& conversation, const std::string& message,
               std::map<std::string, std::string> reaction) {
              try { OnReaction(account, conversation, message, &reaction); } catch (...) {}
            }),
        libjami::exportable_callback<libjami::ConversationSignal::ReactionRemoved>(
            [](const std::string& account, const std::string& conversation, const std::string& message,
               const std::string& reaction) {
              try { OnReaction(account, conversation, message, nullptr, reaction); } catch (...) {}
            }),
        // The daemon folds edits/deletions onto the original interaction before surfacing this signal.
        libjami::exportable_callback<libjami::ConversationSignal::SwarmMessageUpdated>(
            [](const std::string& accountId, const std::string& conversationId,
               const libjami::SwarmMessage& message) {
              try {
                OnSwarmMessageUpdated(accountId, conversationId, message);
              } catch (...) {
              }
            }),
        // The loadConversation reply (M6): the conversation's history → the persistent shared folder.
        libjami::exportable_callback<libjami::ConversationSignal::MessagesFound>(
            [](uint32_t id, const std::string& account, const std::string& conversation,
               std::vector<std::map<std::string, std::string>> messages) {
              try { OnHistorySearch(id, account, conversation, std::move(messages)); } catch (...) {}
            }),
        libjami::exportable_callback<libjami::ConversationSignal::SwarmLoaded>(
            [](uint32_t id, const std::string& accountId, const std::string& conversationId,
               std::vector<libjami::SwarmMessage> messages) {
              try {
                OnSwarmLoaded(id, accountId, conversationId, messages);
              } catch (...) {
              }
            }),
        // The contact conversation became ready — cache its id for file ops.
        libjami::exportable_callback<libjami::ConversationSignal::ConversationReady>(
            [](const std::string& accountId, const std::string& conversationId) {
              try {
                OnConversationReady(accountId, conversationId);
              } catch (...) {
              }
            }),
        libjami::exportable_callback<libjami::ConfigurationSignal::ComposingStatusChanged>(
            [](const std::string& accountId,
               const std::string& conversationId, const std::string& from,
               int status) {
              try {
                const auto peer = BareJamiId(from);
                const auto snapshot = RoutingSnapshot();
                if (!snapshot || !snapshot->AcceptsComposerActivity(
                                     accountId, conversationId, peer, status)) {
                  return;
                }
                Emit("composerActivity",
                     {{"accountId", accountId},
                      {"fromJamiId", peer},
                      {"conversationId", conversationId},
                      {"kind", status == 1 ? "typing" : "idle"}});
              } catch (...) {
              }
            }),
        libjami::exportable_callback<libjami::ConversationSignal::ConversationRemoved>(
            [](const std::string& accountId,
               const std::string& /*conversationId*/) {
              try {
                Post([accountId]() {
                  try {
                    RefreshRoutingSnapshot(accountId);
                  } catch (...) {
                    Log("conversationRemoved routing refresh threw");
                  }
                });
              } catch (...) {
              }
            }),
        libjami::exportable_callback<libjami::ConversationSignal::ConversationMemberEvent>(
            [](const std::string& accountId,
               const std::string& /*conversationId*/,
               const std::string& /*memberUri*/, int /*event*/) {
              try {
                Post([accountId]() {
                  try {
                    RefreshRoutingSnapshot(accountId);
                  } catch (...) {
                    Log("conversationMember routing refresh threw");
                  }
                });
              } catch (...) {
              }
            }),
        libjami::exportable_callback<libjami::ConversationSignal::ConversationSyncFinished>(
            [](const std::string& accountId) {
              try {
                if (accountId == CurrentAccountId()) {
                  Emit("conversationSyncFinished", {{"accountId", accountId}});
                }
              } catch (...) {
              }
              }),
        libjami::exportable_callback<libjami::ConversationSignal::SybLMessageCompleted>(
            [](const std::string& account, const std::string& conversation,
               const std::string& operation, const std::string& commit) {
              try {
                auto owned = UpdateOwnedFileCommit(account, conversation, operation, commit);
                if (!owned) owned = CompleteOwnedMessage(account, conversation, operation, !commit.empty());
                if (!owned) return;
                Emit("sendOperationCompleted", {{"accountId", account}, {"peerJamiId", owned->peer},
                    {"conversationId", conversation}, {"operationId", operation},
                    {"status", commit.empty() ? "unknown" : "committed"}, {"commitId", commit}});
              } catch (...) {}
            }),
        libjami::exportable_callback<libjami::ConversationSignal::SybLFileSeedReady>(
            [](const std::string& account, const std::string& conversation,
               const std::string& operation, const std::string& commit,
               const std::string& file, bool ready) {
              try {
                if (commit.empty() || commit.size() > 1024 || file.empty() || file.size() > 1024) return;
                std::string peer;
                bool retained = false;
                {
                  std::lock_guard<std::mutex> lock(g_mutex);
                  const auto found = g_ownedFiles.find(operation);
                  if (found == g_ownedFiles.end()) return;
                  auto& owned = found->second;
                  if (owned.command.owner.accountId != account || owned.command.conversation != conversation ||
                      (!owned.commit.empty() && owned.commit != commit) ||
                      (!owned.file.empty() && owned.file != file)) return;
                  owned.commit = commit;
                  owned.file = file;
                  owned.ready = owned.ready || ready;
                  retained = owned.ready;
                  peer = owned.command.peer;
                }
                Emit("fileSeedReady", {{"accountId", account}, {"peerJamiId", peer},
                    {"conversationId", conversation}, {"operationId", operation},
                    {"commitId", commit}, {"fileId", file}, {"ready", retained ? "true" : "false"}});
              } catch (...) {}
            }),
        libjami::exportable_callback<libjami::ConversationSignal::ConversationProfileUpdated>(
            [](const std::string& accountId, const std::string& conversationId,
              const std::map<std::string, std::string>& /*profile*/) {
              try {
                if (!IsOwnedConversation(accountId, conversationId)) return;
                const auto peerId = ConversationOwner(accountId, conversationId);
                if (peerId.empty()) return;
                if (sybl::routing::GroupConversationId(peerId)) {
                  Post([accountId]() {
                    try {
                      RefreshRoutingSnapshot(accountId);
                    } catch (...) {
                      Log("group profile routing refresh threw");
                    }
                  });
                }
              } catch (...) {
              }
            }),
        // Surface every remaining friend/group request. Jami already consumed trusted one-to-one requests.
        libjami::exportable_callback<libjami::ConversationSignal::ConversationRequestReceived>(
            [](const std::string& accountId, const std::string& conversationId,
               const std::map<std::string, std::string>& metadatas) {
              try {
                std::string from, mode, title;
                auto it = metadatas.find("from");
                if (it != metadatas.end()) from = it->second;
                it = metadatas.find("mode");
                if (it != metadatas.end()) mode = it->second;
                it = metadatas.find("title");
                if (it != metadatas.end()) title = it->second;
                OnConversationRequest(accountId, conversationId, from, mode, title);
              } catch (...) {
              }
            }),
    });
    g_signalHandlersRegistered.store(true);
    Log("signal handlers registered");
  } catch (...) {
    Log("registerSignalHandlers threw");
    return;
  }
  }

  // No NO_AUTOLOAD flag -> the daemon autoloads any persisted account (the reuse path).
  if (!g_daemonStarted.load()) {
  // Manager::init marks itself initialized before every start step has completed. A failed start may therefore have
  // created process-global state that cannot be safely initialized again; visible retries must fail closed instead.
  if (g_daemonStartAttempted.exchange(true)) {
    Log("start previously failed; refusing unsafe retry");
    return;
  }
  const bool started = libjami::start();
  if (!started) {
    Log("start=FAIL");
    return;
  }
  g_daemonStarted.store(true);
  Log("start=OK");
  // Normalize the process-global flag left by older builds after the audio driver can exist. In-call controls below
  // are call-scoped; this one-time write only opens a legacy gate that could otherwise survive an upgrade.
  try { libjami::muteCapture(false); } catch (...) { Log("legacy muteCapture normalization threw"); }
  }
  if (!libjami::initialized()) {
    Log("initialized=false");
    return;
  }
  Log("initialized=true");

  // Adopt a persisted account id into the cache so myJamiId works before ensureAccount is called.
  try {
    if (g_pendingRestore && g_pendingRestore->phase == sybl::identity_restore::Phase::kRollingBack)
      FinishIdentityRestoreRollback();
    auto list = libjami::getAccountList();
    // A valid restore marker admits only its guarded recovery path. Ordinary
    // archive create/export still require g_archiveProtectionReady.
    const bool rollingBack = g_pendingRestore &&
        g_pendingRestore->phase == sybl::identity_restore::Phase::kRollingBack;
    if (!rollingBack && !InitializeArchiveProtection(list) && !g_pendingRestore) return;
    Log("boot: accounts loaded=" + std::to_string(list.size()));  // DIAG: 0 => daemon didn't load the account
    for (const auto& a : list) {
      auto d = libjami::getAccountDetails(a);
      auto u = d.find(libjami::Account::ConfProperties::USERNAME);
      Log("boot: account=" + a + " username=" + (u != d.end() ? u->second : std::string("<none>")));
    }
    const auto resetAccount = ResetDoorlightMarker();
    if (!resetAccount.empty()) {
      std::lock_guard<std::mutex> lock(g_mutex);
      g_resetDoorlightPending = true;
      g_identityActivationPending = true;
    }
    if (!resetAccount.empty() && AccountExists(resetAccount)) {
      if (!DisablePreparedAccount(resetAccount)) throw std::runtime_error("reset account could not be disabled");
    }
    std::string picked = resetAccount.empty() ? PickAccount(list) : std::string{};
    if (!picked.empty()) {
      PinCallPolicy(picked);
      {
        std::lock_guard<std::mutex> lock(g_mutex);
        SelectAccountLocked(picked);
      }
      // Call/message trust gates consult this immutable projection. Readiness without it would silently reject
      // early traffic until a later contact/conversation callback happened to rebuild the snapshot.
      RefreshRoutingSnapshot(picked);
      { std::lock_guard<std::mutex> lock(g_mutex); g_networkPreparedRevision = g_accountRevision; }
      (void) ActivatePreparedAccount(picked);
    }
  } catch (...) {
    Log("boot: getAccountList threw");
    return;
  }
  // EnsureAccount may create a new identity. Publish readiness only after
  // every prerequisite that protects that mutation has succeeded.
  g_daemonReady.store(true);
  } catch (...) {
    Log("BootDaemon threw");
    g_daemonReady.store(false);
  }
}

}  // namespace

namespace {

// Worker only, with g_mutex held. Queries below run on the same worker as
// identity changes; their native callbacks cannot bypass the protected maps.
bool UpdateNativeIdleLocked() {
  return g_running && g_daemonReady.load() && !g_accountId.empty() &&
      !g_resetDoorlightPending && !g_identityActivationPending &&
      !g_pendingRestore && !g_pendingRestoreBlocked && !g_pendingRestoreOwner &&
      !g_archiveRecoveryBlocked &&
      MediaSlotIdleLocked() && g_groupReservationId.empty() &&
      !g_groupPlacementStarted && g_groupCallLegs.empty() &&
      g_incomingOffers.empty() && g_currentWinnerCallId.empty() &&
      !g_sourceTransition && !g_recordingOwner &&
      (!g_pairing || g_pairing->flow->snapshot().terminal) &&
      g_receiveAttempts.empty() && g_reservedReceivePaths.empty() &&
      g_outgoingStagingPaths.empty() && g_ownedMessages.empty() && g_ownedFiles.empty() &&
      g_updateActiveTransfers.empty() && g_updateDeviceRevocations.empty() &&
      g_tasks.empty();
}

// Query without either admission mutex: daemon callbacks may need those locks.
// The final owner/revision/idle check and reservation serialize with call signals.
bool UpdateDaemonCallsIdle(const std::string& account) {
  return !account.empty() && libjami::getCallList(account).empty() &&
      libjami::getConferenceList(account).empty();
}

}  // namespace

bool UpdateShutdownPending() {
  std::lock_guard<std::mutex> lock(g_mutex);
  return g_updateShutdown.pending();
}

void PrepareUpdateShutdown(const std::string& expectedAccountId, std::function<void(bool)> done) {
  bool began = false;
  uint64_t attempt = 0;
  try {
    {
      std::lock_guard<std::mutex> lock(g_mutex);
      began = g_running && g_daemonReady.load() && expectedAccountId == g_accountId &&
          g_updateShutdown.Begin(expectedAccountId, g_accountRevision);
      if (began) attempt = g_updateShutdown.attempt();
    }
    if (!began) { if (done) done(false); return; }
    // Closing platform admission above and posting a FIFO barrier preserves
    // all earlier commands, including their ordinary success/failure replies.
    Post([expectedAccountId, attempt, done] {
      bool ready = false;
      try {
        bool current;
        { std::lock_guard<std::mutex> lock(g_mutex); current = g_updateShutdown.current(attempt); }
        const bool callsIdle = current && UpdateDaemonCallsIdle(expectedAccountId);
        std::lock_guard<std::mutex> dispatch(g_callSignalMutex);
        std::lock_guard<std::mutex> lock(g_mutex);
        ready = g_updateShutdown.Reserve(attempt, g_accountId, g_accountRevision,
            callsIdle && UpdateNativeIdleLocked());
        if (!ready) g_updateShutdown.Cancel(attempt);
      } catch (...) {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_updateShutdown.Cancel(attempt);
      }
      try { if (done) done(ready); } catch (...) {}
    });
  } catch (...) {
    if (began) {
      std::lock_guard<std::mutex> lock(g_mutex);
      g_updateShutdown.Cancel(attempt);
    }
    try { if (done) done(false); } catch (...) {}
  }
}

void CancelUpdateShutdown(std::function<void(bool)> done) {
  bool cancelled;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    cancelled = g_updateShutdown.Cancel();
  }
  try { if (done) done(cancelled); } catch (...) {}
}

void CommitUpdateShutdown(std::function<bool()> postQuit, std::function<void(bool)> done) {
  try {
    uint64_t attempt;
    { std::lock_guard<std::mutex> lock(g_mutex); attempt = g_updateShutdown.attempt(); }
    Post([postQuit, done, attempt] {
      bool committed = false;
      try {
        std::string account;
        {
          std::lock_guard<std::mutex> lock(g_mutex);
          if (g_updateShutdown.current(attempt) && g_updateShutdown.reserved()) account = g_accountId;
        }
        const bool callsIdle = UpdateDaemonCallsIdle(account);
        std::lock_guard<std::mutex> dispatch(g_callSignalMutex);
        std::lock_guard<std::mutex> lock(g_mutex);
        committed = g_updateShutdown.Commit(attempt, g_accountId, g_accountRevision,
            callsIdle && UpdateNativeIdleLocked(), postQuit);
      } catch (...) {}
      try { if (done) done(committed); } catch (...) {}
    });
  } catch (...) { try { if (done) done(false); } catch (...) {} }
}

void RetryBoot() noexcept {
  try {
    bool needsStart = false;
    {
      std::lock_guard<std::mutex> lock(g_mutex);
      needsStart = !g_everStarted;
    }
    if (needsStart) {
      Start();
      return;
    }
    Post(BootDaemon);
  } catch (...) {
    try { Log("BootDaemon retry post failed"); } catch (...) {}
  }
}

void ResetDoorlight(const std::string& accountId, std::function<void(bool)> done) {
  try {
    Post([accountId, done] {
      bool removed = false;
      try {
        const auto marker = ResetDoorlightMarker();
        std::string selected;
        {
          std::lock_guard<std::mutex> lock(g_mutex);
          if (!g_daemonReady.load() || !g_archiveProtectionReady || g_archiveRecoveryBlocked ||
              g_pendingRestore || g_pendingRestoreBlocked || (g_pairing && !g_pairing->flow->snapshot().terminal) ||
              !MediaSlotIdleLocked(g_resetDoorlightPending) ||
              (!g_accountId.empty() && g_accountId != accountId))
            throw std::runtime_error("reset owner busy or changed");
          selected = g_accountId;
        }
        const auto accounts = libjami::getAccountList();
        removed = sybl::reset::LocalAccount(accountId, marker, selected, accounts,
            [&] {
              {
                std::lock_guard<std::mutex> lock(g_mutex);
                if (!MediaSlotIdleLocked(g_resetDoorlightPending)) return false;
                g_resetDoorlightPending = true;
                g_identityActivationPending = true;
              }
              if (!RecordWindowsSybLRevokeAndWait(3000) ||
                  (AccountExists(accountId) && !DisablePreparedAccount(accountId))) return false;
              std::lock_guard<std::mutex> lock(g_mutex);
              SelectAccountLocked("");
              return true;
            },
            [](const auto& id) { libjami::removeAccount(id); },
            [](const auto& id) {
              return !AccountExists(id) &&
                  std::filesystem::symlink_status(g_jamiDataDir / id).type() == std::filesystem::file_type::not_found &&
                  std::filesystem::symlink_status(g_jamiDataDir.parent_path() / L"cache" / id).type() == std::filesystem::file_type::not_found;
            });
      } catch (...) { removed = false; }
      if (done) done(removed);
    });
  } catch (...) { if (done) done(false); }
}

void Start() {
  RecordWindowsSybLConfigure(RecordingOwnerCurrent, RecordingOwnerReleased);
  RecordWindowsSybLSetForeground(g_foreground.load());
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_everStarted) return;  // single-shot for the process — a 2nd Start() after Stop() must NOT re-arm
    g_everStarted = true;
    g_running = true;
  }
  // std::thread's ctor can throw std::system_error (thread exhaustion). Start() is called from OnCreate — a
  // runner frame compiled _HAS_EXCEPTIONS=0 — so a throw must NEVER unwind out of here. Contain it, roll the
  // latch back so a retry is possible, and Post BootDaemon only once the worker actually exists.
  try {
    g_worker = std::thread(WorkerLoop);
  } catch (...) {
    Log("worker thread create failed");
    std::lock_guard<std::mutex> lock(g_mutex);
    g_everStarted = false;
    g_running = false;
    return;
  }
  // Post() (deque push) + the task capture can throw bad_alloc; this is entered from OnCreate (a _HAS_EXCEPTIONS=0
  // runner frame), so contain it. The worker is already up — if this throws the daemon just doesn't boot and Stop()
  // will still drain+join the idle worker cleanly.
  try {
    Post([] { CleanUnissuedRecordings(); BootDaemon(); });
  } catch (...) {
    Log("BootDaemon post failed");
  }
}

void Stop() {
  g_daemonReady.store(false);
  RecordWindowsSybLSetForeground(false);
  RecordWindowsSybLRevokeAndWait(3000);
  RecordWindowsSybLConfigure(nullptr, nullptr);
  CancelKnownDeviceRevocations();
  bool finiQueueFailed = false;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (!g_running) return;
    // Enqueue fini and close the posting gate under one lock. It remains FIFO after BootDaemon/earlier work, while
    // daemon callbacks can no longer slip work behind finalization.
    try {
      g_tasks.emplace_back([] {
        try {
          if (libjami::initialized()) {
            try { libjami::setAudioMeterState("audiolayer_id", false); } catch (...) {}
            Log("fini");
            libjami::fini();
          }
        } catch (...) {
          Log("fini threw");
        }
      });
    } catch (...) {
      finiQueueFailed = true;
    }
    g_conferenceInfoIngress.Clear();
    g_running = false;  // NOTE: g_everStarted is NOT reset — Start() stays single-shot for the process.
  }
  if (finiQueueFailed) Log("fini queue failed");
  g_cv.notify_one();
  if (g_worker.joinable()) g_worker.join();
  std::vector<SearchMessageRequest> pending;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    pending = g_searchMessageLoads.TakeAll();
  }
  for (const auto& request : pending) {
    try { if (request.done) request.done(std::nullopt); } catch (...) {}
  }
}

void SetEventSink(EventSink sink) {
  // Entered from the runner (onListen/onCancel/dtor — _HAS_EXCEPTIONS=0), and the std::function/std::map copies
  // below can throw bad_alloc, so the whole body is firewalled (the per-replay try/catch blocks stay for granular
  // logging).
  try {
    std::map<std::string, std::string> reg, ann;
    bool haveReg, haveAnn;
    {
      std::lock_guard<std::mutex> lock(g_mutex);
      g_sink = sink;
      haveReg = g_haveReg;
      reg = g_regData;
      haveAnn = g_haveAnnounced;
      ann = g_announcedData;
    }
    // Replay the latest state to the fresh listener (the daemon often REGISTERs / announces before Dart's onListen
    // attaches, and EventChannel drops pre-onListen events). The sink does a PostMessage hop, so this is safe to
    // call from the platform thread (it just defers the delivery).
    if (sink) {
      if (haveReg) {
        try {
          sink("registrationState", reg);
        } catch (...) {
        }
      }
      if (haveAnn) {
        try {
          sink("deviceAnnounced", ann);
        } catch (...) {
        }
      }
      // Account-scoped requests/rings wait for ReplayPendingNativeEvents(), after Dart has installed account and
      // friend gates. Replaying them here can make a stale persisted account discard a real native event.
    }
  } catch (...) {
    Log("setEventSink threw");
  }
}

std::string ControlAccountForCall(const std::string& call_id,
                                  const std::string& peer_account) {
  try {
    std::lock_guard<std::mutex> lock(g_mutex);
    const auto peer = g_callPeers.find(call_id);
    if (g_accountId.empty() || !IsAuthoritativeCallLocked(call_id) ||
        peer == g_callPeers.end() || peer->second != peer_account ||
        !g_routingSnapshot || !g_routingSnapshot->IsTrusted(peer_account))
      return {};
    return g_accountId;
  } catch (...) {
    Log("control account query threw");
    return {};
  }
}

std::string ControlPeerNameForCall(const std::string& account_id,
                                  const std::string& call_id,
                                  const std::string& peer_account) {
  try {
    if (account_id.empty() ||
        ControlAccountForCall(call_id, peer_account) != account_id)
      return "Your friend";
    const auto profile = CachedPeerProfile(account_id, peer_account);
    if (!profile || profile->display_name.empty() ||
        ControlAccountForCall(call_id, peer_account) != account_id)
      return "Your friend";
    return profile->display_name;
  } catch (...) {
    return "Your friend";
  }
}

void SetControlSink(ControlSink sink) {
  try {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_controlSink = std::move(sink);
  } catch (...) {
    Log("setControlSink threw");
  }
}

bool ReplayPendingNativeEvents() {
  try {
    struct PendingReplay {
      std::string from;
      bool is_group = false;
      std::string name;
    };
    std::map<std::string, PendingReplay> pending;
    struct IncomingReplay {
      std::string call_id;
      std::string peer_id;
      bool with_video = false;
    };
    std::vector<IncomingReplay> incoming;
    std::string accountId;
    {
      std::lock_guard<std::mutex> lock(g_mutex);
      if (!g_sink || g_accountId.empty()) return false;
      accountId = g_accountId;
      for (const auto& entry : g_pendingConnect) {
        const auto owner = g_pendingConnectAccount.find(entry.first);
        if (owner == g_pendingConnectAccount.end() || owner->second != accountId)
          continue;
        const auto group = g_pendingConnectIsGroup.find(entry.first);
        const auto name = g_pendingConnectName.find(entry.first);
        pending.emplace(entry.first, PendingReplay{
            entry.second,
            group != g_pendingConnectIsGroup.end() && group->second,
            name == g_pendingConnectName.end() ? std::string{} : name->second});
      }
      for (const auto& entry : g_incomingOffers) {
        const auto peer = g_callPeers.find(entry.first);
        if (peer != g_callPeers.end() && !peer->second.empty()) {
          incoming.push_back(
              {entry.first, peer->second, ListHasActiveVideo(entry.second)});
        }
      }
    }
    for (const auto& entry : pending) {
      Emit("connectRequest", {{"accountId", accountId},
                              {"conversationId", entry.first},
                              {"fromJamiId", entry.second.from},
                              {"isGroup", entry.second.is_group ? "true" : "false"},
                              {"name", entry.second.name}});
    }
    for (const auto& entry : incoming) {
      Emit("incomingCall", {{"accountId", accountId},
                            {"callId", entry.call_id},
                            {"fromJamiId", entry.peer_id},
                            {"fromName", ""},
                            {"withVideo", entry.with_video ? "true" : "false"}});
    }
    // libjami persists undecided requests, while g_pendingConnect is process-local. Run the daemon query on
    // its worker after Dart installs account/friend gates. Reuse live callback validation and bounded admission;
    // a request delivered concurrently by the callback becomes a no-op duplicate.
    Post([accountId] {
      if (!IsActiveAccount(accountId)) return;
      try {
        for (const auto& request : libjami::getConversationRequests(accountId)) {
          if (!IsActiveAccount(accountId)) break;
          const auto id = request.find("id");
          if (id == request.end() ||
              !sybl::timeline::IsRequiredUtf8(
                  id->second, sybl::timeline::kMaxDaemonIdCodeUnits)) {
            // A corrupt daemon ID is not safe to pass to declineConversationRequest.
            Log("persisted conversation request has invalid id");
            continue;
          }
          const auto from = request.find("from");
          const auto mode = request.find("mode");
          const auto title = request.find("title");
          OnConversationRequest(accountId,
                                id->second,
                                from == request.end() ? "" : from->second,
                                mode == request.end() ? "" : mode->second,
                                title == request.end() ? "" : title->second);
        }
      } catch (...) {
        Log("replay persisted conversation requests threw");
      }
    });
    return IsActiveAccount(accountId);
  } catch (...) {
    Log("replayPendingNativeEvents threw");
    return false;
  }
}

bool RevalidateControlAuthority(const ControlSignal& expected) {
  try {
    bool valid = false;
    bool refresh = false;
    uint64_t revision = 0, trustEpoch = 0;
    {
      std::lock_guard<std::mutex> lock(g_mutex);
      if (!MatchesControlAuthorityLocked(expected)) return false;
      const auto trust = g_controlTrustEpochs.find(expected.controllerAccountId);
      if (trust == g_controlTrustEpochs.end()) return false;
      revision = g_accountRevision;
      trustEpoch = trust->second;
      const auto now = GetTickCount64();
      const auto snapshot = g_controlAuthorityLease.Current(now);
      valid = snapshot && snapshot->account_revision == revision && snapshot->trust_epoch == trustEpoch &&
          SameControlAuthority(snapshot->signal, expected);
      refresh = g_controlAuthorityLease.RefreshDue(now) && !g_controlAuthorityRefreshPending;
      if (refresh) g_controlAuthorityRefreshPending = true;
    }
    if (refresh) {
      auto owned = expected;
      owned.payload.clear();
      Post([owned = std::move(owned), revision, trustEpoch] { RefreshControlAuthority(owned, revision, trustEpoch); });
    }
    return valid;
  } catch (...) {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_controlAuthorityRefreshPending = false;
    return false;
  }
}

void RefreshControllerClipboardAuthority(const std::string& call_id,
    const std::string& peer_account, std::function<void(bool)> done) {
  try {
    const auto account = ControlAccountForCall(call_id, peer_account);
    uint64_t revision = 0, trust_epoch = 0;
    {
      std::lock_guard<std::mutex> lock(g_mutex);
      revision = g_accountRevision;
      const auto trust = g_controlTrustEpochs.find(peer_account);
      if (trust != g_controlTrustEpochs.end()) trust_epoch = trust->second;
    }
    Post([account, call_id, peer_account, revision, trust_epoch, done] {
      bool valid = false;
      try {
        const auto started = GetTickCount64();
        const auto authenticated = AuthenticatedPeerFromDaemon(account, call_id);
        {
          std::lock_guard<std::mutex> lock(g_mutex);
          const auto trust = g_controlTrustEpochs.find(peer_account);
          const auto admitted = g_callPeers.find(call_id);
          valid = !account.empty() && account == g_accountId && revision == g_accountRevision &&
              !g_identityActivationPending && IsAuthoritativeCallLocked(call_id) &&
              admitted != g_callPeers.end() && admitted->second == peer_account &&
              trust != g_controlTrustEpochs.end() && trust->second == trust_epoch &&
              g_routingSnapshot && g_routingSnapshot->account_id == account &&
              g_routingSnapshot->IsTrusted(peer_account) &&
              authenticated.accountId == peer_account && !authenticated.deviceId.empty();
          if (valid) {
            ControlSignal signal;
            signal.accountId = account;
            signal.callId = call_id;
            signal.controllerAccountId = peer_account;
            signal.controllerDeviceId = authenticated.deviceId;
            g_controllerClipboardLease.Publish({std::move(signal), revision, trust_epoch},
                started, GetTickCount64());
          }
        }
      } catch (...) { valid = false; }
      if (done) done(valid);
    });
  } catch (...) { if (done) done(false); }
}

bool WithControllerClipboardAuthority(const std::string& account_id,
    const std::string& call_id, const std::string& peer_account,
    const std::string& peer_device, const std::function<bool()>& apply) {
  try {
    // Account/call/trust retirement uses this same lock. Never call daemon APIs
    // or emit callbacks inside this transaction.
    std::lock_guard<std::mutex> lock(g_mutex);
    const auto lease = g_controllerClipboardLease.Current(GetTickCount64());
    const auto trust = g_controlTrustEpochs.find(peer_account);
    const auto admitted = g_callPeers.find(call_id);
    if (!lease || lease->account_revision != g_accountRevision ||
        trust == g_controlTrustEpochs.end() || lease->trust_epoch != trust->second ||
        g_identityActivationPending || account_id != g_accountId ||
        !IsAuthoritativeCallLocked(call_id) || admitted == g_callPeers.end() ||
        admitted->second != peer_account || !g_routingSnapshot ||
        g_routingSnapshot->account_id != account_id || !g_routingSnapshot->IsTrusted(peer_account) ||
        lease->signal.accountId != account_id || lease->signal.callId != call_id ||
        lease->signal.controllerAccountId != peer_account ||
        lease->signal.controllerDeviceId != peer_device || peer_device.empty()) return false;
    return apply && apply();
  } catch (...) { return false; }
}

std::optional<OwnedScreenSource> ResolveOwnedScreenSource(
    const std::string& callId, std::uint64_t sourceRevision) {
  try {
    if (callId.empty() || sourceRevision == 0) return std::nullopt;
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_accountId.empty() || !IsAuthoritativeCallLocked(callId) ||
        g_sourceTransition ||
        g_localVideoSource.kind != screen_source::Kind::Screen ||
        g_localVideoSource.call_id != callId ||
        g_localVideoSource.epoch != sourceRevision ||
        g_localVideoSource.uri.empty() || g_localVideoSource.width <= 0 ||
        g_localVideoSource.height <= 0 ||
        !OwnsLiveScreenFrameLocked(g_localVideoSource)) {
      return std::nullopt;
    }
    return OwnedScreenSource{g_localVideoSource.uri,
                             g_localVideoSource.epoch,
                             g_localVideoSource.width,
                             g_localVideoSource.height};
  } catch (...) {
    return std::nullopt;
  }
}

void EnsureAccount(const std::string& displayName, const std::string& preferredAccountId,
                   const std::string& preferredPeerId, bool createIfMissing,
                   std::function<void(const Account&)> done) {
  // Entered from the runner (_HAS_EXCEPTIONS=0). Post()/the capture can throw bad_alloc — contain it AND still
  // complete `done` (capture it by COPY) so the Dart MethodResult isn't left unanswered (Flutter logs that as a
  // leak). The lambda's copy fires on success; the outer copy only fires from the catch — exactly once either way.
  try {
    Post([displayName, preferredAccountId, preferredPeerId, createIfMissing, done]() {
      Account acc;
      try {
        // Inside the try: a std::string copy can throw bad_alloc, and WorkerLoop runs task() unguarded — a throw
        // escaping here would terminate the worker thread. (acc stays declared outside so the catch path can still
        // complete `done` with an empty Account.)
        {
          std::lock_guard<std::mutex> lock(g_mutex);
          if (!g_daemonReady.load() || !g_archiveProtectionReady || g_resetDoorlightPending)
            throw std::runtime_error(
                "native engine or device archive protection is unavailable");
        }
        const auto boundedHint = sybl::profile_wire::DecodeDisplayName(displayName);
        acc.displayName = boundedHint && !boundedHint->empty() ? *boundedHint : "Me";
        auto list = libjami::getAccountList();
        if (list.empty() && !createIfMissing) {
          acc.status = "noAccount";
          if (done) done(acc);
          return;
        }
        if (list.empty() && (!boundedHint || boundedHint->empty()))
          throw std::runtime_error("invalid display name");
        std::string id = !list.empty() ? PickAccount(list, preferredAccountId)
                                      : (g_pendingRestore || g_pendingRestoreBlocked ? std::string{} : CreateAccount(*boundedHint));
        if (id.empty()) {
          acc.status = g_pendingRestore || g_pendingRestoreBlocked ? "restorePending" : "noAccount";
          if (done) done(acc);
          return;
        }
        PinCallPolicy(id);
        acc.accountId = id;
        {
          std::lock_guard<std::mutex> lock(g_mutex);
          SelectAccountLocked(id);
        }
        acc.jamiId = AwaitUsername(id);
        // Surface the PERSISTED Account.enable so Dart reconciles the appear-offline pref with the daemon's
        // truth (mirrors Android ensureAccount).
        {
          auto det = libjami::getAccountDetails(id);
          auto display = det.find(libjami::Account::ConfProperties::DISPLAYNAME);
          if (display != det.end()) {
            const auto bounded =
                sybl::profile_wire::DecodeDisplayName(display->second);
            if (bounded && !bounded->empty()) acc.displayName = *bounded;
          }
          auto en = det.find("Account.enable");
          acc.enabled = (en == det.end() || en->second != "false");
        }
        // Surface deviceAnnounced now if the account is already reachable on the DHT — a cold daemon often isn't
        // ready the instant it REGISTERs, so the UI gates the first call on this (VolatileDetailsChanged also
        // emits it when it flips later).
        auto vol = libjami::getVolatileAccountDetails(id);
        auto it = vol.find(libjami::Account::VolatileProperties::DEVICE_ANNOUNCED);
        acc.announced = it != vol.end() && it->second == "true";
        {
          std::lock_guard<std::mutex> lock(g_mutex);
          g_announcedByAccount[id] = {{"accountId", id},
                                      {"announced", acc.announced ? "true" : "false"}};
          auto reg = g_regByAccount.find(id);
          if (reg != g_regByAccount.end()) {
            auto state = reg->second.find("state");
            if (state != reg->second.end()) acc.registration = state->second;
          }
          SelectAccountLocked(id);
        }
        RefreshRoutingSnapshot(id);
        if (const auto profile = ReadPeerProfile(g_jamiDataDir / id / "profile.vcf"))
          acc.avatarBase64 = profile->avatar_base64;
        Emit("deviceAnnounced", {{"accountId", id},
                                  {"announced", acc.announced ? "true" : "false"}});
        Log("ensureAccount(" + displayName + ") jamiId=" + acc.jamiId);
        acc.status = "ok";
      } catch (...) {
        Log("ensureAccount threw");
      }
      try {
        if (done) done(acc);
      } catch (...) {
      }
    });
  } catch (...) {
    Log("ensureAccount post failed");
    try {
      if (done) done(Account{});
    } catch (...) {
    }
  }
}

void LoadSendJournal(std::function<void(bool, std::optional<std::string>)> done) {
  Post([done] {
    const auto root = sybl::archive::ArchiveSecretStore::DefaultPath();
    if (!root) { done(false, std::nullopt); return; }
    const auto result = sybl::journal::Load(root->parent_path() / L"send-journal.dpapi");
    done(result.healthy, result.source);
  });
}

void DiscardUnissuedStage(const std::string& path, std::function<void(bool)> done) {
  Post([path, done] {
    bool removed = false;
    try {
      std::lock_guard<std::mutex> lock(g_mutex);
      auto& registry = StageRegistryLocked();
      const auto root = sybl::picked_file::DefaultStagingRoot();
      if (root && !registry.OwnsIssued(path)) {
        std::error_code error;
        const auto candidate = std::filesystem::u8path(path);
        const auto status = std::filesystem::symlink_status(candidate, error);
        const bool absent = status.type() == std::filesystem::file_type::not_found &&
            (!error || error == std::errc::no_such_file_or_directory);
        if (absent || sybl::picked_file::Discard(candidate, *root)) removed = registry.Forget(path);
      }
    } catch (...) {}
    done(removed);
  });
}

void SaveSendJournal(const std::string& source, std::function<void(bool)> done) {
  Post([source, done] {
    const auto root = sybl::archive::ArchiveSecretStore::DefaultPath();
    done(root && sybl::journal::Save(root->parent_path() / L"send-journal.dpapi", source));
  });
}

void MyJamiId(std::function<void(const std::string&)> done) {
  try {
    Post([done]() {
      std::string jid;
      try {
        std::string id;
        {
          std::lock_guard<std::mutex> lock(g_mutex);
          id = g_accountId;
        }
        if (id.empty()) {
          id = PickAccount(libjami::getAccountList());
        }
        if (!id.empty()) {
          auto d = libjami::getAccountDetails(id);
          auto it = d.find(libjami::Account::ConfProperties::USERNAME);
          if (it != d.end()) jid = it->second;
        }
      } catch (...) {
        Log("myJamiId threw");
      }
      try {
        if (done) done(jid);
      } catch (...) {
      }
    });
  } catch (...) {
    Log("myJamiId post failed");
    try {
      if (done) done(std::string());
    } catch (...) {
    }
  }
}

// Legacy pure read for rolling compatibility. The routing snapshot is refreshed by account/contact callbacks and
// explicit trust commands; this accessor never mutates or selects native routing.
void PeerId(std::function<void(const std::string&)> done) {
  try {
    Post([done]() {
      std::string peer;
      try {
        const auto snapshot = RoutingSnapshot();
        if (snapshot && !snapshot->friends.empty()) peer = snapshot->friends.begin()->first;
      } catch (...) {
        Log("peerId threw");
      }
      try {
        if (done) done(peer);
      } catch (...) {
      }
    });
  } catch (...) {
    Log("peerId post failed");
    try {
      if (done) done(std::string());
    } catch (...) {
    }
  }
}

// Fire ONE non-swarm reachability probe to the peer (a plain-Jami-id account message → the P2P message channel,
// opening one if needed; never a git commit). HONEST LIFECYCLE (daemon-verified): queued in the message engine,
// PERSISTED to cache/<acct>/messages across restarts, retried on reconnect events until SENT or 20 cumulative
// retries; no cancel API; the `flags` arg is inert in this daemon (marshaling bug drops the onlyConnected bit,
// configurationmanager.cpp:272) — Dart bounds the queue by never firing a new probe while one is in flight.
// Reports the daemon's message id as a string so the UI can correlate the "messageStatus" delivery event. Worker.
void ListFriends(std::function<void(const FriendList&)> done) {
  try {
    Post([done]() {
      FriendList result;
      try {
        const auto snapshot = RoutingSnapshot();
        if (snapshot) {
          result.revision = snapshot->revision;
          for (const auto& [peerId, route] : snapshot->friends) {
            Friend friendValue{peerId, route.confirmed, route.canonical_conversation_id};
            if (const auto profile =
                    CachedPeerProfile(snapshot->account_id, peerId)) {
              friendValue.displayName = profile->display_name;
              friendValue.avatarBase64 = profile->avatar_base64;
            }
            result.friends.push_back(std::move(friendValue));
          }
          for (const auto& [conversation_id, route] : snapshot->groups) {
            FriendList::Group group;
            group.conversationId = conversation_id;
            group.memberCount = static_cast<int64_t>(route.MemberCount());
            group.canManageMembers = route.CanManageMembers();
            group.localRole = route.local_role;
            if (!snapshot->account_id.empty()) {
              const auto profile = libjami::conversationInfos(
                  snapshot->account_id, conversation_id);
              if (const auto it = profile.find("title"); it != profile.end()) {
                group.title =
                    sybl::profile_wire::DecodeDisplayName(it->second)
                        .value_or(std::string{});
              }
              if (const auto it = profile.find("description");
                  it != profile.end()) {
                group.description = it->second;
              }
            }
            for (const auto& member_id : route.member_ids) {
              std::string role = "unknown";
              if (route.admin_member_ids.find(member_id) !=
                  route.admin_member_ids.end()) {
                role = "admin";
              } else if (route.active_member_ids.find(member_id) !=
                  route.active_member_ids.end()) {
                role = "member";
              } else if (route.invited_member_ids.find(member_id) !=
                         route.invited_member_ids.end()) {
                role = "invited";
              }
              FriendList::GroupMember member{member_id, std::move(role)};
              if (const auto profile =
                      CachedPeerProfile(snapshot->account_id, member_id)) {
                member.displayName = profile->display_name;
                member.avatarBase64 = profile->avatar_base64;
              }
              group.members.push_back(std::move(member));
            }
            result.groups.push_back(std::move(group));
          }
        }
      } catch (...) { Log("listFriends threw"); }
      try { if (done) done(result); } catch (...) {}
    });
  } catch (...) {
    Log("listFriends post failed");
    try { if (done) done(FriendList{}); } catch (...) {}
  }
}

void ListKnownDevices(std::function<void(const KnownDeviceList&)> done) {
  try {
    Post([done]() {
      KnownDeviceList result;
      try {
        const auto account = CurrentAccountId();
        if (!account.empty()) {
          const auto details = libjami::getVolatileAccountDetails(account);
          const auto current = details.find(
              libjami::Account::ConfProperties::DEVICE_ID);
          result = sybl::known_device::Project(
              libjami::getKnownRingDevices(account),
              current == details.end() ? std::string{} : current->second);
        }
      } catch (...) {
        Log("listKnownDevices threw");
      }
      try {
        if (done) done(result);
      } catch (...) {
      }
    });
  } catch (...) {
    Log("listKnownDevices post failed");
    try {
      if (done) done(KnownDeviceList{});
    } catch (...) {
    }
  }
}

void PollKnownDeviceRevocations() {
  try {
    auto ready = g_deviceRevocations.TakeReady(GetTickCount64());
    for (auto& completion : ready) {
      try { if (completion.reply) completion.reply(completion.result); }
      catch (...) { Log("device revocation reply failed"); }
    }
  } catch (...) { Log("device revocation poll failed"); }
}

void CancelKnownDeviceRevocations() {
  try { g_deviceRevocations.Close(); }
  catch (...) { Log("device revocation cancellation failed"); }
  PollKnownDeviceRevocations();
}

void RevokeKnownDevice(const std::string& accountId, const std::string& deviceId,
                       std::function<void(const DeviceRevocationResult&)> done) {
  using Status = sybl::known_device::RevocationStatus;
  std::uint64_t ticket = 0;
  try {
    sybl::known_device::RevocationRegistry::Admission admission;
    {
      std::lock_guard<std::mutex> lock(g_mutex);
      if (g_running && g_daemonReady.load())
        admission = g_deviceRevocations.Begin(accountId, deviceId, GetTickCount64(), done);
    }
    ticket = admission.ticket;
    if (ticket == 0) {
      if (done) done({accountId, deviceId, admission.status});
      return;
    }
    // Register before queuing work. SelectAccount cancels this exact ticket,
    // including account A -> B -> A while the request waits behind other work.
    Post([accountId, deviceId, ticket]() {
      std::string secret;
      try {
        if (!g_deviceRevocations.Pending(ticket)) return;
        if (IsActiveAccount(accountId)) {
          const auto details = libjami::getVolatileAccountDetails(accountId);
          const auto current = details.find(
              libjami::Account::ConfProperties::DEVICE_ID);
          const auto current_id =
              current == details.end() ? std::string{} : current->second;
          const auto known = libjami::getKnownRingDevices(accountId);
          bool recovery_blocked = false;
          bool protection_ready = false;
          {
            std::lock_guard<std::mutex> lock(g_mutex);
            secret = g_archiveSecret;
            recovery_blocked = g_archiveRecoveryBlocked;
            protection_ready = g_archiveProtectionReady;
          }
          if (!recovery_blocked && protection_ready &&
              sybl::archive::IsValidArchiveSecret(secret) &&
              sybl::known_device::CanRevoke(deviceId, current_id, known)) {
            g_deviceRevocations.Invoke(ticket, GetTickCount64(), [&] {
              {
                std::lock_guard<std::mutex> lock(g_mutex);
                g_updateDeviceRevocations.insert({accountId, deviceId});
              }
              // A false return can still mean the request was scheduled.
              // Only DeviceRevocationEnded clears this native lifetime.
              return libjami::revokeDevice(accountId, deviceId, "password", secret);
            });
          } else {
            g_deviceRevocations.Refuse(ticket, Status::kRefused);
          }
        } else {
          g_deviceRevocations.Refuse(ticket, Status::kAccountChanged);
        }
      } catch (...) {
        Log("revokeKnownDevice threw");
        g_deviceRevocations.Refuse(ticket, Status::kUnavailable);
      }
      if (!secret.empty()) SecureZeroMemory(secret.data(), secret.size());
    });
  } catch (...) {
    Log("revokeKnownDevice post failed");
    try {
      if (ticket != 0) g_deviceRevocations.Refuse(ticket, Status::kUnavailable);
      else if (done) done({accountId, deviceId, Status::kUnavailable});
    } catch (...) {
    }
  }
}

void UpdateProfile(const std::string& displayName,
                   const std::string& avatarBase64,
                   const std::string& fileType, int flag,
                   const std::optional<std::string>& expectedAccountId,
                   std::function<void(bool)> done) {
  try {
    const auto owner = CaptureAccountCommandOwner(expectedAccountId);
    if (!owner) { if (done) done(false); return; }
    Post([displayName, avatarBase64, fileType, flag, owner = *owner, done]() {
      bool ok = false;
      try {
        const auto acc = OwnsAccountCommand(owner) ? owner.accountId : std::string{};
        const auto title =
            sybl::profile_wire::DecodeDisplayName(displayName);
        const auto avatar = sybl::profile_wire::DecodeAvatar(avatarBase64);
        if (!acc.empty() && title && avatar &&
            (flag == 0 || flag == 1 || flag == 2) &&
            ((flag == 0 && fileType.empty() && avatar->empty()) ||
             (flag == 1 && fileType == "JPEG" && !avatar->empty()) ||
             (flag == 2 && fileType.empty() && avatar->empty()))) {
          libjami::updateProfile(acc, *title, *avatar, fileType, flag);
          ok = true;
        }
      } catch (...) {
        Log("updateProfile threw");
      }
      try {
        if (done) done(ok);
      } catch (...) {
      }
    });
  } catch (...) {
    try {
      if (done) done(false);
    } catch (...) {
    }
  }
}

// The friend-request payload carries the sender's display name ONLY (a vCard with FN, the format other Jami
// clients send), never the photo. An empty or invalid name sends no payload.
std::vector<uint8_t> FriendRequestPayload(const std::string& accountId) {
  auto name = libjami::getAccountDetails(accountId)[libjami::Account::ConfProperties::DISPLAYNAME];
  if (!sybl::profile_wire::DecodeDisplayName(name)) return {};
  for (auto& c : name)
    if (c == '\r' || c == '\n') c = ' ';  // one vCard line; a newline must not inject PHOTO or other keys
  if (name.empty()) return {};
  const std::string card = "BEGIN:VCARD\nVERSION:2.1\nFN:" + name + "\nEND:VCARD\n";
  return {card.begin(), card.end()};
}

void AddFriend(const std::string& peerJamiId,
               const std::optional<std::string>& expectedAccountId,
               std::function<void(bool)> done) {
  try {
    const auto owner = CaptureAccountCommandOwner(expectedAccountId);
    if (!owner) { if (done) done(false); return; }
    Post([peerJamiId, owner = *owner, done]() {
      bool ok = false;
      try {
        const auto peer = BareJamiId(peerJamiId);
        const auto acc = OwnsAccountCommand(owner) ? owner.accountId : std::string{};
        if (!acc.empty() && !peer.empty()) {
          // sendTrustRequest is addContact plus the request itself: it starts the 1:1 conversation, adds the
          // unconfirmed contact, puts the request now and caches the payload for the daemon's resend when the peer
          // comes online. A separate addContact first could let that resend race out with no payload.
          libjami::sendTrustRequest(acc, peer, FriendRequestPayload(acc));
          libjami::subscribeBuddy(acc, peer, true);
          RefreshRoutingSnapshot(acc);
          ok = IsTrustedPeer(acc, peer);
        }
      } catch (...) { Log("addFriend threw"); }
      try { if (done) done(ok); } catch (...) {}
    });
  } catch (...) {
    Log("addFriend post failed");
    try { if (done) done(false); } catch (...) {}
  }
}

void SetPresenceSubscriptions(const std::vector<std::string>& peerJamiIds,
                              std::function<void(bool)> done) {
  try {
    Post([peerJamiIds, done]() {
      bool ok = false;
      try {
        const auto acc = CurrentAccountId();
        const auto snapshot = RoutingSnapshot();
        if (acc.empty() || !snapshot || snapshot->account_id != acc) {
          if (done) done(false);
          return;
        }
        std::set<std::string> desired;
        for (const auto& value : peerJamiIds) {
          const auto peer = BareJamiId(value);
          if (peer.empty() || !snapshot->IsTrusted(peer)) {
            Log("setPresenceSubscriptions rejected an untrusted peer");
            if (done) done(false);
            return;
          }
          desired.insert(peer);
        }
        ok = ReconcilePresenceSubscriptions(acc, desired);
      } catch (...) { Log("setPresenceSubscriptions threw"); }
      try { if (done) done(ok); } catch (...) {}
    });
  } catch (...) {
    Log("setPresenceSubscriptions post failed");
    try { if (done) done(false); } catch (...) {}
  }
}

void ProbeReachable(const std::string& peerJamiId, std::function<void(const std::string&)> done) {
  try {
    const auto owner = CaptureAccountCommandOwner(std::nullopt);
    const auto epoch = g_presenceProbeEpoch.load();
    Post([peerJamiId, owner, epoch, done]() {
      std::string msgId;
      try {
        const std::string acc = owner ? owner->accountId : std::string();
        if (owner && OwnsAccountCommand(*owner) && epoch == g_presenceProbeEpoch.load() &&
            g_shareActivityPresence.load() &&
            !g_recordingOffline.load() && !acc.empty() && IsTrustedPeer(acc, peerJamiId) &&
            libjami::getAccountDetails(acc)["Account.enable"] == "true") {
          std::map<std::string, std::string> payloads{{kProbeMime, PresenceJson("ping")}};
          uint64_t id = libjami::sendAccountTextMessage(acc, peerJamiId, payloads, 0);
          if (id != 0)  // the daemon returns 0 on its failure paths — honor the "" contract
            msgId = std::to_string(id);
        }
      } catch (...) {
        Log("probeReachable threw");
      }
      if (msgId.empty())  // trust refusal and the daemon's 0-id both land here — say so (mirrors the Dart line)
        Log("probeReachable(" + BareJamiId(peerJamiId) + ") sent nothing (untrusted or daemon refusal)");
      try {
        if (done) done(msgId);
      } catch (...) {
      }
    });
  } catch (...) {
    Log("probeReachable post failed");
    try {
      if (done) done(std::string());
    } catch (...) {
    }
  }
}

// ---- inbound-trust gate + remove/block (M7.5 d) — public API; the internal OnConversationRequest helper (in the
// anonymous namespace above) surfaces the gated request, these resolve it. They reference the file-local
// BareJamiUri / g_pendingConnect (same TU). ----

// Composer activity is separate from swarm messages and the connect gate below.
void SendComposerActivity(const std::string& accountId,
                           const std::string& peerJamiId,
                           const std::string& conversationId,
                           const std::string& kind,
                           std::function<void(bool)> done) {
  try {
    Post([accountId, peerJamiId, conversationId, kind, done]() {
      bool ok = false;
      try {
        const auto peer = BareJamiId(peerJamiId);
        const auto acc = CurrentAccountId();
        const auto snapshot = RoutingSnapshot();
        if (!acc.empty() && accountId == acc &&
            (kind == "typing" || kind == "idle") &&
            snapshot && snapshot->account_id == acc &&
            snapshot->Owns(peer, conversationId)) {
          libjami::setIsComposing(acc, "swarm:" + conversationId,
                                  kind == "typing");
          ok = true;
        }
      } catch (...) {
        Log("sendComposerActivity threw");
      }
      try {
        if (done) done(ok);
      } catch (...) {
      }
    });
  } catch (...) {
    Log("sendComposerActivity post failed");
    try {
      if (done) done(false);
    } catch (...) {
    }
  }
}

std::function<bool()> HologramPresentationAuthority(const std::string& accountId,
    const std::string& peerJamiId, const std::string& conversationId) {
  const auto settings_path = sybl::identity_restore::CanonicalSettingsLease::DefaultPath();
  const auto settings = settings_path ? sybl::identity_restore::CanonicalSettingsLease::AcquireCurrent(*settings_path, false) : nullptr;
  if (!settings || !settings->AllowsFriendHolograms(accountId, peerJamiId)) return {};
  std::lock_guard<std::mutex> lock(g_mutex);
  if (!g_running || !g_daemonReady.load() || accountId != g_accountId ||
      g_identityActivationPending || !g_routingSnapshot ||
      !sybl::hologram::Authorized(*g_routingSnapshot, accountId, peerJamiId, conversationId)) return {};
  const auto revision = g_accountRevision;
  const auto routing = g_routingGeneration;
  return [accountId, peerJamiId, conversationId, revision, routing]() {
    const auto path = sybl::identity_restore::CanonicalSettingsLease::DefaultPath();
    const auto current = path ? sybl::identity_restore::CanonicalSettingsLease::AcquireCurrent(*path, false) : nullptr;
    if (!current || !current->AllowsFriendHolograms(accountId, peerJamiId)) return false;
    std::lock_guard<std::mutex> guard(g_mutex);
    return g_running && g_daemonReady.load() && accountId == g_accountId &&
        revision == g_accountRevision && routing == g_routingGeneration &&
        !g_identityActivationPending && g_routingSnapshot &&
        sybl::hologram::Authorized(*g_routingSnapshot, accountId, peerJamiId, conversationId);
  };
}

void SendHologramControl(const std::string& accountId, const std::string& peerJamiId,
                         const std::string& payload, std::function<void(bool)> done) {
  const auto owner = CaptureAccountCommandOwner(accountId);
  try {
    Post([owner, peerJamiId, payload, done]() {
      bool ok = false;
      try {
        const auto packet = sybl::hologram::Decode(payload);
        const auto peer = BareJamiId(peerJamiId);
        const auto snapshot = RoutingSnapshot();
        bool ready = false;
        { std::lock_guard<std::mutex> lock(g_mutex); ready = !g_identityActivationPending; }
        if (owner && packet && ready && OwnsAccountCommand(*owner) && snapshot &&
            sybl::hologram::Authorized(*snapshot, owner->accountId, peer, packet->conversation)) {
          const auto details = libjami::getAccountDetails(owner->accountId);
          const auto enabled = details.find("Account.enable");
          if (enabled != details.end() && enabled->second == "true") {
            // onlyConnected prevents offline storage/connection establishment.
            ok = libjami::sendAccountTextMessage(owner->accountId, peer,
                {{sybl::hologram::kMime, payload}}, 1) != 0;
          }
        }
      } catch (...) { Log("Hologram control send failed"); }
      try { if (done) done(ok); } catch (...) {}
    });
  } catch (...) { try { if (done) done(false); } catch (...) {} }
}

void SendFileThumbnail(const std::string& peerJamiId,
                       const std::string& conversationId,
                       const std::string& fileId,
                       const std::string& pngBase64,
                       std::function<void(bool)> done) {
  try {
    Post([peerJamiId, conversationId, fileId, pngBase64, done]() {
      bool ok = false;
      try {
        const auto peer = BareJamiId(peerJamiId);
        const auto acc = CurrentAccountId();
        bool connected = false;
        {
          std::lock_guard<std::mutex> lock(g_mutex);
          connected = acc == g_accountId &&
                      g_connectedPeers.find(peer) != g_connectedPeers.end();
        }
        const auto snapshot = RoutingSnapshot();
        const auto now = std::chrono::duration_cast<std::chrono::milliseconds>(
                             std::chrono::system_clock::now().time_since_epoch())
                             .count();
        const auto body = sybl::file_thumbnail_wire::Encode(
            {conversationId, fileId, now, pngBase64}, now);
        if (!acc.empty() && connected && snapshot &&
            snapshot->account_id == acc && snapshot->Owns(peer, conversationId) &&
            IsTrustedPeer(acc, peer) && body) {
          ok = libjami::sendAccountTextMessage(
                   acc, peer, {{kFileThumbnailMime, *body}}, 1) != 0;
        }
      } catch (...) {
        Log("sendFileThumbnail threw");
      }
      try {
        if (done) done(ok);
      } catch (...) {
      }
    });
  } catch (...) {
    Log("sendFileThumbnail post failed");
    try {
      if (done) done(false);
    } catch (...) {
    }
  }
}

void SendFileDeclined(const std::string& peerJamiId,
                      const std::string& conversationId,
                      const std::string& fileId,
                      std::function<void(bool)> done) {
  try {
    Post([peerJamiId, conversationId, fileId, done]() {
      bool ok = false;
      try {
        const auto peer = BareJamiId(peerJamiId);
        const auto acc = CurrentAccountId();
        const auto snapshot = RoutingSnapshot();
        const auto body = sybl::file_thumbnail_wire::EncodeDeclined(
            {conversationId, fileId});
        if (!acc.empty() && snapshot && snapshot->account_id == acc &&
            snapshot->Owns(peer, conversationId) &&
            IsTrustedPeer(acc, peer) && body) {
          ok = libjami::sendAccountTextMessage(
                   acc, peer, {{kFileDeclinedMime, *body}}, 0) != 0;
        }
      } catch (...) {
        Log("sendFileDeclined threw");
      }
      try {
        if (done) done(ok);
      } catch (...) {
      }
    });
  } catch (...) {
    Log("sendFileDeclined post failed");
    try {
      if (done) done(false);
    } catch (...) {
    }
  }
}

void NotifyCallRequest(const std::string& peerJamiId,
                       std::function<void(bool)> done) {
  try {
    Post([peerJamiId, done]() {
      bool ok = false;
      try {
        const auto peer = BareJamiId(peerJamiId);
        const auto acc = CurrentAccountId();
        const auto snapshot = RoutingSnapshot();
        const auto route = snapshot ? snapshot->Friend(peer) : nullptr;
        const auto now = std::chrono::duration_cast<std::chrono::milliseconds>(
                             std::chrono::system_clock::now().time_since_epoch())
                             .count();
        if (!acc.empty() && snapshot && snapshot->account_id == acc && route &&
            route->confirmed && !route->canonical_conversation_id.empty()) {
          const std::string body =
              "{\"v\":1,\"ts\":" + std::to_string(now) + "}";
          ok = libjami::sendAccountTextMessage(
                   acc, peer, {{kCallRequestMime, body}}, 0) != 0;
        }
      } catch (...) {
        Log("notifyCallRequest threw");
      }
      try {
        if (done) done(ok);
      } catch (...) {
      }
    });
  } catch (...) {
    Log("notifyCallRequest post failed");
    try {
      if (done) done(false);
    } catch (...) {
    }
  }
}

// Accept a gated request. A friend request also grants contact trust; a group invitation only joins the group.
void ErasePendingConnectLocked(const std::string& conversationId) {
  g_pendingConnect.erase(conversationId);
  g_pendingConnectAccount.erase(conversationId);
  g_pendingConnectIsGroup.erase(conversationId);
  g_pendingConnectName.erase(conversationId);
  // Keep the gate slot reserved while the daemon decision is in flight. A failure can then restore the card
  // without racing a newly admitted request for the last bounded slot.
}

bool RestorePendingConnectLocked(const std::string& conversationId,
                                 const std::string& accountId,
                                 const std::string& from, bool isGroup) {
  if (accountId != g_accountId || conversationId.empty() || accountId.empty() || from.empty() ||
      !g_pendingConnectGate.Restore(conversationId)) {
    return false;
  }
  g_pendingConnect[conversationId] = from;
  g_pendingConnectAccount[conversationId] = accountId;
  g_pendingConnectIsGroup[conversationId] = isGroup;
  return true;
}

void AcceptConnect(const std::string& conversationId, std::function<void(bool)> done) {
  // Erase the pending entry SYNCHRONOUSLY (under lock) before queueing the daemon ops, so a racing EventChannel
  // relisten -> SetEventSink replay can't re-surface a request that's already being accepted (the old deferred
  // erase inside Post left a window for a ghost "allow?" card). Mirrors Android, which removes from pendingConnect
  // synchronously in acceptConnect. Entered from the runner (_HAS_EXCEPTIONS=0) -> firewall the whole body.
  std::string from, accountId;
  bool isGroup = false;
  try {
    {
      std::lock_guard<std::mutex> lock(g_mutex);
      accountId = g_accountId;
      auto it = g_pendingConnect.find(conversationId);
      auto owner = g_pendingConnectAccount.find(conversationId);
      if (it != g_pendingConnect.end() && owner != g_pendingConnectAccount.end() && owner->second == accountId) {
        from = it->second;
        const auto group = g_pendingConnectIsGroup.find(conversationId);
        isGroup = group != g_pendingConnectIsGroup.end() && group->second;
        ErasePendingConnectLocked(conversationId);
      }
    }
    if (from.empty()) {
      if (done) done(false);
      return;
    }
    Post([conversationId, from, accountId, isGroup, done]() {
      bool ok = false;
      try {
        if (IsActiveAccount(accountId) && !conversationId.empty()) {
          if (!isGroup && !from.empty()) {
            // No addContact: acceptConversationRequest already confirms the trust request and clones the peer's
            // conversation. addContact ran first would find no 1:1 conversation yet and start a second, empty one.
            libjami::subscribeBuddy(accountId, from, true);
          }
          libjami::acceptConversationRequest(accountId, conversationId);
          ok = true;  // the request is consumed; later logging must never resurrect its card
          {
            std::lock_guard<std::mutex> lock(g_mutex);
            g_pendingConnectGate.Remove(conversationId);
          }
          try {
            RefreshRoutingSnapshot(accountId);
          } catch (...) {
            Log("refresh routing after accept threw");
          }
          Log("acceptConnect(" + conversationId + ") from=" + from);
        }
      } catch (...) {
        Log("acceptConnect threw");
      }
      if (!ok && !from.empty()) {
        std::lock_guard<std::mutex> lock(g_mutex);
        RestorePendingConnectLocked(conversationId, accountId, from, isGroup);
      }
      try { if (done) done(ok); } catch (...) {}
    });
  } catch (...) {
    Log("acceptConnect post failed");
    if (!from.empty()) {
      try {
        std::lock_guard<std::mutex> lock(g_mutex);
        RestorePendingConnectLocked(conversationId, accountId, from, isGroup);
      } catch (...) {}
    }
    try { if (done) done(false); } catch (...) {}
  }
}

// Decline a gated request. Only a friend request has a corresponding trust request to discard.
void DeclineConnect(const std::string& conversationId, const std::string& fromJamiId,
                    std::function<void(bool)> done) {
  // Resolve `from` + erase the pending entry SYNCHRONOUSLY (under lock) before queueing the daemon ops — same
  // ghost-card race fix as AcceptConnect. Firewalled (entered from the _HAS_EXCEPTIONS=0 runner).
  std::string from, accountId;
  bool isGroup = false;
  try {
    (void) fromJamiId;  // the native pending record is authoritative
    {
      std::lock_guard<std::mutex> lock(g_mutex);
      accountId = g_accountId;
      auto it = g_pendingConnect.find(conversationId);
      auto owner = g_pendingConnectAccount.find(conversationId);
      const bool owned = owner != g_pendingConnectAccount.end() && owner->second == accountId;
      if (it != g_pendingConnect.end() && owned) {
        from = it->second;
        const auto group = g_pendingConnectIsGroup.find(conversationId);
        isGroup = group != g_pendingConnectIsGroup.end() && group->second;
        ErasePendingConnectLocked(conversationId);
      }
    }
    if (from.empty()) {
      if (done) done(false);
      return;
    }
    Post([conversationId, from, accountId, isGroup, done]() {
      bool ok = false;
      try {
        if (IsActiveAccount(accountId) && !conversationId.empty()) {
          libjami::declineConversationRequest(accountId, conversationId);
          ok = true;  // the request is consumed; secondary cleanup/logging cannot make it retryable
          {
            std::lock_guard<std::mutex> lock(g_mutex);
            g_pendingConnectGate.Remove(conversationId);
          }
          // The primary request is already declined. Do not restore a now-invalid card if secondary trust cleanup
          // throws; log that cleanup separately and report the completed user decision.
          if (!isGroup && !from.empty()) {
            try {
              libjami::discardTrustRequest(accountId, from);
            } catch (...) {
              Log("discardTrustRequest threw");
            }
          }
          Log("declineConnect(" + conversationId + ") from=" + from);
        }
      } catch (...) {
        Log("declineConnect threw");
      }
      if (!ok && !from.empty()) {
        std::lock_guard<std::mutex> lock(g_mutex);
        RestorePendingConnectLocked(conversationId, accountId, from, isGroup);
      }
      try { if (done) done(ok); } catch (...) {}
    });
  } catch (...) {
    Log("declineConnect post failed");
    if (!from.empty()) {
      try {
        std::lock_guard<std::mutex> lock(g_mutex);
        RestorePendingConnectLocked(conversationId, accountId, from, isGroup);
      } catch (...) {}
    }
    try { if (done) done(false); } catch (...) {}
  }
}

// Remove (ban=true -> BLOCK) a contact — the remove/block control. Block also bans future trust requests.
void RemoveContact(const std::string& uri, bool ban,
                   std::function<void(bool)> done) {
  try {
  Post([uri, ban, done]() {
    bool ok = false;
    try {
      const std::string acc = CurrentAccountId();
      const std::string peer = BareJamiId(uri);
      if (acc.empty() || peer.empty()) {
        if (done) done(false);
        return;
      }
      // Cleanup failure must not suppress the primary remove/block mutation.
      try {
        libjami::subscribeBuddy(acc, peer, false);
        std::lock_guard<std::mutex> lock(g_mutex);
        if (acc == g_accountId) g_subscribedPeers.erase(peer);
      } catch (...) {
        Log("unsubscribe before removeContact threw");
      }
      libjami::removeContact(acc, peer, ban);
      const bool control_retired = RetireControlTrust(acc, peer);
      RefreshRoutingSnapshot(acc);
      ok = !IsTrustedPeer(acc, peer) && control_retired;
      Log("removeContact(" + peer + ") ban=" + (ban ? "true" : "false"));
    } catch (...) {
      Log("removeContact threw");
    }
    try { if (done) done(ok); } catch (...) {}
  });
  } catch (...) {
    Log("removeContact post failed");
    try { if (done) done(false); } catch (...) {}
  }
}

// ---- identity backup / restore (M7.5 a) ----

// Export the identity to destinationPath as an optionally password-protected snapshot. The daemon reads the live archive with
// the device secret and atomically writes only the destination with the user passphrase.
std::optional<BackupOwner> CaptureBackupOwner(const std::optional<std::string>& expectedAccountId) {
  try {
    const auto owner = CaptureAccountCommandOwner(expectedAccountId);
    return owner ? std::optional<BackupOwner>(BackupOwner{owner->accountId, owner->revision}) : std::nullopt;
  } catch (...) { return std::nullopt; }
}

void ExportAccount(const BackupOwner& owner, const std::string& destinationPath, const std::string& passphrase,
                   const std::string& settingsDocument,
                   std::function<void(bool)> done) {
  try {
    Post([owner, destinationPath, passphrase, settingsDocument, done]() {
      bool ok = false;
      try {
        const std::string acc = OwnsAccountCommand({owner.accountId, owner.revision}) ? owner.accountId : std::string{};
        if (acc.empty() || passphrase.size() > kMaxArchivePassphraseBytes ||
            settingsDocument.size() > kMaxSettingsDocumentBytes ||
            destinationPath.empty()) {
          if (done) done(false);
          return;
        }
        const auto privatePath =
            sybl::archive::ArchiveSecretStore::DefaultPath();
        if (!privatePath ||
            !sybl::archive::IsSafeArchiveExchangePath(
                std::filesystem::u8path(destinationPath),
                privatePath->parent_path(),
                sybl::archive::ArchivePathUse::kExportDestination)) {
          Log("exportAccount: unsafe destination rejected");
          if (done) done(false);
          return;
        }
        std::string current;
        bool recoveryBlocked = false;
        bool protectionReady = false;
        {
          std::lock_guard<std::mutex> lock(g_mutex);
          current = g_archiveSecret;
          recoveryBlocked = g_archiveRecoveryBlocked;
          protectionReady = g_archiveProtectionReady;
        }
        if (recoveryBlocked || !protectionReady ||
            !sybl::archive::IsValidArchiveSecret(current)) {
          Log("exportAccount: archive protection is unavailable or blocked");
          SecureZeroMemory(current.data(), current.size());
          if (done) done(false);
          return;
        }
        try {
          const auto previousDetails = libjami::getAccountDetails(acc);
          auto exportDetails = previousDetails;
          const auto backupSettings = sybl::identity_restore::StampBackupSettings(settingsDocument, acc);
          if (!backupSettings) throw std::runtime_error("invalid backup settings document");
          exportDetails[libjami::Account::ConfProperties::UI_CUSTOMIZATION] = *backupSettings;
          ok = sybl::archive::ExportWithRestoredAccountDetails(
              [&] { libjami::setAccountDetails(acc, exportDetails); },
              [&] {
                return sybl::archive::ExportArchiveSnapshot(
                    acc, destinationPath, current, passphrase,
                    [](const std::string& account_id,
                       const std::string& destination_path,
                       const std::string& input_scheme,
                       const std::string& input_password,
                       const std::string& output_scheme,
                       const std::string& output_password) {
                      return libjami::exportToFileWithCredentials(
                          account_id, destination_path, input_scheme, input_password,
                          output_scheme, output_password);
                    });
              },
              [&] { libjami::setAccountDetails(acc, previousDetails); });
        } catch (...) {
          ok = false;
        }
        SecureZeroMemory(current.data(), current.size());
        Log(std::string("exportAccount -> ") + (ok ? "ok" : "fail"));
      } catch (...) {
        Log("exportAccount threw");
        ok = false;
      }
      try {
        if (done) done(ok);
      } catch (...) {
      }
    });
  } catch (...) {
    Log("exportAccount post failed");
    try { if (done) done(false); } catch (...) {}  // done() PostToPlatform-allocates → firewall it too (_HAS_EXCEPTIONS=0)
  }
}

// Restore an identity from an exported backup via addAccount{archivePath, archivePassword}. The daemon re-imports
// the archive's master keypair → IDENTICAL 40-hex. An empty jamiId in the reply means the passphrase/file was
// wrong (the import never authenticates); we remove the broken account so it doesn't become the front account.
static void ApplyConnectionProfile(std::map<std::string, std::string>& m,
                                   const std::string& profile,
                                   const std::string& dhtBootstrap,
                                   const std::string& turnServer,
                                   const std::string& turnRealm,
                                   const std::string& turnUser,
                                   const std::string& turnPassword);

namespace {

using RestorePhase = sybl::identity_restore::Phase;
using RestoreRecord = sybl::identity_restore::PendingRestore;
using RestoreStore = sybl::identity_restore::PendingRestoreStore;

bool DisablePreparedAccount(const std::string& id) {
  auto details = libjami::getAccountDetails(id);
  if (details.empty()) return false;
  details["Account.enable"] = "false";
  libjami::setAccountDetails(id, details);
  libjami::sendRegister(id, false);
  details = libjami::getAccountDetails(id);
  libjami::setAccountActive(id, false, false);
  const auto volatileDetails = libjami::getVolatileAccountDetails(id);
  const auto enabled = details.find("Account.enable");
  const auto active = volatileDetails.find("Account.active");
  return enabled != details.end() && active != volatileDetails.end() &&
      sybl::identity_restore::PreparedIdentityClosed(enabled->second, active->second);
}

void ApplyRestoreNetwork(const RestoreRecord& pending) {
  auto policy = libjami::getAccountDetails(pending.account_id);
  policy[libjami::Account::ConfProperties::DENYSECONDCALL] = "true";
  policy[libjami::Account::ConfProperties::DHT::PUBLIC_IN_CALLS] = "false";
  const auto& network = pending.network_details;
  const auto& requested = network.at("connectionProfile");
  const std::string profile = requested == "lan" || requested == "strict" || requested == "jami"
      ? requested : "jami";
  ApplyConnectionProfile(policy, profile, network.at("dhtBootstrap"), network.at("turnServer"),
                         network.at("turnRealm"), network.at("turnUser"), network.at("turnPassword"));
  policy["Account.enable"] = "false";
  libjami::setAccountDetails(pending.account_id, policy);
  if (!DisablePreparedAccount(pending.account_id))
    throw std::runtime_error("prepared restore did not remain disabled");
}

Account RestoreProjection(const RestoreRecord& pending, bool prepared) {
  Account result;
  result.accountId = pending.account_id;
  const auto details = libjami::getAccountDetails(pending.account_id);
  const auto username = details.find(libjami::Account::ConfProperties::USERNAME);
  if (username == details.end() || BareJamiId(username->second).empty()) return Account{};
  result.jamiId = BareJamiId(username->second);
  if (!pending.pairing_operation &&
      (pending.expected_jami_id.empty() || result.jamiId != pending.expected_jami_id))
    return Account{};
  const auto name = details.find(libjami::Account::ConfProperties::DISPLAYNAME);
  if (name != details.end()) result.displayName = sybl::profile_wire::DecodeDisplayName(name->second).value_or("");
  if (const auto own = ReadPeerProfile(g_jamiDataDir / pending.account_id / "profile.vcf"))
    result.avatarBase64 = own->avatar_base64;
  const auto enabled = details.find("Account.enable");
  if (enabled == details.end() || (enabled->second != "true" && enabled->second != "false"))
    return Account{};
  result.enabled = enabled->second == "true";
  if (prepared) {
    const auto state = libjami::getVolatileAccountDetails(pending.account_id);
    const auto active = state.find("Account.active");
    if (active == state.end() || !sybl::identity_restore::PreparedIdentityClosed(
        enabled->second, active->second)) return Account{};
  }
  result.restoreToken = pending.token;
  result.settingsDocument = pending.settings_document;
  result.backupSourceAccountId = sybl::identity_restore::BackupSourceAccount(pending.settings_document);
  result.settingsAlreadyNormalized = pending.settings_already_normalized;
  result.devicePairing = pending.pairing_operation.has_value() && pending.pairing_acknowledged;
  if (pending.settings_already_normalized) result.backupSourceAccountId = pending.account_id;
  if (!pending.normalized_document.empty()) {
    // This transaction already committed settings before a later activation
    // failure. Its normalized scopes now belong to the exact imported account.
    result.settingsDocument = pending.normalized_document;
    result.backupSourceAccountId = pending.account_id;
    result.settingsAlreadyNormalized = true;
  }
  result.status = prepared ? "prepared" : "ok";
  const auto vol = libjami::getVolatileAccountDetails(pending.account_id);
  const auto announced = vol.find(libjami::Account::VolatileProperties::DEVICE_ANNOUNCED);
  result.announced = result.enabled && announced != vol.end() && announced->second == "true";
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    const auto reg = g_regByAccount.find(pending.account_id);
    if (reg != g_regByAccount.end()) {
      const auto state = reg->second.find("state");
      if (state != reg->second.end()) result.registration = state->second;
    }
  }
  return result;
}

bool SameRestoreOwner(const AccountCommandOwner& owner) {
  return g_pendingRestoreOwner && g_pendingRestoreOwner->accountId == owner.accountId &&
      g_pendingRestoreOwner->revision == owner.revision && OwnsAccountCommand(owner);
}

void CaptureImportedSettings(RestoreRecord& pending) {
  const auto details = libjami::getAccountDetails(pending.account_id);
  const auto settings = details.find(libjami::Account::ConfProperties::UI_CUSTOMIZATION);
  if (settings != details.end() && settings->second.size() <= kMaxSettingsDocumentBytes &&
      sybl::timeline::MeasureUtf8(settings->second, kMaxSettingsDocumentBytes))
    pending.settings_document = settings->second;
}

bool PairingForeground() {
  const auto window = GetForegroundWindow();
  DWORD process = 0;
  if (!window || !GetWindowThreadProcessId(window, &process)) return false;
  return process == GetCurrentProcessId() && IsWindowVisible(window) && !IsIconic(window);
}

bool PairingVisible() {
  if (!g_foreground.load()) return false;
  bool visible = false;
  EnumWindows([](HWND window, LPARAM result) -> BOOL {
    DWORD process = 0;
    GetWindowThreadProcessId(window, &process);
    if (process == GetCurrentProcessId() && IsWindowVisible(window) && !IsIconic(window)) {
      *reinterpret_cast<bool*>(result) = true;
      return FALSE;
    }
    return TRUE;
  }, reinterpret_cast<LPARAM>(&visible));
  return visible;
}

bool SavePairingRecord(const RestoreRecord& record) {
  const auto path = RestoreStore::DefaultPath();
  if (!path || !record.pairing_operation) return false;
  RestoreStore store(*path);
  if (!store.Save(record)) return false;
  const auto loaded = store.Load();
  if (loaded.status != sybl::identity_restore::LoadStatus::kLoaded || !loaded.value ||
      sybl::identity_restore::EncodePending(*loaded.value) != sybl::identity_restore::EncodePending(record)) return false;
  g_pendingRestore = record;
  return true;
}

DevicePairingState PairingRecovery(const RestoreRecord& record, const AccountCommandOwner& owner) {
  DevicePairingState result;
  result.flowToken = record.token; result.accountId = record.account_id;
  result.ownerAccountId = owner.accountId;
  result.role = "destination"; result.status = "unconfirmed";
  result.operation = record.pairing_operation.value_or(0); result.recovery = true;
  return result;
}

DevicePairingReply PairingProjection(const std::shared_ptr<PairingEntry>& entry) {
  const auto value = entry->flow->snapshot();
  DevicePairingReply result;
  result.ownerAccountId = entry->owner.accountId; result.ownerRevision = entry->owner.revision;
  result.privacyEpoch = entry->epoch;
  auto& out = result.state;
  out.flowToken = value.token; out.accountId = value.account; out.ownerAccountId = entry->owner.accountId;
  out.role = value.destination ? "destination" : "source"; out.status = value.status;
  out.operation = value.operation; out.terminal = value.terminal; out.invalidCode = value.invalid_code;
  out.uri = value.uri; out.code = value.code; out.peerId = value.peer;
  out.peerDeviceId = value.peer_device; out.deviceId = value.device; out.error = value.error;
  if (value.destination && g_pendingRestore && g_pendingRestore->token == value.token) {
    out.recovery = entry->flow->retired() || (value.terminal && !g_pendingRestore->pairing_acknowledged);
    if (value.status == "ready" && !entry->flow->retired() && g_pendingRestore->pairing_acknowledged)
      result.preparedIdentity = RestoreProjection(*g_pendingRestore, true);
  }
  return result;
}

void CancelPairingEntry(const std::shared_ptr<PairingEntry>& entry) {
  const auto value = entry->flow->snapshot();
  if (value.terminal) {
    if (!value.destination && entry->flow->retired()) {
      std::lock_guard<std::mutex> lock(g_mutex);
      if (g_pairing == entry) g_pairing.reset();
    }
    return;
  }
  if (!value.operation || entry->cancelIssued) return;
  entry->cancelIssued = true;
  // Cancellation is a request, not a terminal outcome. The exact retained
  // native lease closes only on DONE or explicit removal of the reserved ID.
  try { libjami::cancelAddDevice(value.account, value.operation); } catch (...) {}
}

bool PairingEntryCurrent(const std::shared_ptr<PairingEntry>& entry, bool userAction = true) {
  return OwnsAccountCommand(entry->owner) && !entry->flow->retired() &&
      g_pairingVisits.Allows(entry->flow->snapshot().token, entry->epoch) &&
      (userAction ? PairingForeground() : PairingVisible());
}

std::shared_ptr<PairingEntry> BeginDevicePairing(bool destination, const std::string& token,
    uint64_t epoch, const std::string& uri, const std::map<std::string, std::string>& network,
    bool appearOffline, const AccountCommandOwner& owner) {
  if ((destination && !owner.accountId.empty()) ||
      !OwnsAccountCommand(owner) || !PairingForeground() || !g_pairingVisits.Allows(token, epoch) ||
      g_pendingRestoreBlocked || network.size() != 6) return {};
  for (const auto* key : {"connectionProfile", "dhtBootstrap", "turnServer", "turnRealm", "turnUser", "turnPassword"}) {
    const auto value = network.find(key);
    if (value == network.end() || value->second.size() > 4096) return {};
  }
  std::string secret;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (!g_archiveProtectionReady || g_archiveRecoveryBlocked || !MediaSlotIdleLocked()) return {};
    if (g_pairing) {
      const auto prior = g_pairing->flow->snapshot();
      if (prior.token == token && prior.destination == destination &&
          g_pairing->owner.accountId == owner.accountId && g_pairing->owner.revision == owner.revision) return g_pairing;
      if (!prior.terminal) return {};
      g_pairing.reset();
    }
    secret = g_archiveSecret;
  }
  if (g_pendingRestore) return {};
  if (!destination) {
    if (owner.accountId.empty() || !sybl::device_pairing::ValidOffer(uri) ||
        libjami::getAccountDetails(owner.accountId)["Account.enable"] != "true") return {};
    auto entry = std::make_shared<PairingEntry>();
    entry->owner = owner; entry->epoch = epoch;
    entry->flow = std::make_shared<sybl::device_pairing::Flow>(token, owner.accountId, false);
    { std::lock_guard<std::mutex> lock(g_mutex); g_pairing = entry; }
    try {
      const auto operation = libjami::addDevice(owner.accountId, uri);
      if (operation <= 0 || !entry->flow->BindOperation(static_cast<uint32_t>(operation))) entry->flow->Unconfirmed();
    } catch (...) { entry->flow->Unconfirmed(); }
    entry->admitting = false;
    return entry;
  }
  const auto reservedToken = sybl::identity_restore::RandomToken();
  if (!reservedToken) return {};
  const auto account = reservedToken->substr(0, 32);
  if (AccountExists(account)) return {};
  const auto path = RestoreStore::DefaultPath();
  if (!path || RestoreStore(*path).Load().status != sybl::identity_restore::LoadStatus::kAbsent) return {};
  RestoreRecord record;
  record.token = token; record.account_id = account; record.previous_account_id = owner.accountId;
  record.phase = RestorePhase::kImporting; record.appear_offline = appearOffline;
  record.network_details = network; record.pairing_operation = 0;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (!MediaSlotIdleLocked()) return {};
    g_identityActivationPending = true;
  }
  g_pendingRestore = record; g_pendingRestoreOwner = owner;
  if (!SavePairingRecord(record)) { g_pendingRestoreBlocked = true; return {}; }
  auto entry = std::make_shared<PairingEntry>();
  entry->owner = owner; entry->epoch = epoch;
  entry->flow = std::make_shared<sybl::device_pairing::Flow>(token, account, true);
  { std::lock_guard<std::mutex> lock(g_mutex); g_pairing = entry; }
  try {
    auto policy = libjami::getAccountTemplate("RING");
    policy["Account.type"] = "RING"; policy["Account.enable"] = "false";
    policy[libjami::Account::ConfProperties::DENYSECONDCALL] = "true";
    policy["DHT.PublicInCalls"] = "false"; policy["Account.uiCustomization"] = "";
    const auto& profile = network.at("connectionProfile");
    ApplyConnectionProfile(policy, profile == "lan" || profile == "strict" ? profile : "jami",
        network.at("dhtBootstrap"), network.at("turnServer"), network.at("turnRealm"),
        network.at("turnUser"), network.at("turnPassword"));
    policy["Account.archiveURL"] = "jami-auth"; policy["Account.archivePassword"] = secret;
    policy["Account.deviceName"] = "Doorlight Windows";
    // The sealed exact-ID marker precedes all native account/identity creation.
    if (libjami::addAccount(policy, account) != account) entry->flow->Unconfirmed();
  } catch (...) { entry->flow->Unconfirmed(); }
  entry->admitting = false;
  return entry;
}

bool PrepareDevicePairingPrivacy(const std::shared_ptr<PairingEntry>& entry, const std::string& document) {
  const auto value = entry->flow->snapshot();
  if (!g_pendingRestore || !value.destination || value.status != "prepared" || !PairingEntryCurrent(entry) ||
      !SameRestoreOwner(entry->owner)) return false;
  auto record = *g_pendingRestore;
  if (record.token != value.token || record.account_id != value.account ||
      record.pairing_operation != value.operation || record.pairing_acknowledged ||
      !DisablePreparedAccount(value.account)) return false;
  const auto path = sybl::identity_restore::CanonicalSettingsLease::DefaultPath();
  auto lease = path ? sybl::identity_restore::CanonicalSettingsLease::Acquire(*path, document) : nullptr;
  if (!lease || lease->appear_offline() != record.appear_offline) return false;
  auto details = libjami::getAccountDetails(value.account);
  const auto volatileDetails = libjami::getVolatileAccountDetails(value.account);
  const auto device = volatileDetails.find(libjami::Account::ConfProperties::DEVICE_ID);
  std::string secret;
  { std::lock_guard<std::mutex> lock(g_mutex); secret = g_archiveSecret; }
  if (BareJamiId(details["Account.username"]) != value.peer || device == volatileDetails.end() ||
      device->second != value.device || details["Account.archiveHasPassword"] != "true" ||
      !libjami::isPasswordValid(value.account, secret)) return false;
  details["Account.uiCustomization"] = ""; details["Account.enable"] = "false";
  libjami::setAccountDetails(value.account, details);
  ApplyRestoreNetwork(record);
  if (!PairingEntryCurrent(entry)) return false;
  record.settings_document = record.normalized_document = document;
  record.settings_already_normalized = true;
  if (!SavePairingRecord(record) || !entry->flow->PreparedPrivacy()) return false;
  // This sends a proof; it does not select, activate or enable the candidate.
  return libjami::completeDeviceLinkPreparation(value.account, value.operation);
}

DevicePairingReply DiscardDevicePairing(const RestoreRecord& record,
    const std::shared_ptr<PairingEntry>& entry, const AccountCommandOwner& owner) {
  DevicePairingReply result;
  result.ownerAccountId = owner.accountId; result.ownerRevision = owner.revision;
  if (!record.pairing_operation || record.account_id == owner.accountId || !SameRestoreOwner(owner)) return result;
  const auto path = RestoreStore::DefaultPath();
  if (!path) return result;
  RestoreStore store(*path); const auto sealed = store.Load();
  if (!sealed.value || sealed.value->token != record.token || sealed.value->account_id != record.account_id) return result;
  if (entry) { entry->flow->Retire(); CancelPairingEntry(entry); }
  if (AccountExists(record.account_id)) {
    if (!DisablePreparedAccount(record.account_id)) return result;
    libjami::removeAccount(record.account_id);
  }
  if (AccountExists(record.account_id) || !store.Clear(record.token) ||
      store.Load().status != sybl::identity_restore::LoadStatus::kAbsent) {
    result.state.status = "unconfirmed"; return result;
  }
  g_pendingRestore.reset(); g_pendingRestoreOwner.reset(); g_pendingRestoreBlocked = false;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_pairing == entry) g_pairing.reset();
    g_identityActivationPending = false;
  }
  result.state.flowToken = record.token; result.state.accountId = record.account_id;
  result.state.ownerAccountId = owner.accountId;
  result.state.status = "discarded"; result.peerOutcomeUnconfirmed = true;
  return result;
}

void OnDevicePairingSignal(const std::string& account, std::optional<uint32_t> sourceOperation,
    int state, const std::map<std::string, std::string>& details, bool destination) {
  std::shared_ptr<PairingEntry> entry;
  { std::lock_guard<std::mutex> lock(g_mutex); entry = g_pairing; }
  if (!entry || state < 1 || state > 5 || details.size() > 12) return;
  const auto snapshot = entry->flow->snapshot();
  if (snapshot.account != account || snapshot.destination != destination) return;
  std::map<std::string, std::string> copied;
  for (const auto* key : {"token", "operation", "auth_scheme", "auth_error", "prepared", "error", "peer_id", "peer_device", "device_id"}) {
    const auto value = details.find(key);
    if (value == details.end()) continue;
    if (value->second.size() > 128) return;
    copied.emplace(*value);
  }
  uint32_t operation = sourceOperation.value_or(0);
  if (!sourceOperation) {
    const auto key = copied.find(state == 1 ? "operation" : "token");
    if (key == copied.end() || !sybl::device_pairing::Digits(key->second, 6) || key->second[0] == '0') return;
    operation = static_cast<uint32_t>(std::stoul(key->second));
  }
  const bool admitting = entry->admitting.load();
  Post([entry, account, operation, state, destination, admitting, copied = std::move(copied)] {
    { std::lock_guard<std::mutex> lock(g_mutex); if (g_pairing != entry) return; }
    try {
      auto value = entry->flow->snapshot();
      if (!value.operation) {
        if ((!destination && !admitting) || !entry->flow->BindOperation(operation)) return;
        if (destination) {
          if (!g_pendingRestore || g_pendingRestore->token != value.token || g_pendingRestore->account_id != account) return;
          auto record = *g_pendingRestore; record.pairing_operation = operation;
          if (!SavePairingRecord(record)) {
            g_pendingRestoreBlocked = true; entry->flow->Retire(); CancelPairingEntry(entry); return;
          }
        }
      }
      if (!PairingEntryCurrent(entry, false)) entry->flow->Retire();
      if (!entry->flow->Accept(operation, state, copied)) {
        if (entry->flow->retired()) CancelPairingEntry(entry);
        return;
      }
      if (state == 5 && destination && entry->flow->native_succeeded() && entry->flow->privacy_committed() && !entry->flow->retired()) {
        if (g_pendingRestore && g_pendingRestore->token == value.token && g_pendingRestore->account_id == account &&
            g_pendingRestore->pairing_operation == operation && !g_pendingRestore->normalized_document.empty()) {
          auto record = *g_pendingRestore; record.phase = RestorePhase::kPrepared; record.pairing_acknowledged = true;
          if (!SavePairingRecord(record) || !entry->flow->AcknowledgedDurably()) {
            g_pendingRestoreBlocked = true; entry->flow->Unconfirmed();
          }
        } else { g_pendingRestoreBlocked = true; entry->flow->Unconfirmed(); }
      }
      if (entry->flow->retired()) CancelPairingEntry(entry);
    } catch (...) {
      entry->flow->Unconfirmed();
      if (destination) g_pendingRestoreBlocked = true;
    }
  });
}

bool RestoreArchiveJournalOwned(const std::string& account) {
  ArchiveRecoveryRecord recovery;
  bool present = false;
  const bool loaded = LoadArchiveRecovery(recovery, present);
  const bool owned = loaded && (!present || recovery.accountId == account);
  if (!recovery.currentSecret.empty()) SecureZeroMemory(recovery.currentSecret.data(), recovery.currentSecret.size());
  if (!recovery.transientPassphrase.empty()) SecureZeroMemory(recovery.transientPassphrase.data(), recovery.transientPassphrase.size());
  return owned;
}

bool FinishIdentityRestoreRollback(const std::optional<AccountCommandOwner>& owner) {
  if (!g_pendingRestore) return false;
  const auto path = RestoreStore::DefaultPath();
  if (!path) return false;
  RestoreStore store(*path);
  const auto loaded = store.Load();
  if (!loaded.value || loaded.value->token != g_pendingRestore->token ||
      loaded.value->account_id != g_pendingRestore->account_id ||
      (!owner && loaded.value->phase != RestorePhase::kRollingBack)) return false;
  auto pending = *loaded.value;
  AccountCommandOwner captured;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    captured = {g_accountId, g_accountRevision};
  }
  const auto owns = [&] {
    if (!sybl::identity_restore::CanDiscard(pending, captured.accountId, libjami::getAccountList())) return false;
    if (owner && (!SameRestoreOwner(*owner) || owner->accountId != captured.accountId ||
        owner->revision != captured.revision)) return false;
    std::lock_guard<std::mutex> lock(g_mutex);
    return g_running && !g_resetDoorlightPending && captured.accountId == g_accountId &&
        captured.revision == g_accountRevision && MediaSlotIdleLocked(true) &&
        g_accountRevision != std::numeric_limits<uint64_t>::max();
  };
  if (!RestoreArchiveJournalOwned(pending.account_id)) return false;
  const auto absent = [&] {
    return !AccountExists(pending.account_id) && !g_jamiDataDir.empty() &&
        std::filesystem::symlink_status(g_jamiDataDir / pending.account_id).type() == std::filesystem::file_type::not_found &&
        std::filesystem::symlink_status(g_jamiDataDir.parent_path() / L"cache" / pending.account_id).type() == std::filesystem::file_type::not_found;
  };
  const bool removed = sybl::identity_restore::Rollback(pending, captured.accountId, libjami::getAccountList(), {
      owns,
      [&](const RestoreRecord& rollback) {
        if (!store.Save(rollback)) return false;
        g_pendingRestore = rollback;
        std::lock_guard<std::mutex> lock(g_mutex);
        g_identityActivationPending = true;
        return true;
      },
      [&] {
        if (!RecordWindowsSybLRevokeAndWait(3000) || !owns()) return false;
        if (AccountExists(pending.account_id)) {
          if (!DisablePreparedAccount(pending.account_id) || !owns()) return false;
          libjami::removeAccount(pending.account_id);
        }
        return absent();
      },
      [&] {
        if (!RestoreArchiveJournalOwned(pending.account_id) || !absent() || !ClearArchiveRecovery()) return false;
        return absent() && store.Clear(pending.token) && store.Load().status == sybl::identity_restore::LoadStatus::kAbsent;
      }});
  if (!removed) return false;
  g_pendingRestore.reset();
  g_pendingRestoreOwner.reset();
  g_pendingRestoreBlocked = false;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_identityActivationPending = false;
    // Boot/retry must reconcile the remaining identities before password-sensitive work.
    g_archiveProtectionReady = false;
    g_archiveRecoveryBlocked = false;
  }
  return true;
}

bool ReprepareDisabledRestore(RestoreRecord& pending, RestoreStore& store) {
  if (pending.phase != RestorePhase::kPrivacyCommitted) return true;
  auto prepared = pending;
  prepared.settings_document = prepared.normalized_document;
  if (!prepared.pairing_operation) prepared.normalized_document.clear();
  prepared.settings_already_normalized = true;
  prepared.phase = RestorePhase::kPrepared;
  if (!store.Save(prepared, true)) return false;
  pending = std::move(prepared);
  return true;
}

}  // namespace

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
                    std::function<void(const Account&)> done) {
  try {
    const auto owner = CaptureRestoreOwner(expectedAccountId);
    if (!owner) { if (done) done(Account{}); return; }
    Post([filePath, passphrase, connectionProfile, dhtBootstrap, turnServer,
          turnRealm, turnUser, turnPassword, appearOffline, expectedJamiId, owner = *owner, done]() {
      Account result;
      std::string secret;
      try {
        if (!OwnsAccountCommand(owner) || filePath.empty() || expectedJamiId.empty() ||
            BareJamiId(expectedJamiId) != expectedJamiId || passphrase.size() > kMaxArchivePassphraseBytes)
          throw std::runtime_error("restore account owner or input changed");
        {
          std::lock_guard<std::mutex> lock(g_mutex);
          if (!MediaSlotIdleLocked() || g_archiveRecoveryBlocked || !g_archiveProtectionReady)
            throw std::runtime_error("restore is unavailable while media or archive recovery is active");
          secret = g_archiveSecret;
        }
        const auto privatePath = sybl::archive::ArchiveSecretStore::DefaultPath();
        const auto pendingPath = RestoreStore::DefaultPath();
        if (!privatePath || !pendingPath || !sybl::archive::IsValidArchiveSecret(secret) ||
            !sybl::archive::IsSafeArchiveExchangePath(std::filesystem::u8path(filePath),
                privatePath->parent_path(), sybl::archive::ArchivePathUse::kImportExisting))
          throw std::runtime_error("restore source or protected storage unavailable");
        RestoreStore store(*pendingPath);
        const auto previous = store.Load();
        if (previous.status != sybl::identity_restore::LoadStatus::kAbsent || g_pendingRestoreBlocked || g_pendingRestore)
          throw std::runtime_error("a previous restore requires completion");
        const auto token = sybl::identity_restore::RandomToken();
        const auto accountToken = sybl::identity_restore::RandomToken();
        if (!token || !accountToken) throw std::runtime_error("restore random owner unavailable");
        RestoreRecord pending;
        pending.token = *token;
        pending.account_id = accountToken->substr(0, 16);
        pending.previous_account_id = owner.accountId;
        pending.expected_jami_id = expectedJamiId;
        // Import's Account.enable=false gate loses the archive's prior choice.
        // Never infer consent to register from a fresh installation's default.
        pending.appear_offline = true;
        pending.network_details = {{"connectionProfile", connectionProfile}, {"dhtBootstrap", dhtBootstrap},
            {"turnServer", turnServer}, {"turnRealm", turnRealm}, {"turnUser", turnUser}, {"turnPassword", turnPassword}};
        {
          std::lock_guard<std::mutex> lock(g_mutex);
          if (!MediaSlotIdleLocked()) throw std::runtime_error("media arrived before restore reservation");
          g_identityActivationPending = true;
        }
        if (!RecordWindowsSybLRevokeAndWait(3000))
          throw std::runtime_error("restore recorder release unconfirmed");
        if (AccountExists(pending.account_id) || !store.Save(pending))
          throw std::runtime_error("restore pending owner could not be persisted");
        g_pendingRestore = pending;
        g_pendingRestoreOwner = owner;
        // Both exact-ID journals are durable before addAccount can create an
        // account. The existing C++ API accepts this reserved local ID.
        if (!RestoreArchiveJournalOwned(pending.account_id) ||
            !SaveArchiveRecovery({pending.account_id, secret, passphrase}))
          throw std::runtime_error("restore rekey journal could not be persisted");
        std::map<std::string, std::string> details{
            {libjami::Account::ConfProperties::TYPE, libjami::Account::ProtocolNames::RING},
            {libjami::Account::ConfProperties::ARCHIVE_PATH, filePath},
            {libjami::Account::ConfProperties::ARCHIVE_PASSWORD, passphrase},
            {"Account.enable", "false"},
            {libjami::Account::ConfProperties::PROXY_ENABLED, "true"},
            {libjami::Account::ConfProperties::DENYSECONDCALL, "true"},
            {libjami::Account::ConfProperties::DHT::PUBLIC_IN_CALLS, "false"},
            {libjami::Account::ConfProperties::DHT_PEER_DISCOVERY, "false"},
            {libjami::Account::ConfProperties::ACCOUNT_PEER_DISCOVERY, "false"},
            {libjami::Account::ConfProperties::ACCOUNT_PUBLISH, "false"}};
        if (libjami::addAccount(details, pending.account_id) != pending.account_id)
          throw std::runtime_error("restore returned another local account owner");
        if (BareJamiId(AwaitRestoredUsername(pending.account_id)) != pending.expected_jami_id)
          throw std::runtime_error("restored identity differs from the expected Friend ID");
        try { libjami::changeAccountPassword(pending.account_id, passphrase, secret); } catch (...) {}
        if (!RecoverInterruptedArchiveRekey(libjami::getAccountList()))
          throw std::runtime_error("restore archive protection is incomplete");
        ApplyRestoreNetwork(pending);
        CaptureImportedSettings(pending);
        pending.phase = RestorePhase::kPrepared;
        if (!store.Save(pending)) throw std::runtime_error("prepared restore could not be persisted");
        g_pendingRestore = pending;
        if (!SameRestoreOwner(owner)) throw std::runtime_error("restore owner changed before reply");
        result = RestoreProjection(pending, true);
        if (result.status == "prepared") result.recoveryOwnerAccountId = owner.accountId;
        result.canDiscard = result.status == "prepared" && SameRestoreOwner(owner) &&
            sybl::identity_restore::CanDiscard(pending, owner.accountId, libjami::getAccountList()) &&
            RestoreArchiveJournalOwned(pending.account_id);
      } catch (...) {
        Log("restore prepare incomplete; the pending identity remains disabled");
        result.status = g_pendingRestore ? "recoveryRequired" : "error";
        // Keep a slow or failed import for a bounded recovery attempt. Absence
        // is the only evidence that permits clearing its exact-ID transaction.
        if (g_pendingRestore) {
          try {
            if (!AccountExists(g_pendingRestore->account_id)) {
              if (FinishIdentityRestoreRollback(owner)) {
                result.status = "error";
              }
            } else {
              DisablePreparedAccount(g_pendingRestore->account_id);
            }
          } catch (...) {}
        }
      }
      if (!secret.empty()) SecureZeroMemory(secret.data(), secret.size());
      {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_identityActivationPending = g_pendingRestoreBlocked || g_pendingRestore.has_value();
      }
      try { if (done) done(result); } catch (...) {}
    });
  } catch (...) { try { if (done) done(Account{}); } catch (...) {} }
}

void RetireDevicePairing() {
  std::lock_guard<std::mutex> lock(g_mutex);
  RetirePairingLocked();
}

bool DevicePairingReplyCurrent(const DevicePairingReply& reply) {
  if (!OwnsAccountCommand({reply.ownerAccountId, reply.ownerRevision})) return false;
  if (reply.state.status == "discarded" || reply.state.recovery) return true;
  if (!PairingVisible() || !g_pairingVisits.Allows(reply.state.flowToken, reply.privacyEpoch)) return false;
  std::lock_guard<std::mutex> lock(g_mutex);
  return g_pairing && g_pairing->flow->snapshot().token == reply.state.flowToken && !g_pairing->flow->retired();
}

void DevicePairingCommand(const std::string& action, const std::string& token,
    const std::string& targetAccount, const std::string& uri, const std::string& code,
    const std::string& document, const std::map<std::string, std::string>& network,
    bool appearOffline, const std::string& expectedAccountId,
    std::function<void(const DevicePairingReply&)> done) {
  try {
    const auto owner = CaptureRestoreOwner(expectedAccountId);
    if (!owner) { if (done) done({}); return; }
    const auto epoch = g_pairingVisits.Capture();
    if (action == "retire") {
      g_pairingVisits.Retire(token);
      std::lock_guard<std::mutex> lock(g_mutex);
      if (g_pairing) {
        const auto value = g_pairing->flow->snapshot();
        if (value.token == token && (targetAccount.empty() || value.account == targetAccount)) g_pairing->flow->Retire();
      }
    }
    Post([action, token, targetAccount, uri, code, document, network, appearOffline, owner = *owner, epoch, done] {
      DevicePairingReply result;
      result.ownerAccountId = owner.accountId; result.ownerRevision = owner.revision;
      std::shared_ptr<PairingEntry> entry;
      try {
        if (!OwnsAccountCommand(owner)) { if (done) done(result); return; }
        if (action == "begin" || action == "connect") {
          entry = BeginDevicePairing(action == "begin", token, epoch, uri, network, appearOffline, owner);
          if (entry) result = PairingProjection(entry);
        } else {
          {
            std::lock_guard<std::mutex> lock(g_mutex);
            if (g_pairing) {
              const auto value = g_pairing->flow->snapshot();
              if (value.token == token && (value.account == targetAccount ||
                  (targetAccount.empty() && (action == "read" || action == "retire"))) &&
                  g_pairing->owner.accountId == owner.accountId && g_pairing->owner.revision == owner.revision) entry = g_pairing;
            }
          }
          const auto record = g_pendingRestore && g_pendingRestore->pairing_operation &&
              g_pendingRestore->token == token && g_pendingRestore->account_id == targetAccount ? g_pendingRestore : std::nullopt;
          if (action == "discard" && record) result = DiscardDevicePairing(*record, entry, owner);
          else if (action == "read" && !entry && record) result.state = PairingRecovery(*record, owner);
          else if (entry) {
            const auto value = entry->flow->snapshot();
            if (action == "retire") { entry->flow->Retire(); CancelPairingEntry(entry); }
            else if (action != "read") {
              if (!PairingEntryCurrent(entry) || g_pendingRestoreBlocked) { if (done) done(result); return; }
              if (action == "approve" && !value.destination && value.status == "consent" &&
                  libjami::getAccountDetails(value.account)["Account.enable"] == "true") {
                std::string secret;
                { std::lock_guard<std::mutex> lock(g_mutex); secret = g_archiveSecret; }
                const auto issued = libjami::confirmAddDeviceWithCode(value.account, value.operation, secret);
                if (!entry->flow->IssuedCode(issued)) entry->flow->Unconfirmed();
              } else if (action == "code" && value.destination && sybl::device_pairing::ValidCode(code) && entry->flow->SubmittingCode()) {
                if (!libjami::provideAccountAuthentication(value.account, code, "doorlight-code-v1")) entry->flow->Unconfirmed();
              } else if (action == "prepare" && value.destination) {
                if (!PrepareDevicePairingPrivacy(entry, document)) entry->flow->Unconfirmed();
              } else { if (done) done(result); return; }
            }
            result = PairingProjection(entry);
          }
        }
      } catch (...) {
        if (entry) { entry->flow->Unconfirmed(); result = PairingProjection(entry); }
        else result.state.status = "unconfirmed";
      }
      try { if (done) done(result); } catch (...) {}
    });
  } catch (...) { try { if (done) done({}); } catch (...) {} }
}

void GetPendingIdentityRestore(std::function<void(const Account&)> done) {
  try {
    Post([done]() {
      // Boot is queued on this worker. Capture the resume owner after it has
      // finished, so the first Flutter request does not race daemon readiness.
      const auto capturedOwner = CaptureRestoreOwner();
      if (!capturedOwner) {
        Account unavailable;
        {
          std::lock_guard<std::mutex> lock(g_mutex);
          unavailable.status = !g_running || !g_daemonReady.load() ? "engineUnavailable" : "recoveryRequired";
          if (g_running && g_daemonStarted.load() && g_archiveRecoveryBlocked)
            unavailable.status = "archiveProtectionUnavailable";
        }
        unavailable.recoveryReason = "ownershipUnclear";
        if (unavailable.status == "engineUnavailable" &&
            ((g_daemonInitAttempted.load() && !g_daemonInitialized.load()) ||
             (g_daemonStartAttempted.load() && !g_daemonStarted.load())))
          unavailable.recoveryReason = "restartRequired";
        if (done) done(unavailable);
        return;
      }
      const auto owner = *capturedOwner;
      Account result;
      result.status = "recoveryRequired";
      result.recoveryReason = "ownershipUnclear";
      bool inspectedRestore = false;
      try {
        if (!OwnsAccountCommand(owner)) throw std::runtime_error("pending restore owner changed");
        result.recoveryReason = "journalUnreadable";
        const auto path = RestoreStore::DefaultPath();
        if (!path) throw std::runtime_error("pending restore store unavailable");
        RestoreStore store(*path);
        const auto loaded = store.Load();
        g_pendingRestoreBlocked = loaded.status == sybl::identity_restore::LoadStatus::kError;
        if (g_pendingRestoreBlocked) throw std::runtime_error("pending restore record unreadable");
        if (loaded.status == sybl::identity_restore::LoadStatus::kAbsent) {
          g_pendingRestore.reset();
          g_pendingRestoreOwner.reset();
          result.status = "none";
        } else {
          g_pendingRestore = *loaded.value;
          g_pendingRestoreOwner = owner;
          inspectedRestore = true;
          auto pending = *g_pendingRestore;
          result.recoveryReason = "preparationFailed";
          if (pending.phase == RestorePhase::kRollingBack) {
            result.recoveryReason = "rollbackPending";
            if (!FinishIdentityRestoreRollback(owner))
              throw std::runtime_error("pending restore rollback is incomplete");
            result.status = "none";
          } else if (pending.pairing_operation && !pending.pairing_acknowledged) {
            if (AccountExists(pending.account_id) && !DisablePreparedAccount(pending.account_id))
              throw std::runtime_error("pending device link is not disabled");
            g_pendingRestoreOwner = owner;
            result.status = "pairing";
            result.pendingPairing = PairingRecovery(pending, owner);
          } else if (!AccountExists(pending.account_id)) {
            if (pending.phase != RestorePhase::kImporting ||
                !sybl::identity_restore::CanDiscard(pending, owner.accountId, libjami::getAccountList()) ||
                !FinishIdentityRestoreRollback(owner))
              throw std::runtime_error("pending restore identity missing");
            result.status = "none";
          } else {
            {
              std::lock_guard<std::mutex> lock(g_mutex);
              if (!MediaSlotIdleLocked(true)) throw std::runtime_error("pending restore cannot interrupt media");
              g_identityActivationPending = true;
            }
            if (!DisablePreparedAccount(pending.account_id))
              throw std::runtime_error("pending restore is not disabled");
            result.recoveryReason = "importIncomplete";
            const auto restoredId = BareJamiId(AwaitRestoredUsername(pending.account_id));
            if (restoredId.empty() ||
                (!pending.pairing_operation &&
                 (pending.expected_jami_id.empty() || restoredId != pending.expected_jami_id)) ||
                !InitializeArchiveProtection(libjami::getAccountList()))
              throw std::runtime_error("pending restore authentication or rekey is incomplete");
            result.recoveryReason = "preparationFailed";
            ApplyRestoreNetwork(pending);
            if (!ReprepareDisabledRestore(pending, store))
              throw std::runtime_error("disabled restore retry could not be persisted");
            if (pending.phase == RestorePhase::kImporting) {
              CaptureImportedSettings(pending);
              pending.phase = RestorePhase::kPrepared;
              if (!store.Save(pending)) throw std::runtime_error("pending restore preparation write failed");
            }
            g_pendingRestore = pending;
            // getPending is the explicit resume boundary after a fresh boot;
            // all later finalize calls retain this exact native lifetime.
            g_pendingRestoreOwner = owner;
            result = RestoreProjection(pending, true);
            if (result.status != "prepared") {
              result.status = "recoveryRequired";
              result.recoveryReason = "preparationFailed";
            }
            if (pending.pairing_operation) result.pendingPairing = PairingRecovery(pending, owner);
          }
        }
      } catch (...) { Log("pending restore needs recovery"); }
      if ((result.status == "recoveryRequired" || result.status == "prepared") && inspectedRestore && g_pendingRestore) {
        result.recoveryOwnerAccountId = owner.accountId;
        if (g_pendingRestore->phase == RestorePhase::kRollingBack) result.recoveryReason = "rollbackPending";
        result.accountId = g_pendingRestore->account_id;
        result.restoreToken = g_pendingRestore->token;
        try {
          result.canDiscard = !g_pendingRestoreBlocked && SameRestoreOwner(owner) &&
              sybl::identity_restore::CanDiscard(*g_pendingRestore, owner.accountId, libjami::getAccountList()) &&
              RestoreArchiveJournalOwned(g_pendingRestore->account_id);
        } catch (...) { result.canDiscard = false; }
      }
      {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_identityActivationPending = g_pendingRestoreBlocked || g_pendingRestore.has_value();
      }
      try { if (done) done(result); } catch (...) {}
    });
  } catch (...) { try { if (done) done(Account{}); } catch (...) {} }
}

void DiscardIdentityRestore(const std::string& accountId, const std::string& restoreToken,
                            const std::string& expectedAccountId, std::function<void(bool)> done) {
  try {
    const auto owner = CaptureRestoreOwner(expectedAccountId);
    if (!owner) { if (done) done(false); return; }
    Post([accountId, restoreToken, owner = *owner, done] {
      bool removed = false;
      try {
        if (SameRestoreOwner(owner) && !g_pendingRestoreBlocked && g_pendingRestore &&
            g_pendingRestore->account_id == accountId && g_pendingRestore->token == restoreToken)
          removed = FinishIdentityRestoreRollback(owner);
      } catch (...) { Log("identity restore rollback remains pending"); }
      try { if (done) done(removed); } catch (...) {}
    });
  } catch (...) { try { if (done) done(false); } catch (...) {} }
}

void FinalizeIdentityRestore(const std::string& accountId, const std::string& restoreToken,
                             const std::string& settingsDocument,
                             std::function<void(const Account&)> done) {
  try {
    const auto owner = CaptureRestoreOwner();
    if (!owner) { if (done) done(Account{}); return; }
    const auto pairingEpoch = g_pairingVisits.Capture();
    Post([accountId, restoreToken, settingsDocument, owner = *owner, pairingEpoch, done]() {
      Account result;
      bool reserved = false;
      try {
        if (!g_pendingRestore || !SameRestoreOwner(owner))
          throw std::runtime_error("restore finalization owner changed");
        const auto path = RestoreStore::DefaultPath();
        const auto settingsPath = sybl::identity_restore::CanonicalSettingsLease::DefaultPath();
        if (!path || !settingsPath) throw std::runtime_error("restore finalization storage unavailable");
        RestoreStore store(*path);
        const auto loaded = store.Load();
        if (loaded.status != sybl::identity_restore::LoadStatus::kLoaded ||
            loaded.value->token != g_pendingRestore->token || loaded.value->account_id != accountId ||
            loaded.value->token != restoreToken ||
            loaded.value->expected_jami_id != g_pendingRestore->expected_jami_id)
          throw std::runtime_error("restore finalization record changed");
        {
          std::lock_guard<std::mutex> lock(g_mutex);
          if (!MediaSlotIdleLocked(true) || !g_identityActivationPending ||
              !g_archiveProtectionReady || g_archiveRecoveryBlocked)
            throw std::runtime_error("restore finalization cannot interrupt media");
          g_identityActivationPending = true;
          reserved = true;
        }
        std::unique_ptr<sybl::identity_restore::CanonicalSettingsLease> settingsLease;
        auto pending = *loaded.value;
        if (!pending.pairing_operation &&
            (pending.expected_jami_id.empty() ||
             BareJamiId(AwaitRestoredUsername(accountId)) != pending.expected_jami_id))
          throw std::runtime_error("restored identity differs from the expected Friend ID");
        const auto pairingCurrent = [&] {
          return !pending.pairing_operation ||
              (PairingForeground() && g_pairingVisits.Allows(restoreToken, pairingEpoch));
        };
        const bool ok = sybl::identity_restore::Finalize(pending, accountId, restoreToken, settingsDocument, {
            [&] { return SameRestoreOwner(owner) && pairingCurrent(); },
            [&](const std::string& document) {
              settingsLease = sybl::identity_restore::CanonicalSettingsLease::Acquire(*settingsPath, document);
              return settingsLease != nullptr;
            },
            [&](const RestoreRecord& committed) {
              if (!store.Save(committed)) return false;
              g_pendingRestore = committed;
              return true;
            },
            [&](bool enabled) {
              if (!SameRestoreOwner(owner) || !pairingCurrent()) return false;
              auto details = libjami::getAccountDetails(accountId);
              details["Account.enable"] = enabled ? "true" : "false";
              libjami::setAccountDetails(accountId, details);
              libjami::sendRegister(accountId, enabled);
              libjami::setAccountActive(accountId, true, false);
              if (!SameRestoreOwner(owner) || !pairingCurrent()) return false;
              result = RestoreProjection(pending, false);
              if (result.status != "ok" || result.enabled != enabled) return false;
              {
                std::lock_guard<std::mutex> lock(g_mutex);
                if (!pairingCurrent()) return false;
                SelectAccountLocked(accountId);
                g_networkPreparedRevision = g_accountRevision;
              }
              RefreshRoutingSnapshot(accountId);
              // Selecting the exact imported identity intentionally retires its old visit.
              return !pending.pairing_operation || PairingForeground();
            },
            [&] { return store.Clear(pending.token); }});
        if (!ok) {
          result = Account{};
          if (!DisablePreparedAccount(accountId)) {
            Log("failed restore finalization could not confirm disabled account");
          } else if (g_pendingRestore && !ReprepareDisabledRestore(*g_pendingRestore, store))
            Log("disabled restore retry could not be persisted");
          {
            std::lock_guard<std::mutex> lock(g_mutex);
            if (g_accountId == accountId) SelectAccountLocked(owner.accountId);
          }
          g_pendingRestoreOwner = CaptureRestoreOwner();
        } else {
          g_pendingRestore.reset();
          g_pendingRestoreOwner.reset();
        }
      } catch (...) { Log("restore finalization incomplete"); }
      if (reserved) {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_identityActivationPending = g_pendingRestoreBlocked || g_pendingRestore.has_value();
      }
      try { if (done) done(result); } catch (...) {}
    });
  } catch (...) { try { if (done) done(Account{}); } catch (...) {} }
}

void PlaceCall(const std::string& peerJamiId, bool withVideo,
               bool initialAudioMuted,
               std::function<void(const std::string&, bool)> done) {
  try {
    Post([peerJamiId, withVideo, initialAudioMuted, done]() {
      std::string callId;
      bool cameraOn = false;
      std::shared_ptr<OutgoingPlacementBarrier> placementBarrier;
      try {
        const std::string acc = CurrentAccountId();
        const std::string targetPeer = BareJamiId(peerJamiId);
        if (acc.empty() || !IsTrustedPeer(acc, targetPeer)) {
          Log("placeCall: no account");
        } else {
          bool canPlace = false;
          {
            std::lock_guard<std::mutex> lock(g_mutex);
            canPlace = g_activeCallId.empty() && g_activeGroupConferenceId.empty() &&
                g_pendingGroupConferenceId.empty() && !g_placingOutgoing &&
                g_reservedCallPeer.empty() && !g_identityActivationPending;
            if (canPlace) {
              placementBarrier = std::make_shared<OutgoingPlacementBarrier>();
              g_outgoingPlacementBarrier = placementBarrier;
              g_placingOutgoing = true;
              g_reservedCallPeer = targetPeer;
              g_winnerCallIdDuringPlacement.clear();
              g_terminalDuringPlacement.clear();
              // PTT and voice activation start privacy-closed in the initial
              // libjami offer, before Dart observes CURRENT.
              g_micMuted.store(initialAudioMuted);
            }
          }
          if (!canPlace) {
            Log("placeCall: another call or placement is active");
          } else {
          // Place-with-video offers ACTIVE video in the INVITE (daemon-captured: SOURCE="camera://<dev>"). Falls
          // back to audio-only if no camera. The negotiated send encoder is VP8 (no H.264/HEVC encoder built).
          if (!RecordWindowsSybLRevokeAndWait(3000))
            throw std::runtime_error("recorder release unconfirmed");
          std::string mrl;
          if (withVideo) {
            size_t idx = 0;
            {
              std::lock_guard<std::mutex> lock(g_mutex);
              idx = g_cameraIndex;
            }
            mrl = CameraMrl(idx, &idx);
            if (!mrl.empty()) {
              std::lock_guard<std::mutex> lock(g_mutex);
              g_cameraIndex = idx;
            }
          }
          auto media = mrl.empty()
              ? AudioMediaList(initialAudioMuted)
              : VideoMediaList(initialAudioMuted, /*videoEnabled=*/true,
                               /*videoMuted=*/false, mrl);
          std::string winnerBeforeDial;
          {
            std::lock_guard<std::mutex> lock(g_mutex);
            winnerBeforeDial = !g_currentWinnerCallId.empty()
                ? g_currentWinnerCallId : g_winnerCallIdDuringPlacement;
            if (!winnerBeforeDial.empty()) {
              g_placingOutgoing = false;
              g_winnerCallIdDuringPlacement.clear();
              g_terminalDuringPlacement.clear();
            } else if (!mrl.empty()) {
              g_localVideoSource.kind = screen_source::Kind::Camera;
              g_localVideoSource.uri = mrl;
              g_localVideoSource.epoch += 1;
            }
          }
          if (!winnerBeforeDial.empty()) {
            const bool adopted = !mrl.empty() && AdoptPlacementCameraIfOwned(acc, winnerBeforeDial, mrl);
            if (adopted) {
              std::lock_guard<std::mutex> lock(g_mutex);
              if (IsAuthoritativeCallLocked(winnerBeforeDial)) {
                g_localVideoSource.kind = screen_source::Kind::Camera;
                g_localVideoSource.uri = mrl;
                g_localVideoSource.call_id = winnerBeforeDial;
              }
            }
            EmitOutgoingSourceIfAuthoritative(acc, winnerBeforeDial);
            Log("placeCall cancelled: CURRENT " + winnerBeforeDial + " established before dial");
          } else {
          callId = libjami::placeCallWithMedia(acc, targetPeer, media);
          bool endedEarly = false;
          bool anotherCallWon = false;
          std::string cameraAdoptionWinner;
          {
            std::lock_guard<std::mutex> lock(g_mutex);
            const std::string placementWinner = g_winnerCallIdDuringPlacement;
            endedEarly = !callId.empty() && g_terminalDuringPlacement.erase(callId) != 0;
            if (!callId.empty() && !endedEarly) g_callPeers[callId] = targetPeer;
            if (!callId.empty() && !endedEarly && !placementWinner.empty() && placementWinner != callId) {
              anotherCallWon = true;
              g_rejectedCallIds.insert(callId);
            } else if (!callId.empty() && !endedEarly && (g_activeCallId.empty() || g_activeCallId == callId)) {
              g_activeCallId = callId;
              if (!mrl.empty()) g_localVideoSource.call_id = callId;
              auto sink = g_sinks.find(mrl);
              if (sink != g_sinks.end()) sink->second->callId = callId;
            } else if (!callId.empty() && !endedEarly && !g_activeCallId.empty() && g_activeCallId != callId) {
              anotherCallWon = true;
              // Decide + tombstone atomically with terminal cleanup; otherwise a terminal can remove it in the gap
              // and this placement reply would recreate a permanent tombstone after the final callback.
              g_rejectedCallIds.insert(callId);
            }
            g_placingOutgoing = false;
            if (callId.empty() || endedEarly) ClearCallReservationIfIdleLocked(targetPeer);
            g_winnerCallIdDuringPlacement.clear();
            cameraOn = !callId.empty() && !mrl.empty() && !endedEarly && !anotherCallWon;
            if (!mrl.empty() && anotherCallWon && !g_currentWinnerCallId.empty() &&
                g_activeCallId == g_currentWinnerCallId && g_currentWinnerCallId != callId &&
                g_localVideoSource.uri == mrl) {
              cameraAdoptionWinner = g_currentWinnerCallId;
            }
            g_terminalDuringPlacement.clear();
          }
          bool cameraAdoptedByWinner = false;
          if (!cameraAdoptionWinner.empty()) {
            cameraAdoptedByWinner = AdoptPlacementCameraIfOwned(acc, cameraAdoptionWinner, mrl);
            Log("placement camera adoption by " + cameraAdoptionWinner + " -> " +
                (cameraAdoptedByWinner ? "true" : "false"));
          }
          {
            std::lock_guard<std::mutex> lock(g_mutex);
            if (!cameraOn && !cameraAdoptedByWinner && g_localVideoSource.uri == mrl)
              g_localVideoSource = {};
          }
          if (!cameraAdoptionWinner.empty())
            EmitOutgoingSourceIfAuthoritative(acc, cameraAdoptionWinner);
          Log("placeCall(" + peerJamiId + ") withVideo=" + (withVideo ? "1" : "0") + " src=" + mrl + " -> " + callId);
          if (anotherCallWon) {
            try { libjami::hangUp(acc, callId); } catch (...) {}
          }
          }
          }
        }
      } catch (...) {
        {
          std::lock_guard<std::mutex> lock(g_mutex);
          g_placingOutgoing = false;
          ClearCallReservationIfIdleLocked(BareJamiId(peerJamiId));
          g_winnerCallIdDuringPlacement.clear();
          g_terminalDuringPlacement.clear();
          if (g_activeCallId.empty()) g_localVideoSource = {};
        }
        Log("placeCall threw");
      }
      {
        std::lock_guard<std::mutex> lock(g_mutex);
        if (g_outgoingPlacementBarrier == placementBarrier) g_outgoingPlacementBarrier.reset();
      }
      CompleteOutgoingPlacement(placementBarrier);
      try {
        if (done) done(callId, cameraOn);
      } catch (...) {
      }
    });
  } catch (...) {
    Log("placeCall post failed");
    try {
      if (done) done(std::string(), false);
    } catch (...) {
    }
  }
}

void ListGroupCalls(
    const std::string& conversationId,
    std::function<void(const std::vector<GroupActiveCall>&)> done) {
  try {
    Post([conversationId, done]() {
      std::vector<GroupActiveCall> result;
      try {
        const auto accountId = CurrentAccountId();
        const auto snapshot = RoutingSnapshot();
        if (!accountId.empty() && snapshot &&
            snapshot->account_id == accountId &&
            snapshot->Group(conversationId)) {
          for (const auto& value :
               libjami::getActiveCalls(accountId, conversationId)) {
            const auto id = value.find("id");
            const auto uri = value.find("uri");
            const auto device = value.find("device");
            if (id == value.end() || uri == value.end() ||
                device == value.end() ||
                sybl::group_call::RoomId(id->second).empty() ||
                uri->second.empty() || device->second.empty()) continue;
            result.push_back(
                {id->second, BareJamiId(uri->second), device->second});
          }
        }
      } catch (...) { Log("listGroupCalls threw"); }
      try { if (done) done(result); } catch (...) {}
    });
  } catch (...) {
    try { if (done) done({}); } catch (...) {}
  }
}

void ReserveGroupCall(const std::string& accountId,
    const std::string& conversationId, const std::string& reservationId,
    std::function<void(bool)> done) {
  const auto owner = CaptureAccountCommandOwner(accountId);
  if (!owner) { if (done) done(false); return; }
  Post([owner, conversationId, reservationId, done]() {
    bool reserved = false;
    try {
      const auto route = RoutingSnapshot();
      const auto details = libjami::getAccountDetails(owner->accountId);
      const auto enabled = details.find("Account.enable");
      if (OwnsAccountCommand(*owner) && enabled != details.end() && enabled->second == "true" && route &&
          route->account_id == owner->accountId && route->Group(conversationId) &&
          !sybl::group_call::RoomId(reservationId).empty()) {
        {
          std::lock_guard<std::mutex> lock(g_mutex);
          if (!g_identityActivationPending && g_accountId == owner->accountId && g_accountRevision == owner->revision &&
              g_activeCallId.empty() && g_reservedCallPeer.empty() && !g_placingOutgoing &&
              g_activeGroupConferenceId.empty() && g_pendingGroupConferenceId.empty()) {
            g_pendingGroupConferenceId = reservationId;
            g_groupReservationId = reservationId;
            g_groupPlacementStarted = false;
            g_groupConversationByConference[reservationId] = conversationId;
            reserved = true;
          }
        }
        if (reserved && !RecordWindowsSybLRevokeAndWait(3000)) reserved = false;
      }
    } catch (...) { Log("reserveGroupCall failed"); }
    if (!reserved) {
      std::lock_guard<std::mutex> lock(g_mutex);
      if (g_accountId == owner->accountId && g_accountRevision == owner->revision &&
          g_groupReservationId != reservationId && !sybl::group_call::RoomId(reservationId).empty()) {
        g_detachedGroupReservations[{reservationId, reservationId}] = owner->revision;
        while (g_detachedGroupReservations.size() > 64) g_detachedGroupReservations.erase(g_detachedGroupReservations.begin());
      }
    }
    try { if (done) done(reserved); } catch (...) {}
  });
}

void JoinGroupCall(
    const std::string& conversationId, const std::string& conferenceId,
    const std::string& reservationId,
    const std::string& hostUri, const std::string& hostDevice,
    bool initialAudioMuted,
    std::function<void(const GroupCallPlacement&)> done) {
  try {
    Post([conversationId, conferenceId, reservationId, hostUri, hostDevice,
          initialAudioMuted, done]() {
      GroupCallPlacement result;
      std::string accountId;
      bool admitted = false;
      bool issued = false;
      try {
        accountId = CurrentAccountId();
        const auto snapshot = RoutingSnapshot();
        if (accountId.empty() || !snapshot ||
            snapshot->account_id != accountId ||
            !snapshot->Group(conversationId) ||
            sybl::group_call::RoomId(conferenceId).empty()) {
          throw std::runtime_error("invalid group call route");
        }
        {
          std::lock_guard<std::mutex> lock(g_mutex);
          if (g_identityActivationPending || !g_activeCallId.empty() || g_placingOutgoing ||
              !g_activeGroupConferenceId.empty() || reservationId.empty() ||
              g_groupReservationId != reservationId || g_groupPlacementStarted ||
              g_pendingGroupConferenceId != reservationId ||
              g_groupConversationByConference[reservationId] != conversationId) {
            throw std::runtime_error("another call is active");
          }
          admitted = true;
          g_groupPlacementStarted = true;
          g_groupConversationByConference.erase(reservationId);
          g_pendingGroupConferenceId = conferenceId;
          g_groupConversationByConference[conferenceId] = conversationId;
          g_micMuted.store(initialAudioMuted);
        }

        if (!RecordWindowsSybLRevokeAndWait(3000))
          throw std::runtime_error("recorder release unconfirmed");
        std::string target;
        const bool hosting = hostUri.empty() && hostDevice.empty();
        if (hosting) {
          const auto details = libjami::getAccountDetails(accountId);
          const auto volatileDetails =
              libjami::getVolatileAccountDetails(accountId);
          const auto username =
              details.find(libjami::Account::ConfProperties::USERNAME);
          const auto device =
              volatileDetails.find(
                  libjami::Account::ConfProperties::DEVICE_ID);
          if (username == details.end() || device == volatileDetails.end() ||
              username->second.empty() || device->second.empty()) {
            throw std::runtime_error("missing local group host identity");
          }
          auto preferences =
              libjami::getConversationPreferences(accountId, conversationId);
          std::optional<std::string> previous;
          const auto old = preferences.find("hostConferences");
          if (old != preferences.end()) previous = old->second;
          {
            std::lock_guard<std::mutex> lock(g_mutex);
            g_previousGroupHostPreference.emplace(conversationId, previous);
          }
          libjami::setConversationPreferences(
              accountId, conversationId, {{"hostConferences", "true"}});
          target = "rdv:" + conversationId + '/' +
                   BareJamiId(username->second) + '/' + device->second + '/' +
                   conferenceId;
        } else {
          const auto bareHost = BareJamiId(hostUri);
          if (bareHost.empty() || hostDevice.empty())
            throw std::runtime_error("invalid group host");
          bool exactCallExists = false;
          for (const auto& call :
               libjami::getActiveCalls(accountId, conversationId)) {
            const auto id = call.find("id");
            const auto uri = call.find("uri");
            const auto device = call.find("device");
            exactCallExists = id != call.end() && uri != call.end() &&
                device != call.end() && id->second == conferenceId &&
                BareJamiId(uri->second) == bareHost &&
                device->second == hostDevice;
            if (exactCallExists) break;
          }
          if (!exactCallExists)
            throw std::runtime_error("group host is no longer active");
          target = "rdv:" + conversationId + '/' + bareHost + '/' +
                   hostDevice + '/' + conferenceId;
        }

        {
          std::lock_guard<std::mutex> lock(g_mutex);
          g_activeGroupHosting = hosting;
        }
        issued = true;
        const auto callId = libjami::placeCallWithMedia(
            accountId, target,
            VideoMediaList(initialAudioMuted, /*videoEnabled=*/true,
                           /*videoMuted=*/true, /*source=*/""));
        if (!hosting && callId.empty())
          throw std::runtime_error("group call placement failed");
        {
          std::lock_guard<std::mutex> lock(g_mutex);
          if (!callId.empty()) g_groupCallLegs[conferenceId] = callId;
          g_activeGroupConferenceId = conferenceId;
          g_activeGroupHosting = hosting;
          g_pendingGroupConferenceId.clear();
        }
        result = {conferenceId, callId, hosting};
        // Reconcile the exact returned leg, including an early terminal signal.
        if (!hosting && !callId.empty()) {
          const auto details = libjami::getCallDetails(accountId, callId);
          const auto found = details.find("CALL_STATE");
          const auto state = found == details.end() ? std::string("FAILURE") : found->second;
          if (state == "CURRENT" || IsTerminalCallState(state)) {
            Emit("groupCallLegState", {{"accountId", accountId}, {"conferenceId", conferenceId},
              {"reservationId", reservationId}, {"callId", callId}, {"state", state}});
            if (found != details.end() && IsTerminalCallState(state))
              ClearGroupCall(accountId, conferenceId);
          }
        }
      } catch (...) {
        Log("joinGroupCall failed");
        // An exception after native publication is not proof of detachment.
        if (admitted && !issued) ClearGroupCall(accountId, conferenceId);
      }
      try { if (done) done(result); } catch (...) {}
    });
  } catch (...) {
    try { if (done) done(GroupCallPlacement{}); } catch (...) {}
  }
}

void LeaveGroupCall(const std::string& conferenceId, const std::string& reservationId,
                    std::function<void(bool)> done) {
  try {
    Post([conferenceId, reservationId, done]() {
      bool ok = false;
      try {
        const auto accountId = CurrentAccountId();
        std::string leg;
        bool owns = false;
        bool unissued = false;
        {
          std::lock_guard<std::mutex> lock(g_mutex);
          const auto retired = g_detachedGroupReservations.find({conferenceId, reservationId});
          ok = !reservationId.empty() && retired != g_detachedGroupReservations.end() &&
               retired->second == g_accountRevision;
          owns = !reservationId.empty() && g_groupReservationId == reservationId &&
                 (g_activeGroupConferenceId == conferenceId || g_pendingGroupConferenceId == conferenceId);
          unissued = owns && !g_groupPlacementStarted && g_activeGroupConferenceId.empty();
          const auto found = g_groupCallLegs.find(conferenceId);
          if (found != g_groupCallLegs.end()) leg = found->second;
        }
        if (!accountId.empty() && owns &&
            !sybl::group_call::RoomId(conferenceId).empty()) {
          ok = unissued ? true : leg.empty() ? libjami::hangUpConference(accountId, conferenceId)
                           : libjami::hangUp(accountId, leg);
          if (ok) {
            const auto calls = libjami::getCallList(accountId);
            const auto conferences = libjami::getConferenceList(accountId);
            ok = (leg.empty() || std::find(calls.begin(), calls.end(), leg) == calls.end()) &&
                 std::find(conferences.begin(), conferences.end(), conferenceId) == conferences.end();
            if (ok) ClearGroupCall(accountId, conferenceId);
          }
        }
      } catch (...) { Log("leaveGroupCall threw"); }
      try { if (done) done(ok); } catch (...) {}
    });
  } catch (...) {
    try { if (done) done(false); } catch (...) {}
  }
}

void SetGroupMicMuted(const std::string& conferenceId, bool muted,
                      std::function<void(bool)> done) {
  try {
    Post([conferenceId, muted, done]() {
      bool ok = false;
      try {
        const auto accountId = CurrentAccountId();
        std::string target;
        {
          std::lock_guard<std::mutex> lock(g_mutex);
          if (g_activeGroupConferenceId == conferenceId && (muted || !g_identityActivationPending)) {
            target = MediaSignalingTargetLocked(conferenceId);
          }
        }
        if (!accountId.empty() && !target.empty()) {
          ok = libjami::muteLocalMedia(accountId, target,
                                       "MEDIA_TYPE_AUDIO", muted);
          if (ok) g_micMuted.store(muted);
        }
      } catch (...) { Log("setGroupMicMuted threw"); }
      try { if (done) done(ok); } catch (...) {}
    });
  } catch (...) {
    try { if (done) done(false); } catch (...) {}
  }
}

void SetGroupDeafened(const std::string& conferenceId, bool deafened,
                      std::function<void(bool)> done) {
  try {
    Post([conferenceId, deafened, done]() {
      bool ok = false;
      try {
        bool owns = false;
        {
          std::lock_guard<std::mutex> lock(g_mutex);
          owns = g_activeGroupConferenceId == conferenceId;
        }
        if (!owns) throw std::runtime_error("stale group conference");
        double volume = 0.0;
        if (deafened) {
          const auto previous = libjami::getVolume("speaker");
          std::lock_guard<std::mutex> lock(g_mutex);
          if (g_activeGroupConferenceId != conferenceId)
            throw std::runtime_error("stale group conference");
          if (!g_previousGroupPlaybackVolume)
            g_previousGroupPlaybackVolume = previous;
        } else {
          std::lock_guard<std::mutex> lock(g_mutex);
          volume = g_previousGroupPlaybackVolume.value_or(1.0);
          g_previousGroupPlaybackVolume.reset();
        }
        libjami::setVolume("speaker", volume);
        ok = true;
      } catch (...) { Log("setGroupDeafened threw"); }
      try { if (done) done(ok); } catch (...) {}
    });
  } catch (...) {
    try { if (done) done(false); } catch (...) {}
  }
}

void SetGroupConferenceLayout(const std::string& conferenceId, int layout,
                              std::function<void(bool)> done) {
  try {
    Post([conferenceId, layout, done]() {
      bool ok = false;
      try {
        const auto accountId = CurrentAccountId();
        {
          std::lock_guard<std::mutex> lock(g_mutex);
          ok = g_activeGroupConferenceId == conferenceId &&
               (layout == 0 || layout == 1);
        }
        if (ok) libjami::setConferenceLayout(accountId, conferenceId, layout);
      } catch (...) { ok = false; Log("setGroupConferenceLayout threw"); }
      try { if (done) done(ok); } catch (...) {}
    });
  } catch (...) {
    try { if (done) done(false); } catch (...) {}
  }
}

void SetGroupActiveStream(const std::string& conferenceId,
                          const std::string& accountUri,
                          const std::string& deviceId,
                          const std::string& streamId, bool active,
                          std::function<void(bool)> done) {
  try {
    Post([conferenceId, accountUri, deviceId, streamId, active, done]() {
      bool ok = false;
      try {
        const auto accountId = CurrentAccountId();
        {
          std::lock_guard<std::mutex> lock(g_mutex);
          ok = g_activeGroupConferenceId == conferenceId &&
               !accountUri.empty() && !deviceId.empty() && !streamId.empty();
        }
        if (ok) libjami::setActiveStream(accountId, conferenceId, accountUri,
                                         deviceId, streamId, active);
      } catch (...) { ok = false; Log("setGroupActiveStream threw"); }
      try { if (done) done(ok); } catch (...) {}
    });
  } catch (...) {
    try { if (done) done(false); } catch (...) {}
  }
}

void MuteGroupParticipant(const std::string& conferenceId,
                          const std::string& accountUri,
                          const std::string& deviceId,
                          const std::string& streamId, bool muted,
                          std::function<void(bool)> done) {
  try {
    Post([conferenceId, accountUri, deviceId, streamId, muted, done]() {
      bool ok = false;
      try {
        const auto accountId = CurrentAccountId();
        {
          std::lock_guard<std::mutex> lock(g_mutex);
          ok = g_activeGroupConferenceId == conferenceId &&
               !accountUri.empty() && !deviceId.empty();
        }
        if (ok) libjami::muteStream(accountId, conferenceId, accountUri,
                                    deviceId, streamId, muted);
      } catch (...) { ok = false; Log("muteGroupParticipant threw"); }
      try { if (done) done(ok); } catch (...) {}
    });
  } catch (...) {
    try { if (done) done(false); } catch (...) {}
  }
}

void DisconnectGroupParticipant(const std::string& conferenceId,
                                const std::string& accountUri,
                                const std::string& deviceId,
                                std::function<void(bool)> done) {
  try {
    Post([conferenceId, accountUri, deviceId, done]() {
      bool ok = false;
      try {
        const auto accountId = CurrentAccountId();
        {
          std::lock_guard<std::mutex> lock(g_mutex);
          ok = g_activeGroupConferenceId == conferenceId &&
               !accountUri.empty() && !deviceId.empty();
        }
        if (ok) libjami::hangupParticipant(accountId, conferenceId, accountUri,
                                           deviceId);
      } catch (...) { ok = false; Log("disconnectGroupParticipant threw"); }
      try { if (done) done(ok); } catch (...) {}
    });
  } catch (...) {
    try { if (done) done(false); } catch (...) {}
  }
}

void PublishGroupCallPresence(const std::string& conversationId,
                              const std::string& body,
                              std::function<void(bool)> done) {
  try {
    Post([conversationId, body, done]() {
      bool ok = false;
      try {
        const auto accountId = CurrentAccountId();
        const auto snapshot = RoutingSnapshot();
        const auto* group = snapshot && snapshot->account_id == accountId
                                ? snapshot->Group(conversationId)
                                : nullptr;
        if (!accountId.empty() && group &&
            body.size() <= sybl::group_call::kMaxPresenceBytes) {
          ok = true;
          const std::map<std::string, std::string> payload{
              {sybl::group_call::kPresenceMime, body}};
          for (const auto& member : group->active_member_ids) {
            if (member == snapshot->self_id) continue;
            ok = libjami::sendAccountTextMessage(
                     accountId, member, payload, 0) != 0 && ok;
          }
        }
      } catch (...) { Log("publishGroupCallPresence threw"); }
      try { if (done) done(ok); } catch (...) {}
    });
  } catch (...) {
    try { if (done) done(false); } catch (...) {}
  }
}

void AnswerCall(const std::string& callId, bool initialAudioMuted,
                std::function<void(bool)> done) {
  try {
    Post([callId, initialAudioMuted, done]() {
      bool ok = false;
      try {
        const std::string acc = CurrentAccountId();
        if (acc.empty()) {
          Log("answerCall: no account");
        } else {
          std::vector<std::map<std::string, std::string>> offer;
          {
            std::lock_guard<std::mutex> lock(g_mutex);
            if (g_identityActivationPending) throw std::runtime_error("answer blocked during identity restore");
            const auto it = g_incomingOffers.find(callId);
            if (it != g_incomingOffers.end()) {
              offer = it->second;
            }
            // Explicit bootstrap state, never the previous call's global latch.
            g_micMuted.store(initialAudioMuted);
            g_activeCallId = callId;  // set early so the REMOTE decoded sink (id==callId) routes correctly
          }
          // Answer with our camera off (receive-only video) — the user turns it on mid-call via toggleCamera.
          ok = RecordWindowsSybLRevokeAndWait(3000) && libjami::acceptWithMedia(
              acc, callId,
              MirrorOffer(offer, initialAudioMuted, /*cameraOn=*/false, ""));
          {
            std::lock_guard<std::mutex> lock(g_mutex);
            if (ok)
              g_incomingOffers.erase(callId);
            else if (g_activeCallId == callId)
              g_activeCallId.clear();
          }
          Log("acceptWithMedia(" + callId + ") -> " + (ok ? "true" : "false"));
        }
      } catch (...) {
        Log("answerCall threw");
      }
      try {
        if (done) done(ok);
      } catch (...) {
      }
    });
  } catch (...) {
    Log("answerCall post failed");
    try {
      if (done) done(false);
    } catch (...) {
    }
  }
}

void HangUp(const std::string& callId, std::function<void(bool)> done) {
  try {
    Post([callId, done]() {
      bool ok = false;
      try {
        const std::string acc = CurrentAccountId();
        if (!acc.empty()) ok = libjami::hangUp(acc, callId);
        Log("hangUp(" + callId + ") -> " + (ok ? "true" : "false"));
      } catch (...) {
        Log("hangUp threw");
      }
      try {
        if (done) done(ok);
      } catch (...) {
      }
    });
  } catch (...) {
    Log("hangUp post failed");
    try {
      if (done) done(false);
    } catch (...) {
    }
  }
}

void AudioOutputs(std::function<void(std::vector<std::string>)> done) {
  try {
    Post([done]() {
      std::vector<std::string> devices;
      try {
        devices = libjami::getAudioOutputDeviceList();
      } catch (...) {
        Log("audioOutputs threw");
      }
      try {
        if (done) done(std::move(devices));
      } catch (...) {
      }
    });
  } catch (...) {
    Log("audioOutputs post failed");
    try {
      if (done) done({});
    } catch (...) {
    }
  }
}

void SetAudioOutput(int index, std::function<void(bool)> done) {
  try {
    Post([index, done]() {
      bool ok = false;
      try {
        if (index >= 0 &&
            index < static_cast<int>(libjami::getAudioOutputDeviceList().size())) {
          libjami::setAudioOutputDevice(index);
          ok = true;
        }
        Log("setAudioOutput(" + std::to_string(index) + ") -> " +
            (ok ? "true" : "false"));
      } catch (...) {
        Log("setAudioOutput threw");
      }
      try {
        if (done) done(ok);
      } catch (...) {
      }
    });
  } catch (...) {
    Log("setAudioOutput post failed");
    try {
      if (done) done(false);
    } catch (...) {
    }
  }
}

void AudioInputs(std::function<void(std::vector<std::string>)> done) {
  try {
    Post([done]() {
      std::vector<std::string> devices;
      try {
        devices = libjami::getAudioInputDeviceList();
      } catch (...) {
        Log("audioInputs threw");
      }
      try {
        if (done) done(std::move(devices));
      } catch (...) {
      }
    });
  } catch (...) {
    Log("audioInputs post failed");
    try {
      if (done) done({});
    } catch (...) {
    }
  }
}

void SetAudioInput(int index, std::function<void(bool)> done) {
  try {
    Post([index, done]() {
      bool ok = false;
      try {
        if (index >= 0 &&
            index < static_cast<int>(libjami::getAudioInputDeviceList().size())) {
          libjami::setAudioInputDevice(index);
          ok = true;
        }
        Log("setAudioInput(" + std::to_string(index) + ") -> " +
            (ok ? "true" : "false"));
      } catch (...) {
        Log("setAudioInput threw");
      }
      try {
        if (done) done(ok);
      } catch (...) {
      }
    });
  } catch (...) {
    Log("setAudioInput post failed");
    try {
      if (done) done(false);
    } catch (...) {
    }
  }
}

void Refuse(const std::string& callId, std::function<void(bool)> done) {
  try {
    Post([callId, done]() {
      bool ok = false;
      try {
        const std::string acc = CurrentAccountId();
        if (!acc.empty()) ok = libjami::refuse(acc, callId);
        Log("refuse(" + callId + ") -> " + (ok ? "true" : "false"));
      } catch (...) {
        Log("refuse threw");
      }
      try {
        if (done) done(ok);
      } catch (...) {
      }
    });
  } catch (...) {
    Log("refuse post failed");
    try {
      if (done) done(false);
    } catch (...) {
    }
  }
}

void SetMicMuted(const std::string& callId, bool muted, std::function<void(bool)> done) {
  try {
    Post([callId, muted, done]() {
      bool ok = false;
      try {
        const std::string acc = CurrentAccountId();
        {
          std::lock_guard<std::mutex> lock(g_mutex);
          ok = !acc.empty() && !callId.empty() && g_activeCallId == callId &&
              (muted || !g_identityActivationPending);
        }
        if (ok) ok = libjami::muteLocalMedia(acc, callId, "MEDIA_TYPE_AUDIO", muted);
        if (ok) {
          std::lock_guard<std::mutex> lock(g_mutex);
          ok = g_activeCallId == callId;
          if (ok) g_micMuted.store(muted);
        }
        Log("muteLocalMedia(" + callId + ", audio, " + (muted ? "true" : "false") + ") -> " +
            (ok ? "true" : "false"));
      } catch (...) {
        Log("muteLocalMedia threw");
      }
      try { if (done) done(ok); } catch (...) {}
    });
  } catch (...) {
    Log("setMicMuted post failed");
    try { if (done) done(false); } catch (...) {}
  }
}

void SetAudioTransmissionMode(const std::string& callId,
                              const std::string& modeValue,
                              std::function<void(bool)> done) {
  const auto parsed = sybl::calls::ParseAudioTransmissionMode(modeValue);
  if (!parsed) {
    Log("setAudioTransmissionMode rejected invalid mode");
    try {
      if (done) done(false);
    } catch (...) {
    }
    return;
  }
  try {
    Post([callId, mode = *parsed, done]() {
      bool ok = false;
      try {
        const std::string acc = CurrentAccountId();
        {
          std::lock_guard<std::mutex> lock(g_mutex);
          ok = !acc.empty() && acc == g_accountId &&
               IsAuthoritativeCallLocked(callId);
        }
        if (ok && mode == sybl::calls::AudioTransmissionMode::kVoiceActivated) {
          if (!libjami::getVoiceActivityDetectionState())
            libjami::setVoiceActivityDetectionState(true);
          ok = libjami::getVoiceActivityDetectionState();
        }
        const std::string daemonMode(
            sybl::calls::AudioTransmissionModeValue(mode));
        if (ok)
          ok = libjami::setAudioTransmissionMode(acc, callId, daemonMode);
        if (ok) {
          std::lock_guard<std::mutex> lock(g_mutex);
          ok = acc == g_accountId && IsAuthoritativeCallLocked(callId);
        }
        Log("setAudioTransmissionMode(" + callId + ", " + daemonMode +
            ") -> " + (ok ? "true" : "false"));
      } catch (...) {
        Log("setAudioTransmissionMode threw");
      }
      try {
        if (done) done(ok);
      } catch (...) {
      }
    });
  } catch (...) {
    Log("setAudioTransmissionMode post failed");
    try {
      if (done) done(false);
    } catch (...) {
    }
  }
}

void SetAudioMeterEnabled(bool enabled, std::function<void(bool)> done) {
  try {
    Post([enabled, done]() {
      bool ok = false;
      try {
        if (libjami::initialized()) {
          {
            std::lock_guard<std::mutex> lock(g_mutex);
            g_audioMeterRequested = enabled;
            g_remoteMeterProbeAfter = 0;
          }
          RefreshRemoteAudioMeters();
          libjami::setAudioMeterState("audiolayer_id", enabled);
          ok = libjami::isAudioMeterActive("audiolayer_id") == enabled;
        }
        Log(std::string("audio meter ") + (enabled ? "enabled" : "disabled") +
            (ok ? "" : " (state mismatch)"));
      } catch (...) {
        Log("setAudioMeterState threw");
      }
      try { if (done) done(ok); } catch (...) {}
    });
  } catch (...) {
    Log("setAudioMeterEnabled post failed");
    try { if (done) done(false); } catch (...) {}
  }
}

// presence v2: stamp OUR fg state for the native pong (Dart calls this BEFORE any announce ping fires).
void SetForeground(bool fg) {
  if (g_foreground.exchange(fg) != fg) ++g_presenceProbeEpoch;
  RecordWindowsSybLSetForeground(fg);
}

void PrepareVoiceRecording(const std::string& accountId,
                           const std::string& peer,
                           const std::string& conversation,
                           std::function<void(std::string)> done) {
  try {
    const auto account = CaptureAccountCommandOwner(accountId);
    if (!account) { if (done) done({}); return; }
    Post([account = *account, peer, conversation, done]() {
      std::string result;
      std::optional<std::filesystem::path> output;
      uint64_t id = 0;
      try {
        if (!OwnsAccountCommand(account)) throw std::runtime_error("recording owner lost");
        const auto details = libjami::getAccountDetails(account.accountId);
        const auto enabled = details.find("Account.enable");
        if (enabled == details.end() || enabled->second != "true")
          throw std::runtime_error("recording offline");
        const auto root = sybl::picked_file::DefaultStagingRoot();
        if (!root) throw std::runtime_error("recording staging unavailable");
        output = sybl::picked_file::ReserveRecordingOutput(*root);
        if (!output) throw std::runtime_error("recording staging unavailable");
        {
          std::lock_guard<std::mutex> lock(g_mutex);
          if (g_recordingOwner || !MediaSlotIdleLocked() ||
              account.accountId != g_accountId || account.revision != g_accountRevision ||
              g_recordingSequence == std::numeric_limits<uint64_t>::max())
            throw std::runtime_error("recording unavailable");
          id = ++g_recordingSequence;
          const auto encoded = output->u8string();
          if (!StageRegistryLocked().ReserveRecording(std::string(encoded.begin(), encoded.end())))
            throw std::runtime_error("recording recovery unavailable");
          g_recordingOwner = RecordingOwner{id, account, peer, conversation, *output};
        }
        g_recordingOffline.store(false);
        if (!RecordWindowsSybLOffer(id, output->c_str()))
          throw std::runtime_error("recording grant refused");
        const auto encoded = output->u8string();
        result.assign(encoded.begin(), encoded.end());
      } catch (...) {
        if (id) RecordingOwnerReleased(id);
        if (output) {
          const auto root = sybl::picked_file::DefaultStagingRoot();
          if (root) sybl::picked_file::Discard(*output, *root);
        }
      }
      try { if (done) done(result); } catch (...) {}
    });
  } catch (...) { try { if (done) done({}); } catch (...) {} }
}

bool RenewVoiceRecording(const std::string& path) {
  try { return RecordWindowsSybLRenew(std::filesystem::u8path(path).c_str()); }
  catch (...) { return false; }
}

void SetPresenceMetadata(bool shareActivity, const std::string& color) {
  if (g_shareActivityPresence.exchange(shareActivity) != shareActivity)
    ++g_presenceProbeEpoch;
  if (const auto index = sybl::identity_color_wire::Index(color)) {
    g_identityColor.store(*index);
  }
}

void CreateGroup(const std::string& title,
                 const std::vector<std::string>& memberIds,
                 const std::optional<std::string>& expectedAccountId,
                 std::function<void(const std::string&)> done) {
  try {
    const auto owner = CaptureAccountCommandOwner(expectedAccountId);
    if (!owner) { if (done) done(std::string{}); return; }
    Post([title, memberIds, owner = *owner, done]() {
      std::string conversation_id;
      try {
        const auto normalized_title = sybl::group::NormalizeTitle(title);
        const auto acc = OwnsAccountCommand(owner) ? owner.accountId : std::string{};
        const auto snapshot = RoutingSnapshot();
        std::set<std::string> trusted;
        if (snapshot) {
          for (const auto& [peer_id, unused] : snapshot->friends) {
            trusted.insert(peer_id);
          }
        }
        const auto members = snapshot
            ? sybl::group::NewMemberIds(
                  memberIds, snapshot->self_id, trusted)
            : std::nullopt;
        if (!acc.empty() && snapshot && snapshot->account_id == acc &&
            normalized_title && members) {
          conversation_id = libjami::startConversation(acc);
          if (!conversation_id.empty()) {
            try {
              libjami::updateConversationInfos(
                  acc, conversation_id, {{"title", *normalized_title}});
              for (const auto& member_id : *members) {
                libjami::addConversationMember(
                    acc, conversation_id, member_id);
              }
              RefreshRoutingSnapshot(acc);
            } catch (...) {
              try {
                libjami::removeConversation(acc, conversation_id);
              } catch (...) {
              }
              conversation_id.clear();
              throw;
            }
          }
        }
      } catch (...) {
        Log("createGroup threw");
        conversation_id.clear();
      }
      try {
        if (done) done(conversation_id);
      } catch (...) {
      }
    });
  } catch (...) {
    Log("createGroup post failed");
    try {
      if (done) done({});
    } catch (...) {
    }
  }
}

void AddGroupMembers(const std::string& conversationId,
                     const std::vector<std::string>& memberIds,
                     const std::optional<std::string>& expectedAccountId,
                     std::function<void(bool)> done) {
  try {
    const auto owner = CaptureAccountCommandOwner(expectedAccountId);
    if (!owner) { if (done) done(false); return; }
    Post([conversationId, memberIds, owner = *owner, done]() {
      bool ok = false;
      try {
        const auto acc = OwnsAccountCommand(owner) ? owner.accountId : std::string{};
        const auto snapshot = RoutingSnapshot();
        const auto* route =
            snapshot ? snapshot->Group(conversationId) : nullptr;
        std::set<std::string> trusted;
        if (snapshot) {
          for (const auto& [peer_id, unused] : snapshot->friends) {
            trusted.insert(peer_id);
          }
        }
        std::set<std::string> existing;
        if (route) {
          existing.insert(
              route->member_ids.begin(), route->member_ids.end());
        }
        const auto members = route
            ? sybl::group::NewMemberIds(
                  memberIds, snapshot->self_id, trusted, existing)
            : std::nullopt;
        if (!acc.empty() && snapshot && snapshot->account_id == acc && route &&
            route->CanManageMembers() && members) {
          std::vector<std::string> added;
          try {
            for (const auto& member_id : *members) {
              libjami::addConversationMember(
                  acc, conversationId, member_id);
              added.push_back(member_id);
            }
            RefreshRoutingSnapshot(acc);
            ok = true;
          } catch (...) {
            for (auto it = added.rbegin(); it != added.rend(); ++it) {
              try {
                libjami::removeConversationMember(
                    acc, conversationId, *it);
              } catch (...) {
              }
            }
            RefreshRoutingSnapshot(acc);
            throw;
          }
        }
      } catch (...) {
        Log("addGroupMembers threw");
      }
      try {
        if (done) done(ok);
      } catch (...) {
      }
    });
  } catch (...) {
    Log("addGroupMembers post failed");
    try {
      if (done) done(false);
    } catch (...) {
    }
  }
}

void RemoveGroupMember(const std::string& conversationId,
                       const std::string& memberId,
                       const std::optional<std::string>& expectedAccountId,
                       std::function<void(bool)> done) {
  try {
    const auto owner = CaptureAccountCommandOwner(expectedAccountId);
    if (!owner) { if (done) done(false); return; }
    Post([conversationId, memberId, owner = *owner, done]() {
      bool ok = false;
      try {
        const auto acc = OwnsAccountCommand(owner) ? owner.accountId : std::string{};
        const auto snapshot = RoutingSnapshot();
        const auto* route =
            snapshot ? snapshot->Group(conversationId) : nullptr;
        const auto member = BareJamiId(memberId);
        if (!acc.empty() && snapshot && snapshot->account_id == acc &&
            route && route->CanManageMembers() &&
            std::find(route->member_ids.begin(), route->member_ids.end(),
                      member) != route->member_ids.end()) {
          libjami::removeConversationMember(
              acc, conversationId, member);
          RefreshRoutingSnapshot(acc);
          ok = true;
        }
      } catch (...) {
        Log("removeGroupMember threw");
      }
      try {
        if (done) done(ok);
      } catch (...) {
      }
    });
  } catch (...) {
    Log("removeGroupMember post failed");
    try {
      if (done) done(false);
    } catch (...) {
    }
  }
}

void RenameGroup(const std::string& conversationId,
                 const std::string& title,
                 const std::optional<std::string>& expectedAccountId,
                 std::function<void(bool)> done) {
  try {
    const auto owner = CaptureAccountCommandOwner(expectedAccountId);
    if (!owner) { if (done) done(false); return; }
    Post([conversationId, title, owner = *owner, done]() {
      bool ok = false;
      try {
        const auto acc = OwnsAccountCommand(owner) ? owner.accountId : std::string{};
        const auto snapshot = RoutingSnapshot();
        const auto* route =
            snapshot ? snapshot->Group(conversationId) : nullptr;
        const auto normalized_title = sybl::group::NormalizeTitle(title);
        if (!acc.empty() && snapshot && snapshot->account_id == acc &&
            route && route->CanManageMembers() &&
            normalized_title) {
          libjami::updateConversationInfos(
              acc, conversationId, {{"title", *normalized_title}});
          RefreshRoutingSnapshot(acc);
          ok = true;
        }
      } catch (...) {
        Log("renameGroup threw");
      }
      try {
        if (done) done(ok);
      } catch (...) {
      }
    });
  } catch (...) {
    Log("renameGroup post failed");
    try {
      if (done) done(false);
    } catch (...) {
    }
  }
}

void UpdateGroupLayout(const std::string& conversationId,
                       const std::string& description,
                       const std::optional<std::string>& expectedAccountId,
                       std::function<void(bool)> done) {
  try {
    const auto owner = CaptureAccountCommandOwner(expectedAccountId);
    if (!owner) { if (done) done(false); return; }
    Post([conversationId, description, owner = *owner, done]() {
      bool ok = false;
      try {
        const auto acc = OwnsAccountCommand(owner) ? owner.accountId : std::string{};
        const auto snapshot = RoutingSnapshot();
        const auto* route =
            snapshot ? snapshot->Group(conversationId) : nullptr;
        const auto normalized = sybl::group::NormalizeLayout(description);
        if (!acc.empty() && snapshot && snapshot->account_id == acc &&
            route && route->CanManageMembers() && normalized) {
          libjami::updateConversationInfos(
              acc, conversationId, {{"description", *normalized}});
          RefreshRoutingSnapshot(acc);
          ok = true;
        }
      } catch (...) {
        Log("updateGroupLayout threw");
      }
      try {
        if (done) done(ok);
      } catch (...) {
      }
    });
  } catch (...) {
    Log("updateGroupLayout post failed");
    try {
      if (done) done(false);
    } catch (...) {
    }
  }
}

void LeaveGroup(const std::string& conversationId,
                const std::optional<std::string>& expectedAccountId,
                std::function<void(bool)> done) {
  try {
    const auto owner = CaptureAccountCommandOwner(expectedAccountId);
    if (!owner) { if (done) done(false); return; }
    Post([conversationId, owner = *owner, done]() {
      bool ok = false;
      try {
        const auto acc = OwnsAccountCommand(owner) ? owner.accountId : std::string{};
        const auto snapshot = RoutingSnapshot();
        if (!acc.empty() && snapshot && snapshot->account_id == acc &&
            snapshot->Group(conversationId)) {
          ok = libjami::removeConversation(acc, conversationId);
          RefreshRoutingSnapshot(acc);
        }
      } catch (...) {
        Log("leaveGroup threw");
      }
      try {
        if (done) done(ok);
      } catch (...) {
      }
    });
  } catch (...) {
    Log("leaveGroup post failed");
    try {
      if (done) done(false);
    } catch (...) {
    }
  }
}

// presence v2 zombie-janitor: beacon every connected socket (dhtnet SEND_BEACON_TIMEOUT = 3 s; a dead one is
// stopped → NewBuddyNotification flips within ~3 s). Off-label lever — connectivityChanged also resets the
// DHT/ICE caches — so the Dart side rate-limits calls (>= 60 s apart, and only on pong-timeout suspicion).
void ConnectivitySweep() {
  try {
    Post([]() {
      try {
        libjami::connectivityChanged();
        Log("connectivitySweep");
      } catch (...) {
        Log("connectivitySweep threw");
      }
    });
  } catch (...) {
    Log("connectivitySweep post failed");
  }
}

void SetAppearOffline(bool on, const std::optional<std::string>& expectedAccountId,
                      std::function<void(bool)> done) {
  try {
    const auto owner = CaptureAccountCommandOwner(expectedAccountId);
    if (!owner) {
      try { if (done) done(false); } catch (...) {}
      return;
    }
    ++g_presenceProbeEpoch;
    Post([on, owner = *owner, done]() {
      bool ok = false;
      try {
        if (OwnsAccountCommand(owner)) {
          // sendRegister toggles the PERSISTED `Account.enable` (daemon Manager::sendRegister: setEnabled +
          // saveConfig + doRegister/doUnregister, full connection shutdown when disabling) — a dark account BOOTS
          // dark. The volatile alternative (setAccountActive) is not persisted: the account would boot active and
          // announce to the DHT (proxy-held ~24 h), leaking "I'm here" on every launch while dark.
          libjami::sendRegister(owner.accountId, !on);
          (void) ActivatePreparedAccount(owner.accountId);
          g_recordingOffline.store(on);
          if (on) RecordWindowsSybLRevokeAndWait(3000);
          Log(std::string("setAppearOffline(") + (on ? "true" : "false") + ") -> sendRegister(enable=" +
              (!on ? "true" : "false") + ")");
          ok = true;
        }
      } catch (...) {
        Log("setAppearOffline threw");
      }
      try { if (done) done(ok); } catch (...) {}
    });
  } catch (...) {
    Log("setAppearOffline post failed");
    try { if (done) done(false); } catch (...) {}
  }
}

// Overwrite the connection keys for [profile] on a full account-details map. M7.5 (L3): LAN peer discovery +
// account publish broadcast our 40-hex + display name in cleartext UDP multicast, so they are enabled ONLY for
// 'lan' (see below); for LAN-only the additional lever is neutering the GLOBAL bootstrap. Mirrors Android
// JamiCore.applyConnectionProfile exactly.
static void ApplyConnectionProfile(std::map<std::string, std::string>& m, const std::string& profile,
                                   const std::string& dhtBootstrap, const std::string& turnServer,
                                   const std::string& turnRealm, const std::string& turnUser,
                                   const std::string& turnPassword) {
  using namespace libjami::Account::ConfProperties;
  // M7.5 (L3): LAN peer discovery + account publish broadcast our 40-hex + display name in CLEARTEXT over UDP
  // multicast, so enable them ONLY for 'lan' (where they're required). 'jami'/'strict' reach peers via the DHT,
  // so the LAN identity broadcast is pure leak — keep it off.
  const char* lpd = (profile == "lan") ? "true" : "false";
  m[DHT_PEER_DISCOVERY] = lpd;       // LAN multicast DHT node discovery
  m[ACCOUNT_PEER_DISCOVERY] = lpd;   // LAN multicast account (identity) discovery
  m[ACCOUNT_PUBLISH] = lpd;          // LAN multicast publish of {accountId, displayName}
  m[STUN::ENABLED] = "false";
  if (profile == "lan") {
    // Same-LAN only: an empty hostname is forced back to bootstrap.jami.net by the daemon, so neuter the global
    // bootstrap with an unreachable RFC-5737 TEST-NET addr; kill proxy/TURN/UPnP. Peers connect only via LAN
    // multicast — cross-network is blocked.
    m[HOSTNAME] = "192.0.2.1";
    m[BOOTSTRAP_LIST_URL] = "";
    m[PROXY_ENABLED] = "false";
    m[PROXY_LIST_ENABLED] = "false";
    m[PROXY_SERVER] = "";
    m[TURN::ENABLED] = "false";
    m[UPNP_ENABLED] = "false";
  } else if (profile == "strict") {
    // Zero third-party servers: bootstrap off the configured dhtnode and relay through configured coTURN.
    // A blank host uses TEST-NET because libjami otherwise silently falls back to bootstrap.jami.net.
    m[HOSTNAME] = dhtBootstrap.empty() ? "192.0.2.1" : dhtBootstrap;
    m[BOOTSTRAP_LIST_URL] = "";
    m[PROXY_ENABLED] = "false";
    m[PROXY_LIST_ENABLED] = "false";
    m[PROXY_SERVER] = "";
    m[UPNP_ENABLED] = "true";
    if (!turnServer.empty()) {
      m[TURN::ENABLED] = "true";
      m[TURN::SERVER] = turnServer;
      m[TURN::SERVER_UNAME] = turnUser;
      m[TURN::SERVER_PWD] = turnPassword;
      m[TURN::SERVER_REALM] = turnRealm.empty() ? "ring" : turnRealm;
    } else {
      m[TURN::ENABLED] = "false";
    }
  } else {  // "jami" — pragmatic v1 default: jami.net bootstrap + DHT proxy + turn.jami.net fallback (LPD off; M7.5 L3).
    m[HOSTNAME] = "bootstrap.jami.net";
    m[BOOTSTRAP_LIST_URL] = "https://config.jami.net/bootstrapList";
    m[PROXY_ENABLED] = "true";
    m[PROXY_LIST_ENABLED] = "true";
    m[PROXY_SERVER] = "dhtproxy.jami.net:[80-95]";
    m[DHT_PROXY_LIST_URL] = "https://config.jami.net/proxyList";
    m[UPNP_ENABLED] = "true";
    m[TURN::ENABLED] = "true";
    m[TURN::SERVER] = "turn.jami.net";
    m[TURN::SERVER_UNAME] = "ring";
    m[TURN::SERVER_PWD] = "ring";
    m[TURN::SERVER_REALM] = "ring";
  }
}

void SetConnectionProfile(const std::string& profile, const std::string& dhtBootstrap,
                          const std::string& turnServer, const std::string& turnRealm,
                          const std::string& turnUser, const std::string& turnPassword,
                          const std::optional<std::string>& expectedAccountId,
                          std::function<void(bool)> done) {
  try {
    const auto owner = CaptureAccountCommandOwner(expectedAccountId);
    if (!owner) {
      try { if (done) done(false); } catch (...) {}
      return;
    }
    Post([profile, dhtBootstrap, turnServer, turnRealm, turnUser, turnPassword, owner = *owner, done]() {
      bool ok = false;
      try {
        if (OwnsAccountCommand(owner)) {
          // Read the FULL details map (setAccountDetails no-ops if unchanged + expects the whole map), overwrite the
          // connection keys, set it back — the daemon doUnregister+doRegister's the account, so no explicit re-register.
          auto m = libjami::getAccountDetails(owner.accountId);
          ApplyConnectionProfile(m, profile, dhtBootstrap, turnServer, turnRealm, turnUser, turnPassword);
          if (OwnsAccountCommand(owner)) {
            libjami::setAccountDetails(owner.accountId, m);
            { std::lock_guard<std::mutex> lock(g_mutex); g_networkPreparedRevision = owner.revision; }
            (void) ActivatePreparedAccount(owner.accountId);
            Log("setConnectionProfile(" + profile + ") -> setAccountDetails (re-registers)");
            ok = true;
          }
        }
      } catch (...) {
        Log("setConnectionProfile threw");
      }
      try { if (done) done(ok); } catch (...) {}
    });
  } catch (...) {
    Log("setConnectionProfile post failed");
    try { if (done) done(false); } catch (...) {}
  }
}

void SetVideoFrameSink(VideoFrameSink sink) {
  // Entered from the runner (_HAS_EXCEPTIONS=0); the std::function copy can throw bad_alloc → firewall it. The
  // runner clears this (nullptr) on teardown BEFORE freeing the textures, so no daemon decoder thread is left
  // calling into freed channel state.
  try {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_frameSink = std::move(sink);
  } catch (...) {
    Log("setVideoFrameSink threw");
  }
}

void SetOutgoingVideoSource(const std::string& expectedCallId,
                            const std::string& kind,
                            const std::string& sourceUri,
                            int width,
                            int height,
                            std::function<void(bool)> done) {
  try {
    Post([expectedCallId, kind, sourceUri, width, height, done]() {
      std::function<void(bool)> reply = done;
      screen_source::Outgoing authoritative;
      bool emit = false;
      std::string accountId;
      // Ticket of the transition THIS invocation admitted; 0 until admitted. Only it may take, cancel or
      // roll back the pending transition below, so a rejected request never disturbs another request's.
      std::uint64_t ticket = 0;
      try {
        accountId = CurrentAccountId();
        std::string uri = sourceUri;
        auto requestedKind = screen_source::Kind::Off;
        screen_source::Outgoing requested;
        size_t cameraIndex = 0;
        {
          std::lock_guard<std::mutex> lock(g_mutex);
          cameraIndex = g_cameraIndex;
        }
        if (kind == "camera") {
          requestedKind = screen_source::Kind::Camera;
          if (sourceUri == "next") {
            const auto devices = libjami::getDeviceList();
            if (devices.size() < 2) throw std::runtime_error("no alternate camera");
            cameraIndex = (cameraIndex + 1) % devices.size();
          }
          uri = CameraMrl(cameraIndex, &cameraIndex);
        } else if (kind == "screen") {
          requestedKind = screen_source::Kind::Screen;
          if (screen_source::Classify(uri) != screen_source::Kind::Screen) uri.clear();
        } else if (kind != "off") {
          uri.clear();
        }
        if (accountId.empty() || expectedCallId.empty() ||
            (requestedKind != screen_source::Kind::Off && uri.empty())) {
          throw std::runtime_error("invalid source request");
        }
        {
          std::lock_guard<std::mutex> lock(g_mutex);
          if (!IsActiveMediaTargetLocked(expectedCallId) || g_sourceTransition) {
            throw std::runtime_error("stale or busy source request");
          }
          auto previous = g_localVideoSource;
          previous.call_id = expectedCallId;
          requested = screen_source::Outgoing{
              requestedKind, uri, expectedCallId,
              g_localVideoSource.epoch + 1, width, height};
          ticket = g_sourceTransition.Admit(PendingSourceTransition{
              {previous, requested}, g_cameraIndex, cameraIndex, accountId, nullptr});
          if (ticket == 0) throw std::runtime_error("stale or busy source request");
          g_sourceTransition->done = std::move(reply);
          // Route an early self sink to this exact transition. Rollback below restores the prior value.
          g_localVideoSource = requested;
          if (requestedKind == screen_source::Kind::Camera) g_cameraIndex = cameraIndex;
        }
        // Close control authority before asking the daemon to change the
        // shared source. Incoming control is also rejected while the source
        // transition exists, so an old revision cannot drive during
        // negotiation or rollback.
        EmitControl(ControlSignal{
            ControlSignalType::kSourceChanged,
            accountId,
            expectedCallId,
            {},
            {},
            {},
            requested.uri,
            requested.epoch,
            requested.width,
            requested.height,
            requested.kind == screen_source::Kind::Screen,
        });

        std::string mediaTarget;
        {
          std::lock_guard<std::mutex> lock(g_mutex);
          mediaTarget = MediaSignalingTargetLocked(expectedCallId);
        }
        const auto live = libjami::currentMediaList(accountId, mediaTarget);
        const bool enabled = requestedKind != screen_source::Kind::Off;
        const bool queued = libjami::requestMediaChange(
            accountId, mediaTarget, ReplaceVideoSource(live, enabled, uri));
        if (!queued) {
          std::lock_guard<std::mutex> lock(g_mutex);
          if (auto taken = g_sourceTransition.Take(ticket)) {
            auto pending = std::move(*taken);
            reply = std::move(pending.done);
            authoritative = screen_source::ResolveTransition(
                g_localVideoSource, ActiveMediaTargetLocked(), pending.source, false);
            if (screen_source::OwnsTransition(
                    g_localVideoSource, ActiveMediaTargetLocked(), pending.source)) {
              g_localVideoSource = authoritative;
              g_cameraIndex = pending.previous_camera_index;
              emit = true;
            }
          }
        } else {
          // Completion is intentionally deferred until
          // MediaNegotiationStatus confirms the actual media list.
          return;
        }
      } catch (...) {
        {
          std::lock_guard<std::mutex> lock(g_mutex);
          if (auto taken = g_sourceTransition.Take(ticket)) {
            auto pending = std::move(*taken);
            reply = std::move(pending.done);
            authoritative = screen_source::ResolveTransition(
                g_localVideoSource, ActiveMediaTargetLocked(), pending.source, false);
            if (screen_source::OwnsTransition(
                    g_localVideoSource, ActiveMediaTargetLocked(), pending.source)) {
              g_localVideoSource = authoritative;
              g_cameraIndex = pending.previous_camera_index;
              emit = true;
            }
          }
        }
        Log("setOutgoingVideoSource failed");
      }
      if (emit) EmitOutgoingVideoSource(accountId, authoritative);
      try {
        if (reply) reply(false);
      } catch (...) {
      }
    });
  } catch (...) {
    try {
      if (done) done(false);
    } catch (...) {
    }
  }
}

void StartVideo(const std::string& expectedCallId, std::function<void(bool)> done) {
  SetOutgoingVideoSource(expectedCallId, "camera", "", 0, 0, std::move(done));
}

void StopVideo(const std::string& expectedCallId, std::function<void(bool)> done) {
  SetOutgoingVideoSource(expectedCallId, "off", "", 0, 0, std::move(done));
}

void SwitchCamera(const std::string& expectedCallId, std::function<void(bool)> done) {
  SetOutgoingVideoSource(expectedCallId, "camera", "next", 0, 0, std::move(done));
}

// ---- file transfer (M5): SendFile / AcceptFile / CancelFile / FileInfoQuery ----

void SendFile(const std::string& peerJamiId, const std::string& conversationId,
              const std::string& path, const std::string& name,
              const std::string& topicId, std::function<void(bool)> done) {
  try {
    Post([peerJamiId, conversationId, path, name, topicId, done]() {
      bool ok = false;
      try {
        const std::string acc = CurrentAccountId();
        const auto peer = NormalizeOwnerKey(peerJamiId);
        const auto snapshot = RoutingSnapshot();
        if (acc.empty() || !snapshot || !snapshot->Owns(peer, conversationId) ||
            !sybl::dm_topic::IsValidOutgoingTopic(topicId)) {
          Log("sendFile: no account/conversation");
        } else {
          std::string display = name;
          if (display.empty()) {
            auto slash = path.find_last_of("/\\");
            display = (slash == std::string::npos) ? path : path.substr(slash + 1);
          }
          const auto staged = StageOutgoingFile(path);
          if (staged.empty()) {
            Log("sendFile: persistent staging failed");
          } else {
            const auto staged_utf8 = ToUtf8(staged.wstring());
            try {
              {
                std::lock_guard<std::mutex> lock(g_mutex);
                g_outgoingStagingPaths.insert(staged_utf8);
              }
              libjami::sendFile(
                  acc, conversationId, staged_utf8, display, std::string(),
                  topicId);
              Log("sendFile: issuing publication");
              ok = true;
            } catch (...) {
              {
                std::lock_guard<std::mutex> lock(g_mutex);
                g_outgoingStagingPaths.erase(staged_utf8);
              }
              sybl::picked_file::Discard(staged, OutgoingDir());
              throw;
            }
          }
        }
      } catch (...) {
        Log("sendFile threw");
      }
      try { if (done) done(ok); } catch (...) {}
    });
  } catch (...) {
    Log("sendFile post failed");
    try { if (done) done(false); } catch (...) {}
  }
}

void AcceptFile(const std::string& peerJamiId, const std::string& conversationId,
                const std::string& interactionId, const std::string& fileId, const std::string& name,
                int64_t maxBytes, const std::string& attemptId, std::function<void(bool)> done) {
  const auto owner = CaptureAccountCommandOwner(std::nullopt);
  if (!owner || attemptId.size() != 32 || !std::all_of(attemptId.begin(), attemptId.end(),
      [](char c) { return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'); })) {
    if (done) done(false);
    return;
  }
  try {
    Post([peerJamiId, conversationId, interactionId, fileId, name, maxBytes, attemptId, owner = *owner, done]() {
      bool ok = false;
      try {
        if (!OwnsAccountCommand(owner)) { if (done) done(false); return; }
        const std::string acc = owner.accountId;
        const auto peer = NormalizeOwnerKey(peerJamiId);
        const FileKey key{peer, conversationId, fileId};
        int64_t declaredSize = -1;
        std::optional<std::string> mediaMetadata;
        {
          std::lock_guard<std::mutex> lock(g_mutex);
          if (g_receiveAttempts.count(key)) { if (done) done(false); return; }
          g_receiveAttempts.emplace(key, attemptId);
          auto size = g_fileSizes.find(key);
          if (size != g_fileSizes.end()) declaredSize = size->second;
          const auto media = g_fileMediaMetadata.find(key);
          if (media != g_fileMediaMetadata.end()) mediaMetadata = media->second;
        }
        const auto snapshot = RoutingSnapshot();
        if (acc.empty() || !snapshot || !snapshot->Owns(peer, conversationId)) {
          Log("acceptFile: no account/conversation");
        } else if (maxBytes < 0 ||
                   (maxBytes > 0 && (declaredSize < 0 || declaredSize > maxBytes))) {
          Log("acceptFile: invalid cap or unavailable/excessive declared size");
        } else {
          std::string dest;
          if (mediaMetadata) {
            Json::CharReaderBuilder builder;
            builder["rejectDupKeys"] = true;
            builder["failIfExtra"] = true;
            builder["allowComments"] = false;
            const std::unique_ptr<Json::CharReader> reader(builder.newCharReader());
            Json::Value metadata;
            std::string errors;
            if (!reader->parse(mediaMetadata->data(), mediaMetadata->data() + mediaMetadata->size(),
                               &metadata, &errors) || !metadata.isObject() ||
                !metadata["v"].isInt() || metadata["v"].asInt() != 1 ||
                !metadata["kind"].isString()) throw std::runtime_error("invalid received media");
            const auto kind = metadata["kind"].asString();
            const int64_t cap = kind == "gif" ? 4 * 1024 * 1024 : 2 * 1024 * 1024;
            if ((kind != "gif" && kind != "voice") || declaredSize <= 0 || declaredSize > cap)
              throw std::runtime_error("invalid received media size");
            const auto staging = sybl::picked_file::DefaultStagingRoot();
            if (!staging) throw std::runtime_error("private receive unavailable");
            const auto root = staging->parent_path() / L"Syb-L Received Media";
            {
              std::lock_guard<std::mutex> lock(g_mutex);
              const auto prior = g_receiveDestByFile.find(key);
              if (prior != g_receiveDestByFile.end()) dest = prior->second;
            }
            if (!dest.empty()) {
              if (!sybl::picked_file::IsOwned(std::filesystem::u8path(dest), root))
                throw std::runtime_error("private receive owner lost");
            } else {
              const auto output = sybl::picked_file::ReserveReceivedMediaOutput(root, kind == "gif", false);
              if (!output) throw std::runtime_error("private receive unavailable");
              dest = ToUtf8(output->wstring());
              std::lock_guard<std::mutex> lock(g_mutex);
              g_receiveDestByFile[key] = dest;
              g_reservedReceivePaths.insert(ReceiveReservationKey(output->wstring()));
            }
          } else {
            dest = ReceiveDestPath(key, name);
          }
          if (dest.empty()) {
            Log("acceptFile: no download dir");
          } else {
            ok = OwnsAccountCommand(owner) && libjami::downloadSybLFile(acc, conversationId, interactionId, fileId, dest, attemptId);
            Log(ok ? "downloadFile accepted" : "downloadFile refused");

          }
        }
      } catch (...) {
        Log("acceptFile threw");

      }
      if (!ok) {
        std::lock_guard<std::mutex> lock(g_mutex);
        const FileKey key{NormalizeOwnerKey(peerJamiId), conversationId, fileId};
        const auto found = g_receiveAttempts.find(key);
        if (owner.accountId == g_accountId && owner.revision == g_accountRevision &&
            found != g_receiveAttempts.end() && found->second == attemptId) {
          g_receiveAttempts.erase(found);
          ReleaseReceiveReservationLocked(key);
        }
      }
      try { if (done) done(ok); } catch (...) {}
    });
  } catch (...) {
    Log("acceptFile post failed");
    try { if (done) done(false); } catch (...) {}
  }
}

void OpenReceivedFile(const std::string& path, std::function<void(bool)> done) {
  bool opened = false;
  try {
    const auto base = std::filesystem::path(ReceiveDirW());
    const auto candidate = std::filesystem::u8path(path);
    std::error_code ec_base, ec_file;
    const auto canonical_base =
        std::filesystem::weakly_canonical(base, ec_base).wstring();
    const auto canonical_file = std::filesystem::canonical(candidate, ec_file);
    const auto file_w = canonical_file.wstring();
    const bool under =
        !ec_base && !ec_file && !canonical_base.empty() &&
        file_w.size() > canonical_base.size() &&
        file_w.compare(0, canonical_base.size(), canonical_base) == 0 &&
        (file_w[canonical_base.size()] == L'\\' ||
         file_w[canonical_base.size()] == L'/') &&
        std::filesystem::is_regular_file(canonical_file);
    if (under) {
      const auto result = reinterpret_cast<intptr_t>(
          ShellExecuteW(nullptr, L"open", file_w.c_str(), nullptr, nullptr,
                        SW_SHOWNORMAL));
      opened = result > 32;
    }
  } catch (...) {
    opened = false;
  }
  try {
    if (done) done(opened);
  } catch (...) {
  }
}

void CancelFile(const std::string& peerJamiId, const std::string& conversationId,
                const std::string& fileId, const std::string& attemptId,
                std::function<void(bool)> done) {
  const auto owner = CaptureAccountCommandOwner(std::nullopt);
  if (!owner) { if (done) done(false); return; }
  try {
    Post([peerJamiId, conversationId, fileId, attemptId, owner = *owner, done]() {
      bool ok = false;
      try {
        const FileKey key{NormalizeOwnerKey(peerJamiId), conversationId, fileId};
        const auto snapshot = RoutingSnapshot();
        bool matches = false;
        {
          std::lock_guard<std::mutex> lock(g_mutex);
          const auto found = g_receiveAttempts.find(key);
          matches = attemptId.empty() ? found == g_receiveAttempts.end() :
              found != g_receiveAttempts.end() && found->second == attemptId;
        }
        if (matches && OwnsAccountCommand(owner) && !fileId.empty() && snapshot &&
            snapshot->Owns(key.peerId, conversationId)) {
          ok = (attemptId.empty()
              ? libjami::cancelDataTransfer(owner.accountId, conversationId, fileId)
              : libjami::cancelSybLFile(owner.accountId, conversationId, fileId, attemptId)) ==
              libjami::DataTransferError::success;
          if (ok && !attemptId.empty()) {
            std::lock_guard<std::mutex> lock(g_mutex);
            const auto found = g_receiveAttempts.find(key);
            if (owner.accountId == g_accountId && owner.revision == g_accountRevision &&
                found != g_receiveAttempts.end() && found->second == attemptId) {
              g_receiveAttempts.erase(found);
              ReleaseReceiveReservationLocked(key);
            }
          }
        }
      } catch (...) { Log("cancelFile threw"); }
      try { if (done) done(ok); } catch (...) {}
    });
  } catch (...) {
    Log("cancelFile post failed");
    try { if (done) done(false); } catch (...) {}
  }
}

// M8: send the in-call annotation payload to the peer on `callId`. Wraps the JSON under our custom MIME and calls
// libjami sendTextMessage (the in-dialog SIP MESSAGE path). Worker thread + firewall, mirroring CancelFile.
bool SendCallMessage(const std::string& callId, const std::string& payload,
                     const std::string& channel) {
  if (callId.empty() || payload.empty() ||
      payload.size() > kMaxTypedCallMessageBytes ||
      (channel != "control" && channel != "annotation")) {
    return false;
  }
  // Reject an already-stale call synchronously. The worker repeats this gate
  // immediately before libjami because the call can still end after this
  // snapshot. libjami exposes no delivery ACK, so true means only that a
  // bounded packet for the exact authoritative call entered our worker.
  std::string account;
  std::string peer;
  uint64_t trust_epoch = 0;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    const auto admitted = g_callPeers.find(callId);
    if (!g_running || g_accountId.empty() ||
        !IsAuthoritativeCallLocked(callId) || admitted == g_callPeers.end() ||
        !g_routingSnapshot || !g_routingSnapshot->IsTrusted(admitted->second)) {
      return false;
    }
    const auto epoch = g_controlTrustEpochs.find(admitted->second);
    if (epoch == g_controlTrustEpochs.end()) return false;
    account = g_accountId;
    peer = admitted->second;
    trust_epoch = epoch->second;
  }
  try {
    Post([account, peer, trust_epoch, callId, payload, channel]() {
      try {
        {
          std::lock_guard<std::mutex> lock(g_mutex);
          const auto admitted = g_callPeers.find(callId);
          const auto epoch = g_controlTrustEpochs.find(peer);
          if (account != g_accountId ||
              !IsAuthoritativeCallLocked(callId) || admitted == g_callPeers.end() ||
              admitted->second != peer || epoch == g_controlTrustEpochs.end() ||
              epoch->second != trust_epoch ||
              !g_routingSnapshot || !g_routingSnapshot->IsTrusted(admitted->second)) {
            return;
          }
        }
        const char* mime = channel == "control" ? kControlMime :
                           channel == "annotation" ? kAnnotMime : nullptr;
        if (!mime) return;
        std::map<std::string, std::string> msg{{mime, payload}};
        libjami::sendTextMessage(account, callId, msg, std::string(), false);  // from="" , isMixed=false (1:1, in-call)
      } catch (...) {
        Log("sendCallMessage threw");
      }
    });
  } catch (...) {
    Log("sendCallMessage post failed");
    return false;
  }
  return true;
}

void FileInfoQuery(const std::string& peerJamiId, const std::string& conversationId,
                   const std::string& fileId, std::function<void(const FileInfo&)> done) {
  try {
    Post([peerJamiId, conversationId, fileId, done]() {
      FileInfo info;
      try {
        const std::string acc = CurrentAccountId();
        const auto snapshot = RoutingSnapshot();
        if (!acc.empty() && snapshot && snapshot->Owns(peerJamiId, conversationId)) {
          std::string path;
          int64_t total = 0, progress = 0;
          libjami::fileTransferInfo(acc, conversationId, fileId, path, total, progress);
          info.transferred = progress;
          info.total = total;
          int64_t completedSize = 0;
          info.completed = libjami::fileTransferCompleted(acc, conversationId, fileId, path, completedSize);
          if (info.completed) {
            info.total = completedSize;
            info.transferred = completedSize;
            info.path = path;
          }
        }
      } catch (...) {
        Log("fileInfo threw");
      }
      try { if (done) done(info); } catch (...) {}
    });
  } catch (...) {
    Log("fileInfo post failed");
    try { if (done) done(FileInfo{}); } catch (...) {}
  }
}

static std::uint32_t StartConversationLoad(
    const std::string& account, sybl::conversation::PendingLoad pending,
    const char* operation) {
  std::lock_guard<std::mutex> registrationLock(g_loadRegistrationMutex);
  bool canStart;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    canStart = g_conversationLoads.CanStart();
  }
  if (!canStart) {
    Log(std::string(operation) + ": pending-load registry is full");
    return 0;
  }
  const auto id = libjami::loadConversation(
      account, pending.conversation_id, pending.cursor,
      static_cast<std::size_t>(pending.limit));
  if (id == 0) return 0;
  std::lock_guard<std::mutex> lock(g_mutex);
  return g_conversationLoads.Register(id, std::move(pending)) ? id : 0;
}

void LoadFolder(const std::string& peerJamiId, const std::string& conversationId, int keepLast,
                std::function<void(uint32_t)> done) {
  try {
    Post([peerJamiId, conversationId, keepLast, done]() {
      uint32_t loadId = 0;
      try {
        const std::string acc = CurrentAccountId();
        const auto peer = NormalizeOwnerKey(peerJamiId);
        const auto snapshot = RoutingSnapshot();
        if (acc.empty() || !snapshot || !snapshot->Owns(peer, conversationId) ||
            !sybl::timeline::IsRequiredUtf8(
                acc, sybl::timeline::kMaxDaemonIdCodeUnits) ||
            !sybl::timeline::IsRequiredUtf8(
                peer, sybl::timeline::kMaxAuthorIdCodeUnits) ||
            !sybl::timeline::IsRequiredUtf8(
                conversationId, sybl::timeline::kMaxDaemonIdCodeUnits)) {
          Log("loadFolder: no account/conversation yet");
        } else {
          int n;
          {
            std::lock_guard<std::mutex> lock(g_mutex);
            if (keepLast > 5000) {
              n = 0;
            } else {
              if (keepLast > 0) g_folderKeepLast = keepLast;
              n = g_folderKeepLast;
            }
          }
          if (n <= 0) {
            Log("loadFolder: retention exceeds native bound");
          } else {
            // The reply arrives on SwarmLoaded and is emitted as one correlated atomic folderSnapshot.
            loadId = StartConversationLoad(
                acc, sybl::conversation::PendingLoad{
                         sybl::conversation::LoadKind::kFolder, peer,
                         conversationId, std::string(), n},
                "loadFolder");
          }
          Log("loadFolder(" + conversationId + ") n=" + std::to_string(n));
        }
      } catch (...) {
        Log("loadFolder threw");
      }
      try { if (done) done(loadId); } catch (...) {}
    });
  } catch (...) {
    Log("loadFolder post failed");
    try { if (done) done(0); } catch (...) {}
  }
}

void SendOwnedFile(const std::string& accountId, const std::string& peerJamiId,
                   const std::string& conversationId, const std::string& path,
                   const std::string& name, const std::string& topicId,
                   const std::string& roomId, const std::string& media,
                   const std::string& operationId,
                   std::function<void(const std::string&)> done) {
  try {
    const auto captured = CaptureAccountCommandOwner(accountId);
    if (!captured) { if (done) done("failed-before-commit"); return; }
    Post([owner = *captured, peerJamiId, conversationId, path, name,
          topicId, roomId, media, operationId, done]() {
      std::string outcome = "failed-before-commit";
      bool issued = false;
      try {
        const auto peer = NormalizeOwnerKey(peerJamiId);
        const auto routing = RoutingSnapshot();
        const auto root = sybl::picked_file::DefaultStagingRoot();
        const bool group = sybl::routing::GroupConversationId(peer).has_value();
        bool priorAdmission = false;
        {
          std::lock_guard<std::mutex> lock(g_mutex);
          auto& registry = StageRegistryLocked();
          priorAdmission = !registry.healthy() || registry.Find(operationId).has_value();
        }
        if (priorAdmission) outcome = "unknown";
        bool eligible = !priorAdmission && OwnsAccountCommand(owner) && routing && routing->Owns(peer, conversationId) &&
            root && path.size() <= 32768 && name.size() <= 1024 && media.size() <= 1024 &&
            sybl::picked_file::IsOwned(std::filesystem::u8path(path), *root) &&
            sybl::dm_topic::IsValidOutgoingTopic(topicId) &&
            (group ? topicId.empty() : roomId.empty()) && operationId.size() == 32 &&
            std::all_of(operationId.begin(), operationId.end(), [](char c) {
              return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
            });
        if (eligible) {
          const auto details = libjami::getAccountDetails(owner.accountId);
          const auto enabled = details.find("Account.enable");
          eligible = enabled != details.end() && enabled->second == "true";
        }
        if (eligible) {
          std::lock_guard<std::mutex> lock(g_mutex);
          eligible = !g_identityActivationPending && !g_pendingRestoreBlocked &&
              owner.accountId == g_accountId && owner.revision == g_accountRevision;
          if (eligible) {
            const bool pathOwned = std::any_of(g_ownedFiles.begin(), g_ownedFiles.end(),
                [&path](const auto& entry) { return entry.second.path == path; });
            if (g_ownedFiles.size() >= 256 || g_ownedFiles.count(operationId) ||
                g_ownedMessages.count(operationId) || g_completedMessageIds.count(operationId) || pathOwned) {
              eligible = false;
              outcome = "unknown";
            } else {
              eligible = StageRegistryLocked().Issue(
                  {path, owner.accountId, peer, conversationId, operationId, false});
              if (eligible)
                g_ownedFiles.emplace(operationId, OwnedFileOperation{{owner, peer, conversationId}, path});
            }
          }
        }
        if (eligible) {
          issued = true;
          outcome = libjami::sendSybLFile(owner.accountId, conversationId, path, name,
                                         topicId, roomId, media, operationId);
          if (outcome == "failed-before-commit") {
            std::lock_guard<std::mutex> lock(g_mutex);
            const auto found = g_ownedFiles.find(operationId);
            if (found != g_ownedFiles.end() && found->second.commit.empty()) {
              StageRegistryLocked().Forget(path);
              g_ownedFiles.erase(found);
            }
          }
        }
      } catch (...) { outcome = issued ? "unknown" : "failed-before-commit"; }
      try { if (done) done(outcome); } catch (...) {}
    });
  } catch (...) { try { if (done) done("unknown"); } catch (...) {} }
}

void AcknowledgeFileSeed(const std::string& accountId, const std::string& operationId,
                         const std::string& commitId, const std::string& conversationId,
                         std::function<void(bool)> done) {
  try {
    const auto captured = CaptureAccountCommandOwner(accountId);
    if (!captured) { if (done) done(false); return; }
    Post([owner = *captured, operationId, commitId, conversationId, done]() {
      bool ok = false;
      try {
        if (!OwnsAccountCommand(owner)) { if (done) done(false); return; }
        std::optional<sybl::stage::Record> record;
        {
          std::lock_guard<std::mutex> lock(g_mutex);
          auto& registry = StageRegistryLocked();
          if (!registry.healthy()) { if (done) done(false); return; }
          record = registry.Find(operationId);
        }
        if (record && (record->account != owner.accountId || record->conversation != conversationId)) {
          if (done) done(false); return;
        }
        const auto root = sybl::picked_file::DefaultStagingRoot();
        const bool sourceOwned = record && root &&
            sybl::picked_file::IsOwned(std::filesystem::u8path(record->path), *root);
        // Signed Jami metadata, including local authorship and operation ID,
        // authorizes only the original immutable seed. No message is sent here.
        if (libjami::repairSybLFileSeed(owner.accountId, conversationId, operationId,
                                      commitId, sourceOwned ? record->path : "") && OwnsAccountCommand(owner)) {
          std::lock_guard<std::mutex> lock(g_mutex);
          ok = !record;
          if (record && root) {
            const auto path = std::filesystem::u8path(record->path);
            std::error_code error;
            const auto status = std::filesystem::symlink_status(path, error);
            const bool absent = status.type() == std::filesystem::file_type::not_found &&
                (!error || error == std::errc::no_such_file_or_directory);
            if (absent || sybl::picked_file::Discard(path, *root))
              ok = StageRegistryLocked().Forget(record->path);
          }
          if (ok) g_ownedFiles.erase(operationId);
        }
      } catch (...) {}
      try { if (done) done(ok); } catch (...) {}
    });
  } catch (...) { try { if (done) done(false); } catch (...) {} }
}

void SendOwnedReaction(const std::string& accountId, const std::string& peerJamiId,
                       const std::string& conversationId, const std::string& messageId,
                       const std::string& removedId, const std::string& emoji,
                       const std::string& topicId, const std::string& roomId,
                       const std::string& operationId,
                       std::function<void(const std::string&)> done) {
  try {
    const auto captured = CaptureAccountCommandOwner(accountId);
    if (!captured) { if (done) done("failed-before-commit"); return; }
    Post([owner = *captured, peerJamiId, conversationId, messageId, removedId, emoji,
          topicId, roomId, operationId, done]() {
      std::string outcome = "failed-before-commit";
      bool issued = false;
      try {
        const auto peer = NormalizeOwnerKey(peerJamiId);
        const auto routing = RoutingSnapshot();
        const bool group = sybl::routing::GroupConversationId(peer).has_value();
        bool eligible = OwnsAccountCommand(owner) && routing && routing->Owns(peer, conversationId) &&
            sybl::reaction::Identity(messageId) && sybl::reaction::Identity(conversationId) &&
            (removedId.empty() ? sybl::reaction::Supported(emoji) :
                (sybl::reaction::Identity(removedId) && removedId != messageId && emoji.empty())) &&
            sybl::dm_topic::IsValidOutgoingTopic(topicId) &&
            (group ? (topicId.empty() && !roomId.empty()) : (roomId.empty() && !topicId.empty())) &&
            operationId.size() == 32 && std::all_of(operationId.begin(), operationId.end(), [](char c) {
              return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
            });
        if (eligible) {
          const auto details = libjami::getAccountDetails(owner.accountId);
          const auto enabled = details.find("Account.enable");
          eligible = enabled != details.end() && enabled->second == "true";
        }
        if (eligible) {
          std::lock_guard<std::mutex> lock(g_mutex);
          eligible = !g_identityActivationPending && !g_pendingRestoreBlocked &&
              owner.accountId == g_accountId && owner.revision == g_accountRevision;
          if (eligible) {
            if (g_ownedMessages.size() >= 256 || g_ownedMessages.count(operationId) || g_completedMessageIds.count(operationId)) {
              outcome = "unknown";
              eligible = false;
            } else {
              g_ownedMessages.emplace(operationId, OwnedMessageOperation{owner, peer, conversationId});
            }
          }
        }
        if (eligible) {
          issued = true;
          outcome = libjami::sendSybLReaction(owner.accountId, conversationId, messageId,
              removedId, emoji, topicId, roomId, operationId);
          if (outcome == "failed-before-commit") CompleteOwnedMessage(owner.accountId, conversationId, operationId);
        }
      } catch (...) { outcome = issued ? "unknown" : "failed-before-commit"; }
      try { if (done) done(outcome); } catch (...) {}
    });
  } catch (...) { try { if (done) done("unknown"); } catch (...) {} }
}

void SendOwnedMessage(const std::string& accountId, const std::string& peerJamiId,
                      const std::string& conversationId, const std::string& mimeType,
                      const std::string& body, const std::string& replyTo,
                      const std::string& topicId, const std::string& roomId,
                      const std::string& operationId,
                      std::function<void(const std::string&)> done) {
  try {
    const auto captured = CaptureAccountCommandOwner(accountId);
    if (!captured) { if (done) done("failed-before-commit"); return; }
    Post([owner = *captured, peerJamiId, conversationId, mimeType, body, replyTo,
          topicId, roomId, operationId, done]() {
      std::string outcome = "failed-before-commit";
      bool issued = false;
      try {
        const auto peer = NormalizeOwnerKey(peerJamiId);
        const auto routing = RoutingSnapshot();
        const bool group = sybl::routing::GroupConversationId(peer).has_value();
        bool eligible = OwnsAccountCommand(owner) && routing && routing->Owns(peer, conversationId) &&
            sybl::timeline::IsRequiredUtf8(body, sybl::timeline::kMaxTextCodeUnits) &&
            sybl::timeline::IsOptionalUtf8(replyTo, sybl::timeline::kMaxDaemonIdCodeUnits) &&
            sybl::dm_topic::IsValidOutgoingTopic(topicId) &&
            (group ? topicId.empty() : roomId.empty()) && operationId.size() == 32 &&
            std::all_of(operationId.begin(), operationId.end(), [](char c) {
              return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
            });
        if (eligible && group && mimeType == "application/x-sybl-sticker+json") {
          Json::CharReaderBuilder builder;
          builder["failIfExtra"] = true;
          builder["rejectDupKeys"] = true;
          builder["stackLimit"] = 8;
          const std::unique_ptr<Json::CharReader> reader(builder.newCharReader());
          Json::Value value;
          eligible = body.size() <= 1024 && reader->parse(body.data(), body.data() + body.size(), &value, nullptr) &&
              value.isObject() && value["presentation"].isString() && value["presentation"].asString() == "inline";
        }
        if (eligible) {
          const auto details = libjami::getAccountDetails(owner.accountId);
          const auto enabled = details.find("Account.enable");
          eligible = enabled != details.end() && enabled->second == "true";
        }
        if (eligible) {
          std::lock_guard<std::mutex> lock(g_mutex);
          eligible = !g_identityActivationPending && !g_pendingRestoreBlocked &&
              owner.accountId == g_accountId && owner.revision == g_accountRevision;
          if (eligible) {
            if (g_ownedMessages.size() >= 256 || g_ownedMessages.count(operationId) || g_completedMessageIds.count(operationId)) {
              outcome = "unknown";
              eligible = false;
            } else {
              g_ownedMessages.emplace(operationId, OwnedMessageOperation{owner, peer, conversationId});
            }
          }
        }
        if (eligible) {
          issued = true;
          outcome = libjami::sendSybLMessage(owner.accountId, conversationId, mimeType, body,
                                            replyTo, topicId, roomId, operationId);
          if (outcome == "failed-before-commit") CompleteOwnedMessage(owner.accountId, conversationId, operationId);
        }
      } catch (...) {
        outcome = issued ? "unknown" : "failed-before-commit";
      }
      try { if (done) done(outcome); } catch (...) {}
    });
  } catch (...) {
    try { if (done) done("unknown"); } catch (...) {}
  }
}

void SendChatMessage(const std::string& peerJamiId, const std::string& conversationId,
                     const std::string& body, const std::string& replyTo,
                     const std::string& topicId,
                     std::function<void(bool)> done) {
  try {
    Post([peerJamiId, conversationId, body, replyTo, topicId, done]() {
      bool ok = false;
      try {
        const std::string acc = CurrentAccountId();
        const std::string peer = NormalizeOwnerKey(peerJamiId);
        const auto snapshot = RoutingSnapshot();
        if (!acc.empty() && snapshot && snapshot->Owns(peer, conversationId) &&
            sybl::timeline::IsRequiredUtf8(
                acc, sybl::timeline::kMaxDaemonIdCodeUnits) &&
            sybl::timeline::IsRequiredUtf8(
                peer, sybl::timeline::kMaxAuthorIdCodeUnits) &&
            sybl::timeline::IsRequiredUtf8(
                conversationId, sybl::timeline::kMaxDaemonIdCodeUnits) &&
            sybl::timeline::IsRequiredUtf8(
                body, sybl::timeline::kMaxTextCodeUnits) &&
            sybl::timeline::IsOptionalUtf8(
                replyTo, sybl::timeline::kMaxDaemonIdCodeUnits) &&
            sybl::dm_topic::IsValidOutgoingTopic(topicId)) {
          ok = !libjami::sendMessageWithId(
                    acc, conversationId, body, replyTo, topicId)
                    .empty();
        }
      } catch (...) {
        Log("sendChatMessage threw");
      }
      try { if (done) done(ok); } catch (...) {}
    });
  } catch (...) {
    Log("sendChatMessage post failed");
    try { if (done) done(false); } catch (...) {}
  }
}

void SendDmTopicEvent(const std::string& peerJamiId,
                      const std::string& conversationId,
                      const std::string& body,
                      std::function<void(const std::string&)> done) {
  try {
    Post([peerJamiId, conversationId, body, done]() {
      std::string commitId;
      try {
        const auto acc = CurrentAccountId();
        const auto peer = NormalizeOwnerKey(peerJamiId);
        const auto snapshot = RoutingSnapshot();
        if (!acc.empty() && snapshot && snapshot->Owns(peer, conversationId) &&
            !snapshot->Group(conversationId) && !body.empty() &&
            body.size() <= sybl::dm_topic::kMaxEventBytes &&
            sybl::timeline::IsRequiredUtf8(
                acc, sybl::timeline::kMaxDaemonIdCodeUnits) &&
            sybl::timeline::IsRequiredUtf8(
                peer, sybl::timeline::kMaxAuthorIdCodeUnits) &&
            sybl::timeline::IsRequiredUtf8(
                conversationId, sybl::timeline::kMaxDaemonIdCodeUnits)) {
          commitId = libjami::sendSybLTopicEventWithId(
              acc, conversationId, body);
        }
      } catch (...) {
        Log("sendDmTopicEvent threw");
      }
      try {
        if (done) done(commitId);
      } catch (...) {
      }
    });
  } catch (...) {
    Log("sendDmTopicEvent post failed");
    try {
      if (done) done({});
    } catch (...) {
    }
  }
}

void SetMessageDisplayed(const std::string& peerJamiId,
                         const std::string& conversationId,
                         const std::string& messageId,
                         std::function<void(bool)> done) {
  try {
    Post([peerJamiId, conversationId, messageId, done]() {
      bool ok = false;
      try {
        const auto acc = CurrentAccountId();
        const auto peer = NormalizeOwnerKey(peerJamiId);
        const auto snapshot = RoutingSnapshot();
        if (!acc.empty() && snapshot && snapshot->Owns(peer, conversationId) &&
            sybl::timeline::IsRequiredUtf8(
                messageId, sybl::timeline::kMaxDaemonIdCodeUnits)) {
          ok = libjami::setMessageDisplayed(
              acc, "swarm:" + conversationId, messageId, 3);
        }
      } catch (...) {
        Log("setMessageDisplayed threw");
      }
      try { if (done) done(ok); } catch (...) {}
    });
  } catch (...) {
    Log("setMessageDisplayed post failed");
    try { if (done) done(false); } catch (...) {}
  }
}

bool HistorySearchReplyCurrent(const HistorySearchReply& reply) {
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (reply.accountId != g_accountId || reply.accountRevision != g_accountRevision ||
        reply.privacyEpoch != g_historySearchEpoch || g_identityActivationPending || g_pendingRestoreBlocked)
      return false;
  }
  const auto routing = RoutingSnapshot();
  return routing && routing->Owns(reply.peerId, reply.conversationId);
}

void RetireHistorySearch(const std::string& accountId) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (!accountId.empty() && accountId == g_accountId) RetireSearchLocked();
}

void SearchHistory(const std::string& accountId, const std::string& peerId,
                   const std::string& conversationId, const std::string& literal, int limit,
                   std::function<void(std::optional<HistorySearchReply>)> done) {
  try {
    const auto owner = CaptureAccountCommandOwner(accountId);
    const auto pattern = sybl::history_search::LiteralPattern(literal);
    if (!owner || !pattern || limit < 1 || limit > 200 ||
        !sybl::history_search::HexId(conversationId, 40)) {
      if (done) done(std::nullopt);
      return;
    }
    uint64_t epoch;
    { std::lock_guard<std::mutex> lock(g_mutex); epoch = g_historySearchEpoch; }
    Post([owner = *owner, peerId, conversationId, literal, pattern = *pattern, limit, epoch, done] {
      std::shared_ptr<HistorySearchEntry> entry;
      bool issued = false;
      try {
        const auto peer = NormalizeOwnerKey(peerId);
        const auto routing = RoutingSnapshot();
        bool eligible = OwnsAccountCommand(owner) && routing && routing->Owns(peer, conversationId);
        if (eligible) {
          std::lock_guard<std::mutex> lock(g_mutex);
          eligible = !g_historySearch && epoch == g_historySearchEpoch &&
              epoch != std::numeric_limits<uint64_t>::max() &&
              !g_identityActivationPending && !g_pendingRestoreBlocked;
          if (eligible) {
            entry = std::make_shared<HistorySearchEntry>();
            entry->owner = owner; entry->peer = peer; entry->conversation = conversationId;
            entry->epoch = epoch; entry->done = done;
            entry->request = std::make_shared<sybl::history_search::Request>(owner.accountId,
                conversationId, sybl::routing::GroupConversationId(peer).has_value(), literal, limit);
            g_historySearch = entry;
          }
        }
        if (!entry) { try { if (done) done(std::nullopt); } catch (...) {} return; }
        issued = true;
        const auto id = libjami::searchConversation(owner.accountId, conversationId, "", "", pattern, "",
                                                   0, 0, static_cast<uint32_t>(limit + 1), 0);
        {
          std::lock_guard<std::mutex> lock(g_mutex);
          entry->nativeId = id;
          if (id == 0) g_historySearch.reset();
        }
        if (id != 0) return;
      } catch (...) {
        // Uncertain admission retains the slot until an actual terminal callback.
        if (entry) entry->request->Retire();
        if (!issued) { std::lock_guard<std::mutex> lock(g_mutex); if (g_historySearch == entry) g_historySearch.reset(); }
      }
      if (entry) entry->delivered = true;
      try { if (done) done(std::nullopt); } catch (...) {}
    });
  } catch (...) { try { if (done) done(std::nullopt); } catch (...) {} }
}

bool SearchMessageReplyCurrent(const SearchMessageReply& reply) {
  const sybl::history_search::MessageLoadTicket ticket{reply.accountId, reply.peerId, reply.conversationId,
                                                       reply.messageId, reply.accountRevision, reply.privacyEpoch};
  return sybl::history_search::MessageLoadCurrent(ticket, SearchMessageFacts(ticket));
}

void LoadSearchMessage(const std::string& accountId, const std::string& peerId,
                       const std::string& conversationId, const std::string& messageId,
                       std::function<void(std::optional<SearchMessageReply>)> done) {
  try {
    const auto owner = CaptureAccountCommandOwner(accountId);
    if (!owner) {
      if (done) done(std::nullopt);
      return;
    }
    uint64_t epoch;
    { std::lock_guard<std::mutex> lock(g_mutex); epoch = g_historySearchEpoch; }
    Post([ticket = sybl::history_search::MessageLoadTicket{owner->accountId, peerId, conversationId, messageId,
                                                           owner->revision, epoch},
          done]() mutable {
      try {
        ticket.peer_id = NormalizeOwnerKey(ticket.peer_id);
        std::lock_guard<std::mutex> registrationLock(g_loadRegistrationMutex);
        const auto facts = SearchMessageFacts(ticket);
        bool canStart = false;
        {
          std::lock_guard<std::mutex> lock(g_mutex);
          canStart = g_conversationLoads.CanStart();
        }
        if (sybl::history_search::AdmitMessageLoad(ticket, facts, canStart)) {
          const auto loadId = libjami::loadSybLMessage(ticket.account_id, ticket.conversation_id, ticket.message_id);
          std::lock_guard<std::mutex> lock(g_mutex);
          if (loadId != 0 &&
              g_searchMessageLoads.Register(
                  g_conversationLoads, loadId,
                  sybl::conversation::PendingLoad{sybl::conversation::LoadKind::kSearchMessage, ticket.peer_id,
                                                  ticket.conversation_id, ticket.message_id, 1},
                  SearchMessageRequest{ticket, done}))
            return;
        }
      } catch (...) {
        Log("loadSearchMessage threw");
      }
      try { if (done) done(std::nullopt); } catch (...) {}
    });
  } catch (...) {
    try { if (done) done(std::nullopt); } catch (...) {}
  }
}

void LoadChat(const std::string& peerJamiId, const std::string& conversationId,
              const std::string& fromMessage, int pageSize,
              std::function<void(uint32_t)> done) {
  try {
    Post([peerJamiId, conversationId, fromMessage, pageSize, done]() {
      uint32_t loadId = 0;
      try {
        const std::string acc = CurrentAccountId();
        const std::string peer = NormalizeOwnerKey(peerJamiId);
        const auto snapshot = RoutingSnapshot();
        if (!acc.empty() && snapshot && snapshot->Owns(peer, conversationId) &&
            pageSize >= 1 &&
            pageSize <= static_cast<int>(
                sybl::timeline::kMaxTimelineSnapshotItems) &&
            sybl::timeline::IsRequiredUtf8(
                acc, sybl::timeline::kMaxDaemonIdCodeUnits) &&
            sybl::timeline::IsRequiredUtf8(
                peer, sybl::timeline::kMaxAuthorIdCodeUnits) &&
            sybl::timeline::IsRequiredUtf8(
                conversationId, sybl::timeline::kMaxDaemonIdCodeUnits) &&
            sybl::timeline::IsOptionalUtf8(
                fromMessage, sybl::timeline::kMaxDaemonIdCodeUnits)) {
          loadId = StartConversationLoad(
              acc, sybl::conversation::PendingLoad{
                       sybl::conversation::LoadKind::kChat, peer,
                       conversationId, fromMessage, pageSize},
              "loadChat");
        }
      } catch (...) {
        Log("loadChat threw");
      }
      try { if (done) done(loadId); } catch (...) {}
    });
  } catch (...) {
    Log("loadChat post failed");
    try { if (done) done(0); } catch (...) {}
  }
}

void LoadDmTopicState(const std::string& peerJamiId,
                      const std::string& conversationId,
                      const std::string& fromMessage, int pageSize,
                      std::function<void(uint32_t)> done) {
  try {
    Post([peerJamiId, conversationId, fromMessage, pageSize, done]() {
      uint32_t loadId = 0;
      try {
        const auto acc = CurrentAccountId();
        const auto peer = NormalizeOwnerKey(peerJamiId);
        const auto snapshot = RoutingSnapshot();
        if (!acc.empty() && snapshot && snapshot->Owns(peer, conversationId) &&
            !snapshot->Group(conversationId) && pageSize >= 1 &&
            pageSize <= sybl::dm_topic::kMaxStatePageItems &&
            sybl::timeline::IsRequiredUtf8(
                acc, sybl::timeline::kMaxDaemonIdCodeUnits) &&
            sybl::timeline::IsRequiredUtf8(
                peer, sybl::timeline::kMaxAuthorIdCodeUnits) &&
            sybl::timeline::IsRequiredUtf8(
                conversationId, sybl::timeline::kMaxDaemonIdCodeUnits) &&
            sybl::timeline::IsOptionalUtf8(
                fromMessage, sybl::timeline::kMaxDaemonIdCodeUnits)) {
          loadId = StartConversationLoad(
              acc, sybl::conversation::PendingLoad{
                       sybl::conversation::LoadKind::kDmTopicState, peer,
                       conversationId, fromMessage, pageSize},
              "loadDmTopicState");
        }
      } catch (...) {
        Log("loadDmTopicState threw");
      }
      try {
        if (done) done(loadId);
      } catch (...) {
      }
    });
  } catch (...) {
    Log("loadDmTopicState post failed");
    try {
      if (done) done(0);
    } catch (...) {
    }
  }
}

bool CancelChatLoad(uint32_t loadId) {
  try {
    if (loadId == 0) return false;
    std::lock_guard<std::mutex> lock(g_mutex);
    return g_conversationLoads.CancelChat(loadId);
  } catch (...) {
    Log("cancelChatLoad failed");
    return false;
  }
}

bool CancelDmTopicStateLoad(uint32_t loadId) {
  try {
    if (loadId == 0) return false;
    // Returned IDs are already registered. Do not block the UI behind
    // unrelated native load initiation on the registration barrier.
    std::lock_guard<std::mutex> lock(g_mutex);
    return g_conversationLoads.CancelDmTopicState(loadId);
  } catch (...) {
    Log("cancelDmTopicStateLoad failed");
    return false;
  }
}

}  // namespace jami_bridge
