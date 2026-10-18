# 优计主义 Windows 原生自更新系统实施计划

日期：2026-10-18
依据：`docs/superpowers/specs/2026-10-18-native-self-update-design.md`（下称"规格"）
分支：`feature/native-implementation`
状态：实施中。本计划把规格 §18.1 的四个里程碑拆成可独立验证的批次，并把 UPD-001～UPD-048 逐项映射到测试名或人工门禁。

## 1. 范围与不可动的事实

本计划实现规格 §1 的全链路：

```text
固定签名清单 → 版本判断 → 后台自动下载 → 完整性/发布者校验 → 左下角入口
→ 用户点击 → 安全退出 → 独立更新助手 MSIX 原位升级 → AUMID 启动
→ 健康确认 → 清理或回退
```

以下事实在本计划中**只允许被读取，不允许被修改**（规格 §3.1、§6.3、§13.3）：

| 事实 | 值 | 读取位置 |
| --- | --- | --- |
| 包身份 | `ShuoZhuang.PersonalPlanner` | `pubspec.yaml` → `msix_config.identity_name` |
| Publisher | `CN=Shuo Zhuang, O=Personal User, C=CN` | `pubspec.yaml` → `msix_config.publisher` |
| 包族名 | `ShuoZhuang.PersonalPlanner_v9555qkaxdyym` | 由 Publisher 派生，客户端用 `sha256+base32` 自算并核对 |
| AUMID | `ShuoZhuang.PersonalPlanner_v9555qkaxdyym!personalplanner` | 清单固定值 + `windows/runner` 的应用入口 |
| 架构 | `x64` | `msix_config` 与清单 `compatibility.architecture` |

版本关系（本计划冻结）：

```text
当前发布线       1.8.1+45   MSIX 1.8.1.0
首个自更新版本   1.9.0+46   MSIX 1.9.0.0   ← 过渡：用户手动安装
演练目标版本     1.9.1+47   MSIX 1.9.1.0   ← 首个自动升级验收
```

## 2. 代码边界与依赖方向

按规格 §16 落地。新增目录与职责：

```text
lib/domain/update/
  update_version.dart          SemVer / MsixVersion / 版本集一致性
  update_manifest.dart         签名清单信封与 payload 的严格模型
  update_failure.dart          错误码、分类、可重试判定
  update_state.dart            持久状态、合法跳转、恢复动作
  update_safety.dart           阻塞项与安全判定（纯规则）
  rollback_baseline.dart       回退基线模型

lib/application/update/
  update_orchestrator.dart     唯一业务编排入口
  update_check_policy.dart     检查时机合并（启动/24h/网络恢复/手动）
  update_safety_coordinator.dart 未保存编辑与业务事务的汇总端口
  update_health_service.dart   健康确认写入与判定
  update_snapshot_service.dart 更新前数据快照

lib/infrastructure/update/
  json_canonicalizer.dart      RFC 8785
  ed25519_manifest_verifier.dart Ed25519 + keyId 允许集合
  http_update_manifest_repository.dart 固定地址、ETag/304、重定向白名单
  file_update_state_store.dart 原子状态文件
  file_manifest_cache.dart     已验证清单缓存
  resumable_package_downloader.dart Range/If-Range/200/206/416
  update_package_verifier.dart 大小/SHA-256/ZIP 结构/身份字段
  file_update_lock.dart        跨进程锁（PID + 进程启动时间）
  update_log_store.dart        轮转日志（≤2MB × 5）
  file_rollback_package_store.dart 回退包与快照存放

lib/platform/update/
  windows_package_info.dart    已安装包身份与版本（经桥）
  windows_update_bridge.dart   包信息、签名验证、助手探针
  windows_update_helper_launcher.dart 助手启动与握手确认
  url_launcher_adapter.dart    保留：只打开 Release 页面

lib/features/shell/
  update_indicator.dart        左下角入口
  update_status_card.dart      非模态状态卡

lib/features/settings/update/
  update_page.dart             状态与诊断页
  update_diagnostics_panel.dart 结构化失败与日志入口

windows/update_helper/         C++/WinRT 独立目标
tool/update_pipeline.dart      发布流水线命令行
tool/verify_update_manifest.dart 下载后复验
```

