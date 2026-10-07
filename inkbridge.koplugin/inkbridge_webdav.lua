-- inkbridge_webdav.lua 负责两类工作：
-- 1. 调用 KOReader 自带的 WebDAV 目标选择器；
-- 2. 调用 KOReader Cloud Storage 的直接上传和只读下载接口。
--
-- InkBridge 不自己保存 WebDAV 密码，也不自己实现 HTTP/WebDAV 协议。
-- 这样可以直接使用 KOReader 已经验证过的云存储代码。

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local Event = require("ui/event")
local ButtonDialog = require("ui/widget/buttondialog")
local util = require("util")

local WebDAV = {}

-- 某些 KOReader 插件方法可能是函数，也可能是带 __call 的 table。
-- 这个辅助函数同时兼容两种形式。
local function is_callable(value)
    if type(value) == "function" then return true end
    if type(value) ~= "table" then return false end
    local mt = getmetatable(value)
    return mt and mt.__call ~= nil
end

local function show(text)
    UIManager:show(InfoMessage:new{ text = text, timeout = 4 })
end

-- ── 内部错误码 → 用户看得懂的中文 ─────────────────────────────────────────
--
-- 这一层刻意与产生错误的地方分开：回调里返回的仍是稳定的英文错误码
-- （测试和排查都依赖它们），只有要显示给用户时才翻译成人话。
local ERROR_TEXT = {
    -- 记录读取/解码
    ["missing"]                     = "云端没有这条记录",
    ["empty"]                       = "记录内容为空",
    ["invalid_json"]                = "记录不是合法的 JSON",
    ["unsupported_schema"]          = "记录格式版本不受支持（可能是更新版本的插件写的）",
    ["missing_book_id"]             = "记录缺少书籍标识",
    ["invalid_book_name"]           = "记录里的书名格式不正确",
    ["invalid_percent"]             = "记录里的阅读百分比越界",
    ["invalid_xpointer"]            = "记录里的 xpointer 格式不正确",
    ["No open book"]                = "当前没有打开的书",
    ["No book is open"]             = "当前没有打开的书",
    ["KOReader could not calculate the book content hash"] =
        "无法计算这本书的内容哈希（partialMD5）",
    -- 云存储
    ["WebDAV destination is not configured"] =
        "还没有设置 WebDAV 目标（菜单 → 设置 WebDAV 目标）",
    ["KOReader WebDAV provider is unavailable"] =
        "KOReader 的 WebDAV 组件不可用（请在插件管理里确认 Cloud storage 已启用）",
    ["local upload file is missing"] = "本地暂存文件不存在",
    ["invalid remote path"]          = "云端返回的文件名不合法，已拒绝",
    ["WebDAV list failed"]           = "读取云端目录失败（网络或认证问题）",
    ["WebDAV upload failed"]         = "上传失败",
    -- 跳转规划
    ["no_document"]                  = "当前没有打开的文档",
    ["no_record"]                    = "远端记录格式不正确",
    ["no_position"]                  = "记录里没有任何位置信息",
    ["no_page_count"]                = "无法获知本书的页数",
}

-- HTTP 状态码的常见含义，直接写给用户看，省得他们去查
local HTTP_HINT = {
    ["401"] = "（认证失败：请检查 WebDAV 用户名和密码）",
    ["403"] = "（服务器拒绝访问：请检查该目录的权限）",
    ["404"] = "（云端找不到该文件）",
    ["405"] = "（服务器不允许该操作）",
    ["409"] = "（路径冲突：请确认目标目录存在）",
    ["412"] = "（文件已被其他设备改动）",
    ["423"] = "（文件被锁定）",
    ["507"] = "（云端空间不足）",
}

