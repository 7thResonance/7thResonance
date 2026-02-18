--[[
@description 7R Insert Project/Take Marker at mouse pointer
@author 7thResonance
@version 1.1
@changelog Takes item offset into account
@about Allows to add markers on items themselves or the ruler (project markers), just point and press shortcut!
--]]
function Main()
  -- Get mouse position
  local mouse_x, mouse_y = reaper.GetMousePosition()
  local mouse_pos = reaper.BR_PositionAtMouseCursor(true) -- Precise timeline position

  if mouse_pos < 0 then return end -- Exit if mouse is not in valid position

  -- Check if mouse is over timeline (ruler)
  local window, segment, details = reaper.BR_GetMouseCursorContext()
  if segment == "timeline" then
    -- Create project marker at mouse timeline position
    reaper.AddProjectMarker(0, false, mouse_pos, 0, "", -1)
    reaper.Undo_OnStateChange("Add project marker at mouse position")
    return
  end

  -- Check if mouse is over an item
  local item, take = reaper.GetItemFromPoint(mouse_x, mouse_y, true)
  if item and take then
    local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local take_startoffs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS") -- "Start in source"

    -- Calculate position in source (where the take marker should go)
    local position_in_item = mouse_pos - item_start
    if position_in_item >= 0 and position_in_item <= item_length then
      local position_in_source = position_in_item + take_startoffs
      -- Add take marker at correct position in source
      reaper.SetTakeMarker(take, -1, "", position_in_source)
      reaper.Undo_OnStateChange("Add take marker at mouse position")
    end
  end
end

-- Run script with undo block
reaper.Undo_BeginBlock()
Main()
reaper.Undo_EndBlock("Create Project or Take Marker", -1)