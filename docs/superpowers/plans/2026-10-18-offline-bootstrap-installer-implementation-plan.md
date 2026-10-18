# 优计主义 Windows 离线单文件安装器实施计划

日期：2026-10-18
依据：`docs/superpowers/specs/2026-10-18-offline-bootstrap-installer-design.md`（下称"规格"）
分支：`feature/native-implementation`
状态：**代码完成、发布验收未完成**（规格 §18）。离线 Setup 的自动化测试、真实构建、签名、发布门禁与一次真实 `1.9.0.0 → 1.10.0.0` 原位升级已完成；§9 的 P0 更新落盘修复已完成并在真实安装态通过（`docs/testing/v1.10.0-packaged-update-storage-acceptance.md`）。Windows 10 与干净虚拟机矩阵、标准账户凭据场景、故障注入矩阵、`1.9.0 → 1.10.0 → 回退` 演练尚未执行。

> **发布阻断补充（P0，2026-10-18）：** 本计划除离线 Setup 外，还必须修复已在真实
> MSIX 安装环境复现的应用内更新落盘故障：安装包已经完整下载并通过长度与 SHA-256
> 校验，但 `%LOCALAPPDATA%` 经 MSIX 文件系统重定向后落入受保护目录，导致
> `state.json` 临时文件替换以及 `package.msix.partial → package.msix.ready` 重命名失败，
> 最终误报 `UPDATE_DOWNLOAD_PERMISSION_DENIED`。§9 是独立、不可省略的工作包；§9
> 未通过真实已安装 MSIX 验收时，即使 Setup 已完成，也不得发布 `1.10.0`。

## 1. 范围与冻结事实

实现规格 §7 的双进程结构：

```text
普通权限主进程（界面 / 校验 / 部署 / 启动）
        │ 一次 UAC
        └─ 提权辅助进程（只写 LocalMachine\TrustedPeople，写完即退）
```

冻结值（只读，来自 `pubspec.yaml` → `msix_config`）：

| 事实 | 值 |
| --- | --- |
| Identity | `ShuoZhuang.PersonalPlanner` |
| Publisher | `CN=Shuo Zhuang, O=Personal User, C=CN` |
| Family | `ShuoZhuang.PersonalPlanner_v9555qkaxdyym` |
| 架构 | `x64` |
| 目标版本 | `1.10.0+47` / MSIX `1.10.0.0` |
| 产物 | `BestPlanning_Setup_1.10.0_x64.exe`、`BestPlanning_Portable_1.10.0_x64.zip`、`BestPlanning_1.10.0.0_x64.msix`、`update-manifest.json`、`SHA256SUMS.txt` |

## 2. 代码边界

