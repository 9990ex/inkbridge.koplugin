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
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local NetworkMgr = require("ui/network/manager")

local State = require("inkbridge_state")
local WebDAV = require("inkbridge_webdav")
local Meta = require("_meta")
local Moonsync = require("inkbridge_moonsync")
local Update = require("inkbridge_update")

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
        title = "修改设备名称",
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

            -- 顺带看一眼静读天下的 .po,作为附加项列在最后。
            -- 取不到**也照样列出来**(显示「静读天下：无数据»)——
            -- 一项凭空消失比"明确告诉你没有"更让人困惑。
            Moonsync.peek_po(self, function(peek)
                local extra = {
                    text = Moonsync.peek_label(peek, os.time(), Moonsync.local_position(self)),
                    on_select = function()
                        if peek then
                            Moonsync.import_from_moon(self)
                        else
                            show("墨桥：静读天下里没有这本书的进度文件。\n"
                                .. "（手动选择文件的功能还在开发中）")
                        end
                    end,
                }
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
                end, extra)
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

-- 是否已经配置过云同步目标(决定一级菜单要不要放"未配置"引导)。
function InkBridge:_has_server()
    local s = G_reader_settings and G_reader_settings:readSetting("inkbridge_webdav_server")
    return type(s) == "table" and s.type ~= nil
end

-- 存储选项(A 方案):**只有一个后端时不制造"假选择"**,直接把它的子项摊开。
-- 以后真加了第二个后端(比如 Syncthing),这里自然长成
--   存储选项 → WebDAV / Syncthing → 各自的目录
-- 而不会在只有一个后端时留下一个"点进去只有一个选项"的空转层。
function InkBridge:_storage_menu()
    local backends = {
        { text = "WebDAV", sub_item_table_func = function() return self:_webdav_menu() end },
    }
    if #backends == 1 then
        return backends[1].sub_item_table_func()
    end
    return backends
end

-- 一个云同步后端内部:它自己的连接设置 + 借它同步的各个阅读器目录。
-- 注意:「墨桥同步目录」是**整个**选服务器+选目录;只有一台服务器时,
-- KOReader 的云存储列表里本来就只有一项,用户点一下也就进目录了(见 README 说明)。
function InkBridge:_webdav_menu()
    return {
        { text = "墨桥同步目录",
          help_text = "墨桥进度存放的目录（配了多台服务器时先选服务器）",
          callback = function() WebDAV.pick_server(self) end },
        { text = "静读天下同步目录",
          help_text = "相对上面那个目录；以 / 开头表示从服务器根算起",
          callback = function() self:set_moon_dir() end },
    }
end

-- 高级选项:低频设置全部收在这里,一级只留"上传/下载"两个动作。
function InkBridge:_advanced_menu()
    return {
        { text = "修改设备名称", callback = function() self:set_device_label() end },
        { text = "打开书时自动核对云端更新",
          help_text = "只在你已经联网时检查；不会自己开 Wi-Fi",
          checked_func = function() return self:auto_check_enabled() end,
          callback = function()
              self:set_auto_check(not self:auto_check_enabled())
              show("墨桥：打开书时自动核对已"
                  .. (self:auto_check_enabled() and "开启。" or "关闭。"))
          end },
        -- 写回不在菜单里放"按钮":上传进度时会自动写(见 _sync 的成功回调)。
        -- 这里只留一个开关,因为它是**覆盖另一台设备状态**的动作。
        { text = "上传时自动写入静读天下",
          checked_func = function() return Moonsync.auto_enabled() end,
          callback = function()
              Moonsync.set_auto(not Moonsync.auto_enabled())
              show("墨桥：上传时自动写入静读天下已"
                  .. (Moonsync.auto_enabled() and "开启。" or "关闭。"))
          end },
        { text = "存储选项", sub_item_table_func = function() return self:_storage_menu() end },
        -- 检查更新**不单独占一项** —— 它和"看版本号"是同一件事,
        -- 摆两处等于让用户猜哪个才是真的。点「关于插件」里的版本号即可。
        { text = "关于插件",
          sub_item_table = {
              { text = "当前版本 v" .. tostring(Meta.version or "unknown"),
                help_text = "点击可检查更新",
                callback = function() self:check_update() end },
              -- 下面三条是纯展示项(故意不带 callback):墨水屏性能差,
              -- 打开浏览器不现实,把链接摆出来让用户抄写更实际。
              { text = Update.HOMEPAGE, help_text = "项目主页（不联网打开）" },
              { text = "许可证 GPL-3.0" },
              { text = "实验性 Alpha，不代表稳定版本" },
          } },
    }
