#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif

#include <windows.h>

#include <algorithm>
#include <cmath>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <functional>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

#include "reaper_plugin.h"

#define REAPERAPI_IMPLEMENT
#include "reaper_plugin_functions.h"

namespace {

constexpr int kRecFxFlag = 0x1000000;
constexpr int kContainerFxFlag = 0x2000000;
constexpr DWORD kTrackDeltaFlushIntervalMs = 20;
constexpr DWORD kSuppressionEntryLifetimeMs = 1000;
constexpr DWORD kParamEditReleaseIdleMs = 175;
constexpr DWORD kSendEditReleaseIdleMs = 650;
constexpr DWORD kSendEditKeepAliveMs = 80;
constexpr DWORD kSendParamResyncIntervalMs = 250;
constexpr int kImmediateTrackDeltaFlushTrackThreshold = 8;
constexpr bool kTrackDeltaFlushImmediately = true;
constexpr bool kDebugTouchState = false;
constexpr const char kExtStateSection[] = "7R_FX_AND_SEND_SYNC";
constexpr const char kExtStateKeyFxSyncEnabled[] = "fx_sync_enabled";
constexpr const char kExtStateKeySendSyncEnabled[] = "send_sync_enabled";
constexpr const char kToggleCommandToken[] = "7RFXLINKRELATIVETOGGLE";
constexpr const char kToggleCommandDesc[] = "7R FX and Send Sync: Toggle FX Sync";
constexpr const char kSendToggleCommandToken[] = "7RSENDLINKRELATIVETOGGLE";
constexpr const char kSendToggleCommandDesc[] = "7R FX and Send Sync: Toggle Send Sync";

struct TrackParamKey {
  MediaTrack* track {};
  int fx_index {};
  int param_index {};

  bool operator==(const TrackParamKey& other) const noexcept {
    return track == other.track && fx_index == other.fx_index &&
           param_index == other.param_index;
  }
};

struct TrackParamKeyHash {
  size_t operator()(const TrackParamKey& key) const noexcept {
    const auto p = reinterpret_cast<std::uintptr_t>(key.track);
    size_t h = static_cast<size_t>(p);
    h ^= static_cast<size_t>(key.fx_index) + 0x9e3779b9 + (h << 6U) + (h >> 2U);
    h ^= static_cast<size_t>(key.param_index) + 0x9e3779b9 + (h << 6U) + (h >> 2U);
    return h;
  }
};

struct TrackSendKey {
  MediaTrack* track {};
  int send_index {};

  bool operator==(const TrackSendKey& other) const noexcept {
    return track == other.track && send_index == other.send_index;
  }
};

struct TrackSendKeyHash {
  size_t operator()(const TrackSendKey& key) const noexcept {
    const auto p = reinterpret_cast<std::uintptr_t>(key.track);
    size_t h = static_cast<size_t>(p);
    h ^= static_cast<size_t>(key.send_index) + 0x9e3779b9 + (h << 6U) + (h >> 2U);
    return h;
  }
};

struct SendTargetCacheKey {
  MediaTrack* source_track {};
  int source_send_index {};
  MediaTrack* target_track {};

  bool operator==(const SendTargetCacheKey& other) const noexcept {
    return source_track == other.source_track &&
           source_send_index == other.source_send_index &&
           target_track == other.target_track;
  }
};

struct SendTargetCacheKeyHash {
  size_t operator()(const SendTargetCacheKey& key) const noexcept {
    const auto source_ptr = reinterpret_cast<std::uintptr_t>(key.source_track);
    const auto target_ptr = reinterpret_cast<std::uintptr_t>(key.target_track);
    size_t h = static_cast<size_t>(source_ptr);
    h ^= static_cast<size_t>(key.source_send_index) + 0x9e3779b9 + (h << 6U) + (h >> 2U);
    h ^= static_cast<size_t>(target_ptr) + 0x9e3779b9 + (h << 6U) + (h >> 2U);
    return h;
  }
};

struct SendLookupKey {
  MediaTrack* track {};
  MediaTrack* dest_track {};
  int ordinal {};
  int send_mode {};
  int src_chan {};
  int dst_chan {};
  int midi_flags {};

  bool operator==(const SendLookupKey& other) const noexcept {
    return track == other.track &&
           dest_track == other.dest_track &&
           ordinal == other.ordinal &&
           send_mode == other.send_mode &&
           src_chan == other.src_chan &&
           dst_chan == other.dst_chan &&
           midi_flags == other.midi_flags;
  }
};

struct SendLookupKeyHash {
  size_t operator()(const SendLookupKey& key) const noexcept {
    const auto track_ptr = reinterpret_cast<std::uintptr_t>(key.track);
    const auto dest_ptr = reinterpret_cast<std::uintptr_t>(key.dest_track);
    size_t h = static_cast<size_t>(track_ptr);
    h ^= static_cast<size_t>(dest_ptr) + 0x9e3779b9 + (h << 6U) + (h >> 2U);
    h ^= static_cast<size_t>(key.ordinal) + 0x9e3779b9 + (h << 6U) + (h >> 2U);
    h ^= static_cast<size_t>(key.send_mode) + 0x9e3779b9 + (h << 6U) + (h >> 2U);
    h ^= static_cast<size_t>(key.src_chan) + 0x9e3779b9 + (h << 6U) + (h >> 2U);
    h ^= static_cast<size_t>(key.dst_chan) + 0x9e3779b9 + (h << 6U) + (h >> 2U);
    h ^= static_cast<size_t>(key.midi_flags) + 0x9e3779b9 + (h << 6U) + (h >> 2U);
    return h;
  }
};

struct TrackFxLookupKey {
  MediaTrack* track {};
  bool rec_fx {};
  int instance {};
  std::string fx_name {};

  bool operator==(const TrackFxLookupKey& other) const noexcept {
    return track == other.track &&
           rec_fx == other.rec_fx &&
           instance == other.instance &&
           fx_name == other.fx_name;
  }
};

struct TrackFxLookupKeyHash {
  size_t operator()(const TrackFxLookupKey& key) const noexcept {
    const auto track_ptr = reinterpret_cast<std::uintptr_t>(key.track);
    size_t h = static_cast<size_t>(track_ptr);
    h ^= static_cast<size_t>(key.rec_fx ? 1 : 0) + 0x9e3779b9 + (h << 6U) + (h >> 2U);
    h ^= static_cast<size_t>(key.instance) + 0x9e3779b9 + (h << 6U) + (h >> 2U);
    h ^= std::hash<std::string>{}(key.fx_name) + 0x9e3779b9 + (h << 6U) + (h >> 2U);
    return h;
  }
};

struct TrackFxTargetCacheKey {
  MediaTrack* source_track {};
  int source_fx_index {};
  MediaTrack* target_track {};

  bool operator==(const TrackFxTargetCacheKey& other) const noexcept {
    return source_track == other.source_track &&
           source_fx_index == other.source_fx_index &&
           target_track == other.target_track;
  }
};

struct TrackFxTargetCacheKeyHash {
  size_t operator()(const TrackFxTargetCacheKey& key) const noexcept {
    const auto source_ptr = reinterpret_cast<std::uintptr_t>(key.source_track);
    const auto target_ptr = reinterpret_cast<std::uintptr_t>(key.target_track);
    size_t h = static_cast<size_t>(source_ptr);
    h ^= static_cast<size_t>(key.source_fx_index) + 0x9e3779b9 + (h << 6U) + (h >> 2U);
    h ^= static_cast<size_t>(target_ptr) + 0x9e3779b9 + (h << 6U) + (h >> 2U);
    return h;
  }
};

struct TrackFxStateKey {
  MediaTrack* track {};
  int fx_index {};

  bool operator==(const TrackFxStateKey& other) const noexcept {
    return track == other.track && fx_index == other.fx_index;
  }
};

struct TrackFxStateKeyHash {
  size_t operator()(const TrackFxStateKey& key) const noexcept {
    const auto p = reinterpret_cast<std::uintptr_t>(key.track);
    size_t h = static_cast<size_t>(p);
    h ^= static_cast<size_t>(key.fx_index) + 0x9e3779b9 + (h << 6U) + (h >> 2U);
    return h;
  }
};

struct ItemFxStateKey {
  MediaItem_Take* take {};
  int fx_index {};

  bool operator==(const ItemFxStateKey& other) const noexcept {
    return take == other.take && fx_index == other.fx_index;
  }
};

struct ItemFxStateKeyHash {
  size_t operator()(const ItemFxStateKey& key) const noexcept {
    const auto p = reinterpret_cast<std::uintptr_t>(key.take);
    size_t h = static_cast<size_t>(p);
    h ^= static_cast<size_t>(key.fx_index) + 0x9e3779b9 + (h << 6U) + (h >> 2U);
    return h;
  }
};

struct TakeParamKey {
  MediaItem_Take* take {};
  int fx_index {};
  int param_index {};

  bool operator==(const TakeParamKey& other) const noexcept {
    return take == other.take && fx_index == other.fx_index &&
           param_index == other.param_index;
  }
};

struct TakeParamKeyHash {
  size_t operator()(const TakeParamKey& key) const noexcept {
    const auto p = reinterpret_cast<std::uintptr_t>(key.take);
    size_t h = static_cast<size_t>(p);
    h ^= static_cast<size_t>(key.fx_index) + 0x9e3779b9 + (h << 6U) + (h >> 2U);
    h ^= static_cast<size_t>(key.param_index) + 0x9e3779b9 + (h << 6U) + (h >> 2U);
    return h;
  }
};

struct FxState {
  std::string fx_name {};
  bool enabled {};
  bool offline {};
};

struct SuppressedWrite {
  int pending_callbacks {};
  DWORD expires_at {};
};

struct TrackSendParamState {
  double volume {};
  double pan {};
};

struct TrackSendState {
  MediaTrack* dest_track {};
  int send_mode {};
  int src_chan {};
  int dst_chan {};
  int midi_flags {};
  bool muted {};
};

struct SendMatchInfo {
  TrackSendState identity {};
  int ordinal {0};
};

struct StableSendLink {
  MediaTrack* dest_track {};
  int ordinal {0};
  int send_mode {};
  int src_chan {};
  int dst_chan {};
  int midi_flags {};
  bool ambiguous {false};
};

struct ActiveTrackParamEdit {
  TrackParamKey source {};
};

struct ActiveTakeParamEdit {
  TakeParamKey source {};
};

struct ActiveSendEdit {
  TrackSendKey source {};
  DWORD last_keepalive_tick {};
};

struct FocusedItemFx {
  int track_index {-1};
  int item_index {-1};
  int take_index {-1};
  int fx_index {-1};
  std::string fx_name {};

