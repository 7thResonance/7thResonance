--[[
@description 7R Insert Instrument (Respecting Folders)
@author 7thResonance
@version 1.1
@changelog - Text field is automaticaly focused for easier search.
@about Original Folder Respect logic is by Aaron Cendan (Insert New Track Respect Folders)
  Uses that logic to insert instrument at the start,middle, or end of folders.
  If no folder is selected, inserts at end of tracks
@screenshot Window https://i.postimg.cc/W4RTQztz/Screenshot-2025-07-11-143430.png
--]]

-- REAIMGUI SETUP
if not reaper.ImGui_CreateContext then
  reaper.ShowMessageBox("ReaImGui not found! Please install via ReaPack.", "Error", 0)
  return
end

local ctx = reaper.ImGui_CreateContext("Instrument Insert")
local font = reaper.ImGui_CreateFont('sans-serif', 14)
reaper.ImGui_Attach(ctx, font)

-- GLOBAL VARIABLES
local window_open = true
local search_text = ""
local instrument_list = {}
local filtered_instruments = {}
local selected_instrument = nil

-- Add string trim function
string.trim = string.trim or function(s)
  return s:match("^%s*(.-)%s*$")
end

-- SETTINGS
local settings = {
  window_x = -1,
  window_y = -1,
  window_width = 600,
  window_height = 400,
  auto_close_on_insert = true,
  hide_vst2_duplicates = true
}

-- SETTINGS FILE FUNCTIONS
local function get_settings_file_path()
  local resource_path = reaper.GetResourcePath()
  return resource_path .. "/Instrument_Insert_settings.lua"
end

local function save_settings()
  local settings_path = get_settings_file_path()
  
  local file = io.open(settings_path, "w")
  if file then
    file:write("-- Instrument Insert Settings File\n")
    file:write("return {\n")
    file:write("  window_x = " .. tostring(settings.window_x) .. ",\n")
    file:write("  window_y = " .. tostring(settings.window_y) .. ",\n")
    file:write("  window_width = " .. tostring(settings.window_width) .. ",\n")
    file:write("  window_height = " .. tostring(settings.window_height) .. ",\n")
    file:write("  auto_close_on_insert = " .. tostring(settings.auto_close_on_insert) .. ",\n")
    file:write("  hide_vst2_duplicates = " .. tostring(settings.hide_vst2_duplicates) .. "\n")
    file:write("}\n")
    file:close()
  end
end

local function load_settings()
  local settings_path = get_settings_file_path()
  
  local file = io.open(settings_path, "r")
  if not file then 
    return 
  end
  
  local content = file:read("*all")
  file:close()
  
  local load_func = load or loadstring
  local success, loaded_settings = pcall(load_func(content))
  if success and loaded_settings then
    if loaded_settings.window_x ~= nil then
      settings.window_x = loaded_settings.window_x
    end
    if loaded_settings.window_y ~= nil then
      settings.window_y = loaded_settings.window_y
    end
    if loaded_settings.window_width ~= nil then
      settings.window_width = loaded_settings.window_width
    end
    if loaded_settings.window_height ~= nil then
      settings.window_height = loaded_settings.window_height
    end
    if loaded_settings.auto_close_on_insert ~= nil then
      settings.auto_close_on_insert = loaded_settings.auto_close_on_insert
    end
    if loaded_settings.hide_vst2_duplicates ~= nil then
      settings.hide_vst2_duplicates = loaded_settings.hide_vst2_duplicates
    end
  end
end

local function save_window_state()
  if not ctx then return end
  
  local x, y = reaper.ImGui_GetWindowPos(ctx)
  local w, h = reaper.ImGui_GetWindowSize(ctx)
  
  if x and y and w and h and w > 100 and h > 100 and x > -10000 and y > -10000 then
    local changed = false
    
    if math.abs(settings.window_x - x) > 1 then
      settings.window_x = x
      changed = true
    end
    if math.abs(settings.window_y - y) > 1 then
      settings.window_y = y
      changed = true
    end
    if math.abs(settings.window_width - w) > 1 then
      settings.window_width = w
      changed = true
    end
    if math.abs(settings.window_height - h) > 1 then
      settings.window_height = h
      changed = true
    end
    
    if changed then
      save_settings()
    end
  end
end

------------------------------------------------------
-- FOLDER LOGIC (From original script)
------------------------------------------------------

