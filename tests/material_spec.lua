-- 视觉组件契约：原生按压节点、图标语义、分页引用及子菜单生命周期。
package.path = "inkbridge.koplugin/?.lua;" .. package.path
local passed, failed = 0, 0
local function check(name, yes)
    if yes then passed = passed + 1 else failed = failed + 1; print("FAIL " .. name) end
end
local Widget = {}
function Widget:extend(o) return setmetatable(o or {}, { __index = self }) end
function Widget:new(o) return setmetatable(o or {}, { __index = self }) end
function Widget:getSize() return { w = self.width or 40, h = self.height or 24 } end
local W, H, scale = 600, 900, 1
local color = { invert = function(self) return self end }
package.preload["ffi/blitbuffer"] = function() return { COLOR_WHITE = color, COLOR_BLACK = color,
    COLOR_DARK_GRAY = color, COLOR_LIGHT_GRAY = color, gray = function() return color end } end
package.preload["device"] = function() return { screen = {
    getWidth = function() return W end, getHeight = function() return H end,
    scaleBySize = function(_, n) return n * scale end }, input = { group = { Back = { "Esc" } } } } end
package.preload["ui/font"] = function() return { getFace = function(_, _, size) return { size = size } end } end
for _, name in ipairs({ "iconwidget", "textwidget", "textboxwidget", "verticalgroup", "horizontalgroup",
        "verticalspan", "horizontalspan", "focusmanager", "container/framecontainer", "container/centercontainer" }) do
    package.preload["ui/widget/" .. name] = function() return Widget end
end
package.preload["ui/geometry"] = function() return Widget end
local live, closed, dirty
package.preload["ui/uimanager"] = function() return {
    setDirty = function(_, panel) dirty = panel end,
    show = function(_, panel) live = panel end,
    close = function(_, panel) closed = panel; if panel.onCloseWidget then panel:onCloseWidget() end end,
} end
local NativeButton = Widget:extend{}
function NativeButton:new(o)
    o = Widget.new(self, o)
    o.label_widget = { text = o.text, fgcolor = color, getSize = Widget.getSize }
    o.native_label = o.label_widget
    o.label_container = { o.label_widget }
    return o
