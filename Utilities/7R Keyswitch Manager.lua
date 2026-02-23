--[[
@description 7R Keyswitch Manager
@author 7thResonance
@version 1.3
@changelog
     - imgui error
@about Original Script by Ugurcan Orcun; ReaKS - Keyswitch Articulation Manager
   I have added a few extra features.
      - Search and load MIDInotename files right inside the script.
      - Option to Extend already existing (live played or inserted KS notes).
      - Autosave window positions and size on close.
@screenshot Window https://i.postimg.cc/xjBRHWP8/Screenshot-2025-08-20-044639.png
    Settings https://i.postimg.cc/wMR1g4tb/Screenshot-2025-08-20-044443.png
    Loaded KSs https://i.postimg.cc/XXMpJKdN/Screenshot-2025-08-20-044433.png
    KS Inject https://i.postimg.cc/Wpd8d2gx/Screenshot-2025-08-20-044509.png
--]]
if not reaper.ImGui_GetBuiltinPath then
    return reaper.MB('ReaImGui is not installed or too old.', 'ReaKS', 0)
end

package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua'
local ImGui = require 'imgui' '0.9'

ActiveMidiEditor = nil
PreviousMidiEditor = nil
ActiveTake = nil
ActiveItem = nil
ActiveTrack = nil
MIDIHash = nil
PreviousMIDIHash = nil
Articulations = {}
CC = {}
ActivatedKS = {}

function ThemeColorToImguiColor(themeColorName)
    local color = reaper.GetThemeColor(themeColorName, 0)
    local r, g, b = reaper.ColorFromNative(color)
    return ImGui.ColorConvertDouble4ToU32(r/255, g/255, b/255, 1)
end

EnumThemeColors = { -- fetch colors from Reaper theme
    A = ThemeColorToImguiColor("col_tracklistbg"), -- Background
    B = ThemeColorToImguiColor("col_tracklistbg") + 0x111111FF, -- Default Interactive
    C = ThemeColorToImguiColor("col_tracklistbg") + 0x444444FF, -- Clicked
    D = ThemeColorToImguiColor("col_tracklistbg") + 0x222222FF, -- Hovered    
    E = ThemeColorToImguiColor("col_tcp_text"), -- HeaderText
    F = 0xFFFFFFFF, -- Text
    G = ThemeColorToImguiColor("midi_editcurs") -- Active Articulation
}

InsertionModes = {
    "Single",
    "Multi"
}

FontTitle = ImGui.CreateFont('sans-serif', 24, ImGui.FontFlags_Italic)
Font = ImGui.CreateFont('sans-serif', 14)

ActiveTakeName = nil
ActiveTrackName = nil
ActiveTrackColor = 0xFFFFFFFF

Setting_AutoupdateTextEvent = true
Setting_ItemsPerColumn = 10
Setting_PPQOffset = -1
Setting_SendNoteWhenClicked = false
Setting_ChaseMode = false
Setting_ExtendOnRefresh = true

Modal_Settings = false
Modal_NoteNameHelper = false

Injector_NotesList = ""
Injector_FirstNoteID = 36

PPQ = reaper.SNM_GetIntConfigVar("miditicksperbeat", 960)

function SaveSettings()
    reaper.SetExtState("ReaKS", "Setting_AutoupdateTextEvent", tostring(Setting_AutoupdateTextEvent), true)
    reaper.SetExtState("ReaKS", "Setting_ItemsPerColumn", tostring(Setting_ItemsPerColumn), true)
    reaper.SetExtState("ReaKS", "Setting_PPQOffset", tostring(Setting_PPQOffset), true)
    reaper.SetExtState("ReaKS", "Setting_SendNoteWhenClicked", tostring(Setting_SendNoteWhenClicked), true)
    reaper.SetExtState("ReaKS", "Setting_ChaseMode", tostring(Setting_ChaseMode), true)
    reaper.SetExtState("ReaKS", "Setting_ExtendOnRefresh", tostring(Setting_ExtendOnRefresh), true)

    -- Save window position & size
    reaper.SetExtState("ReaKS", "Window_PosX", tostring(Window_PosX), true)
    reaper.SetExtState("ReaKS", "Window_PosY", tostring(Window_PosY), true)
    reaper.SetExtState("ReaKS", "Window_SizeW", tostring(Window_SizeW), true)
    reaper.SetExtState("ReaKS", "Window_SizeH", tostring(Window_SizeH), true)
end

function LoadSettings()
    local val
    val = reaper.GetExtState("ReaKS", "Setting_AutoupdateTextEvent")
    if val ~= "" then Setting_AutoupdateTextEvent = val == "true" end

    val = reaper.GetExtState("ReaKS", "Setting_ItemsPerColumn")
    if val ~= "" then Setting_ItemsPerColumn = tonumber(val) end

    val = reaper.GetExtState("ReaKS", "Setting_PPQOffset")
    if val ~= "" then Setting_PPQOffset = tonumber(val) end

    val = reaper.GetExtState("ReaKS", "Setting_SendNoteWhenClicked")
    if val ~= "" then Setting_SendNoteWhenClicked = val == "true" end

    val = reaper.GetExtState("ReaKS", "Setting_ChaseMode")
    if val ~= "" then Setting_ChaseMode = val == "true" end

    val = reaper.GetExtState("ReaKS", "Setting_ExtendOnRefresh")
    if val ~= "" then Setting_ExtendOnRefresh = val == "true" end

    -- Load window position & size
    val = reaper.GetExtState("ReaKS", "Window_PosX")
    if val ~= "" then Window_PosX = tonumber(val) end

    val = reaper.GetExtState("ReaKS", "Window_PosY")
    if val ~= "" then Window_PosY = tonumber(val) end

    val = reaper.GetExtState("ReaKS", "Window_SizeW")
    if val ~= "" then Window_SizeW = tonumber(val) end

    val = reaper.GetExtState("ReaKS", "Window_SizeH")
    if val ~= "" then Window_SizeH = tonumber(val) end
