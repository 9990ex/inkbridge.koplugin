# 墨桥 InkBridge — 工作区说明

KOReader 插件 InkBridge(墨桥)的开发工作区。功能:通过 KOReader 自带的 WebDAV 云存储,
在不同设备之间手动同步当前阅读位置。

## 目录结构

| 路径 | 说明 |
|---|---|
| `inkbridge.koplugin/` | **插件本体(唯一开发目录)**。改代码只改这里。 |
| `tests/` | 回归测试。用桩替换 KOReader 的界面/网络模块,**不需要设备**即可运行。 |
| `koreader-master/` | KOReader 上游源码快照,用于核对 API 契约。与 GitHub master 逐文件校验一致。 |
| `reference/koreader-base/` | koreader-base 的 C/C++ 源码(`cre.cpp`、`xtext.cpp`)。xpointer 的真实语义在这里。 |
| `reference/syncery-1.2.4.1.2/` | Syncery 插件源码。KOReader 云存储/WebDAV 接口的现成参考实现。 |
| `releases/` | 历史版本 zip(v0.1.0 → v0.2.13),仅作档案,已被 git 忽略。 |
| `InkBridge-Alpha.code-workspace` | VS Code 工作区配置。 |

`reference/`、`koreader-master/`、`releases/` 都不属于工程本体,已在 `.gitignore` 中排除。

## 如何验证

源码改动后**必须**跑这两份测试(需要 LuaJIT,与 KOReader 运行时同款):

```powershell
# Windows 上 LuaJIT 的默认安装位置:
#   C:\Users\<用户名>\AppData\Local\Programs\LuaJIT\bin\luajit.exe
cd "D:/path/to/repo"
& "C:\Users\USER\AppData\Local\Programs\LuaJIT\bin\luajit.exe" tests\webdav_spec.lua   # 58 条
& "C:\Users\USER\AppData\Local\Programs\LuaJIT\bin\luajit.exe" tests\main_spec.lua     # 27 条
```

| 测试文件 | 覆盖内容 |
|---|---|
| `tests/webdav_spec.lua`（77 条） | 远端路径校验、只读下载（含 404、非法路径、临时文件清理）、历史记录筛选与排序、上传的两条路径与 `provider.base` 副本/恢复、**跳转方式分级 `_plan_jump`** |
| `tests/main_spec.lua`（27 条） | 云端文件名生成与非法字符处理、设备号回退、位置比较、上传后清理暂存文件、未联网时的提示流程 |
| `tests/state_spec.lua`（64 条） | 文本锚点规范化（UTF-8 按字符计数）、阅读位置采集（含新增锚点）、记录校验与向后兼容、**紧凑载荷的结构与体积** |

跑法（需要 LuaJIT，与 KOReader 运行时同款）：

```powershell
cd "D:/path/to/repo"
$lj = "C:\Users\USER\AppData\Local\Programs\LuaJIT\bin\luajit.exe"
& $lj tests\webdav_spec.lua
& $lj tests\main_spec.lua
& $lj tests\state_spec.lua
```

已知环境限制:Windows 上 LuaJIT 通过 ANSI 代码页打开文件,含中文的**本地**路径会报
`Illegal byte sequence`,所以测试夹具刻意使用 ASCII 本地文件名(远端名仍含中文)。
设备端是 Linux/UTF-8,不受此限制。

## 版本控制

```bash
git log --oneline                              # 改动历史
git diff HEAD -- inkbridge.koplugin            # 未提交的改动
git diff v0.2.13-alpha -- inkbridge.koplugin   # 与迁移前的基线对比
```

基线标签 `v0.2.13-alpha` 是「从旧工作目录迁移过来的原始状态」。

> 历史教训:迁移之前没有 git,只能用「复制目录 + 打 zip」记版本,导致同名内容的多份副本并存
> (例如 `work/inkbridge.koplugin` 与 `inkbridge.koplugin-v0.2.13-alpha/inkbridge.koplugin`
> 内容完全相同)。以后一律用 git 记录,不再复制目录、不再手动打 zip。

## 安装到设备

把 `inkbridge.koplugin/` 整个目录放进 KOReader 的 `plugins/` 下,重启 KOReader,
在工具菜单打开「墨桥 InkBridge」。

首次使用需在菜单里点「设置 WebDAV 目标」——**必须长按**「Long-press here to choose current folder」
那一项才能选中目录(KOReader 的标准交互)。

## 已修复(相对 v0.2.13-alpha,待真机验证)

1. **下载功能此前必然报错。** `inkbridge_webdav.lua` 的远端路径校验写作
   `remote_path:find("[\\\r\n\0]", 1)`,而 Lua 的模式扫描器在字符类里遇到 NUL 字节会
   认为模式结束,该模式**非法**,`string.find` 直接抛 `malformed pattern (missing ']')`。
   它位于 `download()` 开头且无 pcall 保护,所以任何一次下载都会抛错。
   → 改为不依赖模式语义的逐字节校验 `is_safe_remote_path()`(拒绝反斜杠、控制字符、`..`、`://`)。
2. **历史记录列表永远为空。** `list_history` 用 `(txt|json)$` 表达「扩展名是 txt 或 json」,
   但 **Lua 模式没有 `|` 运算符**,它是字面量字符,该模式实际要求文件名以 `txt|json` 结尾,
   永远无法命中——于是下载流程永远找不到任何历史记录。
   → 改为 `is_inkbridge_record()`:先取出扩展名逐个比较,再用字面量比较主干。
