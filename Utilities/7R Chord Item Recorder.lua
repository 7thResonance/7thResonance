--[[
  @description 7R Chord Item Recorder
  @version 0.3
  @author 7thResonance
  @changelog 
    - Looped recording improved
    - fixed lane support (value at the top of the script)
    - region lane handling improivemant.
    - On playback/recording end, last chord extends to fill the measure.
    - Defaulted to item mode
  @about
    Creates real-time chord labels from live MIDI input.
    Run this as a deferred script while the transport is playing or recording.
    The script watches the selected record-armed MIDI track (or the first armed MIDI
    track it can find), detects held note groups, and outputs them as empty
    items on a chord track.

    Chord names are adapted from FeedTheCat's Lil Chordbox naming table.
]]

local OUTPUT_MODE = 0 -- 0 = track items, 1 = regions in ruler lane named "Chords"
local USE_FIXED_LANES = 0 -- item mode only: 0 = disabled, 1 = write each script pass to its own fixed lane on the chord track

local EXTNAME = "FTC.LilChordBox"
local DEFAULT_CHORD_TRACK_NAME = "Chords"
local REGION_LANE_NAME = "Chords"
local REGION_LANE_CREATE_TYPES = { "region", "regionmarker", "marker" }
local GROUP_DEBOUNCE = 0.08
local MIN_ITEM_LENGTH = 0.05
local LIVE_UPDATE_STEP = 0.03
local QUANTIZE_EPSILON = 0.000001
local PLAYBACK_JUMP_EPSILON = 0.01

local _, _, section, command_id = reaper.get_action_context()

local chord_names = {}

-- Dyads
chord_names["1 2"] = { expanded = " minor 2nd", compact = "m2" }
chord_names["1 3"] = { expanded = " major 2nd", compact = "M2" }
chord_names["1 4"] = { expanded = " minor 3rd", compact = "m3" }
chord_names["1 5"] = { expanded = " major 3rd", compact = "M3" }
chord_names["1 6"] = { expanded = " perfect 4th", compact = "P4" }
chord_names["1 7"] = { expanded = "5-", compact = "5-" }
chord_names["1 8"] = { expanded = "5", compact = "5" }
chord_names["1 9"] = { expanded = " minor 6th", compact = "m6" }
chord_names["1 10"] = { expanded = " major 6th", compact = "M6" }
chord_names["1 11"] = { expanded = " minor 7th", compact = "m7" }
chord_names["1 12"] = { expanded = " major 7th", compact = "M7" }
chord_names["1 13"] = { expanded = " octave", compact = "P8" }

-- Compound intervals
chord_names["1 14"] = { expanded = " minor 9th", compact = "m9" }
chord_names["1 15"] = { expanded = " major 9th", compact = "M9" }
chord_names["1 16"] = { expanded = " minor 10th", compact = "m10" }
chord_names["1 17"] = { expanded = " major 10th", compact = "M10" }
chord_names["1 18"] = { expanded = " perfect 11th", compact = "P11" }
chord_names["1 19"] = { expanded = " minor 12th", compact = "m12" }
chord_names["1 20"] = { expanded = " perfect 12th", compact = "P12" }
chord_names["1 21"] = { expanded = " minor 13th", compact = "m13" }
chord_names["1 22"] = { expanded = " major 13th", compact = "M13" }
chord_names["1 23"] = { expanded = " minor 14th", compact = "m14" }
chord_names["1 24"] = { expanded = " major 14th", compact = "M14" }

-- Major chords
chord_names["1 5 8"] = { expanded = "maj", compact = "M" }
chord_names["1 8 12"] = { expanded = "maj7 omit3", compact = "M7(no3)" }
chord_names["1 5 12"] = { expanded = "maj7 omit5", compact = "M7(no5)" }
chord_names["1 5 8 12"] = { expanded = "maj7", compact = "M7" }
chord_names["1 3 5 12"] = { expanded = "maj9 omit5", compact = "M9(no5)" }
chord_names["1 3 5 8 12"] = { expanded = "maj9", compact = "M9" }
chord_names["1 3 5 6 12"] = { expanded = "maj11 omit5", compact = "M11(no5)" }
chord_names["1 5 6 8 12"] = { expanded = "maj11 omit9", compact = "M11(no9)" }
chord_names["1 3 5 6 8 12"] = { expanded = "maj11", compact = "M11" }
chord_names["1 3 5 6 10 12"] = { expanded = "maj13 omit5", compact = "M13(no5)" }
chord_names["1 5 6 8 10 12"] = { expanded = "maj13 omit9", compact = "M13(no9)" }
chord_names["1 3 5 6 8 10 12"] = { expanded = "maj13", compact = "M13" }
chord_names["1 8 10"] = { expanded = "6 omit3", compact = "6(no3)" }
chord_names["1 5 8 10"] = { expanded = "6", compact = "6" }
chord_names["1 3 5 10"] = { expanded = "6/9 omit5", compact = "6/9(no5)" }
chord_names["1 3 5 8 10"] = { expanded = "6/9", compact = "6/9" }

-- Dominant / seventh
chord_names["1 8 11"] = { expanded = "7 omit3", compact = "7(no3)" }
chord_names["1 5 11"] = { expanded = "7 omit5", compact = "7(no5)" }
chord_names["1 5 8 11"] = { expanded = "7", compact = "7" }
chord_names["1 3 8 11"] = { expanded = "9 omit3", compact = "9(no3)" }
chord_names["1 3 5 11"] = { expanded = "9 omit5", compact = "9(no5)" }
chord_names["1 3 5 8 11"] = { expanded = "9", compact = "9" }
chord_names["1 3 5 10 11"] = { expanded = "13 omit5", compact = "13(no5)" }
chord_names["1 5 8 10 11"] = { expanded = "13 omit9", compact = "13(no9)" }
chord_names["1 3 5 8 10 11"] = { expanded = "13", compact = "13" }
chord_names["1 5 7 11"] = { expanded = "7#11 omit5", compact = "7#11(no5)" }
chord_names["1 5 7 8 11"] = { expanded = "7#11", compact = "7#11" }
chord_names["1 3 5 7 11"] = { expanded = "9#11 omit5", compact = "9#11(no5)" }
chord_names["1 3 5 7 8 11"] = { expanded = "9#11", compact = "9#11" }

