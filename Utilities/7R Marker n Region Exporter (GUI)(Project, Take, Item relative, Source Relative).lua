--[[
@description 7R Marker n Region Exporter (Project/Take/Regions)
@author 7thResonance
@version 1.11
@changelog
  - lane support
@about GUI for exporting project and take markers and Regions in various formats.
  - HH:MM:SS
  - HH:MM:SS:MS
  - MM:SS Youtube timestamp style
  - MM:SS:MS
  - SS
  - SS:MS
  - MS only
  - Frames
  - Bar:beat
  - Beats

  - Optional Numbering
  - Optional Naming

  - Forum Post link https://forum.cockos.com/showthread.php?t=301676

--]]
local reaper = reaper

-- SETTINGS
local SCRIPT_TITLE = "Export Markers/Regions (Custom Formats & Presets)"
local PRESET_FILENAME = "MarkerExportPresets.json"

-- Custom format tokens help text
local CUSTOM_TOKENS_TOOLTIP = [[Available tokens for custom formats:

Time Tokens:
{seconds} - Time in seconds (e.g. 65.250)
{bar} - Bar number (e.g. 3)
{beat} - Beat within bar (e.g. 2.500)
{fullbeats} - Total beats from project start
{frames} - Frame number

Time Component Tokens:
{hh} - Hours (00-23)
{mm} - Minutes (00-59)
{ss} - Seconds (00-59)
{ms} - Milliseconds (000-999)

Context Tokens:
{markername} - Marker/region name
{itemname} - Item name (for take markers)
{tempo} - Tempo at position
{tsig_num} - Time signature numerator
{tsig_denom} - Time signature denominator

Example: "{bar}:{beat} - {markername} ({tempo} BPM)"
Example: "{hh}:{mm}:{ss}.{ms} - {markername}"]]

-- REAIMGUI SETUP
if not reaper.ImGui_CreateContext then
  reaper.ShowMessageBox("ReaImGui not found! Please install via ReaPack.", "Error", 0)
  return
end

local ctx = reaper.ImGui_CreateContext(SCRIPT_TITLE)
local FONT_SIZE = 16.0
local font = reaper.ImGui_CreateFont('sans-serif', FONT_SIZE)
reaper.ImGui_Attach(ctx, font)

-- GUI STATE
local format_options = {
  "HH:MM:SS",
  "HH:MM:SS:MS",
  "MM:SS",
  "MM:SS:MS",
  "SS",
  "SS:MS",
  "MS Only",
  "Frames",
  "Bar:Beat",
  "Beat",
  "Custom..."
}
local NUM_FORMATS = #format_options

local marker_time_format = 1
local marker_custom_format = ""
local marker_numbering = true
local marker_name_enabled = true
local item_marker_timebase = 1 -- 1:Item-Relative, 2:Project-Relative, 3:Source-Relative
local export_markers_enabled = true
local export_regions_enabled = true
local region_len_fmt = 1
local region_start_fmt = 1
local region_end_fmt = 1
local region_custom_len_format = ""
local region_custom_start_format = ""
local region_custom_end_format = ""
local region_numbering = true
local region_name_enabled = true
local region_show_length = true
local region_show_start = true
local region_show_end = true
local region_field_order = {"name", "length", "start", "end"}
local apply_project_offset = false -- New option for project start offset
local selected_ruler_lanes = {}

local REGION_FIELD_KEYS = {"name", "length", "start", "end"}
local REGION_FIELD_LABELS = {
  name = "Name",
  length = "Duration",
  start = "Start",
  ["end"] = "End",
}

-- Preset system variables (initialize after functions are defined)
local presets = {}
local preset_names = {}
local current_preset = ""
local new_preset_name = ""
local preset_to_delete = ""
local show_save_preset = false
local show_delete_preset = false

local timebase_options = {
  "Item-Relative",
  "Project-Relative",
  "Source-Relative"
}

------------------------------------------------------
-- UTILS
------------------------------------------------------

local function copy_list(list)
  local out = {}
  if type(list) ~= "table" then return out end
  for i = 1, #list do out[i] = list[i] end
  return out
end

local function sanitize_region_field_order(order)
  local sanitized = {}
  local seen = {}
  local had_input = (type(order) == "table")
  if type(order) == "table" then
    for i = 1, #order do
      local key = order[i]
      if REGION_FIELD_LABELS[key] and not seen[key] then
        table.insert(sanitized, key)
        seen[key] = true
      end
    end
  end
  -- Backward compatibility: old presets didn't include "name" in order;
  -- keep legacy visual behavior by placing it first when missing.
  if not seen.name and had_input then
    table.insert(sanitized, 1, "name")
    seen.name = true
  end
  for _, key in ipairs(REGION_FIELD_KEYS) do
    if not seen[key] then table.insert(sanitized, key) end
  end
  return sanitized
end

local function get_region_field_enabled(field_key)
  if field_key == "name" then return region_name_enabled end
  if field_key == "length" then return region_show_length end
  if field_key == "start" then return region_show_start end
  if field_key == "end" then return region_show_end end
  return false
end

local function set_region_field_enabled(field_key, enabled)
  if field_key == "name" then
    region_name_enabled = enabled
  elseif field_key == "length" then
    region_show_length = enabled
  elseif field_key == "start" then
    region_show_start = enabled
  elseif field_key == "end" then
    region_show_end = enabled
  end
end

local function swap_region_field_order(order, idx_a, idx_b)
  if type(order) ~= "table" then return end
  if idx_a == idx_b then return end
  if idx_a < 1 or idx_b < 1 then return end
  if idx_a > #order or idx_b > #order then return end
  order[idx_a], order[idx_b] = order[idx_b], order[idx_a]
end

local function normalize_lane_number(lane_number)
  lane_number = tonumber(lane_number) or 0
  if lane_number < 0 then lane_number = 0 end
  return math.floor(lane_number + 0.5)
end

local function read_ruler_lane_name(api_index)
  if not reaper.GetSetProjectInfo_String then return false, "" end
  local ok, name = reaper.GetSetProjectInfo_String(0, "RULER_LANE_NAME:" .. tostring(api_index), "", false)
  return ok == true, name or ""
end

local function get_project_region_marker_entries()
  local entries = {}

  if reaper.GetNumRegionsOrMarkers and reaper.GetRegionOrMarker and reaper.GetRegionOrMarkerInfo_Value then
    local total = reaper.GetNumRegionsOrMarkers(0) or 0
    for i = 0, total - 1 do
      local region_or_marker = reaper.GetRegionOrMarker(0, i, "")
      if region_or_marker then
        local isrgn = (reaper.GetRegionOrMarkerInfo_Value(0, region_or_marker, "B_ISREGION") or 0) ~= 0
        local pos = reaper.GetRegionOrMarkerInfo_Value(0, region_or_marker, "D_STARTPOS") or 0
        local rgnend = reaper.GetRegionOrMarkerInfo_Value(0, region_or_marker, "D_ENDPOS") or pos
        local idx = math.floor((reaper.GetRegionOrMarkerInfo_Value(0, region_or_marker, "I_NUMBER") or 0) + 0.5)
        local lane = normalize_lane_number(reaper.GetRegionOrMarkerInfo_Value(0, region_or_marker, "I_LANENUMBER"))
        local name = ""

        if reaper.GetSetRegionOrMarkerInfo_String then
          local ok, marker_name = reaper.GetSetRegionOrMarkerInfo_String(0, region_or_marker, "P_NAME", "", false)
          if ok and marker_name then name = marker_name end
        end

        table.insert(entries, {
          idx = idx,
          isrgn = isrgn,
          pos = pos,
          start = pos,
          ["end"] = rgnend,
          length = rgnend - pos,
          name = name,
          lane = lane,
        })
      end
    end
    return entries
  end

  local _, num_markers, num_regions = reaper.CountProjectMarkers(0)
  local total = num_markers + num_regions
  for i = 0, total - 1 do
    local retval, isrgn, pos, rgnend, name, idx = reaper.EnumProjectMarkers(i)
    if retval then
      table.insert(entries, {
        idx = idx,
        isrgn = isrgn,
        pos = pos,
        start = pos,
        ["end"] = rgnend,
        length = rgnend - pos,
        name = name or "",
        lane = 0,
      })
    end
  end
  return entries
