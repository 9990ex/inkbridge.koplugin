-- 离线农历：按公历日期计日，不通过秒数相减，避免夏令时造成一天偏移。
-- 年型数据来自 solarlunar/const/lunarInfo.js，1900—2100。
-- https://github.com/yize/solarlunar （ISC，授权声明见文件末尾）
local Calendar = {}
local years = {
    0x04bd8,0x04ae0,0x0a570,0x054d5,0x0d260,0x0d950,0x16554,0x056a0,0x09ad0,0x055d2,
    0x04ae0,0x0a5b6,0x0a4d0,0x0d250,0x1d255,0x0b540,0x0d6a0,0x0ada2,0x095b0,0x14977,
    0x04970,0x0a4b0,0x0b4b5,0x06a50,0x06d40,0x1ab54,0x02b60,0x09570,0x052f2,0x04970,
    0x06566,0x0d4a0,0x0ea50,0x06e95,0x05ad0,0x02b60,0x186e3,0x092e0,0x1c8d7,0x0c950,
    0x0d4a0,0x1d8a6,0x0b550,0x056a0,0x1a5b4,0x025d0,0x092d0,0x0d2b2,0x0a950,0x0b557,
    0x06ca0,0x0b550,0x15355,0x04da0,0x0a5b0,0x14573,0x052b0,0x0a9a8,0x0e950,0x06aa0,
    0x0aea6,0x0ab50,0x04b60,0x0aae4,0x0a570,0x05260,0x0f263,0x0d950,0x05b57,0x056a0,
    0x096d0,0x04dd5,0x04ad0,0x0a4d0,0x0d4d4,0x0d250,0x0d558,0x0b540,0x0b6a0,0x195a6,
    0x095b0,0x049b0,0x0a974,0x0a4b0,0x0b27a,0x06a50,0x06d40,0x0af46,0x0ab60,0x09570,
    0x04af5,0x04970,0x064b0,0x074a3,0x0ea50,0x06b58,0x05ac0,0x0ab60,0x096d5,0x092e0,
    0x0c960,0x0d954,0x0d4a0,0x0da50,0x07552,0x056a0,0x0abb7,0x025d0,0x092d0,0x0cab5,
    0x0a950,0x0b4a0,0x0baa4,0x0ad50,0x055d9,0x04ba0,0x0a5b0,0x15176,0x052b0,0x0a930,
    0x07954,0x06aa0,0x0ad50,0x05b52,0x04b60,0x0a6e6,0x0a4e0,0x0d260,0x0ea65,0x0d530,
    0x05aa0,0x076a3,0x096d0,0x04afb,0x04ad0,0x0a4d0,0x1d0b6,0x0d250,0x0d520,0x0dd45,
    0x0b5a0,0x056d0,0x055b2,0x049b0,0x0a577,0x0a4b0,0x0aa50,0x1b255,0x06d20,0x0ada0,
    0x14b63,0x09370,0x049f8,0x04970,0x064b0,0x168a6,0x0ea50,0x06b20,0x1a6c4,0x0aae0,
    0x092e0,0x0d2e3,0x0c960,0x0d557,0x0d4a0,0x0da50,0x05d55,0x056a0,0x0a6d0,0x055d4,
    0x052d0,0x0a9b8,0x0a950,0x0b4a0,0x0b6a6,0x0ad50,0x055a0,0x0aba4,0x0a5b0,0x052b0,
    0x0b273,0x06930,0x07337,0x06aa0,0x0ad50,0x14b55,0x04b60,0x0a570,0x054e4,0x0d160,
    0x0e968,0x0d520,0x0daa0,0x16aa6,0x056d0,0x04ae0,0x0a9d4,0x0a4d0,0x0d150,0x0f252,
    0x0d520,
}
local months = { "正月", "二月", "三月", "四月", "五月", "六月", "七月", "八月", "九月", "十月", "冬月", "腊月" }
local digits = { "一", "二", "三", "四", "五", "六", "七", "八", "九", "十" }
local gregorian_months = { 31,28,31,30,31,30,31,31,30,31,30,31 }
local function leap_year(y) return y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0) end
local function ordinal(y, m, d)
    local previous = y - 1
    local days = previous * 365 + math.floor(previous / 4) - math.floor(previous / 100) + math.floor(previous / 400) + d
    for month = 1, m - 1 do days = days + gregorian_months[month] end
    return days + (m > 2 and leap_year(y) and 1 or 0)
end
local function month_days(info, month) return 29 + math.floor(info / 2 ^ (16 - month)) % 2 end
local function leap_days(info) return 29 + math.floor(info / 65536) % 2 end

function Calendar.convert(y, m, d)
    if type(y) ~= "number" or type(m) ~= "number" or type(d) ~= "number"
            or y % 1 ~= 0 or m % 1 ~= 0 or d % 1 ~= 0 or y < 1900 or y > 2100
            or m < 1 or m > 12 or d < 1 then return end
    if d > gregorian_months[m] + (m == 2 and leap_year(y) and 1 or 0) then return end
    local offset = ordinal(y, m, d) - ordinal(1900, 1, 31)
    if offset < 0 then return end
    for year = 1900, 2100 do
        local info, total = years[year - 1899], 0
        for month = 1, 12 do total = total + month_days(info, month) end
        local leap = info % 16
        if leap > 0 then total = total + leap_days(info) end
        if offset >= total then offset = offset - total
        else
            for month = 1, 12 do
                local days = month_days(info, month)
                if offset < days then return { year = year, month = month, day = offset + 1, leap = false } end
                offset = offset - days
                if month == leap then
                    days = leap_days(info)
                    if offset < days then return { year = year, month = month, day = offset + 1, leap = true } end
                    offset = offset - days
                end
            end
        end
    end
end

function Calendar.format(date)
    date = date or os.date("*t")
    local lunar = Calendar.convert(date.year, date.month, date.day)
    if not lunar then return "农历日期超出范围" end
    local day = lunar.day == 10 and "初十" or lunar.day == 20 and "二十" or lunar.day == 30 and "三十"
        or ((lunar.day < 10 and "初" or lunar.day < 20 and "十" or "廿") .. digits[lunar.day % 10])
    return "农历" .. (lunar.leap and "闰" or "") .. months[lunar.month] .. day
end

--[[
ISC License
Copyright (c) 2015, yize
Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.
THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
]]
return Calendar