end

-- 检查更新:只查、不装。
-- 自动安装要替换正在运行的插件目录,失败会让插件变砖 —— 而它恰恰是"修插件"的工具,
-- 所以先只把"有没有新版"说清楚(完整设计见 research/ 的笔记)。
function InkBridge:check_update()
    self:_with_network(function()
        show("墨桥：正在检查更新…")
        if UIManager.forceRePaint then UIManager:forceRePaint() end
        UIManager:nextTick(function() self:_do_check_update() end)
    end)
end

function InkBridge:_do_check_update()
    local ok_http, http   = pcall(require, "socket.http")
    local ok_sock, socket = pcall(require, "socket")
    local ok_ltn12, ltn12 = pcall(require, "ltn12")
    if not (ok_http and ok_sock and ok_ltn12) then
        show("墨桥：本机缺少网络模块，无法检查更新。")
        return
    end

    local sink, code
    local ok = pcall(function()
        code = tonumber(socket.skip(1, http.request{
            url    = Update.API_URL,
            method = "GET",
            sink   = ltn12.sink.table(sink),
            headers = {
                -- GitHub 的 API 不带 User-Agent 会直接 403
                ["User-Agent"] = "inkbridge-koplugin",
                ["Accept"]     = "application/vnd.github+json",
            },
        }))
    end)
    local body = type(sink) == "table" and table.concat(sink) or ""

    if not ok or not code then
        show("墨桥：连不上 GitHub，检查更新失败。\n项目主页：" .. Update.HOMEPAGE)
        return
    end
    if code ~= 200 then
        show(string.format("墨桥：GitHub 返回 %d，检查更新失败。\n项目主页：%s",
                           code, Update.HOMEPAGE))
        return
    end

    local ok_json, rapidjson = pcall(require, "rapidjson")
    local rel, err = Update.parse_release(body,
        (ok_json and rapidjson and rapidjson.decode) or nil)
    if not rel then
        show("墨桥：没能读懂 GitHub 的返回（" .. tostring(err) .. "）。\n项目主页："
            .. Update.HOMEPAGE)
        return
    end

    local kv = Update.describe(tostring(Meta.version or "?"), rel)
    local ok_kv, KeyValuePage = pcall(require, "ui/widget/keyvaluepage")
    if ok_kv and type(KeyValuePage) == "table" and KeyValuePage.new then
        UIManager:show(KeyValuePage:new{ title = "墨桥 · 检查更新", kv_pairs = kv })
        return
    end
    -- 拿不到 KeyValuePage(极老版本)就退化成纯文本,不能让功能消失
    local lines = {}
    for _, row in ipairs(kv) do
        lines[#lines + 1] = tostring(row[1]) .. "：" .. tostring(row[2])
    end
    show("墨桥 · 检查更新\n" .. table.concat(lines, "\n"))
end

-- ── 打开书时自动核对云端有没有更新的进度 ──────────────────────────────────
--
-- 写法跟着 KOReader 官方进度同步插件(kosync)走:onReaderReady + nextTick + 一个开关。
-- 三条自我约束 —— 否则这功能会从"贴心"变成"骚扰":
--   1. **绝不自动开 WiFi**:只在已经联网时查,没网就静默跳过;
--   2. **本机没同步过的设备不提示**:否则第一次打开这本书就弹;
--   3. 同一本书 10 分钟内只查一次,免得反复翻书时狂发请求。
--
-- 新旧一律用**服务器时间**比:记录项的 modification 与 .po 的 Last-Modified
-- 都来自同一台服务器,不受两台设备时钟差的影响(设备本地时间不可比,这点吃过亏)。

InkBridge.AUTO_CHECK_SETTING  = "inkbridge_auto_check"
InkBridge.AUTO_CHECK_INTERVAL = 600      -- 同一本书两次检查的最小间隔(秒)

function InkBridge:auto_check_enabled()
    local v = G_reader_settings:readSetting(InkBridge.AUTO_CHECK_SETTING)
    if v == nil then return true end     -- 默认开
    return v and true or false
end

function InkBridge:set_auto_check(on)
    G_reader_settings:saveSetting(InkBridge.AUTO_CHECK_SETTING, on and true or false)
end

-- 记录名格式:<书名>-MMDD-HHMMSS-<设备名>.<短哈希>.InkBridge.txt
-- 里面的时间戳与设备名只给人看;真正用来比新旧的是服务器时间。
function InkBridge:_record_device(name)
    return tostring(name or ""):match("%-%d%d%d%d%-%d%d%d%d%d%d%-(.-)%.%x+%.InkBridge%.txt$")
end

function InkBridge:_get_seen(book_id)
    local raw = G_reader_settings:readSetting("inkbridge_seen:" .. tostring(book_id))
    return type(raw) == "table" and raw or {}
end

function InkBridge:_set_seen(book_id, seen)
    G_reader_settings:saveSetting("inkbridge_seen:" .. tostring(book_id), seen or {})
end

-- KOReader 在书准备好之后会调用插件的这个方法(官方 kosync 插件同款)。
function InkBridge:onReaderReady()
    if not self:auto_check_enabled() then return end
    UIManager:nextTick(function() self:_auto_check_remote() end)
end

function InkBridge:_auto_check_remote()
    local entry = self:_book_context()
    if not entry then return end        -- 没有书 / 取不到上下文:静默
    if type(self.server) ~= "table" or self.server.type ~= "webdav" then return end

    -- **不自动开 WiFi**:没联网就安静跳过,把"要不要联网"留给用户决定
    if not NetworkMgr:isConnected() then return end

    local now = os.time()
    self._auto_check_at = self._auto_check_at or {}
    local last = self._auto_check_at[entry.book_id]
    if last and now - last < InkBridge.AUTO_CHECK_INTERVAL then return end
    self._auto_check_at[entry.book_id] = now

    -- ★ 两条路**互相独立**。之前把 _auto_check_moon 放在 list_history 的回调里,
    -- 于是"这本书没有 KO 云端记录"时回调直接 return,静读天下那条**永远不执行** ——
    -- 真机上就表现为"打开书毫无反应"。KO 记录为空/失败,绝不能挡住另一条路。
    self:_auto_check_moon(entry)

    WebDAV.list_history(self, self:_history_prefix(entry), function(ok, records)
        if not ok or type(records) ~= "table" or #records == 0 then return end

        -- 同一台设备只留它最新的一条
        local newest = {}
        for _, item in ipairs(records) do
            local device = self:_record_device(item.text)
            local t = tonumber(item.modification)
            if device and t and (not newest[device] or t > newest[device].time) then
                newest[device] = { source = device, time = t, url = item.url }
            end
        end
        local cands = {}
        for _, c in pairs(newest) do cands[#cands + 1] = c end

        local updates = WebDAV.select_updates(cands, self:_get_seen(entry.book_id))
        if #updates == 0 then return end
        self:_ask_remote_update(entry, updates)
    end)
end

-- 静读天下那份单独查:它没有记录项,而且 .po 里没有时间戳。
-- 所以用**内容指纹** `(*章节, #偏移)` 当版本号 —— 内容变了就说明对面动过。
--
-- 防误报只有一条:远端位置与本机几乎相同时,多半正是"我们自己刚写出去的那次",
-- 不打扰。除此之外**第一次见到就提示** —— 否则刚装上这一版时,
-- 你在手机上改了位置、打开 KO 却没有任何反应,会以为功能坏了。
function InkBridge:_auto_check_moon(entry)
    Moonsync.peek_po(self, function(peek)
        if not peek or type(peek.po) ~= "table" then return end

        local key = "inkbridge_moon_fp:" .. tostring(entry.book_id)
        local fp  = tostring(peek.po.star) .. "#" .. tostring(peek.po.hash)
        if G_reader_settings:readSetting(key) == fp then return end   -- 没变过

        local pos = Moonsync.local_position(self)
        -- 算不出本机偏移时**也照提示**:页首停在章标题上时算不出偏移,而"翻开书停在
        -- 章首页"极常见 —— 若因此静默,用户会觉得功能根本没生效。
        -- 代价是可能误报一次(例如刚上传过、本地又正好停在标题页),点「忽略」即可。
        local same_place = pos and tonumber(pos.hash)
            and pos.section == tonumber(peek.po.star)
            and math.abs((tonumber(pos.hash) or 0) - (tonumber(peek.po.hash) or 0)) < 200
        G_reader_settings:saveSetting(key, fp)
        if same_place then return end

        UIManager:show(ConfirmBox:new{
            text = string.format("静读天下有了新进度（第 %d 章）。\n\n要跳过去吗？",
                                 (tonumber(peek.po.star) or 0) + 1),
            ok_text = "跳转",
            cancel_text = "忽略",
            ok_callback = function()
                -- 已经问过用户了,让 import 直接跳,别再弹第二个确认框
                Moonsync.import_from_moon(self, { already_confirmed = true })
            end,
        })
    end)
end

function InkBridge:_ask_remote_update(entry, updates)
    local parts = {}
    for _, u in ipairs(updates) do
        parts[#parts + 1] = string.format("%s（%s）", u.source,
            WebDAV.human_age(os.time() - (tonumber(u.time) or 0)))
    end
    local newest = updates[1]

    -- 无论跳还是忽略都记下"已见过",否则每次打开这本书都会再弹一次。
    local function remember()
        local seen = self:_get_seen(entry.book_id)
        for _, u in ipairs(updates) do seen[u.source] = u.time end
        self:_set_seen(entry.book_id, seen)
    end

    UIManager:show(ConfirmBox:new{
        text = "云端有更新的进度：\n" .. table.concat(parts, "\n") .. "\n\n要跳过去吗？",
        ok_text = "跳转",
        cancel_text = "忽略",
        ok_callback = function()
            remember()
            WebDAV.download(self, newest.url, function(ok, remote, err)
                if not ok or not remote then
                    show("墨桥：下载失败 —— " .. WebDAV.describe_error(err))
                    return
                end
                UIManager:nextTick(function()
                    -- 已经问过用户了,这里别再问第二遍
                    WebDAV.confirm_jump(self, remote, { already_confirmed = true })
                end)
            end)
        end,
        cancel_callback = remember,
    })
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
            local items = {}

            -- 一级只留两个动作之后,新用户会不知道去哪配云同步 ——
            -- 所以未配置时在**最上面**放一条引导,配好之后它自己就消失了。
            if not self:_has_server() then
                table.insert(items, {
                    text = "⚠ 尚未设置云同步，点此配置",
                    callback = function() WebDAV.pick_server(self) end,
                })
            end

            table.insert(items, { text = "上传阅读进度",
                                  callback = function() self:upload_current() end })
            table.insert(items, { text = "下载阅读进度",
                                  callback = function() self:download_current() end })
            table.insert(items, { text = "高级选项",
                                  sub_item_table_func = function()
                                      return self:_advanced_menu()
                                  end })
            return items
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
    G_reader_settings:delSetting("inkbridge_auto_check")
end

return InkBridge
