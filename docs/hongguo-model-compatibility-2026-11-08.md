# 红果模型字段与同画质备用资源（2026-11-08）

在 v0.20.11 的签名与独立身份修复之后，按 [后续评估](hongguo-drama-review-2026-11-08.md)优先落实模型字段兼容和备用候选保留。固定参考 [hongguo-drama b2b81ce](https://github.com/jackotom/hongguo-drama/tree/b2b81cec61159ae788c723b21ad1015ac40296f6) 的 `src/native/app-source.js:parseAppPlayModel` 与 `app-source-inline-fallback.test.cjs`，不增加联网步骤或更改播放器状态机。

## 修复范围

- 编码、密钥和加密标记同时读取候选顶层与现有嵌套结构。顶层编码/密钥优先；任一编码字段或 gear 明确标记 ByteVC2/BVC2 时跳过，兼容编码保留 AVC/H.264 和 HEVC/H.265/ByteVC1 的现有别名。未知编码不再误当作兼容格式。
- `spade_a` 存在时必须经过现有内容密钥算法校验。没有密钥时，仅明确未加密的 `false`、数字 `0`、字符串 `"0"` / `"false"` 可直接播放。加密、未知或冲突的标记及缺失加密资料都不会被当作普通 MP4；不完整候选不会覆盖另一个已验证的可用档位。
- 画质优先使用候选实际宽高的短边，依次读取顶层和嵌套的 `vwidth/vheight`、`width/height`。真实 720×1280 不会因为标签写着 1080p 而被当作 1080p；旧式只有画质标签的模型仍保留标签解析。
- 保留 `main_url`、`backup_url`、`backup_url_list` 的有效 HTTP(S) 地址，沿用现有地址与凭据检查，按地址和内容密钥去重。每个画质、每类兼容编码最多保留四条，防止同一类型的大量备选挤掉另一兼容类型，也不会以全局截断丢失已有低画质档位。
- 顺序保持最高画质优先；同一画质优先 AVC，然后 HEVC，主地址先于其备用地址。同画质备选通过现有 `mobilePlaybackChoices` 交给回退入口，备用候选各自保留密钥、Referer 和时长；手动指定画质仍只选择该档位。

主要实现是 `provider_hongguo_media_variants.go` 和 `provider_hongguo_native_media.go`。这些规则也用于后续分集模型缓存，缓存命中、到期、取消与注册预算沿用 v0.20.11 的契约。

## 回归与主机验证

新增回归先在旧实现下复现了顶层密钥被忽略、顶层 ByteVC2 穿过过滤、画质丢失、备用地址丢失和同画质编码被覆盖，再验证修复结果。覆盖顶层/嵌套字段、横竖屏实际尺寸、数字和字符串未加密标记、缺失或无效密钥、冲突标记、编码别名、有效备用地址去重、固定画质与自动画质候选、候选数量限制，以及高画质资料无效时保留低画质的有效媒体。

既有合成未加密夹具补上明确的编码和未加密标记；通用清晰度回归也改为确认两个同画质编码都被保留，同时清晰度选项继续按高度去重。

真实主机探针检索《浴火之路》（`7631046819190934553`），取得 58 集详情，媒体首段 HTTP 206 / 1024 字节、完整 CENC 解密、MP4 准备和 FFmpeg 全集解码通过。日志 `/tmp/guoguo-hongguo-variants-live.log`；这证明当前真实模型通过新解析规则，不能替代 iPhone 上的实际起播、主地址故障后的回退、切集、PiP 和长时间连播验收。

最终本地 `go test ./... -json -count=1` 共 764 个测试／子测试通过，零失败；8 项既有可选联网巡检未启用。FFmpeg/CENC 回归实际执行。模型、固定画质和缓存相关竞态检查、`go vet ./...`、Go 格式和差异检查通过。日志为 `/tmp/guoguo-hongguo-variants-go-verified-final.jsonl`、`/tmp/guoguo-hongguo-variants-race.log`、`/tmp/guoguo-hongguo-variants-race-final.log` 和 `/tmp/guoguo-hongguo-variants-vet-final.log`。交付仍须通过当前 PR、合并提交和发布标签的必需检查。

## 后续范围

下一步可复用本轮字段/密钥/尺寸规则，实现受约束的 `fallback_api` 模型恢复；再将结构化拒绝类型用于批量取源停止和失败阶段诊断。桌面 ByteVC2 软件转换需单独评估移动端包体、性能和运行时能力。