  bool IsValid() const noexcept {
    return track_index >= 0 && item_index >= 0 && take_index >= 0 && fx_index >= 0 &&
           !fx_name.empty();
  }
};

class FxLinkSurface;

static int g_toggle_command_id = 0;
static int g_send_toggle_command_id = 0;
static bool g_enabled = false;
static bool g_send_enabled = false;
static bool g_persist_toggle_state = true;
static int g_internal_change_depth = 0;
static FxLinkSurface* g_surface = nullptr;
static gaccel_register_t g_action = {{0, 0, 0}, kToggleCommandDesc};
static gaccel_register_t g_send_action = {{0, 0, 0}, kSendToggleCommandDesc};

static std::unordered_map<TrackParamKey, double, TrackParamKeyHash> g_track_param_snapshot;
static std::unordered_map<TrackParamKey, double, TrackParamKeyHash> g_pending_track_param_deltas;
static std::unordered_map<TrackParamKey, SuppressedWrite, TrackParamKeyHash>
    g_suppressed_track_param_writes;
static std::unordered_map<TrackParamKey, DWORD, TrackParamKeyHash>
    g_track_source_activity_ticks;
static std::unordered_map<TrackParamKey, ActiveTrackParamEdit, TrackParamKeyHash>
    g_active_track_param_edits;
static std::unordered_map<TakeParamKey, DWORD, TakeParamKeyHash>
    g_take_source_activity_ticks;
static std::unordered_map<TakeParamKey, ActiveTakeParamEdit, TakeParamKeyHash>
    g_active_take_param_edits;
static std::unordered_map<TrackFxStateKey, FxState, TrackFxStateKeyHash> g_track_fx_state_snapshot;
static std::unordered_map<ItemFxStateKey, FxState, ItemFxStateKeyHash> g_item_fx_state_snapshot;
static FocusedItemFx g_focused_item_fx;
static std::unordered_map<int, double> g_item_param_snapshot;
static std::unordered_map<TrackSendKey, TrackSendParamState, TrackSendKeyHash>
    g_track_send_param_snapshot;
static std::unordered_map<TrackSendKey, TrackSendState, TrackSendKeyHash>
    g_track_send_state_snapshot;
static std::unordered_map<TrackSendKey, StableSendLink, TrackSendKeyHash>
    g_stable_send_links;
static std::unordered_map<SendTargetCacheKey, int, SendTargetCacheKeyHash>
    g_send_target_index_cache;
static std::unordered_map<TrackSendKey, std::vector<MediaTrack*>, TrackSendKeyHash>
    g_send_peer_track_cache;
static std::unordered_map<SendLookupKey, int, SendLookupKeyHash>
    g_send_lookup_index;
static std::unordered_map<TrackSendKey, SuppressedWrite, TrackSendKeyHash>
    g_suppressed_send_volume_writes;
static std::unordered_map<TrackSendKey, SuppressedWrite, TrackSendKeyHash>
    g_suppressed_send_pan_writes;
static std::unordered_map<TrackSendKey, DWORD, TrackSendKeyHash>
    g_send_source_activity_ticks;
static std::unordered_map<TrackSendKey, ActiveSendEdit, TrackSendKeyHash>
    g_active_send_volume_edits;
static std::unordered_map<TrackSendKey, ActiveSendEdit, TrackSendKeyHash>
    g_active_send_pan_edits;
static std::unordered_map<TrackFxStateKey, int, TrackFxStateKeyHash>
    g_track_fx_instance_lookup;
static std::unordered_map<TrackFxLookupKey, int, TrackFxLookupKeyHash>
    g_track_fx_lookup;
static std::unordered_map<TrackFxTargetCacheKey, int, TrackFxTargetCacheKeyHash>
    g_track_fx_target_index_cache;
static DWORD g_last_send_source_activity_tick = 0;
static DWORD g_last_send_param_resync_tick = 0;
static DWORD g_last_track_delta_flush_tick = 0;

struct ScopedInternalChange {
  ScopedInternalChange() { ++g_internal_change_depth; }
  ~ScopedInternalChange() { --g_internal_change_depth; }
};

void DebugTouchLog(const char* fmt, ...) {
  if (!kDebugTouchState || !ShowConsoleMsg) return;
  char buf[1024];
  va_list args;
  va_start(args, fmt);
  vsnprintf(buf, sizeof(buf), fmt, args);
  va_end(args);
  ShowConsoleMsg(buf);
  ShowConsoleMsg("\n");
}

bool ParseExtStateBool(const char* text) {
  if (!text || !*text) return false;
  return text[0] == '1' || text[0] == 't' || text[0] == 'T' ||
         text[0] == 'y' || text[0] == 'Y';
}

void SaveGlobalToggleState() {
  if (!g_persist_toggle_state || !SetExtState) return;
  SetExtState(kExtStateSection, kExtStateKeyFxSyncEnabled, g_enabled ? "1" : "0", true);
  SetExtState(kExtStateSection, kExtStateKeySendSyncEnabled, g_send_enabled ? "1" : "0", true);
}

void LoadGlobalToggleState(bool* fx_enabled_out, bool* send_enabled_out) {
  if (fx_enabled_out) *fx_enabled_out = false;
  if (send_enabled_out) *send_enabled_out = false;
  if (!GetExtState) return;

  const char* fx_state = GetExtState(kExtStateSection, kExtStateKeyFxSyncEnabled);
  const char* send_state = GetExtState(kExtStateSection, kExtStateKeySendSyncEnabled);

  if (fx_enabled_out) *fx_enabled_out = ParseExtStateBool(fx_state);
  if (send_enabled_out) *send_enabled_out = ParseExtStateBool(send_state);
}

int GetEffectiveTrackAutomationMode(MediaTrack* track) {
  if (!track || !GetTrackAutomationMode) return -1;
  int mode = GetTrackAutomationMode(track);
  if (GetGlobalAutomationOverride) {
    const int global_mode = GetGlobalAutomationOverride();
    if (global_mode >= 0) mode = global_mode;
  }
  return mode;
}

bool IsTrackTrimReadMode(MediaTrack* track) {
  return GetEffectiveTrackAutomationMode(track) == 0;
}

double Clamp01(const double value) {
  if (value < 0.0) return 0.0;
  if (value > 1.0) return 1.0;
  return value;
}

bool IsContainerFxIndex(const int fx_index) {
  return (fx_index & kContainerFxFlag) != 0;
}

bool IsRecFxIndex(const int fx_index) {
  return (fx_index & kRecFxFlag) != 0;
}

int StripTrackFxFlags(const int fx_index) {
  return fx_index & 0xFFFFFF;
}

int MakeTrackFxIndex(const bool rec_fx, const int raw_index) {
  return (rec_fx ? kRecFxFlag : 0) | raw_index;
}

std::vector<MediaTrack*> GetSelectedTracksIncludingMaster() {
  std::vector<MediaTrack*> tracks;
  const int selected_count = CountSelectedTracks(nullptr);
  tracks.reserve(static_cast<size_t>(selected_count + 1));
  for (int i = 0; i < selected_count; ++i) {
    if (MediaTrack* track = GetSelectedTrack(nullptr, i)) {
      tracks.push_back(track);
    }
  }

  MediaTrack* master = GetMasterTrack(nullptr);
  if (master && IsTrackSelected(master)) {
    tracks.push_back(master);
  }

  return tracks;
}

std::vector<MediaItem*> GetSelectedItems() {
  std::vector<MediaItem*> items;
  const int selected_count = CountSelectedMediaItems(nullptr);
  items.reserve(static_cast<size_t>(selected_count));
  for (int i = 0; i < selected_count; ++i) {
    if (MediaItem* item = GetSelectedMediaItem(nullptr, i)) {
      items.push_back(item);
    }
  }
  return items;
}

void BuildTrackParamSnapshot(
    std::unordered_map<TrackParamKey, double, TrackParamKeyHash>* snapshot_out) {
  if (!snapshot_out) return;
  const size_t reserve_hint = snapshot_out->size();
  snapshot_out->clear();
  snapshot_out->reserve(reserve_hint);

  const auto selected_tracks = GetSelectedTracksIncludingMaster();
  for (MediaTrack* track : selected_tracks) {
    if (!track) continue;

    for (int pass = 0; pass < 2; ++pass) {
      const bool rec_fx = pass == 1;
      const int fx_count = rec_fx ? TrackFX_GetRecCount(track) : TrackFX_GetCount(track);
      for (int fx_raw_index = 0; fx_raw_index < fx_count; ++fx_raw_index) {
        const int fx_index = MakeTrackFxIndex(rec_fx, fx_raw_index);
        const int param_count = TrackFX_GetNumParams(track, fx_index);
        for (int param_index = 0; param_index < param_count; ++param_index) {
          (*snapshot_out)[TrackParamKey{track, fx_index, param_index}] =
              TrackFX_GetParamNormalized(track, fx_index, param_index);
        }
      }
    }
  }
}

void CreateTrackParamSnapshot() {
  BuildTrackParamSnapshot(&g_track_param_snapshot);
}

int GetTrackSendCount(MediaTrack* track) {
  if (!track) return 0;
  return GetTrackNumSends(track, 0);
}

int ToSendUiIndex(MediaTrack* track, const int send_index) {
  if (!track || send_index < 0) return send_index;
  const int hwout_count = GetTrackNumSends(track, 1);
  return hwout_count + send_index;
}

bool SetTrackSendVolumeForAutomation(MediaTrack* track,
                                     const int send_index,
                                     const double volume,
                                     const int is_end) {
  if (!track || send_index < 0) return false;

  if (SetTrackSendUIVol) {
    const int ui_send_index = ToSendUiIndex(track, send_index);
    if (SetTrackSendUIVol(track, ui_send_index, volume, is_end ? 1 : 0)) {
      return true;
    }
  }

  return SetTrackSendInfo_Value(track, 0, send_index, "D_VOL", volume);
}

bool SetTrackSendPanForAutomation(MediaTrack* track,
                                  const int send_index,
                                  const double pan,
                                  const int is_end) {
  if (!track || send_index < 0) return false;

  if (SetTrackSendUIPan) {
    const int ui_send_index = ToSendUiIndex(track, send_index);
    if (SetTrackSendUIPan(track, ui_send_index, pan, is_end ? 1 : 0)) {
      return true;
    }
  }

  return SetTrackSendInfo_Value(track, 0, send_index, "D_PAN", pan);
}

bool IsSameTrackSendIdentity(const TrackSendState& a, const TrackSendState& b) {
  return a.dest_track == b.dest_track &&
         a.send_mode == b.send_mode &&
         a.src_chan == b.src_chan &&
         a.dst_chan == b.dst_chan &&
         a.midi_flags == b.midi_flags;
}

bool IsSameTrackSendDestination(const TrackSendState& a, const TrackSendState& b) {
  return a.dest_track == b.dest_track;
}

bool HasTrackSendStructureChanged(
    const std::unordered_map<TrackSendKey, TrackSendState, TrackSendKeyHash>& old_snapshot,
    const std::unordered_map<TrackSendKey, TrackSendState, TrackSendKeyHash>& new_snapshot) {
  if (old_snapshot.size() != new_snapshot.size()) return true;

  for (const auto& kv : new_snapshot) {
    const auto it = old_snapshot.find(kv.first);
    if (it == old_snapshot.end()) return true;
    if (!IsSameTrackSendIdentity(it->second, kv.second)) return true;
  }

  return false;
}

bool ReadTrackSendState(MediaTrack* track, const int send_index, TrackSendState* state_out) {
  if (!track || !state_out || send_index < 0) return false;
  if (send_index >= GetTrackSendCount(track)) return false;

  state_out->dest_track = static_cast<MediaTrack*>(
      GetSetTrackSendInfo(track, 0, send_index, "P_DESTTRACK", nullptr));
  state_out->send_mode =
      static_cast<int>(GetTrackSendInfo_Value(track, 0, send_index, "I_SENDMODE"));
  state_out->src_chan =
      static_cast<int>(GetTrackSendInfo_Value(track, 0, send_index, "I_SRCCHAN"));
  state_out->dst_chan =
      static_cast<int>(GetTrackSendInfo_Value(track, 0, send_index, "I_DSTCHAN"));
  state_out->midi_flags =
      static_cast<int>(GetTrackSendInfo_Value(track, 0, send_index, "I_MIDIFLAGS"));
  state_out->muted = GetTrackSendInfo_Value(track, 0, send_index, "B_MUTE") != 0.0;
  return true;
}

bool ReadTrackSendParamState(MediaTrack* track,
                             const int send_index,
                             TrackSendParamState* state_out) {
  if (!track || !state_out || send_index < 0) return false;
  if (send_index >= GetTrackSendCount(track)) return false;

  state_out->volume = GetTrackSendInfo_Value(track, 0, send_index, "D_VOL");
  state_out->pan = GetTrackSendInfo_Value(track, 0, send_index, "D_PAN");
  return true;
}

void BuildTrackSendStateSnapshot(
    std::unordered_map<TrackSendKey, TrackSendState, TrackSendKeyHash>* snapshot_out) {
  if (!snapshot_out) return;
  const size_t reserve_hint = snapshot_out->size();
  snapshot_out->clear();
  snapshot_out->reserve(reserve_hint);

  const auto selected_tracks = GetSelectedTracksIncludingMaster();
  for (MediaTrack* track : selected_tracks) {
    if (!track) continue;
    const int send_count = GetTrackSendCount(track);
    for (int send_index = 0; send_index < send_count; ++send_index) {
      TrackSendState send_state;
      if (!ReadTrackSendState(track, send_index, &send_state)) continue;
      (*snapshot_out)[TrackSendKey{track, send_index}] = send_state;
    }
  }
}

void BuildTrackSendParamSnapshot(
    std::unordered_map<TrackSendKey, TrackSendParamState, TrackSendKeyHash>* snapshot_out) {
  if (!snapshot_out) return;
  const size_t reserve_hint = snapshot_out->size();
  snapshot_out->clear();
  snapshot_out->reserve(reserve_hint);

  const auto selected_tracks = GetSelectedTracksIncludingMaster();
  for (MediaTrack* track : selected_tracks) {
    if (!track) continue;
    const int send_count = GetTrackSendCount(track);
    for (int send_index = 0; send_index < send_count; ++send_index) {
      TrackSendParamState send_state;
      if (!ReadTrackSendParamState(track, send_index, &send_state)) continue;
      (*snapshot_out)[TrackSendKey{track, send_index}] = send_state;
    }
  }
}

void RebuildStableSendLinks();
bool HasActiveSendEdits();
void ClearSendTargetIndexCache();
void ClearSendPeerTrackCache();

void CreateTrackSendSnapshots() {
  BuildTrackSendStateSnapshot(&g_track_send_state_snapshot);
  BuildTrackSendParamSnapshot(&g_track_send_param_snapshot);
  g_last_send_param_resync_tick = GetTickCount();
  ClearSendTargetIndexCache();
  ClearSendPeerTrackCache();
  if (!HasActiveSendEdits()) {
    RebuildStableSendLinks();
  }
}

std::vector<std::pair<int, TrackSendState>> GetIndexedTrackSendStatesFromSnapshot(
    const std::unordered_map<TrackSendKey, TrackSendState, TrackSendKeyHash>& snapshot,
    MediaTrack* track) {
  std::vector<std::pair<int, TrackSendState>> indexed;
  for (const auto& kv : snapshot) {
    if (kv.first.track != track) continue;
    indexed.emplace_back(kv.first.send_index, kv.second);
  }

  std::sort(indexed.begin(), indexed.end(),
            [](const auto& a, const auto& b) { return a.first < b.first; });
  return indexed;
}

[[maybe_unused]] std::vector<TrackSendState> GetTrackSendStatesFromSnapshot(
    const std::unordered_map<TrackSendKey, TrackSendState, TrackSendKeyHash>& snapshot,
    MediaTrack* track) {
  std::vector<std::pair<int, TrackSendState>> indexed =
      GetIndexedTrackSendStatesFromSnapshot(snapshot, track);

  std::vector<TrackSendState> states;
  states.reserve(indexed.size());
  for (const auto& kv : indexed) {
    states.push_back(kv.second);
  }
  return states;
}

[[maybe_unused]] bool AreTrackSendStateListsEqualIgnoringOrder(
    const std::vector<TrackSendState>& a,
    const std::vector<TrackSendState>& b) {
  if (a.size() != b.size()) return false;
  std::vector<bool> matched(b.size(), false);

  for (const TrackSendState& lhs : a) {
    bool found = false;
    for (size_t i = 0; i < b.size(); ++i) {
      if (matched[i]) continue;
      if (!IsSameTrackSendIdentity(lhs, b[i])) continue;
      matched[i] = true;
      found = true;
      break;
    }
    if (!found) return false;
  }
  return true;
}

[[maybe_unused]] bool HasTrackSendOrderChanged(
    const std::unordered_map<TrackSendKey, TrackSendState, TrackSendKeyHash>& old_snapshot,
    const std::unordered_map<TrackSendKey, TrackSendState, TrackSendKeyHash>& new_snapshot,
    MediaTrack* track) {
  const std::vector<TrackSendState> old_slots =
      GetTrackSendStatesFromSnapshot(old_snapshot, track);
  const std::vector<TrackSendState> new_slots =
      GetTrackSendStatesFromSnapshot(new_snapshot, track);

  if (old_slots.size() != new_slots.size()) return false;
  if (old_slots.empty()) return false;
  if (!AreTrackSendStateListsEqualIgnoringOrder(old_slots, new_slots)) return false;

  for (size_t i = 0; i < old_slots.size(); ++i) {
    if (!IsSameTrackSendIdentity(old_slots[i], new_slots[i])) {
      return true;
    }
  }
  return false;
}

SendMatchInfo GetSendMatchInfoFromSnapshot(
    const std::unordered_map<TrackSendKey, TrackSendState, TrackSendKeyHash>& snapshot,
    MediaTrack* track,
    const int send_index) {
  SendMatchInfo info;
  if (!track || send_index < 0) return info;

  const auto snapshot_it = snapshot.find(TrackSendKey{track, send_index});
  if (snapshot_it == snapshot.end()) return info;
  info.identity = snapshot_it->second;

  std::vector<std::pair<int, TrackSendState>> indexed =
      GetIndexedTrackSendStatesFromSnapshot(snapshot, track);

  int ordinal = 0;
  for (const auto& kv : indexed) {
    if (kv.first > send_index) break;
    if (!IsSameTrackSendDestination(kv.second, info.identity)) continue;
    ++ordinal;
  }
  info.ordinal = ordinal;
  return info;
}

int FindMatchingSendIndex(MediaTrack* track,
                          const TrackSendState& target_state,
                          const int ordinal) {
  if (!track) return -1;

  const int send_count = GetTrackSendCount(track);
  std::vector<int> destination_matches;
  destination_matches.reserve(send_count);

  for (int i = 0; i < send_count; ++i) {
    TrackSendState current_state;
    if (!ReadTrackSendState(track, i, &current_state)) continue;
    if (!IsSameTrackSendDestination(current_state, target_state)) continue;
    destination_matches.push_back(i);
  }

  if (destination_matches.empty()) return -1;
  if (ordinal > 0 && ordinal <= static_cast<int>(destination_matches.size())) {
    return destination_matches[ordinal - 1];
  }
  if (destination_matches.size() == 1) {
    return destination_matches[0];
  }
  return -1;
}

[[maybe_unused]] bool IsHomogeneousDestinationGroup(
    const std::vector<TrackSendState>& sends,
    const MediaTrack* dest_track) {
  bool found = false;
  TrackSendState reference {};
  for (const auto& send : sends) {
    if (send.dest_track != dest_track) continue;
    if (!found) {
      reference = send;
      found = true;
      continue;
    }
    if (send.send_mode != reference.send_mode ||
        send.src_chan != reference.src_chan ||
        send.dst_chan != reference.dst_chan ||
        send.midi_flags != reference.midi_flags) {
      return false;
    }
  }
  return true;
}

void RebuildStableSendLinks() {
  g_stable_send_links.clear();
  g_send_lookup_index.clear();
  ClearSendTargetIndexCache();
  ClearSendPeerTrackCache();

  const auto selected_tracks = GetSelectedTracksIncludingMaster();
  for (MediaTrack* track : selected_tracks) {
    if (!track) continue;

    std::vector<std::pair<int, TrackSendState>> indexed =
        GetIndexedTrackSendStatesFromSnapshot(g_track_send_state_snapshot, track);
    if (indexed.empty()) continue;

    std::unordered_map<MediaTrack*, TrackSendState> destination_references;
    std::unordered_map<MediaTrack*, bool> destination_homogeneous;
    for (const auto& kv : indexed) {
      const TrackSendState& send_state = kv.second;
      const auto ref_it = destination_references.find(send_state.dest_track);
      if (ref_it == destination_references.end()) {
        destination_references.emplace(send_state.dest_track, send_state);
        destination_homogeneous.emplace(send_state.dest_track, true);
        continue;
      }

      bool same_identity = send_state.send_mode == ref_it->second.send_mode &&
                           send_state.src_chan == ref_it->second.src_chan &&
                           send_state.dst_chan == ref_it->second.dst_chan &&
                           send_state.midi_flags == ref_it->second.midi_flags;
      if (!same_identity) {
        destination_homogeneous[send_state.dest_track] = false;
      }
    }

    std::unordered_map<MediaTrack*, int> destination_ordinals;
    for (const auto& kv : indexed) {
      const int send_index = kv.first;
      const TrackSendState& send_state = kv.second;
      const int ordinal = ++destination_ordinals[send_state.dest_track];

      StableSendLink link;
      link.dest_track = send_state.dest_track;
      link.ordinal = ordinal;
      link.send_mode = send_state.send_mode;
      link.src_chan = send_state.src_chan;
      link.dst_chan = send_state.dst_chan;
      link.midi_flags = send_state.midi_flags;
      link.ambiguous = !destination_homogeneous[send_state.dest_track];

      g_stable_send_links[TrackSendKey{track, send_index}] = link;
      g_send_lookup_index[SendLookupKey{
          track,
          send_state.dest_track,
          ordinal,
          send_state.send_mode,
          send_state.src_chan,
          send_state.dst_chan,
          send_state.midi_flags,
      }] = send_index;
    }
  }
}

bool HasActiveSendEdits() {
  return !g_active_send_volume_edits.empty() || !g_active_send_pan_edits.empty();
}

int FindStableMatchingSendIndex(MediaTrack* track, const StableSendLink& link) {
  if (!track || !link.dest_track || link.ordinal <= 0 || link.ambiguous) return -1;

  const auto lookup_it = g_send_lookup_index.find(SendLookupKey{
      track,
      link.dest_track,
      link.ordinal,
      link.send_mode,
      link.src_chan,
      link.dst_chan,
      link.midi_flags,
  });
  if (lookup_it != g_send_lookup_index.end()) {
    return lookup_it->second;
  }

  const int send_count = GetTrackSendCount(track);
  int ordinal = 0;
  for (int i = 0; i < send_count; ++i) {
    TrackSendState current_state;
    if (!ReadTrackSendState(track, i, &current_state)) continue;
    if (current_state.dest_track != link.dest_track) continue;

    ++ordinal;
    if (ordinal != link.ordinal) continue;

    if (link.send_mode != current_state.send_mode ||
        link.src_chan != current_state.src_chan ||
        link.dst_chan != current_state.dst_chan ||
        link.midi_flags != current_state.midi_flags) {
      return -1;
    }

    return i;
  }

  return -1;
}

void ClearSendTargetIndexCache() {
  g_send_target_index_cache.clear();
}

void ClearSendPeerTrackCache() {
  g_send_peer_track_cache.clear();
}

const std::vector<MediaTrack*>& GetCachedSendPeerTracks(
    const TrackSendKey& source_key,
    const StableSendLink& link) {
  const auto cached = g_send_peer_track_cache.find(source_key);
  if (cached != g_send_peer_track_cache.end()) {
    return cached->second;
  }

  auto& peers = g_send_peer_track_cache[source_key];
  if (!source_key.track || source_key.send_index < 0 ||
      !link.dest_track || link.ordinal <= 0 || link.ambiguous) {
    return peers;
  }

  const int receive_count = GetTrackNumSends(link.dest_track, -1);
  std::unordered_set<MediaTrack*> dedupe;
  dedupe.reserve(static_cast<size_t>(std::max(0, receive_count)));

  for (int receive_index = 0; receive_index < receive_count; ++receive_index) {
    MediaTrack* receive_source = static_cast<MediaTrack*>(
        GetSetTrackSendInfo(link.dest_track, -1, receive_index, "P_SRCTRACK", nullptr));
    if (!receive_source || receive_source == source_key.track) continue;
    if (!IsTrackSelected(receive_source)) continue;
    if (!dedupe.insert(receive_source).second) continue;
    peers.push_back(receive_source);
  }

  return peers;
}

int FindCachedStableMatchingSendIndex(const TrackSendKey& source_key,
                                      MediaTrack* target_track,
                                      const StableSendLink& link) {
  if (!source_key.track || source_key.send_index < 0 || !target_track) return -1;

  const SendTargetCacheKey cache_key{
      source_key.track,
      source_key.send_index,
      target_track,
  };

  const auto cached = g_send_target_index_cache.find(cache_key);
  if (cached != g_send_target_index_cache.end()) {
    return cached->second;
  }

  const int matched_index = FindStableMatchingSendIndex(target_track, link);
  g_send_target_index_cache.emplace(cache_key, matched_index);
  return matched_index;
}

using SuppressedSendMap = std::unordered_map<TrackSendKey, SuppressedWrite, TrackSendKeyHash>;

void CleanupSuppressedSendWrites(SuppressedSendMap* writes) {
  if (!writes || writes->empty()) return;
  const DWORD now = GetTickCount();
  for (auto it = writes->begin(); it != writes->end();) {
    if (static_cast<int>(now - it->second.expires_at) >= 0) {
      it = writes->erase(it);
    } else {
      ++it;
    }
  }
}

void MarkSuppressedSendWrite(SuppressedSendMap* writes, const TrackSendKey& key) {
  if (!writes) return;
  auto& entry = (*writes)[key];
  ++entry.pending_callbacks;
  entry.expires_at = GetTickCount() + kSuppressionEntryLifetimeMs;
}

bool ConsumeSuppressedSendWrite(SuppressedSendMap* writes, const TrackSendKey& key) {
  if (!writes) return false;
  const auto it = writes->find(key);
  if (it == writes->end()) return false;

  const DWORD now = GetTickCount();
  if (static_cast<int>(now - it->second.expires_at) >= 0) {
    writes->erase(it);
    return false;
  }

  if (it->second.pending_callbacks <= 0) {
    writes->erase(it);
    return false;
  }

  --it->second.pending_callbacks;
  if (it->second.pending_callbacks == 0) {
    writes->erase(it);
  }
  return true;
}

void NoteSendSourceActivity(const TrackSendKey& source_key) {
  const DWORD now = GetTickCount();
  g_send_source_activity_ticks[source_key] = now;
  g_last_send_source_activity_tick = now;
}

void MarkSendVolumeEditActive(const TrackSendKey& target_key, const TrackSendKey& source_key) {
  auto& edit = g_active_send_volume_edits[target_key];
  edit.source = source_key;
  edit.last_keepalive_tick = 0;
}

void MarkSendPanEditActive(const TrackSendKey& target_key, const TrackSendKey& source_key) {
  auto& edit = g_active_send_pan_edits[target_key];
  edit.source = source_key;
  edit.last_keepalive_tick = 0;
}

void KeepSendEditsAlive() {
  if (g_active_send_volume_edits.empty() && g_active_send_pan_edits.empty()) return;

  const DWORD now = GetTickCount();

  if (!g_active_send_volume_edits.empty()) {
    for (auto& kv : g_active_send_volume_edits) {
      TrackSendKey target = kv.first;
      ActiveSendEdit& edit = kv.second;
      if (!edit.source.track || !IsTrackTrimReadMode(edit.source.track)) continue;
      if (edit.last_keepalive_tick != 0 &&
          static_cast<int>(now - edit.last_keepalive_tick) < static_cast<int>(kSendEditKeepAliveMs)) {
        continue;
      }
      if (!target.track || target.send_index < 0 ||
          target.send_index >= GetTrackSendCount(target.track) ||
          !IsTrackTrimReadMode(target.track)) {
        continue;
      }

      const double current = GetTrackSendInfo_Value(target.track, 0, target.send_index, "D_VOL");
      ScopedInternalChange guard;
      MarkSuppressedSendWrite(&g_suppressed_send_volume_writes, target);
      SetTrackSendVolumeForAutomation(target.track, target.send_index, current, 0);
      edit.last_keepalive_tick = now;
    }
  }

  if (!g_active_send_pan_edits.empty()) {
    for (auto& kv : g_active_send_pan_edits) {
      TrackSendKey target = kv.first;
      ActiveSendEdit& edit = kv.second;
      if (!edit.source.track || !IsTrackTrimReadMode(edit.source.track)) continue;
      if (edit.last_keepalive_tick != 0 &&
          static_cast<int>(now - edit.last_keepalive_tick) < static_cast<int>(kSendEditKeepAliveMs)) {
        continue;
      }
      if (!target.track || target.send_index < 0 ||
          target.send_index >= GetTrackSendCount(target.track) ||
          !IsTrackTrimReadMode(target.track)) {
        continue;
      }

      const double current = GetTrackSendInfo_Value(target.track, 0, target.send_index, "D_PAN");
      ScopedInternalChange guard;
      MarkSuppressedSendWrite(&g_suppressed_send_pan_writes, target);
      SetTrackSendPanForAutomation(target.track, target.send_index, current, 0);
      edit.last_keepalive_tick = now;
    }
  }
}

void ReleaseExpiredSendEdits(const bool force = false) {
  if (!force && g_active_send_volume_edits.empty() && g_active_send_pan_edits.empty()) return;

  const DWORD now = GetTickCount();
  if (!force && g_last_send_source_activity_tick != 0 &&
      static_cast<int>(now - g_last_send_source_activity_tick) <
          static_cast<int>(kSendEditReleaseIdleMs)) {
    return;
  }

  if (!g_active_send_volume_edits.empty()) {
    for (auto it = g_active_send_volume_edits.begin();
         it != g_active_send_volume_edits.end();) {
      bool release = force;
      if (!release) {
        const auto source_tick = g_send_source_activity_ticks.find(it->second.source);
        release = source_tick == g_send_source_activity_ticks.end() ||
                  static_cast<int>(now - source_tick->second) >=
                      static_cast<int>(kSendEditReleaseIdleMs);
      }

      if (!release) {
        ++it;
        continue;
      }

      const TrackSendKey target = it->first;
      if (target.track && target.send_index >= 0 &&
          target.send_index < GetTrackSendCount(target.track) &&
          IsTrackTrimReadMode(target.track)) {
        const double current = GetTrackSendInfo_Value(target.track, 0, target.send_index, "D_VOL");
        ScopedInternalChange guard;
        SetTrackSendVolumeForAutomation(target.track, target.send_index, current, 1);
      }
      it = g_active_send_volume_edits.erase(it);
    }
  }

  if (!g_active_send_pan_edits.empty()) {
    for (auto it = g_active_send_pan_edits.begin();
         it != g_active_send_pan_edits.end();) {
      bool release = force;
      if (!release) {
        const auto source_tick = g_send_source_activity_ticks.find(it->second.source);
        release = source_tick == g_send_source_activity_ticks.end() ||
                  static_cast<int>(now - source_tick->second) >=
                      static_cast<int>(kSendEditReleaseIdleMs);
      }

      if (!release) {
        ++it;
        continue;
      }

      const TrackSendKey target = it->first;
      if (target.track && target.send_index >= 0 &&
          target.send_index < GetTrackSendCount(target.track) &&
          IsTrackTrimReadMode(target.track)) {
        const double current = GetTrackSendInfo_Value(target.track, 0, target.send_index, "D_PAN");
        ScopedInternalChange guard;
        SetTrackSendPanForAutomation(target.track, target.send_index, current, 1);
      }
      it = g_active_send_pan_edits.erase(it);
    }
  }

  if (force) {
    g_send_source_activity_ticks.clear();
    g_last_send_source_activity_tick = 0;
  } else {
    const DWORD stale_after = kSendEditReleaseIdleMs * 8;
    for (auto it = g_send_source_activity_ticks.begin();
         it != g_send_source_activity_ticks.end();) {
      if (static_cast<int>(now - it->second) >= static_cast<int>(stale_after)) {
        it = g_send_source_activity_ticks.erase(it);
      } else {
        ++it;
      }
    }
  }
}

void PropagateSendVolumeDelta(MediaTrack* source_track,
                              const int send_index,
                              const double source_old_value,
                              const double source_new_value) {
  if (!source_track || send_index < 0) return;
  if (!IsTrackTrimReadMode(source_track)) return;
  if (!IsTrackSelected(source_track)) return;
  const TrackSendKey source_key{source_track, send_index};

  const auto stable_it = g_stable_send_links.find(source_key);
  if (stable_it == g_stable_send_links.end()) return;
  const StableSendLink& stable_link = stable_it->second;
  if (!stable_link.dest_track || stable_link.ordinal <= 0 || stable_link.ambiguous) return;

  const double linear_delta = source_new_value - source_old_value;
  const bool force_zero =
      source_old_value > 0.0 && source_new_value <= 0.0 &&
      std::isfinite(source_old_value) && std::isfinite(source_new_value);
  bool use_gain_ratio =
      source_old_value > 0.0 && source_new_value > 0.0 &&
      std::isfinite(source_old_value) && std::isfinite(source_new_value);
  double gain_ratio = 1.0;
  if (use_gain_ratio) {
    gain_ratio = source_new_value / source_old_value;
    if (!std::isfinite(gain_ratio) || gain_ratio <= 0.0) {
      use_gain_ratio = false;
    }
  }

  const auto& peer_tracks = GetCachedSendPeerTracks(source_key, stable_link);
  ScopedInternalChange guard;
  for (MediaTrack* track : peer_tracks) {
    if (!track) continue;
    if (!IsTrackTrimReadMode(track)) continue;

    const int target_send_index =
        FindCachedStableMatchingSendIndex(source_key, track, stable_link);
    if (target_send_index < 0) continue;

    const double current = GetTrackSendInfo_Value(track, 0, target_send_index, "D_VOL");
    double updated = 0.0;
    if (force_zero) {
      updated = 0.0;
    } else if (use_gain_ratio) {
      updated = std::max(0.0, current * gain_ratio);
    } else {
      updated = std::max(0.0, current + linear_delta);
    }
    if (!std::isfinite(updated)) {
      updated = 0.0;
    }
    if (!SetTrackSendVolumeForAutomation(track, target_send_index, updated, 0)) continue;

    const TrackSendKey key{track, target_send_index};
    auto& state = g_track_send_param_snapshot[key];
    state.volume = updated;
    MarkSuppressedSendWrite(&g_suppressed_send_volume_writes, key);
    MarkSendVolumeEditActive(key, source_key);
  }
}

void PropagateSendPanDelta(MediaTrack* source_track, const int send_index, const double delta) {
  if (!source_track || send_index < 0) return;
  if (delta == 0.0) return;
  if (!IsTrackTrimReadMode(source_track)) return;
  if (!IsTrackSelected(source_track)) return;

  const TrackSendKey source_key{source_track, send_index};
  const auto stable_it = g_stable_send_links.find(source_key);
  if (stable_it == g_stable_send_links.end()) return;
  const StableSendLink& stable_link = stable_it->second;
  if (!stable_link.dest_track || stable_link.ordinal <= 0 || stable_link.ambiguous) return;

  const auto& peer_tracks = GetCachedSendPeerTracks(source_key, stable_link);
  ScopedInternalChange guard;
  for (MediaTrack* track : peer_tracks) {
    if (!track) continue;
    if (!IsTrackTrimReadMode(track)) continue;

    const int target_send_index =
        FindCachedStableMatchingSendIndex(source_key, track, stable_link);
    if (target_send_index < 0) continue;

    const double current = GetTrackSendInfo_Value(track, 0, target_send_index, "D_PAN");
    const double updated = std::clamp(current + delta, -1.0, 1.0);
    if (!SetTrackSendPanForAutomation(track, target_send_index, updated, 0)) continue;

    const TrackSendKey key{track, target_send_index};
    auto& state = g_track_send_param_snapshot[key];
    state.pan = updated;
    MarkSuppressedSendWrite(&g_suppressed_send_pan_writes, key);
    MarkSendPanEditActive(key, source_key);
  }
}

void HandleSendVolumeDelta(MediaTrack* source_track, const int send_index, const double new_value) {
  if (!g_send_enabled || !source_track || send_index < 0) return;

  const TrackSendKey key{source_track, send_index};
  if (ConsumeSuppressedSendWrite(&g_suppressed_send_volume_writes, key)) {
    g_track_send_param_snapshot[key].volume = new_value;
    return;
  }
  if (IsTrackTrimReadMode(source_track)) {
    NoteSendSourceActivity(key);
  }

  auto existing = g_track_send_param_snapshot.find(key);
  if (existing == g_track_send_param_snapshot.end()) {
    TrackSendParamState source_state;
    if (ReadTrackSendParamState(source_track, send_index, &source_state)) {
      g_track_send_param_snapshot.emplace(key, source_state);
    } else {
      g_track_send_param_snapshot[key].volume = new_value;
    }
    return;
  }

  const double old_value = existing->second.volume;
  if (new_value == old_value) return;
  existing->second.volume = new_value;
  PropagateSendVolumeDelta(source_track, send_index, old_value, new_value);
}

void HandleSendPanDelta(MediaTrack* source_track, const int send_index, const double new_value) {
  if (!g_send_enabled || !source_track || send_index < 0) return;

  const TrackSendKey key{source_track, send_index};
  if (ConsumeSuppressedSendWrite(&g_suppressed_send_pan_writes, key)) {
    g_track_send_param_snapshot[key].pan = new_value;
    return;
  }
  if (IsTrackTrimReadMode(source_track)) {
    NoteSendSourceActivity(key);
  }

  auto existing = g_track_send_param_snapshot.find(key);
  if (existing == g_track_send_param_snapshot.end()) {
    TrackSendParamState source_state;
    if (ReadTrackSendParamState(source_track, send_index, &source_state)) {
      g_track_send_param_snapshot.emplace(key, source_state);
    } else {
      g_track_send_param_snapshot[key].pan = new_value;
    }
    return;
  }

  const double delta = new_value - existing->second.pan;
  if (delta == 0.0) return;
  existing->second.pan = new_value;
  PropagateSendPanDelta(source_track, send_index, delta);
}

void PropagateSendMuteState(MediaTrack* source_track, const int send_index, const bool muted) {
  if (!source_track || send_index < 0) return;
  if (!IsTrackTrimReadMode(source_track)) return;
  if (!IsTrackSelected(source_track)) return;
  const TrackSendKey source_key{source_track, send_index};
  const auto stable_it = g_stable_send_links.find(source_key);
  if (stable_it != g_stable_send_links.end()) {
    const StableSendLink& stable_link = stable_it->second;
    if (stable_link.dest_track && stable_link.ordinal > 0 && !stable_link.ambiguous) {
      const auto& peer_tracks = GetCachedSendPeerTracks(source_key, stable_link);
      ScopedInternalChange guard;
      for (MediaTrack* track : peer_tracks) {
        if (!track) continue;
        if (!IsTrackTrimReadMode(track)) continue;

        const int target_send_index =
            FindCachedStableMatchingSendIndex(source_key, track, stable_link);
        if (target_send_index < 0) continue;
        SetTrackSendInfo_Value(track, 0, target_send_index, "B_MUTE", muted ? 1.0 : 0.0);
      }
      return;
    }
  }

  const SendMatchInfo match_info =
      GetSendMatchInfoFromSnapshot(g_track_send_state_snapshot, source_track, send_index);
  if (!match_info.identity.dest_track || match_info.ordinal <= 0) return;

  const auto selected_tracks = GetSelectedTracksIncludingMaster();
  ScopedInternalChange guard;
  for (MediaTrack* track : selected_tracks) {
    if (!track || track == source_track) continue;
    if (!IsTrackTrimReadMode(track)) continue;

    const int target_send_index =
        FindMatchingSendIndex(track, match_info.identity, match_info.ordinal);
    if (target_send_index < 0) continue;
    SetTrackSendInfo_Value(track, 0, target_send_index, "B_MUTE", muted ? 1.0 : 0.0);
  }
}

void SyncTrackSendStatesFromSelection() {
  if (!g_send_enabled || g_internal_change_depth > 0) return;

  std::unordered_map<TrackSendKey, TrackSendState, TrackSendKeyHash> current_snapshot;
  BuildTrackSendStateSnapshot(&current_snapshot);

  if (HasTrackSendStructureChanged(g_track_send_state_snapshot, current_snapshot)) {
    ReleaseExpiredSendEdits(true);
    g_track_send_state_snapshot = std::move(current_snapshot);
    BuildTrackSendParamSnapshot(&g_track_send_param_snapshot);
    g_last_send_param_resync_tick = GetTickCount();
    RebuildStableSendLinks();
    g_suppressed_send_volume_writes.clear();
    g_suppressed_send_pan_writes.clear();
    return;
  }

  for (const auto& kv : current_snapshot) {
    const auto previous = g_track_send_state_snapshot.find(kv.first);
    if (previous == g_track_send_state_snapshot.end()) continue;
    if (previous->second.muted == kv.second.muted) continue;
    PropagateSendMuteState(kv.first.track, kv.first.send_index, kv.second.muted);
  }

  const DWORD now = GetTickCount();
  if (g_last_send_param_resync_tick == 0 ||
      static_cast<int>(now - g_last_send_param_resync_tick) >=
          static_cast<int>(kSendParamResyncIntervalMs)) {
    BuildTrackSendParamSnapshot(&g_track_send_param_snapshot);
    g_last_send_param_resync_tick = now;
  }

  g_track_send_state_snapshot = std::move(current_snapshot);
}

std::string GetTrackFxName(MediaTrack* track, const int fx_index) {
  if (!track || fx_index < 0) return {};
  char name[512] = {};
  if (!TrackFX_GetFXName(track, fx_index, name, static_cast<int>(sizeof(name)))) return {};
  return std::string(name);
}

std::string GetTakeFxName(MediaItem_Take* take, const int fx_index) {
  if (!take || fx_index < 0) return {};
  char name[512] = {};
  if (!TakeFX_GetFXName(take, fx_index, name, static_cast<int>(sizeof(name)))) return {};
  return std::string(name);
}

std::vector<std::string> GetTrackFxNameList(MediaTrack* track, const bool rec_fx) {
  std::vector<std::string> names;
  if (!track) return names;

  const int fx_count = rec_fx ? TrackFX_GetRecCount(track) : TrackFX_GetCount(track);
  names.reserve(static_cast<size_t>(fx_count));
  for (int i = 0; i < fx_count; ++i) {
    names.push_back(GetTrackFxName(track, (rec_fx ? kRecFxFlag : 0) | i));
  }
  return names;
}

std::vector<std::string> GetTrackFxNameListFromSnapshot(MediaTrack* track, const bool rec_fx) {
  std::vector<std::pair<int, std::string>> indexed;
  for (const auto& kv : g_track_fx_state_snapshot) {
    if (kv.first.track != track) continue;
    if (IsRecFxIndex(kv.first.fx_index) != rec_fx) continue;
    indexed.emplace_back(StripTrackFxFlags(kv.first.fx_index), kv.second.fx_name);
  }

  std::sort(indexed.begin(), indexed.end(),
            [](const auto& a, const auto& b) { return a.first < b.first; });

  std::vector<std::string> names;
  names.reserve(indexed.size());
  for (const auto& kv : indexed) {
    names.push_back(kv.second);
  }
  return names;
}

void PropagateDeletedTrackFx(MediaTrack* source_track,
                             const bool rec_fx,
                             const std::string& fx_name,
                             const int instance) {
  if (!source_track || fx_name.empty() || instance <= 0) return;
  if (!IsTrackSelected(source_track)) return;

  const auto selected_tracks = GetSelectedTracksIncludingMaster();
  ScopedInternalChange guard;
  for (MediaTrack* track : selected_tracks) {
    if (!track || track == source_track) continue;
    const int fx_count = rec_fx ? TrackFX_GetRecCount(track) : TrackFX_GetCount(track);
    int found_instance = 0;
    for (int i = 0; i < fx_count; ++i) {
      const int fx_idx = (rec_fx ? kRecFxFlag : 0) | i;
      if (GetTrackFxName(track, fx_idx) != fx_name) continue;
      ++found_instance;
      if (found_instance == instance) {
        TrackFX_Delete(track, fx_idx);
        break;
      }
    }
  }
}

void SyncTrackFxDeletionFromChange(MediaTrack* source_track, const bool rec_fx) {
  if (!source_track) return;

  std::vector<std::string> old_names = GetTrackFxNameListFromSnapshot(source_track, rec_fx);
  const std::vector<std::string> new_names = GetTrackFxNameList(source_track, rec_fx);
  if (old_names.size() <= new_names.size()) return;

  while (old_names.size() > new_names.size()) {
    size_t delete_pos = 0;
    while (delete_pos < new_names.size() && old_names[delete_pos] == new_names[delete_pos]) {
      ++delete_pos;
    }
    if (delete_pos >= old_names.size()) {
      break;
    }

    const std::string deleted_name = old_names[delete_pos];
    int deleted_instance = 1;
    for (size_t i = 0; i < delete_pos; ++i) {
      if (old_names[i] == deleted_name) ++deleted_instance;
    }

    PropagateDeletedTrackFx(source_track, rec_fx, deleted_name, deleted_instance);
    old_names.erase(old_names.begin() + delete_pos);
  }
}

int GetTrackFxCountByType(MediaTrack* track, const bool rec_fx) {
  if (!track) return 0;
  return rec_fx ? TrackFX_GetRecCount(track) : TrackFX_GetCount(track);
}

int GetTrackFxInstanceNumber(MediaTrack* track, const int fx_index, const std::string& fx_name) {
  if (!track || fx_name.empty() || fx_index < 0 || IsContainerFxIndex(fx_index)) return -1;

  const auto cached = g_track_fx_instance_lookup.find(TrackFxStateKey{track, fx_index});
  if (cached != g_track_fx_instance_lookup.end()) {
    return cached->second;
  }

  const bool rec_fx = IsRecFxIndex(fx_index);
  const int raw_index = StripTrackFxFlags(fx_index);
  const int fx_count = GetTrackFxCountByType(track, rec_fx);
  if (raw_index >= fx_count) return -1;

  int instance = 1;
  for (int i = 0; i < raw_index; ++i) {
    const int idx = MakeTrackFxIndex(rec_fx, i);
    if (GetTrackFxName(track, idx) == fx_name) {
      ++instance;
    }
  }
  return instance;
}

int FindTrackFxInstance(MediaTrack* track,
                        const std::string& fx_name,
                        const int target_instance,
                        const bool rec_fx) {
  if (!track || fx_name.empty() || target_instance <= 0) return -1;

  const auto cached = g_track_fx_lookup.find(TrackFxLookupKey{
      track,
      rec_fx,
      target_instance,
      fx_name,
  });
  if (cached != g_track_fx_lookup.end()) {
    return cached->second;
  }

  const int fx_count = GetTrackFxCountByType(track, rec_fx);
  int instance = 0;
  for (int i = 0; i < fx_count; ++i) {
    const int idx = MakeTrackFxIndex(rec_fx, i);
    if (GetTrackFxName(track, idx) == fx_name) {
      ++instance;
      if (instance == target_instance) return idx;
    }
  }
  return -1;
}

int GetTakeFxInstanceNumber(MediaItem_Take* take, const int fx_index, const std::string& fx_name) {
  if (!take || fx_name.empty() || fx_index < 0 || IsContainerFxIndex(fx_index)) return -1;
  const int fx_count = TakeFX_GetCount(take);
  if (fx_index >= fx_count) return -1;

  int instance = 1;
  for (int i = 0; i < fx_index; ++i) {
    if (GetTakeFxName(take, i) == fx_name) {
      ++instance;
    }
  }
  return instance;
}

int FindTakeFxInstance(MediaItem_Take* take,
                       const std::string& fx_name,
                       const int target_instance) {
  if (!take || fx_name.empty() || target_instance <= 0) return -1;
  const int fx_count = TakeFX_GetCount(take);
  int instance = 0;
  for (int i = 0; i < fx_count; ++i) {
    if (GetTakeFxName(take, i) == fx_name) {
      ++instance;
      if (instance == target_instance) return i;
    }
  }
  return -1;
}

void ClearTrackFxTargetIndexCache() {
  g_track_fx_target_index_cache.clear();
}

void ClearTrackFxLookupCaches() {
  g_track_fx_instance_lookup.clear();
  g_track_fx_lookup.clear();
  ClearTrackFxTargetIndexCache();
}

void RebuildTrackFxLookupFromSelection() {
  const size_t instance_hint = g_track_fx_instance_lookup.size();
  const size_t lookup_hint = g_track_fx_lookup.size();
  g_track_fx_instance_lookup.clear();
  g_track_fx_lookup.clear();
  ClearTrackFxTargetIndexCache();
  g_track_fx_instance_lookup.reserve(instance_hint);
  g_track_fx_lookup.reserve(lookup_hint);

  const auto selected_tracks = GetSelectedTracksIncludingMaster();
  for (MediaTrack* track : selected_tracks) {
    if (!track) continue;

    for (int pass = 0; pass < 2; ++pass) {
      const bool rec_fx = pass == 1;
      const int fx_count = GetTrackFxCountByType(track, rec_fx);
      if (fx_count <= 0) continue;

      std::unordered_map<std::string, int> fx_name_ordinals;
      fx_name_ordinals.reserve(static_cast<size_t>(fx_count));
      for (int raw_index = 0; raw_index < fx_count; ++raw_index) {
        const int fx_index = MakeTrackFxIndex(rec_fx, raw_index);
        const std::string fx_name = GetTrackFxName(track, fx_index);
        if (fx_name.empty()) continue;

        const int instance = ++fx_name_ordinals[fx_name];
        g_track_fx_instance_lookup[TrackFxStateKey{track, fx_index}] = instance;
        g_track_fx_lookup[TrackFxLookupKey{track, rec_fx, instance, fx_name}] = fx_index;
      }
    }
  }
}

std::string GetTrackFxNameFromSnapshotOrLive(MediaTrack* track, const int fx_index) {
  const auto snapshot_it = g_track_fx_state_snapshot.find(TrackFxStateKey{track, fx_index});
  if (snapshot_it != g_track_fx_state_snapshot.end() && !snapshot_it->second.fx_name.empty()) {
    return snapshot_it->second.fx_name;
  }
  return GetTrackFxName(track, fx_index);
}

int FindCachedTrackFxMatchIndex(MediaTrack* source_track,
                                const int source_fx_index,
                                MediaTrack* target_track,
                                const std::string& source_fx_name,
                                const int source_instance,
                                const bool rec_fx) {
  if (!source_track || source_fx_index < 0 || !target_track || source_fx_name.empty() ||
      source_instance <= 0) {
    return -1;
  }

  const TrackFxTargetCacheKey cache_key{source_track, source_fx_index, target_track};
  const auto cached = g_track_fx_target_index_cache.find(cache_key);
  if (cached != g_track_fx_target_index_cache.end()) {
    return cached->second;
  }

  const int target_fx_index =
      FindTrackFxInstance(target_track, source_fx_name, source_instance, rec_fx);
  g_track_fx_target_index_cache.emplace(cache_key, target_fx_index);
  return target_fx_index;
}

bool ShouldFlushTrackParamDeltaImmediately() {
  if (!kTrackDeltaFlushImmediately) return false;

  int selected_count = CountSelectedTracks(nullptr);
  MediaTrack* master_track = GetMasterTrack(nullptr);
  if (master_track && IsTrackSelected(master_track)) {
    ++selected_count;
  }

  return selected_count <= kImmediateTrackDeltaFlushTrackThreshold;
}

MediaItem_Take* ResolveFocusedItemTake(const FocusedItemFx& focused, MediaItem** item_out = nullptr) {
  if (!focused.IsValid()) return nullptr;

  MediaTrack* track = GetTrack(nullptr, focused.track_index);
  if (!track) return nullptr;

  MediaItem* item = GetTrackMediaItem(track, focused.item_index);
  if (!item) return nullptr;

  if (item_out) {
    *item_out = item;
  }

  return GetMediaItemTake(item, focused.take_index);
}

bool ReadFocusedItemFx(FocusedItemFx* focused_out) {
  if (!focused_out) return false;

  int track_index = -1;
  int item_index = -1;
  int take_index = -1;
  int fx_index = -1;
  int parm_out = 0;
  if (!GetTouchedOrFocusedFX(1, &track_index, &item_index, &take_index, &fx_index, &parm_out)) {
    return false;
  }
  if (item_index < 0 || track_index < 0 || take_index < 0 || fx_index < 0 ||
      IsContainerFxIndex(fx_index)) {
    return false;
  }

  MediaTrack* track = GetTrack(nullptr, track_index);
  if (!track) return false;
  MediaItem* item = GetTrackMediaItem(track, item_index);
  if (!item) return false;
  MediaItem_Take* take = GetMediaItemTake(item, take_index);
  if (!take) return false;
  const std::string fx_name = GetTakeFxName(take, fx_index);
  if (fx_name.empty()) return false;

  focused_out->track_index = track_index;
  focused_out->item_index = item_index;
  focused_out->take_index = take_index;
  focused_out->fx_index = fx_index;
  focused_out->fx_name = fx_name;
  return true;
}

bool IsSameFocusedItemFx(const FocusedItemFx& a, const FocusedItemFx& b) {
  return a.track_index == b.track_index && a.item_index == b.item_index &&
         a.take_index == b.take_index && a.fx_index == b.fx_index;
}

void CreateTrackFxStateSnapshot();
void CreateItemFxStateSnapshot();
void SyncTrackFxStatesFromSelection();
void SyncTrackSendStatesFromSelection();
void SyncItemFxStates();
void PollFocusedItemFxAndSync();
void FlushTrackParamDeltas(bool force = false);
void ReleaseExpiredParamEdits(bool force = false);
bool HasActiveParamEdits();

void ResetSnapshots() {
  g_track_param_snapshot.clear();
  g_pending_track_param_deltas.clear();
  g_suppressed_track_param_writes.clear();
  g_track_source_activity_ticks.clear();
  g_active_track_param_edits.clear();
  g_take_source_activity_ticks.clear();
  g_active_take_param_edits.clear();
  g_track_fx_state_snapshot.clear();
  g_item_fx_state_snapshot.clear();
  g_item_param_snapshot.clear();
  ClearTrackFxLookupCaches();
  g_focused_item_fx = FocusedItemFx();
  g_last_track_delta_flush_tick = 0;
}

void ResetSendSnapshots() {
  g_track_send_param_snapshot.clear();
  g_track_send_state_snapshot.clear();
  g_stable_send_links.clear();
  g_send_lookup_index.clear();
  ClearSendTargetIndexCache();
  ClearSendPeerTrackCache();
  g_suppressed_send_volume_writes.clear();
  g_suppressed_send_pan_writes.clear();
  g_send_source_activity_ticks.clear();
  g_active_send_volume_edits.clear();
  g_active_send_pan_edits.clear();
  g_last_send_source_activity_tick = 0;
  g_last_send_param_resync_tick = 0;
}

bool HasActiveParamEdits() {
  return !g_active_track_param_edits.empty() || !g_active_take_param_edits.empty();
}

bool IsAutomationPlaybackDrivingTrackParam(MediaTrack* track,
                                           const int fx_index,
                                           const int param_index) {
  if (!track || fx_index < 0 || param_index < 0) return false;
  TrackEnvelope* env = GetFXEnvelope(track, fx_index, param_index, false);
  if (!env) return false;

  const int env_state = GetEnvelopeUIState(env);
  const bool playback = (env_state & 1) != 0;
  const bool writing = (env_state & 2) != 0;
  return playback && !writing;
}

void CleanupSuppressedWrites() {
  if (g_suppressed_track_param_writes.empty()) return;
  const DWORD now = GetTickCount();
  for (auto it = g_suppressed_track_param_writes.begin();
       it != g_suppressed_track_param_writes.end();) {
    if (static_cast<int>(now - it->second.expires_at) >= 0) {
      it = g_suppressed_track_param_writes.erase(it);
    } else {
      ++it;
    }
  }
}

void MarkSuppressedWrite(const TrackParamKey& key) {
  auto& entry = g_suppressed_track_param_writes[key];
  ++entry.pending_callbacks;
  entry.expires_at = GetTickCount() + kSuppressionEntryLifetimeMs;
}

bool ConsumeSuppressedWrite(const TrackParamKey& key) {
  const auto it = g_suppressed_track_param_writes.find(key);
  if (it == g_suppressed_track_param_writes.end()) return false;

  const DWORD now = GetTickCount();
  if (static_cast<int>(now - it->second.expires_at) >= 0) {
    g_suppressed_track_param_writes.erase(it);
    return false;
  }

  if (it->second.pending_callbacks <= 0) {
    g_suppressed_track_param_writes.erase(it);
    return false;
  }

  --it->second.pending_callbacks;
  if (it->second.pending_callbacks == 0) {
    g_suppressed_track_param_writes.erase(it);
  }
  return true;
}

void NoteTrackSourceActivity(const TrackParamKey& source) {
  g_track_source_activity_ticks[source] = GetTickCount();
}

void NoteTakeSourceActivity(const TakeParamKey& source) {
  g_take_source_activity_ticks[source] = GetTickCount();
}

void MarkTrackParamEditActive(const TrackParamKey& target, const TrackParamKey& source) {
  g_active_track_param_edits[target] = ActiveTrackParamEdit{source};
}

void MarkTakeParamEditActive(const TakeParamKey& target, const TakeParamKey& source) {
  g_active_take_param_edits[target] = ActiveTakeParamEdit{source};
}

void ReleaseExpiredParamEdits(const bool force) {
  if (!force && !HasActiveParamEdits()) return;

  const DWORD now = GetTickCount();
  int released_track = 0;
  int released_take = 0;

  if (!g_active_track_param_edits.empty()) {
    for (auto it = g_active_track_param_edits.begin();
         it != g_active_track_param_edits.end();) {
      bool release = force;
      if (!release) {
        const auto source_tick = g_track_source_activity_ticks.find(it->second.source);
        release = source_tick == g_track_source_activity_ticks.end() ||
                  static_cast<int>(now - source_tick->second) >=
                      static_cast<int>(kParamEditReleaseIdleMs);
      }

      if (!release) {
        ++it;
        continue;
      }

      ScopedInternalChange guard;
      TrackFX_EndParamEdit(it->first.track, it->first.fx_index, it->first.param_index);
      it = g_active_track_param_edits.erase(it);
      ++released_track;
    }
  }

  if (!g_active_take_param_edits.empty()) {
    for (auto it = g_active_take_param_edits.begin();
         it != g_active_take_param_edits.end();) {
      bool release = force;
      if (!release) {
        const auto source_tick = g_take_source_activity_ticks.find(it->second.source);
        release = source_tick == g_take_source_activity_ticks.end() ||
                  static_cast<int>(now - source_tick->second) >=
                      static_cast<int>(kParamEditReleaseIdleMs);
      }

      if (!release) {
        ++it;
        continue;
      }

      ScopedInternalChange guard;
      TakeFX_EndParamEdit(it->first.take, it->first.fx_index, it->first.param_index);
      it = g_active_take_param_edits.erase(it);
      ++released_take;
    }
  }

  if (force) {
    g_track_source_activity_ticks.clear();
    g_take_source_activity_ticks.clear();
  } else {
    const DWORD stale_after = kParamEditReleaseIdleMs * 8;
    for (auto it = g_track_source_activity_ticks.begin();
         it != g_track_source_activity_ticks.end();) {
      if (static_cast<int>(now - it->second) >= static_cast<int>(stale_after)) {
        it = g_track_source_activity_ticks.erase(it);
      } else {
        ++it;
      }
    }
    for (auto it = g_take_source_activity_ticks.begin();
         it != g_take_source_activity_ticks.end();) {
      if (static_cast<int>(now - it->second) >= static_cast<int>(stale_after)) {
        it = g_take_source_activity_ticks.erase(it);
      } else {
        ++it;
      }
    }
  }

  if (released_track > 0 || released_take > 0 || force) {
    DebugTouchLog("[touch reset] force=%d idle_ms=%lu released track_edits=%d take_edits=%d",
                  force ? 1 : 0,
                  static_cast<unsigned long>(kParamEditReleaseIdleMs),
                  released_track,
                  released_take);
  }
}

void PropagateTrackFxState(MediaTrack* source_track,
                           const int source_fx_index,
                           const std::string& fx_name,
                           const bool enabled,
                           const bool offline) {
  if (!source_track || source_fx_index < 0 || IsContainerFxIndex(source_fx_index)) {
    return;
  }
  if (!IsTrackSelected(source_track)) return;

  const std::string resolved_fx_name =
      fx_name.empty() ? GetTrackFxNameFromSnapshotOrLive(source_track, source_fx_index) : fx_name;
  if (resolved_fx_name.empty()) return;

  const bool rec_fx = IsRecFxIndex(source_fx_index);
  const int source_instance =
      GetTrackFxInstanceNumber(source_track, source_fx_index, resolved_fx_name);
  if (source_instance <= 0) return;

  const auto selected_tracks = GetSelectedTracksIncludingMaster();
  ScopedInternalChange guard;
  for (MediaTrack* track : selected_tracks) {
    if (!track || track == source_track) continue;
    const int target_fx_index = FindCachedTrackFxMatchIndex(
        source_track,
        source_fx_index,
        track,
        resolved_fx_name,
        source_instance,
        rec_fx);
    if (target_fx_index < 0) continue;
    TrackFX_SetEnabled(track, target_fx_index, enabled);
    TrackFX_SetOffline(track, target_fx_index, offline);
  }
}

void PropagateItemFxState(MediaItem_Take* source_take,
                          const int source_fx_index,
                          const std::string& fx_name,
                          const bool enabled,
                          const bool offline) {
  if (!source_take || source_fx_index < 0 || fx_name.empty() || IsContainerFxIndex(source_fx_index)) {
    return;
  }

  MediaItem* source_item = GetMediaItemTake_Item(source_take);
  if (!source_item || !IsMediaItemSelected(source_item)) return;

  const int source_instance = GetTakeFxInstanceNumber(source_take, source_fx_index, fx_name);
  if (source_instance <= 0) return;

  const auto selected_items = GetSelectedItems();
  ScopedInternalChange guard;
  for (MediaItem* item : selected_items) {
    if (!item) continue;
    MediaItem_Take* take = GetActiveTake(item);
    if (!take || take == source_take) continue;
    const int target_fx_index = FindTakeFxInstance(take, fx_name, source_instance);
    if (target_fx_index < 0) continue;
    TakeFX_SetEnabled(take, target_fx_index, enabled);
    TakeFX_SetOffline(take, target_fx_index, offline);
  }
}

void HandleTrackFxParamDelta(MediaTrack* source_track,
                             const int source_fx_index,
                             const int param_index,
                             const double new_value) {
  if (!source_track || source_fx_index < 0 || param_index < 0 || IsContainerFxIndex(source_fx_index)) {
    return;
  }

  const TrackParamKey key {source_track, source_fx_index, param_index};
  if (ConsumeSuppressedWrite(key)) {
    g_track_param_snapshot[key] = new_value;
    return;
  }

  const auto existing = g_track_param_snapshot.find(key);
  if (existing == g_track_param_snapshot.end()) {
    g_track_param_snapshot.emplace(key, new_value);
    return;
  }

  const double delta = new_value - existing->second;
  existing->second = new_value;
  if (delta == 0.0) return;
  if (!IsTrackSelected(source_track)) return;
  if (IsAutomationPlaybackDrivingTrackParam(source_track, source_fx_index, param_index)) return;

  NoteTrackSourceActivity(key);
  g_pending_track_param_deltas[key] += delta;
  if (ShouldFlushTrackParamDeltaImmediately()) {
    FlushTrackParamDeltas(true);
  }
}

void FlushTrackParamDeltas(const bool force) {
  if (!g_enabled || g_internal_change_depth > 0) return;
  if (g_pending_track_param_deltas.empty()) return;

  const DWORD now = GetTickCount();
  if (!force &&
      g_last_track_delta_flush_tick != 0 &&
      (now - g_last_track_delta_flush_tick) < kTrackDeltaFlushIntervalMs) {
    return;
  }
  g_last_track_delta_flush_tick = now;

  auto pending = std::move(g_pending_track_param_deltas);
  g_pending_track_param_deltas.clear();

  const auto selected_tracks = GetSelectedTracksIncludingMaster();
  if (selected_tracks.size() <= 1) return;

  ScopedInternalChange guard;
  for (const auto& kv : pending) {
    const TrackParamKey& source_key = kv.first;
    const double delta = kv.second;
    if (delta == 0.0) continue;

    MediaTrack* source_track = source_key.track;
    const int source_fx_index = source_key.fx_index;
    const int param_index = source_key.param_index;

    if (!source_track || source_fx_index < 0 || param_index < 0 ||
        IsContainerFxIndex(source_fx_index) || !IsTrackSelected(source_track)) {
      continue;
    }

    const std::string fx_name =
        GetTrackFxNameFromSnapshotOrLive(source_track, source_fx_index);
    if (fx_name.empty()) continue;

    const bool rec_fx = IsRecFxIndex(source_fx_index);
    const int source_instance =
        GetTrackFxInstanceNumber(source_track, source_fx_index, fx_name);
    if (source_instance <= 0) continue;

    for (MediaTrack* track : selected_tracks) {
      if (!track || track == source_track) continue;
      const int target_fx_index =
          FindCachedTrackFxMatchIndex(
              source_track,
              source_fx_index,
              track,
              fx_name,
              source_instance,
              rec_fx);
      if (target_fx_index < 0) continue;

      const double current_value =
          TrackFX_GetParamNormalized(track, target_fx_index, param_index);
      const double new_target_value = Clamp01(current_value + delta);

      const TrackParamKey target_key{track, target_fx_index, param_index};
      g_track_param_snapshot[target_key] = new_target_value;
      MarkSuppressedWrite(target_key);
      TrackFX_SetParamNormalized(track, target_fx_index, param_index, new_target_value);
      MarkTrackParamEditActive(target_key, source_key);
    }
  }
}

void SyncItemParamDelta(const int param_index, const double delta) {
  if (delta == 0.0 || !g_focused_item_fx.IsValid()) return;

  MediaItem* source_item = nullptr;
  MediaItem_Take* source_take = ResolveFocusedItemTake(g_focused_item_fx, &source_item);
  if (!source_take || !source_item || !IsMediaItemSelected(source_item)) return;

  const int source_instance =
      GetTakeFxInstanceNumber(source_take, g_focused_item_fx.fx_index, g_focused_item_fx.fx_name);
  if (source_instance <= 0) return;
  const TakeParamKey source_key{source_take, g_focused_item_fx.fx_index, param_index};
  NoteTakeSourceActivity(source_key);

  const auto selected_items = GetSelectedItems();
  ScopedInternalChange guard;
  for (MediaItem* item : selected_items) {
    if (!item) continue;
    MediaItem_Take* take = GetActiveTake(item);
    if (!take || take == source_take) continue;
    const int target_fx_index = FindTakeFxInstance(take, g_focused_item_fx.fx_name, source_instance);
    if (target_fx_index < 0) continue;

    const double current_value =
        TakeFX_GetParamNormalized(take, target_fx_index, param_index);
    const double new_target_value = Clamp01(current_value + delta);
    TakeFX_SetParamNormalized(take, target_fx_index, param_index, new_target_value);
    MarkTakeParamEditActive(TakeParamKey{take, target_fx_index, param_index}, source_key);
  }
}

void CreateItemParamSnapshot() {
  g_item_param_snapshot.clear();
  if (!g_focused_item_fx.IsValid()) return;

  MediaItem_Take* take = ResolveFocusedItemTake(g_focused_item_fx);
  if (!take) return;

  const int param_count = TakeFX_GetNumParams(take, g_focused_item_fx.fx_index);
  for (int i = 0; i < param_count; ++i) {
    g_item_param_snapshot[i] =
        TakeFX_GetParamNormalized(take, g_focused_item_fx.fx_index, i);
  }
}

void UpdateAndSyncItemParams() {
  if (!g_focused_item_fx.IsValid()) return;

  MediaItem_Take* take = ResolveFocusedItemTake(g_focused_item_fx);
  if (!take) {
    g_item_param_snapshot.clear();
    return;
  }

  const int param_count = TakeFX_GetNumParams(take, g_focused_item_fx.fx_index);
  for (int param_index = 0; param_index < param_count; ++param_index) {
    const double current_value =
        TakeFX_GetParamNormalized(take, g_focused_item_fx.fx_index, param_index);

    const auto existing = g_item_param_snapshot.find(param_index);
    if (existing != g_item_param_snapshot.end()) {
      const double delta = current_value - existing->second;
      if (delta != 0.0) {
        SyncItemParamDelta(param_index, delta);
      }
      existing->second = current_value;
    } else {
      g_item_param_snapshot.emplace(param_index, current_value);
    }
  }
}

void BuildTrackFxStateSnapshot(std::unordered_map<TrackFxStateKey, FxState, TrackFxStateKeyHash>* snapshot_out) {
  if (!snapshot_out) return;
  const size_t reserve_hint = snapshot_out->size();
  snapshot_out->clear();
  snapshot_out->reserve(reserve_hint);

  const auto selected_tracks = GetSelectedTracksIncludingMaster();
  for (MediaTrack* track : selected_tracks) {
    if (!track) continue;

    const int normal_count = TrackFX_GetCount(track);
    for (int fx_index = 0; fx_index < normal_count; ++fx_index) {
      const std::string fx_name = GetTrackFxName(track, fx_index);
      if (fx_name.empty()) continue;
      (*snapshot_out)[TrackFxStateKey{track, fx_index}] = FxState{
          fx_name,
          TrackFX_GetEnabled(track, fx_index),
          TrackFX_GetOffline(track, fx_index),
      };
    }

    const int rec_count = TrackFX_GetRecCount(track);
    for (int i = 0; i < rec_count; ++i) {
      const int fx_index = kRecFxFlag | i;
      const std::string fx_name = GetTrackFxName(track, fx_index);
      if (fx_name.empty()) continue;
      (*snapshot_out)[TrackFxStateKey{track, fx_index}] = FxState{
          fx_name,
          TrackFX_GetEnabled(track, fx_index),
          TrackFX_GetOffline(track, fx_index),
      };
    }
  }
}

void CreateTrackFxStateSnapshot() {
  BuildTrackFxStateSnapshot(&g_track_fx_state_snapshot);
  RebuildTrackFxLookupFromSelection();
}

void BuildItemFxStateSnapshot(std::unordered_map<ItemFxStateKey, FxState, ItemFxStateKeyHash>* snapshot_out) {
  if (!snapshot_out) return;
  const size_t reserve_hint = snapshot_out->size();
  snapshot_out->clear();
  snapshot_out->reserve(reserve_hint);

  const auto selected_items = GetSelectedItems();
  for (MediaItem* item : selected_items) {
    if (!item) continue;
    MediaItem_Take* take = GetActiveTake(item);
    if (!take) continue;

    const int fx_count = TakeFX_GetCount(take);
    for (int fx_index = 0; fx_index < fx_count; ++fx_index) {
      const std::string fx_name = GetTakeFxName(take, fx_index);
      if (fx_name.empty()) continue;
      (*snapshot_out)[ItemFxStateKey{take, fx_index}] = FxState{
          fx_name,
          TakeFX_GetEnabled(take, fx_index),
          TakeFX_GetOffline(take, fx_index),
      };
    }
  }
}

void CreateItemFxStateSnapshot() {
  BuildItemFxStateSnapshot(&g_item_fx_state_snapshot);
}

void SyncTrackFxStatesFromSelection() {
  if (!g_enabled || g_internal_change_depth > 0) return;

  std::unordered_map<TrackFxStateKey, FxState, TrackFxStateKeyHash> current_snapshot;
  BuildTrackFxStateSnapshot(&current_snapshot);

  for (const auto& kv : current_snapshot) {
    const auto previous = g_track_fx_state_snapshot.find(kv.first);
    if (previous == g_track_fx_state_snapshot.end()) continue;

    const FxState& prev = previous->second;
    const FxState& curr = kv.second;
    if (prev.enabled == curr.enabled && prev.offline == curr.offline) continue;

    PropagateTrackFxState(
        kv.first.track,
        kv.first.fx_index,
        curr.fx_name,
        curr.enabled,
        curr.offline);
  }

  g_track_fx_state_snapshot = std::move(current_snapshot);
  RebuildTrackFxLookupFromSelection();
}

void SyncItemFxStates() {
  if (!g_enabled || g_internal_change_depth > 0) return;

  std::unordered_map<ItemFxStateKey, FxState, ItemFxStateKeyHash> current_snapshot;
  BuildItemFxStateSnapshot(&current_snapshot);

  for (const auto& kv : current_snapshot) {
    const auto previous = g_item_fx_state_snapshot.find(kv.first);
    if (previous == g_item_fx_state_snapshot.end()) continue;

    const FxState& prev = previous->second;
    const FxState& curr = kv.second;
    if (prev.enabled == curr.enabled && prev.offline == curr.offline) continue;

    PropagateItemFxState(
        kv.first.take,
        kv.first.fx_index,
        curr.fx_name,
        curr.enabled,
        curr.offline);
  }

  g_item_fx_state_snapshot = std::move(current_snapshot);
}

void PollFocusedItemFxAndSync() {
  if (!g_enabled || g_internal_change_depth > 0) return;

  FocusedItemFx current_focus;
  const bool has_focus = ReadFocusedItemFx(&current_focus);
  if (!has_focus) {
    g_focused_item_fx = FocusedItemFx();
    g_item_param_snapshot.clear();
    return;
  }

  if (!IsSameFocusedItemFx(current_focus, g_focused_item_fx)) {
    g_focused_item_fx = std::move(current_focus);
    CreateItemParamSnapshot();
  }

  UpdateAndSyncItemParams();
}

void SetEnabled(const bool enabled) {
  if (g_enabled == enabled) return;

  if (!enabled && g_enabled) {
    FlushTrackParamDeltas(true);
    ReleaseExpiredParamEdits(true);
  }

  g_enabled = enabled;
  SaveGlobalToggleState();
  ResetSnapshots();

  if (g_enabled) {
    CreateTrackParamSnapshot();
    CreateTrackFxStateSnapshot();
    CreateItemFxStateSnapshot();
    PollFocusedItemFxAndSync();
  }
}

void SetSendEnabled(const bool enabled) {
  if (g_send_enabled == enabled) return;

  if (!enabled && g_send_enabled) {
    ReleaseExpiredSendEdits(true);
  }

  g_send_enabled = enabled;
  SaveGlobalToggleState();
  ResetSendSnapshots();
  if (g_send_enabled) {
    CreateTrackSendSnapshots();
  }
}

bool HookCommand2(KbdSectionInfo* section,
                  const int command,
                  int val,
                  int val2,
                  int relmode,
                  HWND hwnd) {
  (void)section;
  (void)val;
  (void)val2;
  (void)relmode;
  (void)hwnd;
  if (command == g_toggle_command_id) {
    SetEnabled(!g_enabled);
    return true;
  }
  if (command == g_send_toggle_command_id) {
    SetSendEnabled(!g_send_enabled);
    return true;
  }
  return false;
}

int ToggleActionCallback(const int command_id) {
  if (command_id == g_toggle_command_id) return g_enabled ? 1 : 0;
  if (command_id == g_send_toggle_command_id) return g_send_enabled ? 1 : 0;
  return -1;
}

void TimerTick() {
  if (g_internal_change_depth > 0) return;
  if (!g_enabled && !g_send_enabled) return;

  if (g_enabled) {
    CleanupSuppressedWrites();
    FlushTrackParamDeltas();
    ReleaseExpiredParamEdits();
    SyncItemFxStates();
    PollFocusedItemFxAndSync();
  }

  if (g_send_enabled) {
    CleanupSuppressedSendWrites(&g_suppressed_send_volume_writes);
    CleanupSuppressedSendWrites(&g_suppressed_send_pan_writes);
    SyncTrackSendStatesFromSelection();
    KeepSendEditsAlive();
    ReleaseExpiredSendEdits();
  }
}

class FxLinkSurface final : public IReaperControlSurface {
public:
  const char* GetTypeString() override { return "R7FXLINKREL"; }
  const char* GetDescString() override { return "7R FX and Send Sync"; }
  const char* GetConfigString() override { return ""; }

