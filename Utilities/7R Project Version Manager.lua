--[[
@description 7R Project Version Manager
@author 7thResonance
@version 0.52
@changelog - Added media file cleanup utility (experimental, use with caution)
@screenshot Window https://i.postimg.cc/qRNQ9926/Screenshot-2025-08-23-001441.png
@about A GUI to save versions of the project to a table and recall them.
    It saves a project into a custom format file (.7rvm)[AI thought of this name lmao, literaly 7thResonance version manager LMAO].
    Each version which is opened will have a temporary rpp along with the master project.
    The temporary rpp will be deleted when the version is closed (if the GUI is open).
    All clean up and extraction only happens while the GUI is open.
    The updates on the version projects are copied automatically when the GUI opens again (if a change has been detected).
    You can also use the GUI to manage your project versions.

    Save as will create a new branch (Master project). Save will function as normal updates.

    Features
        - Save and recall project versions
        - Automatic cleanup of temporary files
        - GUI for managing project versions
        - Open tab detection
        - Active tag detection
        - Post save detection and autocopy (during opening of GUI)
        - Position and size is remembered
        - Media file cleanup utility (experimental, use with caution)

    Do not use this script for important projects, still needs a lot of testing. thats why the version is 0.51
--]]

-- Safety: require ReaImGui (v0.9+) for GUI
if not reaper or not reaper.ImGui_GetBuiltinPath then
  reaper.ShowMessageBox("ReaImGui not found or too old. Install via ReaPack.", "7R Version Manager", 0)
  return
end

package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua'
local ImGui = require 'imgui' '0.9'

-- Namespace
local VM = {}

-- Constants
VM.EXT_SECTION = "7RVM"
VM.EXT_ROLE_KEY = "role"            -- "master"|"version"
VM.EXT_MASTER_PATH = "master_path"
VM.EXT_CONTAINER_PATH = "container_path"
VM.EXT_VERSION_ID = "version_id"
VM.EXT_VERSION_NAME = "version_name"

VM.CONTAINER_EXT = ".7rvm"
VM.SCHEMA = 1
VM.APP_NAME = "7R Project Version Manager"

-- Fonts and UI colors
local ctx = ImGui.CreateContext(VM.APP_NAME)
local FontTitle = ImGui.CreateFont('sans-serif', 20, ImGui.FontFlags_Bold)
local Font = ImGui.CreateFont('sans-serif', 14)
ImGui.Attach(ctx, Font)
ImGui.Attach(ctx, FontTitle)

-- State
local Window_Open = true
local SelectedIndex = 0  -- 0 = master, >=1 = version index
local PromptNewName = ""
local PromptOverwriteConfirm = false
local PromptNewNameOpen = false
local StatusMsg = ""

