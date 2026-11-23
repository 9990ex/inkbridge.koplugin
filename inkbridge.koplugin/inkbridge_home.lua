-- 正在阅读与目录书库；完整同步记录按需展开。
-- 不复制 SimpleUI/ZenOS 的全局补丁，不接管阅读器排版或同步算法。
local Home = { AUTO = "inkbridge_home_auto", PREVIOUS = "inkbridge_home_previous_start" }

-- 只清理展示名称；原始文件路径、书籍身份与缓存内容始终不变。
function Home.displayTitle(value)
    local title = type(value) == "string" and value or ""
    title = title:gsub("%.[eE][pP][uU][bB]$", ""):gsub("%.[tT][xX][tT]$", "")
        :gsub("%.[pP][dD][fF]$", ""):gsub("%.[mM][oO][bB][iI]$", "")
    local function source_tag(group)
        local lower = group:lower()
        if lower:find("z-library", 1, true) or lower:find("z-lib.", 1, true)
                or lower:find("1lib.", 1, true) then return "" end
        return group
    end
    title = title:gsub("%b()", source_tag):gsub("%b[]", source_tag)
        :gsub("_+", " "):gsub("%s+", " "):match("^%s*(.-)%s*$")
    return title ~= "" and title or "未命名书籍"
end

function Home.setAuto(enabled)
    if enabled then
        if not G_reader_settings:readSetting(Home.AUTO) then
            G_reader_settings:saveSetting(Home.PREVIOUS, {
                value = G_reader_settings:readSetting("start_with"),
            })
        end
        G_reader_settings:saveSetting("start_with", "filemanager")
    else
        local previous = G_reader_settings:readSetting(Home.PREVIOUS)
        if previous and G_reader_settings:readSetting("start_with") == "filemanager" then
            if previous.value then G_reader_settings:saveSetting("start_with", previous.value)
            else G_reader_settings:delSetting("start_with") end
        end
        G_reader_settings:delSetting(Home.PREVIOUS)
    end
    G_reader_settings:saveSetting(Home.AUTO, enabled and true or false)
end

function Home.attach(plugin)
    if not plugin.ui or plugin.ui.document then return end
    local fm = plugin.ui
    -- 只挂接当前文件管理器实例的 Home 动作，不修改共享类或主目录设置。
    -- 原生文件管理器左上角房子／Home 键应能回到墨桥首页。
    if not fm._inkbridge_home_route and type(fm.onHome) == "function" then
        local native_home = fm.onHome
        fm._inkbridge_home_route = true
        fm.onHome = function(self, ...)
            if G_reader_settings:readSetting(Home.AUTO) then
                Home.show(plugin)
                return true
            end
            return native_home(self, ...)
        end
    end
    if not Home.pending and not (G_reader_settings:readSetting(Home.AUTO)
            and G_reader_settings:readSetting("start_with") == "filemanager") then return end
    Home.pending = nil
    require("ui/uimanager"):nextTick(function()
        local Reader = package.loaded["apps/reader/readerui"]
        if not (Reader and Reader.instance) then Home.show(plugin) end
    end)
end