end
package.preload["ui/widget/button"] = function() return NativeButton end
package.preload["ui/widget/infomessage"] = function() return Widget end
package.preload["ui/widget/inputdialog"] = function() return Widget end
local M = require("inkbridge_material")
check("输入弹窗与图标菜单同为模态以避免遮挡", M.widget("inputdialog"):new{ title = "编辑" }.modal == true)
local button = M.button{ text = "书库", icon = "book.opened", width = 120, stacked = true, selected = true }
check("保留按压反馈可访问的文本叶节点", button.label_widget.fgcolor == color and button.label_widget.text == "书库")
check("组合图标不会替换原生标签契约", button.label_container[1][3] == button.label_widget)
check("导航具有图标及选中状态", button.material_icon == "book.opened" and button.material_selected)
check("图标底色为独立圆形", button.material_circle_size == 40 and button.material_circle.radius == 20)
check("图标圆形保留独立空隙", button.width - button.material_circle_size >= 16)
local no_flash_calls = 0
local quiet = M.button{ text = "测试", callback = function() no_flash_calls = no_flash_calls + 1 end }
quiet:_doFeedbackHighlight(); quiet:_undoFeedbackHighlight(); quiet.callback()
check("按钮不画反色背景且保留回调", quiet.material_quiet and no_flash_calls == 1)
check("默认动作按钮统一48高度", quiet.height == 48)
check("导航触控高度至少64", button.height >= 64)
check("删除图标有明确语义", M.iconFor("删除本地文件") == "cancel")
check("编辑图标有明确语义", M.iconFor("编辑文件名") == "edit")
check("同步图标有明确语义", M.iconFor("同步设置") == "cre.render.reload")
local items = {}
for i = 1, 31 do items[i] = { text = "选项" .. i, callback = function() end } end
local panel = M.sheet{ title = "很多选项", item_table = items }
check("图标菜单独立于原生栏目", panel.material and panel.item_table == items)
panel:onShow()
check("自有弹窗首次显示主动请求重绘", dirty == panel)
check("所有子项保留且显式分页", #panel.material_actions == 31 and panel.material_pages > 1)
local first_page = panel.material_page
local footer = panel.layout[#panel.layout]
footer[#footer].callback()
check("翻页保持同一弹窗引用", live == panel and panel.material_page == first_page + 1)
check("翻页仍可关闭最初的弹窗对象", closed == panel)
panel = M.sheet{ title = "同步前位置对比", subtitle = "本机位置\n远端位置", subtitle_height = 216,
    subtitle_font_size = 17, subtitle_emphasis = true, close_text = "取消",
    buttons = {{ { text = "跳转到远端", callback = function() end } }} }
check("差异预览可容纳多行位置摘要", panel.material_subtitle_height == 216)
local preview_text = panel[1][1][1][2]
check("位置预览使用可读字号且不被弱化", preview_text.face.size == 17 and preview_text.height == 216)
check("位置预览保留明确取消按钮", panel.layout[#panel.layout][1].text == "取消")
panel = M.sheet{ title = "同步前位置对比", title_size = 24, title_height = 58,
    content_gap = 16, footer_gap = 16, card_padding = 24, card_radius = 28, tonal = true,
    subtitle = "正文：第一行\n　　第二行", subtitle_height = 460,
    subtitle_font_size = 17, subtitle_emphasis = true,
    buttons = {{ { text = "跳转到远端", icon = "move.down", callback = function() end },
        { text = "上传本机", icon = "move.up", callback = function() end } }} }
check("预览弹窗采用专用标题层级和留白", panel.material_subtitle_height == 460
    and panel[1][1].radius == 28 and panel[1][1].padding == 24)
check("预览正文使用强调字号", panel[1][1][1][2].face.size == 17)
local called = false
panel = M.sheet{ title = "状态", buttons = {{ { text = "自动核对", checked_func = function() return true end,
    callback = function() called = true end }, { text = "关闭", callback = function() called = "closed" end } }} }
check("移除重复关闭图标入口", #panel.material_actions == 1)
check("动态开关具有选中状态", panel.layout[1][1].material_selected)
panel.layout[1][1].callback()
check("图标调用原动作", called == true)
panel:onClose()
check("返回键执行原关闭回调", called == "closed")
panel = M.sheet{ title = "不可用", buttons = {{ { text = "删除", enabled = false } }} }
check("不可用操作保留禁用状态", panel.layout[1][1].enabled == false)
W, H = 320, 480
panel = M.sheet{ title = "窄屏", item_table = items }
check("窄屏自动两列", #panel.layout[1] == 2)
check("窄屏菜单仍保留全部操作", #panel.material_actions == 31 and panel.material_pages > 1)
panel:onSetDimensions()
check("窗口尺寸变化关闭旧菜单避免失效页面回调", closed == panel)
local back = false
M.showMenu("上级", { { text = "下级", sub_item_table_func = function() return { { text = "信息" } } end } },
    function() back = true end)
local parent = live
parent.layout[1][1].callback()
check("动态子项进入自己的图标菜单", live ~= parent and live.title == "下级")
live:onClose()
check("子菜单返回原上级", live == parent and live.title == "上级")
live:onClose()
check("顶层返回执行返回动作", back)
M.showMenu("说明", { { text = "许可证 GPL-3.0" } })
check("纯说明也可打开不会被截断隐藏", #live.material_actions == 1 and live.material_actions[1].callback ~= nil)
live.layout[1][1].callback()
check("说明展示完整文本", live.text == "许可证 GPL-3.0")
local record_clicked
local records = {}
for i = 1, 8 do records[i] = { meta = "本机 · 12:30", chapter = "第" .. i .. "章",
    excerpt = "真实正文摘要", callback = function(list) record_clicked = list end } end
panel = M.recordList{ title = "阅读记录", items = records }
check("阅读记录使用独立模态卡片列表", panel.modal and panel.name == "inkbridge_record_list" and panel.record_items == records)
check("窄屏记录显式分页且保留全部条目", panel.record_pages == 8 and panel.record_page == 1)
local record_button = panel.layout[1][1]
check("卡片直接展示时间章节和正文", record_button.label_container[1][1].text == "本机 · 12:30"
    and record_button.label_container[1][3].text == "第1章" and record_button.label_container[1][5].text == "真实正文摘要")
record_button.callback()
check("点击卡片交付原列表供详情关闭", record_clicked == panel)
panel.layout[#panel.layout][3].callback()
check("记录翻页保留同一弹窗引用", live == panel and panel.record_page == 2)
panel:onSetDimensions()
check("记录窗口变化关闭旧页", closed == panel)
local record_back = false
panel = M.recordList{ title = "空记录", items = {}, back = function() record_back = true end }
check("空记录保留返回和明确空态", #panel.record_items == 0 and #panel.layout == 1)
panel:onClose()
check("记录返回恢复书籍详情", record_back)
local dismissed = 0
W, H = 605, 921
local selection = { title = "选择要跳转的进度", items = records, compact_footer = true, close_text = "取消",
    on_dismiss = function() dismissed = dismissed + 1 end }
panel = M.recordList(selection)
check("进度列表纵向排列且无图标", #panel.layout[1] == 1 and not panel.layout[1][1].material_icon)
panel.layout[#panel.layout][3].callback()
check("记录翻页不取消正在读取的内容", dismissed == 0 and live == panel)
panel:onClose()
check("关闭记录列表通知调用方取消读取", dismissed == 1)
selection.items = { records[1] }; selection.number = 1
panel = M.recordList(selection)
check("单页进度选择只保留无图标取消按钮", #panel.layout[#panel.layout] == 1
    and panel.layout[#panel.layout][1].text == "取消" and not panel.layout[#panel.layout][1].material_icon)
print(string.format("合计：%d 通过，%d 失败", passed, failed))
os.exit(failed == 0 and 0 or 1)
