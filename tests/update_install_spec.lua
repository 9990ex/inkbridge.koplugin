-- 自动更新安装器的拒绝路径测试；不写真实插件目录、不联网。
local script_path = arg and arg[0] or "tests/update_install_spec.lua"
local script_dir = script_path:match("^(.*)[/\\][^/\\]*$") or "."
local PLUGIN_DIR = script_dir .. "/../inkbridge.koplugin"
local Update = dofile(PLUGIN_DIR .. "/inkbridge_update.lua")
package.loaded["inkbridge_update"] = Update
local Installer = dofile(PLUGIN_DIR .. "/inkbridge_update_install.lua")

local passed, failed = 0, 0
local function check(label, condition)
    if condition then passed = passed + 1; print("    PASS  " .. label)
    else failed = failed + 1; print("    FAIL  " .. label) end
end

local hash = string.rep("a", 64)
local opened, renamed, purged = 0, 0, 0
local entries = {}
local fake_archive = { Reader = {} }
function fake_archive.Reader:new()
    return setmetatable({}, { __index = {
        open = function(self) self.err = nil; opened = opened + 1; return true end,
        iterate = function()
            local index = 0
            return function()
                index = index + 1
                return entries[index]
            end
        end,
        extractToPath = function() return true end,
        close = function() end,
    } })
end
local deps = {
    lfs = { attributes = function() return nil end },
    util = { makePath = function() return true end },
    ffiUtil = { dirname = function(path) return path:match("^(.*)/[^/]+$") end,
                purgeDir = function() purged = purged + 1; return true end },
    Archiver = fake_archive,
    hash_file = function() return hash end,
    read_file = function() return 'return { version = "0.3.21-alpha" }' end,
    digest_matches = Update.digest_matches,
    rename = function() renamed = renamed + 1; return true end,
}

local ok, err = Installer.install("update.zip", "/plugins/inkbridge.koplugin", nil,
    "0.3.21-alpha", deps)
check("缺少 SHA-256 拒绝安装", not ok and err:find("SHA%-256") ~= nil)
check("缺摘要时不打开 ZIP", opened == 0)
check("缺摘要时不替换插件", renamed == 0)

ok, err = Installer.install("update.zip", "/plugins/inkbridge.koplugin", "sha256:" .. string.rep("b", 64),
    "0.3.21-alpha", deps)
check("摘要不匹配拒绝安装", not ok and err:find("不匹配", 1, true) ~= nil)
check("摘要不匹配时不打开 ZIP", opened == 0)
check("摘要不匹配时不替换插件", renamed == 0)

entries = {
    { path = "inkbridge.koplugin/", mode = "directory", size = 0 },
    { path = "inkbridge.koplugin/../escape.lua", mode = "file", size = 10 },
}
ok, err = Installer.install("update.zip", "/plugins/inkbridge.koplugin", "sha256:" .. hash,
    "0.3.21-alpha", deps)
check("ZIP 路径穿越拒绝安装", not ok and err:find("不安全路径", 1, true) ~= nil)
check("恶意 ZIP 在解压前关闭并清理暂存目录", opened == 1 and purged == 1)
check("恶意 ZIP 不触碰当前插件", renamed == 0)

entries = {
    { path = "inkbridge.koplugin/", mode = "directory", size = 0 },
    { path = "inkbridge.koplugin/main.lua", mode = "file", size = 100 },
    { path = "inkbridge.koplugin/_meta.lua", mode = "file", size = 40 },
}
deps.lfs.attributes = function(path)
    if path:match("/main.lua$") then return "file" end
    return nil
end
deps.rename = function() renamed = renamed + 1; return true end
ok, err = Installer.install("update.zip", "/plugins/inkbridge.koplugin", "sha256:" .. hash,
    "v0.3.21-alpha", deps)
check("有效更新完成替换", ok == true)
check("有效更新先备份再安装", renamed == 2)

renamed = 0
deps.rename = function()
    renamed = renamed + 1
    if renamed == 2 then return nil, "simulated replace failure" end
    return true
end
ok, err = Installer.install("update.zip", "/plugins/inkbridge.koplugin", "sha256:" .. hash,
    "0.3.21-alpha", deps)
check("替换失败报告失败", not ok and err:find("已恢复旧版本", 1, true) ~= nil)
check("替换失败后尝试恢复备份", renamed == 3)

print(string.format("\n合计：%d 通过，%d 失败", passed, failed))
os.exit(failed == 0 and 0 or 1)
