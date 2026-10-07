-- main.lua 是 KOReader 加载插件时的主入口。
--
-- 这个文件负责三件事：
-- 1. 创建 InkBridge 插件对象；
-- 2. 在 KOReader 工具菜单中添加 InkBridge 菜单；
-- 3. 把“读取位置”和“WebDAV 同步”两个模块连接起来。
--
-- 具体的 JSON 读写放在 inkbridge_state.lua，WebDAV 调用放在
-- inkbridge_webdav.lua。这样主程序不会把所有代码挤在一个文件里。

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local DataStorage = require("datastorage")
local NetworkMgr = require("ui/network/manager")

local State = require("inkbridge_state")
local WebDAV = require("inkbridge_webdav")
local Meta = require("_meta")
local Moonsync = require("inkbridge_moonsync")

-- KOReader 插件通常继承 WidgetContainer。
-- extend{} 会创建一个可以接收 KOReader 生命周期事件的插件类。
local InkBridge = WidgetContainer:extend{}
InkBridge.name = "inkbridge"

local function show(text)
    UIManager:show(InfoMessage:new{ text = text, timeout = 4 })
end

-- 文件名片段清洗：替换掉文件系统不接受的字符，并做长度限制。
-- 长度必须**按字符**截断：按字节截断会把一个汉字劈成半个，
-- 生成非法 UTF-8 文件名（State._utf8_sub 是为此写的）。
local function safe_filename_component(value, fallback, max_chars)
    value = tostring(value or "")
    value = value:gsub("[\\/:*?\"<>|]", "_"):gsub("[%c]", "_")
    if value == "" then value = fallback end
    return State._utf8_sub(value, max_chars or 40)
end

-- 插件初始化：读取设备身份和已经保存的 WebDAV 配置。
function InkBridge:init()
    self.device_id = G_reader_settings:readSetting("inkbridge_device_id")
    if not self.device_id or self.device_id == "" then
        self.device_id = tostring(os.time()) .. "-" .. tostring(math.random(1000, 9999))
        G_reader_settings:saveSetting("inkbridge_device_id", self.device_id)
    end
    self.device_label = G_reader_settings:readSetting("inkbridge_device_label", "KOReader")
    self.server = G_reader_settings:readSetting("inkbridge_webdav_server")

    -- 仅仅被 PluginLoader 识别，还不会自动出现在阅读菜单里。
    -- ReaderMenu 只会调用已经注册到 registered_widgets 的插件的
    -- addToMainMenu 方法，所以这里必须显式注册自己。
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
end

-- WebDAV 同步服务要求我们先提供一个本地文件。
-- 这里创建一个只用于临时上传的目录，不放用户的原书或 Moon+ 文件。
function InkBridge:_staging_dir()
    local dir = DataStorage:getSettingsDir() .. "/inkbridge/staging"
    require("util").makePath(dir)
    return dir
end

-- 组装“当前书籍的同步上下文”。
-- 返回的 entry 会包含书籍哈希、页码、百分比和 xpointer。
function InkBridge:_book_context()
    local ui = self.ui
    if not ui or not ui.document or not ui.document.file then return nil, "No book is open" end
    local entry, err = State.read_position(ui)
    if not entry then return nil, err end
    local id, id_err = State.book_id(ui.document.file, ui)
    if not id then return nil, id_err end
    entry = State.with_identity(entry, id, self.device_id, self.device_label)
    return entry
end

-- 生成对用户友好的文件名前缀。短哈希仍保留，用来区分同名书籍；
-- 书名只来自当前打开的文件名，不上传完整本地路径。
function InkBridge:_history_prefix(entry)
    local short_id = tostring(entry.book_id):sub(1, 8)
    -- 这个短哈希必须在所有设备上一致，才能发现其他设备上传的记录。
    return short_id
end

