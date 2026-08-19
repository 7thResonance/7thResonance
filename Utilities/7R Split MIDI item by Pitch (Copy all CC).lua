--[[
@description 7R Split MIDI item by Pitch (Copy all CC)
@author 7thResonance
@version 1.2
@changelog - was not working for some reason. fixed? i guess
@about Creates tracks for each pitch in selected MIDI items, copying all CC and text events.
--]]

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

------------------------------------------------------------
-- SETTINGS
------------------------------------------------------------

local INCLUDE_TRACK_NAME = true


------------------------------------------------------------
-- PITCH NAME
------------------------------------------------------------

local function PitchName(pitch)

    local names = {
        "C", "C#", "D", "D#", "E", "F",
        "F#", "G", "G#", "A", "A#", "B"
    }

    return names[(pitch % 12) + 1] ..
           (math.floor(pitch / 12) - 1)
end


------------------------------------------------------------
-- TRACK NAME
------------------------------------------------------------

local function GetTrackName(track)

    local _, name =
        reaper.GetSetMediaTrackInfo_String(
            track,
            "P_NAME",
            "",
            false
        )

    if name == "" then
        name = "MIDI"
    end

    return name
end


------------------------------------------------------------
-- ITEM BOUNDS
------------------------------------------------------------

local function GetItemBounds(item)

    local position =
        reaper.GetMediaItemInfo_Value(
            item,
            "D_POSITION"
        )

    local length =
        reaper.GetMediaItemInfo_Value(
            item,
            "D_LENGTH"
        )

    return position, position + length
end


------------------------------------------------------------
-- COPY ITEM PROPERTIES
------------------------------------------------------------

local function CopyItemProperties(source, destination)

    local properties = {
        "D_SNAPOFFSET",
        "D_FADEINLEN",
        "D_FADEOUTLEN",
        "D_FADEINLEN_AUTO",
        "D_FADEOUTLEN_AUTO",
        "D_VOL",
        "D_PAN",
        "D_PANLAW",
        "B_MUTE",
        "C_LOCK",
        "C_AUTOSTRETCH",
        "C_BEATATTACHMODE",
        "I_CUSTOMCOLOR"
    }

    for _, property in ipairs(properties) do

        local value =
            reaper.GetMediaItemInfo_Value(
                source,
                property
            )

        reaper.SetMediaItemInfo_Value(
            destination,
            property,
            value
        )
    end
end


------------------------------------------------------------
-- GET PITCHES USED BY TAKE
------------------------------------------------------------

local function GetItemPitches(take)

    local pitches = {}

    local _, note_count =
        reaper.MIDI_CountEvts(take)

    for i = 0, note_count - 1 do

        local ok,
              selected,
              muted,
              start_ppq,
              end_ppq,
              channel,
              pitch,
              velocity =
            reaper.MIDI_GetNote(
                take,
                i
            )

        if ok then
            pitches[pitch] = true
        end
    end

    return pitches
end


------------------------------------------------------------
-- CREATE NEW MIDI ITEM
------------------------------------------------------------

local function CreateNewItem(
    destination_track,
    source_item
)

    local position, end_position =
        GetItemBounds(source_item)

    local new_item =
        reaper.CreateNewMIDIItemInProj(
            destination_track,
            position,
            end_position,
            false
        )

    if not new_item then
        return nil, nil
    end

    CopyItemProperties(
        source_item,
        new_item
    )

    local new_take =
        reaper.GetActiveTake(new_item)

    if not new_take then

        reaper.DeleteTrackMediaItem(
            destination_track,
            new_item
        )

        return nil, nil
    end

    return new_item, new_take
end


------------------------------------------------------------
-- COPY NOTES FOR ONE PITCH
--
-- SOURCE PPQ
--     ↓
-- PROJECT TIME
--     ↓
-- DESTINATION PPQ
------------------------------------------------------------