  void SetTrackListChange() override {
    if (!g_enabled && !g_send_enabled) return;
    if (g_enabled) {
      g_track_param_snapshot.clear();
      g_pending_track_param_deltas.clear();
      g_suppressed_track_param_writes.clear();
      SyncTrackFxStatesFromSelection();
      CreateTrackParamSnapshot();
    }
    if (g_send_enabled) {
      g_suppressed_send_volume_writes.clear();
      g_suppressed_send_pan_writes.clear();
      CreateTrackSendSnapshots();
    }
  }

  void OnTrackSelection(MediaTrack* track) override {
    (void)track;
    if (!g_enabled && !g_send_enabled) return;
    if (g_enabled) {
      g_track_param_snapshot.clear();
      g_pending_track_param_deltas.clear();
      g_suppressed_track_param_writes.clear();
      SyncTrackFxStatesFromSelection();
      CreateTrackParamSnapshot();
    }
    if (g_send_enabled) {
      g_suppressed_send_volume_writes.clear();
      g_suppressed_send_pan_writes.clear();
      CreateTrackSendSnapshots();
    }
  }

  int Extended(const int call, void* parm1, void* parm2, void* parm3) override {
    if (g_internal_change_depth > 0) return 0;

    switch (call) {
      case CSURF_EXT_SETSENDVOLUME: {
        if (!g_send_enabled) return 0;
        auto* source_track = static_cast<MediaTrack*>(parm1);
        auto* send_index = static_cast<int*>(parm2);
        auto* value = static_cast<double*>(parm3);
        if (!source_track || !send_index || !value) return 0;
        HandleSendVolumeDelta(source_track, *send_index, *value);
        return 0;
      }

      case CSURF_EXT_SETSENDPAN: {
        if (!g_send_enabled) return 0;
        auto* source_track = static_cast<MediaTrack*>(parm1);
        auto* send_index = static_cast<int*>(parm2);
        auto* value = static_cast<double*>(parm3);
        if (!source_track || !send_index || !value) return 0;
        HandleSendPanDelta(source_track, *send_index, *value);
        return 0;
      }

      case CSURF_EXT_SETFXPARAM:
      case CSURF_EXT_SETFXPARAM_RECFX: {
        if (!g_enabled) return 0;
        auto* source_track = static_cast<MediaTrack*>(parm1);
        auto* packed_indices = static_cast<int*>(parm2);
        auto* value = static_cast<double*>(parm3);
        if (!source_track || !packed_indices || !value) return 0;

        const unsigned int packed = static_cast<unsigned int>(*packed_indices);
        int fx_index = static_cast<int>((packed >> 16U) & 0xFFFFU);
        const int param_index = static_cast<int>(packed & 0xFFFFU);
        if (call == CSURF_EXT_SETFXPARAM_RECFX) {
          fx_index |= kRecFxFlag;
        }

        HandleTrackFxParamDelta(source_track, fx_index, param_index, *value);
        return 0;
      }

      case CSURF_EXT_SETFXENABLED: {
        if (!g_enabled) return 0;
        auto* source_track = static_cast<MediaTrack*>(parm1);
        auto* fx_index = static_cast<int*>(parm2);
        if (!source_track || !fx_index) return 0;

        const bool enabled = reinterpret_cast<std::intptr_t>(parm3) != 0;
        const int index = *fx_index;
        if (index < 0 || IsContainerFxIndex(index)) return 0;

        const std::string fx_name = GetTrackFxName(source_track, index);
        if (fx_name.empty()) return 0;
        const bool offline = TrackFX_GetOffline(source_track, index);
        PropagateTrackFxState(source_track, index, fx_name, enabled, offline);
        CreateTrackFxStateSnapshot();
        return 0;
      }

      case CSURF_EXT_SETFXCHANGE: {
        if (!g_enabled) return 0;
        auto* source_track = static_cast<MediaTrack*>(parm1);
        const bool rec_fx = (reinterpret_cast<std::intptr_t>(parm2) & 1) != 0;
        SyncTrackFxDeletionFromChange(source_track, rec_fx);

        g_track_param_snapshot.clear();
        g_pending_track_param_deltas.clear();
        g_suppressed_track_param_writes.clear();
        SyncTrackFxStatesFromSelection();
        CreateTrackParamSnapshot();
        return 0;
      }

      case CSURF_EXT_SETLASTTOUCHEDFX: {
        if (!g_enabled) return 0;
        bool clear = (!parm1 && !parm2 && !parm3);
        const int fxidx = parm3 ? *static_cast<int*>(parm3) : -1;

        DebugTouchLog(
            "[CSURF_EXT_SETLASTTOUCHEDFX] parm1=%p parm2=%p parm3=%p fxidx=%d clear=%d",
            parm1, parm2, parm3, fxidx, clear ? 1 : 0);

        if (clear) {
          ReleaseExpiredParamEdits(true);
        }
        return 0;
      }

      default:
        return 0;
    }
  }
};

void RegisterPluginComponents() {
  g_toggle_command_id = plugin_register("command_id", (void*)kToggleCommandToken);
  g_send_toggle_command_id = plugin_register("command_id", (void*)kSendToggleCommandToken);
  if (g_toggle_command_id == 0 || g_send_toggle_command_id == 0) {
    if (plugin_register) {
      if (g_toggle_command_id != 0) {
        plugin_register("-command_id", (void*)kToggleCommandToken);
      }
      if (g_send_toggle_command_id != 0) {
        plugin_register("-command_id", (void*)kSendToggleCommandToken);
      }
    }
    g_toggle_command_id = 0;
    g_send_toggle_command_id = 0;
    return;
  }

  g_action.accel.cmd = static_cast<WORD>(g_toggle_command_id);
  g_send_action.accel.cmd = static_cast<WORD>(g_send_toggle_command_id);
  plugin_register("gaccel", &g_action);
  plugin_register("gaccel", &g_send_action);
  plugin_register("hookcommand2", (void*)HookCommand2);
  plugin_register("toggleaction", (void*)ToggleActionCallback);
  plugin_register("timer", (void*)TimerTick);

  g_surface = new FxLinkSurface();
  plugin_register("csurf_inst", (void*)g_surface);
}

void UnregisterPluginComponents() {
  const bool prev_persist = g_persist_toggle_state;
  g_persist_toggle_state = false;
  SetEnabled(false);
  SetSendEnabled(false);
  g_persist_toggle_state = prev_persist;

  if (plugin_register) {
    if (g_surface) {
      plugin_register("-csurf_inst", (void*)g_surface);
    }
    plugin_register("-timer", (void*)TimerTick);
    plugin_register("-toggleaction", (void*)ToggleActionCallback);
    plugin_register("-hookcommand2", (void*)HookCommand2);
    plugin_register("-gaccel", &g_send_action);
    plugin_register("-gaccel", &g_action);
    if (g_send_toggle_command_id != 0) {
      plugin_register("-command_id", (void*)kSendToggleCommandToken);
    }
    if (g_toggle_command_id != 0) {
      plugin_register("-command_id", (void*)kToggleCommandToken);
    }
  }

  delete g_surface;
  g_surface = nullptr;
  g_toggle_command_id = 0;
  g_send_toggle_command_id = 0;
  ResetSnapshots();
  ResetSendSnapshots();
}

}  // namespace

extern "C" REAPER_PLUGIN_DLL_EXPORT int REAPER_PLUGIN_ENTRYPOINT(
    REAPER_PLUGIN_HINSTANCE h_instance,
    reaper_plugin_info_t* rec) {
  (void)h_instance;

  if (rec) {
    if (rec->caller_version != REAPER_PLUGIN_VERSION) return 0;
    if (REAPERAPI_LoadAPI(rec->GetFunc) != 0) return 0;
    if (!plugin_register) return 0;

    RegisterPluginComponents();
    if (g_toggle_command_id == 0 || g_send_toggle_command_id == 0) return 0;

    bool fx_enabled = false;
    bool send_enabled = false;
    LoadGlobalToggleState(&fx_enabled, &send_enabled);
    SetEnabled(fx_enabled);
    SetSendEnabled(send_enabled);
    return 1;
  }

  UnregisterPluginComponents();
  return 0;
}
