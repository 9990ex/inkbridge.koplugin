# AGENTS.md —— 给在此仓库工作的 AI 助手（以及人类贡献者）

本仓库是 KOReader 插件「InkBridge+ / 墨桥+」：通过 KOReader 自带的 WebDAV 云存储，在不同设备之间
手动同步阅读位置。动手前请先读 [`DEVELOPMENT.md`](DEVELOPMENT.md)（含目录结构、验证方法、
已修复清单、已知精度上限）。

## 硬性要求

1. **改任何 Lua 代码后必须跑完整回归测试**（1953 条断言，用桩替换 KOReader 的界面/网络模块，
   **不需要设备**）：

   ```bash
   luajit tests/moon_spec.lua       # 163 条  位置格式与 URL/目录拼接
   luajit tests/moontxt_spec.lua    # 149 条  TXT 编码、UTF-16 分块显示坐标、短段确认回退与反向核对
   luajit tests/moonsync_spec.lua   # 392 条  静读天下互通（读、写、上传设备来源、平台、目录换算、导航单元与字符坐标）
    luajit tests/update_spec.lua     #  59 条  版本比较、release 解析与安装包校验
    luajit tests/update_install_spec.lua # 13 条  ZIP 拒绝、事务替换与失败恢复
    luajit tests/webdav_spec.lua     # 311 条  云存储层、实际排版行号与恢复原页、首页远端正文采集、逐条条件删除、同步前位置预览
      luajit tests/main_spec.lua       # 176 条  主流程、桥墨平级页签与顺序、书籍工具原生委托、图标安装、关书自动上传、保留策略、设备名探测、状态页与更新流程
    luajit tests/menu_spec.lua       # 33 条  原生下拉圆形图标、透明背景、间距、去除黑色反馈、动作委托、页签隔离、窄屏与DPI、配置刷新、子菜单返回
    luajit tests/rebuild_spec.lua    # 121 条  正文保留、章节识别与误判防护、卷层级、脚本内容、spine、打包回读、失败清理、取消、新副本身份、实际进度与节流
   luajit tests/state_spec.lua      #  82 条  位置记录本身、首页章节不进入同步载荷
      luajit tests/home_spec.lua       # 195 条  首页书库对齐、统一记录卡片、章节摘要、逐条确认删除、关闭返回、元信息入口、分页与生命周期
     luajit tests/home_sync_spec.lua  #  52 条  首页只读补全、完整身份、限量、去重、离线、超时、部分失败、迟到回调与旧批量删除安全校验
   luajit tests/library_spec.lua    # 41 条 本地及WebDAV递归目录扫描、文件夹层级、空目录、密度排序设置、目录优先级、取消、下载接口继承、完整身份归组与逐条删除守卫
   luajit tests/calendar_spec.lua   # 23 条 离线农历、公农历对照、闰月、非法日期及支持边界
   luajit tests/home_preview_spec.lua # 19 条 原书章节与正文选段、唯一锚点、标题与空章、跨文件续文、UTF8、分批读取、取消及原书身份变化守卫
   luajit tests/book_files_spec.lua # 31 条 本地文件改名、阅读数据与历史迁移、保留保护、两种删除、名称与身份校验、操作失败与缓存隔离
    luajit tests/material_spec.lua # 43 条 圆形图标与间距、去除反色、统一高度、模态层级、窄屏、卡片章节摘要、分页与返回
   luajit tests/book_metadata_spec.lua # 50 条 本机元数据、身份校验、回读、四字段保存、内嵌改名与失败保护、改名后保留草稿
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

6. **绝对不要自己往 GitHub 上发任何东西**。不 `push`、不打 tag、不建 release、不删 release、
   不改远端分支、不动 `gh` 的任何写操作 —— **除非用户在当轮对话里明确说了"发 / 推"**。
   没说就只交**本地包**（`releases/<包名>.zip`）与本地提交。

   这一条比"测试全绿"更严格：**必须等用户在本机真机测试通过，才能推送到 GitHub**。
   插件里凡是碰界面 / 云存储交互的改动，我在这个环境里**跑不了真机** —— 984 条断言全绿
   只证明"没写错"，不证明"能用"。已经发生过一次：0.3.3 自写的目录浏览器测试全绿、
   实机却根本用不了，包发出去之后被迫删 release 撤版。
   已经发出去的东西要撤回，同样等用户明确指示再动。

   **而且不要主动提这件事**：不询问"要不要发 / 推"、不说"等你验证通过我就发"、
   不在交付说明里附带"推上去是快进 / 远端还留着某个提交"之类的铺垫 ——
   用户想发的时候会自己讲。交付时只讲**改了什么、为什么、怎么验证、包在哪**。

7. **发布包**用 `墨桥-samples/build_release.py` 生成（布局 = `LICENSE` + `inkbridge.koplugin/`，
   打完逐文件 sha256 校验），包名 `inkbridge.moon.koplugin-v<版本>.zip`。
   **包内目录永远是 `inkbridge.koplugin/`** —— KOReader 靠它认插件，改了老用户升级时
   会多出一个旧插件目录同时跑。发完要**下载回来验 MD5**。
   release 的 prerelease 标记：**历史补档**用 prerelease（别去抢 Latest）；
   **当前在用的那一版**用普通 release —— 插件里的「检查更新」走 `/releases/latest`，
   标了 prerelease 就永远看不到它。

8. 源码是**纯 LF**（`.gitattributes` 里 `* -text`），不要引入 CRLF。

## 已知的、不要"顺手修"的东西

- **分页模式下跳转是「页级」精度**：KOReader 会把 xpointer 换算成「包含该位置的页码」再跳到该页开头，
  因此原位置在页面中间时落点会早几行（上限一页）；章节开头本身就是页首，所以能完全对齐。
  这是 KOReader 分页模式的固有粒度（它自己的进度同步也一样），滚动模式下才是逐字精确。
  详见 `DEVELOPMENT.md` 的专门章节。
- `DEVELOPMENT.md` 里的「仍未处理」与「已知精度上限」两节是**有意的记录**，不是待办清单。
