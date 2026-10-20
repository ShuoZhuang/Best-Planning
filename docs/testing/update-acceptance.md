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

2026-10-18 最近一次结果（HEAD `cef5b727`）：`flutter analyze` 无问题；全量 `flutter test` **2911 个通过**；
助手脚本 `selftest`、真实 MSIX `--verify`、`--apply --dry-run`、错误令牌拒绝全部通过。

## 测试产物（2026-10-18）

`tool/build_update_release.ps1` 生成并签名的候选产物（**未安装、未发布**）：

| 版本 | 文件 | 字节 | SHA-256 |
| --- | --- | --- | --- |
| 1.9.0+46 | `release-artifacts/1.9.0/BestPlanning_1.9.0.0_x64.msix` | 18,542,096 | `18cc6fdcfd0a46702fd31f8080f9bfe24cc2c0f18fdac68f1d0d5f823e50d09d` |
| 1.9.1+47 | `release-artifacts/1.9.1/BestPlanning_1.9.1.0_x64.msix` | 18,542,143 | `999567a17f719d82a048122324c0096506052ced564d2e77a64031bd61462244` |

首次安装另有两套旧发布形态的完整包（便携目录 + MSIX + 证书 + 一键安装脚本 + 校验值）：

| 版本 | ZIP | 字节 |
| --- | --- | --- |
| 1.9.0+46 | `release-artifacts/PersonalPlanner-1.9.0-build46-windows-x64-20261018.zip` | 35,424,021 |
| 1.9.1+47 | `release-artifacts/PersonalPlanner-1.9.1-build47-windows-x64-20261018.zip` | 35,424,121 |

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
- 027–030 未保存/纯查看/事务/专注：`update_safety_test.dart`、规划规则/课程/固定日程/保护时间/任务/周期目标编辑器测试；UPD-029 的业务事务租约与各生产入口见下条。
- 029 业务事务阻塞：`update_safety_test` 的重叠租约；`plan_application_service_test`、
  `plan_undo_service_test`、`timetable_import_commit_test`、`backup_service_test`、
  `pre_migration_backup_test` 的阻塞/成功/异常解除；两个重叠导入的用例；
  `update_orchestrator_test` 的“检查通过后才开始事务”与“阻塞解除后直接重试”；
  `backup_version_provider_test` 的组合根实例一致性。生产接线位于各服务构造与
  `lib/main.dart`，不在页面按钮处。
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

---

## 1.11.1 事故修复验收补充（2026-10-20）

事故：1.10.2 客户端已下载 1.11.0 后，建立回退基线时用 tag 清单覆盖了 latest 的全局缓存，
`latest` 的 304 读到 1.10.2，状态机把已下载的 1.11.0 判成“已是最新版”，安装入口被永久
阻塞于“回退基线未就绪”。修复计划：
`docs/superpowers/plans/2026-10-20-v1.11.1-update-manifest-cache-and-baseline-recovery-repair.md`。

### 分层证据

