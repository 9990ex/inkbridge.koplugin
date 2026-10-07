-- ============================================================================
-- tests/update_spec.lua —「检查更新」的纯逻辑回归测试
--
-- 这一层不联网、不碰界面:版本比较、GitHub 返回的解析、展示内容拼装。
-- JSON 解码器是**注入**的,所以这里传桩即可,不需要 rapidjson。
-- 运行: luajit tests/update_spec.lua   (在仓库根目录执行)
-- ============================================================================

local script_path = arg and arg[0] or "tests/update_spec.lua"
local script_dir  = script_path:match("^(.*)[/\\][^/\\]*$") or "."
local PLUGIN_DIR  = script_dir .. "/../inkbridge.koplugin"

local Update = dofile(PLUGIN_DIR .. "/inkbridge_update.lua")

local passed, failed = 0, 0
local function check(label, cond, detail)
    if cond then passed = passed + 1; print("    PASS  " .. label)
    else failed = failed + 1
        print(string.format("    FAIL  %s%s", label, detail and ("  -> " .. tostring(detail)) or "")) end
end
local function eq(label, got, want)
    check(label, got == want, string.format("得到 %s，期望 %s", tostring(got), tostring(want)))
end

-- 一个"不管输入是什么,都返回这张表"的解码器桩
local function decoder_returning(t)
    return function(text) _G.__last_json = text; return t end
end

