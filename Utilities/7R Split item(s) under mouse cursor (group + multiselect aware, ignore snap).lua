--[[
@description 7R Split item(s) under mouse cursor (group + multiselect, ignore snap, no change in selection)
@author 7thResonance
@version 1.0
@about
  Splits media items at the mouse cursor position while ignoring snap.

  Behavior:
  1) Split item under mouse cursor.
  2) Respects grouping and multi-selection.
  3) If multiple items are selected and mouse is over an unselected item,
     only that unselected item is split.
  4) All splits ignore snap (split is exactly at mouse position).
  5) Doesnt change selection

  Requires SWS extension for mouse-position-at-arrange support.
--]]

local function msg(text)
  reaper.ShowMessageBox(text, "Split item under mouse cursor", 0)
end

local function get_mouse_split_position()
  if reaper.BR_PositionAtMouseCursor then
    return reaper.BR_PositionAtMouseCursor(true)
  end

  if reaper.BR_GetMouseCursorContext_Position then
    return reaper.BR_GetMouseCursorContext_Position()
  end

  return nil
end

local function add_item_if_new(list, seen, item)
  if item and not seen[item] then
    seen[item] = true
    list[#list + 1] = item
  end
end

local function collect_selected_items()
  local items = {}
  local seen = {}
  local count = reaper.CountSelectedMediaItems(0)

  for i = 0, count - 1 do
    add_item_if_new(items, seen, reaper.GetSelectedMediaItem(0, i))
  end

  return items, seen
end

local function expand_with_grouped_items(items, seen)
  local group_ids = {}

  for i = 1, #items do
    local item = items[i]
    local group_id = reaper.GetMediaItemInfo_Value(item, "I_GROUPID")
    if group_id and group_id > 0 then
      group_ids[group_id] = true
    end
  end

  if next(group_ids) == nil then
    return items, seen
  end

  local total_items = reaper.CountMediaItems(0)
  for i = 0, total_items - 1 do
    local item = reaper.GetMediaItem(0, i)
    local group_id = reaper.GetMediaItemInfo_Value(item, "I_GROUPID")
    if group_id and group_id > 0 and group_ids[group_id] then
      add_item_if_new(items, seen, item)
    end
  end

  return items, seen
end

local x, y = reaper.GetMousePosition()
local mouse_item = reaper.GetItemFromPoint(x, y, true)
if not mouse_item then
  return
end

local split_pos = get_mouse_split_position()
if not split_pos then
  msg("This script requires SWS extension (BR_PositionAtMouseCursor).")
  return
end

local selected_count = reaper.CountSelectedMediaItems(0)
local mouse_is_selected = reaper.IsMediaItemSelected(mouse_item)
local multiselect_active = selected_count > 1

local targets = {}
local seen = {}
local use_group_expansion = true

if multiselect_active and not mouse_is_selected then
  -- Explicit rule: ignore current multi-selection and split only hovered item.
  add_item_if_new(targets, seen, mouse_item)
  use_group_expansion = false
elseif mouse_is_selected and selected_count > 0 then
  targets, seen = collect_selected_items()
else
  add_item_if_new(targets, seen, mouse_item)
end

if use_group_expansion then
  targets, seen = expand_with_grouped_items(targets, seen)
end

if #targets == 0 then
  return
end

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

for i = 1, #targets do
  reaper.SplitMediaItem(targets[i], split_pos)
end

reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
reaper.Undo_EndBlock("Split item(s) under mouse cursor (ignore snap)", -1)
