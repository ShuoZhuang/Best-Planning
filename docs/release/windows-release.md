# Windows 发布流程

Task 20 的交付物之一，定义首版 Windows 产物的构建、版本与校验步骤。

**当前状态（2026-10-02）**：Task 20 尚未完成。本文件先固定流程与校验点，避免发布时
临时决定版本号、包标识与验收范围。标有「待补」的步骤必须先完成才能执行发布。

## 1. 产物

| 产物 | 用途 | 状态 |
| --- | --- | --- |
| `personal_planner.exe`（release） | 可直接运行的桌面程序 | 可构建 |
| `personal_planner.msix` | 正式安装方式；提供 Windows 包身份，使本地通知可被可靠安排与取消 | **待补**：`msix` 依赖尚未加入 `pubspec.yaml` |

发布必须以 MSIX 为准：技术设计 §10 说明只预排一次性通知，而可靠的通知取消与查询能力
依赖包身份（§11 的风险表亦记录「Windows 通知行为受包身份限制」）。仅分发 release EXE
会让通知行为不可靠，不作为发布形式。

## 2. 版本与标识

| 项 | 值 | 说明 |
| --- | --- | --- |
| 应用版本 | `pubspec.yaml` 的 `version` | 当前仍为模板默认 `1.0.0+1`，发布前必须确定为正式版本号 |
| 包标识（Identity Name） | 待定 | 一旦发布不可更改，需在首次发布前固定 |
| 发布者（Publisher） | 待定 | 与签名证书主体一致 |
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

# 3. 端到端流程（待补：integration_test 尚未编写）
flutter test integration_test -d windows

# 4. release 产物
flutter build windows --release

# 5. MSIX（待补：先加入 msix 依赖并配置包标识）
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
| MSIX 依赖与配置缺失 | `pubspec.yaml` 尚无 `msix` 依赖，包标识与发布者未定 |
| 端到端测试缺失 | `integration_test/` 不存在，`pubspec.yaml` 亦无 `integration_test` 依赖 |
| 手工清单尚未执行 | 需求规格第 18 节的 19 项验收全部未勾选 |
| 部分功能在界面上不可达 | 统计、专注、偏好设置、数据管理与特殊日页面尚无路由；应用锁不拦截启动；手动移动被禁用。详见技术设计文档 §13.0 |

在这些阻塞项清零之前，首版状态应记为「不可发布」，而不是「已完成待验收」。
