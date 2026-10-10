# 当前状态与异步边界

产品行为见 [当前规格](product-spec.md)，本页只记录工程职责与必须保持的契约。

## 状态归属

| 对象 | 归属 |
| --- | --- |
| AppStore | 装配、离线、诊断、分区持久化与保存错误；不转发所有子状态通知。 |
| PreferencesStore | 主题、网络、播放偏好；主题单独通知应用外壳。 |
| CatalogStore | 来源目录/分类、详情/分集、搜索及栏目缓存、请求去重/游标、资料合并。 |
| SourceDiagnostics / ObservedProviderClient | 固定字段的本次运行 API 诊断及独立通知；不写入目录缓存或用户记录。 |
| RecordStore | 收藏、历史、已读基准、提醒、备份和事务；progress 单独通知观看位置。 |
| HomePage | 稳定的导航和 IndexedStack；独立 Discovery/Personal/Downloads 页面保留自身状态。 |
| LibraryPage / SearchPage | 完整剧库筛选与滚动 / 独立搜索会话与滚动；CatalogSearchController 管输入、联想、请求代次及取消。 |
| DownloadsPage / DownloadStore | 当前视图、筛选、选择、播放意图 / 清单、原生任务、恢复、处理、文件与容量统计。 |

页面只订阅所需状态。正常进度保存不重建目录和 MaterialApp；收藏更新限于相应卡片，主题变化使用专用通知。窗口切换保留实际页面 State 和位置。

## 站源与查询边界

现有 ProviderOperations 将目录、分类、推荐/榜单、搜索、详情、分集、播放及下载计划解析为明确类型。完整校验元数据和来源身份后再安装内容、推进游标或保存缓存；错误和缓存保存失败分开，不能因保存失败重复请求已安装的页。

解析后的标签、清晰度、章节列表与顶层 raw/headers 保持只读副本，避免延迟类型转换污染状态。Episode.raw 保留完整站源字段与凭据，真实集号与原始队列位置不混用。下载计划的安全名称、唯一资源、输入、URL、编码、headers 和 flags 在创建目录或取消旧任务前验证；恢复继续比较内容键、清单/密钥字节及完成资源身份。

搜索进度须匹配来源/查询，请求代次与拥有者继续归会话控制器；切换输入/来源或退出取消旧轮次。自然排序的标题片段仅在一次排序内复用，查询词仅规范化一次；没有跨页面可失效的索引或查询状态。

红果分季续搜令牌绑定原查询和下一页，核心快照只读，各请求修改独立副本；不按搜索词共享可变游标。未完成红果搜索的磁盘缓存只能提供资料，重新联网取得令牌。同系列检查保留三页/二十秒预算及完整结果才建立提醒基准的契约。具体边界见 [分季续搜](hongguo-season-continuation.md)。

剧库预取只用于有明确页码的十六个分类源；当前来源、分类、slice、页码和请求所有者一致才安装。聚合游标目录继续按需加载。页面负责 Wi-Fi/前台/路由和停稳预算，CatalogStore 负责取消、安装与退避，核心负责低优先级请求、八秒总时限及按请求身份取消。具体约束见 [站源诊断与预取](source-diagnostics-prefetch.md)。

## 提交与页面生命周期

记录事务与记录文件写入共用串行操作队列，入队后取快照；候选备份落盘成功后才安装。失败保留原状态，已接受的保存可以在关闭后完成，但不再通知已关闭页面。相同资料、已读集合和进度跳过冗余保存，已发生保存错误时仍允许重试。

记录与可重建缓存拥有独立文件和写队列；缓存、网络请求不占用记录事务。StorePersistence 保留最小写入接口。备份 v2、交换格式和全新安装范围见产品规格。

异步续播、下载播放、弹窗、文件操作固定当前对象与代次。标签/来源切换、依赖替换、页面退出或覆盖使旧意图失效，返回也不复活旧跳转。DownloadsPage 自己处理路由覆盖取消，Home 只传所选标签状态，自己的筛选弹窗返回仍能应用筛选。分享准备后重新取得当前窗口锚点并检查当前路由。

详情、播放和下载弹窗使用操作时的只读分集快照；刷新资料不能改变已选队列。续播按 ID 计算，完成状态仅由确认播放结束建立；离线自动前进只接受原始位置相邻。

## 播放与资源

| 控制器 | 归属 |
| --- | --- |
| PlaybackSessionController | 资源准备、预取接管、轮次、安装与释放。 |
| PlaybackLifecycleController | 前台/后台/PiP、暂停意图与生命周期计时。 |
| PlaybackProgressController | 分集身份、真实集号、完成状态、十秒周期提交；切集/后台/退出/交接立即提交。 |
| PlaybackRecoveryController | 有限恢复、异步有效性与每分集预算。 |

PlayerPage 协调界面和原生事件，手势、控件、弹层各有独立归属。取消手势不提交旧进度/速度，旧菜单不能操作新媒体。AirPlay、Cast/DLNA 保留独立会话与手机交接；停止设备并确认资源不再使用后才释放文件。

启动先读取本地记录/清单并展示，再分别初始化核心、恢复下载和检查网络；失败按组件重试，不清空页面。只允许共享核心初始化与协议验证完成后的请求，迟到网络检查不能覆盖较新的监听状态。

空间统计在清单载入后执行，并按实际可测范围报告未知值；进度事件不扫描磁盘。清理遵守记录/缓存边界和活跃媒体资源归属，不扫父目录、不删除用户记录。容量和设备性能限制见 [基线](performance-baseline.md)。

## 回归入口

- `record_transactions_test`、`partitioned_store_test`、`scoped_store_test`：提交、分区与通知。
- `provider_contract_test`、`catalog_retry_test`、`catalog_upgrade_test`：解析、身份、游标与查询语义。
- `catalog_search_state_test`、`download_page_state_test`、`adaptive_layout_test`：拥有者、退出、覆盖和窗口保留。
- `download_recovery_test`：签名刷新、无效计划、完成文件与原任务保护。
- `playback_session_test`、`playback_progress_test`、`playback_coordination_test`、`player_cast_handoff_test`：媒体、生命周期、进度和交接。

设备验证另见 [清单](ios-device-checklist.md)，自动化不代替实际设备结果。
