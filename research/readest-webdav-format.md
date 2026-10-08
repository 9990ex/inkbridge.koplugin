# Readest WebDAV 同步格式 —— 破译报告（附"能不能给墨桥用"的结论）

> 状态：**格式已解**（源码级，非抓包）；但**结论是"不要接"**。
> 源码：`D:\UserData\Documents\开发\readest-main`（用户 2026-10-08 取回，`apps/readest-app` + `apps/readest.koplugin`）。
> 所有断言都标了出处（`文件:行`），没有推测。

---

## 0. 一句话结论

目录、文件名、JSON 结构全拿到了，**写文件很容易**；但 Readest 有三条进度通道，
**只有两条懂 KOReader 的 xpointer，WebDAV 那条不懂**：

- WebDAV 通道应用进度时只做一件事 —— `view.goTo(config.location)`，
  而 `location` 是 **foliate 的 EPUB CFI**（`useFileSync.ts:506-515`）。
- `xpointer` 字段在 WebDAV 通道里**只被搬运、从不被解析**：解析它的只有
  `useProgressSync.ts`（Readest Cloud，需登录，`useProgressSync.ts:335-368`）
  和 `useKOSync.ts`（koSync 协议，`useKOSync.ts:174-218`）。
- 所以墨桥就算把 KOReader 的 xpointer 写进 `config.json`，Readest 打开书也**不会跳过去**；
  它只会在自己下次 push 时把 xpointer 原样带回来。反方向同理：墨桥拿到 CFI 也用不了。
- → **Readest 这边已经有官方、免费、精度更高的 KOReader 通道（§7 A），墨桥不需要碰它。**

---

## 1. 目录布局（源码里标了 FROZEN，改了就孤儿化所有人的远端树）

`apps/readest-app/src/services/sync/file/layout.ts:10-38`

```
<rootPath>/Readest/
  library.json                       ← 共享索引
  books/
    <hash>/
      <safe-title>.<ext>             ← 书文件本体
      cover.png                      ← 可选
      config.json                    ← 进度 + 批注
      tts/                           ← 可选（TTS 语音包）
```

- `<rootPath>` 是用户在 WebDAV 设置里填的根目录，默认 `/`（`normalizeRoot`）。
- `<safe-title>` 由 `makeSafeFilename(title)` 生成，扩展名来自 `EXTS[book.format]`。
- 子树的**全部**读写都只发生在 `Readest/` 下面，不会碰用户其它文件。

### 1.1 书身份 = KOReader 的 partial md5（关键）

三处独立证据：

1. `src/types/statistics.ts:9`：`bookMd5: string; // = Book.hash = KOReader book.md5`
2. `apps/readest.koplugin/library/librarystore.lua:4`："via the partial-md5 hash that both sides already use"
3. `apps/readest-crosspoint-plugin/README.md:69-70`："the same file, identified by its KOReader-compatible partial MD5"

算法（`src/utils/md5.ts:11-30`）与 KOReader 的 `util.partialMD5` 同构：
`i = -1..10`，偏移 `1024 << (2i)`，每个偏移取 1024 字节，**顺序喂给同一个 md5**，越界即停。

> 含义：墨桥能自己算出目录名，**不需要遍历**远端就能定位/创建某本书的目录。

---

## 2. `config.json` 的确切结构

`src/services/sync/file/wire.ts:21-94`（`RemoteBookConfig` + `buildRemotePayload`）

```json
{
  "schemaVersion": 1,
  "bookHash": "d41d8cd98f00b204e9800998ecf8427e",
  "metaHash": "（可选，Readest Cloud 的行身份，md5(NFC(标题|作者|ISBN))）",
  "config": {
    "progress": [176, 411],
    "location": "epubcfi(/6/28!/4/20/1:58)",
    "xpointer": "/body/DocFragment[14]/body/p[45]/text().0",
    "updatedAt": 1760000000000
  },
  "booknotes": [],
  "referencePageCount": 8922,
  "writerDeviceId": "inkbridge",
  "writerVersion": "readest-webdav-1",
  "updatedAt": 1760000000000
}
```

- `config` 是**裁剪白名单**，只有 `progress / location / xpointer / updatedAt` 四个键会出网
  （`wire.ts:76-81`）。`viewSettings`、`searchConfig`、`rsvpPosition` 等一律留在本机。