function insert_track_respect_folders()
  if reaper.CountSelectedTracks(0) > 0 then
    -- Get selected track
    local sel_track = reaper.GetSelectedTrack(0, 0)
    local sel_track_idx = reaper.GetMediaTrackInfo_Value(sel_track, "IP_TRACKNUMBER")
    
    local folder_depth = reaper.GetMediaTrackInfo_Value(sel_track, "I_FOLDERDEPTH")
    local folder_depth_prev_track = 0
    if sel_track_idx > 1 then
      folder_depth_prev_track = reaper.GetMediaTrackInfo_Value(reaper.GetTrack(0, sel_track_idx - 2), "I_FOLDERDEPTH")
    end
    
    local new_track = nil
    
    -- Normal track right after the last track in a nested folder
    if folder_depth == 0 and folder_depth_prev_track < 0 then
      reaper.InsertTrackAtIndex(sel_track_idx, true)
      new_track = reaper.GetTrack(0, sel_track_idx)
      
    -- Last track in a folder right after the last track in a nested folder
    elseif folder_depth < 0 and folder_depth_prev_track < 0 then
      reaper.InsertTrackAtIndex(sel_track_idx, true)
      new_track = reaper.GetTrack(0, sel_track_idx)
      reaper.SetOnlyTrackSelected(new_track)
      reaper.ReorderSelectedTracks(sel_track_idx, 2)
      
    -- Folder parent
    elseif folder_depth == 1 then
      reaper.InsertTrackAtIndex(sel_track_idx, true)
      new_track = reaper.GetTrack(0, sel_track_idx)
      
    -- Normal track, or last track in folder/nested folder
    elseif folder_depth <= 0 then
      reaper.InsertTrackAtIndex(sel_track_idx - 1, true)
      new_track = reaper.GetTrack(0, sel_track_idx - 1)
      
      -- Move new track below originally selected track
      reaper.SetOnlyTrackSelected(sel_track)
      reaper.ReorderSelectedTracks(sel_track_idx - 1, 2)
    end
    
    if new_track then
      -- Set new track color and select it
      reaper.SetMediaTrackInfo_Value(new_track, "I_CUSTOMCOLOR", reaper.GetMediaTrackInfo_Value(sel_track, "I_CUSTOMCOLOR"))
      reaper.SetOnlyTrackSelected(new_track)
      return new_track
    end
    
  else
    -- Insert track at end of project if none selected
    local track_count = reaper.CountTracks(0)
    reaper.InsertTrackAtIndex(track_count, true)
    local new_track = reaper.GetTrack(0, track_count)
    reaper.SetOnlyTrackSelected(new_track)
    return new_track
  end
  
  return nil
end

------------------------------------------------------
-- INSTRUMENT SCANNING
------------------------------------------------------