end

local function get_ruler_lane_indexing(entries)
  local ok_zero = read_ruler_lane_name(0)
  if ok_zero then return 0, true end

  local ok_one = read_ruler_lane_name(1)
  if ok_one then
    for _, entry in ipairs(entries or {}) do
      if normalize_lane_number(entry.lane) == 0 then
        return 1, true
      end
    end
    return 0, false
  end

  return 0, true
end

local function make_ruler_lane_label(lane_id, name, zero_based, hidden)
  local display_number = zero_based and (lane_id + 1) or lane_id
  if name and name ~= "" then
    return name
  end
  local label = "Lane " .. tostring(display_number)
  if hidden then
    label = label .. " (hidden)"
  end
  return label
end

local function get_current_ruler_lanes(entries)
  entries = entries or get_project_region_marker_entries()
  local name_offset, zero_based = get_ruler_lane_indexing(entries)
  local lanes = {}
  local seen = {}

  local function add_lane(lane_id, api_index, name)
    lane_id = normalize_lane_number(lane_id)
    if seen[lane_id] then return end
    seen[lane_id] = true

    api_index = api_index or (lane_id + name_offset)
    if name == nil then
      local ok, lane_name = read_ruler_lane_name(api_index)
      name = ok and lane_name or ""
    end

    local hidden = false
    local visible = true
    if reaper.GetSetProjectInfo then
      hidden = (reaper.GetSetProjectInfo(0, "RULER_LANE_HIDDEN:" .. tostring(api_index), 0, false) or 0) ~= 0
      visible = (reaper.GetSetProjectInfo(0, "RULER_LANE_VISIBLE:" .. tostring(api_index), 0, false) or 1) ~= 0
    end

    table.insert(lanes, {
      id = lane_id,
      api_index = api_index,
      name = name or "",
      hidden = hidden,
      visible = visible,
      label = make_ruler_lane_label(lane_id, name or "", zero_based, hidden),
    })
  end

  if reaper.GetSetProjectInfo_String then
    local found_any = false
    for api_index = 0, 255 do
      local ok, lane_name = read_ruler_lane_name(api_index)
      if ok then
        found_any = true
        add_lane(api_index - name_offset, api_index, lane_name)
      elseif found_any then
        break
      end
    end
  end

  for _, entry in ipairs(entries) do
    add_lane(entry.lane)
  end

  if #lanes == 0 then
    add_lane(0, name_offset, "")
  end

  table.sort(lanes, function(a, b) return a.id < b.id end)
  return lanes
end

local function sanitize_ruler_lane_selection(lanes)
  local existing = {}
  for _, lane in ipairs(lanes or {}) do
    existing[lane.id] = true
    if selected_ruler_lanes[lane.id] == nil then
      selected_ruler_lanes[lane.id] = true
    end
  end

  for lane_id in pairs(selected_ruler_lanes) do
    if not existing[lane_id] then
      selected_ruler_lanes[lane_id] = nil
    end
  end
end

local function set_all_ruler_lanes(lanes, selected)
  for _, lane in ipairs(lanes or {}) do
    selected_ruler_lanes[lane.id] = selected
  end
end

local function get_selected_ruler_lane_lookup(lanes)
  local lookup = {}
  for _, lane in ipairs(lanes or {}) do
    if selected_ruler_lanes[lane.id] == true then
      lookup[lane.id] = true
    end
  end
  return lookup
end

local function is_lane_allowed(lane_id, selected_lane_lookup)
  if not selected_lane_lookup then return true end
  return selected_lane_lookup[normalize_lane_number(lane_id)] == true
end

local function group_entries_by_ruler_lane(entries, lanes)
  local lane_lookup = {}
  for _, lane in ipairs(lanes or {}) do
    lane_lookup[lane.id] = lane
  end

  local groups_by_lane = {}
  for _, entry in ipairs(entries or {}) do
    local lane_id = normalize_lane_number(entry.lane)
    if not groups_by_lane[lane_id] then
      local lane = lane_lookup[lane_id]
      groups_by_lane[lane_id] = {
        lane_id = lane_id,
        label = lane and lane.label or ("Lane " .. tostring(lane_id + 1)),
        entries = {},
      }
    end
    table.insert(groups_by_lane[lane_id].entries, entry)
  end

  local groups = {}
  for _, lane in ipairs(lanes or {}) do
    if groups_by_lane[lane.id] then
      table.insert(groups, groups_by_lane[lane.id])
      groups_by_lane[lane.id] = nil
    end
  end

  for _, group in pairs(groups_by_lane) do
    table.insert(groups, group)
  end

  table.sort(groups, function(a, b) return a.lane_id < b.lane_id end)
  return groups
end

local function get_project_framerate()
  local rate = reaper.SNM_GetIntConfigVar and reaper.SNM_GetIntConfigVar("projfrrate", -1) or -1
  if rate == -1 then
    local _, str = reaper.GetSetProjectInfo_String(0, "VIDEO_FRAME_RATE", "", false)
    rate = tonumber(str) or 30
  end
  return rate
end

local function get_time_sig_and_tempo(time)
  local proj = 0
  local _, tsig_denom, tempo = reaper.TimeMap_GetTimeSigAtTime(proj, time)
  local _, tsig_num = reaper.TimeMap_GetTimeSigAtTime(proj, time)
  return tsig_num or "", tsig_denom or "", tempo or ""
end

-- Custom format parsing function
local function parse_custom_format(format_str, context)
  if not format_str or format_str == "" then
    return tostring(context.seconds or 0)
  end
  
  local result = format_str
  
  -- Replace all tokens with their values
  result = result:gsub("{seconds}", tostring(context.seconds or 0))
  result = result:gsub("{bar}", tostring(context.bar or 0))
  result = result:gsub("{beat}", tostring(math.floor(context.beat or 0)))
  result = result:gsub("{fullbeats}", tostring(math.floor(context.fullbeats or 0)))
  result = result:gsub("{frames}", tostring(context.frames or 0))
  result = result:gsub("{markername}", tostring(context.markername or ""))
  result = result:gsub("{itemname}", tostring(context.itemname or ""))
  result = result:gsub("{tempo}", string.format("%.2f", context.tempo or 120))
  result = result:gsub("{tsig_num}", tostring(context.tsig_num or 4))
  result = result:gsub("{tsig_denom}", tostring(context.tsig_denom or 4))
  
  -- Time component tokens (convert seconds to individual components)
  local seconds = context.seconds or 0
  local abs_seconds = math.abs(seconds)
  local is_negative = seconds < 0
  local sign = is_negative and "-" or ""
  
  -- Calculate time components
  local hours = math.floor(abs_seconds / 3600)
  local minutes = math.floor((abs_seconds % 3600) / 60)
  local secs = math.floor(abs_seconds % 60)
  local ms = math.floor((abs_seconds % 1) * 1000)
  
  result = result:gsub("{hh}", string.format("%s%02d", sign, hours))
  result = result:gsub("{mm}", string.format("%02d", minutes))
  result = result:gsub("{ss}", string.format("%02d", secs))
  result = result:gsub("{ms}", string.format("%03d", ms))
  
  return result