-- 生成云端历史文件名：<书名>-MMDD-HHMMSS-<设备名>.<短哈希>.InkBridge.txt
--
-- 每一段的用途（要改名请先看完）：
--   * 书名    —— 只给人看。云端目录里有很多本书，浏览时要认得出。
--   * 时间    —— 只给人看。MMDD-HHMMSS：可读、可按字典序排、纯 ASCII。
--                旧格式是 %d%H日%M分%S秒（“日+时”），**不含月份** ——
--                9 月 6 日和 10 月 6 日会生成一模一样的名字；而且“日/分/秒”
--                三个汉字本身多占 9 字节。
--   * 设备名  —— 只给人看。同一本书在几台设备上都读过时用来区分。
--                曾经还拼上设备 ID 尾四位（如 c7t8147），那是多余的：
--                设备名已经在前面，没有任何逻辑读它。
--   * 短哈希  —— **机器用，不能去掉**。它是 partialMD5 的前 8 位，另一台设备
--                就是靠它筛出“同一本书”的历史记录（见 is_inkbridge_record）。
--   * .InkBridge.txt —— 命名空间标记 + 扩展名。扩展名必须是 .txt：
--                KOReader 的 WebDAV 列表按“是否为可打开的文档类型”过滤，
--                .json 之类默认根本不显示（除非打开 show_unsupported）。
function InkBridge:_history_name(entry)
    local timestamp = os.date("%m%d-%H%M%S", tonumber(entry.updated_at) or os.time())
    local device_label = safe_filename_component(self.device_label, "KOReader", 16)
    local name = safe_filename_component(entry.book_name, "book", 40)
    return name .. "-" .. timestamp .. "-" .. device_label
        .. "." .. self:_history_prefix(entry) .. ".InkBridge.txt"
end

