-- 首页离线数据与生命周期回归；测试数据只在当前进程，不写入真实阅读设置。
package.path = "inkbridge.koplugin/?.lua;" .. package.path
local passed, failed = 0, 0
local function check(name, yes)
    if yes then passed = passed + 1 else failed = failed + 1; print("FAIL " .. name) end
end
local values = {}
G_reader_settings = {
    readSetting = function(_, k) return values[k] end,
    saveSetting = function(_, k, v) values[k] = v end,
    delSetting = function(_, k) values[k] = nil end,
}
local History = require("inkbridge_home_history")
check("空设置", #History.load().books == 0)
check("拒绝缺文件", not History.add(nil, { text_anchor = "正文" }))
check("拒绝缺正文", not History.add("a", {}))
check("拒绝空白", not History.add("a", { text_anchor = " \n" }))
check("加入正文", History.add("a", { text_anchor = "真实的第一条正文", updated_at = 100 }, "静读天下", 200, "id"))
check("保留原时间", History.load().books[1].records[1].time == 100)
check("记录读取时间", History.load().books[1].records[1].observed_at == 200)
check("超范围云端时间按缺失处理", History.add("bad-time", {
    text_anchor = "包含错误时间的正文", updated_at = 1e99,
}, "墨桥", 200, "id") and History.load().books[1].records[1].time == nil)
History.add("local-delete", { text_anchor = "本地缓存一" }, "墨桥", 300, "id")
local selected_record = History.load().books[1].records[1]
History.add("local-delete", { text_anchor = "本地缓存二" }, "静读天下", 301, "id")
check("只删除选中的单条本地缓存", History.remove_record("local-delete", "id", selected_record)
    and #History.load().books[1].records == 1
    and History.load().books[1].records[1].text == "本地缓存二")
check("本地缓存引用已变化时拒绝删除", not History.remove_record("local-delete", "id", selected_record))
local bad_time_label, bad_time_is_original = History.format_time({ time = 1e99, observed_at = 200 })
check("旧缓存异常时间安全回退读取时间", bad_time_label == os.date("%m-%d %H:%M", 200)
    and bad_time_is_original == false)
local no_time_label = History.format_time({ time = -math.huge, observed_at = 1e99 })
check("两个时间都异常时仍能安全显示", no_time_label == os.date("%m-%d %H:%M", os.time()))
local old = values[History.KEY]
History.add("a", { text_anchor = "第二条正文" }, "墨桥", 201, "id")
check("设置不可变", #old.books[1].records == 1)
History.add("a", { text_anchor = "第二条正文" }, "墨桥", 202, "id")
check("同来源正文去重", #History.load().books[1].records == 2)
History.add("a", { text_anchor = "第二条正文" }, "静读天下", 203, "id")
check("不同来源保留", #History.load().books[1].records == 3)
History.add("a", { text_anchor = "第四条正文" }, "静读天下", 204, "id")
check("只保留三条", #History.load().books[1].records == 3)
check("最新读取排首位", History.load().books[1].records[1].text == "第四条正文")
check("缺时间不伪造", History.load().books[1].records[1].time == nil)
History.add("a", { text_anchor = "新版原书正文" }, "静读天下", 205, "id2", "退回前一段")
check("换版清旧记录", #History.load().books[1].records == 1)
check("退段说明保留", History.load().books[1].records[1].note == "退回前一段")
History.add("a", { text_anchor = string.rep("中", 161) }, "墨桥", 206, "id2")
check("UTF8 截断完整", History.load().books[1].records[1].text == string.rep("中", 160))
for i = 1, 30 do History.add("file" .. i, { text_anchor = "正文" }, "墨桥", i, "id") end
check("总量有界", #History.load().books == 24)
local recent = History.recent({
    false, { file = "file1", dim = true }, { file = "file30" }, { file = "file30" },
    { file = "absent" }, { file = "new-book" }, { file = "file29" }, { file = "file28" },
}, function(f) return f ~= "absent" end)
check("三本去重并排除丢失", #recent == 3)
check("按阅读顺序而非同步顺序", recent[1].file == "file30" and recent[2].file == "new-book")
check("无历史不伪造片段", #recent[2].records == 0)
local cache_before = values[History.KEY]
values[History.KEY] = { version = 1, books = { { file = "bad-cache", records = true } } }
check("损坏的正文缓存不会导致首页崩溃", #History.recent({ { file = "bad-cache" } })[1].records == 0)
check("损坏的正文缓存可以重新采集", History.add("bad-cache", { text_anchor = "重新采集的正文" }))
values[History.KEY] = cache_before
values[History.KEY] = { version = 999, books = {} }
check("未知版本安全留空", #History.load().books == 0)
for book = 1, 3 do
    for record = 1, 3 do
        History.add("nine" .. book, { text_anchor = "正文" .. record, updated_at = record }, "墨桥", 50, "id")
    end
end
local nine = History.recent({ { file = "nine1" }, { file = "nine2" }, { file = "nine3" } })
check("三书各三条共九条", #nine == 3 and #nine[1].records + #nine[2].records + #nine[3].records == 9)
History.add("nine1", { text_anchor = "更旧的远端正文", updated_at = 0 }, "墨桥", 200, "id")
check("晚下载的旧进度不挤掉新记录", History.recent({ { file = "nine1" } })[1].records[3].time == 1)
values[History.KEY] = nil
check("observe 无书安全", not History.observe({}, {}, "墨桥"))
package.preload.inkbridge_state = function() return { book_id = function() return "id" end } end
check("observe 入库", History.observe({ ui = { document = { file = "real.epub" } } },
    { text_anchor = "真实采集的正文片段" }, "静读天下"))
check("关书上传回调使用采集时的书籍快照", History.observe({ ui = {} }, {
    book_file = "closed.epub", book_id = "closed-id", text_anchor = "关书前采集的真实正文",
}, "墨桥 · 本机上传", "closed.epub", "closed-id"))
local closed_book = History.load().books[1]
check("文档关闭后仍缓存到原书且保留原身份",
    closed_book.file == "closed.epub" and closed_book.book_id == "closed-id"
        and closed_book.records[1].text == "关书前采集的真实正文")
local original_save = G_reader_settings.saveSetting
G_reader_settings.saveSetting = function() error("磁盘错误") end
check("缓存异常不破坏同步", not History.observe({ ui = { document = { file = "a" } } },
    { text_anchor = "正文" }, "墨桥"))
G_reader_settings.saveSetting = original_save

local Home = require("inkbridge_home")
check("显示标题移除扩展名和站点括注", Home.displayTitle("雪中悍刀行 (Z-Library).epub") == "雪中悍刀行")
check("显示标题保留作者和版本", Home.displayTitle("绍宋 (精修版) (榴弹怕水) (z-library.sk, 1lib.sk).EPUB")
    == "绍宋 (精修版) (榴弹怕水)")
check("显示标题清理方括号来源", Home.displayTitle("死人经 [Z-Library].txt") == "死人经")
check("显示标题合并下划线空白", Home.displayTitle("雪中悍刀行__ (烽火戏诸侯).TXT") == "雪中悍刀行 (烽火戏诸侯)")
check("显示标题保留普通括注", Home.displayTitle("作品 (上卷) [修订版].pdf") == "作品 (上卷) [修订版]")
check("标题清理不吃普通句点", Home.displayTitle("作品4.0.mobi") == "作品4.0")
check("空标题有兜底", Home.displayTitle(nil) == "未命名书籍" and Home.displayTitle("   ") == "未命名书籍")
values.start_with = "last"
Home.setAuto(true)
check("启用首页切换文件管理器", values.start_with == "filemanager" and values[Home.AUTO])
Home.setAuto(true)
Home.setAuto(false)
check("重复启用不覆盖原设置", values.start_with == "last")
values.start_with = nil
Home.setAuto(true); Home.setAuto(false)
check("原无设置正确恢复", values.start_with == nil)
Home.setAuto(true); values.start_with = "history"; Home.setAuto(false)
check("不覆盖用户后来修改", values.start_with == "history")

-- 原生控件契约桩：只实现实际存在的 API，捕获页面生命周期和正文跳转。
local scheduled, shown, next_ticks, buttons = {}, {}, {}, {}
local close_refresh, full_dirty, closed_widget
local registered_zones
local Widget = {}
function Widget:extend(proto) return setmetatable(proto or {}, { __index = self }) end
function Widget:new(o)
    o = setmetatable(o or {}, { __index = self })
    if o.init then o:init() end
    return o
end
function Widget:getSize() return { w = self.width or 400, h = 35 } end
function Widget:resetLayout() self.layout_reset_children = #self end
function Widget:setText(s) self.text = s end
function Widget:registerTouchZones(zones) registered_zones = zones end
local UI = {
    show = function(_, w) shown[#shown + 1] = w end,
    close = function(_, w, refresh) closed_widget = w; close_refresh = refresh; if w.onCloseWidget then w:onCloseWidget() end end,
    nextTick = function(_, fn) next_ticks[#next_ticks + 1] = fn end,
    setDirty = function(_, _, refresh, region) if refresh == "ui" and region == nil then full_dirty = true end end,
    unschedule = function(_, fn) scheduled[fn] = nil end,
    scheduleIn = function(_, delay, fn) scheduled[fn] = delay end,
}
package.preload["ui/uimanager"] = function() return UI end
for _, name in ipairs({
    "ui/widget/container/inputcontainer", "ui/widget/container/framecontainer", "ui/widget/verticalgroup",
    "ui/widget/verticalspan", "ui/widget/textwidget", "ui/widget/textboxwidget",
    "ui/gesturerange", "ui/geometry",
    "ui/widget/infomessage", "ui/widget/buttondialog", "ui/widget/touchmenu", "ui/widget/confirmbox",
    "ui/widget/horizontalgroup", "ui/widget/horizontalspan", "ui/widget/linewidget",
    "ui/widget/container/centercontainer", "ui/widget/container/leftcontainer", "ui/widget/textviewer",
    "ui/widget/container/topcontainer",
    "ui/widget/iconwidget", "ui/widget/focusmanager",
    "ui/widget/pathchooser", "ui/widget/menu",
}) do package.preload[name] = function() return Widget end end
package.preload["ui/widget/container/scrollablecontainer"] = function()
    error("固定首页不得重新引入滚动容器")
end
package.preload["ui/widget/button"] = function()
    return Widget:extend{ init = function(self) buttons[#buttons + 1] = self end }
end
package.preload["ui/widget/buttontable"] = function()
    return Widget:extend{ init = function(self) for _, row in ipairs(self.buttons) do
        for _, b in ipairs(row) do buttons[#buttons + 1] = b end
    end end }
end
package.preload["ui/font"] = function() return { getFace = function(_, name, size) return { name = name, size = size } end } end
package.preload["ffi/blitbuffer"] = function() return {
    COLOR_WHITE = "white", COLOR_BLACK = "black", COLOR_GRAY = "gray", COLOR_DARK_GRAY = "darkgray",
} end
package.preload["device"] = function() return {
    input = { group = { Back = "Back" } },
    isTouchDevice = function() return true end,
    screen = { getWidth = function() return 454 end, getHeight = function() return 721 end,
        scaleBySize = function(_, n) return n end },
} end
G_defaults = { readSetting = function(_, key)
    if key == "DTAP_ZONE_MENU" then return { x = 0, y = 0, w = 1, h = 1 / 8 } end
    if key == "DTAP_ZONE_MENU_EXT" then return { x = 1 / 4, y = 0, w = 2 / 4, h = 1 / 5 } end
end }
package.preload["libs/libkoreader-lfs"] = function() return { attributes = function(f) return f ~= "gone" and "file" or nil end } end
local readhistory = { hist = {
    { file = "real.epub" }, { file = "new.epub" }, { file = "third.epub" },
} }
function readhistory:getIndexByFile(file)
    for i, item in ipairs(self.hist) do if item.file == file then return i end end
end
function readhistory:removeItem(item, index)
    table.remove(self.hist, index)
    self.removed_file = item.file
end
package.preload["readhistory"] = function() return readhistory end
History.add("real.epub", { text_anchor = "较早的同步正文", updated_at = 1 }, "墨桥", 1, "id")
History.add("real.epub", { text_anchor = "更早的同步正文", updated_at = 0 }, "墨桥", 0, "id")
History.add("third.epub", { text_anchor = "第三本书的最新摘录", updated_at = 1 }, "墨桥", 1, "third-id")
local after_open, opened
package.preload["apps/reader/readerui"] = function() return {
    showReader = function(_, file, _, _, _, cb) opened = file; after_open = cb end,
} end
local jumped
package.preload.inkbridge_webdav = function() return {
    confirm_jump = function(plugin, remote, opts) jumped = { plugin, remote, opts } end,
} end
local native_homes, native_arg = 0
local native_menu_swipes, native_menu_taps = 0, 0
local metadata_readonly = true
local plugin = { ui = { menu = {
    onTapShowMenu = function(_, ges)
        if ges.pos then native_menu_taps = native_menu_taps + 1; return true end
    end,
    onSwipeShowMenu = function(_, ges)
    if ges.direction == "south" then native_menu_swipes = native_menu_swipes + 1; return true end
    end,
}, bookinfo = { getDocProps = function(_, file, props, no_open)
    metadata_readonly = metadata_readonly and no_open == true and props == nil
    if file == "real.epub" then return { display_title = "主书名 (Z-Library).epub", authors = "作者甲\n作者乙" } end
    return {}
end }, onHome = function(_, arg)
    native_homes = native_homes + 1; native_arg = arg; return "native-home"
end }, _advanced_menu = function() return {} end }
Home.attach(plugin)
check("默认不抢启动", #next_ticks == 0)
check("关闭首页时保留原生Home返回值", plugin.ui:onHome("original") == "native-home")
check("关闭首页保留原参数", native_homes == 1 and native_arg == "original")
local routed_home = plugin.ui.onHome
Home.attach(plugin)
check("重复attach不层叠Home补丁", plugin.ui.onHome == routed_home)
Home.setAuto(true)
Home.attach(plugin)
check("启用延迟显示", #next_ticks == 1)
table.remove(next_ticks, 1)()
local page = Home.instance
check("创建首页", page and #shown == 1)
check("首页注册KOReader原生顶部菜单触摸区域", registered_zones and #registered_zones == 4
    and registered_zones[1].screen_zone.ratio_h == 1 / 8)
registered_zones[3].handler({ direction = "south" })
check("首页顶部下滑转交原生菜单处理器", native_menu_swipes == 1)
check("其他方向不伪装成下拉菜单", registered_zones[3].handler({ direction = "north" }) == nil
    and native_menu_swipes == 1)
registered_zones[1].handler({ pos = true })
check("首页顶部轻点转交原生菜单处理器", native_menu_taps == 1)
check("全屏不透明避免原生书库透出", page[1].background == "white")
check("打开首页显式全屏刷新", full_dirty == true)
check("分钟刷新而非秒刷新", scheduled[page.tick] and scheduled[page.tick] > 0 and scheduled[page.tick] <= 60)
Home.show(plugin)
check("不重复创建首页", #shown == 1)
page:onSuspend()
check("休眠停止时钟", scheduled[page.tick] == nil)
page:onResume()
check("唤醒恢复时钟", scheduled[page.tick] ~= nil)
local function button(label)
    for i = #buttons, 1, -1 do if buttons[i].text == label then return buttons[i] end end
end
local function findText(widget, value)
    if widget.text == value then return widget end
    for _, child in ipairs(widget) do
        local found = findText(child, value)
        if found then return found end
    end
end
check("首页使用当前文件名而非内部旧标题", findText(page[1], "real") ~= nil
    and findText(page[1], "主书名") == nil)
check("首页元数据读取禁止打开文档", metadata_readonly)
check("正在阅读独立只展示一本", #page.book_sections == 1 and page.view == "reading")
check("首页按四个区域分配且中间放三次阅读", #page.home_regions == 4
    and page.home_region_height == math.floor((721 - 48 - 96) / 3)
    and #page.book_sections[1].record_rows == 3)
check("首页第一段显示离线农历", findText(page.home_regions[1], require("inkbridge_calendar").format()) ~= nil)
local reading_metrics = page.layout_metrics
check("首页底部导航使用固定96高度", page.navigation.dimen.h == 96
    and reading_metrics.navigation_y == 721 - 24 - 96)
check("首页导航按钮统一88高度", button("正在阅读").height == 88 and button("书库").height == 88 and button("设置").height == 88)
check("首页卡片宽度与页面内容边界一致", page.home_regions[2].dimen.w == 454 - 48
    and page.home_regions[3].dimen.w == 454 - 48)
check("没有章节信息时明确占位", findText(page.content, "章节未记录") ~= nil)
check("最新摘录留在首页", findText(page.content, "真实采集的正文片段") ~= nil)
check("三条记录全部直显不再折叠", findText(page.content, "较早的同步正文") ~= nil
    and findText(page.content, "更早的同步正文") ~= nil)
check("其他书不混入正在阅读", findText(page.content, "第三本书的最新摘录") == nil)
check("正在阅读保留书名", findText(page[1], "real").face.size == 25)
check("长摘录截断并保留溢出提示", findText(page[1], "真实采集的正文片段").height_overflow_show_ellipsis == true)
check("首页操作移除粗边框", button("刷新记录").bordersize == 0 and button("继续阅读  ›").bordersize == 0)
button("同步记录 · 3").callback()
local history_viewer = shown[#shown]
check("完整历史含最新和旧摘录", history_viewer.text:find("真实采集的正文片段", 1, true)
    and history_viewer.text:find("较早的同步正文", 1, true) and history_viewer.text:find("更早的同步正文", 1, true))
check("完整历史保留原始书名", history_viewer.text:find("real.epub", 1, true) ~= nil)
check("完整历史为每条记录保留打开入口", #history_viewer.buttons_table[1] == 3)
check("查看记录暂停时钟", scheduled[page.tick] == nil)
UI:close(history_viewer)
check("关闭记录恢复时钟", scheduled[page.tick] ~= nil)
check("首页完全移除滚动容器", page.cropping_widget == nil)
check("首页按钮反馈绑定当前首页", button("正在阅读").show_parent == page
    and button("设置").show_parent == page and button("继续阅读  ›").show_parent == page)
check("当前书固定三个记录位置", #page.book_sections[1].record_rows == 3)
check("补齐记录后失效原生栏目布局缓存", page.book_sections[1].layout_reset_children == #page.book_sections[1]
    )
check("书库统一承载历史入口且移除独立历史页签", button("书库") ~= nil and button("历史记录") == nil
    and button("正在阅读") ~= nil and button("设置") ~= nil)
check("固定首页反复点击当前页签不崩溃", pcall(function()
    for _ = 1, 3 do button("正在阅读").callback() end
end))
button("设置").callback()
check("设置打开暂停时钟", scheduled[page.tick] == nil)
UI:close(shown[#shown])
check("关闭设置恢复时钟", scheduled[page.tick] ~= nil)
button("设置").callback()
check("设置提供文件管理器入口", shown[#shown].buttons[1][1].text == "文件管理器")
shown[#shown].buttons[3][1].callback()
check("同步设置使用独立图标菜单", shown[#shown].material and shown[#shown].title == "同步设置")
check("设置子菜单保留首页并暂停时钟", Home.instance == page and scheduled[page.tick] == nil)
shown[#shown]:onClose()
check("设置子菜单返回设置图标面板", shown[#shown].material and shown[#shown].title == "首页设置")
UI:close(shown[#shown])
page:leave()
buttons = {}
Home.show(plugin)
page = Home.instance

-- 点击真实正文：先打开正确书籍，再走唯一锚点确认，不用比例兜底。
local content = page.content
local function findRow(widget, value)
    if widget.onHomeRecord and findText(widget, value) then return widget end
    for _, child in ipairs(widget) do
        local found = findRow(child, value)
        if found then return found end
    end
end
local row = findRow(content, "真实采集的正文片段")
check("有可点正文", row ~= nil)
row:onHomeRecord()
check("点击先打开所属书", opened == "real.epub")
check("离开首页停止时钟", Home.instance == nil and scheduled[page.tick] == nil)
check("关闭首页显式刷新书库", close_refresh == "ui")
after_open({ document = { file = opened } })
table.remove(next_ticks, 1)()
check("要求唯一全文命中", jumped and jumped[2].require_unique_text == true)
check("重放不制造新历史", jumped and jumped[3].home_replay == true)
jumped = nil
after_open({ document = { file = "other.epub" } })
table.remove(next_ticks, 1)()
check("异书不跳转", jumped == nil)
require("inkbridge_state").book_id = function() return "new-id" end
after_open({ document = { file = opened } })
table.remove(next_ticks, 1)()
check("换版不跳转", jumped == nil)
buttons = {}
Home.show(plugin)
button("书库").callback()
check("未配置目录时默认打开本地书库页", Home.instance.view == "library"
    and Home.instance.library_data.source == "local" and not Home.instance.library_data.loading)
check("书库有本地与WebDAV切换栏", button("本地") and button("WebDAV"))
check("未配置目录不强制打开远端选择器", findText(Home.instance.content,
    "点击「选择目录」设置书籍文件夹。") ~= nil)
Home.instance:leave()
buttons = {}
check("原生房子入口已消费事件", plugin.ui:onHome() == true)
check("原生房子入口打开墨桥而非主目录", Home.instance and Home.instance.name == "inkbridge_home" and native_homes == 1)
Home.instance:leave()
Home.setAuto(false)
check("关闭功能即时恢复原生Home", plugin.ui:onHome("restored") == "native-home" and native_arg == "restored")

local sync_calls, sync_done = 0
local sync = { refresh = function(_, selected, cb)
    sync_calls = sync_calls + 1; sync_done = cb
    check("刷新只传首页最近三本", #selected <= 3 and selected[1].file == "real.epub")
end }
package.preload.inkbridge_home_sync = function() return sync end
buttons = {}
Home.show(plugin)
check("打开首页本身不后台读取", sync_calls == 0)
button("刷新记录").callback()
check("读取按钮接入真实补全模块", sync_calls == 1 and sync_done ~= nil)
local refreshing_page = Home.instance
sync_done(true, "读取完成")
check("读取完成重建当前首页", Home.instance ~= refreshing_page and Home.instance ~= nil)
Home.instance:leave()
buttons = {}; Home.show(plugin)
button("刷新记录").callback()
Home.instance:leave()
sync_done(true, "读取完成")
check("读取期间离开不强制重开首页", Home.instance == nil)

-- 折叠后的旧记录仍经过原书核对与唯一锚点确认。
buttons = {}; Home.show(plugin)
require("inkbridge_state").book_id = function() return "id" end
button("同步记录 · 3").callback()
history_viewer = shown[#shown]
history_viewer.buttons_table[1][2].callback()
check("旧记录入口打开原书并关闭首页", opened == "real.epub" and Home.instance == nil)
after_open({ document = { file = opened } })
table.remove(next_ticks, 1)()
check("旧记录不丢失安全重放语义", jumped and jumped[2].text_anchor == "较早的同步正文"
    and jumped[2].require_unique_text == true and jumped[3].home_replay == true)

-- 继续阅读只恢复本机位置，不暗中采用同步摘录。
buttons = {}; Home.show(plugin); jumped = nil
button("继续阅读  ›").callback()
after_open({ document = { file = opened } })
check("继续阅读不安排远端跳转", jumped == nil and #next_ticks == 0)

local hist = require("readhistory").hist
require("readhistory").hist = {}
buttons = {}; Home.show(plugin)
check("空书库保留单栏并展示阅读引导", #Home.instance.book_sections == 1
    and findText(Home.instance[1], "从书库打开书籍后显示在这里") ~= nil)
button("书库").callback()
check("空阅读历史也能进入本地目录书库", Home.instance.view == "library"
    and Home.instance.library_data.source == "local")
Home.instance:leave()
require("readhistory").hist = hist
local get_props = plugin.ui.bookinfo.getDocProps
plugin.ui.bookinfo.getDocProps = function() error("元数据损坏") end
buttons = {}; Home.show(plugin)
check("元数据读取异常安全退回文件名", findText(Home.instance[1], "real") ~= nil)
Home.instance:leave()
plugin.ui.bookinfo.getDocProps = get_props
local old_hist_file = require("readhistory").hist[1].file
require("readhistory").hist[1].file = "蛊真人.epub"
buttons = {}; Home.show(plugin)
check("文件改名后正在阅读展示新名称", findText(Home.instance.content, "蛊真人") ~= nil)
Home.instance:leave()
require("readhistory").hist[1].file = old_hist_file

-- 历史页完整可达，当前书独立，不受旧三本显示上限影响。
local saved_hist = require("readhistory").hist
require("readhistory").hist = {
    { file = "real.epub" }, { file = "new.epub" }, { file = "third.epub" },
    { file = "four.epub" }, { file = "five.epub" }, { file = "six.epub" }, { file = "seven.epub" },
}
buttons = {}; Home.show(plugin)
local reading_page = Home.instance
reading_page:leave()
buttons = {}; Home.show(plugin, "history")
page = Home.instance
check("历史记录独立页面", page ~= reading_page and page.view == "history")
check("切换后旧页停止时钟", scheduled[reading_page.tick] == nil)
check("历史页排除正在阅读", #page.books == 3 and page.books[1].file == "new.epub"
    and findText(page.content, "real") == nil)
check("历史页展示其他书摘录", findText(page.content, "第三本书的最新摘录") ~= nil)
check("历史页每书保留三条位置", #page.book_sections == 3 and #page.book_sections[1].record_rows == 3)
button("管理书籍").callback()
local manage_dialog = shown[#shown]
check("历史书籍管理不提供整书删除", #manage_dialog.buttons == 2
    and manage_dialog.buttons[1][1].text == "查看同步记录")
manage_dialog.buttons[2][1].callback()
check("无同步历史的书保留空位", findText(page.book_sections[1], "暂无同步记录") ~= nil)
check("历史记录超过三本可翻页", page.history_pages == 2 and page.history_page == 1)
local next_page = button("下一页")
buttons = {}; next_page.callback()
page = Home.instance
check("历史下一页能访问全部其他书", page.history_page == 2 and page.books[1].file == "five.epub"
    and page.books[3].file == "seven.epub")
local current_page = page
button("下一页").callback()
check("历史末页不能越界", Home.instance == current_page)
local back_reading = button("正在阅读")
buttons = {}; back_reading.callback()
page = Home.instance
check("返回正在阅读仍是最近打开书", page.view == "reading" and #page.books == 1 and page.books[1].file == "real.epub")
page:leave()
buttons = {}; Home.show(plugin, "history", 2)
page = Home.instance
page:onSetDimensions()
table.remove(next_ticks, 1)()
check("尺寸变化保留历史页位置", Home.instance.view == "history" and Home.instance.history_page == 2)
Home.instance:onHomeBack()
check("历史物理返回回到正在阅读", Home.instance and Home.instance.view == "reading")
Home.instance:leave()
require("readhistory").hist = { { file = "real.epub" } }
buttons = {}; Home.show(plugin, "history")
check("只有当前书时历史明确为空", #Home.instance.books == 0 and #Home.instance.book_sections == 1
    and findText(Home.instance.content, "暂无其他阅读书籍") ~= nil)
Home.instance:leave()

readhistory.hist = { { file = "current.epub" }, { file = "local-target.epub" } }
History.add("local-target.epub", { text_anchor = "本机应保留的缓存" }, "墨桥", 400, "local-id")
check("逐条缓存管理不负责删除KOReader阅读历史", readhistory:getIndexByFile("local-target.epub") ~= nil)
require("readhistory").hist = saved_hist

-- 书库使用实际目录书目和自己的分页，不受正在阅读/旧历史页数量影响。
local library_books = {}
for i = 1, 25 do
    library_books[i] = { title = string.format("Book %02d.epub", i), file = "/books/book-" .. i .. ".epub",
        local_records = {}, cloud_records = {} }
end
local data = { source = "local", root = "/books", books = library_books, skipped = 0 }
buttons = {}; Home.show(plugin, "library", 1, data)
page = Home.instance
check("目录书目直接显示在书库主体", #page.library_rows > 0 and page.library_rows[1] == library_books[1]
    and findText(page.content, "Book 01") ~= nil)
check("书库不调度不可见首页时钟", scheduled[page.tick] == nil)
check("书库按可用高度分页且不滚动", page.library_pages > 1 and page.cropping_widget == nil)
local per_page = #page.library_rows
next_page = button("下一页"); buttons = {}; next_page.callback()
check("书库下一页不被旧历史页数截断", Home.instance.library_page == 2
    and Home.instance.library_rows[1] == library_books[per_page + 1])
page = Home.instance
page:onSetDimensions(); table.remove(next_ticks, 1)()
check("书库尺寸改变保留来源目录和页码", Home.instance.library_page == 2
    and Home.instance.library_data == data)
Home.instance:leave()
buttons = {}; Home.show(plugin, "library", 1, data)
Home.instance.book_overflow[1].callback()
check("书库与首页导航具有同一基线和高度", Home.instance.layout_metrics.navigation_y == reading_metrics.navigation_y
    and Home.instance.navigation.dimen.h == 96 and button("书库").height == 88)
check("书库动作按钮统一48高度", button("本地").height == 48 and button("文件夹").height == 48
    and button("列表调整").height == 48 and Home.instance.book_overflow[1].height == 48)
check("书籍三点菜单是独立的48像素触控区", Home.instance.book_overflow[1].width == 48
    and Home.instance.book_overflow[1].accessibility_label == "书籍操作")
check("点击三点菜单保留书库且不打开阅读器", Home.instance.view == "library" and shown[#shown].material == true)
check("本地详情保留阅读及手动云端读取入口", shown[#shown].item_table[1].text == "打开书籍"
    and shown[#shown].item_table[6].text == "读取这本书的云端记录")
local detail = shown[#shown]
local managed_file = detail.item_table[2].text:sub(#"本地文件 · " + 1)
check("详情合并历史和同步记录并移除独立改名", detail.item_table[7].text == "阅读记录"
    and #detail.item_table == 7 and detail.item_table[3].text == "文件存留 · 正常")
check("三点菜单直接提供删除文件与EPUB元数据", detail.item_table[4].text == "删除文件"
    and detail.item_table[5].text == "EPUB 元数据")
detail.item_table[4].callback()
local delete_options = shown[#shown]
check("直接删除仍先选择阅读数据处理方式", delete_options.title == "删除文件"
    and delete_options.buttons[1][1].text == "删除文件，保留阅读数据"
    and delete_options.buttons[2][1].text == "删除文件及本机阅读数据")
local Files = require("inkbridge_book_files")
local native_snapshot, native_delete = Files.snapshot, Files.delete
local delete_calls, delete_target, delete_purge = 0
Files.snapshot = function(file) return { file = file } end
Files.delete = function(target, purge)
    delete_calls, delete_target, delete_purge = delete_calls + 1, target, purge
    return false, "测试删除拒绝，不修改文件"
end
delete_options.buttons[1][1].callback()
local deletion_confirm = shown[#shown]
check("直接删除先确认且不立即删除", delete_calls == 0 and deletion_confirm.ok_text == "确认删除"
    and deletion_confirm.text:find("保留本机阅读进度", 1, true) ~= nil)
UI:close(deletion_confirm)
check("关闭确认不调用文件删除", delete_calls == 0)
delete_options.buttons[2][1].callback()
deletion_confirm = shown[#shown]
check("删除阅读数据在确认中明确列出", deletion_confirm.text:find("同时删除本机阅读进度", 1, true) ~= nil
    and deletion_confirm.text:find("云端文件和记录不变", 1, true) ~= nil)
deletion_confirm.ok_callback()
check("确认后仅删除选中本地文件并传递数据选项", delete_calls == 1 and delete_target.file == managed_file and delete_purge == true)
UI:close(shown[#shown])
Files.snapshot, Files.delete = native_snapshot, native_delete
UI:close(delete_options)
local edited_file
package.loaded["inkbridge_book_metadata"] = { show = function(_, file) edited_file = file end }
detail.item_table[5].callback()
check("EPUB元数据入口只交付当前选中书籍", edited_file == managed_file)
package.loaded["inkbridge_book_metadata"] = nil
detail.item_table[7].callback()
check("未读书籍记录如实显示为空", #shown[#shown].record_items == 0 and shown[#shown].title == "阅读记录")
UI:close(shown[#shown])
detail.item_table[3].callback()
local retention = shown[#shown]
check("文件存留提供两种删除和保留入口", #retention.buttons == 4
    and retention.buttons[2][1].text == "删除文件，保留阅读数据")
retention.buttons[1][1].callback()
check("保留标记写入并刷新书籍详情", require("inkbridge_book_files").kept(managed_file)
    and shown[#shown].item_table[3].text == "文件存留 · 已标记保留")
check("标记保留时直接删除入口禁用", shown[#shown].item_table[4].enabled == false)
require("inkbridge_book_files").setKept(managed_file, false)
UI:close(shown[#shown])
local record_book = library_books[1]
local local_record = { file = managed_file, book_id = "local-id", record = {
    time = 500, source = "本机阅读", chapter = "真实第一章", excerpt = "第一章完整正文摘要", text = "本机同步锚点" } }
local cloud_record = { book_id = "local-id", record = {
    time = 600, source = "手机", chapter = "真实第二章", text = "来自手机的真实摘要" } }
record_book.local_records, record_book.cloud_records = { local_record }, { cloud_record }
Home.instance.book_overflow[1].callback()
detail = shown[#shown]
detail.item_table[7].callback()
local record_list = shown[#shown]
check("打开阅读记录先关闭书籍菜单避免遮挡", closed_widget == detail and record_list.modal)
check("统一列表包含本机和云端并按时间降序", #record_list.record_items == 2
    and record_list.record_items[1].chapter == "真实第二章" and record_list.record_items[2].chapter == "真实第一章")
check("记录卡片显示章节正文及来源范围", record_list.record_items[1].excerpt == "来自手机的真实摘要"
    and record_list.record_items[1].meta:find("云端记录", 1, true) ~= nil
    and record_list.record_items[2].excerpt == "第一章完整正文摘要")
record_list.record_items[2].callback(record_list)
local record_detail = shown[#shown]
check("记录详情保持模态并展示完整章节摘要锚点", closed_widget == record_list and record_detail.modal
    and record_detail.title == "真实第一章" and record_detail.text:find("本机同步锚点", 1, true) ~= nil)
local RecordLibrary = require("inkbridge_library")
local old_delete_local, old_delete_cloud = RecordLibrary.delete_local, RecordLibrary.delete_cloud
local removed_row, remove_count = nil, 0
RecordLibrary.delete_local = function(target) removed_row = target; remove_count = remove_count + 1; return true end
record_detail.buttons_table[1][2].callback()
local record_confirm = shown[#shown]
check("从记录详情删除仍需逐条确认", remove_count == 0 and record_confirm.ok_text == "删除此条")
UI:close(record_confirm)
check("取消记录删除不触碰数据", remove_count == 0 and #record_book.local_records == 1)
record_detail.buttons_table[1][2].callback()
shown[#shown].ok_callback()
record_list = shown[#shown - 1]
check("确认只删除原本机条目并刷新列表", removed_row == local_record and remove_count == 1
    and #record_book.local_records == 0 and #record_book.cloud_records == 1 and #record_list.record_items == 1)
record_list.record_items[1].callback(record_list)
record_detail = shown[#shown]
local cloud_target
RecordLibrary.delete_cloud = function(_, selected_book, target, done)
    cloud_target = target
    check("云端删除交付原书和原记录", selected_book == record_book and target == cloud_record)
    done(false, "云端版本已变化，未删除。")
end
record_detail.buttons_table[1][2].callback(); shown[#shown].ok_callback()
check("云端拒绝时保留记录", cloud_target == cloud_record and #record_book.cloud_records == 1
    and shown[#shown].text == "云端版本已变化，未删除。")
record_detail.close_callback()
check("原生关闭按钮也返回统一记录列表", shown[#shown].title == "阅读记录" and #shown[#shown].record_items == 1)
RecordLibrary.delete_local, RecordLibrary.delete_cloud = old_delete_local, old_delete_cloud
UI:close(shown[#shown]); UI:close(record_detail)
row = findRow(Home.instance.content, "Book 01")
row:onHomeRecord()
check("书库点击本地书名直接阅读", opened == "/books/book-1.epub" and Home.instance == nil)
buttons = {}; Home.show(plugin, "library", 1, data)
local webdav_tab = button("WebDAV"); buttons = {}; webdav_tab.callback()
check("WebDAV作为可选来源独立切换", Home.instance.library_data.source == "webdav"
    and not Home.instance.library_data.loading)
check("远端未配置时留在书库显示选择入口", findText(Home.instance[1], "请选择 WebDAV 书籍目录") ~= nil)
local local_tab = button("本地"); buttons = {}; local_tab.callback()
check("切回本地不要求WebDAV配置", Home.instance.library_data.source == "local")
Home.instance:onHomeBack()
check("书库物理返回回到正在阅读", Home.instance and Home.instance.view == "reading")
Home.instance:leave()
local Lib = require("inkbridge_library")
local old_root, old_scan = Lib.localRoot, Lib.scanLocal
local local_done, cancelled
Lib.localRoot = function() return "/books" end
Lib.scanLocal = function(_, cb) local_done = cb; return function() cancelled = true end end
buttons = {}; Home.show(plugin, "library")
check("本地扫描期间仍显示完整书库导航", Home.instance.library_data.loading and button("WebDAV") ~= nil)
Home.instance:leave()
local_done(true, {}, 0)
check("离开本地书库终止扫描且迟到结果不重开页面", cancelled and Home.instance == nil)
Lib.localRoot, Lib.scanLocal = old_root, old_scan

buttons = {}; Home.show(plugin, "library", 1, data)
local normal_rows = #Home.instance.library_rows
button("列表调整").callback()
local adjust = shown[#shown]
check("列表调整提供密度和排序选项", #adjust.buttons[1] == 3 and #adjust.buttons[2] == 2)
buttons = {}; adjust.buttons[1][1].callback()
check("紧凑列表增加每页书目并保存选项", #Home.instance.library_rows > normal_rows
    and Lib.viewOptions().density == "compact")
button("列表调整").callback(); adjust = shown[#shown]
buttons = {}; adjust.buttons[2][2].callback()
check("名称降序即时改变书目顺序", Home.instance.library_rows[1] == library_books[25]
    and Lib.viewOptions().sort == "descending")
Home.instance:leave()
Lib.setViewOption("sort", "name"); Lib.setViewOption("density", "normal")
local folder_data = { source = "local", root = "/books", books = {
    { file = "/books/fiction/nested.epub", title = "Nested.epub", local_records = {}, cloud_records = {} },
}, folders = { { path = "/books/fiction" }, { path = "/books/empty" } } }
buttons = {}; Home.show(plugin, "library", 1, folder_data)
check("文件夹视图保留空目录和真实层级", #Home.instance.library_rows == 2
    and Home.instance.library_rows[1].is_folder and Home.instance.library_rows[1].title == "empty")
findRow(Home.instance.content, "fiction"):onHomeRecord()
check("点击文件夹只显示本层书籍和上级入口", Home.instance.library_data.directory == "books/fiction"
    and Home.instance.library_rows[1].is_parent and Home.instance.library_rows[2].file == "/books/fiction/nested.epub")
Home.instance:onHomeBack()
check("子目录物理返回先回到书库上级", Home.instance.view == "library"
    and Home.instance.library_data.directory == "books")
local all_button = button("全部书籍"); buttons = {}; all_button.callback()
check("全部书籍视图跨目录显示且保留切换", #Home.instance.library_rows == 1
    and Home.instance.library_rows[1].title == "Nested.epub" and Lib.viewOptions().mode == "all")
Home.instance:leave(); Lib.setViewOption("mode", "folders")

local chapter_target
local chapter_ui = { document = { file = "real.epub", isXPointerInDocument = function(_, xp) return xp == "valid-xp" end },
    toc = { getTocTitleByPage = function(_, xp) chapter_target = xp; return "第七百一十七节：巨阳的伟大" end } }
check("章节按实际记录锚点查询而非当前页", History.captureChapter(chapter_ui,
    { book_file = "real.epub", xpointer = "valid-xp" }) == "第七百一十七节：巨阳的伟大" and chapter_target == "valid-xp")
chapter_target = nil
check("无效锚点不调用目录也不猜章节", History.captureChapter(chapter_ui, { xpointer = "invalid" }) == nil
    and chapter_target == nil)
check("异书不借用当前书章节", History.captureChapter(chapter_ui,
    { book_file = "another.epub", xpointer = "valid-xp" }) == nil)
check("缺目录接口明确留空", History.captureChapter({ document = chapter_ui.document }, { xpointer = "valid-xp" }) == nil)
History.observe({ ui = chapter_ui }, { text_anchor = "章节内的真实选段", xpointer = "valid-xp" }, "墨桥", "real.epub", "id")
check("观察记录时保存真实章节", History.load().books[1].records[1].chapter == "第七百一十七节：巨阳的伟大")
History.observe({ ui = {} }, { text_anchor = "关书时保留的章节选段", home_chapter = "真实关闭前章节" },
    "墨桥", "real.epub", "id")
check("关书后保留采集时章节快照", History.load().books[1].records[1].chapter == "真实关闭前章节")
readhistory.hist = saved_hist
buttons = {}; Home.show(plugin)
check("四分首页展示记录章节与选段", findText(Home.instance.content, "真实关闭前章节") ~= nil
    and findText(Home.instance.content, "关书时保留的章节选段") ~= nil)
Home.instance:leave()
local originals = History.load().books[1].records
local preview_result = {}
for i in ipairs(originals) do preview_result[i] = { chapter = "原书实际章节", excerpt = "从原书补全的真实正文选段。", status = "verified" } end
check("只向原来存在的同一条缓存补充原书预览", History.storePreviews("real.epub", "id", originals, preview_result, "file-stamp"))
local enriched = History.load().books[1].records[1]
check("补全章节选段不改同步锚点和原记录对象", enriched.text == originals[1].text
    and enriched.excerpt == "从原书补全的真实正文选段。" and originals[1].excerpt == nil)
History.add("real.epub", { text_anchor = enriched.text }, enriched.source, os.time(), "id")
check("重复读取同一锚点保留已核对的选段缓存", History.load().books[1].records[1].preview_stamp == "file-stamp")
buttons = {}; Home.show(plugin)
check("首页使用原书选段而非同步短锚点", findText(Home.instance.content, "从原书补全的真实正文选段。") ~= nil)
Home.instance:leave()
local current_records = History.load().books[1].records
check("异书身份不能补入章节选段", not History.storePreviews("real.epub", "different-id", current_records, preview_result, "file-stamp"))
History.remove_record("real.epub", "id", current_records[1])
check("迟到的预览不会复活已删除记录", not History.storePreviews("real.epub", "id", { current_records[1] },
    { preview_result[1] }, "file-stamp"))

print(string.format("合计：%d 通过，%d 失败", passed, failed))
os.exit(failed == 0 and 0 or 1)