| 验收项 | 自动化证据 | 结果 |
| --- | --- | --- |
| 缓存身份隔离（latest / tag 各一文件） | `test/infrastructure/update/file_update_manifest_cache_test.dart` | PASS |
| 304 只读同 key 缓存、缺缓存时无条件重试 | `test/infrastructure/update/http_update_manifest_repository_test.dart` | PASS |
| 事故顺序（latest 200 → tag 200 → latest 304） | `test/application/update/update_cache_baseline_incident_test.dart` | PASS |
| 目标单调性与显式撤回 | `test/application/update/update_state_monotonicity_test.dart` | PASS |
| 启动复核与 ready 收养/隔离 | `test/application/update/update_startup_reconciliation_test.dart` | PASS |
| v1 状态与旧缓存迁移 | `test/domain/update/update_state_test.dart`、`test/infrastructure/update/update_store_test.dart`、缓存测试 | PASS |
| 基线严格校验与磁盘预算 | `test/application/update/update_baseline_service_test.dart` | PASS |
| 触发入口矩阵与 single-flight | `test/application/update/update_controller_test.dart`、`update_orchestrator_test.dart` | PASS |
| 安装/健康确认/基线晋升生命周期 | `update_orchestrator_test.dart`、`update_snapshot_health_test.dart` | PASS |
| 界面文案与诊断脱敏 | `test/features/shell/**`、`test/features/settings/update_page_test.dart`、`test/architecture/update_no_popup_test.dart` | PASS |
| 真实组合根恢复链路（真实缓存/状态/控制器/widget） | `test/app/update_cache_baseline_recovery_test.dart` | PASS |
| 真实事故机器回放（本机数据 + 真实 GitHub） | `test/app/incident_replay_test.dart` | PASS |
| 已安装态事故序列（Windows integration） | `integration_test/update_cache_baseline_recovery_test.dart` | PASS（`-d windows`） |
| 签名 MSIX 覆盖升级与失败回退 | `tool/update_e2e.ps1` | NOT RUN（无正式签名证书与安装授权） |
| 发布不可变资产门禁 | `test/tool/update_publisher_test.dart`、`update_pipeline_test.dart` | PASS |
| 版本一致性（1.11.1+53 / MSIX 1.11.1.0 / tag v1.11.1） | `test/app/version_consistency_test.dart` | PASS |

### 人工/安装态证据

未执行。`docs/testing/v1.11.1-release-gate.md` 逐项记录了阻断原因，**不得**把 NOT RUN
改写成通过。受影响的 1.10.2 用户的自愈路径是下载并覆盖安装正式安装器
（产物实际命名 `BestPlanning_Setup_1.11.1_x64.exe`）；不需要手工删除缓存或编辑状态文件。

### 维护规则（避免同类回归）

1. latest 与 tag 的清单缓存**永远分文件**；任何“共享一份缓存”的改动都会让
   `update_cache_baseline_incident_test.dart` 变红。
2. `304` 只允许读取与本次请求同一个 `ManifestRequestKey` 的缓存项；`UpdateState.manifestEtag`
   只是诊断字段，不得再驱动请求。
3. 任何“最新清单更旧/相同”的结果都不得清空已有的更高 target；只有
   `installed >= target`、清单明确撤回、或用户显式放弃才能清除。
4. 启动时枚举受控目录里的 `.ready`：能证明身份就收养，不能证明就隔离，绝不静默删除。
5. 基线建立与复用共用一个 `validateBaseline`；只查“存在 + 长度”一律视为缺陷。

### 2026-10-20 分层与全量结果

| 层 | 结果 |
|---|---|
| `test/domain/update` | 72 passed |
| `test/infrastructure/update` | 114 passed |
| `test/application/update` | 83 passed |
| `test/features/shell` + `update_page_test.dart` | 30 passed |
| `test/architecture`（无弹窗 + 网络边界） | 10 passed |
| `test/app`（版本一致性 + 外壳 + 事故恢复） | 8 passed |
| `test/tool`（发布不可变门禁） | 21 passed |
| 全量 `flutter test test` | **3402 passed + 1 skipped（真实事故回放），退出码 0** |
| `flutter analyze` | No issues found |
| `dart format --set-exit-if-changed`（本次修改文件） | 0 changed |
| `git diff --check` | 退出码 0 |

Windows 桌面 integration（Developer Mode 已开启，设备 `windows`）：

```powershell
& G:\best-planing\.tooling\fx.ps1 test --no-pub -d windows integration_test/update_cache_baseline_recovery_test.dart
# 构建 personal_planner.exe 后 +1: All tests passed!
& G:\best-planing\.tooling\fx.ps1 test --no-pub -d windows integration_test/packaged_update_storage_test.dart
# +1: All tests passed!（SKIP packaged assertions: unpackaged fallback）
```