--- 把内部错误码翻译成给用户看的中文。
--- 认不出的错误**原样返回**，不吞掉信息（宁可难看，也不要丢失排查线索）。
function WebDAV.describe_error(err)
    if err == nil then return "未知错误" end
    local text = tostring(err)

    if ERROR_TEXT[text] then return ERROR_TEXT[text] end

    -- 某些 provider 会把内层错误包一层：remote_record_invalid_json
    local inner = text:match("^remote_record_(.+)$")
    if inner then
        return "远端记录无法解析：" .. WebDAV.describe_error(inner)
    end

    -- 带 HTTP 状态码的形式：把码单独摘出来，并附上常见原因
    local code = text:match("HTTP%s+(%d%d%d)")
    if code then
        local action = text:find("download", 1, true) and "下载失败" or "上传失败"
        return action .. "（HTTP " .. code .. "）" .. (HTTP_HINT[code] or "")
    end

    return text
end

-- provider.base 承载服务器配置（地址、用户名、密码）。provider 可能往 base 上
-- 写字段（例如 Dropbox 的 run 会写 access_token），因此不能直接把插件保存的
-- 设置表挂上去——那样这些写入会回落到 settings.reader.lua。上游 KOReader 在
-- Cloud:uploadFile / Cloud:sync 里同样使用 util.tableDeepCopy(server) 传副本。
local function provider_base(server)
    if type(util.tableDeepCopy) == "function" then
        return util.tableDeepCopy(server)
    end
    local copy = {}
    for k, v in pairs(server or {}) do copy[k] = v end
    return copy
end

-- 远端路径来自 WebDAV 服务器返回的文件名，不可信任，必须拒绝：
-- 反斜杠、控制字符（含 CR/LF/NUL/TAB）、".." 以及 "://"。
--
-- 为什么不用模式匹配（Lua pattern）：这里曾写成
--     remote_path:find("[\\\r\n\0]", 1)
-- 而这个模式是**非法的**——Lua 的模式扫描器在字符类里遇到 NUL 字节时会认为模式
-- 已经结束，于是抛出 “malformed pattern (missing ']')”。它位于 download() 的
-- 开头且无 pcall 保护，导致任何一次下载都会直接报错。
-- 教训：NUL 在模式里必须写 %z，且字符类里的 NUL 极难目测。这里改用逐字节检查，
-- 彻底不依赖模式转义语义，行为可被单元测试完全覆盖。
local function is_safe_remote_path(path)
    if type(path) ~= "string" or path == "" then return false end
    if path:find("..", 1, true) then return false end
    if path:find("://", 1, true) then return false end
    for i = 1, #path do
        local byte = path:byte(i)
        if byte < 32 or byte == 127 or byte == 92 then return false end
    end
    return true
end

