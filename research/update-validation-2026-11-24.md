# 在线更新闪退修复验证（2026-11-24）

用户报告 Kindle 点击「下载并安装」后闪退，尚未提供 Kindle 型号、KOReader 版本及 crash.log。本地已复现与该阶段一致、所有平台均会触发的 Lua 错误：

```text
main.lua:918: bad argument #2 to 'sub' (number expected, got string)
```

原因是 `#"https://github.com/" .. Update.REPO .. "/releases/download/"` 只对首段字符串取长度，然后拼接为字符串，传入 `sub` 的结束位置。修复为先保存完整前缀，再取 `#release_prefix`。

同时修复两条后续异常路径：下载 sink 不再关闭文件，统一在请求结束或抛异常后关闭；安装确认回调用 `pcall` 捕获模块加载和安装异常并显示原因。

## 自动回归

WSL Ubuntu 使用 LuaJIT 执行 `sh tests/run_all.sh`，18 组、1976 条断言全部通过。主流程新增 23 条断言，覆盖地址校验、403、404、超时、连接异常、传输失败但 HTTP 200、重复结束 sink、未结束 sink、成功下载及安装异常。修改前新测试已复现入口地址校验异常。`git diff --check` 通过。

## 真实 KOReader 运行验证

- 运行时：本机 WSL 中 KOReader v2026.07.1，LuaJIT 2.1.1783773675，605×921。
- 隔离目录：`/home/nvidia/ib-update-lab-20261124`，独立 `KO_HOME` 与测试 EPUB。
- 起始插件使用修复后的更新代码，版本标记设为 0.3.31-alpha；目标是本地构建的 0.3.32-alpha 完整包。
- 使用隔离探针触发插件安装确认回调。仅将 HTTP 请求地址映射到本机临时服务器；原下载地址校验、真实 LuaSocket、文件写入、SHA-256、libarchive、目录替换与 UI 提示均按真实代码运行。
- 请求 `/denied` 返回 HTTP 403：显示「更新失败。下载更新包失败：HTTP 403」，进程继续运行。
- 请求 `/redirect` 返回 302，再请求 `/package.zip` 返回 200：成功显示「墨桥已更新到 v0.3.32-alpha。请重启 KOReader 使新版本生效。」
- 安装后版本为 0.3.32-alpha；26 个插件文件与 ZIP 逐字节一致，更新暂存目录、备份目录及下载 ZIP 均已清理。
- KOReader 正常退出，退出码 0；临时 HTTP 服务停止。

隔离目录内保留 `runtime.log`、`evidence.json`、`denied.png` 与 `success.png`。验证脚本为 Windows 临时目录的 `ib-update-runtime.py`。

本次没有 Kindle 真机日志，不能据此确认设备上是否还有其他独立问题。验证的网络端点是本机 HTTP 服务，未覆盖 Kindle 的实际 GitHub HTTPS 网络环境。
