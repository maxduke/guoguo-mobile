# Android 手机与电视

同一应用支持 Android 手机、Android TV 和 Google TV／电视盒子。最低 Android 7（API 24）；按 `armeabi-v7a`、`arm64-v8a` 和 `x86_64` 分别提供 APK，每台设备只需安装一个。系统报告电视模式时自动启用电视界面，普通手机和平板继续使用原布局。

## 安装与遥控器

正式版本标签的 Release 构建同时提供 iOS IPA 与固定签名的 Android APK。从 v0.20.3 起，APK 名为 `Guoguo-版本+构建号-android-架构.apk`，每个包对应 `SHA256SUMS-android-架构` 与 `build-info-android-架构.json`，记录源码提交、Go 核心摘要、签名证书指纹及架构。v0.20.2 提供的是包含三架构的通用 APK；v0.20.0／v0.20.1 的发布分别因签名恢复脚本错误、重复 Go 缓存恢复阻塞而未公开，保留原标签。

CI 分别提供 `Guoguo-Android-test-armeabi-v7a`、`Guoguo-Android-test-arm64-v8a` 和 `Guoguo-Android-test-x86_64` 附件，下载对应架构的一个即可。测试包采用与正式版相同的 AOT 编译和代码／资源缩减，应用显示为“果果 测试”，应用 ID 为 `com.maxduke.guoguo_mobile.dev`，可与正式版并存，数据分别保存。测试包使用临时调试证书签名，但不启用应用调试；不同 CI 构建之间不保证覆盖安装，已有旧测试版时可能需要先卸载“果果 测试”。正式包沿用项目固定签名。

| 包名中的架构 | 适用系统 |
| --- | --- |
| `armeabi-v7a` | 32 位 ARM Android 系统 |
| `arm64-v8a` | 64 位 ARM Android 系统 |
| `x86_64` | 64 位 Intel／AMD Android 系统 |

选择依据是 Android 系统支持的 ABI，不能只看 CPU 是否为 64 位。可用 ADB 的 `getprop ro.product.cpu.abilist` 查询；支持列表中有 `arm64-v8a` 时选 ARM64，只有 `armeabi-v7a` 时选 ARM32。不支持的架构会被 Android 安装器拒绝。每个 APK 可单独安装，不需要组合三个包。CI 上传额度不足时摘要会说明附件不可用，构建和包校验仍必须成功。

初次电视测试包为三架构 debug APK，约 333 MB，其中约 287 MB 是三套原生库，另有约 29 MB 的压缩 Dart 调试内核。分架构包不携带另外两套原生库；优化编译去掉调试内核和较大的调试引擎。安装还需要临时空间，下载的旧 APK／附件与已装正式版也会占用空间。安装完成后可删除安装文件；正式版与测试版的数据相互独立。

电视有独立的桌面启动入口与横幅。左侧为发现、追剧、下载和设置。上下键选择导航，确认键切换栏目，右键进入内容并恢复上次位置；内容左侧边界的左键或返回键回到当前栏目导航。进入详情、设置等页面后，返回回到原项目。海报与主要按钮显示焦点边框；每张海报只有一个焦点，收藏操作位于详情页。

剧库、推荐、搜索和选集使用行列导航：左右在同一行移动，右端停止；上下保留列位置，尾行不足时落到最后一项。下一行尚未挂载时会先滚动再交接焦点。选集底部可翻页，翻页聚焦新范围首集，“定位当前”定位并滚动到续看集。搜索提交后聚焦首个结果，返回详情后保留原结果位置。交互与回归范围见 [遥控器导航说明](tv-remote-navigation.md)。

播放页使用电视布局，开播后焦点位于播放／暂停按钮。方向／确认键显示控制条；隐藏控制条时左右键单次快退／快进 10 秒。控制条显示后，方向键移动到播放、进度、分集和倍速控件；进度条上的左右键调节进度，上下键离开进度条。返回先收起控制条，再按一次退出；加载中或出错时可直接返回退出。支持遥控器媒体播放、暂停、播放暂停及上一／下一集键。

电视选集和播放设置使用居中面板，选集默认聚焦当前集。更多设置中的“遥控器操作”提供按键说明，横竖屏切换和触屏手势锁定仅在手机显示。

从 0.20.3+55 的兼容测试构建起，系统识别为电视时，Flutter 启动参数请求旧版 OpenGL 渲染；手机保留自动渲染配置。该路径针对旧电视的视频纹理合成问题做设备验证，尚不能认定它修复了所有“有声无画面”。Android 9 原本已默认回退旧版 OpenGL，该版本的行为可能不变；Android 10 及以上的变化取决于设备是否原本启用了 Impeller。

