# 离线安装器 UAC 通信与证书信任修复实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复 `1.10.0+49` 与 `1.10.1+50` 单文件 Setup 在首次安装时无法完成 UAC 辅助进程通信的问题，使管理员账户和标准账户都能在一次 UAC 后完成固定证书信任，并由原始用户安装 MSIX。

**Architecture:** Setup 继续采用普通权限主进程与最小权限辅助进程的双进程结构。主进程用真正的 overlapped 命名管道等待 UAC 子进程，通过 `ShellExecuteExW` 返回的进程句柄取得预期 PID，再用 `GetNamedPipeClientProcessId` 核对实际连接者；32 字节随机 nonce、协议版本、载荷摘要和证书指纹继续参与双向握手。辅助进程不再依赖不稳定的直接父 PID，也不负责部署 MSIX。

**Tech Stack:** Windows Win32/C++20、`ShellExecuteExW`、overlapped named pipe、Windows Certificate Store、CMake/Visual Studio、PowerShell 发布脚本、Flutter Windows/MSIX。

**Spec:** `docs/superpowers/specs/2026-10-18-offline-bootstrap-installer-design.md`，重点执行 §7.1、§8.1、§8.5、§9、§10、§12、§14、§16～§18；本文是该规格针对 UAC 通信缺陷的修复计划。若两份文件冲突，以本文中更严格且针对真实故障的要求为准。

**Document status:** 2026-10-18 完成计划编写；生产代码尚未按本文修改，全部新增验收项初始状态为 `NOT RUN`。不得把文档完成度写成代码完成度。

## Global Constraints

- 修复发行版固定为应用 `1.10.2+51`、MSIX `1.10.2.0`、Git Tag `v1.10.2`；`1.10.0+49` 和 `1.10.1+50` 的 Setup 均视为已知缺陷产物。
- 不覆盖、不删除后重新创建 `v1.10.0` 或 `v1.10.1`；不替换旧 Release 中同名附件。旧 Release 只追加醒目的已知问题说明并指向 `v1.10.2`。
- Setup 进程清单继续使用 `asInvoker`。禁止把整个 Setup 改成 `requireAdministrator`，否则标准账户输入另一管理员凭据时可能把 per-user MSIX 安装给管理员账户。
- 正常流程只允许一次 UAC。辅助进程只校验并写入安装器内嵌的固定公开证书到 `LocalMachine\TrustedPeople`；它不能安装 MSIX、启动应用、接受任意路径或运行任意命令。
- 不调用 PowerShell、`cmd.exe`、`certutil.exe` 或外部脚本完成用户安装；Setup 内含完整 MSIX，断网必须可安装。
- 不降低命名管道 ACL，不授予 `Everyone`、`Authenticated Users` 或匿名用户访问；保留原始用户 SID、`SYSTEM`、`Builtin Administrators` 三类主体，并使用 `PIPE_REJECT_REMOTE_CLIENTS` 拒绝远程客户端。
- 不以增加超时时间作为修复。生产连接等待上限保持 `180000 ms`，辅助进程连接尝试上限保持 `20000 ms`；测试通过可注入的较短超时覆盖边界。
- 连接者身份由 `ShellExecuteExW` 返回的进程句柄和命名管道实际客户端 PID 共同确定。进程树中的直接父 PID 不得作为允许或拒绝证书写入的条件。
- 主进程完成客户端 PID、nonce、协议、命令、元数据 SHA-256、MSIX SHA-256、证书指纹核对前，辅助进程不得写证书。
- UAC 被拒绝、辅助进程提前退出、连接超时、连接者 PID 不符、握手不符和真实证书写入失败必须使用不同的日志 detail；用户界面至少区分“未获授权”“安全通信失败”“证书写入失败”。
- 任一失败必须保留 `finalState NotInstalled` 或真实查询所得状态。禁止因为通信失败而宣称证书导入失败，更不能宣称安装成功。
- 日志不得包含业务数据库、任务、课程、日程、偏好、管理员密码、令牌、私钥或完整用户文件清单。PID、Win32 错误码、退出码、版本、摘要和证书指纹可以记录。
- 所有代码改动采用 TDD：先新增会失败的测试，确认失败原因与目标缺陷相符，再写最小修复，最后跑定向与全量回归。
- 当前 `feature/native-implementation` 工作树含用户已有的 `docs/release/1.10.0-github-release-body.md` 修改。执行者不得覆盖或回退该修改；实现前应从包含 `1.10.1+50` 的真实发布提交创建独立工作树。
- 不允许两个代理或两个工作树同时修改 `installer/src/elevation_broker.cpp`、`installer/src/installer_controller.cpp` 或发布版本文件。

## Review Focus

- 标准账户在 UAC 中输入另一管理员账户凭据：证书写入机器存储，但 MSIX 必须登记给发起安装的标准账户。Task 6 的 `UAC-STD-01` 固定该行为。
- 非预期进程先连接随机管道：主进程必须在发送 ACK 前按客户端 PID 拒绝连接，且不得写证书。Task 1 的 `elevation_channel_rejects_unexpected_client_pid` 和 Task 5 的 `IPC-AUTO-05` 覆盖。
- 提权进程在连接前退出：主进程应立即报告真实退出码，不得等待三分钟或误报证书写入失败。Task 1 的 `elevation_channel_reports_child_exit_code` 覆盖。
- UAC 被用户取消：退出码必须仍为 `10`，不得创建证书、安装包或显示“安装证书失败”。Task 4 与 Task 6 的 `UAC-CANCEL-01` 覆盖。
- 管道连接成功后发生协议、资源摘要或证书指纹不一致：必须在证书写入前停止，并返回载荷/会话不一致错误。Task 3 的协议测试和 Task 5 的 `IPC-HANDSHAKE-01` 覆盖。

---

## 1. 事故证据与问题边界

### 1.1 已取得的跨设备日志

故障设备运行 `1.10.1+50` Setup，日志如下：

```text
setup version 1.10.1+50
state INITIALIZING -> PREFLIGHT_CHECK
target 1.10.1.0 app 1.10.1+50
preflight ok build=26200
state PREFLIGHT_CHECK -> EXTRACTING
extracted payload bytes=18571866
state EXTRACTING -> VERIFYING_PAYLOAD
payload verified sha256=2e9ed97099fa2420b95fc9ea8c5ba51aca29423e99ce79a4819b236a1c92608d
certificate not trusted yet
state VERIFYING_PAYLOAD -> REQUESTING_ELEVATION
requesting one elevation for certificate trust
failure INSTALLER_CERTIFICATE_IMPORT_FAILED detail=pipe-connect-timeout
state REQUESTING_ELEVATION -> FAILED_BEFORE_CHANGE
result FAILED_BEFORE_CHANGE
finalState NotInstalled
```

可据此确定：预检、载荷释放及 SHA-256 校验均已通过；失败位于 `REQUESTING_ELEVATION`，证书写入和 MSIX 部署均未开始。`INSTALLER_CERTIFICATE_IMPORT_FAILED` 是错误映射，不是已经发生证书写入失败的证据。

