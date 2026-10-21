# 优计主义 Windows 开机自启动与单实例激活设计

日期：2026-10-21

状态：设计已逐节确认，等待书面规格复核

目标版本：待发布计划确定；本设计不自行修改版本号

## 1. 文档目的

本文定义优计主义 Windows 版“登录 Windows 时启动”的完整产品语义、系统集成方式、单实例协议、界面状态、异常恢复和验收门禁。

目标不是简单地把一个布尔值写进设置，而是建立以下闭环：

```text
首次运行时默认启用一次
→ 由操作系统保存真实启动状态
→ 下次登录 Windows 时启动应用并显示主界面
→ 已有实例时只唤醒，不创建第二个数据库写入进程
→ 用户在软件或 Windows 中关闭后永久尊重该选择
→ 升级、修复安装、托盘、通知和深链均不破坏上述语义
```

本文是架构规格，不授权直接修改产品代码。后续必须先依据本文编写实施计划，再按计划开发、验证和发布。

## 2. 已确认的产品决策

下列决策已经由用户逐项确认，实施阶段不得擅自更改：

1. Windows 登录后直接显示主界面，不静默启动、不只驻留托盘。
2. MSIX 安装版与解压即用的便携版都支持开机自启动。
3. 新用户默认开启。
4. 默认开启只执行一次，不得在每次启动或每次升级时重新开启。
5. 用户通过软件关闭后，后续启动与升级均不得恢复。
6. 用户通过 Windows“启动应用”或任务管理器关闭后，软件不得绕过系统决定。
7. MSIX 使用 Windows 官方 `StartupTask`。
8. 便携版使用当前用户 `HKCU Run`。
9. 同一 Windows 用户只允许一个优计主义主实例访问应用数据。
10. 第二次启动、开机启动、托盘、通知、深链和更新完成都应唤醒已有实例，并保留原始启动意图。
11. 正常流程不弹确认窗口，不要求管理员权限，不触发 UAC。
12. 自启动功能放在现有“设置 → 窗口与后台”，不新增重复设置页。

## 3. 当前代码事实

撰写本文时，工作树中的版本为 `1.11.1+53`，MSIX 数值版本为 `1.11.1.0`。当前实现具有以下可复用基础：

- `lib/domain/models/window_behavior.dart` 已定义关闭窗口与最小化到托盘的领域设置。
- `lib/application/window_behavior_service.dart` 已负责保存并推送窗口行为。
- `lib/features/settings/window/window_background_page.dart` 已是“窗口与后台”设置页。
- `lib/platform/windows/window_shell.dart` 已通过 `personal_planner/window` 与原生窗口通信。
- `windows/runner/window_channel.cpp` 当前只处理 `setCloseBehavior`。
- `windows/runner/flutter_window.cpp` 会在首帧后显示窗口，并已装配托盘能力。
- `windows/runner/main.cpp` 当前每次运行都会创建 Flutter 引擎和窗口，没有单实例锁或激活转交。
- `lib/platform/windows/windows_package_identity.dart` 已能区分有包身份的 MSIX 进程和无包身份的便携进程。
- `lib/platform/notifications/windows_notification_adapter.dart` 与 `lib/app/planner_app.dart` 已负责通知运行时点击和通知冷启动载荷。
- `lib/app/planner_app.dart` 当前在首帧后调用通知端口的 `launchPayload()` 并导航。
- `windows/update_helper/main.cpp` 已能按 AUMID 激活安装版应用。
- `pubspec.yaml` 已有稳定的 MSIX 包身份、Publisher、Application Id 和通知激活器配置。

当前缺口：

1. 没有自启动领域模型、应用服务和设置界面。
2. MSIX 清单没有本功能所需的稳定 StartupTask 声明。
3. 便携版没有受控的 HKCU Run 适配器。
4. 原生入口没有单实例协调，第二个进程可能再次初始化数据库、通知、托盘和更新服务。
5. 没有把第二次启动的意图可靠转交给第一个实例。
6. 如果直接加互斥锁并让第二个进程退出，现有通知冷启动或深链可能被静默丢失。

## 4. 范围与非目标

### 4.1 本期范围