- `progress` 是 `[当前页, 总页数]`，1 起（`types/book.ts:668`）——**Readest 自己的分页口径**。
- `location` 是 CFI（`types/book.ts:669`）；`xpointer` 注释写着 "for Koreader interoperability"（`:670`）。
- `writerVersion` 是**冻结的历史字串** `'readest-webdav-1'`，即使引擎早已与 provider 无关，
  也**不要**改（`wire.ts:14-19`）。
- `schemaVersion !== 1` → 整份 payload 被当成不存在（`wire.ts:96-105`）。
- `updatedAt` 是**毫秒**墙钟。

### 2.1 合并规则（决定了"省略字段"是安全的）

`mergeBookConfig`（`merge.ts:70-108`）：

- `remote.config.updatedAt ?? remote.updatedAt` 与本地 `config.updatedAt` 比大小，
  **`>=` 时远端赢**（完全 LWW，不比"谁读得更远"）。
- 远端 `null/undefined` 的键在 spread 前被**过滤掉**（`merge.ts:76-78`）→
  **省略 `location` = 不碰对方的位置**；省略 `booknotes` 也不会清空（批注另有 CRDT，`mergeNotes`）。
- 批注是 union-by-id + 每元素 `updatedAt/deletedAt` 的 CRDT，与标量谁赢无关。

---

## 3. `library.json`

`wire.ts:112-148`（`RemoteLibraryIndex`）

```json
{
  "schemaVersion": 1,
  "books": [ { "hash": "...", "title": "...", "progress": [176, 411], "updatedAt": 1760000000000 } ],
  "updatedAt": 1760000000000,
  "uploadedHashes": ["..."],
  "emptyDirs":      ["..."]
}
```

- 成员是 union-by-hash；删除靠 `deletedAt` 墓碑；行元数据按 `book.updatedAt` LWW。
- `books[]` 里**不能**带 `filePath / altFilePaths / coverImageUrl / downloadedAt / coverDownloadedAt / absDownloadedAt`
  （`wire.ts:164-184`，会引发"这本书本地丢了"的误删）。
- 货架上的百分比来自这一行（`merge.ts:137-146`），不是来自 `config.json` 的 `progress`。

---

## 4. Readest 什么时候读写这些文件

| 时机 | 行为 | 出处 |
|---|---|---|
| 打开书 | 拉一次 `config.json`（同一实例 30s 内不重复拉） | `useFileSync.ts:567-584` |
| 窗口重新获得焦点 | 拉（60s 冷却） | `useFileSync.ts:640-648` |
| 进度变化 | **5s 防抖** PUT 整份 config | `useFileSync.ts:82, 586-591` |
| 关书/失焦 | flush 挂起的 push | `useFileSync.ts:639-655` |
| "Sync now"/库级同步 | `engine.syncLibrary()`：拉索引 → 逐本 pull-merge-push | `runLibrarySync.ts:96` |

**应用进度的那一步**（这是全案的死结）：

- `useFileSync.ts:506`：`if (remoteProgressApplied(config.location, working.location))`
  → `await view.goTo(working.location!)`。**只看 `location`**。
- `FoliateViewer.tsx:864-868`：开书时 `const lastLocation = overrideLocation ?? config.location;
  if (lastLocation) view.init({lastLocation}) else view.goToFraction(0)`。
  → **`location` 缺失 = 从 0% 开始**，`config.progress` / `xpointer` 在这里都不参与。

`xpointer` 的两次真正被解析，都在别的通道上：

- `useProgressSync.ts:335-356`：把远端 `xpointer` 用 `getCFIFromXPointer` 换成 CFI，
  取"更靠后"的那个再 `view.goTo`；转换失败才退回整比分数（`:371+`）。**该 hook 依赖 `user`（登录 Readest Cloud）**。
- `useKOSync.ts:174-218`：koSync 协议拉到的远端位置，同样先换 CFI。

### 4.1 三条通道对照

| 通道 | 传输 | 进度字段 | 解析 xpointer？ | 要钱？ |
|---|---|---|---|---|
| Readest Cloud | Supabase HTTP | `location` / `xpointer` | ✅ | 登录即可（免费） |
| **KOReader（koSync）** | KOReader 同步协议 HTTP | `progress`(字符串) + `percentage` | ✅ | **免费**（设置里不带 Premium 角标） |
| WebDAV / Drive / S3 / OneDrive | 文件同步 | **只有 `location`(CFI)** | ❌ 只搬运 | 付费（见 §6） |

