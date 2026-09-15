# 果果

暖白与墨绿的 Flutter 短剧应用。以 iPhone、iPad 为当前交付重点，Android 工程保留。

> 开发版本。源码已接入三站目录、原生播放与下载/投屏路径；具体 iOS 安装包和验证结果以 GitHub Actions 及 [实现状态](docs/implementation-status.md) 为准，源码接入不等于真机验收通过。

## 界面预览

以下使用明确标注的布局示例内容，不是站源实测截图。

<img src="screenshots/phone-light.png" width="260" alt="手机浅色界面" /> <img src="screenshots/tablet-dark.png" width="560" alt="平板深色界面" />

## 使用方式

- 剧库按红果、黄果、黄豆分别浏览；收藏、历史和下载跨站汇总。
- 选集、上下滑切集、续播、倍速、画中画；单击切换控件，左右滑动预览进度，长按 2 倍速，长按后左右滑动快进/快退。
- 榜单带小封面；黄果、黄豆以及历史/下载记录会自动补取缺失或过期的封面。
- 浅色、深色、跟随系统，手机与平板布局。
- 分集与整剧下载、离线浏览、记录备份与导入。
- iOS AirPlay；Google Cast、DLNA 设备发现与在线投屏。
- 站源解析嵌入应用内，不需要部署电脑或业务服务器。

## 安装 iOS 开发版本

1. 打开本仓库 Actions，选择当前提交通过的 `CI` 运行。
2. 下载 `Guoguo-iOS-unsigned` artifact 并解压，得到 `Guoguo-unsigned.ipa`。
3. 使用自己的签名工具和 Apple 账户重新签名后侧载到 iPhone / iPad。

IPA 未签名，不能直接点击安装。签名工具、账号与证书均由使用者管理，不存入仓库。自签后需实测本地网络发现、画中画及后台下载。

## 本地开发

工具版本与 CI 对齐：Flutter 3.47.4、Go 1.27.1。iOS 原生编译需要 macOS、Xcode 和 CocoaPods。

```bash
flutter pub get
scripts/setup_core.sh
scripts/build_core.sh ios
flutter config --no-enable-swift-package-manager
scripts/prepare_ios_media.sh
flutter build ios --release --no-codesign
```

`prepare_ios_media.sh` 在构建时准备依赖包提供的原生 FFmpeg 库；应用运行时不会下载或启动桌面可执行文件。

Android 暂未完成验收。配置 Android SDK/NDK 后可使用 `scripts/build_core.sh android` 构建桥接库。

## 检查

```bash
flutter analyze
flutter test --concurrency=1
cd native/core
go test ./mobile ./internal/app
```

三站目录手动实测（不在 CI 自动访问站源）：

```bash
cd native/core
go run ./cmd/probe -source hongguo
go run ./cmd/probe -source huangdou
go run ./cmd/probe -source huangguo
```

## 目录

| 目录 | 职责 |
| --- | --- |
| `lib/domain` | 站源、短剧、分集、观看记录、备份模型 |
| `lib/data` | 缓存、收藏/历史持久化、下载任务与恢复 |
| `lib/ui` | 手机/平板界面与播放器 |
| `lib/platform` | 原生桥接、媒体准备、局域网投屏 |
| `packages/guoguo_core` | Swift/Kotlin 平台插件 |
| `native/core` | 从参考项目复用的 Go 解析核心与移动端接口 |
| `docs` | 需求、ADR、验收场景与实现状态 |

## 文档

- [首版规格](docs/v1-spec.md)
- [实现状态与已知限制](docs/implementation-status.md)
- [移动端技术调研](docs/mobile-feasibility.md)
- [领域术语](CONTEXT.md)
- [参考代码来源](native/core/UPSTREAM.md)
