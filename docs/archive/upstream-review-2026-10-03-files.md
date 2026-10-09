> 历史记录：保留当时的设计、实现和验证范围，不代表当前行为。参见 [当前产品规格](../product-spec.md)。

# 上游变更文件覆盖清单（2026-10-03）

配套 [吸收评估](upstream-review-2026-10-03.md)。固定范围 `ffddc0b..5999e469e1281e55dcf603c980f83cd0ba00206d`，由 Git 文件差异生成，不依赖 README 功能列表。

共 157 个路径，其中 24 个二进制品牌资源；133 个文本文件。`后续` 列说明相对已核对的 `ad67468`（与 9 月 28 日 ZIP 核心对应）是否还发生变化：有 141 个路径。`仅首轮范围` 不代表该文件已原样移植，例如弹幕和 TV 在前次已决定暂缓；需结合主报告和本地源码判断。

分类覆盖用于确保范围不漏项，不等于全仓逐行安全审计、动态功能验证或二进制视觉验收。上游路径链接固定到已审查提交，私有仓库需要登录。

| 分类 | 文件数 |
| --- | ---: |
| 上游导入 | 4 |
| 说明 | 1 |
| 构建校验 | 8 |
| 品牌资源 | 27 |
| Android 渲染 | 3 |
| 设备验证 | 8 |
| 版本显示 | 1 |
| TV 与界面联动 | 16 |
| 搜索 | 7 |
| 核心集成 | 9 |
| 弹幕 | 6 |
| 触摸交互 | 1 |
| 错误与站源界面 | 4 |
| 主界面集成 | 2 |
| 剧库互通 | 7 |
| 持久化 | 4 |
| 来源模型 | 1 |
| 播放器 | 7 |
| 设置与用户 | 2 |
| 榜单 | 7 |
| 站源与资料 | 19 |
| 媒体传输 | 9 |
| 依赖 | 4 |

