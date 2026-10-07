-- inkbridge_update.lua ——「检查更新」:只查、不装。
--
-- 为什么先只做"查":自动安装要**替换正在运行的插件目录**。一旦解压到一半失败,
-- 插件就废了 —— 而它恰恰是"修插件"的工具。所以这一步先把"有没有新版"说清楚,
-- 自动安装留到插件更稳的时候。完整设计(下载 → 解压到临时目录 → 校验 →
-- 原子改名替换 → 提示重启)已记录在 research/ 的笔记里。
--
-- 本模块只做纯计算(版本比较、解析 GitHub 返回、拼展示内容),不碰网络与界面 ——
-- 这样这一层能在 LuaJIT 里直接测。JSON 解码器由调用方**注入**:
-- 真机上传 rapidjson.decode,测试里传一个桩。

local Update = {}

Update.REPO     = "9990ex/inkbridge.koplugin"
Update.API_URL  = "https://api.github.com/repos/" .. Update.REPO .. "/releases/latest"
Update.HOMEPAGE = "https://github.com/" .. Update.REPO

-- "0.2.24-alpha" / "0.3.0" → { 0, 2, 24 } / { 0, 3, 0 }。
-- 只取数字段,所以带不带 `-alpha` 这类预发布后缀都不影响比较
-- (0.2.24-alpha 与 0.2.24 在这里是同一个版本,这正是我们要的)。
function Update.version_numbers(v)
    local nums = {}
    for n in tostring(v or ""):gmatch("(%d+)") do
        nums[#nums + 1] = tonumber(n)
    end
    return nums
end

-- 比较版本号:a<b 返回 -1,a=b 返回 0,a>b 返回 1。
-- 逐段按数字比;前缀相同时短的那个更小(0.2 < 0.2.1)。
-- 刻意不做字符串比较 —— "0.2.9" 和 "0.2.10" 用字符串比会得出相反结论。
function Update.compare_versions(a, b)
    local x, y = Update.version_numbers(a), Update.version_numbers(b)
    for i = 1, math.max(#x, #y) do
        local xi, yi = x[i] or 0, y[i] or 0
        if xi ~= yi then return xi < yi and -1 or 1 end
    end
    return 0
end

-- 从 GitHub 的 release JSON 里取出要用的字段。
-- decode 为 JSON 解码函数。返回表 或 nil + 原因。
function Update.parse_release(json_text, decode)
    if type(json_text) ~= "string" or json_text == "" then return nil, "空响应" end
    if type(decode) ~= "function" then return nil, "没有 JSON 解码器" end

    local ok, data = pcall(decode, json_text)
    if not ok or type(data) ~= "table" then return nil, "返回的不是有效 JSON" end

    -- GitHub 出错时返回 {"message": "..."} —— 最常见的是未登录的限流(60 次/小时)
    if type(data.message) == "string" and type(data.tag_name) ~= "string" then
        return nil, "GitHub 返回：" .. tostring(data.message)
    end
    if type(data.tag_name) ~= "string" or data.tag_name == "" then
        return nil, "返回里没有版本号（tag_name）"
    end

    -- 资产里挑第一个 .zip(就是插件包);没有也照样能显示版本信息
    local asset_name, asset_url, asset_size
    if type(data.assets) == "table" then
        for _, a in ipairs(data.assets) do
            if type(a) == "table" and type(a.name) == "string"
                    and a.name:lower():sub(-4) == ".zip" then
                asset_name = a.name
                asset_url  = a.browser_download_url
                asset_size = tonumber(a.size)
                break
            end
        end
    end

    return {
        tag        = data.tag_name,
        name       = (type(data.name) == "string") and data.name or data.tag_name,
        published  = (type(data.published_at) == "string")
                     and data.published_at:sub(1, 10) or nil,
        page_url   = (type(data.html_url) == "string") and data.html_url or Update.HOMEPAGE,
        asset_name = asset_name,
        asset_url  = asset_url,
        asset_size = asset_size,
        prerelease = data.prerelease and true or false,
    }
end

-- 把"当前版本 vs 远端发布"拼成给 KeyValuePage 用的键值对(纯函数)。
function Update.describe(current, rel)
    if type(rel) ~= "table" or type(rel.tag) ~= "string" then return nil end

    local cmp = Update.compare_versions((rel.tag:gsub("^v", "")), current)
    local status
    if cmp > 0 then
        status = "有新版本，可更新"
    elseif cmp < 0 then
        status = "本地比它更新（开发中）"
    else
        status = "已是最新"
    end

    local pairs_out = {
        { "当前版本", "v" .. tostring(current or "?") },
        { "最新版本", tostring(rel.tag) },
        { "状态",     status },
    }
    if rel.published then table.insert(pairs_out, { "发布日期", rel.published }) end
    if rel.asset_name then
        table.insert(pairs_out, { "安装包",
            rel.asset_size and string.format("%s（%d KB）", rel.asset_name,
                                             math.floor(rel.asset_size / 1024))
                            or rel.asset_name })
    end
    if cmp > 0 then
        table.insert(pairs_out, { "下载地址", rel.asset_url or rel.page_url or Update.HOMEPAGE })
    end
    table.insert(pairs_out, { "项目主页", Update.HOMEPAGE })
    table.insert(pairs_out, { "许可证",   "GPL-3.0" })
    table.insert(pairs_out, { "说明",     "0.x：核心功能已真机验证，仍在打磨" })
    return pairs_out
end

return Update
