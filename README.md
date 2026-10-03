# 果果

暖白与墨绿的 Flutter 短剧应用。以 iPhone、iPad 为当前交付重点，Android 工程保留。

> 开发版本。源码已接入十六站目录、原生播放与下载/投屏路径；具体 iOS 安装包和验证结果以 GitHub Actions 及 [实现状态](docs/implementation-status.md) 为准，源码接入不等于真机验收通过。

## 界面预览

以下使用明确标注的布局示例内容，不是站源实测截图。

<img src="screenshots/phone-light.png" width="260" alt="手机浅色界面" /> <img src="screenshots/tablet-dark.png" width="560" alt="平板深色界面" />

[发现页预览](screenshots/recommendations-light.png) · [深色发现页](screenshots/recommendations-dark.png) · [新版详情页](screenshots/detail-phone-light.png) · [平板详情页](screenshots/detail-tablet-dark.png)

## 0.11.3 开播缓冲与站源选择

提前开播改为等待足够的已完成分片，连续 10 秒没有播放进度时保留位置并回退完整准备；覆盖已出画面但卡在开头的原生等待状态。站源入口改为可搜索的网格弹窗，剧库、收藏／历史和下载共用，手机正常字号可直接选择十六站。范围与验证见 [修复记录](docs/playback-startup-and-source-picker-2026-10-03.md)。

## 0.11.2 恢复与后台交接

有限重试、恢复请求互斥、播放意图和 PiP 后台交接由独立控制器协调。修复等待取消提前开播任务时关闭 PiP，回到前台后被旧恢复请求重新开播的问题；保留进度和暂停状态。范围与验证见 [实施记录](docs/playback-coordination-2026-10-03.md)。

## 0.11.1 播放会话整理

播放资源的准备、缓存、前台接管和释放统一由独立会话控制器管理，集中校验切集与重试的播放轮次。快速连续切集时跳过过时的原生设置请求，设置失败后仍可继续恢复；补齐未使用备用资源的释放。保留现有播放、预取及 PiP 策略，范围与验证见 [实施记录](docs/playback-session-2026-10-03.md)。

## 0.11.0 首段预取

下一集后台准备改为解析地址及有限首段预取，每个播放会话最多读取 4 MiB 媒体数据、持续 6 秒、发起 8 次请求（含重定向）。选中该集后复用已有数据，再按现有方式准备加密媒体。继续遵守 Wi-Fi 偏好；取消、退出和释放会话时清理。播放诊断区分地址准备与首段缓存，详细边界见 [实施记录](docs/media-prefetch-2026-10-03.md)。

## 0.10.0 上游更新

吸收 guoapp `0.2.79+2086` 的站源修复、榜单入口、黄果 AI 在线搜索与受限媒体证书回退，新增红果渐进搜索、搜索缓存、JSON/XZ 剧库互通、同系列入口及显示层刷新节流。移除网果、发果，现有站源为十六个。完整范围、取舍和验证边界见 [本轮实施记录](docs/upstream-refresh-2026-10-03.md)。

## 0.9.0 接口更新

根据用户提供的真果·鉴 `0.2.55+61` 压缩包，新增芽果、猫果、饭果、观果、河果、星果、花果、牛果、网果、发果、皮果、伍果十二个站源接口，接入现有分类、目录、搜索、详情及分集解析流程。包含河果、星果搜索接口更新和猫果标题清理；十八个站源沿用独立缓存与记录身份。皮果可能受站点浏览器校验限制，真实播放与 iOS 真机行为仍待验证。来源、范围及验证见 [本轮合并记录](docs/upstream-refresh-2026-09-28.md)。

## 0.8.0 新增站源

合并 guoapp 的剧果、野果、帝果，支持在线分类、分页目录与搜索、详情和分集解析。六源选择栏可横向滚动，分类缓存独立保存；剧果播放凭证限制在对应媒体源，过期地址重新解析，下载恢复刷新授权并保留身份一致的已完成分片。原有收藏、历史和下载身份保持兼容。范围和验收记录见 [融合实施记录](docs/app-fusion.md)。

## 0.7.3 修复

