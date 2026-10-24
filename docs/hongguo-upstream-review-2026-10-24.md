# 红果接口修复与上游重构评估（2026-10-24）

## 本次修复

参考 [chewu1590/hongguoTV 43b970b](https://github.com/chewu1590/hongguoTV/commit/43b970bf77f5c3ae3e06075a210b49a71c3d9e1a)，并对照 [tsukiyo-zero/hongguoTV e41a747](https://github.com/tsukiyo-zero/hongguoTV/tree/e41a74722cc339c3aa40936a325f184d176b1564)。修复前实际发现三个问题：

| 问题 | 实测与改动 |
| --- | --- |
| 播放接口空响应 | 原 `multi_video_model/preload/v1/` 即使去掉签名仍为空；改用 `multi_video_model/v1/`。播放使用无签名请求，独立生成 `device_id`、`iid`、`cdid`，同一客户端内稳定，重建后更新，不写入目录缓存。 |
| 推荐与详情空响应 | 原简化 Gorgon 签名及只替换 Gorgon 的探针均失败；上游完整签名对相同接口返回成功。适配 Gorgon、Helios、Medusa 与配套头，签名绑定当前查询、序列化请求体、设备 ID、版本及时间。支持的哈希分支通过有界调整请求时间票据选择。 |
| 综合搜索缺失 | 官网 `/search/<keyword>` 已改为客户端加载。采用上游 [2e9b7da](https://github.com/tsukiyo-zero/hongguoTV/commit/2e9b7daf5be227551a95adc4c77398935acf9a77) 的 `/api/search/result?query=...&page=1`，保留名称检索、补季、去重、排序和移动端续页。校验结果数组、页码及分页标志，验证页或异常响应继续报错。 |

本地主要入口是 `provider_hongguo_app.go`、`provider_hongguo_native_media.go`、`provider_hongguo_search.go`。签名算法集中在 `provider_hongguo_app_sign*.go`，不进入 Flutter 页面或媒体处理代码。带签名的 App 请求、无签名播放请求及既有评论签名各自选择策略，共用限流、超时、重试与响应校验。签名准备失败时不发送请求，并释放超时和限流名额；黄豆请求仅适配这一内部回调的返回类型。

播放继续只接受所请求分集的 `data[videoID].video_model`，兼容对象和 JSON 字符串，沿用编码过滤、清晰度选择和 CENC 密钥处理。没有采用上游“缺失目标分集时取第一条响应”的回退。

## 重构取舍

| 上游做法 | 我们当前实现与决定 |
| --- | --- |
| 按接口隔离请求策略 | 本次采用。真实接口对签名的要求相反，拆分调用入口可防止目录签名重新混入播放请求；网络调度仍复用同一套实现。 |
| [减少重复详情请求、保留公共连接池](https://github.com/tsukiyo-zero/hongguoTV/commit/635523cd808afe8c4d65af37cd100482af5c66b6) | 本地已有详情请求合并、5 分钟缓存、128 条容量，以及搜索缓存/请求合并；共享 Go 客户端保留连接，每个主机最多 8 条空闲连接。继续使用现有能力。 |
| 推荐数据直接提供试播首集 | 仅在服务端明确返回 `first_vid` 或 `vid_index=1` 时可靠。当前移动端没有该 TV 首页试播流程，保留完整详情验证，不把任意推荐片段 `vid` 当第一集。 |
| [首页多部预缓冲](https://github.com/tsukiyo-zero/hongguoTV/commit/723743de46f92642f467f6d84b6c50bf31db5f4c) | 本地已有下一集预缓冲，按缓冲就绪、网络、前后台/PiP 和任务代次调度，并处理取消与复用。暂不增加并行下载多部作品的资源开销。 |
| [复用 ExoPlayer 队列切集](https://github.com/tsukiyo-zero/hongguoTV/commit/b237e50d456ab35093b39c4661c561a740cc86b0) | 属于原生 Android TV 的播放器结构；当前 Flutter/iOS 媒体准备、PiP 和投屏生命周期不同。先保留既有单集预取与复用，后续依据设备切集耗时决定。 |
| 账号同步、评论及弹幕 | 属于新增产品能力。既有评论签名继续隔离，不把账号、云端记录及 TV 交互并入本次协议修复。 |

下一步值得跟踪的是设备上的真实起播和切集耗时、预缓冲流量/内存，以及 CDN 拒绝后的重试结果；本轮没有证据支持另建缓存系统或更换播放器。

## 验证

- `native/core` 的 `go test ./...` 通过，包含真实 FFmpeg 合成媒体回归。主机使用 Go 1.26.6、FFmpeg 5.1.9；CI 的工具版本继续由工作流管理。
- `go vet ./...` 及红果、补季、黄豆和请求准备失败路径的 `go test -race` 通过。
- 独立上游 Node oracle 的 12 组签名向量逐项比对哈希、Gorgon、Helios 和 Medusa；另外生成 2 组当前版本及不同设备 ID 的向量，合计 14 组通过，覆盖有/无请求体和四组时间相关变换表。
- 回归覆盖无签名播放、客户端身份生命周期、目录缓存恢复、重试、评论上下文隔离、分集身份、请求准备失败释放资源，以及 JSON 搜索格式、页码、特殊字符、业务错误和原有补季/并发/取消流程。
- 真实真人剧推荐返回 18 条，无警告，48 集详情和一集 HTTP 206 / 1024 字节读取成功。
- 漫剧推荐返回 18 条，76 集详情与媒体首段读取成功；AI 剧推荐返回 17 条，197 集详情与媒体首段读取成功，均无警告。
- 按“分手六年我的记忆说没分”搜索，返回 20 条合并结果，无警告；正确解析剧集 `7691530085832068121` 的 71 集，一集通过 HTTP 206、完整 CENC 解密、MP4 整理及整集解码。
- 另一条随机推荐样本曾遇到媒体 CDN HTTP 403；随后重新解析该样本，主/备地址均读取到 HTTP 206。它不再是播放 API 空响应，但本轮不能据此保证 CDN 持续可用。

这些结果是主机端样本。iPhone/iPad 的真实起播画面、长时间连播、PiP、投屏及设备负载仍按 [设备清单](ios-device-checklist.md) 验收。

安装 Go 和 FFmpeg 后，可在 `native/core` 下复查：

```sh
go test ./...
go vet ./...
go test -race ./internal/app -run 'TestHongguo|TestMobileSeason|TestCatalogPreparationFailure|TestHuangdou' -count=1
go run ./cmd/probe -source hongguo -genre short_play -media
go run ./cmd/probe -source hongguo -genre comic_series -media
go run ./cmd/probe -source hongguo -genre ai_series -media
go run ./cmd/probe -source hongguo -query '分手六年我的记忆说没分' -decode
```

算法来源、固定版本和许可见 [UPSTREAM.md](../native/core/UPSTREAM.md#october-24-hongguo-protocol-repair)。
