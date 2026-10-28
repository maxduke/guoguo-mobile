# v0.20.5 后的现有功能改进审查

前三条可靠性路径的后续实现见 [播放可靠性修复记录](playback-reliability-2026-10-28.md)；以下保留修复前的审查证据。

基线：`0.20.5+59`（发布标签 `v0.20.5`），`694c9de9fa544496f304fe3a50a54768d7c750f1`。按本轮要求只审查已有功能的可靠性、重复工作和性能；定时停止、电视键盘、组合筛选、扫码输入、评论及账号云同步均不进入本轮建议。

本次没有修改应用行为，也没有提交或发布补丁。审查发现不代表用户设备已经出现同一故障；下文分别标明受控复现、源码确认和待量测项目。前几轮已经修好的下载增量进度、隐藏页面订阅、大备份后台编码、损坏清单恢复及榜单会话复用不重复列为缺陷。

## 建议先修的可靠性问题

### 1. 原生播放器初始化缺少等待上限

**证据：受控 widget 探针复现。** `PlaybackSessionController.installSource` 串行等待上一份安装；`PlayerPage._activate` 等待 `setupDataSource` 后才结束加载。现有健康检查排除了加载期间。锁定的 BetterPlayer 中，设置数据源会等待原生初始化或错误事件，应用没有为这一阶段设置期限。

探针让第一集的原生 `setDataSource` 正常返回，但不发送 `initialized` 或错误事件。随后切到第二集，两个分集都已解析，却仍只向原生提交了第一份数据源。推进约 131 秒模拟时间后，界面仍显示“正在启动播放器…”，没有重试按钮，也没有开始播放。补发第一份初始化事件后，第二份数据源才得以安装。该结果说明缺少事件时存在持续等待路径，不证明生产环境发生频率。