依赖方向固定为 `UI → application → domain`，`infrastructure` 与 `platform` 只实现 domain 端口，不得被 domain 反向依赖。领域层不允许出现 `package:flutter`、`package:http`、`dart:io`、`dart:ffi`。

## 3. 四个里程碑与单一所有者

规格 §18.1 要求拆成四个有先后依赖的里程碑，并给共享文件指定单一顺序所有者。本计划的执行顺序与共享文件所有权：

| 里程碑 | 内容 | 共享文件（单一所有者顺序） | 门禁 |
| --- | --- | --- | --- |
| M1 协议与检查器 | 领域模型、规范 JSON、Ed25519、固定地址、ETag/304、错误分类、替换旧检查器 | `lib/app/router.dart`、`lib/main.dart`、`lib/application/update_service.dart`、`test/architecture/*` | `flutter test test/domain/update test/infrastructure/update test/architecture` + 假"最新版"回归全绿 |
| M2 下载与界面 | 持久状态、断点续传、磁盘余量、日志、锁、左下角入口、设置诊断页、未保存协调 | `lib/features/shell/*`、`lib/app/planner_app.dart`、`lib/app/router.dart`、`lib/main.dart` | 下载/状态/界面测试全绿；`flutter analyze` 干净 |
| M3 原生安装链 | 包验证、C++/WinRT 助手、主程序退出、部署、AUMID 启动、健康确认 | `windows/update_helper/*`、`windows/CMakeLists.txt`、`lib/platform/update/*` | 助手单元/集成测试 + 手工部署演练记录 |
| M4 恢复与发布 | 快照、回退基线、自动回退、发布流水线、Windows 矩阵、1.9.0→1.9.1 演练 | `tool/update_pipeline.dart`、`docs/release/*` | 发布门禁 + 手工矩阵记录；未跑项标 `NOT RUN` |

**前三个里程碑不单独对正式用户启用**：`nativeUpdaterEnabled` 内部开关默认关闭，关闭时保留旧检查器行为，打开时旧入口全部停用（规格 §18）。

## 4. 协议实现要点

### 4.1 清单信封

```json
{
  "payload": {
    "schemaVersion": 1,
    "channel": "stable",
    "release": {
      "version": "1.9.0",
      "buildNumber": 46,
      "msixVersion": "1.9.0.0",
      "tag": "v1.9.0",
      "publishedAtUtc": "2026-10-18T00:00:00Z"
    },
    "compatibility": {
      "architecture": "x64",
      "minimumWindowsBuild": "10.0.19041.0",
      "packageIdentityName": "ShuoZhuang.PersonalPlanner",
      "packageFamilyName": "ShuoZhuang.PersonalPlanner_v9555qkaxdyym",
      "publisher": "CN=Shuo Zhuang, O=Personal User, C=CN"
    },
    "package": {
      "fileName": "BestPlanning_1.9.0.0_x64.msix",
      "downloadUrl": "https://github.com/ShuoZhuang/Best-Planning/releases/download/v1.9.0/BestPlanning_1.9.0.0_x64.msix",
      "sizeBytes": 12345678,
      "sha256": "<64 位小写十六进制>"
    },
    "presentation": {
      "title": "1.9.0",
      "summary": "修复与改进",
      "releaseUrl": "https://github.com/ShuoZhuang/Best-Planning/releases/tag/v1.9.0"
    },
    "revokedVersions": []
  },
  "signature": {
    "algorithm": "Ed25519",
    "keyId": "best-planning-2026-10",
    "value": "<base64>"
  }
}
```

签名 = Ed25519(privateKey, RFC 8785(payload))，UTF-8 字节。客户端固定允许 `keyId` 集合（规格 §10.3：新旧密钥至少重叠一个正式版本）。

### 4.2 严格解析

- 未知字段一律拒绝（`UPDATE_MANIFEST_SCHEMA_UNSUPPORTED`），不静默忽略。
- `schemaVersion` 只接受 `1`；`channel` 只接受 `stable`；`tag` 必须等于 `v{version}`。
- SemVer 必须是三段；`buildNumber` 单调正整数；`msixVersion` 必须四段且前三段等于 SemVer。
- `sha256` 必须正好 64 位小写十六进制；`sizeBytes` > 0；文件名必须是安全单段名。
- 展示字段只作为纯文本（标题长度上限 120，摘要 500）。
- `revokedVersions` 每项四段；当前目标命中即拒绝。

