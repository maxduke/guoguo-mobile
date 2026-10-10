# 定位与锁屏恢复

0.17.2 保留 BetterPlayer/AVPlayer 及现有 Go 中转。黄果普通 HLS 播放不经过“提前开播（实验）”；该实验开关不影响本轮优化是否生效。

## 定位的完成和播放意图

原插件方法通道在提交 AVPlayer.seek 后立即返回，原生和 Dart 又分别保存开始定位时的播放状态。迟到的完成回调可能重新播放已被用户暂停的媒体，连续调用也会互相取消。本轮通过主线程 `GuoguoSeekCoordinator` 完成当前请求，再只追最后一个目标。被替代的调用返回取消；每次原生操作最多等待 12 秒，媒体替换、后台非 PiP 暂停和释放先失效回调再取消原生操作。

应用的 iOS 定位使用 `guoguoSeek` 通道，按唯一会话媒体地址匹配当前原生播放器，收到真实完成通知后更新公共视频值。这样避开插件 Dart `seekTo` 在 await 后恢复旧播放快照的行为，无须读取其测试专用 textureId 或修改共享 pub 缓存。地址只用于进程内调用，不写诊断。其他平台保留已有公开 API。

普通拖动允许前后 250 ms 的容差，起点和终点限制向外容差。完成后是否恢复由当前播放意图决定；切集、暂停及投屏归属保护继续生效。Flutter 定位等待和卡顿监测分开，完成后重新给缓冲恢复计时。每次定位记录目标、耗时和结果，保留原有最近 30 条的诊断限额。

Apple 建议通过完成回调顺序处理连续定位：[QA1820](https://developer.apple.com/library/archive/qa/qa1820/_index.html)。零容差的精确定位可能增加解码延迟：[AVPlayer.seek](https://developer.apple.com/documentation/avfoundation/avplayer/seek(to:tolerancebefore:toleranceafter:))。

## 缓存和显示恢复

只有已结束、包含媒体片段且没有 BYTERANGE 的点播播放列表建立可复用对象。完整 GET 按本地资源身份共享请求，已完成且长度一致的分片和初始化片段进入 LRU。按声明长度预留内存并固定活跃读者，最多 32 MiB、单对象 8 MiB、128 个对象、四个缓存下载。缓存统计只用于内部测试，不把加入正在下载的请求当作已缓存字节。跨会话不共享，关闭时取消任务并释放存储。

边收边读，不等整个对象下载后才播放。已缓存的范围请求和 HEAD 复用 HTTP 内容语义；未缓存的范围、直播、密钥、整部 MP4、未知大小、超大对象、非正常编码、Vary、no-store 及不安全响应继续转发。加密媒体保持已有解密路径。某个读者取消不会中断其他读者；最后一个读者离开才取消未完成下载。

普通非 PiP 锁屏暂停后只断开 AVPlayerLayer 的播放器引用，保留 AVPlayerItem 和会话。进入前台或用户播放时重新连接当前可见显示层，不重新解析地址、安装媒体或定位。系统锁屏定位直接走同一原生协调器，不再发送让插件 Dart 重复定位的事件；回到前台时通过公开位置查询同步进度，并检查分集和定位身份。已有实验 EVENT 媒体中断后的完整准备回退保持原策略。Apple 对前后台显示层和播放器分别管理的说明：[Media Playback Guide](https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/MediaPlaybackGuide/Contents/Resources/en.lproj/RefiningTheUserExperience/RefiningTheUserExperience.html)。

## 验证范围

自动化覆盖原生请求合并、超时、取消和迟到回调，Flutter 定位中暂停/切集/后台、容差后的实际位置和等待期不触发换源，以及缓存的实际 HTTP 请求数、部分传输、取消隔离、完整性、加密及内存预算。iOS CI 编译原生补丁和完整应用。

主机测试不测量 iPhone 的实际首帧、解码器恢复和内存/能耗。真机按同一剧集、同一网络分别重复前拖、回拖和锁屏恢复至少五次；记录操作到正常画面的时间，核对诊断中的定位完成时间。超过缓存工作集的回拖仍可能重新联网，未播放过的位置仍需要获取新分片。若原生完成快但画面慢，再根据 AVPlayer 和网络日志定位渲染或源端瓶颈。