end

function UpdateActiveTargets()
    ActiveMidiEditor = reaper.MIDIEditor_GetActive() or nil
    ActiveTake = reaper.MIDIEditor_GetTake(ActiveMidiEditor) or nil
    if ActiveTake ~= nil then ActiveTrack = reaper.GetMediaItemTake_Track(ActiveTake) end
    if ActiveTake ~= nil then ActiveItem = reaper.GetMediaItemTake_Item(ActiveTake) end

    if ActiveTake ~= nil and ActiveTake ~= PreviousTake then
        Articulations = {}
        CC = {}
        RefreshGUI()

        ActiveTakeName = reaper.GetTakeName(ActiveTake)
        _, ActiveTrackName = reaper.GetTrackName(ActiveTrack)

        ActiveTrackColor = reaper.GetTrackColor(ActiveTrack)
        if ActiveTrackColor == 0 then ActiveTrackColor = 0xFFFFFFFF end

        local r, g, b = reaper.ColorFromNative(ActiveTrackColor)
        ActiveTrackColor = ImGui.ColorConvertDouble4ToU32(r/255, g/255, b/255, 1)
    end

    PreviousTake = ActiveTake
end

function UpdateTextEvents()
    if ActiveTake == nil then return end

    --Clear all text events first
    local _, _, _, TextSysexEventCount = reaper.MIDI_CountEvts(ActiveTake)
    for TextSysexEvent = TextSysexEventCount, 1, -1 do
        local _, _, _, _, eventType, _, _ = reaper.MIDI_GetTextSysexEvt(ActiveTake, TextSysexEvent - 1)
        if eventType == 1 then
            reaper.MIDI_DeleteTextSysexEvt(ActiveTake, TextSysexEvent - 1)
        end
    end

    --Insert a text event for each note event that's in the articulation list
    local _, noteCount = reaper.MIDI_CountEvts(ActiveTake)
    for noteID = 1, noteCount do
        local _, _, _, startppqpos, _, _, pitch, _ = reaper.MIDI_GetNote(ActiveTake, noteID - 1)
        if Articulations[pitch] ~= nil then
            reaper.MIDI_InsertTextSysexEvt(ActiveTake, false, false, startppqpos, 1, Articulations[pitch])
        end
    end
end

function LoadNoteNames()
    Articulations = {}
    CC = {}
    reaper.MIDIEditor_LastFocused_OnCommand(40409, false)    
    RefreshGUI()
end

function SaveNoteNames()
    reaper.MIDIEditor_LastFocused_OnCommand(40410, false)    
end

function ClearNoteNames()
    reaper.MIDIEditor_LastFocused_OnCommand(40412, false)
    Articulations = {}
    CC = {}
end

function InjectNoteNames(noteNames, firstNoteID)
    if ActiveTake == nil then return end
    local noteNameTable = {}
    for noteName in string.gmatch(noteNames, "([^\n]+)") do
        table.insert(noteNameTable, noteName)
    end

    for i, noteName in ipairs(noteNameTable) do
        reaper.SetTrackMIDINoteNameEx(0, ActiveTrack, firstNoteID + i - 1, 0, noteName)
    end

    RefreshGUI()
end

function ParseNoteNamesFromTake()
    if ActiveTake == nil then return end

    Articulations = {}
    for i = 0, 127 do
        local notename = reaper.GetTrackMIDINoteNameEx(0, ActiveTrack, i, 0)
        if notename ~= nil then
            Articulations[i] = notename
        end
    end
end

function ParseCCNamesFromTake()
    if ActiveTake == nil then return end

    CC = {}
    for i = 128, 255 do
        local ccname = reaper.GetTrackMIDINoteNameEx(0, ActiveTrack, i, 0)
        if ccname ~= nil then
            CC[i] = ccname
        end
    end
end

function FocusToCCLane(i)
    reaper.BR_MIDI_CCLaneReplace(ActiveMidiEditor, 0, i)
end

function RenameAliasCCLane()
    reaper.MIDIEditor_LastFocused_OnCommand(40416, false)
    RefreshGUI()
end

