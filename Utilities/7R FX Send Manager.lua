--[[
@description 7R FX Send Manager
@author 7thResonance
@version 1.2
@changelog - made things much smaller with knobs. suitable for docking.
@about Opens GUI to mark tracks to be a FX send target
    - Autoloads marked tracks on new projects
    - Saves position and size of GUI
    - Set all selected track's Send values
    - Configurable default send value
    - Click + to add, right click to delete send (all selected tracks)
    - Control click to enter value directly
@screenshot https://i.postimg.cc/1RNB05tC/Screenshot-2025-08-08-012257.png
    https://i.postimg.cc/RV5Rg5JM/Screenshot-2025-08-08-012308.png

--]]

local reaper = reaper
local script_name = "FX Send Manager"
local imgui_flags = reaper.ImGui_ConfigFlags_DockingEnable and reaper.ImGui_ConfigFlags_DockingEnable() or 0
local ctx = reaper.ImGui_CreateContext and reaper.ImGui_CreateContext(script_name, imgui_flags)
if not ctx then
  reaper.ShowMessageBox("ReaImGui extension required","Error",0)
  return
end

-- Constants
local EXT_SECTION = "FXSendMgr"
local EXT_PROJECT_PREFIX = EXT_SECTION .. ":"
local EXT_CACHE = "cache_names"
local EXT_POSX = "win_pos_x"
local EXT_POSY = "win_pos_y"
local EXT_W = "win_w"
local EXT_H = "win_h"
local EXT_COMPACT = "compact_mode"
local DEFAULT_DB = -60
local MIN_DB = -100
local MAX_DB = 6
local MOUSE_LEFT = reaper.ImGui_MouseButton_Left and reaper.ImGui_MouseButton_Left() or 0
local MOUSE_RIGHT = reaper.ImGui_MouseButton_Right and reaper.ImGui_MouseButton_Right() or 1

-- State
local FX_TRACKS = {}    -- [guid] = true
local FX_ORDER = {}     -- ordered guids
local show_list = false
local default_db = tonumber(reaper.GetExtState(EXT_SECTION, "default_db")) or DEFAULT_DB
local default_db_text = string.format("%.1f", default_db)
local open_main = true
local win_x = tonumber(reaper.GetExtState(EXT_SECTION, EXT_POSX))
local win_y = tonumber(reaper.GetExtState(EXT_SECTION, EXT_POSY))
local win_w = tonumber(reaper.GetExtState(EXT_SECTION, EXT_W))
local win_h = tonumber(reaper.GetExtState(EXT_SECTION, EXT_H))
local compact_mode = reaper.GetExtState(EXT_SECTION, EXT_COMPACT) == "true"

-- Helpers
local function get_project_key()
  local _, projfn = reaper.EnumProjects(-1, "")
  return EXT_PROJECT_PREFIX .. (projfn ~= "" and projfn or "_unsaved_")
end

local function get_all_tracks()
  local names, guids = {}, {}
  for i=0, reaper.CountTracks(0)-1 do
    local tr = reaper.GetTrack(0,i)
    local _, nm = reaper.GetTrackName(tr, "")
    table.insert(names, nm)
    table.insert(guids, reaper.GetTrackGUID(tr))
  end
  return names, guids
end

local function find_track(guid)
  for i=0, reaper.CountTracks(0)-1 do
    local tr = reaper.GetTrack(0,i)
    if reaper.GetTrackGUID(tr) == guid then return tr end
  end
end

local function get_selected()
  local sel = {}
  for i=0, reaper.CountSelectedTracks(0)-1 do
    local tr = reaper.GetSelectedTrack(0,i)
    sel[reaper.GetTrackGUID(tr)] = tr
  end
  return sel
end

local function guid_send_index(src, dest)
  for i=0, reaper.GetTrackNumSends(src,0)-1 do
    if reaper.GetTrackSendInfo_Value(src,0,i,'P_DESTTRACK') == dest then return i end
  end
end