function scan_instruments_with_enum()
  local instruments = {}
  local index = 0
  local total_fx_count = 0
  local instrument_count = 0
  
  -- Enumerate all installed FX using the REAPER API
  while true do
    local retval, name, ident = reaper.EnumInstalledFX(index)
    
    -- Break if no more FX found
    if not retval then
      break
    end
    
    total_fx_count = total_fx_count + 1
    
    -- Skip empty names or identifiers
    if name and name ~= "" and ident and ident ~= "" then
      local is_instrument = false
      
      -- Simple check: Look for plugin types ending with "i" (instrument)
      -- VST3i:, VST2i:, VSTi:, CLAPi:, AUi:, etc.
      if name:match("^%w+i:") then
        is_instrument = true
      end
      
      if is_instrument then
        instrument_count = instrument_count + 1
        
        -- Extract plugin type and clean name from "Plugin Type: Plugin Name" format
        local plugin_type = ""
        local clean_name = name
        
        -- Check if name contains colon separator for type:name format
        local colon_pos = name:find(":")
        if colon_pos then
          plugin_type = name:sub(1, colon_pos - 1):trim()
          local extracted_name = name:sub(colon_pos + 1):trim()
          -- Only use extracted name if it's not empty
          if extracted_name ~= "" then
            clean_name = extracted_name
          end
        end
        
        -- Extract developer from the plugin name if possible
        local developer = "Unknown"
        
        -- Try to extract developer from name patterns like "PluginName (Developer)"
        local name_part, dev_part = clean_name:match("^(.+)%s+%((.+)%)$")
        if name_part and dev_part then
          clean_name = name_part:gsub("%s+$", "")
          developer = dev_part
        else
          -- Try to extract from identifier patterns
          local dev_from_ident = ident:match("^VST3:(.-)_") or ident:match("^VST:(.-)_") or ident:match("^(.-):")
          if dev_from_ident then
            developer = dev_from_ident:gsub("_", " ")
          end
        end
        
        -- Determine plugin type from the extracted plugin_type or identifier
        local final_plugin_type = plugin_type
        if final_plugin_type == "" then
          -- Fallback to identifier analysis
          local ident_lower = ident:lower()
          if ident_lower:match("vst3i") or ident:match("^VST3:") or ident:match("%.vst3") then
            final_plugin_type = "VST3"
          elseif ident_lower:match("vsti") or ident:match("^VST:") or ident:match("%.dll") or ident:match("%.vst") then
            final_plugin_type = "VST2"
          elseif ident_lower:match("clapi") or ident:match("^CLAP:") or ident:match("%.clap") then
            final_plugin_type = "CLAP"
          elseif ident_lower:match("aui") then
            final_plugin_type = "AU"
          else
            final_plugin_type = "Instrument"
          end
        else
          -- Clean up the plugin_type to standardize it
          if plugin_type:match("VST3i") then
            final_plugin_type = "VST3"
          elseif plugin_type:match("VSTi") or plugin_type:match("VST2i") then
            final_plugin_type = "VST2"
          elseif plugin_type:match("CLAPi") then
            final_plugin_type = "CLAP"
          elseif plugin_type:match("AUi") then
            final_plugin_type = "AU"
          else
            final_plugin_type = plugin_type
          end
        end
        
        table.insert(instruments, {
          name = clean_name, -- Use clean name without type prefix
          developer = developer,
          filename = ident, -- Use identifier for insertion
          type = final_plugin_type,
          original_name = name -- Keep original for debugging if needed
        })
      end
    end
    
    index = index + 1
  end
  
  -- Filter VST duplicates if setting is enabled
  if settings.hide_vst2_duplicates then
    instruments = filter_vst_duplicates(instruments)
  end
  
  -- Sort instruments alphabetically
  table.sort(instruments, function(a, b)
    return a.name:lower() < b.name:lower()
  end)
  
  return instruments
end

function filter_vst_duplicates(instruments)
  local filtered = {}
  local vst3_plugins = {} -- Track VST3 plugins by name
  local clap_plugins = {} -- Track CLAP plugins by name
  
  -- First pass: collect all VST3 and CLAP plugin names
  for _, instrument in ipairs(instruments) do
    if instrument.type == "VST3" then
      vst3_plugins[instrument.name] = true
    elseif instrument.type == "CLAP" then
      clap_plugins[instrument.name] = true
    end
  end
  
  -- Second pass: filter out VST2 if VST3 or CLAP exists
  local hidden_count = 0
  for _, instrument in ipairs(instruments) do
    local is_vst2 = (instrument.type == "VST2")
    local has_newer_version = vst3_plugins[instrument.name] or clap_plugins[instrument.name]
    
    if is_vst2 and has_newer_version then
      -- Skip VST2 if VST3 or CLAP version exists
      hidden_count = hidden_count + 1
    else
      table.insert(filtered, instrument)
    end
  end
  
  return filtered
end

function filter_instruments(instruments, search_term)
  if search_term == "" then 
    return instruments 
  end
  
  local filtered = {}
  local search_lower = search_term:lower()
  
  for _, instrument in ipairs(instruments) do
    if instrument.name:lower():find(search_lower, 1, true) then
      table.insert(filtered, instrument)
    end
  end
  
  return filtered
end

function scan_instruments()
  -- Use the new enumeration-based scanning
  local instruments = scan_instruments_with_enum()
  
  -- Sort by name (already done in scan_instruments_with_enum, but ensuring it)
  table.sort(instruments, function(a, b)
    return a.name:lower() < b.name:lower()
  end)
  
  return instruments
end

------------------------------------------------------
-- INSTRUMENT INSERTION
------------------------------------------------------