```text
windows/native_shared/              共享原生库（更新助手与安装器唯一实现）
  include/native_shared/
    planner_identity.h              包身份常量的唯一定义处
    package_inspector.h             MSIX 身份/签名检查（从 update_helper 迁入）
    zip_reader.h                    降级路径的 ZIP 读取
    package_deployment.h            部署、登记查询、AUMID 解析与激活
    deployment_errors.h             HRESULT → 稳定错误码 → 用户可读原因
    text.h                          UTF-8/UTF-16、SHA-256、路径边界
  src/                              对应实现（package_inspector 等原样迁入）

windows/update_helper/              改为链接 native_shared，行为不变
installer/
  CMakeLists.txt
  include/
    installer_state.h               状态与合法跳转、退出码
    installer_errors.h              错误码、界面文案、退出码映射
    payload_metadata.h              内嵌元数据模型与严格解析
    installer_log.h                 会话日志（无业务数据）
  src/
    main.cpp                        命令行分派：普通 / --elevated / --verify-embedded / --selftest / --plan
    installer_controller.cpp        唯一编排入口
    payload_reader.cpp              读取 RCDATA 资源
    secure_session.cpp              随机会话目录、限制性 ACL、拒绝重解析点、一次性令牌
    package_verifier.cpp            大小/SHA-256/身份/签名者/信任状态
    certificate_manager.cpp         指纹、公钥、TrustedPeople 存在性与导入、安全回收
    elevation_broker.cpp            命名管道 + nonce + 有限命令协议
    package_deployer.cpp            以发起用户部署、登记查询、拒绝降级
    application_launcher.cpp        从实际登记结果解析 AUMID 并激活
    installer_state_machine.cpp     转换记录与取消点
    installer_ui.cpp                Win32 对话框：准备/等待关闭/进度/完成/错误
    installer_log.cpp
  tools/embed_payload.cpp           把 MSIX、公开证书、元数据写成 RCDATA
  tests/                            单元测试可执行文件（自建断言，无外部依赖）
tool/
  build_offline_installer.ps1       构建 stub → 内嵌 → 签名 → 自检
  verify_release_assets.ps1         发布门禁（名称/版本/哈希/manifest）
  installer_tests.ps1               组件测试（真实 MSIX、篡改载荷、错误证书）
  build_update_release.ps1          改为产出 5 个正式产物（含 Setup EXE）

lib/platform/update/
  windows_update_storage.dart       从原生层取得包身份感知的 LocalCacheFolder
lib/infrastructure/update/
  update_storage_layout.dart        接收已解析根目录；不再自行猜测已打包应用路径
  atomic_file.dart                  保留同目录刷新后替换，并把底层 OS 错误交给调用方
  resumable_package_downloader.dart 保留已校验 partial；记录最终替换的真实失败原因
windows/runner/
  update_storage_channel.h/.cpp     通过 ApplicationData.Current.LocalCacheFolder 返回缓存根
test/platform/update/
  windows_update_storage_test.dart  原生通道成功、失败与非 Windows 回退
test/infrastructure/update/
  update_storage_layout_test.dart   包身份路径不经环境变量二次拼接
  atomic_file_test.dart             首次写入、覆盖、失败清理和错误详情
  resumable_package_downloader_test.dart
                                    下载完成后的成功提升与失败诊断
integration_test/
  packaged_update_storage_test.dart 已安装 MSIX 内的 state/partial/ready/重启恢复证据
```

依赖方向固定为 `installer → native_shared`、`update_helper → native_shared`，禁止互引。

## 3. 内嵌资源格式

| 资源 | 类型 | ID | 内容 |
| --- | --- | --- | --- |
| MSIX | `RCDATA` | 101 | 最终已签名包的完整字节 |
| 公开证书 | `RCDATA` | 102 | DER 编码，不含私钥 |
| 元数据 | `RCDATA` | 103 | UTF-8 JSON（下表） |

元数据字段：`schemaVersion`、`installerVersion`、`appVersion`、`msixVersion`、`identityName`、`publisher`、`familyName`、`architecture`、`packageSizeBytes`、`packageSha256`、`certificateSha256`、`certificateThumbprint`、`minimumWindowsBuild`、`assetFileName`。

生成规则：全部由同一次发布构建从成品读取（`update_helper --verify` 与证书解析），不接受人工复制。

## 4. 状态机与退出码

状态与规格 §9.1 一致；转换表写在 `installer_state_machine.cpp`，非法跳转直接失败且不执行系统写入。

| 退出码 | 触发条件 |
| --- | --- |
| 0 / 10 / 20 / 21 / 30 / 31 / 40 / 41 / 42 / 50 / 60 / 70 / 99 | 规格 §10.4 原样实现 |

错误码（`installer_errors.h`）到退出码的映射是唯一来源，界面文案也从同一表派生。

## 5. 提权协议

- 管道名：`\\.\pipe\BestPlanningSetup-<32 字节随机 hex>`，安全描述符只允许 `IU`（发起用户）与 `BA`（管理员）。
- 令牌：主进程生成 32 字节 nonce，经命令行传给提权进程**仅用于识别**；载荷摘要与证书指纹由提权进程从自身 EXE 只读资源重新读取后自算，不采信命令行。
- 消息：长度前缀 JSON，命令只有 `verify-and-trust-certificate`，字段为 `protocolVersion`、`nonce`、`metadataSha256`、`packageSha256`、`certificateThumbprint`。未知命令、额外字段、任意路径一律拒绝。
- 提权进程只做三件事：重读资源 → 校验 MSIX 签名与固定证书 → 写 `LocalMachine\TrustedPeople`；随后返回 `{ok, alreadyPresent, thumbprint, errorCode}` 并退出。
- 提权进程绝不调用包部署接口；包部署始终由普通权限主进程以发起用户身份完成。

