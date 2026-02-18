--[[
@description 7R Untrim Item to source Length (until other item edge)
@author 7thResonance
@version 1.0
@changelog - intital
@about 
 Expands selected media item(s) so their visible take covers the full source length.
 Each edge (left and right) is expanded independently and will stop at the nearest
 item edge on the same track (so items won't overlap).

 Behavior summary:
 - For each selected item: read take source length, take start offset, playrate.
 - Compute how much left and right can expand to reach source start/end.
 - Limit each expansion by nearest neighboring item edge on the same track.
 - Apply the expansions by lengthening the item.

 Notes:
 - Works on audio items (media sources) and on items with takes.
 - If there is no neighboring item in a direction, that edge may expand up to the source.
 - Operates on all selected items. Undoable as a single action.

--]]


-- Helpers
local function get_item_edges(item)
  local p = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local l = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  return p, p + l
end

local function find_nearest_edges_on_track(track, this_item, this_left, this_right)
  local nearest_left = nil -- nearest right-edge strictly < this_left
  local nearest_right = nil -- nearest left-edge strictly > this_right
  local cnt = reaper.GetTrackNumMediaItems(track)
  for i = 0, cnt-1 do
    local it = reaper.GetTrackMediaItem(track, i)
    if it ~= this_item then
      local l = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
      local r = l + reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
      if r <= this_left then
        if (not nearest_left) or (r > nearest_left) then nearest_left = r end
      end
      if l >= this_right then
        if (not nearest_right) or (l < nearest_right) then nearest_right = l end
      end
    end
  end
  return nearest_left, nearest_right
end

-- Main
local function main()
  local num_sel = reaper.CountSelectedMediaItems(0)
  if num_sel == 0 then
    reaper.ShowMessageBox("No selected media items.", "7R Untrim Item", 0)
    return
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  for idx = 0, num_sel-1 do
    local item = reaper.GetSelectedMediaItem(0, idx)
    if item then
      local take = reaper.GetActiveTake(item)
      if not take then goto continue end

      local source = reaper.GetMediaItemTake_Source(take)
      if not source then goto continue end

      local src_len = reaper.GetMediaSourceLength(source)
      if not src_len or src_len <= 0 then goto continue end

      local playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
      if playrate == 0 then playrate = 1.0 end

      local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      local item_end = item_pos + item_len

      local startoffs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")

      -- Which portion of source is currently visible: [startoffs, startoffs + item_len*playrate]
      local vis_src_left = startoffs
      local vis_src_right = startoffs + item_len * playrate

      -- Desired deltas (in project time) to reach full source on each side
      local desired_left_delta = 0
      if vis_src_left > 0 then desired_left_delta = vis_src_left / playrate end
      local desired_right_delta = 0
      if vis_src_right < src_len then desired_right_delta = (src_len - vis_src_right) / playrate end

      -- Find nearest items on same track to limit movement
      local track = reaper.GetMediaItemTrack(item)
      local neigh_left, neigh_right = find_nearest_edges_on_track(track, item, item_pos, item_end)

      local allowed_left = desired_left_delta
      if neigh_left then
        local max_left_possible = item_pos - neigh_left
        if max_left_possible < allowed_left then allowed_left = math.max(0, max_left_possible) end
      end

      local allowed_right = desired_right_delta
      if neigh_right then
        local max_right_possible = neigh_right - item_end
        if max_right_possible < allowed_right then allowed_right = math.max(0, max_right_possible) end
      end

      -- If both edges limited, apply both independently (left moves start, right extends end)
      if allowed_left > 1e-12 or allowed_right > 1e-12 then
        local new_pos = item_pos - allowed_left
        local new_len = item_len + allowed_left + allowed_right
        local new_startoffs = startoffs - (allowed_left * playrate)
        if new_startoffs < 0 then new_startoffs = 0 end

        reaper.SetMediaItemInfo_Value(item, "D_POSITION", new_pos)
        reaper.SetMediaItemInfo_Value(item, "D_LENGTH", new_len)
        reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", new_startoffs)
        reaper.UpdateItemInProject(item)
      end
    end
    ::continue::
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("7R: Untrim selected item(s) to source length (limit to nearest edges)", -1)
end

main()