function Home.show(plugin, view, history_page, library_data)
    view = view == "history" and "history" or view == "library" and "library" or "reading"
    history_page = math.max(1, math.floor(tonumber(history_page) or 1))
    local UIManager = require("ui/uimanager")
    if plugin.ui and plugin.ui.document then
        Home.pending = true
        plugin.ui:onHome()
        return
    end
    if Home.instance then return end
    if view == "library" then
        library_data = library_data or { source = "local", loading = true }
        library_data.books = library_data.books or {}
        library_data.skipped = library_data.skipped or 0
    end
    local InputContainer = require("ui/widget/container/inputcontainer")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local LeftContainer = require("ui/widget/container/leftcontainer")
    local TopContainer = require("ui/widget/container/topcontainer")
    local LineWidget = require("ui/widget/linewidget")
    local TextWidget = require("ui/widget/textwidget")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local Button = require("ui/widget/button")
    local GestureRange = require("ui/gesturerange")
    local Geom = require("ui/geometry")
    local Font = require("ui/font")
    local Material = require("inkbridge_material")
    local Device = require("device")
    local Screen = Device.screen
    local History = require("inkbridge_home_history")
    local InfoMessage = Material.widget("infomessage")
    local ConfirmBox = Material.widget("confirmbox")
    local ButtonDialog = Material.widget("buttondialog")
    local Blitbuffer = require("ffi/blitbuffer")
    local W, H = Screen:getWidth(), Screen:getHeight()
    local function px(n) return Screen:scaleBySize(n) end
    local pad = px(24)
    local width = W - 2 * pad
    local navigation_height = px(Material.navigation_height or 96)
    local navigation_button_height = px(Material.navigation_button_height or 88)
    local button_height = px(Material.button_height or 48)
    local content_width = width
    local Page = InputContainer:extend{ name = "inkbridge_home", covers_fullscreen = true }
    local page = Page:new{ dimen = Geom:new{ w = W, h = H } }
    Home.instance = page
    page.view = view
    page.library_data = library_data

    function page:stopClock()
        if self.tick then UIManager:unschedule(self.tick) end
    end
    function page:onCloseWidget()
        self:stopClock()
        if self.cancel_scan then self.cancel_scan() end
        if self.cancel_preview then self.cancel_preview() end
        if Home.instance == self then Home.instance = nil end
    end
    function page:leave()
        UIManager:close(self, "ui")
    end
    function page:onHomeBack()
        if view == "library" and library_data.directory
                and require("inkbridge_library").viewOptions().mode == "folders" then
            local parent = require("inkbridge_library").parentFolder(library_data.directory, library_data.root)
            if parent ~= library_data.directory then
                library_data.directory = parent
                self:leave()
                Home.show(plugin, "library", 1, library_data)
                return true
            end
        end
        self:leave()
        if view == "history" or view == "library" then Home.show(plugin) end
        return true
    end
    function page:onSuspend()
        self:stopClock()
        if self.cancel_preview and self.preview_running then
            self.cancel_preview()
            self.preview_cancelled, self.preview_running = true, false
        end
    end
    function page:onResume()
        if self.preview_cancelled then
            self:leave()
            Home.show(plugin, view, history_page, library_data)
        elseif self.tick then self.tick() end
    end
    function page:onShowingReader() self:leave() end
    function page:onSetDimensions()
        self:leave()
        UIManager:nextTick(function() Home.show(plugin, view, history_page, library_data) end)
        return true
    end
    page.key_events = { HomeBack = { { Device.input.group.Back } } }
    local menu = plugin.ui and plugin.ui.menu
    if Device:isTouchDevice() and menu and type(menu.onSwipeShowMenu) == "function" then
        local menu_zone = G_defaults:readSetting("DTAP_ZONE_MENU")
        local extended_zone = G_defaults:readSetting("DTAP_ZONE_MENU_EXT")
        page:registerTouchZones({
            {
                id = "inkbridge_home_menu_tap",
                ges = "tap",
                screen_zone = {
                    ratio_x = menu_zone.x, ratio_y = menu_zone.y,
                    ratio_w = menu_zone.w, ratio_h = menu_zone.h,
                },
                handler = function(ges) return menu:onTapShowMenu(ges) end,
            },
            {
                id = "inkbridge_home_menu_tap_ext",
                ges = "tap",
                screen_zone = {
                    ratio_x = extended_zone.x, ratio_y = extended_zone.y,
                    ratio_w = extended_zone.w, ratio_h = extended_zone.h,
                },
                overrides = { "inkbridge_home_menu_tap" },
                handler = function(ges) return menu:onTapShowMenu(ges) end,
            },
            {
                id = "inkbridge_home_menu_swipe",
                ges = "swipe",
                screen_zone = {
                    ratio_x = menu_zone.x, ratio_y = menu_zone.y,
                    ratio_w = menu_zone.w, ratio_h = menu_zone.h,
                },
                handler = function(ges) return menu:onSwipeShowMenu(ges) end,
            },
            {
                id = "inkbridge_home_menu_swipe_ext",
                ges = "swipe",
                screen_zone = {
                    ratio_x = extended_zone.x, ratio_y = extended_zone.y,
                    ratio_w = extended_zone.w, ratio_h = extended_zone.h,
                },
                overrides = { "inkbridge_home_menu_swipe" },
                handler = function(ges) return menu:onSwipeShowMenu(ges) end,
            },
        })
    end

    local muted = Blitbuffer.COLOR_DARK_GRAY
    local function gap(n) return VerticalSpan:new{ width = px(n) } end
    local function rule(heavy, rule_width)
        return LineWidget:new{
            dimen = Geom:new{ w = rule_width or content_width, h = math.max(1, px(heavy and 2 or 1)) },
            background = Blitbuffer.COLOR_LIGHT_GRAY,
        }
    end
    local function text(value, size, opts)
        opts = opts or {}
        local face = Font:getFace(opts.serif and "NotoSerif-Regular.ttf" or "cfont", size or 17)
        local line_height = opts.line_height or 0.3
        return TextBoxWidget:new{
            text = value, width = opts.width or content_width, face = face,
            bold = opts.bold, fgcolor = opts.muted and muted or Blitbuffer.COLOR_BLACK,
            alignment = opts.align or "left",
            line_height = line_height,
            height = opts.lines and math.floor(face.size * (1 + line_height) + 0.5) * opts.lines or nil,
            height_adjust = opts.lines ~= nil, height_overflow_show_ellipsis = opts.lines ~= nil,
        }
    end
    local function action(label, callback, opts)
        opts = opts or {}
        return Material.button{ text = label, callback = callback, width = opts.width,
            show_parent = page, size = opts.size or 14, bold = opts.bold,
            icon = opts.icon, selected = opts.selected,
            height = button_height }
    end
    local function spread(left, right, row_width)
        return HorizontalGroup:new{ align = "center", left,
            HorizontalSpan:new{ width = math.max(0, (row_width or content_width) - left:getSize().w - right:getSize().w) }, right }
    end
    local weekdays = { "星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六" }
    local date_width = math.min(px(158), math.floor(width * 0.4))
    local date_line = TextWidget:new{ text = os.date("%Y / %m / %d"),
        face = Font:getFace("cfont", 15), width = date_width }
    local weekday = TextWidget:new{ text = weekdays[tonumber(os.date("%w")) + 1],
        face = Font:getFace("cfont", 15), width = date_width }
    local lunar_date = TextWidget:new{ text = require("inkbridge_calendar").format(),
        face = Font:getFace("cfont", 14), width = date_width }
    local clock = TextWidget:new{ text = os.date("%H:%M"),
        face = Font:getFace("cfont", W < H and 60 or 42),
        max_width = width - date_width, padding = 0 }
    local header
    page.tick = function()
        page:stopClock()
        if view == "library" then return end
        clock:setText(os.date("%H:%M"))
        date_line:setText(os.date("%Y / %m / %d"))
        weekday:setText(weekdays[tonumber(os.date("%w")) + 1])
        lunar_date:setText(require("inkbridge_calendar").format())
        UIManager:setDirty(page, "ui", header and header.dimen or clock.dimen)
        UIManager:scheduleIn(60 - tonumber(os.date("%S")), page.tick)
    end

    local content = VerticalGroup:new{ align = "left" }
    local function openBook(book, record)
        local lfs = require("libs/libkoreader-lfs")
        if lfs.attributes(book.file, "mode") ~= "file" then
            UIManager:show(InfoMessage:new{ text = "这本书已移动或不存在，请从书库重新打开。" })
            return
        end
        page:leave()
        require("apps/reader/readerui"):showReader(book.file, nil, nil, nil, function(reader)
            if not record then return end
            UIManager:nextTick(function()
                if not reader.document or reader.document.file ~= book.file then return end
                local id = require("inkbridge_state").book_id(book.file, reader)
                if not book.book_id or id ~= book.book_id then
                    UIManager:show(InfoMessage:new{ text = "原书版本无法核对，已打开书籍但未跳转旧记录。" })
                    return
                end
                require("inkbridge_webdav").confirm_jump({ ui = reader }, {
                    text_anchor = record.text, require_unique_text = true,
                    character_percent = record.percent,
                    device_label = record.source,
                }, { home_replay = true })
            end)
        end)
    end

    local Row = InputContainer:extend{}
    function Row:onHomeRecord() self.callback(); return true end
    local function recordRow(widget, callback)
        local frame = FrameContainer:new{ padding = 0, margin = 0, bordersize = 0, widget }
        local row = Row:new{ frame, callback = callback }
        row.ges_events = { HomeRecord = { GestureRange:new{
            ges = "tap", range = function() return frame.dimen end,
        } } }
        return row
    end
    local function metadata(record)
        local stamp, original = History.format_time(record)
        return (record.source or "墨桥") .. " · " .. stamp .. (original and "" or " 读取")
    end
    local function percentage(record)
        local p = record and tonumber(record.percent)
        if p and p == p and p >= 0 and p <= 1 then return string.format("%.1f%%", p * 100) end
        return nil
    end
    local function showRecords(book)
        local paragraphs, targets = { book.title }, {}
        local viewer
        for i, record in ipairs(book.records) do
            local r = record
            paragraphs[#paragraphs + 1] = "记录 " .. i .. "  ·  " .. metadata(r)
                .. (percentage(r) and " · " .. percentage(r) or "")
                .. (r.chapter and r.chapter ~= "" and ("\n" .. r.chapter) or "")
                .. "\n" .. (r.excerpt and r.excerpt ~= "" and r.excerpt or r.text)
                .. (r.excerpt and r.excerpt ~= "" and ("\n原同步锚点：" .. r.text) or "")
                .. (r.note and r.note ~= "" and "\n" .. r.note or "")
            targets[#targets + 1] = { text = "打开记录 " .. i, callback = function()
                UIManager:close(viewer)
                openBook(book, r)
            end }
        end
        viewer = require("ui/widget/textviewer"):new{
            title = "同步记录", text = table.concat(paragraphs, "\n\n"),
            buttons_table = { targets, {{ text = "返回", callback = function() UIManager:close(viewer) end }} },
        }
        local native_close = viewer.onCloseWidget
        function viewer:onCloseWidget()
            if native_close then native_close(self) end
            if Home.instance == page then page.tick() end
        end
        page:stopClock()
        UIManager:show(viewer)
    end
    local function manageBook(book)
        local dialog
        dialog = ButtonDialog:new{
            title = "管理书籍",
            buttons = {
                {{ text = "查看同步记录", callback = function()
                    UIManager:close(dialog)
                    showRecords(book)
                end }},
                {{ text = "取消", callback = function() UIManager:close(dialog) end }},
            },
        }
        UIManager:show(dialog)
    end
    local Library = require("inkbridge_library")
    local library_options = view == "library" and Library.viewOptions()
    local library_entries
    local function rebuildLibrary()
        page:leave()
        Home.show(plugin, "library", 1, library_data)
    end
    local function openLibrary(source)
        if type(source) ~= "string" then source = library_data and library_data.source or "local" end
        page:leave()
        Home.show(plugin, "library", 1, { source = source, loading = true })
    end
    local function chooseLibraryFolder()
        local source = library_data.source
        local function chosen(ok, message)
            if not ok then UIManager:show(InfoMessage:new{ text = message, timeout = 6 }); return end
            UIManager:nextTick(function()
                if Home.instance == page then openLibrary(source) end
            end)
        end
        if source == "local" then Library.pickLocalFolder(plugin, chosen)
        elseif not Library.pickFolder(plugin, chosen) then
            UIManager:show(InfoMessage:new{ text = "KOReader WebDAV 目录选择器不可用。", timeout = 6 })
        end
    end
    local function adjustLibraryList()
        local dialog
        local function option(key, value, label)
            return { text = (library_options[key] == value and "✓ " or "") .. label, callback = function()
                Library.setViewOption(key, value)
                UIManager:close(dialog)
                rebuildLibrary()
            end }
        end
        dialog = ButtonDialog:new{ title = "列表调整 · 行高与排序", buttons = {
            { option("density", "compact", "紧凑"), option("density", "normal", "标准"), option("density", "large", "宽松") },
            { option("sort", "name", "名称升序"), option("sort", "descending", "名称降序") },
            { option("sort", "modified", "最近修改优先") },
            {{ text = "返回书库", callback = function() UIManager:close(dialog) end }},
        } }
        UIManager:show(dialog)
    end
    local function showLibraryBook(book)
        local data, rows = library_data, {}
        if book.file then
            rows[#rows + 1] = { text = "打开书籍", callback = function()
                UIManager:close(page.book_menu)
                openBook(book)
            end }
            rows[#rows + 1] = { text = "本地文件 · " .. book.file, dim = true }
            local Files = require("inkbridge_book_files")
            local function currentFile() return plugin.ui and plugin.ui.document and plugin.ui.document.file end
            local function snapshot()
                local ok, value, err = pcall(Files.snapshot, book.file)
                if ok and value then return value end
                UIManager:show(InfoMessage:new{ text = ok and err or "无法读取本地文件信息。", timeout = 6 })
            end
            local function result(ok, message)
                UIManager:show(InfoMessage:new{ text = message, timeout = 7 })
                if ok then
                    UIManager:close(page.book_menu)
                    openLibrary(library_data.source)
                end
            end
            local function editFilename(done)
                local original = snapshot()
                if not original then return end
                local dialog
                dialog = Material.widget("inputdialog"):new{
                    title = "编辑文件名（保留扩展名）", input = book.file:match("([^/]+)$"),
                    buttons = {{ { text = "取消", id = "close", callback = function() UIManager:close(dialog) end },
                        { text = "改名", callback = function()
                            local ok, message = Files.rename(original, dialog:getInputText(), currentFile())
                            if ok then
                                UIManager:close(dialog)
                                done(message)
                            else UIManager:show(InfoMessage:new{ text = message, timeout = 6 }) end
                        end } }},
                }
                UIManager:show(dialog)
                dialog:onShowKeyboard()
            end
            local function askDelete(purge, dialog)
                    local original = snapshot()
                    if not original then return end
                    local confirm
                    confirm = ConfirmBox:new{
                        text = "永久删除本地书籍文件？\n" .. book.file .. "\n\n"
                            .. (purge and "同时删除本机阅读进度、书签、批注和墨桥缓存。" or "保留本机阅读进度、书签、批注和墨桥缓存。")
                            .. "\n云端文件和记录不变。",
                        ok_text = "确认删除", ok_callback = function()
                            UIManager:close(confirm)
                            local ok, message = Files.delete(original, purge, currentFile())
                             if ok and dialog then UIManager:close(dialog) end
                            result(ok, message)
                        end,
                    }
                    UIManager:show(confirm)
            end
            rows[#rows + 1] = { text = "文件存留 · " .. (Files.kept(book.file) and "已标记保留" or "正常"),
                short_text = "文件存留", icon = "bookmark", callback = function()
                local dialog
                dialog = ButtonDialog:new{
                    title = "文件存留 · " .. Home.displayTitle(book.title), buttons = {
                        {{ text = Files.kept(book.file) and "取消保留标记" or "标记保留（阻止删除）",
                            short_text = Files.kept(book.file) and "取消保留" or "标记保留", icon = "bookmark", callback = function()
                            Files.setKept(book.file, not Files.kept(book.file))
                            UIManager:close(dialog); UIManager:close(page.book_menu); showLibraryBook(book)
                        end }},
                        {{ text = "删除文件，保留阅读数据", short_text = "仅删文件", enabled = not Files.kept(book.file), callback = function() askDelete(false, dialog) end }},
                        {{ text = "删除文件及本机阅读数据", short_text = "文件及数据", enabled = not Files.kept(book.file), callback = function() askDelete(true, dialog) end }},
                        {{ text = "返回", callback = function() UIManager:close(dialog) end }},
                    },
                }
                UIManager:show(dialog)
            end }
            rows[#rows + 1] = { text = "删除文件", icon = "cancel", enabled = not Files.kept(book.file), callback = function()
                local dialog
                dialog = ButtonDialog:new{ title = "删除文件", buttons = {
                    {{ text = "删除文件，保留阅读数据", short_text = "仅删文件", icon = "cancel",
                        callback = function() askDelete(false, dialog) end }},
                    {{ text = "删除文件及本机阅读数据", short_text = "文件及数据", icon = "cancel",
                        callback = function() askDelete(true, dialog) end }},
                    {{ text = "返回", callback = function() UIManager:close(dialog) end }},
                } }
                UIManager:show(dialog)
            end }
            if book.file:lower():sub(-5) == ".epub" then
                rows[#rows + 1] = { text = "EPUB 元数据", icon = "edit", callback = function()
                    UIManager:close(page.book_menu)
                    require("inkbridge_book_metadata").show(plugin, book.file, {
                        finished = function() if Home.instance == page then openLibrary(library_data.source) end end,
                    })
                end }
            else
                rows[#rows + 1] = { text = "编辑文件名", icon = "edit", callback = function()
                    editFilename(function(message) result(true, message) end)
                end }
            end
        end
        if data.source == "local" and not book.cloud_loaded then
            rows[#rows + 1] = { text = "读取这本书的云端记录", short_text = "读取云端", icon = "wifi", callback = function()
                local id = require("inkbridge_state").book_id(book.file)
                if type(id) ~= "string" or #id ~= 32 then
                    UIManager:show(InfoMessage:new{ text = "无法核对书籍身份。", timeout = 5 })
                    return
                end
                local progress = InfoMessage:new{ text = "正在读取云端同步记录。", timeout = 95 }
                UIManager:show(progress)
                local sync_plugin = Library.client(plugin, plugin.server)
                Library.scan(sync_plugin, function(ok, records)
                    UIManager:close(progress)
                    if Home.instance ~= page then return end
                    if not ok then UIManager:show(InfoMessage:new{ text = records, timeout = 6 }); return end
                    book.id, book.cloud_loaded, book.cloud_records = id, true, {}
                    for _, row in ipairs(records) do
                        if row.book_id == id then table.insert(book.cloud_records, row) end
                    end
                    data.sync_plugin = sync_plugin
                    UIManager:close(page.book_menu)
                    showLibraryBook(book)
                end)
            end }
        end
        if book.remote then
            rows[#rows + 1] = { text = "WebDAV 文件 · " .. book.remote.path, dim = true }
        end
        local record_actions, showUnified, record_viewer = {}, nil, nil
        local function deletedRecord(row, source)
            for i = #source, 1, -1 do if source[i] == row then table.remove(source, i) end end
            for i = #record_actions, 1, -1 do
                if record_actions[i].row == row then table.remove(record_actions, i) end
            end
            if record_viewer then UIManager:close(record_viewer); record_viewer = nil end
            showUnified()
        end
        for _, row in ipairs(book.local_records or {}) do
            record_actions[#record_actions + 1] = {
                row = row, location = "本机缓存",
                text = "删除本机缓存 · " .. row.record.source .. " · " .. History.format_time(row.record)
                    .. "\n" .. row.record.text,
                short_text = "本机 · " .. History.format_time(row.record), icon = "appbar.navigation",
                callback = function()
                    local confirm
                    confirm = ConfirmBox:new{
                        text = "仅删除选中的这条本地缓存？\n\n" .. row.record.source .. " · " .. History.format_time(row.record)
                            .. "\n" .. row.record.text .. "\n\n其他记录和云端内容不变。",
                        ok_text = "删除此条",
                        ok_callback = function()
                            UIManager:close(confirm)
                             if Library.delete_local(row) then
                                 deletedRecord(row, book.local_records)
                                UIManager:show(InfoMessage:new{ text = "已删除这条本地缓存。", timeout = 4 })
                            else UIManager:show(InfoMessage:new{ text = "本地缓存已变化，未删除。", timeout = 5 }) end
                        end,
                    }
                    UIManager:show(confirm)
                end,
            }
        end
        for _, row in ipairs(book.cloud_records or {}) do
            record_actions[#record_actions + 1] = {
                row = row, location = "云端记录",
                text = "删除云端记录 · " .. row.record.source .. " · " .. History.format_time(row.record)
                    .. (percentage(row.record) and (" · " .. percentage(row.record)) or "")
                    .. "\n" .. row.record.text,
                short_text = "云端 · " .. History.format_time(row.record), icon = "wifi",
                callback = function()
                    local confirm
                    confirm = ConfirmBox:new{
                        text = "仅删除选中的这条云端记录？\n\n" .. row.record.source .. " · " .. History.format_time(row.record)
                            .. "\n" .. row.record.text .. "\n\n本地缓存和其他云端记录不变。",
                        ok_text = "删除此条",
                        ok_callback = function()
                            UIManager:close(confirm)
                            local progress = InfoMessage:new{ text = "正在核验云端记录版本。", timeout = 95 }
                            UIManager:show(progress)
                             Library.delete_cloud(data.sync_plugin, book, row, function(deleted, message)
                                 UIManager:close(progress)
                                 if deleted and Home.instance == page then deletedRecord(row, book.cloud_records) end
                                UIManager:show(InfoMessage:new{ text = message, timeout = deleted and 4 or 7 })
                            end)
                        end,
                    }
                    UIManager:show(confirm)
                end,
            }
        end
        showUnified = function()
            local items, latest = {}, "尚无本机阅读历史"
            for _, item in ipairs(require("readhistory").hist) do
                if item.file == book.file and type(item.time) == "number" then
                    latest = "最近阅读 · " .. History.format_time({ time = item.time })
                    break
                end
            end
            for _, action in ipairs(record_actions) do
                local row, r = action.row, action.row.record
                local entry = {
                    meta = action.location .. " · " .. metadata(r) .. (percentage(r) and " · " .. percentage(r) or ""),
                    chapter = r.chapter and r.chapter ~= "" and r.chapter or "章节未记录",
                    excerpt = r.excerpt and r.excerpt ~= "" and r.excerpt or r.text or "暂无正文摘要",
                    time = tonumber(r.time) or tonumber(r.observed_at) or 0,
                }
                if entry.time ~= entry.time or math.abs(entry.time) == math.huge then entry.time = 0 end
                entry.callback = function(list)
                    UIManager:close(list)
                    local viewer
                    local buttons = {}
                    if book.file then buttons[#buttons + 1] = { text = "前往此处", callback = function()
                        UIManager:close(viewer)
                        openBook({ file = book.file, book_id = row.book_id or book.id }, r)
                    end } end
                    buttons[#buttons + 1] = { text = "删除此条", callback = function()
                        action.callback()
                    end }
                    buttons[#buttons + 1] = { text = "返回记录", callback = function() UIManager:close(viewer); showUnified() end }
                    viewer = Material.widget("textviewer"):new{
                        title = entry.chapter, text = entry.meta .. "\n\n" .. entry.excerpt
                            .. (r.excerpt and r.excerpt ~= "" and "\n\n同步锚点：" .. (r.text or "") or "")
                            .. (r.note and r.note ~= "" and "\n\n" .. r.note or ""),
                        buttons_table = { buttons },
                        close_callback = function() if Home.instance == page then showUnified() end end,
                    }
                    local native_close = viewer.onCloseWidget
                    function viewer:onCloseWidget()
                        if native_close then native_close(self) end
                        if record_viewer == self then record_viewer = nil end
                    end
                    record_viewer = viewer
                    UIManager:show(viewer)
                end
                items[#items + 1] = entry
            end
            table.sort(items, function(a, b) return a.time > b.time end)
            UIManager:show(Material.recordList{ title = "阅读记录", subtitle = Home.displayTitle(book.title) .. "\n" .. latest,
                items = items, back = function() if Home.instance == page then showLibraryBook(book) end end })
        end
        rows[#rows + 1] = { text = "阅读记录", icon = "appbar.navigation", callback = function()
            UIManager:close(page.book_menu)
            showUnified()
        end }
        if #rows == 0 then rows[1] = { text = "暂无同步记录", dim = true } end
        page.book_menu = Material.widget("menu"):new{
            title = Home.displayTitle(book.title) .. " · 书籍详情",
            item_table = rows, columns = 3, multilines_forced = true, items_max_lines = 3 }
        UIManager:show(page.book_menu)
    end
    local all_books = History.recent(require("readhistory").hist, function(file)
        return require("libs/libkoreader-lfs").attributes(file, "mode") == "file"
    end, math.huge)
    local books = {}
    local history_pages = math.max(1, math.ceil(math.max(0, #all_books - 1) / 3))
    if view == "history" then history_page = math.min(history_page, history_pages) end
    page.history_page, page.history_pages = history_page, history_pages
    if view == "history" then
        for i = 2 + (history_page - 1) * 3, math.min(#all_books, 1 + history_page * 3) do
            books[#books + 1] = all_books[i]
        end
    elseif all_books[1] then books[1] = all_books[1] end
    page.books = books
    local needs_preview = view == "reading" and require("inkbridge_home_preview").needed(books[1])
    local function refresh()
        local Sync = require("inkbridge_home_sync")
        if Sync.running then
            UIManager:show(InfoMessage:new{ text = "正在读取同步历史，请稍候。", timeout = 2 })
            return
        end
        local progress = InfoMessage:new{ text = "正在读取本页书籍的同步历史，不会跳转或修改云端。" }
        UIManager:show(progress)
        Sync.refresh(plugin, books, function(ok, message)
            UIManager:close(progress)
            if Home.instance == page then
                page:leave()
                Home.show(plugin, view, history_page)
            end
            UIManager:show(InfoMessage:new{ text = message, timeout = ok and 5 or 8 })
        end)
    end
    -- 正在阅读只展示一本；历史每页三本，均固定高度，不创建滚动视口。
    local function fillReadingQuarters(quarter)
        local b = books[1]
        local compact = quarter < px(190)
        local section = VerticalGroup:new{ align = "left" }
        section.record_rows = {}
        page.book_sections = { section }
        local title = b and Home.displayTitle(b.title) or "暂无正在阅读的书籍"
        local inset = px(16)
        local border = px(1)
        local inner_width = width - 2 * (inset + border)
        local inner_height = quarter - px(12) - 2 * (inset + border)
        local title_widget = text(title, compact and 22 or 25,
            { bold = true, lines = 1, line_height = 0.18, width = inner_width })
        local book_heading = VerticalGroup:new{ align = "left", gap(4),
            b and recordRow(title_widget, function() openBook(b) end) or title_widget,
        }
        if b then
            book_heading[#book_heading + 1] = spread(
                action("继续阅读  ›", function() openBook(b) end, { size = 13, padding = 4 }),
                action("同步记录 · " .. #b.records, function() showRecords(b) end, { size = 12, padding = 4 }), inner_width)
        else
            book_heading[#book_heading + 1] = text("从书库打开书籍后显示在这里", 12, { muted = true, lines = 1 })
        end
        local function recordCell(index, height)
            local r = b and b.records[index]
            local widget
            if r then
                local chapter = type(r.chapter) == "string" and r.chapter ~= "" and r.chapter
                    or (needs_preview and "正在整理章节与选段…" or "章节未记录")
                local lines = math.max(1, math.min(5, math.floor((height - px(50)) / px(compact and 20 or 22))))
                widget = recordRow(VerticalGroup:new{ align = "left", gap(6),
                    text(chapter, compact and 12 or 13,
                        { bold = true, lines = 1, line_height = 0.1, width = inner_width }),
                    gap(3), text(r.excerpt and r.excerpt ~= "" and r.excerpt or r.text,
                        compact and 15 or 17, { lines = lines, line_height = 0.2, width = inner_width }),
                    gap(3), text(metadata(r) .. (percentage(r) and " · " .. percentage(r) or ""),
                        compact and 10 or 11, { muted = true, lines = 1, line_height = 0.1, width = inner_width }),
                }, function() openBook(b, r) end)
            else
                widget = VerticalGroup:new{ align = "left", gap(10),
                    text("暂无同步记录", compact and 14 or 16, { muted = true, lines = 1, width = inner_width }) }
            end
            local cell = TopContainer:new{ dimen = Geom:new{ w = inner_width, h = height }, widget }
            section.record_rows[index] = cell
            return cell
        end
        local heading_height = book_heading:getSize().h
        local part_two = VerticalGroup:new{ align = "left", book_heading,
            recordCell(1, math.max(px(36), inner_height - heading_height)) }
        local older_height = math.floor((inner_height - px(12)) / 2)
        local part_three = VerticalGroup:new{ align = "left",
            recordCell(2, older_height), gap(12), recordCell(3, older_height) }
        local second = TopContainer:new{ dimen = Geom:new{ w = width, h = quarter },
            Material.card(TopContainer:new{ dimen = Geom:new{ w = inner_width, h = inner_height }, part_two },
                { padding = 16, outline = true }) }
        local third = TopContainer:new{ dimen = Geom:new{ w = width, h = quarter },
            Material.card(TopContainer:new{ dimen = Geom:new{ w = inner_width, h = inner_height }, part_three },
                { padding = 16, outline = true }) }
        section[#section + 1], section[#section + 2] = second, third
        section:resetLayout()
        content[#content + 1] = section
        return second, third
    end

    local function fillColumns(body_height)
        page.book_sections = {}
        local count = view == "history" and math.max(1, #books) or 1
        local section_height = math.floor(body_height / count)
        local compact = H < px(800)
        for index = 1, count do
            local b = books[index]
            local section = VerticalGroup:new{ align = "left" }
            local title = b and b.title or (view == "history" and "暂无其他阅读书籍" or "暂无正在阅读的书籍")
            -- 使用当前路径的文件名，重命名后立即生效；EPUB 内部标题可能仍是旧名。
            local title_widget = text(b and Home.displayTitle(title) or title, compact and 18 or 21,
                { bold = true, lines = 1, line_height = 0.18 })
            section[#section + 1] = gap(4)
            section[#section + 1] = b and recordRow(title_widget, function() openBook(b) end) or title_widget
            if b then
                section[#section + 1] = spread(
                    action("继续阅读  ›", function() openBook(b) end, { size = 13, padding = 2 }),
                    action(view == "history" and "管理书籍" or "同步记录 · " .. #b.records,
                        function() if view == "history" then manageBook(b) else showRecords(b) end end,
                        { size = 12, padding = 2 }))
            else
                section[#section + 1] = text("从书库打开书籍后显示在这里", 12, { muted = true, lines = 1 })
            end
            local row_height = math.floor((section_height - section:getSize().h - px(6)) / 3)
            section.record_rows = {}
            for record_index = 1, 3 do
                local r = b and b.records[record_index]
                local row_content
                if r then
                    local lines = view == "reading" and math.max(1, math.min(6, math.floor((row_height - px(28)) / px(24))))
                        or (row_height >= px(64) and 2 or 1)
                    row_content = VerticalGroup:new{ align = "left",
                        text(r.text, compact and 15 or 17, { lines = lines, line_height = 0.18 }),
                        text(metadata(r) .. (percentage(r) and " · " .. percentage(r) or ""),
                            compact and 10 or 11, { muted = true, lines = 1, line_height = 0.1 }),
                    }
                    row_content = recordRow(row_content, function() openBook(b, r) end)
                else
                    row_content = text("暂无同步记录", compact and 14 or 16,
                        { muted = true, lines = 1, line_height = 0.18 })
                end
                local cell = CenterContainer:new{
                    dimen = Geom:new{ w = content_width, h = row_height }, row_content,
                }
                section.record_rows[record_index] = cell
                section[#section + 1] = cell
            end
            -- 标题高度曾用于分配记录行高，补齐三行后必须丢弃原生布局缓存。
            section:resetLayout()
            local slot = VerticalGroup:new{ align = "left",
                LeftContainer:new{ dimen = Geom:new{ w = content_width, h = section_height - px(1) }, section },
                rule(false),
            }
            page.book_sections[index] = section
            content[#content + 1] = slot
        end
    end

    local function settings()
        page:stopClock()
        local dialog
        dialog = ButtonDialog:new{
            title = "首页设置",
            buttons = {
                {{ text = "文件管理器", callback = function()
                    UIManager:close(dialog)
                    page:leave()
                    local FileManager = require("apps/filemanager/filemanager")
                    if not FileManager.instance then FileManager:showFiles() end
                end }},
                {{ text = (G_reader_settings:readSetting(Home.AUTO) and "✓ " or "") .. "启动／关书后进入首页",
                    short_text = "启动首页", icon = "home", checked_func = function() return G_reader_settings:readSetting(Home.AUTO) end,
                    callback = function()
                        Home.setAuto(not G_reader_settings:readSetting(Home.AUTO))
                        UIManager:close(dialog)
                        page.tick()
                    end }},
                {{ text = "墨桥同步设置", callback = function()
                    UIManager:close(dialog)
                    page:stopClock()
                    Material.showMenu("同步设置", function() return plugin:_advanced_menu() end,
                        function() if Home.instance == page then settings() end end)
                end }},
                {{ text = "说明", callback = function()
                    UIManager:show(InfoMessage:new{ text = "书库默认读取本地文件夹，可在顶部切换 WebDAV；两种目录分别保存。扫描含最多五层子目录，本地浏览无需联网。点击书名直接阅读，点击记录查看书籍详情；云端记录需手动读取，删除只针对选中的单条记录。\n正在阅读页提供最近一本书的快捷入口。\n静读天下仅保留当前进度，未采集的历史无法凭空恢复。点击摘录需全文唯一命中并确认。" })
                end }},
                {{ text = "返回首页", callback = function() UIManager:close(dialog); page.tick() end }},
            },
        }
        -- 用物理返回键关闭对话框时也恢复时钟；重复调度先取消旧定时器。
        local original_close = dialog.onCloseWidget
        function dialog:onCloseWidget()
            if original_close then original_close(self) end
            if Home.instance == page then page.tick() end
        end
        UIManager:show(dialog)
    end
    local function switchView(target, number)
        if view == target and (target ~= "history" or number == history_page) then return true end
        page:leave()
        Home.show(plugin, target, number)
        return true
    end
    local nav_buttons = HorizontalGroup:new{ align = "top" }
    local nav_gap = px(8)
    local nav_width = math.floor((width - 2 * nav_gap) / 3)
    for i, item in ipairs({ { "正在阅读", function() switchView("reading") end },
            { "书库", openLibrary }, { "设置", settings } }) do
        local selected = i == (view == "library" and 2 or 1)
        local item_width = i == 3 and width - 2 * nav_width - 2 * nav_gap or nav_width
        nav_buttons[#nav_buttons + 1] = Material.button{ text = item[1], callback = item[2],
            icon = ({ "book.opened", "appbar.filebrowser", "appbar.settings" })[i],
            width = item_width, height = navigation_button_height, selected = selected, stacked = true,
            size = 13, show_parent = page }
        if i < 3 then nav_buttons[#nav_buttons + 1] = HorizontalSpan:new{ width = px(8) } end
    end
    local nav_base = CenterContainer:new{ dimen = Geom:new{ w = width, h = navigation_height }, nav_buttons }
    local nav = VerticalGroup:new{ align = "left", nav_base }
    page.navigation = nav_base
    page.layout_metrics = { padding = pad, width = width, navigation_height = navigation_height,
        navigation_y = H - pad - navigation_height, button_height = button_height,
        navigation_button_height = navigation_button_height }
    local library_pager
    if view == "library" then
        library_pager = text("1 / 1", 13, { width = math.floor(width / 3), lines = 1, align = "center" })
        local function turnPage(delta)
            local number = math.max(1, math.min(page.library_pages or 1, history_page + delta))
            if number == history_page then return end
            page:leave()
            Home.show(plugin, "library", number, library_data)
        end
        table.insert(nav, 1, HorizontalGroup:new{ align = "center",
            action("上一页", function() turnPage(-1) end,
                { width = math.floor(width / 3), align = "center", size = 13, padding = 4 }),
            library_pager,
            action("下一页", function() turnPage(1) end,
                { width = math.floor(width / 3), align = "center", size = 13, padding = 4 }),
        })
    elseif view == "history" then
        local pager = HorizontalGroup:new{ align = "center",
            action("上一页", function() switchView("history", math.max(1, history_page - 1)) end,
                { width = math.floor(width / 3), align = "center", size = 13, padding = 4 }),
            text(history_page .. " / " .. history_pages, 13, { width = math.floor(width / 3), lines = 1, align = "center" }),
            action("下一页", function() switchView("history", math.min(history_pages, history_page + 1)) end,
                { width = math.floor(width / 3), align = "center", size = 13, padding = 4 }),
        }
        table.insert(nav, 1, pager)
    end
    if view == "library" then
        local data = library_data
        data.root = data.root or (data.source == "local" and Library.localRoot(plugin)
            or data.source == "webdav" and (Library.target(plugin) or {}).url)
        if not data.root then data.loading = false end
        library_entries, data.directory = Library.entries(data.books, data.folders, data.root, data.directory, library_options)
        if library_options.mode == "folders" then
            local parent = Library.parentFolder(data.directory, data.root)
            if parent ~= data.directory then
                table.insert(library_entries, 1, { is_folder = true, is_parent = true, path = parent, title = "返回上级目录" })
            end
        end
        local half = math.floor(width / 2)
        local third = math.floor(width / 3)
        local source_bar = HorizontalGroup:new{ align = "center" }
        for _, source in ipairs({ { "local", "本地" }, { "webdav", "WebDAV" } }) do
            source_bar[#source_bar + 1] = action(source[2], function()
                    if data.source ~= source[1] then openLibrary(source[1]) end
                end, { width = (source[1] == "local" and half or width - half) - px(4), icon = source[1] == "local" and "appbar.filebrowser" or "wifi",
                    selected = data.source == source[1], height = 44 })
            if source[1] == "local" then source_bar[#source_bar + 1] = HorizontalSpan:new{ width = px(8) } end
        end
        local views = HorizontalGroup:new{ align = "center" }
        for _, mode in ipairs({ { "folders", "文件夹" }, { "all", "全部书籍" } }) do
            views[#views + 1] = action(mode[2], function()
                if library_options.mode == mode[1] then return end
                Library.setViewOption("mode", mode[1])
                data.directory = nil
                rebuildLibrary()
            end, { width = third, align = "center", size = 13,
                icon = mode[1] == "folders" and "appbar.filebrowser" or "book.opened",
                selected = library_options.mode == mode[1], padding = 8 })
        end
        views[#views + 1] = action("列表调整", adjustLibraryList,
            { width = width - 2 * third, align = "center", size = 13, icon = "appbar.pageview", padding = 8 })
        header = VerticalGroup:new{ align = "left",
            spread(text("书库", 28, { bold = true, lines = 1, width = width - px(56) }),
                Material.button{ text = "", icon = "appbar.menu", width = px(48), height = px(48), show_parent = page,
                    callback = function() Material.showMenu("书库选项", {
                        { text = "选择目录", icon = "appbar.filebrowser", callback = chooseLibraryFolder },
                        { text = "列表调整", icon = "appbar.pageview", callback = adjustLibraryList },
                        { text = "刷新书目", icon = "cre.render.reload", callback = function() openLibrary(data.source) end },
                    }) end }), gap(12), source_bar, gap(4), views, gap(4),
            text(data.root and ("/" .. data.directory) or
                (data.source == "local" and "请选择本地书籍文件夹" or "请选择 WebDAV 书籍目录"),
                12, { muted = true, lines = 1 }),
            text(data.loading and "正在扫描书目…" or (string.format("%d 本书", #data.books)
                .. (library_options.mode == "folders" and (" · 本层 " .. (#library_entries
                    - (library_entries[1] and library_entries[1].is_parent and 1 or 0)) .. " 项") or "")
                .. (data.skipped > 0 and (" · " .. data.skipped .. " 项未读取") or "")),
                12, { muted = true, lines = 1 }), gap(12),
        }
    else
    header = VerticalGroup:new{ align = "left",
        spread(text(view == "library" and "墨桥 · 书库" or "墨桥 · 正在阅读", 18,
                { bold = true, width = math.floor(width / 2) }),
            action("刷新记录", refresh, { size = 13, padding = 2 }), width),
        gap(8),
        HorizontalGroup:new{ align = "center",
            LeftContainer:new{ dimen = Geom:new{ w = width - date_width, h = clock:getSize().h }, clock },
            VerticalGroup:new{ align = "left", date_line, gap(5), weekday } },
        gap(8), rule(true, width),
    }
    end
    local body_height = H - 2 * pad - header:getSize().h - nav:getSize().h
    if view == "reading" then
        local available = H - 2 * pad
        local quarter = math.floor((available - navigation_height) / 3)
        local header_height = available - navigation_height - 2 * quarter
        local heading = spread(text("墨桥", 28,
            { bold = true, width = math.floor(width / 2) }), action("刷新记录", refresh,
                { size = 13, icon = "cre.render.reload", padding = 2 }), width)
        local heading_height = heading:getSize().h
        header = TopContainer:new{ dimen = Geom:new{ w = width, h = header_height },
            VerticalGroup:new{ align = "left", heading,
            CenterContainer:new{ dimen = Geom:new{ w = width, h = header_height - heading_height },
                HorizontalGroup:new{ align = "center",
                    LeftContainer:new{ dimen = Geom:new{ w = width - date_width, h = clock:getSize().h }, clock },
                    VerticalGroup:new{ align = "left", date_line, gap(5), weekday, gap(5), lunar_date } } },
        } }
        local second, third = fillReadingQuarters(quarter)
        page.home_regions = { header, second, third, nav }
        page.home_region_height = quarter
    elseif view == "library" then
        local data = library_data
        local row_size = library_options.density == "compact" and 60 or library_options.density == "large" and 104 or 76
        local count = math.max(1, math.floor(body_height / px(row_size)))
        local pages = math.max(1, math.ceil(#library_entries / count))
        history_page = math.min(history_page, pages)
        page.library_page, page.library_pages = history_page, pages
        library_pager:setText(history_page .. " / " .. pages)
        page.library_rows = {}
        local row_height = math.floor(body_height / count)
        for i = 1, count do
            local entry = library_entries[(history_page - 1) * count + i]
            local book = entry and entry.book
            local row = VerticalGroup:new{ align = "left" }
            if entry and entry.is_folder then
                local function enterFolder()
                    data.directory = entry.path
                    rebuildLibrary()
                end
                row[#row + 1] = recordRow(LeftContainer:new{
                    dimen = Geom:new{ w = width, h = row_height - px(8) },
                    HorizontalGroup:new{ align = "center",
                        Material.icon(entry.is_parent and "chevron.up" or "appbar.filebrowser", 26),
                        HorizontalSpan:new{ width = px(12) },
                        VerticalGroup:new{ align = "left",
                            text(entry.title, library_options.density == "compact" and 15 or 17,
                                { bold = true, lines = 1, width = width - px(84) }), gap(5),
                            text(entry.is_parent and "返回上级" or "文件夹", 11,
                                { muted = true, lines = 1, width = width - px(84) }) },
                        Material.icon("chevron.right", 20) } }, enterFolder)
                page.library_rows[#page.library_rows + 1] = entry
            elseif book then
                local state = string.format("本机记录 %d", #book.local_records)
                    .. ((data.source == "webdav" or book.cloud_loaded) and (" · 云端记录 " .. #book.cloud_records)
                        or " · 云端未读取")
                local text_width = width - px(100)
                local book_text = VerticalGroup:new{ align = "left",
                    text(Home.displayTitle(book.title), library_options.density == "compact" and 15 or 17,
                        { bold = true, lines = 1, line_height = 0.15, width = text_width }), gap(5),
                    text(state, 11, { muted = true, lines = 1, width = text_width }) }
                local body = HorizontalGroup:new{ align = "center", Material.icon("book.opened", 26),
                    HorizontalSpan:new{ width = px(12) }, book_text }
                local open = recordRow(LeftContainer:new{
                    dimen = Geom:new{ w = width - px(48), h = row_height - px(8) }, body }, function()
                        if book.file then openBook(book) else showLibraryBook(book) end
                    end)
                local overflow = Material.button{ text = "⋮", width = px(48), height = px(48), size = 26,
                    show_parent = page, callback = function() showLibraryBook(book) end }
                overflow.book_file, overflow.accessibility_label = book.file, "书籍操作"
                row[#row + 1] = HorizontalGroup:new{ align = "center", open, overflow }
                page.book_overflow = page.book_overflow or {}
                page.book_overflow[#page.book_overflow + 1] = overflow
                page.library_rows[#page.library_rows + 1] = book
            elseif i == (library_entries[1] and library_entries[1].is_parent and 2 or 1) then
                row[#row + 1] = gap(12)
                row[#row + 1] = text(data.error or (data.loading and "正在读取目录，请稍候。"
                    or not data.root and "点击「选择目录」设置书籍文件夹。"
                    or "此文件夹中暂无可阅读的书籍。"), 15, { lines = 3, muted = true })
            end
            content[#content + 1] = VerticalGroup:new{ align = "left",
                LeftContainer:new{ dimen = Geom:new{ w = width, h = math.max(0, row_height - px(1)) }, row },
                gap(1),
            }
        end
    else fillColumns(body_height) end
    page.content = content
    page[1] = FrameContainer:new{ padding = pad, margin = 0, bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{ align = "left",
            TopContainer:new{ dimen = Geom:new{ w = width, h = H - 2 * pad - nav:getSize().h },
                VerticalGroup:new{ align = "left", header, content } }, nav },
    }
    UIManager:show(page)
    UIManager:setDirty(page, "ui")
    if view ~= "library" then page.tick() end
    if view == "library" and library_data.loading then
        local data = library_data
        local function complete(ok, result, skipped, remote_books, remote_folders)
            if Home.instance ~= page then return end
            data.loading, data.skipped = false, skipped or 0
            if not ok then data.error = result
            elseif data.source == "local" then
                data.books = Library.localCatalog(result, History.load().books, nil, require("inkbridge_state").book_id)
                data.folders = remote_books
            else
                local merged = Library.catalog(require("readhistory").hist, History.load().books, result,
                    function(file) return require("libs/libkoreader-lfs").attributes(file, "mode") == "file" end,
                    require("inkbridge_state").book_id, remote_books)
                data.books = {}
                for _, book in ipairs(merged) do
                    if book.remote then data.books[#data.books + 1] = book end
                end
                data.sync_plugin = Library.client(plugin, plugin.server)
                data.folders = remote_folders
            end
            page:leave()
            Home.show(plugin, "library", 1, data)
        end
        if data.source == "local" then
            page.cancel_scan = Library.scanLocal(data.root, complete)
        else
            UIManager:nextTick(function()
                if Home.instance ~= page then return end
                local client = Library.client(plugin, Library.target(plugin))
                client.sync_server = plugin.server
                Library.scan(client, complete)
            end)
        end
    end
    if needs_preview then
        page.preview_running = true
        page.cancel_preview = require("inkbridge_home_preview").start(books[1], function(ok, previews, stamp)
            if Home.instance ~= page then return end
            page.preview_running = false
            if ok then
                local saved, changed = pcall(History.storePreviews, books[1].file, books[1].book_id,
                    books[1].records, previews, stamp)
                if saved and changed then page:leave(); Home.show(plugin) end
            else page.preview_error = previews end
        end)
    end
end

return Home