function insert_instrument(instrument)
  if not instrument then
    reaper.ShowMessageBox("No instrument selected", "Error", 0)
    return false
  end
  
  -- Create new track with folder respect
  local new_track = insert_track_respect_folders()
  if not new_track then
    reaper.ShowMessageBox("Failed to create new track", "Error", 0)
    return false
  end
  
  -- Insert the instrument using the filename
  local fx_index = -1
  
  if instrument.type == "CLAP" then
    -- For CLAP, try using just the filename without full path
    fx_index = reaper.TrackFX_AddByName(new_track, instrument.filename, false, -1)
    if fx_index < 0 then
      -- If that fails, try with the instrument name
      fx_index = reaper.TrackFX_AddByName(new_track, instrument.name, false, -1)
    end
  elseif instrument.type == "VST3" then
    -- For VST3, try the plugin name first (more reliable)
    fx_index = reaper.TrackFX_AddByName(new_track, instrument.name, false, -1)
    if fx_index < 0 then
      -- If that fails, try with the filename
      fx_index = reaper.TrackFX_AddByName(new_track, instrument.filename, false, -1)
    end
    if fx_index < 0 then
      -- Try with "VST3:" prefix
      fx_index = reaper.TrackFX_AddByName(new_track, "VST3:" .. instrument.name, false, -1)
    end
  else
    -- For VST2, use the filename directly
    fx_index = reaper.TrackFX_AddByName(new_track, instrument.filename, false, -1)
    if fx_index < 0 then
      -- If that fails, try with the instrument name
      fx_index = reaper.TrackFX_AddByName(new_track, instrument.name, false, -1)
    end
  end
  
  if fx_index >= 0 then
    -- Set track name to instrument name
    reaper.GetSetMediaTrackInfo_String(new_track, "P_NAME", instrument.name, true)
    
    -- Record arm the track
    reaper.SetMediaTrackInfo_Value(new_track, "I_RECARM", 1)
    
    -- Auto-float the instrument FX window
    reaper.TrackFX_SetOpen(new_track, fx_index, true)
    
    -- Update arrangement
    reaper.UpdateArrange()
    
    return true
  else
    -- Show error message with instrument details
    local error_msg = string.format("Failed to insert instrument:\n\nName: %s\nDeveloper: %s\nType: %s\nFile: %s", 
      instrument.name, instrument.developer, instrument.type, instrument.filename)
    reaper.ShowMessageBox(error_msg, "Instrument Insert Failed", 0)
    return false
  end
end

function insert_instrument_track(instrument)
  -- Use the folder-aware track insertion logic
  local new_track = insert_track_respect_folders()
  
  if new_track then
    -- Set track name
    reaper.GetSetMediaTrackInfo_String(new_track, "P_NAME", instrument.name, true)
    
    -- Insert the instrument based on type
    if instrument.type == "CLAP" then
      -- For CLAP, use the filename
      reaper.TrackFX_AddByName(new_track, instrument.filename, false, -1)
    else
      -- For VST, use the existing logic
      reaper.TrackFX_AddByName(new_track, instrument.filename, false, -1)
    end
    
    -- Set track to record mode and arm it
    reaper.SetMediaTrackInfo_Value(new_track, "I_RECMODE", 1) -- Record input (audio or MIDI)
    reaper.SetMediaTrackInfo_Value(new_track, "I_RECARM", 1) -- Arm for recording
    
    -- Select the new track
    reaper.SetOnlyTrackSelected(new_track)
    
    -- Update arrange view
    reaper.UpdateArrange()
    
    return true
  end
  
  return false
end

------------------------------------------------------
-- GUI FUNCTIONS
------------------------------------------------------