local function CopyNotes(
    source_take,
    destination_take,
    wanted_pitch
)

    local _, note_count =
        reaper.MIDI_CountEvts(
            source_take
        )

    reaper.MIDI_DisableSort(
        destination_take
    )

    for i = 0, note_count - 1 do

        local ok,
              selected,
              muted,
              start_ppq,
              end_ppq,
              channel,
              pitch,
              velocity =
            reaper.MIDI_GetNote(
                source_take,
                i
            )

        if ok and pitch == wanted_pitch then

            local start_time =
                reaper.MIDI_GetProjTimeFromPPQPos(
                    source_take,
                    start_ppq
                )

            local end_time =
                reaper.MIDI_GetProjTimeFromPPQPos(
                    source_take,
                    end_ppq
                )

            local destination_start_ppq =
                reaper.MIDI_GetPPQPosFromProjTime(
                    destination_take,
                    start_time
                )

            local destination_end_ppq =
                reaper.MIDI_GetPPQPosFromProjTime(
                    destination_take,
                    end_time
                )

            reaper.MIDI_InsertNote(
                destination_take,
                selected,
                muted,
                destination_start_ppq,
                destination_end_ppq,
                channel,
                pitch,
                velocity,
                true
            )
        end
    end
end


------------------------------------------------------------
-- COPY ALL CCs
------------------------------------------------------------

local function CopyCCs(
    source_take,
    destination_take
)

    local _, _, cc_count =
        reaper.MIDI_CountEvts(
            source_take
        )

    reaper.MIDI_DisableSort(
        destination_take
    )

    for i = 0, cc_count - 1 do

        local ok,
              selected,
              muted,
              ppq,
              chanmsg,
              channel,
              msg2,
              msg3 =
            reaper.MIDI_GetCC(
                source_take,
                i
            )

        if ok then

            local project_time =
                reaper.MIDI_GetProjTimeFromPPQPos(
                    source_take,
                    ppq
                )

            local destination_ppq =
                reaper.MIDI_GetPPQPosFromProjTime(
                    destination_take,
                    project_time
                )

            reaper.MIDI_InsertCC(
                destination_take,
                selected,
                muted,
                destination_ppq,
                chanmsg,
                channel,
                msg2,
                msg3
            )
        end
    end
end


------------------------------------------------------------
-- COPY CC SHAPES
------------------------------------------------------------

local function CopyCCShapes(
    source_take,
    destination_take
)

    local _, _, cc_count =
        reaper.MIDI_CountEvts(
            source_take
        )

    for i = 0, cc_count - 1 do

        local ok =
            reaper.MIDI_GetCC(
                source_take,
                i
            )

        if ok then

            local shape_ok,
                  shape,
                  tension =
                reaper.MIDI_GetCCShape(
                    source_take,
                    i
                )

            if shape_ok then

                reaper.MIDI_SetCCShape(
                    destination_take,
                    i,
                    shape,
                    tension,
                    true
                )
            end
        end
    end
end


------------------------------------------------------------
-- COPY TRACK COLOR
------------------------------------------------------------

local function CopyTrackColor(
    source_track,
    destination_track
)

    local color =
        reaper.GetMediaTrackInfo_Value(
            source_track,
            "I_CUSTOMCOLOR"
        )

    reaper.SetMediaTrackInfo_Value(
        destination_track,
        "I_CUSTOMCOLOR",
        color
    )
end


------------------------------------------------------------
-- COPY SEND PARAMETERS
------------------------------------------------------------

local function CopySendParameters(
    source_track,
    source_send,
    destination_track,
    destination_send
)

    local properties = {
        "D_VOL",
        "D_PAN",
        "D_PANLAW",
        "I_SENDMODE",
        "I_SRCCHAN",
        "I_DSTCHAN",
        "I_MIDIFLAGS",
        "B_MUTE",
        "B_PHASE"
    }

    for _, property in ipairs(properties) do

        local value =
            reaper.GetTrackSendInfo_Value(
                source_track,
                0,
                source_send,
                property
            )

        if value ~= nil then

            reaper.SetTrackSendInfo_Value(
                destination_track,
                0,
                destination_send,
                property,
                value
            )
        end
    end
end


------------------------------------------------------------
-- COPY ORIGINAL SENDS
------------------------------------------------------------

