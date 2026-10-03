# iOS 提前开播画面修复（0.11.4+26）

用户补充了更具体的现象：红果提前开播已经出画面，进度条持续前进，但画面不播放；手动拖动后恢复。上一版的位置无进度检测不能识别这种情况，本批继续在 PR #9 上修正原生渲染和起播路径。

## 原生渲染

锁定的 BetterPlayer 1.4.1 会异步读取视频轨并为每个媒体添加 `AVMutableVideoComposition`，合成指令时长取自 `asset.duration`。本地 EVENT HLS 的时长不确定或仍在增长。[Apple 文档](https://developer.apple.com/documentation/avfoundation/avplayeritem/videocomposition) 明确说明 `AVPlayerItem.videoComposition` 适用于基于文件的媒体，不支持 HLS。这是源码中确认存在的错误用法，与反馈相符；没有获得该设备原生日志，不能把计时器前进当成画面正常的证据。

修复把现有 `formatHint` 转交给 iOS，按 HLS 提示或 `.m3u8` 路径禁用这条合成路径，包括没有扩展名的 HLS 地址。HLS 由现有 `AVPlayerLayer` 直接渲染。普通 MP4 保留原有合成，赋值前检查有限时长、当前媒体身份和关闭状态，回到主线程后再修改播放器，阻止旧媒体异步回调干扰新一集。

依赖固定为 1.4.1。`patches/better_player_plus` 保存小范围修复、源码摘要和许可，构建脚本先验证原始源码再在 `.dart_tool/ios_player` 生成独立副本；Podfile 将该副本接入 CocoaPods。原始 pub 缓存不修改；脚本输出未通过校验时构建停止。当前构建继续关闭 Swift Package Manager。

## 起播定位

插件的 Dart `seekTo` 在 iOS 方法通道返回后继续执行，而 iOS 方法通道没有等待 AVPlayer 真正完成定位。提前开播初始化先定位到零、再播放，会使定位与播放重叠。本地 EVENT 播放列表现在附带 `EXT-X-START:TIME-OFFSET=0,PRECISE=YES`，原子输出文件本身不修改，GET 与 HEAD 的长度同步更新。依据 [RFC 8216 §4.3.5.2](https://www.rfc-editor.org/rfc/rfc8216.html#section-4.3.5.2)，客户端可按该提示从剧集起点开始；页面不再额外发起初始定位。

完整媒体的续播、用户拖动和结束后重播保留；上一版启动缓冲、有限恢复、源网格及搜索隔离保留。不使用自动拖动来掩盖画面状态，也没有把时间推进记录升级成真实视频帧指标。

## 验证与设备复测

新增回归检查原生 HLS 提示、初始化没有额外定位且请求播放；播放列表从零起播提示、HEAD 长度及原始文件保持原样；独立修复副本重复生成、缓存原始文件未修改、版本／源码／修复结果不匹配时拒绝生成，错误补丁和输出软链接不会覆盖已有文件。

- 本地 4 个相关 Flutter 文件共 59 项通过，其中完整播放器／PiP 回归 41 项；实际 FFmpeg CENC 音视频回归再次检查首帧、全部视频帧及音轨解码。
- 16 项 Python 发布／身份／播放器副本测试通过，其中新增副本回归 7 项；实际播放器副本生成成功，原始文件与锁定的官方包源码一致。
- `flutter analyze --no-pub`、73 个 Dart 文件格式、actionlint、`0.11.4+26` 版本校验和 diff 空白检查通过。

iOS CI 编译并执行八项 Swift 媒体策略回归，覆盖 EVENT、无扩展名 HLS、大小写、查询参数和普通／本地 MP4，再编译完整 iOS 应用。实际画面仍需安装构建号 26，在原先卡住的分集上不拖动复测，同时检查方向、声音、暂停、续播和 PiP；Flutter 原生通道模拟及策略测试不能代表设备上的视频帧验收。

后续反馈（2026-10-03）：用户确认 0.11.4 真机测试无明显问题，继续实施新季提醒与同系列补全。
