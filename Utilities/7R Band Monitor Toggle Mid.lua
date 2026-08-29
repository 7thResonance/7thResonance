

--[[
  @description 7R Band Monitor
  @version 0.2
  @author 7thResonance
  @about
    companion script to togggle mid in 7R Band Monitor JSFX
]]

local FX_NAME = "7R Band Monitor"

-- Get master track
local master = reaper.GetMasterTrack(0)

-- Find the JSFX
local fx = reaper.TrackFX_GetByName(master, FX_NAME, false)

if fx < 0 then
    reaper.ShowMessageBox(
        "7R Band Monitor was not found on the Master Track.",
        "7R Band Monitor",
        0
    )
    return
end

-- slider7 is Monitor Mode
-- 0 = Stereo
-- 1 = Mid
local param = 6 -- zero-based parameter index: slider7 = index 6

local current = reaper.TrackFX_GetParam(master, fx, param)

-- Toggle Stereo <-> Mid
local new_value

if current < 0.5 then
    new_value = 1
else
    new_value = 0
end

reaper.TrackFX_SetParam(master, fx, param, new_value)

-- Prevent unnecessary undo point
reaper.UpdateArrange()