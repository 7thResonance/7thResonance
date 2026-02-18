--[[
@description 7R Project Browser
@author 7thResonance
@version 1.0
@changelog - initial
@screenshot Window https://i.postimg.cc/W1D3q8m6/Screenshot-2025-08-23-002124.png
@about A simple GUI to view and load projects.
    - Select Root Master folder.
    - Hide individual folders at any level
    - Open, Open in new tab, and explorer window
    - Search all folders or only selected folder (settings)
    - Name, and date modification sort
    - Position and size is remembered
--]]
local os_name = reaper.GetOS()
local PATH_SEP = (os_name:match("Win")) and "\\" or "/"

-- --------------- Utility --------------- 

local function join_path(a, b)
  if not a or a == "" then return b end
  local last = a:sub(-1)
  if last == "/" or last == "\\" then
    return a .. b
  end
  return a .. PATH_SEP .. b
end

local function normalize_path(p)
  if not p or p == "" then return "" end
  -- Keep platform-native separator in saved paths to match REAPER behavior
  -- but trim trailing separators
    p = p:gsub("[/\\]+$", "")
  return p
end

-- forward noop dbg so earlier callers (before full dbg definition) don't trigger static checks
local dbg = function() end

local function os_get_file_mtime(path)
  -- Helpers: plausibility check and FILETIME (Win) -> Unix seconds
  local function _plausible_unix(sec)
    sec = tonumber(sec)
    if not sec or sec ~= sec or sec <= 0 then return false end
    -- accept from 1980..now+2y to be safe
    local now = os.time()
    return sec >= 315532800 and sec <= (now + 63072000)
  end
  local function _filetime_to_unix(hi, lo)
    hi, lo = tonumber(hi), tonumber(lo)
    if not hi or not lo then return nil end
    -- normalize possible signed 32-bit
    if lo < 0 then lo = lo + 4294967296 end
    if hi < 0 then hi = hi + 4294967296 end
    -- (hi<<32 | lo) are 100ns ticks since 1601-01-01
    -- seconds = ticks/1e7 - 11644473600
    local seconds = hi * 429.4967296 + (lo / 10000000.0) - 11644473600.0
    return seconds
  end
  local function _parse_datetime_local_string(s)
    if type(s) ~= "string" then return nil end
    -- Trim leading/trailing whitespace and ignore trailing junk after seconds
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    -- Accept formats like:
    --  YYYY.MM.DD HH:MM[:SS][...]
    --  YYYY-MM-DD HH:MM[:SS][...]
    --  YYYY/MM/DD HH:MM[:SS][...]
    local y, m, d, hh, mm, ss = s:match("^(%d%d%d%d)[%./-](%d%d)[%./-](%d%d)[ T]+(%d%d):(%d%d):?(%d%d?)")
    if y then
      ss = tonumber(ss) or 0
      local t = { year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = tonumber(hh), min = tonumber(mm), sec = ss, isdst = false }
      local ts = os.time(t)
      return ts
    end
    -- Try DD.MM.YYYY HH:MM[:SS]
    d, m, y, hh, mm, ss = s:match("^(%d%d)[%./-](%d%d)[%./-](%d%d%d%d)[ T]+(%d%d):(%d%d):?(%d%d?)")
    if y then
      ss = tonumber(ss) or 0
      local t = { year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = tonumber(hh), min = tonumber(mm), sec = ss, isdst = false }
      return os.time(t)
    end
    return nil
  end

  if not reaper.JS_File_Stat then
  reaper.ShowMessageBox("7R Project Browser requires the 'JS_ReaScriptAPI' extension for file mtimes. Please install it via ReaPack.", "Missing dependency", 0)
    return 0
  end
  -- Require JS_ReaScriptAPI and ensure the initial test passed
  if not state._js_stat_ok then
    dbg("os_get_file_mtime: JS_File_Stat not available or failed startup test; returning 0 for %s", path)
    return 0
  end
  local ok, retval, a, b, modifiedTime = pcall(reaper.JS_File_Stat, path)
  if not ok then
    dbg("os_get_file_mtime: JS_File_Stat threw for '%s': %s", path, tostring(retval))
    return 0
  end
  state._fastMtime = true
  -- Per JS_File_Stat API: retval == 0 indicates success
  if retval == 0 then
    -- 1) Try modifiedTime as seconds
    local m_direct = tonumber(modifiedTime)
    if m_direct and _plausible_unix(m_direct) then
      dbg("os_get_file_mtime: path='%s' unixSeconds=%s [source=modifiedTime]", path, tostring(m_direct))
      return m_direct
    end

    -- 2) If modifiedTime is a formatted local string, parse it
    local m_local = _parse_datetime_local_string(modifiedTime)
    if m_local and _plausible_unix(m_local) then
      dbg("os_get_file_mtime: path='%s' unixSeconds=%s [source=modifiedTime(local-string)]", path, tostring(m_local))
      return m_local
    end

    -- 3) If modifiedTime looks like a huge integer string (maybe FILETIME ticks), parse it
    if modifiedTime ~= nil then
      local s = tostring(modifiedTime)
      local digits = s:match("(%d+)")
      if digits then
        local n = tonumber(digits)
        if n and n > 1000000000000 then -- > 1e12 suggests FILETIME ticks
          local sec = (n / 10000000.0) - 11644473600.0
          if _plausible_unix(sec) then
            dbg("os_get_file_mtime: path='%s' unixSeconds=%s [source=modifiedTime(FILETIME-string)]", path, tostring(sec))
            return sec
          end
        end
      end
    end

    -- 4) Try combining a/b as 64-bit FILETIME (unknown order). Accept whichever is plausible.
    local an, bn = tonumber(a), tonumber(b)
    if an and bn then
      local s1 = _filetime_to_unix(an, bn)
      local s2 = _filetime_to_unix(bn, an)
      local s
      if _plausible_unix(s1) and _plausible_unix(s2) then
        -- pick the one closer to now
        local now = os.time()
        s = (math.abs(now - s1) <= math.abs(now - s2)) and s1 or s2
      elseif _plausible_unix(s1) then
        s = s1
      elseif _plausible_unix(s2) then
        s = s2
      end
      if s then
        dbg("os_get_file_mtime: path='%s' unixSeconds=%s [source=a/b as FILETIME] a=%s b=%s", path, tostring(s), tostring(a), tostring(b))
        return s
      end
    end

    -- 5) Consider 'b' as a formatted string time, too (some JS builds return it there)
    local b_local = _parse_datetime_local_string(b)
    if b_local and _plausible_unix(b_local) then
      dbg("os_get_file_mtime: path='%s' unixSeconds=%s [source=b(local-string)]", path, tostring(b_local))
      return b_local
    end

    -- 6) As last resort, allow small/old seconds if non-zero (so sort has a stable signal)
    if m_direct and m_direct > 0 then
      dbg("os_get_file_mtime: path='%s' fallbackUsingDirectSeconds=%s (NOT plausible)", path, tostring(m_direct))
      return m_direct
    end

    dbg("os_get_file_mtime: path='%s' retval=0 but usable time not found; returns: a=%s(%s) b=%s(%s) modifiedTime=%s(%s)", path, tostring(a), type(a), tostring(b), type(b), tostring(modifiedTime), type(modifiedTime))
    -- On Windows, try alternate path forms (backslashes, long-path prefix) before giving up
    if os_name:match("Win") then
      local tried = {}
      local function try_path_variant(p)
        if tried[p] then return nil end
        tried[p] = true
        local ok2, retval2, aa, bb, modifiedTime2 = pcall(reaper.JS_File_Stat, p)
        if not ok2 then
          dbg("os_get_file_mtime: JS_File_Stat threw for variant '%s': %s", p, tostring(retval2))
          return nil
        end
        if retval2 == 0 then
          -- Repeat the decoding logic for the variant
          local m2 = tonumber(modifiedTime2)
          if m2 and _plausible_unix(m2) then
            dbg("os_get_file_mtime: variant '%s' -> unixSeconds=%s [source=modifiedTime]", p, tostring(m2))
            return m2
          end
          local m2_local = _parse_datetime_local_string(modifiedTime2)
          if m2_local and _plausible_unix(m2_local) then
            dbg("os_get_file_mtime: variant '%s' -> unixSeconds=%s [source=modifiedTime(local-string)]", p, tostring(m2_local))
            return m2_local
          end
          if modifiedTime2 ~= nil then
            local s = tostring(modifiedTime2)
            local digits = s:match("(%d+)")
            if digits then
              local n = tonumber(digits)
              if n and n > 1000000000000 then
                local sec = (n / 10000000.0) - 11644473600.0
                if _plausible_unix(sec) then
                  dbg("os_get_file_mtime: variant '%s' -> unixSeconds=%s [source=modifiedTime(FILETIME-string)]", p, tostring(sec))
                  return sec
                end
              end
            end
          end
          local aa_n, bb_n = tonumber(aa), tonumber(bb)
          if aa_n and bb_n then
            local s1 = _filetime_to_unix(aa_n, bb_n)
            local s2 = _filetime_to_unix(bb_n, aa_n)
            if _plausible_unix(s1) or _plausible_unix(s2) then
              local now = os.time()
              local pick = (_plausible_unix(s1) and (not _plausible_unix(s2) or math.abs(now - s1) <= math.abs(now - s2))) and s1 or s2
              dbg("os_get_file_mtime: variant '%s' -> unixSeconds=%s [source=a/b as FILETIME]", p, tostring(pick))
              return pick
            end
          end
          -- try bb/aa as local string timestamps too
          local aa_local = _parse_datetime_local_string(aa)
          if aa_local and _plausible_unix(aa_local) then
            dbg("os_get_file_mtime: variant '%s' -> unixSeconds=%s [source=a(local-string)]", p, tostring(aa_local))
            return aa_local
          end
          local bb_local = _parse_datetime_local_string(bb)
          if bb_local and _plausible_unix(bb_local) then
            dbg("os_get_file_mtime: variant '%s' -> unixSeconds=%s [source=b(local-string)]", p, tostring(bb_local))
            return bb_local
          end
          dbg("os_get_file_mtime: variant '%s' returned retval=0 but time not usable; a=%s b=%s modifiedTime=%s", p, tostring(aa), tostring(bb), tostring(modifiedTime2))
        else
          dbg("os_get_file_mtime: variant '%s' returned retval=%s", p, tostring(retval2))
        end
        return nil
      end

      -- Variant 1: normalize slashes to backslashes
      local alt = path:gsub("/","\\")
      if alt ~= path then
        local m_alt = try_path_variant(alt)
        if m_alt then return m_alt end
      end

      -- Variant 2: long-path prefix (\\?\) for very long paths
      if #path > 260 and not path:match('^\\\\%?\\') then
        local lp = "\\\\?\\" .. path
        local m_lp = try_path_variant(lp)
        if m_lp then return m_lp end
      end
    end
    return 0
  end
  dbg("os_get_file_mtime: path='%s' stat returned non-success (retval=%s)", path, tostring(retval))
  return 0
