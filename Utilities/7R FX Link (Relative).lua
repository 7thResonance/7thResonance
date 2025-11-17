--[[
@description 7R FX Link (Relative)
@author 7thResonance
@version 1.03
@changelog - fixed error when selecting media item.
@donation https://paypal.me/7thresonance
@about Links the same FX on selected track.

Original script by zaibuyidao.
Any changes to the FX parameters on one track will be reflected on all other selected tracks with the same FX (all of them).
Also syncs bypass and offline states of the FX.
Uses FX focus as the starting point. If you have multiple FX windows open
wait a short time (maybe 50 to 100ms) before adjusting parameter. 
(limitation of how reaper defer cycles work, or my lack of ideas lmao)
 
--]]

function Msg(string)
  reaper.ShowConsoleMsg(tostring(string).."\n")
end

only_first = true -- true or false: Set to true, Link The first FX of the same name. Set to false, Link all FX of the same name.

-- 當前focused FX的信息
focused_fx = {
  track_idx = nil,
  item_idx = nil,
  take_idx = nil,
  fx_idx = nil,
  fx_name = nil
}

-- 參數快照，保存當前focused FX所有參數的值
param_snapshot = {}

-- 追蹤所有選中item/track上FX的bypass和offline狀態
fx_state_snapshot = {}

function create_param_snapshot()
  param_snapshot = {}
  
  if not focused_fx.track_idx then return end
  
  -- 確定是item FX還是track FX
  local is_item_fx = focused_fx.item_idx and focused_fx.item_idx >= 0
  
  if is_item_fx then
    local track = reaper.GetTrack(0, focused_fx.track_idx)
    local item = reaper.GetTrackMediaItem(track, focused_fx.item_idx)
    local take = reaper.GetMediaItemTake(item, focused_fx.take_idx)
    
    if take then
      local param_count = reaper.TakeFX_GetNumParams(take, focused_fx.fx_idx)
      for i = 0, param_count - 1 do
        param_snapshot[i] = reaper.TakeFX_GetParam(take, focused_fx.fx_idx, i)
      end
    end
  else
    -- Track FX
    local track = reaper.GetTrack(0, focused_fx.track_idx)
    if track or focused_fx.track_idx == -1 then
      if focused_fx.track_idx == -1 then
        track = reaper.GetMasterTrack(0)
      end
      local param_count = reaper.TrackFX_GetNumParams(track, focused_fx.fx_idx)
      for i = 0, param_count - 1 do
        param_snapshot[i] = reaper.TrackFX_GetParam(track, focused_fx.fx_idx, i)
      end
    end
  end
end

function update_and_sync_params()
  if not focused_fx.track_idx then return end
  
  local is_item_fx = focused_fx.item_idx and focused_fx.item_idx >= 0
  local track, take
  
  if is_item_fx then
    track = reaper.GetTrack(0, focused_fx.track_idx)
    local item = reaper.GetTrackMediaItem(track, focused_fx.item_idx)
    take = reaper.GetMediaItemTake(item, focused_fx.take_idx)
    if not take then return end
  else
    if focused_fx.track_idx == -1 then
      track = reaper.GetMasterTrack(0)
    else
      track = reaper.GetTrack(0, focused_fx.track_idx)
    end
    if not track then return end
  end
  
  -- 讀取所有當前參數值並檢查變化
  local param_count = is_item_fx and reaper.TakeFX_GetNumParams(take, focused_fx.fx_idx) or reaper.TrackFX_GetNumParams(track, focused_fx.fx_idx)
  
  for param_idx = 0, param_count - 1 do
    local current_val = is_item_fx and reaper.TakeFX_GetParam(take, focused_fx.fx_idx, param_idx) or reaper.TrackFX_GetParam(track, focused_fx.fx_idx, param_idx)
    local snapshot_val = param_snapshot[param_idx] or 0
    
    -- 檢測參數變化（應用任何變化，讓REAPER處理浮點精度）
    if current_val ~= snapshot_val then
      local delta = current_val - snapshot_val
      
      -- 同步到所有選中的item/track
      if is_item_fx then
        sync_item_fx_param(param_idx, delta)
      else
        sync_track_fx_param(param_idx, delta)
      end
    end
    
    -- 更新快照為當前值
    param_snapshot[param_idx] = current_val
  end
