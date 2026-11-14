# InkBridge / 墨桥开发交接

**适用对象：** 接手 InkBridge（KOReader 插件）的后续 agent。
**状态截至：** 2026-11-14。
**当前版本：** `0.3.7-alpha`。

这份文档是面向下一项开发任务的压缩交接，不取代源码、回归测试或详细研究记录。遇到冲突时，以当前源码和 `AGENTS.md` 为准；旧研究文档中标有“已解码”的早期推断，可能已被后续版本纠正。

## 1. 当前工作区与可交付物

- 主仓库：`D:\UserData\Documents\开发\墨桥`
- 主分支：`main`
- 代码与安装包对应的提交：`74e94cc`（实现静读天下整书字符坐标导入并打包 0.3.7-alpha）。本交接文档随后以文档提交单独保存；查当前 HEAD 用 `git log -1 --oneline`。
- 当前分支：`main`；工作区干净。包含未推送的本地提交，不要据此推断远端状态。
- 安装包：`D:\UserData\Documents\开发\墨桥\releases\inkbridge.moon.koplugin-v0.3.7-alpha.zip`
- 包大小：93,567 字节；SHA-256：`4A29291F240B95136CE72261DFF57F4A7AE6EDF65A70F7183D7DB37F6BE7991C`
- 打包器逐文件核对通过，ZIP 完整性检查通过。`releases/` 被 Git 忽略，包是本地工件，不在提交内。
- 当前六套 LuaJIT 回归测试全部通过，共 **923 条断言**。这只是桩测试，不等于 0.3.7-alpha 已经在 KOReader/Android/墨水屏设备上验证。

本次核心变化：Moon+ `.po` 的 `*N#offset` 不再硬套 KOReader `DocFragment`；改为换算为原 EPUB 的整书 Unicode 正文字符坐标，提取正文锚点，再要求 KOReader 全文**唯一命中**才跳转。无可靠命中就停止，不用页码比例猜位置。

## 2. 先读哪些资料

按当前权威性和用途排序：

1. `AGENTS.md`：仓库硬性约束、测试要求、版本/打包/远端操作规则。
2. `DEVELOPMENT.md`：架构、历次修复、已知精度边界和仍未闭环的问题。
3. `inkbridge.koplugin/README.md`：用户实际可见行为、菜单、安装和限制。
4. `research/moonplus-po-format.md`：Moon+ 写回、双端页首与来回同步漂移的详细研究。
5. `D:\UserData\Documents\开发\墨桥-samples\po-findings.md`、`MOON-互操作-现状与下一步.md`：样本分析与实验工具。它们含有**早期章节映射假设**，见下文“历史结论更正”。

公开仓库中 `koreader-master/` 与 `reference/` 是本机参考快照，不要把它们当作插件源文件；唯一插件开发目录是 `inkbridge.koplugin/`。

## 3. 不可违反的项目约束

- **不要 push、tag、创建/删除 GitHub release 或改远端。** 只有用户在当轮明确要求“发/推”才可操作；真机功能改动还必须先由用户验证。不要主动询问或暗示要发布。当前任务只交本地工件和本地提交。
- 版本沿用 `0.3.x-alpha`，`0.3.0` 是正式版基线；不要自行跳到 `0.4.0`。一次对话最多生成一个版本包。
- 包名按 `inkbridge.moon.koplugin-v<版本>.zip`；ZIP 内插件目录必须始终叫 `inkbridge.koplugin/`，否则旧版目录可能残留并导致重复运行。
- 由 `D:\UserData\Documents\开发\墨桥-samples\build_release.py` 打包。不要用过期的解压目录或手工复制出来的插件副本。
- 纯 Lua 代码需保持 LF。改任意 Lua 后跑完六套测试；新增 spec 也要更新 `tests/run_all.sh` 和 `AGENTS.md` 的测试清单。
- 分清静态检查、桩测试、打包验证和真实设备验证；不可把前三者说成“真机可用”。
- Moon+ 手动导入读取 `.po` 是 GET/只读流程；独立的上传/写回流程会更新 `.po`，必须保留其备份、写入后回读校验和错误守卫。不要把两条流程混为一谈。
- 不要递归扫描坚果云/Nutstore 用户目录。枚举可能触发云文件下载；只读用户明确给出的确切本地路径，或让用户先复制样本到 `墨桥-samples/`。
- 旧的 `D:\UserData\Documents\ChatGPT\Syncery 兼容静读天下` 是另一份旧工作区，不是本项目源目录；不可把它的版本号、源码、发布流程直接套到这里。

