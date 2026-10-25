# Android 手机与电视

同一 APK 支持 Android 手机、Android TV 和 Google TV／电视盒子。最低 Android 7（API 24），包含 `armeabi-v7a`、`arm64-v8a` 和 `x86_64`。系统报告电视模式时自动启用电视界面，普通手机和平板继续使用原布局。

## 安装与遥控器

正式版本标签的 Release 构建同时提供 iOS IPA 与固定签名的 Android APK。APK 名为 `Guoguo-版本+构建号-android.apk`，使用 `SHA256SUMS-android` 校验；`build-info-android.json` 记录源码提交、Go 核心摘要、签名证书指纹及架构。首个提供此能力的版本为 v0.20.2；v0.20.0／v0.20.1 的发布分别因签名恢复脚本错误、重复 Go 缓存恢复阻塞而未公开，保留原标签。

CI 的 `Guoguo-Android-test` 为开发测试包，应用 ID 为 `com.maxduke.guoguo_mobile.dev`，可与正式版并存，数据分别保存。测试包使用临时调试签名，不保证不同构建之间覆盖安装；正式包固定签名。CI 上传额度不足时摘要会说明附件不可用，构建和包校验仍必须成功。

电视有独立的桌面启动入口与横幅。左侧为发现、追剧、下载；方向键移动焦点，确认键打开项目，返回键退出当前页面。海报和主要按钮显示焦点边框。

播放时方向／确认键显示控制条；隐藏控制条时左右键单次快退／快进 10 秒，显示后方向键移动到播放、进度、分集和倍速控件。支持遥控器媒体播放、暂停、播放暂停及上一／下一集键。进度条继续使用 Flutter 的方向键操作。

## 本地构建

使用与 CI 相同的 Flutter、Go、JDK 17、Android SDK 36、Build Tools 36.0.0 和 NDK 28.2.13676358。先配置 `ANDROID_HOME` 及 Flutter 的 Android SDK 路径。

```bash
python3 scripts/prepare_player.py
flutter pub get
scripts/setup_core.sh
scripts/build_core.sh android
flutter build apk --debug --no-pub
```

Go 桥接 AAR 在插件构建时解包为 Java bridge 与 JNI 库，避免新版 Android Gradle 插件拒绝直接 AAR 依赖。AAR 生成物不提交到仓库。

正式构建使用 `android/key.properties` 的 `storeFile`、`storePassword`、`keyAlias`、`keyPassword`，或对应环境变量 `GUOGUO_ANDROID_KEYSTORE`、`GUOGUO_ANDROID_STORE_PASSWORD`、`GUOGUO_ANDROID_KEY_ALIAS`、`GUOGUO_ANDROID_KEY_PASSWORD`；签名缺失时明确拒绝 release 构建。随后运行 `flutter build apk --release --no-pub`。

包检查示例（`GITHUB_SHA` 须指向实际源码提交）：

```bash
python3 scripts/android_package.py --apk build/app/outputs/flutter-apk/app-release.apk \
  --mode release --build-tools "$ANDROID_HOME/build-tools/36.0.0"
```

正式包检查还需要环境变量 `ANDROID_CERTIFICATE_SHA256` 与项目固定证书指纹一致。脚本检查版本／包名、TV 启动入口、签名、三种 ABI、原生库和 64 位 ELF 的 16 KB 对齐，并输出包、元数据及校验和。

## GitHub 签名配置

仓库 Secrets 使用 `ANDROID_KEYSTORE_BASE64`、`ANDROID_KEYSTORE_PASSWORD`、`ANDROID_KEY_ALIAS` 和 `ANDROID_KEY_PASSWORD`。Variables 使用 `ANDROID_RELEASE_ENABLED=true` 和公开的 `ANDROID_CERTIFICATE_SHA256`。构建时仅在 runner 临时目录恢复密钥，发布前必须通过验证；任务最后清除临时密钥。CI／PR 的 debug 构建不读取正式签名。

首次建立的签名需在仓库外另行私密备份，包括 keystore 和对应口令；后续版本沿用同一密钥。不要将密钥或 `key.properties` 提交到 Git。

## 验收边界

APK 构建、签名、ABI、16 KB 静态校验以及 Flutter 遥控器测试不能证明所有盒子的硬件解码能力。真机至少检查：电视桌面启动；方向／确认／返回完成浏览、搜索和选集；播放、暂停、进度与相邻集；本地下载播放；切后台／回前台；退出后重新启动；持续播放及换集。手机还需检查画中画、通知权限和后台下载。

主机曾因磁盘余量不足未能安装 Google TV 模拟器，不能将该次包构建结果写成模拟器或真机通过。当前具体结果见[本轮实施记录](app-improvements-2026-10-25.md)。
