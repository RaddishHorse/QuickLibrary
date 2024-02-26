--- 
FILEPATH_SOURCE = debug.getinfo(1).source:match("@?(.*/)")
FILEPATH_UI = FILEPATH_SOURCE .. "./dialog.ui"
FILEPATH_PREFS = FILEPATH_SOURCE .. "./prefs.ini"
IMAGES_EXTENSIONS = {"svg", "jpg", "jpeg", "png"}
ZOOM_LEVEL_MIN, ZOOM_LEVEL_MAX = 20, 250
IMAGES_INSERT_MARGIN = 20


-- Register toolbar and menu
function initUi()
    app.registerUi({["menu"] = "Quick Library", ["callback"] = "showMainWindow", ["accelerator"] = "<Alt>a",
                    toolbarId = "PLUGIN_QUICK_LIBRARY", ["callback"] = "showMainWindow", iconName="image-x-generic"});

    -- Load lgi globally
    hasLgi, lgi = pcall(require, "lgi")
    
    if not hasLgi then
        app.msgbox("QuickLibrary Plugin | You need to have the Lua lgi-module installed and included in your Lua package path \n\n", {[1]="OK"})
        return
    end
end


-- Get user preferences from ini file
function getUserPreferences()
    local GLib = lgi.GLib

    local keyfile = GLib.KeyFile.new()
    keyfile:load_from_file(FILEPATH_PREFS, GLib.KeyFileFlags.KEEP_TRANSLATIONS)

    --FIXME handle default values and min/max
    return { 
    WindowPosition = {x=keyfile:get_integer("WindowPosition", "x"),
                      y=keyfile:get_integer("WindowPosition", "y")},
                        
    WindowSize = {width=keyfile:get_integer("WindowSize", "width"),
                  height=keyfile:get_integer("WindowSize", "height")},
                    
    Settings = {image_folder=makeFilePathAbsolute(keyfile:get_value("Settings", "image_folder")),
                zoom_level=keyfile:get_double("Settings", "zoom_level"),
                insert_position=keyfile:get_value("Settings", "insert_position"),
                insert_width=keyfile:get_integer("Settings", "insert_width"),
                close_on_insert=keyfile:get_boolean("Settings", "close_on_insert")}, 
    
    save =  function(self)
                for group, values in pairs(self) do
                    item = self[group]
                    
                    if type(item) == "table" then
                        for k, v in pairs(item) do
                            keyfile:set_value(group, k, tostring(v))
                        end
                    end
                end
                keyfile:save_to_file(FILEPATH_PREFS)
           end
    }
end


-- Convert relative path to absolute path (Linux-only)
function makeFilePathAbsolute(path)
    local firstChar = string.sub(path, 1, 1)
    
    if firstChar == '/' then    
        return path --already absolute
    else
        return FILEPATH_SOURCE .. path
    end
end