-- Debugging for cleanup/deletion
local DebugCleanup = false
local DebugLines = {}
local function DebugLog(msg)
  local line = string.format("[%s] %s", os.date("%H:%M:%S"), tostring(msg))
  DebugLines[#DebugLines+1] = line
  if #DebugLines > 400 then
    table.remove(DebugLines, 1)
  end
  reaper.ShowConsoleMsg(line .. "\n")
end

-- Version management UI state
local RenameIndex = nil
local RenameInput = ""
local DeleteIndex = nil
local UnusedWindowOpen = false
local UnusedRows = {}
local UnusedReport = { scanned_projects = 0, referenced_files = 0, candidate_files = 0, skipped_zip_projects = 0, source_scope = "" }

-- Runtime tracking of open projects (for Save/Save As detection)
VM.OpenState = VM.OpenState or {}   -- keyed by ReaProject*; values: { lastPath = "..." }

-- UI persistence
local UI_X, UI_Y, UI_W, UI_H = nil, nil, nil, nil
local function load_ui_state()
  local sect = "7RVM_UI"
  local v
  v = reaper.GetExtState(sect, "X"); if v ~= "" then UI_X = tonumber(v) end
  v = reaper.GetExtState(sect, "Y"); if v ~= "" then UI_Y = tonumber(v) end
  v = reaper.GetExtState(sect, "W"); if v ~= "" then UI_W = tonumber(v) end
  v = reaper.GetExtState(sect, "H"); if v ~= "" then UI_H = tonumber(v) end
end
local function save_ui_state()
  local sect = "7RVM_UI"
  if UI_X then reaper.SetExtState(sect, "X", tostring(UI_X), true) end
  if UI_Y then reaper.SetExtState(sect, "Y", tostring(UI_Y), true) end
  if UI_W then reaper.SetExtState(sect, "W", tostring(UI_W), true) end
  if UI_H then reaper.SetExtState(sect, "H", tostring(UI_H), true) end
end

-- Time utility (seconds; prefer high-res if available)
local function now_precise()
  if reaper.time_precise then return reaper.time_precise() end
  return os.clock()
end

-- Background watcher setting (persisted)
local BGWatcherEnabled = false
local function load_settings()
  local v = reaper.GetExtState("7RVM_Settings", "BGWatcher")
  if v ~= "" then BGWatcherEnabled = (v == "1" or v == "true") end
end
local function save_settings()
  reaper.SetExtState("7RVM_Settings", "BGWatcher", BGWatcherEnabled and "1" or "0", true)
end


-- Throttle polling (shared between GUI and background mode)
VM.NextPollAt = VM.NextPollAt or 0.0

-- Utilities

local function sep()
  return package.config:sub(1,1)
end

local function path_dirname(path)
  local s = sep()
  return path:match("^(.*"..s..")") or (path:match("^(.*[/\\])") or "")
end

local function path_basename(path)
  local s = sep()
  return path:match("([^"..s.."]+)$") or path
end

local function path_stem(name)
  return (name:gsub("%.[^%.]+$", ""))
end

local function path_join(a, b)
  local s = sep()
  if a == "" then return b end
  if a:sub(-1) == s then return a .. b else return a .. s .. b end
end

local function ensure_dir(p)
  -- naive: create via os.execute
  local s = sep()
  if reaper.EnumerateFiles(p, 0) ~= nil or reaper.EnumerateSubdirectories(p, 0) ~= nil then
    return true
  end
  if s == "\\" then
    os.execute(('mkdir "%s"'):format(p))
  else
    os.execute(('mkdir -p "%s"'):format(p))
  end
  return (reaper.EnumerateFiles(p, 0) ~= nil) or (reaper.EnumerateSubdirectories(p, 0) ~= nil)
end

-- Quick write-access probe for a directory: try creating and deleting a tiny temp file
local function can_write_dir(dir)
  if not dir or dir == "" then return false, "empty dir" end
  -- Ensure directory exists first
  if not ensure_dir(dir) then return false, "cannot create directory" end
  local probe_name = ".7rvm_writecheck_" .. tostring(os.time()) .. "_" .. tostring(math.random(100000, 999999)) .. ".tmp"
  local probe_path = path_join(dir, probe_name)
  local f, err = io.open(probe_path, "wb")
  if not f then return false, "open failed: " .. tostring(err) end
  local ok, werr = pcall(function() f:write("ok") end)
  f:close()
  -- Attempt cleanup regardless
  os.remove(probe_path)
  if not ok then return false, "write failed: " .. tostring(werr) end
  return true
end

-- Normalize paths for comparison (lowercase, forward slashes, collapse repeats)
local function normalize_path(p)
  p = (p or ""):gsub("\\", "/")
  p = p:gsub("/+", "/")
  return p:lower()
end

local function file_read_bytes(path)
  local f = io.open(path, "rb"); if not f then return nil, "cannot open" end
  local d = f:read("*a"); f:close(); return d
end

local function file_write_bytes(path, data)
  local f = io.open(path, "wb"); if not f then return false, "cannot create" end
  f:write(data); f:close(); return true
end

-- Atomic-ish write: write to temp file in same directory, then rename into place.
local function atomic_write(path, data)
  local dir = path_dirname(path)
  local base = path_basename(path)
  local tmp = path_join(dir, "." .. base .. ".tmp." .. tostring(os.time()) .. "." .. tostring(math.random(100000, 999999)))

  local ok, err = file_write_bytes(tmp, data)
  if not ok then
    return false, "temp write failed: " .. tostring(err)
  end

  -- Try rename; on Windows this may fail if target exists, so remove target and retry.
  local renamed = os.rename(tmp, path)
  if not renamed then
    os.remove(path)
    renamed = os.rename(tmp, path)
  end

  if not renamed then
    os.remove(tmp)
    return false, "rename failed"
  end

  return true
end

local function file_exists(path)
  local f = io.open(path, "rb")
  if f then f:close(); return true end
  return false
end

local function path_is_abs(p)
  if not p or p == "" then return false end
  if p:match("^%a:[/\\]") then return true end
  if p:match("^[/\\][/\\]") then return true end
  if p:sub(1,1) == "/" then return true end
  return false
end

local function path_relative_to(root, full)
  local rn = normalize_path(root or "")
  local fn = normalize_path(full or "")
  if rn ~= "" and fn:sub(1, #rn) == rn then
    local rel = (full or ""):sub(#(root or "") + 1)
    rel = rel:gsub("^[/\\]+", "")
    if rel ~= "" then return rel end
  end
  return full or ""
end

-- Manifest-with-blobs constants and helpers
local RVM_MAGIC = "7RVM1\n"
local RVM_RESERVED_BYTES = 524288 -- 512 KB reserved manifest area (adjust if needed)

local function file_size(path)
  local f = io.open(path, "rb"); if not f then return nil end
  local sz = f:seek("end")
  f:close()
  return sz
end

-- Lightweight FNV-1a 32-bit hash for small buffers
local function fnv1a32(data)
  local hash = 2166136261
  for i = 1, #data do
    hash = (hash ~ data:byte(i)) & 0xFFFFFFFF
    -- multiply by 16777619 with overflow emulation
    hash = ((hash * 16777619) & 0xFFFFFFFF)
  end
  return string.format("%08x", hash)
end

-- Fingerprint: hash of first 64KB + last 64KB (concatenated)
local function file_fingerprint64k(path)
  local sz = file_size(path) or 0
  if sz <= 0 then return "00000000" end
  local f = io.open(path, "rb"); if not f then return "00000000" end
  local head_sz = math.min(64*1024, sz)
  local head = f:read(head_sz) or ""
  local tail = ""
  if sz > 64*1024 then
    f:seek("set", math.max(0, sz - 64*1024))
    tail = f:read(64*1024) or ""
  end
  f:close()
  return fnv1a32(head .. tail)
end

-- Read first two header lines to locate reserved area start and size
local function _read_header(path)
  local f = io.open(path, "rb"); if not f then return nil, nil, nil end
  local magic = f:read("*l"); magic = magic and (magic .. "\n") or ""
  local rsvl = f:read("*l") or ""
  local header_len = #magic + #rsvl + 2 - 1 -- both lines include \n; +2 accounts read "*l" excluding \n; adjust to include newlines
  -- Normalize header_len: recompute by concatenating strings as they were read
  header_len = #magic + #rsvl + 1
  f:close()
  if magic ~= RVM_MAGIC then return nil, nil, nil end
  local rsv = tonumber(rsvl:match("RSV%s+(%d+)")) or RVM_RESERVED_BYTES
  return magic, rsv, header_len
end

-- Self-contained serializer for manifest block (avoid dependency on outer locals)
local function rvm_serialize(val, name, depth)
  depth = depth or 0
  local indent = string.rep(" ", depth)
  local out = ""
  local function is_ident(n) return type(n)=="string" and n:match('^[a-zA-Z_][a-zA-Z0-9_]*$') end
  if name then
    if type(name)=="number" then
      out = out .. indent .. "["..name.."] = "
    elseif is_ident(name) then
      out = out .. indent .. name .. " = "
    else
      out = out .. indent .. "["..string.format("%q", name).."] = "
    end
  else
    out = out .. indent
  end
  if type(val)=="table" then
    out = out .. "{\n"
    for k,v in pairs(val) do
      out = out .. rvm_serialize(v, k, depth+2) .. ",\n"
    end
    out = out .. indent .. "}"
  elseif type(val)=="string" then
    out = out .. string.format("%q", val)
  elseif type(val)=="number" then
    out = out .. tostring(val)
  elseif type(val)=="boolean" then
    out = out .. (val and "true" or "false")
  elseif val == nil then
    out = out .. "nil"
  else
    out = out .. "nil"
  end
  return out
end
local function rvm_table_to_chunk(t)
  return "return " .. rvm_serialize(t) .. "\n"
end
local function rvm_chunk_to_table(str)
  local f, err = load(str)
  if not f then return nil, err end
  local ok, res = pcall(f)
  if not ok or type(res) ~= "table" then return nil, "chunk did not return a table" end
  return res
end

local function _write_new_container(path, master_path)
  -- Preflight: directory must exist and be writable
  local dir = path_dirname(path)
  local okDir, derr = can_write_dir(dir)
  if not okDir then
    return false, string.format("no write access to folder: %s (%s)", tostring(dir), tostring(derr))
  end
  -- Create new container file
  local f, ferr = io.open(path, "wb"); if not f then return false, "cannot create container file: " .. tostring(ferr) end
  -- Header
  f:write(RVM_MAGIC)
  f:write(("RSV %d\n"):format(RVM_RESERVED_BYTES))
  -- Manifest area: start with LEN 0 and pad
  local len_line = "LEN 0\n"
  f:write(len_line)
  local pad_bytes = RVM_RESERVED_BYTES - #len_line
  if pad_bytes > 0 then f:write(string.rep("\0", pad_bytes)) end
  f:close()
  -- Initialize manifest and write it
  local manifest = {
    schema = VM.SCHEMA,
    master = { path = master_path or "", name = path_stem(path_basename(master_path or "")) },
    versions = {}
  }
  local ok, err = (function()
    local mf, oerr = io.open(path, "r+b"); if not mf then return false, "cannot reopen: " .. tostring(oerr) end
    local _, rsv, header_len = _read_header(path); if not header_len then mf:close(); return false, "bad header" end
    local chunk = rvm_table_to_chunk(manifest)
    local len_line2 = ("LEN %d\n"):format(#chunk)
    if #len_line2 + #chunk > rsv then mf:close(); return false, "manifest too large" end
    mf:seek("set", header_len)
    mf:write(len_line2)
    mf:write(chunk)
    local used = #len_line2 + #chunk
    local pad = rsv - used
    if pad > 0 then mf:write(string.rep("\0", pad)) end
    mf:close()
    return true
  end)()
  if not ok then return false, err end
  return true
end

local function _read_manifest(path)
  local magic, rsv, header_len = _read_header(path)
  if not magic then return nil, "not new format" end
  local f = io.open(path, "rb"); if not f then return nil, "open failed" end
  f:seek("set", header_len)
  local len_hdr = f:read(64) or ""
  local mlen = tonumber(len_hdr:match("LEN%s+(%d+)")) or 0
  -- Move to manifest start (right after the len line)
  local after_len_off = header_len + #("LEN " .. tostring(mlen) .. "\n")
  f:seek("set", after_len_off)
  local chunk = ""
  if mlen > 0 then
    chunk = f:read(mlen) or ""
  end
  f:close()
  if chunk == "" then
    return { schema = VM.SCHEMA, master = { path = "", name = "" }, versions = {} }
  end
  local t, err = rvm_chunk_to_table(chunk)
  if not t then return nil, "manifest parse error: " .. tostring(err) end
  t.versions = t.versions or {}
  return t
end

local function _write_manifest_in_place(path, manifest)
  local magic, rsv, header_len = _read_header(path)
  if not magic then return false, "not new format" end
  local chunk = rvm_table_to_chunk(manifest)
  local len_line = ("LEN %d\n"):format(#chunk)
  if (#len_line + #chunk) > rsv then
    return false, "manifest too large for reserved header"
  end
  local f = io.open(path, "r+b"); if not f then return false, "open failed" end
  f:seek("set", header_len)
  f:write(len_line)
  f:write(chunk)
  local used = #len_line + #chunk
  local pad = rsv - used
  if pad > 0 then f:write(string.rep("\0", pad)) end
  f:close()
  return true
end

local function _append_blob(path, bytes)
  local sz = file_size(path) or 0
  local f = io.open(path, "ab"); if not f then return nil, "open append failed" end
  f:write(bytes)
  f:close()
  return sz, #bytes
end

local function _read_blob(path, offset, size)
  local f = io.open(path, "rb"); if not f then return nil, "open failed" end
  f:seek("set", offset)
  local data = f:read(size)
  f:close()
  return data
end

local function _ensure_new_container(path, master_path)
  if not file_exists(path) then
    return _write_new_container(path, master_path)
  end
  local magic, _, _ = _read_header(path)
  if magic then return true end
  return false, "not new format"
end

local function now_iso()
  return os.date("%Y-%m-%d_%H-%M-%S")
end

-- Streamed append of a file into the container: returns offset and size
local function append_file_to_container_streamed(container_path, project_path)
  local offset = file_size(container_path) or 0

  local cf, cerr = io.open(container_path, "ab"); if not cf then return nil, nil, ("open container append failed for %s: %s"):format(container_path, tostring(cerr)) end
  local pf = io.open(project_path, "rb"); if not pf then cf:close(); return nil, nil, "open project failed" end

  local total = 0
  local CHUNK = 16 * 1024 * 1024 -- large chunks to reduce I/O overhead
  while true do
    local chunk = pf:read(CHUNK)
    if not chunk or #chunk == 0 then break end
    cf:write(chunk)
    total = total + #chunk
  end
  pf:close()
  cf:close()

  return offset, total
end

-- Base64
local b='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local function b64encode(data)
  return ((data:gsub('.', function(x)
    local r,bits='',x:byte()
    for i=8,1,-1 do r=r..(bits%2^i-bits%2^(i-1)>0 and '1' or '0') end
    return r
  end)..'0000'):gsub('%d%d%d?%d?%d?%d?', function(x)
    if (#x < 6) then return '' end
    local c=0
    for i=1,6 do c=c + (x:sub(i,i)=='1' and 2^(6-i) or 0) end
    return b:sub(c+1,c+1)
  end)..({ '', '==', '=' })[#data%3+1])
end

local function b64decode(data)
  data = data:gsub('[^'..b..'=]', '')
  return (data:gsub('.', function(x)
    if (x == '=') then return '' end
    local r,f='',(b:find(x)-1)
    for i=6,1,-1 do r=r..(f%2^i-f%2^(i-1)>0 and '1' or '0') end
    return r
  end):gsub('%d%d%d?%d?%d?%d?%d?%d?', function(x)
    if (#x ~= 8) then return '' end
    local c=0
    for i=1,8 do c=c + (x:sub(i,i)=='1' and 2^(8-i) or 0) end
    return string.char(c)
  end))
end

-- Serialize to a Lua chunk (safe subset, strings/numbers/booleans/tables)
local function serialize(val, name, depth)
  depth = depth or 0
  local indent = string.rep(" ", depth)
  local out = ""
  local function is_ident(n) return type(n)=="string" and n:match('^[a-zA-Z_][a-zA-Z0-9_]*$') end
  if name then
    if type(name)=="number" then
      out = out .. indent .. "["..name.."] = "
    elseif is_ident(name) then
      out = out .. indent .. name .. " = "
    else
      out = out .. indent .. "["..string.format("%q", name).."] = "
    end
  else
    out = out .. indent
  end
  if type(val)=="table" then
    out = out .. "{\n"
    for k,v in pairs(val) do
      out = out .. serialize(v, k, depth+2) .. ",\n"
    end
    out = out .. indent .. "}"
  elseif type(val)=="string" then
    out = out .. string.format("%q", val)
  elseif type(val)=="number" then
    out = out .. tostring(val)
  elseif type(val)=="boolean" then
    out = out .. (val and "true" or "false")
  elseif val == nil then
    out = out .. "nil"
  else
    out = out .. "nil"
  end
  return out
end

local function table_to_chunk(t)
  return "return " .. serialize(t) .. "\n"
end

local function chunk_to_table(str)
  local f, err = load(str)
  if not f then return nil, err end
  local ok, res = pcall(f)
  if not ok then return nil, res end
  if type(res) ~= "table" then return nil, "chunk did not return a table" end
  return res
end

-- Project/path helpers

local function get_current_project_path()
  local _, p = reaper.EnumProjects(-1, "")
  return p or ""
end

local function ensure_project_saved()
  local p = get_current_project_path()
  if p == "" then
    reaper.Main_OnCommand(40022, 0) -- File: Save project as...
    p = get_current_project_path()
  end
  return p ~= "" and p or nil
end

local function get_container_path_for_master(master_path)
  local d = path_dirname(master_path)
  local base = path_stem(path_basename(master_path))
  return path_join(d, base .. VM.CONTAINER_EXT)
end

-- Forward declaration: used by unused-file analysis before implementation appears.
local load_container

local function iter_files_recursive(root_dir, out)
  if not root_dir or root_dir == "" then return end
  out = out or {}
  local function walk(dir)
    local i = 0
    while true do
      local f = reaper.EnumerateFiles(dir, i)
      if not f then break end
      out[#out+1] = path_join(dir, f)
      i = i + 1
    end
    local j = 0
    while true do
      local sub = reaper.EnumerateSubdirectories(dir, j)
      if not sub then break end
      walk(path_join(dir, sub))
      j = j + 1
    end
  end
  walk(root_dir)
  return out
end

local CleanupExts = {
  [".wav"] = true, [".wave"] = true, [".flac"] = true, [".mp3"] = true, [".ogg"] = true, [".opus"] = true,
  [".aif"] = true, [".aiff"] = true, [".caf"] = true, [".w64"] = true, [".wv"] = true,
  [".mid"] = true, [".midi"] = true, [".rex"] = true, [".rx2"] = true,
  [".mp4"] = true, [".mov"] = true, [".avi"] = true, [".mkv"] = true, [".webm"] = true,
  [".reapeaks"] = true,
}

local function file_ext(path)
  local e = (path or ""):match("(%.[^%./\\]+)$")
  return e and e:lower() or ""
end

local function resolve_ref_path(raw_ref, proj_path)
  if not raw_ref or raw_ref == "" then return nil end
  local ref = raw_ref:gsub('\\"', '"')
  ref = ref:gsub("/", sep())
  ref = ref:gsub("^%s+", ""):gsub("%s+$", "")
  if ref == "" then return nil end
  if not path_is_abs(ref) then
    local base = path_dirname(proj_path or "")
    ref = path_join(base, ref)
  end
  return ref
end

local function collect_refs_from_open_projects(ref_set, report)
  local added = 0
  local i = 0
  while true do
    local proj = reaper.EnumProjects(i, "")
    if not proj then break end

    report.scanned_projects = report.scanned_projects + 1
    local tr_count = reaper.CountTracks(proj) or 0
    for t = 0, tr_count - 1 do
      local tr = reaper.GetTrack(proj, t)
      local item_count = reaper.CountTrackMediaItems(tr) or 0
      for it = 0, item_count - 1 do
        local item = reaper.GetTrackMediaItem(tr, it)
        local tk_count = reaper.CountTakes(item) or 0
        for k = 0, tk_count - 1 do
          local take = reaper.GetTake(item, k)
          if take then
            local src = reaper.GetMediaItemTake_Source(take)
            if src then
              local a, b = reaper.GetMediaSourceFileName(src, "")
              local p = ""
              if type(a) == "string" then
                p = a
              elseif type(b) == "string" then
                p = b
              end
              if p ~= "" then
                local abs = resolve_ref_path(p, "")
                local np = normalize_path(abs)
                if np ~= "" and not ref_set[np] then
                  ref_set[np] = true
                  added = added + 1
                end
              end
            end
          end
        end
      end
    end

    i = i + 1
  end
  return added
end

local function collect_rpp_file_refs(bytes, proj_path, ref_set)
  if not bytes or bytes == "" then return 0 end
  -- Binary zip payloads are unsupported here; caller tracks skips.
  if bytes:sub(1, 2) == "PK" then return -1 end

  local count = 0
  for line in bytes:gmatch("[^\r\n]+") do
    local p = line:match('FILE%s+"(.-)"')
    if not p then p = line:match("FILE%s+([^%s][^%c]*)") end
    if p and p ~= "" then
      local abs = resolve_ref_path(p, proj_path)
      if abs and abs ~= "" then
        local np = normalize_path(abs)
        if not ref_set[np] then
          ref_set[np] = true
          count = count + 1
        end
      end
    end
  end
  return count
end

local function analyze_unused_files(master_path, container_path)
  local report = {
    scanned_projects = 0,
    referenced_files = 0,
    candidate_files = 0,
    skipped_zip_projects = 0,
    source_scope = path_dirname(master_path or ""),
  }
  local scope_dir = report.source_scope
  if not scope_dir or scope_dir == "" then
    return {}, report, "Missing master project directory."
  end

  local refs = {}
  local function collect_from_project_bytes(bytes, proj_path)
    report.scanned_projects = report.scanned_projects + 1
    local found = collect_rpp_file_refs(bytes, proj_path, refs)
    if found == -1 then
      report.skipped_zip_projects = report.skipped_zip_projects + 1
    end
  end

  if file_exists(master_path) then
    local mbytes = file_read_bytes(master_path)
    if mbytes then collect_from_project_bytes(mbytes, master_path) end
  end

  -- Include all currently open projects (in-memory state), so unsaved edits are considered.
  collect_refs_from_open_projects(refs, report)

  if container_path and container_path ~= "" and file_exists(container_path) then
    local cont_tbl = load_container(container_path, master_path)
    if cont_tbl and cont_tbl.versions then
      for _, v in ipairs(cont_tbl.versions) do
        if v.blob_offset and v.blob_size and v.blob_size > 0 then
          local bytes = _read_blob(container_path, v.blob_offset, v.blob_size)
          if bytes then
            local stem = (v.name and v.name ~= "" and v.name) or "version"
            local pseudo_proj = path_join(scope_dir, stem .. (v.ext or ".rpp"))
            collect_from_project_bytes(bytes, pseudo_proj)
          end
        end
      end
    end
  end

  -- Also scan all saved project files in the master folder tree.
  -- This catches newly saved local variants that are not yet copied into the container.
  local scope_files = iter_files_recursive(scope_dir, {})
  for _, p in ipairs(scope_files or {}) do
    local pn = normalize_path(p)
    local is_proj = pn:match("%.rpp$") or pn:match("%.rpp%-zip$")
    local is_sidecar = pn:match("%.7rvm%.meta$")
    local is_container = (container_path and container_path ~= "" and pn == normalize_path(container_path))
    if is_proj and (not is_sidecar) and (not is_container) then
      local bytes = file_read_bytes(p)
      if bytes then
        collect_from_project_bytes(bytes, p)
      end
    end
  end

  local ref_count = 0
  for _ in pairs(refs) do ref_count = ref_count + 1 end
  report.referenced_files = ref_count

  local files = scope_files
  local rows = {}
  for _, f in ipairs(files or {}) do
    local ext = file_ext(f)
    if CleanupExts[ext] then
      report.candidate_files = report.candidate_files + 1
      local nf = normalize_path(f)
      local used = refs[nf] and true or false
      if (not used) and ext == ".reapeaks" then
        local base = nf:gsub("%.reapeaks$", "")
        if refs[base] then used = true end
      end
      if not used then
        rows[#rows+1] = {
          path = f,
          size = file_size(f) or 0,
          selected = false,
          error = "",
        }
      end
    end
  end

  table.sort(rows, function(a, b) return normalize_path(a.path) < normalize_path(b.path) end)
  return rows, report, nil
end

local function delete_unused_rows(delete_all)
  local deleted, failed = 0, 0
  for i = #UnusedRows, 1, -1 do
    local row = UnusedRows[i]
    if row and (delete_all or row.selected) then
      local ok, err = os.remove(row.path)
      if ok then
        table.remove(UnusedRows, i)
        deleted = deleted + 1
      else
        row.error = tostring(err or "delete failed")
        failed = failed + 1
      end
    end
  end
  return deleted, failed
end

local function get_workspace_root()
  local base = path_join(reaper.GetResourcePath(), "7RVM_workspace")
  ensure_dir(base)
  return base
end

-- Attempt to rebind a sidecar to a container/master in the current project's directory
local function _find_master_in_dir(dir, stem)
  local cand1 = path_join(dir, stem .. ".rpp")
  local cand2 = path_join(dir, stem .. ".rpp-zip")
  if file_exists(cand1) then return cand1 end
  if file_exists(cand2) then return cand2 end
  return nil
end

local function maybe_rebind_sidecar(proj_path, meta_tbl)
  if not proj_path or proj_path == "" or not meta_tbl then return false end
  local dir = path_dirname(proj_path)
  local master_stem = nil
  if meta_tbl.master_path and meta_tbl.master_path ~= "" then
    master_stem = path_stem(path_basename(meta_tbl.master_path))
  end
  if not master_stem or master_stem == "" then
    if meta_tbl.container_path and meta_tbl.container_path ~= "" then
      master_stem = path_stem(path_basename(meta_tbl.container_path))
    end
  end
  if not master_stem or master_stem == "" then
    return false
  end

  local new_container = path_join(dir, master_stem .. VM.CONTAINER_EXT)
  local changed = false
  if file_exists(new_container) then
    if meta_tbl.container_path ~= new_container then
      meta_tbl.container_path = new_container
      changed = true
    end
  else
    -- nothing to rebind to
    return false
  end

  local new_master = _find_master_in_dir(dir, master_stem)
  if new_master and meta_tbl.master_path ~= new_master then
    meta_tbl.master_path = new_master
    changed = true
  end

  return changed
end

local function set_proj_ext_role(proj, role, master_path, container_path, version_id, version_name)
  if proj == nil then proj = 0 end
  if role then reaper.SetProjExtState(proj, VM.EXT_SECTION, VM.EXT_ROLE_KEY, role) end
  if master_path then reaper.SetProjExtState(proj, VM.EXT_SECTION, VM.EXT_MASTER_PATH, master_path) end
  if container_path then reaper.SetProjExtState(proj, VM.EXT_SECTION, VM.EXT_CONTAINER_PATH, container_path) end
  if version_id then reaper.SetProjExtState(proj, VM.EXT_SECTION, VM.EXT_VERSION_ID, version_id) end
  if version_name then reaper.SetProjExtState(proj, VM.EXT_SECTION, VM.EXT_VERSION_NAME, version_name) end
end

local function get_proj_ext(proj, key)
  if proj == nil then proj = 0 end
  local _, v = reaper.GetProjExtState(proj, VM.EXT_SECTION, key)
  return v or ""
end

-- Container

-- Structure:
-- {
--   schema = 1,
--   master = { path = "...", name = "ProjectName" },
--   versions = {
--     { id="...", name="...", timestamp=..., size=..., hash="...", ext=".rpp" or ".rpp-zip", comment="", data_b64="<...>" }
--   }
-- }

load_container = function(container_path, master_path)
  -- Ensure or detect new-format container first
  if not file_exists(container_path) then
    local ok, err = _write_new_container(container_path, master_path or get_current_project_path())
    if not ok then
      return nil, ("Failed to create container at %s. Reason: %s. Hints: ensure folder is writable (not Program Files/OneDrive-protected), and path is not too long.")
        :format(container_path, tostring(err))
    end
    return { schema = VM.SCHEMA, master = { path = master_path or get_current_project_path(), name = path_stem(path_basename(master_path or get_current_project_path())) }, versions = {} }
  end

  -- Try new-format manifest first
  local manifest, nerr = _read_manifest(container_path)
  if manifest then
    -- Ensure master fields are set
    if not manifest.master or not manifest.master.path or manifest.master.path == "" then
      manifest.master = { path = master_path or get_current_project_path(), name = path_stem(path_basename(master_path or get_current_project_path())) }
      _write_manifest_in_place(container_path, manifest)
    end
    return manifest
  end

  -- Fallback: old inline container -> migrate to manifest+blobs
  local data, err = file_read_bytes(container_path)
  if not data then return nil, "Failed to read container: " .. tostring(err) end
  local tbl, perr = chunk_to_table(data)
  if not tbl then return nil, "Container parse error: " .. tostring(perr) end

  tbl.versions = tbl.versions or {}
  -- Create fresh new-format file
  local okN, eN = _write_new_container(container_path, (tbl.master and tbl.master.path) or (master_path or get_current_project_path()))
  if not okN then return nil, "Failed to initialize new container: " .. tostring(eN) end

  -- Append each inline blob to the blob region; remove data_b64
  for _, v in ipairs(tbl.versions) do
    local b64 = v.data_b64
    if b64 and b64 ~= "" then
      local bytes = b64decode(b64)
      if bytes and #bytes > 0 then
        local off, sz = _append_blob(container_path, bytes)
        v.blob_offset = off
        v.blob_size = sz
      else
        v.blob_offset = nil
        v.blob_size = 0
      end
      v.data_b64 = nil
    end
  end

  -- Write migrated manifest
  local okW, eW = _write_manifest_in_place(container_path, tbl)
  if not okW then return nil, "Failed to write migrated manifest: " .. tostring(eW) end
  return tbl
end

local function save_container(container_path, tbl)
  -- If new-format, update manifest in place
  local magic = select(1, _read_header(container_path))
  if magic then
    return _write_manifest_in_place(container_path, tbl)
  end
  -- Old format: migrate first, then write
  local ok, err = _write_new_container(container_path, (tbl.master and tbl.master.path) or get_current_project_path())
  if not ok then return false, err end
  -- No blobs exist yet in this branch; just write manifest
  return _write_manifest_in_place(container_path, tbl)
end

local function container_find_version_index(tbl, version_id)
  for i, v in ipairs(tbl.versions or {}) do
    if v.id == version_id then return i end
  end
  return nil
end

-- Capture current project file bytes
local function read_project_file_bytes()
  -- Ensure the current in-memory state (items, automation, etc.) is flushed to disk
  -- so we capture the exact current project state, not the last manual save.
  reaper.Main_SaveProject(0, false)  -- save current project to its existing path without prompting

  local p = get_current_project_path()
  if p == "" then return nil, "Project has not been saved yet." end
  local bytes, err = file_read_bytes(p)
  if not bytes then return nil, "Failed to read project file: " .. tostring(err) end
  return bytes, p
end

local function save_new_version(container_path, name_opt)
  local t0 = now_precise()
  local okp = ensure_project_saved()
  if not okp then return false, "Please save the project first." end

  -- Make sure in-memory state is flushed to disk and get current project path
  reaper.Main_SaveProject(0, false)
  local proj_path = get_current_project_path()
  if proj_path == "" then return false, "Project has not been saved yet." end

  local ext = ""
  local base = path_basename(proj_path)
  if base:lower():match("%.rpp%-zip$") then
    ext = ".rpp-zip"
  elseif base:lower():match("%.rpp$") then
    ext = ".rpp"
  else
    ext = ".rpp"
  end

  -- Ensure container exists in new format and load manifest
  local t1 = now_precise()
  local tbl, err = load_container(container_path, okp)
  if not tbl then return false, err end

  -- Append project file into container (streamed copy)
  local t2 = now_precise()
  local off, sz, cerr = append_file_to_container_streamed(container_path, proj_path)
  if not off then return false, "Failed to append to container: " .. tostring(cerr) end

  local name = name_opt and name_opt ~= "" and name_opt or (now_iso())
  local id = string.format("%x", off) .. "_" .. os.time()
  local v = {
    id = id,
    name = name,
    timestamp = os.time(),
    size = sz,
    ext = ext,
    comment = "",
    blob_offset = off,
    blob_size = sz,
  }
  table.insert(tbl.versions, 1, v) -- newest first

  -- Write manifest update
  local t3 = now_precise()
  local okW, werr = save_container(container_path, tbl)
  if not okW then return false, "Failed to write container manifest: " .. tostring(werr) end
  local t4 = now_precise()

  if DebugCleanup then
    DebugLog(string.format("save_new: t_total=%.3fs, t_load=%.3fs, t_copy=%.3fs, t_manifest=%.3fs",
      (t4 - t0), (t2 - t1), (t3 - t2), (t4 - t3)))
  end

  StatusMsg = string.format("Saved version '%s' (%s) into container.", name, id)
  return true
end

local function overwrite_version(container_path, version_idx)
  if version_idx < 1 then return false, "Select a version row to overwrite (not Master)." end
  local t0 = now_precise()
  local okp = ensure_project_saved()
  if not okp then return false, "Please save the project first." end

  -- Flush to disk and get current project path
  reaper.Main_SaveProject(0, false)
  local proj_path = get_current_project_path()
  if proj_path == "" then return false, "Project has not been saved yet." end

  local tbl, err = load_container(container_path, okp)
  if not tbl then return false, err end
  local target = tbl.versions[version_idx]
  if not target then return false, "Invalid version index." end

  local base = path_basename(proj_path)
  local ext = base:lower():match("%.rpp%-zip$") and ".rpp-zip" or ".rpp"

  -- Append project file (streamed) and repoint
  local t1 = now_precise()
  local off, sz, cerr = append_file_to_container_streamed(container_path, proj_path)
  if not off then return false, "Failed to append blob to container: " .. tostring(cerr) end

  target.size = sz
  target.timestamp = os.time()
  target.ext = ext
  target.blob_offset = off
  target.blob_size = sz
  target.data_b64 = nil

  local t2 = now_precise()
  local okW, werr = save_container(container_path, tbl)
  if not okW then return false, "Failed to write container manifest: " .. tostring(werr) end
  local t3 = now_precise()

  if DebugCleanup then
    DebugLog(string.format("overwrite: t_total=%.3fs, t_copy=%.3fs, t_manifest=%.3fs",
      (t3 - t0), (t2 - t1), (t3 - t2)))
  end

  StatusMsg = string.format("Overwrote version '%s' (%s).", target.name or "", target.id or "")
  return true
end

-- Extraction/open

-- Forward declaration so functions below capture the local, not a global
local find_open_project_by_path
local detect_master_and_container

-- Build a set of currently open project file paths (normalized), and a map of open version stems per container.
local function get_open_workspace_info()
  local open_set = {}
  local open_versions_by_container = {}
  local i = 0
  while true do
    local proj = reaper.EnumProjects(i, "")
    if not proj then break end
    local _, p = reaper.EnumProjects(i, "")
    if p and p ~= "" then
      local np = normalize_path(p)
      open_set[np] = true

      -- If this is a workspace temp project, read its sidecar meta to attribute it to a container and version name
      local meta_bytes = file_read_bytes(p .. ".7rvm.meta")
      if meta_bytes then
        local meta_tbl = chunk_to_table(meta_bytes)
        if meta_tbl and meta_tbl.container_path and meta_tbl.version_name then
          local container_norm = normalize_path(meta_tbl.container_path)
          local cont_name = path_stem(path_basename(meta_tbl.container_path))
          local safe_ver = meta_tbl.version_name:gsub("[^%w%-%._ ]", "_"):gsub("%s+", "_")
          local expected_stem = string.format("%s_%s", cont_name, safe_ver)
          open_versions_by_container[container_norm] = open_versions_by_container[container_norm] or {}
          open_versions_by_container[container_norm][expected_stem] = true
        end
      end
    end
    i = i + 1
  end
  return open_set, open_versions_by_container
end

-- Delete all closed temp projects (and sidecars) under the workspace directory
local function cleanup_workspace()
  -- Only clean up temps next to the current session's master, and only those that belong to this container.
  local master_path, container_path = detect_master_and_container()
  if not master_path or master_path == "" or not container_path or container_path == "" then
    if DebugCleanup then DebugLog("cleanup: skipped (missing master/container). master=" .. tostring(master_path) .. " container=" .. tostring(container_path)) end
    return -- No reliable context; do nothing to avoid accidental deletion
  end

  -- Load container manifest once
  local cont_tbl, cerr = load_container(container_path, master_path)
  if not cont_tbl then
    if DebugCleanup then DebugLog("cleanup: load_container failed: " .. tostring(cerr)) end
    return
  end

  -- Prepare both raw (with trailing sep) and trimmed dir variants; try both
  local dir_raw = path_dirname(master_path)
  local dir_trim = dir_raw:gsub("[/\\]+$", "")
  local open_set = select(1, get_open_workspace_info())

  local function enumerate_meta_files(base_dir)
    local metas = {}
    local i = 0
    while true do
      local f = reaper.EnumerateFiles(base_dir, i)
      if not f then break end
      if f:lower():match("%.7rvm%.meta$") then
        metas[#metas+1] = path_join(base_dir, f)
      end
      i = i + 1
    end
    return metas
  end

  local metas = enumerate_meta_files(dir_raw)
  if (#metas == 0) then
    metas = enumerate_meta_files(dir_trim)
  end

  if DebugCleanup then
    DebugLog(("cleanup: scanning dir_raw=%s dir_trim=%s; found %d meta(s); container=%s"):format(dir_raw, dir_trim, #metas, container_path))
  end

  for _, meta_full in ipairs(metas) do
    local proj_path = meta_full:gsub("%.7rvm%.meta$", "")
    local proj_norm = normalize_path(proj_path)
    local is_open = open_set[proj_norm] and true or false
    if DebugCleanup then
      DebugLog(("cleanup: meta=%s -> project=%s open=%s"):format(meta_full, proj_path, tostring(is_open)))
    end
    if not is_open then
      local meta_bytes = file_read_bytes(meta_full)
      local meta_tbl = meta_bytes and chunk_to_table(meta_bytes) or nil
      -- Self-heal: if sidecar points to a missing container, try to rebind in this directory
      if meta_tbl and (not (meta_tbl.container_path and file_exists(meta_tbl.container_path))) then
        local reb = maybe_rebind_sidecar(proj_path, meta_tbl)
        if reb then
          file_write_bytes(meta_full, table_to_chunk(meta_tbl))
          if DebugCleanup then DebugLog("cleanup: sidecar re-bound to container: " .. tostring(meta_tbl.container_path)) end
        end
      end
      local matches_container = meta_tbl and meta_tbl.container_path
                                  and normalize_path(meta_tbl.container_path) == normalize_path(container_path)
      if DebugCleanup then
        DebugLog(("cleanup: meta parse ok=%s container_match=%s"):format(tostring(meta_tbl ~= nil), tostring(matches_container)))
      end
      if matches_container and meta_tbl then
        -- Check for modifications via size and fingerprint
        local curr_size = file_size(proj_path) or 0
        local was_size = tonumber(meta_tbl.extracted_size or 0) or 0
        local modified = (curr_size ~= was_size)
        local curr_fp = nil
        if not modified then
          curr_fp = file_fingerprint64k(proj_path)
          local was_fp = tostring(meta_tbl.extracted_fp or "")
          modified = (curr_fp ~= was_fp)
        end
        if DebugCleanup then
          DebugLog(("cleanup: change check size: %d -> %d, fp_match=%s"):format(was_size, curr_size, tostring(not modified)))
        end

        if modified then
          -- Overwrite original version in container (default behavior)
          local idx = nil
          if meta_tbl.version_id and meta_tbl.version_id ~= "" then
            idx = container_find_version_index(cont_tbl, meta_tbl.version_id)
          end
          -- If not found, we’ll add as new entry to avoid losing changes
          local ext = ""
          local base = path_basename(proj_path):lower()
          if base:match("%.rpp%-zip$") then ext = ".rpp-zip" elseif base:match("%.rpp$") then ext = ".rpp" else ext = ".rpp" end

          local off, sz, aerr = append_file_to_container_streamed(container_path, proj_path)
          if not off then
            if DebugCleanup then DebugLog("cleanup: append_file_to_container_streamed failed: " .. tostring(aerr)) end
          else
            if idx then
              cont_tbl.versions[idx].size = sz
              cont_tbl.versions[idx].timestamp = os.time()
              cont_tbl.versions[idx].ext = ext
              cont_tbl.versions[idx].blob_offset = off
              cont_tbl.versions[idx].blob_size = sz
              cont_tbl.versions[idx].data_b64 = nil
              if DebugCleanup then DebugLog(("cleanup: auto-captured changes -> overwrite idx=%d size=%d"):format(idx, sz)) end
            else
              -- No original found; add as new version
              local name = (meta_tbl.version_name and meta_tbl.version_name ~= "" and meta_tbl.version_name or "autosaved") .. " (autosaved)"
              local v = {
                id = string.format("%x", off) .. "_" .. os.time(),
                name = name,
                timestamp = os.time(),
                size = sz,
                ext = ext,
                comment = "Auto-captured from modified temp",
                blob_offset = off,
                blob_size = sz,
              }
              table.insert(cont_tbl.versions, 1, v)
              if DebugCleanup then DebugLog(("cleanup: auto-captured changes -> saved new '%s' size=%d"):format(name, sz)) end
            end
            local okW, werr = save_container(container_path, cont_tbl)
            if not okW and DebugCleanup then
              DebugLog("cleanup: save_container failed after capture: " .. tostring(werr))
            end
          end
        end

        -- Delete sidecar and project (modified or not, after optional capture)
        local ok_meta, err_meta = os.remove(meta_full)
        if DebugCleanup then
          DebugLog(("cleanup: delete meta result ok=%s err=%s"):format(tostring(ok_meta == true), tostring(err_meta)))
        end
        if file_exists(proj_path) then
          local ok_proj, err_proj = os.remove(proj_path)
          if DebugCleanup then
            DebugLog(("cleanup: delete project result ok=%s err=%s"):format(tostring(ok_proj == true), tostring(err_proj)))
          end
        else
          if DebugCleanup then DebugLog("cleanup: project file not found (already gone): " .. proj_path) end
        end
      end
    end
  end
end

local function extract_version_to_workspace(container_path, v)
  -- Proactively prune stale temp files so we can reuse canonical names
  pcall(cleanup_workspace)

  -- Resolve master directory from container manifest (fallbacks included)
  local manifest = select(1, _read_manifest(container_path))
  local master_path = (manifest and manifest.master and manifest.master.path) or ""
  if master_path == "" then
    -- Fallback to current project or container directory
    master_path = get_current_project_path()
    if master_path == "" then
      master_path = container_path
    end
  end
  local cont_name = path_stem(path_basename(container_path)) -- master/container stem
  local proj_dir = path_dirname(master_path)
  ensure_dir(proj_dir)

  -- Canonical filename: "masterprojectname_versionname.ext"
  local ver_name = (v.name and v.name ~= "" and v.name) or "version"
  local safe_ver = ver_name:gsub("[^%w%-%._ ]", "_"):gsub("%s+", "_")
  local ext = v.ext or ".rpp"
  local candidate = path_join(proj_dir, string.format("%s_%s%s", cont_name, safe_ver, ext))

  -- If the canonical file exists and is open, just reuse and focus it;
  -- if it exists but is closed, only delete it if its sidecar points to this same container.
  local existing = find_open_project_by_path(candidate)
  if DebugCleanup then
    DebugLog(("extract: candidate=%s exists=%s open_tab=%s"):format(candidate, tostring(file_exists(candidate)), tostring(existing ~= nil)))
  end
  if file_exists(candidate) and not existing then
    local meta_path = candidate .. ".7rvm.meta"
    local ok_to_delete = false
    if file_exists(meta_path) then
      local meta_bytes = file_read_bytes(meta_path)
      local meta_tbl = meta_bytes and chunk_to_table(meta_bytes) or nil
      local match = meta_tbl and meta_tbl.container_path
                    and normalize_path(meta_tbl.container_path) == normalize_path(container_path)
      if DebugCleanup then
        DebugLog(("extract: sidecar=%s present; container_match=%s"):format(meta_path, tostring(match)))
      end
      if match then ok_to_delete = true end
    else
      if DebugCleanup then DebugLog("extract: sidecar missing, skipping deletion") end
    end
    if ok_to_delete then
      local ok_meta, err_meta = os.remove(meta_path)
      local ok_proj, err_proj = os.remove(candidate)
      if DebugCleanup then
        DebugLog(("extract: pre-clean delete meta ok=%s err=%s; project ok=%s err=%s"):format(
          tostring(ok_meta == true), tostring(err_meta), tostring(ok_proj == true), tostring(err_proj)))
      end
    end
  end

  if not existing then
    -- Write fresh project bytes from blob in container
    if not v.blob_offset or not v.blob_size or v.blob_size <= 0 then
      return nil, "Missing blob reference for version."
    end
    local bytes, rerr = _read_blob(container_path, v.blob_offset, v.blob_size)
    if not bytes or #bytes == 0 then return nil, "Empty or unreadable version data." end
    local ok, err = file_write_bytes(candidate, bytes)
    if not ok then return nil, "Failed to write workspace project: " .. tostring(err) end

    -- Write sidecar meta (use resolved master path)
    local meta = {
      master_path = master_path,
      container_path = container_path,
      version_id = v.id,
      version_name = v.name,
      created = os.time(),
    }
    file_write_bytes(candidate .. ".7rvm.meta", table_to_chunk(meta))
  end

  return candidate
end

-- Find an already-open project instance by file path (case-insensitive, normalized)
find_open_project_by_path = function(path)
  local target = normalize_path(path)
  local i = 0
  while true do
    local proj = reaper.EnumProjects(i, "")
    if not proj then break end
    local _, p = reaper.EnumProjects(i, "")
    if p and normalize_path(p) == target then
      return proj
    end
    i = i + 1
  end
  return nil
end

local function open_project_in_current(path)
  local existing = find_open_project_by_path(path)
  if existing then
    reaper.SelectProjectInstance(existing)
  else
    reaper.Main_openProject(path)
  end
  -- Immediately prime role from sidecar for the now-current project
  local meta_bytes = file_read_bytes(path .. ".7rvm.meta")
  local meta_tbl = meta_bytes and chunk_to_table(meta_bytes) or nil
  if meta_tbl and meta_tbl.container_path then
    set_proj_ext_role(0, "version", meta_tbl.master_path or "", meta_tbl.container_path, meta_tbl.version_id, meta_tbl.version_name)
  end
end

local function open_project_in_new_tab(path)
  local existing = find_open_project_by_path(path)
  if existing then
    reaper.SelectProjectInstance(existing)
  else
    reaper.Main_OnCommand(40859, 0) -- New project tab
    reaper.Main_openProject(path)
  end
  -- Immediately prime role from sidecar for the now-current project (new tab is active)
  local meta_bytes = file_read_bytes(path .. ".7rvm.meta")
  local meta_tbl = meta_bytes and chunk_to_table(meta_bytes) or nil
  if meta_tbl and meta_tbl.container_path then
    set_proj_ext_role(0, "version", meta_tbl.master_path or "", meta_tbl.container_path, meta_tbl.version_id, meta_tbl.version_name)
  end
end

-- Detection of master/container for current session

detect_master_and_container = function()
  local cur_path = get_current_project_path()
  if cur_path == "" then
    return nil, nil, "Please save the project first."
  end

  -- 1) Prefer sidecar (likely a version session on first open); initialize extstate
  local role, master_path, container_path = "", "", ""
  local meta_path = cur_path .. ".7rvm.meta"
  if file_exists(meta_path) then
    local data = file_read_bytes(meta_path)
    local t = data and chunk_to_table(data) or nil
    if t and (t.container_path or t.master_path) then
      -- Self-heal: if the recorded container doesn't exist here (e.g. folder moved), rebind next to current project
      if not (t.container_path and file_exists(t.container_path)) then
        local changed = maybe_rebind_sidecar(cur_path, t)
        if changed then
          file_write_bytes(meta_path, table_to_chunk(t))
        end
      end
      role = "version"
      master_path = t.master_path or ""
      container_path = t.container_path or ""
      set_proj_ext_role(0, role, master_path, container_path, t.version_id, t.version_name)
    end
  end

  -- 2) If still unknown, use extstate
  if role == "" then
    role = get_proj_ext(0, VM.EXT_ROLE_KEY)
    master_path = get_proj_ext(0, VM.EXT_MASTER_PATH)
    container_path = get_proj_ext(0, VM.EXT_CONTAINER_PATH)
  end

  -- 3) If still unknown, assume current is master and derive container
  if role == "" then
    role = "master"
    master_path = cur_path
    container_path = get_container_path_for_master(master_path)
    set_proj_ext_role(0, role, master_path, container_path, "", "")
  end

  -- normalize if missing container
  if container_path == "" and master_path ~= "" then
    container_path = get_container_path_for_master(master_path)
    set_proj_ext_role(0, role, master_path, container_path, get_proj_ext(0, VM.EXT_VERSION_ID), get_proj_ext(0, VM.EXT_VERSION_NAME))
  end

  return master_path, container_path, nil
end

-- UI

-- Version management operations
local function rename_version(container_path, index, new_name)
  if not new_name or new_name == "" then return false, "New name is empty." end
  local tbl, err = load_container(container_path, nil)
  if not tbl then return false, err end
  if not tbl.versions or not tbl.versions[index] then return false, "Invalid version index." end

  -- Trim whitespace
  new_name = new_name:gsub("^%s+", ""):gsub("%s+$", "")
  tbl.versions[index].name = new_name

  local ok, werr = save_container(container_path, tbl)
  if not ok then return false, "Failed to save container: " .. tostring(werr) end
  return true
end

local function delete_version(container_path, index)
  local tbl, err = load_container(container_path, nil)
  if not tbl then return false, err end
  if not tbl.versions or not tbl.versions[index] then return false, "Invalid version index." end

  -- Compute canonical temp file path next to the master and ensure it isn't open; then delete it (and sidecar)
  local v = tbl.versions[index]
  local cont_name = path_stem(path_basename(container_path))
  local ver_name = (v.name and v.name ~= "" and v.name) or "version"
  local safe_ver = ver_name:gsub("[^%w%-%._ ]", "_"):gsub("%s+", "_")
  local ext = v.ext or ".rpp"

  local master_path = (tbl.master and tbl.master.path) or ""
  local proj_dir = master_path ~= "" and path_dirname(master_path) or path_dirname(container_path)
  local candidate = path_join(proj_dir, string.format("%s_%s%s", cont_name, safe_ver, ext))

  -- If open anywhere, refuse deletion (GUI should prevent this, but double-check here)
  local open_set = select(1, get_open_workspace_info())
  if open_set and open_set[normalize_path(candidate)] then
    return false, "Cannot delete: version is currently opened."
  end

  -- Remove entry from container first
  table.remove(tbl.versions, index)
  local ok, werr = save_container(container_path, tbl)
  if not ok then return false, "Failed to save container: " .. tostring(werr) end

  -- Remove temp project and sidecar if present, but only if sidecar belongs to this container
  local meta_path = candidate .. ".7rvm.meta"
  if file_exists(meta_path) then
    local meta_bytes = file_read_bytes(meta_path)
    local meta_tbl = meta_bytes and chunk_to_table(meta_bytes) or nil
    if meta_tbl and meta_tbl.container_path
       and normalize_path(meta_tbl.container_path) == normalize_path(container_path) then
      if file_exists(candidate) then os.remove(candidate) end
      os.remove(meta_path)
    end
  end

  return true
end

local function draw_unused_files_window(master_path, container_path)
  if not UnusedWindowOpen then return end

  local visible, open = ImGui.Begin(ctx, "Delete Unused Files", true)
  if visible then
    ImGui.Text(ctx, "Scope: " .. (UnusedReport.source_scope or path_dirname(master_path or "")))
    ImGui.Text(ctx, string.format(
      "Scanned projects: %d  |  Referenced files: %d  |  Candidates: %d  |  Zip projects skipped: %d",
      tonumber(UnusedReport.scanned_projects or 0),
      tonumber(UnusedReport.referenced_files or 0),
      tonumber(UnusedReport.candidate_files or 0),
      tonumber(UnusedReport.skipped_zip_projects or 0)
    ))
    ImGui.Separator(ctx)

    if ImGui.Button(ctx, "Analyze") then
      local rows, report, err = analyze_unused_files(master_path, container_path)
      if err then
        StatusMsg = "Unused scan failed: " .. tostring(err)
      else
        UnusedRows = rows
        UnusedReport = report
        StatusMsg = string.format("Unused scan complete: %d file(s) found.", #UnusedRows)
      end
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Select All") then
      for _, r in ipairs(UnusedRows) do r.selected = true end
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Select None") then
      for _, r in ipairs(UnusedRows) do r.selected = false end
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Delete Selected") then
      local d, f = delete_unused_rows(false)
      StatusMsg = string.format("Delete selected: removed %d, failed %d.", d, f)
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Delete All") then
      local d, f = delete_unused_rows(true)
      StatusMsg = string.format("Delete all: removed %d, failed %d.", d, f)
    end

    ImGui.Separator(ctx)
    if #UnusedRows == 0 then
      ImGui.Text(ctx, "No unused files listed. Click Analyze to refresh.")
    else
      local flags = ImGui.TableFlags_Borders | ImGui.TableFlags_RowBg | ImGui.TableFlags_ScrollY | ImGui.TableFlags_SizingStretchProp
      if ImGui.BeginTable(ctx, "unused_files_tbl", 4, flags, 0, 360) then
        ImGui.TableSetupColumn(ctx, "Sel", ImGui.TableColumnFlags_WidthFixed, 50)
        ImGui.TableSetupColumn(ctx, "Size", ImGui.TableColumnFlags_WidthFixed, 90)
        ImGui.TableSetupColumn(ctx, "Path", ImGui.TableColumnFlags_WidthStretch, 600)
        ImGui.TableSetupColumn(ctx, "Status", ImGui.TableColumnFlags_WidthStretch, 180)
        ImGui.TableHeadersRow(ctx)

        local root = UnusedReport.source_scope or path_dirname(master_path or "")
        for i, row in ipairs(UnusedRows) do
          ImGui.TableNextRow(ctx)
          ImGui.TableSetColumnIndex(ctx, 0)
          local changed, val = ImGui.Checkbox(ctx, "##unused_sel_" .. tostring(i), row.selected or false)
          if changed then row.selected = val end
          ImGui.TableSetColumnIndex(ctx, 1); ImGui.Text(ctx, string.format("%.1f KB", (row.size or 0) / 1024))
          ImGui.TableSetColumnIndex(ctx, 2); ImGui.Text(ctx, path_relative_to(root, row.path))
          if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, row.path) end
          ImGui.TableSetColumnIndex(ctx, 3); ImGui.Text(ctx, row.error or "")
        end
        ImGui.EndTable(ctx)
      end
    end
  end
  ImGui.End(ctx)

  UnusedWindowOpen = open
end

local function draw_toolbar(master_path, container_path, cont_tbl)
  if ImGui.Button(ctx, "Save New") then
    local ok, err = save_new_version(container_path, nil)
    if not ok then StatusMsg = err end
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Save New (prompt)") then
    PromptNewName = ""
    PromptNewNameOpen = true
    ImGui.OpenPopup(ctx, "Name New Version")
  end
  ImGui.SameLine(ctx)
  ImGui.BeginDisabled(ctx, SelectedIndex == 0)
  if ImGui.Button(ctx, "Overwrite Selected") then
    local ok, err = overwrite_version(container_path, SelectedIndex)
    if not ok then StatusMsg = err end
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Delete Selected") then
    local ok, err = delete_version(container_path, SelectedIndex)
    if ok then
      StatusMsg = "Version deleted."
      -- Move selection to previous item if possible; otherwise clear selection
      if SelectedIndex > 1 then
        SelectedIndex = SelectedIndex - 1
      else
        SelectedIndex = 0
      end
    else
      StatusMsg = err or "Delete failed."
    end
  end
  ImGui.EndDisabled(ctx)
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Clean Temp Now") then
    if DebugCleanup then DebugLog("cleanup: manual trigger via toolbar") end
    local ok, err = pcall(cleanup_workspace)
    if DebugCleanup then
      if ok then
        DebugLog("cleanup: manual trigger finished ok=true")
      else
        DebugLog("cleanup: manual trigger finished ok=false err=" .. tostring(err))
      end
    end
    StatusMsg = ok and "Cleanup executed." or ("Cleanup error: " .. tostring(err))
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Settings") then
    ImGui.OpenPopup(ctx, "7RVM Settings")
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Delete Unused Files") then
    local rows, report, err = analyze_unused_files(master_path, container_path)
    UnusedWindowOpen = true
    if err then
      StatusMsg = "Unused scan failed: " .. tostring(err)
    else
      UnusedRows = rows
      UnusedReport = report
      StatusMsg = string.format("Unused scan complete: %d file(s) found.", #UnusedRows)
    end
  end

  -- Popup for naming
  if ImGui.BeginPopupModal(ctx, "Name New Version", true, ImGui.WindowFlags_AlwaysAutoResize) then
    ImGui.Text(ctx, "Enter version name:")
    ImGui.SetNextItemWidth(ctx, 300)
    local changedName, newname = ImGui.InputText(ctx, "##newver", PromptNewName)
    if changedName then PromptNewName = newname end
    if ImGui.Button(ctx, "Save") then
      local ok, err = save_new_version(container_path, PromptNewName ~= "" and PromptNewName or nil)
      if not ok then StatusMsg = err end
      ImGui.CloseCurrentPopup(ctx)
      PromptNewNameOpen = false
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Cancel") then
      ImGui.CloseCurrentPopup(ctx)
      PromptNewNameOpen = false
    end
    ImGui.EndPopup(ctx)
  end

  -- Settings modal
  if ImGui.BeginPopupModal(ctx, "7RVM Settings", true, ImGui.WindowFlags_AlwaysAutoResize) then
    ImGui.Text(ctx, "Debug")
    ImGui.Separator(ctx)
    do
      local changedDbg, newDbg = ImGui.Checkbox(ctx, "Debug cleanup", DebugCleanup)
      if changedDbg then
        DebugCleanup = newDbg
        reaper.ShowConsoleMsg("Debug cleanup " .. (DebugCleanup and "enabled" or "disabled") .. "\n")
      end
      if ImGui.IsItemHovered(ctx) then
        ImGui.SetTooltip(ctx, "Logs detailed info about cleanup decisions to the ReaScript console")
      end
    end
    ImGui.Separator(ctx)
    if ImGui.Button(ctx, "Close") then
      ImGui.CloseCurrentPopup(ctx)
    end
    ImGui.EndPopup(ctx)
  end
end

local function draw_versions_table(master_path, container_path, cont_tbl)
  local flags = ImGui.TableFlags_Borders | ImGui.TableFlags_RowBg | ImGui.TableFlags_SizingStretchProp

  -- Determine opened statuses by scanning all tabs
  local open_set, open_versions_by_container = get_open_workspace_info()
  local master_open = open_set[normalize_path(master_path)] or false
  local container_norm = normalize_path(container_path)
  local cont_name = path_stem(path_basename(container_path))

  -- Determine focused project info for yellow highlight
  local cur_path = get_current_project_path()
  local cur_norm = normalize_path(cur_path)
  local cur_stem = path_stem(path_basename(cur_path))
  local cur_container_norm = normalize_path(get_proj_ext(0, VM.EXT_CONTAINER_PATH))

  if ImGui.BeginTable(ctx, "versions", 7, flags) then
    ImGui.TableSetupColumn(ctx, "Role", ImGui.TableColumnFlags_WidthFixed, 90)
    ImGui.TableSetupColumn(ctx, "Status", ImGui.TableColumnFlags_WidthFixed, 80)
    ImGui.TableSetupColumn(ctx, "Name", ImGui.TableColumnFlags_WidthStretch, 200)
    ImGui.TableSetupColumn(ctx, "Timestamp", ImGui.TableColumnFlags_WidthFixed, 140)
    ImGui.TableSetupColumn(ctx, "Size", ImGui.TableColumnFlags_WidthFixed, 100)
    ImGui.TableSetupColumn(ctx, "ID", ImGui.TableColumnFlags_WidthStretch, 200)
    ImGui.TableSetupColumn(ctx, "Actions", ImGui.TableColumnFlags_WidthFixed, 260)
    ImGui.TableHeadersRow(ctx)

    -- Row 0: Master
    ImGui.TableNextRow(ctx)
    ImGui.TableSetColumnIndex(ctx, 0); ImGui.Text(ctx, "Master")
    ImGui.TableSetColumnIndex(ctx, 1); ImGui.Text(ctx, master_open and "Opened" or "")
    ImGui.TableSetColumnIndex(ctx, 2)
    local master_is_active = (cur_norm == normalize_path(master_path))
    if master_is_active then ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xFF00FFFF) end -- yellow text
    ImGui.Text(ctx, path_stem(path_basename(master_path)))
    if master_is_active then ImGui.PopStyleColor(ctx) end
    ImGui.TableSetColumnIndex(ctx, 3); ImGui.Text(ctx, "(current)")
    ImGui.TableSetColumnIndex(ctx, 4); ImGui.Text(ctx, "-")
    ImGui.TableSetColumnIndex(ctx, 5); ImGui.Text(ctx, path_basename(master_path))
    ImGui.TableSetColumnIndex(ctx, 6)
    if ImGui.Button(ctx, "Load (current)") then
      if file_exists(master_path) then
        open_project_in_current(master_path)
      else
        StatusMsg = "Master project not found on disk."
      end
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Load (new tab)") then
      if file_exists(master_path) then
        open_project_in_new_tab(master_path)
      else
        StatusMsg = "Master project not found on disk."
      end
    end
    if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, master_path) end

    -- Versions
    for i, v in ipairs(cont_tbl.versions or {}) do
      ImGui.TableNextRow(ctx)
      local is_selected = (SelectedIndex == i)
      if is_selected then ImGui.TableSetBgColor(ctx, ImGui.TableBgTarget_RowBg0, 0x3020A0A0) end

      -- Compute expected stem "masterstem_sanitizedVersionName"
      local ver_name = (v.name and v.name ~= "" and v.name) or "version"
      local safe_ver = ver_name:gsub("[^%w%-%._ ]", "_"):gsub("%s+", "_")
      local expected_stem = string.format("%s_%s", cont_name, safe_ver)
      local is_opened = open_versions_by_container[container_norm]
                        and open_versions_by_container[container_norm][expected_stem] or false
      local is_active_here = (cur_container_norm == container_norm) and (cur_stem == expected_stem)

      ImGui.TableSetColumnIndex(ctx, 0); ImGui.Text(ctx, "Version")
      ImGui.TableSetColumnIndex(ctx, 1); ImGui.Text(ctx, is_opened and "Opened" or "")
      ImGui.TableSetColumnIndex(ctx, 2)
      local label = (v.name and v.name ~= "" and v.name) or "(unnamed)"
      if is_active_here then ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xFF00FFFF) end -- yellow text
      if ImGui.Selectable(ctx, label .. "##row" .. tostring(i), is_selected) then
        SelectedIndex = i
      end
      if is_active_here then ImGui.PopStyleColor(ctx) end
      if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Click row to select for overwrite") end

      ImGui.TableSetColumnIndex(ctx, 3); ImGui.Text(ctx, os.date("%Y-%m-%d %H:%M:%S", v.timestamp or 0))
      ImGui.TableSetColumnIndex(ctx, 4); ImGui.Text(ctx, string.format("%.1f KB", (v.size or 0)/1024))
      ImGui.TableSetColumnIndex(ctx, 5); ImGui.Text(ctx, tostring(v.id or ""))
      ImGui.TableSetColumnIndex(ctx, 6)
      -- Actions
      if ImGui.Button(ctx, ("Load (current)##%d"):format(i)) then
        local out_path, err = extract_version_to_workspace(container_path, v)
        if out_path then open_project_in_current(out_path) else StatusMsg = err end
      end
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, ("Load (new tab)##%d"):format(i)) then
        local out_path, err = extract_version_to_workspace(container_path, v)
        if out_path then open_project_in_new_tab(out_path) else StatusMsg = err end
      end
      ImGui.SameLine(ctx)
      -- Rename (disabled if opened)
      if is_opened then ImGui.BeginDisabled(ctx, true) end
      if ImGui.Button(ctx, ("Rename##%d"):format(i)) then
        RenameIndex = i
        RenameInput = v.name or ""
        ImGui.OpenPopup(ctx, "Rename Version")
      end
      if is_opened then ImGui.EndDisabled(ctx) end
      ImGui.SameLine(ctx)
      -- Delete (disabled if opened)
      if is_opened then ImGui.BeginDisabled(ctx, true) end
      if ImGui.Button(ctx, ("Delete##%d"):format(i)) then
        DeleteIndex = i
        ImGui.OpenPopup(ctx, "Delete Version?")
      end
      if is_opened then ImGui.EndDisabled(ctx) end
    end

    -- Rename modal
    if ImGui.BeginPopupModal(ctx, "Rename Version", true, ImGui.WindowFlags_AlwaysAutoResize) then
      ImGui.Text(ctx, "Enter new name:")
      ImGui.SetNextItemWidth(ctx, 320)
      local _, newtxt = ImGui.InputText(ctx, "##rename_input", RenameInput or "")
      if _ then RenameInput = newtxt end
      if ImGui.Button(ctx, "Save") then
        if RenameIndex then
          local ok, err = rename_version(container_path, RenameIndex, RenameInput)
          if not ok then StatusMsg = err else StatusMsg = "Version renamed." end
        end
        RenameIndex = nil
        RenameInput = ""
        ImGui.CloseCurrentPopup(ctx)
      end
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, "Cancel") then
        RenameIndex = nil
        RenameInput = ""
        ImGui.CloseCurrentPopup(ctx)
      end
      ImGui.EndPopup(ctx)
    end

    -- Delete modal
    if ImGui.BeginPopupModal(ctx, "Delete Version?", true, ImGui.WindowFlags_AlwaysAutoResize) then
      ImGui.Text(ctx, "This will remove the version entry from the container.")
      ImGui.Text(ctx, "Temp workspace file (if present and closed) will also be deleted.")
      ImGui.Separator(ctx)
      if ImGui.Button(ctx, "Delete") then
        if DeleteIndex then
          local ok, err = delete_version(container_path, DeleteIndex)
          if not ok then StatusMsg = err else StatusMsg = "Version deleted." end
        end
        DeleteIndex = nil
        ImGui.CloseCurrentPopup(ctx)
      end
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, "Cancel") then
        DeleteIndex = nil
        ImGui.CloseCurrentPopup(ctx)
      end
      ImGui.EndPopup(ctx)
    end

    ImGui.EndTable(ctx)
  end
end

local function draw_body()
  ImGui.PushFont(ctx, FontTitle)
  ImGui.Text(ctx, VM.APP_NAME)
  ImGui.PopFont(ctx)

  local master_path, container_path, derr = detect_master_and_container()
  if derr then
    ImGui.TextColored(ctx, 0xFF8080FF, derr)
    if ImGui.Button(ctx, "Save Project...") then
      reaper.Main_OnCommand(40022, 0)
    end
    return
  end

  local cont_tbl, err = load_container(container_path, master_path)
  if not cont_tbl then
    ImGui.TextColored(ctx, 0xFF8080FF, "Container error: " .. tostring(err))
    return
  end

  -- Show paths
  ImGui.Text(ctx, "Master: " .. master_path)
  ImGui.Text(ctx, "Container: " .. container_path)
  ImGui.Separator(ctx)

  draw_toolbar(master_path, container_path, cont_tbl)
  ImGui.Separator(ctx)

  draw_versions_table(master_path, container_path, cont_tbl)
  draw_unused_files_window(master_path, container_path)

  if StatusMsg ~= "" then
    ImGui.Separator(ctx)
    ImGui.TextColored(ctx, 0x80FF80FF, StatusMsg)
  end
end




-- Forward declaration so background_loop captures the local, not a global
local main_loop

-- Cleanup driver that only runs while GUI is open: trigger on project list changes
local LastProjectsSig = LastProjectsSig or nil
local function projects_signature()
  local paths = {}
  local i = 0
  while true do
    local proj = reaper.EnumProjects(i, "")
    if not proj then break end
    local _, p = reaper.EnumProjects(i, "")
    if p and p ~= "" then
      paths[#paths+1] = normalize_path(p)
    end
    i = i + 1
  end
  table.sort(paths)
  return table.concat(paths, "|")
end

local function maybe_cleanup_on_project_change()
  local sig = projects_signature()
  if sig ~= LastProjectsSig then
    if DebugCleanup then DebugLog(("projects changed -> triggering cleanup; prev='%s' new='%s'"):format(tostring(LastProjectsSig), tostring(sig))) end
    LastProjectsSig = sig
    if DebugCleanup then DebugLog("cleanup: begin (project change)") end
    local ok, err = pcall(cleanup_workspace)
    if DebugCleanup then
      if ok then
        DebugLog("cleanup: end (project change) ok=true")
      else
        DebugLog("cleanup: end (project change) ok=false err=" .. tostring(err))
      end
    end
  end
end

local function main_loop()
  if not Window_Open then return end

  -- Prune closed temp projects only when project list changes (GUI open only)
  maybe_cleanup_on_project_change()

  ImGui.PushFont(ctx, Font)

  -- Restore window pos/size on first show of this session
  if UI_X and UI_Y then
    ImGui.SetNextWindowPos(ctx, UI_X, UI_Y, ImGui.Cond_FirstUseEver)
  end
  if UI_W and UI_H then
    ImGui.SetNextWindowSize(ctx, UI_W, UI_H, ImGui.Cond_FirstUseEver)
  end

  local visible, open = ImGui.Begin(ctx, VM.APP_NAME, true)
  if visible then
    draw_body()

    -- Close GUI on ESC (background watcher continues if enabled)
    if ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then
      open = false
    end

    -- Persist window position and size changes
    local x, y = ImGui.GetWindowPos(ctx)
    local w, h = ImGui.GetWindowSize(ctx)
    local changed = false
    if x and y and w and h then
      if UI_X ~= x then UI_X = x; changed = true end
      if UI_Y ~= y then UI_Y = y; changed = true end
      if UI_W ~= w then UI_W = w; changed = true end
      if UI_H ~= h then UI_H = h; changed = true end
    end
    if changed then save_ui_state() end

    ImGui.End(ctx)
  end
  ImGui.PopFont(ctx)

  if open then
    reaper.defer(main_loop)
  else
    Window_Open = false
    -- Dedicated watcher handles background; nothing to schedule here.
  end
end

-- Initialize
do
  -- Load saved UI position/size
  pcall(load_ui_state)

  -- Remove stale temp projects on startup; keep only currently open ones
  pcall(cleanup_workspace)

  -- Initialize extstate best-effort
  local master_path, container_path = detect_master_and_container()
  -- If current is master, ensure extstate reflects that
  if master_path and container_path then
    local role = get_proj_ext(0, VM.EXT_ROLE_KEY)
    if role == "master" then
      set_proj_ext_role(0, "master", master_path, container_path, "", "")
    end
  end
end

reaper.defer(main_loop)

-- Cleanup
reaper.atexit(function()
  -- Persist last known window position/size
  pcall(save_ui_state)

  -- On script exit, remove any temp projects not open in REAPER
  pcall(cleanup_workspace)

  -- Destroy ImGui context via ReaImGui C-API
  if ctx and reaper.ImGui_DestroyContext then
    reaper.ImGui_DestroyContext(ctx)
  end
end)
