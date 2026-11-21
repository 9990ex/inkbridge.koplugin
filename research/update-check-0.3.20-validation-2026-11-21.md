# 0.3.20-alpha 检查更新修复验证

日期：2026-11-21。

## 问题与根因

用户截图显示点击检查更新后提示“连不上 GitHub，检查更新失败”。

在 KOReader v2026.07.1 随包 LuaJIT、LuaSocket、LuaSec 环境中，使用原请求表达式访问官方 latest release API，服务器返回 HTTP 200，但 `tonumber(socket.skip(1, http.request{...}))` 会把响应头表一起传入 `tonumber` 的第二个参数，抛出 `bad argument #2 to 'tonumber' (number expected, got table)`。异常被原有 `pcall` 捕获，随后统一误报为连接失败。

另有独立缺陷：`local sink, code` 未初始化响应接收表。`ltn12.sink.table(nil)` 内部创建的表未被调用方保存，即使修正状态码处理，后续也只能读到空正文。

## 修改

- 显式创建正文接收表。
- 先分别接住 HTTP 请求的结果和状态，再转换单个状态值。
- 请求失败时保留超时或异常原因，HTTP 错误继续显示状态码。
- 不修改同步功能；检查更新仍只显示版本与下载地址，不安装文件。

## 验证

1. 先加入完整请求流程测试，在未修复代码上复现失败；修复后完整九组回归全部通过。断言数以 `AGENTS.md` 为准。
2. 覆盖带响应头的正常多返回值、分块正文、下载地址显示、超时、TLS 异常、HTTP 403/404、坏 JSON，以及离线确认后继续检查。
3. 使用修复后的实际 `InkBridge:_do_check_update()`，以 KOReader 随包 HTTP/TLS/rapidjson 库请求官方 API；仅替换界面和无关同步模块依赖。成功得到更新结果页数据：本地 `v0.3.20-alpha`、远端 `v0.3.19-alpha`，状态为“本地比它更新（开发中）”。这是本次验证时的远端状态。
4. 通过项目打包器生成本地包，并核对文件集合和逐文件 SHA-256；另检查 ZIP CRC 与文本文件 LF。

本次验证没有覆盖用户设备的网络环境，也没有执行自动安装或真机图形验收。
