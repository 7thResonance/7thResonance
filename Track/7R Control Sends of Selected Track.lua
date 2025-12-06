--[[
@description 7R Control Send volume of Selected Track
@author 7thResonance
@version 1.3
@donation https://paypal.me/7thresonance
@changelog Multiple sends to the same track bug is fixed. Controls each slot respectevely.
@about When mulltiple tracks are selected, can change the relative volume of the send over those tracks.

    due to my lack of knowledge, or limitation of API (i wouldnt know lmao) 
    alt key is the temporary override button, but you have to press it before dragging the mouse and it will stay active untill the mouse is released.

    Known issues; Undo doesnt work properly, have to undo untill track seletion changes for intial values to be restored. (idk how to fix this)
--]]

-- Function to convert linear volume to dB (no clamping)
local function LinearToDB(linear)
    return 20 * math.log(linear, 10) -- REAPER handles -inf internally
end

-- Function to convert dB to linear volume
local function DBToLinear(db)
    return 10 ^ (db / 20)
end

-- Helper: get send name & volume for a track/send index
local function GetSendInfo(track, send_idx)
    local _, send_name = reaper.GetTrackSendName(track, send_idx)
    local send_vol = reaper.GetTrackSendInfo_Value(track, 0, send_idx, "D_VOL")
    return send_name or "", send_vol
end

-- Store send volumes & pan by track and send index, in dB for volume
local function StoreSendVolumes()
    local track_sends = {}
    local sel_track_count = reaper.CountSelectedTracks(0)
    for i = 0, sel_track_count - 1 do
        local track = reaper.GetSelectedTrack(0, i)
        track_sends[track] = {}
        local send_count = reaper.GetTrackNumSends(track, 0)
        for j = 0, send_count - 1 do
            local send_name, vol = GetSendInfo(track, j)
            local pan = reaper.GetTrackSendInfo_Value(track, 0, j, "D_PAN")
            track_sends[track][j] = {
                send_name = send_name,
                vol = LinearToDB(vol),
                pan = pan
            }
        end
    end
    return track_sends
end

-- Main
local function Main()
    local track_sends = StoreSendVolumes()
    local last_sel_count = reaper.CountSelectedTracks(0)
    local alt_latched = false
    local mouse_was_down = false
    local changes_during_drag = {}
    local undo_started = false

    local function GetAltAndMouseState()
        local alt_held = false
        local mouse_down = false
        if reaper.JS_VKeys_GetState then
            local state = reaper.JS_VKeys_GetState(-1)
            if state and #state >= 18 then
                alt_held = state:byte(18) == 1 -- VK_MENU (Alt)
            end
        end
        if reaper.JS_Mouse_GetState then
            mouse_down = reaper.JS_Mouse_GetState(1) == 1 -- Left mouse button
        end
        return alt_held, mouse_down
    end

    local function CheckAndUpdate()
        -- Manager script handshake
        if reaper.GetExtState("7R_SendScripts", "manager_running") == "true" then
            track_sends = StoreSendVolumes()
            reaper.defer(CheckAndUpdate)
            return
        end

        local sel_track_count = reaper.CountSelectedTracks(0)

        if sel_track_count < 2 then
            track_sends = StoreSendVolumes()
            last_sel_count = sel_track_count
            reaper.defer(CheckAndUpdate)
            return
        end

        if sel_track_count ~= last_sel_count then
            track_sends = StoreSendVolumes()
            last_sel_count = sel_track_count
            reaper.defer(CheckAndUpdate)
            return
        end

        -- Alt latch
        local alt_held, mouse_down = GetAltAndMouseState()

        if mouse_down and alt_held then
            alt_latched = true
        elseif not mouse_down then
            alt_latched = false
        end

        -- Detect changes
        local changes = {}
        for i = 0, sel_track_count - 1 do
            local track = reaper.GetSelectedTrack(0, i)
            local send_count = reaper.GetTrackNumSends(track, 0)
            for j = 0, send_count - 1 do
                local send_name, current_vol = GetSendInfo(track, j)
                local current_vol_db = LinearToDB(current_vol)
                local current_pan = reaper.GetTrackSendInfo_Value(track, 0, j, "D_PAN")

                if track_sends[track] and track_sends[track][j] then
                    local stored = track_sends[track][j]
                    local vol_changed = (stored.vol ~= current_vol_db)
                    local pan_changed = math.abs(stored.pan - current_pan) > 0.001
                    if vol_changed or pan_changed then
                        table.insert(changes, {
                            track = track,
                            send_idx = j,
                            send_name = stored.send_name or send_name,
                            vol_change_db = vol_changed and (current_vol_db - stored.vol) or 0,
                            pan_change = pan_changed and (current_pan - stored.pan) or 0
                        })
                    end
                end
            end
        end

        -- Apply changes
        if #changes > 0 and not alt_latched then
            for _, change in ipairs(changes) do
                local target_send_name = change.send_name
                local vol_change_db = change.vol_change_db
                local pan_change = change.pan_change
                local changed_track = change.track
                local send_idx = change.send_idx

                for i = 0, sel_track_count - 1 do
                    local track2 = reaper.GetSelectedTrack(0, i)
                    if track2 ~= changed_track then
                        local send_count2 = reaper.GetTrackNumSends(track2, 0)
                        if send_idx < send_count2 then
                            local send_name2, _ = GetSendInfo(track2, send_idx)
                            if send_name2 == target_send_name then

                                if not undo_started then
                                    reaper.Undo_BeginBlock()
                                    undo_started = true
                                end

                                if vol_change_db ~= 0 then
                                    local current_vol2 = reaper.GetTrackSendInfo_Value(track2, 0, send_idx, "D_VOL")
                                    local current_vol2_db = LinearToDB(current_vol2)
                                    local new_vol = DBToLinear(current_vol2_db + vol_change_db)
                                    reaper.SetTrackSendInfo_Value(track2, 0, send_idx, "D_VOL", new_vol)
                                end

                                if pan_change ~= 0 then
                                    local current_pan2 = reaper.GetTrackSendInfo_Value(track2, 0, send_idx, "D_PAN")
                                    local new_pan2 = current_pan2 + pan_change
                                    reaper.SetTrackSendInfo_Value(track2, 0, send_idx, "D_PAN", new_pan2)
                                end
                            end
                        end
                    end
                end
            end

            track_sends = StoreSendVolumes()
        end

        if mouse_was_down and not mouse_down then
            if undo_started then
                reaper.Undo_EndBlock("Adjust send volumes across selected tracks", -1)
                undo_started = false
            end
            changes_during_drag = {}
        end

        mouse_was_down = mouse_down

        reaper.defer(CheckAndUpdate)
    end

    reaper.defer(CheckAndUpdate)
end

Main()