### 1.2 代码层已确认缺陷

| ID | 位置 | 现状 | 风险 |
| --- | --- | --- | --- |
| ROOT-01 | `installer/src/elevation_broker.cpp::CreateChannel` | `CreateNamedPipeW` 未设置 `FILE_FLAG_OVERLAPPED`，后续却向 `ConnectNamedPipe` 传入 `OVERLAPPED` | I/O 模式不一致，等待与取消行为不受代码契约保证 |
| ROOT-02 | `ParentIsSameExecutable` / `RunElevatedSession` | 辅助进程要求其直接父 PID 等于普通进程传入值 | UAC/AppInfo、跨账户凭据、进程枚举或访问限制可使辅助进程在连接前以 `3` 退出 |
| ROOT-03 | `ConnectToPipe`、`ReadMessage`、`WriteMessage` | 客户端以同步句柄打开管道，读函数却使用 overlapped；服务端修成 overlapped 后，现有同步写也不再满足统一 I/O 契约 | 只改创建标志会留下第二组 I/O 错误 |
| ROOT-04 | `RequestCertificateTrust` | 非 `ERROR_PIPE_CONNECTED` / `ERROR_IO_PENDING` 的连接错误、事件创建失败、等待失败、辅助进程退出都统一变成 `pipe-connect-timeout` | 丢失真正原因，无法诊断，也可能无谓等待 |
| ROOT-05 | `InstallerController::RunInteractive` | 除拒绝与资源不一致外，把 `TrustOutcome.error` 强制改成 `CertificateImportFailed` | 界面声称证书写入失败，实际可能尚未写入 |
| ROOT-06 | 既有验收 | 测试会话已经提权，日志明确为 `elevation skipped: process already elevated`；交互式 UAC 和标准账户场景标记 `NOT RUN` | 测试绕过了发生缺陷的生产路径 |

### 1.3 受影响版本

- `1.10.0+49`：首次加入单文件离线 Setup 时就包含 ROOT-01～ROOT-06。
- `1.10.1+50`：沿用相同通信实现，跨设备日志证明普通用户路径可失败。
- 已经安装成功的应用数据不因本缺陷损坏；问题集中在证书尚未信任时的首次安装、修复安装或跨设备安装入口。
- 已经信任发布证书的设备会跳过 UAC 信任路径，因此“某台机器安装成功”不能反证缺陷不存在。

## 2. 修复后的安全协议

### 2.1 正常顺序

```text
普通权限 Setup
  -> 创建随机 nonce 与第一实例命名管道（overlapped + 限制 ACL）
  -> ShellExecuteExW(runas) 启动同一 Setup EXE
  -> 从 hProcess 获取 launchedPid
  -> 同时等待 pipe-connect event 与 hProcess
  -> 管道连接时读取 actualClientPid
  -> 要求 actualClientPid == launchedPid
  -> 辅助进程发送 protocol=2、nonce、固定命令、资源摘要、证书指纹
  -> 主进程逐字段核对并回复 accepted
  -> 辅助进程再次校验内嵌载荷
  -> 仅写 LocalMachine\TrustedPeople
  -> 返回结构化结果
  -> 普通进程重新执行系统信任验证
  -> 普通进程以原始用户身份部署 MSIX
```

### 2.2 不再使用的条件

- 删除 `--parent` 参数。
- 删除 `ParentIsSameExecutable` 及其 Toolhelp 进程树扫描。
- 不尝试沿父进程链寻找原始进程。
- 不把相同 EXE 路径等同于相同会话；攻击者可以启动同一文件，真正的绑定来自 `hProcess` 的 PID、受限管道、一次性 nonce 和双向摘要握手。

### 2.3 管道与消息规则

- 管道名必须严格等于 `\\.\pipe\BestPlanningSetup-<64 个小写或大写十六进制字符>`，且后缀必须与 `--nonce` 相同；不能只验证 nonce 长度。
- 服务端 `CreateNamedPipeW` 的 open mode 必须包含：
  `PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE | FILE_FLAG_OVERLAPPED`。
- 服务端 pipe mode 必须包含 `PIPE_REJECT_REMOTE_CLIENTS`，不得允许网络侧连接本机安装会话。
- 客户端 `CreateFileW` 必须包含 `FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION`，防止普通权限服务端取得可用于模拟的管理员令牌；两端所有 `ReadFile` / `WriteFile` 均使用有效 `OVERLAPPED`、手动复位事件、有限超时和 `CancelIoEx`。
- 单条消息硬上限保持 `64 KiB`；超过上限在写入前拒绝。
- JSON 协议版本从 `1` 提升到 `2`。父子进程来自同一 Setup EXE，不提供跨版本兼容模式。
- 未知字段可以忽略，但缺失、类型错误、重复命令行参数、未知命令、pipe/nonce 不匹配均拒绝。
- 主进程在客户端 PID 核对成功前不读取或回应协议消息；辅助进程在收到 `accepted=true` 前不写证书。

### 2.4 稳定错误语义

用户级错误码沿用现有枚举，避免无必要地扩张公共协议：

| 情况 | `ErrorCode` | 稳定编号 | 退出码 | detail 例子 |
| --- | --- | --- | ---: | --- |
| 用户拒绝 UAC | `ElevationDeclined` | `INSTALLER_ELEVATION_DECLINED` | 10 | `uac-declined` |
| 无进程句柄/PID | `ElevationFailed` | `INSTALLER_ELEVATION_FAILED` | 31 | `elevated-process-id-unavailable win32=...` |
| 辅助进程提前退出 | `ElevationFailed` | `INSTALLER_ELEVATION_FAILED` | 31 | `elevated-child-exited exit=3` |
| 启动连接失败 | `ElevationFailed` | `INSTALLER_ELEVATION_FAILED` | 31 | `pipe-connect-start-failed win32=...` |
| 真正超时 | `ElevationFailed` | `INSTALLER_ELEVATION_FAILED` | 31 | `pipe-connect-timeout waitMs=180000` |
| 连接者 PID 不符 | `ElevationFailed` | `INSTALLER_ELEVATION_FAILED` | 31 | `pipe-client-id-mismatch expected=... actual=...` |
| nonce/摘要/协议不符 | `ElevationResourceMismatch` | `INSTALLER_ELEVATION_RESOURCE_MISMATCH` | 30 | `handshake-rejected field=...` |
| 已连接并尝试写证书，但系统存储拒绝 | `CertificateImportFailed` 或 `CertificateStoreUnavailable` | 对应既有编号 | 31 | 辅助进程返回的稳定码 |

`pipe-connect-timeout` 只能在等待函数实际返回 `WAIT_TIMEOUT` 时使用。不能把事件创建失败、`ConnectNamedPipe` 立即失败、子进程退出或 PID 不符写成 timeout。

## 3. 文件职责

### 新建

