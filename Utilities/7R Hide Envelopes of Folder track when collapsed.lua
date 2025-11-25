--[[
@description 7R Hide Envelopes of Folder track when collapsed
@author 7thResonance
@version 1.0
@donation https://paypal.me/7thresonance
@about Intented to use with collapes folders. Hides the atumation from the folder.
--]]

function msg(s) reaper.ShowConsoleMsg(tostring(s).."\n") end

local function TrackIsFolder(track)
    return reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH") == 1
end

local function GetFolderCollapseState(track)
    return reaper.GetMediaTrackInfo_Value(track, "I_FOLDERCOMPACT")
end

-- Hide all visible envelopes and store their states
local function HideTrackEnvelopes(track)
    local envCount = reaper.CountTrackEnvelopes(track)
    local saved = {}

    for i = 0, envCount-1 do
        local env = reaper.GetTrackEnvelope(track, i)

        local br = ({reaper.GetEnvelopeStateChunk(env, "", false)})[2]
        -- Check if lane is visible
        local visible = br:match("VIS %d")
        local visVal = visible and tonumber(visible:match("%d")) or 0

        if visVal == 1 then
            table.insert(saved, i)
            -- Set lane visibility to 0
            local new = br:gsub("VIS %d", "VIS 0")
            reaper.SetEnvelopeStateChunk(env, new, false)
        end
    end

    -- Write saved indices to P_EXT
    local json = table.concat(saved, ",")
    reaper.GetSetMediaTrackInfo_String(track, "P_EXT:SavedEnvVisible", json, true)
end

-- Restore previously-visible envelopes
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

    -- Clear restore memory
    reaper.GetSetMediaTrackInfo_String(track, "P_EXT:SavedEnvVisible", "", true)
end


-- MAIN LOOP (deferred / realtime)
local lastState = {}

function Main()
    local tracks = reaper.CountTracks(0)

    for i = 0, tracks-1 do
        local tr = reaper.GetTrack(0, i)

        if TrackIsFolder(tr) then
            local state = GetFolderCollapseState(tr)

            if lastState[tr] ~= state then
                -- Folder collapsed
                if state >= 1 then
                    HideTrackEnvelopes(tr)
                else
                    -- Folder expanded
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
reaper.Undo_EndBlock("Auto-hide folder envelopes on collapse", -1)
