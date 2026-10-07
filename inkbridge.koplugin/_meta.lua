-- _meta.lua 是 KOReader 插件的元数据文件：插件列表里的名称、说明和版本号。
--
-- 这里刻意不做 i18n：本项目面向中文用户，用户可见文案一律中文硬编码。
-- 原先那个 inkbridge_i18n 只是个「原样返回」的空壳，只有本文件在用，
-- 已删除 —— 免得看起来像有翻译系统实则没有。
-- 以后真要国际化，正统做法是 require("gettext") + 英文源串，
-- 这样才能直接复用 KOReader 自带的几十种语言翻译。
return {
    fullname = "InkBridge / 墨桥",
    description = "通过 WebDAV 在 KOReader 与静读天下之间同步阅读位置的插件",
    version = "0.3.0",
}