- `installer/include/elevation_channel.h`：定义 overlapped IPC 结果类型、连接等待和有限读写接口；不含证书业务。
- `installer/src/elevation_channel.cpp`：实现事件、等待、取消、客户端 PID 核对及 Win32 错误保留。
- `installer/tests/elevation_channel_test.cpp`：通过真实本地命名管道覆盖连接、错误 PID、提前退出、超时和消息边界。
- `installer/tests/elevation_test_helper.cpp`：无提权测试进程，只实现连接、立即退出和延迟三种测试行为；不链接证书写入代码。
- `docs/testing/offline-installer-uac-broker-acceptance.md`：人可读验收记录。
- `docs/testing/evidence/offline-installer-uac-broker-1.10.2.json`：发布门禁读取的机器可读证据；真实执行前状态全部为 `NOT RUN`，不能预填 `PASS`。
- `docs/release/1.10.2-github-release-body.md`：修复版本 Release 文案、安装说明与旧版风险说明。

### 修改

- `installer/src/elevation_broker.cpp`：删除父 PID 校验，使用新 channel 接口，绑定已启动 PID，采用协议 v2。
- `installer/include/elevation_broker.h`：只保留业务请求/结果和 broker 公共接口；不得暴露 Win32 测试后门。
- `installer/CMakeLists.txt`：把 `elevation_channel.cpp` 加入核心库，把新测试与 helper 加入构建。
- `installer/src/installer_controller.cpp`：保留 `TrustOutcome.error`，不再把通信错误改写成证书导入错误。
- `installer/src/installer_errors.cpp`：修订 `ElevationFailed` 的用户文案；真实证书导入错误文案保持专用含义。
- `installer/tests/error_mapping_test.cpp`：固定错误码、退出码和用户文案边界。
- `installer/tests/test_main.cpp`、`installer/tests/test_support.h`：向 IPC 测试提供同目录 helper 路径；不增加生产开关。
- `tool/installer_tests.ps1`：替换依赖 `--parent` 的旧用例，加入参数绑定、协议 v2 与安全失败检查。
- `tool/verify_release_assets.ps1`：校验 UAC 验收 JSON 与当前 Setup 哈希、版本、用例集合一致。
- `docs/testing/offline-installer-acceptance.md`：把旧版结论改为历史证据，明确 UAC 缺陷和失效范围；不得保留“可正式发布”的暗示。
- `docs/release/1.10.0-github-release-body.md`：追加已知缺陷警告，不篡改原有哈希记录。
- `docs/release/version-policy.md`、`docs/release/build-ledger.md`：记录 `1.10.2+51` 和旧 Setup 撤回决定。
- `pubspec.yaml`、`lib/app/backup_assembly.dart`：执行发布任务时统一提升到 `1.10.2+51` / `1.10.2.0`。

## 4. 公共接口决定

在 `installer/include/elevation_channel.h` 中定义以下接口，名称和字段不可在任务间自行改写：

```cpp
namespace planner::installer {

enum class ElevationChannelStatus {
  Connected,
  EventCreationFailed,
  ConnectStartFailed,
  WaitFailed,
  TimedOut,
  ChildExited,
  ClientPidUnavailable,
  ClientPidMismatch,
  IoFailed,
  MessageTooLarge,
};

struct ElevationChannelResult {
  ElevationChannelStatus status = ElevationChannelStatus::ConnectStartFailed;
  DWORD win32_error = ERROR_SUCCESS;
  DWORD child_exit_code = STILL_ACTIVE;
  DWORD expected_client_pid = 0;
  DWORD actual_client_pid = 0;

  bool ok() const { return status == ElevationChannelStatus::Connected; }
};

ElevationChannelResult WaitForExpectedElevationClient(
    HANDLE pipe,
    HANDLE elevated_process,
    DWORD expected_client_pid,
    DWORD timeout_ms);

ElevationChannelResult ReadElevationMessage(
    HANDLE pipe,
    std::string& payload,
    DWORD timeout_ms);

ElevationChannelResult WriteElevationMessage(
    HANDLE pipe,
    const std::string& payload,
    DWORD timeout_ms);

std::wstring ElevationChannelDetail(const ElevationChannelResult& result,
                                    DWORD timeout_ms = 0);

}  // namespace planner::installer
```

`WaitForExpectedElevationClient` 必须使用 `WaitForMultipleObjects` 同时等待管道事件和 `elevated_process`。连接完成后调用 `GetNamedPipeClientProcessId`；只有实际 PID 与 `expected_client_pid` 相同才返回 `Connected`。

在 `elevation_broker.cpp` 内保留参数解析为私有实现，但其规则必须能由公开的纯函数测试。若执行者需要抽出类型，固定为：

```cpp
struct ElevatedSessionArguments {
  bool valid = false;
  std::wstring pipe_name;
  std::wstring nonce_hex;
  std::wstring error;
};

ElevatedSessionArguments ParseElevatedSessionArguments(
    const std::vector<std::wstring>& arguments);
```

该类型可以放入 `elevation_channel.h`，但不能包含父 PID、证书路径、存储区名称或任意命令字符串。

## 5. 任务实施

### Task 1: 建立可测试的 overlapped IPC 层

**Files:**
- Create: `installer/include/elevation_channel.h`
- Create: `installer/src/elevation_channel.cpp`
- Create: `installer/tests/elevation_channel_test.cpp`
- Create: `installer/tests/elevation_test_helper.cpp`
- Modify: `installer/CMakeLists.txt`
- Modify: `installer/tests/test_main.cpp`
- Modify: `installer/tests/test_support.h`

**Interfaces:**
- Consumes: Win32 `CreateNamedPipeW`、`ConnectNamedPipe`、`WaitForMultipleObjects`、`GetOverlappedResult`、`CancelIoEx`、`GetNamedPipeClientProcessId`、`ReadFile`、`WriteFile`。
- Produces: §4 中固定的 `ElevationChannelStatus`、`ElevationChannelResult`、`WaitForExpectedElevationClient`、`ReadElevationMessage`、`WriteElevationMessage`、`ElevationChannelDetail`。

- [ ] **Step 1: 新增会失败的真实管道测试**

  在 `elevation_channel_test.cpp` 注册以下测试，不使用 mock：

  ```text
  elevation_channel_connects_expected_client
  elevation_channel_rejects_unexpected_client_pid
  elevation_channel_reports_child_exit_code
  elevation_channel_times_out_and_cancels_io
  elevation_channel_round_trips_message_over_overlapped_handles
  elevation_channel_rejects_oversized_message
  elevation_channel_reports_broken_pipe
  ```

  断言要求：

  - 正确客户端返回 `Connected`，expected/actual PID 相等；
  - 故意传错 expected PID 返回 `ClientPidMismatch`，证据中保留两个 PID；
  - helper 以 `73` 立即退出时，五秒内返回 `ChildExited` 且 `child_exit_code == 73`；
  - 200 ms 内无人连接时返回 `TimedOut`，随后 `CancelIoEx` 完成，测试进程不挂起；
  - 64 KiB 以内消息字节完全一致；64 KiB 加 1 字节返回 `MessageTooLarge`；
  - 对端关闭后读取返回 `IoFailed` 且保留非零 Win32 错误。

