-- 只读原书，给同步短锚点补充真实章节和正文选段；绝不改动跳转锚点。
local Rebuild = require("inkbridge_rebuild")
local Preview = { VERSION = 1 }
local MAX_EXCERPT = 220

local function compact(text) return Rebuild.normalize_text(text):gsub("%s+", "") end
local function short(text, count)
    local chars, last = 0, 0
    for i = 1, #text do
        local byte = text:byte(i)
        if byte < 128 or byte >= 192 then
            chars = chars + 1
            if chars > count then return text:sub(1, last) end
        end
        last = i
    end
    return text
end
local function char_count(text)
    local count = 0
    for i = 1, #text do local b = text:byte(i); if b < 128 or b >= 192 then count = count + 1 end end
    return count
end
local function original_offset(text, compact_offset)
    local kept = 0
    for i = 1, #text do
        if not text:sub(i, i):match("%s") then
            kept = kept + 1
            if kept == compact_offset then return i end
        end
    end
    return #text + 1
end

-- 按 spine 流式处理，一份正文文件后就让出 UI；整本书唯一命中才提交结果。
function Preview.analyzer(records)
    local analyzer = { records = records, matches = {}, chapter = nil }
    for i, record in ipairs(records) do
        analyzer.matches[i] = { anchor = compact(record.text or ""), count = 0 }
    end
    local function append(candidate, segments, start, offset)
        if candidate.closed then return end
        local pieces = { candidate.excerpt or "" }
        for j = start, #segments do
            local segment = segments[j]
            if segment.heading then candidate.closed = true; break end
            local text = segment.text
            if j == start and offset then text = text:sub(original_offset(text, offset)) end
            if text ~= "" then pieces[#pieces + 1] = text end
            local joined = table.concat(pieces, " "):gsub("^%s+", "")
            if char_count(joined) >= MAX_EXCERPT then
                candidate.excerpt, candidate.closed = short(joined, MAX_EXCERPT), true
                return
            end
        end
        candidate.excerpt = short(table.concat(pieces, " "):gsub("^%s+", ""), MAX_EXCERPT)
    end
    function analyzer:feed(items)
        local segments, text, position = {}, {}, 1
        for _, paragraph in ipairs(Rebuild.join_titles(items)) do
            local heading = Rebuild.is_heading(paragraph.text, nil, paragraph.heading)
            if heading then self.chapter = paragraph.text end
            local value = compact(paragraph.text)
            segments[#segments + 1] = { text = Rebuild.normalize_text(paragraph.text), heading = heading,
                chapter = self.chapter, first = position, last = position + #value - 1 }
            text[#text + 1], position = value, position + #value
        end
        text = table.concat(text)
        for _, match in ipairs(self.matches) do
            if match.candidate then append(match.candidate, segments, 1) end
            if #match.anchor > 0 then
                local from = 1
                while true do
                    local first = text:find(match.anchor, from, true)
                    if not first then break end
                    match.count = match.count + 1
                    if match.count == 1 then
                        for i, segment in ipairs(segments) do
                            if first >= segment.first and first <= segment.last then
                                local candidate = { chapter = segment.chapter, excerpt = "" }
                                if segment.heading then
                                    -- 锚点就在标题上：选段取本章紧随其后的正文，不重复标题。
                                    append(candidate, segments, i + 1)
                                else append(candidate, segments, i, first - segment.first + 1) end
                                match.candidate = candidate
                                break
                            end
                        end
                    end
                    from = first + 1
                end
            end
        end
    end
    function analyzer:results()
        local result = {}
        for i, match in ipairs(self.matches) do
            local candidate = match.candidate
            result[i] = match.count == 1 and candidate and {
                chapter = candidate.chapter, excerpt = candidate.excerpt,
                status = candidate.excerpt ~= "" and "verified" or "no_body",
            } or { status = match.count > 1 and "ambiguous" or "missing" }
        end
        return result
    end
    return analyzer
end

function Preview.stamp(file, lfs)
    lfs = lfs or require("libs/libkoreader-lfs")
    local ok, attr = pcall(lfs.attributes, file)
    if not ok or type(attr) ~= "table" or attr.mode ~= "file" then return end
    return tostring(attr.size) .. ":" .. tostring(attr.modification) .. ":" .. tostring(attr.change)
end

function Preview.needed(book)
    if not book or type(book.book_id) ~= "string" or #book.book_id ~= 32
            or type(book.file) ~= "string" or not (book.file:lower():sub(-5) == ".epub"
                or book.file:lower():sub(-4) == ".txt") then return false end
    local stamp = Preview.stamp(book.file)
    if not stamp then return false end
    for _, record in ipairs(book.records or {}) do
        if record.preview_version ~= Preview.VERSION or record.preview_stamp ~= stamp then return true end
    end
    return false
end

function Preview.start(book, callback, deps)
    deps = deps or {}
    local UI = deps.UI or require("ui/uimanager")
    local lfs = deps.lfs or require("libs/libkoreader-lfs")
    local identify = deps.identify or require("inkbridge_state").book_id
    local stamp = Preview.stamp(book.file, lfs)
    local active, archive, initialized, spine, read, index, txt = true, nil, false, nil, nil, 0, nil
    local analyzer = Preview.analyzer(book.records)
    local function close()
        if archive then pcall(function() archive:close() end); archive = nil end
    end
    local function finish(ok, result)
        if not active then return end
        active = false
        close()
        callback(ok, result, stamp)
    end
    local function initialize()
        assert(stamp and identify(book.file) == book.book_id, "原书身份已变化")
        if book.file:lower():sub(-4) == ".txt" then
            local model = assert((deps.Txt or require("inkbridge_moontxt")).read(book.file))
            txt, index = model.text, 1
            return
        end
        archive = (deps.Archiver or require("ffi/archiver")).Reader:new()
        assert(archive:open(book.file), "无法打开原书")
        local entries, count, total = {}, 0, 0
        for entry in archive:iterate() do
            count = count + 1
            assert(count <= 30000 and not entries[entry.path], "原书归档条目无效")
            entries[entry.path] = { size = tonumber(entry.size), mode = entry.mode }
        end
        assert(not archive.err, "无法读取原书归档")
        read = function(path)
            local entry = assert(entries[path], "原书正文文件缺失")
            assert(entry.mode == "file" and entry.size and entry.size >= 0
                and entry.size <= 16 * 1024 * 1024, "原书正文条目过大")
            total = total + entry.size
            assert(total <= 256 * 1024 * 1024, "原书正文超过读取上限")
            return assert(archive:extractToMemory(path), "无法读取原书正文")
        end
        spine = Rebuild.inspect(read)
    end
    local step
    step = function()
        if not active then return end
        local ok, err = pcall(function()
            if not initialized then initialize(); initialized = true end
            if txt then
                -- TXT 按 100 行一批处理；不丢掉换行边界的正文。
                local items = {}
                for _ = 1, 100 do
                    local first, last = txt:find("[^\r\n]+", index)
                    if not first then index = #txt + 1; break end
                    items[#items + 1] = { text = txt:sub(first, last) }
                    index = last + 1
                end
                analyzer:feed(items)
                if index <= #txt then UI:nextTick(step); return end
            else
                index = index + 1
                if spine[index] then
                    analyzer:feed(Rebuild.paragraphs(read(spine[index])))
                    UI:nextTick(step)
                    return
                end
            end
            assert(Preview.stamp(book.file, lfs) == stamp and identify(book.file) == book.book_id,
                "读取期间原书已变化")
            finish(true, analyzer:results())
        end)
        if not ok then finish(false, tostring(err)) end
    end
    UI:nextTick(step)
    return function() active = false; close() end
end

return Preview
