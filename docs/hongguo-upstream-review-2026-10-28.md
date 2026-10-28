# 红果匿名播放设备修复与优化评估（2026-10-28）

参考仓库固定为 [tsukiyo-zero/hongguoTV c376666](https://github.com/tsukiyo-zero/hongguoTV/tree/c376666da49615871867e742861f98e108da39ba)，重点对照 [匿名设备注册修复 3889318](https://github.com/tsukiyo-zero/hongguoTV/commit/388931852ddc614db8b00775a3dc54c5ede6307f)、[播放准备优化 e606c8d](https://github.com/tsukiyo-zero/hongguoTV/commit/e606c8d7c236369dcfe222c5eae17b0f0cf5bfa4) 和 [榜单会话修复 6b18d8c](https://github.com/tsukiyo-zero/hongguoTV/commit/6b18d8c617b5ef90a47700b80bedd083cd846441)。此前采用的接口和签名适配见 [10 月 24 日记录](hongguo-upstream-review-2026-10-24.md)。

## 故障与修复

本地原有播放设备 ID 和安装 ID 是随机数字，没有经过服务端注册。修复前真实推荐返回 18 条，作品 `7592524831132765209` 的 12 集详情正常，但第一集播放信息为空；故障发生在下载和解码之前。

新逻辑在第一次取流前完成匿名设备注册，再把返回的 `device_id`、`install_id` 用于现有 `multi_video_model/v1/` 接口。注册请求使用 `ttEncrypt(gzip(JSON))` 原始二进制、对应校验头和无签名策略；注册资料与本地现有 App 版本、设备型号及 OS 参数一致。无需登录账号。

- 播放和下一集预取共用同一移动客户端的成功身份；并发首次请求只发起一次注册，后续切集或模型重试不轮换身份。
- 等待注册的调用可各自取消；注册拥有者取消或失败时不缓存身份，后续有效调用可以重新注册。
- 身份只留在内存，不写入剧库、历史或备份。注册与播放不读取账号/站点 CookieJar，只发送注册返回的 `install_id`、`ttreq`、`store-region`、`store-region-src`；不跟随重定向转发二进制资料或设备 Cookie。
- 缺失、零值、非十进制、超长设备 ID、无效 JSON、额外 JSON 及超过 64 KiB 的注册响应均报错，不使用随机身份继续取流。整数响应以 `json.Number` 解析，避免大 ID 精度损失。
- 偶发 HTTP 200 空白播放信息使用原有请求重试预算；默认移动客户端最多两次，沿用可取消的退避和同一注册身份。业务错误、模型格式异常与不兼容编码保持明确失败。

仍然严格按所请求的分集 ID 选择响应，不采用上游单集请求缺失目标时取第一条记录的回退。现有编码过滤、清晰度和 CENC 处理继续生效。

## 值得参考的改进

| 优先级 | 上游做法与本地现状 | 决定 |
| --- | --- | --- |
| 已采用 | 注册播放设备并在多次播放间复用 | 修复本轮可复现的取流失败；保留现有客户端及网络调度，不新增账号系统。 |
| 已采用 | 空播放信息有限重试 | 纳入既有总次数，避免叠加新的内部重试层；每次更新时间戳，不改变设备身份。 |
| 优先评估 | `ContentRepository.streamLadder` 一次请求当前集及后两集，后续模型保留 60 秒、领取即删除、最多 6 条 | 本地 `resolveHongguoAppMedia` 每次只取一集，已有整集预缓冲。可先比较模型请求次数和预缓冲完成时间，再决定增加小批量元数据缓存；不能据此直接承诺切集变快。 |
| 条件评估 | 官网榜单重定向下发 `ttwid`，上游增加内存 CookieJar | 本地共享 Go HTTP 客户端没有 CookieJar，但已经有五分钟榜单缓存、强制刷新和失败回退。先复现当前榜单的跳转和 Cookie 要求，再考虑仅限红果官网的内存会话；本轮未证明本地榜单存在相同故障。 |
| 继续复用 | 下一集在途任务接管与已准备结果复用 | 本地 `EpisodeBuffer.get`、`PlaybackSession` 已实现，前台接管解除后台期限并复用 Future。直接保留，避免重复下载和新增并行媒体负载。 |
| 后续产品能力 | 账号收藏、云端观看历史与跨端续播 | 需要独立的登录、账号隔离和本机/云端冲突规则。当前本机历史与同系列能力继续使用，账号能力单独设计和验收。 |

上游同一 ExoPlayer 队列换集、Android TV 解码器学习及音画重同步依赖其原生播放器结构。本地 Flutter/iOS/Android、PiP 和投屏的生命周期不同，需先有目标设备的首帧、切集、音画和负载数据，再决定平台适配范围。

主要本地入口：`native/core/internal/app/provider_hongguo_device.go`、`provider_hongguo_app.go`、`provider_hongguo_native_media.go`；预取复用见 `lib/platform/episode_buffer.dart` 和 `playback_session.dart`，榜单缓存见 `native/core/internal/app/provider_rankings.go` 及 `lib/data/discovery_cache.dart`。算法来源和许可见 [UPSTREAM.md](../native/core/UPSTREAM.md#october-28-hongguo-anonymous-playback-device-repair)。

## 真实抽查

同一作品第一集使用原随机身份连续两次返回 HTTP 200 / 0 字节；注册一次后同一集连续两次返回 19,472 / 19,664 字节的有效播放模型，均选到 1080p 和 CENC 密钥。

随后固定同一分集、同一 CDID、UA 和请求体，双方都不发送 Cookie，交替比较随机/注册设备 ID 两轮：随机身份第一轮为空、第二轮成功，注册身份两轮均成功。该结果支持采用注册身份，并说明无 Cookie 也可以返回模型；它没有证明注册是每一次请求成功的必要条件，也不能把其他时间或设备的所有播放故障归因于未注册设备。第二组实验原本要求随机身份每次失败，因此在第二轮断言失败；这里保留该反例，不把它当作应用回归失败或隐去后重试。

| 入口 | 推荐 | 详情 | 媒体 |
| --- | --- | --- | --- |
| 真人剧 | 18 条，无警告 | 48 集 | HTTP 206 / 1024 字节；完整 CENC 解密、MP4 整理及整集解码通过 |
| 漫剧 | 18 条，无警告 | 76 集 | HTTP 206 / 1024 字节，加密媒体 |
| AI 剧 | 16 条，无警告 | 20 集 | HTTP 206 / 1024 字节，加密媒体 |

主机使用 Go 1.26.6 和既有 FFmpeg 5.1.9 环境。这些结果不能代替 iPhone/iPad、Android 手机/电视的实际起播画面、长时间连播、PiP、投屏和网络切换验收，具体场景见 [iOS 设备清单](ios-device-checklist.md) 与 [Android/TV 说明](android-tv.md)。

## 本地验证

- `native/core` 的 `go test ./... -json -count=1`：613 个测试/子测试通过，零失败；8 项既有的显式启用型真实网络检查未开启。合成 CENC、断流恢复和源密钥 FFmpeg 回归实际执行，没有因缺少 FFmpeg 而跳过。
- `go vet ./...` 通过；红果、黄豆和请求准备资源释放的 `go test -race` 通过。之后追加的注册/播放重定向阻断、业务/格式错误不重试用例也单独通过竞态检查，生产代码没有再次改动。
- 新回归覆盖注册二进制结构和校验、注册/播放身份一致、大整数 ID、成功身份复用、并发合并、等待者与拥有者取消、取消后重试、注册失败恢复、Cookie 白名单与账号 Jar 隔离，以及空响应的既有次数限制。原有目标分集、模型格式、兼容编码、画质、密钥和目录持久化隔离回归继续保留。
- 首次全量测试受沙箱禁止本地监听影响，在既有 `httptest` 处中断；在允许本地监听的环境重新执行同一套检查后通过，没有修改断言或排除失败测试。

复查命令（需可用的 Go 与 PATH 中的 FFmpeg）：

```sh
cd native/core
go test ./...
go vet ./...
go test -race ./internal/app -run 'TestHongguo|TestCatalogPreparationFailure|TestHuangdou' -count=1
go run ./cmd/probe -source hongguo -genre short_play -decode
go run ./cmd/probe -source hongguo -genre comic_series -media
go run ./cmd/probe -source hongguo -genre ai_series -media
```