3. 上传成功后不删除本地暂存文件,导致设备设置目录无限增长。
   → 上传回调里无论成败都 `os.remove`(必须放在回调内,provider 此时才读完该文件)。
4. 未联网时完全无反馈:provider 的 `run()` 内部是 `NetworkMgr:willRerunWhenConnected()`,
   未联网时直接返回且不执行回调,用户点了菜单既无成功也无失败提示。
   → 新增 `_with_network()`,先用 `NetworkMgr:promptWifiOn()` 征询并等待连接,失败则明确提示。
5. `provider.base` 此前直接引用插件保存的设置表;上游 KOReader 用的是
   `util.tableDeepCopy(server)`。provider 可能往 `base` 写字段(如 Dropbox 的 `access_token`),
   直接引用会把这类写入回落到 `settings.reader.lua`。
   → 统一改用副本(`provider_base()`),上传兼容路径用完还恢复原对象。
6. 文档口径更正:账号密码确实会明文保存在 `settings.reader.lua`(README 原文声称不会);
   文件名示例里多了个 `+`;「秒级时间戳可避免重名」的说法不成立(同秒仍会重名覆盖)。
7. **跨设备定位不准(0.2.15)。** 实测:在 8922 页的设备上于第 2222 页上传,到 8689 页的设备
   落到第 2164 页——正好等于 `floor(percent × 本机总页数) + 1`,说明走的是页数比例换算。
   根因有两层:
   - 记录里的 `percent` 来自 `ReaderFooter:getBookProgress()` = `pageno / pages`,
     它是「页序占本机总页数的比例」,**天然依赖排版**,不可能跨设备精确;
   - `confirm_jump` 只在 `ui.rolling and isXPointerInDocument(...)` 成立时才用 xpointer,
     该校验失败就直接掉进页数比例分支,xpointer 等于被忽略。
   → 记录新增两个与排版无关的锚点:`pos_percent`(内容高度比例)与 `text_anchor`(正文片段);
     跳转改为分级 `_plan_jump()`:xpointer → 文本锚点全文搜索(用 pos_percent 消歧)→ 页数比例。
     同时把使用的方式显示在确认框里,便于诊断。字段是可选新增,schema_version 仍为 1,
     旧记录自动降级。
   → 另注:无效 xpointer **不能**直接交给 crengine,`gotoXPointer` 在 `createXPointer` 失败时
     `SetPos(0)` 会跳到书首;而 `getPageFromXPointer` 失败时静默返回 1,也不能当判据。
     所以有效性预检必须保留(`isXPointerInDocument` = `!createXPointer().isNull()`)。

8. **记录体积过大(0.2.16)。** 实测一份记录 541 字节,而 Moon+ Reader 的 `.po` 只有 28 字节。
   拆账后发现一大半是可省的:
   - `book_file`(上传方本机绝对路径,如 `/storage/emulated/0/Books/…`)约 85 字节 ——
     接收方只用 `book_id` 认书,这个字段**任何地方都没有被读取**;
   - `book_name` 约 52 字节 —— 云端文件名本身就带书名,载荷里再存一遍是重复;
   - 百分比 17 位有效数字,保留 5 位即可;
   - 长字段名换两字母短名。
   → 新增紧凑载荷层(`State.to_payload` / `State.from_payload`),`encode` 写短名,
     `decode` **同时接受新旧两种字段名**(云上已有的旧记录仍可下载)。
     实测 541 → **270 字节**。测试里加了体积上限断言(≤300 字节)防止回涨。
   → 注:Moon+ 能到 28 字节是因为文件名固定、载荷无需带书籍身份、只存自己的字符偏移;
     墨桥的 xpointer 本身就 46 字节,且保留追加式历史,不可能压到那个量级。
9. 文本锚点长度 32 → 20 字(多个命中还会用 `pos_percent` 消歧,20 字已足够唯一)。

## 仍未处理

1. `_download_staging_path()` 直接把远端文件名当本地临时名。设备端(Linux/UTF-8)没问题,
   但 Windows 版 KOReader 的文件 API 走 ANSI,含中文的本地路径可能写不出来。
   可改为用短哈希等纯 ASCII 名。
2. UI 文案中英混杂(`main.lua` 有英文提示、`inkbridge_webdav.lua` 的 toast 全英文),
   `inkbridge_i18n` 目前只有 `_meta.lua` 在用。错误信息里 `remote_record_invalid_json`
   这类内部串会直接显示给用户。
3. `_staged_path()`(`main.lua`)是死代码,从未被调用。
4. `pick_server()` 里 `require("apps/cloudstorage/syncservice")` 的兜底分支在现行 KOReader
   上不可达(cloudstorage 已迁到 `plugins/cloudstorage.koplugin`,`onShowCloudStorageList`
   就在其 `main.lua`),可清理。
5. 文本锚点取自 xpointer 所在**段落**的文本,所以锚点指向段落开头;若原位置在段落中间,
   降级到文本锚点时误差为「小半个段落」。要彻底消除,需要把 xpointer 里的 `text().N`
   偏移也带上(注意 N 是字符偏移,不能按字节截断)。
6. `findAllText` 是全文档搜索,超大书籍上可能在 UI 线程卡顿一两秒
   (KOReader 自己的搜索会用 `Device:setIgnoreInput(true)` 挡住输入,本插件暂未加)。
7. **两条链路都改过之后,仍需实机确认一次完整流程**(上传 → 另一台设备下载 → 跳转)。
