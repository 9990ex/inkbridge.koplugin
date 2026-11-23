-- 通过 KOReader 的原生自定义元数据保存；不重打包 EPUB，不改变跨设备书籍身份。
local Metadata = {}
Metadata.fields = {
    { key = "title", text = "书名", icon = "book.opened" },
    { key = "authors", text = "作者", icon = "edit", multiline = true },
    { key = "series", text = "丛书", icon = "book.opened" },
    { key = "series_index", text = "丛书序号", icon = "edit", number = true },
    { key = "language", text = "语言", icon = "edit" },
    { key = "keywords", text = "关键词", icon = "bookmark", multiline = true },
    { key = "description", text = "简介", icon = "info", multiline = true },
}
local function dependencies()
    return { Files = require("inkbridge_book_files"), DocSettings = require("docsettings"),
        BookInfo = require("apps/filemanager/filemanagerbookinfo"),
        BookList = require("ui/widget/booklist"), UI = require("ui/uimanager"), Event = require("ui/event") }
end
local function custom(session)
    local d = session.deps
    local path = d.DocSettings:findCustomMetadataFile(session.file)
    return path and d.DocSettings.openSettingsFile(path) or nil
end
function Metadata.open(plugin, file, deps)
    deps = deps or dependencies()
    if type(file) ~= "string" or file:lower():sub(-5) ~= ".epub" then
        return nil, "此入口仅支持本地 EPUB 书籍。"
    end
    local current = plugin.ui and plugin.ui.document and plugin.ui.document.file
    if current == file then return nil, "请先关闭这本书，再编辑元数据。" end
    local snapshot, err = deps.Files.snapshot(file)
    if not snapshot then return nil, err end
    local info = deps.BookInfo:new{ ui = plugin.ui or {} }
    local props = info:getDocProps(file)
    if type(props) ~= "table" then return nil, "无法读取这本 EPUB 的元数据。" end
    -- 原生方法末尾默认重开 KeyValuePage；这里只记录刷新信息，继续使用插件图标界面。
    function info:updateBookInfo(path, book_props, key, old)
        self.prop_updated = { filepath = path, doc_props = book_props,
            metadata_key_updated = key, metadata_value_old = old }
    end
    local session = { file = file, snapshot = snapshot, props = props, info = info, deps = deps, plugin = plugin }
    session.info.custom_doc_settings = custom(session)
    return session
end
function Metadata.save(session, key, value)
    local field
    for _, entry in ipairs(Metadata.fields) do if entry.key == key then field = entry; break end end
    if not field then return false, "不支持修改该元数据字段。" end
    if value ~= nil then
        if type(value) ~= "string" or #value > 65536 then return false, "输入内容过长或无效。" end
        for i = 1, #value do
            local byte = value:byte(i)
            if byte < 32 and byte ~= 9 and byte ~= 10 and byte ~= 13 then return false, "内容包含无效控制字符。" end
        end
        value = value:gsub("^%s+", ""):gsub("%s+$", "")
        if key == "title" and value == "" then return false, "书名不能为空。" end
        if field.number and value ~= "" then
            local number = tonumber(value)
            if not number or number ~= number or math.abs(number) == math.huge then
                return false, "丛书序号请输入有效数字。"
            end
            value = number
        end
    end
    local current = session.plugin.ui and session.plugin.ui.document and session.plugin.ui.document.file
    if current == session.file then return false, "请先关闭这本书，再编辑元数据。" end
    local now, err = session.deps.Files.snapshot(session.file)
    if not now then return false, err end
    for _, name in ipairs({ "id", "size", "modification", "change" }) do
        if now[name] ~= session.snapshot[name] then return false, "原书文件已变化，请重新打开元数据编辑。" end
    end
    -- 每次写之前重读自定义文件，保留其他字段及其他编辑器已保存的修改。
    session.info.custom_doc_settings = custom(session)
    local ok, failure = pcall(session.info.setCustomMetadata, session.info, session.file, session.props, key, value)
    if not ok then return false, "保存元数据失败：" .. tostring(failure) end
    local stored = custom(session)
    local props = stored and stored:readSetting("custom_props") or {}
    if type(props) ~= "table" or props[key] ~= value then return false, "元数据未能写入阅读数据，请检查目录权限。" end
    session.info.custom_doc_settings = stored
    local d = session.deps
    local refreshed = pcall(function()
        d.BookList.resetBookInfoCache(session.file)
        d.UI:broadcastEvent(d.Event:new("InvalidateMetadataCache", session.file))
        d.UI:broadcastEvent(d.Event:new("BookMetadataChanged", session.info.prop_updated))
    end)
    if not refreshed then return true, "本机元数据已保存；部分界面刷新失败，请重新打开书库。原 EPUB 文件不变。" end
    return true, "已保存本机元数据，原 EPUB 文件不变。"
