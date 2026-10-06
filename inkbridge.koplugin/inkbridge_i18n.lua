-- 这是 Alpha 阶段的最小翻译接口。
-- 现在直接返回原文；以后添加 locale 文件时，可以在这里接入真正的翻译系统。
local I18n = {}
function I18n.translate(text) return text end
return I18n
