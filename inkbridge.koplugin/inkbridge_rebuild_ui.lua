-- 重构操作仅由用户点击触发，不随开书执行，不接管原书进度或同步身份。
local RebuildUI = {}
local active = false

local function message(text)
    require("ui/uimanager"):show(require("inkbridge_material").widget("infomessage"):new{ text = text })
end

-- 工作目录通过 mkdir 独占，重复生成自动换名，不覆盖旧副本。
function RebuildUI.reserve(source, lfs)
    lfs = lfs or require("libs/libkoreader-lfs")
    local stem = source:gsub("%.[^/\\%.]+$", "") .. "－墨桥重构版"
    for i = 1, 999 do
        local dest = stem .. (i == 1 and "" or "-" .. i) .. ".epub"
        if not lfs.attributes(dest) then
            local work = dest .. ".work"
            if lfs.mkdir(work) then return dest, work end
            if not lfs.attributes(work) then return nil, "原书所在目录无法写入" end
        end
    end
    return nil, "同名副本过多，请先整理文件"
end

function RebuildUI.publish(workfile, dest, lfs)
    lfs = lfs or require("libs/libkoreader-lfs")
    if lfs.attributes(dest) then return nil, "目标文件已存在，未覆盖" end
    if lfs.attributes(workfile, "mode") ~= "file" then return nil, "没有生成完整的副本" end
    return os.rename(workfile, dest)
end

function RebuildUI.run(plugin, source, recognize)
    if active then message("书籍重构正在进行，请稍候。也可以点击进度提示取消。"); return end
    local lfs = require("libs/libkoreader-lfs")
    local Trapper = require("ui/trapper")
    local Rebuild = require("inkbridge_rebuild")
    local Progress = require("inkbridge_rebuild_progress")
    local headings = {}
    local doc = plugin.ui and plugin.ui.document
    if doc and doc.file == source and type(doc.getToc) == "function" then
        local ok, toc = pcall(doc.getToc, doc)
        if ok and type(toc) == "table" then
            for _, item in ipairs(toc) do
                if type(item) == "table" and type(item.title) == "string" then
                    headings[Rebuild.normalize_text(item.title)] = true
                end
            end
        end
    end
    Trapper:wrap(function()
        local dest, work = RebuildUI.reserve(source, lfs)
        if not dest then message("墨桥：" .. work); return end
        active = true
        local workfile, progress_path = work .. "/book.epub", work .. "/progress"
        local stop_progress
        local ok, completed, result, err = pcall(function()
            local progress_widget
            progress_widget, stop_progress = Progress.show(progress_path)
            return Trapper:dismissableRunInSubprocess(function()
                return Rebuild.convert(source, workfile,
                    { recognize = recognize, headings = headings, progress = Progress.writer(progress_path) })
            end, progress_widget)
        end)
        if stop_progress then
            local stopped, stop_err = pcall(stop_progress)
            if not stopped then require("logger").warn("墨桥重构进度关闭失败", stop_err) end
        end
        local published, publish_err
        if ok and completed and type(result) == "table" then
            local publish_ok, value, reason = pcall(RebuildUI.publish, workfile, dest, lfs)
            if publish_ok then published, publish_err = value, reason else publish_err = value end
        end
        -- 子进程只写工作目录；即使恰在完成时取消，也不会发布半成品。
        os.remove(workfile)
        os.remove(progress_path)
        os.remove(progress_path .. ".part")
        lfs.rmdir(work)
        active = false
        if not ok then message("墨桥：重构失败\n" .. tostring(completed)); return end
        if not completed then message("已取消书籍重构，原书保留。"); return end
        if not published then message("墨桥：重构失败\n" .. tostring(publish_err or err or "转换进程未返回结果")); return end
        local dialog
        local UIManager = require("ui/uimanager")
        dialog = require("inkbridge_material").widget("buttondialog"):new{
            title = "重构完成\n" .. result.sections .. " 个章节，" .. result.paragraphs .. " 个正文段落\n"
                .. "副本：" .. dest .. "\n请将同一份副本复制到其他设备，再建立同步记录。",
            buttons = {
                {{ text = "打开重构副本", callback = function()
                    UIManager:close(dialog)
                    -- 按新文件正常开书，不把原书的 xpointer 或 .po 搬过去。
                    require("apps/reader/readerui"):showReader(dest)
                end }},
                {{ text = "完成", callback = function() UIManager:close(dialog) end }},
            },
        }
        UIManager:show(dialog)
    end)
end

function RebuildUI.show(plugin)
    if active then message("书籍重构正在进行，请稍候。"); return end
    local source = plugin.ui and plugin.ui.document and plugin.ui.document.file
    if type(source) ~= "string" or not source:lower():match("%.epub$") then
        message("请先打开一本 EPUB 小说，再使用书籍重构。"); return
    end
    local UIManager = require("ui/uimanager")
    local dialog
    local function start(recognize)
        UIManager:close(dialog)
        RebuildUI.run(plugin, source, recognize)
    end
    dialog = require("inkbridge_material").widget("buttondialog"):new{
        title = "书籍重构\n提取纯文字，保留段落，另存 EPUB；原书保留。\n"
            .. "图片、原样式和脚注跳转会移除，适合纯文字小说。\n"
            .. "重新识别章节：按目录、标题和章名重新划分。\n"
            .. "按原正文文件分章：每个内部正文文件一章，可能与原目录不同。\n"
            .. "副本作为新书同步，原记录不直接套用。",
        buttons = {
            {{ text = "重新识别章节", callback = function() start(true) end }},
            {{ text = "按原正文文件分章", callback = function() start(false) end }},
            {{ text = "取消", callback = function() UIManager:close(dialog) end }},
        },
    }
    UIManager:show(dialog)
end

return RebuildUI
