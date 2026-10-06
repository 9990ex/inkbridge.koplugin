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
function WebDAV.pick_server(plugin)
    local ui = plugin.ui
    if ui and ui.cloudstorage and is_callable(ui.cloudstorage.onShowCloudStorageList) then
        ui.cloudstorage:onShowCloudStorageList(function(server)
            plugin.server = server
            G_reader_settings:saveSetting("inkbridge_webdav_server", server)
            show("InkBridge WebDAV destination saved.")
        end)
        return
    end
    local ok, SyncService = pcall(require, "apps/cloudstorage/syncservice")
    if not ok or not SyncService then
        show("KOReader cloud storage picker is unavailable.")
        return
    end
    local picker = SyncService:new{}
    picker.onConfirm = function(server)
        plugin.server = server
        G_reader_settings:saveSetting("inkbridge_webdav_server", server)
        show("InkBridge WebDAV destination saved.")
    end
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
    local path = plugin:_download_staging_path(remote_path:match("([^/]+)$") or "record")
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
        show("InkBridge: 没有找到这本书的历史记录。")
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

-- 远端位置较新时，询问用户是否跳转。
-- 优先使用 xpointer；如果 xpointer 在本机文档中不存在，则按百分比
-- 换算为页码，避免把无效 xpointer 强行交给 KOReader。
function WebDAV.confirm_jump(plugin, remote)
    local ui = plugin.ui
    if not ui or not ui.document then return end
    local text = string.format("Remote InkBridge position: %.1f%%\nJump there?", remote.percent * 100)
    UIManager:show(ConfirmBox:new{
        text = text,
        ok_text = "Jump",
        cancel_text = "Stay",
        ok_callback = function()
            -- xpointer 只适用于滚动模式。分页模式由 ReaderPaging 负责，
            -- 它不处理 GotoXPointer；此时必须使用百分比换算页码。
            if ui.rolling and remote.xpointer and ui.document.isXPointerInDocument
                    and ui.document:isXPointerInDocument(remote.xpointer) then
                -- 阅读器模块通过 ReaderUI:handleEvent 接收跳转事件。
                -- 直接发给当前 ui 比广播给所有窗口更可靠，尤其是在
                -- 确认框关闭后的 nextTick 回调中。
                ui:handleEvent(Event:new("GotoXPointer", remote.xpointer, remote.xpointer))
            elseif type(ui.document.getPageCount) == "function" then
                local ok, total = pcall(ui.document.getPageCount, ui.document)
                total = ok and tonumber(total) or nil
                if total and total > 0 then
                    local page = math.max(1, math.floor(remote.percent * total) + 1)
                    ui:handleEvent(Event:new("GotoPage", page))
                else
                    show("Remote position cannot be applied on this document.")
                end
            else
                show("Remote position cannot be applied on this document.")
            end
        end,
    })
end

-- 导出为测试钩子（下划线前缀表示非稳定接口，与 Syncery 的写法一致）。
WebDAV._is_safe_remote_path  = is_safe_remote_path
WebDAV._is_inkbridge_record  = is_inkbridge_record

return WebDAV
