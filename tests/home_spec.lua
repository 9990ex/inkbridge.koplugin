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
    { file = "file1", dim = true }, { file = "file30" }, { file = "file30" },
    { file = "absent" }, { file = "new-book" }, { file = "file29" }, { file = "file28" },
}, function(f) return f ~= "absent" end)
check("三本去重并排除丢失", #recent == 3)
check("按阅读顺序而非同步顺序", recent[1].file == "file30" and recent[2].file == "new-book")
check("无历史不伪造片段", #recent[2].records == 0)
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
local close_refresh, full_dirty
local registered_zones
local Widget = {}
function Widget:extend(proto) return setmetatable(proto or {}, { __index = self }) end
function Widget:new(o)
    o = setmetatable(o or {}, { __index = self })
    if o.init then o:init() end
    return o
end
function Widget:getSize() return { w = self.width or 400, h = 35 } end
function Widget:setText(s) self.text = s end
function Widget:getScrollbarWidth(width) return 3 * width end
function Widget:registerTouchZones(zones) registered_zones = zones end
function Widget:scrollToRatio(_, y)
    -- 保留原生 API 的裁剪高度前提，不能再用无条件成功的桩掩盖 nil 算术。
    self._scroll_offset_y = math.max(0, y * (self._max_scroll_offset_y + self._crop_h)
        - math.floor(self._crop_h / 2 + 0.5))
    self.last_ratio = y
end
local UI = {
    show = function(_, w) shown[#shown + 1] = w end,
    close = function(_, w, refresh) close_refresh = refresh; if w.onCloseWidget then w:onCloseWidget() end end,
    nextTick = function(_, fn) next_ticks[#next_ticks + 1] = fn end,
    setDirty = function(_, _, refresh, region) if refresh == "ui" and region == nil then full_dirty = true end end,
    unschedule = function(_, fn) scheduled[fn] = nil end,
    scheduleIn = function(_, delay, fn) scheduled[fn] = delay end,
}
package.preload["ui/uimanager"] = function() return UI end
for _, name in ipairs({
    "ui/widget/container/inputcontainer", "ui/widget/container/framecontainer", "ui/widget/verticalgroup",
    "ui/widget/verticalspan", "ui/widget/textwidget", "ui/widget/textboxwidget",
    "ui/widget/container/scrollablecontainer", "ui/gesturerange", "ui/geometry",
    "ui/widget/infomessage", "ui/widget/buttondialog", "ui/widget/touchmenu",
    "ui/widget/horizontalgroup", "ui/widget/horizontalspan", "ui/widget/linewidget",
    "ui/widget/container/centercontainer", "ui/widget/container/leftcontainer", "ui/widget/textviewer",
}) do package.preload[name] = function() return Widget end end
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
package.preload["readhistory"] = function() return { hist = {
    { file = "real.epub" }, { file = "new.epub" }, { file = "third.epub" },
} } end
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
    for _, b in ipairs(buttons) do if b.text == label then return b end end
end
local function findText(widget, value)
    if widget.text == value then return widget end
    for _, child in ipairs(widget) do
        local found = findText(child, value)
        if found then return found end
    end
end
check("书刊首页优先显示已有元数据标题", findText(page[1], "主书名") ~= nil)
check("首页元数据读取禁止打开文档", metadata_readonly)
check("作者独立排版", findText(page[1], "作者甲 / 作者乙") ~= nil)
check("最新摘录留在首页", findText(page.cropping_widget[1], "真实采集的正文片段") ~= nil)
check("较旧记录默认折叠", findText(page.cropping_widget[1], "较早的同步正文") == nil
    and findText(page.cropping_widget[1], "更早的同步正文") == nil)
check("第三本仍展示最新摘录", findText(page.cropping_widget[1], "第三本书的最新摘录") ~= nil)
check("主次标题有字号层级", findText(page[1], "主书名").face.size > findText(page[1], "third").face.size)
check("主摘录限制三行并保留溢出提示", findText(page[1], "真实采集的正文片段").height_overflow_show_ellipsis == true)
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
local viewport = page.cropping_widget
check("正文为原生竖向滚动条预留宽度", findText(page[1], "主书名").width
    + viewport:getScrollbarWidth(viewport.scroll_bar_width) <= viewport.dimen.w)
check("未绘制前点击首页不崩溃", pcall(button("首页").callback))
check("未初始化不调用滚动", viewport.last_ratio == nil)
viewport._is_scrollable = false
viewport._max_scroll_offset_y = 0
check("不足一屏反复点首页不崩溃", pcall(function()
    for _ = 1, 3 do button("首页").callback() end
end))
check("不足一屏不调用滚动", viewport.last_ratio == nil)
viewport._is_scrollable = true
check("裁剪高度缺失安全跳过", pcall(button("首页").callback) and viewport.last_ratio == nil)
viewport._crop_h = 500
viewport._max_scroll_offset_y = 1000
viewport._scroll_offset_y = 400
button("首页").callback()
check("可滚动首页导航回到顶部", viewport.last_ratio == 0 and viewport._scroll_offset_y == 0)
button("设置").callback()
check("设置打开暂停时钟", scheduled[page.tick] == nil)
UI:close(shown[#shown])
check("关闭设置恢复时钟", scheduled[page.tick] ~= nil)
button("设置").callback()
shown[#shown].buttons[2][1].callback()
check("同步设置使用原生动态子菜单", shown[#shown].tab_item_table[1].icon == "appbar.settings")
check("设置跳转停止首页时钟", Home.instance == nil and scheduled[page.tick] == nil)
buttons = {}
Home.show(plugin)
page = Home.instance

-- 点击真实正文：先打开正确书籍，再走唯一锚点确认，不用比例兜底。
local content = page.cropping_widget[1]
local row
for _, w in ipairs(content) do
    if w.onHomeRecord and w[1][1].text == "真实采集的正文片段" then row = w; break end
end
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
check("书库按钮关闭首页", Home.instance == nil)
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
check("空书库展示阅读引导", findText(Home.instance[1], "从一本书开始") ~= nil)
button("打开书库  ›").callback()
check("空态书库入口关闭首页", Home.instance == nil)
require("readhistory").hist = hist
local get_props = plugin.ui.bookinfo.getDocProps
plugin.ui.bookinfo.getDocProps = function() error("元数据损坏") end
buttons = {}; Home.show(plugin)
check("元数据读取异常安全退回文件名", findText(Home.instance[1], "real") ~= nil)
Home.instance:leave()
plugin.ui.bookinfo.getDocProps = get_props

print(string.format("合计：%d 通过，%d 失败", passed, failed))
os.exit(failed == 0 and 0 or 1)