end

-- Bar:Beat and Beat formatting using accurate logic
local function format_bar_beat(seconds)
  local proj = 0
  local beat_in_bar, bar_idx = reaper.TimeMap2_timeToBeats(proj, seconds)
  
  -- Handle negative times properly
  if seconds < 0 then
    return string.format("-%d:%d", math.abs((bar_idx or 0) + 1), math.floor(math.abs((beat_in_bar or 0) + 1)))
  else
    return string.format("%d:%d", (bar_idx or 0) + 1, math.floor((beat_in_bar or 0) + 1))
  end
end

-- Bar:Beat formatting for item-relative positions (bar starts from 1, beat starts from 1)
local function format_bar_beat_item_relative(seconds)
  local proj = 0
  local beat_in_bar, bar_idx = reaper.TimeMap2_timeToBeats(proj, seconds)
  
  -- For item-relative positioning:
  -- Position 0 (item start) should be 1:1 (first bar, first beat)
  -- Both bar and beat should be 1-based to match standard notation
  if seconds < 0 then
    return string.format("-%d:%d", math.abs((bar_idx or 0) + 1), math.floor(math.abs((beat_in_bar or 0) + 1)))
  else
    -- Add 1 to both bar_idx and beat_in_bar for item-relative to make them 1-based
    return string.format("%d:%d", (bar_idx or 0) + 1, math.floor((beat_in_bar or 0) + 1))
  end
end

local function format_beat(seconds)
  local proj = 0
  local _, _, _, total_full_beats = reaper.TimeMap2_timeToBeats(proj, seconds)
  return string.format("%.0f", total_full_beats or 0)
end

local function format_time(seconds, fmt, framerate)
  seconds = tonumber(seconds) or 0
  
  -- Handle negative time properly
  local is_negative = seconds < 0
  local abs_seconds = math.abs(seconds)
  local ms = math.floor((abs_seconds % 1) * 1000)
  
  local result = ""
  
  if fmt == 1 then
    -- HH:MM:SS
    local h = math.floor(abs_seconds / 3600)
    local m = math.floor((abs_seconds % 3600) / 60)
    local s = math.floor(abs_seconds % 60)
    result = string.format("%02d:%02d:%02d", h, m, s)
  elseif fmt == 2 then
    -- HH:MM:SS:MS
    local h = math.floor(abs_seconds / 3600)
    local m = math.floor((abs_seconds % 3600) / 60)
    local s = math.floor(abs_seconds % 60)
    result = string.format("%02d:%02d:%02d.%03d", h, m, s, ms)
  elseif fmt == 3 then
    -- MM:SS
    local m = math.floor(abs_seconds / 60)
    local s = math.floor(abs_seconds % 60)
    result = string.format("%02d:%02d", m, s)
  elseif fmt == 4 then
    -- MM:SS:MS
    local m = math.floor(abs_seconds / 60)
    local s = math.floor(abs_seconds % 60)
    result = string.format("%02d:%02d.%03d", m, s, ms)
  elseif fmt == 5 then
    -- SS
    local s = math.floor(abs_seconds)
    result = string.format("%d", s)
  elseif fmt == 6 then
    -- SS:MS
    local s = math.floor(abs_seconds)
    result = string.format("%d.%03d", s, ms)
  elseif fmt == 7 then
    -- MS only
    local ms_total = math.floor(abs_seconds * 1000)
    result = string.format("%d", ms_total)
  elseif fmt == 8 then
    -- Frames
    local rate = framerate or get_project_framerate()
    local frames = math.floor(abs_seconds * rate + 0.5)
    result = tostring(frames)
  elseif fmt == 9 then
    -- Bar:Beat
    return format_bar_beat(seconds) -- Pass original seconds to preserve sign handling
  elseif fmt == 10 then
    -- Beat
    return format_beat(seconds) -- Pass original seconds to preserve sign handling
  else
    result = tostring(seconds)
  end
  
  -- Add negative sign if needed (except for Bar:Beat and Beat which handle it themselves)
  if is_negative and fmt ~= 9 and fmt ~= 10 then
    result = "-" .. result
  end
  
  return result
end

local function region_length_bar_beat(start_sec, end_sec)
  -- Calculate region length using total beats, then convert to bars:beats
  local proj = 0
  local _, _, _, fullbeats1 = reaper.TimeMap2_timeToBeats(proj, start_sec)
  local _, _, _, fullbeats2 = reaper.TimeMap2_timeToBeats(proj, end_sec)
  local total_beats = (fullbeats2 or 0) - (fullbeats1 or 0)
  
  -- Get beats per bar for conversion
  local _, beats_per_bar = reaper.TimeMap_GetTimeSigAtTime(proj, start_sec)
  beats_per_bar = beats_per_bar or 4
  
  -- Convert total beats to bars:beats format
  local bars = math.floor(total_beats / beats_per_bar)
  local remaining_beats = math.floor(total_beats % beats_per_bar)
  
  -- Format as consolidated bar:beat notation (e.g., "3:0" instead of "2 bars + 4 beats")
  return string.format("%d:%d", bars, remaining_beats)
end

local function region_length_beats(start_sec, end_sec)
  local proj = 0
  local _, _, _, fullbeats1 = reaper.TimeMap2_timeToBeats(proj, start_sec)
  local _, _, _, fullbeats2 = reaper.TimeMap2_timeToBeats(proj, end_sec)
  return string.format("%.0f", (fullbeats2 or 0) - (fullbeats1 or 0))
end

------------------------------------------------------
-- PROJECT START OFFSET FUNCTIONS
------------------------------------------------------

local function get_project_start_time_offset()
  -- Get project start time offset in seconds
  -- Try different methods to get project offset
  local offset = reaper.GetProjectTimeOffset(0, false) or 0 -- false = don't include recording delay
  if offset == 0 then
    local _, offset_str = reaper.GetSetProjectInfo_String(0, "PROJECT_START_TIME", "", false)
    offset = tonumber(offset_str) or 0
  end
  
  -- Debug: show offset value (uncomment for debugging)
  -- reaper.ShowConsoleMsg("Time offset: " .. tostring(offset) .. "\n")
  return offset
end

local function get_project_start_measure_offset()
  -- Get project start measure/bar offset
  -- In REAPER, this is typically set via Project Settings > Project start time
  local time_offset = get_project_start_time_offset()
  if time_offset == 0 then return 0 end
  
  -- Convert time offset to measure offset at project start
  local proj = 0
  local _, start_bar_idx = reaper.TimeMap2_timeToBeats(proj, 0)
  local _, offset_bar_idx = reaper.TimeMap2_timeToBeats(proj, time_offset)
  return (offset_bar_idx or 0) - (start_bar_idx or 0)
end

