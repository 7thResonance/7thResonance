--[[
@description 7R Track Template Inserter (GUI)
@author 7thResonance
@version 1.3
@about
  Browse and insert REAPER track templates organized in a tree structure
  matching the folder hierarchy in the TrackTemplates directory.
  Double-click to insert track templates into the current project.
@changelog - added font size setting
           - remember last search term setting 
@donation https://paypal.me/7thresonance
@screenshot Window https://i.postimg.cc/Y25QbqXX/Screenshot-2025-07-12-213753.png
--]]

-- REAIMGUI SETUP
if not reaper.ImGui_CreateContext then
  reaper.ShowMessageBox("ReaImGui not found! Please install via ReaPack.", "Error", 0)
  return
end

local ctx = reaper.ImGui_CreateContext("Track Template Insert")
local font = reaper.ImGui_CreateFont('sans-serif', 14)
reaper.ImGui_Attach(ctx, font)

-- GLOBAL VARIABLES
local window_open = true
local search_text = ""
local template_tree = {}
local filtered_templates = {}
local selected_template = nil
local expanded_folders = {}
local refocus_search_next_frame = false

-- Add string trim function
string.trim = string.trim or function(s)
  return s:match("^%s*(.-)%s*$")
end

-- SETTINGS
local settings = {
  window_x = -1,
  window_y = -1,
  window_width = 700,
  window_height = 500,
  auto_close_on_insert = true,
  show_file_paths = false,
  templates_folder = "",
  remember_last_search_term = false,
  last_search_text = "",
  font_size = 14
}

-- SETTINGS FILE FUNCTIONS
local function get_settings_file_path()
  local resource_path = reaper.GetResourcePath()
  return resource_path .. "/TrackTemplate_Insert_settings.lua"
end

local function save_settings()
  local settings_path = get_settings_file_path()

  local file = io.open(settings_path, "w")
  if file then
    file:write("-- Track Template Insert Settings File\n")
    file:write("return {\n")
    file:write("  window_x = " .. tostring(settings.window_x) .. ",\n")
    file:write("  window_y = " .. tostring(settings.window_y) .. ",\n")
    file:write("  window_width = " .. tostring(settings.window_width) .. ",\n")
    file:write("  window_height = " .. tostring(settings.window_height) .. ",\n")
    file:write("  auto_close_on_insert = " .. tostring(settings.auto_close_on_insert) .. ",\n")
    file:write("  show_file_paths = " .. tostring(settings.show_file_paths) .. ",\n")
    -- Escape backslashes in the templates_folder path
    local escaped_folder = (settings.templates_folder or ""):gsub("\\", "\\\\")
    file:write("  templates_folder = \"" .. escaped_folder .. "\",\n")
    file:write("  remember_last_search_term = " .. tostring(settings.remember_last_search_term) .. ",\n")
    file:write("  last_search_text = " .. string.format("%q", settings.last_search_text) .. ",\n")
    file:write("  font_size = " .. tostring(settings.font_size) .. "\n")
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
  local success, loaded_settings = pcall(load_func, content)
  if success and type(loaded_settings) == "function" then
    local exec_success, result = pcall(loaded_settings)
    if exec_success and type(result) == "table" then
      for key, value in pairs(result) do
        if settings[key] ~= nil then
          settings[key] = value
        end
      end
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
-- TEMPLATE SCANNING
------------------------------------------------------

local function get_templates_folder()
  if settings.templates_folder ~= "" then
    return settings.templates_folder
  end

  -- Default to REAPER's track templates folder in AppData
  local appdata_path = os.getenv("APPDATA")
  if appdata_path then
    local templates_path = appdata_path .. "/REAPER/TrackTemplates"
    if reaper.file_exists(templates_path) then
      settings.templates_folder = templates_path
      return templates_path
    end
  end

  -- Fallback to REAPER resource path
  local resource_path = reaper.GetResourcePath()
  local templates_path = resource_path .. "/TrackTemplates"

  -- Check if folder exists
  if reaper.file_exists(templates_path) then
    settings.templates_folder = templates_path
    return templates_path
  end

  -- Fallback to user documents if default doesn't exist
  local documents_path = os.getenv("USERPROFILE") or os.getenv("HOME")
  if documents_path then
    templates_path = documents_path .. "/Documents/REAPER/TrackTemplates"
    if reaper.file_exists(templates_path) then
      settings.templates_folder = templates_path
      return templates_path
    end
  end

  -- If nothing found, use the AppData path anyway
  settings.templates_folder = (appdata_path or "") .. "/REAPER/TrackTemplates"
  return settings.templates_folder