function InsertKS(noteNumber, isShiftHeld)
    if ActiveTake == nil then return end

    local newKSStartPPQ, newKSEndPPQ

    local insertionRangeStart = math.huge
    local insertionRangeEnd = 0
    local selectionMode = false

    local MIDIItemEndPPQ = reaper.MIDI_GetPPQPosFromProjTime(ActiveTake, reaper.GetMediaItemInfo_Value(ActiveItem, "D_POSITION") + reaper.GetMediaItemInfo_Value(ActiveItem, "D_LENGTH"))

    local singleGridLength = reaper.MIDI_GetGrid(ActiveTake) * PPQ

    reaper.MIDI_DisableSort(ActiveTake)

    -- Find the earliest start time and latest end time of selected notes, if any
    if reaper.MIDI_EnumSelNotes(ActiveTake, -1) ~= -1 then
        selectionMode = true

        local selectedNoteIDX = -1
        selectedNoteIDX = reaper.MIDI_EnumSelNotes(ActiveTake, selectedNoteIDX)

        while selectedNoteIDX ~= -1 do
            local _, _, _, selectedNoteStartPPQ, selectedNoteEndPPQ = reaper.MIDI_GetNote(ActiveTake, selectedNoteIDX)         

            insertionRangeStart = math.min(insertionRangeStart, selectedNoteStartPPQ)
            insertionRangeEnd = math.max(insertionRangeEnd, selectedNoteEndPPQ)
            selectedNoteIDX = reaper.MIDI_EnumSelNotes(ActiveTake, selectedNoteIDX)
        end
    -- Find playhead and one exact grid length after it if no notes are selected
    else
        insertionRangeStart = reaper.GetCursorPosition()
        insertionRangeStart = reaper.MIDI_GetPPQPosFromProjTime(ActiveTake, insertionRangeStart)
        
        if Setting_ChaseMode then
            insertionRangeEnd = MIDIItemEndPPQ
        else 
            insertionRangeEnd = insertionRangeStart + singleGridLength
        end
    end

    newKSStartPPQ = insertionRangeStart + Setting_PPQOffset
    newKSEndPPQ = insertionRangeEnd + Setting_PPQOffset

    -- Operations on other KS notes
    local _, noteCount = reaper.MIDI_CountEvts(ActiveTake)        
    if not isShiftHeld then
        if selectionMode then
            -- Split/trim existing KS notes around the selected range (aligned with offset), and remove only the overlapped part
            for noteID = noteCount - 1, 0, -1 do
                local _, selected, muted, startPosPPQ, endPosPPQ, chan, pitch, vel = reaper.MIDI_GetNote(ActiveTake, noteID)
                -- Use offset-adjusted bounds so trims match the inserted KS boundaries
                local selStart = newKSStartPPQ
                local selEnd   = newKSEndPPQ

                if Articulations[pitch] then
                    local overlaps = not (endPosPPQ <= selStart or startPosPPQ >= selEnd)
                    if overlaps then
                        -- Fully inside selection -> delete
                        if startPosPPQ >= selStart and endPosPPQ <= selEnd then
                            reaper.MIDI_DeleteNote(ActiveTake, noteID)
                        -- Fully covers selection -> split into two parts
                        elseif startPosPPQ < selStart and endPosPPQ > selEnd then
                            -- Left piece: trim end to selStart
                            reaper.MIDI_SetNote(ActiveTake, noteID, nil, nil, nil, selStart, nil, nil, nil)
                            -- Right piece: insert from selEnd to original end
                            reaper.MIDI_InsertNote(ActiveTake, false, muted, selEnd, endPosPPQ, chan, pitch, vel, false)
                        -- Overlaps on the left only -> trim end to selStart
                        elseif startPosPPQ < selStart and endPosPPQ > selStart and endPosPPQ <= selEnd then
                            reaper.MIDI_SetNote(ActiveTake, noteID, nil, nil, nil, selStart, nil, nil, nil)
                        -- Overlaps on the right only -> trim start to selEnd
                        elseif startPosPPQ >= selStart and startPosPPQ < selEnd and endPosPPQ > selEnd then
                            reaper.MIDI_SetNote(ActiveTake, noteID, nil, nil, selEnd, nil, nil, nil, nil)
                        end
                    end
                end
            end
        else
            -- No selection: keep original trimming behavior
            for noteID = noteCount, 0, -1 do
                local _, _, _, startPosPPQ, endPosPPQ, _, pitch, _ = reaper.MIDI_GetNote(ActiveTake, noteID)
                local selStart = newKSStartPPQ
                local selEnd   = newKSEndPPQ

                if Articulations[pitch] then
                    if startPosPPQ < selStart and endPosPPQ > selStart then reaper.MIDI_SetNote(ActiveTake, noteID, nil, nil, nil, selStart) end
                    if startPosPPQ < selStart and endPosPPQ > selStart and endPosPPQ < selEnd then reaper.MIDI_SetNote(ActiveTake, noteID, nil, nil, nil, selStart) end
                    if startPosPPQ >= selStart and startPosPPQ < selEnd and endPosPPQ > selEnd then reaper.MIDI_SetNote(ActiveTake, noteID, nil, nil, selEnd, nil) end
                    if startPosPPQ >= selStart and endPosPPQ <= selEnd then reaper.MIDI_DeleteNote(ActiveTake, noteID) end
                end
            end
        end
    end

    reaper.Undo_BeginBlock()
    reaper.MarkTrackItemsDirty(ActiveTrack, ActiveItem)

    -- Insert the new KS note

    reaper.MIDI_InsertNote(ActiveTake, false, false, newKSStartPPQ, newKSEndPPQ, 0, noteNumber, 100, false)
    
    -- Move edit cursor to the end of the new note if no notes are selected
    if reaper.MIDI_EnumSelNotes(ActiveTake, -1) == -1 and not isShiftHeld then 
        local mouseMovePos = 0
        if Setting_ChaseMode then mouseMovePos = insertionRangeStart + singleGridLength else mouseMovePos = insertionRangeEnd end

        reaper.SetEditCurPos(reaper.MIDI_GetProjTimeFromPPQPos(ActiveTake, mouseMovePos), true, false) 
    end    

    -- Update text events if the setting is enabled
    if Setting_AutoupdateTextEvent then UpdateTextEvents() end

    reaper.Undo_EndBlock("Insert KS Note", -1)

    reaper.MIDI_Sort(ActiveTake)    
end

function SendMIDINote(noteNumber)
    --send a MIDI note to the virtual MIDI keyboard
    reaper.StuffMIDIMessage(0, 0x90, noteNumber, 100)

    --send note off
    reaper.StuffMIDIMessage(0, 0x80, noteNumber, 0)
end

