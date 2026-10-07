# 墨桥 InkBridge

面向 KOReader 的跨平台阅读进度同步项目。

InkBridge（墨桥）希望把不同平台上的 KOReader 设备连接起来，让阅读位置可以在 Kindle、Android、汉王等设备之间可靠地往返同步。

## 第一阶段目标

- 在不同平台的 KOReader 设备之间同步当前阅读位置；
- 以 WebDAV 作为首要云端传输方式；
- 使用图书内容哈希识别同一本书，减少路径差异带来的问题；
- 尽量保留 KOReader 的精确位置（xpointer），并提供百分比回退；
- 支持手动同步与跳转确认；
- 冲突时保护本地阅读进度，不静默覆盖用户数据。

## 后续方向

- Moon+ Reader（静读天下）阅读进度互通；
- Legado 等其他 Android 阅读器适配；
- 不同阅读器位置格式之间的转换；
- 更适合手机和平板的 KOReader 工作流。

## 暂不计划

- 书籍文件同步；
- 批注、笔记和高亮同步；
- 阅读统计与社交功能；
- 不必要的后台服务和复杂功能。

## 当前状态

**已有可用的 0.3.0**，可在 [Releases](../../releases) 下载安装包。
0.3.0 是正式版基线；之后的小改动继续走 **`0.3.x-alpha`**（0.3.1-alpha、0.3.2-alpha…），
不跳大版本号。
上传、下载、跨设备跳转的完整流程已在 Android 与 Kindle 设备上实测通过，
与静读天下（Moon+ Reader）的双向互通也已真机验证。

这是 0.x 版本：核心功能已真机验证，但仍在打磨，不代表稳定版本。使用前请先读插件自己的说明
[`inkbridge.koplugin/README.md`](inkbridge.koplugin/README.md)。

### 安装

1. 到 [Releases](../../releases) 下载最新的 `inkbridge.moon.koplugin-v*-alpha.zip`；
2. 解压得到 `inkbridge.koplugin/` 目录（**不要**只解压里面的文件）；
3. 放进 KOReader 的 `plugins/` 目录：
   - Kobo：`.adds/koreader/plugins/`
   - Kindle：`koreader/plugins/`
   - Android：`/sdcard/koreader/plugins/`
4. 完整重启 KOReader，在工具菜单打开「墨桥 InkBridge」。

首次使用先配云同步：**高级选项 → 存储选项 → 墨桥同步目录**
（只配了一台服务器时会直接进目录浏览），并在里面**长按**「Long-press here to choose current folder」
那一项来选定云端目录（KOReader 的标准交互）。

> 包内目录名**永远**是 `inkbridge.koplugin/`，只有压缩包的**文件名**带 `.moon.`
> —— KOReader 靠目录名认插件，改名会让老用户升级时多出一个旧插件。

### 参与开发

见 [`DEVELOPMENT.md`](DEVELOPMENT.md)：如何跑回归测试（689 条断言，不需要设备）、
进度记录的定位原理，以及已知问题清单。

## 设计原则

- 小而专注；
- 数据由用户自己掌控；
- WebDAV 优先；
- 失败不覆盖本地进度；
- 兼容性和可恢复性优先；
- 不把实验性功能包装成稳定功能。

## 说明

InkBridge 是独立项目，与 Syncery 没有官方隶属关系。早期设计会参考现有开源项目的经验，
但不会把未完成的实验代码当作本项目的正式实现。

## 开发方式

**Powered by DeepSeek** —— 本项目的代码、回归测试与文档均在 DeepSeek 的辅助下完成。
所有改动都要跑过 689 条回归断言（不需要设备即可运行，见 [`DEVELOPMENT.md`](DEVELOPMENT.md)），
关键链路由真机验证。

> DeepSeek 在这里是开发工具。本项目与 DeepSeek 官方没有任何隶属关系。

## 名称

**InkBridge / 墨桥**：连接不同阅读设备，也连接不同阅读软件之间的阅读进度。

## 许可证

本项目以 [GNU General Public License v3.0](LICENSE) 授权。

> 说明：InkBridge 是 KOReader 的插件，运行时会 `require` KOReader 自身的模块；
> KOReader 本体以 AGPL-3.0 发布。