end

local function scan_folder_recursive(folder_path, relative_path)
  local items = {}
  local folders = {}
  local files = {}

  -- Scan for subdirectories
  local dir_index = 0
  while true do
    local subdir = reaper.EnumerateSubdirectories(folder_path, dir_index)
    if not subdir then break end

    local subdir_path = folder_path .. "/" .. subdir
    local subdir_relative = relative_path == "" and subdir or (relative_path .. "/" .. subdir)

    local subfolder_items = scan_folder_recursive(subdir_path, subdir_relative)

    table.insert(folders, {
      name = subdir,
      type = "folder",
      path = subdir_path,
      relative_path = subdir_relative,
      children = subfolder_items,
      expanded = expanded_folders[subdir_relative] or false
    })

    dir_index = dir_index + 1
  end

  -- Scan for template files
  local file_index = 0
  while true do
    local file = reaper.EnumerateFiles(folder_path, file_index)
    if not file then break end

    -- Check if it's a template file (.RTrackTemplate primarily)
    local file_lower = file:lower()
    if file_lower:match("%.rtracktemplate$") or
       file_lower:match("%.rpp$") then

      local file_path = folder_path .. "/" .. file
      local file_relative = relative_path == "" and file or (relative_path .. "/" .. file)

      -- Determine template type
      local template_type = "Track"
      if file_lower:match("%.rpp$") then
        template_type = "Project"
      end

      -- Clean up the display name
      local display_name = file:gsub("%.rtracktemplate$", "")
                              :gsub("%.rpp$", "")

      table.insert(files, {
        name = display_name,
        filename = file,
        type = "template",
        template_type = template_type,
        path = file_path,
        relative_path = file_relative,
        file_size = 0 -- Could be populated if needed
      })
    end

    file_index = file_index + 1
  end

  -- Sort folders and files separately, then combine
  table.sort(folders, function(a, b) return a.name:lower() < b.name:lower() end)
  table.sort(files, function(a, b) return a.name:lower() < b.name:lower() end)

  -- Combine folders first, then files
  for _, folder in ipairs(folders) do
    table.insert(items, folder)
  end
  for _, file in ipairs(files) do
    table.insert(items, file)
  end

  return items
end

local function scan_templates()
  local templates_folder = get_templates_folder()

  -- Create folder if it doesn't exist
  reaper.RecursiveCreateDirectory(templates_folder, 0)

  -- Scan recursively
  local tree = scan_folder_recursive(templates_folder, "")

  return tree
end

local function flatten_templates(tree_items, flattened)
  flattened = flattened or {}

  for _, item in ipairs(tree_items) do
    if item.type == "template" then
      table.insert(flattened, item)
    elseif item.type == "folder" and item.children then
      flatten_templates(item.children, flattened)
    end
  end

  return flattened
end

local function filter_templates(tree_items, search_term)
  if search_term == "" then
    return tree_items
  end

  local filtered = {}
  local search_lower = search_term:lower()

  for _, item in ipairs(tree_items) do
    if item.type == "template" then
      if item.name:lower():find(search_lower, 1, true) then
        table.insert(filtered, item)
      end
    elseif item.type == "folder" and item.children then
      local filtered_children = filter_templates(item.children, search_term)
      if #filtered_children > 0 then
        local folder_copy = {
          name = item.name,
          type = item.type,
          path = item.path,
          relative_path = item.relative_path,
          children = filtered_children,
          expanded = true -- Auto-expand when searching
        }
        table.insert(filtered, folder_copy)
      end
    end
  end

  return filtered
end

------------------------------------------------------
-- TEMPLATE INSERTION
------------------------------------------------------