end

function get_fx_instance_number(take, fx_idx, fx_name)
  -- 計算同名FX在此位置之前有多少個，得到實例編號（1-based）
  local instance = 1
  for i = 0, fx_idx - 1 do
    local _, name = reaper.TakeFX_GetFXName(take, i, '')
    if name == fx_name then
      instance = instance + 1
    end
  end
  return instance
end

function get_track_fx_instance_number(track, fx_idx, fx_name)
  -- 計算同名FX在此位置之前有多少個，得到實例編號（1-based）
  local instance = 1
  for i = 0, fx_idx - 1 do
    local _, name = reaper.TrackFX_GetFXName(track, i, '')
    if name == fx_name then
      instance = instance + 1
    end
  end
  return instance
end

function find_fx_instance_on_take(take, fx_name, target_instance)
  -- 在take中找到第target_instance個同名FX的位置，返回其fx_idx
  local instance = 0
  local fx_count = reaper.TakeFX_GetCount(take)
  for i = 0, fx_count - 1 do
    local _, name = reaper.TakeFX_GetFXName(take, i, '')
    if name == fx_name then
      instance = instance + 1
      if instance == target_instance then
        return i
      end
    end
  end
  return -1  -- 未找到
end

function find_fx_instance_on_track(track, fx_name, target_instance)
  -- 在track中找到第target_instance個同名FX的位置，返回其fx_idx
  local instance = 0
  local fx_count = reaper.TrackFX_GetCount(track)
  for i = 0, fx_count - 1 do
    local _, name = reaper.TrackFX_GetFXName(track, i, '')
    if name == fx_name then
      instance = instance + 1
      if instance == target_instance then
        return i
      end
    end
  end
  return -1  -- 未找到
end

function sync_item_fx_param(param_idx, delta)
  local source_track = reaper.GetTrack(0, focused_fx.track_idx)
  local source_item = reaper.GetTrackMediaItem(source_track, focused_fx.item_idx)
  local source_take = reaper.GetMediaItemTake(source_item, focused_fx.take_idx)
  
  -- 只有當source item被選中時才同步
  if not reaper.IsMediaItemSelected(source_item) then return end
  
  -- 計算source FX的實例編號
  local source_instance = get_fx_instance_number(source_take, focused_fx.fx_idx, focused_fx.fx_name)
  
  local items_count = reaper.CountSelectedMediaItems(0)
  
  for i = 0, items_count - 1 do
    local selected_item = reaper.GetSelectedMediaItem(0, i)
    local selected_take = reaper.GetActiveTake(selected_item)
    
    if not selected_take then goto continue_item end
    
    -- 跳過source item
    if selected_take == source_take then goto continue_item end
    
    -- 在選中item上找到相同實例編號的FX
    local target_fx_idx = find_fx_instance_on_take(selected_take, focused_fx.fx_name, source_instance)
    if target_fx_idx < 0 then goto continue_item end
    
    -- 應用delta
    local other_current_val = reaper.TakeFX_GetParam(selected_take, target_fx_idx, param_idx)
    local new_val = other_current_val + delta
    new_val = math.max(0, math.min(1, new_val))
    reaper.TakeFX_SetParam(selected_take, target_fx_idx, param_idx, new_val)
    
    ::continue_item::
  end
end