## 6. 测试映射

| 规格条目 | 测试 |
| --- | --- |
| §16.1 版本比较、拒绝降级 | `version_policy_test.cpp` |
| §16.1 Identity/Publisher/架构比较 | `version_policy_test.cpp`、`payload_verifier_test.cpp` |
| §16.1 长度与 SHA-256 | `payload_verifier_test.cpp` |
| §16.1 证书指纹/公钥/主题 | `certificate_policy_test.cpp` |
| §16.1 状态机合法转换 | `state_machine_test.cpp` |
| §16.1 错误码映射 | `error_mapping_test.cpp`、`deployment_errors_test.cpp` |
| §16.1 证书安全回收判定 | `certificate_policy_test.cpp` |
| §16.1 文件名与 manifest 一致性 | `tool/verify_release_assets.ps1` 门禁 |
| §16.2 资源提取 / 篡改字节 / 替换证书 / 错误身份 / 重解析点 / nonce / 未知命令 / 无 PowerShell | `installer_tests.ps1`（真实 MSIX 与 Setup） |
| P0 更新缓存根 | `windows_update_storage_test.dart`、`update_storage_layout_test.dart` |
| P0 状态文件原子替换 | `atomic_file_test.dart`、`packaged_update_storage_test.dart` |
| P0 `.partial → .ready` | `resumable_package_downloader_test.dart`、`packaged_update_storage_test.dart` |
| P0 真实错误可诊断 | 下载器/状态存储测试断言 `FileSystemException.osError` 已写入日志且界面仍只显示安全文案 |

组件测试使用 `--verify-embedded`（只校验不写系统）与 `--plan`（走完预检与校验后停止）作为可重复的非破坏性证据。

## 7. 提交顺序

1. `refactor: share the MSIX inspector between the helper and the installer`
2. `feat: build the offline setup payload verifier and session`
3. `feat: broker one elevation for the certificate trust only`
4. `feat: deploy and verify the package as the initiating user`
5. `feat: add the setup user interface and state machine`
6. `test: cover payload, certificate and state policies`
7. `build: embed the payload and gate the release assets`
8. `fix: use package-aware storage for native updates`
9. `test: verify update finalization inside the installed MSIX`
10. `release: target 1.10.0 build 47 with the offline setup`
11. `docs: record the offline installer plan and acceptance status`

## 8. 验收状态口径

本计划执行完后：

- 单元/组件测试、构建、内嵌、签名与版本门禁必须是**真实通过**的记录；
- 应用内更新必须在**真实安装的 MSIX 进程**中完成 `state.json` 原子写入、完整包下载、
  `.partial → .ready`、重启恢复、助手读取与安装；只在源码运行或临时目录通过不算验收；
- 日志必须保留实际 Windows 错误码、源路径、目标路径与操作阶段；用户界面不得暴露访问
  令牌、完整下载查询参数或本地个人目录；
- 真实安装（证书导入 + 部署 + 启动）在本开发机可行时执行，并记入验收文档；
- Windows 10/11 干净虚拟机矩阵、标准账户输入管理员凭据场景、故障注入矩阵，若无真实机器证据，一律标 `NOT RUN`，不得声明发布完成（规格 §17、§18）。

## 9. P0：修复已安装 MSIX 中的更新包落盘失败

### 9.1 已确认事实与禁止误判

真实故障样本同时满足：

- `1.9.0.0` 回退基线 `.partial` 的长度与 SHA-256 和 GitHub Release 完全一致；
- `1.9.1.0` 更新包 `.partial` 的长度与 SHA-256 和 GitHub Release 完全一致；
- `.ready` 与 `state.json` 均未生成；
- 日志同时出现 `UPDATE_STATE_WRITE_FAILED` 与 `UPDATE_DOWNLOAD_PERMISSION_DENIED`；
- 实际目录位于包重定向路径
  `...\\Packages\\ShuoZhuang.PersonalPlanner_v9555qkaxdyym\\LocalCache\\Local\\BestPlanning\\Updates`，
  且文件被标记为 `Application Protected`。