---

## 5. 为什么"墨桥写 xpointer 进去"没用（把链路走一遍）

1. 墨桥 PUT `Readest/books/<md5>/config.json`，带 `xpointer` + `updatedAt = now`。
2. Readest 打开这本书 → `useFileSync.pullNow()` → `engine.pullBookConfig()` → `mergeBookConfig()`。
   `remote.config.updatedAt` 更新 → 远端赢，但远端**没有** `location` 这个键 → 本地 `location` **原样保留**。
   xpointer 落进本地 config，仅此而已。
3. `remoteProgressApplied(config.location, working.location)` → 两者相同 → **不跳转**。
4. 之后 Readest 自己的 5s 防抖 push 会把合并后的整份 config 写回（此时含本地的 `location` 和我们的 `xpointer`）。

净效果：位置没动，但**写回了更晚的时间戳**。若墨桥写的是"更早的位置"，这一步会把
Readest 的 `config.updatedAt` 推新，**在纯 LWW 下把对方拖回前面**——这是真实风险，不是理论风险。

反方向（Readest → 墨桥）：拿到的 `location` 是 `epubcfi(/6/28!/4/20/1:58)`，
KOReader/crengine 没有 CFI 概念，只能退化用 `progress` 的百分比（精度还不如 `.po`：Readest 的分页是它自己的）。

---

## 6. 付费门槛，以及"怎么免费测"

- `src/utils/access.ts:69`：`CLOUD_SYNC_REQUIRES_PREMIUM = true`；WebDAV/Drive/S3/OneDrive 要 Plus/Pro/Lifetime。
- **但** `access.ts:167-184`：`isSelfHosted()` 为真时**解锁全部 premium**，登录与否都算。
- `docker/README.md:56-61`：官方镜像（`ghcr.io/readest/readest:latest`）默认 `SELF_HOSTED=true`
  → **拉自建镜像就等于拿到 WebDAV 功能，不用付钱**。
- 本地开发同理：`apps/readest-app` 有 `.env.web` / `dev-web` 脚本（`package.json:dev-web`），
  设 `NEXT_PUBLIC_SELF_HOSTED=true` 即可（`access.ts:177` 两个变量都认）。

代价：这是**网页版**（或你自己编的包），不是 App Store 里那个官方安卓 App。
要在 Android 上验证，得自己 `tauri android build` 带上环境变量。

---

## 7. 三条可行路线

### A. 不接（推荐）

Readest 侧现成两条免费 KOReader 通道，精度都比墨桥能做的更好：

1. **官方 KOReader 插件** `apps/readest.koplugin`（Readest 仓库自带、随 release 发布）：
   KOReader 装它 → 登录 Readest Cloud，进度以 **xpointer + 百分比** 双向同步。
   它**完全不碰 WebDAV**（`readest.koplugin` 全目录 grep `webdav` = 0 命中）。
2. **Readest 自带的 KOReader(koSync) 客户端**（设置 → 阅读同步 → KOReader，**免费**）：
   指向任意一台 koSync 服务器；KOReader 用自带的 progress sync 插件指向同一台即可。
   位置同样是 xpointer（`KOSyncClient.ts:215, 281` 就是标准 `/syncs/progress[/{doc}]`）。

结论：Readest 的"兼容平台"开关里，应把 Readest 标成"建议走官方 KOReader 通道"，
而不是做成一个只能搬运字段、动不了位置的空壳。

### B. 只做"货架可见 + 不碰位置"的弱桥（可做，价值有限）

- 写 `config.json`：`progress:[cur,total]` + `xpointer` + `updatedAt`，**省略 `location`**（安全）。
- 写 `library.json` 里那一行为 `progress:[cur,total]`、`updatedAt` 推新 → **货架百分比会变**。
- 位置不动（§5）。要"只前进"，得墨桥自己保证永不写回更早的位置——
  Readest 在这一通道里**没有** furthest-wins 保护。
- 风险：读改整份 `library.json` 是典型 lost-update（Readest 自己也只用 ETag + 串行化缓解）；
  墨桥的 WebDAV 层目前没有 ETag/If-Match。

### C. 全量 CFI ⇄ xpointer 互转（不建议）

- 转换**不是纯字符串变换**：`getCFIFromXPointer` 需要该 spine 段的 **DOM**
  （`xcfi.ts:723-741`，`bookDoc.sections[i].createDocument()`）。
