package.path = "inkbridge.koplugin/?.lua;" .. package.path
local Calendar = require("inkbridge_calendar")
local passed, failed = 0, 0
local function check(name, value)
    if value then passed = passed + 1 else failed = failed + 1; print("FAIL " .. name) end
end
local function lunar(y, m, d, expected)
    check(string.format("%04d-%02d-%02d 农历核对", y, m, d),
        Calendar.format({ year = y, month = m, day = d }) == "农历" .. expected)
end
-- 2026 年样本来自香港天文台公农历对照表；不依赖主机时区或网络。
lunar(2026, 1, 1, "冬月十三")
lunar(2026, 1, 19, "腊月初一")
lunar(2026, 2, 16, "腊月廿九")
lunar(2026, 2, 17, "正月初一")
lunar(2026, 3, 3, "正月十五")
lunar(2026, 3, 19, "二月初一")
lunar(2026, 6, 19, "五月初五")
lunar(2026, 9, 25, "八月十五")
lunar(2026, 11, 8, "九月三十")
lunar(2026, 11, 9, "十月初一")
lunar(2026, 11, 22, "十月十四")
lunar(2026, 12, 9, "冬月初一")
lunar(2026, 12, 31, "冬月廿三")
lunar(1900, 1, 31, "正月初一")
lunar(2024, 2, 10, "正月初一")
lunar(2025, 1, 29, "正月初一")
lunar(2025, 7, 25, "闰六月初一")
check("闰月结构字段", Calendar.convert(2025, 7, 25).leap == true)
check("无效公历日期不归一化成别日", Calendar.convert(2026, 2, 29) == nil)
check("公历闰年二十九日可计算", Calendar.convert(2024, 2, 29) ~= nil)
check("纪元前安全拒绝", Calendar.convert(1900, 1, 30) == nil)
check("上限之后明确占位", Calendar.format({ year = 2101, month = 1, day = 1 }) == "农历日期超出范围")
check("拒绝非法日期类型", Calendar.convert("2026", 11, 22) == nil and Calendar.convert(2026, 13, 1) == nil)
print(string.format("合计：%d 通过，%d 失败", passed, failed))
os.exit(failed == 0 and 0 or 1)
