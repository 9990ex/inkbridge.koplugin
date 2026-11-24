-- 插件专用 Material 视觉层；不修改 KOReader 的全局样式或控件原型。
local M = { name = "Material Ink", version = 1, button_height = 48, navigation_height = 96, navigation_button_height = 88 }
local function px(n) return require("device").screen:scaleBySize(n) end
local function colors()
    local B = require("ffi/blitbuffer")
    return B.COLOR_WHITE, B.COLOR_BLACK, B.COLOR_DARK_GRAY, B.gray and B.gray(0.06) or B.COLOR_LIGHT_GRAY
end
function M.iconFor(text)
    text = tostring(text or "")
    for _, pair in ipairs({
        { "删除", "cancel" }, { "改名", "edit" }, { "名称", "edit" }, { "编辑", "edit" },
        { "保留", "bookmark" }, { "存留", "bookmark" }, { "历史", "appbar.navigation" },
        { "记录", "appbar.navigation" }, { "上传", "move.up" }, { "下载", "move.down" },
        { "读取", "move.down" }, { "刷新", "cre.render.reload" }, { "目录", "appbar.filebrowser" },
        { "文件夹", "appbar.filebrowser" }, { "文件管理", "appbar.filebrowser" },
        { "WebDAV", "wifi" }, { "云端", "wifi" }, { "同步", "cre.render.reload" },
        { "阅读", "book.opened" }, { "书籍", "book.opened" }, { "书库", "appbar.filebrowser" },
        { "设置", "appbar.settings" }, { "选项", "appbar.settings" }, { "设备", "appbar.tools" },
        { "重构", "appbar.tools" }, { "返回", "chevron.left" }, { "取消", "close" },
        { "关闭", "close" }, { "上一", "chevron.left" }, { "下一", "chevron.right" },
        { "说明", "info" }, { "关于", "info" }, { "版本", "info" }, { "开启", "check" },
        { "标准", "align.left" }, { "紧凑", "align.justify" }, { "宽松", "appbar.pageview" },
    }) do if text:find(pair[1], 1, true) then return pair[2] end end
    return "appbar.settings"
end
function M.icon(name, size)
    return require("ui/widget/iconwidget"):new{ icon = name, width = px(size or 24), height = px(size or 24), alpha = true }
end
function M.card(widget, opts)
    opts = opts or {}
    local white, black, _, surface = colors()
    return require("ui/widget/container/framecontainer"):new{
        padding = px(opts.padding or 16), margin = 0, bordersize = opts.outline and px(1) or 0,
        radius = px(opts.radius or 20), color = require("ffi/blitbuffer").gray and require("ffi/blitbuffer").gray(0.30) or black,
        background = opts.tonal and surface or white, widget,
    }
end
function M.quietButton(button)
    -- 仅关闭本插件按钮的按压反色；回调、禁用、长按和按键逻辑仍由原生Button处理。
    button._doFeedbackHighlight = function() end
    button._undoFeedbackHighlight = function() end
    button.material_quiet = true
    return button
