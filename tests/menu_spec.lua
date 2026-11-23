-- 原生下拉网格：页签隔离、布局、动作委托、动态配置与子菜单返回。
package.path = "inkbridge.koplugin/?.lua;" .. package.path
local passed, failed = 0, 0
local function check(label, ok)
    if ok then passed = passed + 1 else failed = failed + 1 end
    print((ok and "PASS " or "FAIL ") .. label)
end
local function geometry(w, h)
    return { w = w, h = h, copy = function(self) return geometry(self.w, self.h) end,
        combine = function(self, other) return geometry(math.max(self.w, other.w), math.max(self.h, other.h)) end }
end
local function group(horizontal)
    return { new = function(_, o)
        o = o or {}
        o.clear = function(self) for i = #self, 1, -1 do self[i] = nil end end
        o.getSize = function(self)
            local w, h = 0, 0
            for _, child in ipairs(self) do
                local s = child:getSize()
                if horizontal then w, h = w + s.w, math.max(h, s.h)
                else w, h = math.max(w, s.w), h + s.h end
            end
            return geometry(w, h)
        end
        return o
    end }
end
package.preload["ui/widget/verticalgroup"] = function() return group(false) end
package.preload["ui/widget/horizontalgroup"] = function() return group(true) end
package.preload["ui/widget/horizontalspan"] = function()
    return { new = function(_, o) o.getSize = function() return geometry(o.width, 0) end; return o end }
end
package.preload["ui/widget/verticalspan"] = function()
    return { new = function(_, o) o.getSize = function() return geometry(0, o.width) end; return o end }
end
package.preload["ui/widget/textwidget"] = function()
    return { new = function(_, o) o.getSize = function() return geometry(40, 20) end; return o end }
end
package.preload["ui/geometry"] = function() return { new = function(_, o) return o end } end
package.preload["ui/widget/container/centercontainer"] = function() return { new = function(_, o)
    o.getSize = function(self) return geometry(self.dimen.w, self.dimen.h) end
    return o
end } end
package.preload["ui/widget/container/framecontainer"] = function() return { new = function(_, o)
    o.getSize = function(self) return self[1]:getSize() end
    return o
end } end
package.preload["ffi/blitbuffer"] = function() return { COLOR_LIGHT_GRAY = {} } end
package.preload["ui/widget/button"] = function()
    return { new = function(_, o)
        o.label_widget = { getSize = function() return geometry(o.icon_width or 0, o.icon_height or 0) end }
        o.label_container = { o.label_widget }
        o.getSize = function() return geometry(o.width, o.height or 32) end
        return o
    end }
end
package.preload["ui/font"] = function() return { getFace = function() return {} end } end
local scale = 1
package.preload["device"] = function()
    return { screen = { scaleBySize = function(_, n) return n * scale end } }
end
package.preload["ui/widget/focusmanager"] = function() return { NOT_FOCUS = false } end
local dirtied = 0
package.preload["ui/uimanager"] = function()
    return { setDirty = function() dirtied = dirtied + 1 end,
        show = function() error("下拉网格不可创建独立弹窗") end }
end
local original_calls = 0
local material_title, material_source
package.preload["inkbridge_material"] = function() return {
    quietButton = function(button) button.material_quiet = true; return button end,
    showMenu = function(title, source) material_title, material_source = title, source end,
} end
local TouchMenu = { updateItems = function(menu, page, target)
    original_calls = original_calls + 1
    menu.original_page, menu.original_target = page, target
    menu.time_updated = true
    return "native"
end }
package.preload["ui/widget/touchmenu"] = function() return TouchMenu end
local Menu = require("inkbridge_menu")
check("首次安装渲染钩子", Menu.install())
local installed = TouchMenu.updateItems
check("重复安装不包裹两次", not Menu.install() and TouchMenu.updateItems == installed)
local native = { item_table = {}, dimen = geometry(605, 300) }
check("其他页签原样委托", TouchMenu.updateItems(native, 2, "target") == "native"
    and native.original_page == 2 and native.original_target == "target")
