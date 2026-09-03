--[[
@description 7R Freeze Instruments to Stereo (Other FX Online)
@author 7thResonance
@version 1.5
@changelog  - script rewrite.
            - Dont offline reaticulate.
@about Freezes Selected tracks. up to Instrument, Other FX are brough online after freezing.

    Lua Script for Reaper: Offline non-instrument FX, Freeze Selected Tracks to Stereo, Unlock All Items Directly, Online Remaining FX
--]]
-- Main function
local KEEP_ONLINE_JSFX = {
    ["Reaticulate"] = true,
}

local FREEZE_ACTION = 41223 -- Track: Freeze to stereo (render pre-fader, save/remove items and online FX)
local UNSELECT_ALL = 40289

local MAX_WAIT_CYCLES = 600

local function get_fx_name(track, fx_idx)
    local _, name = reaper.TrackFX_GetFXName(track, fx_idx, "")
    return name or ""
end

local function is_instrument_fx(track, fx_idx)
    if reaper.TrackFX_GetInstrument(track) == fx_idx then
        return true
    end

    local ok, fx_type = reaper.TrackFX_GetNamedConfigParm(track, fx_idx, "fx_type")
    if ok and type(fx_type) == "string" then
        if fx_type == "VSTi" or fx_type == "CLAPi" or fx_type == "AUi" or fx_type == "DXi" then
            return true
        end
    end

    local fx_name = get_fx_name(track, fx_idx)
    return fx_name:match("^VSTi:") ~= nil
        or fx_name:match("^CLAPi:") ~= nil
        or fx_name:match("^AUi:") ~= nil
        or fx_name:match("^DXi:") ~= nil
end

local function is_keep_online_jsfx(track, fx_idx)
    local _, displayed_name = reaper.TrackFX_GetFXName(track, fx_idx, "")
    displayed_name = displayed_name or ""

    local ok_name, fx_name = reaper.TrackFX_GetNamedConfigParm(track, fx_idx, "fx_name")
    if not ok_name or type(fx_name) ~= "string" then
        fx_name = ""
    end

    local ok_ident, fx_ident = reaper.TrackFX_GetNamedConfigParm(track, fx_idx, "fx_ident")
    if not ok_ident or type(fx_ident) ~= "string" then
        fx_ident = ""
    end

    local ok_type, fx_type = reaper.TrackFX_GetNamedConfigParm(track, fx_idx, "fx_type")
    if not ok_type or type(fx_type) ~= "string" then
        fx_type = ""
    end

    local disp = displayed_name:lower()
    local name = fx_name:lower()
    local ident = fx_ident:lower()
    local typ = fx_type:lower()

    local function name_matches(name_value, wanted)
        return name_value == wanted or name_value:match("^" .. wanted .. "%s*$") ~= nil
    end

    local direct_name_match = false
    for wanted_name, enabled in pairs(KEEP_ONLINE_JSFX) do
        if enabled then
            local wanted = wanted_name:lower()
            if name_matches(name, wanted)
                or name_matches(disp:gsub("^js:%s*", ""), wanted) then
                direct_name_match = true
                break
            end
        end
    end

    if direct_name_match then
        return true
    end

    local is_js = typ == "js" or disp:match("^js:%s*") ~= nil
    if is_js then
        for wanted_name, enabled in pairs(KEEP_ONLINE_JSFX) do
            if enabled then
                local wanted = wanted_name:lower()
                if ident:find(wanted, 1, true) ~= nil
                    or name:find(wanted, 1, true) ~= nil
                    or disp:find(wanted, 1, true) ~= nil then
                    return true
                end
            end
        end
    end

    -- Final direct lookup fallback for JSFX whose displayed/config fields differ.
    for wanted_name, enabled in pairs(KEEP_ONLINE_JSFX) do
        if enabled then
            local direct_idx = reaper.TrackFX_GetByName(track, wanted_name, false)
            if direct_idx == fx_idx then
                return true
            end
        end
    end

    return false
end

local function get_fx_guid(track, fx_idx)
    local guid = reaper.TrackFX_GetFXGUID(track, fx_idx)
    if type(guid) == "string" and guid ~= "" then
        return guid
    end
    return nil
end

local function find_fx_by_guid(track, guid)
    if not guid then return -1 end

    local fx_count = reaper.TrackFX_GetCount(track)
    for fx_idx = 0, fx_count - 1 do
        if get_fx_guid(track, fx_idx) == guid then
            return fx_idx
        end
    end

    return -1
end

-- Inspect every FX and save its GUID while deciding which FX must be temporarily offline.
-- Exact requested rule:
--   before instrument -> online
--   instrument        -> online
--   Reaticulate       -> online
--   everything else   -> offline
local function build_offline_list(selected_tracks)
    local offline_fx = {}

    for _, track in ipairs(selected_tracks) do
        local instrument_idx = reaper.TrackFX_GetInstrument(track)
        local fx_count = reaper.TrackFX_GetCount(track)

        for fx_idx = 0, fx_count - 1 do
            local guid = get_fx_guid(track, fx_idx)
            local keep_online = is_keep_online_jsfx(track, fx_idx)
            local should_offline = false

            if keep_online then
                should_offline = false
            elseif instrument_idx >= 0 then
                should_offline = fx_idx > instrument_idx
            else
                should_offline = true
            end

            if should_offline and guid then
                offline_fx[#offline_fx + 1] = {
                    track = track,
                    guid = guid,
                }
            end
        end
    end

    return offline_fx
