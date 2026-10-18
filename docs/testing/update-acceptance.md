# 原生自更新验收记录

日期：2026-10-18
分支：`feature/native-implementation`
依据：`docs/superpowers/specs/2026-10-18-native-self-update-design.md`
实施计划：`docs/superpowers/plans/2026-10-18-native-self-update-implementation-plan.md`

## 门禁命令

```powershell
& G:\best-planing\.tooling\fx.ps1 analyze --no-pub
& G:\best-planing\.tooling\fx.ps1 test --no-pub
& tool\update_helper_tests.ps1 -SkipBuild
```

2026-10-18 最近一次结果：`flutter analyze` 无问题；全量 `flutter test` **2899 个通过**；
助手脚本 `selftest`、真实 MSIX `--verify`、`--apply --dry-run`、错误令牌拒绝全部通过。

## 测试产物（2026-10-18）

`tool/build_update_release.ps1` 生成并签名的候选产物（**未安装、未发布**）：

| 版本 | 文件 | 字节 | SHA-256 |
| --- | --- | --- | --- |
| 1.9.0+46 | `release-artifacts/1.9.0/BestPlanning_1.9.0.0_x64.msix` | 18,538,929 | `2a03988ad8abda3b7383fc2ad21c332c8020198da80e8a20db0a18b5f4d72970` |
| 1.9.1+47 | `release-artifacts/1.9.1/BestPlanning_1.9.1.0_x64.msix` | 18,538,905 | `52727ba719d0a8c7ae4aa14d84a8f60d787e2839df1032cdd80e9146b55a1df2` |

两份产物都用 `update_helper --verify` 验证过身份/签名，并用
`dart run tool/update_pipeline.dart verify` 复验过清单与成品一致。`pubspec.yaml` 与
`backup_assembly.dart` 在构建后已恢复为 `1.8.1+45`，产物目录被 `.gitignore` 忽略。

生成过程中修复了 `update_pipeline verify` 的一个真实缺陷：它把已解析的信封再次传给
`UpdateManifestEnvelope.tryParse`，导致 `type 'Null' is not a subtype ...`；现在直接校验
解析后的信封。

## 状态汇总

| 状态 | UPD |
| --- | --- |
| PASS（自动测试） | 001–008、010–020、022–027、029–033、035、037、039、041–044、048 |
| PARTIAL（代码完成，自动证据有限） | 009（无网络类型分支的静态门禁；热点/计费网络未实测）、021（主程序与助手锁均有测试；跨机并发未演练）、028（所有草稿编辑器已接入；设置页为即时保存/模态对话框）、034/038/040（代码与 dry-run 覆盖部署前，真实部署未演练）、036（既有迁移事务/备份测试，未新增失败回退专项） |
| NOT RUN | 015 的**真实安装**部分（验证已通过，部署未跑）、045、046、047 |

## 逐项证据（摘要）

- 001 不再调用 Releases API：`test/architecture/update_network_boundary_test.dart`。
- 002/003 304 与缓存：`test/infrastructure/update/http_update_manifest_repository_test.dart`。
- 004/005 四类结论与假“最新版”：同文件 + `test/application/update/update_orchestrator_test.dart`。
- 006/007 规范化/签名/严格 Schema：`test/infrastructure/update/json_canonicalizer_test.dart`、`ed25519_manifest_verifier_test.dart`、`test/domain/update/update_manifest_test.dart`。
- 008 重定向白名单：`update_network_policy_test.dart` 与仓库测试。
- 009 任意网络自动下载：`update_network_boundary_test.dart` 的“不按网络类型分支”。
- 010–014 下载器：`resumable_package_downloader_test.dart`（Range/200/416/取消/哈希/大小）。
- 015/032 包验证：`update_package_verifier_test.dart`；助手真实 MSIX `--verify` 结果见
  `docs/testing/update-helper-verification.md`。
- 016 身份/发布者/PFN/架构：同上。
- 017/018 版本与撤回：`test/domain/update/update_manifest_test.dart`。
- 019/020 状态存储与非法跳转：`update_store_test.dart`、`update_state_test.dart`。
- 021 锁：`file_update_lock_test.dart`、`update_orchestrator_test.dart`。
- 022 六页面入口：`test/app/update_indicator_shell_test.dart`。
- 023/024 入口状态与无二次确认：`test/features/shell/update_indicator_test.dart`。
- 025 未点击不安装：`update_orchestrator_test.dart`（安装只由 `install()` 触发）。
- 026 无弹窗：`test/architecture/update_no_popup_test.dart`。
- 027–030 未保存/纯查看/事务/专注：`update_safety_test.dart`、规划规则/课程/固定日程/保护时间/任务/周期目标编辑器测试。
- 031/033 请求与进程协调：`tool/update_helper_tests.ps1` 的 `--apply --dry-run`。
- 035 快照：`update_snapshot_health_test.dart`。
- 037 健康确认：同上。
- 039 重试上限与暂停目标：`update_orchestrator_test.dart`。
- 041 日志隐私：`update_store_test.dart`。
- 042/044 清单生成与哈希一致：`test/tool/update_pipeline_test.dart`。
- 043 草稿→回读→发布：`test/tool/update_publisher_test.dart`（假 gh runner）。
- 048 旧实现删除：`update_network_boundary_test.dart`。

## 未执行项与原因

- 045/046/047：需要 Windows 10 与 Windows 11 真机、正式签名的 1.8.1/1.9.0/1.9.1 产物；
  本环境只有单机与 1.8.1 构建，`tool/update_e2e.ps1` 已备。
- 015 的部署部分、034/038/040：`AddPackageAsync` 会真实改写本机已安装应用，未在开发环境执行。
- 043 的真实上传：需要 GitHub 凭据，未在本地执行。

**结论**：代码与自动证据已覆盖除真机部署/升级矩阵以外的全部条目；按规格 §23，在 045–047
完成前不能把整个子系统标记为“已实现”。
