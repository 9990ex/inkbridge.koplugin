# 墨桥 InkBridge — 开发说明

KOReader 插件 InkBridge(墨桥)的开发文档。功能:通过 KOReader 自带的 WebDAV 云存储,
在不同设备之间手动同步当前阅读位置。

## 目录结构

公开的仓库里只有两项:

| 路径 | 说明 |
|---|---|
| `inkbridge.koplugin/` | **插件本体(唯一开发目录)**。改代码只改这里。 |
| `tests/` | 回归测试。用桩替换 KOReader 的界面/网络模块,**不需要设备**即可运行。 |

本地开发时还有几份**不随仓库发布**的参考资料(已在 `.gitignore` 中排除):

| 路径 | 说明 |
|---|---|
| `koreader-master/` | KOReader 上游源码快照,用于核对 API 契约 |
| `reference/koreader-base/` | koreader-base 的 C/C++ 源码(`cre.cpp`、`xtext.cpp`),xpointer 的真实语义在这里 |
| `reference/syncery-*/` | Syncery 插件源码,KOReader 云存储/WebDAV 接口的现成参考实现 |
| `releases/` | 历史版本 zip,仅作档案 |

## 如何验证

| 测试文件 | 覆盖内容 |
|---|---|
| `tests/webdav_spec.lua`（96 条） | 远端路径校验、只读下载（含 404、非法路径、临时文件清理）、历史记录筛选与排序、上传的两条路径与 `provider.base` 副本/恢复、**跳转方式分级 `_plan_jump`**、**错误码→中文的 `describe_error`**、全文搜索期间的输入防护 |
| `tests/main_spec.lua`（37 条） | 云端文件名生成（格式、分段、UTF-8 截断、非法字符）、位置比较、上传后清理暂存文件、未联网时的提示流程、**下载临时路径为纯 ASCII** |
| `tests/state_spec.lua`（81 条） | 文本锚点规范化（UTF-8 按字符计数、**xpointer 字符偏移**）、阅读位置采集、记录校验与向后兼容、紧凑载荷的结构与体积 |

在仓库根目录执行(需要 LuaJIT —— 与 KOReader 运行时同款,LuaJIT 官网或包管理器都能装):

```bash
luajit tests/webdav_spec.lua
luajit tests/main_spec.lua
luajit tests/state_spec.lua
```

Windows 上可 `winget install DEVCOM.LuaJIT`,装完在
`%LOCALAPPDATA%\Programs\LuaJIT\bin\luajit.exe`,用全路径调用即可。

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

首次使用先配云同步:**高级选项 → 存储选项 → 墨桥同步目录**
(只配了一台服务器时会直接进目录浏览)——**必须长按**「Long-press here to choose current folder」
那一项才能选中目录(KOReader 的标准交互)。

> 压缩包的文件名是 `inkbridge.moon.koplugin-v*-alpha.zip`,但**包内目录名永远是
> `inkbridge.koplugin/`** —— KOReader 靠目录名认插件,改它会让老用户升级时多出一个旧插件。

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
10. **云端文件名整理(0.2.17)。** 原名 `死人经…-0612日58分36秒-c7t8147.d31f852b.InkBridge.txt`,
    85 字节。两个问题:
    - 时间格式 `%d%H日%M分%S秒` 是「日+时+分+秒」,**不含月份** —— 9 月 6 日与 10 月 6 日
      会生成一模一样的名字;而且「日/分/秒」三个汉字多占 9 字节。
    - 设备名后又拼了「设备 ID 尾四位」(如 `c7t8147`),但**没有任何代码读它**,
      设备名本身已经在前面了。
    → 新格式 `<书名>-MMDD-HHMMSS-<设备名>.<短哈希>.InkBridge.txt`(75 字节),
      时间可读、可按字典序排序、纯 ASCII;去掉设备 ID 尾四位;书名/设备名分别限 40/16 字符。
      短哈希与 `.InkBridge.txt` 后缀保持不变 —— 前者是跨设备认书的依据,后者是 KOReader
      WebDAV 列表的显示条件,都不能动。旧文件名的记录仍能被 `is_inkbridge_record` 匹配
      (它只看 `.<短哈希>.InkBridge.<扩展名>`),所以云上已有的记录无需改名。
