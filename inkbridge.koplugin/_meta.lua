-- _meta.lua 是 KOReader 插件的元数据文件。
-- KOReader 用它显示插件名称、说明和版本号。
local _ = require("inkbridge_i18n").translate

return {
    fullname = _([[InkBridge / 墨桥]]),
    description = _([[A small, manual WebDAV reading-position sync for KOReader devices.]]),
    version = "0.2.13-alpha",
}
