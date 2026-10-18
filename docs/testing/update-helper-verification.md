# 原生更新助手验证记录

日期：2026-10-18

## 构建

```powershell
$cmake -S windows/update_helper -B windows/update_helper/build `
  -G "Visual Studio 18 2026" -A x64 `
  "-DWINRT_INCLUDE=E:\Windows Kits\10\Include\10.0.26100.0\cppwinrt"
$cmake --build windows/update_helper/build --config Release
```

结果：通过（MSVC 19.50 / Windows SDK 10.0.26100）。

## 自检

```powershell
windows\update_helper\build\Release\update_helper.exe --selftest
```

输出：`selftest ok`（退出码 0）。

## 真实 MSIX 验证

对象：`build\windows\x64\runner\Release\personal_planner_1.8.1.0_x64.msix`（18,197,195 字节，
由本仓库正式证书签名，`AppxSignature.p7x` 为 PKCX + PKCS#7）。

```powershell
windows\update_helper\build\Release\update_helper.exe --verify <msix>
```

输出：

```json
{
  "ok": true,
  "identity": {
    "identityName": "ShuoZhuang.PersonalPlanner",
    "publisher": "CN=Shuo Zhuang, O=Personal User, C=CN",
    "familyName": "ShuoZhuang.PersonalPlanner_v9555qkaxdyym",
    "architecture": "x64",
    "version": "1.8.1.0"
  },
  "sha256": "6adcdf7aebf6e4592716330e88d9d47a349e0af9e016f8d4b2b595fba35565cf",
  "sizeBytes": 18197195
}
```

覆盖：包身份、Publisher、PFN（由 Publisher 按 Windows base32 规则派生）、架构、版本、
PKCS#7 签名、证书链、内容哈希。

## 与 AppxPackaging 的关系

本会话的 `IAppxFactory::CreatePackageReader` 在该受限令牌下返回 `E_ACCESSDENIED`。
`package_inspector.cpp` 因此实现了一条不依赖 AppxPackaging 的降级路径：

1. 自带 ZIP64 读取器（含 stored 与 deflate 条目、ZIP64 扩展字段）；
2. 最小 DEFLATE 解码器（RFC 1951）读取 `AppxManifest.xml`；
3. `CryptVerifyMessageSignature` 验证 `AppxSignature.p7x`（去掉 `PKCX` 头）的签名与证书链；
4. 用 `CertNameToStr` 得到 X500 Subject，与期望 Publisher 逐属性比较。

正常用户会话仍优先使用 AppxPackaging；降级路径只处理"读取器不可用"，不降低任何校验要求。

## 请求校验与安装准备（dry-run）

`tool/update_helper_tests.ps1` 生成一份真实请求（真实 MSIX、真实大小/SHA-256、一次性令牌、
PID/启动时间、有效期），执行：

```powershell
update_helper.exe --apply <request> --dry-run
```

输出 `helper-status.json`：`{"transactionId":"dry-run-1","state":"verified",...}`，退出码 0。
该模式真实执行：请求结构/有效期/路径越界校验、跨进程锁、进程退出等待、二次读取包身份、
大小与 SHA-256 复核、签名验证；**在部署前停止**，不做 `AddPackageAsync`、不激活、不回退。

同一脚本用短令牌重放请求，断言被拒绝且失败码为 `UPDATE_HELPER_REQUEST_INVALID`（不进入部署）。

## 未覆盖

- `--apply` 的真实部署、AUMID 启动、健康等待与回退：需要两台真实 Windows 与正式产物，
  按 `tool/update_e2e.ps1` 执行并保留证据。
- 本记录不能替代 UPD-045～047 的 Windows 矩阵与 1.9.0→1.9.1 演练。
