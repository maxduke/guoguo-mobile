# 红果空响应与一次性设备身份恢复（2026-11-02）

用户在 v0.20.7 后继续反馈 iPhone 红果无法播放，并提供 [hongguoTV issue #41](https://github.com/tsukiyo-zero/hongguoTV/issues/41)。本轮固定参考 [3e2db1b](https://github.com/tsukiyo-zero/hongguoTV/tree/3e2db1b75126c804d6b1e1dc6acb5e8c6f365766) 中已合入的 [PR #42](https://github.com/tsukiyo-zero/hongguoTV/pull/42)，重点核对设备会话、空响应判定及恢复触发条件。

## 对上次判断的修正

[首条调查回复](https://github.com/tsukiyo-zero/hongguoTV/issues/41#issuecomment-6566332154)提供了更长时间的对照：部分设备身份在不同官方域名和新旧连接上一直收到空内容，而同一时段的其他身份可用。换接口和连接不能覆盖这一类故障。v0.20.7 保留同一注册身份的策略缺少恢复这类情况的途径。

[后续用户反馈](https://github.com/tsukiyo-zero/hongguoTV/issues/41#issuecomment-6571582993)及[调查追加回复](https://github.com/tsukiyo-zero/hongguoTV/issues/41#issuecomment-6571924451)又显示，重新注册的身份也可能同时失败。它支持区分“重新注册后能恢复”和“重新注册仍无资源”两种结果；这些外部和单个网络环境的观察不足以证明所有地区或所有用户都处于同一全局故障。

本轮不会以继续增加相同身份的重试次数，或某次主机探针成功，作为问题已彻底解决的证据。

## 本地适配

- 移动端前台单集取流在连续两轮完全空响应后，沿用现有官方注册流程重新注册一次匿名设备。每轮仍按 `b → hl → lf → b` 读取，四次均为 HTTP 200 空内容才计入证据；HTTP 错误、限流、超时、格式错误和错集模型不触发这项恢复。
- 一次解析最多运行两轮旧身份和一轮替代身份，即最多 12 次模型读取，加一次替代注册；继续受原有移动请求总期限和取消控制。本地界面只会自动刷新一次资源，因此恢复在原解析调用内完成，不依赖新增五分钟界面循环。
- 同一连续失败期只完成一次替代注册尝试。新身份仍全空时返回明确的恢复耗尽提示，后续解析只使用普通四次预算。注册失败保留原身份并停止再次注册；取消不发布新身份，后续有效请求可继续完成尚未完成的恢复。
- 前台播放和预取共享注册进行中的等待；等待者可以独立取消。携带后续模型提示的后台准备只使用原有单轮预算，不主动轮换或消耗前台恢复资格。
- 每个请求保留实际使用的身份和成功模型版本。旧请求在轮换进行中或完成后返回时，不能重置当前身份的恢复资格、增加失败轮数或把旧身份的模型放回缓存。只有当前版本中目标分集的有效兼容媒体，才复位连续失败状态。
- 替代注册成功后清理未来分集模型缓存，并阻止旧响应重新填充。已经交给播放器的媒体继续使用；目录、收藏、观看进度、账号 Cookie 和备份结构不因身份恢复而改变。

没有把上游的并发状态实现直接照搬：注册资格在联网前加锁领取，实际注册在锁外执行，成功身份、等待结果和缓存失效一起发布。请求版本还防止同一身份的迟到成功响应覆盖较新的失败状态。

用户提示固定为“红果服务仍未返回播放资源，请稍后重试或切换网络”，不显示设备 ID、Cookie、媒体地址或底层异常正文。

主要入口：`provider_hongguo_identity_recovery.go`、`provider_hongguo_native_media.go`、`provider_hongguo_device.go`、`provider_hongguo_app.go` 和 `provider_hongguo_model_cache.go`；安全提示位于 `lib/platform/playback_failure.dart`。来源与 GPL 许可见 [UPSTREAM.md](../native/core/UPSTREAM.md#november-2-hongguo-selective-identity-recovery)。

## 验证证据与限制

受控传输回归验证：旧身份连续八次为空后恰好进行一次替代注册，新身份可取得保留 CENC 密钥的兼容媒体；全部身份都为空时最多 12 次模型请求后结束，下一次解析不会再次注册。另覆盖非空错误不触发、后台预取不触发、注册失败保留旧身份、并发共享注册、取消拥有者/等待者、轮换中的迟到成功、轮换后的旧模型与持久化隔离。

真实探针从 18 条推荐进入 48 集详情，但在走过一次身份恢复后仍没有取得播放信息，最后返回恢复耗尽提示，未进入媒体解密或解码。失败日志保留在 `/tmp/guoguo-hongguo-issue41-live-decode.log`，没有通过反复更换身份或重跑直到成功来覆盖失败。这与 issue 的最新追加观察一致，但不能仅凭该主机网络判断全球服务状态，也不能归因于 iPhone 解码器。

最终本地检查：Go 全量 671 个测试/子测试通过、零失败，8 项既有可选联网巡检未启用；FFmpeg/CENC 回归实际执行。身份注册、并发、取消、旧响应和无后续分集的后台路径通过竞态检查；`go vet`、Flutter analyze、5 项安全提示测试、43 项 Python/JVM 发布工具测试、格式与差异检查通过。最终 Go 与竞态日志分别为 `/tmp/guoguo-hongguo-issue41-release-go-final.jsonl`、`/tmp/guoguo-hongguo-issue41-release-race-final.log`。

主机回归和模拟传输验证不代表 iPhone 已恢复可播，设备起播、切集、PiP 和连播仍需安装修复构建验收。
