-- 子进程只写小型进度快照，主进程更新界面；不跨进程访问 UIManager。
local Progress = {}
local stages = { prepare = true, text = true, package = true, verify = true }

function Progress.describe(stage, done, total)
    if not stages[stage] or not done or not total or done < 0 or total < 0 or done > total then return nil end
    local fraction = total > 0 and done / total or 0
    local percent, text
    if stage == "prepare" then percent, text = 0, "正在读取原书结构…"
    elseif stage == "text" then
        percent = math.floor(fraction * 90)
        text = string.format("提取文字与分章\n已处理 %d／%d 个正文文件", done, total)
    elseif stage == "package" then percent, text = 90, "正在生成 EPUB 目录…"
    else
        percent = math.min(99, 90 + math.floor(fraction * 10))
        text = string.format("校验重构副本\n已校验 %d／%d 个文件", done, total)
    end
    return percent, text
end

function Progress.writer(path, clock)
    clock = clock or require("socket").gettime
    local last_stage, last_time = nil, -math.huge
    return function(stage, done, total)
        local now = clock()
        -- 阶段变化立即落盘，阶段内最多每秒一次；末项也要报告。
        if stage == last_stage and done ~= total and now - last_time < 1 then return end
        local file = assert(io.open(path .. ".part", "wb"))
        assert(file:write(string.format("%s %d %d", stage, done, total)))
        assert(file:close())
        assert(os.rename(path .. ".part", path))
        last_stage, last_time = stage, now
    end
end

function Progress.read(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local raw = file:read(128)
    file:close()
    local stage, done, total = (raw or ""):match("^(%a+) (%d+) (%d+)$")
    return Progress.describe(stage, tonumber(done), tonumber(total))
end

function Progress.show(path)
    local Screen = require("device").screen
    local UIManager = require("ui/uimanager")
    local Font = require("ui/font")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local Geom = require("ui/geometry")
    local px = function(n) return Screen:scaleBySize(n) end
    local width = math.floor(Screen:getWidth() * 0.8)
    local detail = TextBoxWidget:new{ text = "正在读取原书结构…\n0%", width = width,
        face = Font:getFace("cfont", 16), height = px(84), height_adjust = false }
    local bar = require("ui/widget/progresswidget"):new{ width = width, height = px(6), percentage = 0 }
    -- 使用原生 TrapWidget 的全屏输入拦截和取消语义，自己绘制固定尺寸的进度卡片。
    local trap = require("ui/widget/trapwidget"):new{ text = nil }
    trap.invisible = false
    trap.frame = require("ui/widget/container/framecontainer"):new{
        background = require("ffi/blitbuffer").COLOR_WHITE, padding = px(24), margin = 0,
        radius = px(24), bordersize = px(1),
        VerticalGroup:new{ align = "left",
            TextBoxWidget:new{ text = "书籍重构", width = width, face = Font:getFace("cfont", 24), bold = true },
            VerticalSpan:new{ width = px(12) }, detail, bar, VerticalSpan:new{ width = px(16) },
            TextBoxWidget:new{ text = "点击取消重构，原书保留", width = width, face = Font:getFace("cfont", 14) },
        },
    }
    trap[1] = require("ui/widget/container/centercontainer"):new{
        dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() }, trap.frame,
    }
    local last, stopped = nil, false
    local function update()
        if stopped then return end
        local percent, text = Progress.read(path)
        local label = percent and text .. "\n" .. percent .. "%"
        if label and label ~= last then
            detail:setText(label)
            bar:setPercentage(percent / 100)
            UIManager:setDirty(trap, "ui", trap.frame.dimen)
            last = label
        end
        UIManager:scheduleIn(1, update)
    end
    UIManager:show(trap)
    UIManager:forceRePaint()
    UIManager:scheduleIn(1, update)
    return trap, function()
        stopped = true
        UIManager:unschedule(update)
        UIManager:close(trap)
    end
end

return Progress