11. **文件名截断按字节的 bug。** `safe_filename_component` 原来用 `value:sub(1, n)` 截断,
    对中文是按字节切 —— 会把一个汉字劈成半个,生成非法 UTF-8 文件名。
    → 改用 `State._utf8_sub` 按字符截断。
12. **用户可见文案统一为中文,内部错误码不再外泄(0.2.18)。** 原先
    `inkbridge_webdav.lua` 的 toast 全是英文、`main.lua` 是「中文外壳包英文内核」
    (`InkBridge: 下载失败：remote_record_invalid_json`)。
    → 新增 `WebDAV.describe_error()`:回调里仍返回稳定的英文错误码(测试依赖它们),
      只在显示时翻译;HTTP 状态码单独摘出来并附常见原因(401 认证、403 权限、404 不存在、
      409 路径冲突、507 空间不足…)。未知错误**原样返回**,不吞排查线索。
    → 删除空壳 `inkbridge_i18n.lua`(只有 `_meta.lua` 在用,`translate` 就是原样返回)。
      以后真要国际化,正统做法是 `require("gettext")` + 英文源串,可直接复用
      KOReader 自带的几十种语言翻译;现在文案是中文硬编码。
13. **一批小清理(0.2.18)。**
    - `_download_staging_path()` 不再用远端(中文)文件名当本地临时名,改为固定的
      ASCII 名 `download.tmp` —— 避免 Windows 上 ANSI 代码页打不开中文路径;
    - 删除死代码 `_staged_path()`;
    - 删除 `pick_server()` 里不可达的 `apps/cloudstorage/syncservice` 兜底
      (现行 KOReader 的云存储已迁到 `plugins/cloudstorage.koplugin`),改为给出
      可执行的提示;
    - `findAllText` 全文搜索前后用 `Device:setIgnoreInput()` 吞掉输入(照
      readersearch.lua 的做法),异常路径也保证恢复;
    - `_sync` 下载分支的内层回调把外层的 `ok` 遮蔽了,改名为 `download_ok` 并重排了缩进。

## 已知精度上限:分页模式是「页级」定位(特性,非 bug —— 记录在案,暂不修)

**现象**(实机,2026-10-06):两台设备同步后,**章节开头能完全对齐,章节中间会差几行**。
用户实测判定「非常接近,不影响接续阅读」,暂不处理。

**实测数据**(两份记录 × EPUB 原文交叉核对):

| | c7t(汉王) | kpw6(Kindle) |
|---|---|---|
| xpointer | `DocFragment[287] p[22] text().71` | `DocFragment[287] p[23] text().23` |
| 按该偏移到原文取字 | `龙王给出个说法，如果真有冒充者，请龙王指…` | `者，挺着硕大的肚子说：“有人对我说，我家…` |
| 与记录里的 `ta` 字段 | 逐字一致 | 逐字一致 |

- 两处相隔 **47 个字符 ≈ 两行**;
- `DocFragment[287]` ≡ `Text/chapter1_35.xhtml` ≡ 第二百八十二章「伏击」(spine 顺序与 ncx 目录双向确认);
- 两份记录都**忠实反映了各自设备屏幕顶端的位置**,所以差异不是采集错误。

**机制**(源码依据,`readerrolling.lua:1203`):

```lua
function ReaderRolling:_gotoXPointer(xpointer)
    if self.view.view_mode == "page" then
        self:_gotoPage(self.ui.document:getPageFromXPointer(xpointer))  -- 换算成页码
    else
        self:_gotoPos(self.ui.document:getPosFromXPointer(xpointer))    -- 精确纵向位置
    end
end
```

