--[[
@description 7R Project Time Tracker
@author 7thResonance
@version 1.4
@changelog - imgui problem that didnt occur in testing for some reason.
@about
  Tracks active project time (editing / play / rec / armed). Stores time per-project using ProjExtState.
  Right-click window for options (reset, add minutes, font/size).
  Simple work/break timer with auto-start.
  Double click to skip to next work/break phase.

--]]

local script_name = "Project Time Tracker"
local ctx = reaper.ImGui_CreateContext(script_name)
local AUTOSAVE_INTERVAL_SEC = 30
local TIMER_AUTOSTART_DELAY_SEC = 3.0

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
local GLOBAL_SETTINGS_PREFIX = "global_"

local settings = {
  font_name = "Arial",
  font_size = 12,
  afk_seconds = 5,
  enable_work_timer = false,
  work_minutes = 25,
  break_minutes = 5,
  auto_start_work = true,
  auto_start_break = false,
  animation_enable = true,
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
local timer_state = {
  mode = "work",
  remaining = 25 * 60,
  running = false,
  flash_until = 0,
  autostart_due = 0,
}

local function ext_to_bool(v, default_value)
  if v == "" or v == nil then return default_value end
  return v == "1"
end

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

  local function get_setting(key)
    local _, proj_val = reaper.GetProjExtState(proj, EXT_SECTION, key)
    if proj_val ~= "" then return proj_val end
    return reaper.GetExtState(EXT_SECTION, GLOBAL_SETTINGS_PREFIX .. key)
  end

  local font_name = get_setting("font_name")
  if font_name ~= "" then settings.font_name = font_name end

  local size_str = get_setting("font_size")
  settings.font_size = tonumber(size_str) or settings.font_size or 12

  local afk_str = get_setting("afk_seconds")
  settings.afk_seconds = tonumber(afk_str) or settings.afk_seconds or 5

  local enable_timer = get_setting("enable_work_timer")
  settings.enable_work_timer = ext_to_bool(enable_timer, settings.enable_work_timer)

  local work_minutes = get_setting("work_minutes")
  settings.work_minutes = tonumber(work_minutes) or settings.work_minutes or 25

  local break_minutes = get_setting("break_minutes")
  settings.break_minutes = tonumber(break_minutes) or settings.break_minutes or 5

  local auto_start_work = get_setting("auto_start_work")
  settings.auto_start_work = ext_to_bool(auto_start_work, settings.auto_start_work)

  local auto_start_break = get_setting("auto_start_break")
  settings.auto_start_break = ext_to_bool(auto_start_break, settings.auto_start_break)

  local animation_enable = get_setting("animation_enable")
  settings.animation_enable = ext_to_bool(animation_enable, settings.animation_enable)

  if settings.work_minutes < 1 then settings.work_minutes = 1 end
  if settings.break_minutes < 1 then settings.break_minutes = 1 end

  pending_rebuild_font = true
end

local function save_settings(proj)
  if not proj or not reaper.ValidatePtr(proj, "ReaProject*") then return end
  local function save_setting(key, value)
    local str = tostring(value)
    reaper.SetProjExtState(proj, EXT_SECTION, key, str)
    reaper.SetExtState(EXT_SECTION, GLOBAL_SETTINGS_PREFIX .. key, str, true)
  end

  save_setting("font_name", settings.font_name or "Arial")
  save_setting("font_size", settings.font_size or 12)
  save_setting("afk_seconds", settings.afk_seconds or 5)
  save_setting("enable_work_timer", settings.enable_work_timer and "1" or "0")
  save_setting("work_minutes", settings.work_minutes or 25)
  save_setting("break_minutes", settings.break_minutes or 5)
  save_setting("auto_start_work", settings.auto_start_work and "1" or "0")
  save_setting("auto_start_break", settings.auto_start_break and "1" or "0")
  save_setting("animation_enable", settings.animation_enable and "1" or "0")
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

local function timer_duration_for_mode(mode)
  if mode == "break" then
    return (tonumber(settings.break_minutes) or 5) * 60
  end
  return (tonumber(settings.work_minutes) or 25) * 60
end

local function timer_autostart_for_mode(mode)
  if mode == "break" then return settings.auto_start_break end
  return settings.auto_start_work
end

local function reset_work_timer(mode, should_run)
  timer_state.mode = mode or "work"
  timer_state.remaining = timer_duration_for_mode(timer_state.mode)
  timer_state.running = should_run == true
  timer_state.autostart_due = 0
end

local function switch_work_timer(is_skip, now)
  local ts = now or reaper.time_precise()
  if timer_state.mode == "work" then
    timer_state.mode = "break"
  else
    timer_state.mode = "work"
  end
  timer_state.remaining = timer_duration_for_mode(timer_state.mode)
  timer_state.autostart_due = 0

  local auto_start_next = timer_autostart_for_mode(timer_state.mode)
  if (not is_skip) and auto_start_next then
    -- After a timer completes, wait briefly before auto-starting the next phase.
    timer_state.running = false
    timer_state.autostart_due = ts + TIMER_AUTOSTART_DELAY_SEC
  else
    timer_state.running = auto_start_next
  end

  if settings.animation_enable and not is_skip then
    -- Use a stable green highlight window instead of text flicker.
    timer_state.flash_until = ts + 1.2
  else
    timer_state.flash_until = 0
  end
end

local function update_work_timer(delta, now)
  if not settings.enable_work_timer then return end
  local ts = now or reaper.time_precise()
  if (timer_state.autostart_due or 0) > 0 and ts >= timer_state.autostart_due then
    timer_state.running = true
    timer_state.autostart_due = 0
  end
  if not timer_state.running then return end
  if not delta or delta <= 0 then return end

  timer_state.remaining = timer_state.remaining - delta
  if timer_state.remaining <= 0 then
    switch_work_timer(false, ts)
  end
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
    reset_work_timer("work", settings.auto_start_work)
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
    local afk = is_afk(proj, now)
    local should_tick_timer = (not afk) or (timer_state.mode == "break")
    if should_tick_timer then
      update_work_timer(delta, now)
    end
    if not afk then
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

    local line_gap = 8
    local total_h = text_h
    local work_mode_name = timer_state.mode == "work" and "W" or "B"
    local work_timer_str = work_mode_name .. " " .. format_time(timer_state.remaining)
    local _, work_text_h = reaper.ImGui_CalcTextSize(ctx, work_timer_str)
    local work_button_h = work_text_h + 8
    local show_work_timer = settings.enable_work_timer
    if show_work_timer then
      total_h = text_h + line_gap + work_button_h
    end

    local centered_y = cur_y + math.max(0, (avail_h - total_h) * 0.5)
    local centered_x = cur_x + math.max(0, (avail_w - text_w) * 0.5)
    reaper.ImGui_SetCursorPos(ctx, centered_x, centered_y)
    reaper.ImGui_Text(ctx, time_str)

    if show_work_timer then
      local row_y = centered_y + text_h + line_gap

      local is_flash = settings.animation_enable and (now < (timer_state.flash_until or 0))
      local is_waiting_autostart = (timer_state.autostart_due or 0) > now

      local work_btn_w = reaper.ImGui_CalcTextSize(ctx, work_timer_str) + 18
      local row_w = work_btn_w
      local row_x = cur_x + math.max(0, (avail_w - row_w) * 0.5)

      reaper.ImGui_SetCursorPos(ctx, row_x, row_y)
      local was_waiting_autostart = is_waiting_autostart
      local was_flash = is_flash
      local was_paused = (not timer_state.running) and (not was_waiting_autostart)
      if was_waiting_autostart or was_flash then
        -- Green highlight after transition to next phase and while waiting auto-start.
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x51B05BFF)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x63BF6CFF)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0x3E9648FF)
      elseif was_paused then
        -- Show paused state via yellow button background instead of text suffix.
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0xE6C84BFF)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0xF2D663FF)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0xCCAF35FF)
      end
      local timer_clicked = reaper.ImGui_Button(ctx, work_timer_str, work_btn_w, 0)
      local timer_double_clicked = reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_IsMouseDoubleClicked(ctx, 0)
      if timer_double_clicked then
        timer_state.autostart_due = 0
        switch_work_timer(true, now)
      elseif timer_clicked then
        timer_state.autostart_due = 0
        timer_state.running = not timer_state.running
      end
      if was_waiting_autostart or was_flash or was_paused then
        reaper.ImGui_PopStyleColor(ctx, 3)
      end
    end

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

      local changed_enable_timer, new_enable_timer = reaper.ImGui_Checkbox(ctx, "Enable Work Timer", settings.enable_work_timer)
      if changed_enable_timer then
        settings.enable_work_timer = new_enable_timer
        if settings.enable_work_timer then
          reset_work_timer("work", settings.auto_start_work)
        end
      end

      local changed_work_mins, new_work_mins = reaper.ImGui_SliderInt(ctx, "Work Time (min)", settings.work_minutes or 25, 1, 240)
      if changed_work_mins then
        settings.work_minutes = new_work_mins
        if timer_state.mode == "work" then
          timer_state.remaining = timer_duration_for_mode("work")
        end
      end
      if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
        local ok, input = reaper.GetUserInputs("Work Time (min)", 1, "Minutes:", tostring(settings.work_minutes or 25))
        if ok then
          local v = tonumber(input)
          if v then
            v = math.floor(v + 0.5)
            if v < 1 then v = 1 end
            if v > 240 then v = 240 end
            settings.work_minutes = v
            if timer_state.mode == "work" then
              timer_state.remaining = timer_duration_for_mode("work")
            end
          end
        end
      end

      local changed_break_mins, new_break_mins = reaper.ImGui_SliderInt(ctx, "Break Time (min)", settings.break_minutes or 5, 1, 120)
      if changed_break_mins then
        settings.break_minutes = new_break_mins
        if timer_state.mode == "break" then
          timer_state.remaining = timer_duration_for_mode("break")
        end
      end
      if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
        local ok, input = reaper.GetUserInputs("Break Time (min)", 1, "Minutes:", tostring(settings.break_minutes or 5))
        if ok then
          local v = tonumber(input)
          if v then
            v = math.floor(v + 0.5)
            if v < 1 then v = 1 end
            if v > 120 then v = 120 end
            settings.break_minutes = v
            if timer_state.mode == "break" then
              timer_state.remaining = timer_duration_for_mode("break")
            end
          end
        end
      end

      local changed_auto_work, new_auto_work = reaper.ImGui_Checkbox(ctx, "Auto Start Work", settings.auto_start_work)
      if changed_auto_work then settings.auto_start_work = new_auto_work end

      local changed_auto_break, new_auto_break = reaper.ImGui_Checkbox(ctx, "Auto Start Break", settings.auto_start_break)
      if changed_auto_break then settings.auto_start_break = new_auto_break end

      local changed_anim, new_anim = reaper.ImGui_Checkbox(ctx, "Animation Enable", settings.animation_enable)
      if changed_anim then settings.animation_enable = new_anim end

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
    reset_work_timer("work", settings.auto_start_work)
    last_proj = init_proj
    last_proj_id = get_project_id(init_proj, init_proj_fn)
  end
end

reaper.defer(main)
