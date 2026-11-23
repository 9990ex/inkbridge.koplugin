-- 墨桥页签的原位图标网格：仅替换内容区，保留原生页签、页脚及多级菜单。
local Menu = {}

function Menu.install()
    local TouchMenu = require("ui/widget/touchmenu")
    if TouchMenu._inkbridge_grid_installed then return false end
    local original = TouchMenu.updateItems
    TouchMenu.updateItems = function(menu, ...)
        if not (menu.item_table and menu.item_table._inkbridge_grid) then
            return original(menu, ...)
        end
        local items = menu.item_table
        if items._inkbridge_items then
            local current = items._inkbridge_items()
            for i = #items, 1, -1 do items[i] = nil end
            for i, item in ipairs(current) do items[i] = item end
        end
        -- 原生逻辑负责时间、电量、分页与焦点初始化，不复制各设备的电量分支。
        local old_dimen = menu.dimen:copy()
        original(menu, 1)
        Menu.render(menu)
        menu.dimen.w = menu.width
        menu.dimen.h = menu.item_group:getSize().h + menu.bordersize * 2 + menu.padding
        require("ui/uimanager"):setDirty("all", "ui", old_dimen:combine(menu.dimen))
    end
    TouchMenu._inkbridge_grid_installed = true
    return true
end

function Menu.render(menu)
    local Button = require("ui/widget/button")
    local Font = require("ui/font")
    local Screen = require("device").screen
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local TextWidget = require("ui/widget/textwidget")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local Geom = require("ui/geometry")
    local Blitbuffer = require("ffi/blitbuffer")
    local px = function(value) return Screen:scaleBySize(value) end
    local width = menu.item_width
    local columns = math.max(1, math.min(5, math.floor(width / px(72))))
    local tile_width = math.floor(width / columns)
    local tile_height = px(96)
    local circle_size = math.min(px(48), tile_width - px(16))
    local items = menu.item_table
    menu.item_group:clear()
    menu.layout = { menu.bar.icon_widgets }
    table.insert(menu.item_group, menu.bar)
    table.insert(menu.item_group, VerticalSpan:new{ width = px(18) })
    local row, focus_row
    local tile_index = 0
    for i, item in ipairs(items) do
        local action = item
        if not item._inkbridge_setup then
            if tile_index % columns == 0 then
                row = HorizontalGroup:new{ align = "center" }
                focus_row = {}
                table.insert(menu.item_group, row)
                table.insert(menu.layout, focus_row)
            end
            local button = Button:new{
                icon = action.icon, icon_width = px(24), icon_height = px(24), alpha = true,
                width = tile_width, height = tile_height,
                enabled = action.enabled ~= false and (not action.enabled_func or action.enabled_func()),
                enabled_func = action.enabled_func,
                padding = 0, margin = 0, bordersize = 0,
                show_parent = menu.show_parent,
                callback = function()
                    if action.sub_item_table or action.sub_item_table_func then
                        menu:closeMenu()
                        require("inkbridge_material").showMenu(action.text, action.sub_item_table_func or action.sub_item_table)
                    else menu:onMenuSelect(action) end
                end,
                hold_callback = action.help_text and function() menu:onMenuHold(action, false) end or nil,
            }
            require("inkbridge_material").quietButton(button)
            -- 旧版 Button 不转发 alpha 参数；清掉首次生成的白底图标缓存，再启用透明混合。
            if button.label_widget.free then button.label_widget:free() end
            button.label_widget.alpha = true
            local circle = FrameContainer:new{ padding = 0, margin = 0, bordersize = 0,
                radius = math.floor(circle_size / 2),
                background = Blitbuffer.gray and Blitbuffer.gray(0.06) or Blitbuffer.COLOR_LIGHT_GRAY,
                CenterContainer:new{ dimen = Geom:new{ w = circle_size, h = circle_size }, button.label_widget } }
            -- 仍使用原生 Button 的整块触控与按键行为，图标和标签共同位于按钮内部。
            button.label_container[1] = VerticalGroup:new{ align = "center",
                circle,
                VerticalSpan:new{ width = px(8) },
                TextWidget:new{ text = action.text, face = Font:getFace("cfont", 14),
                    max_width = tile_width - px(8) },
            }
            table.insert(row, button)
            table.insert(focus_row, button)
            tile_index = tile_index + 1
            if tile_index % columns ~= 0 then
                local next_action = items[i + 1]
                if not next_action or next_action._inkbridge_setup then
                    table.insert(row, HorizontalSpan:new{ width = (columns - tile_index % columns) * tile_width })
                end
            end
        else
            local button = Button:new{ text = action.text, width = width,
                bordersize = 0, show_parent = menu.show_parent,
                callback = function() menu:onMenuSelect(action) end }
            require("inkbridge_material").quietButton(button)
            table.insert(menu.item_group, button)
            table.insert(menu.layout, { button })
        end
    end
    table.insert(menu.item_group, menu.footer_top_margin)
    table.insert(menu.item_group, menu.footer)
    menu.page, menu.page_num = 1, 1
    menu.page_info_text:setText("")
    menu.page_info_left_chev:showHide(false)
    menu.page_info_right_chev:showHide(false)
    menu:moveFocusTo(menu.cur_tab, 1, require("ui/widget/focusmanager").NOT_FOCUS)
end

return Menu