## 4. 代码地图与主要数据流

- `inkbridge.koplugin/main.lua`：菜单、上传/下载流程、设置和提示。
- `inkbridge.koplugin/inkbridge_state.lua`：位置记录、锚点、JSON/schema 与紧凑载荷兼容。
- `inkbridge.koplugin/inkbridge_webdav.lua`：KOReader Cloud Storage/WebDAV 接口、文件列表/上传/下载/删除、跳转规划与确认。
- `inkbridge.koplugin/inkbridge_moon.lua`：Moon+ `.po` 的解析/生成、UTF-8 字符处理、HTML 正文块、字符偏移工具、目录 URL 工具。
- `inkbridge.koplugin/inkbridge_moonsync.lua`：Moon+ `.po` 的 GET、EPUB spine/正文统计、进度换算与导入/写回流程。
- `inkbridge.koplugin/_meta.lua`：版本唯一权威来源。
- `tests/`：六套 LuaJIT 单测；使用桩，不启动 KOReader UI，也不等价于设备测试。

## 5. Moon+ `.po` 格式与 0.3.7 定位方案

常见 `.po` 单行形如：

```text
1785683827794*1144@0#2821:94%
```

当前理解：

- 首个数字在本项目已测的跨书样本中相同，不是位置坐标。本项目早期笔记称其为账号级；外部 MoonSync 将同一设备跨书重复的 13 位字段视为设备/安装标识，而不是时间戳。InkBridge 尚未独立验证其语义，不要宣称账户级已证实；代码应当作不透明字段保存、写回时原样保留。
- `*N` 是 Moon+ 的源坐标；0.3.7 **当前实现按原始 EPUB spine itemref 序号（0 基）解释它**，不是 KOReader 的 `DocFragment`。对含非 HTML spine item 的真实 Moon+ `.po`，这一点尚无设备证据，是 0.3.7 必须重点验证的假设之一。
- `@0` 含义未知，历史样本中恒为 0；写回时原样透传，不自行赋予语义。
- `#offset` 是 Moon+ 逻辑章节内的字符偏移。按 HTML 正文块顺序、忽略空白再计 Unicode 字符，能复现本项目已分析的部分小说样本；外部 MoonSync 作者认为 offset 可能按 HTML 源文本（含空白）计数，但也明确称 Moon+ 是否折叠空白尚未证实。两者是冲突假设，必须用真实样本判别，不能把任一方说成通用定论。
- `:percent` 是 Moon+ 显示的进度百分比；单独改它不会改变 Moon+ 自身落点。它与 EPUB 纯文本比例的精确关系仍需多书验证。0.3.7 只把它用于宽松一致性校验/显示，不用于挑选 KOReader 搜索结果。

0.3.7 的步骤：

