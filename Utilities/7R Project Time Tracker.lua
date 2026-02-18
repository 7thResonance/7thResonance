--[[
@description 7R Project Time Tracker
@author 7thResonance
@version 1.0
@about
  Tracks active project time (editing / play / rec / armed). Stores time per-project using ProjExtState.
  Right-click window for options (reset, add minutes, font/size).

--]]

local script_name = "Project Time Tracker"
local ctx = reaper.ImGui_CreateContext(script_name)
local AUTOSAVE_INTERVAL_SEC = 30

-- Compatibility: some ReaImGui versions use ImGui_Attach()/Detach() instead of ImGui_AttachFont()/DetachFont()
local function ImGui_AttachFont_Compat(ctx, font)
  if reaper.ImGui_AttachFont then return reaper.ImGui_AttachFont(ctx, font) end
  if reaper.ImGui_Attach then return reaper.ImGui_Attach(ctx, font) end
end
local function ImGui_DetachFont_Compat(ctx, font)
  if reaper.ImGui_DetachFont then return reaper.ImGui_DetachFont(ctx, font) end
  if reaper.ImGui_Detach then return reaper.ImGui_Detach(ctx, font) end
end


-- ProjExtState section name (must be consistent)
local EXT_SECTION = "7R_PROJECT_TIME_TRACKER"

local settings = {
  font_name = "Arial",
  font_size = 12,
  afk_seconds = 5,
}

local time_data = {
  total = 0.0,
  last_update = reaper.time_precise(),
  last_save = reaper.time_precise(),
}

local last_proj = nil
local last_proj_id = nil
local last_state_change = 0
local editing = false
local last_edit_activity = 0
local armed_cached = false
local add_minutes = 0

local font = nil
local pending_rebuild_font = true

local function destroy()
  if last_proj and reaper.ValidatePtr(last_proj, "ReaProject*") then
    -- Save before exit
    reaper.SetProjExtState(last_proj, EXT_SECTION, "total_seconds", tostring(time_data.total))
    reaper.SetProjExtState(last_proj, EXT_SECTION, "font_name", settings.font_name)
    reaper.SetProjExtState(last_proj, EXT_SECTION, "font_size", tostring(settings.font_size))
  end
  if reaper.ImGui_DestroyContext then
    reaper.ImGui_DestroyContext(ctx)
  elseif reaper.ImGui_Destroy then
    reaper.ImGui_Destroy(ctx)
  end
end

local function rebuild_font()
  if font then
    -- ReaImGui doesn't provide explicit font deletion; just create+attach a new one.
    font = nil
  end

  if settings.font_name and settings.font_size then
    font = reaper.ImGui_CreateFont(settings.font_name, settings.font_size)
    if font then
      ImGui_AttachFont_Compat(ctx, font)
    end
  end
  pending_rebuild_font = false
end

local function load_settings(proj)
  if not proj or not reaper.ValidatePtr(proj, "ReaProject*") then return end

  local _, font_name = reaper.GetProjExtState(proj, EXT_SECTION, "font_name")
  if font_name ~= "" then settings.font_name = font_name end

  local _, size_str = reaper.GetProjExtState(proj, EXT_SECTION, "font_size")
  settings.font_size = tonumber(size_str) or settings.font_size or 12

  local _, afk_str = reaper.GetProjExtState(proj, EXT_SECTION, "afk_seconds")
  settings.afk_seconds = tonumber(afk_str) or settings.afk_seconds or 5

  pending_rebuild_font = true
end

local function save_settings(proj)
  if not proj or not reaper.ValidatePtr(proj, "ReaProject*") then return end
  reaper.SetProjExtState(proj, EXT_SECTION, "font_name", settings.font_name or "Arial")
  reaper.SetProjExtState(proj, EXT_SECTION, "font_size", tostring(settings.font_size or 12))
  reaper.SetProjExtState(proj, EXT_SECTION, "afk_seconds", tostring(settings.afk_seconds or 5))
end

local function load_time(proj)
  if not proj or not reaper.ValidatePtr(proj, "ReaProject*") then return end

  local _, total_str = reaper.GetProjExtState(proj, EXT_SECTION, "total_seconds")
  time_data.total = tonumber(total_str) or 0.0

  time_data.last_update = reaper.time_precise()
  time_data.last_save = time_data.last_update
  last_edit_activity = time_data.last_update
  last_state_change = reaper.GetProjectStateChangeCount(proj)
  editing = false
end

local function scan_armed_tracks(proj)
  local tr_count = reaper.CountTracks(proj)
  for i = 0, tr_count - 1 do
    local track = reaper.GetTrack(proj, i)
    if track and reaper.GetMediaTrackInfo_Value(track, "I_RECARM") == 1 then
      return true
    end
  end
  return false
end

local function save_time(proj)
  if not proj or not reaper.ValidatePtr(proj, "ReaProject*") then return end
  reaper.SetProjExtState(proj, EXT_SECTION, "total_seconds", tostring(time_data.total))
  time_data.last_save = reaper.time_precise()