### 4.3 网络

- 只允许两个固定 URL：
  - `https://github.com/ShuoZhuang/Best-Planning/releases/latest/download/update-manifest.json`
  - `https://github.com/ShuoZhuang/Best-Planning/releases/download/v{SemVer}/update-manifest.json`
- 最多 5 次重定向；初始与中间地址必须 HTTPS 且位于 `github.com/ShuoZhuang/Best-Planning/` 或官方资产域 `release-assets.githubusercontent.com`（仅资产重定向，且仍需内容校验）。
- 200：验证签名后原子写缓存 + ETag；304：缓存有效则用缓存继续比较，缓存缺失/损坏则去掉条件头完整重试一次；完整请求仍失败 → `temporarilyBlocked`（"暂时无法确认"），绝不显示"已是最新版"。
- 只发送 `Accept`、`User-Agent`、`If-None-Match`、`Range`、`If-Range`。

### 4.4 错误模型

`UPDATE_<STAGE>_<REASON>`，枚举全覆盖规格 §14.2。每个错误码带三个属性：`retryable`、`userMessage`（中文一句话）、`stage`。界面只渲染 `userMessage`；日志记录阶段、版本、时间、重试次数、哈希/签名结论、Windows 结果码，不记录业务内容。

### 4.5 状态机

19 个状态（规格 §9.1），合法跳转表集中在 `update_state.dart`。非法跳转：

- 记录 `UPDATE_STATE_ILLEGAL_TRANSITION` 结构化错误；
- 保持原状态不变；
- 不写回状态文件。

恢复动作表（规格 §9.5）实现为纯函数 `recoveryActionFor(status)`，启动时由编排器执行"重新核对文件/进程/锁/实际包版本"后再落状态。

## 5. 下载器与证据