local function CopyOriginalSends(
    source_track,
    destination_track
)

    local send_count =
        reaper.GetTrackNumSends(
            source_track,
            0
        )

    for i = 0, send_count - 1 do

        local destination =
            reaper.GetTrackSendInfo_Value(
                source_track,
                0,
                i,
                "P_DESTTRACK"
            )

        if destination then

            local new_send =
                reaper.CreateTrackSend(
                    destination_track,
                    destination
                )

            if new_send >= 0 then

                CopySendParameters(
                    source_track,
                    i,
                    destination_track,
                    new_send
                )
            end
        end
    end
end


------------------------------------------------------------
-- COPY ORIGINAL RECEIVES
--
-- A REAPER receive is represented as a send on the
-- source track, so find every source that sends to the
-- original and duplicate that routing to the new track.
------------------------------------------------------------

local function CopyOriginalReceives(
    original_track,
    destination_track
)

    local track_count =
        reaper.CountTracks(0)

    for i = 0, track_count - 1 do

        local source_track =
            reaper.GetTrack(
                0,
                i
            )

        if source_track ~= destination_track then

            local send_count =
                reaper.GetTrackNumSends(
                    source_track,
                    0
                )

            for send_index = 0, send_count - 1 do

                local destination =
                    reaper.GetTrackSendInfo_Value(
                        source_track,
                        0,
                        send_index,
                        "P_DESTTRACK"
                    )

                if destination == original_track then

                    local new_send =
                        reaper.CreateTrackSend(
                            source_track,
                            destination_track
                        )

                    if new_send >= 0 then

                        CopySendParameters(
                            source_track,
                            send_index,
                            source_track,
                            new_send
                        )
                    end
                end
            end
        end
    end
end


------------------------------------------------------------
-- FIND SIBLING INSERT POSITION
------------------------------------------------------------

local function GetSiblingInsertPosition(
    source_track
)

    local source_index =
        math.floor(
            reaper.GetMediaTrackInfo_Value(
                source_track,
                "IP_TRACKNUMBER"
            )
        ) - 1

    local folder_depth =
        reaper.GetMediaTrackInfo_Value(
            source_track,
            "I_FOLDERDEPTH"
        )

    --------------------------------------------------------
    -- Normal track / track inside folder.
    --------------------------------------------------------

    if folder_depth <= 0 then
        return source_index + 1
    end

    --------------------------------------------------------
    -- Source is a folder parent.
    -- Skip all children.
    --------------------------------------------------------

    local level = folder_depth
    local index = source_index + 1

    local track_count =
        reaper.CountTracks(0)

    while index < track_count do

        local track =
            reaper.GetTrack(
                0,
                index
            )

        local depth =
            reaper.GetMediaTrackInfo_Value(
                track,
                "I_FOLDERDEPTH"
            )

        level = level + depth

        index = index + 1

        if level <= 0 then
            break
        end
    end

    return index
end


------------------------------------------------------------
-- PROCESS ONE SOURCE TRACK
------------------------------------------------------------

