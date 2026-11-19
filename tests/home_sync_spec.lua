-- 首页补全必须纯读；不打开书籍，不改云端，不按短哈希混入异书。
package.path = "inkbridge.koplugin/?.lua;" .. package.path
local passed, failed = 0, 0
local function check(label, ok)
    if ok then passed = passed + 1 else failed = failed + 1; print("FAIL " .. label) end
end
local values, queue, timers, online, calls, results
local lists, payloads, moons, positions, identity
G_reader_settings = {
    readSetting = function(_, k) return values[k] end,
    saveSetting = function(_, k, v) values[k] = v end,
}
local UI = {
    nextTick = function(_, fn) queue[#queue + 1] = fn end,
    scheduleIn = function(_, _, fn) timers[fn] = true end,
    unschedule = function(_, fn) timers[fn] = nil end,
}
package.preload["ui/uimanager"] = function() return UI end
package.preload["ui/network/manager"] = function() return { isConnected = function() return online end } end
package.preload.inkbridge_state = function() return { book_id = function(file)
    if identity == "throw" then error("bad file") end
    if identity == "missing" then return nil end
    return file .. "-full-hash"
end } end
local downloader
package.preload.inkbridge_webdav = function() return {
    list_history = function(plugin, prefix, cb)
        calls.list = calls.list + 1
        calls.prefixes[#calls.prefixes + 1] = prefix
        if lists == "throw" then error("provider error") end
        cb(lists ~= false, lists or nil)
    end,
    download = function(plugin, path, cb)
        calls.download = calls.download + 1
        if downloader then return downloader(path, cb) end
        cb(payloads[path] ~= false, payloads[path])
    end,
    upload = function() error("首页绝不允许上传") end,
    delete_file = function() error("首页绝不允许删除") end,
    confirm_jump = function() error("首页刷新绝不允许跳转") end,
} end
package.preload.inkbridge_moon = function() return { parse = function(body) return body ~= "bad" and { raw = body } or nil end } end
package.preload.inkbridge_moonsync = function() return {
    fetch_po = function(proxy)
        calls.moon = calls.moon + 1
        check("Moon独立上下文不借用文件管理器", proxy.ui ~= calls.real_ui and proxy.ui.document.file ~= nil)
        return moons
    end,
    position_from_po = function(file, po)
        calls.map = calls.map + 1
        return positions
    end,
} end
local History = require("inkbridge_home_history")
local Sync = require("inkbridge_home_sync")
local plugin, books
local function reset()
    values, queue, timers, results = {}, {}, {}, {}
    online, lists, payloads, moons, positions, identity = true, {}, {}, nil, nil, nil
    calls = { list = 0, download = 0, moon = 0, map = 0, prefixes = {} }
    downloader = nil
    plugin = { server = { type = "webdav" }, ui = { untouched = true } }
    calls.real_ui = plugin.ui
    books = { { file = "book-a", title = "A" } }
end
local function refresh()
    Sync.refresh(plugin, books, function(ok, message) results[#results + 1] = { ok = ok, message = message } end)
end
local function drain()
    local n = 0
    while #queue > 0 do
        n = n + 1; assert(n < 150, "刷新不能无限循环")
        table.remove(queue, 1)()
    end
end
local function record(text, id, time)
    return { text_anchor = text, book_id = id or "book-a-full-hash", updated_at = time or 100, device_label = "Kindle" }
end
reset(); plugin.server = nil; refresh()
check("无配置不联网", calls.list == 0 and #results == 1 and not results[1].ok)
reset(); online = false; refresh()
check("离线不联网", calls.list == 0 and #results == 1 and not results[1].ok)
check("离线不生成伪历史", #History.load().books == 0)
reset(); refresh()
check("延迟读取不阻塞页面构建", calls.list == 0 and #queue == 1)
check("刷新期间有防重入锁", Sync.running == true)
refresh()
check("重复点击不会并行读取", #results == 1 and not results[1].ok and #queue == 1)
drain()
check("空云端仍明确完成", #results == 2 and results[2].ok)
check("完成取消超时和锁", next(timers) == nil and not Sync.running)
check("空数据不伪造正文", #History.load().books == 0)

reset(); lists = { { url = "same-prefix-wrong-book" }, { url = "valid" }, { url = "empty" } }
payloads["same-prefix-wrong-book"] = record("异书正文", "book-a-other-full-hash")
payloads.valid = record("真实云端墨桥正文")
payloads.empty = record(nil)
refresh(); drain()
local r = History.load().books[1].records
check("完整书籍身份拒绝短哈希碰撞", #r == 1 and r[1].text == "真实云端墨桥正文")
check("保留远端设备来源", r[1].source == "墨桥 · Kindle")
check("保留原时间而非下载时间", r[1].time == 100)
check("原文件管理器未伪装打开文档", plugin.ui.document == nil and plugin.ui.untouched)
check("通过短哈希筛选请求", calls.prefixes[1] == "book-a-f")

reset(); lists = { { url = "dup1" }, { url = "dup2" } }
payloads.dup1, payloads.dup2 = record("相同正文"), record("相同正文")
refresh(); drain()
check("重复载荷不会凑够三条", #History.load().books[1].records == 1)

reset()
for i = 1, 10 do lists[i] = { url = "r" .. i }; payloads["r" .. i] = record("正文" .. i, nil, i) end
refresh(); drain()
check("单书最多下载六份有界载荷", calls.download == 6)
check("首页缓存依然每书最多三条", #History.load().books[1].records == 3)

reset(); books = {}
for i = 1, 5 do books[i] = { file = "b" .. i, title = "书" .. i } end
refresh(); drain()
check("只读取最近三本", calls.list == 3 and calls.moon == 3)

reset(); moons = "po"; positions = { snippet = "静读天下源坐标还原正文", character_percent = 0.5, anchor_note = "短段退回前段" }
refresh(); drain()
r = History.load().books[1].records[1]
check("无墨桥历史也读Moon当前位置", r.text == positions.snippet and calls.moon == 1)
check("Moon原时间未知只记录读取时间", r.time == nil and r.observed_at ~= nil)
check("Moon比例保留", r.percent == 0.5)
check("短段回退说明保留", r.note == "短段退回前段")
check("明确Moon来源", r.source == "静读天下")

reset(); lists = false; moons = "po"; positions = { snippet = "墨桥列目录失败但Moon仍可读" }
refresh(); drain()
check("部分失败不丢另一来源", History.load().books[1].records[1].text == positions.snippet)
check("部分失败明确提示", results[1].message:find("未取到", 1, true) ~= nil)

reset(); lists = "throw"; refresh(); drain()
check("provider异常解锁并报告失败", not Sync.running and #results == 1 and not results[1].ok)
reset(); identity = "missing"; refresh(); drain()
check("无法核对书籍不读取该书", calls.list == 0 and calls.moon == 0)
reset(); identity = "throw"; refresh(); drain()
check("身份计算异常不让首页崩溃", #results == 1 and not results[1].ok and not Sync.running)

reset(); refresh(); online = false; drain()
check("中途断网不会卡锁", calls.list == 0 and not Sync.running and not results[1].ok)
reset(); lists = { { url = "late" } }
local late
downloader = function(_, cb) late = cb end
refresh(); drain()
check("挂起时等待回调", Sync.running and late ~= nil)
local timeout = next(timers); timeout()
check("缺失provider回调可超时退出", not Sync.running and #results == 1 and not results[1].ok)
late(true, record("超时后的过期正文")); drain()
check("超时后的迟到回调不写缓存", #History.load().books == 0 and #results == 1)

reset(); History.add("book-a", record("保留原缓存"), "墨桥", 100, "book-a-full-hash")
lists = { { url = "failure" } }; payloads.failure = false
refresh(); drain()
check("读取失败不清空既有缓存", History.load().books[1].records[1].text == "保留原缓存")
print(string.format("合计：%d 通过，%d 失败", passed, failed))
os.exit(failed == 0 and 0 or 1)