遇到异常时，可打开播放页“更多播放设置 → 画面状态”，查看应用构建号、型号、Android API、渲染配置，以及打开面板时播放器的初始化、尺寸和封面状态。面板支持遥控器逐行浏览与复制，不包含播放 URL、密钥或异常原文。这里的渲染配置是启动请求，尺寸和初始化也不能证明电视已显示视频。

0.20.3+57 将站源清晰度档位、播放器报告的视频尺寸、Flutter 应用画布的物理尺寸、Android 屏幕输出模式和画面缩放方式分开显示。电视设置为 1080P 或源档位写着 1080P，不能单独证明整个显示链路没有缩放，也不代表视频细节或码率。红果实流抽查与验收边界见 [画质核对](tv-quality-2026-10-26.md)。

## 本地构建

使用与 CI 相同的 Flutter、Go、JDK 17、Android SDK 36、Build Tools 36.0.0 和 NDK 28.2.13676358。先配置 `ANDROID_HOME` 及 Flutter 的 Android SDK 路径。

```bash
python3 scripts/prepare_player.py
flutter pub get
scripts/setup_core.sh
scripts/build_core.sh android
GUOGUO_ANDROID_PREVIEW=true flutter build apk --release --split-per-abi --no-pub
```

Go 桥接 AAR 在插件构建时解包为 Java bridge 与 JNI 库，避免新版 Android Gradle 插件拒绝直接 AAR 依赖。AAR 生成物不提交到仓库。

上述命令生成优化的独立测试包，不需要正式签名。需要开发调试时仍可使用 `flutter build apk --debug --no-pub`，但不作为空间紧张电视的测试安装包。

正式构建使用 `android/key.properties` 的 `storeFile`、`storePassword`、`keyAlias`、`keyPassword`，或对应环境变量 `GUOGUO_ANDROID_KEYSTORE`、`GUOGUO_ANDROID_STORE_PASSWORD`、`GUOGUO_ANDROID_KEY_ALIAS`、`GUOGUO_ANDROID_KEY_PASSWORD`；签名缺失时明确拒绝正式构建。随后运行 `GUOGUO_ANDROID_PREVIEW=false flutter build apk --release --split-per-abi --no-pub`。分架构 APK 保持 `pubspec.yaml` 的 build number，防止 ABI 偏移造成之后更新被判为降级。

包检查示例（`GITHUB_SHA` 须指向实际源码提交）：

```bash
python3 scripts/android_package.py --split-per-abi \
  --apk build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk \
        build/app/outputs/flutter-apk/app-arm64-v8a-release.apk \
        build/app/outputs/flutter-apk/app-x86_64-release.apk \
  --mode preview --build-tools "$ANDROID_HOME/build-tools/36.0.0"
```

正式包将 `--mode preview` 改为 `--mode release`，并配置环境变量 `ANDROID_CERTIFICATE_SHA256` 与项目固定证书指纹一致。脚本先验证三个包完整、每包只含指定 ABI、版本／包名、TV 启动入口、签名、AOT 原生库和 64 位 ELF 的 16 KB 对齐，再输出各包、元数据及校验和；混入其它 ABI、旧核心、调试内核或缺少架构会失败。

## GitHub 签名配置

仓库 Secrets 使用 `ANDROID_KEYSTORE_BASE64`、`ANDROID_KEYSTORE_PASSWORD`、`ANDROID_KEY_ALIAS` 和 `ANDROID_KEY_PASSWORD`。Variables 使用 `ANDROID_RELEASE_ENABLED=true` 和公开的 `ANDROID_CERTIFICATE_SHA256`。构建时仅在 runner 临时目录恢复密钥，发布前必须通过验证；任务最后清除临时密钥。CI／PR 的 preview 和 debug 构建不读取正式签名。

首次建立的签名需在仓库外另行私密备份，包括 keystore 和对应口令；后续版本沿用同一密钥。不要将密钥或 `key.properties` 提交到 Git。

## 验收边界

APK 构建、签名、ABI、16 KB 静态校验以及 Flutter 遥控器测试不能证明所有盒子的硬件解码能力。真机至少检查：电视桌面启动；方向／确认／返回完成浏览、搜索和选集；播放、暂停、进度与相邻集；本地下载播放；切后台／回前台；退出后重新启动；持续播放及换集。手机还需检查画中画、通知权限和后台下载。

用户已确认兼容包在原电视上能正常出画面、遥控器操作已改善，并在 0.20.3+57 复测后反馈基本正常，同意合并发布。该反馈不能推断其它型号或长时间连播均已通过；主机也未取得模拟器视频合成验收结果。具体结果见[Android 首次交付记录](app-improvements-2026-10-25.md)及[电视播放页修复记录](tv-player-repair-2026-10-25.md)。