因此不得把本问题归因于网络、GitHub 限流、资产损坏、SHA-256、MSIX 签名、证书信任或
用户没有管理员权限。网络重试不得作为修复；删除 `.partial` 后重下也不得作为修复。

### 9.2 冻结实现决策

1. 已打包 Windows 应用的更新缓存根必须由原生 Windows API
   `ApplicationData.Current.LocalCacheFolder.Path` 返回；Dart 不得再用
   `Platform.environment['LOCALAPPDATA']` 推导包身份目录。
2. 原生通道固定为 `personal_planner/update_storage`，方法固定为 `getLocalCacheRoot`；成功
   返回绝对路径字符串，失败返回稳定错误码和原始 HRESULT/Win32 code。
3. 最终更新根固定为 `<LocalCacheFolder>\\BestPlanning\\Updates`。便携版或无包身份运行时
   才允许回退到 `<LOCALAPPDATA>\\BestPlanning\\Updates`；回退必须在日志中标明
   `unpackaged-fallback`，不得在已识别包身份后静默回退。
4. `state.json` 临时文件必须与目标文件同目录；写入后必须 `flush`、关闭句柄，再执行替换。
   任一步失败必须清理本次临时文件，但不得删除最后一份有效 `state.json`。
5. 包文件只有在长度和 SHA-256 都通过后才允许从 `.partial` 提升为 `.ready`。提升失败时
   保留已验证的 `.partial`，不得重新下载；下一次启动应先重新验证并再次尝试提升。
6. `FileSystemException` 不得再无条件压扁为一个无详情错误。领域错误码仍可使用
   `UPDATE_DOWNLOAD_PERMISSION_DENIED`，但诊断日志必须包含操作名、脱敏后的源/目标路径、
   `osError.errorCode` 与 `osError.message`。
7. 旧的受保护缓存只做尽力清理：能读取则删除已经验证且不再使用的旧文件，不能读取时记录
   一条日志并继续；迁移失败不得阻止应用启动，也不得把旧 `.partial` 当作新路径的 `.ready`。

### 9.3 Task A：先锁定失败边界（TDD）

**Files:**

- Modify: `test/infrastructure/update/resumable_package_downloader_test.dart`
- Modify: `test/infrastructure/update/update_store_test.dart`
- Create: `test/infrastructure/update/atomic_file_test.dart`

- [ ] 写失败测试：完整且哈希正确的 `.partial` 在最终提升失败时必须保留，结果包含稳定领域
  错误码与可供日志记录的底层错误详情；不得发起第二次 HTTP 请求。
- [ ] 写失败测试：覆盖已有 `state.json` 失败时旧文件内容保持不变，仅删除本次 `.tmp`。
- [ ] 写失败测试：进程重启后发现“完整且哈希正确的 `.partial`、没有 `.ready`”时直接重试
  提升，不重新下载。
- [ ] 运行：
  `flutter test test/infrastructure/update/resumable_package_downloader_test.dart test/infrastructure/update/update_store_test.dart test/infrastructure/update/atomic_file_test.dart`。
  修复前必须至少有一条因“详情丢失或错误地重新下载”失败，不能接受测试意外全绿。

### 9.4 Task B：使用包身份感知的更新缓存根

**Files:**

- Create: `windows/runner/update_storage_channel.h`
- Create: `windows/runner/update_storage_channel.cpp`
- Modify: `windows/runner/flutter_window.cpp`
- Modify: `windows/runner/CMakeLists.txt`
- Create: `lib/platform/update/windows_update_storage.dart`
- Modify: `lib/infrastructure/update/update_storage_layout.dart`
- Modify: `lib/main.dart`
- Create: `test/platform/update/windows_update_storage_test.dart`
- Create: `test/infrastructure/update/update_storage_layout_test.dart`

- [ ] 原生层实现 `getLocalCacheRoot`：先判断包身份，再调用
  `winrt::Windows::Storage::ApplicationData::Current().LocalCacheFolder().Path()`；禁止接收 Dart
  传入的任意路径。
- [ ] Dart 层实现 `WindowsUpdateStorage.resolveRoot()`；已打包环境的原生失败必须向上传递，
  只有无包身份运行才使用明确的环境变量回退。