-- All UI-related functions, display main window, preference window, and register signals
function showMainWindow()
    local Gtk = lgi.require("Gtk", "3.0")
    local Gdk = lgi.Gdk
    local GLib = lgi.GLib
    local GdkPixbuf = lgi.GdkPixbuf
    local assert = lgi.assert
    local builder = Gtk.Builder()

    -- 
    local userprefs = getUserPreferences()
    local images = listImagesFilepaths(userprefs.Settings.image_folder)
    
    assert(builder:add_from_file(FILEPATH_UI))
    local ui = builder.objects
    local mainWindow = ui.mainWindow
    local preferencesWindow = ui.preferencesWindow
    local flowbox = ui.flowBox

    --------------------
    -- Preference window
    function showPreferencesWindow()
        -- Set values of input field
        zoom_level = userprefs.Settings.zoom_level
        ui.zoomLevelAdjustment:set_value(zoom_level)
        
        ui.inputFolder:set_current_folder(userprefs.Settings.image_folder)
        ui.inputInsertPosition:set_active_id(userprefs.Settings.insert_position)
        ui.inputInsertWidth:set_text(userprefs.Settings.insert_width)
        ui.inputCloseOnInsert:set_state(userprefs.Settings.close_on_insert)
                
        -- Redraw image on zoom level change 
        function ui.inputZoomLevel.on_button_release_event(event)
            userprefs.Settings.zoom_level = ui.zoomLevelAdjustment:get_value()
            redrawImages()
        end
                
        -- Display menu
        preferencesWindow:show()
    end
    
    function preferencesWindow.on_closed()
        local redraw = false
        
        -- Redraw is required if folder or zoom level changes
        if ui.inputFolder:get_filename() ~= userprefs.Settings.image_folder 
           or ui.zoomLevelAdjustment:get_value() ~= userprefs.Settings.zoom_level then
            redraw = true
        end
    
    
        -- Set other user prefs values
        userprefs.Settings.image_folder = ui.inputFolder:get_filename()
        userprefs.Settings.zoom_level = ui.zoomLevelAdjustment:get_value()
        userprefs.Settings.insert_position = ui.inputInsertPosition:get_active_id()
        userprefs.Settings.insert_width = tonumber(ui.inputInsertWidth:get_text())
        userprefs.Settings.close_on_insert = ui.inputCloseOnInsert:get_state()        
        
        -- Redraw images if required
        if redraw == true then
            redrawImages()
        end
    end
    
    
    --------------------
    -- Main window
    function closeMainWindow()
        userprefs.WindowSize.width, userprefs.WindowSize.height = mainWindow:get_size()
        userprefs.WindowPosition.x, userprefs.WindowPosition.y = mainWindow:get_position() -- Nort-West by default
        
        userprefs:save()
        mainWindow:destroy()
    end
    
    -- Flowbox - add images to the UI
    function displayImages()
        for i=1, #images do
            local filepath = images[i]
            local image_width = math.floor(userprefs.Settings.zoom_level * (ZOOM_LEVEL_MAX-ZOOM_LEVEL_MIN) + ZOOM_LEVEL_MIN)
            
            local pixbuf = GdkPixbuf.Pixbuf.new_from_file_at_size(filepath, image_width, -1) --fixme into pref
            local image = Gtk.Image.new_from_pixbuf(pixbuf)            
            
            -- eventbox required to detected double clicks and drag-drop
            local eventbox = Gtk.EventBox.new()
            eventbox:add(image)
            eventbox:drag_source_set(Gdk.ModifierType.BUTTON1_MASK, { Gtk.TargetEntry.new("text/uri-list", 0, 0) }, Gdk.DragAction.COPY)  -- image/png if using pixbuf, but limited pic quality           
            
            function eventbox.on_drag_end(widget, drag_context)
                -- Draging file URI or pixbuf does not allow resizing of the elements
                -- therefore we simply use the API to insert the dragged element
                -- and emulate a drag and drop 
                
                -- There is no way to get mouse position, or even current page position
                -- so we insert right in the center
                
                flowbox_selection = getSelectedImages()
                
                -- If dragged item is part of selected flowbox, else insert only the one dragged image
                local dragged_images = {filepath}
                for i=1, #flowbox_selection do                          -- there should be a better way to check for that?
                    if flowbox_selection[i] == filepath then
                        dragged_images = flowbox_selection
                        break
                    end
                end
                
                insertImages(dragged_images, userprefs.Settings.insert_width, "middle-center")
            end
            
            -- Eventbox double click insert
            function eventbox.on_button_press_event(object, event)          
                if event.type == "DOUBLE_BUTTON_PRESS" or event.type == "2BUTTON_PRESS" then
                    insertImages(getSelectedImages(), 
                                 userprefs.Settings.insert_width, 
                                 userprefs.Settings.insert_position)
                    
                    if userprefs.Settings.close_on_insert then
                        closeMainWindow()
                    end
                end
            end
            
            
            local flowboxchild = Gtk.FlowBoxChild.new()
            flowboxchild:add(eventbox)
            
            flowbox:insert(flowboxchild, -1)
        end
    end
    
    -- Clear images displayed in UI
    function clearImages()
        -- flowbox:remove_all()  in gtk4        
        local children = flowbox:get_children()
 
        for i=1, #children do
            flowbox:remove(children[i])
            children[i]:destroy()
        end 
    end
    
    -- Redraw the flowbox
    function redrawImages()
        -- List new image filepaths
        images = listImagesFilepaths(userprefs.Settings.image_folder)

        -- Cleaning and redraw the flowbox
        clearImages()
        displayImages()
        
        -- Needed to show changes
        mainWindow:show_all()
    end
    
    -- Returns selected images in the flowbox
    function getSelectedImages()
        local selected_flowboxchildren = flowbox:get_selected_children() 
        
        local selected_filepaths = {}
        
        for j=1, #selected_flowboxchildren do
            local index = selected_flowboxchildren[j]:get_index() + 1    -- Position starts at 0, but lua index starts at 1
            local filepath = images[index]

            table.insert(selected_filepaths, filepath)
        end
        
        return selected_filepaths
    end
    
    -- Connect button actions
    function ui.btnInsert.on_clicked()
        insertImages(getSelectedImages(), 
                     userprefs.Settings.insert_width, 
                     userprefs.Settings.insert_position)
        
        if userprefs.Settings.close_on_insert then
            closeMainWindow()
        end
    end
    
    function ui.btnClose.on_clicked()
        closeMainWindow()
    end
    
    function ui.btnUserPrefs.on_clicked()
        showPreferencesWindow()
    end
    
    
    
    -- Show window and stuff
    
    -- Display images in the flowbox
    displayImages()
    
    -- Restore window size and position (on Xorg)
    mainWindow:move(userprefs.WindowPosition.x, userprefs.WindowPosition.y)
    mainWindow:resize(userprefs.WindowSize.width, userprefs.WindowSize.height)
    mainWindow:set_keep_above(true)
    
    mainWindow:show_all()
