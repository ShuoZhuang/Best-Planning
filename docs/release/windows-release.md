# Windows 发布流程

Task 20 的交付物之一，定义首版 Windows 产物的构建、版本与校验步骤。

**当前状态（2026-10-03 实测更新）**：本文件先固定流程与校验点，避免发布时临时决定版本号、
包标识与验收范围。**`dart run msix:create` 已在本机实际执行过**（此前一直记为"尚未执行"），
结果如下——它把这条流程从"从未跑过"推进到"只差一项外部依赖"：

| 步骤 | 实测结果 |
| --- | --- |
| `flutter build windows`（release） | **成功**（56.7s） |
| MSIX 文件组装与打包 | **成功**，产出 `build\windows\x64\runner\Release\personal_planner_1.0.0_x64.msix`（14.4 MB） |
| **SignTool 签名** | **失败**：`No certificates were found that met all the given criteria`。即**没有任何代码签名证书**，产物因此是**未签名的 MSIX**（不可作为受信任包安装） |

因此**发布仍被证书挡住**，而证书正是下文第 2 节列为"待确认"的那一项。**本次刻意不生成自签
证书**：`msix_config.install_certificate` 明确为 `false`（构建过程不得静默修改本机受信任证书
库），而生成自签证书属于"替发布者做决定"。**包标识 `identity_name` 也刻意未改**——一旦发布
不可更改，须由产品侧确定自有反向域名。

**端到端集成测试同日实测**：`flutter test integration_test -d windows` 的三条流程
（首周计划、临时晚归重排、备份恢复）**逐条单独运行时全部通过**；**一次性批量运行**时第一条
通过、后两条在 `loading` 阶段报 `Error waiting for a debug connection: The log reader
stopped unexpectedly, or never started.`——失败发生在**测试装置与应用的连接**上，不在任何
断言上。因此**建议逐条运行**（见第 5 节）。

**本机运行桌面构建前必须手工补插件符号链接**（本轮新发现，成因见技术设计 §13.0.9）：本机
**开发人员模式已开启**，但 flutter_tools 这个 **Dart 子进程**创建符号链接会失败
（`errno = 1314 ERROR_PRIVILEGE_NOT_HELD`），而普通 shell 可以。绕法是从普通 shell 先把
`windows/flutter/ephemeral/.plugin_symlinks/<插件>` 指向 pub 缓存里的插件目录（清单见
`windows/flutter/generated_plugins.cmake` 与 `.flutter-plugins-dependencies`），flutter_tools
发现链接已存在就不再创建。**不要为此跑 `flutter clean`**——它删掉 ephemeral 后在这个令牌下
重建不出来。

## 1. 产物

| 产物 | 用途 | 状态 |
| --- | --- | --- |
| `personal_planner.exe`（release） | 可直接运行的桌面程序 | 可构建 |
| `personal_planner.msix` | 正式安装方式；提供 Windows 包身份，使本地通知可被可靠安排与取消 | 依赖与 `msix_config` 已加入 `pubspec.yaml`；**尚未实际执行过 `dart run msix:create`** |

发布必须以 MSIX 为准：技术设计 §10 说明只预排一次性通知，而可靠的通知取消与查询能力
依赖包身份（§11 的风险表亦记录「Windows 通知行为受包身份限制」）。仅分发 release EXE
会让通知行为不可靠，不作为发布形式。

## 2. 版本与标识

| 项 | 值 | 说明 |
| --- | --- | --- |
| 应用版本 | `pubspec.yaml` 的 `version` | 当前仍为模板默认 `1.0.0+1`，发布前必须确定为正式版本号 |
| 包标识（Identity Name） | `msix_config.identity_name`，当前为示例值 `com.example.personal_planner` | 一旦发布不可更改，需在首次发布前固定为自有反向域名 |
| 发布者（Publisher） | `msix_config.publisher_display_name`，当前为示例值 | 与签名证书主体一致 |
| MSIX 版本 | `msix_config.msix_version`，四段式 | 必须与 `pubspec.yaml` 的 `version` 对应，当前均为 1.0.0 |
| 升级策略 | 同一包标识 + 递增版本 | 换标识等于换应用，用户数据不会自动迁移 |
| 版本号同步 | `windows/runner/Runner.rc` | 需与 `pubspec.yaml` 保持一致 |

`windows/runner/Runner.rc` 中的产品版本与文件版本必须随 `pubspec.yaml` 一起更新，否则
文件属性显示的版本与安装包不一致。

## 3. 发布前必须提交的内容

- `pubspec.lock`（保证依赖可复现，见技术设计 §1.2）；
- `drift_schemas/` 下的 schema 快照（每次 `schemaVersion` 变化都要重新导出）；
- `docs/testing/manual-windows-checklist.md` 的执行记录。

## 4. 构建步骤

```bash
# 1. 依赖与生成代码
flutter pub get
dart run build_runner build --delete-conflicting-outputs

# 2. 静态检查与自动化测试（必须全绿）
flutter analyze
flutter test

# 3. 端到端流程（已编写，尚未在 Windows 上执行）
flutter test integration_test -d windows

# 4. release 产物
flutter build windows --release

# 5. MSIX（依赖与 msix_config 已就绪；首次执行前先确认 identity_name 与发布者）
dart run msix:create
```

`flutter build windows --release` 与 `dart run msix:create` 的产物路径需在发布说明中记录，
便于回溯具体构建。

## 5. 发布前校验

1. 在**未安装 Flutter**的 Windows 10/11 x64 机器上安装 MSIX；
2. 逐项执行 `docs/testing/manual-windows-checklist.md`，任何「不通过」项都阻塞发布；
3. 确认卸载后用户数据目录的处理方式符合预期（默认保留数据，永久清除只由用户主动触发）；
4. 确认全新安装后无需手工配置即可生成首个计划。

## 6. 已知阻塞项

| 阻塞 | 说明 |
| --- | --- |
| MSIX 已执行到签名前一步（**2026-10-03 实测更新**） | `dart run msix:create` 已实际运行：`flutter build windows` 成功、MSIX 组装与打包成功并产出 `personal_planner_1.0.0_x64.msix`（14.4 MB），**仅 SignTool 签名失败**（`No certificates were found`）。因此**剩余阻塞项只有签名证书与包标识/发布者这两个必须由产品侧决定的取值**，不再是"整条流程没跑过" |
| 端到端测试尚未执行 | `integration_test/` 下已有三条流程（首个七日计划、临时晚归后重排、备份与恢复），`pubspec.yaml` 已加入 SDK 自带的 `integration_test` 依赖，但从未在 Windows 设备上运行过 |
| 手工清单尚未执行 | 需求规格第 18 节的 19 项验收全部未勾选 |
| 部分功能在界面上不可达 | 统计、专注、偏好设置、数据管理与特殊日页面尚无路由；应用锁不拦截启动；手动移动被禁用。详见技术设计文档 §13.0 |

在这些阻塞项清零之前，首版状态应记为「不可发布」，而不是「已完成待验收」。
