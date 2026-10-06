# InkBridge / 墨桥 Alpha 0.2.14

在不同平台的 KOReader 设备之间，通过 KOReader 已有的 WebDAV 云存储服务手动同步当前阅读位置。

## Alpha 范围

- 仅面向当前打开的 EPUB/可重排文档；
- 使用 KOReader `partialMD5` 作为书籍身份；
- 保存 `xpointer`、百分比、页码和更新时间；
- 上传与下载都直接调用 KOReader 自带的 WebDAV provider，插件不自行实现 HTTP/WebDAV 协议；
- 远端进度较新时保护远端状态，下载操作仍需用户确认跳转；
- 下载操作使用只读 WebDAV 请求，不会把本地进度反向上传；
- 上传记录使用可读书名和短哈希命名，并保留历史记录；下载时可从最近三条记录中选择；
- 历史记录文件扩展名为 `.txt` 以兼容 KOReader 默认 WebDAV 文件列表，文件内容仍为 JSON；
- 可在“设置设备名称”中自定义设备名，设备名会写入阅读记录和历史文件名；
- 文件名示例：`死人经-0615日30分45秒-汉王C7T8147.d31f852b.InkBridge.txt`；
- 文件名中的设备编号取插件设备 ID 的末尾四位，避免把内部时间戳显示出来；
- 文件名时间精确到秒。同一设备在同一秒内对同一本书重复上传仍会得到同名文件（见“当前限制”）；
- xpointer 无法在本机文档解析时，回退为按百分比换算页码；两者都无法应用时给出可见提示；
- 未联网时先询问是否开启 Wi-Fi，连上后再继续，不会出现“点了没反应”；
- 兼容未提供 `Cloud:uploadFile` 辅助方法的 KOReader 版本，回退到 KOReader 自带 WebDAV provider 上传接口。

## 账号信息说明

插件会把你在“设置 WebDAV 目标”里选中的那份服务器配置（**包含用户名和密码**）保存在
KOReader 的 `settings.reader.lua` 中，键名 `inkbridge_webdav_server`，供后续同步直接使用。

- 这与 KOReader 自身的云存储配置（`cloudstorage.lua` 里的 `cs_servers`）行为一致，都是本地明文保存；
- 插件**不会**把这些信息上传到任何第三方，也不会发送到 KOReader 官方服务器；
- 卸载插件或删除插件设置时，这三个设置项会被一并清理；
- 如果设备会与他人共用，请注意 `settings.reader.lua` 的可读性。

## 当前限制

- 需要先在 KOReader 的云存储界面配置好 WebDAV；
- 选择目标目录时必须**长按**「Long-press here to choose current folder」那一项（KOReader 的标准交互），点一下不会选中；
- 目前是手动上传/下载，不做后台自动同步；
- 不同步书籍文件、批注、笔记或高亮；
- 同一设备在同一秒内对同一本书重复上传会得到同名文件，后一次覆盖前一次；
- 尚未完成 Kindle、Android、汉王真机矩阵测试；
- 这是实验性 Alpha，不代表稳定版本。

## 安装

将 `inkbridge.koplugin` 目录放到 KOReader 的 `plugins/` 目录下，然后重启 KOReader。在工具菜单中打开“墨桥 InkBridge”。

## 开发

改动源码后请跑一遍回归测试，见仓库根目录 `DEVELOPMENT.md` 的「如何验证」一节。
