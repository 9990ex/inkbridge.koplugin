-- 书刊式首页：一主两次的阅读摘录，完整同步记录按需展开。
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
    -- 书库仍是原生文件管理器，但左上角房子／Home 键应能回到墨桥首页。
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

function Home.show(plugin)
    local UIManager = require("ui/uimanager")
    if plugin.ui and plugin.ui.document then
        Home.pending = true
        plugin.ui:onHome()
        return
    end
    if Home.instance then return end
    local InputContainer = require("ui/widget/container/inputcontainer")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local LeftContainer = require("ui/widget/container/leftcontainer")
    local LineWidget = require("ui/widget/linewidget")
    local TextWidget = require("ui/widget/textwidget")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local Button = require("ui/widget/button")
    local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
    local GestureRange = require("ui/gesturerange")
    local Geom = require("ui/geometry")
    local Font = require("ui/font")
    local Device = require("device")
    local Screen = Device.screen
    local History = require("inkbridge_home_history")
    local InfoMessage = require("ui/widget/infomessage")
    local Blitbuffer = require("ffi/blitbuffer")
    local W, H = Screen:getWidth(), Screen:getHeight()
    local function px(n) return Screen:scaleBySize(n) end
    local pad = px(26)
    local width = W - 2 * pad
    local scrollbar_width = math.max(1, px(3))
    local content_width = width - ScrollableContainer:getScrollbarWidth(scrollbar_width)
    local Page = InputContainer:extend{ name = "inkbridge_home", covers_fullscreen = true }
    local page = Page:new{ dimen = Geom:new{ w = W, h = H } }
    Home.instance = page

    function page:stopClock()
        if self.tick then UIManager:unschedule(self.tick) end
    end
    function page:onCloseWidget()
        self:stopClock()
        if Home.instance == self then Home.instance = nil end
    end
    function page:leave()
        UIManager:close(self, "ui")
    end
    function page:onHomeBack() self:leave(); return true end
    function page:onSuspend() self:stopClock() end
    function page:onResume() if self.tick then self.tick() end end
    function page:onShowingReader() self:leave() end
    function page:onSetDimensions()
        self:leave()
        UIManager:nextTick(function() Home.show(plugin) end)
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
            background = heavy and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
        }
    end
    local function text(value, size, opts)
        opts = opts or {}
        local face = Font:getFace(opts.serif and "NotoSerif-Regular.ttf" or "cfont", size or 17)
        local line_height = opts.line_height or 0.3
        return TextBoxWidget:new{
            text = value, width = opts.width or content_width, face = face,
            bold = opts.bold, fgcolor = opts.muted and muted or Blitbuffer.COLOR_BLACK,
            line_height = line_height,
            height = opts.lines and math.floor(face.size * (1 + line_height) + 0.5) * opts.lines or nil,
            height_adjust = opts.lines ~= nil, height_overflow_show_ellipsis = opts.lines ~= nil,
        }
    end
    local function action(label, callback, opts)
        opts = opts or {}
        return Button:new{
            text = label, callback = callback, width = opts.width,
            text_font_size = opts.size or 16, text_font_bold = opts.bold or false,
            align = opts.align or "left", bordersize = 0, margin = 0,
            padding_h = 0, padding_v = px(opts.padding or 8),
            avoid_text_truncation = false,
        }
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
    local clock = TextWidget:new{ text = os.date("%H:%M"),
        face = Font:getFace("NotoSerif-Regular.ttf", W < H and 86 or 62),
        max_width = width - date_width, padding = 0 }
    local header
    page.tick = function()
        page:stopClock()
        clock:setText(os.date("%H:%M"))
        date_line:setText(os.date("%Y / %m / %d"))
        weekday:setText(weekdays[tonumber(os.date("%w")) + 1])
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
                .. (percentage(r) and " · " .. percentage(r) or "") .. "\n" .. r.text
                .. (r.note and r.note ~= "" and "\n" .. r.note or "")
            targets[#targets + 1] = { text = "打开记录 " .. i, callback = function()
                UIManager:close(viewer)
                openBook(book, r)
            end }
        end
        viewer = require("ui/widget/textviewer"):new{
            title = "同步记录", text = table.concat(paragraphs, "\n\n"),
            buttons_table = { targets, {{ text = "返回首页", callback = function() UIManager:close(viewer) end }} },
        }
        local native_close = viewer.onCloseWidget
        function viewer:onCloseWidget()
            if native_close then native_close(self) end
            if Home.instance == page then page.tick() end
        end
        page:stopClock()
        UIManager:show(viewer)
    end
    local books = History.recent(require("readhistory").hist, function(file)
        return require("libs/libkoreader-lfs").attributes(file, "mode") == "file"
    end)
    local function refresh()
        local Sync = require("inkbridge_home_sync")
        if Sync.running then
            UIManager:show(InfoMessage:new{ text = "正在读取同步历史，请稍候。", timeout = 2 })
            return
        end
        local progress = InfoMessage:new{ text = "正在读取最近三本的同步历史，不会跳转或修改云端。" }
        UIManager:show(progress)
        Sync.refresh(plugin, books, function(ok, message)
            UIManager:close(progress)
            if Home.instance == page then
                page:leave()
                Home.show(plugin)
            end
            UIManager:show(InfoMessage:new{ text = message, timeout = ok and 5 or 8 })
        end)
    end
    content[#content + 1] = gap(15)
    content[#content + 1] = spread(
        text("正在读", 15, { bold = true, width = math.floor(width * 0.45) }),
        action("刷新记录", refresh, { size = 14, padding = 6 }))
    content[#content + 1] = gap(12)
    for index, book in ipairs(books) do
        local b = book
        local featured = index == 1
        local title, authors = b.title, nil
        local info = plugin.ui and plugin.ui.bookinfo
        if info and type(info.getDocProps) == "function" then
            -- 只读 KOReader 已有元数据，不为首页打开或排版文档。
            local ok, props = pcall(info.getDocProps, info, b.file, nil, true)
            if ok and type(props) == "table" then
                if type(props.display_title) == "string" and props.display_title ~= "" then title = props.display_title end
                if type(props.authors) == "string" and props.authors ~= "" then authors = props.authors:gsub("\n", " / ") end
            end
        end
        title = Home.displayTitle(title)
        if index == 2 then
            content[#content + 1] = gap(8)
            content[#content + 1] = text("也在读", 14, { muted = true })
            content[#content + 1] = gap(14)
        end
        content[#content + 1] = recordRow(
            text(title, featured and 30 or 22, { bold = true, lines = featured and 2 or 1, line_height = 0.18 }),
            function() openBook(b) end)
        if authors then
            content[#content + 1] = gap(5)
            content[#content + 1] = text(authors, 14, { muted = true, lines = 1 })
        end
        content[#content + 1] = gap(featured and 14 or 7)
        local r = b.records[1]
        if r then
            content[#content + 1] = recordRow(text(r.text, featured and 23 or 18,
                { lines = featured and 3 or 2, line_height = 0.4 }), function() openBook(b, r) end)
            content[#content + 1] = gap(featured and 12 or 6)
            local meta = metadata(r) .. (percentage(r) and " · " .. percentage(r) or "")
            content[#content + 1] = text(meta, 14, { muted = true, lines = 1 })
            if r.note and r.note ~= "" then
                content[#content + 1] = text(r.note, 14, { muted = true, lines = 1 })
            end
        else
            content[#content + 1] = text("还没有同步摘录，继续阅读或刷新记录后会出现在这里。", 15,
                { muted = true, lines = 2 })
        end
        if featured then
            content[#content + 1] = gap(10)
            content[#content + 1] = spread(action("继续阅读  ›", function() openBook(b) end, { bold = true, size = 18 }),
                #b.records > 0 and action("同步记录 · " .. #b.records, function() showRecords(b) end, { size = 14 })
                    or HorizontalSpan:new{ width = 0 })
        elseif #b.records > 0 then
            content[#content + 1] = action("同步记录 · " .. #b.records, function() showRecords(b) end,
                { size = 13, padding = 4 })
        end
        content[#content + 1] = gap(featured and 17 or 12)
        content[#content + 1] = rule(false)
        content[#content + 1] = gap(featured and 10 or 16)
    end
    if #books == 0 then
        content[#content + 1] = gap(28)
        content[#content + 1] = text("从一本书开始", 30, { bold = true })
        content[#content + 1] = gap(16)
        content[#content + 1] = text("在书库打开一本书。下一次回来，这里会留下你的阅读片段。", 19,
            { muted = true })
        content[#content + 1] = gap(22)
        content[#content + 1] = action("打开书库  ›", function() page:leave() end, { bold = true, size = 18 })
    end

    local function settings()
        page:stopClock()
        local dialog
        dialog = require("ui/widget/buttondialog"):new{
            title = "首页设置",
            buttons = {
                {{ text = (G_reader_settings:readSetting(Home.AUTO) and "✓ " or "") .. "启动／关书后进入首页",
                    callback = function()
                        Home.setAuto(not G_reader_settings:readSetting(Home.AUTO))
                        UIManager:close(dialog)
                        page.tick()
                    end }},
                {{ text = "墨桥同步设置", callback = function()
                    UIManager:close(dialog)
                    page:leave()
                    -- 原生 TouchMenu 才支持动态子菜单与 checked_func，不能用普通列表菜单冒充。
                    local tab = plugin:_advanced_menu()
                    tab.icon = "appbar.settings"
                    UIManager:show(require("ui/widget/touchmenu"):new{
                        width = W, tab_item_table = { tab },
                    })
                end }},
                {{ text = "说明", callback = function()
                    UIManager:show(InfoMessage:new{ text = "首页展示最近三本书，每本默认一段最新同步摘录；完整三条记录在「同步记录」中查看。不会后台联网。\n重复来源与正文合并，时间缺失时标为读取时间。\n静读天下仅保留当前进度，安装前未采集的历史无法凭空恢复。\n点击书名或「继续阅读」打开本机位置；点击摘录需全文唯一命中并确认，不按百分比猜跳。\n如使用 SimpleUI／ZenOS，请勿同时开启两个首页。" })
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
    local function goTop()
        local viewport = page.cropping_widget
        -- 原生容器在内容不足一屏时不创建 _crop_h；未绘制时也尚未初始化。
        -- 这两种情况已经在顶部，无需调用要求裁剪尺寸的 scrollToRatio。
        if viewport and viewport._is_scrollable == true
                and type(viewport._crop_h) == "number" and viewport._crop_h > 0 then
            viewport:scrollToRatio(nil, 0)
        end
    end
    local nav_buttons = HorizontalGroup:new{ align = "top" }
    local nav_width = math.floor(width / 3)
    for i, item in ipairs({ { "首页", goTop }, { "书库", function() page:leave() end }, { "设置", settings } }) do
        local item_width = i == 3 and width - 2 * nav_width or nav_width
        nav_buttons[#nav_buttons + 1] = VerticalGroup:new{ align = "center",
            action(item[1], item[2], { width = item_width, align = "center", size = 17, bold = i == 1, padding = 12 }),
            CenterContainer:new{ dimen = Geom:new{ w = item_width, h = px(3) },
                i == 1 and rule(true, px(22)) or HorizontalSpan:new{ width = 0 } },
        }
    end
    local nav = VerticalGroup:new{ align = "left", rule(false, width), gap(4), nav_buttons }
    header = VerticalGroup:new{ align = "left",
        spread(text("墨桥", 18, { bold = true, width = math.floor(width / 2) }),
            TextWidget:new{ text = "阅读扉页", face = Font:getFace("cfont", 13), fgcolor = muted }, width),
        gap(14),
        HorizontalGroup:new{ align = "center",
            LeftContainer:new{ dimen = Geom:new{ w = width - date_width, h = clock:getSize().h }, clock },
            VerticalGroup:new{ align = "left", date_line, gap(5), weekday } },
        gap(14), rule(true, width),
    }
    local viewport = ScrollableContainer:new{
        dimen = Geom:new{ w = width, h = math.max(80, H - 2 * pad - header:getSize().h - nav:getSize().h) },
        scroll_bar_width = scrollbar_width,
        content,
    }
    page.cropping_widget = viewport
    page[1] = FrameContainer:new{ padding = pad, margin = 0, bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{ align = "left", header, viewport, nav },
    }
    UIManager:show(page)
    UIManager:setDirty(page, "ui")
    page.tick()
end

return Home
