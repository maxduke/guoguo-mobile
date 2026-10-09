> 历史记录：保留当时的设计、实现和验证范围，不代表当前行为。参见 [当前产品规格](../product-spec.md)。

# AirPlay 换集资源与失败恢复（0.15.1+34）

用户已确认：红果 CENC 视频投到安卓电视的蓝莓投屏，第一集能播，自动下一集报“视频播放中断”，手动下一集报“下一集准备失败”。旧提示丢掉了真实异常，不能据此认定是网络、红果解密或接收器不支持队列。

## 代码中可复现的缺陷

- Dart 收到任何新 `itemId` 就关闭上一集中转；native `currentItem` KVO 同时取消旧 asset。这仅代表本机队列提升，不能证明电视已停止读取旧 URL。原生已有 `retainedItemIds`，Dart 没有使用。
- `ready(item)` 忽略未成为 current 的排队项失败，`nextID` 和去重集合没有撤销失败项的转移。再次点击下一集可能推进失败项或空队列，无法重新提交相同分集。
- 原生拒绝 append 后 Dart 仍保留已提交的 relay，重试覆盖同一个索引而泄漏旧 relay；迟到响应也可能覆盖先到的原生拒绝事件。
- 独立投屏准备会话会借用手机临时完整文件，却没有给手机缓存加引用。网络变化按当前页裁剪手机缓存时可以删除电视正在读取的文件。
- 原生 item/player 错误和 Dart 的源准备、HTTP relay、native append 异常统一显示“网络失败”，既掩盖原因，也没有恢复失败 native player 的操作。

## 最终行为

仍采用独立 `AVQueuePlayer` 和 AVKit 界面。播放队列最多当前加下一集，另保留交接尚未确认的旧媒体；连续手动切集时，不能用中间集覆盖仍可被电视读取的最早旧集。在最新一集位置实际推进、播放状态为 playing，并且选中电视时外部视频确实 active 后，才取消旧 asset 并从 `retainedItemIds` 移除。没有固定睡眠或用猜测时长模拟完成。暂停/连接未完成时继续保留旧集；退出显式撤下全部媒体后释放。

Dart 按 native 保留集合释放中转，正在准备/提交及中转关闭中的文件仍保留。拒绝的 append 立即关闭自己的 relay；退出与已提交 append 串行，native close 确认之前不删除 receiver URL。投屏只使用永久下载文件或自身准备的文件，不再借用手机临时缓存。

排队项加载失败或原生提前移除它时，会从 AVQueuePlayer 移除、释放其 slot/去重 ID，并发出 `rejectedItemId` 和最新保留集合；不打断仍正常播放的当前集。进度事件不自动重试失败源，原生“下一集”可重试同一分集。先收到 reject、后收到 append 成功响应时也不会复活失败项。

当前项/播放器失败保留当前身份和进度，显示“重试本集”。重试先撤下旧队列/观察器，再创建新的 AVQueuePlayer，保留意图、当前和已准备下一集的 URL，手机隔离锁不释放。Apple 明确说明 failed 状态的 AVPlayer 不能继续使用，需要新实例：[AVPlayer.status](https://developer.apple.com/documentation/avfoundation/avplayer/status-swift.property)。失败提升 KVO 和迟到旧项回调不能把新集错误或播放意图覆盖。

错误显示 `source.prepare/*`、`relay.start/*`、`queue.append/airplay_*`、`item.load/*`、`item.end/*`、`queue.removed/*`、`player.status/*` 或 `route.video_timeout`。NSError 只保留白名单域别名、整数码及一层 underlying code，绝不输出 localizedDescription、userInfo、URL、请求头或内容密钥。失败到结尾通知的 NSError 取自 Apple 的 [FailedToPlayToEndTimeErrorKey](https://developer.apple.com/documentation/avfoundation/avplayeritem/failedtoplaytoendtimenotification)。

## 验证与边界

真实资源只读验证：从手机同款 `mobile.NewClient` 的红果目录取一个 57 集作品，前三集逐集解析、CENC 完整 remux、完整解码通过，输出约 7.55/4.63/5.68 MB。再通过实际 CastRelay 验证每集 HEAD、尾部 Range 206/Content-Range 和完整 HTTP 解码；读取后集时前集 URL 仍可读。此结果排除该样本的一般解析/解密/HTTP 故障，不能代表用户的未知具体作品或蓝莓接收器。

自动化覆盖：新集提升后仍保留旧 URL、原生确认后清理、慢关闭保留文件、加载中的下一集不被进度事件取消、拒绝 append 的释放与重试、排队失败后同 ID 重试、reject 先于 append 响应、close 等待 append、手机缓存裁剪不删除投屏独立文件。Swift 纯策略覆盖旧/新 KVO 顺序、连续手动切集的多次未确认交接、队列失败撤销、意图和错误脱敏；iOS 编译及 Swift 策略在 CI 执行。

本地完整 Flutter 回归通过（339 项通过、7 项按原环境条件跳过）；最终 AirPlay 会话/页面定向测试 30 项通过，新增实际 HTTP 生命周期测试和同一红果文件的独立红测用例均通过，iOS patch Python 检查 7 项通过。最终静态分析通过。此 Linux 环境没有 Swift 编译器，也没有用户电视；不能声明蓝莓真机换集已验证。需要同一作品连续三集、手动下一集、关闭自动连播、暂停、断网恢复、退出/重进与切回 iPhone 的实机验收，并记录失败阶段/错误码及蓝莓版本。