function RemoveKS(noteNumber)
    if ActiveTake == nil then return end

    if ActivatedKS[noteNumber] ~= nil then
        reaper.MIDI_DeleteNote(ActiveTake, ActivatedKS[noteNumber])
    end    
end

function LengthenSelectedNotes(toLeft)
    if ActiveTake == nil then return end

    local selectedNoteIDX = -1
    local selectedNotes = {}

    selectedNoteIDX = reaper.MIDI_EnumSelNotes(ActiveTake, selectedNoteIDX)
    while selectedNoteIDX ~= -1 do
        table.insert(selectedNotes, selectedNoteIDX)
        selectedNoteIDX = reaper.MIDI_EnumSelNotes(ActiveTake, selectedNoteIDX)
    end

    reaper.Undo_BeginBlock()
    reaper.MarkTrackItemsDirty(ActiveTrack, ActiveItem)

    for _, noteID in pairs(selectedNotes) do
        local _, _, _, startPosPPQ, endPosPPQ, _, _, _ = reaper.MIDI_GetNote(ActiveTake, noteID)
        local moveAmount = PPQ / 32

        if toLeft then
            startPosPPQ = startPosPPQ - moveAmount
        else
            endPosPPQ = endPosPPQ + moveAmount
        end

        reaper.MIDI_SetNote(ActiveTake, noteID, nil, nil, startPosPPQ, endPosPPQ)
    end

    reaper.Undo_EndBlock("Lengthen Selected Notes", -1)
end

function GetActiveKSAtPlayheadPosition()
    if ActiveTake == nil then return end

    ActivatedKS = {}
    local playheadPosition

    playheadPosition = reaper.GetPlayState() == 1 and reaper.GetPlayPosition() or reaper.GetCursorPosition()
    playheadPosition = reaper.MIDI_GetPPQPosFromProjTime(ActiveTake, playheadPosition)
    
    local _, noteCount = reaper.MIDI_CountEvts(ActiveTake)
    
    for noteID = 1, noteCount do
        local _, _, _, startppqpos, endppqpos, _, pitch, _ = reaper.MIDI_GetNote(ActiveTake, noteID - 1)
        if startppqpos <= playheadPosition and endppqpos >= playheadPosition then                
            if Articulations[pitch] ~= nil then
                    ActivatedKS[pitch] = noteID - 1
            end
        end
    end
end

function RefreshGUI()
    UpdateTextEvents()
    ParseNoteNamesFromTake()
    ParseCCNamesFromTake()
end

function StylingStart(ctx)
    ImGui.PushStyleColor(ctx, ImGui.Col_WindowBg, EnumThemeColors.A)

    ImGui.PushStyleVar(ctx, ImGui.StyleVar_ButtonTextAlign, 0, 0.5)
    ImGui.PushStyleColor(ctx, ImGui.Col_Button, EnumThemeColors.B)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive, EnumThemeColors.C)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, EnumThemeColors.D)

    ImGui.PushStyleColor(ctx, ImGui.Col_FrameBg, EnumThemeColors.B)
    ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgActive, EnumThemeColors.C)
    ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgHovered, EnumThemeColors.D)

    ImGui.PushStyleColor(ctx, ImGui.Col_Text, EnumThemeColors.F)

    ImGui.PushStyleColor(ctx, ImGui.Col_Header, EnumThemeColors.B)
    ImGui.PushStyleColor(ctx, ImGui.Col_HeaderActive, EnumThemeColors.C)
    ImGui.PushStyleColor(ctx, ImGui.Col_HeaderHovered, EnumThemeColors.D)

    ImGui.PushStyleColor(ctx, ImGui.Col_CheckMark, EnumThemeColors.F)

    ImGui.PushFont(ctx, Font)
end

function StylingEnd(ctx)
    ImGui.PopStyleColor(ctx, 12)
    ImGui.PopStyleVar(ctx, 1)
    ImGui.PopFont(ctx)
end

-- UI Part
local ctx = ImGui.CreateContext('7R Keyswitch Manager')
ImGui.Attach(ctx, Font)
ImGui.Attach(ctx, FontTitle)

-- Extend current KS to item end or until next KS
function ExtendAllKS()
    if not ActiveTake then return end

    local _, noteCount = reaper.MIDI_CountEvts(ActiveTake)

    -- Collect all KS notes
    local ksNotes = {}
    for i = 0, noteCount-1 do
        local _, _, _, startPPQ, _, _, pitch, _ = reaper.MIDI_GetNote(ActiveTake, i)
        if Articulations[pitch] ~= nil then
            table.insert(ksNotes, { index = i, pitch = pitch, startPPQ = startPPQ })
        end
    end

    -- Sort KS notes by start time
    table.sort(ksNotes, function(a, b) return a.startPPQ < b.startPPQ end)

    -- Calculate end of item
    local itemEndPPQ = reaper.MIDI_GetPPQPosFromProjTime(ActiveTake,
        reaper.GetMediaItemInfo_Value(ActiveItem, "D_POSITION") +
        reaper.GetMediaItemInfo_Value(ActiveItem, "D_LENGTH"))

    -- Extend each KS until next KS or item end
    for i, ks in ipairs(ksNotes) do
        local nextStart = itemEndPPQ
        if ksNotes[i+1] then
            nextStart = ksNotes[i+1].startPPQ
        end
        reaper.MIDI_SetNote(ActiveTake, ks.index, nil, nil, nil, nextStart, nil, nil, nil)
    end

    reaper.MIDI_Sort(ActiveTake)
end