- Windows 10、Windows 11。
- 当前用户级自启动。
- 已签名 MSIX 安装版。
- 无包身份的便携版 EXE。
- 设置页状态读取、开启、关闭、重试和系统设置入口。
- 首次初始化与升级迁移。
- 每用户单实例。
- 普通启动、自动启动、托盘、通知、深链、更新完成后的激活协调。
- 自动化测试、真实登录测试和发布证据。

### 4.2 明确非目标

- 不建立 Windows 服务。
- 不建立要求管理员权限的计划任务。
- 不写 `HKLM`。
- 不绕过 Windows 的启动应用管理。
- 不使用受限制能力换取即时注册。
- 不支持“开机后仅隐藏到托盘”这一第二模式；本期唯一语义是显示主界面。
- 不在本设计中改变关闭窗口行为的默认值。
- 不在本设计中改变通知内容、更新下载策略或应用锁语义。
- 不把自启动开关作为遥测或上传数据。
- 不承诺便携版能通过公开 API 精确读取任务管理器的所有内部抑制状态。

## 5. 不可破坏的系统不变量

实现和评审必须同时守住下列不变量：

1. **系统真实状态优先。** 设置页不能用本地布尔值冒充操作系统状态。
2. **初始化最多一次。** 默认开启不能成为每次启动时的“自动修复”。
3. **系统禁用不可绕过。** `DisabledByUser` 或可确认的系统禁用状态不得由后台逻辑恢复。
4. **数据单写者。** 同一用户同一产品的数据目录在任一时刻最多有一个主实例写入。
5. **激活不丢失。** 第二实例退出前必须收到主实例的接收确认。
6. **通知归通知系统所有。** 单实例层不能把通知插件的私有载荷格式重新解释成另一套不兼容格式。
7. **失败不阻断普通启动。** 查询或写入自启动项失败，不能导致主应用打不开。
8. **权限最小化。** 不要求管理员权限，不触发 UAC。
9. **只管理自身资源。** 只读取或修改固定 TaskId、固定 Run 值名和固定 IPC 名称。
10. **升级不改变用户决定。** 安装更新不能把关闭状态改回开启。
11. **不偷偷弹窗。** 正常状态、状态查询失败和系统禁用均使用设置页内联信息；只有第二实例无法安全交付用户主动操作时，才允许一次原生错误提示。
12. **非 Windows 安全退化。** 其他平台不调用 Windows 接口，并返回 `unsupported`。

## 6. 总体架构

```text
WindowBackgroundPage
        │
        ▼
StartupService ────────────── StartupPreferenceStore
        │                         （只存初始化与用户意图证据）
        ▼
StartupRegistrationPort
        │
        ├─ PackagedStartupAdapter ── Windows StartupTask
        │
        └─ PortableStartupAdapter ── HKCU Run

Windows process entry
        │
        ▼
SingleInstanceCoordinator ── per-user mutex + local authenticated IPC
        │
        ▼
ActivationBridge ── queued native activation → Dart ActivationCoordinator
        │
        ├─ show/restore existing FlutterWindow
        ├─ existing notification adapter
        ├─ deep-link router
        └─ update-completed handling
```

### 6.1 建议新增文件

领域层：

- `lib/domain/startup/startup_status.dart`
- `lib/domain/startup/startup_registration_port.dart`
- `lib/domain/startup/startup_preference.dart`
- `lib/domain/activation/app_activation.dart`

应用层：

- `lib/application/startup/startup_service.dart`
- `lib/application/activation/activation_coordinator.dart`

平台层：

- `lib/platform/windows/windows_startup_registration.dart`
- `lib/platform/windows/windows_activation_bridge.dart`

原生 Runner：

- `windows/runner/startup_channel.h`
- `windows/runner/startup_channel.cpp`
- `windows/runner/single_instance.h`
- `windows/runner/single_instance.cpp`
- `windows/runner/activation_protocol.h`
- `windows/runner/activation_protocol.cpp`
- `windows/runner/activation_channel.h`
- `windows/runner/activation_channel.cpp`

测试：

- `test/domain/startup/startup_status_test.dart`
- `test/application/startup/startup_service_test.dart`
- `test/platform/windows/windows_startup_registration_test.dart`
- `test/features/settings/window_startup_section_test.dart`
- `test/application/activation/activation_coordinator_test.dart`
- `windows/runner/activation_protocol_test.cpp`
- `windows/runner/single_instance_policy_test.cpp`
- `integration_test/windows_startup_activation_test.dart`

