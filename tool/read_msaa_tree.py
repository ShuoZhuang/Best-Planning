"""读 Windows MSAA 辅助功能树（路线图 §6「Accessibility Insights 或 Inspect 看到独立控件节点」的测量工具）。

**为什么是 Python + comtypes**：本机没有 Accessibility Insights，也没有 Windows SDK 的
`inspect.exe`。而在 PowerShell 里做这件事连试四版都不行：

1. 直接声明 `AccessibleChildren` 的 `object[]` 参数 → VARIANT 编组**静默算错**，连 Notepad
   都读成 0 个子节点。**这一版最危险**：它把"工具读不出来"报成了"应用没有节点"。
2. `dynamic` → 缺 `Microsoft.CSharp.RuntimeBinder`（CS0656）。
3. `IAccessible` 声明为 `ComImport` 后强转 → 拿到的是普通 `__ComObject`，转不过去。
4. `Type.InvokeMember` → 读不出 IDispatch 上那些**带可选参数**的属性。
   本机也**没有 .NET SDK**（只有运行时），编译正式读取器的路也断了。

`comtypes` 会从 `oleacc.dll` 的类型库生成强类型 `IAccessible`，VARIANT 由它负责，
因此这条路是通的。

**必须带对照**：默认先量 Notepad（已知可访问）。**对照失败则本次结果一律无效。**
这正是这份工具存在的理由。

用法：
    python tool/read_msaa_tree.py [进程名] [最大节点数]
"""

from __future__ import annotations

import ctypes
import ctypes.wintypes as wt
import subprocess
import sys
import time
import uuid

sys.path.insert(0, r"G:\best-planing\.appdata\pylibs")

import comtypes  # noqa: E402
import comtypes.client  # noqa: E402

oleacc = ctypes.WinDLL("oleacc")
user32 = ctypes.WinDLL("user32")

OBJID_CLIENT = 0xFFFFFFFC
IID_IAccessible = "{618736E0-3C3D-11CF-810C-00AA00389B71}"


def _guid_le(guid: str):
    return (ctypes.c_ubyte * 16).from_buffer_copy(uuid.UUID(guid).bytes_le)


oleacc.AccessibleObjectFromWindow.restype = ctypes.c_long
oleacc.AccessibleObjectFromWindow.argtypes = [
    wt.HWND,
    wt.DWORD,
    ctypes.POINTER(ctypes.c_ubyte),
    ctypes.POINTER(ctypes.c_void_p),
]


def accessibility_module():
    """从 oleacc.dll 的类型库生成 IAccessible 等强类型接口。"""
    return comtypes.client.GetModule("oleacc.dll")


def window_pid(hwnd: int) -> int:
    pid = wt.DWORD()
    user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
    return int(pid.value)


def visible_top_windows() -> list[int]:
    """所有可见顶层窗口。用**返回值**收集，不靠闭包改写外部变量。"""
    real: list[int] = []
    proto = ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)

    def _cb(hwnd, _lparam):
        if user32.IsWindowVisible(hwnd):
            real.append(int(hwnd))
        return True

    user32.EnumWindows(proto(_cb), 0)
    return real


def pids_of(image_name: str) -> set[int]:
    out = subprocess.run(
        ["tasklist", "/FI", f"IMAGENAME eq {image_name}", "/FO", "CSV", "/NH"],
        capture_output=True,
        text=True,
    ).stdout
    pids: set[int] = set()
    for line in out.splitlines():
        parts = [p.strip('" ') for p in line.split('","')]
        if len(parts) >= 2 and parts[1].isdigit():
            pids.add(int(parts[1]))
    return pids


def main_window(image_name: str) -> int:
    pids = pids_of(image_name)
    if not pids:
        return 0
    for hwnd in visible_top_windows():
        if window_pid(hwnd) in pids:
            return hwnd
    return 0


def root_accessible(hwnd: int, acc_mod):
    """取窗口的 MSAA 根，返回强类型 IAccessible 指针或 None。"""
    punk = ctypes.c_void_p()
    hr = oleacc.AccessibleObjectFromWindow(
        hwnd, OBJID_CLIENT, _guid_le(IID_IAccessible), ctypes.byref(punk)
    )
    if hr != 0 or not punk:
        print(f"  AccessibleObjectFromWindow 失败 hr=0x{hr & 0xFFFFFFFF:08X}")
        return None
    return ctypes.cast(punk, ctypes.POINTER(acc_mod.IAccessible))


