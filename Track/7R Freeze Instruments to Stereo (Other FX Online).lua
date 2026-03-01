--[[
@description 7R Freeze Instruments to Stereo (Other FX Online)
@author 7thResonance
@version 1.4
@changelog  - Multi instrument detection
            - FX before the first FX are now kept online, only FX after the instrument are frozen offline.
@about Freezes Selected tracks. up to Instrument, Other FX are brough online after freezing.

    Lua Script for Reaper: Offline non-instrument FX, Freeze Selected Tracks to Stereo, Unlock All Items Directly, Online Remaining FX
--]]
-- Main function
local function is_instrument_fx(track, fx_idx)
    if reaper.TrackFX_GetInstrument(track) == fx_idx then
        return true
    end

    -- Prefer config type when available (e.g. VSTi/CLAPi/AUi/DXi).
    local ok, fx_type = reaper.TrackFX_GetNamedConfigParm(track, fx_idx, "fx_type")
    if ok and type(fx_type) == "string" and fx_type:match("i$") then
        return true
    end

    -- Fallback for older REAPER versions where fx_type may be unavailable.
    local _, fx_name = reaper.TrackFX_GetFXName(track, fx_idx, "")
    if fx_name:match("^VSTi:") or fx_name:match("^CLAPi:") or fx_name:match("^AUi:") or fx_name:match("^DXi:") then
        return true
    end

    return false
end

-- Main function
local function main()
    -- Step 0: Unselect folder tracks at the very start
    local original_selection = {}
    local track_count = reaper.CountSelectedTracks(0)
    if track_count == 0 then
        return
    end

    -- Store original selection and unselect folder tracks
    for track_idx = 0, track_count - 1 do
        local track = reaper.GetSelectedTrack(0, track_idx)
        if track then
            table.insert(original_selection, track)
            local is_folder = reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH") == 1
            local track_index = reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") - 1
            local next_track_idx = track_index + 1
            local next_track = reaper.GetTrack(0, next_track_idx)
            local has_child = next_track and reaper.GetTrackDepth(next_track) > reaper.GetTrackDepth(track)
            if is_folder or has_child then
                reaper.SetTrackSelected(track, false)
            end
        end
    end

    -- Re-check track count after unselecting folder tracks
    track_count = reaper.CountSelectedTracks(0)
    if track_count == 0 then
        reaper.Main_OnCommand(40289, 0) -- Unselect all tracks
        for _, track in ipairs(original_selection) do
            reaper.SetTrackSelected(track, true)
        end
        return
    end

    -- Get all selected tracks into a table
    local selected_tracks = {}
    for track_idx = 0, track_count - 1 do
        local track = reaper.GetSelectedTrack(0, track_idx)
        if track then
            table.insert(selected_tracks, track)
        end
    end

    if #selected_tracks == 0 then
        reaper.Main_OnCommand(40289, 0) -- Unselect all tracks
        for _, track in ipairs(original_selection) do
            reaper.SetTrackSelected(track, true)
        end
        return
    end

    -- Step 1: Offline post-instrument FX for all selected tracks
    for i, track in ipairs(selected_tracks) do
        local fx_count = reaper.TrackFX_GetCount(track)
        if fx_count < 0 then
            goto continue_offline
        end
        local instrument_idx = reaper.TrackFX_GetInstrument(track)
        -- Keep FX before the instrument online; only offline FX after it.
        if instrument_idx >= 0 then
            for fx_idx = instrument_idx + 1, fx_count - 1 do
                if not is_instrument_fx(track, fx_idx) then
                    reaper.TrackFX_SetOffline(track, fx_idx, true)
                end
            end
        end
        ::continue_offline::
    end

    -- Step 2: For each track, check for last frozen item and determine next freeze name/number
    local freeze_info = {} -- key: track ptr, value: {base_name=..., next_num=...}
    for _, track in ipairs(selected_tracks) do
        local item_count = reaper.CountTrackMediaItems(track)
        local found = false
        local max_num = 0
        local base_name = nil

        for item_idx = 0, item_count - 1 do
            local item = reaper.GetTrackMediaItem(track, item_idx)
            if item then
                local take = reaper.GetActiveTake(item)
                if take and not reaper.TakeIsMIDI(take) then
                    local _, name = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
                    local b, n = name:match("^(.+) Frozen (%d+)$")
                    n = tonumber(n)
                    if b and n and n > max_num then
                        found = true
                        max_num = n
                        base_name = b
                    end
                    -- Handle "Frozen" with no number as first freeze (should be treated as 1)
                    if not b then
                        b = name:match("^(.+) Frozen$")
                        if b and max_num < 1 then
                            found = true
                            max_num = 1
                            base_name = b
                        end
                    end
                end
            end
        end

        if not found then
            -- Use track name as base for first freeze
            local _, track_name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
            base_name = track_name ~= "" and track_name or ("Track " .. tostring(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")))
            max_num = 0
        end

        freeze_info[track] = {base_name = base_name, next_num = max_num + 1}
    end

    -- Step 3: Freeze all selected tracks to stereo in one batch
    reaper.Main_OnCommand(40289, 0) -- Unselect all tracks
    for _, track in ipairs(selected_tracks) do
        reaper.SetTrackSelected(track, true)
        -- reaper.SetMediaTrackInfo_Value(track, "I_NCHAN", 2) -- Set to stereo
    end
    reaper.Main_OnCommand(41223, 0) -- Freeze selected tracks to stereo

    -- Step 4: Unlock all items on frozen tracks, and rename frozen items (hide "1" on first freeze)
    for _, track in ipairs(selected_tracks) do
        local item_count = reaper.CountTrackMediaItems(track)
        local info = freeze_info[track]
        local name_to_set
        if info.next_num == 1 then
            name_to_set = info.base_name .. " Frozen"
        else
            name_to_set = info.base_name .. " Frozen " .. tostring(info.next_num)
        end
        for item_idx = 0, item_count - 1 do
            local item = reaper.GetTrackMediaItem(track, item_idx)
            if item then
                reaper.SetMediaItemInfo_Value(item, "C_LOCK", 0)
                local take = reaper.GetActiveTake(item)
                if take and not reaper.TakeIsMIDI(take) then
                    reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", name_to_set, true)
                end
            end
        end
    end

    -- Step 5: Online all FX for all selected tracks
    for i, track in ipairs(selected_tracks) do
        local fx_count = reaper.TrackFX_GetCount(track)
        for fx_idx = 0, fx_count - 1 do
            reaper.TrackFX_SetOffline(track, fx_idx, false)
        end
    end

    -- Restore original track selection
    reaper.Main_OnCommand(40289, 0) -- Unselect all tracks
    for _, track in ipairs(original_selection) do
        reaper.SetTrackSelected(track, true)
    end

    -- Update the UI
    reaper.UpdateArrange()
    reaper.UpdateTimeline()
end

-- Run the script with undo block
reaper.Undo_BeginBlock()
main()
reaper.Undo_EndBlock("Freeze Non-Folder Tracks with Non-Instrument FX Handling", -1)
