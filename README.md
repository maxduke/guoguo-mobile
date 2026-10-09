# 果果

暖白与墨绿的 Flutter 短剧应用。以 iPhone、iPad 为当前交付重点，Android 工程保留。

> 开发版本。源码已接入十六站目录、原生播放与下载/投屏路径；具体 iOS 安装包和验证结果以 GitHub Actions 及 [实现状态](docs/implementation-status.md) 为准，源码接入不等于真机验收通过。

## 界面预览

以下为当前导航的布局示例（2026-10-09），使用示例内容，不是站源实测截图。

<img src="screenshots/phone-light.png" width="260" alt="手机浅色界面" /> <img src="screenshots/tablet-dark.png" width="560" alt="平板深色界面" />

## 当前开发约定

按全新安装维护：记录使用 `records.json`，可重建缓存使用 `catalog-cache.json`；记录备份只接受和生成 v2，不导入旧 `state.json`。旧文件不会自动删除。

当前行为见 [产品规格](docs/product-spec.md)，验证与限制见 [实现状态](docs/implementation-status.md)，历史版本说明见 [更新记录](CHANGELOG.md)。

## 使用方式

- 发现、追剧、下载为主导航；发现保留推荐、榜单、完整剧库及独立搜索入口，追剧提供最近续播与明确的记录操作。
- 十六站分别浏览，可管理常用、最近和隐藏站源；收藏、历史和下载支持“全部站源”筛选。联网搜索和本地缓存筛选按站源能力区分。
- 选集、上下滑切集、续播、倍速、画中画；单击切换控件，普通横滑预览进度，长按临时加速，并保留明确的播放和相邻分集控件。
- 浅色、深色、跟随系统；按可用窗口切换侧栏与底部导航，保留页面状态，支持大字号和读屏操作。
- 下载按剧分组，展开后可操作分集与滑动删除；保留选定范围/整剧下载、离线播放、筛选与批量重试，以及次级空间管理。设置提供真实统计范围与安全清理，记录备份包含收藏、历史和新季提醒。
- 统一设备入口提供 iOS AirPlay、Google Cast、DLNA 及进度交接。Cast/DLNA 手机中转需保持前台；AirPlay 独立原生队列的后台与接收器兼容性仍需真机验收。
- 站源解析嵌入应用内，不需要部署电脑或业务服务器。

## 安装 iOS 开发版本

1. 打开本仓库 [Releases](https://github.com/maxduke/guoguo-mobile/releases/latest)，下载对应版本的 `Guoguo-版本+构建号-ios-unsigned.ipa`。
2. 可使用同页 `SHA256SUMS` 核对文件完整性，`build-info.json` 可查询源码提交与构建记录。
3. 使用自己的签名工具和 Apple 账户重新签名后侧载到 iPhone / iPad。

未发布的开发构建可在通过的 main 或手动 `CI` 运行中下载 `Guoguo-iOS-unsigned` artifact，保留 7 天。PR 仍执行检查和 iOS 构建，但不上传 IPA。tag 发布的中转包只保留 1 天，Release 附件不受这些保留期影响。

IPA 未签名，不能直接点击安装。签名工具、账号与证书均由使用者管理，不存入仓库。自签后需实测本地网络发现、画中画及后台下载。

## 发布新版

1. 更新 `pubspec.yaml` 中的版本和递增构建号，新增 `releases/v版本.md` 更新说明。
2. 提交并推送源码，等待常规 CI 检查通过后合并到 `main`。
3. 对需要发布的提交创建并推送版本标签，例如 `git tag v0.3.0`、`git push origin v0.3.0`。
4. 标签触发 `Release`，调用与普通 CI 相同的检查和 iOS 构建流程；全部成功后仅下载本次运行的 IPA，核对版本、提交及 SHA-256 校验和，再上传同一份文件，上传完成前保持草稿状态。发布不再依赖历史 main CI 包。

构建失败可重跑失败任务。若本次中转包超过 1 天仍未完成发布，需要重跑整个 Release 工作流重新构建，不能只重跑下载步骤；不会回退到其他运行或提交的安装包。新流程仅对包含新工作流的提交生效，旧提交上的 tag 仍使用当时的工作流。

标签必须匹配源码版本，安装包内部版本及构建号也必须一致。普通分支、PR 和手动 CI 运行不会发布；失败运行可重试，已公开版本的附件不会自动覆盖。发布标签不应移动或复用，修复已发布版本时递增版本号。

## 本地开发

工具版本与 CI 对齐：Flutter 3.47.4、Go 1.27.1。iOS 原生编译需要 macOS、Xcode 和 CocoaPods。

```bash
flutter pub get
scripts/setup_core.sh
scripts/build_core.sh ios
flutter config --no-enable-swift-package-manager
scripts/prepare_ios_media.sh
python3 scripts/prepare_ios_player.py
flutter build ios --release --no-codesign
```

`prepare_ios_media.sh` 在构建时准备依赖包提供的原生 FFmpeg 库；应用运行时不会下载或启动桌面可执行文件。

`prepare_ios_player.py` 校验锁定的播放器源码并生成仅供 CocoaPods 使用的 iOS 修复副本，依赖缓存保持原样；Podfile 也会在安装依赖时准备该副本。当前 iOS 构建使用 CocoaPods，保持 Swift Package Manager 关闭。

Android 暂未完成验收。配置 Android SDK/NDK 后可使用 `scripts/build_core.sh android` 构建桥接库。

## 检查

```bash
flutter analyze
flutter test --concurrency=1
cd native/core
go test ./mobile ./internal/app
```

各站目录手动实测（不在 CI 自动访问站源）：

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
| `docs` | 当前规格、工程边界、性能证据、验收与历史档案 |

## 文档

- [当前产品规格](docs/product-spec.md)
- [实现状态与已知限制](docs/implementation-status.md)
- [状态职责与页面更新边界](docs/app-state.md)
- [性能基线与取舍](docs/performance-baseline.md)
- [iPhone / iPad 真机验收](docs/ios-device-checklist.md)
- [历史规划与实施记录](docs/archive/README.md)
- [架构决策](docs/adr/0001-standalone-mobile-app.md)
- [领域术语](CONTEXT.md)
- [参考代码来源](native/core/UPSTREAM.md)
