# iOS 安装源

使用同一份 AltStore JSON，为 LiveContainer、SideStore、AltStore Classic 和兼容此格式的工具提供安装与更新入口。iOS 安装包仍由各工具完成签名和安装，源不负责证书续签。

## 添加与更新

公开分发启用后，在工具的“源 / Sources”中添加一次：

```text
https://raw.githubusercontent.com/maxduke/guoguo-releases/main/apps.json
```

- LiveContainer 3.7 及以上：进入“源”，添加上述地址；刷新后选择果果的新版本，按工具提示更新已有应用并保留数据。
- SideStore / AltStore Classic：在 Sources 中添加上述地址，刷新后从应用更新入口安装新版。
- 其他工具：需支持 AltStore 源格式。此源同时提供 `versions` 和旧版顶层版本字段；是否提供自动检查、提醒或后台更新取决于工具自身。

以后不需要换源地址或逐次复制 IPA 链接。每条版本记录指向对应 Release 中固定的 IPA，不使用会变化的 `latest` 下载链接。更新前不要卸载原应用。

## 首次启用

源码仓库保持私有；经维护者确认后，另建 `maxduke/guoguo-releases` 公开仓库，默认分支为 `main`。该仓库仅放安装源、图标、使用说明和经过验证的 iOS Release 附件，不镜像源码、Android 签名材料或 Actions 日志。

本地先预览真实版本，无 GitHub 写入：

```bash
python3 scripts/publish_ios_source.py --target maxduke/guoguo-releases --tag v0.20.9 --dry-run
```

首次发布和以后手动同步均可使用已登录的 GitHub CLI：

```bash
python3 scripts/publish_ios_source.py --target maxduke/guoguo-releases --tag v0.20.9
```

省略 `--tag` 同步私有仓库最新的正式 Release。公开仓库需预先创建；脚本不会改变现有仓库可见性，也不会自动创建公开仓库。

## 后续自动更新

`.github/workflows/ios-source.yml` 在 `Release` 成功完成后运行，也支持手动补同步已有版本。使用 `workflow_run`，因为由 `GITHUB_TOKEN` 创建的 Release 不会再次触发 `release` 事件工作流。

首次配置一次：

1. 创建 GitHub fine-grained token，仅选择公开分发仓库，授予 **Contents: Read and write**。不要选择私有源码仓库，不需要管理权限。
2. 把它存为源码仓库的 Actions secret `IOS_SOURCE_TOKEN`，不要放进源 JSON、URL、源码或聊天记录。
3. 将源码仓库 Actions variable `IOS_SOURCE_REPOSITORY` 设为 `maxduke/guoguo-releases`。该变量未设置时，自动分发不启用。
4. 合并工作流后，对现有版本手动运行一次 `Update iOS installation source`；后续沿用原来的正常发布流程即可。

```bash
gh secret set IOS_SOURCE_TOKEN --repo maxduke/guoguo-mobile
gh variable set IOS_SOURCE_REPOSITORY --repo maxduke/guoguo-mobile --body maxduke/guoguo-releases
gh workflow run ios-source.yml --repo maxduke/guoguo-mobile -f tag=v0.20.9
```

第一个命令在本机终端安全输入 token。读取私有 Release 使用工作流自带的 `GITHUB_TOKEN`，公开分发 token 只用于分发仓库；不把本机登录使用的高权限 token 复制进 CI。

## 发布边界

- 只接受已经发布的 `vX.Y.Z` 正式版本，核对标签实际提交、`build-info.json`、原始 IPA 及 SHA-256。
- 从 IPA 内部读取 bundle ID、版本、构建号、最低 iOS 和隐私权限；不猜测文件大小或系统要求。当前仅支持本项目无扩展的未签名 IPA，新增应用扩展时需先复核权限声明。
- 镜像的 IPA、`build-info.json`、`SHA256SUMS` 先上传至草稿，核对 GitHub 记录的附件摘要，再公开 Release，最后更新 `apps.json`。错误会保留上一份可用源。
- 已公开镜像只接受完全一致的重复同步，不覆盖已发布附件。源更新使用文件 SHA 做并发检查，不强推，补发旧版本不会把旧版本排到新版之前。
- `buildVersion` 用于 AltStore，`buildNumber` 为 LiveContainer 当前读取字段，二者来自同一个 `CFBundleVersion`。保留顶层 `version` / `versionDate` / `downloadURL` 等字段供旧格式读取器使用。

格式依据：[AltStore 开发者文档](https://faq.altstore.io/developers/make-a-source)、[LiveContainer 解析器](https://github.com/LiveContainer/LiveContainer/blob/9108ae624ea001f7d7696d48407f890b48fa2653/LiveContainerSwiftUI/Views/LCAltStoreSourcesView.swift)、[GitHub 工作流事件规则](https://docs.github.com/en/actions/how-tos/writing-workflows/choosing-when-your-workflow-runs/triggering-a-workflow)。协议与脚本验证不代替实体设备上签名、覆盖安装和数据保留的验收。
