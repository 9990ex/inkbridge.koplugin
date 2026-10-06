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

local State = require("inkbridge_state")
local WebDAV = require("inkbridge_webdav")
local Meta = require("_meta")

-- KOReader 插件通常继承 WidgetContainer。
-- extend{} 会创建一个可以接收 KOReader 生命周期事件的插件类。
local InkBridge = WidgetContainer:extend{}
InkBridge.name = "inkbridge"

local function show(text)
    UIManager:show(InfoMessage:new{ text = text, timeout = 4 })
end

local function safe_filename_component(value, fallback, max_length)
    value = tostring(value or "")
    value = value:gsub("[\\/:*?\"<>|]", "_"):gsub("[%c]", "_")
    if value == "" then value = fallback end
    return value:sub(1, max_length or 64)
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

-- 根据书籍内容哈希生成临时文件名。
-- 不能只使用 progress.json，否则多本书会在 WebDAV 上互相覆盖。
function InkBridge:_staged_path(book_id)
    return self:_staging_dir() .. "/inkbridge-progress-" .. book_id .. ".json"
end

-- 生成对用户友好的文件名前缀。短哈希仍保留，用来区分同名书籍；
-- 书名只来自当前打开的文件名，不上传完整本地路径。
function InkBridge:_history_prefix(entry)
    local short_id = tostring(entry.book_id):sub(1, 8)
    -- 这个短哈希必须在所有设备上一致，才能发现其他设备上传的记录。
    return short_id
end

function InkBridge:_history_name(entry)
    -- 文件名中的时间按“日 + 小时 + 分钟 + 秒”显示，例如 0615日30分45秒。
    -- 加入秒可以避免同一本书同一设备在同一分钟内重复上传时重名。
    local timestamp = os.date("%d%H日%M分%S秒", tonumber(entry.updated_at) or os.time())
    -- 设备 ID 的最后四位是生成时的短随机编号，例如 8147。
    -- 只取这四位，避免把前面的时间戳也混进可读文件名。
    local device_id = tostring(self.device_id or ""):match("(%d%d%d%d)$")
    if not device_id then
        device_id = tostring(self.device_id or "device"):gsub("[^%w]", ""):sub(-4)
    end
    if device_id == "" then device_id = "device" end
    local device_label = safe_filename_component(self.device_label, "KOReader", 32)
    local name = safe_filename_component(entry.book_name, "book", 96)
    -- 使用 .txt 让 KOReader 默认的 WebDAV 文件列表显示它；文件内容
    -- 仍然是 JSON，下载后由 State.decode 校验。
    return name .. "-" .. timestamp .. "-" .. device_label .. device_id
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
                    show("InkBridge: 设备名称已保存。")
                else
                    UIManager:close(dialog)
                    show("InkBridge: 设备名称不能为空。")
                end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- 只读下载使用单独的临时文件名，避免和 SyncService 的 .temp/.sync
-- 文件混用。该文件只在 WebDAV GET 期间存在，完成后立即删除。
function InkBridge:_download_staging_path(remote_name)
    return self:_staging_dir() .. "/" .. remote_name .. ".download"
end

-- 发起一次手动上传或只读下载。
function InkBridge:_sync(entry, mode)
    if mode == "download" then
        local prefix = self:_history_prefix(entry)
        WebDAV.list_history(self, prefix, function(ok, entries, list_err)
            if not ok then show("InkBridge: 无法读取历史记录：" .. tostring(list_err)); return end
            if #entries == 0 then
                -- 兼容 0.1.x 只写一份哈希文件的旧记录。
                local legacy_name = "inkbridge-progress-" .. entry.book_id .. ".json"
                local legacy = (self.server.url or "")
                legacy = legacy == "" and legacy_name or legacy .. "/" .. legacy_name
                WebDAV.download(self, legacy, function(legacy_ok, remote, legacy_err)
                    if legacy_ok and remote then
                        UIManager:nextTick(function() WebDAV.confirm_jump(self, remote) end)
                    elseif legacy_err ~= "missing" then
                        show("InkBridge: 无法读取旧版远端记录：" .. tostring(legacy_err))
                    else
                        show("InkBridge: 没有找到这本书的历史记录。")
                    end
                end)
                return
            end
            WebDAV.choose_history(self, entries, function(item)
                WebDAV.download(self, item.url, function(ok, remote, remote_err)
            if not ok then
                show("InkBridge: 下载失败：" .. tostring(remote_err))
                return
            end
            if not remote then
                show("InkBridge: 未找到这本书的远端阅读记录。")
                return
            end
            if remote.book_id ~= entry.book_id then
                show("InkBridge: 远端记录不属于当前书籍，已停止。")
                return
            end
            if not InkBridge:_position_differs(entry, remote) then
                show("InkBridge: 远端记录与当前位置相同。")
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
    if not ok then show("InkBridge staging failed: " .. tostring(err)); return end

    -- 历史记录是追加式文件，直接上传当前文件名即可。
    -- 只有 Cloud Storage 收到 provider 的 2xx 回调后才显示成功。
    WebDAV.upload(self, history_path, function(upload_ok, upload_err)
        if upload_ok then
            show("InkBridge: 阅读进度上传成功。")
        else
            show("InkBridge: 阅读进度上传失败：" .. tostring(upload_err))
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

-- 菜单动作：读取当前页并发起同步。
function InkBridge:upload_current()
    local entry, err = self:_book_context()
    if not entry then show("InkBridge: " .. tostring(err)); return end
    self:_sync(entry, "upload")
end

-- 菜单动作：读取当前页并发起同步。
-- 如果远端记录更新，会在同步回调后显示跳转确认框。
function InkBridge:download_current()
    local entry, err = self:_book_context()
    if not entry then show("InkBridge: " .. tostring(err)); return end
    self:_sync(entry, "download")
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
end

return InkBridge
