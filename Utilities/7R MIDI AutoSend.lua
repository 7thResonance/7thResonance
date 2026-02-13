--[[
@description 7R MIDI Auto Send for CC Feedback
@author 7thResonance
@version 1.11
@changelog - Re; Stricter clean up when selection changes.
    - Re; Added exit clean up
@link Youtube Video https://www.youtube.com/watch?v=u1325Y-tJZQ
@donation https://paypal.me/7thresonance
@about MIDI Auto Send from selected track to Specific track
    Original Script made by Heda. This script allows to send MIDI back to hardware faders. (assuming it supports midi receives and motorised faders positioning themselves)

    Creates a MIDI Send from selected track to "Hardware Feedback Track"
    Auto Creates track when script is first ran.

    Save the track as part of the default template with the appropriate filters and hardware send. 
    Disable master send of the hardware feedback track.

    - Does not create send if its a Folder.
    - has a delay of 500 ms to create a send.
    - Need track selection undo points.
--]]

local FEEDBACK_TRACK_NAME = "Hardware Feedback Track"

function findHardwareFeedbackTrack()
    for i = 0, reaper.CountTracks(0) - 1 do
        local track = reaper.GetTrack(0, i)
---@diagnostic disable-next-line: redundant-parameter
        local _, trackName = reaper.GetTrackName(track, "")
        if trackName == FEEDBACK_TRACK_NAME then
            return track
        end
    end
    return nil
end

-- Function to check or create "Hardware Feedback Track" in the current project
function ensureHardwareFeedbackTrack()
    local feedbackTrack = findHardwareFeedbackTrack()
    if not feedbackTrack then
        reaper.Undo_BeginBlock()
        reaper.InsertTrackAtIndex(reaper.CountTracks(0), false)
        feedbackTrack = reaper.GetTrack(0, reaper.CountTracks(0) - 1)
        reaper.GetSetMediaTrackInfo_String(feedbackTrack, "P_NAME", FEEDBACK_TRACK_NAME, true)
        reaper.Undo_EndBlock("Create Hardware Feedback Track", -1)
    end
    return feedbackTrack
end

-- Remove all receives on the feedback track (equivalent to removing all sends targeting it)
function removeAllFeedbackReceives(feedbackTrack)
    if not feedbackTrack then return end
    for recvIdx = reaper.GetTrackNumSends(feedbackTrack, -1) - 1, 0, -1 do
        reaper.RemoveTrackSend(feedbackTrack, -1, recvIdx)
    end
end

-- Keep only one receive from keepSourceTrack on feedback track, remove everything else.
-- Returns true when a kept receive already existed.
function keepOnlyFeedbackReceiveFrom(feedbackTrack, keepSourceTrack)
    if not feedbackTrack then return false end
    local hasKeptReceive = false

    for recvIdx = reaper.GetTrackNumSends(feedbackTrack, -1) - 1, 0, -1 do
        local srcTrack = reaper.BR_GetMediaTrackSendInfo_Track(feedbackTrack, -1, recvIdx, 0)
        local keepThis = keepSourceTrack and srcTrack == keepSourceTrack

        if keepThis and not hasKeptReceive then
            hasKeptReceive = true
        else
            reaper.RemoveTrackSend(feedbackTrack, -1, recvIdx)
        end
    end

    return hasKeptReceive
end
  
-- Function to create a MIDI-only send to "Hardware Feedback Track"
function setupMIDISend(selectedTrack, feedbackTrack)
    if selectedTrack and feedbackTrack then
      local sendIdx = reaper.CreateTrackSend(selectedTrack, feedbackTrack)
      reaper.SetTrackSendInfo_Value(selectedTrack, 0, sendIdx, "I_SRCCHAN", -1) -- All MIDI channels
      reaper.SetTrackSendInfo_Value(selectedTrack, 0, sendIdx, "I_DSTCHAN", 0)  -- Destination to channel 1
      reaper.SetTrackSendInfo_Value(selectedTrack, 0, sendIdx, "I_MIDIFLAGS", 1) -- MIDI only
      reaper.SetTrackSendInfo_Value(selectedTrack, 0, sendIdx, "I_SENDMODE", 1)
    end