- [ ] **Step 2: 构建测试并确认按预期失败**

  Run:

  ```powershell
  & cmake --build installer\build --config Debug --target installer_tests elevation_test_helper
  & installer\build\Debug\installer_tests.exe
  ```

  Expected: 编译或链接因 `WaitForExpectedElevationClient` 等接口尚未实现而失败；失败不能来自既有测试或环境路径。

- [ ] **Step 3: 实现最小 IPC 层**

  实现 §4 接口。每一次 overlapped 操作独占一个手动复位事件；同步完成、`ERROR_IO_PENDING`、`ERROR_PIPE_CONNECTED`、超时、等待失败和取消完成分别处理。不要在库中调用 `TerminateProcess`，进程终止策略由 broker 决定。

- [ ] **Step 4: 把 helper 作为独立测试目标接入**

  `elevation_test_helper.exe` 只支持：

  ```text
  --connect <pipeName> [--write <utf8>]
  --exit <0..255>
  --sleep <milliseconds>
  ```

  参数无效返回 `2`。该目标不得链接 `certificate_manager.cpp`，也不得请求管理员权限。

- [ ] **Step 5: 运行定向测试**

  Run: `installer\build\Debug\installer_tests.exe`

  Expected: 上述七项全部 `PASS`，进程在十秒内结束，没有残留 helper。

- [ ] **Step 6: 运行 Release 构建测试**

  Run:

  ```powershell
  & cmake --build installer\build --config Release --target installer_tests elevation_test_helper
  & installer\build\Release\installer_tests.exe
  ```

  Expected: 退出码 `0`，新增测试在 Release 优化下仍通过。

- [ ] **Step 7: Commit**

  ```powershell
  git add installer/include/elevation_channel.h installer/src/elevation_channel.cpp installer/tests/elevation_channel_test.cpp installer/tests/elevation_test_helper.cpp installer/tests/test_main.cpp installer/tests/test_support.h installer/CMakeLists.txt
  git commit -m "test: cover installer elevation channel"
  ```

### Task 2: 固定辅助进程参数和协议 v2

**Files:**
- Modify: `installer/include/elevation_channel.h`
- Modify: `installer/src/elevation_channel.cpp`
- Modify: `installer/src/elevation_broker.cpp`
- Modify: `installer/tests/elevation_channel_test.cpp`

**Interfaces:**
- Consumes: Task 1 的有限消息读写函数。
- Produces: `ParseElevatedSessionArguments(...)`；严格绑定的 pipe/nonce；协议版本 `2`。

- [ ] **Step 1: 写参数解析失败测试**

  新增：

  ```text
  elevated_args_accept_exact_pipe_nonce_pair
  elevated_args_reject_pipe_nonce_mismatch
  elevated_args_reject_duplicate_pipe
  elevated_args_reject_duplicate_nonce
  elevated_args_reject_parent_argument
  elevated_args_reject_unknown_argument
  elevated_args_reject_non_hex_or_wrong_length_nonce
  ```

  有效样例只能是：

  ```text
  --elevated-session
  --pipe \\.\pipe\BestPlanningSetup-<64 hex>
  --nonce <同一个 64 hex>
  ```

- [ ] **Step 2: 运行并确认新测试失败**

  Run: `installer\build\Debug\installer_tests.exe`

  Expected: 仅新增解析测试失败。

- [ ] **Step 3: 实现严格解析并删除父进程扫描**

  删除 `ParentIsSameExecutable`、`<tlhelp32.h>`、`--parent` 解析和退出码 `3` 对父进程不符的含义。保留退出码数值兼容不是要求；新的辅助进程退出码固定为：

  | 值 | 含义 |
  | ---: | --- |
  | 0 | 成功 |
  | 2 | 参数无效 |
  | 4 | 无法连接管道或 I/O 失败 |
  | 5 | 主进程拒绝协议/资源握手 |
  | 6 | 辅助进程复验载荷失败 |
  | 7 | 证书写入失败 |

- [ ] **Step 4: 升级 JSON 协议版本**

  将 `kProtocolVersion` 从 `1` 改为 `2`；父进程和辅助进程都必须拒绝非 `2`。命令仍固定为 `verify-and-trust-certificate`。

- [ ] **Step 5: 运行测试**

  Run: `installer\build\Debug\installer_tests.exe`

  Expected: 参数与协议测试全部通过，源码中 `ParentIsSameExecutable`、`TH32CS_SNAPPROCESS`、`--parent` 均无匹配。

- [ ] **Step 6: Commit**

  ```powershell
  git add installer/include/elevation_channel.h installer/src/elevation_channel.cpp installer/src/elevation_broker.cpp installer/tests/elevation_channel_test.cpp
  git commit -m "fix: bind elevated session arguments to nonce"
  ```

### Task 3: 把 broker 绑定到实际启动的提权进程

**Files:**
- Modify: `installer/src/elevation_broker.cpp`
- Modify: `installer/include/elevation_broker.h`
- Modify: `installer/tests/elevation_channel_test.cpp`

**Interfaces:**
- Consumes: Task 1 的 IPC 接口、Task 2 的参数协议。
- Produces: `ElevationBroker::RequestCertificateTrust(...)` 的可靠连接路径；公共函数签名不变。

- [ ] **Step 1: 新增 broker 决策测试**

  固定以下结果映射：

  ```text
  broker_maps_child_exit_to_elevation_failed
  broker_maps_real_timeout_only_to_pipe_connect_timeout
  broker_rejects_client_pid_mismatch_before_ack
  broker_preserves_resource_mismatch
  broker_preserves_certificate_import_failure_after_ack
  ```

  若直接测试 broker 需要 UAC，抽取一个不执行系统写入的纯映射函数；不得给生产 EXE 增加跳过 PID 校验或假装提权成功的命令行开关。

- [ ] **Step 2: 运行并确认失败**

  Run: `installer\build\Debug\installer_tests.exe`

  Expected: 新增映射测试失败，旧测试不回归。

- [ ] **Step 3: 修正管道创建模式**

  `CreateNamedPipeW` 增加 `FILE_FLAG_OVERLAPPED`，pipe mode 增加 `PIPE_REJECT_REMOTE_CLIENTS`。若事件创建失败，返回 `event-create-failed win32=<GetLastError()>`，不能继续调用连接。

- [ ] **Step 4: 取得并验证已启动 PID**

  `ShellExecuteExW` 成功后必须满足：

  ```cpp
  execute.hProcess != nullptr
  GetProcessId(execute.hProcess) != 0
  ```

  任一条件不满足时，不等待管道，不写证书，返回 `ElevationFailed` 并关闭所有句柄。

- [ ] **Step 5: 替换连接等待**

  用 `WaitForExpectedElevationClient(pipe_, execute.hProcess, launched_pid, timeout_ms)` 替换现有单事件等待。行为固定如下：

  - `ChildExited`：读取并记录退出码，不调用 `TerminateProcess`；
  - `TimedOut`、`ClientPidMismatch`、`ConnectStartFailed`、`WaitFailed`：确认握手尚未 ACK 后才可以终止仍存活的 helper；
  - `Connected`：继续协议；
  - 每条路径调用一次且仅一次 `CloseHandle(execute.hProcess)` 和 `CloseChannel()`。

