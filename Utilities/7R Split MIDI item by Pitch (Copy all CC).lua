--[[
@description 7R Split MIDI item by Pitch (Copy all CC)
@author 7thResonance
@version 1.1
@changelog - Copies Sends and recieves as well
@donation https://paypal.me/7thresonance
@about Creates tracks for each pitch in selected MIDI items, copying all CC and text events.
--]]

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

--------------------------------------------------
-- Utilities
--------------------------------------------------

local function getNoteName(track, pitch)
    local name = reaper.GetTrackMIDINoteNameEx(0, track, pitch, 0)
    if name and name ~= "" then
        return name:gsub("^%s+", ""):gsub("%s+$", "")
    end

    local noteNames = { "C","C#","D","D#","E","F","F#","G","G#","A","A#","B" }
    local n = noteNames[(pitch % 12) + 1]
    local o = math.floor(pitch / 12) - 1
    return n .. o
end

local sendReceiveParams = {
    "B_MUTE",
    "B_PHASE",
    "B_MONO",
    "D_VOL",
    "D_PAN",
    "D_PANLAW",
    "I_SENDMODE",
    "I_SRCCHAN",
    "I_DSTCHAN",
    "I_MIDIFLAGS",
    "I_AUTOMODE"
}

local function copyRoutingParams(srcTrack, srcCat, srcIdx, dstTrack, dstCat, dstIdx)
    for _, parm in ipairs(sendReceiveParams) do
        local val = reaper.GetTrackSendInfo_Value(srcTrack, srcCat, srcIdx, parm)
        reaper.SetTrackSendInfo_Value(dstTrack, dstCat, dstIdx, parm, val)
    end
end

local function cloneTrackSendsAndReceives(srcTrack, dstTrack)
    local sendCount = reaper.GetTrackNumSends(srcTrack, 0)
    for s = 0, sendCount - 1 do
        local destTrack =
            reaper.GetTrackSendInfo_Value(srcTrack, 0, s, "P_DESTTRACK")
        if destTrack then
            local newSendIdx = reaper.CreateTrackSend(dstTrack, destTrack)
            copyRoutingParams(srcTrack, 0, s, dstTrack, 0, newSendIdx)
        end
    end

    local recvCount = reaper.GetTrackNumSends(srcTrack, -1)
    for r = 0, recvCount - 1 do
        local recvSrcTrack =
            reaper.GetTrackSendInfo_Value(srcTrack, -1, r, "P_SRCTRACK")
        if recvSrcTrack then
            reaper.CreateTrackSend(recvSrcTrack, dstTrack)
            local newRecvIdx = reaper.GetTrackNumSends(dstTrack, -1) - 1
            copyRoutingParams(srcTrack, -1, r, dstTrack, -1, newRecvIdx)
        end
    end
end

--------------------------------------------------
-- Collect selected MIDI items grouped by track
--------------------------------------------------

local itemsByTrack = {}
local selCount = reaper.CountSelectedMediaItems(0)
if selCount == 0 then return end

for i = 0, selCount - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    local take = reaper.GetActiveTake(item)
    if take and reaper.TakeIsMIDI(take) then
        local track = reaper.GetMediaItem_Track(item)
        itemsByTrack[track] = itemsByTrack[track] or {}
        table.insert(itemsByTrack[track], item)
    end
end

--------------------------------------------------
-- Process per source track
--------------------------------------------------

for track, items in pairs(itemsByTrack) do

    if reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH") ~= 1 then
        reaper.SetMediaTrackInfo_Value(track, "I_FOLDERDEPTH", 1)
    end

    local parentIdx =
        reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") - 1

    local insertOffset = 1
    local lastChildTrack = nil

    for _, item in ipairs(items) do
        local take = reaper.GetActiveTake(item)

        local itemPos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local itemLen = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
        local itemEnd = itemPos + itemLen

        reaper.SetMediaItemInfo_Value(item, "B_MUTE", 1)

        local itemStartPPQ =
            reaper.MIDI_GetPPQPosFromProjTime(take, itemPos)

        local _, noteCount, ccCount, textCount =
            reaper.MIDI_CountEvts(take)

        local notesByPitch = {}

        for n = 0, noteCount - 1 do
            local _, _, mute, sPPQ, ePPQ, chan, pitch, vel =
                reaper.MIDI_GetNote(take, n)

            local ns = sPPQ - itemStartPPQ
            local ne = ePPQ - itemStartPPQ

            if ns >= 0 and ne > ns then
                notesByPitch[pitch] = notesByPitch[pitch] or {}
                table.insert(notesByPitch[pitch], {
                    sPPQ = ns, ePPQ = ne,
                    chan = chan, vel = vel, mute = mute
                })
            end
        end

        local ccEvents = {}
        for c = 0, ccCount - 1 do
            local _, _, mute, ppq, chan, msg2, msg3, msg4 =
                reaper.MIDI_GetCC(take, c)
            local nppq = ppq - itemStartPPQ
            if nppq >= 0 then
                ccEvents[#ccEvents+1] =
                    {nppq, chan, msg2, msg3, msg4, mute}
            end
        end

        local textEvents = {}
        for t = 0, textCount - 1 do
            local _, _, mute, ppq, typ, msg =
                reaper.MIDI_GetTextSysexEvt(take, t)
            local nppq = ppq - itemStartPPQ
            if nppq >= 0 then
                textEvents[#textEvents+1] =
                    {nppq, typ, msg, mute}
            end
        end

        for pitch, noteList in pairs(notesByPitch) do
            local trackIdx = parentIdx + insertOffset
            reaper.InsertTrackAtIndex(trackIdx, true)

            local newTrack = reaper.GetTrack(0, trackIdx)
            lastChildTrack = newTrack
            insertOffset = insertOffset + 1

            cloneTrackSendsAndReceives(track, newTrack)

            reaper.GetSetMediaTrackInfo_String(
                newTrack,
                "P_NAME",
                getNoteName(track, pitch),
                true
            )

            local newItem =
                reaper.CreateNewMIDIItemInProj(
                    newTrack, itemPos, itemEnd, false
                )

            local newTake = reaper.GetActiveTake(newItem)
            reaper.MIDI_DisableSort(newTake)

            for _, n in ipairs(noteList) do
                reaper.MIDI_InsertNote(
                    newTake, false, n.mute,
                    n.sPPQ, n.ePPQ, n.chan,
                    pitch, n.vel, false
                )
            end

            for _, cc in ipairs(ccEvents) do
                reaper.MIDI_InsertCC(
                    newTake, false, cc[6],
                    cc[1], cc[2], cc[3], cc[4], cc[5], false
                )
            end

            for _, tx in ipairs(textEvents) do
                reaper.MIDI_InsertTextSysexEvt(
                    newTake, false, tx[4],
                    tx[1], tx[2], tx[3], false
                )
            end

            reaper.MIDI_Sort(newTake)
        end
    end

    if lastChildTrack then
        reaper.SetMediaTrackInfo_Value(lastChildTrack, "I_FOLDERDEPTH", -1)
    end
end

reaper.PreventUIRefresh(-1)
reaper.Undo_EndBlock(
    "Split MIDI by pitch (PPQ-normalized, REAPER note names)",
    -1
)