end

local function apply_offline_list(offline_fx)
    for _, record in ipairs(offline_fx) do
        local fx_idx = find_fx_by_guid(record.track, record.guid)
        if fx_idx >= 0 then
            reaper.TrackFX_SetOffline(record.track, fx_idx, true)
        end
    end
end

-- Bring every FX that still exists on the track online.
local function bring_all_remaining_fx_online(selected_tracks)
    for _, track in ipairs(selected_tracks) do
        local fx_count = reaper.TrackFX_GetCount(track)
        for fx_idx = 0, fx_count - 1 do
            reaper.TrackFX_SetOffline(track, fx_idx, false)
        end
    end
end

local function restore_selection(original_selection)
    reaper.Main_OnCommand(UNSELECT_ALL, 0)
    for _, track in ipairs(original_selection) do
        if track then
            reaper.SetTrackSelected(track, true)
        end
    end
end

local function get_freeze_info(selected_tracks)
    local freeze_info = {}

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
            local _, track_name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
            base_name = track_name ~= "" and track_name
                or ("Track " .. tostring(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")))
            max_num = 0
        end

        freeze_info[track] = {
            base_name = base_name,
            next_num = max_num + 1,
        }
    end

    return freeze_info
end

local function unlock_and_rename_frozen_items(selected_tracks, freeze_info)
    for _, track in ipairs(selected_tracks) do
        local item_count = reaper.CountTrackMediaItems(track)
        local info = freeze_info[track]
        if info then
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
    end
end

local function finish(original_selection)
    restore_selection(original_selection)
    reaper.UpdateArrange()
    reaper.UpdateTimeline()
    reaper.Undo_EndBlock("Freeze Instruments to Stereo (Other FX Online)", -1)
end

local function abort(original_selection, message)
    restore_selection(original_selection)
    reaper.UpdateArrange()
    reaper.UpdateTimeline()
    reaper.Undo_EndBlock("Freeze Instruments to Stereo (Other FX Online) - aborted", -1)

    if message then
        reaper.ShowMessageBox(message, "7R Freeze Instruments", 0)
    end
end

local function main()
    local original_selection = {}
    local selected_tracks = {}

    -- 1. Get selected tracks.
    local initial_count = reaper.CountSelectedTracks(0)
    if initial_count == 0 then
        return
    end

    for i = 0, initial_count - 1 do
        local track = reaper.GetSelectedTrack(0, i)
        if track then
            original_selection[#original_selection + 1] = track
        end
    end

    -- 2. Explicitly UNSELECT folder tracks immediately.
    for _, track in ipairs(original_selection) do
        local is_folder = reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH") == 1
        if is_folder then
            reaper.SetTrackSelected(track, false)
        end
    end

    -- Only non-folder selected tracks continue.
    local working_count = reaper.CountSelectedTracks(0)
    for i = 0, working_count - 1 do
        local track = reaper.GetSelectedTrack(0, i)
        if track then
            selected_tracks[#selected_tracks + 1] = track
        end
    end

    if #selected_tracks == 0 then
        restore_selection(original_selection)
        return
    end

    reaper.Undo_BeginBlock()

    -- 3-4. Inspect every FX, save GUIDs, and classify the FX.
    local offline_fx = build_offline_list(selected_tracks)

    -- Record naming information before freeze changes media items.
    local freeze_info = get_freeze_info(selected_tracks)

    -- Take exactly the classified FX offline.
    apply_offline_list(offline_fx)

    -- All remaining non-folder selected tracks are frozen, including tracks
    -- without an instrument. The FX classification above is the same for all
    -- tracks: protected FX stay online; everything else is temporarily offline.
    local freeze_tracks = {}
    for _, track in ipairs(selected_tracks) do
        freeze_tracks[#freeze_tracks + 1] = track
    end

    -- Select all non-folder working tracks for the native freeze action.
    reaper.Main_OnCommand(UNSELECT_ALL, 0)
    for _, track in ipairs(freeze_tracks) do
        reaper.SetTrackSelected(track, true)
    end

    -- 5. Freeze using exactly the FX online/offline state established above.
    reaper.Main_OnCommand(FREEZE_ACTION, 0)

    local wait_cycles = 0
    local stable_cycles = 0
    local last_state_change = reaper.GetProjectStateChangeCount()

    local function wait_for_freeze()
        wait_cycles = wait_cycles + 1

        local state_change = reaper.GetProjectStateChangeCount()
        if state_change ~= last_state_change then
            last_state_change = state_change
            stable_cycles = 0
        else
            stable_cycles = stable_cycles + 1
        end

        -- We intentionally do not verify the old GUIDs here. Native freeze may
        -- legitimately remove online FX, and the requested post-freeze behavior
        -- is simply to online every FX that remains.
        if stable_cycles >= 3 then
            -- 6. Bring every FX that remains on the selected tracks online.
            bring_all_remaining_fx_online(selected_tracks)
            unlock_and_rename_frozen_items(selected_tracks, freeze_info)
            finish(original_selection)
            return
        end

        if wait_cycles >= MAX_WAIT_CYCLES then
            abort(
                original_selection,
                "Timed out waiting for REAPER to finish the freeze.\n\n" ..
                "The script did not attempt to change the FX chain after the timeout."
            )
            return
        end

        reaper.defer(wait_for_freeze)
    end

    reaper.defer(wait_for_freeze)
end

main()
