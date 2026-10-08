# M2 辅助功能树测量记录

路线图 §6 要求：

> Windows Accessibility Insights 或 Inspect 能看到独立控件节点，不再只有一个 `FLUTTERVIEW`。

**本机没有安装 Accessibility Insights，也没有 `inspect.exe`（Windows SDK 未安装）。**
本轮我做出了**两个可用的读取器**，并带 Notepad 对照量到了结构（见 §3）。

---

## 1. 可用的读取器

两个脚本（都在 `tool/`）：

```powershell
$env:PYTHONIOENCODING='utf-8'
# ① 读 MSAA 树，默认先量 Notepad 作对照
python tool/read_msaa_tree.py personal_planner.exe 40
# ② 看窗口层级，并**对每个窗口**（含 FLUTTERVIEW 子窗口）各取一次 MSAA 根
python tool/probe_window_tree.py personal_planner.exe
```

`②` 是必要的：只问顶层窗口会把"顶层看不到"误读成"整个应用没有语义节点"。
实测输出见 §3。

**依赖**：`comtypes` 装在 `G:\best-planing\.appdata\pylibs`（工作区内，未动系统环境）。
脚本里把该路径插进 `sys.path`，因此直接跑即可。

## 2. 为什么这条路走了很久（写下来免得重走）

| 尝试 | 结果 |
| --- | --- |
| PowerShell `AccessibleChildren` + `object[]` | **静默算错 VARIANT**：连 Notepad 都读成 0 个子节点。**最危险的一版**——把"工具读不出来"报成了"应用没有节点" |
| PowerShell `dynamic` | 缺 `Microsoft.CSharp.RuntimeBinder`（CS0656） |
| `IAccessible` 声明为 `ComImport` 强转 | 拿到普通 `__ComObject`，转不过去 |
| `Type.InvokeMember("accChildCount")` | 读不出 IDispatch 上带可选参数的属性 |
| `AccessibleChildren` + `IntPtr[]` | 能读到 Notepad 有 7 个子节点，但后续遍历走不通 |
| `dotnet` 编译正式读取器 | **本机没有 .NET SDK**（只有运行时） |
| `FindWindowEx` 枚举子窗口 | 探针**死循环**，已终止 |
| `pythoncom.WrapObject` → `PyIDispatch` | 裸 `PyIDispatch` **没有** `accName` 等属性（AttributeError） |
| `win32com.client.DynamicDispatch` | 本机 pywin32 里**不存在**这个属性 |
| **`comtypes` + `IAccessible.accChild(i)`** | ✅ **成功**。类型库从 `oleacc.dll` 生成强类型接口；不用 `AccessibleChildren`（类型库里没有它），改用 `accChild(i)` 逐个取子节点 |

`comtypes` 装在 `G:\best-planing\.appdata\pylibs`（工作区内，未动系统环境）。
## 3. 结论

`tool/probe_window_tree.py` 把窗口层级也问了一遍（2026-10-07 实测）：

```text
顶层 hwnd=3542668 class='FLUTTER_RUNNER_WIN32_WINDOW' text='智能日程'
  MSAA: name='智能日程' role=10 children=1 kids=["[simple name='' role=]"]
  子窗口 hwnd=3543190 class='FLUTTERVIEW' text='FLUTTERVIEW' pid=41640
    MSAA: name='FLUTTERVIEW' role=10 children=0 kids=[]
```

也就是说：

- 顶层窗口只有 **1** 个**无名、无角色**的子元素；
- 那个子元素就是 `FLUTTERVIEW`，而 **`FLUTTERVIEW` 自己报 `children=0`**。

**这与路线图 §1.3 第 9 条登记的现象一致**：安装版对外暴露的不是一组独立控件，
Flutter 侧的语义节点（M2 修好的详情入口名称、筛选项、错误播报）在这一层**看不到**。

**必须标注的两点限度**：

1. 本应用在 MSAA 这一层**只暴露一个无名子元素**，而 `FLUTTERVIEW` 报 0 个子节点。
   这**不足以**单独断定"辅助技术用户什么都读不到"——因为 MSAA 的 `obj`/`simple` 混用在某些
   实现下会让读取器漏读（Notepad 的 7 个子元素同样表现为 `simple` 且名称读不出来）。
2. **没有拿到可信的原版 Flutter 对照**（那类应用在本会话启动后不存活，窗口句柄为 0）。
   因此**不能排除**是本工程或本 Flutter 版本的配置问题。上一轮我拿一个**已被证明会静默算错**
   的探针做过这个对照并据此下结论，**那个结论已撤回**。

**当前能负责地说的是**：在 MSAA 的"窗口 → 子元素 → `FLUTTERVIEW`"这条路径上，
本应用**没有任何带名称或角色的控件节点**；要判定辅助技术实际能读到什么，仍需官方工具。

## 4. 限度

- 读取器能读出**节点数、名称、角色、状态**，但 Notepad 与 Flutter 的子节点都表现为
  **`simple` 子元素**（`accChild(i)` 返回空 → 按子 ID 回问父节点仍拿不到名称与角色）。
  也就是说**再往下一层就读不出来了**：`FLUTTERVIEW` 里面到底有没有语义节点，这个工具
  **回答不了**。
- 因此本轮只能说：**在 MSAA 的"窗口 → 子元素"这一层，本应用只暴露一个无名子元素。**
  这**不足以**断言"辅助技术用户什么也读不到"。
- 要判定辅助技术实际能读到什么，仍然需要 **Accessibility Insights / Inspect**，
  或一个能读出 `simple` 子元素名称的更强读取器。

## 5. 建议的下一步

1. **装 Accessibility Insights for Windows**（或 Windows SDK 的 `inspect.exe`）：
   它是唯一能把 `FLUTTERVIEW` 展开看的工具。对着本应用与一个**原版 Flutter 应用**各看一遍，
   截图存档，两者对照。
2. 判据建议改为**"与原版 Flutter 基线对照（不劣于）"**，而不是字面的"必须有独立节点"——
   理由：若原版 Flutter 应用同样只暴露 `FLUTTERVIEW`，那么字面判据会卡住**任何** Flutter 应用，
   把一个引擎层面的形状问题记到业务里程碑头上。**是否采纳需用户裁决**，因为它改的是验收判据。
3. **M2 里已经做掉的部分不因此作废**：语义标签、键盘可达、对比度、错误播报都有 21 条测试守着，
   基线一旦改善就会生效。

## 6. 会话限制

- `Start-Process` 在本会话**间歇性挂住**（120s／300s 超时，多次实测）；改用
  `Start-Job { Start-Process }` 可以绕开，本轮的前几次测量就是这么做的。
- 但**用 `Start-Process` 启动 `flutter create` 出来的原版应用时它不存活**（进程立刻消失，
  窗口句柄为 0），因此本轮的**原版 Flutter 对照没做成**。这也是为什么 §3 第 1 条要更正。
