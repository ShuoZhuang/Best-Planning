# M6 规格：课表导入可靠性（错误恢复补齐）

> 冻结路线图 §10 的边界。**先复现用户真实图片的读取失败，再补边界；不得另建第二套导入界面。**
> **不抬版本、不单独发布**（§3）；**不带入 M7 及以后**（§14）。

## 1. 现状（审计结论，2026-10-07）

现有实现相当厚：`timetable_import_controller.dart` 783 行 + 13 个测试文件
（隐私、回滚、预览、冲突、解析、OCR 契约、路由、集成）。逐条对照 §10「错误恢复」：

| §10 错误恢复要求 | 现状 | 差距 |
| --- | --- | --- |
| 解码失败显示**文件名**、**支持格式**、"**更换图片**"，不得只显示系统异常文本 | ⚠️ 有 `TimetableOcrFailureCode.decodeFailed` 分支与文案，但**没有文件名**，格式只是顺带一提，**失败处没有"更换图片"按钮**（只有上方一个通用选择按钮） | **补齐** |
| OCR 识别不到表格时允许**手动新增课程**，不能把用户困在上传步骤 | ✅ `manual-timetable-entry` 按钮在 `ocrFailureCode != null` 或 `draft == null` 时出现 | 无 |
| 图片过大时先在本地生成**临时识别副本**，原图不变 | ✅ `imageTooLarge` 分支 + OCR 引擎侧缩放 | 无 |
| 重复导入同一课表必须提供**去重预览**，不得静默创建重复课程 | ✅ 已有去重与"默认跳过"文案 | 无 |
| 单门课程信息不完整时**标出该门**，其他识别结果继续保留 | ✅ 已有 | 无 |

**结论**：M6 本轮只需要补**解码失败这一条**。其余四条已实现，本轮**加测试钉住**而不改行为。

## 2. 用户结果（§10）

用户从日历页能找到"导入课表"。**图片读取失败时能换图、旋转、裁剪、重试或手动继续**；
识别结果必须经过确认，不能直接写入日历。

## 3. 非目标

- **不重建导入系统、不新增第二套导入界面**（§10「已有能力」明确划界）。
- 不改 OCR 引擎、裁剪/旋转算法、解析器、去重逻辑、回滚语义。
- 不改 `PreviewStep` / `ReviewStep` / `TermStep` / `PeriodStep` 的既有行为。
- 不改数据库、包身份、版本号。
- 不做 M7 统计、M8 引导。

## 4. 实施范围

### 4.1 解码失败的消息要能自查（§10 第一条）

`decodeFailed` 的文案必须同时给出：

1. **文件名**（取自 `selectedImagePath`，只取**文件名**不含目录——§10 同时要求"图片原件
   不写入数据库、不上传"，把完整路径显示出来没有必要，也更容易被截图外泄）；
2. **支持的格式**：PNG / JPG / JPEG；
3. 可做的事：**更换图片**（就地按钮）、重试、或手动录入。

### 4.2 失败处就地给"更换图片"

失败信息下方直接给一个 `更换图片` 按钮（key `timetable-change-image`），
**只在该失败与图片有关时出现**（`decodeFailed` / `imageTooLarge`），
点击等价于"重新选一张并识别"（复用既有 `pickAndRecognize`，不新建流程）。

> **为什么不能只靠上方那个通用选择按钮**：§10 要求的是"失败时能换图"。
> 用户在失败提示处读完原因之后，动作必须在**同一处**，否则要回头找按钮。

## 5. 强制测试

`test/features/calendar/timetable_import_page_test.dart` 追加：

| 要求 | 测试 |
| --- | --- |
| 解码失败消息含**文件名** | 选一张路径为 `.../我的课表.png` 的图、让 OCR 抛 `decodeFailed`，断言提示里出现 `我的课表.png` |
| 解码失败消息含**支持格式** | 断言提示里同时出现 `PNG`、`JPG`、`JPEG` |
| **不暴露原始异常文本** | 让 OCR 抛出一个**带路径的** `PathAccessException` 之类的东西，断言界面上**不出现** `PathAccessException`、不出现完整目录路径 |
| 失败处有"更换图片" | 断言 `timetable-change-image` 存在；点击后再次调用 `pickImage` |
| 与图片无关的失败**不给**"更换图片" | `languageUnavailable` 时断言 `timetable-change-image` **不存在**（换图解决不了缺 OCR 语言） |
| 其余四条**不回归** | 既有的手动录入、去重预览、单门不完整、隐私用例全部保留并通过 |
| 手动录入不被困住 | 解码失败时 `manual-timetable-entry` 仍然可用 |

## 6. 退出条件（§10）

- [ ] **无法用真实截图验证**：§10 第一条要求"使用用户提供的两种课表截图各完成一次识别、
      修正、预览和导入"。**用户提供的截图不在本会话上下文中**，因此**如实标注未完成**，
      由用户确认或重新提供。**不得声称已验证。**
- [ ] 周数与第一周日期双向换算有跨年、学期中途和非法日期测试（既有，需核实覆盖）。
- [ ] 单双周、非整学期课程、连续两节和不同节长均有测试（既有，需核实覆盖）。
- [ ] 同一图片重复导入不会产生重复固定日程（既有）。
- [ ] 任一步失败都不会写入半套课程（既有 `timetable_import_rollback_test.dart`）。
- [ ] **图片读取失败不再暴露 `PathAccessException` 等原始异常**（本轮补齐 + 新测试）。
- [ ] `analyze` 0 问题、`format` 0 改动、全量 `flutter test` 全绿、六条集成测试逐条通过。
- [ ] M6 章节写入用户指南草稿；更新路线图 §19。

## 7. 复现命令

```powershell
$env:TEMP = "G:\best-planing\.flutter-tmp"; $env:TMP = "G:\best-planing\.flutter-tmp"
Set-Location 'G:\best-planing\.worktrees\native-implementation'
& 'G:\best-planing\.tooling\flutter-bundle\flutter\bin\flutter.bat' test test/features/calendar/timetable_import_page_test.dart
& 'G:\best-planing\.tooling\flutter-bundle\flutter\bin\flutter.bat' test test/application/
& 'G:\best-planing\.tooling\flutter-bundle\flutter\bin\flutter.bat' analyze --no-pub
& 'G:\best-planing\.tooling\flutter-bundle\flutter\bin\flutter.bat' test
```
