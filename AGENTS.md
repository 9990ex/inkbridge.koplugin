# AGENTS.md —— 给在此仓库工作的 AI 助手（以及人类贡献者）

本仓库是 KOReader 插件「墨桥 InkBridge」：通过 KOReader 自带的 WebDAV 云存储，在不同设备之间
手动同步阅读位置。动手前请先读 [`DEVELOPMENT.md`](DEVELOPMENT.md)（含目录结构、验证方法、
已修复清单、已知精度上限）。

## 硬性要求

1. **改任何 Lua 代码后必须跑完整回归测试**（764 条断言，用桩替换 KOReader 的界面/网络模块，
   **不需要设备**）：

   ```bash
   luajit tests/moon_spec.lua       # 159 条  位置格式的解析与生成
   luajit tests/moonsync_spec.lua   # 213 条  静读天下互通（读、写、平台、手动选文件）
   luajit tests/update_spec.lua     #  48 条  版本比较与 release 解析
   luajit tests/webdav_spec.lua     # 184 条  云存储层（上传/下载/列目录/删除）
   luajit tests/main_spec.lua       #  79 条  主流程、保留策略、设备名探测
   luajit tests/state_spec.lua      #  81 条  位置记录本身
   ```

   全绿才算过。需要 LuaJIT（与 KOReader 运行时同款）。新增 spec 请一并写进
   `tests/run_all.sh` 和本节 —— 漏掉一份，等于那个模块没人看着。

   涉及**删除或覆盖**云端数据的改动（`WebDAV.delete_file`、`InkBridge:_prune_history`、
   `.po` 写回），除了正常路径，必须覆盖：路径校验拒绝、provider 抛异常、
   服务器拒绝、以及"绝不删错那一条"的守卫。

2. **版本号规则：不跳大版本号**。`0.3.0` 是正式版基线，之后的小改动一律走
   **`0.3.x-alpha`**（`0.3.1-alpha`、`0.3.2-alpha`…）。**不要**因为"加了个功能"就跳到
   `0.4.0` —— 已经发生过一次（自作主张跳号，被要求退回）。要动大版本号先问。
   版本号只有 `_meta.lua` 一处是权威来源；README 标题与菜单树是手抄的，改版本时一起改。

3. **涉及 Lua 模式（pattern）的改动必须实测，不能目测**。本项目的两个致命 bug 都是"想当然"造成的：
   - 字符类里放 NUL 字节会让模式非法（`malformed pattern`），NUL 必须写 `%z`；
   - **Lua 模式没有 `|` 运算符**，`(txt|json)$` 里它是字面量，模式永不命中。
   写模式前先写一行最小用例跑一遍。

4. **不要改动这三处的语义**（理由见 `DEVELOPMENT.md`）：
   - 云端文件名里的**短哈希**（`partialMD5` 前 8 位）与 `.InkBridge.txt` 后缀 —— 前者是跨设备认书的
     依据，后者是 KOReader WebDAV 列表的显示条件（`.json` 默认不显示）；
   - `isXPointerInDocument` 有效性预检 —— 无效 xpointer 交给 crengine 会 `SetPos(0)` 跳到书首；
   - 下载路径使用**只读** provider 调用 —— 不要改用 `Cloud:sync`（它在合并回调后必定重新上传）。

5. **提交信息用中文**，说明"改了什么 / 为什么 / 怎么验证"。
   在 Windows 上用 PowerShell 时，中文提交信息请写进文件再 `git commit -F <文件>`，
   避免命令行编码破坏。

6. **发布包**用 `墨桥-samples/build_release.py` 生成（布局 = `LICENSE` + `inkbridge.koplugin/`，
   打完逐文件 sha256 校验），包名 `inkbridge.moon.koplugin-v<版本>.zip`。
   **包内目录永远是 `inkbridge.koplugin/`** —— KOReader 靠它认插件，改了老用户升级时
   会多出一个旧插件目录同时跑。发完要**下载回来验 MD5**。
   release 的 prerelease 标记：**历史补档**用 prerelease（别去抢 Latest）；
   **当前在用的那一版**用普通 release —— 插件里的「检查更新」走 `/releases/latest`，
   标了 prerelease 就永远看不到它。

7. 源码是**纯 LF**（`.gitattributes` 里 `* -text`），不要引入 CRLF。

## 已知的、不要"顺手修"的东西

- **分页模式下跳转是「页级」精度**：KOReader 会把 xpointer 换算成「包含该位置的页码」再跳到该页开头，
  因此原位置在页面中间时落点会早几行（上限一页）；章节开头本身就是页首，所以能完全对齐。
  这是 KOReader 分页模式的固有粒度（它自己的进度同步也一样），滚动模式下才是逐字精确。
  详见 `DEVELOPMENT.md` 的专门章节。
- `DEVELOPMENT.md` 里的「仍未处理」与「已知精度上限」两节是**有意的记录**，不是待办清单。