文件名可在实施计划中按仓库命名规范微调，但层次职责和依赖方向不得倒置。

## 7. 领域状态与接口契约

### 7.1 `StartupRegistrationStatus`

领域状态必须至少包含：

| 状态 | 含义 | UI 开关 |
| --- | --- | --- |
| `enabled` | 操作系统确认已启用 | 开 |
| `disabledByApp` | 本应用明确关闭，系统项不存在或已禁用 | 关 |
| `disabledBySystem` | Windows/用户从系统入口关闭 | 关 |
| `registeredStateUnknown` | 便携版 Run 项存在，但没有可靠公开接口确认任务管理器抑制状态 | 开，附说明 |
| `stalePath` | 便携版 Run 项属于本产品，但指向的 EXE 不存在或不是当前 EXE | 关 |
| `notRegistered` | 没有注册项，且没有系统禁用证据 | 关 |
| `unsupported` | 非 Windows 或当前系统不支持 | 禁用 |
| `unavailable` | 查询失败、包配置错误或权限/系统 API 异常 | 保持上次已知视觉状态并禁用操作 |

`unavailable` 必须携带稳定错误码和可读说明，但不得携带用户任务数据。

### 7.2 `StartupRegistrationPort`

端口至少提供：

```dart
Future<StartupRegistrationStatus> query();
Future<StartupRegistrationStatus> enable();
Future<StartupRegistrationStatus> disable();
Future<void> openSystemStartupSettings();
```

契约：

- 每次修改后必须重新查询系统状态并返回查询结果。
- `enable()` 不能只返回“API 调用成功”；必须返回实际状态。
- `disable()` 只能操作本产品的固定注册项。
- `openSystemStartupSettings()` 失败不得改变当前状态。
- 端口不负责“是否首次初始化”的产品规则，该规则属于 `StartupService`。

### 7.3 本地偏好证据

`SettingsRepository` 中新增有版本的键：

| 键 | 值 | 作用 |
| --- | --- | --- |
| `windows.startup.initialized.v1` | `true` | 证明默认策略已经执行或明确跳过 |
| `windows.startup.last_user_intent.v1` | `enabled` / `disabled` / 缺省 | 证明最近一次软件内显式操作 |
| `windows.startup.last_known_status.v1` | 状态名 | 查询失败时只用于说明，不用于写回系统 |

禁止保存一个会在每次启动时强制同步到系统的 `autostart=true` 布尔值。

`last_user_intent` 只用于审计和解释：系统真实状态与它冲突时，系统状态优先。

## 8. MSIX StartupTask 设计

### 8.1 固定身份

MSIX 使用固定 TaskId：

```text
BestPlanningStartup
```

TaskId、Application Id、包身份和可执行文件入口在所有后续升级中保持稳定。

生成的 AppxManifest 必须声明桌面 StartupTask，语义等价于：

```xml
<desktop:Extension
    Category="windows.startupTask"
    Executable="personal_planner.exe"
    EntryPoint="Windows.FullTrustApplication">
  <desktop:StartupTask
      TaskId="BestPlanningStartup"
      Enabled="true"
      DisplayName="优计主义" />
</desktop:Extension>
```

具体命名空间和生成方式由现有 `msix` 打包工具支持情况决定。无论采用模板、后处理还是打包工具配置，发布门禁必须检查最终 MSIX 内的真实清单，不能只检查源配置。

### 8.2 状态映射

Windows `StartupTaskState` 映射规则：

- `Enabled` → `enabled`
- `Disabled` → `disabledByApp` 或 `notRegistered`，由本地显式操作证据区分
- `DisabledByUser` → `disabledBySystem`
- 任务不存在、清单不匹配 → `unavailable(configurationMismatch)`

`DisabledByUser` 时不得循环调用 `RequestEnableAsync()`。界面提供打开 Windows 启动应用设置的入口，由用户恢复。

### 8.3 首次启动

清单中默认启用，但应用第一次运行仍必须查询真实状态：