end

local function format_time(seconds)
  seconds = math.max(0, math.floor(seconds + 0.5))
  local h = math.floor(seconds / 3600)
  local m = math.floor((seconds % 3600) / 60)
  local s = math.floor(seconds % 60)
  return string.format("%02d:%02d:%02d", h, m, s)
end

local function concat_path(...)
  return table.concat({...}, package.config:sub(1, 1))
end

local function get_startup_hook_command_id()
  local _, script_file, section, cmd_id = reaper.get_action_context()
  if section == 0 and cmd_id ~= 0 then
    local cmd_name = "_" .. reaper.ReverseNamedCommandLookup(cmd_id)
    reaper.SetExtState(EXT_SECTION, "hook_cmd_name", cmd_name, true)
    return cmd_id
  end

  local cmd_name = reaper.GetExtState(EXT_SECTION, "hook_cmd_name")
  cmd_id = reaper.NamedCommandLookup(cmd_name)
  if cmd_id == 0 and script_file and script_file ~= "" then
    cmd_id = reaper.AddRemoveReaScript(true, 0, script_file, true)
    if cmd_id ~= 0 then
      cmd_name = "_" .. reaper.ReverseNamedCommandLookup(cmd_id)
      reaper.SetExtState(EXT_SECTION, "hook_cmd_name", cmd_name, true)
    end
  end
  return cmd_id
end

local function is_startup_hook_enabled()
  local cmd_id = get_startup_hook_command_id()
  if cmd_id == 0 then return false end

  local res_path = reaper.GetResourcePath()
  local startup_path = concat_path(res_path, "Scripts", "__startup.lua")
  local cmd_name = reaper.ReverseNamedCommandLookup(cmd_id)
  if cmd_name == "" then return false end

  if reaper.file_exists(startup_path) then
    local startup_file = io.open(startup_path, "r")
    if not startup_file then return false end
    local content = startup_file:read("*a")
    startup_file:close()

    local pattern = "[^\n]+" .. cmd_name .. "'?\n?[^\n]+"
    local s, e = content:find(pattern)
    if s and e then
      local hook = content:sub(s, e)
      local comment = hook:match("[^\n]*%-%-[^\n]*reaper%.Main_OnCommand")
      if not comment then return true end
    end
  end
  return false
end

local function set_startup_hook_enabled(is_enabled)
  local cmd_id = get_startup_hook_command_id()
  if cmd_id == 0 then return end

  local res_path = reaper.GetResourcePath()
  local startup_path = concat_path(res_path, "Scripts", "__startup.lua")
  local cmd_name = reaper.ReverseNamedCommandLookup(cmd_id)
  if cmd_name == "" then return end

  local content = ""
  local hook_exists = false
  if reaper.file_exists(startup_path) then
    local startup_file = io.open(startup_path, "r")
    if not startup_file then return end
    content = startup_file:read("*a")
    startup_file:close()

    local pattern = "[^\n]+" .. cmd_name .. "'?\n?[^\n]+"
    local s, e = content:find(pattern)
    if s and e then
      local hook = content:sub(s, e)
      local repl = (is_enabled and "" or "-- ") .. "reaper.Main_OnCommand"
      hook = hook:gsub("[^\n]*reaper%.Main_OnCommand", repl, 1)
      content = content:sub(1, s - 1) .. hook .. content:sub(e + 1)

      local new_startup_file = io.open(startup_path, "w")
      if not new_startup_file then return end
      new_startup_file:write(content)
      new_startup_file:close()
      hook_exists = true
    end
  end

  if is_enabled and not hook_exists then
    local hook = "-- Start script: " .. script_name .. "\n"
    hook = hook .. "local project_time_tracker_cmd_name = '_" .. cmd_name .. "'\n"
    hook = hook .. "reaper.Main_OnCommand(reaper.NamedCommandLookup(project_time_tracker_cmd_name), 0)\n\n"

    local startup_file = io.open(startup_path, "w")
    if not startup_file then return end
    startup_file:write(hook .. content)
    startup_file:close()
  end
end

local function get_project_id(proj, proj_fn)
  -- Use both pointer identity and file path to robustly detect active-project changes.
  return tostring(proj) .. "|" .. (proj_fn or "")
end

local function is_afk(proj, now)
  local playstate = reaper.GetPlayState()
  local playing = (playstate & 1) ~= 0
  local recording = (playstate & 4) ~= 0

  local current_state_change = reaper.GetProjectStateChangeCount(proj)
  if current_state_change > last_state_change then
    last_edit_activity = now or reaper.time_precise()
    last_state_change = current_state_change
    armed_cached = scan_armed_tracks(proj)
  end

  local afk_seconds = tonumber(settings.afk_seconds) or 5
  if afk_seconds < 1 then afk_seconds = 1 end
  editing = ((now or reaper.time_precise()) - (last_edit_activity or 0)) <= afk_seconds
  local active = playing or recording or armed_cached or editing
  editing = false
  return not active