位置：[`playback_session.dart:132`](../lib/platform/playback_session.dart#L132)、[`player_page.dart:562`](../lib/ui/player_page.dart#L562)、[`player_page.dart:698`](../lib/ui/player_page.dart#L698)；依赖的等待逻辑位于生成的 `.dart_tool/player/better_player_plus/lib/src/video_player/video_player.dart` 中 `_setDataSource`。

建议给原生初始化设置有界期限，并使超时、切集和退出能够安全终止旧初始化。不能只给 Future 加 `timeout` 就允许下一份安装：旧原生工作和迟到事件仍须隔离，避免污染新分集。沿用现有恢复预算、暂停意图和资源归属。

必要回归：原生调用不返回、调用返回但缺初始化事件、超时后迟到事件、快速多次选集、等待中退出，以及后续重试能够成功。双平台的原生事件行为仍须分别验证。

### 2. 取消应覆盖取流阶段，并能及时进入 Android 核心

**证据：取流取消缺口由定向探针确认；Android 队列影响由源码确认。** 当前 `EpisodeCancellation` 会取消媒体预取和 FFmpeg 准备，但 `_provider.resolve` 尚未返回时没有播放会话 ID，也没有独立的取流请求取消入口。关闭 session 后，探针中的解析仍在等待；直到 provider 返回，才释放迟到结果。既有迟到结果保护有效，没有复现错误播放或结果泄漏，但旧联网工作仍会继续。

位置：[`playback_session.dart:157`](../lib/platform/playback_session.dart#L157)、[`provider_client.dart:378`](../lib/platform/provider_client.dart#L378)、[`mobile_api.go:128`](../native/core/internal/app/mobile_api.go#L128)。核心单次调用的期限从进入 `MobileClient.Call` 才开始，默认最多 75 秒。

Android 的 [`GuoguoCorePlugin.kt:15`](../packages/guoguo_core/android/src/main/kotlin/com/maxduke/guoguo_core/GuoguoCorePlugin.kt#L15) 使用一个三线程池；联网工作、`cancelSearch`、`cancelCatalog`、`cancelPrefetch` 和 `release` 都经相同队列派发。当三个工作线程都被慢请求占用时，控制请求也必须等待。固定线程池的排队语义见 [Android 官方 API](https://developer.android.com/reference/java/util/concurrent/Executors#newFixedThreadPool(int))。桥接排队发生在上述 Go 期限之前，不能把 Go 的 75 秒当成整个 Flutter 调用的总上限。

建议为取流增加有身份的取消，复用已有搜索／目录的取消契约；淘汰或关闭时停止对应请求，仍被当前集使用的预取不能误取消。Android 的取消和释放应能在联网线程繁忙时及时执行，队列中的过期工作也应退出；不能以增加联网并发替代取消与总预算。保留引擎 session 隔离，不能取消整个共享客户端。

必要回归：三个受控慢请求占满线程后取消仍可执行、队列等待计入总期限、关闭和反复切集停止无主请求、预取转前台继续复用，以及新旧引擎互不影响。当前未运行 Android 原生队列的设备探针。

## 随后可收敛的重复工作

推荐页尚未采用榜单页已有的分栏目会话复用。切换真人剧／漫剧／AI 剧时，`_restoreColumn` 将 `offset` 和 `session` 重置，再立即请求首页；非当前类型的在途结果也被丢弃。见 [`recommendations_page.dart:50`](../lib/ui/recommendations_page.dart#L50) 及 `_load`。这属于可减少的请求和分页状态丢失，现有缓存仍可显示旧内容，并非空白页故障。

可在页面会话内为三种类型保留有期限的分页和进行中请求，采用榜单的状态归属思路；显式刷新仍重新建立推荐会话，过期会话不能继续提交旧游标。先补“切换后返回不重复获取新鲜首页、旧结果不覆盖当前类型、返回后续页正确”的回归。推荐接口的会话语义不同于榜单，不应仅复制五分钟 TTL。

## 大剧库性能：先确认规模，再选择改动

本轮在当前提交运行已有 `synthetic catalog and partitioned disk baseline`：每项预热一次、五次采样，数据如下。完整环境、样本及原始数值见 [探针记录](app-review-2026-10-28-probes.json)。

| 合成目录 / 收藏及历史各条数 | 目录缓存 bytes | 标题排序中位数 | 缓存保存中位数 | 读取及恢复中位数 |
| --- | ---: | ---: | ---: | ---: |
| 1,000 / 100 | 2,629,194 | 23.14 ms | 75.45 ms | 60.55 ms |
| 10,000 / 100 | 24,803,396 | 179.55 ms | 628.65 ms | 524.61 ms |
| 10,000 / 1,000 | 24,803,396 | 183.06 ms | 650.40 ms | 559.75 ms |

这是 Linux／Flutter debug／热文件缓存的合成样本，缓存保存总耗时包含后台编码和磁盘 IO，不能解释为同等长度的 UI 阻塞；读取恢复也不是完整应用启动时间。没有据此宣布回归、设备卡顿原因或优化收益。设备 UI 性能应使用真机 profile 模式量测，见 [Flutter 官方指导](https://docs.flutter.dev/perf/ui-performance)。

当前 `CatalogStore.cacheSnapshot` 包含完整目录、分类成员和分集缓存；这些集合尚无新增容量上限。搜索、发现、封面和媒体缓存已有各自边界，不能笼统声称所有缓存无界。`LibraryPage` 也已按查询输入复用排序结果，不会因每次普通通知都重新排序。

建议先取得长期浏览后的真实缓存体积、工作集、启动恢复、排序的 UI 时间及内存数据。若规模足够大，再优先处理重建缓存的工作集和大集合首次排序；淘汰须保护收藏、观看进度、导入剧库及离线可用性。当前没有依据更换数据库、播放器或全局状态框架。

## 执行顺序与验证边界

下一批优先完成初始化等待、取流取消和 Android 控制请求排队这三条关联路径，再处理推荐页状态复用。大缓存限制和进一步性能改动在目标设备／真实规模量测后决定。

设备性能复测集中于现有流程：长时间连播的首帧／切集等待、内存与临时文件回收，弱网及 Wi-Fi／蜂窝切换，PiP 和投屏返回时的进度与暂停意图。已有诊断与画面状态可用于采样；不直接移植参考项目的解码学习或自动音画修正。

本轮运行两项临时诊断用例及一项既有性能基线，均完成；前两项的成功断言用于确认缺口，**不表示缺口已修复**。临时用例和日志位于 `/tmp/guoguo-existing-audit-20261028/`，没有加入正式回归套件。未重复全量 Flutter／Go 套件、未新建 PR、未执行设备播放验收。