**它能证明什么 / 不能证明什么**：事故序列在真实 Windows 文件系统与真实 app 进程里自愈；
但 `flutter test` 产物没有 MSIX 包身份，所以“已安装态的受保护目录与 ACL”以及**签名 MSIX
覆盖安装**仍必须由 `tool/update_e2e.ps1` 在签名安装环境执行（本表对应行仍是 NOT RUN）。

red-first 时序证据见
`docs/testing/v1.11.1-update-incident-red-green-evidence.md`。

### 真实事故机器回放（本机，2026-10-20）

事故就发生在执行本任务的这台机器上，因此除合成夹具外还做了一次**真实数据 + 真实网络**回放。

现场事实（只读取，未改动）：

| 事实 | 值 |
|---|---|
| 已安装包 | `ShuoZhuang.PersonalPlanner_1.10.2.0_x64` |
| 更新根 | `%LOCALAPPDATA%\Packages\<PFN>\LocalCache\BestPlanning\Updates` |
| 已下载的 1.11.0 | `1.11.0.0\package.msix.ready`，18,946,393 B，SHA-256 `e4b5294e…3842d6` |
| 线上 latest 清单 | 1.11.0 / build 52，`sizeBytes=18946393`、`sha256=e4b5294e…3842d6`（**与磁盘逐字节一致**） |
| 回退基线 | `baseline\BestPlanning_1.10.2.0_x64.msix`，18,575,088 B，SHA-256 `de8af8f7…3791c9`（与 state 记录一致） |
| 状态文件 | `schemaVersion: 1`、`phase: upToDate`、`currentMsixVersion: 1.11.0.0`、**`target: null`**（目标已丢失） |
| 旧全局缓存 | `update-manifest.cache.json`，`schemaVersion: 1`（无请求身份） |
| 真实日志 | `UPDATE_BLOCKED_ROLLBACK_NOT_READY`、`baseline ready version=`（版本为空 → UPD-INC-022 在真实日志里复现） |
| 助手状态 | `state: failed`、`failureCode: UPDATE_ROLLBACK_DATA_RESTORE_FAILED`（见下方遗留风险） |

回放命令（把真实目录整份复制到临时目录后运行，源目录只读）：

```powershell
$env:INCIDENT_UPDATE_ROOT='%LOCALAPPDATA%\Packages\<PFN>\LocalCache\BestPlanning\Updates'
$env:INCIDENT_APPX_MANIFEST='C:\Program Files\WindowsApps\ShuoZhuang.PersonalPlanner_1.10.2.0_x64__v9555qkaxdyym\AppxManifest.xml'
& G:\best-planing\.tooling\fx.ps1 test --no-pub --timeout 300s test/app/incident_replay_test.dart
```

结果：`+1: All tests passed!`，关键观察：

```text
INSTALLED: 1.10.2.0 CN=Shuo Zhuang, O=Personal User, C=CN
CHECK1: classification=updateAvailable phase=ready target=1.11.0.0
CHECK2: classification=updateAvailable fromCache=true target=1.11.0.0 phase=ready
LOG: ready_pending_manifest version=1.11.0.0 | ready_reused version=1.11.0.0 |
     manifest_cache_hit key=latest-stable status=304
```

它证明了：v1 状态迁移保住基线、旧缓存被隔离、磁盘上 19 MB 的 1.11.0 被**复用（零下载）**、
1.10.2 基线通过严格校验、真实 GitHub 304 之后目标仍是 1.11.0。

它没有证明：安装 1.11.1 之后真机上的一次真实自愈——那需要签名构建，仍为 NOT RUN。

> **遗留风险（本计划范围之外）**：这台机器的助手在 2026-10-20T12:32:36Z 记录
> `UPDATE_ROLLBACK_DATA_RESTORE_FAILED`，说明 1.11.0 的安装尝试失败、随后回退数据恢复也失败。
> 缓存/状态缺陷修好后，下次升级仍会再触发这条原生路径，需要单独的安装/回退事故排查
> （`windows/update_helper` 与快照恢复），不能用本次修复冒充已解决。
