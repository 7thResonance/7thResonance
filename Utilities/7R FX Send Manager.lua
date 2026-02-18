--[[
@description 7R FX Send Manager
@author 7thResonance
@version 1.1
@changelog - Added pause to work with other background send scripts
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
local ctx = reaper.ImGui_CreateContext and reaper.ImGui_CreateContext(script_name)
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
local DEFAULT_DB = -60

-- State
local FX_TRACKS = {}    -- [guid] = true
local FX_ORDER = {}     -- ordered guids
local show_list = false
local default_db = tonumber(reaper.GetExtState(EXT_SECTION, "default_db")) or DEFAULT_DB
local open_main = true
local win_x = tonumber(reaper.GetExtState(EXT_SECTION, EXT_POSX))
local win_y = tonumber(reaper.GetExtState(EXT_SECTION, EXT_POSY))
local win_w = tonumber(reaper.GetExtState(EXT_SECTION, EXT_W))
local win_h = tonumber(reaper.GetExtState(EXT_SECTION, EXT_H))

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
local function Knob(label, val_lin, min_db, max_db)
  local val_db = lin2db(val_lin)
  local t = (val_db - min_db) / (max_db - min_db)
  t = math.max(0, math.min(1, t))
  reaper.ImGui_InvisibleButton(ctx, label, 40, 40)
  if reaper.ImGui_IsItemActive(ctx) then
    local dx, dy = reaper.ImGui_GetMouseDelta(ctx)
    local ddb = (dx - dy) * (max_db - min_db) / 200
    val_db = math.max(min_db, math.min(max_db, val_db + ddb))
    val_lin = db2lin(val_db)
    return true, val_lin
  end
  return false, val_lin
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
    local changed, new_default = reaper.ImGui_SliderDouble(ctx, '##default_db', default_db, -100, 6, '%.1f dB')
    if changed then
      default_db = new_default
      reaper.SetExtState(EXT_SECTION, "default_db", tostring(default_db), true)
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

-- Init
load_fx()
reaper.SetExtState("7R_SendScripts", "manager_running", "true", true)

-- Main loop
local function main()
  -- window pos/size
  if win_x and win_y then reaper.ImGui_SetNextWindowPos(ctx, win_x, win_y, reaper.ImGui_Cond_FirstUseEver()) end
  if win_w and win_h then reaper.ImGui_SetNextWindowSize(ctx, win_w, win_h, reaper.ImGui_Cond_FirstUseEver()) end

  local visible, new_open = reaper.ImGui_Begin(ctx, script_name, open_main)
  open_main = new_open
  if visible then
    -- save geom
    local p={reaper.ImGui_GetWindowPos(ctx)}; local s={reaper.ImGui_GetWindowSize(ctx)}
    reaper.SetExtState(EXT_SECTION, EXT_POSX, tostring(p[1]), true)
    reaper.SetExtState(EXT_SECTION, EXT_POSY, tostring(p[2]), true)
    reaper.SetExtState(EXT_SECTION, EXT_W, tostring(s[1]), true)
    reaper.SetExtState(EXT_SECTION, EXT_H, tostring(s[2]), true)

    -- track list button
    if reaper.ImGui_Button(ctx, 'Track List') then show_list = true; reaper.ImGui_OpenPopup(ctx, 'Track List') end
    reaper.ImGui_Separator(ctx)
    draw_list()

    -- sends
    reaper.ImGui_Text(ctx, 'Sends:')
    local sel = get_selected(); update_order()
    for _, g in ipairs(FX_ORDER) do
      local trfx = find_track(g)
      if trfx then
        local hv_lin = highest(sel, g)
        local _, fx_name = reaper.GetTrackName(trfx, '')
        local has_send = hv_lin ~= nil
        local hv_db = has_send and lin2db(hv_lin) or default_db

        reaper.ImGui_Text(ctx, fx_name)
        reaper.ImGui_SameLine(ctx, 200)

        if has_send then
          reaper.ImGui_BeginDisabled(ctx, false)
          local changed_local, new_db = reaper.ImGui_SliderDouble(ctx, "##"..fx_name, hv_db, -100, 6, "%.1f dB")
          reaper.ImGui_EndDisabled(ctx)

          if changed_local then
            local delta_db = new_db - hv_db
            apply_delta(sel, g, delta_db)
          end

          if reaper.ImGui_IsItemClicked(ctx, 1) then
            for _, tr in pairs(sel) do
              remove_send(tr, trfx)
            end
          end
        else
          if reaper.ImGui_Button(ctx, "+##"..fx_name) then
            for _, tr in pairs(sel) do
              local idx = reaper.CreateTrackSend(tr, trfx)
              if idx >= 0 then
                reaper.SetTrackSendInfo_Value(tr, 0, idx, 'D_VOL', db2lin(default_db))
              end
            end
          end
        end
      end
    end

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