end

function isHardwareFeedbackTrack(track)
    if not track then return false end
---@diagnostic disable-next-line: redundant-parameter
    local _, trackName = reaper.GetTrackName(track, "")
    return trackName == FEEDBACK_TRACK_NAME
end

-- Utility: Check if track has any items
function trackHasAnyItems(track)
    if not track then return false end
    local itemCount = reaper.CountTrackMediaItems(track)
    return itemCount > 0
end

-- Utility: Check if track has any MIDI items
function trackHasAnyMIDIItems(track)
    if not track then return false end
    local itemCount = reaper.CountTrackMediaItems(track)
    for i = 0, itemCount - 1 do
        local item = reaper.GetTrackMediaItem(track, i)
        if item then
            local takeCount = reaper.CountTakes(item)
            for t = 0, takeCount - 1 do
                local take = reaper.GetTake(item, t)
                if take and reaper.TakeIsMIDI(take) then
                    return true
                end
            end
        end
    end
    return false
end

-- Function to evaluate track for MIDI send eligibility
function trackEligibleForSend(track)
    -- No send if: no items, or no MIDI items
    if not trackHasAnyItems(track) then return false end
    if not trackHasAnyMIDIItems(track) then return false end
    return true
end

lastSelectedTrack = nil
lastRunTime = 0
lastIsRecording = reaper.GetPlayState() & 4 == 4
lastItemCount = 0



function monitorTrackSelection()
    local currentTime = reaper.time_precise()
    if currentTime - lastRunTime < 0.5 then -- Run every 0.5 seconds (2 times per second)
        reaper.defer(monitorTrackSelection)
        return
    end
    lastRunTime = currentTime

    -- Ensure "Hardware Feedback Track" exists
    local feedbackTrack = ensureHardwareFeedbackTrack()

    -- Get the currently selected track
    local selectedTrack = reaper.GetSelectedTrack(0, 0)

    -- Detect if recording has just stopped
    local isRecording = (reaper.GetPlayState() & 4) == 4
    local recordingJustStopped = lastIsRecording and not isRecording
    lastIsRecording = isRecording

    -- Detect if a new media item was added to the selected track
    local itemCount = 0
    if selectedTrack then
        itemCount = reaper.CountTrackMediaItems(selectedTrack)
    end
    local itemCountIncreased = (selectedTrack == lastSelectedTrack) and (itemCount > lastItemCount)
    lastItemCount = itemCount

    -- Only act if the selection has changed, recording just stopped, or a new item was added
    if selectedTrack ~= lastSelectedTrack or recordingJustStopped or itemCountIncreased then
        local shouldCreateSend = false
        if selectedTrack and not isHardwareFeedbackTrack(selectedTrack) then
            local isFolder = reaper.GetMediaTrackInfo_Value(selectedTrack, "I_FOLDERDEPTH")
            if isFolder <= 0 then -- Only proceed if not a folder track (folder depth <= 0)
                if trackEligibleForSend(selectedTrack) then
                    shouldCreateSend = true
                end
            end
        end

        -- Single source of truth: check only feedback track receives.
        local hasExisting = keepOnlyFeedbackReceiveFrom(feedbackTrack, shouldCreateSend and selectedTrack or nil)
        if shouldCreateSend and not hasExisting then
            setupMIDISend(selectedTrack, feedbackTrack)
        end

        -- Update the last selected track and item count
        lastSelectedTrack = selectedTrack
        lastItemCount = itemCount
    end

    reaper.defer(monitorTrackSelection)
end

function cleanupOnExit()
    local feedbackTrack = findHardwareFeedbackTrack()
    if feedbackTrack and reaper.ValidatePtr2(0, feedbackTrack, "MediaTrack*") then
        reaper.Undo_BeginBlock()
        removeAllFeedbackReceives(feedbackTrack)
        reaper.Undo_EndBlock("MIDI Auto Send: remove feedback sends on exit", -1)
    end
end

reaper.atexit(cleanupOnExit)

monitorTrackSelection()