end
local function enumerate_files(abs_path, recursive, filter_fn, respect_hidden, hidden_set)
  local results = {}

  local function scan(path)
    -- files
    local i = 0
    while true do
      local fname = reaper.EnumerateFiles(path, i)
      if not fname then break end
      local abs = join_path(path, fname)
      if not filter_fn or filter_fn(abs) then
        results[#results+1] = abs
      end
      i = i + 1
    end
    if recursive then
      -- subdirs
      local j = 0
      while true do
        local dname = reaper.EnumerateSubdirectories(path, j)
        if not dname then break end
        local subabs = join_path(path, dname)
        if not (respect_hidden and hidden_set and hidden_set[subabs]) then
          scan(subabs)
        end
        j = j + 1
      end
    end
  end

  scan(abs_path)
  table.sort(results, function(a,b) return a:lower() < b:lower() end)
  return results
end

-- Forward-declare is_rpp so it can be referenced earlier
local is_rpp

-- Helper: check if a file exists (used by load_config)
local function file_exists(path)
  if not path or path == "" then return false end
  local f = io.open(path, "r")
  if f then f:close(); return true end
  return false
end

-- Enumerate immediate subdirectory names (not full paths), sorted
local function enumerate_subdirs(abs_path)
  local t = {}
  local i = 0
  while true do
    local d = reaper.EnumerateSubdirectories(abs_path, i)
    if not d then break end
    t[#t+1] = d
    i = i + 1
  end
  table.sort(t, function(a,b) return a:lower() < b:lower() end)
  return t
end

-- Return true if a directory has any files or subdirectories
local function dir_has_anything(abs_path)
  if not abs_path or abs_path == "" then return false end
  local subs = enumerate_subdirs(abs_path)
  if #subs > 0 then return true end
  local i = 0
  while true do
    local f = reaper.EnumerateFiles(abs_path, i)
    if not f then break end
    return true
  end
  return false
end

local function enqueue_mtime(path)
  if not path or state._mtimeCache[path] ~= nil or state._mtimeQueuedSet[path] then return end
  state._mtimeQueuedSet[path] = true
  table.insert(state._mtimeQueue, path)
end

local function ensure_mtime_for_paths(paths)
  for i = 1, #paths do enqueue_mtime(paths[i]) end
end

local function process_mtime_queue(max_items)
  max_items = max_items or 24
  local processed = 0
  while processed < max_items and #state._mtimeQueue > 0 do
    local path = table.remove(state._mtimeQueue, 1)
    local mtime = os_get_file_mtime(path)
    state._mtimeCache[path] = tonumber(mtime) or 0
    state._mtimeQueuedSet[path] = nil
    processed = processed + 1
  end
end

-- Prefetch: enqueue all .rpp files for the selected folder (respects settings)
local function enqueue_selected_folder_mtimes()
  if not state.selectedFolder or state.selectedFolder == "" then return end
  local files = enumerate_files(state.selectedFolder, state.includeSubfolders, is_rpp, true, state.hiddenPaths)
  if #files == 0 then return end
  ensure_mtime_for_paths(files)
end

local function is_rpp(path)
  local ext = path:match("%.([^.]*)$")
  if not ext then return false end
  ext = ext:lower()
  return ext == "rpp"
end

local function ensure_dir(path)
  -- Creates if missing; returns true on success or if already exists.
  local ok = reaper.RecursiveCreateDirectory(path, 0)
  -- ok is number created; if 0 and dir exists, fine.
  return ok ~= nil
end

-- --------------- Config --------------- 

local function get_config_dir()
  local dir = join_path(reaper.GetResourcePath(), join_path("Scripts", "ProjectFolderBrowser"))
  ensure_dir(dir)
  return dir
end

local function config_path()
  return join_path(get_config_dir(), "config.ini")
end

local function save_config(cfg)
  local p = config_path()
  local f, err = io.open(p, "w")
  if not f then return false, err end

  -- Flatten sets
  local function join_set(set)
    local t = {}
    for k, v in pairs(set or {}) do
      if v then t[#t+1] = k end
    end
    table.sort(t)
    return table.concat(t, "|")
  end

  f:write("masterPath=", cfg.masterPath or "", "\n")
  f:write("hideMaster=", cfg.hideMaster and "true" or "false", "\n")
  f:write("includeTop=", join_set(cfg.includeTop), "\n")
  f:write("hiddenPaths=", join_set(cfg.hiddenPaths), "\n")
  f:write("includeSubfolders=", cfg.includeSubfolders and "true" or "false", "\n")
  f:write("searchAllFolders=", cfg.searchAllFolders and "true" or "false", "\n")
  f:write("sortMode=", cfg.sortMode or "name", "\n")
  f:write("winX=", tostring(cfg.winX or ""), "\n")
  f:write("winY=", tostring(cfg.winY or ""), "\n")
  f:write("winW=", tostring(cfg.winW or ""), "\n")
  f:write("winH=", tostring(cfg.winH or ""), "\n")
  f:close()
  return true
end

local function load_config()
  local cfg = {
    masterPath = "",
    hideMaster = true,
    includeTop = {},   -- set of absolute paths of top-level subfolders to include
    hiddenPaths = {},  -- set of absolute paths to hide anywhere in the tree
    includeSubfolders = true,
    sortMode = "name",
    winX = nil, winY = nil, winW = nil, winH = nil,
  }
  local p = config_path()
  if not file_exists(p) then return cfg end

  for line in io.lines(p) do
    local k, v = line:match("^([^=]+)=(.*)$")
    if k and v ~= nil then
      if k == "masterPath" then
        cfg.masterPath = normalize_path(v)
      elseif k == "hideMaster" then
        cfg.hideMaster = (v == "true")
      elseif k == "includeTop" then
        cfg.includeTop = {}
        for item in v:gmatch("([^|]+)") do cfg.includeTop[item] = true end
      elseif k == "hiddenPaths" then
        cfg.hiddenPaths = {}
        for item in v:gmatch("([^|]+)") do cfg.hiddenPaths[item] = true end
      elseif k == "includeSubfolders" then
        cfg.includeSubfolders = (v == "true")
      elseif k == "searchAllFolders" then
        cfg.searchAllFolders = (v == "true")
      elseif k == "sortMode" then
        cfg.sortMode = v
      elseif k == "winX" then
        cfg.winX = tonumber(v)
      elseif k == "winY" then
        cfg.winY = tonumber(v)
      elseif k == "winW" then
        cfg.winW = tonumber(v)
      elseif k == "winH" then
        cfg.winH = tonumber(v)
      end
    end
  end
  return cfg
end

-- --------------- Folder Picker --------------- 

local function browse_for_folder(title, initial)
  initial = initial or ""
  if reaper.JS_Dialog_BrowseForFolder then
    -- Be robust: JS_Dialog_BrowseForFolder may return (retval, path) or just (path)
    local ok, a, b = pcall(reaper.JS_Dialog_BrowseForFolder, title, initial)
    if ok then
      local path = nil
      if type(a) == "string" then
        path = a
      elseif type(b) == "string" then
        path = b
      end
      if path and path ~= "" then
        return normalize_path(path)
      end
    end
  end
  -- Fallback: manual input
  local ok, ret = reaper.GetUserInputs(title .. " (type/paste full path)", 1, "Folder path,extrawidth=200", initial)
  if ok and ret and ret ~= "" then
    return normalize_path(ret)
  end
  return nil
end

-- --------------- State --------------- 

state = load_config()
state.selectedFolder = state.selectedFolder or ""
state.includeSubfolders = (state.includeSubfolders ~= nil) and state.includeSubfolders or true -- Right-pane toggle for recursive listing
state.sortMode = state.sortMode or "date_desc"
state.searchAllFolders = state.searchAllFolders or false
state.searchQuery = state.searchQuery or ""
state._topLevelCache = {}      -- cache of names for master top-level
state._lastScannedMaster = nil
state.showSettings = state.showSettings or false
state._mtimeCache = state._mtimeCache or {}
state._mtimeQueue = state._mtimeQueue or {}
state._mtimeQueuedSet = state._mtimeQueuedSet or {}
state._mtimeBurst = state._mtimeBurst or false
state._fastMtime = (reaper.JS_File_Stat ~= nil) or state._fastMtime
state.debugEnabled = state.debugEnabled or false
state._debugLogs = state._debugLogs or {}
state._searchFocusPending = (state._searchFocusPending == nil) and true or state._searchFocusPending
-- Persisted per-session expansion states for normal (non-search) tree view
state.expandedFolders = state.expandedFolders or {}
-- Cache for search -> set of directories that contain matches (by file or folder name)
state._searchMatchCache = state._searchMatchCache or { root = nil, q = nil, dirs = nil }

-- --------------- ReaImGui setup --------------- 

if not reaper.ImGui_CreateContext then
  reaper.ShowMessageBox("This script requires the ReaImGui extension.\n\nPlease install 'ReaImGui: Dear ImGui for REAPER' via ReaPack, then try again.", "7R Project Browser", 0)
  return
end

local imgui_flags = reaper.ImGui_ConfigFlags_DockingEnable and reaper.ImGui_ConfigFlags_DockingEnable() or 0
local ctx = reaper.ImGui_CreateContext('7R Project Browser', imgui_flags)

-- Diagnostic: test JS_File_Stat once and record result
state._js_stat_ok = false
local function test_js_filestat()
  if not reaper.JS_File_Stat then
    dbg("test_js_filestat: JS_File_Stat not present")
  reaper.ShowMessageBox("JS_ReaScriptAPI (JS_File_Stat) is not installed. 7R Project Browser requires it for mtime checks.", "Missing JS_ReaScriptAPI", 0)
    state._js_stat_ok = false
    return
  end
  -- Use a file that should exist in the REAPER resource path for a reliable test
  local test_path = join_path(reaper.GetResourcePath(), "reaper.ini")
  local ok, retval, a, b, modifiedTime = pcall(reaper.JS_File_Stat, test_path)
  if not ok then
    dbg("test_js_filestat: JS_File_Stat threw: %s", tostring(retval))
    reaper.ShowMessageBox("JS_ReaScriptAPI: JS_File_Stat threw an error: " .. tostring(retval), "JS error", 0)
    state._js_stat_ok = false
    return
  end
  dbg("test_js_filestat: test_path=%s retval=%s(%s) modifiedTime=%s(%s)", tostring(test_path), tostring(retval), type(retval), tostring(modifiedTime), type(modifiedTime))
  if retval == 0 then
    state._js_stat_ok = true
  else
    -- JS_File_Stat returned non-success for a file that should exist. Likely a broken JS installation.
    state._js_stat_ok = false
    reaper.ShowMessageBox("JS_ReaScriptAPI is installed but JS_File_Stat returned non-success for a known file (reaper.ini).\nPlease reinstall JS_ReaScriptAPI via ReaPack and restart REAPER.", "JS_File_Stat test failed", 0)
  end
end
test_js_filestat()

-- --------------- UI Helpers --------------- 

local function _hash_id(s)
  local h = 0
  for i = 1, #s do
    h = (h * 31 + s:byte(i)) % 2147483647
  end
  return tostring(h)
end

local function label_with_id(label, id)
  label = label or ""
  local id_str = id and _hash_id(tostring(id)) or "0"
  if label == "" then label = "(folder)" end
  return string.format("%s##%s", label, id_str)
end

-- Lightweight debug logger (keeps last N entries)
dbg = function(fmt, ...)
  if not state then return end
  if not state.debugEnabled then return end
  local msg
  if select('#', ...) > 0 then
    msg = string.format(fmt, ...)
  else
    msg = tostring(fmt)
  end
  local ts = os.date("%H:%M:%S")
  state._debugLogs[#state._debugLogs + 1] = ts .. " " .. msg
  if #state._debugLogs > 200 then table.remove(state._debugLogs, 1) end
end

local function safe_TreeNodeEx(ctx, label, flags)
  -- Use the simplest variant to keep labels correct across bindings.
  return reaper.ImGui_TreeNode(ctx, label)
end

-- Convert RGBA floats (0-1) to ImGui U32 color
local function col32(r, g, b, a)
  return reaper.ImGui_ColorConvertDouble4ToU32(r, g, b, a or 1)
end

local function refresh_top_level_cache()
  local master = state.masterPath
  if master ~= state._lastScannedMaster and master and master ~= "" and dir_has_anything(master) then
    state._topLevelCache = enumerate_subdirs(master)
    state._lastScannedMaster = master
  end
end

local function render_top_level_selector()
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Text(ctx, "Top-level folders to include:")
  reaper.ImGui_SameLine(ctx) ; if reaper.ImGui_SmallButton(ctx, "Select All") then
    refresh_top_level_cache()
    for _, name in ipairs(state._topLevelCache) do
      state.includeTop[join_path(state.masterPath, name)] = true
    end
    save_config(state)
  end
  reaper.ImGui_SameLine(ctx) ; if reaper.ImGui_SmallButton(ctx, "Clear All") then
    state.includeTop = {}
    save_config(state)
  end

  refresh_top_level_cache()
  if #state._topLevelCache == 0 then
    reaper.ImGui_TextColored(ctx, col32(0.8, 0.6, 0.2, 1), "(No subfolders found or master not set)")
    return
  end

  reaper.ImGui_BeginChild(ctx, "topSel", 0, 120, (reaper.ImGui_ChildFlags_Border and reaper.ImGui_ChildFlags_Border() or 0), 0)
  for _, name in ipairs(state._topLevelCache) do
    local abs = join_path(state.masterPath, name)
    local checked = state.includeTop[abs] or false
    local changed, v = reaper.ImGui_Checkbox(ctx, label_with_id(name, abs), checked)
    if changed then
      state.includeTop[abs] = v or nil
      save_config(state)
    end
  end
  reaper.ImGui_EndChild(ctx)
end

-- Visibility Manager (Settings): hide/unhide any folder in a tree
local function render_visibility_node(abs_path)
  local name = abs_path:match("([^/\\]+)$") or abs_path
  reaper.ImGui_PushID(ctx, abs_path)
    local opened = reaper.ImGui_TreeNode(ctx, name)
  reaper.ImGui_SameLine(ctx)
  local hidden = state.hiddenPaths[abs_path] and true or false
  local changed, v = reaper.ImGui_Checkbox(ctx, "Hidden", hidden)
  if changed then
    if v then state.hiddenPaths[abs_path] = true else state.hiddenPaths[abs_path] = nil end
    state._searchMatchCache = { root = nil, q = nil, dirs = nil }
    save_config(state)
  end
  if opened then
    local subs = enumerate_subdirs(abs_path)
    for _, child in ipairs(subs) do
      render_visibility_node(join_path(abs_path, child))
    end
    reaper.ImGui_TreePop(ctx)
  end
  reaper.ImGui_PopID(ctx)
end

local function render_visibility_manager()
  if not state.masterPath or state.masterPath == "" then
    reaper.ImGui_TextColored(ctx, col32(0.8, 0.6, 0.2, 1), "(Set Master folder to manage visibility)")
    return
  end
  reaper.ImGui_Text(ctx, "Folder visibility (hide/unhide):")
  reaper.ImGui_BeginChild(ctx, "vismgr", 0, 200, (reaper.ImGui_ChildFlags_Border and reaper.ImGui_ChildFlags_Border() or 0), 0)
    if state.hideMaster then
      refresh_top_level_cache()
      for _, name in ipairs(state._topLevelCache) do
        render_visibility_node(join_path(state.masterPath, name))
      end
    else
      render_visibility_node(state.masterPath)
    end
  reaper.ImGui_EndChild(ctx)
  if reaper.ImGui_Button(ctx, "Unhide All") then
    state.hiddenPaths = {}
    save_config(state)
  end
end

-- Build an expansion set for the folder tree based on current search query
-- (auto expand/collapse helpers removed per user request)
-- Search helpers: compute directories to auto-open when searching
local function _folder_contains_match(abs_path, q_lower)
  -- Folder name match
  local base = abs_path:match("([^/\\]+)$") or abs_path
  if base:lower():find(q_lower, 1, true) then return true end
  -- Any .rpp inside (non-recursive) that matches? quick check of file names
  local i = 0
  while true do
    local f = reaper.EnumerateFiles(abs_path, i)
    if not f then break end
    if f:lower():find(q_lower, 1, true) and f:lower():match("%.rpp$") then return true end
    i = i + 1
  end
  -- Any subdir name match triggers
  local j = 0
  while true do
    local d = reaper.EnumerateSubdirectories(abs_path, j)
    if not d then break end
    if d:lower():find(q_lower, 1, true) then return true end
    j = j + 1
  end
  return false
end

local function _compute_search_dirs(root, q)
  q = (q or ""):lower()
  if q == "" or not root or root == "" then return nil end
  local cache = state._searchMatchCache
  if cache and cache.root == root and cache.q == q and cache.dirs then
    return cache.dirs
  end
  local dirs = {}
  local function mark_chain(path)
    local p = path
    while p and p ~= "" do
      dirs[p] = true
      local parent = p:match("(.+)[\\/][^\\/]+$")
      if not parent or parent == p then break end
      p = parent
    end
  end
  local function walk(dir)
    if state.hiddenPaths[dir] then return end
    if _folder_contains_match(dir, q) then
      mark_chain(dir)
    end
    -- dive
    local i = 0
    while true do
      local sub = reaper.EnumerateSubdirectories(dir, i)
      if not sub then break end
      local subabs = join_path(dir, sub)
      if not state.hiddenPaths[subabs] then walk(subabs) end
      i = i + 1
    end
  end
  walk(root)
  state._searchMatchCache = { root = root, q = q, dirs = dirs }
  return dirs
end

-- Unified node renderer supporting two modes:
--  - search mode (q != ""): auto-open nodes that are on paths with matches, without persisting expansion
--  - normal mode: respect and persist expansion in state.expandedFolders
local function render_folder_node2(abs_path, display_name, search_dirs)
  if state.hiddenPaths[abs_path] then return end
  if search_dirs and not search_dirs[abs_path] then return end
  local subdirs = enumerate_subdirs(abs_path)
  local vis = display_name and tostring(display_name) or (abs_path:match("([^/\\]+)$") or abs_path)

  reaper.ImGui_PushID(ctx, search_dirs and (abs_path .. "::s") or (abs_path .. "::n"))
  if search_dirs then
    -- Auto-open only if this dir or a descendant is a match
    local should_open = search_dirs[abs_path] and true or false
    if should_open then reaper.ImGui_SetNextItemOpen(ctx, true) end
    local opened = reaper.ImGui_TreeNode(ctx, vis)
    -- Selection on click
    if reaper.ImGui_IsItemClicked(ctx, 0) then
      state.selectedFolder = abs_path
    end
    if opened then
      for _, child in ipairs(subdirs) do
        render_folder_node2(join_path(abs_path, child), child, search_dirs)
      end
      reaper.ImGui_TreePop(ctx)
    end
  else
    -- Normal mode: persist expansion in state
    local open_state = state.expandedFolders[abs_path] and true or false
    if open_state then reaper.ImGui_SetNextItemOpen(ctx, true) end
    local opened = reaper.ImGui_TreeNode(ctx, vis)
    if reaper.ImGui_IsItemClicked(ctx, 0) then
      state.selectedFolder = abs_path
    end
    if opened ~= open_state then
      state.expandedFolders[abs_path] = opened or nil
    end
    if opened then
      for _, child in ipairs(subdirs) do
        render_folder_node2(join_path(abs_path, child), child, nil)
      end
      reaper.ImGui_TreePop(ctx)
    end
  end
  reaper.ImGui_PopID(ctx)

  -- Context menu
  if reaper.ImGui_BeginPopupContextItem(ctx) then
    if not state.hiddenPaths[abs_path] then
      if reaper.ImGui_MenuItem(ctx, "Hide this folder") then state.hiddenPaths[abs_path] = true; state._searchMatchCache = { root = nil, q = nil, dirs = nil }; save_config(state) end
    else
      if reaper.ImGui_MenuItem(ctx, "Unhide this folder") then state.hiddenPaths[abs_path] = nil; state._searchMatchCache = { root = nil, q = nil, dirs = nil }; save_config(state) end
    end
    if reaper.ImGui_MenuItem(ctx, "Set as Selected") then state.selectedFolder = abs_path end
    reaper.ImGui_EndPopup(ctx)
  end
end

local function render_tree()
  if not state.masterPath or state.masterPath == "" then
    reaper.ImGui_TextWrapped(ctx, "Pick a Master folder to begin, then browse folders on the left.")
    return
  end
  refresh_top_level_cache()
  local q = (state.searchQuery or "")
  local search_active = q ~= ""
  local root_for_search = state.hideMaster and state.masterPath or state.masterPath
  local search_dirs = search_active and _compute_search_dirs(root_for_search, q) or nil
  if state.hideMaster then
    -- Render all visible top-level folders as roots
    local any = false
    for _, name in ipairs(state._topLevelCache) do
      local top_abs = join_path(state.masterPath, name)
  if not state.hiddenPaths[top_abs] and (not search_dirs or search_dirs[top_abs]) then
        any = true
    render_folder_node2(top_abs, name, search_dirs)
      end
    end
    if not any then
      reaper.ImGui_TextColored(ctx, col32(0.8, 0.6, 0.2, 1), "(No visible folders found)")
    end
  else
    -- Master visible as root; inside, show all visible top-levels
  -- Root node
  if search_dirs and search_dirs[state.masterPath] then reaper.ImGui_SetNextItemOpen(ctx, true) end
  local opened = reaper.ImGui_TreeNode(ctx, state.masterPath)
    if reaper.ImGui_IsItemClicked(ctx, 0) then
      state.selectedFolder = state.masterPath
    end
  if opened then
      for _, name in ipairs(state._topLevelCache) do
        local top_abs = join_path(state.masterPath, name)
        if not state.hiddenPaths[top_abs] then
      render_folder_node2(top_abs, name, search_dirs)
        end
      end
      reaper.ImGui_TreePop(ctx)
    end
  -- no extra ID stack operations
  end
end

-- After rendering tree, clear one-shot collapse flag
-- no post-render behavior

local function open_project(path, in_new_tab)
  if in_new_tab then
    -- New project tab
    reaper.Main_OnCommand(40859, 0) -- File: New project tab
  end
  reaper.Main_openProject(path)
end

local function reveal_in_file_manager(path)
  if not path or path == "" then return end
  local dir = path:match("(.+)[\\/][^\\/]*$") or path

  -- Prefer SWS CF_ShellExecute when available (same method used by ReaLauncher)
  local has_sws = (reaper.CF_ShellExecute ~= nil) or (reaper.APIExists and reaper.APIExists("CF_ShellExecute"))
  if has_sws then
    -- CF_ShellExecute opens the target with the OS file manager; use the directory for a stable reveal
    local target = dir
    -- On macOS CF_ShellExecute works fine with either file or dir; choose dir for consistency
    reaper.CF_ShellExecute(target)
    return
  end

  -- Fallbacks without SWS
  if os_name:match("Win") then
    -- Use Explorer with /select to highlight the file
    local cmd = string.format('explorer.exe /select,"%s"', path:gsub("/", "\\"))
    if reaper.ShellExecute then reaper.ShellExecute(cmd) else os.execute(cmd) end
  elseif os_name:match("OSX") or os_name:match("mac") then
    -- macOS reveal
    local cmd = string.format('open -R "%s"', path)
    if reaper.ShellExecute then reaper.ShellExecute(cmd) else os.execute(cmd) end
  else
    -- Linux: open containing folder
    local cmd = string.format('xdg-open "%s"', dir)
    if reaper.ShellExecute then reaper.ShellExecute(cmd) else os.execute(cmd) end
  end
end

local function render_right_pane()
  local q = state.searchQuery or ""
  local search_active = q ~= ""
  -- Only search across all folders when a query is active; otherwise respect selected folder
  local show_all_scope = (search_active and (state.searchAllFolders or false)) and (state.masterPath and state.masterPath ~= "")
  if (not state.selectedFolder or state.selectedFolder == "") and not show_all_scope then
    reaper.ImGui_TextWrapped(ctx, "Select a folder from the tree to view its projects.")
    return
  end

  reaper.ImGui_Text(ctx, "Folder:")
  reaper.ImGui_SameLine(ctx)
  local folderLabel = show_all_scope and ("All folders under " .. state.masterPath) or (state.selectedFolder or "")
  reaper.ImGui_TextColored(ctx, col32(0.7, 0.9, 1.0, 1.0), folderLabel)

  reaper.ImGui_Separator(ctx)

  local function _fmt_local_time(sec)
    sec = tonumber(sec)
    if not sec or sec <= 0 then return "n/a" end
    return os.date("%Y-%m-%d %H:%M:%S", sec)
  end

  -- Build candidate file list based on search scope
  local files
  if show_all_scope then
    files = enumerate_files(state.masterPath, true, is_rpp, true, state.hiddenPaths)
  else
    files = enumerate_files(state.selectedFolder, state.includeSubfolders, is_rpp, true, state.hiddenPaths)
  end
  if #files == 0 then
    reaper.ImGui_TextColored(ctx, col32(0.8, 0.6, 0.2, 1), "(No .rpp projects found)")
    return
  end

  -- Build items with optional filtering by search query (matches name or parent folder name)
  local items = {}
  local q = (state.searchQuery or ""):lower()
  local q_active = q ~= ""
  for _, p in ipairs(files) do
    local name = (p:match("([^/\\]+)$") or p)
    if q_active then
      local parent = p:match("(.+)[\\/][^\\/]+$") or ""
      local folderName = parent:match("([^/\\]+)$") or parent
      local hay_name = name:lower()
      local hay_folder = folderName:lower()
      if hay_name:find(q, 1, true) or hay_folder:find(q, 1, true) then
        items[#items+1] = { path = p, name = name }
      end
    else
      items[#items+1] = { path = p, name = name }
    end
  end
  if q_active and #items == 0 then
    reaper.ImGui_TextColored(ctx, col32(0.8, 0.6, 0.2, 1), "(No matches for search)")
    return
  end

  local mode = state.sortMode or "date_desc"

  -- Compute mtimes if sorting by date (always fetch fresh, no caching)
  if mode == "date_asc" or mode == "date_desc" then
    for _, it in ipairs(items) do
      it.mtime = os_get_file_mtime(it.path) or 0
      dbg("prepare_item: name='%s' path='%s' mtime=%s local='%s'", it.name, it.path, tostring(it.mtime), _fmt_local_time(it.mtime))
    end
  end

  -- Snapshot list before sort for debug dumping (as enumerated)
  local pre_sort_snapshot = nil
  if state.debugEnabled and (mode == "date_asc" or mode == "date_desc") then
    pre_sort_snapshot = {}
    for i = 1, #items do
      local it = items[i]
      pre_sort_snapshot[i] = { name = it.name, path = it.path, mtime = it.mtime }
    end
  end

  if mode == "date_desc" then
    table.sort(items, function(a,b) 
      if a.mtime ~= b.mtime then return a.mtime > b.mtime end
      return a.name:lower() < b.name:lower()
    end)
  elseif mode == "date_asc" then
    table.sort(items, function(a,b) 
      if a.mtime ~= b.mtime then return a.mtime < b.mtime end
      return a.name:lower() < b.name:lower()
    end)
  else -- "name"
    table.sort(items, function(a,b)
      return a.name:lower() < b.name:lower()
    end)
  end

  -- Debug UI: allow one-click dump of detected and sorted mtimes
  local do_dump = false
  local do_dump_raw = false
  if state.debugEnabled and (mode == "date_asc" or mode == "date_desc") then
    if reaper.ImGui_SmallButton(ctx, "Debug: Dump mtimes") then
      do_dump = true
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_SmallButton(ctx, "Debug: Dump raw stat") then
      do_dump_raw = true
    end
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_TextDisabled(ctx, "(logs to Settings > debug pane; capped)")
  end

  if do_dump and pre_sort_snapshot then
    dbg("---- MTIME DEBUG: folder='%s' includeSub=%s sort=%s files=%d ----", state.selectedFolder, tostring(state.includeSubfolders), mode, #pre_sort_snapshot)
    dbg("Detected mtimes (as enumerated):")
    for i = 1, #pre_sort_snapshot do
      local it = pre_sort_snapshot[i]
      local flag = (tonumber(it.mtime) or 0) == 0 and " !" or ""
      dbg(string.format("[%02d] mtime=%s local=%s%s | name=%s | path=%s",
        i,
        tostring(it.mtime),
        _fmt_local_time(it.mtime),
        flag,
        it.name,
        it.path
      ))
    end
    dbg("Sorted order (%s):", mode)
    for i = 1, #items do
      local it = items[i]
      local flag = (tonumber(it.mtime) or 0) == 0 and " !" or ""
      dbg(string.format("(%02d) mtime=%s local=%s%s | name=%s | path=%s",
        i,
        tostring(it.mtime),
        _fmt_local_time(it.mtime),
        flag,
        it.name,
        it.path
      ))
    end
    dbg("---- END MTIME DEBUG ----")
  end

  if do_dump_raw then
    local cap = 60
    local n = math.min(#items, cap)
    dbg("---- RAW JS_File_Stat DEBUG: folder='%s' items=%d (showing %d) sort=%s ----", state.selectedFolder, #items, n, mode)
    for i = 1, n do
      local it = items[i]
      local ok, retval, a, b, modifiedTime = pcall(reaper.JS_File_Stat, it.path)
      local parsed = tonumber(modifiedTime) or tonumber(a) or tonumber(b)
      local parsed_local = _fmt_local_time(parsed)
      dbg("stat[%02d]: name='%s'\n  path='%s'\n  ok=%s retval=%s(%s)\n  a=%s(%s) b=%s(%s) modifiedTime=%s(%s)\n  parsed=%s local=%s",
        i,
        it.name,
        it.path,
        tostring(ok), tostring(retval), type(retval),
        tostring(a), type(a), tostring(b), type(b), tostring(modifiedTime), type(modifiedTime),
        tostring(parsed), parsed_local
      )

      if os_name:match("Win") then
        local alt = it.path:gsub("/","\\")
        if alt ~= it.path then
          local ok2, rv2, aa, bb, mt2 = pcall(reaper.JS_File_Stat, alt)
          local parsed2 = tonumber(mt2) or tonumber(aa) or tonumber(bb)
          dbg("  alt-bslash: ok=%s retval=%s a=%s b=%s modifiedTime=%s parsed=%s local=%s",
            tostring(ok2), tostring(rv2), tostring(aa), tostring(bb), tostring(mt2), tostring(parsed2), _fmt_local_time(parsed2))
        end
        if #it.path > 260 and not it.path:match('^\\\\%?\\') then
          local lp = "\\\\?\\" .. it.path
          local ok3, rv3, aaa, bbb, mt3 = pcall(reaper.JS_File_Stat, lp)
          local parsed3 = tonumber(mt3) or tonumber(aaa) or tonumber(bbb)
          dbg("  alt-long: ok=%s retval=%s a=%s b=%s modifiedTime=%s parsed=%s local=%s",
            tostring(ok3), tostring(rv3), tostring(aaa), tostring(bbb), tostring(mt3), tostring(parsed3), _fmt_local_time(parsed3))
        end
      end
    end
    if #items > cap then
      dbg("(truncated raw dump: %d more items omitted)", #items - cap)
    end
    dbg("---- END RAW JS_File_Stat DEBUG ----")
  end

  reaper.ImGui_BeginChild(ctx, "files", 0, 0, (reaper.ImGui_ChildFlags_Border and reaper.ImGui_ChildFlags_Border() or 0), 0)
  for _, it in ipairs(items) do
    local p = it.path
    local fname = it.name
    if reaper.ImGui_Selectable(ctx, fname, false) then
      -- Single-click does nothing special
    end
    if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
      open_project(p, false)
    end

    if reaper.ImGui_BeginPopupContextItem(ctx, "file_ctx_" .. p) then
      if reaper.ImGui_MenuItem(ctx, "Open") then open_project(p, false) end
      if reaper.ImGui_MenuItem(ctx, "Open in New Tab") then open_project(p, true) end
      if reaper.ImGui_MenuItem(ctx, "Reveal in Explorer/Finder") then reveal_in_file_manager(p) end
      reaper.ImGui_EndPopup(ctx)
    end
  end
  reaper.ImGui_EndChild(ctx)
end

-- --------------- Main Window --------------- 

local function render_menu_bar()
  if reaper.ImGui_BeginMenuBar(ctx) then
    if reaper.ImGui_BeginMenu(ctx, "File") then
      if reaper.ImGui_MenuItem(ctx, "Save Settings") then
        save_config(state)
      end
      if reaper.ImGui_MenuItem(ctx, "Reload Settings") then
        local loaded = load_config()
        -- Keep selectedFolder and includeSubfolders session-local
        state.masterPath = loaded.masterPath
        state.hideMaster = loaded.hideMaster
        state.includeTop = loaded.includeTop
        state.hiddenPaths = loaded.hiddenPaths
        state._lastScannedMaster = nil
        refresh_top_level_cache()
      end
      reaper.ImGui_EndMenu(ctx)
    end
    if reaper.ImGui_BeginMenu(ctx, "Help") then
      reaper.ImGui_TextWrapped(ctx, "Usage:\n- Pick Master folder.\n- Select top-level folders to include (multi-select).\n- Browse tree on left.\n- Projects appear on the right; double-click to open, or use context menu/buttons.\n- Right-click folders to hide/unhide.")
      reaper.ImGui_EndMenu(ctx)
    end
    reaper.ImGui_EndMenuBar(ctx)
  end
end

local function render_master_controls()
  reaper.ImGui_Text(ctx, "Master folder:")
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_TextColored(ctx, col32(0.9, 0.9, 0.9, 1), state.masterPath ~= "" and state.masterPath or "(not set)")
  reaper.ImGui_SameLine(ctx)

  if reaper.ImGui_SmallButton(ctx, "Pick...") then
    local picked = browse_for_folder("Pick Master Folder", state.masterPath)
    if picked and picked ~= "" then
      state.masterPath = picked
      state._lastScannedMaster = nil
      refresh_top_level_cache()
      save_config(state)
    end
  end

  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_SmallButton(ctx, "Clear") then
    state.masterPath = ""
    state.includeTop = {}
    state._topLevelCache = {}
    state._lastScannedMaster = nil
    save_config(state)
  end

  local changed, v = reaper.ImGui_Checkbox(ctx, "Hide master in tree", state.hideMaster)
  if changed then
    state.hideMaster = v
    save_config(state)
  end
end

local function render_settings_window()
  reaper.ImGui_SetNextWindowSize(ctx, 600, 600, reaper.ImGui_Cond_FirstUseEver())
  local visible, open = reaper.ImGui_Begin(ctx, '7R Project Browser - Settings', true)
  if visible then
    render_master_controls()
    reaper.ImGui_Separator(ctx)

    local changed, v = reaper.ImGui_Checkbox(ctx, "Include subfolders (right pane)", state.includeSubfolders)
    if changed then state.includeSubfolders = v end

    local changedAll, vAll = reaper.ImGui_Checkbox(ctx, "Search across all folders (ignore current selection)", state.searchAllFolders or false)
    if changedAll then
      state.searchAllFolders = vAll and true or false
      save_config(state)
    end

    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Text(ctx, "Project list sorting:")
    local current = state.sortMode or "date_desc"
    local current_label = (current == "name") and "Name (A-Z)"
        or (current == "date_asc") and "Date modified (oldest first)"
        or "Date modified (latest first)"
    if reaper.ImGui_BeginCombo(ctx, "Sort by", current_label) then
      if reaper.ImGui_Selectable(ctx, "Name (A-Z)", current == "name") then state.sortMode = "name" end
      if reaper.ImGui_Selectable(ctx, "Date modified (oldest first)", current == "date_asc") then state.sortMode = "date_asc" end
      if reaper.ImGui_Selectable(ctx, "Date modified (latest first)", current == "date_desc") then state.sortMode = "date_desc" end
      reaper.ImGui_EndCombo(ctx)
    end

    reaper.ImGui_Separator(ctx)
    render_visibility_manager()

    reaper.ImGui_Separator(ctx)
    -- Debug controls
    local changed_dbg, dbg_v = reaper.ImGui_Checkbox(ctx, "Enable debug logs", state.debugEnabled)
    if changed_dbg then state.debugEnabled = dbg_v end
    if state.debugEnabled then
      reaper.ImGui_Text(ctx, "Recent debug logs:")
      reaper.ImGui_BeginChild(ctx, "debug_logs", 0, 150, (reaper.ImGui_ChildFlags_Border and reaper.ImGui_ChildFlags_Border() or 0), 0)
      for i = math.max(1, #state._debugLogs - 199), #state._debugLogs do
        reaper.ImGui_TextWrapped(ctx, state._debugLogs[i])
      end
      reaper.ImGui_EndChild(ctx)
    end
    if reaper.ImGui_Button(ctx, "Save Settings") then
      save_config(state)
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Reload Settings") then
      local loaded = load_config()
      -- Keep selectedFolder and includeSubfolders session-local
      state.masterPath = loaded.masterPath
      state.hideMaster = loaded.hideMaster
      state.includeTop = loaded.includeTop
      state.hiddenPaths = loaded.hiddenPaths
      state.includeSubfolders = loaded.includeSubfolders
      state.sortMode = loaded.sortMode or state.sortMode
      state._lastScannedMaster = nil
      refresh_top_level_cache()
    end
  end
  reaper.ImGui_End(ctx)
  if not open then state.showSettings = false end
end

local function main_loop()
  reaper.ImGui_SetNextWindowPos(ctx, state.winX or 100, state.winY or 100, reaper.ImGui_Cond_FirstUseEver())
  reaper.ImGui_SetNextWindowSize(ctx, state.winW or 1000, state.winH or 600, reaper.ImGui_Cond_FirstUseEver())
  local visible, open = reaper.ImGui_Begin(ctx, '7R Project Browser', true)
  if visible then
    if reaper.ImGui_Button(ctx, "Settings") then state.showSettings = true end
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_Text(ctx, "Search:")
    reaper.ImGui_SameLine(ctx)
    if state._searchFocusPending and reaper.ImGui_SetKeyboardFocusHere then
      reaper.ImGui_SetKeyboardFocusHere(ctx)
      state._searchFocusPending = false
    end
    local q_changed, q_val = reaper.ImGui_InputText(ctx, "##global_search", state.searchQuery or "")
    if q_changed then
      state.searchQuery = q_val or ""
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_SmallButton(ctx, "Clear") then
  state.searchQuery = ""
  -- keep focus in the search box for quick typing
  state._searchFocusPending = true
    end
    reaper.ImGui_Separator(ctx)

    -- Two-pane layout
    local left_width = 340
    reaper.ImGui_BeginChild(ctx, "left", left_width, 0, (reaper.ImGui_ChildFlags_Border and reaper.ImGui_ChildFlags_Border() or 0), 0)
      reaper.ImGui_Text(ctx, "Folders")
      reaper.ImGui_BeginChild(ctx, "tree", 0, 0, (reaper.ImGui_ChildFlags_Border and reaper.ImGui_ChildFlags_Border() or 0), 0)
  render_tree()
      reaper.ImGui_EndChild(ctx)
    reaper.ImGui_EndChild(ctx)

    reaper.ImGui_SameLine(ctx)

    reaper.ImGui_BeginChild(ctx, "right", 0, 0, (reaper.ImGui_ChildFlags_Border and reaper.ImGui_ChildFlags_Border() or 0), 0)
      render_right_pane()
    reaper.ImGui_EndChild(ctx)

    if state.showSettings then
      render_settings_window()
    end

  -- mtime cache/queue disabled: always computed on-demand per item

    -- Capture current window position/size
    if reaper.ImGui_GetWindowPos and reaper.ImGui_GetWindowSize then
      local x, y = reaper.ImGui_GetWindowPos(ctx)
      local w, h = reaper.ImGui_GetWindowSize(ctx)
      if x and y and w and h then
        state.winX, state.winY, state.winW, state.winH = x, y, w, h
      end
    end

    reaper.ImGui_End(ctx)
  end

  if open then
    reaper.defer(main_loop)
  else
    save_config(state)
    if reaper.ImGui_DestroyContext then
      reaper.ImGui_DestroyContext(ctx)
    end
  end
end

-- Kick off
reaper.defer(main_loop)