- [ ] **Step 6: 把全部消息 I/O 换成 Task 1 接口**

  主、辅进程都通过 `ReadElevationMessage` / `WriteElevationMessage` 传输 JSON。客户端 `CreateFileW` 增加 `FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION`；不得混用同步句柄和 overlapped 调用，也不得给服务端管理员级模拟能力。

- [ ] **Step 7: 运行句柄与退出测试**

  Run:

  ```powershell
  & cmake --build installer\build --config Debug --target installer_tests
  & installer\build\Debug\installer_tests.exe
  ```

  Expected: 全部通过；Application Verifier 或调试输出中没有无效句柄、重复关闭或未完成 I/O 警告。

- [ ] **Step 8: Commit**

  ```powershell
  git add installer/src/elevation_broker.cpp installer/include/elevation_broker.h installer/tests/elevation_channel_test.cpp
  git commit -m "fix: authenticate elevated pipe client"
  ```

### Task 4: 修正错误传播、界面文案和日志

**Files:**
- Modify: `installer/src/installer_controller.cpp`
- Modify: `installer/src/installer_errors.cpp`
- Modify: `installer/tests/error_mapping_test.cpp`
- Modify: `installer/src/elevation_broker.cpp`

**Interfaces:**
- Consumes: `TrustOutcome.error` 与 `TrustOutcome.detail`。
- Produces: 准确的 `Fail(ErrorCode, detail)`、稳定 UI 文案和可审计日志。

- [ ] **Step 1: 写错误传播测试**

  新增或扩展测试，断言：

  ```text
  controller_preserves_elevation_failed
  controller_preserves_certificate_store_unavailable
  controller_preserves_certificate_import_failed
  elevation_failed_copy_does_not_claim_certificate_write
  certificate_import_failed_copy_requires_attempted_write
  ```

  `ElevationFailed` 用户文案固定为：

  - 标题：`管理员授权步骤未完成`
  - 原因：`安装器启动的管理员辅助进程未能建立安全连接。证书尚未写入，应用尚未安装。`
  - 建议：`请重试；如果仍然失败，请打开日志并反馈错误编号。`

- [ ] **Step 2: 运行并确认错误映射测试失败**

  Run: `installer\build\Debug\installer_tests.exe`

  Expected: 新断言显示当前控制器错误地映射为 `CertificateImportFailed`。

- [ ] **Step 3: 修正控制器**

  保留 UAC 拒绝和资源不一致的专用分支；其余失败调用 `Fail(trust.error, trust.detail)`。只有 `trust.error == ErrorCode::None` 但 `ok == false` 这种内部不变量破坏才降级为 `ElevationFailed`。

- [ ] **Step 4: 结构化日志**

  日志至少写入：

  ```text
  elevation launch succeeded pid=<pid>
  elevation channel connected clientPid=<pid> protocol=2
  elevation helper exited code=<code>
  elevation channel failed status=<stable-token> win32=<n>
  ```

  UAC 凭据、用户名、管道 nonce 全文和命令行不得写日志。管道名最多记录固定前缀，不记录随机后缀。

- [ ] **Step 5: 运行错误测试和控制器自检**

  Run:

  ```powershell
  & cmake --build installer\build --config Debug --target installer_tests BestPlanningSetup
  & installer\build\Debug\installer_tests.exe
  & installer\build\Debug\BestPlanningSetup.exe --selftest
  ```

  Expected: 两个进程退出码均为 `0`；用户文案不再把连接失败描述成证书写入失败。

- [ ] **Step 6: Commit**

  ```powershell
  git add installer/src/installer_controller.cpp installer/src/installer_errors.cpp installer/src/elevation_broker.cpp installer/tests/error_mapping_test.cpp
  git commit -m "fix: report elevation failures accurately"
  ```

### Task 5: 扩充组件测试和故障注入

**Files:**
- Modify: `tool/installer_tests.ps1`
- Modify: `installer/tests/elevation_channel_test.cpp`
- Modify: `docs/testing/offline-installer-acceptance.md`
- Create: `docs/testing/offline-installer-uac-broker-acceptance.md`

**Interfaces:**
- Consumes: Task 1～4 的测试二进制与稳定错误 detail。
- Produces: 不依赖真人 UAC 的自动化回归证据，以及待执行的真人验收模板。

- [ ] **Step 1: 删除失效的旧测试假设**

  `tool/installer_tests.ps1` 的“无效提权会话”不再传 `--parent`。改为 pipe/nonce 不匹配、重复参数和未知参数三个独立用例；每个用例都记录运行前后发布证书是否存在，并断言状态不变。

- [ ] **Step 2: 加入故障注入 ID**

  自动化用例固定为：

  | ID | 条件 | 预期 |
  | --- | --- | --- |
  | IPC-AUTO-01 | pipe 后缀与 nonce 不同 | helper exit 2；证书不变 |
  | IPC-AUTO-02 | 重复 `--nonce` | helper exit 2；证书不变 |
  | IPC-AUTO-03 | 未知参数 | helper exit 2；证书不变 |
  | IPC-AUTO-04 | helper 在连接前 exit 73 | `ChildExited`，五秒内返回 |
  | IPC-AUTO-05 | 错误 expected PID | `ClientPidMismatch`，不发送 ACK |
  | IPC-AUTO-06 | 无客户端 | `TimedOut`，I/O 被取消 |
  | IPC-AUTO-07 | 握手 protocol=1 | `ElevationResourceMismatch`，不写证书 |
  | IPC-AUTO-08 | 摘要不一致 | `ElevationResourceMismatch`，不写证书 |
  | IPC-AUTO-09 | 64 KiB+1 消息 | `MessageTooLarge` |
  | IPC-AUTO-10 | 对端断开 | `IoFailed`，无挂起进程 |

- [ ] **Step 3: 运行组件脚本并先观察失败**

  Run: `& tool\installer_tests.ps1`

  Expected before completing the script changes: 旧 `--parent` 用例或新增用例失败；不得把失败记录成通过。

- [ ] **Step 4: 完成脚本断言并运行**

  Run: `& tool\installer_tests.ps1`

  Expected: 原 10 组及新增 IPC 组全部通过；JSON 总结中 `ok=true`、`failures=[]`，测试数与实际一致。

- [ ] **Step 5: 更正历史验收记录**

  在 `offline-installer-acceptance.md` 顶部追加“历史记录更正”：此前通过项只证明已提权路径、载荷和部署，不证明普通用户 UAC broker。保留原始记录，不改写当时命令、哈希和结果。

- [ ] **Step 6: 创建真人验收模板**

  `offline-installer-uac-broker-acceptance.md` 初始结论写：

  ```text
  结论：NOT RUN
  原因：修复产物尚未生成或真实 Windows 矩阵尚未完成。
  ```

  模板必须包含 Task 6 的全部 ID、实际结果、日志路径、截图路径、Setup SHA-256、执行账户、UAC 使用账户、安装前后包登记和证书状态。

