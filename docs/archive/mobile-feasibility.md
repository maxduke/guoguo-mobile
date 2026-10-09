> 历史记录：保留当时的设计、实现和验证范围，不代表当前行为。参见 [当前产品规格](../product-spec.md)。

# 移动端技术验证

## 调研范围与限制

参考仓库：`maxduke/guoguo-video`，提交 `9f1a1b5886ad5d86f85e6bfb7bf8de5536bc8cf9`。
本地参考检出与此提交一致且工作区干净。本轮只读检查源码及平台官方资料，没有运行站源请求、下载或播放器，没有修改参考仓库。

当前环境为 Linux，PATH 未发现 flutter、dart、go 或 adb 命令；这仅表示当前工具环境尚未准备，不代表设备适配失败。iOS 编译签名与真机验证环境尚未检查。

## 已发现的实现差异

### 1. 原生媒体能力需要重新验证

参考项目 `internal/app/playback_stream.go` 的 `playbackEncodingArgs` 配置 H.264/AAC 转码，`playback_native.go` 通过 `exec.CommandContext` 启动 FFmpeg 并生成 HLS。这里的 native 路径是服务端为浏览器生成 HLS，不能据此认为已有手机原生播放器。

`provider_hongguo_native_media.go` 的 `selectHongguoAppMedia` 处理清晰度、编码筛选及加密媒体信息；`provider_media.go` 的媒体结构还携带 Referer、播放列表和密钥信息。因此仅把 URL 传给 Flutter 播放控件是否可行，必须按媒体类型实测。

源码依据：[播放处理](https://github.com/maxduke/guoguo-video/blob/9f1a1b5886ad5d86f85e6bfb7bf8de5536bc8cf9/internal/app/playback_stream.go)、[HLS 生成](https://github.com/maxduke/guoguo-video/blob/9f1a1b5886ad5d86f85e6bfb7bf8de5536bc8cf9/internal/app/playback_native.go)、[红果媒体选择](https://github.com/maxduke/guoguo-video/blob/9f1a1b5886ad5d86f85e6bfb7bf8de5536bc8cf9/internal/app/provider_hongguo_native_media.go)。

验证目标：每站选取代表性媒体，在 iOS、Android 上验证首帧、拖动、清晰度切换、续播、请求头及链接刷新；比较直接播放与手机端必要处理的路径。不能把桌面 FFmpeg 子进程调用当作已完成移动适配。

### 2. 完整下载管理需要独立设计

`downloader.go` 与 `provider_huangguo.go` 中的下载实现会在进入下载及若干失败路径删除 `.part.mp4`，并启动 FFmpeg。现有进度回调可以参考，但不能据此承诺已具备持久化断点恢复。

源码依据：[通用下载](https://github.com/maxduke/guoguo-video/blob/9f1a1b5886ad5d86f85e6bfb7bf8de5536bc8cf9/internal/app/downloader.go)、[站源下载](https://github.com/maxduke/guoguo-video/blob/9f1a1b5886ad5d86f85e6bfb7bf8de5536bc8cf9/internal/app/provider_huangguo.go)。

验证目标：分别检查文件与分片资源的恢复能力、临时资源持久化、链接过期后重新解析、剩余空间不足及后台运行。需要区分下载传输和媒体处理，不能假设后台文件传输可持续执行任意转码。

Apple 提供后台 URLSession 下载，应用恢复时需重新关联会话；HLS 资源下载也有专门 API。它们是候选能力，并不证明所有站源媒体均可直接使用。参见 [Apple 后台下载](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background)及 [AVAssetDownloadURLSession](https://developer.apple.com/documentation/avfoundation/avassetdownloadurlsession)。

### 3. 三站联网搜索不是现成的统一接口

`ui_library_search.go` 的 `handleLibrarySearch` 直接调用 `searchHongguoDramas`。此次检查只确认现有 UI 联网搜索入口支持红果，不能由此推断黄果或黄豆的上游一定没有搜索能力。

源码依据：[联网搜索入口](https://github.com/maxduke/guoguo-video/blob/9f1a1b5886ad5d86f85e6bfb7bf8de5536bc8cf9/internal/app/ui_library_search.go)。

验证目标：分别调查另外两个站源的搜索能力。不支持或暂时失败时保留本地结果并准确说明，不能显示假的联网成功状态。

### 4. 投屏是单独的兼容问题

在参考项目 internal 与 go.mod 中搜索 AirPlay、Chromecast、DLNA、Google Cast、UPnP 等关键词，未发现对应实现；此结果仅限此次检查范围。

根据参考代码的请求头及媒体处理需求，推断部分资源可能不能直接交给接收设备播放。Google Cast 官方资料还要求按接收端核对格式、编码与 CORS；因此“手机可播放”不能作为“电视可播放”的充分证据。参见 [Google Cast 媒体支持](https://developers.google.com/cast/docs/media)。

验证目标：分别记录手机平台、接收设备型号/软件、协议、媒体样本、播放/控制/续播结果和手机后台行为。国内电视不能统一视作 DLNA 设备，先确认接收端实际能力。

优先验证接收端直接取流；若资源需要手机中转，单独验证后台可持续性与网络行为。不得为解决兼容问题悄悄引入必需的远程业务服务器。

### 5. PiP 必须连接真实播放会话

PiP 需要按照原生平台要求处理播放器与生命周期，不能用应用内悬浮组件替代。参见 [Apple 自定义播放器 PiP](https://developer.apple.com/documentation/avkit/adopting-picture-in-picture-in-a-custom-player)及 [Android PiP](https://developer.android.com/develop/ui/views/picture-in-picture)。

验证目标：使用最终候选播放路径，检查进入 PiP、切回全屏、暂停恢复、结束分集、方向切换及进度持久化，避免只用公开 MP4 样本证明全部媒体兼容。

## 尚未决定的技术选择

- 站源逻辑使用 Dart 重写还是抽取可嵌入的 Go 核心。
- 播放器插件、原生桥接方式，以及是否需要额外媒体处理库。
- 下载后台服务与分片恢复实现。
- AirPlay、Google Cast 与国内接收端的适配路径。
- 最低系统版本、设备矩阵与性能阈值。

上述选型应在技术样例通过后再形成 ADR。目前唯一确定的架构约束是独立运行，见 [ADR 0001](../adr/0001-standalone-mobile-app.md)。

## 完成技术验证的证据

每项保存测试设备/系统、参考提交、测试时间、媒体类型、复现步骤与结果；失败需保留可追踪原因。未执行项目标记为“未验证”，不使用模拟器画面或单一站源成功替代三站和真机结论。
