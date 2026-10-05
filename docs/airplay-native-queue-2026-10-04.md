# AirPlay 独立原生队列（0.15.0+33）

## 为什么替换

用户真机反馈 0.14.0 下一集仍卡住、投屏不稳定。前几批自动化通过不能证明安卓电视接收软件的运行结果。本次删除 AirPlay 与 BetterPlayer 共用 AVPlayer、逐集重新安装 relay、按 Flutter finished 切页及共享播放器路由恢复的实现；原有手机 HLS 渲染修正保留。

## 参考 app 的实际实现

核对 maxduke/guoapp 最新 `5999e469e1281e55dcf603c980f83cd0ba00206d`（0.2.79+2086）。该仓库私有，源码可通过已认证 GitHub 读取，普通网页访问返回 404。

它的“推送”使用自定义局域网设备互联：发送站源、剧集和分集标识、最新位置，接收端必须运行同款 app，自行解析或读取下载视频。准备完成后发送开始请求；接收端定位、视频尺寸有效、没有缓冲且位置继续前进，才回执开播，发起端随后暂停。它没有 AirPlay、DLNA 或 Chromecast 实现，不能直接复用为第三方安卓电视 AirPlay 接收软件的方案。

来源：[推送协议源码](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/lib/lan_playback.dart)、[接收端播放器](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/lib/player_screen.dart)、[上游功能说明](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/README.md)。可吸收的是明确的资源归属、确认后交接和过期操作失效约定，不能把协议名称或图标当作实现能力。

## 新实现

`guoguo_core` 注册独立 AirPlay 方法通道。`AVPlayerViewController` 提供系统视频、暂停、定位和路由控件，`AVQueuePlayer` 持有独立播放队列。手机 BetterPlayer 始终使用自己的播放源，投屏不会替换其 texture 或媒体地址。

Flutter 为投屏建立独立完整媒体准备会话，仅保留当前集和下一集。已经完成的手机媒体可以借用，文件归原会话持有；提前开播的本机 EVENT 服务先停止，投屏重新准备完整视频。加密视频、本地 MP4 和带请求头的远端媒体继续通过已验证的 HTTP 中转公开给电视。下一集提前入队，原生按真实 item 结束／切换管理连播；准备晚到时保留播放意图，暂停意图也不被后续入队覆盖。关闭自动连播时不预入队，原生“下一集”仍可主动请求。

每次投屏拥有独立会话 ID，事件还带单调序号和当前 item ID。过期页面、过期事件、重复下一集请求不能控制新的播放。原生切换后才关闭已撤下视频的中转，关闭整个会话时先暂停、清空队列、撤销观察者并关闭界面，得到确认后再释放所有 HTTP 服务和准备文件。下一集准备失败只报告一次，原生显示提示并允许主动重试，不触发手机恢复循环。

原生全屏界面包含系统路由选择与“下一集”入口，关闭界面会结束这次播放。实际系统音频路由另行读取：仍选中电视时手机继续暂停，提供可见的系统路由选择界面；用户选回 iPhone 后恢复原生报告的分集、位置与暂停意图。重新进入时也先检查路由，防止手机画面配电视声音。视频已连接只按真实 `isExternalPlaybackActive` 判定；仅音频路由选中不能算成功，连接等待有明确超时提示。应用不使用私有 API 或录音类别强制切换路由。

Apple 依据：[AVQueuePlayer](https://developer.apple.com/documentation/avfoundation/avqueueplayer) 管理顺序媒体；[AVPlayerViewController](https://developer.apple.com/documentation/avkit/avplayerviewcontroller) 自带 AirPlay 支持；[currentRoute](https://developer.apple.com/documentation/avfaudio/avaudiosession/currentroute) 描述系统当前音频路由。

## 验证边界

Flutter 回归验证手机源不被替换、暂停传递、提前入队、结束早于准备完成、后台原生切集、关闭后进度恢复、系统路由仍选电视时手机阻断、取消与停止确认顺序、旧会话事件过滤，以及准备失败不会无限重试。纯 Swift 队列策略回归和完整 iOS 编译由 CI 验证。

本地完整 Flutter 回归 336 项通过、3 项布局预览跳过；最后的队列租约竞态补充后，23 项投屏定向回归通过。静态分析无问题，16 项 Python 发布／补丁工具测试通过，受校验补丁可正常生成独立构建副本。iOS 原生编译及 Swift 策略执行仍由当前提交的 CI 结果确认。

本次不能把自动化或编译通过描述为第三方接收软件真机通过。接收软件名称和版本仍待提供。交付后需按设备清单验证连续三集、下一集准备迟到、暂停后下一集、关闭并重进、切回 iPhone、锁屏和断网。Apple 公开 API 不能保证所有安卓接收软件支持视频队列；实际失败应结合原生提示及 HTTP 取流情况定位。

Google Cast／DLNA 保留各自独立传输与控制实现；本次替换的是用户实际反复测试失败的 AirPlay 路径。