end
function M.button(opts)
    local Button = require("ui/widget/button")
    local white, black, _, surface = colors()
    local label = opts.text or ""
    local Font = require("ui/font")
    local Text = require("ui/widget/textwidget")
    local VG = require("ui/widget/verticalgroup")
    local HG = require("ui/widget/horizontalgroup")
    local Span = require("ui/widget/horizontalspan")
    local VSpan = require("ui/widget/verticalspan")
    local stacked = opts.stacked
    local icon = opts.icon
    local icon_size = opts.icon_size or (stacked and 24 or 20)
    local label_widget = Text:new{ text = label, face = Font:getFace("cfont", opts.size or 14),
        bold = opts.selected or opts.bold or false,
        fgcolor = opts.enabled == false and require("ffi/blitbuffer").COLOR_DARK_GRAY or black,
        max_width = opts.width and opts.width - px(stacked and 12 or (icon and 48 or 20)) or nil }
    local child = label_widget
    if icon then
        if stacked then
            child = VG:new{ align = "center", M.icon(icon, icon_size), VSpan:new{ width = px(6) }, label_widget }
        else child = HG:new{ align = "center", M.icon(icon, icon_size), Span:new{ width = px(8) }, label_widget } end
    end
    local width = opts.width or child:getSize().w + px(24)
    local height = opts.height or px(stacked and M.navigation_button_height or M.button_height)
    local button = Button:new{ text = label, width = width, height = height,
        padding = 0, padding_h = 0, padding_v = 0, margin = 0,
        bordersize = 0, radius = px(stacked and 18 or 22),
        background = not stacked and opts.selected and surface or white,
        enabled = opts.enabled ~= false, callback = opts.callback, hold_callback = opts.hold_callback,
        show_parent = opts.show_parent, text_font_size = opts.size or 14, text_font_bold = opts.selected or opts.bold or false,
        avoid_text_truncation = false }
    button.material_icon = icon
    button.material_selected = opts.selected or false
    if button.label_container then
        -- Button 的按压反馈会直接访问 label_widget.fgcolor，必须保留原生文本节点。
        if label_widget.free then label_widget:free() end
        if stacked then
            if button.label_widget.free then button.label_widget:free() end
            button.label_widget = require("ui/widget/textboxwidget"):new{
                text = label, width = width - px(12), height = px(34), height_adjust = true,
                height_overflow_show_ellipsis = true, alignment = "center", line_height = 0.15,
                face = Font:getFace("cfont", opts.size or 14), bold = opts.selected or opts.bold or false,
                fgcolor = opts.enabled == false and require("ffi/blitbuffer").COLOR_DARK_GRAY or black,
                bgcolor = white }
        end
        if icon then child[3] = button.label_widget else child = button.label_widget end
        if icon and stacked then
            local diameter = math.min(px(40), width - px(16))
            local B = require("ffi/blitbuffer")
            local circle = require("ui/widget/container/framecontainer"):new{
                padding = 0, margin = 0, bordersize = 0, radius = math.floor(diameter / 2),
                background = opts.selected and (B.gray and B.gray(0.16) or surface) or surface,
                require("ui/widget/container/centercontainer"):new{
                    dimen = require("ui/geometry"):new{ w = diameter, h = diameter }, child[1] } }
            child[1] = circle
            button.material_circle = circle
            button.material_circle_size = diameter
        end
        button.label_container[1] = child
    end
    return M.quietButton(button)
end