function create_fx_state_snapshot()
  fx_state_snapshot = {}
  
  -- 掃描所有選中item的FX狀態
  local items_count = reaper.CountSelectedMediaItems(0)
  for i = 0, items_count - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    local take = reaper.GetActiveTake(item)
    if take then
      local fx_count = reaper.TakeFX_GetCount(take)
      for fx_idx = 0, fx_count - 1 do
        local _, fx_name = reaper.TakeFX_GetFXName(take, fx_idx, '')
        local bypass = reaper.TakeFX_GetEnabled(take, fx_idx)
        local offline = reaper.TakeFX_GetOffline(take, fx_idx)
        local key = "item_" .. i .. "_" .. fx_idx
        fx_state_snapshot[key] = {
          type = "item",
          item_idx = i,
          fx_idx = fx_idx,
          fx_name = fx_name,
          bypass = bypass,
          offline = offline
        }
      end
    end
  end
  
  -- 掃描所有選中track的FX狀態
  local tracks = {}
  for i = 0, reaper.CountSelectedTracks(0) - 1 do
    table.insert(tracks, reaper.GetSelectedTrack(0, i))
  end
  if reaper.IsTrackSelected(reaper.GetMasterTrack(0)) then
    table.insert(tracks, reaper.GetMasterTrack(0))
  end
  
  for track_seq, track in pairs(tracks) do
    local fx_count = reaper.TrackFX_GetCount(track)
    for fx_idx = 0, fx_count - 1 do
      local _, fx_name = reaper.TrackFX_GetFXName(track, fx_idx, "")
      local bypass = reaper.TrackFX_GetEnabled(track, fx_idx)
      local offline = reaper.TrackFX_GetOffline(track, fx_idx)
      local key = "track_" .. track_seq .. "_" .. fx_idx
      fx_state_snapshot[key] = {
        type = "track",
        track_seq = track_seq,
        fx_idx = fx_idx,
        fx_name = fx_name,
        bypass = bypass,
        offline = offline
      }
    end
  end
end

function sync_fx_states()
  -- 重新掃描FX狀態並比較
  local items_count = reaper.CountSelectedMediaItems(0)
  
  -- 檢查item FX狀態變化和刪除
  local current_item_fx = {}
  local current_selected_items = {}
  for i = 0, items_count - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    local take = reaper.GetActiveTake(item)
    if take then
      local fx_count = reaper.TakeFX_GetCount(take)
      for fx_idx = 0, fx_count - 1 do
        local _, fx_name = reaper.TakeFX_GetFXName(take, fx_idx, '')
        local bypass = reaper.TakeFX_GetEnabled(take, fx_idx)
        local offline = reaper.TakeFX_GetOffline(take, fx_idx)
        local key = "item_" .. i .. "_" .. fx_idx
        current_item_fx[key] = true
        
        local old_state = fx_state_snapshot[key]
        if old_state then
          if old_state.bypass ~= bypass or old_state.offline ~= offline then
            -- 狀態改變，同步到其他選中item上同名的FX
            propagate_fx_state_item(fx_name, bypass, offline, fx_idx, take)
          end
        end
      end
    end
  end
  

  
  -- 檢查track FX狀態變化和刪除
  local tracks = {}
  local current_selected_tracks = {}
  for i = 0, reaper.CountSelectedTracks(0) - 1 do
    local track = reaper.GetSelectedTrack(0, i)
    table.insert(tracks, track)
    current_selected_tracks[reaper.GetTrackGUID(track)] = i
  end
  if reaper.IsTrackSelected(reaper.GetMasterTrack(0)) then
    local master = reaper.GetMasterTrack(0)
    table.insert(tracks, master)
    current_selected_tracks[reaper.GetTrackGUID(master)] = #tracks
  end
  
  local current_track_fx = {}
  for track_seq, track in pairs(tracks) do
    local fx_count = reaper.TrackFX_GetCount(track)
    for fx_idx = 0, fx_count - 1 do
      local _, fx_name = reaper.TrackFX_GetFXName(track, fx_idx, "")
      local bypass = reaper.TrackFX_GetEnabled(track, fx_idx)
      local offline = reaper.TrackFX_GetOffline(track, fx_idx)
      local key = "track_" .. track_seq .. "_" .. fx_idx
      current_track_fx[key] = true
      
      local old_state = fx_state_snapshot[key]
      if old_state then
        if old_state.bypass ~= bypass or old_state.offline ~= offline then
          -- 狀態改變，同步到其他選中track上同名的FX
          propagate_fx_state_track(fx_name, bypass, offline, fx_idx, track)
        end
      end
    end
  end
  

  
  -- 更新快照
  create_fx_state_snapshot()
