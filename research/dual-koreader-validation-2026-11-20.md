# 双 KOReader 实机同步验证（2026-11-20）

## 环境

| 实例 | 分辨率 | 字号 | 行距 | 本机总页数 | 设备标识 |
|---|---:|---:|---:|---:|---|
| A | 454 × 721 | 20 | 95% | 5,663 | `Test-A-454x721` |
| B | 800 × 1024 | 32 | 140% | 16,803 | `Test-B-800x1024` |

- 书籍：《绍宋》EPUB；两份副本 SHA-256 均为 `553f53a2c5642d6d3f6df9a56015edb4bd218ef7a91f880b324e6100a22aaba7`。
- 测试目录：`D:\webdav\inkbridgeplus`。
- 两个 KOReader 配置、设备 ID、书籍文件均隔离；全程使用分页模式。

## 双向结果

| 方向 | 上传位置 | 接收端实际落点 | 正文核对 |
|---|---|---|---|
| A → B | A 第 2,095 / 5,663 页，36.99%；`/body/DocFragment[243]/body/p[105]/text().24` | B 第 6,120 / 16,803 页，远端正文行位于本页第 8 行 | 首行锚点“素相交，刚才见他失态，略有揣测，还请官家”出现在屏幕，xpointer 和锚点均与上传记录一致 |
| B → A | B 第 11,426 / 16,803 页，68.00%；`/body/DocFragment[377]/body/p[32]/text().89` | A 第 3,862 / 5,663 页，远端正文行位于本页第 15 行 | 首行锚点“话都说不利索，却依然还能从形式角度被接纳”出现在屏幕，xpointer 和锚点均与上传记录一致 |

两端的手动下载均显示确认框后执行跳转。接收端页码与发送端页码不同，但定位命中同一正文段落；页首提前于锚点是分页模式的页级定位结果。确认框截图与跳转后的正文截图：

- A → B：[确认框](evidence/dual-koreader-2026-11-20/confirm-B-corrected.png)，[正文落点](evidence/dual-koreader-2026-11-20/result-A-to-B.png)
- B → A：[确认框](evidence/dual-koreader-2026-11-20/confirm-A-corrected.png)，[正文落点](evidence/dual-koreader-2026-11-20/result-B-to-A.png)

取消两端确认框后，当前页、文档位置与 xpointer 均保持不变；前后快照见 [cancel-audit.json](evidence/dual-koreader-2026-11-20/cancel-audit.json)。

## 行号提示修正

本次实测暴露了原行号估算的偏差：用页首到锚点的纵向距离除以字号推算行高，会把段落间距也折算成正文行。原先 A → B 报第 11 行、B → A 报第 19 行；按 KOReader 实际渲染行框去重计数后，实测分别为第 8 行与第 15 行，与落点截图逐行核对一致。

`inkbridge_webdav.lua` 现优先查询目标页实际行框。只有当前页不同于目标页时才临时切页，并在保护调用后恢复原页；行框接口失败时不猜行号，也不影响定位方案。回归测试覆盖行框去重、同页查询、异常及空结果、切页后恢复，以及接口失败时不产生估算行号。

修正后的确认框截图：[A → B，第 8 行](evidence/dual-koreader-2026-11-20/confirm-B-corrected.png)；[B → A，第 15 行](evidence/dual-koreader-2026-11-20/confirm-A-corrected.png)。

## 云端与测试

测试前已对云端 15 个 `.po` 与墨桥记录保存基线。测试后逐个比较 SHA-256：原有文件 **15/15 未变、0 删除**，只新增本次 A、B 两条《绍宋》测试记录；记录保留在测试目录中。完整审计见 [cloud-audit.json](evidence/dual-koreader-2026-11-20/cloud-audit.json)。

完整回归测试：**1,349 条通过，0 失败**；其中 `webdav_spec.lua` 289 条。两个隔离实例也加载了修改后的行号实现，并分别实测确认框及取消流程。
