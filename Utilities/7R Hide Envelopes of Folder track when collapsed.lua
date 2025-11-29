--[[
@description 7R Hide Envelopes of Folder track when collapsed
@author 7thResonance
@version 1.1
@changelog - Autocollapse mode. (disabled by default)
@donation https://paypal.me/7thresonance
@about Intented to use with colcollapsed folders. Hides the automation from the folder.
    Autocollapse mode when height is below threshold.
    Set these values at the top of the script.
    autoCollapse = 0, change to 1 to enable autocollapse.
--]]

-------------------------------------------
-- USER SETTINGS
-------------------------------------------

autoCollapse = 0        -- 0 = Off (default), 1 = Auto-collapse folders by height
heightThreshold = 25    -- TCP height in pixels at which folders collapse automatically

-------------------------------------------

function msg(s) reaper.ShowConsoleMsg(tostring(s).."\n") end

local function TrackIsFolder(track)
    return reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH") == 1
end

local function GetFolderCollapseState(track)
    return reaper.GetMediaTrackInfo_Value(track, "I_FOLDERCOMPACT")
end

local function SetFolderCollapseState(track, val)
    reaper.SetMediaTrackInfo_Value(track, "I_FOLDERCOMPACT", val)
end

--=====================================================
-- Hide all visible envelopes and store their indices
--=====================================================
local function HideTrackEnvelopes(track)
    local envCount = reaper.CountTrackEnvelopes(track)
    local saved = {}

    for i = 0, envCount-1 do
        local env = reaper.GetTrackEnvelope(track, i)

        local br = ({reaper.GetEnvelopeStateChunk(env, "", false)})[2]
        -- Check if visible
        local visible = br:match("VIS %d")
        local visVal = visible and tonumber(visible:match("%d")) or 0

        if visVal == 1 then
            table.insert(saved, i)
            local new = br:gsub("VIS %d", "VIS 0")
            reaper.SetEnvelopeStateChunk(env, new, false)
        end
    end

    -- Save indices
    local json = table.concat(saved, ",")
    reaper.GetSetMediaTrackInfo_String(track, "P_EXT:SavedEnvVisible", json, true)
end

--=====================================================
-- Restore previously visible envelopes
--=====================================================
local function RestoreTrackEnvelopes(track)
    local ok, json = reaper.GetSetMediaTrackInfo_String(track, "P_EXT:SavedEnvVisible", "", false)
    if not ok or json == "" then return end

    local restore = {}
    for idx in json:gmatch("(%d+)") do
        restore[tonumber(idx)] = true
    end

    local envCount = reaper.CountTrackEnvelopes(track)

    for i = 0, envCount-1 do
        if restore[i] then
            local env = reaper.GetTrackEnvelope(track, i)
            local br = ({reaper.GetEnvelopeStateChunk(env, "", false)})[2]
            local new = br:gsub("VIS %d", "VIS 1")
            reaper.SetEnvelopeStateChunk(env, new, false)
        end
    end

    reaper.GetSetMediaTrackInfo_String(track, "P_EXT:SavedEnvVisible", "", true)
end

--=====================================================
-- MAIN LOOP
--=====================================================

local lastState = {}

function Main()
    local tracks = reaper.CountTracks(0)

    for i = 0, tracks-1 do
        local tr = reaper.GetTrack(0, i)

        if TrackIsFolder(tr) then

            ---------------------------------------------------
            -- AUTO COLLAPSE / UNCOPLLAPSE BASED ON HEIGHT
            ---------------------------------------------------
            if autoCollapse == 1 then
                local height = reaper.GetMediaTrackInfo_Value(tr, "I_TCPH")
                local current = GetFolderCollapseState(tr)

                if height <= heightThreshold and current == 0 then
                    -- collapse folder
                    SetFolderCollapseState(tr, 2)
                elseif height > heightThreshold and current >= 1 then
                    -- uncollapse folder
                    SetFolderCollapseState(tr, 0)
                end
            end

            ---------------------------------------------------
            -- HANDLE ENVELOPE VISIBILITY WHEN COLLAPSED
            ---------------------------------------------------
            local state = GetFolderCollapseState(tr)

            if lastState[tr] ~= state then
                if state >= 1 then
                    HideTrackEnvelopes(tr)
                else
                    RestoreTrackEnvelopes(tr)
                end
                lastState[tr] = state
            end
        end
    end

    reaper.defer(Main)
end

reaper.Undo_BeginBlock()
Main()
reaper.Undo_EndBlock("Auto-hide folder envelopes + Auto-collapse", -1)