吸收 guoapp 的红果榜单兼容解析：结构化数据未完整返回时读取经过身份、名次和分页校验的网页内容，有限重试并沿用旧榜单回退。修复暂停时线路恢复会自动开播的问题；下一集后台准备限制为 15 秒，切到该集后复用任务并撤销后台时限，迟到结果释放资源。合并取舍和播放器后续优化见 [融合实施记录](docs/app-fusion.md#第三批近期更新评估与稳定性修复07318)。

## 0.7.2 修复

修复提前开播与自动画中画的交接：直接返回桌面时保留当前播放，支持后台恢复与自动连播；画中画启动较晚时恢复兼容视频并保留位置。

## 0.7.1 修复

修复提前开播在 iOS 上初始时长为 0、进度条无法拖动的问题，持续更新已准备范围；保存真实观看位置，整集时长未知时首页显示已看时间。实验仍默认关闭，需真机复测。

## 0.7.0 更新

播放诊断新增默认关闭的“提前开播（实验）”：从头播放加密 MP4 时，首段准备完成即可交给现有原生播放器，剩余内容继续准备。临时内容不计入下载；续播、画中画、投屏与返回前台使用完整准备，保留进度和暂停状态。失败自动回退，详情见 [融合实施记录](docs/app-fusion.md)。尚未完成 iOS 真机性能验收。

## 0.6.0 更新

吸收 guoapp 的播放恢复与详情交互设计：详情底部常驻播放和下载入口，选集支持定位当前；播放失败优先尝试备用线路，再有限次重新解析，保留位置与倍速。新增自动连播开关和倍速记忆，预加载等待当前播放缓冲充足后启动。iOS 继续使用现有原生播放器及后台下载路径。

本轮范围、验证与后续融合计划见 [融合实施记录](docs/app-fusion.md)。流式解密内核替换、Android TV 和设备同步尚未接入；更多站源见 0.8.0。

## 0.5.0 更新

同步新版解析、搜索补季与联想，新增红果发现页、剧库排序、黄豆 VIP 筛选、详情资料刷新和分集分页跳转。详见 [本轮同步范围与验证](docs/upstream-refresh-2026-09.md)。

## 使用方式

- 点击当前站源打开网格，支持搜索站源名称；剧库按十六站分别浏览，收藏、历史和下载支持“全部站源”筛选。
- 选集、上下滑切集、续播、倍速、画中画；单击切换控件，左右滑动预览进度，长按 2 倍速，长按后左右滑动快进/快退。
- 榜单采用大封面与排名卡片；黄果、黄豆以及历史/下载记录会自动补取缺失或过期的封面。
- 浅色、深色、跟随系统，手机与平板布局。
- 分集与整剧下载、直接播放、滑动删除；按剧统计空间和大小排序，跨状态整剧多选删除，按失败/暂停状态筛选与批量重试；离线浏览、记录备份与导入。
- iOS AirPlay；Google Cast、DLNA 设备发现与在线投屏。
- 站源解析嵌入应用内，不需要部署电脑或业务服务器。

## 安装 iOS 开发版本

1. 打开本仓库 [Releases](https://github.com/maxduke/guoguo-mobile/releases/latest)，下载对应版本的 `Guoguo-版本+构建号-ios-unsigned.ipa`。
2. 可使用同页 `SHA256SUMS` 核对文件完整性，`build-info.json` 可查询源码提交与构建记录。
3. 使用自己的签名工具和 Apple 账户重新签名后侧载到 iPhone / iPad。

未发布的开发构建仍可在通过的 `CI` 运行中下载 `Guoguo-iOS-unsigned` artifact，保留 14 天。Release 附件不受该保留期影响。

IPA 未签名，不能直接点击安装。签名工具、账号与证书均由使用者管理，不存入仓库。自签后需实测本地网络发现、画中画及后台下载。

## 发布新版

1. 更新 `pubspec.yaml` 中的版本和递增构建号，新增 `releases/v版本.md` 更新说明。
2. 提交并推送源码，等待该提交在 `main` 上的 push CI 检查和 iOS 构建通过。
3. 对同一提交创建并推送版本标签，例如 `git tag v0.3.0`、`git push origin v0.3.0`。
4. 标签仅触发 `Release` 工作流：查找同一提交已成功的 `main` push CI，复用其 IPA，核对版本、提交及 SHA-256 校验和后发布；不重复测试或 iOS 构建，上传完成前保持草稿状态。

若标签先于 CI 完成，待 CI 成功后重跑失败的 Release；若构建产物已超过 14 天保留期，先重跑该提交的 main push CI，再重跑 Release。不会回退到其他提交的安装包。

标签必须匹配源码版本，安装包内部版本及构建号也必须一致。普通分支、PR 和手动 CI 运行不会发布；失败运行可重试，已公开版本的附件不会自动覆盖。发布标签不应移动或复用，修复已发布版本时递增版本号。

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
| `docs` | 需求、ADR、验收场景与实现状态 |

## 文档

- [首版规格](docs/v1-spec.md)
- [实现状态与已知限制](docs/implementation-status.md)
- [移动端技术调研](docs/mobile-feasibility.md)
- [领域术语](CONTEXT.md)
- [参考代码来源](native/core/UPSTREAM.md)