- CFI 的元素步长语义是"**所有**元素子节点的偶数序号"（`/4/2/4/6/…`），
  而 KOReader 的 xpointer 是"**同类标签**的第 n 个"（`p[3]`）。
  `epubcfi(/6/4!/4/2/2)` ⇄ `/body/DocFragment[2]/body/div/p[1]`，
  `p[2]` 是 `/4`、`p[3]` 是 `/6`（`xcfi.spec.ts:84-115`）——
  中间夹了 `<h2>` 就会错位，所以必须真的解析 XHTML。
- Readest 团队自己都要在 KOReader emulator 里跑 `apps/readest.koplugin/scripts/xpointer-oracle.lua`
  逐词导出真机 xpointer，再回来校准转换器（`xcfi.crengine-oracle.test.ts`、`xcfi.crengine-semantics.test.ts`）。
  这说明该转换的边界细节靠猜必错。

在墨桥里自研这条路 = 在 Lua 里复刻 foliate 的 DOM 步长语义 + 一个真 HTML 解析器。**成本远超收益**，
而且失败了很难发现（错位一两个元素只会"跳错段落"，不会报错）。

---

## 8. 万一真要做 B：最小写入 & 配额账

请求量（单本书、单次）：

| 动作 | 请求 |
|---|---|
| 定位/写进度 | `GET Readest/books/<md5>/config.json`（只为拿 updatedAt 与 booknotes，可省） + `PUT` 同一路径 |
| 想让货架也变 | 再 `GET Readest/library.json` + `PUT` 回去 |
| 建目录 | 首次 `MKCOL`，父目录最多 3 级（`Readest`、`books`、`<md5>`） |

**不要**复刻 Readest 的 discovery：它会 `PROPFIND /Readest/books`（Depth 1）然后
**逐个 hash 目录再 PROPFIND** 去认书文件（`engine.ts:990-1026`），书多了是 O(N) 请求，
而且 config-only 的空目录会被记进 `emptyDirs` **直接跳过**——
即"只写 config.json 不写书文件"的目录，Readest 的发现逻辑**不会**认（`engine.ts:1021-1023`）。

必填最小集：
`schemaVersion:1` / `bookHash` / `config.updatedAt`（毫秒，**必须 > 对方**）/ `writerDeviceId` /
`writerVersion:"readest-webdav-1"` / `updatedAt`（毫秒）。

---

## 9. 未验证清单（都是"没跑过"，不是"推测有风险"）

1. 全程**没在真机跑过**（用户未付费；§6 的自建镜像路线也未实测）。
2. `DocFragment[N] → epubcfi(/6/{2N})` 的 spine 对齐，在汉王等第三方分支上是否与官方一致
   （与 DEVELOPMENT.md「仍未处理 #2」是同一个漂移风险）。
3. 章节级 CFI（如 `/6/28!/4/2`）foliate 是否接受、落在哪里，**未验证**。
4. 读改 `library.json` 的并发覆盖窗口（无 ETag）**未验证**。
5. koSync 路线的服务器从哪来（自建 kosync-dotnet / 公共 `sync.koreader.rocks`）**未落实**。

---

## 10. 附：本报告用到的一手出处

| 内容 | 文件 |
|---|---|
| 目录布局（FROZEN） | `apps/readest-app/src/services/sync/file/layout.ts:10-122` |
| config/library 的 wire 结构 | `.../sync/file/wire.ts:21-183` |
| 合并策略 | `.../sync/file/merge.ts:34-213` |
| 引擎（读写时机、发现、空目录） | `.../sync/file/engine.ts:301-336, 471-521, 990-1200` |
| 开书/翻页/聚焦的拉推 | `apps/readest-app/src/app/reader/hooks/useFileSync.ts:426-591` |
| 应用进度只认 location | 同上 `:506-523`；`.../components/FoliateViewer.tsx:864-868` |
| xpointer 真正被解析处 | `.../reader/hooks/useProgressSync.ts:335-368`（Cloud）、`useKOSync.ts:174-218`（koSync） |
| 付费与自建解锁 | `src/utils/access.ts:69, 167-184`；`docker/README.md:56-61` |
| 官方 KOReader 插件（走 Cloud，不碰 WebDAV） | `apps/readest.koplugin/`（全目录无 `webdav`） |
| 第三方设备先例 | `apps/readest-crosspoint-plugin/README.md`（koSync 协议 + partial md5 匹配） |
