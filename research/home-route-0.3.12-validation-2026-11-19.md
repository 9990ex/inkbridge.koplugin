# 0.3.12-alpha：原配置启用首页及原生 Home 入口接入

## 原因核查与纠正

用户指出当前仍是 KOReader 原生首页。实际核查发现：

- `/home/nvidia/koreader-dev/plugins/inkbridge.koplugin/_meta.lua` 仍为 **0.3.10-alpha**，原配置无 `inkbridge_home_auto` 且 `start_with="last"`。之前验证的 0.3.11 是另一个隔离配置，不代表原配置已经升级启用。
- 此前结束验证时停在书库，用户看到的是原生文件管理器。书库本身按首版约定复用原生页面，但它左上角房子仍执行 `FileManager:onHome()` → `file_chooser:goHome()`，即回主目录，而不是墨桥页面。
- 开始排查时曾怀疑启动时序／QuickStart 覆写；源码核查没有证明该猜测。未把这个猜测作为修复依据，未修改 QuickStart 或 KOReader 源码。

## 修复边界

- 在 `Home.attach` 中只包裹当前 FileManager **实例**的 `onHome`，不修改共享类；启用墨桥首页时打开墨桥页面，关闭时透传原动作的参数和返回值。
- 重复 attach 不重复包裹。保留启动选项与显式首页开关的原有约定，不默认劫持其他用户的启动设置。
- 原配置插件和 settings/history 已备份后，部署 0.3.12，并通过 `Home.setAuto(true)` 开启用户要求的启动首页。未复制隔离配置中的预览历史，不动 `.sdr`、云端位置或正文映射算法。

## 实际验证

证据目录：`C:\Users\burn\AppData\Local\Temp\opencode\home-route-0312-20261119`。

1. 直接使用 **KO_HOME=/home/nvidia/koreader-dev**、无书籍或目录启动参数冷启动 KOReader v2026.07.1，首页显示日期时间、最近三本与首页／书库／设置底栏。`cold-start.png`。
2. 点击底栏「书库」，进入原生文件管理器。`library.png`。
3. 点击原生文件管理器左上角房子，回到墨桥首页，而非停留原生主目录。`home-button.png`。
4. 原配置缺少之前隔离测试的正文缓存，显示真实空状态；不伪造、混入或从隔离配置迁移预览样本。
5. 正常退出后再次冷启动，设置持久化仍生效，停留墨桥首页供用户查看。`cold-restart.png`。部署文件与源码一致，原阅读历史逐字节未变，测试前八份 `.po` SHA-256 均未变。

## 自动化与交付

- 新增 Home 入口启用／禁用、透传参数和返回值、防重复包裹等六条断言。
- 完整八份回归 **1270 条通过、0 失败**，其中首页 64 条。
- 原 0.3.10／0.3.11 安装包保留，新包 0.3.12-alpha 使用原打包器生成并逐文件 SHA-256、ZIP CRC、文件集合和 LF 校验。
- 本次不宣称所有品牌真机验证通过，不宣称不存在其他导航入口差异。
