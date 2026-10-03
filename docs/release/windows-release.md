# Windows 发布流程

Task 20 的交付物之一，定义首版 Windows 产物的构建、版本与校验步骤。

**当前状态（2026-10-03 实测更新）**：本文件先固定流程与校验点，避免发布时临时决定版本号、
包标识与验收范围。**`dart run msix:create` 已在本机实际执行过**（此前一直记为"尚未执行"），
结果如下——它把这条流程从"从未跑过"推进到"只差一项外部依赖"：

| 步骤 | 实测结果 |
| --- | --- |
| `flutter build windows`（release） | **成功**（56.7s） |
| MSIX 文件组装与打包 | **成功**，产出 `build\windows\x64\runner\Release\personal_planner_1.0.0_x64.msix`（14.4 MB） |
| **SignTool 签名** | **成功**（2026-10-03，见下方"签名已通过"一节）：产物**已签名**，签名者 `CN=Shuo Zhuang, O=Personal User, C=CN`，包身份 `ShuoZhuang.PersonalPlanner`。`Get-AuthenticodeSignature` 状态为 `UnknownError`／"证书链在不受信任的根证书中终止"——这是**未把证书导入受信任存储**导致的，属预期，签名本身有效 |

**签名已通过（2026-10-03 实测）**。这一步踩到了一个不明显的坑，记在这里免得重复排查：

1. **包内自带的测试证书用不了**。msix 在没配 `certificate_path` 时会退回包内自带的
   `lib/assets/test_certificate.pfx`（密码 `1234`），但那张证书是 **X.509 v1、零扩展**
   （没有 Code Signing EKU），本机 signtool 直接拒绝：`No certificates were found that met
   all the given criteria`——**不是**"没有证书"，而是那张证书不被接受。
2. **自己签一张**：`New-SelfSignedCertificate -Type CodeSigningCert -Subject "CN=…, O=…, C=…"
   -CertStoreLocation Cert:\CurrentUser\My`（生成的是 v3、带代码签名 EKU 的证书），
   再 `Export-PfxCertificate` 导出带私钥的 `.pfx`。
3. **但 `/f <pfx> /p <密码>` 仍然失败**：`Store::ImportCertObject() failed`
   （`0x80090010` = `NTE_PERM`）。密码正确也一样，直接从普通 shell 调用也一样（两条都实测过）。
   结论是**这台机器上 msix 自带的 signtool（10.0.19041.1）无法导入它自己那代工具链生成的
   CNG 私钥**——本例没有独立的 Windows SDK signtool 可比对，因此未能进一步定位到具体版本差异。
4. **可行的方式是按指纹从证书库选取**：`signtool sign /sha1 <指纹> /fd SHA256`。它跳过了
   pfx 导入这一步。因此 `pubspec.yaml` 用 `signtool_options` 指定自定义签名命令，而**不是**
   `certificate_path` + `certificate_password`。
5. **一个连带约束**：`certificate_path` 若指向 `.pfx`，msix 会**强制要求** `certificate_password`
   （源码 `extension == '.pfx' && certificatePassword.isNull` 即抛错），那样密码就不得不写进
   会进版本库的 `pubspec.yaml`。因此该字段改指**导出的 `.cer`（只含公钥）**：既满足
   "publisher 由证书推导"的校验，又**让密码不出现在任何文件或命令里**。
6. **私钥刻意放在仓库之外**（`C:\Users\zs200\signing\personal_planner.pfx`），因此"私钥不进
   版本库"不依赖是否记得写 `.gitignore`。

**因此本机现在能产出已签名的 MSIX**。

**安装与身份验证也已完成（2026-10-03 实测）**：证书已导入 `Cert:\CurrentUser\Root` 与
`Cert:\LocalMachine\Root`，`Add-AppxPackage` 安装成功（`ShuoZhuang.PersonalPlanner_1.0.0.0_x64__v9555qkaxdyym`）。
随后用 `tool/verify-package-identity.ps1` 核对包身份：把探针跑进**本包上下文**，得到与生产代码
逐行对应的两段式结果 `FIRST-RC=122` → `SECOND-RC=0`，包全名与安装信息一致；对照的非打包进程
是 `FIRST-RC=15700`。**因此 `hasWindowsPackageIdentity` 的 true / false 两个分支都已有真实
kernel32 调用证据**（边界：验证用的是同 API、同流程、同包上下文的探针，不是读应用自己的变量）。

**仍然待办**：**通知点击的真实 toast 交互**——需要一个**人去点一下通知**。这是发布前唯一
剩下的人工验证项。

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
| 端到端测试**已执行**（2026-10-03 更正） | 三条流程（首个七日计划、临时晚归后重排、备份与恢复）**逐条单独在 Windows 上运行、全部通过**。**批量一次跑会失败**：第一条通过，后两条在 `loading` 阶段报 `Error waiting for a debug connection`——失败在测试装置与应用的连接上，不在断言上。因此可靠的跑法是逐条运行 |
| 手工清单**尚未执行** | 其"当前不可达"标注已逐条更正（那些能力后来都接通了，现已无不可达条目），但**每一格的结果仍然是空的**。需求规格 §18 已完成逐项核对：**18/19 勾选**，唯一未勾选的第 3 项（"一分钟内完成快速录入"）正需要本清单的人工计时 |
| 部分功能在界面上不可达 | 统计、专注、偏好设置、数据管理与特殊日页面尚无路由；应用锁不拦截启动；手动移动被禁用。详见技术设计文档 §13.0 |

在这些阻塞项清零之前，首版状态应记为「不可发布」，而不是「已完成待验收」。
