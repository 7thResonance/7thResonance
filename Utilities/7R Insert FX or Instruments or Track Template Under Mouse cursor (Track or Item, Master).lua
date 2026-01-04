--[[
@description 7R Insert FX/Instruments/Track Template Under Mouse cursor (Track or Item, Master)
@author 7thResonance
@version 3.5
@changelog - Added "remeber last search term" setting
@donation https://paypal.me/7thresonance
@about Opens GUI for track, item or master under cursor with GUI to select FX
    - Saves position and size of GUI
    - Cache for quick search. Updates when new plugins are installed
    - Settings for basic options
    - Requires JS ReaScript and Imgui
@screenshot https://i.postimg.cc/DyqgzknJ/Screenshot-2025-07-11-062605.png
    https://i.postimg.cc/3JM17J5Q/Screenshot-2025-07-11-062614.png

--]]

-- REAIMGUI SETUP
if not reaper.ImGui_CreateContext then
  reaper.ShowMessageBox("ReaImGui not found! Please install via ReaPack.", "Error", 0)
  return
end

--------------------------------------------------------------------------
-- START: Integrated Sexan FX Browser Parser V7
--------------------------------------------------------------------------

local r                                = reaper
local os                               = r.GetOS()
local os_separator                     = package.config:sub(1, 1)
local script_path                      = debug.getinfo(1, "S").source:match [[^@?(.*[\/])[^\/]-$]]

local FX_FILE                          = script_path .. "/FX_LIST.txt"
local FX_CAT_FILE                      = script_path .. "/FX_CAT_FILE.txt"
local FX_DEV_LIST_FILE                 = script_path .. "/FX_DEV_LIST_FILE.txt"
local FX_STAT_FILE                     = script_path .. "/FX_VST_STAT.txt"

local CAT                              = {}
local DEVELOPER_LIST                   = { " (Waves)" }
local PLUGIN_LIST                      = {}
local INSTRUMENTS                      = {}
local VST_INFO, VST, VSTi, VST3, VST3i = {}, {}, {}, {}, {}
local JS_INFO, JS                      = {}, {}
local AU_INFO, AU, AUi                 = {}, {}, {}
local CLAP_INFO, CLAP, CLAPi           = {}, {}, {}
local LV2_INFO, LV2, LV2i              = {}, {}, {}

-- Feature flags
local ENABLE_FX_CHAINS = false -- set to true to enable FX Chains in the UI

local function ResetTables()
    CAT = {}
    DEVELOPER_LIST = { " (Waves)" }
    PLUGIN_LIST = {}
    INSTRUMENTS = {}
    VST_INFO, VST, VSTi, VST3, VST3i = {}, {}, {}, {}, {}
    JS_INFO, JS = {}, {}
    AU_INFO, AU, AUi = {}, {}, {}
    CLAP_INFO, CLAP, CLAPi = {}, {}, {}
    LV2_INFO, LV2, LV2i = {}, {}, {}
end

function MakeFXFiles()
    GetFXTbl()
    local serialized_fx = TableToString(PLUGIN_LIST)
    WriteToFile(FX_FILE, serialized_fx)

    local serialized_cat = TableToString(CAT)
    WriteToFile(FX_CAT_FILE, serialized_cat)

    local serialized_dev_list = TableToString(DEVELOPER_LIST)
    WriteToFile(FX_DEV_LIST_FILE, serialized_dev_list)

    return PLUGIN_LIST, CAT, DEVELOPER_LIST
end

function ReadFXFile()
    local fx_file = io.open(FX_FILE, "r")
    if fx_file then
        PLUGIN_LIST = {}
        local fx_string = fx_file:read("*all")
        fx_file:close()
        PLUGIN_LIST = StringToTable(fx_string)
    end

    local cat_file = io.open(FX_CAT_FILE, "r")
    if cat_file then
        CAT = {}
        local cat_string = cat_file:read("*all")
        cat_file:close()
        CAT = StringToTable(cat_string)
    end

    local dev_list_file = io.open(FX_DEV_LIST_FILE, "r")
    if dev_list_file then
        DEVELOPER_LIST = {}
        local dev_list_string = dev_list_file:read("*all")
        dev_list_file:close()
        DEVELOPER_LIST = StringToTable(dev_list_string)
    end

    return PLUGIN_LIST, CAT, DEVELOPER_LIST
end

function WriteToFile(path, data)
    local file_cat = io.open(path, "w")
    if file_cat then
        file_cat:write(data)
        file_cat:close()
    end
end

function SerializeToFile(val, name, skipnewlines, depth)
    skipnewlines = skipnewlines or false
    depth = depth or 0
    local tmp = string.rep(" ", depth)
    if name then
        if type(name) == "number" and math.floor(name) == name then
            name = "[" .. name .. "]"
        elseif not string.match(name, '^[a-zA-z_][a-zA-Z0-9_]*$') then
            name = string.gsub(name, "'", "''")
            name = "['" .. name .. "']"
        end
        tmp = tmp .. name .. " = "
    end
    if type(val) == "table" then
        tmp = tmp .. "{" .. (not skipnewlines and "\n" or "")
        for k, v in pairs(val) do
            tmp = tmp .. SerializeToFile(v, k, skipnewlines, depth + 1) .. "," .. (not skipnewlines and "\n" or "")
        end
        tmp = tmp .. string.rep(" ", depth) .. "}"
    elseif type(val) == "number" then
        tmp = tmp .. tostring(val)
    elseif type(val) == "string" then
        tmp = tmp .. string.format("%q", val)
    elseif type(val) == "boolean" then
        tmp = tmp .. (val and "true" or "false")
    else
        tmp = tmp .. "nil"
    end
    return tmp
end

function StringToTable(str)
    local f, err = load("return " .. str)
    if err then
        -- suppress console output
    end
    return f ~= nil and f() or nil
end

function TableToString(table) return SerializeToFile(table) end

function Literalize(str)
    return str:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", function(c) return "%" .. c end)
end

function GetFileContext(fp)
    local str = "\n"
    if not fp then return str end
    local f = io.open(fp, 'r')
    if f then
        str = f:read('a')
        f:close()
    end
    return str
end

-- File stat helpers (uses js_ReaScriptAPI if available)
local function FileExists(path)
    if not path then return false end
    if not reaper.JS_File_Stat then return false end
    local a, b, c = reaper.JS_File_Stat(path)
    if type(a) == 'boolean' then return a end
    if type(a) == 'number' then return true end
    if type(a) == 'table' then return true end
    return false
end

local function GetVSTPluginsFilePath()
    local rp = r.GetResourcePath()
    local candidates = {
        rp .. "/reaper-vstplugins64",
        rp .. "/reaper-vstplugins64.ini",
        rp .. "/reaper-vstplugins",
        rp .. "/reaper-vstplugins.ini",
    }
    for i = 1, #candidates do
        if FileExists(candidates[i]) then return candidates[i] end
    end
    -- fallback to the first candidate even if it doesn't exist
    return candidates[1]
end

local function GetFileStat(path)
    if not path then return nil end
    if not reaper.JS_File_Stat then return nil end
    local a, b, c = reaper.JS_File_Stat(path)
    -- a may be boolean (exists), number (size) or table depending on JS version
    if type(a) == 'boolean' then
        if not a then return nil end
        return { path = path, size = tonumber(b) or 0, mtime = tonumber(c) or 0 }
    elseif type(a) == 'number' then
        return { path = path, size = tonumber(a) or 0, mtime = tonumber(b) or 0 }
    elseif type(a) == 'table' then
        return { path = path, size = tonumber(a.size) or 0, mtime = tonumber(a.mtime) or 0 }
    end
    return nil
end

-- Return list of watched files (keys -> full path)
local function GetWatchedFiles()
    local rp = r.GetResourcePath()
    return {
        vst = GetVSTPluginsFilePath(),                 -- reaper-vstplugins* (existing)
        fxfolders = rp .. "/reaper-fxfolders.ini",   -- reaper-fxfolders
        clap = rp .. "/reaper-clap-win64",          -- reaper-clap-win64
        fxtags = rp .. "/reaper-fxtags.ini",        -- reaper-fxtags
        jsfx = rp .. "/reaper-jsfx.ini",            -- reaper-jsfx
    }
end

local function ReadStatFile()
    local f = io.open(FX_STAT_FILE, 'r')
    if not f then return nil end
    local s = f:read('*all')
    f:close()
    local ok, tbl = pcall(function() return StringToTable(s) end)
    if ok and type(tbl) == 'table' then return tbl end
    return nil
end

local function WriteStatFile(stat_tbl)
    if not stat_tbl then return end
    local s = TableToString(stat_tbl)
    WriteToFile(FX_STAT_FILE, s)
end

local function StatEquals(a, b)
    if not a or not b then return false end
    if a.path ~= b.path then return false end
    -- Compare size and mtime; allow exact match only
    if tonumber(a.size) ~= tonumber(b.size) then return false end
    if tonumber(a.mtime) ~= tonumber(b.mtime) then return false end
    return true
end