local function insert_template(template)
  if not template then
    reaper.ShowMessageBox("No template selected", "Error", 0)
    return false
  end

  if not reaper.file_exists(template.path) then
    reaper.ShowMessageBox("Template file not found:\n" .. template.path, "Error", 0)
    return false
  end

  local success = false

  if template.template_type == "Track" then
    -- Get the current track selection to insert after
    local selected_track = reaper.GetSelectedTrack(0, 0)
    local insert_position = selected_track and (reaper.GetMediaTrackInfo_Value(selected_track, "IP_TRACKNUMBER") - 1) or reaper.CountTracks(0)

    -- Store current track count
    local track_count_before = reaper.CountTracks(0)

    -- Open the track template file as a project to extract its tracks
    reaper.Main_openProject(template.path)

    -- Get the track count after opening the template
    local track_count_after = reaper.CountTracks(0)

    if track_count_after > track_count_before then
      -- Move the newly inserted tracks to the correct position
      if selected_track and insert_position < track_count_before then
        -- We need to move the tracks to after the selected track
        local tracks_to_move = track_count_after - track_count_before

        -- Move each new track to the correct position
        for i = 0, tracks_to_move - 1 do
          local track_to_move = reaper.GetTrack(0, track_count_before + i)
          if track_to_move then
            reaper.SetOnlyTrackSelected(track_to_move)
            -- Move track to position after selected track
            for j = 0, (insert_position + i) - (track_count_before + i) do
              reaper.Main_OnCommand(40867, 0) -- Track: Move tracks up
            end
          end
        end
      end

      success = true
    end

  elseif template.template_type == "Project" then
    -- For .RPP files in track templates folder, treat them as projects to extract tracks from
    local choice = reaper.ShowMessageBox(
      "This appears to be a project file in your track templates folder.\n\n" ..
      "How would you like to insert it?\n\n" ..
      "Yes - Insert tracks from this project\n" ..
      "No - Open as new project\n" ..
      "Cancel - Cancel operation",
      "Insert Project as Tracks",
      3
    )

    if choice == 6 then -- Yes - Insert tracks
      local track_count_before = reaper.CountTracks(0)

      -- Open the project file to extract tracks
      reaper.Main_openProject(template.path)

      local track_count_after = reaper.CountTracks(0)
      if track_count_after > track_count_before then
        success = true
      end
    elseif choice == 7 then -- No - Open as new project
      reaper.Main_OnCommand(40859, 0) -- File: Close project
      reaper.Main_openProject(template.path)
      success = true
    else -- Cancel
      return false
    end
  end

  if success then
    reaper.UpdateArrange()
    reaper.TrackList_AdjustWindows(false)
  end

  return success
end

------------------------------------------------------
-- GUI FUNCTIONS
------------------------------------------------------