-- Enhanced formatting functions that can apply project offset
local function format_time_with_offset(seconds, fmt, framerate, apply_offset)
  if not apply_offset then
    return format_time(seconds, fmt, framerate)
  end
  
  -- Debug (uncomment for debugging)
  -- reaper.ShowConsoleMsg("Applying offset to " .. tostring(seconds) .. " format " .. tostring(fmt) .. "\n")
  
  if fmt == 9 or fmt == 10 then
    -- For Bar:Beat and Beat formats, we need to handle measure offset
    if fmt == 9 then
      -- Bar:Beat format with measure offset
      local measure_offset = get_project_start_measure_offset()
      local proj = 0
      local beat_in_bar, bar_idx = reaper.TimeMap2_timeToBeats(proj, seconds)
      local adjusted_bar = (bar_idx or 0) + 1 + measure_offset
      return string.format("%d:%d", adjusted_bar, math.floor((beat_in_bar or 0) + 1))
    else
      -- Beat format with beat offset
      local measure_offset = get_project_start_measure_offset()
      local proj = 0
      local _, _, _, total_full_beats = reaper.TimeMap2_timeToBeats(proj, seconds)
      -- Get beats per bar at project start to calculate beat offset
      local _, beats_per_bar = reaper.TimeMap_GetTimeSigAtTime(proj, 0)
      local beat_offset = measure_offset * (beats_per_bar or 4)
      return string.format("%.0f", (total_full_beats or 0) + beat_offset)
    end
  else
    -- For time formats, add time offset
    local time_offset = get_project_start_time_offset()
    local adjusted_seconds = seconds + time_offset
    return format_time(adjusted_seconds, fmt, framerate)
  end
end

local function format_bar_beat_with_offset(seconds, apply_offset)
  return format_time_with_offset(seconds, 9, nil, apply_offset)
end

local function format_beat_with_offset(seconds, apply_offset)
  return format_time_with_offset(seconds, 10, nil, apply_offset)
end

local function GetProjectMarkers(entries, selected_lane_lookup)
  local markers = {}
  entries = entries or get_project_region_marker_entries()
  for _, entry in ipairs(entries) do
    if not entry.isrgn and is_lane_allowed(entry.lane, selected_lane_lookup) then
      table.insert(markers, {
        idx = entry.idx,
        pos = entry.pos,
        name = entry.name or "",
        lane = entry.lane,
      })
    end
  end
  return markers
end

local function GetProjectMarkerSelection(time_sel_start, time_sel_end, entries, selected_lane_lookup)
  local all = GetProjectMarkers(entries, selected_lane_lookup)
  if not (time_sel_start and time_sel_end and time_sel_end > time_sel_start) then
    return all
  end
  local filtered = {}
  for _, m in ipairs(all) do
    if m.pos >= time_sel_start and m.pos <= time_sel_end then
      table.insert(filtered, m)
    end
  end
  return filtered
end

local function GetProjectRegionsFiltered(time_sel_start, time_sel_end, entries, selected_lane_lookup)
  local regions = {}
  entries = entries or get_project_region_marker_entries()
  for _, entry in ipairs(entries) do
    if entry.isrgn and is_lane_allowed(entry.lane, selected_lane_lookup) then
      local include = true
      if time_sel_start and time_sel_end and time_sel_end > time_sel_start then
        -- region overlaps time selection?
        include = (entry["end"] > time_sel_start) and (entry.start < time_sel_end)
      end
      if include then
        table.insert(regions, {
          idx = entry.idx,
          name = entry.name or "",
          start = entry.start,
          ["end"] = entry["end"],
          length = entry.length,
          lane = entry.lane,
        })
      end
    end
  end
  return regions
end