-- Note Name Browser helpers (attached child window content)
function GetNoteNamesRoot()
    local sep = package.config:sub(1,1)
    return reaper.GetResourcePath() .. sep .. 'MIDINoteNames'
end

function PathJoin(a, b)
    local sep = package.config:sub(1,1)
    if a:sub(-1) == sep then return a .. b else return a .. sep .. b end
end

function RenderNoteNameTree(path)
    local hadEntries = false

    -- Subdirectories
    local i = 0
    while true do
        local sub = reaper.EnumerateSubdirectories(path, i)
        if not sub then break end
        hadEntries = true
        local full = PathJoin(path, sub)
        local label = sub .. '##' .. full  -- show folder name, keep unique ID
        if ImGui.TreeNode(ctx, label) then
            RenderNoteNameTree(full)
            ImGui.TreePop(ctx)
        end
        i = i + 1
    end

    -- Files
    i = 0
    while true do
        local file = reaper.EnumerateFiles(path, i)
        if not file then break end
        hadEntries = true
        if file:lower():match('%.txt$') then
            if ImGui.Selectable(ctx, file, false) then
                local full = PathJoin(path, file)
                LoadNoteNamesFromFile(full)
            end
        else
            ImGui.BulletText(ctx, file)
        end
        i = i + 1
    end

    if not hadEntries then
        ImGui.Text(ctx, "(empty)")
    end
end

-- Search/browser state
NoteBrowser_Search = NoteBrowser_Search or ""
NoteBrowser_SelectedIndex = NoteBrowser_SelectedIndex or 1
NoteBrowser_Files = NoteBrowser_Files or nil
NoteBrowser_InputFocusNext = NoteBrowser_InputFocusNext or false
NoteBrowser_WasOpen = NoteBrowser_WasOpen or false
NoteBrowser_LastRoot = NoteBrowser_LastRoot or nil
NoteBrowser_CurrentDir = NoteBrowser_CurrentDir or nil
-- Tree-based browser state (mirrors Track Template Inserter logic)
NoteTree = NoteTree or {}
FilteredNoteTree = FilteredNoteTree or {}
ExpandedFolders = ExpandedFolders or {}
SelectedNoteFile = SelectedNoteFile or nil

-- Build a flat list of all .txt files under the root
function BuildNoteNameFileList(root)
    NoteBrowser_Files = {}
    local function scan(path)
        -- Recurse subfolders
        local i = 0
        while true do
            local sub = reaper.EnumerateSubdirectories(path, i)
            if not sub then break end
            scan(PathJoin(path, sub))
            i = i + 1
        end
        -- Collect files
        i = 0
        while true do
            local file = reaper.EnumerateFiles(path, i)
            if not file then break end
            if file:lower():match('%.txt$') then
                table.insert(NoteBrowser_Files, { name = file, path = PathJoin(path, file) })
            end
            i = i + 1
        end
    end
    scan(root)
    table.sort(NoteBrowser_Files, function(a, b) return a.name:lower() < b.name:lower() end)
end

-- Build file list only for the selected folder (non-recursive)
function BuildFilesInDir(dir)
    NoteBrowser_Files = {}
    local i = 0
    while true do
        local file = reaper.EnumerateFiles(dir, i)
        if not file then break end
        if file:lower():match('%.txt$') then
            table.insert(NoteBrowser_Files, { name = file, path = PathJoin(dir, file) })
        end
        i = i + 1
    end
    table.sort(NoteBrowser_Files, function(a, b) return a.name:lower() < b.name:lower() end)
end

-- Render a directory-only tree; clicking a folder selects it
function RenderFolderTree(path)
    local i = 0
    while true do
        local sub = reaper.EnumerateSubdirectories(path, i)
        if not sub then break end
        local full = PathJoin(path, sub)
        local opened = ImGui.TreeNode(ctx, sub .. '##' .. full)
        if ImGui.IsItemClicked(ctx) then
            NoteBrowser_CurrentDir = full
            BuildFilesInDir(NoteBrowser_CurrentDir)
            NoteBrowser_SelectedIndex = 1
        end
        if opened then
            RenderFolderTree(full)
            ImGui.TreePop(ctx)
        end
        i = i + 1
    end
end

-- Single-pane browser: visible files accumulator
NoteBrowser_VisibleFiles = NoteBrowser_VisibleFiles or {}

-- Returns true if this folder contains any matching .txt files (directly or in subfolders)
function HasMatch(path, q)
    if q == "" then return true end
    -- Files in this folder
    local i = 0
    while true do
        local file = reaper.EnumerateFiles(path, i)
        if not file then break end
        if file:lower():match('%.txt$') and file:lower():find(q, 1, true) then
            return true
        end
        i = i + 1
    end
    -- Subfolders
    i = 0
    while true do
        local sub = reaper.EnumerateSubdirectories(path, i)
        if not sub then break end
        if HasMatch(PathJoin(path, sub), q) then
            return true
        end
        i = i + 1
    end
    return false
end

-- Render the folder tree (without showing the root label), listing .txt files under each folder.
-- When searching, only branches with matches are shown and are default-open.
function RenderNoteNameTreeFiltered(root, showRoot, q)
    -- Deprecated by tree-based logic; kept as a stub if referenced elsewhere.
end