-- 自有图标菜单：固定大小、显式分页和按键焦点，不借用原生 Menu 的长栏目。
function M.sheet(opts)
    local Device = require("device")
    local Screen, UI = Device.screen, require("ui/uimanager")
    local Focus = require("ui/widget/focusmanager")
    local VG, HG = require("ui/widget/verticalgroup"), require("ui/widget/horizontalgroup")
    local VS, HS = require("ui/widget/verticalspan"), require("ui/widget/horizontalspan")
    local Text = require("ui/widget/textboxwidget")
    local Font, Geom = require("ui/font"), require("ui/geometry")
    local Center = require("ui/widget/container/centercontainer")
    local W, H = Screen:getWidth(), Screen:getHeight()
    local width = math.min(W - px(32), px(560))
    local inner = width - px(40)
    local subtitle_height = math.min(px(opts.subtitle_height or 44), math.max(px(64), H - px(260)))
    local actions, descriptions, dismiss_action = {}, {}, nil
    for _, row in ipairs(opts.buttons or {}) do
        for _, action in ipairs(row) do actions[#actions + 1] = action end
    end
    if opts.item_table then
        actions = {}
        for _, item in ipairs(opts.item_table) do
            if item.callback or item.sub_item_table or item.sub_item_table_func then actions[#actions + 1] = item
            else descriptions[#descriptions + 1] = item.text end
        end
    end
    for index = #actions, 1, -1 do
        local label = actions[index].text
        if label == "返回" or label == "返回首页" or label == "关闭" or label == "取消" then
            dismiss_action = actions[index]
            table.remove(actions, index)
            break
        end
    end
    local columns = W < px(400) and 2 or (opts.columns or 3)
    local tile_height = px(88)
    local rows = math.max(1, math.floor((H - px(240)) / tile_height))
    local per_page = rows * columns
    local pages = math.max(1, math.ceil(#actions / per_page))
    local number = math.min(opts.material_page or 1, pages)
    local panel = opts._material_owner or Focus:extend{ name = "inkbridge_material_sheet", modal = true }:new{}
    opts._material_owner = panel
    panel.buttons, panel.item_table, panel.title = opts.buttons, opts.item_table, opts.title
    panel.material = true
    panel.material_subtitle_height = subtitle_height
    panel.material_page, panel.material_pages = number, pages
    panel.layout = {}
    panel.dimen = Geom:new{ w = W, h = H }
    function panel:onShow()
        UI:setDirty(self, "ui")
    end
    function panel:onClose()
        UI:close(self)
        if opts.back then opts.back()
        elseif dismiss_action and dismiss_action.callback then dismiss_action.callback() end
        return true
    end
    function panel:onCloseWidget()
        UI:setDirty("all", "ui")
        if opts.onClose then opts.onClose() end
    end
    function panel:onSetDimensions()
        -- 背后的首页/书库会重建；关闭旧菜单，避免回调仍持有已经销毁的页面。
        UI:close(self)
        return true
    end
    panel.key_events = { Close = { { Device.input.group.Back } } }
    local group = VG:new{ align = "left" }
    group[#group + 1] = Text:new{ text = opts.title or "墨桥", width = inner,
        face = Font:getFace("cfont", opts.title_size or 23), bold = true, height = px(opts.title_height or 56), height_adjust = true,
        height_overflow_show_ellipsis = true }
    local subtitle = opts.subtitle or table.concat(descriptions, "\n")
    if subtitle ~= "" then
        group[#group + 1] = Text:new{ text = subtitle, width = inner,
            face = Font:getFace("cfont", opts.subtitle_font_size or 13),
            fgcolor = opts.subtitle_emphasis and require("ffi/blitbuffer").COLOR_BLACK
                or require("ffi/blitbuffer").COLOR_DARK_GRAY,
            height = subtitle_height, height_adjust = true,
            height_overflow_show_ellipsis = true }
    end
    group[#group + 1] = VS:new{ width = px(opts.content_gap or 12) }
    local tile_width = math.floor((inner - px(8) * (columns - 1)) / columns)
    local row, focus
    for index = (number - 1) * per_page + 1, math.min(number * per_page, #actions) do
        local item = actions[index]
        if (index - 1) % columns == 0 then
            row, focus = HG:new{ align = "center" }, {}
            group[#group + 1] = row
            panel.layout[#panel.layout + 1] = focus
        elseif #row > 0 then row[#row + 1] = HS:new{ width = px(8) } end
        local enabled = item.enabled ~= false and (not item.enabled_func or item.enabled_func())
        local selected = item.checked_func and item.checked_func() or item.selected
        local label = item.short_text or (item.text_func and item.text_func()) or item.text or "选项"
        local button = M.button{ text = label, icon = item.icon or M.iconFor(label), width = tile_width,
            height = tile_height - px(8), stacked = true, selected = selected, enabled = enabled,
            size = 13, show_parent = panel,
            callback = function()
                if item.sub_item_table or item.sub_item_table_func then
                    UI:close(panel)
                    M.showMenu(item.text, item.sub_item_table_func or item.sub_item_table, function()
                        UI:show(M.sheet(opts))
                    end)
                elseif item.callback then item.callback() end
            end,
            hold_callback = item.help_text and function()
                UI:show(M.widget("infomessage"):new{ text = item.help_text })
            end or item.hold_callback }
        row[#row + 1], focus[#focus + 1] = button, button
    end
    local footer, focus_footer = HG:new{ align = "center" }, {}
    local function footerButton(label, icon, callback)
        local button = M.button{ text = label, icon = icon, width = math.floor(inner / (pages > 1 and 3 or 1)),
            height = px(48), callback = callback, show_parent = panel }
        footer[#footer + 1], focus_footer[#focus_footer + 1] = button, button
    end
    if pages > 1 then
        footerButton("上一页", "chevron.left", function()
            if number > 1 then UI:close(panel); opts.material_page = number - 1; UI:show(M.sheet(opts)) end
        end)
    end
    footerButton(opts.back and "返回" or opts.close_text or "关闭", opts.back and "chevron.left" or "close", function()
        panel:onClose()
    end)
    if pages > 1 then
        footerButton(number .. " / " .. pages, "chevron.right", function()
            if number < pages then UI:close(panel); opts.material_page = number + 1; UI:show(M.sheet(opts)) end
        end)
    end
    group[#group + 1] = VS:new{ width = px(opts.footer_gap or 12) }
    group[#group + 1] = footer
    panel.layout[#panel.layout + 1] = focus_footer
    panel[1] = Center:new{ dimen = Geom:new{ w = W, h = H }, M.card(group, {
        padding = opts.card_padding or 20, outline = true, radius = opts.card_radius or 24,
        tonal = opts.tonal,
    }) }
    panel.material_actions = actions
    if panel.refocusWidget then panel:refocusWidget() end
    return panel
end

-- 阅读记录使用文字卡片，避免图标磁贴截掉章节和正文。
function M.recordList(opts)
    local Device, UI = require("device"), require("ui/uimanager")
    local Screen = Device.screen
    local W, H = Screen:getWidth(), Screen:getHeight()
    local Geom, Font = require("ui/geometry"), require("ui/font")
    local VG, HG = require("ui/widget/verticalgroup"), require("ui/widget/horizontalgroup")
    local Text, Span = require("ui/widget/textboxwidget"), require("ui/widget/verticalspan")
    local width = math.min(W - px(32), px(560))
    local inner = width - px(32)
    local row_height = px(126)
    local per_page = math.max(1, math.floor((H - px(236)) / (row_height + px(8))))
    local items = opts.items or {}
    local pages = math.max(1, math.ceil(#items / per_page))
    local number = math.max(1, math.min(opts.number or 1, pages))
    local panel = opts.owner or require("ui/widget/focusmanager"):extend{
        name = "inkbridge_record_list", modal = true }:new{}
    opts.owner, opts.number = panel, number
    panel.title, panel.record_items, panel.record_page, panel.record_pages = opts.title, items, number, pages
    panel.subtitle = opts.subtitle
    panel.dimen, panel.layout = Geom:new{ w = W, h = H }, {}
    local function label(value, size, lines, bold, muted)
        return Text:new{ text = value, width = inner - px(24), face = Font:getFace("cfont", size),
            bold = bold, fgcolor = muted and require("ffi/blitbuffer").COLOR_DARK_GRAY or require("ffi/blitbuffer").COLOR_BLACK,
            height = px(size + 5) * lines, height_adjust = true, height_overflow_show_ellipsis = true,
            line_height = 0.15, alignment = "left" }
    end
    local group = VG:new{ align = "left", label(opts.title or "阅读记录", 22, 1, true), Span:new{ width = px(8) },
        label(opts.subtitle or (#items .. " 条记录 · 点击查看与管理"), 12, 2, false, true), Span:new{ width = px(8) } }
    for i = (number - 1) * per_page + 1, math.min(number * per_page, #items) do
        local item = items[i]
        local button = M.button{ text = item.chapter, width = inner, height = row_height,
            show_parent = panel, callback = function() if item.callback then item.callback(panel) end end }
        if button.label_container then
            button.label_container[1] = VG:new{ align = "left",
                label(item.meta or "", 11, 1, false, true), Span:new{ width = px(5) },
                label(item.chapter or "章节未记录", 15, 1, true), Span:new{ width = px(5) },
                label(item.excerpt or "暂无正文摘要", 13, 2) }
        end
        group[#group + 1] = M.card(button, { padding = 0, outline = true, radius = 12 })
        group[#group + 1] = Span:new{ width = px(8) }
        panel.layout[#panel.layout + 1] = { button }
    end
    if #items == 0 then group[#group + 1] = label("暂无阅读记录，可返回详情手动读取云端记录。", 15, 3) end
    function panel:onClose() UI:close(self); if opts.back then opts.back() end; return true end
    function panel:onShow() UI:setDirty(self, "ui") end
    function panel:onCloseWidget()
        UI:setDirty("all", "ui")
        if not opts._refreshing and opts.on_dismiss then opts.on_dismiss() end
    end
    function panel:onSetDimensions() UI:close(self); return true end
    panel.key_events = { Close = { { Device.input.group.Back } } }
    local footer = HG:new{ align = "center" }
    local focus = {}
    local function foot(text, enabled, callback)
        local button = M.button{ text = text, width = math.floor(inner / (opts.compact_footer and pages == 1 and 1 or 3)), height = px(48),
            enabled = enabled, callback = callback, show_parent = panel }
        footer[#footer + 1], focus[#focus + 1] = button, button
    end
    local function turn(delta)
        opts._refreshing = true
        UI:close(panel); opts.number = number + delta; UI:show(M.recordList(opts))
        opts._refreshing = nil
    end
    if not opts.compact_footer or pages > 1 then
        foot("上一页", number > 1, function() if number > 1 then turn(-1) end end)
    end
    foot((pages > 1 and number .. " / " .. pages .. " · " or "") .. (opts.close_text or "返回"), true, function() panel:onClose() end)
    if not opts.compact_footer or pages > 1 then
        foot("下一页", number < pages, function() if number < pages then turn(1) end end)
    end
    group[#group + 1], panel.layout[#panel.layout + 1] = footer, focus
    panel[1] = require("ui/widget/container/centercontainer"):new{ dimen = panel.dimen,
        M.card(group, { padding = 16, outline = true, radius = 20 }) }
    if panel.refocusWidget then panel:refocusWidget() end
    return panel
end

function M.showMenu(title, items, back)
    local source = type(items) == "function" and items() or items
    local entries = {}
    local panel
    for _, item in ipairs(source or {}) do
        local copy = {}
        for key, value in pairs(item) do copy[key] = value end
        if item.callback then copy.callback = function()
            require("ui/uimanager"):close(panel)
            item.callback()
        end
        elseif not item.sub_item_table and not item.sub_item_table_func then
            copy.icon = copy.icon or "info"
            copy.callback = function()
                require("ui/uimanager"):show(M.widget("infomessage"):new{
                    text = item.text .. (item.help_text and ("\n\n" .. item.help_text) or "") })
            end
        end
        entries[#entries + 1] = copy
    end
    panel = M.sheet{ title = title, item_table = entries, back = back }
    require("ui/uimanager"):show(panel)
    return panel
end

-- 通知、确认和输入继续使用原生行为，仅对插件自己的实例统一字体和圆角。
function M.widget(kind)
    return { new = function(_, opts)
        opts = opts or {}
        if kind == "buttondialog" or kind == "menu" then return M.sheet(opts) end
        -- 原生输入框默认非 modal；从图标菜单打开时必须与菜单同层，避免被菜单盖住。
        if opts.modal == nil then opts.modal = true end
        if kind == "keyvaluepage" then
            local lines = {}
            for _, pair in ipairs(opts.kv_pairs or {}) do
                lines[#lines + 1] = tostring(pair[1]) .. "\n" .. tostring(pair[2])
            end
            opts.text = table.concat(lines, "\n\n")
            kind = "textviewer"
        end
        opts.face = opts.face or require("ui/font"):getFace("cfont", 17)
        opts.title_face = opts.title_face or require("ui/font"):getFace("cfont", 22)
        opts.radius = px(20)
        local widget = require("ui/widget/" .. kind):new(opts)
        if widget.frame then widget.frame.radius = px(20); widget.frame.bordersize = px(1) end
        local seen = {}
        local function quietChildren(node)
            if type(node) ~= "table" or seen[node] then return end
            seen[node] = true
            if type(node._doFeedbackHighlight) == "function" then M.quietButton(node) end
            for _, child in ipairs(node) do quietChildren(child) end
        end
        quietChildren(widget)
        return widget
    end }
end
return M
