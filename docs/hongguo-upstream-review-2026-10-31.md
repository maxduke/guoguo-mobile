# 红果播放恢复修复与参考项目评估（2026-10-31）

用户反馈 iPhone 上任意红果剧集无法播放。本轮参考固定为 [hongguoTV b6e018d](https://github.com/tsukiyo-zero/hongguoTV/tree/b6e018ddb941b798e0672d23186c91cc556f1ab7)，与上次参考的 `c376666` 相差 10 个提交，重点核对 [空响应重试计划](https://github.com/tsukiyo-zero/hongguoTV/blob/b6e018ddb941b798e0672d23186c91cc556f1ab7/kotlin-tv/core/src/main/kotlin/com/hongguotv/core/PlayRetry.kt)、[取流和编码档位](https://github.com/tsukiyo-zero/hongguoTV/blob/b6e018ddb941b798e0672d23186c91cc556f1ab7/kotlin-tv/core/src/main/kotlin/com/hongguotv/core/ContentRepository.kt)及 [issue #38](https://github.com/tsukiyo-zero/hongguoTV/issues/38)。

## 本轮修复

原实现对空响应、连接或读取失败的重试仍使用同一接口域名及共享连接池。在服务端连续返回 HTTP 200 空内容时，这些尝试可能再次落入相同失败路径。

- 播放重试依次使用固定的 `sinfonlineb → hl → lf` 官方接口，刷新请求时间，保留同一注册设备、CDID 和允许的设备 Cookie。
- 每次重试建立独立的标准 HTTP transport，禁止连接复用，并重新建立 HTTP/2 协议处理，避免克隆后仍引用旧 HTTP/2 连接池。保留 HTTP/2、TLS 校验、DNS、代理和取消策略；清理只作用于重试自身的连接。
- 移动端红果播放采用专用四次预算，路径为 `b → hl → lf → b`，重试前等待 700/1500/3000 毫秒，累计 5.2 秒退避。第四次回到主接口时也使用新连接。
- 可选的多集模型请求失败后，单集降级使用剩余三次预算并继续尝试序号；不会在降级时重新开始计数或叠加一组重试。
- 播放请求改为上游的 `device_level: 1`，优先请求兼容档位；解析同时识别 `bytevc2` 与 `bvc2`，排除不支持的编码及对应 gear 标记，仍从其他可用档位选择媒体。

通用请求仍使用原有次数，移动客户端为两次；四次策略只配置给红果播放，不进入 JSON 设置或持久化数据。整个移动调用仍受原有总期限和取消控制。业务/格式错误、4xx、限流和设备注册失败沿用原处理；目录、推荐、搜索和评论继续使用已有签名策略。下一集模型缓存、按目标分集取值、CENC 密钥和清晰度选择继续保留。

上游还采用最长五分钟的界面分阶段恢复。本轮采用有界的请求重试；长时间自动恢复需要独立明确 iOS 前后台、PiP、投屏、取消及界面等待语义，再决定是否采用。

主要实现：`native/core/internal/app/provider_hongguo_app.go`、`provider_hongguo_playback_retry.go`、`provider_hongguo_native_media.go`。来源和许可记录见 [UPSTREAM.md](../native/core/UPSTREAM.md#october-31-hongguo-playback-route-recovery)。

## 实际验证与限制

修复前一次推荐、54 集详情和加密媒体首段读取成功；本轮在两次和四次预算下都观察到过连续空播放响应，不能保证路径切换消除服务端异常窗口。漫剧曾返回完整 76 集详情但取流失败；随后同一作品和第一集对照以及带诊断的完整移动调用均取得有效媒体。失败日志继续保留，不以再次成功抹去失败。

固定作品 `7519755359314005017`、第一集 `7520499514625510425` 和同一已注册身份，对三个官方接口分别测试 `device_level` 3 与 1，六次均返回 1080/720/540/480/360 的兼容档位及 CENC 密钥。这证明当时三条线路可用；此作品没有体现档位数量差异，不据此宣称设备档位调整对所有剧集都增加了清晰度。

另一次明确注入主接口连接失败后，实际请求序列为 `b → hl`，备用接口返回有效 1080p 媒体。注入的连接失败是受控条件；空响应、5xx、读失败和耗尽预算由离线回归验证。HTTP/2 本地服务验证重试使用新连接，前后正常请求仍复用原连接，原池未被清理。

对曾失败的漫剧 `7566112865115966489`、第一集 `7566295653672815640`，另做了两组同身份对照，分别先请求档位 3、先请求档位 1；三条线路均返回相同五个兼容档位。带诊断的完整移动调用确认所请求的分集、JSON 参数、HTTP/2 和响应长度有效，没有发现固定的参数顺序或作品供给差异。

整集抽查从 18 条真人剧推荐进入 75 集详情，首段 HTTP 206 / 1024 字节、CENC 解密、MP4 整理及整集解码通过。AI 剧返回 16 条推荐、95 集详情和 HTTP 206 / 1024 字节的加密媒体。日志使用 `/tmp/guoguo-hongguo-20261031-*` 前缀，不输出媒体地址、设备身份或密钥。

最终不带诊断的漫剧移动调用返回 18 条推荐、76 集详情和 HTTP 206 / 1024 字节的加密媒体。先前失败记录为 `comic.log`、`comic-budget.log`，最终结果为 `comic-final.log`；这些文件均使用上述日志前缀。

本地验证：Go 全量 `go test ./... -json -count=1` 共 653 个测试/子测试通过、零失败，8 项既有可选联网巡检未启用；FFmpeg/CENC 用例实际执行。`go vet ./...`、注册身份/移动四次预算/HTTP2 重试/批量降级/取消的 `go test -race` 和差异检查通过。最终测试日志分别为 `budget-go-final.jsonl`、`budget-race-final.log`。

主机取流和解码验证不能代替 iPhone 实际起播、后台/PiP、连续切集与长时间播放。本轮没有设备安装或验收结果，也没有量化起播速度或故障率改善。

## 适合后续吸收的能力

| 优先级 | 能力及参考 | 本地现状与建议 |
| --- | --- | --- |
| 优先 | 按分钟或集数定时停止：[PlaybackComfort](https://github.com/tsukiyo-zero/hongguoTV/blob/b6e018ddb941b798e0672d23186c91cc556f1ab7/kotlin-tv/core/src/main/kotlin/com/hongguotv/core/PlaybackComfort.kt) | 手机和电视均适用。本地有自动下一集开关，可增加会话级定时停止；明确计时、切集边界、暂停与投屏行为。 |
| 优先 | 按主题、年代、受众、上新和状态组合筛选：[DiscoveryFilters](https://github.com/tsukiyo-zero/hongguoTV/blob/b6e018ddb941b798e0672d23186c91cc556f1ab7/kotlin-tv/core/src/main/kotlin/com/hongguotv/core/DiscoveryFilters.kt) | 本地推荐/目录关闭 selector panel，各筛选项为空。可先接服务端选项，再复用现有分页、取消和缓存；需要实测筛选契约及重置游标。 |
| 条件采用 | 按设备能力选择编码/尺寸并记住确定的解码失败：[StreamLadder](https://github.com/tsukiyo-zero/hongguoTV/blob/b6e018ddb941b798e0672d23186c91cc556f1ab7/kotlin-tv/core/src/main/kotlin/com/hongguotv/core/ContentRepository.kt) | 本地已有清晰度、备用资源恢复和完整视频兼容准备；可补充设备解码能力与失败经验。需要 iPhone/目标电视的实际解码错误证据，不把网络或空响应记成解码能力不足。 |
| TV 后续 | 遥控器字母/数字搜索键盘：[TvSearchPanel](https://github.com/tsukiyo-zero/hongguoTV/blob/b6e018ddb941b798e0672d23186c91cc556f1ab7/kotlin-tv/app/src/main/kotlin/com/hongguotv/nativeapp/TvSearchPanel.kt) | 本地已有最近搜索和联想，输入主要依赖系统 TextField。可增加方向键面板，保留系统中文输入。 |
| 后续评估 | 推荐流试播、相邻作品预加载和观看全集交接：[HomeFeedScreen](https://github.com/tsukiyo-zero/hongguoTV/blob/b6e018ddb941b798e0672d23186c91cc556f1ab7/kotlin-tv/app/src/main/kotlin/com/hongguotv/nativeapp/HomeFeedScreen.kt) | 属于新的发现体验。需先确定移动端流量、音频焦点和隐藏页面生命周期；原生 ExoPlayer 的缓存及队列实现需要结合 Flutter/iOS 结构重新设计和测量。 |

已有的匿名设备注册、有限模型批量缓存、预取任务接管、榜单独立状态及后台刷新继续复用，见 [10 月 28 日实现记录](hongguo-optimizations-2026-10-28.md)。账号收藏和云端同步仍作为独立产品能力评估。