local function draw_search_box()
  reaper.ImGui_Text(ctx, "Search Track Templates:")
  reaper.ImGui_SameLine(ctx)

  -- Auto-focus when window appears
  local flags = 0
  if reaper.ImGui_IsWindowAppearing(ctx) and settings.remember_last_search_term and search_text ~= "" then
    flags = reaper.ImGui_InputTextFlags_AutoSelectAll()
  end
  if reaper.ImGui_IsWindowAppearing(ctx) then
    reaper.ImGui_SetKeyboardFocusHere(ctx)
  end

  -- Regular input: report changes on each keystroke
  local changed, new_text = reaper.ImGui_InputText(ctx, "##search", search_text, flags)
  if changed then
    search_text = new_text
    if settings.remember_last_search_term then
      settings.last_search_text = new_text
      save_settings()
    end
    if search_text == "" then
      filtered_templates = template_tree
    else
      filtered_templates = filter_templates(template_tree, search_text)
    end

    -- Ensure the first result is selected by default when the search changes
    local results = flatten_templates(filtered_templates)
    if #results > 0 then
      local found = false
      if selected_template then
        for i, t in ipairs(results) do
          if t.path == selected_template.path then
            found = true
            break
          end
        end
      end
      if not found then
        selected_template = results[1]
      end
    end
  end

  -- Handle keyboard navigation and enter-to-insert when search box is focused
  if reaper.ImGui_IsItemFocused(ctx) then
    local results = flatten_templates(filtered_templates)

    -- Act on keyboard if there are results (even if the search is empty)
    if #results > 0 then
      -- Determine current selected index within results
      local current_index = 1
      if selected_template then
        for i, t in ipairs(results) do
          if t.path == selected_template.path then
            current_index = i
            break
          end
        end
      end

      -- Up/Down arrows to change highlighted (selected) template
      if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_DownArrow()) then
        current_index = math.min(current_index + 1, #results)
        selected_template = results[current_index]
      elseif reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_UpArrow()) then
        current_index = math.max(current_index - 1, 1)
        selected_template = results[current_index]
      end

      -- Enter inserts the selected template (defaulting to the first result)
      if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Enter()) then
        local to_insert = selected_template or results[1]
        if insert_template(to_insert) then
          if settings.auto_close_on_insert then
            window_open = false
          end
        end
      end
    end
  end

  -- Show count
  reaper.ImGui_SameLine(ctx)
  local flat_templates = flatten_templates(template_tree)
  local flat_filtered = flatten_templates(filtered_templates)
  reaper.ImGui_Text(ctx, string.format("(%d/%d)", #flat_filtered, #flat_templates))
end

local function draw_tree_node(item, depth)
  depth = depth or 0
  local indent = depth * 20

  if item.type == "folder" then
    -- Draw folder node
    reaper.ImGui_SetCursorPosX(ctx, reaper.ImGui_GetCursorPosX(ctx) + indent)

    local node_flags = reaper.ImGui_TreeNodeFlags_OpenOnArrow() | reaper.ImGui_TreeNodeFlags_OpenOnDoubleClick()
    if item.expanded then
      node_flags = node_flags | reaper.ImGui_TreeNodeFlags_DefaultOpen()
    end

    -- Use TreeNode instead of TreeNodeEx to see if it displays correctly
    local unique_id = "folder_" .. tostring(math.random(1000000))
    reaper.ImGui_PushID(ctx, unique_id)

    local tree_open = false
    if item.expanded then
      reaper.ImGui_SetNextItemOpen(ctx, true)
    end

    tree_open = reaper.ImGui_TreeNode(ctx, item.name)

    -- Update expanded state
    if tree_open ~= item.expanded then
      item.expanded = tree_open
      expanded_folders[item.relative_path] = tree_open
    end

    if tree_open then
      -- Draw children
      if item.children then
        for _, child in ipairs(item.children) do
          draw_tree_node(child, depth + 1)
        end
      end
      reaper.ImGui_TreePop(ctx)
    end

    reaper.ImGui_PopID(ctx)

  elseif item.type == "template" then
    -- Draw template item
    reaper.ImGui_SetCursorPosX(ctx, reaper.ImGui_GetCursorPosX(ctx) + indent)

    -- Use path for comparison since template objects might be different instances
    local is_selected = (selected_template and selected_template.path == item.path)
    local selectable_flags = reaper.ImGui_SelectableFlags_AllowDoubleClick()

    -- Calculate available width for template name to avoid overlap with tag
    local available_width = reaper.ImGui_GetContentRegionAvail(ctx)
    local tag_width = 60 -- Width needed for [Track] tag
    local name_width = available_width - tag_width - 10 -- Leave some padding

    -- Create a unique ID for the selectable
    local unique_id = "template_" .. item.relative_path

    if reaper.ImGui_Selectable(ctx, item.name .. "##" .. unique_id, is_selected, selectable_flags, name_width, 0) then
      selected_template = item
    end

    -- Double-click to insert
    if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
      if insert_template(item) then
        if settings.auto_close_on_insert then
          window_open = false
        end
      end
    end

    -- Show tooltip with details
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_BeginTooltip(ctx)
      reaper.ImGui_Text(ctx, "Type: " .. item.template_type .. " Template")
      reaper.ImGui_Text(ctx, "File: " .. item.filename)
      if settings.show_file_paths then
        reaper.ImGui_Text(ctx, "Path: " .. item.path)
      end
      reaper.ImGui_EndTooltip(ctx)
    end

    -- Show template type indicator on the same line, aligned to the right
    reaper.ImGui_SameLine(ctx)
    local cursor_x = reaper.ImGui_GetCursorPosX(ctx)
    local content_width = reaper.ImGui_GetContentRegionAvail(ctx)
    reaper.ImGui_SetCursorPosX(ctx, cursor_x + content_width - tag_width)

    local color = item.template_type == "Track" and 0xFF4444FF or 0xFF44FF44
    reaper.ImGui_TextColored(ctx, color, "[" .. item.template_type .. "]")
  end
end

local function draw_template_tree()
  if reaper.ImGui_BeginChild(ctx, "TemplateTree", 0, -100) then
    if #filtered_templates == 0 then
      if #template_tree == 0 then
        reaper.ImGui_Text(ctx, "No templates found.")
        reaper.ImGui_Text(ctx, "Templates folder: " .. get_templates_folder())
        reaper.ImGui_Text(ctx, "")
        reaper.ImGui_Text(ctx, "Place .RTrackTemplate files in your TrackTemplates folder")
        reaper.ImGui_Text(ctx, "to see them here. You can also organize them in subfolders.")
      else
        reaper.ImGui_Text(ctx, "No templates match your search.")
      end
    else
      for _, item in ipairs(filtered_templates) do
        draw_tree_node(item, 0)
      end
    end

    reaper.ImGui_EndChild(ctx)
  end
end

local function draw_settings_section()
  if reaper.ImGui_CollapsingHeader(ctx, "Settings") then
    -- Auto-close setting
    local auto_close_changed, new_auto_close = reaper.ImGui_Checkbox(ctx, "Auto-close on insert", settings.auto_close_on_insert)
    if auto_close_changed then
      settings.auto_close_on_insert = new_auto_close
      save_settings()
    end

    -- Show file paths setting
    local show_paths_changed, new_show_paths = reaper.ImGui_Checkbox(ctx, "Show file paths in tooltips", settings.show_file_paths)
    if show_paths_changed then
      settings.show_file_paths = new_show_paths
      save_settings()
    end

    -- Remember last search term
    local remember_changed, new_remember = reaper.ImGui_Checkbox(ctx, "Remember last search term", settings.remember_last_search_term)
    if remember_changed then
      settings.remember_last_search_term = new_remember
      save_settings()
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx, "When enabled, the last search term is remembered and restored when reopening the script. The search box will be highlighted for easy editing.")
    end

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
  end
end

local function draw_status_bar()
  reaper.ImGui_Separator(ctx)

  -- Buttons
  local available_width = reaper.ImGui_GetContentRegionAvail(ctx)
  reaper.ImGui_SetCursorPosX(ctx, reaper.ImGui_GetCursorPosX(ctx) + available_width - 200)

  -- Refresh button
  if reaper.ImGui_Button(ctx, "Refresh", 60, 25) then
    template_tree = scan_templates()
    filtered_templates = template_tree
  end

  reaper.ImGui_SameLine(ctx)

  -- Insert button
  local insert_enabled = (selected_template ~= nil)
  if not insert_enabled then
    reaper.ImGui_BeginDisabled(ctx)
  end

  if reaper.ImGui_Button(ctx, "Insert", 60, 25) then
    if insert_template(selected_template) then
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

-- Add a flag to track if we've set the initial position
local initial_position_set = false

local function draw_main_window()
  local window_flags = reaper.ImGui_WindowFlags_NoSavedSettings() | reaper.ImGui_WindowFlags_NoNavInputs() | reaper.ImGui_WindowFlags_NoNavFocus()

  -- Set window position and size from saved settings only once
  if not initial_position_set and settings.window_x >= 0 and settings.window_y >= 0 then
    reaper.ImGui_SetNextWindowPos(ctx, settings.window_x, settings.window_y)
    reaper.ImGui_SetNextWindowSize(ctx, settings.window_width, settings.window_height)
    initial_position_set = true
  end

  local visible, open = reaper.ImGui_Begin(ctx, "Track Template Insert", true, window_flags)

  if visible then
    draw_search_box()
    reaper.ImGui_Spacing(ctx)
    draw_template_tree()
    draw_settings_section()
    draw_status_bar()

    -- Save window state every frame (but only if it actually changed)
    save_window_state()

    reaper.ImGui_End(ctx)
  end

  return open
end

------------------------------------------------------
-- MAIN LOOP
------------------------------------------------------

local function init()
  -- Load settings first
  load_settings()

  -- Recreate font with loaded size
  font = reaper.ImGui_CreateFont('sans-serif', settings.font_size)
  reaper.ImGui_Attach(ctx, font)

  if settings.remember_last_search_term then
    search_text = settings.last_search_text or ""
  end

  -- Scan for templates
  template_tree = scan_templates()
  filtered_templates = template_tree

  if search_text ~= "" then
    filtered_templates = filter_templates(template_tree, search_text)
    -- Select first result
    local results = flatten_templates(filtered_templates)
    if #results > 0 then
      selected_template = results[1]
    end
  end

  -- Focus search box
  reaper.ImGui_SetNextWindowFocus(ctx)
end

local function main_loop()
  if not window_open then
    return
  end

  reaper.ImGui_PushFont(ctx, font, settings.font_size)
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

reaper.Undo_EndBlock("Insert Track Template", -1)
reaper.PreventUIRefresh(-1)

-- Cleanup
reaper.atexit(function()
  -- Save settings one final time
  save_settings()

  if ctx and reaper.ImGui_DestroyContext then
    reaper.ImGui_DestroyContext(ctx)
  end
end)