local function get_send(src, dest)
  local idx = guid_send_index(src,dest)
  return idx and reaper.GetTrackSendInfo_Value(src,0,idx,'D_VOL') or nil
end

local function set_send(src, dest, v)
  local idx = guid_send_index(src,dest)
  if idx then reaper.SetTrackSendInfo_Value(src,0,idx,'D_VOL',v) end
end

local function remove_send(src, dest)
  local idx = guid_send_index(src,dest)
  if idx then reaper.RemoveTrackSend(src,0,idx) end
end

local function db2lin(db)
  return db <= -100 and 0 or 10^(db/20)
end

local function lin2db(v)
  return v <= 0 and -100 or 20*math.log(v,10)
end

local function clamp(v, lo, hi)
  return math.max(lo, math.min(hi, v))
end

local function db_label(db)
  if db <= -99.9 then return "-inf" end
  return string.format("%.1f", db)
end

local function fit_text(text, max_w)
  if reaper.ImGui_CalcTextSize(ctx, text) <= max_w then return text end
  local out = text
  while #out > 1 and reaper.ImGui_CalcTextSize(ctx, out .. "..") > max_w do
    out = string.sub(out, 1, #out - 1)
  end
  return out .. ".."
end

-- Cache
local function load_fx()
  FX_TRACKS = {}
  -- project
  local gu = reaper.GetExtState(get_project_key(), 'guids') or ''
  for g in string.gmatch(gu, '[^,]+') do FX_TRACKS[g] = true end
  -- global
  local namecache = {}
  local cs = reaper.GetExtState(EXT_SECTION, EXT_CACHE) or ''
  for nm in string.gmatch(cs, '[^,]+') do namecache[nm] = true end
  local names, guids = get_all_tracks()
  for i,nm in ipairs(names) do
    if namecache[nm] then FX_TRACKS[guids[i]] = true end
  end
end

local function save_fx()
  -- per project
  local list = {}
  for g in pairs(FX_TRACKS) do table.insert(list,g) end
  reaper.SetExtState(get_project_key(), 'guids', table.concat(list,','), true)
  -- global names
  local cache = {}
  for g in pairs(FX_TRACKS) do
    local tr = find_track(g)
    if tr then local _,nm = reaper.GetTrackName(tr,'') ; cache[nm] = true end
  end
  local old = reaper.GetExtState(EXT_SECTION, EXT_CACHE) or ''
  for nm in string.gmatch(old,'[^,]+') do cache[nm] = true end
  local cl = {}
  for nm in pairs(cache) do table.insert(cl,nm) end
  reaper.SetExtState(EXT_SECTION, EXT_CACHE, table.concat(cl,','), true)
end

local function update_order()
  FX_ORDER = {}
  for i=0, reaper.CountTracks(0)-1 do
    local tr = reaper.GetTrack(0,i)
    local g = reaper.GetTrackGUID(tr)
    if FX_TRACKS[g] then table.insert(FX_ORDER,g) end
  end
end

-- UI
local function color(r, g, b, a)
  return reaper.ImGui_ColorConvertDouble4ToU32(r, g, b, a)
end

local function Knob(label, val_db, has_send, size, allow_remove, show_value)
  if allow_remove == nil then allow_remove = true end
  if show_value == nil then show_value = true end
  local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
  reaper.ImGui_InvisibleButton(ctx, label, size, size)

  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local active = reaper.ImGui_IsItemActive(ctx)
  local clicked = reaper.ImGui_IsItemClicked(ctx, MOUSE_LEFT)
  local right_clicked = reaper.ImGui_IsItemClicked(ctx, MOUSE_RIGHT)
  local changed = false
  local action = nil

  if has_send then
    if active then
      local dx, dy = reaper.ImGui_GetMouseDelta(ctx)
      local ddb = (dx - dy) * (MAX_DB - MIN_DB) / 220
      if ddb ~= 0 then
        val_db = clamp(val_db + ddb, MIN_DB, MAX_DB)
        changed = true
      end
    end
    if right_clicked and allow_remove then action = "remove" end
  elseif clicked then
    action = "add"
  end

  local t = clamp((val_db - MIN_DB) / (MAX_DB - MIN_DB), 0, 1)
  local cx = x + size * 0.5
  local cy = y + size * 0.5
  local radius = size * 0.43
  local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
  local fill_col = has_send and color(0.20, 0.21, 0.23, 1.00) or color(0.13, 0.13, 0.14, 1.00)
  local ring_col = hovered and color(0.74, 0.76, 0.80, 1.00) or color(0.43, 0.45, 0.48, 1.00)
  local accent_col = active and color(0.95, 0.78, 0.36, 1.00) or color(0.42, 0.68, 0.96, 1.00)
  local text_col = has_send and color(0.92, 0.93, 0.95, 1.00) or color(0.42, 0.68, 0.96, 1.00)

  reaper.ImGui_DrawList_AddCircleFilled(draw_list, cx, cy, radius, fill_col, 32)
  reaper.ImGui_DrawList_AddCircle(draw_list, cx, cy, radius, ring_col, 32, hovered and 2.0 or 1.3)

  if has_send then
    local angle = math.rad(135 + t * 270)
    local px = cx + math.cos(angle) * radius * 0.66
    local py = cy + math.sin(angle) * radius * 0.66
    reaper.ImGui_DrawList_AddLine(draw_list, cx, cy, px, py, accent_col, 2.0)
  end

  if show_value then
    local label_text = has_send and db_label(val_db) or "+"
    local tw, th = reaper.ImGui_CalcTextSize(ctx, label_text)
    reaper.ImGui_DrawList_AddText(draw_list, cx - tw * 0.5, cy - th * 0.5, text_col, label_text)
  end

  if hovered then
    if has_send then
      local tip = db_label(val_db) .. " dB\nDrag to adjust"
      if allow_remove then tip = tip .. ", right-click to remove" end
      reaper.ImGui_SetTooltip(ctx, tip)
    else
      reaper.ImGui_SetTooltip(ctx, "Click to add send at " .. db_label(default_db) .. " dB")
    end
  end

  return changed, val_db, action
end

local function SendBar(label, text, val_db, has_send, width, height)
  local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
  reaper.ImGui_InvisibleButton(ctx, label, width, height)

  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local clicked = reaper.ImGui_IsItemClicked(ctx, MOUSE_LEFT)
  local right_clicked = reaper.ImGui_IsItemClicked(ctx, MOUSE_RIGHT)
  local action = nil
  if has_send and right_clicked then action = "remove" end
  if not has_send and clicked then action = "add" end

  local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
  local bg_col = hovered and color(0.12, 0.14, 0.14, 1.00) or color(0.08, 0.09, 0.09, 1.00)
  local fill_col = color(0.12, 0.31, 0.24, 0.95)
  local border_col = color(0.20, 0.23, 0.23, 1.00)
  local text_col = has_send and color(0.71, 0.92, 0.98, 1.00) or color(0.42, 0.68, 0.96, 1.00)

  reaper.ImGui_DrawList_AddRectFilled(draw_list, x, y, x + width, y + height, bg_col, 0)
  if has_send then
    local t = clamp((val_db - MIN_DB) / (MAX_DB - MIN_DB), 0, 1)
    reaper.ImGui_DrawList_AddRectFilled(draw_list, x, y, x + width * t, y + height, fill_col, 0)
  end
  reaper.ImGui_DrawList_AddRect(draw_list, x, y, x + width, y + height, border_col, 0, 0, 1)

  local right_text = has_send and db_label(val_db) or "+"
  local right_w, right_h = reaper.ImGui_CalcTextSize(ctx, right_text)
  local name = fit_text(text, width - right_w - 12)
  local _, name_h = reaper.ImGui_CalcTextSize(ctx, name)
  reaper.ImGui_DrawList_AddText(draw_list, x + 4, y + (height - name_h) * 0.5, text_col, name)
  reaper.ImGui_DrawList_AddText(draw_list, x + width - right_w - 4, y + (height - right_h) * 0.5, text_col, right_text)

  if hovered then
    if has_send then
      reaper.ImGui_SetTooltip(ctx, db_label(val_db) .. " dB\nRight-click to remove")
    else
      reaper.ImGui_SetTooltip(ctx, "Click to add send at " .. db_label(default_db) .. " dB")
    end
  end

  return action
end

-- Draw track list popup
local function draw_list()
  local namecache = {}
  local cs = reaper.GetExtState(EXT_SECTION, EXT_CACHE) or ''
  for nm in string.gmatch(cs, '[^,]+') do namecache[nm] = true end

  if reaper.ImGui_BeginPopupModal(ctx, 'Track List', nil, reaper.ImGui_WindowFlags_AlwaysAutoResize()) then
    reaper.ImGui_Text(ctx, 'Select tracks:')
    
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Text(ctx, 'Default Send Level (dB):')
    reaper.ImGui_SetNextItemWidth(ctx, 80)
    local changed, new_default_text = reaper.ImGui_InputText(ctx, '##default_db', default_db_text)
    if changed then
      default_db_text = new_default_text
      local parsed = tonumber(new_default_text)
      if parsed then
        default_db = clamp(parsed, MIN_DB, MAX_DB)
        if default_db ~= parsed then default_db_text = string.format("%.1f", default_db) end
        reaper.SetExtState(EXT_SECTION, "default_db", tostring(default_db), true)
      end
    end
    reaper.ImGui_Separator(ctx)
    if reaper.ImGui_TreeNode(ctx, 'Cached Track Names') then
      for nm in pairs(namecache) do
        reaper.ImGui_Text(ctx, nm)
        reaper.ImGui_SameLine(ctx)
        if reaper.ImGui_Button(ctx, 'Remove##'..nm) then
          namecache[nm] = nil
          local cl = {}
          for n in pairs(namecache) do table.insert(cl, n) end
          reaper.SetExtState(EXT_SECTION, EXT_CACHE, table.concat(cl,','), true)
        end
      end
      reaper.ImGui_TreePop(ctx)
    end
    local names, guids = get_all_tracks()
    if reaper.ImGui_BeginChild(ctx, '##list', 300, 200, 0) then
      for i, nm in ipairs(names) do
        local g = guids[i]
        local ck = FX_TRACKS[g] or false
        local changed, new = reaper.ImGui_Checkbox(ctx, nm, ck)
        if changed then FX_TRACKS[g] = new and true or nil; save_fx(); update_order() end
      end
      reaper.ImGui_EndChild(ctx)
    end
    if reaper.ImGui_Button(ctx, 'Close') then reaper.ImGui_CloseCurrentPopup(ctx); show_list = false end
    reaper.ImGui_EndPopup(ctx)
  end
end

-- Highest send value
local function highest(selected, fxg)
  local m
  local dest = find_track(fxg)
  for _, tr in pairs(selected) do
    local v = get_send(tr, dest)
    if v and (not m or v > m) then m = v end
  end
  return m
end

-- Apply delta change to sends
local function apply_delta(selected, fxg, delta_db)
  local dest = find_track(fxg)
  for _, tr in pairs(selected) do
    local v = get_send(tr, dest)
    if v then
      local v_db = lin2db(v)
      local new_db = v_db + delta_db
      local new_lin = db2lin(new_db)
      set_send(tr, dest, new_lin)
    end
  end
end

local function add_sends_to_selected(selected, dest)
  for _, tr in pairs(selected) do
    local idx = reaper.CreateTrackSend(tr, dest)
    if idx >= 0 then
      reaper.SetTrackSendInfo_Value(tr, 0, idx, 'D_VOL', db2lin(default_db))
    end
  end
end

local function remove_sends_from_selected(selected, dest)
  for _, tr in pairs(selected) do
    remove_send(tr, dest)
  end
end

local function draw_send_row(selected, g)
  local trfx = find_track(g)
  if not trfx then return end

  local hv_lin = highest(selected, g)
  local _, fx_name = reaper.GetTrackName(trfx, '')
  local has_send = hv_lin ~= nil
  local hv_db = has_send and lin2db(hv_lin) or default_db
  local row_h = compact_mode and 15 or 17
  local knob_size = row_h
  local avail_w = reaper.ImGui_GetContentRegionAvail(ctx)
  local bar_w = has_send and (avail_w - knob_size - 3) or avail_w
  bar_w = math.max(compact_mode and 82 or 120, bar_w)

  local action = SendBar("##send_bar_"..g, fx_name, hv_db, has_send, bar_w, row_h)
  if action == "add" then
    add_sends_to_selected(selected, trfx)
  elseif action == "remove" then
    remove_sends_from_selected(selected, trfx)
  end

  if has_send then
    reaper.ImGui_SameLine(ctx, 0, 2)
    local changed, new_db, knob_action = Knob("##send_knob_"..g, hv_db, true, knob_size, true, false)
    if changed then
      apply_delta(selected, g, new_db - hv_db)
    end
    if knob_action == "remove" then
      remove_sends_from_selected(selected, trfx)
    end
  end
end

-- Init
load_fx()
reaper.SetExtState("7R_SendScripts", "manager_running", "true", true)

-- Main loop
local function main()
  -- window pos/size
  if win_x and win_y then reaper.ImGui_SetNextWindowPos(ctx, win_x, win_y, reaper.ImGui_Cond_FirstUseEver()) end
  if win_w and win_h then reaper.ImGui_SetNextWindowSize(ctx, win_w, win_h, reaper.ImGui_Cond_FirstUseEver()) end
  if not win_w or not win_h then
    reaper.ImGui_SetNextWindowSize(ctx, compact_mode and 190 or 330, compact_mode and 360 or 420, reaper.ImGui_Cond_FirstUseEver())
  end

  local visible, new_open = reaper.ImGui_Begin(ctx, script_name, open_main)
  open_main = new_open
  if visible then
    -- save geom
    local p={reaper.ImGui_GetWindowPos(ctx)}; local s={reaper.ImGui_GetWindowSize(ctx)}
    reaper.SetExtState(EXT_SECTION, EXT_POSX, tostring(p[1]), true)
    reaper.SetExtState(EXT_SECTION, EXT_POSY, tostring(p[2]), true)
    reaper.SetExtState(EXT_SECTION, EXT_W, tostring(s[1]), true)
    reaper.SetExtState(EXT_SECTION, EXT_H, tostring(s[2]), true)

    local sel = get_selected(); update_order()
    local _, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
    reaper.ImGui_BeginChild(ctx, '##send_list', -1, math.max(0, avail_h - 36), 0)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), compact_mode and 4 or 8, 0)
    for _, g in ipairs(FX_ORDER) do
      draw_send_row(sel, g)
    end
    reaper.ImGui_PopStyleVar(ctx)
    reaper.ImGui_EndChild(ctx)

    reaper.ImGui_Separator(ctx)
    if reaper.ImGui_Button(ctx, 'Track List') then show_list = true; reaper.ImGui_OpenPopup(ctx, 'Track List') end
    reaper.ImGui_SameLine(ctx)
    local compact_changed, new_compact = reaper.ImGui_Checkbox(ctx, 'Compact', compact_mode)
    if compact_changed then
      compact_mode = new_compact
      reaper.SetExtState(EXT_SECTION, EXT_COMPACT, compact_mode and "true" or "false", true)
      reaper.ImGui_SetWindowSize(ctx, compact_mode and 190 or 330, s[2], reaper.ImGui_Cond_Always())
    end
    draw_list()

    reaper.ImGui_End(ctx)
  end
  if open_main then
    reaper.defer(main)
  else
    -- Clear the flag when window is closed
    reaper.SetExtState("7R_SendScripts", "manager_running", "false", true)
  end
end

reaper.defer(main)

