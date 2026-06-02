--[[
@description 7R Fade under mouse cursor
@author 7thResonance
@version 1.0
@about
  Release the shortcut to fade the item under the mouse, or all selected items
  when more than one item is selected. Before the item midpoint sets a fade-in;
  after it sets a fade-out.

  Hold the shortcut for more than 50 ms and move left/right to override the
  midpoint decision on release. Left movement applies fade-ins; right movement
  applies fade-outs.

  If a target overlaps another item on the same track at or near the mouse
  position, the script sets mirrored crossfade-facing fades.

  Requires SWS for accurate mouse timeline position. Hold detection for keyboard
  shortcuts requires js_ReaScriptAPI.
--]]

local SCRIPT_NAME = "7R Fade under mouse cursor"
local EXT_SECTION = "7R_FadeUnderMouseCursor"
local EXT_KEY = "run_token"
local HOLD_SECONDS = 0.05
local MOVE_THRESHOLD_PX = 2
local OVERLAP_NEAR_PIXELS = 24
local STALE_RUN_SECONDS = 300
local EPSILON = 1e-9

local function msg(text)
  reaper.ShowMessageBox(text, SCRIPT_NAME, 0)
end

local function clamp(value, min_value, max_value)
  if value < min_value then return min_value end
  if value > max_value then return max_value end
  return value
end

local function get_item_bounds(item)
  local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  return pos, pos + len, len
end

local function get_mouse_timeline_position()
  if reaper.BR_PositionAtMouseCursor then
    local pos = reaper.BR_PositionAtMouseCursor(true)
    if pos and pos >= 0 then return pos end
  end

  if reaper.BR_GetMouseCursorContext_Position then
    local pos = reaper.BR_GetMouseCursorContext_Position()
    if pos and pos >= 0 then return pos end
  end

  return nil
end

