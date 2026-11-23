-- 元数据使用原生伴随文件，验证身份守卫、字段校验和落盘回读。
package.path = "inkbridge.koplugin/?.lua;" .. package.path
local passed, failed = 0, 0
local function check(label, yes)
    if yes then passed = passed + 1 else failed = failed + 1; print("FAIL " .. label) end
end
local M = require("inkbridge_book_metadata")
local function copy(t)
    local result = {}
    for key, value in pairs(t or {}) do result[key] = value end
    return result
end
local state, disk, saves, resets, events, error_mode
local originals = { title = "原书名", authors = "原作者", language = "zh", pages = 100 }
local function setting()
    local data = { doc_props = disk and copy(disk.doc_props), custom_props = disk and copy(disk.custom_props) }
    return { readSetting = function(_, key, fallback) return data[key] or fallback end,
        saveSetting = function(_, key, value) data[key] = value end,
        flushCustomMetadata = function()
            if error_mode == "exception" then error("permission denied") end
            saves = saves + 1
            if error_mode == "refuse" then return false end
            if error_mode ~= "silent" then disk = { doc_props = copy(data.doc_props), custom_props = copy(data.custom_props) } end
            return true
        end }
end
local deps = {
    Files = { snapshot = function(file)
        if not state then return nil, "文件不存在或不是普通文件。" end
        local s = copy(state); s.file = file; return s
    end },
    DocSettings = { findCustomMetadataFile = function() return disk and "/metadata.lua" end,
        openSettingsFile = function() return setting() end },
    BookInfo = { new = function(_, opts)
        function opts:getDocProps()
            local props = copy(originals)
            for key, value in pairs(disk and disk.custom_props or {}) do props[key] = value end
            return props
        end
        function opts:setCustomMetadata(file, props, key, value)
            if error_mode == "exception" then error("permission denied") end
            saves = saves + 1
            if error_mode ~= "silent" then
                disk = disk or { doc_props = copy(originals), custom_props = {} }
                disk.custom_props[key] = value
                if next(disk.custom_props) == nil then disk = nil end
            end
            props[key] = value or originals[key]
            self:updateBookInfo(file, props, key, originals[key])
        end
        return opts
    end },
    BookList = { resetBookInfoCache = function() resets = resets + 1 end },
    UI = { broadcastEvent = function(_, event) events[#events + 1] = event end },
    Event = { new = function(_, name, arg) return { name = name, arg = arg } end },
}
local function reset()
    state = { id = string.rep("a", 32), size = 2048, modification = 100, change = 100 }
    disk, saves, resets, events, error_mode = nil, 0, 0, {}, nil
end
reset()
local plugin = { ui = {} }
local session = assert(M.open(plugin, "/books/test.epub", deps))
check("读取EPUB原始字段", session.props.title == "原书名" and session.props.authors == "原作者")
check("支持七种书籍元数据", #M.fields == 7)
check("非EPUB拒绝进入", not M.open(plugin, "/books/test.txt", deps))
check("不依赖扩展名大小写", M.open(plugin, "/books/test.EPUB", deps) ~= nil)
plugin.ui.document = { file = "/books/test.epub" }
check("打开中的书籍拒绝进入编辑", not M.open(plugin, "/books/test.epub", deps))
check("编辑途中打开原书也拒绝保存", not M.save(session, "title", "新书名") and saves == 0)
plugin.ui.document = nil
local ok, message = M.save(session, "title", "  新书名  ")
check("保存书名去除首尾空白", ok and disk.custom_props.title == "新书名")
check("提示明确仅本机元数据", message:find("原 EPUB 文件不变", 1, true) ~= nil)
check("保存后按原生协议刷新缓存", resets == 1 and events[1].name == "InvalidateMetadataCache"
    and events[2].name == "BookMetadataChanged" and events[2].arg.filepath == session.file)
check("书籍文件身份和原属性保留", state.id == session.snapshot.id and state.size == 2048
    and disk.doc_props.title == "原书名")
session = assert(M.open(plugin, "/books/test.epub", deps))
check("重新打开能读到已保存内容", session.props.title == "新书名")
disk.custom_props.keywords = "其他界面保存的标签"
check("保存作者保留其他字段", M.save(session, "authors", "甲\n乙")
    and disk.custom_props.title == "新书名" and disk.custom_props.keywords == "其他界面保存的标签")
check("丛书序号使用数字类型", M.save(session, "series_index", "1.5") and disk.custom_props.series_index == 1.5)
local count = saves
check("拒绝非数字序号", not M.save(session, "series_index", "第一卷") and saves == count)
check("拒绝无限数值", not M.save(session, "series_index", "1e9999") and saves == count)
check("拒绝空书名", not M.save(session, "title", "  ") and saves == count)
check("拒绝任意字段写入", not M.save(session, "book_id", "bad") and saves == count)
check("拒绝控制字符", not M.save(session, "title", "hello" .. string.char(0)) and saves == count)
check("拒绝超长输入", not M.save(session, "description", string.rep("x", 65537)) and saves == count)
check("简介可以多行", M.save(session, "description", "第一段\n第二段") and disk.custom_props.description == "第一段\n第二段")
check("单字段恢复原值保留其他自定义内容", M.save(session, "title", nil)
    and disk.custom_props.title == nil and disk.custom_props.authors == "甲\n乙" and session.props.title == "原书名")
state.modification = 200; count = saves
check("文件修改后拒绝迟到保存", not M.save(session, "title", "错书") and saves == count)
state.modification = 100; state.id = string.rep("b", 32)
check("同路径另一版本也拒绝写入", not M.save(session, "title", "错书") and saves == count)
state = nil
check("文件删除后不创建孤立元数据", not M.save(session, "title", "错书") and saves == count)
reset(); session = assert(M.open(plugin, "/books/test.epub", deps))
error_mode = "exception"
check("原生保存异常可报告", not M.save(session, "title", "新标题") and resets == 0)
error_mode = "silent"
check("原生静默写入失败由回读发现", not M.save(session, "title", "新标题") and resets == 0)
error_mode = nil
assert(M.save(session, "title", "新标题"))
check("最后一个字段恢复后移除自定义内容", M.save(session, "title", nil) and disk == nil)
reset(); session = assert(M.open(plugin, "/books/test.epub", deps))
check("表单顺序匹配书名作者分类系列", #M.form_fields == 4 and M.form_fields[1].text == "书名"
    and M.form_fields[2].text == "作者" and M.form_fields[3].key == "keywords" and M.form_fields[4].key == "series")
check("表单一次保存四字段", M.saveForm(session, { "新书名", "新作者", "小说", "系列一" })
    and saves == 1 and disk.custom_props.title == "新书名" and disk.custom_props.authors == "新作者"
    and disk.custom_props.keywords == "小说" and disk.custom_props.series == "系列一")
check("批量保存保留原始元数据", disk.doc_props.title == "原书名" and disk.doc_props.language == "zh")
check("原值提交不重复写磁盘", M.saveForm(session, { "新书名", "新作者", "小说", "系列一" }) and saves == 1)
disk.custom_props.description = "其他字段的简介"
check("表单修改保留非表单字段", M.saveForm(session, { "新书名", "作者二", "小说", "系列一" })
    and disk.custom_props.description == "其他字段的简介")
count = saves
check("表单任一字段无效时全部不保存", not M.saveForm(session, { "下一书名", "作者二", "小说", "坏" .. string.char(0) })
    and saves == count and disk.custom_props.title == "新书名")
check("表单空书名不保存", not M.saveForm(session, { "", "作者二", "小说", "系列一" }) and saves == count)
check("表单缺字段不保存", not M.saveForm(session, { "书名" }) and saves == count)
state.size = 4096
check("表单保存同样核对原书身份", not M.saveForm(session, { "下一书名", "作者二", "小说", "系列一" }) and saves == count)
state.size = 2048; error_mode = "refuse"
check("表单磁盘拒绝不会报成功", not M.saveForm(session, { "下一书名", "作者二", "小说", "系列一" }))
error_mode = "silent"
check("表单落盘静默失败由回读发现", not M.saveForm(session, { "下一书名", "作者二", "小说", "系列一" }))
error_mode = nil
local shown, closed, last_form
package.preload["device"] = function() return { screen = { scaleBySize = function(_, n) return n end,
    getWidth = function() return 420 end } } end
package.preload["ui/font"] = function() return { getFace = function() return {} end } end
package.preload["ui/uimanager"] = function() return { show = function(_, dialog) shown = dialog end,
    close = function(_, dialog) closed = dialog end, nextTick = function(_, callback) callback() end } end
package.preload["inkbridge_material"] = function() return { widget = function(kind) return { new = function(_, opts)
    opts.kind = kind
    if kind == "multiinputdialog" then last_form = opts end
    opts.onShowKeyboard = function(self) self.keyboard = true end
    return opts
end } end } end
local native_open, native_save = M.open, M.saveForm
M.open = function() return session end
M.show(plugin, session.file)
local form = shown
check("点击元数据直接打开多输入表单", form.kind == "multiinputdialog" and #form.fields == 4 and form.keyboard)
check("表单预填已有信息并声明本机范围", form.fields[1].text == "新书名" and form.fields[2].text == "作者二"
    and form.title:find("仅本机", 1, true) ~= nil)
check("表单只包含取消和保存两个主按钮", #form.buttons[1] == 2
    and form.buttons[1][1].text == "取消" and form.buttons[1][2].text == "保存")
form.buttons[1][1].callback()
check("取消关闭表单且不修改数据", closed == form and disk.custom_props.title == "新书名")
local submitted
M.saveForm = function(_, fields) submitted = fields; return true, "已保存" end
form.getFields = function() return { "表单书名", "表单作者", "分类", "系列" } end
form.buttons[1][2].callback()
check("保存一次提交四字段并关闭表单", #submitted == 4 and submitted[1] == "表单书名" and closed == form)
form:onSetDimensions()
check("表单尺寸变化重新排版并保留未保存输入", shown.kind == "multiinputdialog"
    and shown.fields[1].text == "表单书名" and shown.fields[4].text == "系列" and closed == form)
form = shown
form.getFields = function() return { "草稿书名", "草稿作者", "草稿分类", "草稿系列" } end
check("元信息表单内提供文件名编辑", #form.buttons == 2 and form.buttons[2][1].text == "编辑文件名")
form.buttons[2][1].callback()
local rename_input = shown
check("内嵌改名保留当前文件全名及扩展名", rename_input.kind == "inputdialog" and rename_input.input == "test.epub")
local rename_target, reopened
deps.Files.rename = function(snapshot, name, current)
    rename_target = { snapshot = snapshot, name = name, current = current }
    return false, "同名文件已存在，未覆盖。"
end
rename_input.getInputText = function() return "新文件名.epub" end
rename_input.buttons[1][2].callback()
check("改名失败保留编辑器并显示原因", shown.text == "同名文件已存在，未覆盖。" and closed ~= form
    and rename_target.snapshot == session.snapshot and rename_target.name == "新文件名.epub")
deps.Files.rename = function() return true, "文件已改名。", "/books/新文件名.epub" end
M.open = function(_, path, passed_deps)
    reopened = path
    check("改名后继续使用同一组原生依赖", passed_deps == deps)
    session.file = path
    session.snapshot.file = path
    return session
end
rename_input.buttons[1][2].callback()
check("成功改名后按新路径重新建立编辑会话", reopened == "/books/新文件名.epub"
    and shown.text:find("未保存的元信息仍保留", 1, true) ~= nil)
check("改名重建表单保留全部未保存草稿", last_form.fields[1].text == "草稿书名"
    and last_form.fields[2].text == "草稿作者" and last_form.fields[3].text == "草稿分类"
    and last_form.fields[4].text == "草稿系列")
M.open, M.saveForm = native_open, native_save
print(string.format("合计：%d 通过，%d 失败", passed, failed))
os.exit(failed == 0 and 0 or 1)