| 上游路径 | + / − | 后续 | 分类 | 处理建议 |
| --- | ---: | --- | --- | --- |
| [.github/upstream.json](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/.github/upstream.json) | 4 / 4 | 有后续变化 | 上游导入 | 借鉴来源锁定和签名 URL 处理；不直接套用整仓导入 |
| [.github/workflows/update-upstream.yml](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/.github/workflows/update-upstream.yml) | 8 / 1 | 有后续变化 | 上游导入 | 借鉴来源锁定和签名 URL 处理；不直接套用整仓导入 |
| [README.md](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/README.md) | 13 / 6 | 有后续变化 | 说明 | 对照源码，记录滞后描述；不覆盖本地说明 |
| [android/app/build.gradle.kts](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/android/app/build.gradle.kts) | 40 / 0 | 有后续变化 | 构建校验 | 适配原生库身份校验；保留 gomobile 和现有发行流程 |
| [android/app/src/main/AndroidManifest.xml](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/android/app/src/main/AndroidManifest.xml) | 1 / 1 | 有后续变化 | 品牌资源 | 保留本项目品牌；清单变化仅图标引用 |
| [android/app/src/main/kotlin/com/duanju/duanju_app/MainActivity.kt](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/android/app/src/main/kotlin/com/duanju/duanju_app/MainActivity.kt) | 1 / 0 | 有后续变化 | Android 渲染 | 延期，依赖 media_kit/mpv，先修复生命周期失败路径 |
| [android/app/src/main/kotlin/com/duanju/duanju_app/VideoSurfaceHost.kt](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/android/app/src/main/kotlin/com/duanju/duanju_app/VideoSurfaceHost.kt) | 190 / 0 | 有后续变化 | Android 渲染 | 延期，依赖 media_kit/mpv，先修复生命周期失败路径 |
| [android/app/src/main/res/drawable-xhdpi/tv_banner.png](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/android/app/src/main/res/drawable-xhdpi/tv_banner.png) | - / - | 有后续变化 | 品牌资源 | 保留本项目品牌；清单变化仅图标引用 |
| [android/app/src/main/res/drawable-xhdpi/tv_banner_all_sources.png](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/android/app/src/main/res/drawable-xhdpi/tv_banner_all_sources.png) | - / - | 有后续变化 | 品牌资源 | 保留本项目品牌；清单变化仅图标引用 |
| [android/app/src/main/res/drawable/app_icon.xml](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/android/app/src/main/res/drawable/app_icon.xml) | 2 / 6 | 有后续变化 | 品牌资源 | 保留本项目品牌；清单变化仅图标引用 |
| [android/app/src/main/res/mipmap-hdpi/ic_launcher.png](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/android/app/src/main/res/mipmap-hdpi/ic_launcher.png) | - / - | 有后续变化 | 品牌资源 | 保留本项目品牌；清单变化仅图标引用 |
| [android/app/src/main/res/mipmap-mdpi/ic_launcher.png](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/android/app/src/main/res/mipmap-mdpi/ic_launcher.png) | - / - | 有后续变化 | 品牌资源 | 保留本项目品牌；清单变化仅图标引用 |
| [android/app/src/main/res/mipmap-xhdpi/ic_launcher.png](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/android/app/src/main/res/mipmap-xhdpi/ic_launcher.png) | - / - | 有后续变化 | 品牌资源 | 保留本项目品牌；清单变化仅图标引用 |
| [android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png) | - / - | 有后续变化 | 品牌资源 | 保留本项目品牌；清单变化仅图标引用 |
| [android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png) | - / - | 有后续变化 | 品牌资源 | 保留本项目品牌；清单变化仅图标引用 |
| [assets/branding/app_icon.png](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/assets/branding/app_icon.png) | - / - | 有后续变化 | 品牌资源 | 保留本项目品牌；清单变化仅图标引用 |
| [integration_test/playback_performance_test.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/integration_test/playback_performance_test.dart) | 197 / 0 | 有后续变化 | 设备验证 | 借鉴测试脚手架；不能视为真机通过 |
| [integration_test/playback_test.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/integration_test/playback_test.dart) | 3 / 0 | 有后续变化 | 设备验证 | 借鉴测试脚手架；不能视为真机通过 |
| [integration_test/player_entry_test.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/integration_test/player_entry_test.dart) | 208 / 0 | 有后续变化 | 设备验证 | 借鉴测试脚手架；不能视为真机通过 |
| [integration_test/startup_test.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/integration_test/startup_test.dart) | 43 / 0 | 有后续变化 | 设备验证 | 借鉴测试脚手架；不能视为真机通过 |
| [integration_test/surface_lifecycle_test.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/integration_test/surface_lifecycle_test.dart) | 138 / 0 | 有后续变化 | 设备验证 | 借鉴测试脚手架；不能视为真机通过 |
| [ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png) | - / - | 有后续变化 | 品牌资源 | 保留本项目品牌；清单变化仅图标引用 |
| [ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@1x.png](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@1x.png) | - / - | 有后续变化 | 品牌资源 | 保留本项目品牌；清单变化仅图标引用 |
| [ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@2x.png](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@2x.png) | - / - | 有后续变化 | 品牌资源 | 保留本项目品牌；清单变化仅图标引用 |
| [ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@3x.png](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@3x.png) | - / - | 有后续变化 | 品牌资源 | 保留本项目品牌；清单变化仅图标引用 |
| [ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@1x.png](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@1x.png) | - / - | 有后续变化 | 品牌资源 | 保留本项目品牌；清单变化仅图标引用 |
| [ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@2x.png](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@2x.png) | - / - | 有后续变化 | 品牌资源 | 保留本项目品牌；清单变化仅图标引用 |
| [ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@3x.png](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@3x.png) | - / - | 有后续变化 | 品牌资源 | 保留本项目品牌；清单变化仅图标引用 |
| [ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@1x.png](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@1x.png) | - / - | 有后续变化 | 品牌资源 | 保留本项目品牌；清单变化仅图标引用 |
| [ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@2x.png](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@2x.png) | - / - | 有后续变化 | 品牌资源 | 保留本项目品牌；清单变化仅图标引用 |
| [ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@3x.png](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@3x.png) | - / - | 有后续变化 | 品牌资源 | 保留本项目品牌；清单变化仅图标引用 |
| [ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-60x60@2x.png](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-60x60@2x.png) | - / - | 有后续变化 | 品牌资源 | 保留本项目品牌；清单变化仅图标引用 |
| [ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-60x60@3x.png](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-60x60@3x.png) | - / - | 有后续变化 | 品牌资源 | 保留本项目品牌；清单变化仅图标引用 |
| [ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-76x76@1x.png](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-76x76@1x.png) | - / - | 有后续变化 | 品牌资源 | 保留本项目品牌；清单变化仅图标引用 |
| [ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-76x76@2x.png](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-76x76@2x.png) | - / - | 有后续变化 | 品牌资源 | 保留本项目品牌；清单变化仅图标引用 |
| [ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-83.5x83.5@2x.png](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-83.5x83.5@2x.png) | - / - | 有后续变化 | 品牌资源 | 保留本项目品牌；清单变化仅图标引用 |
| [lib/android_video_surface.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/lib/android_video_surface.dart) | 207 / 0 | 有后续变化 | Android 渲染 | 延期，依赖 media_kit/mpv，先修复生命周期失败路径 |
| [lib/app_layout.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/lib/app_layout.dart) | 1 / 1 | 有后续变化 | 版本显示 | 不复制滞后的显示版本常量 |
| [lib/batch_download_screen.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/lib/batch_download_screen.dart) | 2 / 0 | 仅首轮范围 | TV 与界面联动 | 焦点导航延期；安全区/历史通知/播放路由按本地能力适配 |
| [lib/catalog_browser.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/lib/catalog_browser.dart) | 19 / 0 | 有后续变化 | 搜索 | 优先适配渐进结果/缓存/缺项兼容，限制补季开销 |
| [lib/catalog_filters.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/lib/catalog_filters.dart) | 55 / 21 | 仅首轮范围 | TV 与界面联动 | 焦点导航延期；安全区/历史通知/播放路由按本地能力适配 |
| [lib/catalog_sort.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/lib/catalog_sort.dart) | 25 / 0 | 有后续变化 | 搜索 | 优先适配渐进结果/缓存/缺项兼容，限制补季开销 |
| [lib/catalog_sort_sheet.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/lib/catalog_sort_sheet.dart) | 13 / 1 | 有后续变化 | TV 与界面联动 | 焦点导航延期；安全区/历史通知/播放路由按本地能力适配 |
| [lib/core_bridge.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/lib/core_bridge.dart) | 101 / 12 | 有后续变化 | 核心集成 | 拆出移动协议、保存及源能力适配；不替换原生核心 |
| [lib/danmaku_controller.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/lib/danmaku_controller.dart) | 35 / 11 | 有后续变化 | 弹幕 | 延期；先有移动接口和时间轴，再吸收表情/刷新优化 |
| [lib/danmaku_models.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/lib/danmaku_models.dart) | 24 / 1 | 仅首轮范围 | 弹幕 | 延期；先有移动接口和时间轴，再吸收表情/刷新优化 |
| [lib/danmaku_overlay.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/lib/danmaku_overlay.dart) | 1 / 2 | 仅首轮范围 | 弹幕 | 延期；先有移动接口和时间轴，再吸收表情/刷新优化 |
| [lib/detail_screen.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/lib/detail_screen.dart) | 12 / 2 | 有后续变化 | TV 与界面联动 | 焦点导航延期；安全区/历史通知/播放路由按本地能力适配 |
| [lib/download_picker.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/lib/download_picker.dart) | 7 / 0 | 仅首轮范围 | TV 与界面联动 | 焦点导航延期；安全区/历史通知/播放路由按本地能力适配 |
| [lib/downloads_screen.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/lib/downloads_screen.dart) | 481 / 23 | 有后续变化 | TV 与界面联动 | 焦点导航延期；安全区/历史通知/播放路由按本地能力适配 |
| [lib/drama_actions.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/lib/drama_actions.dart) | 16 / 6 | 有后续变化 | 触摸交互 | 借鉴 48 点触摸范围，保留视觉设计 |
| [lib/episode_browser.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/lib/episode_browser.dart) | 6 / 0 | 仅首轮范围 | TV 与界面联动 | 焦点导航延期；安全区/历史通知/播放路由按本地能力适配 |
| [lib/error_boundary.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/lib/error_boundary.dart) | 98 / 0 | 有后续变化 | 错误与站源界面 | 有界诊断和兜底；保留聚合站源语义，TV 部分延期 |
| [lib/home_screen.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/lib/home_screen.dart) | 181 / 38 | 有后续变化 | 主界面集成 | 适配搜索/通知/错误兜底；TV 焦点与多用户不直接移植 |
| [lib/lan_controller.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/lib/lan_controller.dart) | 2 / 0 | 有后续变化 | TV 与界面联动 | 焦点导航延期；安全区/历史通知/播放路由按本地能力适配 |
| [lib/lan_screen.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/lib/lan_screen.dart) | 14 / 1 | 有后续变化 | TV 与界面联动 | 焦点导航延期；安全区/历史通知/播放路由按本地能力适配 |
| [lib/library_transfer.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/lib/library_transfer.dart) | 97 / 0 | 有后续变化 | 剧库互通 | 独立适配格式、身份映射和大小限制；不搬桌面 xz 进程 |
| [lib/library_transfer_actions.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/lib/library_transfer_actions.dart) | 72 / 0 | 有后续变化 | 剧库互通 | 独立适配格式、身份映射和大小限制；不搬桌面 xz 进程 |
| [lib/local_encoder.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/lib/local_encoder.dart) | 127 / 0 | 有后续变化 | 持久化 | 吸收通知/编码优化；保留本地数据模型和原子保存 |
| [lib/local_media_screen.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/lib/local_media_screen.dart) | 8 / 2 | 有后续变化 | TV 与界面联动 | 焦点导航延期；安全区/历史通知/播放路由按本地能力适配 |
| [lib/local_snapshot.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/lib/local_snapshot.dart) | 4 / 1 | 有后续变化 | 持久化 | 吸收通知/编码优化；保留本地数据模型和原子保存 |
| [lib/local_store.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/lib/local_store.dart) | 60 / 12 | 有后续变化 | 持久化 | 吸收通知/编码优化；保留本地数据模型和原子保存 |
| [lib/local_store_sync.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/lib/local_store_sync.dart) | 9 / 3 | 有后续变化 | 持久化 | 吸收通知/编码优化；保留本地数据模型和原子保存 |
| [lib/main.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/lib/main.dart) | 12 / 3 | 有后续变化 | 主界面集成 | 适配搜索/通知/错误兜底；TV 焦点与多用户不直接移植 |
| [lib/merge_queue_screen.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/lib/merge_queue_screen.dart) | 2 / 0 | 仅首轮范围 | TV 与界面联动 | 焦点导航延期；安全区/历史通知/播放路由按本地能力适配 |
| [lib/models.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/lib/models.dart) | 32 / 1 | 有后续变化 | 来源模型 | 保留十八源；适配搜索能力，不能同步删枚举 |
| [lib/playback_launch_screen.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/lib/playback_launch_screen.dart) | 10 / 4 | 有后续变化 | 播放器 | 选择性适配控件/推荐/节流；手势与后端变更分开决策 |
| [lib/player_controls.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/lib/player_controls.dart) | 133 / 45 | 有后续变化 | 播放器 | 选择性适配控件/推荐/节流；手势与后端变更分开决策 |
| [lib/player_interactions.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/lib/player_interactions.dart) | 74 / 0 | 有后续变化 | 播放器 | 选择性适配控件/推荐/节流；手势与后端变更分开决策 |
| [lib/player_route.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/lib/player_route.dart) | 9 / 0 | 有后续变化 | 播放器 | 选择性适配控件/推荐/节流；手势与后端变更分开决策 |
| [lib/player_screen.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/lib/player_screen.dart) | 490 / 45 | 有后续变化 | 播放器 | 选择性适配控件/推荐/节流；手势与后端变更分开决策 |
| [lib/profiles_screen.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/lib/profiles_screen.dart) | 66 / 1 | 有后续变化 | 设置与用户 | 库互通单独适配；TV/多用户延期，启动登录非本次新增核心 |
| [lib/ranking_models.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/lib/ranking_models.dart) | 14 / 18 | 有后续变化 | 榜单 | 扩展来源与推荐/目录入口，不能伪装官方热度排名 |
| [lib/rankings_screen.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/lib/rankings_screen.dart) | 135 / 99 | 有后续变化 | 榜单 | 扩展来源与推荐/目录入口，不能伪装官方热度排名 |
| [lib/recommendations_screen.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/lib/recommendations_screen.dart) | 65 / 2 | 仅首轮范围 | TV 与界面联动 | 焦点导航延期；安全区/历史通知/播放路由按本地能力适配 |
| [lib/remote_widgets.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/lib/remote_widgets.dart) | 573 / 5 | 仅首轮范围 | TV 与界面联动 | 焦点导航延期；安全区/历史通知/播放路由按本地能力适配 |
| [lib/resource_settings_screen.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/lib/resource_settings_screen.dart) | 2 / 0 | 仅首轮范围 | TV 与界面联动 | 焦点导航延期；安全区/历史通知/播放路由按本地能力适配 |
| [lib/saved_library.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/lib/saved_library.dart) | 29 / 0 | 有后续变化 | TV 与界面联动 | 焦点导航延期；安全区/历史通知/播放路由按本地能力适配 |
| [lib/screen_awake.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/lib/screen_awake.dart) | 36 / 0 | 有后续变化 | 播放器 | 选择性适配控件/推荐/节流；手势与后端变更分开决策 |
| [lib/search_cache.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/lib/search_cache.dart) | 220 / 0 | 有后续变化 | 搜索 | 优先适配渐进结果/缓存/缺项兼容，限制补季开销 |
| [lib/settings_screen.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/lib/settings_screen.dart) | 287 / 22 | 有后续变化 | 设置与用户 | 库互通单独适配；TV/多用户延期，启动登录非本次新增核心 |
| [lib/sources_screen.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/lib/sources_screen.dart) | 26 / 26 | 有后续变化 | 错误与站源界面 | 有界诊断和兜底；保留聚合站源语义，TV 部分延期 |
| [lib/television_controls.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/lib/television_controls.dart) | 39 / 4 | 有后续变化 | TV 与界面联动 | 焦点导航延期；安全区/历史通知/播放路由按本地能力适配 |
| [native/core/app_build.go](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/native/core/app_build.go) | 1 / 0 | 有后续变化 | 核心集成 | 拆出移动协议、保存及源能力适配；不替换原生核心 |
| [native/core/app_cache_test.go](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/native/core/app_cache_test.go) | 12 / 12 | 有后续变化 | 核心集成 | 拆出移动协议、保存及源能力适配；不替换原生核心 |
| [native/core/app_catalog_cache.go](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/native/core/app_catalog_cache.go) | 8 / 0 | 有后续变化 | 核心集成 | 拆出移动协议、保存及源能力适配；不替换原生核心 |
| [native/core/app_catalog_defer_test.go](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/native/core/app_catalog_defer_test.go) | 56 / 0 | 有后续变化 | 核心集成 | 拆出移动协议、保存及源能力适配；不替换原生核心 |
| [native/core/app_categories.go](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/native/core/app_categories.go) | 19 / 2 | 有后续变化 | 站源与资料 | 按报告 A/C/D 选择性移植，保留本地分页、ID、凭证及旧源 |
| [native/core/app_cover_metadata.go](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/native/core/app_cover_metadata.go) | 76 / 2 | 有后续变化 | 站源与资料 | 按报告 A/C/D 选择性移植，保留本地分页、ID、凭证及旧源 |
| [native/core/app_cover_repair.go](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/native/core/app_cover_repair.go) | 4 / 1 | 有后续变化 | 站源与资料 | 按报告 A/C/D 选择性移植，保留本地分页、ID、凭证及旧源 |
| [native/core/app_discovery_test.go](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/native/core/app_discovery_test.go) | 3 / 3 | 有后续变化 | 核心集成 | 拆出移动协议、保存及源能力适配；不替换原生核心 |
| [native/core/app_library_exchange.go](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/native/core/app_library_exchange.go) | 322 / 0 | 有后续变化 | 剧库互通 | 独立适配格式、身份映射和大小限制；不搬桌面 xz 进程 |
| [native/core/app_library_exchange_test.go](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/native/core/app_library_exchange_test.go) | 166 / 0 | 有后续变化 | 剧库互通 | 独立适配格式、身份映射和大小限制；不搬桌面 xz 进程 |
| [native/core/app_runtime.go](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/native/core/app_runtime.go) | 130 / 26 | 有后续变化 | 核心集成 | 拆出移动协议、保存及源能力适配；不替换原生核心 |
| [native/core/app_source_health.go](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/native/core/app_source_health.go) | 1 / 1 | 有后续变化 | 核心集成 | 拆出移动协议、保存及源能力适配；不替换原生核心 |
| [native/core/app_sources.go](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/native/core/app_sources.go) | 66 / 16 | 有后续变化 | 核心集成 | 拆出移动协议、保存及源能力适配；不替换原生核心 |
| [native/core/app_stream.go](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/native/core/app_stream.go) | 264 / 53 | 有后续变化 | 媒体传输 | 适配嗅探/有限回退和契约测试；排除 TLS 放宽与盲猜域名 |
| [native/core/app_stream_test.go](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/native/core/app_stream_test.go) | 126 / 0 | 有后续变化 | 媒体传输 | 适配嗅探/有限回退和契约测试；排除 TLS 放宽与盲猜域名 |
| [native/core/danmaku_emoji.go](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/native/core/danmaku_emoji.go) | 107 / 0 | 仅首轮范围 | 弹幕 | 延期；先有移动接口和时间轴，再吸收表情/刷新优化 |
| [native/core/danmaku_emoji_test.go](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/native/core/danmaku_emoji_test.go) | 81 / 0 | 仅首轮范围 | 弹幕 | 延期；先有移动接口和时间轴，再吸收表情/刷新优化 |
| [native/core/library_exchange_xz.go](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/native/core/library_exchange_xz.go) | 103 / 0 | 有后续变化 | 剧库互通 | 独立适配格式、身份映射和大小限制；不搬桌面 xz 进程 |
| [native/core/library_exchange_xz_test.go](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/native/core/library_exchange_xz_test.go) | 191 / 0 | 有后续变化 | 剧库互通 | 独立适配格式、身份映射和大小限制；不搬桌面 xz 进程 |
| [native/core/media_transport_parity_test.go](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/native/core/media_transport_parity_test.go) | 151 / 0 | 有后续变化 | 媒体传输 | 适配嗅探/有限回退和契约测试；排除 TLS 放宽与盲猜域名 |
| [native/core/network_browser.go](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/native/core/network_browser.go) | 27 / 5 | 有后续变化 | 媒体传输 | 适配嗅探/有限回退和契约测试；排除 TLS 放宽与盲猜域名 |
| [native/core/network_cdn_test.go](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/native/core/network_cdn_test.go) | 4 / 4 | 有后续变化 | 媒体传输 | 适配嗅探/有限回退和契约测试；排除 TLS 放宽与盲猜域名 |
| [native/core/network_media.go](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/native/core/network_media.go) | 107 / 1 | 有后续变化 | 媒体传输 | 适配嗅探/有限回退和契约测试；排除 TLS 放宽与盲猜域名 |
| [native/core/network_media_credentials.go](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/native/core/network_media_credentials.go) | 10 / 1 | 有后续变化 | 媒体传输 | 适配嗅探/有限回退和契约测试；排除 TLS 放宽与盲猜域名 |
| [native/core/network_media_fallback.go](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/native/core/network_media_fallback.go) | 171 / 0 | 有后续变化 | 媒体传输 | 适配嗅探/有限回退和契约测试；排除 TLS 放宽与盲猜域名 |
| [native/core/network_media_test.go](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/native/core/network_media_test.go) | 87 / 0 | 有后续变化 | 媒体传输 | 适配嗅探/有限回退和契约测试；排除 TLS 放宽与盲猜域名 |
| [native/core/provider_detail_metadata.go](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/native/core/provider_detail_metadata.go) | 82 / 4 | 有后续变化 | 站源与资料 | 按报告 A/C/D 选择性移植，保留本地分页、ID、凭证及旧源 |
| [native/core/provider_dsd_catalog.go](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/native/core/provider_dsd_catalog.go) | 5 / 0 | 有后续变化 | 站源与资料 | 按报告 A/C/D 选择性移植，保留本地分页、ID、凭证及旧源 |
| [native/core/provider_duanju.go](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/native/core/provider_duanju.go) | 325 / 0 | 有后续变化 | 站源与资料 | 按报告 A/C/D 选择性移植，保留本地分页、ID、凭证及旧源 |
| [native/core/provider_duanju_api.go](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/native/core/provider_duanju_api.go) | 498 / 0 | 有后续变化 | 站源与资料 | 按报告 A/C/D 选择性移植，保留本地分页、ID、凭证及旧源 |
| [native/core/provider_duanju_client.go](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/native/core/provider_duanju_client.go) | 272 / 0 | 仅首轮范围 | 站源与资料 | 按报告 A/C/D 选择性移植，保留本地分页、ID、凭证及旧源 |
| [native/core/provider_duanju_dispatch.go](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/native/core/provider_duanju_dispatch.go) | 232 / 0 | 有后续变化 | 站源与资料 | 按报告 A/C/D 选择性移植，保留本地分页、ID、凭证及旧源 |
| [native/core/provider_duanju_heguo.go](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/native/core/provider_duanju_heguo.go) | 243 / 0 | 仅首轮范围 | 站源与资料 | 按报告 A/C/D 选择性移植，保留本地分页、ID、凭证及旧源 |
| [native/core/provider_duanju_key.go](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/native/core/provider_duanju_key.go) | 77 / 0 | 有后续变化 | 站源与资料 | 按报告 A/C/D 选择性移植，保留本地分页、ID、凭证及旧源 |
| [native/core/provider_duanju_maccms.go](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/native/core/provider_duanju_maccms.go) | 556 / 0 | 有后续变化 | 站源与资料 | 按报告 A/C/D 选择性移植，保留本地分页、ID、凭证及旧源 |
| [native/core/provider_duanju_sources.go](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/native/core/provider_duanju_sources.go) | 694 / 0 | 有后续变化 | 站源与资料 | 按报告 A/C/D 选择性移植，保留本地分页、ID、凭证及旧源 |
| [native/core/provider_duanju_test.go](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/native/core/provider_duanju_test.go) | 686 / 0 | 有后续变化 | 站源与资料 | 按报告 A/C/D 选择性移植，保留本地分页、ID、凭证及旧源 |
| [native/core/provider_duanju_yaguo.go](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/native/core/provider_duanju_yaguo.go) | 322 / 0 | 仅首轮范围 | 站源与资料 | 按报告 A/C/D 选择性移植，保留本地分页、ID、凭证及旧源 |
| [native/core/provider_hongguo.go](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/native/core/provider_hongguo.go) | 5 / 0 | 有后续变化 | 站源与资料 | 按报告 A/C/D 选择性移植，保留本地分页、ID、凭证及旧源 |
| [native/core/provider_hongguo_search.go](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/native/core/provider_hongguo_search.go) | 25 / 3 | 有后续变化 | 搜索 | 优先适配渐进结果/缓存/缺项兼容，限制补季开销 |
| [native/core/provider_hongguo_search_seasons.go](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/native/core/provider_hongguo_search_seasons.go) | 82 / 5 | 有后续变化 | 搜索 | 优先适配渐进结果/缓存/缺项兼容，限制补季开销 |
| [native/core/provider_huangguo.go](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/native/core/provider_huangguo.go) | 552 / 92 | 有后续变化 | 站源与资料 | 按报告 A/C/D 选择性移植，保留本地分页、ID、凭证及旧源 |
| [native/core/provider_huangguo_search_test.go](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/native/core/provider_huangguo_search_test.go) | 181 / 0 | 有后续变化 | 站源与资料 | 按报告 A/C/D 选择性移植，保留本地分页、ID、凭证及旧源 |
| [native/core/provider_media.go](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/native/core/provider_media.go) | 55 / 14 | 有后续变化 | 站源与资料 | 按报告 A/C/D 选择性移植，保留本地分页、ID、凭证及旧源 |
| [native/core/provider_rankings.go](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/native/core/provider_rankings.go) | 35 / 2 | 有后续变化 | 榜单 | 扩展来源与推荐/目录入口，不能伪装官方热度排名 |
| [native/core/provider_rankings_duanju_test.go](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/native/core/provider_rankings_duanju_test.go) | 140 / 0 | 有后续变化 | 榜单 | 扩展来源与推荐/目录入口，不能伪装官方热度排名 |
| [native/core/provider_rankings_parse.go](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/native/core/provider_rankings_parse.go) | 2 / 2 | 有后续变化 | 榜单 | 扩展来源与推荐/目录入口，不能伪装官方热度排名 |
| [native/core/provider_rankings_test.go](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/native/core/provider_rankings_test.go) | 5 / 2 | 有后续变化 | 榜单 | 扩展来源与推荐/目录入口，不能伪装官方热度排名 |
| [native/core/ui_playback_danmaku.go](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/native/core/ui_playback_danmaku.go) | 2 / 2 | 仅首轮范围 | 弹幕 | 延期；先有移动接口和时间轴，再吸收表情/刷新优化 |
| [native/go.mod](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/native/go.mod) | 2 / 1 | 有后续变化 | 依赖 | 仅按所选功能增量引入，不覆盖锁文件 |
| [native/go.sum](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/native/go.sum) | 2 / 0 | 有后续变化 | 依赖 | 仅按所选功能增量引入，不覆盖锁文件 |
| [pubspec.lock](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/pubspec.lock) | 8 / 8 | 有后续变化 | 依赖 | 仅按所选功能增量引入，不覆盖锁文件 |
| [pubspec.yaml](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/pubspec.yaml) | 2 / 1 | 有后续变化 | 依赖 | 仅按所选功能增量引入，不覆盖锁文件 |
| [scripts/app_build.py](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/scripts/app_build.py) | 33 / 0 | 有后续变化 | 构建校验 | 适配原生库身份校验；保留 gomobile 和现有发行流程 |
| [scripts/build_native.py](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/scripts/build_native.py) | 2 / 1 | 有后续变化 | 构建校验 | 适配原生库身份校验；保留 gomobile 和现有发行流程 |
| [scripts/generate_brand_assets.py](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/scripts/generate_brand_assets.py) | 20 / 10 | 有后续变化 | 品牌资源 | 保留本项目品牌；清单变化仅图标引用 |
| [scripts/package_release.py](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/scripts/package_release.py) | 6 / 1 | 有后续变化 | 构建校验 | 适配原生库身份校验；保留 gomobile 和现有发行流程 |
| [scripts/sync_source.py](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/scripts/sync_source.py) | 1 / 0 | 有后续变化 | 构建校验 | 适配原生库身份校验；保留 gomobile 和现有发行流程 |
| [scripts/test_app_build.py](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/scripts/test_app_build.py) | 18 / 1 | 有后续变化 | 构建校验 | 适配原生库身份校验；保留 gomobile 和现有发行流程 |
| [scripts/test_sync_source.py](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/scripts/test_sync_source.py) | 1 / 0 | 有后续变化 | 构建校验 | 适配原生库身份校验；保留 gomobile 和现有发行流程 |
| [scripts/test_update_upstream.py](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/scripts/test_update_upstream.py) | 306 / 0 | 有后续变化 | 上游导入 | 借鉴来源锁定和签名 URL 处理；不直接套用整仓导入 |
| [scripts/update_upstream.py](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/scripts/update_upstream.py) | 64 / 15 | 有后续变化 | 上游导入 | 借鉴来源锁定和签名 URL 处理；不直接套用整仓导入 |
| [test/app_build_test.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/test/app_build_test.dart) | 4 / 1 | 有后续变化 | 构建校验 | 适配原生库身份校验；保留 gomobile 和现有发行流程 |
| [test/catalog_progressive_test.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/test/catalog_progressive_test.dart) | 111 / 0 | 有后续变化 | 搜索 | 优先适配渐进结果/缓存/缺项兼容，限制补季开销 |
| [test/error_boundary_test.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/test/error_boundary_test.dart) | 68 / 0 | 有后续变化 | 错误与站源界面 | 有界诊断和兜底；保留聚合站源语义，TV 部分延期 |
| [test/fixtures.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/test/fixtures.dart) | 3 / 0 | 有后续变化 | 设备验证 | 借鉴测试脚手架；不能视为真机通过 |
| [test/library_transfer_test.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/test/library_transfer_test.dart) | 113 / 0 | 有后续变化 | 剧库互通 | 独立适配格式、身份映射和大小限制；不搬桌面 xz 进程 |
| [test/player_fixtures.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/test/player_fixtures.dart) | 7 / 0 | 有后续变化 | 设备验证 | 借鉴测试脚手架；不能视为真机通过 |
| [test/player_screen_test.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/test/player_screen_test.dart) | 306 / 25 | 有后续变化 | 播放器 | 选择性适配控件/推荐/节流；手势与后端变更分开决策 |
| [test/ranking_models_test.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/test/ranking_models_test.dart) | 107 / 0 | 有后续变化 | 榜单 | 扩展来源与推荐/目录入口，不能伪装官方热度排名 |
| [test/search_cache_test.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/test/search_cache_test.dart) | 180 / 0 | 有后续变化 | 搜索 | 优先适配渐进结果/缓存/缺项兼容，限制补季开销 |
| [test/sources_screen_test.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/test/sources_screen_test.dart) | 81 / 0 | 有后续变化 | 错误与站源界面 | 有界诊断和兜底；保留聚合站源语义，TV 部分延期 |
| [test_driver/playback_performance.dart](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/test_driver/playback_performance.dart) | 23 / 0 | 有后续变化 | 设备验证 | 借鉴测试脚手架；不能视为真机通过 |
| [windows/runner/resources/app_icon.ico](https://github.com/maxduke/guoapp/blob/5999e469e1281e55dcf603c980f83cd0ba00206d/windows/runner/resources/app_icon.ico) | - / - | 有后续变化 | 品牌资源 | 保留本项目品牌；清单变化仅图标引用 |
