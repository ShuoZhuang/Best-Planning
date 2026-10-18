# UAC broker 验收原始证据目录（1.10.2）

这里存放 `docs/testing/offline-installer-uac-broker-acceptance.md` 每个用例的原始证据：

```text
<ID>/setup.log                 Setup 日志原文件
<ID>/setup.log.sha256          对应 SHA-256
<ID>/before-whoami.txt         执行账户测试别名与账户类型
<ID>/before-package.txt        安装前 Get-AppxPackage 结果
<ID>/before-certificate.txt    安装前 LocalMachine\TrustedPeople 查询
<ID>/screenshot-uac.png        UAC 前的界面
<ID>/screenshot-granted.png    授权后的界面
<ID>/screenshot-final.png      最终页面
<ID>/after-package.txt         安装后原始用户的包登记
<ID>/admin-package.txt         标准账户场景：管理员账户安装前后登记对比
```

约束：

- 目录内容与 `docs/testing/evidence/offline-installer-uac-broker-1.10.2.json` 中的
  `logPath` / `logSha256` / `screenshotPath` / `screenshotSha256` 必须逐项一致。
- 账户名只记录测试别名（`AdminTest` / `StandardTest`），不记录真实姓名或密码。
- 证据必须绑定**最终签名** Setup 的 SHA-256；重建候选后旧证据全部作废。

当前状态：**NOT RUN**（目录为空）。
