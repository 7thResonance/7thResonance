--[[
@description 7R MIDI Auto Send for CC Feedback
@author 7thResonance
@version 1.10
@changelog - Stricter clean up when selection changes.
    - Added exit clean up
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

-- Function to check or create "Hardware Feedback Track" in the current project
function ensureHardwareFeedbackTrack()
    local feedbackTrack
    for i = 0, reaper.CountTracks(0) - 1 do
      local track = reaper.GetTrack(0, i)
---@diagnostic disable-next-line: redundant-parameter
      local _, trackName = reaper.GetTrackName(track, "")
      if trackName == "Hardware Feedback Track" then
        feedbackTrack = track
        break
      end
    end
  
    if not feedbackTrack then
      reaper.Undo_BeginBlock()
      reaper.InsertTrackAtIndex(reaper.CountTracks(0), false)
      feedbackTrack = reaper.GetTrack(0, reaper.CountTracks(0) - 1)
      reaper.GetSetMediaTrackInfo_String(feedbackTrack, "P_NAME", "Hardware Feedback Track", true)
      reaper.Undo_EndBlock("Create Hardware Feedback Track", -1)
    end
    return feedbackTrack
end
  
-- Function to remove all sends from a track to "Hardware Feedback Track"
function removeMIDISends(track, feedbackTrack)
    if track and feedbackTrack then
      for sendIdx = reaper.GetTrackNumSends(track, 0) - 1, 0, -1 do
        local sendTrack = reaper.BR_GetMediaTrackSendInfo_Track(track, 0, sendIdx, 1)
        if sendTrack == feedbackTrack then
          reaper.RemoveTrackSend(track, 0, sendIdx)
        end
      end
    end
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
        -- Remove MIDI sends from the previously selected track
        if lastSelectedTrack and reaper.ValidatePtr2(0, lastSelectedTrack, "MediaTrack*") then
            removeMIDISends(lastSelectedTrack, feedbackTrack)
        end

        -- Set up MIDI send for the newly selected track, but only if it's not a folder track and meets eligibility
        if selectedTrack and reaper.GetTrackName(selectedTrack, "") ~= "Hardware Feedback Track" then
            local isFolder = reaper.GetMediaTrackInfo_Value(selectedTrack, "I_FOLDERDEPTH")
            if isFolder <= 0 then -- Only proceed if not a folder track (folder depth <= 0)
                if trackEligibleForSend(selectedTrack) then
                    removeMIDISends(selectedTrack, feedbackTrack) -- Clean any existing sends
                    setupMIDISend(selectedTrack, feedbackTrack)
                else
                    -- Remove any previous sends just in case
                    removeMIDISends(selectedTrack, feedbackTrack)
                end
            end
        end

        -- Update the last selected track and item count
        lastSelectedTrack = selectedTrack
        lastItemCount = itemCount
    end

    reaper.defer(monitorTrackSelection)
end

monitorTrackSelection()