def _text(value) -> str:
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    return str(value)


def name_of(acc, child_id: int = 0) -> str:
    try:
        return _text(acc.accName(child_id))
    except Exception:  # noqa: BLE001
        return ""


def role_of(acc, child_id: int = 0) -> str:
    try:
        return _text(acc.accRole(child_id))
    except Exception:  # noqa: BLE001
        return ""


def state_of(acc, child_id: int = 0) -> str:
    try:
        return _text(acc.accState(child_id))
    except Exception:  # noqa: BLE001
        return ""


def child_count(acc) -> int:
    try:
        return int(acc.accChildCount)
    except Exception:  # noqa: BLE001
        return 0


def children(acc, acc_mod) -> list[tuple[str, object]]:
    """逐个用 `get_accChild` 取子节点。

    **为什么不用 `AccessibleChildren`**：comtypes 从 `oleacc.dll` 类型库只生成了
    `IAccessible` 系列接口，**没有** `AccessibleChildren` 这个自由函数
    （实测 `AttributeError`）。而手写它的 P/Invoke 需要传 VARIANT 数组——那正是让我们
    在 PowerShell 里栽了四版的地方。`get_accChild(i)` 走的是**强类型接口**，
    简单子元素返回 NULL，此时改用 `accName(i)` / `accRole(i)` 回问父节点即可。
    """
    count = child_count(acc)
    if count <= 0:
        return []
    out: list[tuple[str, object]] = []
    for i in range(1, count + 1):
        try:
            child = acc.accChild(i)
        except Exception:  # noqa: BLE001
            child = None
        if child:
            out.append(("obj", ctypes.cast(child, ctypes.POINTER(acc_mod.IAccessible))))
        else:
            out.append(("id", i))
    return out


def walk(acc, acc_mod, depth: int, max_nodes: int, lines: list[str], counter: list[int]):
    if counter[0] >= max_nodes:
        return
    lines.append(
        f"{'  ' * depth}- name={name_of(acc)!r} role={role_of(acc)} "
        f"state={state_of(acc)} children={child_count(acc)}"
    )
    counter[0] += 1

    for kind, value in children(acc, acc_mod):
        if counter[0] >= max_nodes:
            return
        if kind == "obj":
            walk(value, acc_mod, depth + 1, max_nodes, lines, counter)
        else:
            # 简单子元素：用子 ID 回问父节点。
            lines.append(
                f"{'  ' * (depth + 1)}- name={name_of(acc, value)!r} "
                f"role={role_of(acc, value)} (simple id={value})"
            )
            counter[0] += 1


def report(label: str, image_name: str, max_nodes: int, acc_mod) -> int:
    hwnd = main_window(image_name)
    if not hwnd:
        print(f"{label}: 未找到可见窗口（进程未运行？）")
        return 0
    root = root_accessible(hwnd, acc_mod)
    if root is None:
        print(f"{label}: 取根 IAccessible 失败")
        return 0
    lines: list[str] = []
    counter = [0]
    walk(root, acc_mod, 0, max_nodes, lines, counter)
    print(f"=== {label} (hwnd={hwnd}) 节点数={counter[0]} ===")
    print("\n".join(lines))
    return counter[0]


def main() -> int:
    target = sys.argv[1] if len(sys.argv) > 1 else "personal_planner.exe"
    max_nodes = int(sys.argv[2]) if len(sys.argv) > 2 else 60

    acc_mod = accessibility_module()

    notepad = subprocess.Popen(["notepad.exe"])
    try:
        time.sleep(3)
        control = report("对照 Notepad", "notepad.exe", 40, acc_mod)
        if control <= 0:
            print("对照失败：读取器连 Notepad 都读不出节点，本次结果无效。")
            return 3
        print()
        report(f"目标 {target}", target, max_nodes, acc_mod)
    finally:
        notepad.terminate()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