end

function propagate_fx_deletion(fx_name, fx_type)
  if fx_type == "item" then
    local items_count = reaper.CountSelectedMediaItems(0)
    for i = 0, items_count - 1 do
      local item = reaper.GetSelectedMediaItem(0, i)
      local take = reaper.GetActiveTake(item)
      if take then
        local fx_count = reaper.TakeFX_GetCount(take)
        for fx_idx = fx_count - 1, 0, -1 do
          local _, current_fx_name = reaper.TakeFX_GetFXName(take, fx_idx, '')
          if current_fx_name == fx_name then
            reaper.TakeFX_Delete(take, fx_idx)
            if only_first then break end
          end
        end
      end
    end
  else
    local tracks = {}
    for i = 0, reaper.CountSelectedTracks(0) - 1 do
      table.insert(tracks, reaper.GetSelectedTrack(0, i))
    end
    if reaper.IsTrackSelected(reaper.GetMasterTrack(0)) then
      table.insert(tracks, reaper.GetMasterTrack(0))
    end
    
    for _, track in pairs(tracks) do
      local fx_count = reaper.TrackFX_GetCount(track)
      for fx_idx = fx_count - 1, 0, -1 do
        local _, current_fx_name = reaper.TrackFX_GetFXName(track, fx_idx, "")
        if current_fx_name == fx_name then
          reaper.TrackFX_Delete(track, fx_idx)
          if only_first then break end
        end
      end
    end
  end
end

function propagate_fx_state_item(fx_name, bypass, offline, source_fx_idx, source_take)
  -- 計算source FX的實例編號
  local source_instance = get_fx_instance_number(source_take, source_fx_idx, fx_name)
  
  local items_count = reaper.CountSelectedMediaItems(0)
  for i = 0, items_count - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    local take = reaper.GetActiveTake(item)
    if take then
      -- 跳過source item
      if take == source_take then goto continue_item_state_outer end
      
      -- 在item上找到相同實例編號的FX
      local target_fx_idx = find_fx_instance_on_take(take, fx_name, source_instance)
      if target_fx_idx < 0 then goto continue_item_state_outer end
      
      reaper.TakeFX_SetEnabled(take, target_fx_idx, bypass)
      reaper.TakeFX_SetOffline(take, target_fx_idx, offline)
      
      ::continue_item_state_outer::
    end
  end
end

function propagate_fx_state_track(fx_name, bypass, offline, source_fx_idx, source_track)
  -- 計算source FX的實例編號
  local source_instance = get_track_fx_instance_number(source_track, source_fx_idx, fx_name)
  
  local tracks = {}
  for i = 0, reaper.CountSelectedTracks(0) - 1 do
    table.insert(tracks, reaper.GetSelectedTrack(0, i))
  end
  if reaper.IsTrackSelected(reaper.GetMasterTrack(0)) then
    table.insert(tracks, reaper.GetMasterTrack(0))
  end
  
  for _, track in pairs(tracks) do
    -- 跳過source track
    if track == source_track then goto continue_track_state_outer end
    
    -- 在track上找到相同實例編號的FX
    local target_fx_idx = find_fx_instance_on_track(track, fx_name, source_instance)
    if target_fx_idx < 0 then goto continue_track_state_outer end
    
    reaper.TrackFX_SetEnabled(track, target_fx_idx, bypass)
    reaper.TrackFX_SetOffline(track, target_fx_idx, offline)
    
    ::continue_track_state_outer::
  end
end

