-- TXT 的 Moon+ 坐标独立于 EPUB：原文 UTF-16 块起点 + 显示文本块内偏移。
-- CRLF、段落缩进会改变块内文本；必须按明确配置换算，不能按百分比猜位置。
local Moon = require("inkbridge_moon")
local Txt = {}
local MAX_BYTES = 64 * 1024 * 1024
local cache

function Txt.is_txt(path)
    return type(path) == "string" and path:lower():match("%.txt$") ~= nil
end

local function utf8_char(cp)
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64) end
    if cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
    end
    return string.char(0xF0 + math.floor(cp / 262144), 0x80 + math.floor(cp / 4096) % 64,
        0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
end

-- 严格 UTF-8：拒绝过长编码、孤立续字节、代理项及越过 Unicode 上限的码点。
local function next_char(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    if not a then return nil end
    if a < 0x80 then return i + 1, a end
    if not b or b < 0x80 or b > 0xBF then return nil end
    if a >= 0xC2 and a <= 0xDF then return i + 2, (a - 0xC0) * 64 + b - 0x80 end
    if not c or c < 0x80 or c > 0xBF then return nil end
    if a >= 0xE0 and a <= 0xEF and not (a == 0xE0 and b < 0xA0)
            and not (a == 0xED and b >= 0xA0) then
        return i + 3, (a - 0xE0) * 4096 + (b - 0x80) * 64 + c - 0x80
    end
    if not d or d < 0x80 or d > 0xBF then return nil end
    if a >= 0xF0 and a <= 0xF4 and not (a == 0xF0 and b < 0x90)
            and not (a == 0xF4 and b > 0x8F) then
        return i + 4, (a - 0xF0) * 262144 + (b - 0x80) * 4096 + (c - 0x80) * 64 + d - 0x80
    end
end

local function whitespace(cp)
    return cp == 32 or (cp >= 9 and cp <= 13)
end

local function valid_utf8(s)
    local i = 1
    while i <= #s do
        local n = next_char(s, i)
        if not n then return false end
        i = n
    end
    return true
end

local gb_data, gb_rows
local function decode_gb(s)
    if not gb_data then gb_data = require("inkbridge_gb18030"); gb_rows = {} end
    local out, chunks, i = {}, {}, 1
    while i <= #s do
        local a, b, c, d = s:byte(i, i + 3)
        if a < 0x80 then
            out[#out + 1], i = string.char(a), i + 1
        elseif a >= 0x81 and a <= 0xFE and b then
            if b >= 0x30 and b <= 0x39 then
                if not c or c < 0x81 or c > 0xFE or not d or d < 0x30 or d > 0x39 then
                    return nil, "TXT 包含无效的 GB18030 四字节序列"
                end
                local pointer = (((a - 0x81) * 10 + b - 0x30) * 126 + c - 0x81) * 10 + d - 0x30
                local lo, hi, cp = 1, #gb_data.ranges
                while lo <= hi do
                    local mid = math.floor((lo + hi) / 2)
                    local r = gb_data.ranges[mid]
                    if pointer < r[1] then hi = mid - 1
                    elseif pointer > r[2] then lo = mid + 1
                    else cp = r[3] + pointer - r[1]; break end
                end
                if not cp then return nil, "TXT 包含未分配的 GB18030 字符" end
                out[#out + 1], i = utf8_char(cp), i + 4
            elseif b >= 0x40 and b <= 0xFE and b ~= 0x7F then
                local lead = a - 0x80
                if not gb_rows[lead] then
                    local row, chars, p = gb_data.rows[lead], {}, 1
                    while p <= #row do
                        local n = next_char(row, p)
                        chars[#chars + 1], p = row:sub(p, n - 1), n
                    end
                    gb_rows[lead] = chars
                end
                local trail = b < 0x7F and b - 0x3F or b - 0x40
                out[#out + 1], i = gb_rows[lead][trail], i + 2
            else return nil, "TXT 包含无效的 GB18030 双字节序列" end
        else return nil, "TXT 不是有效 UTF-8 / GB18030 文本" end
        -- 分批合并，避免长篇 GB18030 每个字符永久占一个 Lua 表槽。
        if #out >= 4096 then chunks[#chunks + 1], out = table.concat(out), {} end
    end
    chunks[#chunks + 1] = table.concat(out)
    return table.concat(chunks), "GB18030"
end

local function decode_utf16(s, little)
    if #s % 2 ~= 0 then return nil, "TXT 的 UTF-16 字节不完整" end
    local function word(i)
        local a, b = s:byte(i, i + 1)
        return little and (a + b * 256) or (a * 256 + b)
    end
    local out, chunks, i = {}, {}, 3
    while i <= #s do
        local cp = word(i)
        i = i + 2
        if cp >= 0xD800 and cp <= 0xDBFF then
            if i > #s then return nil, "TXT 的 UTF-16 代理对不完整" end
            local low = word(i)
            if low < 0xDC00 or low > 0xDFFF then return nil, "TXT 的 UTF-16 代理对无效" end
            cp, i = 0x10000 + (cp - 0xD800) * 1024 + low - 0xDC00, i + 2
        elseif cp >= 0xDC00 and cp <= 0xDFFF then return nil, "TXT 包含孤立 UTF-16 代理项" end
        out[#out + 1] = utf8_char(cp)
        if #out >= 4096 then chunks[#chunks + 1], out = table.concat(out), {} end
    end
    chunks[#chunks + 1] = table.concat(out)
    return table.concat(chunks), little and "UTF-16LE" or "UTF-16BE"
end

function Txt.from_bytes(bytes)
    if type(bytes) ~= "string" or bytes == "" then return nil, "TXT 为空或读不到内容" end
    if #bytes > MAX_BYTES then return nil, "TXT 超过 64 MiB 安全上限" end
    local text, encoding
    if bytes:sub(1, 4) == "\255\254\0\0" or bytes:sub(1, 4) == "\0\0\254\255" then
        return nil, "暂不支持 UTF-32 TXT"
    elseif bytes:sub(1, 2) == "\255\254" then text, encoding = decode_utf16(bytes, true)
    elseif bytes:sub(1, 2) == "\254\255" then text, encoding = decode_utf16(bytes, false)
    elseif bytes:sub(1, 3) == "\239\187\191" then
        text, encoding = bytes:sub(4), "UTF-8 BOM"
        if not valid_utf8(text) then return nil, "TXT 的 UTF-8 BOM 与正文编码不符" end
    elseif valid_utf8(bytes) then text, encoding = bytes, "UTF-8"
    else text, encoding = decode_gb(bytes) end
    if not text then return nil, encoding end
    if text == "" then return nil, "TXT 没有正文" end
    local checkpoints, i, units, compact_byte = {}, 1, 0, 1
    local next_checkpoint = 0
    while i <= #text do
        local n, cp = next_char(text, i)
        if not n or cp == 0 or (cp < 32 and not whitespace(cp)) then
            return nil, "TXT 含有无效字符或二进制控制符"
        end
        if units >= next_checkpoint then
            checkpoints[#checkpoints + 1] = { byte = i, units = units, compact = compact_byte }
            next_checkpoint = units + 4096
        end
        if not whitespace(cp) then compact_byte = compact_byte + n - i end
        units, i = units + (cp > 0xFFFF and 2 or 1), n
    end
    local compact = Moon.compact(text)
    if compact == "" then return nil, "TXT 没有可核对的正文" end
    return { text = text, compact = compact, total = units, checkpoints = checkpoints, encoding = encoding }
end

function Txt.read(path)
    local stamp
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok and type(lfs.attributes) == "function" then
        local aok, attr = pcall(lfs.attributes, path)
        if aok and type(attr) == "table" then
            if tonumber(attr.size) and attr.size > MAX_BYTES then return nil, "TXT 超过 64 MiB 安全上限" end
            stamp = tostring(attr.size) .. ":" .. tostring(attr.modification) .. ":" .. tostring(attr.change)
        end
    end
    if stamp and cache and cache.path == path and cache.stamp == stamp then return cache.model end
    local f = io.open(path, "rb")
    if not f then return nil, "无法打开 TXT 原文件" end
    local bytes = f:read(MAX_BYTES + 1)
    f:close()
    local model, err = Txt.from_bytes(bytes)
    if model then cache = { path = path, stamp = stamp, model = model } end
    return model, err
end

local function checkpoint(model, value, key)
    local points = model.checkpoints
    local lo, hi, found = 1, #points, points[1]
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        if points[mid][key] <= value then found, lo = points[mid], mid + 1 else hi = mid - 1 end
    end
    return found
end

local function byte_at_units(model, offset)
    if type(offset) ~= "number" or offset < 0 or offset >= model.total or offset ~= math.floor(offset) then
        return nil, "TXT 字符偏移超出正文范围"
    end
    local cp = checkpoint(model, offset, "units")
    local i, units = cp.byte, cp.units
    while units < offset do
        local n, code = next_char(model.text, i)
        units, i = units + (code > 0xFFFF and 2 or 1), n
    end
    if units ~= offset then return nil, "TXT 字符偏移落在 UTF-16 代理对中间" end
    return i
end

local function units_at_compact_byte(model, target)
    local cp = checkpoint(model, target, "compact")
    local i, units, compact_byte = cp.byte, cp.units, cp.compact
    while i <= #model.text do
        local n, code = next_char(model.text, i)
        if not whitespace(code) then
            if compact_byte == target then return units end
            compact_byte = compact_byte + n - i
        end
        units, i = units + (code > 0xFFFF and 2 or 1), n
    end
end

local function source_slice(model, start, count)
    local a, err = byte_at_units(model, start)
    if not a then return nil, err end
    local finish = math.min(model.total, start + count)
    local b = finish == model.total and (#model.text + 1) or byte_at_units(model, finish)
    if not b then return nil, "TXT 分块边界落在 UTF-16 代理对中间，暂不支持" end
    return model.text:sub(a, b - 1)
end

-- Moon+ 10.7 isTxtDoubleBreak：在第二块检测已有双换行，不能按全书比例替代。
local function double_break(model, size)
    local s, err = source_slice(model, model.total > size and size or 0, size)
    if not s then return nil, err end
    local sep = s:find("\r\n", 1, true) and "\r\n" or "\n"
    -- Java String.length / substring 使用 UTF-16 单元，不是 Unicode 码点。
    local units, byte, sample_byte = 0, 1, nil
    while byte <= #s do
        if units >= 500 and not sample_byte then sample_byte = byte end
        local following, cp = next_char(s, byte)
        units, byte = units + (cp > 0xFFFF and 2 or 1), following
    end
    if units > 2000 then
        local p = s:find(sep, sample_byte or (#s + 1), true)
        if p then s = s:sub(p + #sep) end
    end
    local function count(needle)
        local n, p = 0, 1
        while true do
            local a = s:find(needle, p, true)
            if not a then return n end
            n, p = n + 1, a + #needle
        end
    end
    return count(sep .. sep) > math.floor(count(sep) / 4)
end

-- 只缓存最近一个块的显示单元→原文单元映射；大书不会为每字常驻一个表槽。
local function display_block(model, block, profile)
    if type(profile) ~= "table" or (profile.block_size ~= 4096 and profile.block_size ~= 8192)
            or type(profile.indent) ~= "boolean" then return nil, "TXT 设备/缩进配置无效" end
    local key = tostring(profile.block_size) .. ":" .. tostring(profile.indent) .. ":" .. tostring(block)
    if model.display_cache and model.display_cache.key == key then return model.display_cache end
    local start = block * profile.block_size
    local raw, err = source_slice(model, start, profile.block_size)
    if not raw then return nil, err end
    local tokens, i, unit = {}, 1, start
    while i <= #raw do
        local n, cp = next_char(raw, i)
        local width = cp > 0xFFFF and 2 or 1
        if cp == 13 then
            cp = 10
            if raw:byte(n) == 10 then n, width = n + 1, width + 1 end
        end
        if profile.indent and (cp == 160 or cp == 12288 or cp == 9) then cp = 32 end
        local prev = tokens[#tokens]
        if not (profile.indent and cp == 32 and (not prev or prev.cp == 32 or prev.cp == 10)) then
            tokens[#tokens + 1] = { cp = cp, source = unit }
        end
        unit, i = unit + width, n
    end
    if profile.indent then
        local double, derr = double_break(model, profile.block_size)
        if double == nil then return nil, derr end
        if not double then
            local expanded = {}
            for _, t in ipairs(tokens) do
                expanded[#expanded + 1] = t
                if t.cp == 10 then expanded[#expanded + 1] = t end
            end
            tokens = expanded
            -- Java String.replace 的两轮非重叠三换二，不是任意长度连续空行全压成二。
            for _ = 1, 2 do
                local out, p = {}, 1
                while p <= #tokens do
                    out[#out + 1] = tokens[p]
                    if tokens[p].cp == 10 and tokens[p + 1] and tokens[p + 1].cp == 10
                            and tokens[p + 2] and tokens[p + 2].cp == 10 then
                        out[#out + 1], p = tokens[p + 1], p + 3
                    else p = p + 1 end
                end
                tokens = out
            end
        end
    end
    local map, chars = {}, {}
    for _, t in ipairs(tokens) do
        chars[#chars + 1] = utf8_char(t.cp)
        map[#map + 1] = t.source
        if t.cp > 0xFFFF then map[#map + 1] = false end
    end
    local result = { key = key, map = map, text = table.concat(chars), start = start }
    model.display_cache = result
    return result
end

function Txt.source_offset(model, offset, profile)
    if not profile then return offset end -- 原文层接口，仅供独立解码测试；同步调用始终传明确配置。
    if type(profile) ~= "table" or (profile.block_size ~= 4096 and profile.block_size ~= 8192)
            or type(profile.indent) ~= "boolean" then return nil, "TXT 设备/缩进配置无效" end
    if type(offset) ~= "number" or offset < 0 or offset >= model.total or offset ~= math.floor(offset) then
        return nil, "TXT 字符偏移超出正文范围"
    end
    local block, err = display_block(model, math.floor(offset / profile.block_size), profile)
    if not block then return nil, err end
    local source = block.map[offset % profile.block_size + 1]
    if source == false then return nil, "TXT 显示偏移落在 UTF-16 代理对中间" end
    if not source then return nil, "TXT 块内偏移超出显示文本，请核对 Moon+ 设备和缩进设置" end
    return source
end

function Txt.position(model, po, snippet_len, tolerance, profile)
    if type(po) ~= "table" or po.star ~= 0 or po.at ~= 0 then
        return nil, "TXT 暂只支持静读天下 *0@0 的整书字符坐标"
    end
    if type(po.hash) ~= "number" or po.hash < 0 or po.hash >= model.total or po.hash ~= math.floor(po.hash) then
        return nil, "TXT 字符偏移超出正文范围"
    end
    local source, serr = Txt.source_offset(model, po.hash, profile)
    if not source then return nil, serr end
    local i, ierr = byte_at_units(model, source)
    if not i then return nil, ierr end
    local pct = po.hash / model.total
    if type(po.pct) ~= "number" or po.pct ~= po.pct or math.abs(pct * 100 - po.pct) > (tolerance or 1) then
        return nil, "TXT 百分比与原文字符坐标不一致（可能编码或文件版本不同）"
    end
    -- 行尾/CRLF 是合法阅读坐标：同段向前借字，不越过换行拼接另一段或漏读后文。
    local at_newline = model.text:sub(i, i):match("[\r\n]") ~= nil
    local begin = at_newline and i or model.text:find("%S", i)
    if at_newline and model.text:sub(i, i) == "\n" and model.text:sub(i - 1, i - 1) == "\r" then begin = i - 1 end
    if not begin or begin - i > 256 then return nil, "TXT 目标附近没有可核对的正文" end
    local ending = at_newline and begin or (model.text:find("[\r\n]", begin) or (#model.text + 1))
    local snippet = Moon.utf8_sub(model.text:sub(begin, ending - 1), 1, snippet_len or 48)
    snippet = snippet:gsub("%s+$", "")
    if Moon.utf8_len(Moon.compact(snippet)) < 8 then
        local from = math.max(1, begin - 4096)
        while from < begin and model.text:byte(from) >= 0x80 and model.text:byte(from) < 0xC0 do from = from + 1 end
        local before = model.text:sub(from, begin - 1)
        local last = before:match(".*()[\r\n]")
        if last then before = before:sub(last + 1) end
        local line = before .. model.text:sub(begin, ending - 1)
        local length = Moon.utf8_len(line)
        snippet = Moon.utf8_sub(line, math.max(1, length - (snippet_len or 48) + 1), snippet_len or 48)
        snippet = snippet:gsub("^%s+", ""):gsub("%s+$", "")
    end
    local anchor_note
    if Moon.utf8_len(Moon.compact(snippet)) < 8 then
        -- 短独立段（如“轰——！”）不能用作唯一锚点。只允许紧邻前一非空段，且必须再次确认。
        -- 不取下一段（会漏读），不在全书找“附近”，也不静默伪装成精确落点。
        local from = math.max(1, i - 4096)
        local before = model.text:sub(from, i - 1)
        before = before:match("^(.*)[\r\n][^\r\n]*$")
        before = before and before:gsub("[\r\n]+$", "")
        if from > 1 and before and not before:find("[\r\n]") then before = nil end
        local previous = before and before:match("([^\r\n]+)$")
        if previous then snippet = Moon.utf8_sub(previous:gsub("^%s+", ""), 1, snippet_len or 48) end
        if not previous or Moon.utf8_len(Moon.compact(snippet)) < 8 then
            return nil, "TXT 目标行正文过短，且紧邻前一段也无法可靠定位"
        end
        anchor_note = "TXT 目标所在短段不足 8 字，不能精确定位。\n可退到紧邻前一段开头，可能需要重读一段；不会跳过目标内容。"
    end
    return { character_offset = po.hash, source_offset = source, total = model.total, character_percent = pct,
        snippet = snippet, anchor_note = anchor_note }
end

-- crengine 返回完整文本节点，text().N 是 Unicode 码点偏移，不是 Moon+ 的 UTF-16 单元。
-- 用节点中当前位置之后的文字在源 TXT 唯一匹配，再将 compact 坐标还原为含换行的源坐标。
function Txt.document_position(model, doc, profile)
    if type(doc.getXPointer) ~= "function" or type(doc.getTextFromXPointer) ~= "function" then
        return nil, "TXT 写回需要本机文本节点核对接口"
    end
    local ok, xp = pcall(doc.getXPointer, doc)
    local offset = ok and type(xp) == "string" and tonumber(xp:match("text%(%)[.]([0-9]+)$"))
    if not offset then return nil, "TXT 当前页首没有可靠的文本节点偏移" end
    local tok, here = pcall(doc.getTextFromXPointer, doc, xp)
    if not tok or type(here) ~= "string" or offset >= Moon.utf8_len(here) then
        return nil, "TXT 当前文本节点无法核对"
    end
    local probe = Moon.compact(Moon.utf8_sub(here, offset + 1, 64))
    if Moon.utf8_len(probe) < 8 then return nil, "TXT 当前节点剩余正文过短，拒绝写回" end
    local first = model.compact:find(probe, 1, true)
    if not first then return nil, "TXT 写入前自检未通过：本机文字与源文件不一致" end
    if model.compact:find(probe, first + 1, true) then return nil, "TXT 写入前自检未通过：正文多次出现" end
    local units = units_at_compact_byte(model, first)
    if not units then return nil, "TXT 源文件字符坐标无法还原" end
    if profile then
        local source_units = units
        if type(profile) ~= "table" or (profile.block_size ~= 4096 and profile.block_size ~= 8192)
                or type(profile.indent) ~= "boolean" then return nil, "TXT 设备/缩进配置无效" end
        local block, err = display_block(model, math.floor(units / profile.block_size), profile)
        if not block then return nil, err end
        local display
        for j, source in ipairs(block.map) do
            if source == units then display = j - 1; break end
        end
        if not display or display >= profile.block_size then
            return nil, "TXT 当前原文无法无损表示为 Moon+ 块内坐标，拒绝写回"
        end
        units = block.start + display
        local back = Txt.source_offset(model, units, profile)
        if back ~= source_units then
            return nil, "TXT 块内坐标往返核对失败"
        end
    end
    return { section = 0, hash = units, total = model.total, checked = "已通过（源 TXT 全文唯一）" }
end

return Txt