- [ ] **Step 7: Commit**

  ```powershell
  git add tool/installer_tests.ps1 installer/tests/elevation_channel_test.cpp docs/testing/offline-installer-acceptance.md docs/testing/offline-installer-uac-broker-acceptance.md
  git commit -m "test: cover installer UAC broker failures"
  ```

### Task 6: 执行真实 Windows/UAC 验收

**Files:**
- Modify: `docs/testing/offline-installer-uac-broker-acceptance.md`
- Create: `docs/testing/evidence/offline-installer-uac-broker-1.10.2.json`
- Evidence only: `docs/testing/evidence/offline-installer-uac-broker-1.10.2/`

**Interfaces:**
- Consumes: 签名后的候选 Setup、候选 MSIX、发布证书、候选 SHA-256。
- Produces: 发布门禁可读取的 12 项真实验收记录。

不得在开发者已经信任证书且会话已经提权的状态下代替本任务。没有测试机时可以使用干净虚拟机；没有任何隔离环境时，本任务保持 `NOT RUN`，发布保持阻断。

- [ ] **Step 1: 固定候选产物**

  复制签名后的 Setup 到只读证据目录，记录：文件名、字节数、SHA-256、Authenticode 状态、时间戳证书、内嵌 MSIX SHA-256、目标版本。后续任何重建都会产生新候选，之前的真人证据不得复用。

- [ ] **Step 2: 准备账户**

  每个系统至少有：

  - 一个启用 UAC 的管理员账户 `AdminTest`；
  - 一个标准账户 `StandardTest`；
  - 两者分别登录一次，确认各自用户配置文件可用；
  - 测试前快照中没有目标包，发布证书不在 `LocalMachine\TrustedPeople`。

  账户名只记录测试别名，不记录真实姓名或密码。

- [ ] **Step 3: 执行以下矩阵**

  | ID | 环境 | 发起账户 | UAC 行为 | 必须证明 |
  | --- | --- | --- | --- | --- |
  | UAC-ADMIN-01 | Windows 11 x64 稳定版 | 管理员过滤令牌 | 点“是” | 一次 UAC；证书写入；包安装给同一用户；启动成功 |
  | UAC-ADMIN-02 | Windows 10 x64 受支持版 | 管理员过滤令牌 | 点“是” | 同上 |
  | UAC-STD-01 | Windows 11 x64 稳定版 | 标准账户 | 输入 `AdminTest` 凭据 | 证书机器级写入；包只登记给 `StandardTest`；管理员账户不新增登记 |
  | UAC-STD-02 | Windows 10 x64 受支持版 | 标准账户 | 输入 `AdminTest` 凭据 | 同上 |
  | UAC-CANCEL-01 | Windows 11 | 管理员过滤令牌 | 点“否” | exit 10；证书不存在；包不存在；`finalState NotInstalled` |
  | UAC-CANCEL-02 | Windows 11 | 标准账户 | 取消凭据框 | 与 UAC-CANCEL-01 相同 |
  | UAC-OFFLINE-01 | Windows 11 | 管理员过滤令牌 | 断网后点“是” | 完整安装和启动；没有网络请求依赖 |
  | UAC-TRUSTED-01 | Windows 11 | 原安装用户 | 证书已存在 | 不弹 UAC；直接复验并安装/修复 |
  | UAC-UPGRADE-01 | Windows 11 | 已装 1.10.0 | 正常授权（如需要） | 原位升级到 1.10.2；数据文件哈希/字段验收符合既有规格 |
  | UAC-UPGRADE-02 | Windows 11 | 已装 1.10.1 | 正常授权（如需要） | 原位升级到 1.10.2；设置和业务数据保留 |
  | UAC-REPAIR-01 | Windows 11 | 已装 1.10.2 | 选择修复 | 不先卸载，不清数据，最终登记仍为 1.10.2.0 |
  | UAC-UI-01 | Windows 11 | 任一未信任账户 | 人为触发 helper 失败候选 | 页面显示 `INSTALLER_ELEVATION_FAILED`，不显示证书已尝试写入 |

- [ ] **Step 4: 每个用例采集一致证据**

  每个 ID 至少保存：

  - 安装前 `whoami` 的测试别名和账户类型；
  - 安装前目标包查询结果；
  - 安装前证书指纹查询结果；
  - UAC 前、授权后和最终页面截图；
  - Setup 日志原文件及 SHA-256；
  - 安装后原始用户的包版本和状态；
  - 标准账户场景中管理员账户的包登记对比；
  - 最终证书指纹、位置和是否含私钥；
  - Setup 退出码和 `finalState`。

- [ ] **Step 5: 校验普通用户安装归属**

  `UAC-STD-01/02` 的硬条件：

  ```text
  StandardTest: ShuoZhuang.PersonalPlanner 1.10.2.0 Status Ok
  AdminTest: 安装前后登记集合不因本次测试新增目标包
  LocalMachine\TrustedPeople: 固定指纹存在，HasPrivateKey=false
  ```

  任一条件不满足即 `FAIL`，不能用“安装器显示成功”替代系统查询。

- [ ] **Step 6: 填写机器可读证据**

  JSON 必须满足：

  ```json
  {
    "schemaVersion": 1,
    "releaseVersion": "1.10.2+51",
    "msixVersion": "1.10.2.0",
    "setupSha256": "<64 lowercase hex>",
    "cases": [
      {
        "id": "UAC-ADMIN-01",
        "status": "PASS",
        "osBuild": "<real build>",
        "accountMode": "filtered-admin",
        "logPath": "<repo-relative path>",
        "logSha256": "<64 lowercase hex>",
        "screenshotPath": "<repo-relative path>",
        "screenshotSha256": "<64 lowercase hex>"
      }
    ]
  }
  ```

  12 个 ID 必须恰好出现一次。任何 `FAIL`、`NOT RUN`、空路径、哈希不符或候选 Setup 哈希变化都阻止发布。

- [ ] **Step 7: 更新人可读结论**

  只有 12 项全部通过时，才把文档结论改为 `PASS`。若缺 Windows 10、标准账户或跨账户凭据测试，结论保持 `NOT RUN` 或 `FAIL`，不能写 `PARTIAL PASS` 后继续发布。

- [ ] **Step 8: Commit evidence**

  ```powershell
  git add docs/testing/offline-installer-uac-broker-acceptance.md docs/testing/evidence/offline-installer-uac-broker-1.10.2.json docs/testing/evidence/offline-installer-uac-broker-1.10.2
  git commit -m "test: record real installer UAC acceptance"
  ```

### Task 7: 加入发布门禁并生成 1.10.2

**Files:**
- Modify: `tool/verify_release_assets.ps1`
- Modify: `pubspec.yaml`
- Modify: `lib/app/backup_assembly.dart`
- Modify: `docs/release/version-policy.md`
- Modify: `docs/release/build-ledger.md`
- Modify: `docs/release/1.10.0-github-release-body.md`
- Create: `docs/release/1.10.2-github-release-body.md`
- Release artifacts: `release-artifacts/1.10.2/`