-- Tree building (Track Template Inserter style)
local function BuildNoteTreeRecursive(root_path, relative_path)
    local items, folders, files = {}, {}, {}

    -- Folders first
    local di = 0
    while true do
        local sub = reaper.EnumerateSubdirectories(root_path, di)
        if not sub then break end
        local sub_path = PathJoin(root_path, sub)
        local sub_rel = relative_path == '' and sub or (relative_path .. '/' .. sub)
        local child_items = BuildNoteTreeRecursive(sub_path, sub_rel)
        table.insert(folders, {
            name = sub,
            type = 'folder',
            path = sub_path,
            relative_path = sub_rel,
            children = child_items,
            expanded = ExpandedFolders[sub_rel] or false
        })
        di = di + 1
    end

    -- Files
    local fi = 0
    while true do
        local file = reaper.EnumerateFiles(root_path, fi)
        if not file then break end
        if file:lower():match('%.txt$') then
            local file_path = PathJoin(root_path, file)
            local file_rel = relative_path == '' and file or (relative_path .. '/' .. file)
            local name = file:gsub('%.txt$', '')
            table.insert(files, {
                name = name,
                filename = file,
                type = 'file',
                path = file_path,
                relative_path = file_rel
            })
        end
        fi = fi + 1
    end

    table.sort(folders, function(a,b) return a.name:lower() < b.name:lower() end)
    table.sort(files, function(a,b) return a.name:lower() < b.name:lower() end)
    for _, f in ipairs(folders) do table.insert(items, f) end
    for _, f in ipairs(files) do table.insert(items, f) end
    return items
end

function BuildNoteTree(root)
    -- Return a list of items under root (folders first, then files)
    return BuildNoteTreeRecursive(root, '')
end

function FlattenNoteFiles(tree_items, out)
    out = out or {}
    for _, it in ipairs(tree_items or {}) do
        if it.type == 'file' then
            table.insert(out, it)
        elseif it.type == 'folder' then
            FlattenNoteFiles(it.children, out)
        end
    end
    return out
end

function FilterNoteTree(tree_items, search_term)
    if not search_term or search_term == '' then return tree_items end
    local q = search_term:lower()
    local filtered = {}
    for _, it in ipairs(tree_items or {}) do
        if it.type == 'file' then
            if it.name:lower():find(q, 1, true) or it.filename:lower():find(q, 1, true) then
                table.insert(filtered, it)
            end
        elseif it.type == 'folder' then
            local kids = FilterNoteTree(it.children, search_term)
            if #kids > 0 then
                table.insert(filtered, {
                    name = it.name,
                    type = 'folder',
                    path = it.path,
                    relative_path = it.relative_path,
                    children = kids,
                    expanded = true
                })
            end
        end
    end
    return filtered
end

local function DrawNoteTreeNode(item)
    if item.type == 'folder' then
        -- Use random ID like the Track Template Inserter so ImGui doesn't keep open state; rely on our expanded flag
        local unique_id = 'folder_' .. tostring(math.random(1000000))
        ImGui.PushID(ctx, unique_id)

        if item.expanded then ImGui.SetNextItemOpen(ctx, true) end
    local opened = ImGui.TreeNode(ctx, item.name)
    -- Persist expanded state always (same as Track Template Inserter)
    if opened ~= item.expanded then
            item.expanded = opened
            ExpandedFolders[item.relative_path] = opened
        end
        if opened then
            for _, child in ipairs(item.children or {}) do
        DrawNoteTreeNode(child)
            end
            ImGui.TreePop(ctx)
        end
        ImGui.PopID(ctx)
    else
        local is_selected = (SelectedNoteFile and SelectedNoteFile.path == item.path)
    local label = (item.filename or item.name) .. '##' .. item.relative_path
        if ImGui.Selectable(ctx, label, is_selected) then
            SelectedNoteFile = item
        end
        if ImGui.IsItemHovered(ctx) and ImGui.IsMouseDoubleClicked(ctx, 0) then
            LoadNoteNamesFromFile(item.path)
        end
        if ImGui.IsItemHovered(ctx) then
            ImGui.SetTooltip(ctx, item.path)
        end
    end
end

local function DrawNoteTree()
    if #FilteredNoteTree == 0 then
        if #NoteTree == 0 then
            ImGui.Text(ctx, 'No note name files found.')
            ImGui.Text(ctx, GetNoteNamesRoot())
        else
            ImGui.Text(ctx, 'No files match your search.')
        end
        return
    end
    for _, it in ipairs(FilteredNoteTree) do
    DrawNoteTreeNode(it)
    end
end

-- Load note/cc names from a file and apply to the active track
function LoadNoteNamesFromFile(filePath)
    if not ActiveTrack then return end

    -- Clear existing names
    ClearNoteNames()

    local f = io.open(filePath, "r")
    if not f then return end

    for line in f:lines() do
        line = line:gsub("\r", "")
        line = line:match("^%s*(.-)%s*$") or ""
        if line ~= "" and not line:match("^//") and not line:match("^#") then
            -- CC entries: "CC <num> <name>"
            local ccnum, ccname = line:match("^[Cc][Cc]%s+(%d+)%s+(.+)$")
            if ccnum and ccname then
                local n = tonumber(ccnum)
                if n and n >= 0 and n <= 127 then
                    reaper.SetTrackMIDINoteNameEx(0, ActiveTrack, 128 + n, 0, ccname)
                end
            else
                -- NOTE entries: "NOTE <num> <name>"
                local notenum, notename = line:match("^[Nn][Oo][Tt][Ee]%s+(%d+)%s+(.+)$")
                if notenum and notename then
                    local n = tonumber(notenum)
                    if n and n >= 0 and n <= 127 then
                        reaper.SetTrackMIDINoteNameEx(0, ActiveTrack, n, 0, notename)
                    end
                else
                    -- Plain mapping: "<num> <name>" (supports 0-127 for notes and 128-255 for CC indices)
                    local num, name = line:match("^(%d+)%s+(.+)$")
                    if num and name then
                        local n = tonumber(num)
                        if n then
                            if n >= 0 and n <= 127 then
                                reaper.SetTrackMIDINoteNameEx(0, ActiveTrack, n, 0, name)
                            elseif n >= 128 and n <= 255 then
                                reaper.SetTrackMIDINoteNameEx(0, ActiveTrack, n, 0, name)
                            end
                        end
                    end
                end
            end
        end
    end
    f:close()

    RefreshGUI()