end

local function main()
  local proj, proj_fn = reaper.EnumProjects(-1, "")
  if not proj or not reaper.ValidatePtr(proj, "ReaProject*") then
    reaper.defer(main)
    return
  end

  local proj_id = get_project_id(proj, proj_fn)

  -- Project switch handling
  if proj_id ~= last_proj_id then
    -- Important: after tab switch, writing to the previous project pointer can
    -- end up affecting the newly active project in some REAPER builds.
    -- We rely on periodic autosave + explicit current-project saves instead.
    load_settings(proj)
    load_time(proj)
    armed_cached = scan_armed_tracks(proj)
    last_proj = proj
    last_proj_id = proj_id
  end

  if pending_rebuild_font then
    rebuild_font()
  end

  -- Time accumulation
  local now = reaper.time_precise()
  local delta = now - (time_data.last_update or now)
  time_data.last_update = now  -- always advance, so AFK doesn't inflate later

  if delta > 0 and delta < 10 then
    if not is_afk(proj, now) then
      time_data.total = time_data.total + delta
    end
  end

  -- Persist tracked time periodically to reduce loss on unexpected exits.
  if (now - (time_data.last_save or now)) >= AUTOSAVE_INTERVAL_SEC then
    save_time(proj)
  end

  -- UI
  reaper.ImGui_SetNextWindowSize(ctx, 240, 110, reaper.ImGui_Cond_FirstUseEver())

  local visible, open = reaper.ImGui_Begin(ctx, script_name, true)
  if visible then
    local time_str = format_time(time_data.total)
    if font then reaper.ImGui_PushFont(ctx, font, settings.font_size or 12) end

    -- Center timer text in the current content region (works for resized/docked windows).
    local text_w, text_h = reaper.ImGui_CalcTextSize(ctx, time_str)
    local avail_w, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
    local cur_x, cur_y = reaper.ImGui_GetCursorPos(ctx)
    local centered_x = cur_x + math.max(0, (avail_w - text_w) * 0.5)
    local centered_y = cur_y + math.max(0, (avail_h - text_h) * 0.5)
    reaper.ImGui_SetCursorPos(ctx, centered_x, centered_y)
    reaper.ImGui_Text(ctx, time_str)

    if font then reaper.ImGui_PopFont(ctx) end

    if reaper.ImGui_BeginPopupContextWindow(ctx) then
      if reaper.ImGui_Button(ctx, "Reset Time") then
        time_data.total = 0.0
        reaper.ImGui_CloseCurrentPopup(ctx)
      end

      local changed_add, new_add = reaper.ImGui_InputInt(ctx, "Add Minutes", add_minutes)
      if changed_add then add_minutes = new_add end

      if reaper.ImGui_Button(ctx, "Add Time") then
        time_data.total = time_data.total + (tonumber(add_minutes) or 0) * 60
        add_minutes = 0
        reaper.ImGui_CloseCurrentPopup(ctx)
      end

      reaper.ImGui_Separator(ctx)

      local changed_font, new_font = reaper.ImGui_InputText(ctx, "Font", settings.font_name or "")
      if changed_font then
        settings.font_name = new_font
        pending_rebuild_font = true
      end

      local changed_size, new_size = reaper.ImGui_SliderInt(ctx, "Size", settings.font_size or 12, 8, 32)
      if changed_size then
        settings.font_size = new_size
        pending_rebuild_font = true
      end

      local changed_afk, new_afk = reaper.ImGui_SliderInt(ctx, "AFK Detection (sec)", settings.afk_seconds or 5, 1, 120)
      if changed_afk then
        settings.afk_seconds = new_afk
      end

      reaper.ImGui_Separator(ctx)

      local startup_enabled = is_startup_hook_enabled()
      local startup_label = startup_enabled and "Disable Run On Startup" or "Enable Run On Startup"
      if reaper.ImGui_Button(ctx, startup_label) then
        set_startup_hook_enabled(not startup_enabled)
      end

      if reaper.ImGui_Button(ctx, "Save Settings") then
        save_settings(proj)
        pending_rebuild_font = true
        reaper.ImGui_CloseCurrentPopup(ctx)
      end

      reaper.ImGui_EndPopup(ctx)
    end

    reaper.ImGui_End(ctx)
  else
    -- Window collapsed; still need End()
    reaper.ImGui_End(ctx)
  end

  if open == false then
    destroy()
    return
  end

  reaper.defer(main)
end

-- Init
do
  local init_proj, init_proj_fn = reaper.EnumProjects(-1, "")
  if init_proj and reaper.ValidatePtr(init_proj, "ReaProject*") then
    load_settings(init_proj)
    load_time(init_proj)
    armed_cached = scan_armed_tracks(init_proj)
    last_proj = init_proj
    last_proj_id = get_project_id(init_proj, init_proj_fn)
  end
end

reaper.defer(main)