**Interfaces:**
- Consumes: Task 6 的机器可读证据和固定候选哈希。
- Produces: `1.10.2+51` 的五类正式产物以及阻止错误 Setup 发布的门禁。

- [ ] **Step 1: 先写门禁失败测试/夹具**

  使用临时证据 JSON 覆盖：缺文件、版本不符、Setup 哈希不符、用例缺失、重复 ID、`NOT RUN`、日志哈希不符。每种情况都必须让 `verify_release_assets.ps1` 退出 `1`。

- [ ] **Step 2: 实现证据门禁**

  给 `verify_release_assets.ps1` 增加：

  ```powershell
  [string]$InstallerUacAcceptance = 'docs/testing/evidence/offline-installer-uac-broker-1.10.2.json'
  [switch]$SkipInstallerUacAcceptance
  ```

  规则：本地非签名开发验证可以显式跳过；只要指定 `-RequireSignature`，使用 `-SkipInstallerUacAcceptance` 就必须失败。正式发布命令没有跳过通道。

- [ ] **Step 3: 运行门禁负例**

  Expected: 所有无效证据均退出 `1`，输出指出具体缺失 ID 或哈希，不输出秘密。

- [ ] **Step 4: 提升版本**

  同一提交内更新：

  ```text
  pubspec.yaml version: 1.10.2+51
  pubspec.yaml msix_version: 1.10.2.0
  backup_assembly.dart appVersion: 1.10.2+51
  Setup ProductVersion: 由构建参数生成 1.10.2+51
  manifest release.version: 1.10.2
  manifest buildNumber: 51
  manifest msixVersion: 1.10.2.0
  manifest tag: v1.10.2
  ```