function draw_search_box()
  reaper.ImGui_Text(ctx, "Search Instruments:")
  reaper.ImGui_SameLine(ctx)
  
  -- Auto-focus the search field when window first opens
  if reaper.ImGui_IsWindowAppearing(ctx) then
    reaper.ImGui_SetKeyboardFocusHere(ctx)
  end
  
  local changed, new_text = reaper.ImGui_InputText(ctx, "##search", search_text)
  if changed then
    search_text = new_text
    filtered_instruments = filter_instruments(instrument_list, search_text)
  end
  
  -- Show count
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_Text(ctx, string.format("(%d/%d)", #filtered_instruments, #instrument_list))
end

function draw_instrument_list()
  if reaper.ImGui_BeginChild(ctx, "InstrumentList", 0, -80) then
    
    if #filtered_instruments == 0 then
      if #instrument_list == 0 then
        reaper.ImGui_Text(ctx, "No instruments found. Make sure you have VST instruments installed.")
      else
        reaper.ImGui_Text(ctx, "No instruments match your search.")
      end
    else
      for i, instrument in ipairs(filtered_instruments) do
        local is_selected = (selected_instrument == instrument)
        
        if reaper.ImGui_Selectable(ctx, instrument.name, is_selected) then
          selected_instrument = instrument
        end
        
        -- Double-click to insert
        if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
          if insert_instrument(instrument) then
            if settings.auto_close_on_insert then
              window_open = false
            end
          end
        end
        
        -- Show tooltip with details
        if reaper.ImGui_IsItemHovered(ctx) then
          reaper.ImGui_BeginTooltip(ctx)
          reaper.ImGui_Text(ctx, "Developer: " .. instrument.developer)
          reaper.ImGui_Text(ctx, "Type: " .. instrument.type)
          if instrument.type == "CLAP" then
            reaper.ImGui_Text(ctx, "File: " .. instrument.filename)
          else
            reaper.ImGui_Text(ctx, "File: " .. instrument.filename)
          end
          reaper.ImGui_EndTooltip(ctx)
        end
      end
    end
    
    reaper.ImGui_EndChild(ctx)
  end
end

function draw_status_bar()
  reaper.ImGui_Separator(ctx)
  
  -- Buttons
  local available_width = reaper.ImGui_GetContentRegionAvail(ctx)
  reaper.ImGui_SetCursorPosX(ctx, reaper.ImGui_GetCursorPosX(ctx) + available_width - 180)
  
  -- Refresh button
  if reaper.ImGui_Button(ctx, "Refresh", 60, 25) then
    instrument_list = scan_instruments()
    filtered_instruments = filter_instruments(instrument_list, search_text)
  end
  
  reaper.ImGui_SameLine(ctx)
  
  -- Insert button
  local insert_enabled = (selected_instrument ~= nil)
  if not insert_enabled then
    reaper.ImGui_BeginDisabled(ctx)
  end
  
  if reaper.ImGui_Button(ctx, "Insert", 60, 25) then
    if insert_instrument(selected_instrument) then
      if settings.auto_close_on_insert then
        window_open = false
      end
    end
  end
  
  if not insert_enabled then
    reaper.ImGui_EndDisabled(ctx)
  end
  
  reaper.ImGui_SameLine(ctx)
  
  -- Close button
  if reaper.ImGui_Button(ctx, "Close", 50, 25) then
    window_open = false
  end
end

function draw_main_window()
  local window_flags = reaper.ImGui_WindowFlags_NoSavedSettings()
  
  -- Set window position and size
  if settings.window_x >= 0 and settings.window_y >= 0 then
    reaper.ImGui_SetNextWindowPos(ctx, settings.window_x, settings.window_y, reaper.ImGui_Cond_FirstUseEver())
  end
  
  reaper.ImGui_SetNextWindowSize(ctx, settings.window_width, settings.window_height, reaper.ImGui_Cond_FirstUseEver())
  
  local visible, open = reaper.ImGui_Begin(ctx, "Instrument Insert", true, window_flags)
  
  if visible then
    draw_search_box()
    reaper.ImGui_Spacing(ctx)
    draw_instrument_list()
    draw_status_bar()
    
    -- Save window state if it changed
    save_window_state()
    
    reaper.ImGui_End(ctx)
  end
  
  return open
end

------------------------------------------------------
-- MAIN LOOP
------------------------------------------------------

function init()
  -- Load settings first
  load_settings()
  
  -- Scan for instruments
  instrument_list = scan_instruments()
  filtered_instruments = instrument_list
  
  -- Focus search box
  reaper.ImGui_SetNextWindowFocus(ctx)
end

function main_loop()
  if not window_open then 
    return 
  end
  
  reaper.ImGui_PushFont(ctx, font)
  local gui_open = draw_main_window()
  reaper.ImGui_PopFont(ctx)
  
  if not gui_open then
    window_open = false
  end
  
  if window_open then
    reaper.defer(main_loop)
  end
end

-- Initialize and start
reaper.PreventUIRefresh(1)
reaper.Undo_BeginBlock()

init()
main_loop()

reaper.Undo_EndBlock("Insert Instrument Track", -1)
reaper.PreventUIRefresh(-1)

-- Cleanup
reaper.atexit(function()
  -- Save settings one final time
  save_settings()
  
  if ctx and reaper.ImGui_DestroyContext then
    reaper.ImGui_DestroyContext(ctx)
  end
end)