local function ProcessTrack(
    source_track,
    selected_items
)

    if #selected_items == 0 then
        return
    end

    --------------------------------------------------------
    -- Find every pitch used by the SELECTED items only.
    --------------------------------------------------------

    local pitches = {}

    for _, data in ipairs(selected_items) do

        local item_pitches =
            GetItemPitches(
                data.take
            )

        for pitch in pairs(item_pitches) do
            pitches[pitch] = true
        end
    end

    local pitch_list = {}

    for pitch in pairs(pitches) do
        pitch_list[#pitch_list + 1] = pitch
    end

    table.sort(pitch_list)

    if #pitch_list == 0 then
        return
    end

    --------------------------------------------------------
    -- Create sibling tracks.
    --------------------------------------------------------

    local insert_position =
        GetSiblingInsertPosition(
            source_track
        )

    local source_name =
        GetTrackName(source_track)

    local destination_tracks = {}

    for _, pitch in ipairs(pitch_list) do

        reaper.InsertTrackAtIndex(
            insert_position,
            true
        )

        local track =
            reaper.GetTrack(
                0,
                insert_position
            )

        ----------------------------------------------------
        -- Not a folder.
        ----------------------------------------------------

        reaper.SetMediaTrackInfo_Value(
            track,
            "I_FOLDERDEPTH",
            0
        )

        ----------------------------------------------------
        -- Copy color.
        ----------------------------------------------------

        CopyTrackColor(
            source_track,
            track
        )

        ----------------------------------------------------
        -- Name.
        ----------------------------------------------------

        local name

        if INCLUDE_TRACK_NAME then

            name =
                source_name ..
                " " ..
                PitchName(pitch)

        else

            name =
                PitchName(pitch)
        end

        reaper.GetSetMediaTrackInfo_String(
            track,
            "P_NAME",
            name,
            true
        )

        destination_tracks[pitch] = track

        insert_position =
            insert_position + 1
    end


    --------------------------------------------------------
    -- Copy routing.
    --------------------------------------------------------

    for _, pitch in ipairs(pitch_list) do

        local destination_track =
            destination_tracks[pitch]

        CopyOriginalSends(
            source_track,
            destination_track
        )

        CopyOriginalReceives(
            source_track,
            destination_track
        )
    end


    --------------------------------------------------------
    -- Process SELECTED items only.
    --------------------------------------------------------

    for _, pitch in ipairs(pitch_list) do

        local destination_track =
            destination_tracks[pitch]

        for _, data in ipairs(selected_items) do

            ------------------------------------------------
            -- Only create an item when THIS selected item
            -- actually contains this pitch.
            ------------------------------------------------

            local item_pitches =
                GetItemPitches(
                    data.take
                )

            if item_pitches[pitch] then

                local new_item,
                      new_take =
                    CreateNewItem(
                        destination_track,
                        data.item
                    )

                if new_take then

                    CopyNotes(
                        data.take,
                        new_take,
                        pitch
                    )

                    CopyCCs(
                        data.take,
                        new_take
                    )

                    CopyCCShapes(
                        data.take,
                        new_take
                    )

                    reaper.MIDI_Sort(
                        new_take
                    )
                end
            end
        end
    end
end


------------------------------------------------------------
-- COLLECT SELECTED MIDI ITEMS
------------------------------------------------------------

local function CollectSelectedMIDIItems()

    local by_track = {}

    local selected_count =
        reaper.CountSelectedMediaItems(0)

    for i = 0, selected_count - 1 do

        local item =
            reaper.GetSelectedMediaItem(
                0,
                i
            )

        local take =
            reaper.GetActiveTake(item)

        if take and reaper.TakeIsMIDI(take) then

            local track =
                reaper.GetMediaItemTrack(item)

            if not by_track[track] then
                by_track[track] = {}
            end

            by_track[track][#by_track[track] + 1] = {
                item = item,
                take = take
            }
        end
    end

    return by_track
end


------------------------------------------------------------
-- MAIN
------------------------------------------------------------

local function Main()

    --------------------------------------------------------
    -- IMPORTANT:
    --
    -- We now use SELECTED MEDIA ITEMS rather than
    -- selected tracks.
    --------------------------------------------------------

    local items_by_track =
        CollectSelectedMIDIItems()

    local source_tracks = {}

    for track in pairs(items_by_track) do
        source_tracks[#source_tracks + 1] = track
    end

    if #source_tracks == 0 then
        return
    end

    --------------------------------------------------------
    -- Sort source tracks from bottom to top.
    --
    -- This prevents inserted tracks from interfering with
    -- the remaining source-track references.
    --------------------------------------------------------

    table.sort(
        source_tracks,
        function(a, b)

            local a_index =
                reaper.GetMediaTrackInfo_Value(
                    a,
                    "IP_TRACKNUMBER"
                )

            local b_index =
                reaper.GetMediaTrackInfo_Value(
                    b,
                    "IP_TRACKNUMBER"
                )

            return a_index > b_index
        end
    )

    reaper.Undo_BeginBlock()

    reaper.PreventUIRefresh(1)

    --------------------------------------------------------
    -- Process each source track.
    --------------------------------------------------------

    for _, source_track in ipairs(source_tracks) do

        ProcessTrack(
            source_track,
            items_by_track[source_track]
        )
    end

    reaper.PreventUIRefresh(-1)

    reaper.UpdateArrange()

    reaper.Undo_EndBlock(
        "Split selected MIDI items by note row",
        -1
    )
end


Main()

reaper.PreventUIRefresh(-1)
reaper.Undo_EndBlock(
    "7R Split MIDI by pitch",
    -1
)