local function GetSelectedItems()
  local t = {}
  for i = 0, reaper.CountSelectedMediaItems(0)-1 do
    t[#t+1] = reaper.GetSelectedMediaItem(0, i)
  end
  return t
end

-- timebase: 1 = item-relative, 2 = project-relative
local function GetTakeMarkersFiltered(item, timebase, time_sel_start, time_sel_end)
  local take = reaper.GetActiveTake(item)
  if not take then return {} end
  local ret = {}
  local num = reaper.GetNumTakeMarkers(take)
  local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local take_offset = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
  local rate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
  local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")

  for i = 0, num-1 do
    local src_pos, name = reaper.GetTakeMarker(take, i) -- src_pos is source-relative!
    local pos
    if timebase == 1 then
      pos = (src_pos - take_offset) / rate
    elseif timebase == 2 then
      pos = item_pos + (src_pos - take_offset) / rate
    elseif timebase == 3 then
      pos = src_pos / rate  -- Source-relative: pure source position
    end

    -- Only include markers within played portion of item (for item- and project-relative)
    local include = true
    if timebase == 1 then
      include = (pos >= 0 and pos <= item_len)
    elseif timebase == 2 then
      include = (pos >= item_pos and pos <= item_pos + item_len)
    elseif timebase == 3 then
      include = true  -- Source-relative: include all markers in the source
    end

    -- Robust time selection filtering (always check marker's project position)
    local marker_project_pos = item_pos + (src_pos - take_offset) / rate
    if time_sel_start and time_sel_end and time_sel_end > time_sel_start then
      include = include and (marker_project_pos >= time_sel_start and marker_project_pos <= time_sel_end)
    end

    if include then
      table.insert(ret, {idx=i+1, pos=pos, name=name or "", item_pos=item_pos})
    end
  end
  return ret
end

local function GetItemName(item)
  local take = reaper.GetActiveTake(item)
  if not take then return "No Take" end
  local _, name = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
  if name ~= "" then return name end
  local src = reaper.GetMediaItemTake_Source(take)
  local fn = reaper.GetMediaSourceFileName(src)
  return fn:match("[^\\/]+$") or "Unnamed"
end

local function GenerateMarkerBlock(markers, fmt, custom_fmt, numbering, framerate, timebase, include_name)
  local lines = {}
  for i, m in ipairs(markers) do
    local idx = numbering and (tostring(i) .. " ") or ""
    local pos = m.pos
    local marker_name = (include_name ~= false) and (m.name or "") or ""
    local time_str
    
    -- Apply project offset for:
    -- - Project markers (timebase == 2, which represents project-relative)
    -- - Project-relative item markers (timebase == 2)
    -- - NOT for item-relative markers (timebase == 1)
    -- - NOT for source-relative markers (timebase == 3)
    local should_apply_offset = apply_project_offset and (timebase == 2)
    
    -- Debug (uncomment for debugging)
    -- reaper.ShowConsoleMsg("Marker " .. tostring(i) .. ": pos=" .. tostring(pos) .. ", timebase=" .. tostring(timebase) .. ", apply_offset=" .. tostring(apply_project_offset) .. ", should_apply=" .. tostring(should_apply_offset) .. "\n")
    
    if fmt == 11 then -- Custom format
      -- Build context for custom format
      local proj = 0
      local beat_in_bar, bar_idx, _, total_full_beats = reaper.TimeMap2_timeToBeats(proj, pos)
      local frames = math.floor((pos or 0) * (framerate or get_project_framerate()) + 0.5)
      local tsig_num, tsig_denom, tempo = get_time_sig_and_tempo(pos)
      
      -- Apply offset to context values if needed
      local context_pos = pos
      local context_bar = (bar_idx or 0) + 1
      local context_beat = (beat_in_bar or 0) + 1
      local context_fullbeats = total_full_beats or 0
      
      if should_apply_offset then
        -- For time formats, add time offset
        local time_offset = get_project_start_time_offset()
        context_pos = pos + time_offset
        
        -- For Bar:Beat and Beat formats, we need to handle measure offset
        local measure_offset = get_project_start_measure_offset()
        context_bar = context_bar + measure_offset
        local _, beats_per_bar = reaper.TimeMap_GetTimeSigAtTime(proj, 0)
        local beat_offset = measure_offset * (beats_per_bar or 4)
        context_fullbeats = context_fullbeats + beat_offset
      end
      
      local context = {
        bar = context_bar,
        beat = context_beat,
        fullbeats = context_fullbeats,
        seconds = context_pos,
        frames = frames,
        markername = marker_name,
        itemname = m.itemname or "",
        tempo = tempo,
        tsig_num = tsig_num,
        tsig_denom = tsig_denom,
      }
      time_str = parse_custom_format(custom_fmt, context)
    elseif fmt == 9 then -- Bar:Beat
      if timebase == 1 then
        -- Item-relative: use special formatting that starts from correct position
        time_str = format_bar_beat_item_relative(pos)
      else
        time_str = format_bar_beat_with_offset(pos, should_apply_offset)
      end
    elseif fmt == 10 then -- Beat
      time_str = format_beat_with_offset(pos, should_apply_offset)
    else
      time_str = format_time_with_offset(pos, fmt, framerate, should_apply_offset)
    end
    local line = idx .. time_str
    if marker_name ~= "" then
      line = line .. " " .. marker_name
    end
    table.insert(lines, line)
  end
  return lines
end

local function GenerateRegionBlock(regions, fmt_len, fmt_start, fmt_end,
                                  custom_len_fmt, custom_start_fmt, custom_end_fmt,
                                  framerate, numbering, include_name, show_length, show_start, show_end, field_order)
  local lines = {}
  local normalized_order = sanitize_region_field_order(field_order)
  for i, r in ipairs(regions) do
    local N = numbering and (tostring(i) .. ". ") or ""
    local name = r.name or ""
    local region_name = (include_name ~= false) and name or ""
    local length, start, end_ = r.length, r.start, r["end"]

    -- Pre-calculate context data for custom formats
    local proj = 0
    local beat_len, bar_len, _, fullbeats_len = reaper.TimeMap2_timeToBeats(proj, end_ - start)
    local beat_start, bar_start, _, fullbeats_start = reaper.TimeMap2_timeToBeats(proj, start)
    local beat_end, bar_end, _, fullbeats_end = reaper.TimeMap2_timeToBeats(proj, end_)
    local tsig_num, tsig_denom, tempo = get_time_sig_and_tempo(start)

    -- Calculate frames for each position
    local frames_len = math.floor(length * (framerate or get_project_framerate()) + 0.5)
    local frames_start = math.floor(start * (framerate or get_project_framerate()) + 0.5)
    local frames_end = math.floor(end_ * (framerate or get_project_framerate()) + 0.5)

    local len_str, start_str, end_str

    -- Length (no offset needed - this is duration)
    if fmt_len == 11 then -- Custom
      local context_len = {
        seconds = length,
        bar = (bar_len or 0),  -- Duration bars (0-based)
        beat = (beat_len or 0),  -- Duration beats (0-based)
        fullbeats = fullbeats_len or 0,
        frames = frames_len,
        markername = region_name,
        itemname = "",
        tempo = tempo,
        tsig_num = tsig_num,
        tsig_denom = tsig_denom,
      }
      len_str = parse_custom_format(custom_len_fmt, context_len)
    elseif fmt_len == 9 then -- Bar:Beat
      len_str = region_length_bar_beat(start, end_)
    elseif fmt_len == 10 then -- Beat
      len_str = region_length_beats(start, end_)
    else
      len_str = format_time(length, fmt_len, framerate)
    end

    -- Start (apply offset for absolute positions)
    if fmt_start == 11 then -- Custom
      local context_start = {
        seconds = apply_project_offset and (start + get_project_start_time_offset()) or start,
        bar = (bar_start or 0) + 1 + (apply_project_offset and get_project_start_measure_offset() or 0),
        beat = (beat_start or 0) + 1,
        fullbeats = (fullbeats_start or 0) + (apply_project_offset and get_project_start_measure_offset() * 4 or 0),
        frames = frames_start,
        markername = region_name,
        itemname = "",
        tempo = tempo,
        tsig_num = tsig_num,
        tsig_denom = tsig_denom,
      }
      start_str = parse_custom_format(custom_start_fmt, context_start)
    elseif fmt_start == 9 then
      start_str = format_bar_beat_with_offset(start, apply_project_offset)
    elseif fmt_start == 10 then
      start_str = format_beat_with_offset(start, apply_project_offset)
    else
      start_str = format_time_with_offset(start, fmt_start, framerate, apply_project_offset)
    end

    -- End (apply offset for absolute positions)
    if fmt_end == 11 then -- Custom
      local context_end = {
        seconds = apply_project_offset and (end_ + get_project_start_time_offset()) or end_,
        bar = (bar_end or 0) + 1 + (apply_project_offset and get_project_start_measure_offset() or 0),
        beat = (beat_end or 0) + 1,
        fullbeats = (fullbeats_end or 0) + (apply_project_offset and get_project_start_measure_offset() * 4 or 0),
        frames = frames_end,
        markername = region_name,
        itemname = "",
        tempo = tempo,
        tsig_num = tsig_num,
        tsig_denom = tsig_denom,
      }
      end_str = parse_custom_format(custom_end_fmt, context_end)
    elseif fmt_end == 9 then
      end_str = format_bar_beat_with_offset(end_, apply_project_offset)
    elseif fmt_end == 10 then
      end_str = format_beat_with_offset(end_, apply_project_offset)
    else
      end_str = format_time_with_offset(end_, fmt_end, framerate, apply_project_offset)
    end

    local values_by_key = {
      name = region_name,
      length = len_str,
      start = start_str,
      ["end"] = end_str,
    }
    local enabled_by_key = {
      name = include_name ~= false,
      length = show_length ~= false,
      start = show_start ~= false,
      ["end"] = show_end ~= false,
    }

    local ordered_keys = {}
    for _, key in ipairs(normalized_order) do
      if enabled_by_key[key] then
        table.insert(ordered_keys, key)
      end
    end

    local parts = {}
    local k = 1
    while k <= #ordered_keys do
      local key = ordered_keys[k]
      if key == "start" and ordered_keys[k + 1] == "end" then
        table.insert(parts, values_by_key.start .. " to " .. values_by_key["end"])
        k = k + 2
      else
        table.insert(parts, values_by_key[key] or "")
        k = k + 1
      end
    end

    local line = N
    if #parts > 0 then
      line = line .. table.concat(parts, " - ")
    else
      line = line:gsub("%s+$", "")
    end
    table.insert(lines, line)
  end
  return lines
end

------------------------------------------------------
-- PRESET STORAGE
------------------------------------------------------

-- Get REAPER resource path and preset file path
local function get_preset_file_path()
  local resource_path = reaper.GetResourcePath()
  local preset_path = resource_path .. "/" .. PRESET_FILENAME
  -- Debug output (uncomment for debugging)
  -- reaper.ShowConsoleMsg("Preset file path: " .. preset_path .. "\n")
  return preset_path
end

local function save_presets(presets)
  local path = get_preset_file_path()
  local f = io.open(path, "w")
  if not f then
    reaper.ShowMessageBox("Could not write preset file:\n" .. path, "Error", 0)
    return false
  end
  
  local json_str = ""
  local success = false
  
  if reaper.utils and reaper.utils.TableToJSON then
    json_str = reaper.utils.TableToJSON(presets)
    success = json_str ~= nil
  elseif package.searchpath and package.searchpath("dkjson", package.path) then
    local json = require("dkjson")
    json_str = json.encode(presets, { indent = true })
    success = json_str ~= nil
  else
    -- Fallback: simple table serialization
    local function serialize_table(t, indent)
      indent = indent or ""
      local lines = {}
      table.insert(lines, "{")
      for k, v in pairs(t) do
        local key_str = type(k) == "string" and string.format('"%s"', k) or tostring(k)
        local val_str
        if type(v) == "string" then
          val_str = string.format('"%s"', v:gsub('"', '\\"'))
        elseif type(v) == "table" then
          val_str = serialize_table(v, indent .. "  ")
        else
          val_str = tostring(v)
        end
        table.insert(lines, string.format("%s  [%s] = %s,", indent, key_str, val_str))
      end
      table.insert(lines, indent .. "}")
      return table.concat(lines, "\n")
    end
    json_str = serialize_table(presets)
    success = true
  end
  
  if success and json_str ~= "" then
    f:write(json_str)
    f:close()
    return true
  else
    f:close()
    reaper.ShowMessageBox("Failed to serialize preset data", "Error", 0)
    return false
  end
end

local function load_presets()
  local path = get_preset_file_path()
  local f = io.open(path, "r")
  if not f then return {} end
  local str = f:read("*a")
  f:close()
  
  -- Handle empty file
  if not str or str == "" then return {} end
  
  local result = {}
  
  if reaper.utils and reaper.utils.JSONToTable then
    result = reaper.utils.JSONToTable(str)
  elseif package.searchpath and package.searchpath("dkjson", package.path) then
    local json = require("dkjson")
    local obj, _, err = json.decode(str)
    if obj then
      result = obj
    else
      -- Log decode error for debugging
      reaper.ShowConsoleMsg("JSON decode error: " .. (err or "unknown") .. "\n")
    end
  else
    -- fallback: simple unsafe eval (not secure, but REAPER sandboxed)
    local func, load_err = load("return " .. str)
    if func then
      local ok, val = pcall(func)
      if ok and type(val) == "table" then
        result = val
      end
    end
  end
  
  -- Ensure we always return a table
  return type(result) == "table" and result or {}
end

------------------------------------------------------
-- MAIN EXPORT LOGIC
------------------------------------------------------

local function Main_Export()
  if not export_markers_enabled and not export_regions_enabled then
    reaper.ShowMessageBox("Both marker and region export are disabled.", "Nothing to Export", 0)
    return
  end

  local out = {}
  local framerate = get_project_framerate()
  local project_marker_region_entries = get_project_region_marker_entries()
  local ruler_lanes = get_current_ruler_lanes(project_marker_region_entries)
  sanitize_ruler_lane_selection(ruler_lanes)
  local selected_lane_lookup = get_selected_ruler_lane_lookup(ruler_lanes)

  -- Time selection
  local time_sel_start, time_sel_end = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  if time_sel_end <= time_sel_start then
    time_sel_start, time_sel_end = nil, nil
  end

  if export_markers_enabled then
    -- Project Markers
    local proj_markers = GetProjectMarkerSelection(time_sel_start, time_sel_end, project_marker_region_entries, selected_lane_lookup)
    if #proj_markers > 0 then
      table.insert(out, "Project Markers:")
      local marker_lane_groups = group_entries_by_ruler_lane(proj_markers, ruler_lanes)
      for _, group in ipairs(marker_lane_groups) do
        table.insert(out, group.label .. ":")
        local proj_lines = GenerateMarkerBlock(group.entries, marker_time_format, marker_custom_format, marker_numbering, framerate, 2, marker_name_enabled)
        for _, line in ipairs(proj_lines) do table.insert(out, line) end
      end
      table.insert(out, "")
    end

    -- Item/Take Markers
    local items = GetSelectedItems()
    if #items > 0 then
      for i, item in ipairs(items) do
        local name = GetItemName(item)
        table.insert(out, "Item: " .. name)
        local timebase = item_marker_timebase
        local markers = GetTakeMarkersFiltered(item, timebase, time_sel_start, time_sel_end)
        -- add itemname to context
        for _, m in ipairs(markers) do m.itemname = name end
        local lines = GenerateMarkerBlock(markers, marker_time_format, marker_custom_format, marker_numbering, framerate, timebase, marker_name_enabled)
        for _, line in ipairs(lines) do table.insert(out, line) end
        table.insert(out, "")
      end
    end
  end

  if export_regions_enabled then
    -- Regions
    local regions = GetProjectRegionsFiltered(time_sel_start, time_sel_end, project_marker_region_entries, selected_lane_lookup)
    if #regions > 0 then
      table.insert(out, "Regions:")
      local region_lane_groups = group_entries_by_ruler_lane(regions, ruler_lanes)
      for _, group in ipairs(region_lane_groups) do
        table.insert(out, group.label .. ":")
        local region_lines = GenerateRegionBlock(
          group.entries,
          region_len_fmt, region_start_fmt, region_end_fmt,
          region_custom_len_format, region_custom_start_format, region_custom_end_format,
          framerate, region_numbering, region_name_enabled,
          region_show_length, region_show_start, region_show_end, region_field_order
        )
        for _, line in ipairs(region_lines) do table.insert(out, line) end
      end
      table.insert(out, "")
    end
  end

  local result = table.concat(out, "\n")
  if reaper.CF_SetClipboard then
    reaper.CF_SetClipboard(result)
  else
    if reaper.GetOS():find("Win") then
      local tmp = os.tmpname() .. ".txt"
      local f = io.open(tmp, "w")
      if f then f:write(result) f:close() end
      os.execute('type "' .. tmp .. '" | clip')
      os.remove(tmp)
    end
  end
  reaper.ShowConsoleMsg(result .. "\n")
end

------------------------------------------------------
-- PRESET GUI
------------------------------------------------------

local function apply_preset(name)
  -- Apply preset to state
  local p = presets[name]
  if p then
    marker_time_format = p.marker_time_format or 1
    marker_custom_format = p.marker_custom_format or ""
    marker_numbering = (p.marker_numbering ~= nil) and p.marker_numbering or true
    marker_name_enabled = (p.marker_name_enabled ~= nil) and p.marker_name_enabled or true
    item_marker_timebase = p.item_marker_timebase or 1
    export_markers_enabled = (p.export_markers_enabled ~= nil) and p.export_markers_enabled or true
    export_regions_enabled = (p.export_regions_enabled ~= nil) and p.export_regions_enabled or true
    region_len_fmt = p.region_len_fmt or 1
    region_start_fmt = p.region_start_fmt or 1
    region_end_fmt = p.region_end_fmt or 1
    region_custom_len_format = p.region_custom_len_format or ""
    region_custom_start_format = p.region_custom_start_format or ""
    region_custom_end_format = p.region_custom_end_format or ""
    region_numbering = (p.region_numbering ~= nil) and p.region_numbering or true
    region_name_enabled = (p.region_name_enabled ~= nil) and p.region_name_enabled or true
    region_show_length = (p.region_show_length ~= nil) and p.region_show_length or true
    region_show_start = (p.region_show_start ~= nil) and p.region_show_start or true
    region_show_end = (p.region_show_end ~= nil) and p.region_show_end or true
    region_field_order = sanitize_region_field_order(copy_list(p.region_field_order))
    apply_project_offset = (p.apply_project_offset ~= nil) and p.apply_project_offset or false
  end
end

local function PresetGUI()
  -- Preset selection
  reaper.ImGui_Text(ctx, "Preset System")
  if #preset_names > 0 then
    local curr_idx = 0
    for i, n in ipairs(preset_names) do if n == current_preset then curr_idx = i - 1 end end
    local changed, new_idx = reaper.ImGui_Combo(ctx, "Choose Preset", curr_idx, table.concat(preset_names, "\0") .. "\0")
    if changed then
      local name = preset_names[new_idx + 1]
      current_preset = name
      apply_preset(name)
    end
    
    -- Add Load button for applying the currently selected preset
    reaper.ImGui_SameLine(ctx)
    if current_preset and #current_preset > 0 and presets[current_preset] then
      if reaper.ImGui_Button(ctx, "Load") then
        apply_preset(current_preset)
      end
      if reaper.ImGui_IsItemHovered(ctx) then 
        reaper.ImGui_SetTooltip(ctx, "Apply the selected preset: " .. current_preset) 
      end
    end
    reaper.ImGui_SameLine(ctx)
  end
  if reaper.ImGui_Button(ctx, "Save New Preset") then show_save_preset = true end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, "Delete Preset") then show_delete_preset = true end

  if show_save_preset then
    reaper.ImGui_OpenPopup(ctx, "SavePresetPopup")
  end
  if show_delete_preset then
    reaper.ImGui_OpenPopup(ctx, "DeletePresetPopup")
  end

  if reaper.ImGui_BeginPopup(ctx, "SavePresetPopup") then
    local _, name = reaper.ImGui_InputText(ctx, "Preset Name", new_preset_name or "", 256)
    new_preset_name = name
    if reaper.ImGui_Button(ctx, "Save") and name and #name > 0 then
      -- Save state to preset
      presets[name] = {
        marker_time_format = marker_time_format,
        marker_custom_format = marker_custom_format,
        marker_numbering = marker_numbering,
        marker_name_enabled = marker_name_enabled,
        item_marker_timebase = item_marker_timebase,
        export_markers_enabled = export_markers_enabled,
        export_regions_enabled = export_regions_enabled,
        region_len_fmt = region_len_fmt,
        region_start_fmt = region_start_fmt,
        region_end_fmt = region_end_fmt,
        region_custom_len_format = region_custom_len_format,
        region_custom_start_format = region_custom_start_format,
        region_custom_end_format = region_custom_end_format,
        region_numbering = region_numbering,
        region_name_enabled = region_name_enabled,
        region_show_length = region_show_length,
        region_show_start = region_show_start,
        region_show_end = region_show_end,
        region_field_order = copy_list(region_field_order),
        apply_project_offset = apply_project_offset
      }
      
      -- Save to file and update UI
      if save_presets(presets) then
        current_preset = name
        preset_names = {}
        for k in pairs(presets) do table.insert(preset_names, k) end
        table.sort(preset_names)
        show_save_preset = false
        new_preset_name = ""
        reaper.ImGui_CloseCurrentPopup(ctx)
      else
        -- Keep popup open on save failure
        reaper.ShowConsoleMsg("Failed to save preset: " .. name .. "\n")
      end
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Cancel") then show_save_preset = false; reaper.ImGui_CloseCurrentPopup(ctx) end
    reaper.ImGui_EndPopup(ctx)
  end

  if reaper.ImGui_BeginPopup(ctx, "DeletePresetPopup") then
    if current_preset and #current_preset > 0 and presets[current_preset] then
      reaper.ImGui_Text(ctx, "Delete preset '"..current_preset.."'?")
      if reaper.ImGui_Button(ctx, "Delete") then
        presets[current_preset] = nil
        save_presets(presets)
        
        -- Rebuild preset list
        preset_names = {}
        for k in pairs(presets) do table.insert(preset_names, k) end
        table.sort(preset_names)
        
        -- Set current_preset to first available preset, or empty if none
        if #preset_names > 0 then
          current_preset = preset_names[1]
        else
          current_preset = ""
        end
        
        show_delete_preset = false
        reaper.ImGui_CloseCurrentPopup(ctx)
      end
      reaper.ImGui_SameLine(ctx)
      if reaper.ImGui_Button(ctx, "Cancel") then show_delete_preset = false; reaper.ImGui_CloseCurrentPopup(ctx) end
    else
      reaper.ImGui_Text(ctx, "No preset selected.")
      if reaper.ImGui_Button(ctx, "Close") then show_delete_preset = false; reaper.ImGui_CloseCurrentPopup(ctx) end
    end
    reaper.ImGui_EndPopup(ctx)
  end
end

------------------------------------------------------
-- GUI LOOP
------------------------------------------------------

local function loop()
  local visible, open = reaper.ImGui_Begin(ctx, SCRIPT_TITLE, true, reaper.ImGui_WindowFlags_AlwaysAutoResize())
  if visible then
    reaper.ImGui_PushFont(ctx, font, 14)
    reaper.ImGui_Text(ctx, "Marker & Region Export Options")
    reaper.ImGui_SameLine(ctx)
    _, export_markers_enabled = reaper.ImGui_Checkbox(ctx, "Export Markers", export_markers_enabled)
    reaper.ImGui_SameLine(ctx)
    _, export_regions_enabled = reaper.ImGui_Checkbox(ctx, "Export Regions", export_regions_enabled)
    reaper.ImGui_PopFont(ctx)

    PresetGUI()

    reaper.ImGui_Separator(ctx)
    local ruler_lanes = get_current_ruler_lanes()
    sanitize_ruler_lane_selection(ruler_lanes)
    reaper.ImGui_Text(ctx, "Project Marker/Region Lanes")
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "All##ruler_lanes_all") then
      set_all_ruler_lanes(ruler_lanes, true)
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "None##ruler_lanes_none") then
      set_all_ruler_lanes(ruler_lanes, false)
    end
    for _, lane in ipairs(ruler_lanes) do
      local selected = selected_ruler_lanes[lane.id] == true
      local changed, new_selected = reaper.ImGui_Checkbox(ctx, lane.label .. "##ruler_lane_" .. tostring(lane.id), selected)
      if changed then
        selected_ruler_lanes[lane.id] = new_selected
      end
    end
    local any_lane_selected = false
    for _, lane in ipairs(ruler_lanes) do
      if selected_ruler_lanes[lane.id] == true then
        any_lane_selected = true
        break
      end
    end
    if not any_lane_selected then
      reaper.ImGui_Text(ctx, "No project marker/region lanes selected.")
    end

    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Text(ctx, "Project/Take Marker Format")
    _, marker_time_format = reaper.ImGui_Combo(ctx, "Marker/Take Marker Format", marker_time_format-1, table.concat(format_options, "\0").."\0")
    marker_time_format = marker_time_format + 1
    if marker_time_format == 11 then
      _, marker_custom_format = reaper.ImGui_InputText(ctx, "Custom Marker Format", marker_custom_format or "", 256)
      if reaper.ImGui_IsItemHovered(ctx) then reaper.ImGui_SetTooltip(ctx, CUSTOM_TOKENS_TOOLTIP) end
    end

    _, marker_numbering = reaper.ImGui_Checkbox(ctx, "Enable Marker Numbering (1, 2...)", marker_numbering)
    _, marker_name_enabled = reaper.ImGui_Checkbox(ctx, "Include Marker Names", marker_name_enabled)

    local num_sel = reaper.CountSelectedMediaItems(0)
    if num_sel > 0 then
      reaper.ImGui_Separator(ctx)
      reaper.ImGui_Text(ctx, "Item Marker Options")

      -- Disable Source-Relative option for Bar:Beat and Beat formats
      local tb_opts = timebase_options
      local tb_count = #timebase_options
      if marker_time_format == 9 or marker_time_format == 10 then -- Bar:Beat or Beat
        tb_opts = {"Item-Relative", "Project-Relative"}
        tb_count = 2
        -- Reset to Item-Relative if currently Source-Relative
        if item_marker_timebase == 3 then
          item_marker_timebase = 1
        end
      end
      
      local tb_opts_str = table.concat(tb_opts, "\0") .. "\0"
      local curr_tb_idx = item_marker_timebase - 1
      if curr_tb_idx < 0 then curr_tb_idx = 0 end
      if curr_tb_idx >= tb_count then curr_tb_idx = tb_count - 1 end

      local changed, new_tb_idx = reaper.ImGui_Combo(ctx, "Item Marker Timebase", curr_tb_idx, tb_opts_str)
      if changed then
        item_marker_timebase = new_tb_idx + 1
      end
      reaper.ImGui_Text(ctx, "Selected Items: " .. tostring(num_sel))
    end

    reaper.ImGui_Separator(ctx)

    -- Regions
    reaper.ImGui_Text(ctx, "Region Export Options")
    _, region_numbering = reaper.ImGui_Checkbox(ctx, "Enable Region Numbering (1. 2. ...)", region_numbering)
    reaper.ImGui_TextDisabled(ctx, "Drag these checkbox rows to reorder Name/Duration/Start/End in export:")

    region_field_order = sanitize_region_field_order(region_field_order)
    local reorder_from_idx, reorder_to_idx = nil, nil
    for pos = 1, #region_field_order do
      local key = region_field_order[pos]
      local field_label = REGION_FIELD_LABELS[key] or key
      local checkbox_label
      if key == "name" then
        checkbox_label = "Include Region Names##region_field_name"
      else
        checkbox_label = "Export Region " .. field_label .. "##region_field_" .. key
      end
      local field_enabled = get_region_field_enabled(key)
      local changed, new_enabled = reaper.ImGui_Checkbox(ctx, checkbox_label, field_enabled)
      if changed then
        set_region_field_enabled(key, new_enabled)
      end

      if reaper.ImGui_BeginDragDropSource(ctx) then
        reaper.ImGui_SetDragDropPayload(ctx, "REGION_FIELD_REORDER", tostring(pos))
        local drag_label = (key == "name") and "Region Names" or field_label
        reaper.ImGui_Text(ctx, "Move: " .. drag_label)
        reaper.ImGui_EndDragDropSource(ctx)
      end

      if reaper.ImGui_BeginDragDropTarget(ctx) then
        local ok, payload = reaper.ImGui_AcceptDragDropPayload(ctx, "REGION_FIELD_REORDER")
        if ok then
          local from_idx = tonumber(payload)
          if from_idx and from_idx >= 1 and from_idx <= #region_field_order and from_idx ~= pos then
            reorder_from_idx = from_idx
            reorder_to_idx = pos
          end
        end
        reaper.ImGui_EndDragDropTarget(ctx)
      end
    end

    if reorder_from_idx and reorder_to_idx then
      swap_region_field_order(region_field_order, reorder_from_idx, reorder_to_idx)
    end

    if not (region_name_enabled or region_show_length or region_show_start or region_show_end) then
      reaper.ImGui_Text(ctx, "All region fields are disabled. Export will include numbering only (if enabled).")
    elseif not (region_show_length or region_show_start or region_show_end) then
      reaper.ImGui_Text(ctx, "All region time fields are disabled. Export will include region names only.")
    end

    _, region_len_fmt = reaper.ImGui_Combo(ctx, "Region Length Format", region_len_fmt-1, table.concat(format_options, "\0").."\0")
    region_len_fmt = region_len_fmt + 1
    if region_len_fmt == 11 then
      _, region_custom_len_format = reaper.ImGui_InputText(ctx, "Custom Region Length Format", region_custom_len_format or "", 256)
      if reaper.ImGui_IsItemHovered(ctx) then reaper.ImGui_SetTooltip(ctx, CUSTOM_TOKENS_TOOLTIP) end
    end
    _, region_start_fmt = reaper.ImGui_Combo(ctx, "Region Start Format", region_start_fmt-1, table.concat(format_options, "\0").."\0")
    region_start_fmt = region_start_fmt + 1
    if region_start_fmt == 11 then
      _, region_custom_start_format = reaper.ImGui_InputText(ctx, "Custom Region Start Format", region_custom_start_format or "", 256)
      if reaper.ImGui_IsItemHovered(ctx) then reaper.ImGui_SetTooltip(ctx, CUSTOM_TOKENS_TOOLTIP) end
    end
    _, region_end_fmt = reaper.ImGui_Combo(ctx, "Region End Format", region_end_fmt-1, table.concat(format_options, "\0").."\0")
    region_end_fmt = region_end_fmt + 1
    if region_end_fmt == 11 then
      _, region_custom_end_format = reaper.ImGui_InputText(ctx, "Custom Region End Format", region_custom_end_format or "", 256)
      if reaper.ImGui_IsItemHovered(ctx) then reaper.ImGui_SetTooltip(ctx, CUSTOM_TOKENS_TOOLTIP) end
    end

    reaper.ImGui_Separator(ctx)

    -- Project start offset option
    _, apply_project_offset = reaper.ImGui_Checkbox(ctx, "Apply Project Start Time/Measure Offset", apply_project_offset)
    if apply_project_offset then
      reaper.ImGui_SameLine(ctx)
      reaper.ImGui_TextDisabled(ctx, "(?)")
      if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, "Adds project start time/measure offset to:\n• Project markers\n• Project-relative item markers\n• Region start/end positions\n\nDoes NOT affect:\n• Region lengths (durations)\n• Item-relative marker positions")
      end
    end

    -- Project offset warning panel
    local project_offset = get_project_start_time_offset()
    if project_offset ~= 0 then
      reaper.ImGui_Separator(ctx)
      
      -- Warning panel with background color
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), 0xFF3333AA) -- Semi-transparent red background
      reaper.ImGui_BeginChild(ctx, "OffsetWarning", 0, 60) -- Removed the boolean parameter
      
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFFFFFFFF) -- White text
      reaper.ImGui_TextWrapped(ctx, "WARNING: A project offset is detected. Due to API limitations, cannot differentiate between time and measure offset. Unless they are at the same place, you will get incorrect values for bars and beats.")
      reaper.ImGui_PopStyleColor(ctx) -- Restore text color
      
      reaper.ImGui_EndChild(ctx)
      reaper.ImGui_PopStyleColor(ctx) -- Restore background color
    end

    reaper.ImGui_Separator(ctx)

    if reaper.ImGui_Button(ctx, "Export Markers & Regions to Clipboard & Console") then
      Main_Export()
      reaper.ImGui_Text(ctx, "Exported!")
    end

    reaper.ImGui_End(ctx)
  end

  if open then
    reaper.defer(loop)
  else
    if ctx and reaper.ImGui_DestroyContext then
      reaper.ImGui_DestroyContext(ctx)
    end
  end
end

-- Initialize preset system
presets = load_presets()
-- Ensure presets is always a table
if not presets or type(presets) ~= "table" then
  presets = {}
end

preset_names = {}
for k in pairs(presets) do 
  table.insert(preset_names, k) 
end
table.sort(preset_names)

-- Auto-select the first preset if there are presets but no current selection
if #preset_names > 0 and (not current_preset or current_preset == "" or not presets[current_preset]) then
  current_preset = preset_names[1]
end

reaper.defer(loop)