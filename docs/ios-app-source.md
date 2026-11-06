# iOS 安装源

LiveContainer 3.7 及以上、SideStore、AltStore Classic 和兼容 AltStore 格式的工具使用同一个地址：

```text
https://github.com/maxduke/guoguo-mobile/releases/latest/download/apps.json
```

在工具的“源 / Sources”中添加一次。以后刷新源，选择果果的新版本更新即可，不需要每次换源或复制 IPA 地址；更新时按工具提示保留已有应用与数据，不要先卸载。

仓库保持 private，源和 IPA 受同样的 GitHub 访问权限保护。通用工具通常不能直接读取私有 GitHub Release；私有期间仍可登录 GitHub 下载 IPA 后导入工具。维护者以后自行把仓库改为 public，上述源地址即可公开读取，无需修改工作流或重新生成地址。源和 URL 中不包含访问 token。

## 随 Release 自动更新

现有 `Release` 工作流在已验证的 iOS / Android 构建完成后，生成 `apps.json` 和 `icon.png`，随原有安装包一起上传到当前 Release。附件全部上传后才结束草稿状态；现有的版本、标签、签名和校验门禁继续生效。不需要新仓库、服务器或额外 secret。

源只展示本次正式版本。IPA 和图标指向对应标签下的固定附件，避免旧源缓存下载到与声明版本不一致的安装包。旧版安装包继续保留在各自 Release 中。

版本、构建号、最低系统、文件大小及隐私声明来自实际 IPA，并核对 `build-info.json`、源码提交和 SHA-256。`buildVersion` 用于 AltStore，`buildNumber` 兼容 LiveContainer；同时保留旧版顶层字段。侧载工具负责签名、覆盖安装与续签，源不改变这些行为。

## 为已发布版本补充源

下载该版本的 IPA、`build-info.json` 和 `SHA256SUMS` 到同一目录后，用已发布标签的真实提交和发布时间生成：

```bash
python3 scripts/ios_source.py \
  --artifacts /tmp/guoguo-release-assets \
  --repository maxduke/guoguo-mobile \
  --tag v0.20.9 \
  --commit 9c7143e033321ff1f2f3ee37ff833b6792f284a5 \
  --date 2026-11-06T04:11:37Z
```

只给原 Release 添加新生成的 `apps.json` 和 `icon.png`，不要移动标签、重建或覆盖现有 IPA / APK / 校验文件。以后新版本由工作流自动生成，无需重复手动补充。

格式依据：[AltStore 文档](https://faq.altstore.io/developers/make-a-source)、[LiveContainer 解析器](https://github.com/LiveContainer/LiveContainer/blob/9108ae624ea001f7d7696d48407f890b48fa2653/LiveContainerSwiftUI/Views/LCAltStoreSourcesView.swift)。源格式和真实包校验不代替实体设备上签名、覆盖安装及数据保留的验收。
