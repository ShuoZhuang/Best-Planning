# 离线单文件安装器

规格：`docs/superpowers/specs/2026-10-18-offline-bootstrap-installer-design.md`
实施计划：`docs/superpowers/plans/2026-10-18-offline-bootstrap-installer-implementation-plan.md`

一个 EXE、一次 UAC，完成断网首次安装：

```text
校验内嵌载荷 → 信任固定证书 → 以发起用户身份部署 MSIX → 验证真实结果 → 清理 → 启动
```

## 代码结构

| 文件 | 职责 |
| --- | --- |
| `src/main.cpp` | 子命令分派：普通界面 / `--elevated-session` / `--verify-embedded` / `--plan` / `--selftest` / `--version` |
| `src/installer_controller.cpp` | 唯一编排入口：预检、校验、提权、部署、验证、清理、启动 |
| `src/payload_reader.cpp` | 读取 RCDATA 资源（MSIX=101、证书=102、元数据=103） |
| `src/payload_metadata.cpp` | 元数据解析与固定身份校验 |
| `src/secure_session.cpp` | 随机会话目录、限制性 ACL、排他创建、拒绝重解析点、一次性令牌 |
| `src/package_verifier.cpp` | 长度 → SHA-256 → 清单身份 → 签名 → 签名者=固定证书 → （可选）链信任 |
| `src/certificate_manager.cpp` | 指纹/公钥、`LocalMachine\TrustedPeople` 存在性与导入、安全回收判定 |
| `src/elevation_broker.cpp` | 命名管道 + nonce + 有限命令协议；提权进程只写证书 |
| `src/package_deployer.cpp` | 以当前用户部署、同版本修复（重新登记）、拒绝降级、登记验证 |
| `src/application_launcher.cpp` | 从实际登记结果解析 AUMID 并激活 |
| `src/installer_state_machine.cpp` | 状态转换、取消点、关键段 |
| `src/installer_ui.cpp` | Win32 对话框：准备 / 等待关闭 / 进度 / 完成 / 错误 |
| `src/installer_log.cpp` | `%LOCALAPPDATA%\BestPlanning\Setup\setup-*.log`（保留最近 10 份） |
| `tools/embed_payload.cpp` | 发布工具：把 MSIX、证书、元数据写进 Setup 的只读资源 |

共享的包检查、部署错误转换与 AUMID 查询在 `windows/native_shared/`，更新助手与安装器
共用同一份实现，禁止各自复制。

## 构建与自检

```powershell
$cmake = 'E:\Microsoft Visual Studio\18\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
& $cmake -S installer -B installer\build -G "Visual Studio 18 2026" -A x64 `
    "-DWINRT_INCLUDE=E:\Windows Kits\10\Include\10.0.26100.0\cppwinrt"
& $cmake --build installer\build --config Release
```

产物：

```text
installer\build\Release\BestPlanningSetup.exe   无载荷的 stub（不能单独发布）
installer\build\Release\embed_payload.exe       内嵌工具
installer\build\Release\installer_tests.exe     单元测试
```

正式 Setup 必须由发布脚本生成（会写入载荷、签名并跑门禁）：

```powershell
& tool\build_offline_installer.ps1 -Msix release-artifacts\1.10.0\BestPlanning_1.10.0.0_x64.msix `
    -Certificate C:\Users\zs200\signing\personal_planner.cer -Version 1.10.0 -Build 47
```

## 命令行（诊断与验收）

| 参数 | 用途 | 是否写系统 |
| --- | --- | --- |
| 无参数 | 正常安装界面 | 是（校验通过后） |
| `--verify-embedded` | 读资源并校验载荷，打印 JSON | 否 |
| `--plan` | 预检 + 校验 + 查询已安装状态，打印计划 JSON | 否 |
| `--selftest` | 状态机/版本/元数据/证书/会话的自检 | 否 |
| `--diagnose` | 打印临时目录与写入探测结果 | 只建一个临时目录并删除 |
| `--install-unattended [--launch] [--repair]` | 验收/CI：不显示窗口，流程完全一致 | 是（校验通过后） |
| `--elevated-session` | 提权辅助进程（由安装器自己拉起，不要手动运行） | 只写证书 |

## 可重复验收

```powershell
& tool\installer_tests.ps1                 # 单元 + 组件（真实 MSIX、篡改、错误证书、无效 nonce）
& tool\verify_release_assets.ps1 -Directory release-artifacts\1.10.0 -Version 1.10.0 -Build 47
```

**在开发机上验证时要把被测 EXE 复制到工作区之外再运行**：本仓库所在的文件沙箱会限制
"位于仓库内的进程"写入系统临时目录，直接运行会得到与安装器无关的 `ACCESS_DENIED`。
两个脚本都已经这样做（暂存目录在仓库之外，如 `%TEMP%\BestPlanningSetup\...`）。

## 同版本"重新安装"的真实语义\n\nWindows 没有"同版本覆盖已安装文件"的受支持接口。因此同版本时安装器提供的是**修复安装**：\n用 `RegisterPackageByFullNameAsync` 重新登记注册关系，保留数据、不先卸载，但**不会替换已安装文件**。\n文件损坏时只有卸载后重装才能替换（这条限制在界面与验收记录里都写明）。\n\n## 安全边界

- 不做在线下载，不调用 PowerShell/cmd/批处理，不执行任意命令行。
- 载荷未全部验证前绝不导入证书、绝不部署。
- 证书只写 `LocalMachine\TrustedPeople`，不写 Root，不导入私钥。
- 提权进程只重读自身资源、重校验、写一次证书；包部署始终由普通权限主进程完成。
- 提权协议只接受 `verify-and-trust-certificate`，拒绝未知命令、额外字段与任意路径。
- 临时会话随机命名、ACL 限制、排他创建、拒绝重解析点、令牌单次使用。
- 失败时不删除可能仍被旧版本依赖的证书（§10.2）。