local function GetDirFilesRecursive(dir, tbl, filter)
    for index = 0, math.huge do
        local path = r.EnumerateSubdirectories(dir, index)
        if not path then break end
        tbl[#tbl + 1] = { dir = path, {} }
        GetDirFilesRecursive(dir .. os_separator .. path, tbl[#tbl], filter)
    end

    for index = 0, math.huge do
        local file = r.EnumerateFiles(dir, index)
        if not file then break end
        if file:find(filter, nil, true) then
            tbl[#tbl + 1] = file:gsub(filter, "")
        end
    end
end

local function FindCategory(cat)
    for i = 1, #CAT do
        if CAT[i].name == cat then return CAT[i].list end
    end
end

local function FindFXIDName(tbl, id, js)
    for i = 1, #tbl do
        if js then
            if tbl[i].id:find(id) then return tbl[i].name end
        else
            if tbl[i].id == id then return tbl[i].name end
        end
    end
end

function InTbl(tbl, val)
    for i = 1, #tbl do
        if tbl[i].name == val then return tbl[i].fx end
    end
end

function AddDevList(val)
    for i = 1, #DEVELOPER_LIST do
        if DEVELOPER_LIST[i] == " (" .. val .. ")" then return end
    end
    DEVELOPER_LIST[#DEVELOPER_LIST + 1] = " (" .. val .. ")"
end

local function ParseVST(name, ident)
    if not name:match("^VST") then return end

    if name:match("VST: ") then
        VST[#VST + 1] = name
    elseif name:match("VSTi: ") then
        VSTi[#VSTi + 1] = name
        INSTRUMENTS[#INSTRUMENTS + 1] = name
    elseif name:match("VST3: ") then
        VST3[#VST3 + 1] = name
    elseif name:match("VST3i: ") then
        VST3i[#VST3i + 1] = name
        INSTRUMENTS[#INSTRUMENTS + 1] = name
    end
    ident = os:match("Win") and ident:reverse():match("(.-)\\") or ident:reverse():match("(.-)/")
    ident = ident:reverse():gsub(" ", "_"):gsub("-", "_")
    VST_INFO[#VST_INFO + 1] = { id = ident, name = name }
    PLUGIN_LIST[#PLUGIN_LIST + 1] = name
end

local function ParseJSFX(name, ident)
    if not name:match("^JS:") then return end
    JS[#JS + 1]                   = name
    JS_INFO[#JS_INFO + 1]         = { id = ident, name = name }
    PLUGIN_LIST[#PLUGIN_LIST + 1] = name
end

local function ParseAU(name, ident)
    if not name:match("^AU") then return end

    if name:match("AU: ") then
        AU[#AU + 1] = name
    elseif name:match("AUi: ") then
        AUi[#AUi + 1] = name
        INSTRUMENTS[#INSTRUMENTS + 1] = name
    end
    AU_INFO[#AU_INFO + 1]         = { id = ident, name = name }
    PLUGIN_LIST[#PLUGIN_LIST + 1] = name
end

local function ParseCLAP(name, ident)
    if not name:match("^CLAP") then return end

    if name:match("CLAP: ") then
        CLAP[#CLAP + 1] = name
    elseif name:match("CLAPi: ") then
        CLAPi[#CLAPi + 1] = name
        INSTRUMENTS[#INSTRUMENTS + 1] = name
    end
    CLAP_INFO[#CLAP_INFO + 1] = { id = ident, name = name }
    PLUGIN_LIST[#PLUGIN_LIST + 1] = name
end

local function ParseLV2(name, ident)
    if not name:match("^LV2") then return end

    if name:match("LV2: ") then
        LV2[#LV2 + 1] = name
    elseif name:match("LV2i: ") then
        LV2i[#LV2i + 1] = name
        INSTRUMENTS[#INSTRUMENTS + 1] = name
    end
    LV2_INFO[#LV2_INFO + 1] = { id = ident, name = name }
    PLUGIN_LIST[#PLUGIN_LIST + 1] = name
end

local function has_fx(tbl, val)
    for i = 1, #tbl do
        if tbl[i] == val then return true end
    end
    return false
end

local function ParseFXTags()
    local tags_path = r.GetResourcePath() .. "/reaper-fxtags.ini"
    local tags_str  = GetFileContext(tags_path)
    local DEV       = true
    for line in tags_str:gmatch('[^\r\n]+') do
        local category = line:match("^%[(.+)%]")
        if line:match("^%[(category)%]") then
            DEV = false
        end
        if category then
            CAT[#CAT + 1] = { name = category:upper(), list = {} }
        end
        local FX, dev_category = line:match("(.+)=(.+)")
        if dev_category then
            dev_category = dev_category:gsub("[%[%]]", "")
            if DEV then AddDevList(dev_category) end
            local fx_name = FindFXIDName(VST_INFO, FX)
            fx_name = fx_name and fx_name or FindFXIDName(AU_INFO, FX)
            fx_name = fx_name and fx_name or FindFXIDName(CLAP_INFO, FX)
            fx_name = fx_name and fx_name or FindFXIDName(JS_INFO, FX, "JS")
            fx_name = fx_name and fx_name or FindFXIDName(LV2_INFO, FX)
            if dev_category:match("|") then
                for category_type in dev_category:gmatch('[^%|]+') do
                    local dev_tbl = InTbl(CAT[#CAT].list, category_type)
                    if fx_name then
                        if not dev_tbl then
                            table.insert(CAT[#CAT].list, { name = category_type, fx = { fx_name } })
                        else
                            if not has_fx(dev_tbl, fx_name) then
                                table.insert(dev_tbl, fx_name)
                            end
                        end
                    end
                end
            else
                local dev_tbl = InTbl(CAT[#CAT].list, dev_category)
                if fx_name then
                    if not dev_tbl then
                        table.insert(CAT[#CAT].list, { name = dev_category, fx = { fx_name } })
                    else
                        if not has_fx(dev_tbl, fx_name) then
                            table.insert(dev_tbl, fx_name)
                        end
                    end
                end
            end
        end
    end
end

local function ParseCustomCategories()
    local fav_path = r.GetResourcePath() .. "/reaper-fxfolders.ini"
    local fav_str  = GetFileContext(fav_path)
    local cur_cat_tbl
    for line in fav_str:gmatch('[^\r\n]+') do
        local category = line:match("%[(.-)%]")

        if category then
            if category == "category" then
                cur_cat_tbl = FindCategory(category:upper())
            elseif category == "developer" then
                cur_cat_tbl = FindCategory(category:upper())
            else
                cur_cat_tbl = nil
            end
        end

        if cur_cat_tbl then
            local FX, categories = line:match("(.+)=(.+)")
            if categories then
                local fx_name = FindFXIDName(VST_INFO, FX)
                fx_name = fx_name and fx_name or FindFXIDName(AU_INFO, FX)
                fx_name = fx_name and fx_name or FindFXIDName(CLAP_INFO, FX)
                fx_name = fx_name and fx_name or FindFXIDName(JS_INFO, FX, "JS")
                fx_name = fx_name and fx_name or FindFXIDName(LV2_INFO, FX)
                for category_type in categories:gmatch('([^+%-%|]+)') do
                    local dev_tbl = InTbl(cur_cat_tbl, category_type)
                    if fx_name then
                        if not dev_tbl then
                            table.insert(cur_cat_tbl, { name = category_type, fx = { fx_name } })
                        else
                            if not has_fx(dev_tbl, fx_name) then
                                table.insert(dev_tbl, fx_name)
                            end
                        end
                    end
                end
            end
        end
    end
end

local function SortFoldersINI(fav_str)
    local folders = {}
    local add
    for line in fav_str:gmatch('[^\r\n]+') do
        local category = line:match("^%[(.-)%]")
        if category then
            if category:find("Folder", nil, true) then
                add = true
                folders[#folders + 1] = { name = category }
            else
                add = false
            end
            if settings then
                settings.last_left_section = "all"
                settings.last_left_value = ""
                if save_settings then save_settings() end
            end
        end
        if folders[#folders] and not category and add then
            folders[#folders][#folders[#folders] + 1] = line .. "\n"
        end
    end

    local main_folder
    for i = #folders, 1, -1 do
        table.sort(folders[i])
        table.insert(folders[i], 1, "[" .. folders[i].name .. "]\n")
        if folders[i].name == "Folders" then
            main_folder = table.remove(folders, i)
        end
    end
    folders[#folders + 1] = main_folder

    local sorted = ""
    for i = 1, #folders do
        folders[i].name = nil
        sorted = sorted .. table.concat(folders[i])
    end

    return sorted
end

local magic = {
    ["not"] = { ' and ', ' not %s:find("%s") ' },
    ["or"] = { ' or ', ' %s:find("%s") ' },
    ["and"] = { ' and ', '%s:find("%s") ' },
}

local function ParseSmartFolder(smart_string)
    local smart_terms = {}
    local SMART_FX = {}

    for exact in smart_string:gmatch('"(.-)"') do
        smart_string = smart_string:gsub('"' .. exact .. '"', '_schwa_magic_' .. exact:gsub(' ', '|||'))
    end

    smart_string = smart_string:gsub('"', '')

    for term in smart_string:gmatch("([^%s]+)") do
        term = term:lower():gsub('[%(%)%.%+%-%*%?%[%]%^%$%%]', '%%%1')
        if term:find('_schwa_magic_') then
            term = term:gsub('_schwa_magic_', '')
            if term:find('|||') then
                term = '(' .. term:gsub('|||', ' ') .. ')'
            else
                term = '%A' .. term .. '%A'
            end
        end
        smart_terms[#smart_terms + 1] = term
    end

    local code_gen = { "for i = 1, #PLUGIN_LIST do\nlocal target = PLUGIN_LIST[i]:lower()", "" }

    local add_magic
    for i = 1, #smart_terms do
        if magic[smart_terms[i]] then
            add_magic = i > 1 and (magic[smart_terms[i]][1] .. magic[smart_terms[i]][2]) or magic[smart_terms[i]][2]
        else
            if add_magic then
                code_gen[2] = code_gen[2] .. add_magic:format("target", smart_terms[i])
                add_magic = nil
            else
                code_gen[2] = i > 1 and code_gen[2] .. " and " .. (' %s:find("%s")'):format("target", smart_terms[i]) or
                    code_gen[2] .. (' %s:find("%s")'):format("target", smart_terms[i])
            end
        end
    end

    code_gen[2] = 'if ' .. code_gen[2] .. ' then'
    code_gen[#code_gen + 1] = 'SMART_FX[#SMART_FX+1] = PLUGIN_LIST[i]\nend\nend\n'

    local code_str = table.concat(code_gen, "\n")

    local func_env = {
        SMART_FX = SMART_FX,
        PLUGIN_LIST = PLUGIN_LIST,
        string = string,
    }

    local func, err = load(code_str, "ScriptRun", "t", func_env)

    if func then
        local status, err2 = pcall(func)
        if err2 then
            -- suppress console output
        end
    end
    return SMART_FX
end

local function ParseFavorites()
    local fav_path    = r.GetResourcePath() .. "/reaper-fxfolders.ini"
    local fav_str     = GetFileContext(fav_path)
    fav_str           = SortFoldersINI(fav_str)
    CAT[#CAT + 1]     = { name = "FOLDERS", list = {} }
    local item_lookup = {}
    local current_folder
    for line in fav_str:gmatch('[^\r\n]+') do
        local folder = line:match("^%[(Folder%d+)%]")

        if folder then current_folder = folder end

        if line:match("Item%d+") then
            local item_id, item_path = line:match("Item(%d+)=(.+)")
            local item = "R_ITEM_" .. item_path
            item_lookup[item_id] = item_path
            local dev_tbl = InTbl(CAT[#CAT].list, current_folder)
            if not dev_tbl then
                table.insert(CAT[#CAT].list,
                    { name = current_folder, fx = { item }, order = current_folder:match("Folder(%d+)") })
            else
                table.insert(dev_tbl, item)
            end
        end

        if line:match("Type%d+") then
            local line_id, fx_type = line:match("(%d+)=(%d+)")
            local folder_item = item_lookup[line_id]
            if folder_item then
                local item = folder_item:gsub("R_ITEM_", "", 1)
                local fx_found
                if fx_type == "3" then -- VST
                    local id = os:match("Win") and item:reverse():match("(.-)\\") or item:reverse():match("(.-)/")
                    if id then
                        id = id:reverse():gsub(" ", "_"):gsub("-", "_")
                        fx_found = FindFXIDName(VST_INFO, id)
                    end
                elseif fx_type == "2" then -- JSFX
                    fx_found = FindFXIDName(JS_INFO, item)
                elseif fx_type == "7" then -- CLAP
                    fx_found = FindFXIDName(CLAP_INFO, item)
                elseif fx_type == "1" then -- LV2
                    fx_found = FindFXIDName(LV2_INFO, item)
                elseif fx_type == "5" then -- AU
                    fx_found = FindFXIDName(AU_INFO, item)
                elseif fx_type == "1048576" then -- SMART FOLDER
                    CAT[#CAT].list[#CAT[#CAT].list].smart = true
                    CAT[#CAT].list[#CAT[#CAT].list].fx = ParseSmartFolder(item)
                elseif fx_type == "1000" then -- FX CHAIN
                    table.insert(CAT[#CAT].list[#CAT[#CAT].list].fx, item .. ".RfxChain")
                end
                if fx_found then
                    table.insert(CAT[#CAT].list[#CAT[#CAT].list].fx, fx_found)
                end
            end
        end

        if line:match("Name%d+=(.+)") then
            local folder_name = line:match("Name%d+=(.+)")
            local folder_ID = line:match("(%d+)=")

            for i = 1, #CAT[#CAT].list do
                if CAT[#CAT].list[i].name == "Folder" .. folder_ID then
                    CAT[#CAT].list[i].name = folder_name
                end
            end
        end
    end

    table.sort(CAT[#CAT].list, function(a, b) return tonumber(a.order) < tonumber(b.order) end)

    for i = 1, #CAT do
        for j = #CAT[i].list, 1, -1 do
            if CAT[i].list[j] then
                for f = #CAT[i].list[j].fx, 1, -1 do
                    if CAT[i].list[j].fx[f]:find("R_ITEM_") then
                        table.remove(CAT[i].list[j].fx, f)
                    end
                end
            end
        end
    end
end

local function ParseFXChains()
    local fxChainsFolder = r.GetResourcePath() .. "/FXChains"
    local FX_CHAINS = {}
    GetDirFilesRecursive(fxChainsFolder, FX_CHAINS, ".RfxChain")
    return FX_CHAINS
end

local function ParseTrackTemplates()
    local trackTemplatesFolder = r.GetResourcePath() .. "/TrackTemplates"
    local TRACK_TEMPLATES = {}
    GetDirFilesRecursive(trackTemplatesFolder, TRACK_TEMPLATES, ".RTrackTemplate")
    return TRACK_TEMPLATES
end

-- Generic converter: turn a parser file-tree (nested tables/strings) into CAT-style entries
local function ConvertFileTreeToCATList(parsed_table, extension)
    extension = extension or ""
    local function convert_children(node, rel_path)
        rel_path = rel_path or ""
        local out = {}
        for _, child in ipairs(node) do
            if type(child) == "table" then
                if child.dir then
                    local folder_name = child.dir
                    local new_rel = (rel_path == "") and folder_name or (rel_path .. "/" .. folder_name)
                    local children_table = {}
                    for _, v in ipairs(child) do table.insert(children_table, v) end
                    local folder_entry = { name = folder_name, fx = convert_children(children_table, new_rel) }
                    table.insert(out, folder_entry)
                end
            elseif type(child) == "string" then
                local full_name = ((rel_path ~= "") and (rel_path .. "/") or "") .. child .. extension
                table.insert(out, full_name)
            end
        end
        table.sort(out, function(a, b)
            local ta, tb = type(a), type(b)
            if ta ~= tb then return ta == "table" end
            if ta == "table" then return (a.name or ""):lower() < (b.name or ""):lower() end
            return (tostring(a)):lower() < (tostring(b)):lower()
        end)
        return out
    end
    return convert_children(parsed_table, "")
end

-- Backwards-compatible wrapper for track templates
local function ConvertTrackTemplatesToCATList(parsed_table)
    return ConvertFileTreeToCATList(parsed_table, ".RTrackTemplate")
end

-- Helper: flatten a CAT category (folders + nested entries) into a flat array of string entries
local function FlattenCatCategoryToList(cat_name)
    local out = {}
    local function collect_from_list(lst)
        if not lst then return end
        for _, entry in ipairs(lst) do
            if type(entry) == 'string' then
                table.insert(out, entry)
            elseif type(entry) == 'table' then
                -- entry may have .fx (folders) or be a folder table
                if entry.fx and type(entry.fx) == 'table' then
                    collect_from_list(entry.fx)
                else
                    -- fallback: iterate numeric children
                    collect_from_list(entry)
                end
            end
        end
    end
    for i = 1, #CAT do
        if CAT[i].name == cat_name and CAT[i].list then
            for _, e in ipairs(CAT[i].list) do
                if type(e) == 'string' then
                    table.insert(out, e)
                elseif type(e) == 'table' then
                    if e.fx and type(e.fx) == 'table' then
                        collect_from_list(e.fx)
                    else
                        collect_from_list(e)
                    end
                end
            end
            break
        end
    end
    return out
end

-- Cached views for two-pane mode (built from canonical data)
local views = { all = {}, fxchains = {}, tracktemplates = {}, instruments = {} }

local function BuildViews()
    -- All plugins (flat)
    views.all = {}
    for _, v in ipairs(PLUGIN_LIST or {}) do
        table.insert(views.all, v)
    end

    -- FX Chains
    if ENABLE_FX_CHAINS then
        views.fxchains = FlattenCatCategoryToList("FX CHAINS") or {}
    else
        views.fxchains = {}
    end

    -- Track Templates
    views.tracktemplates = FlattenCatCategoryToList("TRACK TEMPLATES") or {}

    -- Instruments
    views.instruments = {}
    for _, v in ipairs(INSTRUMENTS or {}) do table.insert(views.instruments, v) end

    -- Deduplicate PLUGIN_LIST-derived views if necessary (simple pass)
    local function dedupe(tbl)
        local seen = {}
        local out = {}
        for _, s in ipairs(tbl) do
            if type(s) == 'string' and not seen[s] then seen[s]=true; table.insert(out, s) end
        end
        return out
    end
    views.all = dedupe(views.all)
    views.fxchains = dedupe(views.fxchains)
    views.tracktemplates = dedupe(views.tracktemplates)
    views.instruments = dedupe(views.instruments)
    -- Sort views deterministically (case-insensitive)
    local function sort_ci(tbl)
        table.sort(tbl, function(a,b) return (tostring(a):lower() < tostring(b):lower()) end)
    end
    sort_ci(views.all)
    sort_ci(views.fxchains)
    sort_ci(views.tracktemplates)
    sort_ci(views.instruments)

    -- If instruments list is empty after rebuild, try to infer instruments from PLUGIN_LIST
    if #views.instruments == 0 and PLUGIN_LIST and #PLUGIN_LIST > 0 then
        for _, pname in ipairs(PLUGIN_LIST) do
            if type(pname) == 'string' then
                local p = pname
                if p:match("^%s*VSTi%s*:") or p:match("^%s*VST3i%s*:") or p:match("^%s*AUi%s*:") or p:match("^%s*CLAPi%s*:") or p:match("^%s*LV2i%s*:") then
                    table.insert(views.instruments, pname)
                end
            end
        end
        -- Deduplicate & sort again
        views.instruments = dedupe(views.instruments)
        sort_ci(views.instruments)
        -- Update global INSTRUMENTS to keep consistency
        INSTRUMENTS = {}
        for _, v in ipairs(views.instruments) do table.insert(INSTRUMENTS, v) end
    end
end

local function AllPluginsCategory()
    CAT[#CAT + 1] = { name = "ALL PLUGINS", list = {} }
    if #JS ~= 0 then table.insert(CAT[#CAT].list, { name = "JS", fx = JS }) end
    if #AU ~= 0 then table.insert(CAT[#CAT].list, { name = "AU", fx = AU }) end
    if #AUi ~= 0 then table.insert(CAT[#CAT].list, { name = "AUi", fx = AUi }) end
    if #CLAP ~= 0 then table.insert(CAT[#CAT].list, { name = "CLAP", fx = CLAP }) end
    if #CLAPi ~= 0 then table.insert(CAT[#CAT].list, { name = "CLAPi", fx = CLAPi }) end
    if #VST ~= 0 then table.insert(CAT[#CAT].list, { name = "VST", fx = VST }) end
    if #VSTi ~= 0 then table.insert(CAT[#CAT].list, { name = "VSTi", fx = VSTi }) end
    if #VST3 ~= 0 then table.insert(CAT[#CAT].list, { name = "VST3", fx = VST3 }) end
    if #VST3i ~= 0 then table.insert(CAT[#CAT].list, { name = "VST3i", fx = VST3i }) end
    if #LV2 ~= 0 then table.insert(CAT[#CAT].list, { name = "LV2", fx = LV2 }) end
    if #LV2i ~= 0 then table.insert(CAT[#CAT].list, { name = "LV2i", fx = LV2i }) end

    for i = 1, #CAT do
        local is_fxchains = (CAT[i].name == "FX CHAINS")
        if CAT[i].name ~= "FOLDERS" and (not is_fxchains or ENABLE_FX_CHAINS) and CAT[i].name ~= "TRACK TEMPLATES" then
            table.sort(CAT[i].list,
                function(a, b) if a.name and b.name then return a.name:lower() < b.name:lower() end end)
        end
        for j = 1, #CAT[i].list do
            if CAT[i].list[j].fx then
                table.sort(CAT[i].list[j].fx, function(a, b) if a and b then return a:lower() < b:lower() end end)
            end
        end
    end

    table.sort(CAT, function(a, b) if a.name and b.name then return a.name:lower() < b.name:lower() end end)
end

function GenerateFxList()
    PLUGIN_LIST[#PLUGIN_LIST + 1] = "Container"
    PLUGIN_LIST[#PLUGIN_LIST + 1] = "Video processor"

    for i = 0, math.huge do
        local retval, name, ident = r.EnumInstalledFX(i)
        if not retval then break end
        ParseVST(name, ident)
        ParseJSFX(name, ident)
        ParseAU(name, ident)
        ParseCLAP(name, ident)
        ParseLV2(name, ident)
    end

    ParseFXTags() -- CATEGORIES
    ParseCustomCategories()
    ParseFavorites()
    -- FX Chains and Track Templates are discovered by parser; enable Track Templates category
    if ENABLE_FX_CHAINS then
        local FX_CHAINS = ParseFXChains()
        if FX_CHAINS and #FX_CHAINS ~= 0 then
            local converted_chains = ConvertFileTreeToCATList(FX_CHAINS, ".RfxChain")
            -- Wrap top-level strings into a default folder entry so the renderer sees entries with name/fx
            local fc_list = {}
            for _, v in ipairs(converted_chains) do
                if type(v) == "table" then
                    table.insert(fc_list, v)
                else
                    if #fc_list == 0 or type(fc_list[#fc_list]) ~= "table" then
                        table.insert(fc_list, { name = "FX Chains", fx = {} })
                    end
                    table.insert(fc_list[#fc_list].fx, v)
                end
            end
            -- If the converter produced a single default wrapper folder ("FX Chains"), flatten it
            if #fc_list == 1 and type(fc_list[1]) == "table" and fc_list[1].name == "FX Chains" then
                local wrapper = fc_list[1]
                if wrapper.fx and #wrapper.fx > 0 and type(wrapper.fx[1]) == "string" then
                    -- Files only: render them directly under the main node
                    CAT[#CAT + 1] = { name = "FX CHAINS", list = { { name = "FX Chains", fx = wrapper.fx, direct = true } } }
                else
                    -- Folder children: place them directly under the main node
                    CAT[#CAT + 1] = { name = "FX CHAINS", list = wrapper.fx }
                end
            else
                CAT[#CAT + 1] = { name = "FX CHAINS", list = fc_list }
            end
        end
    end
    local TRACK_TEMPLATES = ParseTrackTemplates()
    if TRACK_TEMPLATES and #TRACK_TEMPLATES ~= 0 then
        -- Convert parser nested structure into CAT-style folder list
        local converted = ConvertTrackTemplatesToCATList(TRACK_TEMPLATES)
        -- The CAT expects a list of entries with name/fx; wrap converted as top-level list entries
        local tt_list = {}
        for _, v in ipairs(converted) do
            if type(v) == "table" then
                table.insert(tt_list, v)
            else
                -- file entries: put them under a default folder entry
                if #tt_list == 0 or type(tt_list[#tt_list]) ~= "table" then
                    table.insert(tt_list, { name = "Track Templates", fx = {} })
                end
                table.insert(tt_list[#tt_list].fx, v)
            end
        end
        -- Flatten default wrapper folder for Track Templates as well
        if #tt_list == 1 and type(tt_list[1]) == "table" and tt_list[1].name == "Track Templates" then
            local wrapper = tt_list[1]
            if wrapper.fx and #wrapper.fx > 0 and type(wrapper.fx[1]) == "string" then
                CAT[#CAT + 1] = { name = "TRACK TEMPLATES", list = { { name = "Track Templates", fx = wrapper.fx, direct = true } } }
            else
                CAT[#CAT + 1] = { name = "TRACK TEMPLATES", list = wrapper.fx }
            end
        else
            CAT[#CAT + 1] = { name = "TRACK TEMPLATES", list = tt_list }
        end

        -- Also flatten templates into PLUGIN_LIST so they're searchable via the main search box
        for _, entry in ipairs(tt_list) do
            if entry.fx then
                for _, fxname in ipairs(entry.fx) do
                    if type(fxname) == "string" then
                        PLUGIN_LIST[#PLUGIN_LIST + 1] = fxname
                    end
                end
            end
        end
    end
    -- Add Instruments as its own top-level category
    if #INSTRUMENTS ~= 0 then
        -- Mark as direct so the renderer lists instruments immediately under the main node
        CAT[#CAT + 1] = { name = "INSTRUMENTS", list = { { name = "Instruments", fx = INSTRUMENTS, direct = true } } }
    end
    AllPluginsCategory()

    return PLUGIN_LIST
end

local sub = string.sub
function Stripname(name, prefix, suffix)
    if not DEVELOPER_LIST then return name end
    if suffix then
        for i = 1, #DEVELOPER_LIST do
            local ss, se = name:find(DEVELOPER_LIST[i], nil, true)
            if ss then
                name = sub(name, 0, ss)
                break
            end
        end
    end
    if prefix then
        local ps, pe = name:find("(%S+: )")
        if ps then
            name = sub(name, pe)
        end
    end
    return name
end

function GetFXTbl()
    ResetTables()
    return GenerateFxList(), CAT, DEVELOPER_LIST
end

function UpdateChainsTrackTemplates(cat_tbl)
    if not cat_tbl then return end
    local FX_CHAINS = ParseFXChains()
    local TRACK_TEMPLATES = ParseTrackTemplates()
    local chain_found, template_found
    for i = 1, #cat_tbl do
        if cat_tbl[i].name == "FX CHAINS" then
            -- Convert parser nested structure into CAT-style folder list (wrap top-level file strings)
            local converted_chains = ConvertFileTreeToCATList(FX_CHAINS, ".RfxChain")
            local fc_list = {}
            for _, v in ipairs(converted_chains) do
                if type(v) == "table" then
                    table.insert(fc_list, v)
                else
                    if #fc_list == 0 or type(fc_list[#fc_list]) ~= "table" then
                        table.insert(fc_list, { name = "FX Chains", fx = {} })
                    end
                    table.insert(fc_list[#fc_list].fx, v)
                end
            end
            cat_tbl[i].list = fc_list
            chain_found = true
        end
        if cat_tbl[i].name == "TRACK TEMPLATES" then
            -- Convert to CAT-style nested entries and set (wrap top-level strings)
            local converted = ConvertTrackTemplatesToCATList(TRACK_TEMPLATES)
            local tt_list = {}
            for _, v in ipairs(converted) do
                if type(v) == "table" then
                    table.insert(tt_list, v)
                else
                    if #tt_list == 0 or type(tt_list[#tt_list]) ~= "table" then
                        table.insert(tt_list, { name = "Track Templates", fx = {} })
                    end
                    table.insert(tt_list[#tt_list].fx, v)
                end
            end
            cat_tbl[i].list = tt_list
            template_found = true
        end
    end
    if not chain_found then
        local converted_chains = ConvertFileTreeToCATList(FX_CHAINS, ".RfxChain")
        local fc_list = {}
        for _, v in ipairs(converted_chains) do
            if type(v) == "table" then
                table.insert(fc_list, v)
            else
                if #fc_list == 0 or type(fc_list[#fc_list]) ~= "table" then
                    table.insert(fc_list, { name = "FX Chains", fx = {} })
                end
                table.insert(fc_list[#fc_list].fx, v)
            end
        end
        if #fc_list == 1 and type(fc_list[1]) == "table" and fc_list[1].name == "FX Chains" then
            local wrapper = fc_list[1]
            if wrapper.fx and #wrapper.fx > 0 and type(wrapper.fx[1]) == "string" then
                cat_tbl[#cat_tbl + 1] = { name = "FX CHAINS", list = { { name = "FX Chains", fx = wrapper.fx, direct = true } } }
            else
                cat_tbl[#cat_tbl + 1] = { name = "FX CHAINS", list = wrapper.fx }
            end
        else
            cat_tbl[#cat_tbl + 1] = { name = "FX CHAINS", list = fc_list }
        end
    end
    if not template_found then
        local converted = ConvertTrackTemplatesToCATList(TRACK_TEMPLATES)
        local tt_list = {}
        for _, v in ipairs(converted) do
            if type(v) == "table" then
                table.insert(tt_list, v)
            else
                if #tt_list == 0 or type(tt_list[#tt_list]) ~= "table" then
                    table.insert(tt_list, { name = "Track Templates", fx = {} })
                end
                table.insert(tt_list[#tt_list].fx, v)
            end
        end
        if #tt_list == 1 and type(tt_list[1]) == "table" and tt_list[1].name == "Track Templates" then
            local wrapper = tt_list[1]
            if wrapper.fx and #wrapper.fx > 0 and type(wrapper.fx[1]) == "string" then
                cat_tbl[#cat_tbl + 1] = { name = "TRACK TEMPLATES", list = { { name = "Track Templates", fx = wrapper.fx, direct = true } } }
            else
                cat_tbl[#cat_tbl + 1] = { name = "TRACK TEMPLATES", list = wrapper.fx }
            end
        else
            cat_tbl[#cat_tbl + 1] = { name = "TRACK TEMPLATES", list = tt_list }
        end
        -- Also add to PLUGIN_LIST for search (avoid duplicates)
        local function add_once(name)
            for _, v in ipairs(PLUGIN_LIST) do if v == name then return end end
            PLUGIN_LIST[#PLUGIN_LIST + 1] = name
        end
        for _, entry in ipairs(tt_list) do
            if entry.fx then
                for _, fxname in ipairs(entry.fx) do
                    if type(fxname) == "string" then add_once(fxname) end
                end
            end
        end
    end
    -- Rebuild cached views whenever chains/templates are updated
    BuildViews()
end

------------------------------------------------------
-- FOLDER-RESPECTING TRACK INSERTION (from user's helper script)
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


--------------------------------------------------------------------------
-- END: Integrated Sexan FX Browser Parser V7
--------------------------------------------------------------------------


local ctx = reaper.ImGui_CreateContext("7R FX Inserter")
-- Create font after loading settings in init to allow user-specified size; temporary default here
local font = reaper.ImGui_CreateFont('sans-serif', settings and settings.font_size or 11)
local bold_font = nil -- Bold font not available in this ReaImGui build
reaper.ImGui_Attach(ctx, font)

-- GLOBAL VARIABLES
local window_open = true
local selected_fx_idx = 1
local left_selection = { section = "all", index = 0 }
local settings_window_open = false

-- Search and keyboard navigation
local search_text = ""
local highlighted_fx_index = 1
local arrow_key_pressed = false

-- Drag-and-drop simulation state
local dragging = false
local drag_fx = nil
local drag_label = ""
local drag_start_x, drag_start_y = 0, 0
local drag_threshold = 6 -- pixels before we consider it a drag
local drag_candidate = nil
local drag_target_type = "none"
local drag_target_name = ""
local prev_selected_tracks = {}

-- Helper to detect instruments by name
local function is_instrument_name(name)
    if type(name) ~= "string" then return false end
    -- Match only explicit instrument prefixes (VSTi, VST3i, AUi, CLAPi, LV2i)
    if name:match("^%s*VSTi%s*:") or name:match("^%s*VST3i%s*:") or name:match("^%s*AUi%s*:") or name:match("^%s*CLAPi%s*:") or name:match("^%s*LV2i%s*:") then
        return true
    end
    for _, v in ipairs(INSTRUMENTS or {}) do
        if v == name then return true end
    end
    return false
end

-- The parser code above declares and populates these tables.
-- local CAT, DEVELOPER_LIST, PLUGIN_LIST

local target_track = nil
local target_item = nil
local insert_mode = "track" -- "track", "item", or "master"
local target_info = ""

settings = settings or {}
settings.auto_close_on_insert = settings.auto_close_on_insert ~= nil and settings.auto_close_on_insert or true
settings.hide_vst2_duplicates = settings.hide_vst2_duplicates ~= nil and settings.hide_vst2_duplicates or true   -- Hide VST2 if VST3 version exists
settings.search_all_folders   = settings.search_all_folders   ~= nil and settings.search_all_folders   or false  -- Placeholder for future search behavior
settings.fx_window_mode       = settings.fx_window_mode       ~= nil and settings.fx_window_mode       or 1      -- 0 = No window, 1 = FX window (float), 2 = Chain window
settings.last_left_section    = settings.last_left_section    ~= nil and settings.last_left_section    or "all"  -- "all" | "folder" | "dev"
settings.last_left_value      = settings.last_left_value      ~= nil and settings.last_left_value      or ""     -- Folder name or developer name
settings.use_tree_view       = settings.use_tree_view       ~= nil and settings.use_tree_view       or false -- false = two-pane, true = single-pane tree view
settings.font_size           = settings.font_size           ~= nil and settings.font_size           or 11
settings.disable_mouse_target = settings.disable_mouse_target ~= nil and settings.disable_mouse_target or false
settings.apply_to_all_selected = settings.apply_to_all_selected ~= nil and settings.apply_to_all_selected or false
settings.remember_last_search_term = settings.remember_last_search_term ~= nil and settings.remember_last_search_term or false
settings.last_search_text = settings.last_search_text or ""
-- Remember which tree nodes were open in single-pane mode
settings.expanded_nodes = settings.expanded_nodes or {}

-- Settings persistence helpers
local function get_settings_file_path()
  local resource_path = reaper.GetResourcePath()
  return resource_path .. "/FX_Inserter_settings_v7.lua"
end

local function save_settings()
  local path = get_settings_file_path()
  local f = io.open(path, "w")
  if f then
    f:write("-- FX Inserter Settings (Self-Contained Parser Edition)\n")
    f:write("return {\n")
    f:write("  hide_vst2_duplicates = " .. tostring(settings.hide_vst2_duplicates) .. ",\n")
    f:write("  auto_close_on_insert = " .. tostring(settings.auto_close_on_insert) .. ",\n")
    f:write("  search_all_folders = " .. tostring(settings.search_all_folders) .. ",\n")
    f:write("  fx_window_mode = " .. tostring(settings.fx_window_mode) .. ",\n")
    f:write("  last_left_section = " .. string.format("%q", settings.last_left_section or "all") .. ",\n")
    f:write("  last_left_value = " .. string.format("%q", settings.last_left_value or "") .. "\n")
    f:write("  ,use_tree_view = " .. tostring(settings.use_tree_view) .. "\n")
    f:write("  ,font_size = " .. tostring(settings.font_size) .. "\n")
    f:write("  ,disable_mouse_target = " .. tostring(settings.disable_mouse_target) .. "\n")
    f:write("  ,apply_to_all_selected = " .. tostring(settings.apply_to_all_selected) .. "\n")
    f:write("  ,remember_last_search_term = " .. tostring(settings.remember_last_search_term) .. "\n")
    f:write("  ,last_search_text = " .. string.format("%q", settings.last_search_text or "") .. "\n")
        -- Serialize expanded_nodes table (only save true entries to keep file small)
        f:write("  ,expanded_nodes = {\n")
        for k, v in pairs(settings.expanded_nodes or {}) do
            if v then
                f:write("    [" .. string.format("%q", k) .. "] = true,\n")
            end
        end
        f:write("  }\n")
        f:write("}\n")
    f:close()
  end
end

local function load_settings()
  local path = get_settings_file_path()
  local file = io.open(path, "r")
  if not file then return end
  local content = file:read("*all")
  file:close()
  local loader = load or loadstring
  local ok, tbl = pcall(loader(content))
  if ok and type(tbl) == "table" then
    if tbl.hide_vst2_duplicates ~= nil then settings.hide_vst2_duplicates = tbl.hide_vst2_duplicates end
    if tbl.auto_close_on_insert ~= nil then settings.auto_close_on_insert = tbl.auto_close_on_insert end
    if tbl.search_all_folders ~= nil then settings.search_all_folders = tbl.search_all_folders end
    if tbl.fx_window_mode ~= nil then settings.fx_window_mode = tbl.fx_window_mode end
    if tbl.last_left_section ~= nil then settings.last_left_section = tbl.last_left_section end
    if tbl.last_left_value ~= nil then settings.last_left_value = tbl.last_left_value end
            if tbl.use_tree_view ~= nil then settings.use_tree_view = tbl.use_tree_view end
            if tbl.font_size ~= nil then settings.font_size = tbl.font_size end
            if tbl.disable_mouse_target ~= nil then settings.disable_mouse_target = tbl.disable_mouse_target end
            if tbl.apply_to_all_selected ~= nil then settings.apply_to_all_selected = tbl.apply_to_all_selected end
            if tbl.remember_last_search_term ~= nil then settings.remember_last_search_term = tbl.remember_last_search_term end
            if tbl.last_search_text ~= nil then settings.last_search_text = tbl.last_search_text end
            if tbl.expanded_nodes ~= nil and type(tbl.expanded_nodes) == 'table' then settings.expanded_nodes = tbl.expanded_nodes end
  end
end


------------------------------------------------------
-- TARGET DETECTION & FX INSERTION
------------------------------------------------------

local function detect_and_set_target()
  local mouse_x, mouse_y = reaper.GetMousePosition()
  local item = reaper.GetItemFromPoint(mouse_x, mouse_y, true)
  local track = reaper.GetTrackFromPoint(mouse_x, mouse_y)

  if item then
    target_item = item
    target_track = reaper.GetMediaItem_Track(item)
    insert_mode = "item"
    target_info = "Item: " .. (reaper.GetTakeName(reaper.GetActiveTake(item)) or "Unnamed")
  elseif track then
    target_track = track
    target_item = nil
    if track == reaper.GetMasterTrack(0) then
      insert_mode = "master"
      target_info = "Master Track"
    else
      insert_mode = "track"
      local _, track_name = reaper.GetTrackName(track)
      target_info = "Track: " .. (track_name or "Unnamed")
    end
  else
    target_track = nil
    target_item = nil
    insert_mode = "none"
    target_info = "No valid target"
  end
end

local function insert_fx(fx_name)
    if not fx_name then return false end


    local fx_to_add = fx_name
    -- Handle FX Chains and Track Templates paths
    if fx_name:match("%.RfxChain$") then
        -- Build full path to the FX chain in the resource FXChains folder and normalize separators
        local rp = reaper.GetResourcePath() or ""
        local chain_path = rp .. os_separator .. 'FXChains' .. os_separator .. fx_name
        chain_path = chain_path:gsub("[/\\]", os_separator)
        if not reaper.file_exists(chain_path) then
            reaper.ShowMessageBox("FX Chain not found:\n" .. chain_path, "Error reading FX chain file", 0)
            return false
        end
        fx_to_add = chain_path
    elseif fx_name:match("%.RTrackTemplate$") then
        -- Try REAPER resource TrackTemplates first
        local res_path = reaper.GetResourcePath() .. '/TrackTemplates/' .. fx_name
        local template_path = nil
        if reaper.file_exists(res_path) then
            template_path = res_path
        else
            -- Fallback: AppData TrackTemplates (common on Windows)
            local appdata = os.getenv("APPDATA")
            if appdata then
                local app_path = appdata .. '/REAPER/TrackTemplates/' .. fx_name
                if reaper.file_exists(app_path) then
                    template_path = app_path
                end
            end
        end

        if not template_path then
            reaper.ShowMessageBox("Track template not found:\n" .. res_path .. "\n\n(or)\n" .. ((os.getenv("APPDATA") and (os.getenv("APPDATA") .. '/REAPER/TrackTemplates/' .. fx_name)) or "(AppData not found)"), "Error reading template file", 0)
            return false
        end

        -- If we have a target track (user dropped onto a track), insert the template and move new tracks
        if insert_mode == "track" and target_track then
            local selected_track = target_track
            local insert_position = selected_track and (reaper.GetMediaTrackInfo_Value(selected_track, "IP_TRACKNUMBER") - 1) or reaper.CountTracks(0)

            local track_count_before = reaper.CountTracks(0)

            -- Insert the track template (REAPER treats .RTrackTemplate inserted this way as inserting tracks)
            reaper.Main_openProject(template_path)

            local track_count_after = reaper.CountTracks(0)
            if track_count_after > track_count_before then
                -- Move the newly inserted tracks to after the target track
                local tracks_to_move = track_count_after - track_count_before
                if tracks_to_move > 0 then
                    -- Clear selection
                    local tc = reaper.CountTracks(0)
                    for ti = 0, tc-1 do
                        local tr = reaper.GetTrack(0, ti)
                        reaper.SetTrackSelected(tr, false)
                    end
                    -- Select all newly added tracks
                    for i = 0, tracks_to_move - 1 do
                        local track_to_move = reaper.GetTrack(0, track_count_before + i)
                        if track_to_move then reaper.SetTrackSelected(track_to_move, true) end
                    end
                end
            end
            return true
        else
            -- Default behavior: open template (inserts at end)
            reaper.Main_openProject(template_path)
            return true
        end
    end

    local fx_index = -1
    -- If plugin is an instrument, create a new track using folder-respecting insertion logic
    if is_instrument_name(fx_name) then
        -- Use folder-aware insertion if available
        local new_tr = nil
        if insert_track_respect_folders then
            new_tr = insert_track_respect_folders()
        end
        -- Fallback: append at end
        if not new_tr then
            local insert_idx = reaper.CountTracks(0) -- append at end
            reaper.InsertTrackAtIndex(insert_idx, true)
            reaper.TrackList_AdjustWindows(false)
            new_tr = reaper.GetTrack(0, insert_idx)
        end
        if new_tr then
            -- Name track after plugin display name (strip prefix)
            local display = fx_name:gsub("^%s*[%w_]+%s*:%s*", "")
            reaper.GetSetMediaTrackInfo_String(new_tr, "P_NAME", display, true)
            reaper.SetMediaTrackInfo_Value(new_tr, "I_RECARM", 1)
            -- Decide instantiate mode: use instantiate=true only for file-based entries (chains/templates or explicit paths)
            local function is_file_entry(s)
                if type(s) ~= 'string' then return false end
                if s:match("%.RfxChain$") or s:match("%.RTrackTemplate$") then return true end
                if s:find(os_separator, 1, true) then return true end
                return false
            end
            local want_instantiate = is_file_entry(fx_to_add)
            fx_index = reaper.TrackFX_AddByName(new_tr, fx_to_add, want_instantiate, -1)
            if fx_index == -1 and want_instantiate then fx_index = reaper.TrackFX_AddByName(new_tr, fx_to_add, false, -1) end
            target_track = new_tr
            target_item = nil
            insert_mode = "track"
            created_new_track = true
        end
    else
        -- Determine targets
        local targets = {}
        local apply_to_all = settings.apply_to_all_selected
        if apply_to_all then
            if insert_mode == "track" or insert_mode == "master" then
                local num_sel = reaper.CountSelectedTracks(0)
                if num_sel > 3 then
                    local msg = "You have " .. num_sel .. " selected tracks. Are you sure you want to add FX to all of them?"
                    local ret = reaper.ShowMessageBox(msg, "Warning", 4) -- 4 = Yes/No
                    if ret ~= 6 then return false end -- 6 = Yes
                end
                for i = 0, num_sel - 1 do
                    targets[#targets + 1] = {type = "track", obj = reaper.GetSelectedTrack(0, i)}
                end
            elseif insert_mode == "item" then
                local num_sel = reaper.CountSelectedMediaItems(0)
                if num_sel > 3 then
                    local msg = "You have " .. num_sel .. " selected items. Are you sure you want to add FX to all of them?"
                    local ret = reaper.ShowMessageBox(msg, "Warning", 4)
                    if ret ~= 6 then return false end
                end
                for i = 0, num_sel - 1 do
                    targets[#targets + 1] = {type = "item", obj = reaper.GetSelectedMediaItem(0, i)}
                end
            end
        else
            -- Single target
            if insert_mode == "track" or insert_mode == "master" then
                targets = {{type = "track", obj = target_track}}
            elseif insert_mode == "item" then
                targets = {{type = "item", obj = target_item}}
            end
        end

        -- Add FX to each target
        local success_count = 0
        for _, target in ipairs(targets) do
            local fx_index = -1
            if target.type == "track" then
                local function is_file_entry(s)
                    if type(s) ~= 'string' then return false end
                    if s:match("%.RfxChain$") or s:match("%.RTrackTemplate$") then return true end
                    if s:find(os_separator, 1, true) then return true end
                    return false
                end
                local want_instantiate = is_file_entry(fx_to_add)
                fx_index = reaper.TrackFX_AddByName(target.obj, fx_to_add, want_instantiate, -1)
                if fx_index == -1 and want_instantiate then fx_index = reaper.TrackFX_AddByName(target.obj, fx_to_add, false, -1) end
            elseif target.type == "item" then
                local take = reaper.GetActiveTake(target.obj)
                if take then
                    fx_index = reaper.TakeFX_AddByName(take, fx_to_add, -1)
                end
            end
            if fx_index > -1 then
                success_count = success_count + 1
                -- Open window only for the first successful insertion
                if success_count == 1 then
                    if settings.fx_window_mode == 1 then
                        if target.type == "item" then
                            reaper.TakeFX_Show(reaper.GetActiveTake(target.obj), fx_index, 3)
                        else
                            reaper.TrackFX_Show(target.obj, fx_index, 3)
                        end
                    elseif settings.fx_window_mode == 2 then
                        if target.type == "item" then
                            reaper.TakeFX_Show(reaper.GetActiveTake(target.obj), fx_index, 1)
                        else
                            reaper.TrackFX_Show(target.obj, fx_index, 1)
                        end
                    end
                end
            end
        end

        if success_count > 0 then
            return true
        end
    end
    -- If insertion failed and it was an FX chain, show diagnostic info
    if fx_name and type(fx_name) == 'string' and fx_name:match("%.RfxChain$") then
        local rp = reaper.GetResourcePath() or ""
        local attempted = (fx_to_add or fx_name)
        local exists = reaper.file_exists(attempted) and "yes" or "no"
        reaper.ShowMessageBox("Failed to insert FX chain:\n" .. tostring(attempted) .. "\nFile exists: " .. exists .. "\n\nIf the file exists, try dropping directly onto a track or report your REAPER version.", "FX chain insertion failed", 0)
    end
    return false
end

------------------------------------------------------
-- GUI FUNCTIONS (Two-pane layout)
------------------------------------------------------

-- Single-pane tree view: shows all categories/folders/devs as tree nodes
local function draw_main_gui_tree_contents()
    -- Single child filling the right side of the window
    if reaper.ImGui_BeginChild(ctx, "TreePane", 0, -30, 0) then
        -- Use a smaller indent spacing for tree nodes (5 pixels per depth)
        -- Push the style var so other UI parts are unaffected
        reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_IndentSpacing(), 5)
        -- If there's a search, show flat filtered results (like the two-pane search)
        if search_text ~= "" then
            local rows = {}
            local search_lower = search_text:lower()

            -- Build a set of VST3 base names to filter VST2 duplicates when requested
            local vst3_basenames = {}
            if settings.hide_vst2_duplicates then
                for _, name in ipairs(PLUGIN_LIST) do
                    if type(name) == "string" and name:match("^VST3i?%s*:") then
                        local base = name:gsub("^%s*[%w_]+%s*:%s*", ""):lower()
                        vst3_basenames[base] = true
                    end
                end
            end

            for _, fx_name in ipairs(PLUGIN_LIST) do
                if type(fx_name) == "string" then
                    local skip = false
                    if settings.hide_vst2_duplicates and fx_name:match("^VSTi?%s*:") then
                        local base = fx_name:gsub("^%s*[%w_]+%s*:%s*", ""):lower()
                        if vst3_basenames[base] then skip = true end
                    end
                    if not skip then
                        -- Use only the basename for display so folder prefixes do not appear in search results
                        local basename = fx_name:match("([^/\\]+)$") or fx_name
                        local label = basename:gsub("^%s*[%w_]+%s*:%s*", "")
                        -- Remove known file-type suffixes for cleaner labels
                        label = label:gsub("%.RfxChain$", ""):gsub("%.RTrackTemplate$", "")
                        if label:lower():find(search_lower, 1, true) or fx_name:lower():find(search_lower, 1, true) then
                            rows[#rows+1] = { label = label, original = fx_name }
                        end
                    end
                end
            end

            table.sort(rows, function(a,b) return (a.label or ""):lower() < (b.label or ""):lower() end)

            for i,row in ipairs(rows) do
                local unique_label = row.label .. "##" .. row.original
                local is_selected = (i == highlighted_fx_index)
                local clicked = reaper.ImGui_Selectable(ctx, unique_label, is_selected)

                if reaper.ImGui_IsItemActive(ctx) and reaper.ImGui_IsMouseDragging(ctx, reaper.ImGui_MouseButton_Left()) and not dragging then
                    dragging = true
                    drag_fx = row.original
                    drag_label = row.label
                    prev_selected_tracks = {}
                    local tc = reaper.CountTracks(0)
                    for ti=0, tc-1 do
                        local tr = reaper.GetTrack(0, ti)
                        if reaper.IsTrackSelected(tr) then table.insert(prev_selected_tracks, ti) end
                    end
                end

                if clicked and not dragging then
                    highlighted_fx_index = i
                    arrow_key_pressed = true
                    if insert_fx(row.original) and settings.auto_close_on_insert then
                        window_open = false
                    end
                end
            end

            -- Keyboard navigation for single-pane search results
            if #rows > 0 then
                if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_UpArrow()) then
                    highlighted_fx_index = highlighted_fx_index - 1
                    if highlighted_fx_index < 1 then highlighted_fx_index = #rows end
                    arrow_key_pressed = true
                elseif reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_DownArrow()) then
                    highlighted_fx_index = highlighted_fx_index + 1
                    if highlighted_fx_index > #rows then highlighted_fx_index = 1 end
                    arrow_key_pressed = true
                end
                if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Enter()) then
                    local insert_idx = arrow_key_pressed and highlighted_fx_index or 1
                    local target = rows[insert_idx]
                    if target and target.original then
                        if insert_fx(target.original) and settings.auto_close_on_insert then
                            window_open = false
                        end
                    end
                    arrow_key_pressed = false
                end
            end

            if #rows == 0 then reaper.ImGui_TextDisabled(ctx, "(No FX match your search)") end
        else
            -- No search: show full category/folder/dev tree
            for i=1, #CAT do
                local cat = CAT[i]
                if cat and cat.name then
                    -- use stable, unique IDs for tree nodes (hidden with ##) to avoid ImGui state collisions
                    local cat_id = cat.name .. "##CAT" .. tostring(i)
                    -- Restore open state if previously expanded
                    if settings.expanded_nodes[cat_id] then reaper.ImGui_SetNextItemOpen(ctx, true) end
                    local tree_open = reaper.ImGui_TreeNode(ctx, cat_id)
                    -- Persist open state
                    settings.expanded_nodes[cat_id] = tree_open
                    if tree_open then
                        if cat.list then
                            for j=1, #cat.list do
                                local entry = cat.list[j]
                                local entry_name = entry.name or ("Item " .. tostring(j))
                                local entry_id = entry_name .. "##CAT" .. tostring(i) .. "_ENTRY" .. tostring(j)
                                if entry.fx and type(entry.fx) == "table" then
                                    -- If this entry is marked direct (e.g. Instruments), render its fx directly under the category
                                    local is_direct = entry.direct or (entry.fx[1] and type(entry.fx[1]) == "table" and entry.fx[1].direct)
                                    if is_direct then
                                        -- Render the fx list directly without an intermediate TreeNode
                                        local function render_fx_list(list, depth)
                                                        depth = depth or 0
                                                        for idx=1, #list do
                                                            local fx = list[idx]
                                                            if type(fx) == "table" then
                                                                -- folder-like entry
                                                                local node_name = fx.name or "Folder"
                                                                local node_id = node_name .. "##F_" .. tostring(depth) .. "_" .. tostring(idx)
                                                                if settings.expanded_nodes[node_id] then reaper.ImGui_SetNextItemOpen(ctx, true) end
                                                                local node_open = reaper.ImGui_TreeNode(ctx, node_id)
                                                                settings.expanded_nodes[node_id] = node_open
                                                                if node_open then
                                                                                                render_fx_list(fx.fx or {}, depth + 1)
                                                                                                reaper.ImGui_TreePop(ctx)
                                                                                            end
                                    elseif type(fx) == "string" then
                                    -- Use only the basename (strip any folder path) so tree shows just the file name
                                    local basename = fx:match("([^/\\]+)$") or fx
                                    local display = basename:gsub("^%s*[%w_]+%s*:%s*", "")
                                    display = display:gsub("%.RfxChain$", ""):gsub("%.RTrackTemplate$", "")
                                    local id = display .. "##" .. fx .. tostring(idx)
                                    local clicked = reaper.ImGui_Selectable(ctx, id, false)

                                                                if reaper.ImGui_IsItemActive(ctx) and reaper.ImGui_IsMouseDragging(ctx, reaper.ImGui_MouseButton_Left()) and not dragging then
                                                                    dragging = true
                                                                    drag_fx = fx
                                                                    drag_label = display
                                                                    prev_selected_tracks = {}
                                                                    local tc = reaper.CountTracks(0)
                                                                    for ti=0, tc-1 do
                                                                        local tr = reaper.GetTrack(0, ti)
                                                                        if reaper.IsTrackSelected(tr) then table.insert(prev_selected_tracks, ti) end
                                                                    end
                                                                end

                                                                if clicked and not dragging then
                                                                    if insert_fx(fx) and settings.auto_close_on_insert then
                                                                        window_open = false
                                                                    end
                                                                end
                                                            end
                                                        end
                                                    end
                                                    render_fx_list(entry.fx or {}, 0)
                                    else
                                        if settings.expanded_nodes[entry_id] then reaper.ImGui_SetNextItemOpen(ctx, true) end
                                        local entry_open = reaper.ImGui_TreeNode(ctx, entry_id)
                                        settings.expanded_nodes[entry_id] = entry_open
                                        if entry_open then
                                            -- Recursive renderer for mixed folder/file entries
                                            local function render_fx_list(list, depth)
                                                depth = depth or 0
                                                for idx=1, #list do
                                                    local fx = list[idx]
                                                    if type(fx) == "table" then
                                                        -- folder-like entry
                                                        local node_name = fx.name or "Folder"
                                                        local node_id = node_name .. "##F_" .. tostring(depth) .. "_" .. tostring(idx)
                                                        if settings.expanded_nodes[node_id] then reaper.ImGui_SetNextItemOpen(ctx, true) end
                                                        local nested_open = reaper.ImGui_TreeNode(ctx, node_id)
                                                        settings.expanded_nodes[node_id] = nested_open
                                                        if nested_open then
                                                            render_fx_list(fx.fx or {}, depth + 1)
                                                            reaper.ImGui_TreePop(ctx)
                                                        end
                                                    elseif type(fx) == "string" then
                                                        -- Show only the filename (basename) for file entries so folder nodes don't prefix the name
                                                        local basename = fx:match("([^/\\]+)$") or fx
                                                        local display = basename:gsub("^%s*[%w_]+%s*:%s*", "")
                                                        display = display:gsub("%.RfxChain$", ""):gsub("%.RTrackTemplate$", "")
                                                        local id = display .. "##" .. fx .. tostring(idx)
                                                        local clicked = reaper.ImGui_Selectable(ctx, id, false)

                                                        if reaper.ImGui_IsItemActive(ctx) and reaper.ImGui_IsMouseDragging(ctx, reaper.ImGui_MouseButton_Left()) and not dragging then
                                                            dragging = true
                                                            drag_fx = fx
                                                            drag_label = display
                                                            prev_selected_tracks = {}
                                                            local tc = reaper.CountTracks(0)
                                                            for ti=0, tc-1 do
                                                                local tr = reaper.GetTrack(0, ti)
                                                                if reaper.IsTrackSelected(tr) then table.insert(prev_selected_tracks, ti) end
                                                            end
                                                        end

                                                        if clicked and not dragging then
                                                            if insert_fx(fx) and settings.auto_close_on_insert then
                                                                window_open = false
                                                            end
                                                        end
                                                    end
                                                end
                                            end
                                            render_fx_list(entry.fx or {}, 0)
                                            reaper.ImGui_TreePop(ctx)
                                        end
                                    end
                                else
                                    -- entry with no fx table: just show the name
                                    reaper.ImGui_TextDisabled(ctx, entry_name)
                                end
                            end
                        end
                        reaper.ImGui_TreePop(ctx)
                    end
                end
            end
        end

        -- Restore style
        reaper.ImGui_PopStyleVar(ctx)
        reaper.ImGui_EndChild(ctx)
    end
end


local function draw_main_gui()
    -- Window geometry is managed by REAPER/ImGui; do not restore saved sizes here

    -- Disable default keyboard navigation; rely on custom keys for the FX list
    local window_flags = reaper.ImGui_WindowFlags_NoNavInputs() | reaper.ImGui_WindowFlags_NoNavFocus()
    local visible, open = reaper.ImGui_Begin(ctx, "7R FX Inserter", true, window_flags)
    if not visible then
        return open
    end

    -- Close the window when Escape is pressed. Do not require ImGui window focus because
    -- clicking an item can move focus to REAPER and prevent the close otherwise.
    if type(reaper.ImGui_IsKeyPressed) == 'function' and type(reaper.ImGui_Key_Escape) == 'function' then
        local ok, esc = pcall(reaper.ImGui_IsKeyPressed, ctx, reaper.ImGui_Key_Escape())
        if ok and esc then
            window_open = false
            reaper.ImGui_End(ctx)
            return false
        end
    end

    -- Top bar: Search + Settings
    -- Slightly reduce search width to accommodate Refresh + Settings buttons
    local flags = 0
    if reaper.ImGui_IsWindowAppearing(ctx) and settings.remember_last_search_term and search_text ~= "" then
        flags = reaper.ImGui_InputTextFlags_AutoSelectAll()
    end
    reaper.ImGui_SetNextItemWidth(ctx, reaper.ImGui_GetContentRegionAvail(ctx) - 180)
    if reaper.ImGui_IsWindowAppearing(ctx) then
        reaper.ImGui_SetKeyboardFocusHere(ctx)
    end
    local changed_search, new_search = reaper.ImGui_InputTextWithHint(ctx, "##search", "Search FX...", search_text, flags)
    if changed_search then
        search_text = new_search
        if settings.remember_last_search_term then
            settings.last_search_text = new_search
            save_settings()
        end
        highlighted_fx_index = 1
        arrow_key_pressed = false
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Refresh", 70, 0) then
        -- Rebuild parser-derived lists and update views
        PLUGIN_LIST, CAT, DEVELOPER_LIST = MakeFXFiles()
        BuildViews()
        reaper.ShowMessageBox("FX lists refreshed.", "Refresh complete", 0)
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Settings", 90, 0) then
        settings_window_open = true
    end
    reaper.ImGui_Separator(ctx)

    local left_width = math.floor(reaper.ImGui_GetWindowWidth(ctx) * 0.33)

    -- LEFT PANE (hidden when single-pane tree view is enabled)
    if not settings.use_tree_view then
        if reaper.ImGui_BeginChild(ctx, "LeftPane", left_width, -30, 0) then
        -- User Folders
    if bold_font then reaper.ImGui_PushFont(ctx, bold_font, settings.font_size) end
        reaper.ImGui_Text(ctx, "User Folders")
        if bold_font then reaper.ImGui_PopFont(ctx) end
        local folders_cat
        for i = 1, #CAT do
            if CAT[i].name == "FOLDERS" then
                folders_cat = CAT[i]
                break
            end
        end
        if folders_cat and folders_cat.list then
            for i, folder in ipairs(folders_cat.list) do
                local fname = folder.name or ("Folder " .. i)
                local selected = (left_selection.section == "folder" and left_selection.index == i)
                    if reaper.ImGui_Selectable(ctx, fname .. "##FOLDER" .. i, selected) then
                    left_selection.section = "folder"
                    left_selection.index = i
                    settings.last_left_section = "folder"
                    settings.last_left_value = fname
                    save_settings()
                end
            end
        else
            reaper.ImGui_TextDisabled(ctx, "(No custom folders)")
        end

        reaper.ImGui_Separator(ctx)

        -- ALL FX (single entry)
        local all_selected = (left_selection.section == "all")
        if reaper.ImGui_Selectable(ctx, "ALL FX##ALL", all_selected) then
            left_selection.section = "all"
            left_selection.index = 0
        end

        -- FX Chains (hidden unless enabled)
        if ENABLE_FX_CHAINS then
            local fxchains_selected = (left_selection.section == "fxchains")
            if reaper.ImGui_Selectable(ctx, "FX CHAINS##LEFT", fxchains_selected) then
                left_selection.section = "fxchains"
                left_selection.index = 0
                settings.last_left_section = "fxchains"
                settings.last_left_value = ""
                save_settings()
            end
        end

        -- Track Templates
        local ttemplates_selected = (left_selection.section == "tracktemplates")
        if reaper.ImGui_Selectable(ctx, "TRACK TEMPLATES##LEFT", ttemplates_selected) then
            left_selection.section = "tracktemplates"
            left_selection.index = 0
            settings.last_left_section = "tracktemplates"
            settings.last_left_value = ""
            save_settings()
        end

        -- Instruments
        local instruments_selected = (left_selection.section == "instruments")
        if reaper.ImGui_Selectable(ctx, "INSTRUMENTS##LEFT", instruments_selected) then
            left_selection.section = "instruments"
            left_selection.index = 0
            settings.last_left_section = "instruments"
            settings.last_left_value = ""
            save_settings()
        end

        reaper.ImGui_Separator(ctx)

        -- Developers
    if bold_font then reaper.ImGui_PushFont(ctx, bold_font, settings.font_size) end
        reaper.ImGui_Text(ctx, "Developers")
        if bold_font then reaper.ImGui_PopFont(ctx) end
        if #DEVELOPER_LIST > 0 then
            for i, dev in ipairs(DEVELOPER_LIST) do
                local dev_name = dev:match("%((.-)%)") or dev
                local selected = (left_selection.section == "dev" and left_selection.index == i)
                        if reaper.ImGui_Selectable(ctx, dev_name .. "##DEV" .. i, selected) then
                    left_selection.section = "dev"
                    left_selection.index = i
                    settings.last_left_section = "dev"
                    settings.last_left_value = dev_name
                    save_settings()
                end
            end
        else
            reaper.ImGui_TextDisabled(ctx, "(No developers)")
        end

            reaper.ImGui_EndChild(ctx)
        end

        reaper.ImGui_SameLine(ctx)
    end

    -- RIGHT PANE (FX list or tree)
    if settings.use_tree_view then
        draw_main_gui_tree_contents()
    else
        if reaper.ImGui_BeginChild(ctx, "RightPane", 0, -30, 0) then
        local fx_list = nil
        if left_selection.section == "all" then
            fx_list = PLUGIN_LIST

        elseif left_selection.section == "fxchains" then
            fx_list = views.fxchains

        elseif left_selection.section == "tracktemplates" then
            fx_list = views.tracktemplates

        elseif left_selection.section == "instruments" then
            fx_list = INSTRUMENTS

        elseif left_selection.section == "folder" then
            local folders_cat
            for i = 1, #CAT do
                if CAT[i].name == "FOLDERS" then
                    folders_cat = CAT[i]
                    break
                end
            end
            if folders_cat and folders_cat.list and folders_cat.list[left_selection.index] then
                fx_list = folders_cat.list[left_selection.index].fx
            end

        elseif left_selection.section == "dev" then
            fx_list = {}
            local tag = DEVELOPER_LIST[left_selection.index]
            if tag then
                for i = 1, #PLUGIN_LIST do
                    if PLUGIN_LIST[i]:find(tag, 1, true) then
                        fx_list[#fx_list + 1] = PLUGIN_LIST[i]
                    end
                end
            end
        end

        -- Build display rows: label (no extension), original name, tooltip (path+extension where applicable)
        local rows = {}
        -- Choose base list depending on search scope
        local base_list = fx_list
        if search_text ~= "" and settings.search_all_folders then
            base_list = PLUGIN_LIST
        end

        if base_list and #base_list > 0 then
            -- Build a map of VST3 base names to filter out VST2 duplicates when enabled
            local vst3_basenames = {}
            if settings.hide_vst2_duplicates then
                for _, name in ipairs(base_list) do
                    if type(name) == "string" and name:match("^VST3i?%s*:") then
                        local base = name:gsub("^%s*[%w_]+%s*:%s*", ""):lower()
                        vst3_basenames[base] = true
                    end
                end
            end

            local search_lower = search_text:lower()
            for _, fx_name in ipairs(base_list) do
                if type(fx_name) == "table" then
                    -- Do not include directories when searching; show only as context when no search
                    if search_text == "" then
                        rows[#rows + 1] = { label = fx_name.dir and (fx_name.dir .. "/") or "(Folder)", original = nil, tooltip = nil, is_folder = true }
                    end
                else
                    -- Skip VST2 if a VST3 version exists (when enabled)
                    local skip = false
                    if settings.hide_vst2_duplicates and fx_name:match("^VSTi?%s*:") then
                        local base = fx_name:gsub("^%s*[%w_]+%s*:%s*", ""):lower()
                        if vst3_basenames[base] then
                            skip = true
                        end
                    end

                    if not skip then
                        local label = fx_name
                        local tooltip = nil

                        -- File-based entries: strip extension for label and compute tooltip with full path
                        if fx_name:match("%.RfxChain$") or fx_name:match("%.RTrackTemplate$") or fx_name:find("[/\\]") then
                            local basename = fx_name:match("([^/\\]+)$") or fx_name
                            label = basename:gsub("%.[^%.]+$", "")
                            if fx_name:match("%.RfxChain$") then
                                tooltip = "FX Chain: " .. (reaper.GetResourcePath() .. "/FXChains/" .. fx_name)
                            elseif fx_name:match("%.RTrackTemplate$") then
                                tooltip = "Track Template: " .. (reaper.GetResourcePath() .. "/TrackTemplates/" .. fx_name)
                            else
                                tooltip = fx_name
                            end
                        else
                            -- Not a file-based entry: strip plugin type prefixes like "VST3:", "VST:", "JS:", "AU:", etc.
                            label = label:gsub("^%s*[%w_]+%s*:%s*", "")
                            tooltip = fx_name
                        end

                        -- Apply filtering if searching
                        local include = true
                        if search_text ~= "" then
                            include = (label:lower():find(search_lower, 1, true) ~= nil)
                                or (fx_name:lower():find(search_lower, 1, true) ~= nil)
                        end

                        if include then
                            rows[#rows + 1] = { label = label, original = fx_name, tooltip = tooltip }
                        end
                    end
                end
            end

            -- Sort rows alphabetically by label (case-insensitive), keep folder markers in order
            table.sort(rows, function(a, b)
                if a.is_folder ~= b.is_folder then
                    return (a.is_folder and true) or false
                end
                return (a.label or ""):lower() < (b.label or ""):lower()
            end)

            -- Clamp highlighted index
            if #rows == 0 then
                highlighted_fx_index = 1
            else
                if highlighted_fx_index < 1 then highlighted_fx_index = 1 end
                if highlighted_fx_index > #rows then highlighted_fx_index = #rows end
            end

            -- Render rows
            for idx, row in ipairs(rows) do
                if row.is_folder then
                    reaper.ImGui_TextDisabled(ctx, row.label)
                else
                    -- Unique ID suffix based on original full name to avoid ID collisions
                    local unique_label = row.label
                    if row.original and row.original ~= "" then
                        unique_label = row.label .. "##" .. row.original
                    end
                    local is_selected = (idx == highlighted_fx_index)
                    local clicked = reaper.ImGui_Selectable(ctx, unique_label, is_selected)

                    -- Start drag if user is dragging the active item
                    if reaper.ImGui_IsItemActive(ctx) and reaper.ImGui_IsMouseDragging(ctx, reaper.ImGui_MouseButton_Left()) and not dragging then
                        dragging = true
                        drag_fx = row.original
                        drag_label = row.label
                    end

                    if clicked and not dragging then
                        highlighted_fx_index = idx
                        arrow_key_pressed = true
                        if insert_fx(row.original) and settings.auto_close_on_insert then
                            open = false
                        end
                    end
                    if reaper.ImGui_IsItemHovered(ctx) and row.tooltip and row.tooltip ~= "" then
                        reaper.ImGui_SetTooltip(ctx, row.tooltip)
                    end
                end
            end

            -- Keyboard navigation
            if #rows > 0 then
                if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_UpArrow()) then
                    highlighted_fx_index = highlighted_fx_index - 1
                    if highlighted_fx_index < 1 then highlighted_fx_index = #rows end
                    arrow_key_pressed = true
                elseif reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_DownArrow()) then
                    highlighted_fx_index = highlighted_fx_index + 1
                    if highlighted_fx_index > #rows then highlighted_fx_index = 1 end
                    arrow_key_pressed = true
                end
                if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Enter()) then
                    local insert_idx = arrow_key_pressed and highlighted_fx_index or 1
                    local target = rows[insert_idx]
                    if target and target.original then
                        if insert_fx(target.original) and settings.auto_close_on_insert then
                            open = false
                        end
                    end
                    arrow_key_pressed = false
                end
            end
        else
            reaper.ImGui_TextDisabled(ctx, "(No FX to display)")
        end

            reaper.ImGui_EndChild(ctx)
        end
    end

    reaper.ImGui_Separator(ctx)
        -- Hide the "no active target" message when the window is docked
        local docked = false
        if type(reaper.ImGui_IsWindowDocked) == "function" then
            local ok, res = pcall(reaper.ImGui_IsWindowDocked, ctx)
            if ok and res then docked = true end
        end

        -- Only show target info if not docked-without-target
        if not (docked and insert_mode == "none") then
            reaper.ImGui_Text(ctx, "Target: " .. target_info)
        end

    -- Window geometry persistence removed

    reaper.ImGui_End(ctx)
    return open
end

local function draw_settings_window()
    if not settings_window_open then return end
    local window_flags = reaper.ImGui_WindowFlags_AlwaysAutoResize()
    local visible, open = reaper.ImGui_Begin(ctx, "FX Inserter Settings", true, window_flags)
    if visible then
        -- Hide VST2 duplicates
        local changed, new_val = reaper.ImGui_Checkbox(ctx, "Hide VST2 if VST3 is present", settings.hide_vst2_duplicates)
        if changed then
            settings.hide_vst2_duplicates = new_val
            save_settings()
        end
        if reaper.ImGui_IsItemHovered(ctx) then
            reaper.ImGui_SetTooltip(ctx, "When enabled, VST2 plugins are hidden if a VST3 version of the same plugin exists")
        end

        reaper.ImGui_Spacing(ctx)

        -- Auto close on insert
        local changed2, new_val2 = reaper.ImGui_Checkbox(ctx, "Autoclose window after FX insertion", settings.auto_close_on_insert)
        if changed2 then
            settings.auto_close_on_insert = new_val2
            save_settings()
        end
        if reaper.ImGui_IsItemHovered(ctx) then
            reaper.ImGui_SetTooltip(ctx, "Close the browser automatically after inserting an FX")
        end

        reaper.ImGui_Spacing(ctx)

        -- Search all folders toggle (behavior to be implemented later)
        local changed3, new_val3 = reaper.ImGui_Checkbox(ctx, "Search all folders when using search", settings.search_all_folders)
        if changed3 then
            settings.search_all_folders = new_val3
            save_settings()
        end
        if reaper.ImGui_IsItemHovered(ctx) then
            reaper.ImGui_SetTooltip(ctx, "When enabled, search will consider all folders (to be implemented)")
        end

        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_Separator(ctx)
        reaper.ImGui_Spacing(ctx)

        -- FX window mode
        reaper.ImGui_Text(ctx, "FX window mode:")
        local fx_window_options = "No window\0FX window\0FX chain\0"
        reaper.ImGui_SetNextItemWidth(ctx, 200)
        local changed4, new_selection = reaper.ImGui_Combo(ctx, "##fx_window_mode", settings.fx_window_mode, fx_window_options)
        if changed4 then
            settings.fx_window_mode = new_selection
            save_settings()
        end
        if reaper.ImGui_IsItemHovered(ctx) then
            local tip = "Choose how FX windows are shown after insertion:\n" ..
                        "• No window: insert only, do not open any window\n" ..
                        "• FX window: open the FX in a floating window\n" ..
                        "• FX chain: show the FX chain window"
            reaper.ImGui_SetTooltip(ctx, tip)
        end

        reaper.ImGui_Spacing(ctx)
        -- Font size slider
        reaper.ImGui_Text(ctx, "Font size:")
        reaper.ImGui_SameLine(ctx)
        local changed_font, new_font = reaper.ImGui_SliderInt(ctx, "##font_size", settings.font_size, 8, 20)
        if changed_font then
            settings.font_size = new_font
            save_settings()
            -- Recreate and attach font so changes take effect immediately
            font = reaper.ImGui_CreateFont('sans-serif', settings.font_size)
            reaper.ImGui_Attach(ctx, font)
        end
        if reaper.ImGui_IsItemHovered(ctx) then
            reaper.ImGui_SetTooltip(ctx, "Set UI font size (8-20). Changes apply immediately.")
        end

        reaper.ImGui_Spacing(ctx)
        -- Single-pane tree view option
        local changed_view, new_view = reaper.ImGui_Checkbox(ctx, "Single-pane tree view", settings.use_tree_view)
        if changed_view then
            settings.use_tree_view = new_view
            save_settings()
        end
        if reaper.ImGui_IsItemHovered(ctx) then
            reaper.ImGui_SetTooltip(ctx, "When enabled, use a single-pane tree view with categories and folders instead of the two-pane layout")
        end

        reaper.ImGui_Spacing(ctx)
        local changed_dt, new_dt = reaper.ImGui_Checkbox(ctx, "Disable mouse target detection", settings.disable_mouse_target)
        if changed_dt then
            settings.disable_mouse_target = new_dt
            save_settings()
        end
        if reaper.ImGui_IsItemHovered(ctx) then
            reaper.ImGui_SetTooltip(ctx, "When enabled the script will not detect the track/item under the mouse. Useful when opening docked.")
        end

        reaper.ImGui_Spacing(ctx)
        local changed_as, new_as = reaper.ImGui_Checkbox(ctx, "Apply FX to all selected tracks/items", settings.apply_to_all_selected)
        if changed_as then
            settings.apply_to_all_selected = new_as
            save_settings()
        end
        if reaper.ImGui_IsItemHovered(ctx) then
            reaper.ImGui_SetTooltip(ctx, "When enabled, applies the FX to all selected tracks or items instead of just the one under the mouse.")
        end

        reaper.ImGui_Spacing(ctx)
        local changed_rlst, new_rlst = reaper.ImGui_Checkbox(ctx, "Remember last search term", settings.remember_last_search_term)
        if changed_rlst then
            settings.remember_last_search_term = new_rlst
            save_settings()
        end
        if reaper.ImGui_IsItemHovered(ctx) then
            reaper.ImGui_SetTooltip(ctx, "When enabled, the last search term is remembered and restored when reopening the script. The search box will be highlighted for easy editing.")
        end

        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_Separator(ctx)
        reaper.ImGui_Spacing(ctx)

        if reaper.ImGui_Button(ctx, "Close", 100, 26) then
            settings_window_open = false
        end

        reaper.ImGui_End(ctx)
    end
    if not open then settings_window_open = false end
end

------------------------------------------------------
-- MAIN LOOP
------------------------------------------------------

local function init()
    -- Load persisted settings first
    load_settings()

    if settings.remember_last_search_term then
        search_text = settings.last_search_text or ""
    end

    -- Recreate fonts using loaded font size
    if font then
        -- Note: ReaImGui doesn't provide a direct destroy; just create and attach new font
    end
    font = reaper.ImGui_CreateFont('sans-serif', settings.font_size or 11)
    reaper.ImGui_Attach(ctx, font)

    if not settings.disable_mouse_target then
        detect_and_set_target()
    else
        target_track = nil
        target_item = nil
        insert_mode = "none"
        target_info = "No valid target"
    end

    -- Use parser's caching mechanism
    local fx_list_test, cat_test, dev_list_test = ReadFXFile()
    -- Check multiple watched files' stats and compare with cached stat table to decide rebuild
    local watched = GetWatchedFiles()
    local current_stats = {}
    for key, path in pairs(watched) do
        local st = GetFileStat(path)
        if st then current_stats[key] = st end
    end

    local saved_stats = ReadStatFile() or {}

    local need_rebuild = false
    if not fx_list_test or #fx_list_test == 0 or not cat_test or #cat_test == 0 then
        need_rebuild = true
    else
        -- If any watched file's stat differs or a previously watched file is missing, rebuild
        for key, cur in pairs(current_stats) do
            local prev = saved_stats[key]
            if not prev or not StatEquals(cur, prev) then
                need_rebuild = true
                break
            end
        end
        -- Also if saved_stats had keys that are now missing (file removed), trigger rebuild
        if not need_rebuild then
            for key, prev in pairs(saved_stats) do
                if not current_stats[key] then need_rebuild = true; break end
            end
        end
    end

    if need_rebuild then
        PLUGIN_LIST, CAT, DEVELOPER_LIST = MakeFXFiles()
        -- Save current combined stats for future comparisons
        if next(current_stats) then WriteStatFile(current_stats) end
    else
        PLUGIN_LIST, CAT, DEVELOPER_LIST = fx_list_test, cat_test, dev_list_test
        -- Ensure we have a saved stat file; if missing but we have current stats, write it
        if (not saved_stats or next(saved_stats) == nil) and next(current_stats) then WriteStatFile(current_stats) end
    end

    -- Build cached views for the UI after loading/generating CAT and PLUGIN_LIST
    BuildViews()

    -- Sort developer list alphabetically by display name
    if DEVELOPER_LIST and #DEVELOPER_LIST > 1 then
        table.sort(DEVELOPER_LIST, function(a, b)
            local aa = (a and a:match("%((.-)%)") or a or ""):lower()
            local bb = (b and b:match("%((.-)%)") or b or ""):lower()
            return aa < bb
        end)
    end

  -- Restore last selection
  if settings.last_left_section == "folder" and settings.last_left_value and settings.last_left_value ~= "" then
      local folders_cat
      for i = 1, #CAT do
          if CAT[i].name == "FOLDERS" then
              folders_cat = CAT[i]
              break
          end
      end
      if folders_cat and folders_cat.list then
          for i, folder in ipairs(folders_cat.list) do
              local fname = folder.name or ("Folder " .. i)
              if fname == settings.last_left_value then
                  left_selection.section = "folder"
                  left_selection.index = i
                  break
              end
          end
      end
  elseif settings.last_left_section == "dev" and settings.last_left_value and settings.last_left_value ~= "" then
      for i, dev in ipairs(DEVELOPER_LIST) do
          local dev_name = dev:match("%((.-)%)") or dev
          if dev_name == settings.last_left_value or dev == settings.last_left_value then
              left_selection.section = "dev"
              left_selection.index = i
              break
          end
      end
  else
      -- Support persisted choices for fxchains/tracktemplates/instruments
      if settings.last_left_section == "fxchains" and ENABLE_FX_CHAINS then
          left_selection.section = "fxchains"
      elseif settings.last_left_section == "tracktemplates" then
          left_selection.section = "tracktemplates"
      elseif settings.last_left_section == "instruments" then
          left_selection.section = "instruments"
      else
          left_selection.section = "all"
      end
      left_selection.index = 0
  end
end

local function main_loop()
    if not window_open then return end

    reaper.ImGui_PushFont(ctx, font, settings.font_size)
    local gui_open = draw_main_gui()
    if window_open then
        window_open = gui_open
    end
  -- Draw settings window if open
  draw_settings_window()
    reaper.ImGui_PopFont(ctx)

    -- Drag overlay and drop handling (use ImGui mouse position for overlay)
    if dragging and drag_fx then
        local mx, my = reaper.GetMousePosition()
        -- Small floating window near mouse to show what is being dragged
        reaper.ImGui_SetNextWindowBgAlpha(ctx, 0.75)
        local flags = reaper.ImGui_WindowFlags_NoTitleBar() | reaper.ImGui_WindowFlags_NoInputs() | reaper.ImGui_WindowFlags_AlwaysAutoResize()
        local visible = reaper.ImGui_Begin(ctx, "##drag_overlay", false, flags)
        if visible then
            reaper.ImGui_Text(ctx, "Dragging: " .. (drag_label or drag_fx))
            reaper.ImGui_End(ctx)
        end

        -- While dragging, update detected target under mouse for feedback
        do
            local mx2, my2 = reaper.GetMousePosition()
            local item = reaper.GetItemFromPoint(mx2, my2, true)
            local track = reaper.GetTrackFromPoint(mx2, my2)
            if item then
                drag_target_type = "item"
                drag_target_name = reaper.GetTakeName(reaper.GetActiveTake(item)) or "Item"
                -- Highlight target track temporarily
                local t = reaper.GetMediaItem_Track(item)
                if t then
                    -- select only this track
                    local track_count = reaper.CountTracks(0)
                    for i=0, track_count-1 do
                        local tr = reaper.GetTrack(0, i)
                        reaper.SetTrackSelected(tr, false)
                    end
                    reaper.SetTrackSelected(t, true)
                end
            elseif track then
                drag_target_type = "track"
                local _, tname = reaper.GetTrackName(track)
                drag_target_name = tname or "Track"
                -- select only this track
                local track_count = reaper.CountTracks(0)
                for i=0, track_count-1 do
                    local tr = reaper.GetTrack(0, i)
                    reaper.SetTrackSelected(tr, false)
                end
                reaper.SetTrackSelected(track, true)
            else
                drag_target_type = "none"
                drag_target_name = ""
                -- clear selection
                -- (do not restore original selection until drop)
            end
        end

        -- If mouse released, perform drop
        if not reaper.ImGui_IsMouseDown(ctx, reaper.ImGui_MouseButton_Left()) then
            -- Detect track/item under mouse and insert
            local mouse_x, mouse_y = reaper.GetMousePosition()
            local item = reaper.GetItemFromPoint(mouse_x, mouse_y, true)
            local track = reaper.GetTrackFromPoint(mouse_x, mouse_y)
            if item then
                target_item = item
                target_track = reaper.GetMediaItem_Track(item)
                insert_mode = "item"
            elseif track then
                target_track = track
                target_item = nil
                if track == reaper.GetMasterTrack(0) then
                    insert_mode = "master"
                else
                    insert_mode = "track"
                end
            else
                -- No direct track/item detected under mouse.
                -- Fallback: if the drag overlay previously selected a track for highlight,
                -- use the currently selected track as the drop target so insertion behaves
                -- like single-pane drag (which relies on track selection).
                local sel_cnt = reaper.CountSelectedTracks(0)
                if sel_cnt and sel_cnt > 0 then
                    target_track = reaper.GetSelectedTrack(0, 0)
                    target_item = nil
                    insert_mode = "track"
                else
                    target_track = nil
                    target_item = nil
                    insert_mode = "none"
                end
            end

            if drag_fx then
                if insert_mode ~= "none" then
                    insert_fx(drag_fx)
                    if settings.auto_close_on_insert then window_open = false end
                else
                    -- If not over a visible target allow creating a new track for instruments, track templates, or FX chains
                    if is_instrument_name(drag_fx) or tostring(drag_fx):match("%.RTrackTemplate$") then
                        insert_fx(drag_fx)
                        if settings.auto_close_on_insert then window_open = false end
                    elseif tostring(drag_fx):match("%.RfxChain$") then
                        -- Create a new track (respect folders when possible) and insert the FX chain
                        local new_tr = nil
                        if insert_track_respect_folders then new_tr = insert_track_respect_folders() end
                        if not new_tr then
                            local insert_idx = reaper.CountTracks(0)
                            reaper.InsertTrackAtIndex(insert_idx, true)
                            reaper.TrackList_AdjustWindows(false)
                            new_tr = reaper.GetTrack(0, insert_idx)
                        end
                        if new_tr then
                            target_track = new_tr
                            target_item = nil
                            insert_mode = "track"
                            insert_fx(drag_fx)
                            if settings.auto_close_on_insert then window_open = false end
                        end
                    end
                end
            end

            -- Reset drag state
            dragging = false
            drag_fx = nil
            drag_label = ""
            -- Restore previous track selection state
            if prev_selected_tracks and #prev_selected_tracks > 0 then
                local track_count = reaper.CountTracks(0)
                for i=0, track_count-1 do
                    local tr = reaper.GetTrack(0, i)
                    reaper.SetTrackSelected(tr, false)
                end
                for _, idx in ipairs(prev_selected_tracks) do
                    local tr = reaper.GetTrack(0, idx)
                    if tr then reaper.SetTrackSelected(tr, true) end
                end
            end
        end
    end

    if window_open then
        reaper.defer(main_loop)
    end
end

-- Initialize and start
init()
-- Register settings save on exit so checkbox states persist
if save_settings and reaper and reaper.atexit then
    reaper.atexit(save_settings)
end

main_loop()