1. 解析 OPF 中原始 `<spine>` itemref 顺序，形成完整 `spine_all`。非 HTML 项（如封面图）保留序号槽位但贡献 0 正文字符，避免后续序号漂移。当前没有解析 TOC anchor 来拆分单个 HTML 文件中的多个 Moon+ 逻辑章节。
2. 对可读 HTML 项用 `Moon.blocks_from_html` 读取正文块，并以 Unicode 字符计数累加；缓存整书每个 spine 槽位的起点、总字符数和 HTML 到原始槽位的映射。
3. 以 `starts[star+1] + hash` 得到整书字符位置，校验 `star/hash` 范围；与 `.po` 百分比差距**超过 3 个百分点**就停止。
4. 在目标正文块附近截取 48 字符锚点，再交给 KOReader `findAllText`。
5. Moon+ 导入设置 `require_unique_text=true`。恰好一个可用命中才生成本机 xpointer；零命中、重复、搜索失败、无效命中、越界均报错停止。该专用路径不按 Moon+ `star` 筛 KOReader 章节，不按 `pos_percent` 挑命中，也不退回页数百分比。

新路径的主要测试：`tests/moonsync_spec.lua` 覆盖含非 HTML spine 项的合成 EPUB、累计字符坐标、偏移越界和百分比差异；`tests/webdav_spec.lua` 覆盖唯一/重复/零命中和无搜索接口时不跳转、不走页数兜底。

### 重要的证据边界与冲突记录

