# Best-Planning / 优计主义

### A local-first intelligent schedule planner for Windows / 面向大学生的本地优先日程规划软件

[![Release](https://img.shields.io/github/v/release/ShuoZhuang/Best-Planning?include_prereleases&logo=github&label=Release)](https://github.com/ShuoZhuang/Best-Planning/releases)
[![Downloads](https://img.shields.io/github/downloads/ShuoZhuang/Best-Planning/total?logo=github&label=Downloads)](https://github.com/ShuoZhuang/Best-Planning/releases)
[![Windows](https://img.shields.io/badge/Windows-x64-0078D6?logo=windows)](https://github.com/ShuoZhuang/Best-Planning/releases)
[![Local First](https://img.shields.io/badge/Data-local%20first-2EA44F)](#privacy--数据与隐私)

---

## Download / 下载

Download the latest Windows release here:

在这里下载最新 Windows 版本：

[https://github.com/ShuoZhuang/Best-Planning/releases](https://github.com/ShuoZhuang/Best-Planning/releases)

> [!TIP]
> 新用户只需下载 **`BestPlanning_Setup_1.10.0_x64.exe`**，双击后同意一次管理员授权即可完成安装。
> 安装器内含完整 MSIX 与公开证书，**断网也能安装**，不需要 PowerShell、证书管理器或单独的 `.msix`。
>
> **当前版本 `1.10.0+47`**（MSIX `1.10.0.0`），同一次 Release 发布五个文件：
>
> | 文件 | 用途 |
> | --- | --- |
> | `BestPlanning_Setup_1.10.0_x64.exe` | 普通新用户：单文件离线安装 |
> | `BestPlanning_Portable_1.10.0_x64.zip` | 不安装 / 无管理员权限：解压即用 |
> | `BestPlanning_1.10.0.0_x64.msix` | 已安装用户或管理员手动部署 |
> | `update-manifest.json` | 应用内更新使用的签名清单 |
> | `SHA256SUMS.txt` | 四个产物的 SHA-256 |
>
> 若 Windows SmartScreen 提示未知发布者，请核对下载来源后选择“更多信息 → 仍要运行”；
> 安装器不会修改任何系统安全策略来绕过它。旧式的“证书 + MSIX + `安装.cmd`”压缩包
> 已不再作为推荐入口。

---

## Documentation / 使用文档

- [1.10.0 发布说明](docs/release/1.10.0-github-release-body.md)
- [Windows 安装与发布说明](docs/release/windows-release.md)
- [版本号规则](版本号规则.md)
- [提交问题](https://github.com/ShuoZhuang/Best-Planning/issues)

---

## Features / 主要功能

- 滚动规划未来 7 天，并检查更远的截止日期。
- 根据截止时间、预计时长、精力要求和个人偏好自动安排任务。
- 支持固定日程、保护时间、可移动任务和个人生活安排。
- 支持连续任务和可拆分任务，计划变化后可以重新计算。
- 支持课表图片识别，并确认学期、周数、节次和课程时间。
- 统一展示领域、保护时间和无领域任务的颜色。
- 按自选时间范围统计计划时间与实际投入。
- 提供无玻璃、克制、激进和极致液体玻璃外观。
- 本地保存数据，并支持备份、恢复和导出。

---

## Supported Platforms / 支持平台

| Platform / 平台 | x64 | x86 | arm64 |
| --- | --- | --- | --- |
| Windows | ✅ | - | - |
| Android | Planned / 计划中 | - | - |
| iOS | Planned / 计划中 | - | - |

当前可下载版本为 Windows x64。新用户下载 `BestPlanning_Setup_1.10.0_x64.exe` 即可；不安装时可使用便携版 ZIP。

---

## Signature Verification / 签名校验

Windows MSIX 使用 Authenticode 签名。Release 同时提供公开证书 `PersonalPlanner-signing-cert.cer`，用于验证签名和完成侧载安装。

```text
Subject:     CN=Shuo Zhuang, O=Personal User, C=CN
Thumbprint:  9E157ECE535D16A224593CA39C084705A4FD3C13
```

`.cer` 只包含公开证书和公钥，不包含签名私钥。各发布文件的 SHA-256 校验值记录在 Release 说明和[构建台账](docs/release/build-ledger.md)中。

---

## Screenshots / 界面预览

### Today / 今日

![今日安排](assets/tutorial/01-today.png)

### Calendar / 日历

![七日历](assets/tutorial/04-calendar.png)

<details>
<summary>查看其他界面 / More screenshots</summary>

![任务管理](assets/tutorial/02-tasks.png)

![领域与项目](assets/tutorial/03-areas.png)

![时间统计](assets/tutorial/05-analytics.png)

![设置](assets/tutorial/06-settings.png)

</details>

---

## Privacy / 数据与隐私

软件默认在本机保存任务、课表、设置和统计数据，不要求登录，也不会默认上传这些内容。建议定期在设置中导出 JSON 备份。

提交 Issue 时请先对截图和日志脱敏，不要上传任务数据库、备份文件、真实课表、签名私钥或密码。

---

## Development / 开发

普通用户无需配置开发环境。需要修改源码、运行测试或自行构建时，请阅读：

- [开发者说明](docs/developer-readme-legacy.md)
- [需求与技术设计](docs/superpowers/specs/2026-10-01-personal-intelligent-scheduling-design.md)
- [Windows 发布流程](docs/release/windows-release.md)