- [ ] 将 `main.dart` 的更新器装配改为先解析根目录，再构造
  `UpdateStorageLayout(root: resolvedRoot)`；业务数据库与用户数据路径保持不变。
- [ ] 测试断言：已打包路径只追加一次 `BestPlanning\\Updates`；原生报错不回退到虚拟化的
  `%LOCALAPPDATA%`；非 Windows/未打包开发模式仍可运行。
- [ ] 运行：
  `flutter test test/platform/update/windows_update_storage_test.dart test/infrastructure/update/update_storage_layout_test.dart`，必须全部 PASS。

### 9.5 Task C：保留可恢复文件并输出真实诊断

**Files:**

- Modify: `lib/infrastructure/update/atomic_file.dart`
- Modify: `lib/infrastructure/update/update_store.dart`
- Modify: `lib/infrastructure/update/resumable_package_downloader.dart`
- Modify: `lib/application/update/update_orchestrator.dart`
- Modify: `lib/domain/update/update_failure.dart`
- Modify: `test/infrastructure/update/atomic_file_test.dart`
- Modify: `test/infrastructure/update/resumable_package_downloader_test.dart`
- Modify: `test/application/update/update_orchestrator_test.dart`

- [ ] 为原子替换和包提升保留结构化失败详情；日志写入原始 Windows 错误码，但界面继续显示
  稳定、可翻译且不泄露完整用户路径的文案。
- [ ] 将已完整下载的 `.partial` 识别为“等待提升”而不是“需要重新下载”；重新验证长度和
  SHA-256 后直接提升。
- [ ] 确保失败清理只删除本次临时文件或哈希错误的包；权限/占用错误不得删除已验证包。
- [ ] 运行 Task A 与 `test/application/update/update_orchestrator_test.dart`，必须全部 PASS。

### 9.6 Task D：真实安装态回归与发布门禁

**Files:**

- Create: `integration_test/packaged_update_storage_test.dart`
- Modify: `tool/update_e2e.ps1`
- Modify: `tool/verify_release_assets.ps1`
- Create: `docs/testing/v1.10.0-packaged-update-storage-acceptance.md`

- [ ] 构建并安装签名的 `1.10.0.0` MSIX，确认测试进程具有正式包身份；源码运行结果不能替代。
- [ ] 在安装态执行：写 `state.json` → 覆盖 `state.json` → 下载测试 MSIX → 校验长度与
  SHA-256 → `.partial → .ready` → 关闭并重启 → 恢复为 `ready`。
- [ ] 断言 `.ready` 位于 `ApplicationData.Current.LocalCacheFolder` 派生目录中，更新助手能够
  在同一根目录内读取它；不得再出现旧的 `LocalCache\\Local\\BestPlanning` 新写入。
- [ ] 注入目标占用/访问拒绝，断言保留 `.partial`、记录真实 Windows 错误码、下一次解除
  占用后无需重新下载即可恢复。
- [ ] 执行 `tool/update_e2e.ps1` 的 `1.9.0 → 1.10.0 → 回退 1.9.0` 路径并保存日志、文件树、
  哈希和安装版本证据。若当前机器不能安全执行，记录 `NOT RUN`，状态保持发布阻断。
- [ ] 将 `verify_release_assets.ps1` 增加门禁：缺少安装态更新存储验收记录或记录不是 PASS
  时，正式 Release 构建失败。

### 9.7 完成定义

以下条件必须同时满足，才可将本 P0 标为完成：

1. `UpdateStorageLayout.localAppData()` 不再用于已打包 Windows 生产装配；
2. 真实安装态的 `state.json`、`.partial`、`.ready` 全链路成功；
3. 覆盖写入、文件占用、权限失败和重启恢复均有自动化证据；
4. 日志含真实 OS 错误码，界面不泄露敏感路径或带签名查询参数的完整 URL；
5. Setup 覆盖升级与应用内更新使用同一 `1.10.0.0` 正式 MSIX 字节；
6. 验收文档为 PASS，且发布门禁实际拒绝缺证据的构建。