-- ── 版本号拆解 ─────────────────────────────────────────────────────────────
print("== 版本号拆解 ==")
do
    local n = Update.version_numbers("0.2.24-alpha")
    eq("共 3 段", #n, 3)
    eq("第 1 段", n[1], 0)
    eq("第 2 段", n[2], 2)
    eq("第 3 段", n[3], 24)
    eq("带 v 前缀也能拆", #Update.version_numbers("v1.2.3"), 3)
    eq("空串得到空表", #Update.version_numbers(""), 0)
    eq("nil 得到空表", #Update.version_numbers(nil), 0)
end

-- ── 版本比较 ───────────────────────────────────────────────────────────────
print("== 版本比较 ==")
do
    eq("相同 → 0",       Update.compare_versions("0.2.24-alpha", "0.2.24-alpha"), 0)
    eq("新版更大 → 1",   Update.compare_versions("0.2.25-alpha", "0.2.24-alpha"), 1)
    eq("旧版更小 → -1",  Update.compare_versions("0.2.23-alpha", "0.2.24-alpha"), -1)
    eq("次版本进位",     Update.compare_versions("0.3.0-alpha", "0.2.99-alpha"), 1)
    eq("前缀相同短的更小", Update.compare_versions("0.2", "0.2.1"), -1)
    eq("补零后相等",     Update.compare_versions("0.2", "0.2.0"), 0)
    -- 这一条是刻意防"按字符串比"的:字符串比会得出 "0.2.9" > "0.2.10"
    eq("0.2.9 < 0.2.10（不能被字符串比较骗到）",
       Update.compare_versions("0.2.9-alpha", "0.2.10-alpha"), -1)
    eq("tag 带 v 前缀也能比", Update.compare_versions("v0.2.25", "0.2.24"), 1)
end

-- ── 解析 GitHub 返回 ───────────────────────────────────────────────────────
print("== 解析 GitHub 返回 ==")
do
    local payload = {
        tag_name = "v0.2.25-alpha",
        name = "v0.2.25-alpha — 测试",
        published_at = "2026-10-08T03:04:05Z",
        html_url = "https://github.com/9990ex/inkbridge.koplugin/releases/tag/v0.2.25-alpha",
        prerelease = false,
        assets = {
            { name = "inkbridge.koplugin-v0.2.25-alpha.zip",
              browser_download_url = "https://example.com/a.zip", size = 59026 },
        },
    }
    local rel, err = Update.parse_release('{"anything":1}', decoder_returning(payload))
    check("能解析", rel ~= nil, err)
    if rel then
        eq("tag", rel.tag, "v0.2.25-alpha")
        eq("发布日期只取日期部分", rel.published, "2026-10-08")
        eq("挑出 zip 资产", rel.asset_name, "inkbridge.koplugin-v0.2.25-alpha.zip")
        eq("资产地址", rel.asset_url, "https://example.com/a.zip")
        eq("资产大小", rel.asset_size, 59026)
        eq("页面地址", rel.page_url, payload.html_url)
    end
    check("JSON 原文确实被传给了解码器",
          type(_G.__last_json) == "string" and _G.__last_json:find("anything") ~= nil)

    -- 没有 assets:仍要能给出**版本信息**(只是没有安装包)
    local no_asset = { tag_name = "v0.2.25-alpha" }
    local rel2 = Update.parse_release("{}", decoder_returning(no_asset))
    check("没有 zip 资产也能解析", rel2 ~= nil)
    if rel2 then
        eq("  资产名称为空", rel2.asset_name, nil)
        eq("  缺 published_at 时为 nil", rel2.published, nil)
        eq("  页面地址回落到主页", rel2.page_url, Update.HOMEPAGE)
    end

    -- 只挑 .zip,别的资产要跳过
    local mixed = { tag_name = "v1.0.0", assets = {
        { name = "notes.txt", browser_download_url = "https://example.com/n.txt", size = 5 },
        { name = "pack.ZIP", browser_download_url = "https://example.com/p.zip", size = 9 },
    } }
    local rel3 = Update.parse_release("{}", decoder_returning(mixed))
    check("跳过非 zip、认大写扩展名", rel3 ~= nil and rel3.asset_name == "pack.ZIP",
          rel3 and rel3.asset_name)

    -- 失败路径
    eq("空响应要拒绝", Update.parse_release("", decoder_returning(payload)), nil)
    eq("没有解码器要拒绝", Update.parse_release("{}", nil), nil)
    eq("JSON 解不出来要拒绝",
       Update.parse_release("{", function() error("bad json") end), nil)
    eq("解出来不是表要拒绝", Update.parse_release("{}", function() return "str" end), nil)
    eq("没有 tag_name 要拒绝", Update.parse_release("{}", decoder_returning({})), nil)

    local rl, rl_err = Update.parse_release("{}",
        decoder_returning({ message = "API rate limit exceeded" }))
    eq("限流要当失败", rl, nil)
    check("限流原因里带上 GitHub 的原话",
          type(rl_err) == "string" and rl_err:find("rate limit", 1, true) ~= nil, rl_err)
end

-- ── 展示内容 ───────────────────────────────────────────────────────────────
print("== 展示内容 ==")
do
    local function find_value(kv, key)
        for _, row in ipairs(kv) do if row[1] == key then return row[2] end end
        return nil
    end

    local newer = { tag = "v0.2.25-alpha", published = "2026-10-08",
                    asset_name = "inkbridge.koplugin-v0.2.25-alpha.zip", asset_size = 59026,
                    asset_url = "https://example.com/a.zip" }
    local kv = Update.describe("0.2.24-alpha", newer)
    check("能拼出键值对", type(kv) == "table" and #kv >= 6)
    eq("状态=有新版本", find_value(kv, "状态"), "有新版本，可更新")
    check("新版要给出下载地址", find_value(kv, "下载地址") == "https://example.com/a.zip")
    check("安装包带大小(KB)",
          tostring(find_value(kv, "安装包")):find("57 KB", 1, true) ~= nil,
          find_value(kv, "安装包"))
    eq("许可证", find_value(kv, "许可证"), "GPL-3.0")
    check("带 Alpha 声明",
          tostring(find_value(kv, "说明")):find("Alpha", 1, true) ~= nil)

    local same = Update.describe("0.2.25-alpha",
                                 { tag = "v0.2.25-alpha", asset_name = "a.zip", asset_size = 1 })
    eq("同版本=已是最新", find_value(same, "状态"), "已是最新")
    eq("已是最新时不显示下载地址", find_value(same, "下载地址"), nil)

    local older = Update.describe("0.2.26-alpha", { tag = "v0.2.25-alpha" })
    eq("本地更新时的状态", find_value(older, "状态"), "本地比它更新（开发中）")

    eq("远端为空时返回 nil", Update.describe("0.2.24-alpha", nil), nil)
    eq("远端没有 tag 时返回 nil", Update.describe("0.2.24-alpha", {}), nil)
end

-- ── 常量 ───────────────────────────────────────────────────────────────────
print("== 常量 ==")
do
    check("API 地址指向 latest release",
          Update.API_URL:find("releases/latest", 1, true) ~= nil, Update.API_URL)
    check("主页是 GitHub 仓库",
          Update.HOMEPAGE == "https://github.com/9990ex/inkbridge.koplugin", Update.HOMEPAGE)
end

print(string.format("\n合计：%d 通过，%d 失败", passed, failed))
os.exit(failed == 0 and 0 or 1)