-- 判断一个远端文件名是不是本书的 InkBridge 记录。
--
-- 这里必须特别小心 Lua 的模式语义：**Lua 模式没有“或”运算符**。
-- 旧实现写成
--     item.text:match("^.+" .. suffix .. "(txt|json)$")
-- 原意是“扩展名是 txt 或 json”，但 `|` 在 Lua 模式里只是普通字符，整个模式
-- 实际要求在文件名结尾出现字面量 "txt|json"，因此**永远无法命中**：
-- list_history 永远返回空列表，下载流程找不到任何历史记录。
-- 现在改为先取出扩展名逐个比较，再用字面量比较主干，彻底绕开模式语义。
local function is_inkbridge_record(name, prefix)
    if type(name) ~= "string" or type(prefix) ~= "string" or prefix == "" then
        return false
    end
    local stem, ext = name:match("^(.*)%.([%a%d]+)$")
    if not stem or (ext ~= "txt" and ext ~= "json") then return false end
    -- 新格式：<书名>-<时间>-<设备>.<短哈希>.InkBridge.txt
    local new_suffix = "." .. prefix .. ".InkBridge"
    if stem:sub(-#new_suffix) == new_suffix then return true end
    -- 旧格式（0.1.x）：InkBridge-<短哈希>-....txt
    -- 短哈希理论上来自 partialMD5（十六进制），但仍做转义以防出现模式元字符。
    local escaped = prefix:gsub("([^%w])", "%%%1")
    return stem:find("^InkBridge%-" .. escaped .. "%-", 1) ~= nil
end

-- 打开 KOReader 的 WebDAV 目标选择界面，并保存用户选中的 server table。
-- 只配了一台云服务器时,跳过"选服务器"那一步,直接进它的目录浏览。
--
-- 为什么值得做:只有一台服务器时,那个列表里只有一项 —— 点进去等于白点一次。
--
-- 依据:KOReader 自己的 CloudStorage:show() 就是这么跳过根列表的
-- (plugins/cloudstorage.koplugin/cloudstorage.lua:154-162,借 default_server)。
-- 这里**刻意不碰 default_server** —— 那是用户的设置,改了会影响他以后的行为。
--
-- "选目录"这一步省不掉:云浏览器里必须用户自己长按目录(cloudstorage.lua:241-245)。
--
-- 返回 true 表示已接管(进了目录浏览);false 表示调用方照旧走"列服务器"流程。
-- **任何一步不顺都返回 false** —— 这条捷径只该是优化,不该成为新的故障点。
function WebDAV.start_dir_pick_on_single_server(plugin, on_saved)
    local ok_all, handled = pcall(function()
        local ui = plugin and plugin.ui
        local manager = ui and ui.cloudstorage
        if not manager or not is_callable(manager.openCloudServer) then return false end

        -- 刷新 manager.servers(它平时只在云存储界面被打开时才加载)
        if is_callable(manager.loadSettings) then
            pcall(function() manager:loadSettings() end)
        end
        local servers = manager.servers
        if type(servers) ~= "table" or #servers ~= 1 then return false end
        local url = servers[1] and servers[1].url
        if type(url) ~= "string" then return false end

        manager.server_idx = 1
        -- 用 caller_choose_folder_callback 字段而不是 openCloudServer 的第 2 个参数:
        -- 它是在**异步回调里**才被读的(cloudstorage.lua:169),传参有可能在那个时序下丢失;
        -- 写字段则确定生效。
        manager.caller_choose_folder_callback = function(server)
            -- 用完立刻清掉:否则以后用户从文件管理器正常浏览云盘、长按目录时,
            -- 会再次触发我们这个回调,弹出一句莫名其妙的"墨桥…已保存"。
            manager.caller_choose_folder_callback = nil
            on_saved(server)
        end
        manager:openCloudServer(url, nil, true)
        return true
    end)
    if not ok_all then return false end
    return handled == true
end

function WebDAV.pick_server(plugin)
    local function save(server)
        plugin.server = server
        G_reader_settings:saveSetting("inkbridge_webdav_server", server)
        show("墨桥：云同步目标已保存。")
    end

    -- 捷径:只配了一台服务器 → 直接进它的目录浏览
    if WebDAV.start_dir_pick_on_single_server(plugin, save) then return end

    local ui = plugin.ui
    if ui and ui.cloudstorage and is_callable(ui.cloudstorage.onShowCloudStorageList) then
        ui.cloudstorage:onShowCloudStorageList(save)
        return
    end
    local ok, SyncService = pcall(require, "apps/cloudstorage/syncservice")
    if not ok or not SyncService then
        -- 现行 KOReader 的云存储就是 plugins/cloudstorage.koplugin 自己，它会把自己
        -- 注册为 ui.cloudstorage（见其 main.lua 的 Cloud:init 与 PluginLoader 的
        -- registerModule）。更早的版本把云存储放在 frontend/apps/cloudstorage/，
        -- 那条路径和对应的 SyncService 组件都已不存在 —— 这里没有可用的兜底，
        -- 直接给出可执行的提示，而不是让用户对着“picker unavailable”猜。
        show("墨桥：找不到 KOReader 的云存储功能。请在「插件管理」里启用 Cloud storage 后重试。")
        return
    end
    local picker = SyncService:new{}
    picker.onConfirm = save
    UIManager:show(picker)
end

-- 直接上传一个已经准备好的历史记录文件。
--
-- 这里刻意使用 Cloud Storage 的 uploadFile，而不是 SyncService：
-- SyncService 会先 GET 同名远端文件，首次上传时 WebDAV 的 404 响应
-- 可能被保存为 .temp，随后被错误地当成 JSON 解析，导致真正的 PUT
-- 永远不会执行。Cloud Storage 的成功回调只在 provider 返回 2xx 后触发。
function WebDAV.upload(plugin, staged_path, callback)
    callback = callback or function() end
    local server = plugin.server
    if type(server) ~= "table" or server.type ~= "webdav" then
        callback(false, "WebDAV destination is not configured")
        return
    end

    if type(staged_path) ~= "string" or staged_path == "" then
        callback(false, "local upload file is missing")
        return
    end
    local file = io.open(staged_path, "rb")
    if not file then
        callback(false, "local upload file is missing")
        return
    end
    file:close()

    local ui = plugin.ui
    local manager = ui and ui.cloudstorage
    local providers = manager and manager.providers
    -- KOReader releases before the Cloud Storage upload helper exposed
    -- `manager:uploadFile`, while still providing the WebDAV provider API.
    -- Use that API directly as a compatibility path.
    local provider = providers and providers[server.type]
    if not provider or type(provider.run) ~= "function"
            or type(provider.uploadFile) ~= "function" then
        callback(false, "KOReader WebDAV provider is unavailable")
        return
    end

    -- Cloud:uploadFile 通常只回调一次；这个保护也覆盖了异常 provider
    -- 或网络重试实现重复回调的情况，避免界面显示相互矛盾的结果。
    local finished = false
    local function finish(ok, err)
        if finished then return end
        finished = true
        callback(ok, err)
    end

    local call_ok, call_err = pcall(function()
        if manager and type(manager.uploadFile) == "function" then
            manager:uploadFile(server, staged_path,
                function() finish(true) end,
                function() finish(false, "WebDAV upload failed") end)
            return
        end

        -- 兼容路径：base 由我们自己设置，因此也由我们恢复（与 download /
        -- list_history 保持一致）；用副本而非设置表本身，理由见 provider_base。
        local old_base = provider.base
        provider.base = provider_base(server)
        provider.run(function()
            local code = provider.uploadFile(server.url, staged_path, nil)
            provider.base = old_base
            if type(code) == "number" and code >= 200 and code < 300 then
                finish(true)
            else
                finish(false, "WebDAV upload failed: HTTP " .. tostring(code))
            end
        end)
    end)
    if not call_ok then
        finish(false, tostring(call_err))
    end
end

-- 只读下载远端记录。
--
-- 不能把“下载”也交给 SyncService.sync：KOReader 的这个接口虽然会先
-- 下载远端文件，但 merge 回调返回 true 后一定会再次 PUT local_path。
-- 因此下载动作使用已经加载的 WebDAV provider 直接 GET，保证不会修改
-- WebDAV 上的记录。
function WebDAV.download(plugin, remote_path, callback)
    local server = plugin.server
    if type(server) ~= "table" or server.type ~= "webdav" then
        callback(false, nil, "WebDAV destination is not configured")
        return
    end

    local ui = plugin.ui
    local manager = ui and ui.cloudstorage
    local providers = manager and manager.providers
    local provider = providers and providers.webdav
    if not provider or type(provider.run) ~= "function"
            or type(provider.downloadFile) ~= "function" then
        callback(false, nil, "KOReader WebDAV provider is unavailable")
        return
    end

    if not is_safe_remote_path(remote_path) then
        callback(false, nil, "invalid remote path")
        return
    end
    -- 本地临时文件由插件决定（纯 ASCII 名，见 main.lua 的 _download_staging_path）
    local path = plugin:_download_staging_path()
    local old_base = provider.base
    -- WebDAV provider 的公开方法通过 base 读取地址、用户名和密码。
    -- 临时使用已保存 server 的副本，完成后恢复原对象，避免影响云存储界面。
    provider.base = provider_base(server)
    local finished = false
    local function finish(ok, remote, err)
        if finished then return end
        finished = true
        provider.base = old_base
        os.remove(path)
        callback(ok, remote, err)
    end
    local function request()
        local ok, code_or_err = pcall(function()
            local code = provider.downloadFile(remote_path, path)
            if code == 200 then
                local State = require("inkbridge_state")
                local remote, err = State.read_file(path)
                if not remote then
                    finish(false, nil, "remote_record_" .. tostring(err))
                else
                    finish(true, remote, nil)
                end
            elseif code == 404 then
                finish(true, nil, "missing")
            else
                finish(false, nil, "WebDAV download failed: HTTP " .. tostring(code))
            end
        end)
        if not ok then finish(false, nil, tostring(code_or_err)) end
    end
    local dispatched, err = pcall(provider.run, request)
    if not dispatched then
        finish(false, nil, tostring(err))
    end
end

-- 列出当前书籍的历史记录。
-- 记录文件名以书名开头，但书名可能包含空格或中文；这里依赖 WebDAV
-- provider 的 listFolder，而不是自行拼接目录或做全盘搜索。
function WebDAV.list_history(plugin, prefix, callback)
    local server = plugin.server
    if type(server) ~= "table" or server.type ~= "webdav" then
        callback(false, nil, "WebDAV destination is not configured")
        return
    end
    local ui = plugin.ui
    local manager = ui and ui.cloudstorage
    local providers = manager and manager.providers
    local provider = providers and providers.webdav
    if not provider or type(provider.run) ~= "function"
            or type(provider.listFolder) ~= "function" then
        callback(false, nil, "KOReader WebDAV provider is unavailable")
        return
    end
    local old_base = provider.base
    provider.base = provider_base(server)
    local finished = false
    local function finish(ok, entries, err)
        if finished then return end
        finished = true
        provider.base = old_base
        callback(ok, entries, err)
    end
    local function request()
        local ok, result = pcall(function()
            return provider.listFolder(server.url or "", true)
        end)
        if not ok then finish(false, nil, tostring(result)); return end
        -- KOReader 的 listFolder 在网络、认证或 HTTP 错误时可能返回 nil。
        -- nil 不能等同于空列表，否则会误报“没有历史记录”，掩盖真正的同步失败。
        if type(result) ~= "table" then
            finish(false, nil, "WebDAV list failed")
            return
        end
        local entries = {}
        for _, item in ipairs(result) do
            -- 同时识别旧格式 InkBridge-<hash>-... 和新格式
            -- ...<hash>.InkBridge.txt，升级后不会丢失历史记录。
            if item.is_file and is_inkbridge_record(item.text, prefix) then
                table.insert(entries, item)
            end
        end
        table.sort(entries, function(a, b)
            local am = tonumber(a.modification) or 0
            local bm = tonumber(b.modification) or 0
            if am == bm then return a.text > b.text end
            return am > bm
        end)
        finish(true, entries, nil)
    end
    local dispatched, err = pcall(provider.run, request)
    if not dispatched then finish(false, nil, tostring(err)) end
end

-- 显示可读的历史记录列表。只显示最近三条，具体跳转仍由用户确认。
function WebDAV.choose_history(plugin, entries, on_select)
    local buttons = {}
    for i, item in ipairs(entries) do
        if i > 3 then break end
        table.insert(buttons, {
            { text = item.text, callback = function()
                UIManager:close(plugin._history_dialog)
                on_select(item)
            end },
        })
    end
    if #buttons == 0 then
        show("墨桥：没有找到这本书的历史记录。")
        return
    end
    table.insert(buttons, {
        { text = "取消", callback = function() UIManager:close(plugin._history_dialog) end },
    })
    plugin._history_dialog = ButtonDialog:new{
        title = "选择远端历史记录（最近三次）",
        buttons = buttons,
    }
    UIManager:show(plugin._history_dialog)
end

-- 规划一次跳转：按“可靠程度从高到低”挑选定位方式。
--
-- 为什么需要分级：页码只在本机排版下有意义（两台设备可能是 8922 页 vs 8689 页），
-- 而记录里的 percent 来自 ReaderFooter:getBookProgress()，本质是 pageno/pages，
-- 同样是“页序比例”，一样依赖排版。可用的锚点按可靠性排序：
--
--   1) xpointer 能在本机解析    -> 内容锚点，最精确
--   2) text_anchor + 全文搜索   -> 与 DOM 索引、spine 切分方式都无关，
--                                  能扛住 xpointer 失效（跨设备最常见的情况）
--   3) percent 页数换算          -> 最后的兜底（最不精确）
--   固定版式（PDF/CBZ）的页码由内容决定、与设备无关，直接用记录里的页码。
--
-- 重要：**无效 xpointer 绝不能直接交给 crengine**。gotoXPointer 的实现是
--   createXPointer(...) -> goToBookmark(xp) -> SetPos(xp.toPoint().y)
-- 解析失败时 xp 为 null、y 为 0，结果会直接跳到书首。所以第 1 步必须先做
-- isXPointerInDocument 校验（它等价于 !createXPointer().isNull()）。
-- 也不能拿 getPageFromXPointer 当判据：它在解析失败时静默返回 1。
--
-- 返回 plan 表，或 nil + 原因：
--   { method = "xpointer", xpointer = ... }
--   { method = "text",     xpointer = ..., hits = n }
--   { method = "page",     page = n }        固定版式
--   { method = "percent",  page = n }        兜底
function WebDAV._plan_jump(plugin, remote)
    local ui = plugin and plugin.ui
    if not ui or not ui.document then return nil, "no_document" end
    if type(remote) ~= "table" then return nil, "no_record" end
    local doc = ui.document

    if doc.info and doc.info.has_pages then
        -- 固定版式：页码与设备无关
        local page = tonumber(remote.page)
        if page and page > 0 then return { method = "page", page = page } end
    elseif ui.rolling then
        -- 1) xpointer（先校验可解析性）
        local xp = remote.xpointer
        if type(xp) == "string" and xp ~= ""
                and type(doc.isXPointerInDocument) == "function" then
            local ok, found = pcall(doc.isXPointerInDocument, doc, xp)
            if ok and found then
                return { method = "xpointer", xpointer = xp }
            end
        end

        -- 2) 文本锚点：全文搜索，命中里挑最接近 pos_percent 的一个
        --    （锚点可能重复，例如“他说。”这类短句，必须用内容比例消歧）
        local anchor = remote.text_anchor
        if type(anchor) == "string" and anchor ~= ""
                and type(doc.findAllText) == "function" then
            -- 全文搜索跑在 UI 线程上，大书可能要一两秒，期间界面是冻住的。
            -- 照 KOReader 自己搜索模块（readersearch.lua）的做法先吞掉输入，
            -- 避免用户连点造成动作重复；搜索结束后无论成败都恢复。
            local ok_dev, Device = pcall(require, "device")
            local can_ignore_input = ok_dev and Device
                and type(Device.setIgnoreInput) == "function"
            if can_ignore_input then
                pcall(Device.setIgnoreInput, Device, true)
            end
            local ok, hits = pcall(doc.findAllText, doc, anchor, true, 0, 8, false)
            if can_ignore_input then
                pcall(Device.setIgnoreInput, Device, false)
            end
            if ok and type(hits) == "table" and #hits > 0 then
                local height = doc.info and tonumber(doc.info.doc_height) or nil
                local ratio = tonumber(remote.pos_percent)
                local expected
                if ratio and height and height > 0
                        and type(doc.getPosFromXPointer) == "function" then
                    expected = math.max(0, math.min(1, ratio)) * height
                end
                local pick, pick_dist
                for i = 1, #hits do
                    local hit = hits[i]
                    if type(hit) == "table" and type(hit.start) == "string" then
                        if not expected then pick = hit; break end
                        local ok_pos, pos = pcall(doc.getPosFromXPointer, doc, hit.start)
                        if ok_pos and tonumber(pos) then
                            local dist = math.abs(tonumber(pos) - expected)
                            if not pick_dist or dist < pick_dist then
                                pick, pick_dist = hit, dist
                            end
                        elseif not pick then
                            pick = hit
                        end
                    end
                end
                -- findAllText 会顺带把命中高亮出来，用完清掉
                if type(doc.clearSelection) == "function" then
                    pcall(doc.clearSelection, doc)
                end
                if pick then
                    return { method = "text", xpointer = pick.start, hits = #hits }
                end
            end
        end
    end

    -- 3) 页数比例兜底
    local percent = tonumber(remote.percent)
    if not percent then return nil, "no_position" end
    if type(doc.getPageCount) == "function" then
        local ok, total = pcall(doc.getPageCount, doc)
        total = ok and tonumber(total) or nil
        if total and total > 0 then
            return { method = "percent", page = math.max(1, math.floor(percent * total) + 1) }
        end
    end
    return nil, "no_page_count"
