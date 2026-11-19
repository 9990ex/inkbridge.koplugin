-- 轻量首页：原生控件、最多九条正文预览，离开页面后没有时钟定时器。
-- 不复制 SimpleUI/ZenOS 的全局补丁，不接管阅读器排版或同步算法。
local Home = { AUTO = "inkbridge_home_auto", PREVIOUS = "inkbridge_home_previous_start" }

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
    local TextWidget = require("ui/widget/textwidget")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local Button = require("ui/widget/button")
    local ButtonTable = require("ui/widget/buttontable")
    local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
    local GestureRange = require("ui/gesturerange")
    local Geom = require("ui/geometry")
    local Font = require("ui/font")
    local Device = require("device")
    local Screen = Device.screen
    local History = require("inkbridge_home_history")
    local InfoMessage = require("ui/widget/infomessage")
    local W, H = Screen:getWidth(), Screen:getHeight()
    local pad = Screen:scaleBySize(12)
    local width = W - 2 * pad
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

    local clock = TextWidget:new{ text = os.date("%H:%M  ·  %m月%d日"),
        face = Font:getFace("cfont", 28), width = width }
    page.tick = function()
        page:stopClock()
        clock:setText(os.date("%H:%M  ·  %m月%d日"))
        UIManager:setDirty(page, "ui", clock.dimen)
        UIManager:scheduleIn(60 - tonumber(os.date("%S")), page.tick)
    end

    local content = VerticalGroup:new{ align = "left" }
    local function text(value, size)
        return TextBoxWidget:new{ text = value, width = width - 2 * pad,
            face = Font:getFace("cfont", size or 17) }
    end
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
    local books = History.recent(require("readhistory").hist, function(file)
        return require("libs/libkoreader-lfs").attributes(file, "mode") == "file"
    end)
    content[#content + 1] = Button:new{
        text = "读取同步历史（只读）", width = width, text_font_size = 17,
        callback = function()
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
        end,
    }
    content[#content + 1] = text("最近三本 · 每本最近三条同步正文\n上下滑动查看；点正文核对并跳转。", 16)
    content[#content + 1] = VerticalSpan:new{ width = pad }
    for _, book in ipairs(books) do
        local b = book
        content[#content + 1] = Button:new{
            text = b.title .. "  ›", width = width, text_font_size = 19,
            callback = function() openBook(b) end,
        }
        for i, record in ipairs(b.records) do
            local r = record
            local stamp = os.date("%m-%d %H:%M", r.time or r.observed_at)
            local meta = tostring(i) .. "  " .. r.source .. " · " .. stamp
                .. (r.time and "" or " 读取")
            if r.percent then meta = meta .. string.format(" · %.2f%%", r.percent * 100) end
            local body = VerticalGroup:new{ align = "left",
                text(meta, 14), text(r.text, 18),
            }
            if r.note and r.note ~= "" then body[#body + 1] = text(r.note, 14) end
            local frame = FrameContainer:new{ padding = pad, margin = 0, bordersize = 0, body }
            local row = Row:new{ frame, callback = function() openBook(b, r) end }
            row.ges_events = { HomeRecord = { GestureRange:new{ ges = "tap", range = function() return frame.dimen end } } }
            content[#content + 1] = row
        end
        if #b.records == 0 then
            content[#content + 1] = text("暂无缓存。点上方「读取同步历史」补全已有云端记录。", 16)
        end
        content[#content + 1] = VerticalSpan:new{ width = pad }
    end
    if #books == 0 then content[#content + 1] = text("尚无本机阅读历史，请先从书库打开一本书。") end

    local function settings()
        page:stopClock()
        local dialog
        dialog = require("ui/widget/buttondialog"):new{
            title = "首页设置 · 试用版",
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
                    UIManager:show(InfoMessage:new{ text = "仅展示本机实际读取或成功上传的同步正文；不会后台联网。\n每本最多三条，重复来源与正文合并。时间缺失时标为读取时间。\n静读天下仅保留当前进度，安装前未采集的三次历史无法凭空恢复。\n点正文需全文唯一命中并确认，不按百分比猜跳。\n如使用 SimpleUI／ZenOS，请勿同时开启两个首页。" })
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
    local nav = ButtonTable:new{ width = width, buttons = {{
        { text = "首页", callback = function()
            local viewport = page.cropping_widget
            -- 原生容器在内容不足一屏时不创建 _crop_h；未绘制时也尚未初始化。
            -- 这两种情况已经在顶部，无需调用要求裁剪尺寸的 scrollToRatio。
            if viewport and viewport._is_scrollable == true
                    and type(viewport._crop_h) == "number" and viewport._crop_h > 0 then
                viewport:scrollToRatio(nil, 0)
            end
        end },
        { text = "书库", callback = function() page:leave() end },
        { text = "设置", callback = settings },
    }} }
    local header = VerticalGroup:new{ align = "left", clock, VerticalSpan:new{ width = pad } }
    local viewport = ScrollableContainer:new{
        dimen = Geom:new{ w = width, h = math.max(80, H - 2 * pad - header:getSize().h - nav:getSize().h) },
        content,
    }
    page.cropping_widget = viewport
    page[1] = FrameContainer:new{ padding = pad, margin = 0, bordersize = 0,
        background = require("ffi/blitbuffer").COLOR_WHITE,
        VerticalGroup:new{ align = "left", header, viewport, nav },
    }
    UIManager:show(page)
    UIManager:setDirty(page, "ui")
    page.tick()
end

return Home