local function add_item_if_new(items, seen, item)
  if item and not seen[item] then
    seen[item] = true
    items[#items + 1] = item
  end
end

local function collect_targets()
  local targets = {}
  local seen = {}
  local selected_count = reaper.CountSelectedMediaItems(0)
  local x, y = reaper.GetMousePosition()
  local mouse_item = reaper.GetItemFromPoint(x, y, true)

  if selected_count > 1 then
    for i = 0, selected_count - 1 do
      add_item_if_new(targets, seen, reaper.GetSelectedMediaItem(0, i))
    end
    return targets, mouse_item
  end

  add_item_if_new(targets, seen, mouse_item)
  return targets, mouse_item
end

local function list_contains_item(items, item)
  if not item then return false end
  for i = 1, #items do
    if items[i] == item then return true end
  end
  return false
end

local function get_reference_item(targets, mouse_item, mouse_pos)
  if list_contains_item(targets, mouse_item) then return mouse_item end

  for i = 1, #targets do
    local item_start, item_end = get_item_bounds(targets[i])
    if mouse_pos >= item_start - EPSILON and mouse_pos <= item_end + EPSILON then
      return targets[i]
    end
  end

  return targets[1]
end

local function get_side_from_item(item, mouse_pos)
  local item_start, _, item_len = get_item_bounds(item)
  local midpoint = item_start + item_len * 0.5
  return mouse_pos < midpoint and "in" or "out"
end

local function get_effective_fade_length(item, side)
  if side == "in" then
    local fade_len = reaper.GetMediaItemInfo_Value(item, "D_FADEINLEN")
    local auto_len = reaper.GetMediaItemInfo_Value(item, "D_FADEINLEN_AUTO")
    if fade_len > 0 then return fade_len end
    return auto_len > 0 and auto_len or 0
  end

  local fade_len = reaper.GetMediaItemInfo_Value(item, "D_FADEOUTLEN")
  local auto_len = reaper.GetMediaItemInfo_Value(item, "D_FADEOUTLEN_AUTO")
  if fade_len > 0 then return fade_len end
  return auto_len > 0 and auto_len or 0
end

local function set_fade(item, side, length)
  local _, _, item_len = get_item_bounds(item)
  local opposite_side = side == "in" and "out" or "in"
  local opposite_len = get_effective_fade_length(item, opposite_side)
  local max_len = math.min(item_len, math.max(0, item_len - opposite_len))
  length = clamp(length or 0, 0, max_len)

  if side == "in" then
    reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN_AUTO", 0)
    reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN", length)
  elseif side == "out" then
    reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN_AUTO", 0)
    reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", length)
  end

  reaper.UpdateItemInProject(item)
  return length
end

local function apply_single_item_fade(item, mouse_pos, side)
  local item_start, item_end, item_len = get_item_bounds(item)
  if item_len <= EPSILON then return false end
  if mouse_pos < item_start - EPSILON or mouse_pos > item_end + EPSILON then return false end

  if side == "in" then
    set_fade(item, "in", mouse_pos - item_start)
  else
    set_fade(item, "out", item_end - mouse_pos)
  end

  return true
end

local function make_pair_key(left_item, right_item)
  return tostring(left_item) .. "|" .. tostring(right_item)
end

local function get_overlap_search_padding()
  local zoom = reaper.GetHZoomLevel and reaper.GetHZoomLevel() or 0
  if zoom and zoom > 0 then
    return OVERLAP_NEAR_PIXELS / zoom
  end

  return 0
end

local function build_overlap_pair(item, other)
  local item_start, item_end = get_item_bounds(item)
  local other_start, other_end = get_item_bounds(other)
  local overlap_start = math.max(item_start, other_start)
  local overlap_end = math.min(item_end, other_end)

  if overlap_end <= overlap_start + EPSILON then return nil end
  if math.abs(item_start - other_start) <= EPSILON then return nil end

  local left_item, right_item = item, other
  local left_start, right_start = item_start, other_start

  if right_start < left_start then
    left_item, right_item = other, item
    left_start, right_start = other_start, item_start
  end

  return {
    left = left_item,
    right = right_item,
    overlap_start = overlap_start,
    overlap_end = overlap_end,
    union_start = math.min(item_start, other_start),
    union_end = math.max(item_end, other_end)
  }
end

local function mouse_is_near_overlap(pair, mouse_pos, padding)
  local near_start = math.max(pair.union_start, pair.overlap_start - padding)
  local near_end = math.min(pair.union_end, pair.overlap_end + padding)

  return mouse_pos >= near_start - EPSILON and mouse_pos <= near_end + EPSILON
end

local function find_overlap_pairs(targets, mouse_pos)
  local pairs = {}
  local pair_seen = {}
  local items_in_pairs = {}
  local padding = get_overlap_search_padding()

  for i = 1, #targets do
    local item = targets[i]
    local track = reaper.GetMediaItem_Track(item)
    local track_item_count = reaper.CountTrackMediaItems(track)

    for j = 0, track_item_count - 1 do
      local other = reaper.GetTrackMediaItem(track, j)
      if other ~= item then
        local pair = build_overlap_pair(item, other)

        if pair and mouse_is_near_overlap(pair, mouse_pos, padding) then
          local key = make_pair_key(pair.left, pair.right)
          if not pair_seen[key] then
            pair_seen[key] = true
            pairs[#pairs + 1] = pair
            items_in_pairs[pair.left] = true
            items_in_pairs[pair.right] = true
          end
        end
      end
    end
  end

  return pairs, items_in_pairs
end

local function apply_crossfade_pair(pair, mouse_pos)
  local overlap_len = pair.overlap_end - pair.overlap_start
  if overlap_len <= EPSILON then return false end

  local fade_len
  if mouse_pos < pair.overlap_start then
    fade_len = pair.overlap_start - mouse_pos
  else
    fade_len = mouse_pos - pair.overlap_start
  end

  fade_len = clamp(fade_len, 0, overlap_len)
  if fade_len <= EPSILON then return false end

  set_fade(pair.left, "out", fade_len)
  set_fade(pair.right, "in", fade_len)
  return true
end

local function apply_fades(targets, mouse_item, mouse_pos, override_side)
  local changed = false
  local pairs, items_in_pairs = find_overlap_pairs(targets, mouse_pos)
  local reference_item = get_reference_item(targets, mouse_item, mouse_pos)
  local side = override_side or get_side_from_item(reference_item, mouse_pos)

  for i = 1, #pairs do
    changed = apply_crossfade_pair(pairs[i], mouse_pos) or changed
  end

  for i = 1, #targets do
    local item = targets[i]
    if not items_in_pairs[item] then
      changed = apply_single_item_fade(item, mouse_pos, side) or changed
    end
  end

  if changed then
    reaper.UpdateArrange()
  end

  return changed
end

local function apply_fades_with_undo(targets, mouse_item, mouse_pos, override_side)
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  apply_fades(targets, mouse_item, mouse_pos, override_side)

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock(SCRIPT_NAME, -1)
end

local function get_trigger_key_code()
  local _, _, _, _, _, _, _, context = reaper.get_action_context()
  if type(context) ~= "string" then return nil end

  local _, code = context:match("key:([^:]*):(%d+)")
  return tonumber(code)
end

local function is_key_down(key_code)
  if not key_code or not reaper.JS_VKeys_GetState then return false end

  local state = reaper.JS_VKeys_GetState(-1)
  if not state or key_code < 1 or key_code > #state then return false end

  return state:byte(key_code) ~= 0
end

local function main()
  local start_time = reaper.time_precise()
  local existing_run = tonumber(reaper.GetExtState(EXT_SECTION, EXT_KEY))
  if existing_run and start_time - existing_run >= 0 and start_time - existing_run < STALE_RUN_SECONDS then
    return
  end

  local targets, mouse_item = collect_targets()
  if #targets == 0 then return end

  local mouse_pos = get_mouse_timeline_position()
  if not mouse_pos then
    msg("This script requires SWS extension for mouse timeline position.")
    return
  end

  local start_x = select(1, reaper.GetMousePosition())
  local key_code = get_trigger_key_code()
  local can_track_hold = key_code and reaper.JS_VKeys_GetState

  local _, _, section_id, command_id = reaper.get_action_context()
  local run_token = string.format("%.9f", start_time)
  local run_active = true
  local pending_override_side = nil

  reaper.SetExtState(EXT_SECTION, EXT_KEY, run_token, false)

  local function cleanup()
    if not run_active then return end

    run_active = false
    if reaper.GetExtState(EXT_SECTION, EXT_KEY) == run_token then
      reaper.DeleteExtState(EXT_SECTION, EXT_KEY, false)
    end
    if section_id and command_id then
      reaper.SetToggleCommandState(section_id, command_id, 0)
      reaper.RefreshToolbar2(section_id, command_id)
    end
  end

  local function apply_on_release(override_side)
    cleanup()
    apply_fades_with_undo(targets, mouse_item, mouse_pos, override_side)
  end

  reaper.atexit(cleanup)

  if not can_track_hold or not is_key_down(key_code) then
    cleanup()
    apply_fades_with_undo(targets, mouse_item, mouse_pos, nil)
    return
  end

  if section_id and command_id then
    reaper.SetToggleCommandState(section_id, command_id, 1)
    reaper.RefreshToolbar2(section_id, command_id)
  end

  local function loop()
    if reaper.GetExtState(EXT_SECTION, EXT_KEY) ~= run_token then
      cleanup()
      return
    end

    if not is_key_down(key_code) then
      apply_on_release(pending_override_side)
      return
    end

    if reaper.time_precise() - start_time >= HOLD_SECONDS then
      local x = select(1, reaper.GetMousePosition())
      local dx = x - start_x

      if math.abs(dx) >= MOVE_THRESHOLD_PX then
        pending_override_side = dx < 0 and "in" or "out"
      end
    end

    reaper.defer(loop)
  end

  reaper.defer(loop)
end

main()