end



-- Lists all images found in the given folder
-- Note: Linux-only function
function listImagesFilepaths(folderPath)
    filepaths = {}
    
    pfile = io.popen('ls -a "' .. folderPath .. '" | grep -E \\.\'' .. table.concat(IMAGES_EXTENSIONS, "$|\\.") .. '$\'')
       
    for filename in pfile:lines() do
        table.insert(filepaths, folderPath .. '/' .. filename)
    end
    
    return filepaths
end


-- Insert given images filepaths into Xournalpp's canvas at the given position (see array below)
function insertImages(images, width, position)
    
    -- Get document size
    local document_structure = app.getDocumentStructure()
    local current_page = document_structure.currentPage
    local page_width = document_structure.pages[current_page].pageWidth 
    local page_height = document_structure.pages[current_page].pageHeight 
    
    -- x, y positions and increments
    local height = width --fixme: height should be fetched for each image individually ? or something
        
    local positions = { 
        ["top-left"] =      {IMAGES_INSERT_MARGIN, IMAGES_INSERT_MARGIN},
        ["top-center"] =    {page_width/2-width/2, IMAGES_INSERT_MARGIN},
        ["top-right"] =     {page_width-width-IMAGES_INSERT_MARGIN, IMAGES_INSERT_MARGIN},
        
        ["middle-left"] =   {IMAGES_INSERT_MARGIN, page_height/2-height/2},
        ["middle-center"] = {page_width/2-width/2, page_height/2-height/2},
        ["middle-right"] =  {page_width-width-IMAGES_INSERT_MARGIN, page_height/2-height/2},
        
        ["bottom-left"] =   {IMAGES_INSERT_MARGIN, page_height-height-IMAGES_INSERT_MARGIN},
        ["bottom-center"] = {page_width/2-width/2, page_height-height-IMAGES_INSERT_MARGIN},
        ["bottom-right"] =  {page_width-width-IMAGES_INSERT_MARGIN, page_height-height-IMAGES_INSERT_MARGIN}
    }

    local x = positions[position][1] 
    local y = positions[position][2]
    local increment = math.floor(width * 0.25)

    -- Prepare array for insertion into xournalpp
    local images_insert_array = {}

    for j=1, #images do
        table.insert(images_insert_array, {path=images[j], 
                                           x=x, y=y, 
                                           maxWidth=width})
                                          
        -- Calculate offset of the next inserted image
        x, y = x+increment, y+increment
    end
 
    -- Insert images in xournalpp
    app.addImagesFromFilepath({images=images_insert_array, allowUndoRedoAction = "grouped"})
    
    -- Scroll to insert position -> I don't understand xournalpp's scroll behaviour, seems to change according to zoom level... ??
    --~ app.scrollToPage(current_page) --> this resets the scroll position to 0,0
    --~ app.scrollToPos(x, y, false)  -- -> this scrolls back to page 1
    --~ app.scrollToPos(x, (current_page-1)*page_height + y, false)
    --~ app.scrollToPos(0, 0, false)
    --~ app.scrollToPos(0, (current_page-1)*page_height, false)
end