1. 若为 `Enabled`，写入初始化标记，不做额外修改。
2. 若为 `DisabledByUser`，写入初始化标记，保持关闭。
3. 若为可由应用启用的 `Disabled`，且尚未初始化，执行一次启用请求并重新查询。
4. 若查询失败，不写“启用成功”；可写初始化标记的前提是已取得足以证明系统状态的结果。否则下次启动允许重试查询，但不得盲写。

不得使用受限制的即时注册能力，也不得为了默认开启而要求管理员权限。

## 9. 便携版 HKCU Run 设计

### 9.1 固定注册位置

```text
Hive: HKCU
Path: Software\Microsoft\Windows\CurrentVersion\Run
Value name: BestPlanning
Value data: "<当前绝对路径>\personal_planner.exe" --autostart
```

要求：

- EXE 绝对路径始终使用双引号。
- 参数固定为 `--autostart`，不接受用户输入。
- 写入前验证命令长度、路径存在、目标文件名和当前进程路径。
- 比较路径时使用 Windows 规范化规则，不用简单大小写敏感字符串比较。
- 删除前同时验证固定值名和可解析的目标属于本产品；无法确认时不删除。

### 9.2 真实状态边界

微软公开文档定义了 Run 项的启动行为，但没有为无包身份应用提供与 `StartupTaskState` 等价、稳定且公开的任务管理器抑制状态 API。因此：

1. Run 项不存在 → `notRegistered` 或 `disabledByApp`。
2. Run 项存在且指向当前 EXE → 至少为 `registeredStateUnknown`。
3. 如实现了对系统抑制信息的只读探测，只有在当前 Windows 版本经过真实测试且格式被确定识别时，才能提升为 `enabled` 或 `disabledBySystem`。
4. 探测不认识、长度异常或未来 Windows 格式变化时，必须退回 `registeredStateUnknown`，不得猜测。
5. 不得把未公开的系统内部值作为写入目标，也不得通过重写 Run 项绕过系统禁用。

### 9.3 移动与遗留路径

- Run 项属于本产品但目标不存在或不是当前 EXE → `stalePath`。
- `stalePath` 不自动修复。
- 用户点击“重新启用”后，才以当前 EXE 路径覆盖固定值。
- 如果值名相同但命令无法证明属于本产品，返回 `unavailable(foreignValueCollision)`，不覆盖、不删除。

## 10. 默认开启的一次性算法

应用组合根在普通服务完成最小初始化后调用 `StartupService.initializeOnce()`。该调用不得阻塞首帧。

伪代码：

```text
status = registration.query()
initialized = settings.read(initializedKey)

if status is disabledBySystem:
    persist initialized=true and lastKnownStatus
    return status

if initialized is true:
    persist lastKnownStatus only
    return status

if status is enabled or registeredStateUnknown:
    persist initialized=true and lastKnownStatus
    return status

if status is notRegistered or disabledByApp:
    result = registration.enable()   // 仅此一次默认启用
    persist initialized=true only after result is a conclusive state
    persist lastKnownStatus
    return result

if status is stalePath or unavailable:
    persist lastKnownStatus
    do not overwrite system state
    return status
```

补充规则：

- 首次查询暂时失败时允许后续启动重新查询，但不允许盲目调用 `enable()`。
- 更新、修复安装和程序版本变化不清除 `initialized.v1`。
- 用户在软件中开关后立即写 `initialized=true` 和 `last_user_intent`。
- 数据恢复导入不得把另一台设备的自启动状态直接应用到本机；这些键应排除在可迁移业务数据之外，或导入后重新按本机状态初始化。
- 测试清库和开发环境可显式清除这些键，生产 UI 不提供“重新执行首次默认策略”。

## 11. 设置页面设计

位置：`设置 → 窗口与后台`，在关闭窗口行为下方新增“登录 Windows 时启动”区块。

### 11.1 正常文案

标题：`登录 Windows 时启动`

已开启说明：`登录 Windows 后自动打开优计主义主界面。`

已关闭说明：`不会随 Windows 登录自动启动。`

便携版不确定说明：`启动项已注册，但当前 Windows 未提供可可靠读取的启用状态。软件不会自动改写它。`

系统关闭说明：`已在 Windows 启动应用中关闭。需要由你在系统设置中重新开启。`

路径失效说明：`启动项仍指向旧位置。确认后可改为当前程序位置。`

### 11.2 交互规则