分页模式下,xpointer 被**换算成「包含该位置的页码」再跳到该页开头** —— 屏幕顶端是那一页的
首字,而不是记录的那个字。误差 = 记录位置在其页内的纵向偏移(通常几行,上限一页)。

**这正好解释「分型」**:章节开头本身就是页首,所以「跳到该页开头」== 记录位置 → 分毫不差;
章中是页内某处 → 只能落到页首 → 差几行。

**不是本插件独有的问题**:KOReader 自己的进度同步(kosync)用的是同一个 `GotoXPointer`,
页级粒度完全相同。分页模式下「页」是 crengine 的渲染单位,页内纵向位置无法单独指定。
**滚动模式例外**:那条分支走 `_gotoPos(getPosFromXPointer(xp))`,是逐字精确的。

**已排除的猜测**:曾怀疑 `self.xpointer` 在普通翻页时不刷新(`onPageUpdate` 只更新
`current_page`)。但点击/滑动翻页走的是 `onGotoViewRel`,`readerrolling.lua:947` 会重新
`getXPointer()`,且实测记录与屏幕首行逐字一致 —— 该猜测不成立。

**待做的判定实验**(三步,尚未执行):
1. A 停在章中某处并上传;
2. B 下载并跳转,**跳完不要移动**,记下屏幕首行;
3. B 直接上传,比较两份记录 —— 若 B 的位置比 A **早**(≤ 一页),且 A 的位置落在 B 同页靠下处,
   则「页首吸附」实锤。

**可能的应对方向**(均未实施):
1. 文档写明(已写入插件 README 的「当前限制」);
2. 重度用户切到滚动模式可获逐字精度(需改变阅读习惯);
3. 插件侧补偿:目前找不到可行路径 —— `_gotoPos` 在分页模式下仍然只显示包含该位置的整页。

> **跨阅读器(静读天下)的同类问题**另记在
> [`research/moonplus-po-format.md` §8](research/moonplus-po-format.md)：
> 除了"页级取整"，还有一条更隐蔽的 —— 写回对方进度时若写"本页页首"，
> 因为对方回写的是**它自己的屏首**（比我们写的早几十字），来回一趟会后退一页（**实测已确认**）。
> 该节同时论证了**为什么不该**把它"修"成写页尾（那会漏读一整页未读内容），
> 以及"不重读"与"不漏读"在两端排版不同时为何无法兼得。

## 仍未处理

1. **一个未闭环的疑问**:最初的实机现象是「在 8922 页的设备上于第 2222 页上传,在 8689 页的
   设备上落到第 2164 页」,而 2164 恰好等于 `floor(percent × 总页数) + 1`,说明当时走的是
   百分比分支;但后来实测跳转确认框显示的是「xpointer 内容锚点(精确)」,即 xpointer 是可解析的。
   两种可能:(a) 当时那条记录的 xpointer 在接收端确实解析失败(汉王 C7T 是第三方分支,
   crengine 的 DocFragment 切分可能与官方版不同);(b) xpointer 一直可用,2164 本来就是
   「那段文字在该设备上的页码」,只是页码数字不同。
   **下次双设备同步时请顺手记录两台分别停在第几页**,即可判定,然后更新本节。
2. 文本锚点的字符偏移是按 crengine 的字符口径解析的(与 `_utf8_*` 一致)。若某个 KOReader
   分支的 `text().N` 用的是别的口径,锚点会退化为「段落开头」水平 —— 需要真机走一次降级
   路径才能确认(目前只在单元测试里覆盖)。
3. 云端历史文件只增不减,没有自动清理;若要回收空间需手动删。
4. 真机矩阵仍不完整:目前在 Android 与 Kindle 上验证过完整流程,汉王 C7T 只作为上传端
   参与过,尚未做「同一台设备之间」与更多 KOReader 版本的交叉验证。
5. **分页模式的页级精度**(见上一节):用户判定不影响阅读,记录在案,暂不修。
