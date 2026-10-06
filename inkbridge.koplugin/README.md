# InkBridge / 墨桥 Alpha 0.2.13

这是 InkBridge 的第一个可安装实验版本：在不同平台的 KOReader 设备之间，通过 KOReader 已有的 WebDAV 云存储服务手动同步当前阅读位置。

## Alpha 范围

- 仅面向当前打开的 EPUB/可重排文档；
- 使用 KOReader `partialMD5` 作为书籍身份；
- 保存 `xpointer`、百分比、页码和更新时间；
- 使用 KOReader 的 WebDAV 配置和 Cloud Storage 直接上传，插件不保存或上传额外账号信息；
- 远端进度较新时保护远端状态，下载操作仍需用户确认跳转；
- 下载操作使用只读 WebDAV 请求，不会把本地进度反向上传；
- 上传记录使用可读书名和短哈希命名，并保留历史记录；下载时可从最近三条记录中选择；
- 历史记录文件扩展名为 `.txt` 以兼容 KOReader 默认 WebDAV 文件列表，文件内容仍为 JSON；
- 可在“设置设备名称”中自定义设备名，设备名会写入阅读记录和历史文件名；
- 文件名示例：`死人经-0615日30分45秒-汉王C7T+8147.d31f852b.InkBridge.txt`；
- 文件名中的设备编号取插件设备 ID 的末尾四位，避免把内部时间戳显示出来；
- 文件名时间包含秒数，用于避免短时间内重复上传产生同名文件；
- xpointer 无法在本机文档解析时不强行跳转。
- 兼容未提供 `Cloud:uploadFile` 辅助方法的 KOReader 版本，回退到 KOReader 自带 WebDAV provider 上传接口。

## 当前限制

- 需要先在 KOReader 的云存储界面配置 WebDAV；
- 目前是手动上传/下载，不做后台自动同步；
- 不同步书籍文件、批注、笔记或高亮；
- 尚未完成 Kindle、Android、汉王真机矩阵测试；
- 这是实验性 Alpha，不代表稳定版本。

## 安装

将 `inkbridge.koplugin` 目录放到 KOReader 的 `plugins/` 目录下，然后重启 KOReader。在工具菜单中打开“墨桥 InkBridge”。