- 页面进入时查询真实状态，并显示短加载态。
- 修改期间禁用开关，防止并发点击。
- 修改结束后重新查询；UI 使用重新查询结果，不使用乐观假状态。
- `disabledBySystem` 时，开关保持关闭，显示“打开 Windows 启动应用设置”。
- `stalePath` 时显示“重新启用”；只有用户点击后才覆盖旧路径。
- `unavailable` 时显示稳定错误说明和“重试”，不弹窗。
- 非 Windows 平台隐藏该区块，或显示不可用说明；不得显示一个无效可点击开关。
- 所有控件支持键盘焦点、Enter/Space 操作和屏幕阅读器状态标签。

## 12. 单实例设计

### 12.1 锁的作用域

原生 `wWinMain` 在创建 Flutter 引擎、数据库或插件前建立每用户锁。

锁名必须包含：

- 稳定产品标识；
- 当前 Windows 用户 SID 的不可逆稳定摘要；
- 协议主版本。

不使用全机器共享的 `Global\` 锁，避免一个用户阻止另一用户运行。锁的 DACL 只允许当前用户和必要的系统主体访问。

### 12.2 主实例与第二实例

主实例：

1. 成功取得锁。
2. 建立本地 IPC 服务器。
3. 再创建 Flutter 引擎和窗口。
4. 原生激活通道就绪前把请求保存在有界队列。
5. Dart 明确调用 `markReady` 后再依次交付。

第二实例：

1. 未取得锁。
2. 解析本次启动来源为白名单激活消息。
3. 连接主实例 IPC。
4. 发送请求并等待带相同 `requestId` 的 ACK。
5. 收到 ACK 后退出，不初始化 Flutter、数据库、托盘、通知或更新服务。

### 12.3 IPC 选择与安全

推荐使用当前用户专属的 Windows Named Pipe；如实施阶段证明现有窗口消息能满足同等认证、队列和 ACK 要求，可在实施计划中替换，但必须重新评审安全性。

协议字段：

```text
magic: 固定 4 字节
schemaVersion: uint16
kind: enum
requestId: 128-bit random id
payloadLength: uint32
payload: UTF-8 JSON or typed bytes
```

限制：

- 总消息上限 64 KiB。
- 连接和 ACK 均有短超时。
- 只允许当前用户 SID。
- `kind` 只接受白名单。
- 未知版本、未知类型、超长、截断、重复 requestId 均拒绝。
- 主实例维护有限期去重集合，防止重试导致重复导航。
- 协议不得承载可执行命令、PowerShell、任意文件读取或动态 DLL 路径。

### 12.4 激活类型

| 类型 | 行为 |
| --- | --- |
| `showMainWindow` | 恢复、显示并尝试置前主窗口 |
| `autostart` | 与 `showMainWindow` 相同，附诊断来源，不改变导航 |
| `notificationWake` | 唤醒窗口，并通知现有通知适配器消费其拥有的载荷 |
| `deepLink` | 校验协议、主机、路径和长度后交给路由协调器 |
| `updateCompleted` | 显示新版本主界面；更新状态由现有更新服务读取 |

通知激活的具体原生数据格式必须以当前 `flutter_local_notifications_windows` 实际行为和回归测试为准。单实例协议只传递应用拥有并能验证的最小标识；不得复制插件内部未承诺稳定的结构。

## 13. 窗口恢复语义

`FlutterWindow` 新增唯一的恢复入口，供托盘与激活协调共用：

```text
RestoreMainWindow(reason)
```

行为顺序：

1. 如果窗口被隐藏，先显示。
2. 如果最小化，恢复。
3. 如果在后台，调用允许的 Windows 前台激活流程。
4. 将焦点交给 Flutter 主视图。
5. 不创建新窗口。

现有托盘左键必须改为调用同一入口，避免托盘恢复和第二实例恢复产生两套不一致行为。

开机启动必须走正常首帧显示逻辑。`--autostart` 只用于标记来源，不得触发隐藏或最小化。

## 14. 激活队列与 Dart 协调

### 14.1 原生到 Dart

建议建立 `personal_planner/activation` 通道：

1. Dart 先安装原生回调处理器。
2. Dart 调用 `markReady`。
3. 原生按接收顺序刷新启动期间队列。
4. 后续消息实时转交。

队列要求：

- 最大 32 条；超出时合并重复的 `showMainWindow`/`autostart`，不得无限增长。
- 导航型消息不可被普通显示消息覆盖。
- 相同 requestId 只处理一次。
- 应用锁未解锁时，导航意图保存在应用锁之后，不能绕过锁屏。

### 14.2 通知所有权

现有通知流程继续负责：

- 运行中通知点击：`NotificationPort.onTapped`；
- 通知冷启动：`NotificationPort.launchPayload()`；
- 最终路由：`PlannerApp`/`GoRouter`。

单实例层只负责确保“第二进程不会吞掉唤醒”。实施前必须为当前插件建立以下真实证据：

1. 无实例时点击通知，插件如何把载荷交给 Dart。
2. 有实例时点击通知，是否由 COM 激活器直接回调主实例。
3. 如果 Windows 启动了第二进程，哪些命令行或 COM 信息需要转交。

在证据确认前，不得删除现有 `launchPayload()` 冷启动路径。

## 15. 启动来源状态机

### 15.1 无主实例

```text
PROCESS_START
→ ACQUIRE_INSTANCE_LOCK
→ START_IPC_SERVER
→ CREATE_FLUTTER_ENGINE
→ CREATE_MAIN_WINDOW
→ REGISTER_CHANNELS_AND_PLUGINS
→ DART_READY
→ DELIVER_INITIAL_ACTIVATION
→ RUNNING
```

任何自启动注册查询失败均不得把进程送入退出状态。

### 15.2 已有主实例

```text
PROCESS_START
→ INSTANCE_LOCK_HELD
→ BUILD_VALIDATED_ACTIVATION
→ CONNECT_PRIMARY
→ SEND
→ WAIT_ACK
→ EXIT_WITHOUT_FLUTTER
```

### 15.3 主实例无响应

```text
CONNECT/ACK TIMEOUT
→ retry with bounded backoff
→ inspect mutex/process liveness
   ├─ owner dead / abandoned mutex → acquire and become primary
   └─ owner alive → do not start second data writer
                    show one native error for user-initiated launches
                    stay silent for background-only system retries
                    exit with diagnostic code