- `墨桥-samples/po-findings.md` 和 `MOON-互操作-现状与下一步.md` 在 2026-10-06 曾根据《死人经》样本总结 `*N = DocFragment[N+1]`。这是当时若干样本里的经验关系，不能推广成跨书规则；《绍宋》出现章节错位后，用户明确否定“每本书单独标定 spine”以及固定 `star+1`。**0.3.7 的 Unicode 整书坐标方案取代了旧的导入映射结论。**那些旧文档作为实验史保留，不要照抄其“最终字段语义”用于新导入代码。
- 0.3.7 的 synthetic test 证明“实现能保留并累计 raw spine 槽位”，**不能证明 Moon+ 的 `*N` 一定包含非 HTML itemref 槽位**。若《绍宋》或《死人经》EPUB 的 OPF spine 含非 HTML 项，真机导入的对照结果将直接验证/证伪这个索引假设；不要把单测通过描述为这条语义已实证。
- 外部 [MoonSync 工作原理记录](https://github.com/Spagoodlers/moonsync/blob/main/docs/how-it-works.md)说明它测试 `toc-all`（正文 TOC anchor 均拆章节）、`toc-split`（只拆超过 100,000 字的大文件）和 `spine`（一个 spine 文件一章）布局。小说类书籍常常三种布局结果相同，差异更多见于 TOC 指向文件中间的技术书。候选需 offset 落在章节范围、文本百分比与 Moon+ 百分比相差不超过 5 点；多候选时优先已学习布局，否则取最接近显示百分比的布局。无候选时虽可退到百分比定位，但会拒绝回写 `.po`，以免污染 Moon+ 进度。作者也列出大文件大小拆分、跳过封面/EPUB3 nav、空白计数规则等未验证处。
- 因此“`*N` 就是 raw spine itemref 下标”与“`#` 是去空白字符偏移”都是 0.3.7 的**主要待证假设**。现有《死人经》样本吻合不能推出所有书吻合；同一本 EPUB 也可能因 Moon+ 的 TOC 章节切分口径不同而不吻合。用户不希望退回逐书手工标定，所以若 raw-spine 假设失败，应研究用统一的 EPUB TOC/DOM 候选模型自动识别 Moon+ 逻辑章节；允许算法按书自动判别/缓存结果，但不能要求用户逐本人工标定或写书名特例。
- Moon+ 的显示百分比与 EPUB 纯文本字符比例可能因图像、分页留白和章节布局而不同。外部 MoonSync 文档报告样本常差 0.3–3.5 个百分点；它用 5 个百分点筛布局候选，而非直接按百分比决定书内位置。InkBridge 当前 3 点硬拒绝阈值可能误拒有效记录，须用本项目真实样本测分布再决定；歧义时仍要停止，不能为了“总能跳”去猜位置。
- 写回方向历史上仍会用 KOReader xpointer 的章节结构生成 Moon+ 的 `*N/#offset`；这不证明反方向的 `*N` 能直接映射到 KOReader `DocFragment`。
- 研究样本《死人经》`*1144#2821:94%` 按字符累计落在 `chapter7_64.xhtml` 附近，正文比例约 93.69%，和 `.po` 相差约 0.31 个百分点。《绍宋》的当前 Nutstore `.po` 曾是 `*10#262:1%`，字符换算约 0.73%，落在 `J01-006.xhtml`；之前对话中的截图看起来像 `J01-007.xhtml`。这可能是 `.po` 生成/缓存时序不同，**不能声称此真机案例已解决**。测试必须确保截图、`.po` 与 EPUB 真的是同一次状态/同一本内容。
- 现阶段证据是本地样本分析、坐标解码和合成夹具单测；0.3.7 导入的新定位流程尚未在设备上运行。Unicode、空白、实体、DOM 分块以及阅读器全文搜索口径在不同真实 EPUB/KOReader 分支上可能有差异。

## 6. 其他已确立的行为与边界

### KOReader 跨设备同步

- 记录有排版无关的 `text_anchor`、`pos_percent`，也保留 `xpointer`、页码比例等兼容字段；载荷用短字段名并能读取旧 schema/长字段格式。历史实测记录体积从约 541 字节降到约 270 字节。
- 普通 KOReader 同步跳转顺序为：先预检并尝试 xpointer；校验它是否指到记录中同一段首行文字；失配则全文搜索文字锚点并按内容比例消歧；最后才允许普通记录走页数比例兜底。无效 xpointer 绝不能直接交给 crengine，因为解析失败可能 `SetPos(0)` 跳书首。
- Moon+ 导入是更严格的特例，唯一命中失败时**不允许**普通路径的页数比例兜底。
- 分页模式只能跳到包含目标文字的本机整页页首，首行可能比远端位置早几行、最多一页；这是 KOReader 的页级渲染粒度，插件不能精确控制页内纵向起点。滚动模式可按 y 位置精确定位。0.3.6 起确认框/自动提示应如实报告首行和行号差，不能承诺分页首行逐字相同。
- Hanvon/第三方 KOReader 分支可能出现 xpointer“解析成功但落到别处”。首行文字校验用于识别并降级，不要仅以 `createXPointer` 成功认定位置正确。

### WebDAV / Cloud Storage

- 复用 KOReader Cloud Storage provider，下载历史记录走只读 provider 调用；不可改成可能在回调后重新上传的 `Cloud:sync`。
- `.po` 在云浏览 UI 中看不到不等于不能取；扩展名过滤只影响列表显示，按用户配置的确切路径直接 GET 不受 UI 过滤影响。
- 用户配置 Moon+ 目录必须明确选定，避免自动猜错导致悄悄读错书。
- 目录选择使用 KOReader 云浏览器入口 `ui.cloudstorage:onShowCloudStorageList(cb)`；“选择当前目录”通常要长按其标准提示行。0.3.4 自写/误用 CloudStorage 窗口入口的方案实机失败并撤回；0.3.5 才改用正确入口。不同 API 版本须保留安全兜底和明确报错。
- 网络 provider 可能把操作推迟到联网后才真正执行；必须在实际回调结束时恢复临时 provider 状态（如 `show_unsupported`），不能根据 `run()` 返回就提前还原。
- provider `base` 传副本，避免 provider 修改插件的持久设置对象；异常、异步和回调路径都要恢复原值。
- 下载路径使用纯 ASCII 本地暂存文件名；中文远端文件名在 Windows ANSI 代码页下可能无法作为本地路径打开。
- 上传结束后在 provider 回调中清理暂存文件；回调前删除会导致 provider 尚未读取完文件。
- 删除云端历史要保留路径校验、按设备/书籍精确筛选和“绝不误删”守卫。每台设备每本书保留最近 10 条（0.3.0 起）；新上传记录不得被清理策略删掉。

## 7. 历史里程碑和踩坑记录

Git 完整历史比此表更全；下列是影响后续判断的阶段：

- **0.2.13-alpha 基线（2026-10-06）：** 下载路径校验非法 Lua 模式导致必然崩溃；`(txt|json)$` 被误当正则交替导致历史列表永远为空；上传暂存泄漏；离线操作无反馈；provider 共用设置表。均已修复并写入 `DEVELOPMENT.md`。
- **0.2.15 附近：** 发现页数比例跨设备不准；增加 xpointer、正文锚点和内容高度比例的分级定位。xpointer 无效预检不可省。
- **0.2.16–0.2.18：** 记录紧凑化、云文件命名、UTF-8 截断、中文错误文案、ASCII 暂存路径和全文搜索输入防护。
- **Moon+ 互通（2026-10-06/07）：** `.po` 解析/生成，手动指定目录、自建只读 GET、位置导入、上传时顺带写回、备份后写入并 GET 回读校验、更新列表/时间/方向提示。反复真机校准确认 `#` 字符口径与 `:%` 的角色，也发现双端页面边界带来的回退现象。
- **0.3.0：** 上传后清理旧云记录，每台设备每本书最多留最近 10 条；移除没有入口的独立写回按钮。
- **0.3.1：** 默认设备标签优先读设备型号，按字符截断，避免所有 Android 设备共用一个“Android”标签。
- **0.3.2：** Readest 被明确标为不建议接入；其 WebDAV 位置格式与 KOReader xpointer 不兼容，不是等待调参即可解决的功能。
- **0.3.3 → 0.3.5：** 自写目录浏览器的测试通过但真机不可用；随后也曾借错 KOReader 窗口入口。结论：KOReader UI/云存储交互的桩测试不能替代真机 API 验证；最终用官方 `onShowCloudStorageList` 回调。
- **0.3.6（2026-10-11）：** 首行文字提升为 xpointer 的交叉核验锚点，落点差距如实报告；修复 `show_unsupported` 异步还原、滚动模式误报、Moon+ 旧章节多命中误选、自动提示漏报。
- **0.3.7-alpha（2026-11-14）：** Moon+ 导入改为整书 Unicode 正文字符坐标 + 唯一全文命中；923 条回归绿，尚待设备验证。

### 高价值技术教训

1. **Lua 模式不是 PCRE：** 没有 `|` 交替；扩展名要拆开比较或用正确的 Lua 模式。字符类中直接包含 NUL 会导致 `malformed pattern`，要避免这种模式或用 `%z` 单独处理。每个模式改动先跑最小例子，再跑全回归。
2. **Lua 长字符串也会踩语法坑：** 模式含 `]` 时 `[[...]]` 可能提前闭合。用普通引号/合适等级长括号，并先做 LuaJIT 语法检查。
3. **LuaJIT/KOReader 不是普通现代 Lua：** 以项目自带 LuaJIT 为准；Windows 测试直接逐个执行 spec。`tests/run_all.sh` 是 shell 脚本，不能用 `luajit tests/run_all.sh`，会报 `unexpected symbol near '#'`。若换机器，先确认已安装 LuaJIT。
4. **测试入口看退出码：** 不能只看控制台是否打印“合计”或日志里是否有 PASS；语法错误/异常退出必须让整个任务失败。
5. **字符数按 UTF-8 字符而非字节：** 文件名、截断、偏移、锚点都注意边界；不能 `string.sub` 把多字节汉字截断。
6. **不同百分比是不同单位：** `percent` 是本机页序比例；`pos_percent` 是内容高度比例；Moon+ `:%` 是字符内容比例近似值。不可混用。0.3.6 的章节内比例消歧也曾选错章，因此 0.3.7 Moon+ 路径改为唯一全文命中。
7. **锚点必须能在目标阅读器中完整搜索：** 不要跨 HTML 块/段落拼片段；读不到足够长的片段就报错，不要静默切到低精度兜底。
8. **UI/网络是异步的：** 真正的完成时机是 provider 回调，不是调用函数返回；清理、状态恢复和提示都要按 callback 时序设计并写推迟执行测试。
9. **KOReader 的 API 入口要核对当前上游源码与本机版本：** 有窗口对象的方法名相似，不代表属于同一个对象；旧路径上的方法可能不可达。
10. **安全优先于“总能跳过去”：** 位置不明确就停止并解释原因。错误地跳到另一个章节比提示无法定位更糟。
11. **页级粒度不是位置解析 bug：** 分页模式无法把屏幕首行精确放到页中任意 y；不要在插件里制造虚假的“完全对齐”提示。
12. **避免无证据的文档承诺：** 曾有账号密码保存方式、时间戳唯一性、文件名结构、章节映射等说明写错。文档描述须由实际代码或设备实验支持。

### 用户此前提及的外部参考项目

这些是研究线索，不是 InkBridge 依赖，也不代表其坐标规则可以直接移植；接手后若要借鉴，先看对方当前代码与测试。

- [moonreader-koreader-sync](https://github.com/crazystress/moonreader-koreader-sync)：Dropbox webhook/变更游标读取 Moon+ `.po`，再推送 KOReader 兼容服务；项目说明主要解析百分比，并以 partial MD5 识别书籍，要求两端书籍文件字节一致。可借鉴“源端同步/目标协议适配”的拆分，不可据此认为百分比足够做跨排版精确定位。
- [moonsync](https://github.com/Spagoodlers/moonsync)：Calibre 插件经 Dropbox/同步目录双向读写 Moon+ `.po`；作者要求两端使用同一 EPUB，并公开 TOC/spine 候选布局、offset 与百分比交叉校验、按书/设备学习的做法与已知限制。它还指出 Moon+ 记录的是当前显示页顶部字符，导入到不同排版后出现页级提前属可预期；如果导入 MoonSync 自己写出的 `.po`，会有最多约 3000 字符的回声差异，避免往返同步每次后退。它是当前最值得比对的实现；InkBridge 可研究通用自动推断并缓存结果，但应保持无需用户逐本手工调参，且歧义时停止。
- [moon-to-ko](https://github.com/sRamosDev/moon-to-ko)：把 Moon+ `.mrpro` 备份迁移为 KOReader 资料/书籍/规则的工具，不是在线 `.po` 跨设备同步方案；README 明确是个人实验工具并提示谨慎使用。可作为备份解析器参考，不应混同当前产品目标。

## 8. 当前未闭环的问题与下一步建议

### 首要任务：在真实设备测 0.3.7-alpha

建议直接安装本地 ZIP；KOReader 插件目录应只保留一个 `inkbridge.koplugin/`，覆盖前先备份用户自己的设置/旧目录，解压后重启 KOReader。测试至少包括：

1. 用《绍宋》确认实际测试的 EPUB 文件 hash、KOReader 当前 `.po` 精确内容、Moon+ 屏幕位置和文件同步时间一致；重点查明 `*10#262:1%` 对应 `J01-006` 与截图 `J01-007` 的时序差。
2. 用《死人经》再测一次，验证不依赖旧 `star+1` 映射；确保测试的是同一份 EPUB，且是同一条最新 `.po`。
3. 在 KOReader 导入后记录确认框采用的定位方式、页面首行、页码/模式；分页模式只期望落在包含目标文字的页，不要要求页内首行逐字对齐。
4. 若出现“不唯一/未命中/比例差异过大”，先保存该提示和确切样本，不要临时把失败改成百分比跳转。
5. 测试两个以上 KOReader 分支/设备前，区分“字符坐标正确但本机全文搜索规则不同”和“Moon+ 源坐标换算错误”。可用 `墨桥-samples/po-verify.py`、`po-align.py` 对确切 EPUB/`.po` 做离线对照；避免从 Nutstore 遍历取样。
6. 用户可以提供手机截图/录屏来确认屏幕首行、确认框与页面结果。KOReader 桌面版可用于低成本检查插件加载、通用 Lua/UI 和部分 EPUB 搜索流程，但不能代替 Moon+ 云端同步，也不能代表汉王/Android 分支的 crengine 与 Cloud Storage 行为。

### 后续技术审查候选（先有实测证据再改）

- 比较 KOReader `findAllText` 实际对 `max_results=8`、空白规范化、大小写/标点和实体解码的语义；不要仅因参数名猜测。
- 若需要研究外部 `moonsync` 的代码，重点核对其 TOC anchor 分章、spine 候选、offset 空白口径和 `.po` 百分比布局判定；可设计 InkBridge 通用自动候选与置信度判定（内部缓存只用于加速），由 offset 范围、整书比例和正文唯一命中共同验证。百分比只帮助筛候选，不作为最终跳转位置。只有一个候选可信时跳转，无法区分则停止。先拿本项目样本验证，不要引入逐书人工配置。
- 用真实 EPUB 检查 OPF 中 spine/manifest href 的相对路径、大小写、查询/锚点、XML namespace/单引号、非 HTML 与空正文项。当前解析器偏轻量，需以真实问题驱动扩展，避免大范围重写。
- 检查 `moon_book_metrics` 缓存（文件路径、size/mtime）在书籍替换、时钟变化、网络文件系统/缺少 lfs 时是否失效；若改缓存键需加缓存失效测试。
- `:%` 的 3 个百分点是安全阈值而非绝对真理；若某书正文规范化差异造成误拒绝，应先量化来源，再决定更好的校验，不可取消唯一命中保护作为绕过。
- 收集 0 命中与多命中的真实样本，看是否需要更稳健的 anchor 构造（如按 Unicode 码点滑窗、前后文组合、分段确认），但任何更宽松定位都必须保持不会静默选错章。
- 设备测试确认后再更新文档中的验证状态；如果改 Lua，重跑全部 923 条测试，构建一个版本包并校验，不生成第二个临时版本包。

## 9. 本机开发与交付步骤

### 六套回归测试

当前机 LuaJIT：

```powershell
$luajit = 'C:\Users\raven-stand\AppData\Local\Programs\LuaJIT\bin\luajit.exe'
& $luajit tests/moon_spec.lua
& $luajit tests/moonsync_spec.lua
& $luajit tests/update_spec.lua
& $luajit tests/webdav_spec.lua
& $luajit tests/main_spec.lua
& $luajit tests/state_spec.lua
```

断言数分别为 `159 + 286 + 48 + 270 + 79 + 81 = 923`。任一返回码非 0 都是失败。

### 生成/校验本地 ZIP

```powershell
$python = 'C:\Users\raven-stand\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe'
& $python 'D:\UserData\Documents\开发\墨桥-samples\build_release.py'
& $python 'D:\UserData\Documents\开发\墨桥-samples\build_release.py' --check
```

打包器读取 `_meta.lua` 生成版本名，并逐文件比较 ZIP 与当前插件目录。另可计算：

```powershell
Get-FileHash 'releases\inkbridge.moon.koplugin-v0.3.7-alpha.zip' -Algorithm SHA256
```

中文 UTF-8 文件优先用已配置的 Python 明确 `encoding='utf-8'` 读写，避免 PowerShell 代码页损坏；本地代码编辑按仓库工作流使用 patch 工具。提交信息用 UTF-8 文件并 `git commit -F <文件>`。

## 10. 交接给下一位 agent 的最短结论

先不要继续改定位算法，也不要把旧样本中的 `star+1` 关系加回去。先让用户在真实 KOReader 上用 0.3.7-alpha 对《绍宋》和《死人经》分别做一次同文件、同时间点验证；保存 `.po` 精确行、EPUB 文件身份、确认框和实际落点。依据这些证据决定是否调整 Unicode 正文提取、百分比宽容度或锚点算法。当前唯一能确定的开发状态是：**实现与桩测试完成，安装包已验证，真实设备定位效果未知。**