local function widget(w, h) return { getSize = function() return geometry(w, h) end } end
local function make_menu(width)
    local actions = {}
    for _, label in ipairs({ "上传", "下载", "同步", "高级", "首页" }) do
        actions[#actions + 1] = { text = label, icon = "home" }
    end
    actions[3].help_text = "只读同步状态"
    actions[4].sub_item_table_func = function() return { { text = "原有设置" } } end
    actions._inkbridge_grid = true
    return {
        item_table = actions, item_width = width, width = width, dimen = geometry(width, 300),
        bordersize = 1, padding = 0, cur_tab = 6, show_parent = {},
        item_group = group(false):new{}, bar = { icon_widgets = {}, getSize = function() return geometry(width, 50) end },
        footer_top_margin = widget(width, 10), footer = widget(width, 40),
        page_info_text = { setText = function(self, text) self.text = text end },
        page_info_left_chev = { showHide = function(self, visible) self.visible = visible end },
        page_info_right_chev = { showHide = function(self, visible) self.visible = visible end },
        moveFocusTo = function(self) self.focus_reset = true end,
        onMenuSelect = function(self, item) self.selected = item end,
        closeMenu = function(self) self.closed = true end,
        onMenuHold = function(self, item) self.held = item end,
    }
end
local menu = make_menu(605)
TouchMenu.updateItems(menu, 1)
check("保留原生时间电量逻辑", menu.time_updated)
check("保留顶部页签", menu.item_group[1] == menu.bar)
check("保留原生底部页脚", menu.item_group[#menu.item_group] == menu.footer)
check("常规宽度五图标同排", #menu.layout == 2 and #menu.layout[2] == 5)
check("显示原标签", menu.layout[2][1].label_container[1][3].text == "上传")
local first = menu.layout[2][1]
local circle = first.label_container[1][1]
check("圆形图标与下方标签共用整个按钮", circle[1][1] == first.label_widget)
check("48像素圆形底色与相邻入口有间隔", circle:getSize().w == 48 and circle.radius == 24
    and first.width - circle:getSize().w >= 16)
check("圆形下方标签保留8像素空隙", first.label_container[1][2].width == 8)
check("圆形内图标透明叠加避免白色方块", first.label_widget.alpha == true)
check("顶层圆形入口关闭黑色按压反色", first.material_quiet == true)
check("网格宽度没有溢出", menu.item_group[3]:getSize().w <= menu.item_width)
check("下拉高度随图标行收缩", menu.dimen.h < 300)
check("没有独立关闭行", #menu.item_group == 5)
menu.layout[2][1].callback()
check("上传委托原生菜单动作", menu.selected == menu.item_table[1])
menu.layout[2][4].callback()
check("高级通过独立图标菜单展示动态子项", menu.closed and material_title == "高级"
    and material_source == menu.item_table[4].sub_item_table_func)
menu.layout[2][3].hold_callback()
check("同步长按保留说明", menu.held == menu.item_table[3])
check("保留原生焦点栏并复位焦点", menu.layout[1] == menu.bar.icon_widgets and menu.focus_reset)
check("网格不显示多页箭头", menu.page_num == 1 and menu.page_info_left_chev.visible == false
    and menu.page_info_right_chev.visible == false)
local tab = menu.item_table
menu.item_table = menu.item_table[4].sub_item_table_func()
local calls = original_calls
check("高级子菜单交回原生列表", TouchMenu.updateItems(menu, 1) == "native" and original_calls == calls + 1)
menu.item_table = tab
TouchMenu.updateItems(menu, 1)
check("从高级返回仍为图标网格", #menu.layout[2] == 5)
local narrow = make_menu(280)
TouchMenu.updateItems(narrow, 1)
check("窄屏自动换行", #narrow.layout == 3 and #narrow.layout[2] == 3 and #narrow.layout[3] == 2)
scale = 2
local dense = make_menu(605)
TouchMenu.updateItems(dense, 1)
check("高 DPI 按缩放宽度换行", #dense.layout == 3 and dense.layout[2][1].icon_width == 48)
scale = 1
local setup = { text = "尚未设置云同步，点此配置", _inkbridge_setup = true }
local configured = false
tab._inkbridge_items = function()
    local out = {}
    for i = 1, 5 do out[i] = tab[i] end
    if not configured then out[6] = setup end
    return out
end
TouchMenu.updateItems(menu, 1)
check("未配置仍有设置入口", #tab == 6 and menu.layout[3][1].text == setup.text)
menu.layout[3][1].callback()
check("配置按钮使用原生动作", menu.selected == setup)
configured = true
TouchMenu.updateItems(menu, 1)
check("缓存页签重新打开时刷新配置状态", #tab == 5 and #menu.layout == 2)
check("重绘覆盖旧下拉菜单区域", dirtied > 0)
local expanded = make_menu(454)
expanded.item_table[6] = { text = "书籍重构", icon = "appbar.typeset" }
expanded.item_table[7] = setup
TouchMenu.updateItems(expanded, 1)
check("六入口保留首排顺序并在第二排放重构", #expanded.layout[2] == 5
    and expanded.layout[3][1].label_container[1][3].text == "书籍重构")
check("重构整块可点击", expanded.layout[3][1].height == 96 and expanded.layout[3][1].icon_width == 24)
expanded.layout[3][1].callback()
check("重构入口委托原生动作", expanded.selected == expanded.item_table[6])
check("未配置入口排在重构网格之后", expanded.layout[4][1].text == setup.text)
print(string.format("合计：%d 通过，%d 失败", passed, failed))
os.exit(failed == 0 and 0 or 1)