function sync_track_fx_param(param_idx, delta)
  local source_track = focused_fx.track_idx == -1 and reaper.GetMasterTrack(0) or reaper.GetTrack(0, focused_fx.track_idx)
  
  -- 只有當source track被選中時才同步
  if not reaper.IsTrackSelected(source_track) then return end
  
  -- 計算source FX的實例編號
  local source_instance = get_track_fx_instance_number(source_track, focused_fx.fx_idx, focused_fx.fx_name)
  
  local selected_tracks = {}
  for i = 0, reaper.CountSelectedTracks(0) - 1 do
    table.insert(selected_tracks, reaper.GetSelectedTrack(0, i))
  end
  local master_track = reaper.GetMasterTrack(0)
  if reaper.IsTrackSelected(master_track) then
    table.insert(selected_tracks, master_track)
  end
  
  for _, selected_track in pairs(selected_tracks) do
    -- 跳過source track
    if selected_track == source_track then goto continue_track end
    
    -- 在選中track上找到相同實例編號的FX
    local target_fx_idx = find_fx_instance_on_track(selected_track, focused_fx.fx_name, source_instance)
    if target_fx_idx < 0 then goto continue_track end
    
    -- 應用delta
    local other_current_val = reaper.TrackFX_GetParam(selected_track, target_fx_idx, param_idx)
    local new_val = other_current_val + delta
    new_val = math.max(0, math.min(1, new_val))
    reaper.TrackFX_SetParam(selected_track, target_fx_idx, param_idx, new_val)
    
    ::continue_track::
  end
end

function main()
  reaper.PreventUIRefresh(1)
  
  -- 第一次執行時初始化FX狀態快照
  if next(fx_state_snapshot) == nil and (reaper.CountSelectedMediaItems(0) > 0 or reaper.CountSelectedTracks(0) > 0) then
    create_fx_state_snapshot()
  end
  
  -- 查詢當前focused FX
  local retval, track_idx, item_idx, take_idx, fx_idx, parm_idx = reaper.GetTouchedOrFocusedFX(1)
  
  -- 檢查focused FX是否改變
  local fx_changed = false
  if retval then
    if track_idx ~= focused_fx.track_idx or item_idx ~= focused_fx.item_idx or 
       take_idx ~= focused_fx.take_idx or fx_idx ~= focused_fx.fx_idx then
      fx_changed = true
    end
  end
  
  -- 如果focused FX改變，建立新快照
  if fx_changed and retval then
    focused_fx.track_idx = track_idx
    focused_fx.item_idx = item_idx
    focused_fx.take_idx = take_idx
    focused_fx.fx_idx = fx_idx
    
    -- 獲取FX名稱
    local is_item_fx = item_idx and item_idx >= 0
    if is_item_fx then
      local track = reaper.GetTrack(0, track_idx)
      local item = reaper.GetTrackMediaItem(track, item_idx)
      local take = reaper.GetMediaItemTake(item, take_idx)
      if take then
        _, focused_fx.fx_name = reaper.TakeFX_GetFXName(take, fx_idx, '')
      end
    else
      local track = track_idx == -1 and reaper.GetMasterTrack(0) or reaper.GetTrack(0, track_idx)
      if track then
        _, focused_fx.fx_name = reaper.TrackFX_GetFXName(track, fx_idx, "")
      end
    end
    
    create_param_snapshot()
  elseif not retval then
    -- No focused FX
    focused_fx.track_idx = nil
    focused_fx.item_idx = nil
    focused_fx.take_idx = nil
    focused_fx.fx_idx = nil
    focused_fx.fx_name = nil
    param_snapshot = {}
  end
  
  -- 檢查並同步FX狀態變化（bypass/offline）
  sync_fx_states()
  
  -- 如果有focused FX，更新並同步參數
  if focused_fx.track_idx ~= nil then
    update_and_sync_params()
  end
  
  reaper.PreventUIRefresh(-1)
  reaper.defer(main)
end

local _, _, sectionId, cmdId = reaper.get_action_context()
if sectionId ~= -1 then
  reaper.SetToggleCommandState(sectionId, cmdId, 1)
  reaper.RefreshToolbar2(sectionId, cmdId)
  main()
  reaper.atexit(function()
    reaper.SetToggleCommandState(sectionId, cmdId, 0)
    reaper.RefreshToolbar2(sectionId, cmdId)
  end)
end