function InkBridge:set_device_label()
    local dialog
    dialog = InputDialog:new{
        title = "设置设备名称",
        description = "设备名称会显示在云端历史记录文件名中。",
        input = self.device_label or "KOReader",
        buttons = {{
            { text = "取消", callback = function() UIManager:close(dialog) end },
            { text = "保存", is_enter_default = true, callback = function()
                local label = dialog:getInputText()
                label = label and label:gsub("^%s+", ""):gsub("%s+$", "") or ""
                if label ~= "" then
                    self.device_label = label
                    G_reader_settings:saveSetting("inkbridge_device_label", label)
                    UIManager:close(dialog)
                    show("墨桥：设备名称已保存。")
                else
                    UIManager:close(dialog)
                    show("墨桥：设备名称不能为空。")
                end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- 让用户手动指定静读天下的云同步目录。
-- 刻意不做自动探测:目录猜错会读到别的书的进度,而用户几乎不可能察觉。
-- 可以填相对路径(相对当前 WebDAV 目标),也可以填以 "/" 开头的绝对路径
-- (从 WebDAV 服务器根算起 —— 当静读天下的目录不在当前目标之下时用这种)。
function InkBridge:set_moon_dir()
    local dialog
    dialog = InputDialog:new{
        title = "静读天下同步目录",
        description = "静读天下云同步存放进度文件的目录。\n"
            .. "相对当前 WebDAV 目标,例如 Apps/Books/.Moon+/Cache\n"
            .. "以 / 开头表示从服务器根算起。\n"
            .. "当前:" .. Moonsync.get_dir(),
        input = Moonsync.get_dir(),
        buttons = {{
            { text = "取消", callback = function() UIManager:close(dialog) end },
            { text = "保存", is_enter_default = true, callback = function()
                local dir = dialog:getInputText()
                dir = dir and dir:gsub("^%s+", ""):gsub("%s+$", "") or ""
                if dir ~= "" then
                    Moonsync.set_dir(dir)
                    UIManager:close(dialog)
                    show("墨桥：静读天下同步目录已保存。")
                else
                    UIManager:close(dialog)
                    show("墨桥：目录不能为空。")
                end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- 只读下载用的本地临时文件。
--
-- 名字刻意用纯 ASCII，而不是沿用远端文件名（那是中文）：
-- LuaJIT 在 Windows 上通过 ANSI 代码页打开文件，含中文的本地路径会直接报
-- “Illegal byte sequence”。设备端是 Linux/UTF-8，本来不受影响，但没有理由
-- 为了一个临时文件把这件事变成平台陷阱。
-- 同一时刻只会进行一次下载（用户手动触发），固定名字不存在冲突。
function InkBridge:_download_staging_path()
    return self:_staging_dir() .. "/download.tmp"
end

-- 发起一次手动上传或只读下载。
function InkBridge:_sync(entry, mode)
    if mode == "download" then
        local prefix = self:_history_prefix(entry)
        WebDAV.list_history(self, prefix, function(ok, entries, list_err)
            if not ok then
                show("墨桥：读取云端历史记录失败 —— " .. WebDAV.describe_error(list_err))
                return
            end

            if #entries == 0 then
                -- 兼容 0.1.x 只写一份哈希文件的旧记录
                local legacy_name = "inkbridge-progress-" .. entry.book_id .. ".json"
                local legacy = (self.server.url or "")
                legacy = legacy == "" and legacy_name or legacy .. "/" .. legacy_name
                WebDAV.download(self, legacy, function(legacy_ok, remote, legacy_err)
                    if legacy_ok and remote then
                        UIManager:nextTick(function() WebDAV.confirm_jump(self, remote) end)
                    elseif legacy_err ~= "missing" then
                        show("墨桥：读取旧版远端记录失败 —— " .. WebDAV.describe_error(legacy_err))
                    else
                        show("墨桥：没有找到这本书的历史记录。")
                    end
                end)
                return
            end

            WebDAV.choose_history(self, entries, function(item)
                WebDAV.download(self, item.url, function(download_ok, remote, remote_err)
                    if not download_ok then
                        show("墨桥：下载失败 —— " .. WebDAV.describe_error(remote_err))
                        return
                    end
                    if not remote then
                        show("墨桥：没有找到这本书的远端阅读记录。")
                        return
                    end
                    if remote.book_id ~= entry.book_id then
                        show("墨桥：远端记录不属于当前书籍，已停止。")
                        return
                    end
                    if not InkBridge:_position_differs(entry, remote) then
                        show("墨桥：远端记录与当前位置相同。")
                        return
                    end
                    UIManager:nextTick(function() WebDAV.confirm_jump(self, remote) end)
                end)
            end)
        end)
        return
    end

    local history_name = self:_history_name(entry)
    local history_path = self:_staging_dir() .. "/" .. history_name
    -- 上传历史文件本身，避免每次上传覆盖同一个云端对象。
    local ok, err = State.write_file(history_path, entry)
    if not ok then show("墨桥：写入暂存文件失败 —— " .. tostring(err)); return end

    -- 历史记录是追加式文件，直接上传当前文件名即可。
    -- 只有 Cloud Storage 收到 provider 的 2xx 回调后才显示成功。
    WebDAV.upload(self, history_path, function(upload_ok, upload_err)
        -- 无论成功失败都清掉本地暂存文件。它是每次上传新建的（文件名含秒级时间戳），
        -- 不清理会让设备设置目录无限增长。必须放在回调里：provider 要在这之后
        -- 才真正读完该文件；且回调只会触发一次（WebDAV.upload 内部有去重）。
        os.remove(history_path)
        if upload_ok then
            -- 顺手把进度写进静读天下的 .po:上传本身就是在声明"我这边是最新的",
            -- 静读天下因此能无感跟随,不必再多点一次按键。
            -- 整段用 pcall 包住:写回失败绝不能影响"上传成功"这个结论。
            local moon_note
            local ok_auto, note = pcall(Moonsync.auto_push, self)
            if ok_auto then
                moon_note = note
            else
                moon_note = "静读天下未同步（内部错误：" .. tostring(note) .. "）"
            end
            show("墨桥：阅读进度上传成功。" .. (moon_note and ("\n" .. moon_note) or ""))
        else
            show("墨桥：阅读进度上传失败 —— " .. WebDAV.describe_error(upload_err))
        end
    end)
end

-- 比较两个位置，而不是比较跨设备的 Unix 时间。
-- 不同设备的系统时钟可能相差几分钟，手动下载时仍应让用户看到远端位置。
function InkBridge:_position_differs(left, right)
    if left.xpointer and right.xpointer then return left.xpointer ~= right.xpointer end
    if left.page and right.page then return tonumber(left.page) ~= tonumber(right.page) end
    return math.abs((tonumber(left.percent) or 0) - (tonumber(right.percent) or 0)) > 0.0001
end

-- 所有同步动作都先确认网络，再执行。
--
-- 为什么需要这一步：WebDAV provider 的 run() 内部是
-- NetworkMgr:willRerunWhenConnected()——未联网时它**直接返回且不执行回调**，
-- 只是把动作登记到“联网后重跑”。于是用户点菜单后既没有成功提示也没有失败提示，
-- 看起来就像插件坏了。这里用 promptWifiOn 明确征询用户并等待连接，
-- 连接失败则给出可见的取消提示，从根上消除“静默无反应”。
function InkBridge:_with_network(action)
    if NetworkMgr:isConnected() then
        action()
        return
    end
    NetworkMgr:promptWifiOn(function()
        if NetworkMgr:isConnected() then
            action()
        else
            show("墨桥：未连接网络，操作已取消。")
        end
    end)
end

-- 菜单动作：读取当前页并发起同步。
function InkBridge:upload_current()
    local entry, err = self:_book_context()
    if not entry then show("墨桥：" .. WebDAV.describe_error(err)); return end
    self:_with_network(function() self:_sync(entry, "upload") end)
end

-- 菜单动作：读取当前页并发起同步。
-- 如果远端记录更新，会在同步回调后显示跳转确认框。
function InkBridge:download_current()
    local entry, err = self:_book_context()
    if not entry then show("墨桥：" .. WebDAV.describe_error(err)); return end
    self:_with_network(function() self:_sync(entry, "download") end)
end

-- KOReader 调用这个方法，把插件菜单加入工具菜单。
function InkBridge:addToMainMenu(menu_items)
    menu_items.inkbridge = {
        text = "墨桥 InkBridge v" .. tostring(Meta.version or "unknown"),
        sorting_hint = "tools",
        -- KOReader 的主菜单使用 sub_item_table_func 动态生成子菜单。
        -- 动态函数比直接写 sub_item_table 更兼容不同 KOReader 版本，
        -- 也能保证每次打开菜单时都拿到当前插件实例。
        sub_item_table_func = function()
            return {
                { text = "设置设备名称", callback = function() self:set_device_label() end },
                { text = "设置 WebDAV 目标", callback = function() WebDAV.pick_server(self) end },
                { text = "上传当前阅读进度", callback = function() self:upload_current() end },
                { text = "下载并检查阅读进度", callback = function() self:download_current() end },
                { text = "从静读天下读取进度", callback = function() Moonsync.import_from_moon(self) end },
                -- 写回不在菜单里放"按钮":上传进度时会自动写(见 _sync 的成功回调)。
                -- 这里只留一个开关,因为它是**覆盖另一台设备状态**的动作。
                { text = "上传时自动写入静读天下",
                  checked_func = function() return Moonsync.auto_enabled() end,
                  callback = function()
                      Moonsync.set_auto(not Moonsync.auto_enabled())
                      show("墨桥：上传时自动写入静读天下已"
                          .. (Moonsync.auto_enabled() and "开启。" or "关闭。"))
                  end },
                { text = "设置静读天下同步目录", callback = function() self:set_moon_dir() end },
            }
        end,
    }
end

-- 用户卸载插件时清理 InkBridge 自己保存的设置。
-- 这里只删除设置，不删除书籍、.sdr 或 Moon+ 文件。
function InkBridge:deletePluginSettings()
    G_reader_settings:delSetting("inkbridge_device_id")
    G_reader_settings:delSetting("inkbridge_device_label")
    G_reader_settings:delSetting("inkbridge_webdav_server")
    G_reader_settings:delSetting("inkbridge_moon_dir")
    G_reader_settings:delSetting("inkbridge_moon_book_ref")
    G_reader_settings:delSetting("inkbridge_moon_auto_push")
end

return InkBridge