- [ ] **Step 5: 构建最终候选**

  按既有发布流程先构建/签名 MSIX，再构建内嵌 Setup，最后签名 Setup。Setup 签名后不得再写资源或改文件。

  Run 示例：

  ```powershell
  & tool\build_offline_installer.ps1 `
    -Msix release-artifacts\1.10.2\BestPlanning_1.10.2.0_x64.msix `
    -Certificate <official-public-certificate.cer> `
    -Version 1.10.2 `
    -Build 51 `
    -SigningThumbprint <official-signing-thumbprint>
  ```

  证书路径和指纹由发布环境注入，不写入文档、提交或日志。

- [ ] **Step 6: 先运行非正式门禁**

  在 Task 6 尚未执行前，可以运行：

  ```powershell
  & tool\verify_release_assets.ps1 -Directory release-artifacts\1.10.2 -Version 1.10.2 -Build 51 -SkipInstallerUacAcceptance
  ```

  这只能证明产物结构，不能发布。

- [ ] **Step 7: 用最终签名候选重新执行 Task 6**

  Task 6 的旧证据若绑定了不同 Setup SHA-256，全部失效。只允许最终签名候选产生的证据进入正式门禁。

- [ ] **Step 8: 运行正式门禁**

  Run:

  ```powershell
  & tool\verify_release_assets.ps1 `
    -Directory release-artifacts\1.10.2 `
    -Version 1.10.2 `
    -Build 51 `
    -RequireSignature
  ```

  Expected: `ok=true`、`problems=[]`，Setup 哈希与 UAC 证据完全一致。

- [ ] **Step 9: 修订旧 Release 提示**

  `v1.10.0` 与 `v1.10.1` 顶部增加：其单文件 Setup 在证书未信任的设备上可能失败；已安装成功的用户无需卸载；新安装请使用 `v1.10.2`。不得删除旧哈希或暗示旧附件已被静默替换。

- [ ] **Step 10: Commit**

  ```powershell
  git add tool/verify_release_assets.ps1 pubspec.yaml lib/app/backup_assembly.dart docs/release/version-policy.md docs/release/build-ledger.md docs/release/1.10.0-github-release-body.md docs/release/1.10.2-github-release-body.md
  git commit -m "release: prepare installer UAC repair 1.10.2"
  ```

### Task 8: 全量回归、审计与发布判定

**Files:**
- Modify: `docs/testing/offline-installer-uac-broker-acceptance.md`
- Modify: `docs/release/build-ledger.md`
- Review: all files changed by Tasks 1～7

**Interfaces:**
- Consumes: 所有实现、自动化结果、真人证据和最终产物。
- Produces: 唯一允许使用“完成并可发布”的结论。

- [ ] **Step 1: 静态分析和 Flutter 全量测试**

  Run:

  ```powershell
  flutter analyze
  flutter test
  ```

  Expected: 退出码均为 `0`；不得用“与安装器无关”忽略已有失败，需先查明是否为基线问题并记录。

- [ ] **Step 2: 原生 Debug/Release 全量测试**

  Run:

  ```powershell
  & cmake --build installer\build --config Debug --target installer_tests elevation_test_helper BestPlanningSetup
  & installer\build\Debug\installer_tests.exe
  & cmake --build installer\build --config Release --target installer_tests elevation_test_helper BestPlanningSetup
  & installer\build\Release\installer_tests.exe
  & tool\installer_tests.ps1 -SkipBuild
  ```

  Expected: 全部退出 `0`，测试计数与验收记录一致。

- [ ] **Step 3: 搜索禁止残留**

  Run:

  ```powershell
  rg -n "ParentIsSameExecutable|TH32CS_SNAPPROCESS|--parent" installer tool
  rg -n "PIPE_ACCESS_DUPLEX" installer/src/elevation_broker.cpp
  ```

  Expected: 第一条无生产匹配；第二条对应表达式同时含 `FILE_FLAG_FIRST_PIPE_INSTANCE` 和 `FILE_FLAG_OVERLAPPED`。

- [ ] **Step 4: 安全审计**

  审核者逐项确认：

  - 不存在主进程在 PID/nonce/摘要验证前发送 accepted 的路径；
  - 辅助进程不接受路径、脚本、存储区或任意命令；
  - DACL 没有扩大；
  - 每个 HANDLE、事件、管道和未完成 I/O 在所有 return 路径都被关闭或取消；
  - `TerminateProcess` 只发生在证书写入尚未开始的 pre-ACK 阶段；
  - 标准账户跨凭据路径仍由普通进程部署 MSIX；
  - 日志 detail 不泄露 nonce、凭据或用户数据。

- [ ] **Step 5: 对照验收矩阵**

  把下方 §6 的每个需求映射到一个测试名或真人 ID；任何空白、`NOT RUN` 或哈希不一致均保持发布阻断。

- [ ] **Step 6: 检查 Git 差异**

  Run:

  ```powershell
  git status --short
  git diff --check
  git log --oneline --decorate -10
  ```

  Expected: 只有计划内文件；没有构建缓存、证书、私钥、密码、临时日志或用户数据库进入提交。

- [ ] **Step 7: 更新最终结论并提交**

  只有自动化、正式门禁和 Task 6 十二项全部通过时，才能在验收与 build ledger 写：

  ```text
  结论：PASS
  1.10.2+51 的普通管理员、标准账户跨凭据、拒绝、断网、升级和修复路径均以最终签名 Setup 实测通过。
  ```

  Commit:

  ```powershell
  git add docs/testing/offline-installer-uac-broker-acceptance.md docs/release/build-ledger.md
  git commit -m "docs: close installer UAC repair acceptance"
  ```

## 6. 需求到证据映射

| Requirement | 自动化证据 | 真人证据 | 发布条件 |
| --- | --- | --- | --- |
| 管道真正使用 overlapped 模式 | `elevation_channel_*` + 源码审计 | UAC-ADMIN-01/02 | 全部 PASS |
| 子进程提前退出立即可诊断 | `elevation_channel_reports_child_exit_code` | UAC-UI-01 | PASS |
| 客户端 PID 绑定 | `elevation_channel_rejects_unexpected_client_pid` | IPC-AUTO-05 | PASS |
| pipe/nonce 强绑定 | Task 2 七项参数测试 | UAC-ADMIN-01 日志 protocol=2 | PASS |
| 摘要不符时不写证书 | IPC-AUTO-07/08 | 故障注入截图/证书查询 | PASS |
| UAC 拒绝无系统改变 | error mapping test | UAC-CANCEL-01/02 | PASS |
| 管理员一次授权安装 | broker + channel tests | UAC-ADMIN-01/02 | PASS |
| 标准账户跨凭据仍装给原用户 | 无法由普通单元测试证明 | UAC-STD-01/02 | PASS，缺一不可 |
| 断网首次安装 | 内嵌资源自检 | UAC-OFFLINE-01 | PASS |
| 已信任证书不重复 UAC | controller tests | UAC-TRUSTED-01 | PASS |
| 旧版升级保留数据 | 既有部署/数据测试 | UAC-UPGRADE-01/02 | PASS |
| 同版本修复不卸载 | 既有 version policy tests | UAC-REPAIR-01 | PASS |
| 错误界面不误称证书已写入 | error mapping tests | UAC-UI-01 | PASS |
| 最终证据绑定发布文件 | `verify_release_assets.ps1` 负例 | JSON 中 setupSha256 | PASS |

## 7. 失败处理与回退

### 7.1 实施过程中

- 任一 Task 的新增测试不按预期失败时，停止实现，先检查测试是否真正覆盖缺陷。
- 不能通过删除断言、增加 sleep、扩大 ACL、跳过客户端 PID 校验或把 helper 改为全程管理员来让测试变绿。
- 若 `GetNamedPipeClientProcessId` 在最低支持系统失败，记录 Win32 错误并停止发布；不能退回父 PID 判断。需要另写兼容性设计并重新审查最低系统版本。
- 若标准账户跨凭据安装给了管理员账户，视为安全与数据归属失败；不得仅修文案或让用户切换账户。

### 7.2 已发布版本

- `v1.10.0`、`v1.10.1` 保持可审计，不重写 Tag。
- GitHub Release 可以把缺陷 Setup 标记为不推荐下载或移除该附件，但必须保留附件哈希和事故说明；是否移除附件要在发布操作前单独确认，因为它会改变外部可下载状态。
- Portable 和独立 MSIX 若各自验证无此 broker 缺陷，可以保留，但 Release 页面必须明确新用户推荐 `v1.10.2` Setup。
- 已成功安装的 1.10.0/1.10.1 用户不需要卸载。应用内更新到 1.10.2 仍使用 MSIX，不下载 Setup。

### 7.3 1.10.2 候选失败

- 真人验收失败时不创建 `v1.10.2` 正式 Tag；修复后重建并产生新的 Setup SHA-256，旧证据全部作废。
- 如果 Tag 已误建但尚未公开，按仓库发布政策处理；公开后不得强推或移动 Tag，改发下一个补丁版本与新构建号。
- 证书写入成功而 MSIX 部署失败时，继续按原规格 §10.2 判断是否安全回收；本计划不放宽证书回收条件。

## 8. 禁止方案

以下做法即使能在开发机安装，也不符合本文：

- 告诉普通用户手动双击证书并选择存储区；
- 要求普通用户右键“以管理员身份运行”作为正式流程；
- 把 `requestedExecutionLevel` 改成 `requireAdministrator`；
- 仅把 180 秒改得更长；
- 保留 `ParentIsSameExecutable`，只在失败时忽略；
- 把管道 ACL 改成 Everyone；
- 不核对连接者 PID，仅依赖随机管道名；
- 为测试增加可在正式构建中跳过 nonce、摘要、PID 或证书校验的开关；
- 复用 `v1.10.1` Tag 并静默替换附件；
- 没跑标准账户和跨凭据场景就宣布完成。

## 9. 完成定义

只有同时满足以下全部条件，才能说此缺陷已修复：

- ROOT-01～ROOT-06 均有代码修改或验收更正；
- 生产代码不再包含 `ParentIsSameExecutable`、Toolhelp 父进程扫描或 `--parent`；
- 管道连接、读、写全部遵循统一 overlapped 契约；
- 实际连接 PID 与 `ShellExecuteExW` 启动 PID 不一致时，主进程在 ACK 前拒绝；
- 子进程提前退出能在五秒内报告退出码；真正超时才使用 `pipe-connect-timeout`；
- 控制器不再把通信错误改写成 `INSTALLER_CERTIFICATE_IMPORT_FAILED`；
- 单元测试、组件测试、Flutter 全量测试、Debug/Release 原生测试全部通过；
- Windows 10 与 Windows 11 管理员首次安装通过；
- Windows 10 与 Windows 11 标准账户输入另一管理员凭据后，包仍登记给原始标准账户；
- UAC 拒绝、断网、已信任证书、1.10.0/1.10.1 升级、同版本修复和错误 UI 均通过；
- 真人证据绑定最终签名 Setup SHA-256，正式发布门禁通过；
- `1.10.2+51` 五类 Release 产物版本、签名、时间戳、名称与哈希一致；
- 旧 Release 有明确警告，未移动旧 Tag，也未静默替换旧附件；
- 验收记录没有 `FAIL`、`NOT RUN`、空证据或把模拟结果写成真实部署。

在真实 Windows/UAC 矩阵完成之前，只能写“自动化修复完成，发布验收未完成”，不能写“问题已经彻底解决”。

## 10. 自审结果

- **规格覆盖：** 已覆盖双进程权限边界、IPC 身份与 nonce、固定资源复验、错误语义、日志隐私、真实 Windows 矩阵、标准账户归属、构建门禁、版本与旧产物处置。
- **步骤可执行性：** 每个 Task 都列出文件、输入输出、先失败测试、实现动作、验证命令、期望结果和提交边界。
- **类型一致性：** Task 1 定义的 channel 类型与函数名在 Task 2～8 中保持一致；broker 公共签名不变。
- **风险覆盖：** Review Focus 的五类高风险输入分别映射到自动化测试和真人 ID。
- **范围控制：** 本计划不改应用业务数据、排程算法、自更新下载逻辑或证书轮换策略；只修 Setup UAC broker、错误传播、测试及发布处置。