任何一项不满足，只能声明“离线安装器完成、应用内更新修复未完成”，不得发布
`v1.10.0`，也不得向用户宣称更新问题已经解决。

### 9.8 实施结果（2026-10-18）

| 任务 | 状态 | 证据 |
| --- | --- | --- |
| Task A：失败边界测试（TDD） | 完成 | `atomic_file_test.dart`（5）、`update_store_test.dart`（新增覆盖失败）、`resumable_package_downloader_test.dart`（新增 3 个落盘/恢复用例） |
| Task B：包身份感知的缓存根 | 完成 | `windows/runner/update_storage_channel.*`、`lib/platform/update/windows_update_storage.dart`、`main.dart` 装配；`windows_update_storage_test.dart`（6）、`update_storage_layout_test.dart`（4） |
| Task C：保留可恢复文件与真实诊断 | 完成 | `atomic_file.dart` 的 `AtomicFileException`（操作名/脱敏路径/OS 错误码）、`_promote` 保留 `.partial`、编排器 `stateWriteFailed` 带详情 |
| Task D：真实安装态回归与门禁 | 完成（部分 NOT RUN） | 安装态自检 PASS：`docs/testing/v1.10.0-packaged-update-storage-acceptance.md`；门禁新增验收记录检查；`tool/update_e2e.ps1` 增加安装态自检步骤；`1.9.0 → 1.10.0 → 回退` 与 Windows 10 仍为 `NOT RUN` |

§9.7 的六条完成条件逐项对照：

1. 已打包生产装配不再使用 `UpdateStorageLayout.localAppData()`（`main.dart` 只通过
   `WindowsUpdateStorage.resolveRoot()` 得到根；`localAppData` 仅保留给便携版/测试）。
2. 真实安装态全链路成功（见验收记录第 3 节报告）。
3. 覆盖写入、文件占用、权限失败、重启恢复均有自动化用例。
4. 日志记录 `op=…` 与真实 `osError.errorCode`；详情只保留"父目录/文件名"，不含完整用户目录。
5. Setup 内嵌的 MSIX 与应用内更新使用同一份 `1.10.0.0` 字节（发布门禁校验哈希一致）。
6. 验收记录 `结论：PASS`；`verify_release_assets.ps1` 在缺少记录或不是 PASS 时失败。

## 10. 离线安装器实施结果（2026-10-18）

### 9.1 已交付

- `windows/native_shared/`：包身份/签名检查、ZIP 降级读取、部署与 AUMID、部署错误映射、
  文本与哈希工具；`update_helper` 与安装器共用同一份实现。
- `installer/`：12 个头文件 + 13 个实现文件，覆盖状态机、载荷读取、元数据、受保护会话、
  载荷校验、证书策略、提权代理、部署、启动、日志与 Win32 界面；`tools/embed_payload.cpp`
  负责资源内嵌；`tests/` 含 5 个测试文件（36 个用例）。
- `tool/`：`build_offline_installer.ps1`、`verify_release_assets.ps1`、`installer_tests.ps1`，
  并把 `build_update_release.ps1` 改写为产出五个正式产物。
- 版本：`pubspec.yaml` `1.10.0+47` / MSIX `1.10.0.0`，`backup_assembly.dart` 同步。

### 9.2 验证结果

| 项目 | 结果 |
| --- | --- |
| `installer_tests.exe` | 36/36 通过 |
| `tool/installer_tests.ps1` | 10/10 组通过 |
| `tool/verify_release_assets.ps1 -RequireSignature` | 通过（含 Setup 签名与时间戳） |
| 真实原位升级 1.9.0.0 → 1.10.0.0 | 退出码 0，数据文件哈希/大小/修改时间不变 |
| 相同版本启动 / 重新安装 | 均退出码 0 |
| 证书导入 + 链复验 | 通过（移除证书后重新导入并复验） |
| 拒绝降级 | 退出码 60 |

### 9.3 未完成（发布阻断项）

规格 §16.3 的 Windows 10 / Windows 11 干净虚拟机矩阵、标准账户输入管理员凭据场景、
§16.5 故障注入、§16.4 业务数据逐项核对、五类界面截图，均尚未执行。
在这些证据齐备之前，本版本不得声明"正式完成"。