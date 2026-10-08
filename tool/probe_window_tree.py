"""查一个进程的窗口层级：主窗口 → 子窗口（含 `FLUTTERVIEW`），并对每个窗口取 MSAA 根。

**为什么单独做这一步**：`tool/read_msaa_tree.py` 从**顶层窗口**取 MSAA 根，只看到一个无名子元素。
Flutter 的语义树可能挂在**子窗口**（`SetChildContent` 创建的那个 `FLUTTERVIEW`）上，
因此必须把子窗口也各自问一遍，否则"顶层看不到"会被误读成"整个应用没有语义节点"。

用法：
    python tool/probe_window_tree.py [进程名]
"""

from __future__ import annotations

import ctypes
import ctypes.wintypes as wt
import subprocess
import sys
import time
import uuid

sys.path.insert(0, r"G:\best-planing\.appdata\pylibs")

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


def class_name(hwnd: int) -> str:
    buf = ctypes.create_unicode_buffer(256)
    user32.GetClassNameW(hwnd, buf, 256)
    return buf.value


def window_text(hwnd: int) -> str:
    length = user32.GetWindowTextLengthW(hwnd)
    buf = ctypes.create_unicode_buffer(length + 1)
    user32.GetWindowTextW(hwnd, buf, length + 1)
    return buf.value


def child_windows(parent: int) -> list[int]:
    """直接子窗口。**用返回值收集**，不靠闭包改写外部变量（闭包版曾导致 hwnd 恒为 0）。"""
    result: list[int] = []
    proto = ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)

    def _cb(hwnd, _lparam):
        result.append(int(hwnd))
        return True

    user32.EnumChildWindows(parent, proto(_cb), 0)
    return result


def pid_of(hwnd: int) -> int:
    pid = wt.DWORD()
    user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
    return int(pid.value)


def top_windows_for(image_name: str) -> list[int]:
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
    if not pids:
        return []
    found: list[int] = []
    proto = ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)

    def _cb(hwnd, _lparam):
        if pid_of(hwnd) in pids and user32.IsWindowVisible(hwnd):
            found.append(int(hwnd))
        return True

    user32.EnumWindows(proto(_cb), 0)
    return found


def msaa_summary(hwnd: int, acc_mod):
    punk = ctypes.c_void_p()
    hr = oleacc.AccessibleObjectFromWindow(
        hwnd, OBJID_CLIENT, _guid_le(IID_IAccessible), ctypes.byref(punk)
    )
    if hr != 0 or not punk:
        return f"MSAA: hr=0x{hr & 0xFFFFFFFF:08X}"
    acc = ctypes.cast(punk, ctypes.POINTER(acc_mod.IAccessible))
    try:
        count = int(acc.accChildCount)
    except Exception:  # noqa: BLE001
        count = -1
    try:
        name = acc.accName(0)
    except Exception:  # noqa: BLE001
        name = ""
    try:
        role = acc.accRole(0)
    except Exception:  # noqa: BLE001
        role = ""
    # 逐个取子节点的名称／角色，看这一层到底有没有可读控件
    kids = []
    for i in range(1, max(count, 0) + 1):
        try:
            child = acc.accChild(i)
        except Exception:  # noqa: BLE001
            child = None
        if child:
            c = ctypes.cast(child, ctypes.POINTER(acc_mod.IAccessible))
            try:
                cname = c.accName(0)
            except Exception:  # noqa: BLE001
                cname = ""
            try:
                crole = c.accRole(0)
            except Exception:  # noqa: BLE001
                crole = ""
            try:
                ccount = int(c.accChildCount)
            except Exception:  # noqa: BLE001
                ccount = -1
            kids.append(f"[obj name={str(cname)!r} role={crole} children={ccount}]")
        else:
            try:
                sname = acc.accName(i)
            except Exception:  # noqa: BLE001
                sname = ""
            try:
                srole = acc.accRole(i)
            except Exception:  # noqa: BLE001
                srole = ""
            kids.append(f"[simple name={str(sname)!r} role={srole}]")
    return f"MSAA: name={str(name)!r} role={role} children={count} kids={kids}"


def main() -> int:
    image = sys.argv[1] if len(sys.argv) > 1 else "personal_planner.exe"
    acc_mod = comtypes.client.GetModule("oleacc.dll")
    time.sleep(1)

    tops = top_windows_for(image)
    if not tops:
        print(f"{image}: 没有可见顶层窗口")
        return 2
    for top in tops:
        print(f"顶层 hwnd={top} class={class_name(top)!r} text={window_text(top)!r}")
        print(f"  {msaa_summary(top, acc_mod)}")
        for child in child_windows(top):
            print(
                f"  子窗口 hwnd={child} class={class_name(child)!r} "
                f"text={window_text(child)!r} pid={pid_of(child)}"
            )
            print(f"    {msaa_summary(child, acc_mod)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