-- Altered
chord_names["1 2 5 11"] = { expanded = "7b9 omit5", compact = "7b9(no5)" }
chord_names["1 2 5 8 11"] = { expanded = "7b9", compact = "7b9" }
chord_names["1 2 5 7 8 11"] = { expanded = "7b9#11", compact = "7b9#11" }
chord_names["1 4 5 11"] = { expanded = "7#9 omit5", compact = "7#9(no5)" }
chord_names["1 4 5 8 11"] = { expanded = "7#9", compact = "7#9" }
chord_names["1 4 5 9 11"] = { expanded = "7#5#9", compact = "7#5#9" }
chord_names["1 4 5 7 8 11"] = { expanded = "7#9#11", compact = "7#9#11" }
chord_names["1 2 5 8 10 11"] = { expanded = "13b9", compact = "13b9" }
chord_names["1 3 5 7 8 10 11"] = { expanded = "13#11", compact = "13#11" }

-- Suspended
chord_names["1 6 8"] = { expanded = "sus4", compact = "sus4" }
chord_names["1 3 8"] = { expanded = "sus2", compact = "sus2" }
chord_names["1 6 11"] = { expanded = "7sus4 omit5", compact = "7sus4(no5)" }
chord_names["1 6 8 11"] = { expanded = "11 omit9", compact = "11(no9)" }
chord_names["1 3 6 11"] = { expanded = "11 omit5", compact = "11(no5)" }
chord_names["1 3 6 8 11"] = { expanded = "11", compact = "11" }

-- Minor
chord_names["1 4 8"] = { expanded = "m", compact = "m" }
chord_names["1 4 11"] = { expanded = "m7 omit5", compact = "m7(no5)" }
chord_names["1 4 8 11"] = { expanded = "m7", compact = "m7" }
chord_names["1 4 12"] = { expanded = "m/maj7 omit5", compact = "m/M7(no5)" }
chord_names["1 4 8 12"] = { expanded = "m/maj7", compact = "m/M7" }
chord_names["1 3 4 12"] = { expanded = "m/maj9 omit5", compact = "m/M9(no5)" }
chord_names["1 3 4 8 12"] = { expanded = "m/maj9", compact = "m/M9" }
chord_names["1 3 4 11"] = { expanded = "m9 omit5", compact = "m9(no5)" }
chord_names["1 3 4 8 11"] = { expanded = "m9", compact = "m9" }
chord_names["1 3 4 6 11"] = { expanded = "m11 omit5", compact = "m11(no5)" }
chord_names["1 4 6 8 11"] = { expanded = "m11 omit9", compact = "m11(no9)" }
chord_names["1 3 4 6 8 11"] = { expanded = "m11", compact = "m11" }
chord_names["1 3 4 6 10 11"] = { expanded = "m13 omit5", compact = "m13(no5)" }
chord_names["1 4 6 8 10 11"] = { expanded = "m13 omit9", compact = "m13(no9)" }
chord_names["1 3 4 6 8 10 11"] = { expanded = "m13", compact = "m13" }
chord_names["1 4 8 10"] = { expanded = "m6", compact = "m6" }
chord_names["1 3 4 10"] = { expanded = "m6/9 omit5", compact = "m6/9(no5)" }
chord_names["1 3 4 8 10"] = { expanded = "m6/9", compact = "m6/9" }

-- Diminished
chord_names["1 4 7"] = { expanded = "dim", compact = "dim" }
chord_names["1 4 7 10"] = { expanded = "dim7", compact = "dim7" }
chord_names["1 4 7 11"] = { expanded = "m7b5", compact = "m7b5" }
chord_names["1 2 4 8 11"] = { expanded = "m7b9", compact = "m7b9" }
chord_names["1 2 4 7 11"] = { expanded = "m7b5b9", compact = "m7b5b9" }
chord_names["1 2 4 11"] = { expanded = "m7b9 omit5", compact = "m7b9(no5)" }
chord_names["1 3 4 7 11"] = { expanded = "m9b5", compact = "m9b5" }
chord_names["1 3 4 6 7 11"] = { expanded = "m11b5", compact = "m11b5" }
chord_names["1 3 5 7 10 11"] = { expanded = "13b5", compact = "13b5" }

-- Augmented
chord_names["1 5 9"] = { expanded = "aug", compact = "aug" }
chord_names["1 5 9 11"] = { expanded = "aug7", compact = "aug7" }
chord_names["1 5 9 12"] = { expanded = "aug/maj7", compact = "aug/M7" }

-- Additions
chord_names["1 3 4"] = { expanded = "m add9 omit5", compact = "m add9(no5)" }
chord_names["1 3 4 8"] = { expanded = "m add9", compact = "m add9" }
chord_names["1 3 5"] = { expanded = "maj add9 omit5", compact = "M add9(no5)" }
chord_names["1 3 5 8"] = { expanded = "maj add9", compact = "M add9" }
chord_names["1 4 6 8"] = { expanded = "m add11", compact = "m add11" }
chord_names["1 5 6 8"] = { expanded = "maj add11", compact = "M add11" }
chord_names["1 5 10 11"] = { expanded = "7 add13", compact = "7 add13" }