```

不允许因 IPC 一次失败就直接启动第二套 Flutter 和数据库。

## 16. 与更新、卸载和安装形态的关系

### 16.1 MSIX 更新

- TaskId 和包身份稳定，更新继承系统状态。
- 更新后首次启动不清除 `initialized.v1`。
- 更新助手按 AUMID 激活后，若已有新版本实例，走单实例转交。
- 旧版本和新版本协议主版本不兼容时，更新流程必须先确保旧实例退出；不得让两个版本共享数据库。

### 16.2 便携版更新或移动

- 原地替换且路径不变时保持 Run 项。
- 文件夹移动后报告 `stalePath`，不自动修改。
- 删除便携版目录可能留下失效 Run 项；由于没有卸载器，应用只能在仍可运行时由用户关闭并清理。

### 16.3 安装形态迁移

运行时通过包身份自动选择适配器，用户不选择“MSIX/便携版”。

MSIX 首次运行时如发现固定便携 Run 项：

- 能证明该项属于当前产品且指向同一受信任安装来源时，可在明确迁移步骤中清理；
- 不能证明时不删除，只在设置页报告可能重复；
- 迁移清理必须有独立测试，不能依靠字符串包含产品名。

MSIX 卸载后，StartupTask 由包系统清理。应用不得额外保留一个 HKCU Run 备用项。

## 17. 错误模型与诊断

稳定错误码至少包括：

| 错误码 | 含义 |
| --- | --- |
| `STARTUP_QUERY_FAILED` | 无法查询系统状态 |
| `STARTUP_ENABLE_FAILED` | 启用失败 |
| `STARTUP_DISABLE_FAILED` | 禁用失败 |
| `STARTUP_TASK_NOT_DECLARED` | MSIX 清单缺少固定 TaskId |
| `STARTUP_DISABLED_BY_SYSTEM` | 系统/用户从 Windows 入口关闭 |
| `STARTUP_PORTABLE_PATH_STALE` | 便携 Run 项路径失效 |
| `STARTUP_PORTABLE_VALUE_COLLISION` | 固定值名被无法确认归属的内容占用 |
| `STARTUP_STATE_UNKNOWN` | 便携系统抑制状态无法可靠判断 |
| `INSTANCE_IPC_CONNECT_TIMEOUT` | 第二实例连接超时 |
| `INSTANCE_IPC_ACK_TIMEOUT` | 主实例未确认接收 |
| `INSTANCE_PROTOCOL_REJECTED` | 消息版本、类型或长度无效 |
| `INSTANCE_PRIMARY_UNRESPONSIVE` | 主实例存活但无法响应 |

日志只允许记录：时间、版本、安装形态、状态枚举、错误码、Win32/HRESULT 数值、耗时和 requestId 的截短摘要。

禁止记录：任务名称、日程标题、通知正文、完整深链查询参数、用户名、完整用户路径和数据库内容。

## 18. 测试设计

### 18.1 领域与应用单元测试

`StartupService` 必须覆盖：

1. 未初始化且未注册时默认启用一次。
2. 初始化后未注册时不自动恢复。
3. `disabledBySystem` 永不调用 `enable()`。
4. `registeredStateUnknown` 不改写系统。
5. `stalePath` 不自动覆盖。
6. 查询失败不写“已启用”。
7. 软件内关闭写入显式意图。
8. 软件内开启后使用真实回读状态。
9. 更新版本变化不重置初始化标记。
10. 非 Windows 返回 `unsupported`。

### 18.2 Dart 平台适配测试

- 包身份探针成功、无包身份和探针异常三者可区分。
- MethodChannel 返回值严格解析；未知枚举不当作启用。
- 原生异常映射为稳定错误码。
- 系统设置入口失败不修改状态。
- 数据备份/恢复不会跨设备覆盖自启动本机状态。

### 18.3 原生测试

建立不依赖 Flutter 引擎的 C++ 测试目标，覆盖：

- 命令行白名单解析。
- 带空格、Unicode 和引号的便携路径。
- Run 命令生成和严格反解析。
- SID 范围锁名与 IPC 名称。
- 协议编码、解码、版本拒绝、截断和 64 KiB 上限。
- requestId 去重。
- 主实例、第二实例和 abandoned mutex 判定。
- ACK 超时策略。
- 激活队列合并规则。
- 非当前用户连接拒绝。

### 18.4 Widget 测试

- 页面加载态。
- `enabled`、`disabledByApp`、`disabledBySystem`、`registeredStateUnknown`、`stalePath`、`unavailable`、`unsupported` 的完整呈现。
- 修改期间防止重复点击。
- 失败后回读并恢复真实开关状态。
- 系统禁用时显示系统设置入口。
- 便携路径失效时只有显式点击才修复。
- 键盘焦点、语义标签和窄窗口不溢出。

### 18.5 集成测试

至少建立以下可自动化链路：

1. 主实例运行时再次启动，进程数仍为一，窗口被恢复。
2. 主实例仍在初始化时第二次启动，请求在 Dart ready 后送达。
3. 通知点击冷启动仍进入目标页面。
4. 通知点击已有实例仍进入目标页面。
5. 深链冷启动和已有实例转交。
6. 更新完成激活不会产生第二个主实例。
7. 应用锁开启时激活不会绕过解锁页。
8. 主实例异常退出后新进程可接管。

### 18.6 打包门禁

发布流水线必须解包最终 MSIX 并验证：

- 包身份、Publisher 和 Application Id 未漂移；
- StartupTask 扩展存在；
- TaskId 为 `BestPlanningStartup`；
- Executable 指向真实主程序；
- 默认 `Enabled` 配置符合本设计；
- 通知激活器配置仍存在且 GUID 与代码一致；
- 最终测试的 MSIX 哈希与发布资产一致。

## 19. 真实环境验收矩阵

以下项目不能由单元测试替代：

| 系统 | 形态 | 场景 |
| --- | --- | --- |
| Windows 10 | 已签名 MSIX | 新装、首次启动、注销登录、系统禁用、应用禁用、覆盖升级 |
| Windows 11 | 已签名 MSIX | 新装、首次启动、注销登录、系统禁用、应用禁用、覆盖升级 |
| Windows 10 | 便携版 | 初次运行、注销登录、移动目录、关闭、重新启用 |
| Windows 11 | 便携版 | 初次运行、注销登录、移动目录、关闭、重新启用 |

每个环境继续检查：

- 开机/登录后主界面可见；
- 任务管理器中只有一个主应用实例；
- 托盘左键恢复；
- 普通双击恢复；
- 通知点击目标正确；
- 深链目标正确；
- 更新后状态保持；
- 未出现 UAC；
- 未出现反复弹窗；
- 125%/150% 缩放和窄窗口可用；
- 键盘和 Windows Narrator 能读出开关真实状态。

测试记录必须写明操作系统构建号、安装形态、应用版本、测试时间、预期、实际、日志位置和执行人。

## 20. 发布与回退

### 20.1 发布顺序

1. 先完成领域状态、端口和纯逻辑测试。
2. 完成 MSIX/便携注册适配器和原生测试。
3. 完成单实例与激活协议。
4. 接入现有通知、深链、托盘和更新链路。
5. 接入设置页。
6. 完成最终 MSIX 清单门禁。
7. 完成真实 Windows 登录验收。
8. 形成发布报告后才允许标记完成。

### 20.2 回退策略

若发布后发现自启动注册缺陷：

- 功能开关可通过版本内特性门禁暂时隐藏；
- 不删除用户现有系统状态；
- 不在后台反向重写 StartupTask 或 Run 项；
- 单实例层如需回退，必须先证明不会重新引入双数据库写入；
- 修复版沿用同一 TaskId 和协议兼容策略。

数据库模式不应因本功能升级；本地初始化证据复用现有 `SettingsRepository`，不为一个设置引入数据库迁移。

## 21. 完成定义

只有满足以下全部条件，才能宣称“开机自启动功能完成”：

- 新安装首次运行后默认启用；
- 下次登录 Windows 时直接显示主界面；
- MSIX 与便携版均可用；
- 用户在软件内关闭后不会自动恢复；
- 用户在 Windows 中关闭后不会被软件绕过；
- 升级和修复安装保持用户决定；
- 普通双击、开机启动、托盘、通知、深链和更新完成均不产生第二个数据写入实例；
- 第二实例的用户操作在收到 ACK 前不会被丢弃；
- 通知冷启动和运行中点击均能到达原目标；
- 不要求管理员权限，不触发 UAC；
- 无正常流程弹窗和重复错误通知；
- 自动化测试全部通过；
- Windows 10/11 的 MSIX 与便携真实验收完成；
- 最终发布资产的清单、签名、哈希与验收资产一致；
- 发布报告如实列出未执行项，不能以单元测试冒充真实登录、签名安装或无障碍验收。

## 22. 官方依据

- Microsoft `StartupTask`：<https://learn.microsoft.com/en-us/uwp/api/windows.applicationmodel.startuptask>
- Microsoft `StartupTask.RequestEnableAsync`：<https://learn.microsoft.com/en-us/uwp/api/windows.applicationmodel.startuptask.requestenableasync>
- Desktop StartupTask 清单元素：<https://learn.microsoft.com/en-us/uwp/schemas/appxpackage/uapmanifestschema/element-desktop-startuptask>
- 将桌面扩展与包集成：<https://learn.microsoft.com/en-us/windows/uwp/porting/desktop-to-uwp-extensions>
- Windows Run/RunOnce 注册表项：<https://learn.microsoft.com/en-us/windows/win32/setupapi/run-and-runonce-registry-keys>
- Windows 包身份概览：<https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/packaging/>

## 23. 待实施计划明确、但不改变设计的事项

以下是实施层选择，不需要重新讨论产品语义，但必须在实施计划中给出明确答案：

1. 当前 `msix` 工具通过配置、模板还是受控后处理生成 StartupTask 清单。
2. 现有通知插件在“已有主实例时 Windows 又创建第二进程”的真实原生载荷形式。
3. Named Pipe 使用的具体 Win32 安全描述符与 owner liveness 探测方法。
4. 打开 Windows 启动应用设置所使用的受支持 URI/入口及其版本兼容降级。
5. 便携版对任务管理器抑制信息是否只返回 `registeredStateUnknown`，或在经 Windows 10/11 真实证据确认后增加只读 best-effort 探测。

无论这些实现选择如何，均不得破坏第 5 节的不变量。
