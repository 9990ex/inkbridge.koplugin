# 墨桥 InkBridge — 工作区说明

KOReader 插件 InkBridge(墨桥)的开发工作区。功能:通过 KOReader 自带的 WebDAV 云存储,
在不同设备之间手动同步当前阅读位置。

## 目录结构

| 路径 | 说明 |
|---|---|
| `inkbridge.koplugin/` | **插件本体(唯一开发目录)**。改代码只改这里。 |
| `koreader-master/` | KOReader 上游源码快照,用于核对 API 契约。与 GitHub master 逐文件校验一致。 |
| `reference/koreader-base/` | koreader-base 的 C/C++ 源码(`cre.cpp`、`xtext.cpp`)。xpointer 的真实语义在这里。 |
| `reference/syncery-1.2.4.1.2/` | Syncery 插件源码。KOReader 云存储/WebDAV 接口的现成参考实现。 |
| `releases/` | 历史版本 zip(v0.1.0 → v0.2.13),仅作档案,已被 git 忽略。 |
| `InkBridge-Alpha.code-workspace` | VS Code 工作区配置。 |

`reference/`、`koreader-master/`、`releases/` 都不属于工程本体,已在 `.gitignore` 中排除。

## 版本控制

```bash
git log --oneline          # 查看改动历史
git diff HEAD -- inkbridge.koplugin   # 查看当前未提交的改动
git diff v0.2.13-alpha -- inkbridge.koplugin   # 与基线对比
```

基线标签:`v0.2.13-alpha`(即从 GPT 工作目录迁移过来的原始状态)。

> 历史教训:迁移之前没有 git,只能用「复制目录 + 打 zip」记版本,导致同名内容的多份副本并存
> (例如 `work/inkbridge.koplugin` 与 `inkbridge.koplugin-v0.2.13-alpha/inkbridge.koplugin`
> 内容完全相同)。以后一律用 git 记录,不再复制目录、不再手动打 zip。

## 安装到设备

把 `inkbridge.koplugin/` 整个目录放进 KOReader 的 `plugins/` 下,重启 KOReader,
在工具菜单打开「墨桥 InkBridge」。

首次使用需在菜单里点「设置 WebDAV 目标」——**必须长按**「Long-press here to choose current folder」
那一项才能选中目录(KOReader 的标准交互)。

## 已知待修问题(尚未处理)

1. `inkbridge_webdav.lua` 远端路径校验:`find(..., 1, true)` 使字符类失效,反斜杠/换行/NUL 未被拦截。
2. 上传成功后不删除本地暂存文件,设备上会无限累积。
3. `provider.base = server` 未做深拷贝,上游用的是 `util.tableDeepCopy(server)`。
4. 离线时无任何提示:未联网时请求被 `NetworkMgr` 延后,界面既无成功也无失败反馈。
5. 文件名精确到秒,同秒重复上传会同名覆盖。
6. 文档口径:`inkbridge_webdav_server` 会明文保存账号密码,README 里「不保存账号信息」的说法不成立。
