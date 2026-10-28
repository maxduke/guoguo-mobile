# 红果播放与榜单优化（2026-10-28）

本轮在匿名播放设备修复之后，选择实现播放信息批量复用、榜单独立状态与后台刷新、安全失败原因保留。账号云同步按用户要求暂不实现。参考版本仍为 [hongguoTV c376666](https://github.com/tsukiyo-zero/hongguoTV/tree/c376666da49615871867e742861f98e108da39ba)。

## 本轮实现

### 播放信息批量复用

沿用已有“预缓冲下一集”的开关、网络、前后台和就绪条件。只有获准执行的红果后台准备会携带 `metadataAhead: 2` 提示；普通前台解析、其他站源和下载规划默认只请求当前集。这个可选字段不改变核心协议版本，旧核心可以忽略它。

Go 核心从同一作品已经验证且未过期的详情中找到相邻分集，批量读取当前集和最多后两集的播放模型。提示传递的是数量，不接受客户端另外指定任意视频 ID；缺少有效详情时退回单集请求，不为优化增加详情请求。

后续模型只在当前客户端内存中保留最多 60 秒、6 条，每条上限 256 KiB；只接受确切请求过的分集，确认当前集有效后才缓存后续的兼容模型。领取即删除，重试重新取得地址和密钥，过期、无效及超大模型不命中。缓存不是视频下载，不会同时准备多集媒体，也不进入备份或持久化目录。

请求契约、分集身份、CENC、画质和原有重试上限继续生效。批量失败时把剩余次数用于只读当前集，既不再次请求后续模型，也不轮换身份；注册失败、请求取消和限流不触发这一降级。对应入口为 `provider_hongguo_model_cache.go`、`provider_hongguo_native_media.go`、移动端 `resolve` 和 `PlaybackSessionController._load`。

### 榜单切换和刷新

榜单页分别保存最近四个栏目在本次页面会话内的结果、分页和请求状态。一个榜单正在读取时可以切换到另一个榜单；完成的非当前榜单仍写入既有缓存，返回时复用原请求或结果。新鲜状态在五分钟内切换不再发起 provider 调用，分页能力和已加载内容一起恢复。

过期结果立即显示，后台续期期间内容和其他榜单仍可操作。手动下拉刷新继续明确传递 `refresh: true`；刷新失败保留原内容与原获取时间，提供重试。追加较晚获取的分页不会把较早第一页的时间更新成新鲜时间。更换 store 或退出后，旧请求不能写回新页面的状态。

仍使用既有持久化缓存及 Go 的五分钟榜单缓存/请求合并，没有另建缓存系统。实际抽查现有总榜前两页均返回 20 条、合计 40 个不同作品，因此本轮没有依据修改全局 CookieJar；上游的 `ttwid` 问题保留为需要重现后再适配的候选。

### 播放失败原因

把核心已知的红果连接准备失败、空播放信息和不兼容媒体映射为固定用户提示。自动恢复期间同时显示安全原因与当前阶段；重试耗尽保留原因，成功、手动重试和切集会清理旧原因。原始错误、媒体地址、签名参数和设备 ID 不进入提示，自动恢复次数保持原有预算。

## 参考项目还有哪些值得吸收

上一轮记录围绕取流修复，以下能力也值得后续考虑，并非只有账号功能可增加：

| 候选 | 参考实现 | 本地差距与实施条件 |
| --- | --- | --- |
| 按分钟/集数定时停止 | [PlaybackComfort.SleepTimer](https://github.com/tsukiyo-zero/hongguoTV/blob/c376666da49615871867e742861f98e108da39ba/kotlin-tv/core/src/main/kotlin/com/hongguotv/core/PlaybackComfort.kt) | 本地已有自动下一集开关，尚无定时停止。可在更多播放设置增加会话级入口；分钟计时应独立于倍速，切集边界和投屏暂停需明确验证。 |
| TV 遥控器字母/数字键盘 | [TvSearchPanel](https://github.com/tsukiyo-zero/hongguoTV/blob/c376666da49615871867e742861f98e108da39ba/kotlin-tv/app/src/main/kotlin/com/hongguotv/nativeapp/TvSearchPanel.kt) | 本地已有输入法、联想与最近搜索，可补方向键操作的 A–Z/0–9、删除、清空及系统中文输入入口；拼音联想继续取决于服务端。优先解决旧电视输入法不便。 |
| 组合筛选找剧 | [DiscoveryFilters](https://github.com/tsukiyo-zero/hongguoTV/blob/c376666da49615871867e742861f98e108da39ba/kotlin-tv/core/src/main/kotlin/com/hongguotv/core/DiscoveryFilters.kt) | 本地请求已有主题/设定/背景/受众等字段，但目前为空并关闭 selector panel；可采用服务端下发选项、按类型重置条件及独立游标，需增加对应 UI 和实际接口契约验证。 |
| 电视通过手机输入关键词 | [PhoneSearchServer](https://github.com/tsukiyo-zero/hongguoTV/blob/c376666da49615871867e742861f98e108da39ba/kotlin-tv/core/src/main/kotlin/com/hongguotv/core/PhoneSearchServer.kt) | 与账号无关。需要有期限的扫码输入会话和局域网生命周期，退出搜索后停止服务，并区分权限或网络不可达。适合作为遥控搜索后续增量。 |
| 解码失败后记忆兼容档位 | [DecoderLessons](https://github.com/tsukiyo-zero/hongguoTV/blob/c376666da49615871867e742861f98e108da39ba/kotlin-tv/app/src/main/kotlin/com/hongguotv/nativeapp/DecoderLessons.kt) | 本地已有备用线路及较低画质回退，可增加只针对真实解码错误的设备经验。必须区分编码、实际宽高与方向，网络失败不能记成解码能力限制；需原生通道和设备样本。 |
| 音画偏移检测与恢复 | [PlaybackSyncGuard](https://github.com/tsukiyo-zero/hongguoTV/blob/c376666da49615871867e742861f98e108da39ba/kotlin-tv/app/src/main/kotlin/com/hongguotv/nativeapp/PlaybackSyncGuard.kt) | 参考项目依据 ExoPlayer 帧处理偏移建议重新同步。本地要先接入对应测量并验证阈值，避免把设备负载或一次定位当成应主动跳播的证据；不能直接照搬到 iOS。 |
| 本集评论与时间轴弹幕 | [AppCommentPages](https://github.com/tsukiyo-zero/hongguoTV/blob/c376666da49615871867e742861f98e108da39ba/kotlin-tv/core/src/main/kotlin/com/hongguotv/core/AppCommentPages.kt)、[TimedComments](https://github.com/tsukiyo-zero/hongguoTV/blob/c376666da49615871867e742861f98e108da39ba/kotlin-tv/core/src/main/kotlin/com/hongguotv/core/TimedComments.kt) | 属于可选产品能力，可先限定只读；需要分页、限量、播放时间轴及暂停/定位处理，并控制渲染开销。与修复取流分开验证。 |

建议下一批优先考虑定时停止和遥控器输入，再扩展组合筛选。解码学习及音画恢复应以目标电视的测量为依据。已有下一集在途任务复用、完整文件接管、分季续播、榜单失败保留和显示时间能力继续复用。

## 验证范围

- Flutter 全量 1001 项通过，零失败、零跳过；中文字体、真实 FFmpeg、既有性能场景均启用。`flutter analyze`、全项目 Dart 格式检查通过。
- `native/core` 的 `go test ./... -json -count=1`：630 个测试/子测试通过、零失败；8 项既有可选联网巡检未启用，合成 FFmpeg 集成回归实际执行。`go vet ./...` 和红果批量/缓存/身份相关竞态检查通过。
- 新回归覆盖缓存只消费一次、过期/条数/字节上限、精确分集、两种模型格式、CENC/画质/时长、取消及无效详情、批量失败在原次数内降为单集、注册失败不被当作批量重试，以及后台准备才传递提示。
- 榜单回归覆盖并行切换、返回后复用进行中分页、新鲜状态零调用、过期后台续期、手动强制刷新、失败保留原内容及时间、追加分页保留较早时间、更换 store 后拒绝迟到结果。既有切榜回归改为验证“迟到结果不覆盖当前榜单，但可供返回时复用”；恢复回归仍验证重试上限、暂停、进度、倍速和全部会话释放，并改为检查保留的安全原因。
- 最终代码经过真实移动 facade 抽查：同一作品第 2–4 集，首次请求携带 `metadataAhead: 2` 模拟已获准的后台准备，后两次普通解析命中缓存；只注册一次、总计一次模型请求，三集各通过 HTTP 206 / 1024 字节媒体读取，CENC 信息完整。验证在 60 秒缓存期限内完成，不能推出真实长时间连播每三集固定一次请求或设备首帧提升。

上述本地验证不包含双平台安装包构建，交付时以本批 PR 及 `v0.20.5` 发布标签的工作流为准。设备首帧、连播、PiP、投屏和原生解码行为仍按设备清单验收。原始本地日志保存在 `/tmp/guoguo-hongguo-opt-20261028-*`，包括 Flutter/Go JSONL、竞态检查和真实缓存探针输出；真实探针只记录计数、状态与数据长度。
