# 原生更新助手

这是规格 §12 的独立 C++/WinRT 目标。它不属于 Flutter 的 CMake 工程（避免在没有 Windows SDK
的机器上阻断应用构建），而是单独构建：

```powershell
$cmake = 'E:\Microsoft Visual Studio\18\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
& $cmake -S windows/update_helper -B windows/update_helper/build `
    -G "Visual Studio 18 2026" -A x64 `
    "-DWINRT_INCLUDE=E:\Windows Kits\10\Include\10.0.26100.0\cppwinrt"
& $cmake --build windows/update_helper/build --config Release
& windows/update_helper/build/Release/update_helper.exe --selftest
```

产物：`windows/update_helper/build/Release/update_helper.exe`。发布时把它放在应用 EXE 同目录
（Dart 侧 `WindowsUpdateHelper` 默认从 `Platform.resolvedExecutable` 的同目录查找），
或通过 `BEST_PLANNING_UPDATE_HELPER` 指定路径。

## 子命令

| 命令 | 用途 |
| --- | --- |
| `--probe` | 输出当前包身份与版本 JSON（未打包时 `installedPackage` 为 null） |
| `--verify <msix>` | 读取包清单与签名，验证身份、签名、证书链、发布者 |
| `--apply <request>` | 执行一次安装事务（请求校验、等待进程退出、部署、激活、健康等待、回退） |
| `--selftest` | 请求路径越界、token、版本、临时写入的自检 |

## 安全边界

- 不联网、不调用 PowerShell/cmd/批处理、不执行远端命令；
- 只接受更新目录内的 `.ready` MSIX；
- 请求一次性：读取后重命名为 `.consumed`；
- 锁文件 `update-helper.lock` 防并发；
- 安装前**自己**重新检查身份、大小、SHA-256、签名与发布者，不信任主程序的布尔值；
- 回退时按 `snapshot-manifest.json` 恢复快照，不解析业务内容。

## 本环境的验证记录（2026-10-18）

- 构建：通过（MSVC 14.50 / Windows SDK 10.0.26100）。
- `--selftest`：通过。
- `--probe`：通过（当前进程未打包，输出 null）。
- `--verify`：**本会话未通过**。`IAppxFactory::CreatePackageReader` 返回 `0x80070005`
  （E_ACCESSDENIED），已排除包本身问题（`makeappx unpack` 成功、证书在 CurrentUser/
  LocalMachine 的 TrustedPeople 与 Root 中均存在、文件流与内存流表现一致）。该错误与
  本会话受限的进程令牌一致；需要在普通用户会话中复跑 `--verify` 并记录结果。**在复跑通过
  之前，UPD-015 与 UPD-032 的真实签名验证只能记为 `NOT RUN`。**