end

-- Defaults for window pos/size
Window_PosX, Window_PosY = Window_PosX or 100, Window_PosY or 100
Window_SizeW, Window_SizeH = Window_SizeW or 800, Window_SizeH or 600

local function loop()
    StylingStart(ctx)

    -- Restore window pos/size
    ImGui.SetNextWindowPos(ctx, Window_PosX, Window_PosY, ImGui.Cond_FirstUseEver)
    ImGui.SetNextWindowSize(ctx, Window_SizeW, Window_SizeH, ImGui.Cond_FirstUseEver)

    local visible, open = ImGui.Begin(ctx, '7R Keyswitch Manager', true)
    if visible then
        if (ActiveTakeName ~= nil and ActiveTrackName ~= nil) then
            ImGui.PushFont(ctx, FontTitle)
            ImGui.TextColored(ctx, ActiveTrackColor, ActiveTrackName .. ": " .. ActiveTakeName)
            ImGui.PopFont(ctx)
        end

        ImGui.BeginGroup(ctx)
        ImGui.SeparatorText(ctx, "Note Name Maps")
        if ImGui.Button(ctx, "Load") then LoadNoteNames() end
        ImGui.SameLine(ctx)
        if ImGui.Button(ctx, "Save") then SaveNoteNames() end
        ImGui.SameLine(ctx)
        if ImGui.Button(ctx, "Clear") then ClearNoteNames() end
        ImGui.SameLine(ctx)
        if ImGui.Button(ctx, "Refresh") then 
            RefreshGUI()
            if Setting_ExtendOnRefresh then
                ExtendAllKS()
            end
        end
        ImGui.SameLine(ctx)
        if ImGui.Button(ctx, "Inject") then ImGui.OpenPopup(ctx, "Note Name Injector") end
        ImGui.SameLine(ctx)
        if ImGui.Button(ctx, "Settings") then ImGui.OpenPopup(ctx, "Settings") end
        ImGui.EndGroup(ctx)

        --TODO Make the settings modal
        if ImGui.BeginPopupModal(ctx, "Settings", true) then
            local val

            if ImGui.Checkbox(ctx, "Insert Text Events", Setting_AutoupdateTextEvent) then 
                Setting_AutoupdateTextEvent = not Setting_AutoupdateTextEvent 
                SaveSettings()
            end
            if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Automatically inserts text events for articulations that's visible on Arrange view. Use [Refresh] button after manual edits to update visuals.") end

            if ImGui.Checkbox(ctx, "Send MIDI Note", Setting_SendNoteWhenClicked) then 
                Setting_SendNoteWhenClicked = not Setting_SendNoteWhenClicked 
                SaveSettings()
            end
            if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Send a MIDI message when the KS button clicked. Good for previewing keyswitches.") end

            if ImGui.Checkbox(ctx, "Chase Mode", Setting_ChaseMode) then 
                Setting_ChaseMode = not Setting_ChaseMode 
                SaveSettings()
            end
            if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "When enabled, the KS note will be inserted until the end of the MIDI item.") end

            if ImGui.Checkbox(ctx, "Extend existing KS notes when refreshing", Setting_ExtendOnRefresh) then
                Setting_ExtendOnRefresh = not Setting_ExtendOnRefresh
                SaveSettings()
            end
            if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "When enabled, clicking Refresh will extend existing KS notes to the next KS or item end.") end

            _, val = ImGui.SliderInt(ctx, "KS per Column", Setting_ItemsPerColumn, 1, 100)
            if val ~= Setting_ItemsPerColumn then
                Setting_ItemsPerColumn = val
                SaveSettings()
            end
            if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "How many KS buttons in a single column.") end

            _, val = ImGui.SliderInt(ctx, "New Note Offset", Setting_PPQOffset, -math.abs(PPQ/4), 0)  
            if val ~= Setting_PPQOffset then
                Setting_PPQOffset = val
                SaveSettings()
            end
            if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Negative offset for inserted KS note. Helps with triggering KS just before the note. Default is -1.") end

            ImGui.EndPopup(ctx)
        end


        if ImGui.BeginPopupModal(ctx, "Note Name Injector", true) then
            _, Injector_NotesList = ImGui.InputTextMultiline(ctx, "Note Names", Injector_NotesList, 128, 256)
            ImGui.SetNextItemWidth(ctx, 128)
            _, Injector_FirstNoteID = ImGui.InputInt(ctx, "Starting Note ID", Injector_FirstNoteID)
            if ImGui.Button(ctx, "Inject!") then InjectNoteNames(Injector_NotesList, Injector_FirstNoteID) end
            ImGui.SameLine(ctx)
            if ImGui.Button(ctx, "Clear") then ClearNoteNames() end
            ImGui.EndPopup(ctx)
        end

        -- Show attached browser when no note name list is loaded
        local hasNoteNames = false
        for _, _ in pairs(Articulations) do
            hasNoteNames = true
            break
        end
        if not hasNoteNames then
            ImGui.SeparatorText(ctx, "Note Name Files")
            ImGui.BeginChild(ctx, "NoteNameBrowser", -1, 300, 0)

            local root = GetNoteNamesRoot()

            -- Initial scan or root changed
            if (not NoteBrowser_WasOpen) or (NoteBrowser_LastRoot ~= root) or (#NoteTree == 0) then
                NoteTree = BuildNoteTree(root)
                FilteredNoteTree = NoteTree
                local flat = FlattenNoteFiles(FilteredNoteTree)
                SelectedNoteFile = flat[1]
                NoteBrowser_LastRoot = root
            end

            -- Focus search on first open
            if not NoteBrowser_WasOpen then
                NoteBrowser_InputFocusNext = true
                NoteBrowser_WasOpen = true
            end
            if NoteBrowser_InputFocusNext then
                ImGui.SetKeyboardFocusHere(ctx)
                NoteBrowser_InputFocusNext = false
            end

            -- Search bar
            ImGui.SetNextItemWidth(ctx, -1)
            local changed
            changed, NoteBrowser_Search = ImGui.InputText(ctx, "Search", NoteBrowser_Search)

            -- Update filtered tree and selection on change
            if changed then
                if NoteBrowser_Search == '' then
                    FilteredNoteTree = NoteTree
                else
                    FilteredNoteTree = FilterNoteTree(NoteTree, NoteBrowser_Search)
                end
                local results = FlattenNoteFiles(FilteredNoteTree)
                if #results > 0 then
                    local keep = false
                    if SelectedNoteFile then
                        for _, it in ipairs(results) do
                            if it.path == SelectedNoteFile.path then keep = true break end
                        end
                    end
                    if not keep then SelectedNoteFile = results[1] end
                else
                    SelectedNoteFile = nil
                end
            end

            -- Keyboard navigation when search is focused
            if ImGui.IsItemFocused(ctx) then
                local results = FlattenNoteFiles(FilteredNoteTree)
                if #results > 0 then
                    local idx = 1
                    if SelectedNoteFile then
                        for i, it in ipairs(results) do
                            if it.path == SelectedNoteFile.path then idx = i break end
                        end
                    end
                    if ImGui.IsKeyPressed(ctx, ImGui.Key_DownArrow, true) then
                        idx = math.min(idx + 1, #results)
                        SelectedNoteFile = results[idx]
                    elseif ImGui.IsKeyPressed(ctx, ImGui.Key_UpArrow, true) then
                        idx = math.max(idx - 1, 1)
                        SelectedNoteFile = results[idx]
                    end
                    if ImGui.IsKeyPressed(ctx, ImGui.Key_Enter) or ImGui.IsKeyPressed(ctx, ImGui.Key_KeypadEnter) then
                        local toLoad = SelectedNoteFile or results[1]
                        if toLoad and toLoad.path then
                            LoadNoteNamesFromFile(toLoad.path)
                        end
                    end
                end
            end

            -- Show tree
            local isFiltering = (NoteBrowser_Search or '') ~= ''
            DrawNoteTree(isFiltering)

            -- Show counts
            local allCount = #FlattenNoteFiles(NoteTree)
            local filtCount = #FlattenNoteFiles(FilteredNoteTree)
            ImGui.Separator(ctx)
            ImGui.Text(ctx, string.format("%d/%d files", filtCount, allCount))

            ImGui.EndChild(ctx)
        else
            -- Reset focus trigger when browser is closed
            NoteBrowser_WasOpen = false
        end

 if ActiveTake == nil then
            ImGui.Separator(ctx)
            ImGui.Text(ctx, "No active MIDI take is open in the MIDI editor.")
        else
            ImGui.SeparatorText(ctx, "Keyswitches")
            local itemCount = 0
            ImGui.BeginGroup(ctx)

            for i = 0, 127 do
                if Articulations[i] ~= nil then
                    local articulation = Articulations[i]

                    if ActivatedKS[i] ~= nil then ImGui.PushStyleColor(ctx, ImGui.Col_Button, EnumThemeColors.G) end

                    local buttonLabel = tostring(articulation) .. "##ks_" .. tostring(i)
                    if ImGui.Button(ctx, buttonLabel, 100) then
                        local isShiftHeld = ImGui.GetKeyMods(ctx) == ImGui.Mod_Shift
                        local isCtrlHeld = ImGui.GetKeyMods(ctx) == ImGui.Mod_Ctrl
                        local isAltHeld = ImGui.GetKeyMods(ctx) == ImGui.Mod_Alt
                        
                        if isCtrlHeld then 
                            SendMIDINote(i)
                        elseif isAltHeld then
                            RemoveKS(i)
                        else
                            InsertKS(i, isShiftHeld)                            
                            if Setting_SendNoteWhenClicked then SendMIDINote(i) end                                
                        end
                    end

                    if ActivatedKS[i] ~= nil then ImGui.PopStyleColor(ctx) end

                    itemCount = itemCount + 1
                    if itemCount % Setting_ItemsPerColumn == 0 then
                        ImGui.EndGroup(ctx)
                        ImGui.SameLine(ctx)
                        ImGui.BeginGroup(ctx) 
                    end
                end
            end
            ImGui.EndGroup(ctx)
        end

        -- Save window pos/size before ending
        Window_PosX, Window_PosY = ImGui.GetWindowPos(ctx)
        Window_SizeW, Window_SizeH = ImGui.GetWindowSize(ctx)

        ImGui.End(ctx)        
    end

    StylingEnd(ctx)
    UpdateActiveTargets()
    GetActiveKSAtPlayheadPosition()

    if open then
            reaper.defer(loop)
        else
            SaveSettings() -- Save window pos/size & other settings when closing
        end
end

LoadSettings()
reaper.set_action_options(1)
reaper.defer(loop)