local note_names_abc_sharp = { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" }
local note_names_abc_flat = { "C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B" }
local note_names_solfege_sharp = { "Do ", "Do# ", "Re ", "Re# ", "Mi ", "Fa ", "Fa# ", "Sol ", "Sol# ", "La ", "La# ", "Si " }
local note_names_solfege_flat = { "Do ", "Reb ", "Re ", "Mib ", "Mi ", "Fa ", "Solb ", "Sol ", "Lab ", "La ", "Sib ", "Si " }

local use_compact = reaper.GetExtState(EXTNAME, "compact") == "1"
local use_inversions = reaper.GetExtState(EXTNAME, "inversions") ~= "0"
local use_omissions = reaper.GetExtState(EXTNAME, "omissions") == "1"
local use_major = reaper.GetExtState(EXTNAME, "major") ~= "0"
local use_solfege = reaper.GetExtState(EXTNAME, "solfege") == "1"
local use_sharps = reaper.GetExtState(EXTNAME, "sharps") == "1"

local chord_track_name = reaper.GetExtState(EXTNAME, "chord_track_name")
if chord_track_name == "" then
    chord_track_name = DEFAULT_CHORD_TRACK_NAME
end

local curr_chord_names = {}

local input_note_map = {}
local input_note_cnt = 0
local prev_input_idx

local current_source_track
local current_chord_track
local current_chord_lane
local current_region_lane
local current_region_lane_name = REGION_LANE_NAME
local region_lane_anchor_guid

if type(reaper.GetProjExtState) == "function" then
    local _, saved_lane_name = reaper.GetProjExtState(0, EXTNAME, "region_lane_name")
    if saved_lane_name ~= "" then
        current_region_lane_name = saved_lane_name
    end

    local _, saved_lane_anchor_guid = reaper.GetProjExtState(0, EXTNAME, "region_lane_anchor_guid")
    if saved_lane_anchor_guid ~= "" then
        region_lane_anchor_guid = saved_lane_anchor_guid
    end
end

local pending_name
local pending_anchor_pos
local pending_change_pos

local active_item
local active_track
local active_name
local active_start_pos
local active_last_update_pos
local active_region_guid
local active_region_lane

local last_capture_pos
local last_transport_active = false
local needs_arrange_update = false
local region_mode_warned = false
local region_lane_create_warned = false

local function SetToggleState(state)
    if command_id == 0 then
        return
    end
    reaper.SetToggleCommandState(section, command_id, state and 1 or 0)
    reaper.RefreshToolbar2(section, command_id)
end

local function IsFixedLaneModeEnabled()
    return OUTPUT_MODE == 0 and USE_FIXED_LANES == 1
end

local function LoadChordNames()
    curr_chord_names = {}
    local key = use_compact and "compact" or "expanded"
    for interval_key, names in pairs(chord_names) do
        curr_chord_names[interval_key] = names[key]
    end
end

local function ClearPendingState()
    pending_name = nil
    pending_anchor_pos = nil
    pending_change_pos = nil
end

local function PitchToName(pitch)
    local note_names
    if use_solfege then
        note_names = use_sharps and note_names_solfege_sharp or note_names_solfege_flat
    else
        note_names = use_sharps and note_names_abc_sharp or note_names_abc_flat
    end
    return note_names[pitch % 12 + 1]
end

local function IdentifyChord(notes)
    local root = math.maxinteger
    for i = 1, #notes do
        local note = notes[i]
        root = note.pitch < root and note.pitch or root
    end

    local intervals = {}
    for i = 1, #notes do
        local note = notes[i]
        intervals[(note.pitch - root) % 12 + 1] = 1
    end

    local interval_cnt = 0
    local key = "1"
    for i = 2, 12 do
        if intervals[i] then
            key = key .. " " .. i
            interval_cnt = interval_cnt + 1
        end
    end

    if interval_cnt <= 1 then
        intervals = {}
        for i = 1, #notes do
            local note = notes[i]
            local diff = note.pitch - root
            if diff >= 12 then
                intervals[diff % 12 + 13] = 1
            elseif diff > 0 then
                intervals = {}
                break
            end
        end

        local compound_key = "1"
        for i = 12, 24 do
            if intervals[i] then
                compound_key = compound_key .. " " .. i
            end
        end

        if curr_chord_names[compound_key] then
            return compound_key, root
        end
    end

    if curr_chord_names[key] then
        return key, root
    end

    local key_nums = {}
    for key_num in key:gmatch("%d+") do
        key_nums[#key_nums + 1] = tonumber(key_num)
    end

    for n = 2, #key_nums do
        local diff = key_nums[n] - key_nums[1]
        intervals = {}
        for i = 1, #key_nums do
            intervals[(key_nums[i] - diff - 1) % 12 + 1] = 1
        end
        local inversion_key = "1"
        for i = 2, 12 do
            if intervals[i] then
                inversion_key = inversion_key .. " " .. i
            end
        end
        if curr_chord_names[inversion_key] then
            return inversion_key, root + diff, root
        end
    end
end

local function BuildChord(notes)
    local chord_key, chord_root, inversion_root = IdentifyChord(notes)
    if not chord_key then
        return nil
    end
    return {
        notes = notes,
        root = chord_root,
        key = chord_key,
        inversion_root = inversion_root,
    }
end

local function BuildChordName(chord)
    if not chord then
        return ""
    end
    if chord.name then
        return chord.name
    end
    local add = curr_chord_names[chord.key]
    if not add then
        return ""
    end
    if not use_omissions then
        add = add:gsub(use_compact and "%(no%d+%)" or " omit%d+", "")
    end
    if not use_major then
        add = add:gsub(use_compact and "^M(%s?)" or "^(%s?)majo?r?%s?", "%1")
    end
    local name = PitchToName(chord.root) .. add
    if use_inversions and chord.inversion_root then
        name = name .. "/" .. PitchToName(chord.inversion_root)
    end
    return name
end

local function ClearInputState()
    prev_input_idx = nil
    input_note_map = {}
    input_note_cnt = 0
    ClearPendingState()
end

local function SnapshotHeldNotes()
    local notes = {}
    for pitch = 0, 127 do
        if input_note_map[pitch] == 1 then
            notes[#notes + 1] = { pitch = pitch }
        end
    end
    return notes
end

local function GetHeldChordName()
    if input_note_cnt < 2 then
        return ""
    end
    local chord = BuildChord(SnapshotHeldNotes())
    return BuildChordName(chord)
end

local function IsTransportActive()
    local play_state = reaper.GetPlayState()
    return (play_state & 1 == 1) or (play_state & 4 == 4)
end

local function GetCapturePosition()
    if reaper.GetPlayPosition2 then
        return reaper.GetPlayPosition2()
    end
    return reaper.GetPlayPosition()
end

local function GetLoopRange()
    if type(reaper.GetSetRepeat) ~= "function" or reaper.GetSetRepeat(-1) ~= 1 then
        return nil
    end
    if type(reaper.GetSet_LoopTimeRange2) == "function" then
        local loop_start, loop_end = reaper.GetSet_LoopTimeRange2(0, false, true, 0, 0, false)
        if loop_end > loop_start + QUANTIZE_EPSILON then
            return loop_start, loop_end
        end
    end
end

local function GetQuantizeInfoAtTime(time)
    local qn = reaper.TimeMap2_timeToQN(0, time)
    local _, measure_start_qn, measure_end_qn = reaper.TimeMap_QNToMeasures(0, qn)
    local _, denominator = reaper.TimeMap_GetTimeSigAtTime(0, time)

    measure_start_qn = measure_start_qn or qn
    measure_end_qn = measure_end_qn or qn
    denominator = math.max(1, tonumber(denominator) or 4)

    return qn, measure_start_qn, measure_end_qn, 4 / denominator
end

local function QuantizeTimeToGrid(time)
    if not time then
        return nil
    end

    local qn, measure_start_qn, measure_end_qn, step_qn = GetQuantizeInfoAtTime(time)
    local step_index = math.floor(((qn - measure_start_qn) / step_qn) + 0.5)
    local snapped_qn = measure_start_qn + (step_index * step_qn)

    if snapped_qn < measure_start_qn then
        snapped_qn = measure_start_qn
    elseif snapped_qn > measure_end_qn then
        snapped_qn = measure_end_qn
    end

    return reaper.TimeMap2_QNToTime(0, snapped_qn)
end

local function GetNextGridTime(time)
    if not time then
        return nil
    end

    local qn, measure_start_qn, measure_end_qn, step_qn = GetQuantizeInfoAtTime(time)
    local step_index = math.floor(((qn - measure_start_qn) / step_qn) + QUANTIZE_EPSILON) + 1
    local next_qn = measure_start_qn + (step_index * step_qn)

    if next_qn > measure_end_qn + QUANTIZE_EPSILON then
        next_qn = measure_end_qn
    end

    if next_qn <= qn + QUANTIZE_EPSILON then
        next_qn = qn + step_qn
    end

    return reaper.TimeMap2_QNToTime(0, next_qn)
end

local function QuantizeTransitionTime(time, previous_time)
    local snapped_time = QuantizeTimeToGrid(time)
    if previous_time and snapped_time and snapped_time <= previous_time + QUANTIZE_EPSILON then
        snapped_time = GetNextGridTime(previous_time + QUANTIZE_EPSILON)
    end
    return snapped_time or time
end

local function GetNextBarTime(time)
    if not time then
        return nil
    end

    local qn = reaper.TimeMap2_timeToQN(0, time + QUANTIZE_EPSILON)
    local _, _, measure_end_qn = reaper.TimeMap_QNToMeasures(0, qn)
    measure_end_qn = measure_end_qn or qn

    return reaper.TimeMap2_QNToTime(0, measure_end_qn)
end

local function IsTrackRecordingMIDI(track)
    if not track then
        return false
    end
    local rec_arm = reaper.GetMediaTrackInfo_Value(track, "I_RECARM")
    local rec_input = math.floor(reaper.GetMediaTrackInfo_Value(track, "I_RECINPUT") or 0)
    return rec_arm == 1 and (rec_input & 4096 == 4096)
end

local function ResolveSourceTrack()
    if current_source_track and reaper.ValidatePtr(current_source_track, "MediaTrack*") then
        if IsTrackRecordingMIDI(current_source_track) then
            return current_source_track
        end
    end

    local selected_count = reaper.CountSelectedTracks(0)
    for i = 0, selected_count - 1 do
        local track = reaper.GetSelectedTrack(0, i)
        if IsTrackRecordingMIDI(track) then
            return track
        end
    end

    local track_count = reaper.CountTracks(0)
    for i = 0, track_count - 1 do
        local track = reaper.GetTrack(0, i)
        if IsTrackRecordingMIDI(track) then
            return track
        end
    end
end

local function HasRegionLaneAPI()
    return type(reaper.GetRegionOrMarker) == "function"
        and type(reaper.GetRegionOrMarkerInfo_Value) == "function"
        and type(reaper.SetRegionOrMarkerInfo_Value) == "function"
        and type(reaper.GetSetRegionOrMarkerInfo_String) == "function"
        and type(reaper.GetSetProjectInfo_String) == "function"
        and type(reaper.GetSetProjectInfo) == "function"
end

local function GetRulerLaneNames()
    local names = {}
    for i = 0, 255 do
        local ok, name = reaper.GetSetProjectInfo_String(0, "RULER_LANE_NAME:" .. i, "", false)
        if not ok then
            break
        end
        names[i + 1] = name or ""
    end
    return names
end

local function GetRulerLaneName(index)
    if index == nil or index < 0 then
        return nil
    end
    local ok, name = reaper.GetSetProjectInfo_String(0, "RULER_LANE_NAME:" .. index, "", false)
    if not ok then
        return nil
    end
    return name or ""
end

local function FindRegionLaneByName(name)
    if not name or name == "" then
        return nil
    end
    local names = GetRulerLaneNames()
    for i = 1, #names do
        if names[i] == name then
            return i - 1
        end
    end
end

local function TryCreateRegionLane(name)
    if not HasRegionLaneAPI() then
        return nil
    end

    local existing = GetRulerLaneNames()
    for _, lane_type in ipairs(REGION_LANE_CREATE_TYPES) do
        reaper.GetSetProjectInfo_String(0, "RULER_LANE_TYPE:", lane_type, true)

        local updated = GetRulerLaneNames()
        if #updated > #existing then
            local new_index
            for i = 1, #updated do
                if i > #existing or updated[i] ~= existing[i] then
                    new_index = i - 1
                    break
                end
            end
            if new_index == nil then
                new_index = #updated - 1
            end
            reaper.GetSetProjectInfo_String(0, "RULER_LANE_NAME:" .. new_index, name, true)
            reaper.GetSetProjectInfo(0, "RULER_LANE_HIDDEN:" .. new_index, 0, true)
            reaper.GetSetProjectInfo(0, "RULER_LANE_DEFAULT:" .. new_index, 1, true)
            needs_arrange_update = true
            return new_index
        end

        local found = FindRegionLaneByName(name)
        if found ~= nil then
            return found
        end
    end
end

local function GetRegionObjectByGUID(guid)
    if not guid or guid == "" then
        return nil
    end
    return reaper.GetRegionOrMarker(0, -1, guid)
end

local function RememberRegionLane(lane_index, anchor_guid)
    if lane_index == nil then
        return
    end
    current_region_lane = lane_index
    current_region_lane_name = REGION_LANE_NAME

    if anchor_guid and anchor_guid ~= "" then
        region_lane_anchor_guid = anchor_guid
    end

    if type(reaper.SetProjExtState) == "function" then
        reaper.SetProjExtState(0, EXTNAME, "region_lane_name", current_region_lane_name or "")
        reaper.SetProjExtState(0, EXTNAME, "region_lane_anchor_guid", region_lane_anchor_guid or "")
    end
end

local function ResolveRegionLaneFromGuid(guid)
    local marker = GetRegionObjectByGUID(guid)
    if not marker then
        return nil
    end
    return math.floor(reaper.GetRegionOrMarkerInfo_Value(0, marker, "I_LANENUMBER") or -1)
end

local function ResolveKnownRegionLane()
    local lane_name = GetRulerLaneName(current_region_lane)
    if lane_name == REGION_LANE_NAME then
        RememberRegionLane(current_region_lane)
        return current_region_lane
    end

    local lane_index = FindRegionLaneByName(REGION_LANE_NAME)
    if lane_index ~= nil then
        RememberRegionLane(lane_index)
        return lane_index
    end
end

local function EnsureRegionLane(name)
    local lane_index = ResolveKnownRegionLane()
    if lane_index ~= nil then
        reaper.GetSetProjectInfo(0, "RULER_LANE_HIDDEN:" .. lane_index, 0, true)
        RememberRegionLane(lane_index)
        return lane_index
    end

    lane_index = TryCreateRegionLane(REGION_LANE_NAME)
    if lane_index ~= nil then
        reaper.GetSetProjectInfo(0, "RULER_LANE_HIDDEN:" .. lane_index, 0, true)
        RememberRegionLane(lane_index)
        return lane_index
    end
end

local function ResolveWritableRegionLane()
    local lane_index = EnsureRegionLane(REGION_LANE_NAME)
    current_region_lane = lane_index
    return lane_index
end

local function FindChordTrack(source_track)
    if not source_track then
        return nil
    end
    local source_track_num = math.floor(reaper.GetMediaTrackInfo_Value(source_track, "IP_TRACKNUMBER"))
    for i = source_track_num - 2, 0, -1 do
        local track = reaper.GetTrack(0, i)
        local _, track_name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
        if track_name == chord_track_name then
            return track
        end
    end
end

local function EnsureChordTrack(source_track)
    if not source_track then
        return nil
    end

    local track = FindChordTrack(source_track)
    if track then
        return track
    end

    local source_index = math.floor(reaper.GetMediaTrackInfo_Value(source_track, "IP_TRACKNUMBER")) - 1
    reaper.InsertTrackAtIndex(source_index, true)
    track = reaper.GetTrack(0, source_index)
    reaper.GetSetMediaTrackInfo_String(track, "P_NAME", chord_track_name, true)
    needs_arrange_update = true
    return track
end

local function IsTrackUsingFixedLanes(track)
    if not track then
        return false
    end
    return math.floor(reaper.GetMediaTrackInfo_Value(track, "I_FREEMODE") or 0) == 2
end

local function RefreshTimelineIfNeeded()
    if type(reaper.UpdateTimeline) == "function" then
        reaper.UpdateTimeline()
    end
    needs_arrange_update = true
end

local function EnsureFixedLaneCapacity(track, lane_index)
    if not track then
        return
    end

    local changed = false
    if not IsTrackUsingFixedLanes(track) then
        reaper.SetMediaTrackInfo_Value(track, "I_FREEMODE", 2)
        changed = true
    end

    lane_index = math.max(0, math.floor(lane_index or 0))
    local lane_count = math.floor(reaper.GetMediaTrackInfo_Value(track, "I_NUMFIXEDLANES") or 0)
    local required_lanes = lane_index + 1
    if lane_count < required_lanes then
        reaper.SetMediaTrackInfo_Value(track, "I_NUMFIXEDLANES", required_lanes)
        changed = true
    end

    if changed then
        RefreshTimelineIfNeeded()
    end
end

local function GetItemLaneIndex(item)
    if not item then
        return nil
    end
    return math.max(0, math.floor(reaper.GetMediaItemInfo_Value(item, "I_FIXEDLANE") or 0))
end

local function ResolveChordTrackLane(track)
    if not IsFixedLaneModeEnabled() or not track then
        current_chord_lane = nil
        return nil
    end

    if current_chord_lane ~= nil then
        EnsureFixedLaneCapacity(track, current_chord_lane)
        return current_chord_lane
    end

    local lane_index = 0
    if reaper.CountTrackMediaItems(track) > 0 then
        local highest_lane = -1
        for i = 0, reaper.CountTrackMediaItems(track) - 1 do
            local item = reaper.GetTrackMediaItem(track, i)
            highest_lane = math.max(highest_lane, GetItemLaneIndex(item) or 0)
        end
        lane_index = highest_lane + 1
    end

    EnsureFixedLaneCapacity(track, lane_index)
    current_chord_lane = lane_index
    return lane_index
end

local function CopyItemNotesAndStyle(src_item, dst_item)
    if not src_item or not dst_item then
        return
    end

    local _, notes = reaper.GetSetMediaItemInfo_String(src_item, "P_NOTES", "", false)
    reaper.GetSetMediaItemInfo_String(dst_item, "P_NOTES", notes or "", true)

    local color = reaper.GetMediaItemInfo_Value(src_item, "I_CUSTOMCOLOR")
    if color and color ~= 0 then
        reaper.SetMediaItemInfo_Value(dst_item, "I_CUSTOMCOLOR", color)
    end

    reaper.SetMediaItemInfo_Value(dst_item, "I_FIXEDLANE", reaper.GetMediaItemInfo_Value(src_item, "I_FIXEDLANE") or 0)
    reaper.SetMediaItemInfo_Value(dst_item, "F_FREEMODE_Y", reaper.GetMediaItemInfo_Value(src_item, "F_FREEMODE_Y") or 0)
    reaper.SetMediaItemInfo_Value(dst_item, "F_FREEMODE_H", reaper.GetMediaItemInfo_Value(src_item, "F_FREEMODE_H") or 1)
end

local function CreateRightSplitItem(track, src_item, start_pos, end_pos)
    local new_item = reaper.AddMediaItemToTrack(track)
    reaper.SetMediaItemInfo_Value(new_item, "D_POSITION", start_pos)
    reaper.SetMediaItemInfo_Value(new_item, "D_LENGTH", math.max(0, end_pos - start_pos))
    reaper.SetMediaItemInfo_Value(new_item, "B_LOOPSRC", 0)
    CopyItemNotesAndStyle(src_item, new_item)
    return new_item
end

local function ResolveOverlappingItems(track, start_pos, end_pos, keep_item, lane_index)
    if not track then
        return
    end

    for i = reaper.CountTrackMediaItems(track) - 1, 0, -1 do
        local item = reaper.GetTrackMediaItem(track, i)
        if item ~= keep_item then
            if lane_index == nil or GetItemLaneIndex(item) == lane_index then
                local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
                local item_end = item_start + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
                if item_start < end_pos and item_end > start_pos then
                    local keep_left = item_start < start_pos - QUANTIZE_EPSILON
                    local keep_right = item_end > end_pos + QUANTIZE_EPSILON

                    if keep_left and keep_right then
                        CreateRightSplitItem(track, item, end_pos, item_end)
                        reaper.SetMediaItemInfo_Value(item, "D_LENGTH", math.max(0, start_pos - item_start))
                    elseif keep_left then
                        reaper.SetMediaItemInfo_Value(item, "D_LENGTH", math.max(0, start_pos - item_start))
                    elseif keep_right then
                        reaper.SetMediaItemInfo_Value(item, "D_POSITION", end_pos)
                        reaper.SetMediaItemInfo_Value(item, "D_LENGTH", math.max(0, item_end - end_pos))
                    else
                        reaper.DeleteTrackMediaItem(track, item)
                    end
                    needs_arrange_update = true
                end
            end
        end
    end
end

local function FindProjectRegionInternalIndex(display_index)
    local total = select(1, reaper.CountProjectMarkers(0))
    for i = 0, total - 1 do
        local retval, is_region, _, _, _, marker_index = reaper.EnumProjectMarkers3(0, i)
        if retval > 0 and is_region and marker_index == display_index then
            return i
        end
    end
end

local function CreateRegionInLane(start_pos, end_pos, name, lane_number, color)
    local display_index = reaper.AddProjectMarker2(0, true, start_pos, end_pos, name or "", -1, color or 0)
    local internal_index = FindProjectRegionInternalIndex(display_index)
    if internal_index == nil then
        return nil
    end

    local marker = reaper.GetRegionOrMarker(0, internal_index, "")
    if not marker then
        return nil
    end

    reaper.SetRegionOrMarkerInfo_Value(0, marker, "I_LANENUMBER", lane_number)
    return marker
end

local function ResolveOverlappingRegions(lane_number, start_pos, end_pos, keep_guid)
    local total = select(1, reaper.CountProjectMarkers(0))
    for i = total - 1, 0, -1 do
        local retval, is_region, region_start, region_end, name, _, color = reaper.EnumProjectMarkers3(0, i)
        if retval > 0 and is_region then
            local marker = reaper.GetRegionOrMarker(0, i, "")
            if marker then
                local lane = reaper.GetRegionOrMarkerInfo_Value(0, marker, "I_LANENUMBER")
                if lane == lane_number then
                    local _, guid = reaper.GetSetRegionOrMarkerInfo_String(0, marker, "GUID", "", false)
                    if guid ~= keep_guid then
                        if region_start < end_pos and region_end > start_pos then
                            local keep_left = region_start < start_pos - QUANTIZE_EPSILON
                            local keep_right = region_end > end_pos + QUANTIZE_EPSILON

                            if keep_left and keep_right then
                                CreateRegionInLane(end_pos, region_end, name, lane_number, color)
                                reaper.SetRegionOrMarkerInfo_Value(0, marker, "D_ENDPOS", start_pos)
                            elseif keep_left then
                                reaper.SetRegionOrMarkerInfo_Value(0, marker, "D_ENDPOS", start_pos)
                            elseif keep_right then
                                reaper.SetRegionOrMarkerInfo_Value(0, marker, "D_STARTPOS", end_pos)
                            else
                                reaper.DeleteProjectMarkerByIndex(0, i)
                            end
                            needs_arrange_update = true
                        end
                    end
                end
            end
        end
    end
end

local function ClearActiveChordState()
    if active_region_guid and active_region_guid ~= "" then
        region_lane_anchor_guid = active_region_guid
    end
    active_item = nil
    active_track = nil
    active_name = nil
    active_start_pos = nil
    active_last_update_pos = nil
    active_region_guid = nil
    active_region_lane = nil
end

local function UpdateActiveChordLength(current_pos, force, clamp_end_pos)
    if not active_start_pos or not current_pos then
        return
    end
    if not force and active_last_update_pos and current_pos - active_last_update_pos < LIVE_UPDATE_STEP then
        return
    end

    local end_pos
    if force then
        end_pos = QuantizeTransitionTime(current_pos, active_start_pos)
    else
        end_pos = QuantizeTimeToGrid(current_pos)
        if not end_pos or end_pos <= active_start_pos + QUANTIZE_EPSILON then
            end_pos = active_start_pos + MIN_ITEM_LENGTH
        end
    end

    local min_end_pos = active_start_pos + MIN_ITEM_LENGTH
    if clamp_end_pos and clamp_end_pos > active_start_pos + QUANTIZE_EPSILON then
        min_end_pos = math.min(min_end_pos, clamp_end_pos)
        end_pos = math.min(end_pos, clamp_end_pos)
    end

    end_pos = math.max(min_end_pos, end_pos)

    if OUTPUT_MODE == 0 then
        if not active_item or not reaper.ValidatePtr(active_item, "MediaItem*") then
            ClearActiveChordState()
            return
        end
        reaper.SetMediaItemInfo_Value(active_item, "D_LENGTH", end_pos - active_start_pos)
    else
        local marker = GetRegionObjectByGUID(active_region_guid)
        if not marker then
            ClearActiveChordState()
            return
        end
        local lane_number = math.floor(reaper.GetRegionOrMarkerInfo_Value(0, marker, "I_LANENUMBER") or -1)
        if lane_number >= 0 then
            RememberRegionLane(lane_number, active_region_guid)
        end
        reaper.SetRegionOrMarkerInfo_Value(0, marker, "D_ENDPOS", end_pos)
    end

    active_last_update_pos = current_pos
    needs_arrange_update = true
end

local function StartActiveChord(name, start_pos, is_quantized)
    if name == "" or not start_pos then
        return
    end

    if not is_quantized then
        start_pos = QuantizeTimeToGrid(start_pos)
    end
    if not start_pos then
        return
    end

    active_name = name
    active_start_pos = start_pos
    active_last_update_pos = nil

    if OUTPUT_MODE == 0 then
        local track = current_chord_track or EnsureChordTrack(current_source_track)
        if not track then
            ClearActiveChordState()
            return
        end

        local lane_index = ResolveChordTrackLane(track)

        local item = reaper.AddMediaItemToTrack(track)
        reaper.SetMediaItemInfo_Value(item, "D_POSITION", start_pos)
        reaper.SetMediaItemInfo_Value(item, "D_LENGTH", MIN_ITEM_LENGTH)
        reaper.SetMediaItemInfo_Value(item, "B_LOOPSRC", 0)
        reaper.GetSetMediaItemInfo_String(item, "P_NOTES", name, true)
        if lane_index ~= nil then
            reaper.SetMediaItemInfo_Value(item, "I_FIXEDLANE", lane_index)
        end

        current_chord_track = track
        active_item = item
        active_track = track
    else
        -- Re-resolve every time so renamed/reordered ruler lanes keep working.
        local lane_number = ResolveWritableRegionLane()
        if lane_number == nil then
            if not region_lane_create_warned then
                region_lane_create_warned = true
                reaper.MB("Could not find or create a ruler lane for chord regions.", "Chord track", 0)
            end
            ClearActiveChordState()
            return
        end

        local display_index = reaper.AddProjectMarker2(0, true, start_pos, start_pos + MIN_ITEM_LENGTH, name, -1, 0)
        local internal_index = FindProjectRegionInternalIndex(display_index)
        if internal_index == nil then
            ClearActiveChordState()
            return
        end

        local marker = reaper.GetRegionOrMarker(0, internal_index, "")
        if not marker then
            ClearActiveChordState()
            return
        end

        reaper.SetRegionOrMarkerInfo_Value(0, marker, "I_LANENUMBER", lane_number)
        local _, guid = reaper.GetSetRegionOrMarkerInfo_String(0, marker, "GUID", "", false)

        active_region_guid = guid
        active_region_lane = lane_number
        current_region_lane = lane_number
        RememberRegionLane(lane_number, guid)
    end

    UpdateActiveChordLength(last_capture_pos or start_pos, false)
end

local function FinalizeActiveChord(end_pos, clamp_end_pos)
    if not active_name or not active_start_pos then
        ClearActiveChordState()
        return
    end

    end_pos = end_pos or last_capture_pos or active_start_pos
    if end_pos < active_start_pos then
        end_pos = active_start_pos
    end

    UpdateActiveChordLength(end_pos, true, clamp_end_pos)

    if OUTPUT_MODE == 0 then
        if active_item and active_track and reaper.ValidatePtr(active_item, "MediaItem*") then
            local length = reaper.GetMediaItemInfo_Value(active_item, "D_LENGTH")
            ResolveOverlappingItems(active_track, active_start_pos, active_start_pos + length, active_item, current_chord_lane)
        end
    else
        local marker = GetRegionObjectByGUID(active_region_guid)
        if marker then
            local lane_number = math.floor(reaper.GetRegionOrMarkerInfo_Value(0, marker, "I_LANENUMBER") or active_region_lane or -1)
            local region_end = reaper.GetRegionOrMarkerInfo_Value(0, marker, "D_ENDPOS")
            if lane_number >= 0 then
                RememberRegionLane(lane_number, active_region_guid)
                ResolveOverlappingRegions(lane_number, active_start_pos, region_end, active_region_guid)
            end
        end
    end

    ClearActiveChordState()
end

local function ProcessRecentInput(track)
    if not IsTrackRecordingMIDI(track) then
        return false, false, false
    end

    local rec_input = math.floor(reaper.GetMediaTrackInfo_Value(track, "I_RECINPUT") or 0)
    local filter_channel = rec_input & 31
    local filter_dev_id = (rec_input >> 5) & 127

    local idx, buf, _, dev_id = reaper.MIDI_GetRecentInputEvent(0)
    prev_input_idx = prev_input_idx or idx

    if idx <= prev_input_idx then
        return false, false, false
    end

    local changed = false
    local saw_note_on = false
    local saw_note_off = false
    local newest_idx = idx
    local i = 0

    repeat
        if type(buf) == "string" and #buf == 3 then
            if filter_dev_id == 63 or filter_dev_id == dev_id then
                local msg1 = buf:byte(1)
                local channel = (msg1 & 0x0F) + 1
                if filter_channel == 0 or filter_channel == channel then
                    local pitch = buf:byte(2)
                    local velocity = buf:byte(3)
                    local is_note_on = msg1 & 0xF0 == 0x90 and velocity > 0
                    local is_note_off = msg1 & 0xF0 == 0x80 or (msg1 & 0xF0 == 0x90 and velocity == 0)

                    if is_note_on and input_note_map[pitch] ~= 1 then
                        input_note_map[pitch] = 1
                        input_note_cnt = input_note_cnt + 1
                        changed = true
                        saw_note_on = true
                    elseif is_note_off and input_note_map[pitch] == 1 then
                        input_note_map[pitch] = nil
                        input_note_cnt = input_note_cnt - 1
                        changed = true
                        saw_note_off = true
                    end
                end
            end
        end

        i = i + 1
        idx, buf, _, dev_id = reaper.MIDI_GetRecentInputEvent(i)
    until idx == prev_input_idx

    prev_input_idx = newest_idx
    return changed, saw_note_on, saw_note_off
end

local function ApplyPendingState(current_pos)
    if not pending_change_pos or not current_pos then
        return
    end
    if current_pos - pending_change_pos < GROUP_DEBOUNCE then
        return
    end

    local split_pos = QuantizeTransitionTime(pending_anchor_pos or current_pos, active_name and active_start_pos or nil)
    if active_name ~= pending_name then
        if active_name then
            FinalizeActiveChord(split_pos)
        end
        if pending_name and pending_name ~= "" then
            if OUTPUT_MODE == 0 then
                current_chord_track = EnsureChordTrack(current_source_track)
            else
                current_region_lane = ResolveWritableRegionLane()
            end
            StartActiveChord(pending_name, split_pos, true)
        end
    end

    ClearPendingState()
end

local function HandleInputChange(current_pos)
    local old_note_count = input_note_cnt
    local changed, saw_note_on = ProcessRecentInput(current_source_track)
    if not changed or not current_pos then
        return
    end

    local chord_name = GetHeldChordName()
    if active_name then
        -- Keep the current chord running through silence.
        -- Only arm a transition when new notes arrive.
        if saw_note_on then
            pending_anchor_pos = pending_anchor_pos or current_pos
        end

        if chord_name ~= "" and chord_name ~= active_name then
            pending_name = chord_name
            pending_change_pos = current_pos
            return
        end

        if chord_name == active_name then
            ClearPendingState()
        elseif input_note_cnt == 0 then
            ClearPendingState()
        end

        return
    end

    -- No active chord yet: keep the first note-on as the future start point,
    -- then wait until we have a recognizable chord.
    if saw_note_on then
        if old_note_count == 0 and input_note_cnt > 0 then
            pending_anchor_pos = current_pos
        elseif not pending_anchor_pos and input_note_cnt > 0 then
            pending_anchor_pos = current_pos
        end
    end

    if chord_name ~= "" then
        pending_name = chord_name
        pending_change_pos = current_pos
    elseif input_note_cnt == 0 then
        ClearPendingState()
    end
end

local function HandlePlaybackJump(previous_pos, current_pos)
    if not previous_pos or not current_pos then
        return
    end
    if current_pos >= previous_pos - PLAYBACK_JUMP_EPSILON then
        return
    end

    local split_pos = previous_pos
    local loop_start, loop_end = GetLoopRange()
    if loop_start and loop_end
        and previous_pos >= loop_start - PLAYBACK_JUMP_EPSILON
        and current_pos <= loop_end + PLAYBACK_JUMP_EPSILON then
        split_pos = loop_end
    end

    ClearPendingState()
    if active_name then
        FinalizeActiveChord(split_pos, split_pos)
    end
    if IsFixedLaneModeEnabled() then
        current_chord_lane = nil
    end

    local resumed_name = GetHeldChordName()
    if resumed_name ~= "" then
        if OUTPUT_MODE == 0 then
            current_chord_track = EnsureChordTrack(current_source_track)
        else
            current_region_lane = ResolveWritableRegionLane()
        end
        StartActiveChord(resumed_name, current_pos, true)
    end
end

local function FlushActiveState(end_pos)
    FinalizeActiveChord(end_pos)
    ClearInputState()
end

local function Main()
    if OUTPUT_MODE == 1 and not HasRegionLaneAPI() then
        if not region_mode_warned then
            region_mode_warned = true
            reaper.MB("Region-lane mode requires a REAPER version with the new ruler lane API (REAPER 7.62+).", "Chord track", 0)
        end
        return
    end

    local transport_active = IsTransportActive()
    local capture_pos = transport_active and GetCapturePosition() or nil
    local previous_capture_pos = last_capture_pos

    if capture_pos then
        last_capture_pos = capture_pos
    end

    local source_track = ResolveSourceTrack()
    if source_track ~= current_source_track then
        FlushActiveState(last_capture_pos)
        current_source_track = source_track
        current_chord_track = nil
        current_chord_lane = nil
    end

    if not transport_active then
        if last_transport_active then
            FlushActiveState(GetNextBarTime(last_capture_pos) or last_capture_pos)
            current_chord_lane = nil
        end
        last_transport_active = false
        if needs_arrange_update then
            reaper.UpdateArrange()
            needs_arrange_update = false
        end
        reaper.defer(Main)
        return
    end

    last_transport_active = true

    if not current_source_track then
        if needs_arrange_update then
            reaper.UpdateArrange()
            needs_arrange_update = false
        end
        reaper.defer(Main)
        return
    end

    HandlePlaybackJump(previous_capture_pos, capture_pos)

    HandleInputChange(capture_pos)
    ApplyPendingState(capture_pos)

    if active_name then
        UpdateActiveChordLength(capture_pos, false)
    end

    if needs_arrange_update then
        reaper.UpdateArrange()
        needs_arrange_update = false
    end

    reaper.defer(Main)
end

local function Exit()
    FinalizeActiveChord(last_capture_pos)
    ClearInputState()
    if needs_arrange_update then
        reaper.UpdateArrange()
        needs_arrange_update = false
    end
    SetToggleState(false)
end

LoadChordNames()
SetToggleState(true)
reaper.atexit(Exit)
reaper.defer(Main)