end
function Metadata.show(plugin, file, opts)
    opts = opts or {}
    local Material = require("inkbridge_material")
    local UI = require("ui/uimanager")
    local function message(text) UI:show(Material.widget("infomessage"):new{ text = text, timeout = 6 }) end
    local ok, session, err = pcall(Metadata.open, plugin, file)
    if not ok or not session then message(ok and err or "无法打开 EPUB 元数据编辑。"); return end
    local Screen = require("device").screen
    local renamed = false
    local function finish(dialog)
        UI:close(dialog)
        if opts.finished then opts.finished(renamed) end
    end
    local function showForm(draft)
        local fields = {}
        for i, field in ipairs(Metadata.form_fields) do
            fields[#fields + 1] = { description = field.text, text = draft and draft[i] or tostring(session.props[field.key] or ""),
                padding = Screen:scaleBySize(4), margin = Screen:scaleBySize(2) }
        end
        local dialog, renameFile
        dialog = Material.widget("multiinputdialog"):new{
        title = "编辑元信息（仅本机）", fields = fields,
        width = math.min(Screen:getWidth() - Screen:scaleBySize(32), Screen:scaleBySize(560)),
        input_face = require("ui/font"):getFace("cfont", 16),
        description_padding = Screen:scaleBySize(2), description_margin = Screen:scaleBySize(1),
        buttons = {{
            { text = "取消", id = "close", callback = function() finish(dialog) end },
            { text = "保存", callback = function()
                local success, saved, text = pcall(Metadata.saveForm, session, dialog:getFields())
                if not success then message("保存元数据失败，请重新打开编辑界面。"); return end
                if saved then finish(dialog) end
                message(text)
            end },
        }, {{ text = "编辑文件名", callback = function() renameFile() end }}},
        }
        renameFile = function()
            local input
            input = Material.widget("inputdialog"):new{
                title = "编辑文件名（保留扩展名）", input = session.file:match("([^/]+)$"),
                description = "改名立即生效；元信息仍可返回表单后继续编辑。",
                buttons = {{
                    { text = "取消", id = "close", callback = function() UI:close(input) end },
                    { text = "改名", callback = function()
                        local current = plugin.ui and plugin.ui.document and plugin.ui.document.file
                        local called, success, text, destination = pcall(session.deps.Files.rename,
                            session.snapshot, input:getInputText(), current)
                        if not called then message("文件改名未完成，请重新打开书库核对文件名。"); return end
                        if not success then message(text); return end
                        local values = dialog:getFields()
                        UI:close(input); UI:close(dialog)
                        renamed = true
                        local opened, next_session, failure = pcall(Metadata.open, plugin, destination, session.deps)
                        if opened and next_session then session = next_session; showForm(values)
                        elseif opts.finished then opts.finished(true) end
                        message(opened and next_session and (text .. "\n未保存的元信息仍保留在表单中。")
                            or (text .. "\n" .. tostring(opened and failure or "请重新打开元信息编辑。")))
                    end },
                }},
            }
            UI:show(input); input:onShowKeyboard()
        end
        function dialog:onSetDimensions()
            local values = self:getFields()
            UI:close(self)
            UI:nextTick(function() showForm(values) end)
            return true
        end
        UI:show(dialog); dialog:onShowKeyboard()
    end
    showForm()
end

Metadata.form_fields = {
    { key = "title", text = "书名" }, { key = "authors", text = "作者" },
    { key = "keywords", text = "分类" }, { key = "series", text = "系列" },
}
function Metadata.saveForm(session, values)
    if type(values) ~= "table" or #values ~= #Metadata.form_fields then return false, "元信息表单不完整。" end
    local changed, pending = {}, {}
    for i, field in ipairs(Metadata.form_fields) do
        local value = values[i]
        if type(value) ~= "string" or #value > 65536 then return false, field.text .. "内容过长或无效。" end
        for n = 1, #value do
            local b = value:byte(n)
            if b < 32 and b ~= 9 and b ~= 10 and b ~= 13 then return false, field.text .. "包含无效控制字符。" end
        end
        value = value:gsub("^%s+", ""):gsub("%s+$", "")
        if field.key == "title" and value == "" then return false, "书名不能为空。" end
        if value ~= tostring(session.props[field.key] or "") then
            changed[#changed + 1] = field.key
            pending[field.key] = value
        end
    end
    if #changed == 0 then return true, "元信息没有变化。" end
    local current = session.plugin.ui and session.plugin.ui.document and session.plugin.ui.document.file
    if current == session.file then return false, "请先关闭这本书，再编辑元数据。" end
    local now, err = session.deps.Files.snapshot(session.file)
    if not now then return false, err end
    for _, name in ipairs({ "id", "size", "modification", "change" }) do
        if now[name] ~= session.snapshot[name] then return false, "原书文件已变化，请重新打开元数据编辑。" end
    end
    local d = session.deps
    local settings = custom(session) or d.DocSettings.openSettingsFile()
    if not settings:readSetting("doc_props") then
        local original = {}
        for key, value in pairs(session.props) do if key ~= "display_title" then original[key] = value end end
        settings:saveSetting("doc_props", original)
    end
    local merged = {}
    for key, value in pairs(settings:readSetting("custom_props", {})) do merged[key] = value end
    for key, value in pairs(pending) do merged[key] = value end
    -- 全表先校验，四个字段合并后只落盘一次，避免保存一半才发现后一个字段无效。
    settings:saveSetting("custom_props", merged)
    local ok, saved = pcall(settings.flushCustomMetadata, settings, session.file)
    if not ok or not saved then return false, "元信息保存失败，请检查阅读数据目录权限。" end
    local stored = custom(session)
    local reread = stored and stored:readSetting("custom_props", {}) or {}
    for key, value in pairs(pending) do
        if reread[key] ~= value then return false, "元信息保存后核验失败，请重新打开编辑界面。" end
    end
    session.info.custom_doc_settings = stored
    for key, value in pairs(pending) do session.props[key] = value end
    session.props.display_title = session.props.title
    local refreshed = pcall(function()
        d.BookList.resetBookInfoCache(session.file)
        d.UI:broadcastEvent(d.Event:new("InvalidateMetadataCache", session.file))
        for _, key in ipairs(changed) do
            d.UI:broadcastEvent(d.Event:new("BookMetadataChanged", { filepath = session.file,
                doc_props = session.props, metadata_key_updated = key }))
        end
    end)
    return true, refreshed and "元信息已保存到本机阅读数据，原 EPUB 文件不变。"
        or "元信息已保存，请重新打开书库刷新显示。"
end
return Metadata