- 目标目录 `%LOCALAPPDATA%\BestPlanning\Updates\`，路径由本地版本构造，不接受远端字符串拼接。
- 单目标版本；更高版本出现时取消旧下载并切换（`UPDATE_DOWNLOAD_CANCELLED_BY_NEW_VERSION`）。
- `.partial` → 校验长度/SHA-256 → 原子重命名 `.ready`。
- `Range` + `If-Range`；206 从偏移续；200 清空重下；416 先判本地是否已完整；ETag/Last-Modified 变化作废旧段；最终整文件复算 SHA-256。
- 退避 30s→2min→10min→1h→6h，带抖动；确定性错误不进高频重试。
- 磁盘检查 `目标包 + 回退包 + 数据快照 + 安装展开 + max(500MB, 包×2)`。

## 6. 更新助手（C++/WinRT）

独立目标 `windows/update_helper`，使用 Windows SDK 10.0.26100 的 C++/WinRT 投影（`IAppxPackageReader`、`PackageManager`、`ApplicationActivationManager`、Toolhelp/进程启动时间），不引入 .NET 或 Dart 运行时。

职责：

1. `--probe`：输出当前包身份/版本 JSON（供 Dart 桥读取，避免在 Dart 里手写 COM）。
2. `--verify <msix>`：读取包清单与签名，校验 Publisher/Identity/PFN/架构/版本，输出结论 JSON。
3. `--apply <request.json>`：校验一次性请求（版本号、事务号、规范路径在更新目录内、大小、SHA-256、身份、PID+启动时间、令牌、有效期），取得跨进程锁，等待主程序与托盘退出，`AddPackageAsync` 原位部署，`IApplicationActivationManager` 用真实 AUMID 启动，等待健康确认文件（60s 初始，每 10s 心跳，5 分钟绝对上限），失败按 §13.4 回退。

安全限制（规格 §12.4）：不联网、不执行远端命令、不调用 PowerShell/批处理、只接受更新目录内 `.ready` 文件、不读业务记录、不改证书库。

## 7. 发布流水线

`tool/update_pipeline.dart` 子命令：

| 子命令 | 行为 |
| --- | --- |
| `manifest` | 读成品 MSIX，计算大小/SHA-256，生成 payload，按 RFC 8785 规范化并用 Ed25519 私钥签名，写 `update-manifest.json` |
| `verify` | 下载清单与 MSIX，复算大小/哈希，调用 `signtool verify` 与助手 `--verify`，核对身份/Publisher/PFN/架构/版本 |
| `gate` | 检查版本单调、SemVer/MSIX/tag/文件名一致、身份未变；任一不满足即非零退出 |
| `publish` | 创建草稿 Release、上传、回读复核、全部通过后才发布；`latest/download/update-manifest.json` 可解析 |

私钥路径从环境变量 `BEST_PLANNING_UPDATE_SIGNING_KEY` 读取，**不进版本库**（与 MSIX pfx 同一口径）。公钥与 `keyId` 在 `lib/infrastructure/update/ed25519_manifest_verifier.dart` 内置。

## 8.1 实施状态（2026-10-18）

下表是**计划时**的映射；实际完成情况以本节为准。未完成项不得标成通过（规格 §23）。

**已实现并有自动测试（`flutter test` 全绿）**

- M1：UPD-001、002、003、004、005、006、007、008、017、018。
- M2：UPD-010、011、012、013、014、016、019、020、022、023、024、025、026、027、029、030、041、048。
- M3/M4：UPD-031、033、035、037（Dart 侧安装准备、快照与健康确认；助手侧请求校验/锁/进程协调为 `--selftest` 与构建验证）。
- 发布：UPD-042、043、044（清单生成/签名、草稿→上传→GitHub 回读复核→发布、测试产物与上传产物哈希一致；`tool/build_update_release.ps1` 已生成并验证 1.9.0/1.9.1 候选产物；回读与发布流程有假 gh runner 自动测试）。

**已实现但真实环境证据不足（保持 `NOT RUN` 或在下一步复跑）**

- UPD-009：代码没有网络类型分支（`update_network_boundary_test` 明确禁止 connectivity/NetworkType/metered 等判断），热点/计费网络的真实行为仍需人工记录。

- UPD-021：主程序侧（文件锁 + 同进程互斥 + PID/启动时间记录）与助手侧锁均已实现，并有自动测试。
- UPD-026：已加静态门禁 `test/architecture/update_no_popup_test.dart`（更新相关代码不得出现 showDialog/底部弹层/ScaffoldMessenger/系统通知/直接 launchUrl），设置页打开说明失败改为行内文本，不再用 SnackBar。
- UPD-028：规划规则页、课程编辑页、固定日程编辑器、保护时间编辑器、任务编辑器、周期目标编辑器与任务详情页内联草稿（期望时段/剩余分钟）已接入（帧后汇报，保存/离开时清除；文本监听只在文本变化时算脏，光标/选区变化不误报；纯查看有测试）。设置页为即时保存或模态对话框，不产生页面级未保存状态。
- UPD-034、038、040：AUMID 启动、自动回退与最小恢复窗口的代码路径已写，回退基线的建立与校验有自动测试；`--apply --dry-run` 只覆盖部署前，真实部署/启动/回退演练未执行。
- UPD-036：迁移本身在 drift 事务中执行且既有迁移测试覆盖；本期未新增"迁移失败 → 回退"的端到端证据。
- UPD-039：已实现——同一目标连续三次下载/验证失败后改为 `UPDATE_DOWNLOAD_RETRY_EXHAUSTED`（不可重试、无下次时间）；回退过的版本写入 `pausedTargetVersion`，再次检查不会自动下载，只有用户显式重试才恢复。

**未执行（需要真实 Windows 与正式产物）**

- UPD-045（Windows 10/11 矩阵）、UPD-046（1.8.1 → 1.9.0 数据）、UPD-047（1.9.0 → 1.9.1 自动升级）。
  已提供可复现脚本 	ool/update_e2e.ps1（记录包身份、数据指纹与升级结果，输出 JSON 证据），
  以及 	ool/build_update_helper.ps1（构建助手、自检、复制进 Release 输出）；两项仍需在真实 Windows 上执行并保留记录。
- 真实 GitHub 上的上传与回读（`publish` 已实现完整流程与自动测试，但本环境未连 GitHub 执行，需发布机留记录）。

**与规格的已知偏差（需在正式启用前处理）**

1. `nativeUpdaterEnabled` 已保留为编译期开关（`lib/application/update/update_feature_flag.dart`）：
   关闭时不显示入口、不自动检查/下载、不建立基线。因旧实现已删除，实际默认值是 `true`；
   正式发布必须显式传 `--dart-define=BEST_PLANNING_NATIVE_UPDATER=true`，并在完成门禁与回滚演练前谨慎开启。
2. 左下角入口的位置与状态在窗口高度很小时可能挤压导航栏；尚未做小窗口截图验证。
3. 快照只覆盖数据库与更新状态；设置与偏好都在数据库内，因此没有额外文件。
4. 助手的 MSIX 签名预检依赖普通进程令牌；受限环境下只验证了构建与 `--selftest`。
## 8. UPD-001～UPD-048 映射

图例：`单元`＝Dart 单元/组件测试；`界面`＝widget 测试；`原生`＝C++ 助手测试或脚本；`人工`＝必须在真实 Windows 上执行并留记录；`未跑`＝本期无法在本环境证明，记录中保持 `NOT RUN`。

| ID | 计划证据（测试名/门禁） | 类型 | 状态 |
| --- | --- | --- | --- |
| UPD-001 | `update_manifest_repository_test`：`只请求固定清单地址且不调用 Releases API`；`update_network_boundary_test`：`旧 Releases API 客户端已删除` | 单元/架构 | 待实现 |
| UPD-002 | `update_manifest_repository_test`：`304 且缓存有效时用缓存清单继续版本比较` | 单元 | 待实现 |
| UPD-003 | `update_manifest_repository_test`：`304 但缓存损坏时去掉条件头完整重试` | 单元 | 待实现 |
| UPD-004 | `update_orchestrator_test`：`网络失败是暂时无法确认而不是无更新` | 单元 | 待实现 |
| UPD-005 | `update_status_projection_test`：`只有已验证清单比较后才显示已是最新` | 界面 | 待实现 |
| UPD-006 | `json_canonicalizer_test`（RFC 8785 向量）＋`ed25519_manifest_verifier_test`：`签名覆盖规范化 payload` | 单元 | 待实现 |
| UPD-007 | `update_manifest_test`：`未知字段被拒绝`、`不支持的 schemaVersion 被拒绝` | 单元 | 待实现 |
| UPD-008 | `update_manifest_repository_test`：`重定向到白名单外域名被拒绝`、`超过 5 次重定向被拒绝` | 单元 | 待实现 |
| UPD-009 | `update_check_policy_test`：`任意网络类型下自动下载` | 单元 | 待实现 |
| UPD-010 | `resumable_package_downloader_test`：`从 Range 偏移继续下载` | 单元 | 待实现 |
| UPD-011 | `resumable_package_downloader_test`：`200 清空重下`、`416 按本地完整性处理` | 单元 | 待实现 |
| UPD-012 | `resumable_package_downloader_test`：`更高版本出现时旧下载作废` | 单元 | 待实现 |
| UPD-013 | `update_disk_space_test`：`空间不足暂停且保留分段` | 单元 | 待实现 |
| UPD-014 | `update_package_verifier_test`：`大小和 SHA-256 不一致时拒绝` | 单元 | 待实现 |
| UPD-015 | `windows_update_bridge_test`：`签名与证书链由 Windows 验证`（假桥断言调用）；`原生`：`helper --verify` 回放 | 组件/原生 | 待实现 |
| UPD-016 | `update_package_verifier_test`：`Publisher/Identity/PFN/架构不一致均拒绝` | 单元 | 待实现 |
| UPD-017 | `update_version_test`：`候选版本必须严格高于当前 MSIX 版本` | 单元 | 待实现 |
| UPD-018 | `update_manifest_test`：`撤回版本不能下载或安装` | 单元 | 待实现 |
| UPD-019 | `file_update_state_store_test`：`原子保存`、`损坏状态不安装并重建` | 单元 | 待实现 |
| UPD-020 | `update_state_test`：`非法跳转被拒绝且状态不变` | 单元 | 待实现 |
| UPD-021 | `file_update_lock_test`：`第二把锁被拒绝`、`PID 复用不算陈旧锁` | 集成 | 待实现 |
| UPD-022 | `update_indicator_test`：`六个主页面都显示同一入口` | 界面 | 待实现 |
| UPD-023 | `update_indicator_test`：`就绪前不可点击安装` | 界面 | 待实现 |
| UPD-024 | `update_indicator_test`：`点击就绪图标不弹二次确认` | 界面 | 待实现 |
| UPD-025 | `update_orchestrator_test`：`无人点击时不安装不退出` | 单元/时序 | 待实现 |
| UPD-026 | `update_no_popup_test`：`正常流程无弹窗/通知/浏览器跳转` | 界面/架构 | 待实现 |
| UPD-027 | `update_safety_coordinator_test`：`未保存编辑禁用安装且不丢内容` | 单元/界面 | 待实现 |
| UPD-028 | `update_safety_coordinator_test`：`纯查看不误判为脏` | 单元/界面 | 待实现 |
| UPD-029 | `update_safety_coordinator_test`：`业务事务结束后自动解除阻塞` | 单元 | 待实现 |
| UPD-030 | `update_safety_coordinator_test`：`专注状态不参与阻塞` | 单元 | 待实现 |
| UPD-031 | `update_helper_request_test`：`过期/重放/越界路径/令牌错误被拒绝` | 单元/原生 | 待实现 |
| UPD-032 | `update_package_verifier_test`：`助手安装前独立二次验证` | 原生 | 待实现 |
| UPD-033 | `helper_process_coordination_test`：`主程序与托盘退出前不部署` | 原生/人工 | 待实现 |
| UPD-034 | `windows_activation_test`：`用真实 AUMID 启动` | 原生/人工 | 待实现 |
| UPD-035 | `update_snapshot_service_test`：`安装前生成一致性快照` | 单元 | 待实现 |
| UPD-036 | `update_health_service_test`：`迁移在事务内失败可回退` | 单元/人工 | 待实现 |
| UPD-037 | `update_health_service_test`：`健康确认含实际版本与核心初始化` | 单元 | 待实现 |
| UPD-038 | `rollback_controller_test`：`健康失败满足条件自动回退` | 原生/人工 | 待实现 |
| UPD-039 | `update_retry_policy_test`：`同一失败目标不会无限自动安装` | 单元 | 待实现 |
| UPD-040 | `rollback_controller_test`：`回退失败只显示最小恢复窗口` | 原生/人工 | 待实现 |
| UPD-041 | `update_log_store_test`：`日志不含业务内容与敏感字段` | 单元/隐私扫描 | 待实现 |
| UPD-042 | `update_pipeline_test`：`从成品生成大小/哈希/清单` | 单元 | 待实现 |
| UPD-043 | `update_pipeline_test`：`草稿 Release 完整验证后才发布` | 单元/脚本 | 待实现 |
| UPD-044 | `update_pipeline_test`：`测试产物与上传产物哈希一致` | 单元 | 待实现 |
| UPD-045 | Windows 10/11 真实升级矩阵记录 | 人工 | NOT RUN |
| UPD-046 | 1.8.1 → 1.9.0 手动安装后数据对比 | 人工 | NOT RUN |
| UPD-047 | 1.9.0 → 1.9.1 自动升级演练 | 人工 | NOT RUN |
| UPD-048 | `update_network_boundary_test`：`旧更新实现已删除`＋`rg` 审计记录 | 架构 | 待实现 |

> UPD-045～047 需要两台以上真实 Windows 与已签名正式版本，本环境只能给出可执行步骤与记录模板；在完成前不得把本子系统标为已实现（规格 §23）。

## 9. 测试策略

### 9.1 分层

- **单元**：`test/domain/update/`、`test/infrastructure/update/`、`test/application/update/`。纯 Dart，不触网、不碰真实 Windows API。
- **组件**：本地 `HttpServer` 模拟 200/206/304/416/重定向；临时目录模拟磁盘与状态文件。
- **界面**：`test/features/shell/update_indicator_test.dart`、`test/features/settings/update_page_test.dart`。
- **架构**：更新网络边界（唯一出网口）、旧实现删除、助手依赖白名单（不出现 PowerShell/批处理调用）。
- **原生**：`windows/update_helper` 自带 `--selftest`（请求校验、路径越界、签名结论解析），由 `tool/run_update_helper_tests.ps1` 驱动。
- **端到端**：`tool/update_e2e.ps1` 在真实 Windows 上执行安装/升级/回退，输出记录 JSON。

### 9.2 永久回归（规格 §20.2）

1. 限流/失败不显示最新版 → `update_orchestrator_test` + `update_manifest_repository_test`。
2. `304` 有缓存 → 用缓存；无缓存 → 完整重试。
3. 非标准历史 Tag（`v1.8.1-build45`）不影响新协议 → `update_version_test`。
4. 网络失败、空内容、解析失败不进入 `upToDate`。
5. Range/忽略 Range/416/远端变更。
6. 长度、哈希、签名、Publisher、Identity、PFN、架构、版本不一致均阻止安装。
7. 主程序验证后替换文件能被助手二次验证发现。
8. 五种界面状态的入口表现。
9. 未保存编辑禁用安装且不丢；纯查看不误阻塞。
10. 连续点击不启动多个助手。
11. 正常流程无弹窗/通知/浏览器。
12. 安装失败保留旧版；启动失败恢复旧包与数据。
13. 1.9.0→1.9.1 在 Windows 10/11 通过（人工）。

### 9.3 门禁命令

```powershell
& G:\best-planing\.tooling\fx.ps1 analyze --no-pub
& G:\best-planing\.tooling\fx.ps1 test --no-pub
& G:\best-planing\.tooling\fx.ps1 test --no-pub test/architecture
& G:\best-planing\.tooling\fx.ps1 test --no-pub test/domain/update test/infrastructure/update test/application/update test/features/shell test/features/settings
```

## 10. 迁移与开关

1. `nativeUpdaterEnabled` 由 `lib/application/update/update_feature_flag.dart` 提供，默认 `false`。
2. 开关关闭：`main.dart` 装配旧 `UpdateService`，`/settings/update` 保持旧页面；不产生新状态文件、不发新请求。
3. 开关打开：`main.dart` 装配 `UpdateOrchestrator` 与新页面；旧 `GithubReleaseClient` 不再被构造。
4. 正式启用同时删除旧实现（规格 §18 第 12 步、UPD-048）；删除前架构测试允许两者共存但禁止同时装配。
5. 过渡发布按规格 §19：1.8.1 手动装 1.9.0；1.9.0 建立自身回退基线；1.9.1 完成首次自动升级。

## 11. 风险与应对

| 风险 | 应对 |
| --- | --- |
| 本环境无法证明真实 MSIX 部署/回退 | 原生助手自带 `--selftest` 与脚本；矩阵项保持 `NOT RUN`，不冒充通过 |
| Ed25519 私钥只有一份 | 私钥存放在仓库外签名目录；`keyId` 允许集合支持重叠轮换（规格 §10.3） |
| 下载器与 HTTP 实现细节偏差 | 以本地 `HttpServer` 覆盖 200/206/304/416/重定向/截断，逐条对应 UPD-010～014 |
| 更新入口改动影响主界面 | 入口只读编排器快照；六个顶层页面的 widget 测试断言位置与状态不变 |
| 迁移期两套逻辑并行 | `nativeUpdaterEnabled` 互斥装配 + 架构测试禁止同时构造 |

## 12. 完成定义（与规格 §23 对齐）

- UPD-001～044、048 均有对应测试且通过；UPD-045～047 有可执行记录，未执行时标 `NOT RUN`。
- `flutter analyze` 无问题；全量测试通过。
- 原生助手可构建并能通过 `--selftest`。
- 发布流水线可在只有成品 MSIX 的情况下生成并验证签名清单。
- 旧 GitHub Releases API 链路已删除（UPD-048）。
- 正常流程无弹窗、无系统通知、无浏览器跳转。
- 安装失败保留旧版本；启动失败按 §13.4 回退（真实环境记录）。