end

-- 远端位置较新时，询问用户是否跳转，并说明本机将用哪种方式定位
-- （把定位方式显示出来，是为了让“跳得准不准”这件事可诊断）。
-- 真正发出跳转事件。
-- 阅读器模块通过 ReaderUI:handleEvent 接收跳转事件；直接发给当前 ui
-- 比广播给所有窗口更可靠，尤其是在确认框关闭后的回调里。
function WebDAV._do_jump(ui, plan)
    if plan.method == "xpointer" or plan.method == "text" then
        ui:handleEvent(Event:new("GotoXPointer", plan.xpointer, plan.xpointer))
    elseif plan.method == "page" or plan.method == "percent" then
        ui:handleEvent(Event:new("GotoPage", plan.page))
    end
end

function WebDAV.confirm_jump(plugin, remote, opts)
    local ui = plugin.ui
    if not ui or not ui.document then return end

    local plan, reason = WebDAV._plan_jump(plugin, remote)
    if not plan then
        -- already_confirmed 时调用方只想要"跳过去",失败也必须说出来
        if opts and opts.already_confirmed then
            show("墨桥：无法在本机文档上还原云端位置 —— " .. WebDAV.describe_error(reason))
        else
            show("墨桥：无法在本机文档上还原远端位置 —— " .. WebDAV.describe_error(reason))
        end
        return
    end

    -- 调用方已经问过用户了(例如"打开书时自动核对"):直接跳,不再问第二遍。
    if opts and opts.already_confirmed then
        WebDAV._do_jump(ui, plan)
        show("墨桥：已跳转到云端位置。")
        return
    end

    -- 确认框遵守一条规矩:**只在"需要你知道"的时候才多一行**。
    -- 原先它把"本机定位方式""命中几处"这类内部细节无条件摊开,五行起步,像调试输出
    -- (实测用户反馈"内容太冗余")。现在:
    --   * 进度、是否内容比例、方向提示 —— 并进第一行的括号里;
    --   * 定位方式**只在不是精确方式时**才显示(降级才是"跳得准不准"的关键);
    --   * 命中数**只在多命中**时才显示(那才有歧义)。
    local shown_pct = tonumber(remote.percent)
    local notes = {}
    if not shown_pct then
        -- 静读天下那条路进来的是 pos_percent(内容比例,≈62%),没有 percent(页数比例)。
        -- 以前这里只读 percent,于是永远显示「0.00%」—— 实测踩到。
        shown_pct = tonumber(remote.pos_percent)
        table.insert(notes, "内容比例")
    end
    if type(remote.dir_note) == "string" and remote.dir_note ~= "" then
        table.insert(notes, remote.dir_note)
    end

    local lines = {
        string.format("远端阅读位置：%.2f%%%s", (shown_pct or 0) * 100,
                      #notes > 0 and ("（" .. table.concat(notes, "；") .. "）") or ""),
    }
    if remote.page and remote.total_pages then
        table.insert(lines, string.format("远端设备：第 %s / %s 页",
            tostring(remote.page), tostring(remote.total_pages)))
    end

    local method_label = {
        xpointer = "xpointer 内容锚点（精确）",
        text     = "文本锚点搜索（精确）",
        page     = "页码（固定版式）",
        percent  = "页数比例换算（近似）",
    }
    if plan.method ~= "xpointer" and plan.method ~= "text" then
        table.insert(lines, "本机定位方式：" .. (method_label[plan.method] or tostring(plan.method)))
        if type(remote.xpointer) == "string" and remote.xpointer ~= "" then
            table.insert(lines, "（远端 xpointer 在本机无法解析，已降级）")
        end
    elseif plan.method == "text" and plan.hits and plan.hits > 1 then
        table.insert(lines, string.format("（锚点命中 %d 处，取最接近的）", plan.hits))
    end
    table.insert(lines, "跳转过去吗？")

    UIManager:show(ConfirmBox:new{
        text = table.concat(lines, "\n"),
        ok_text = "跳转",
        cancel_text = "留在原处",
        ok_callback = function()
            WebDAV._do_jump(ui, plan)
        end,
    })
end

-- ── 「远端有没有比我新」的判定(纯函数,便于测试)─────────────────────────
--
-- 为什么用"服务器时间"而不是记录里的时间戳:
--   * KOReader 记录里的 updated_at 是**设备本地时钟**,两台机器差几分钟很正常;
--   * 而列表项自带的 modification 来自服务器(PROPFIND 的 getlastmodified,
--     provider 已经用 datetime.stringRFC1123ToSeconds 转成 Unix 秒),
--     静读天下 .po 的 Last-Modified 响应头也是**同一台服务器**给的 ——
--     两者单位一致、基准一致,可以直接比较。

-- 从候选里挑出"比本机上次看到的更新"的那些,按时间从新到旧。
--
--   candidates = { { source = "kpw6", time = 1699999999, ... }, ... }
--   seen       = { ["kpw6"] = 1699900000, ... }   -- 本机上次同步后记下的时间
--
-- **没有 seen 的候选一律跳过**:本机从没同步过这本书时不打扰用户
-- (第一次同步请用菜单里的「下载阅读进度」)。
function WebDAV.select_updates(candidates, seen)
    local out = {}
    for _, c in ipairs(candidates or {}) do
        local key = tostring(c and c.source or "")
        local t   = tonumber(c and c.time)
        local prev = tonumber(seen and seen[key])
        if key ~= "" and t and prev and t > prev then
            out[#out + 1] = c
        end
    end
    table.sort(out, function(a, b) return (tonumber(a.time) or 0) > (tonumber(b.time) or 0) end)
    return out
end

-- Unix 秒差 → 人话("刚刚" / "3 分钟前" / "2 小时前" / "3 天前")。
function WebDAV.human_age(seconds)
    local s = tonumber(seconds)
    if not s or s < 0 then return "未知" end
    if s < 60 then return "刚刚" end
    local m = math.floor(s / 60)
    if m < 60 then return tostring(m) .. " 分钟前" end
    local h = math.floor(m / 60)
    if h < 24 then return tostring(h) .. " 小时前" end
    return tostring(math.floor(h / 24)) .. " 天前"
end

-- 导出为测试钩子（下划线前缀表示非稳定接口，与 Syncery 的写法一致）。
WebDAV._is_safe_remote_path  = is_safe_remote_path
WebDAV._is_inkbridge_record  = is_inkbridge_record

return WebDAV
