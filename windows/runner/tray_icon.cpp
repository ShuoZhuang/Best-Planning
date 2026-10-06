#include "tray_icon.h"

#include <shellapi.h>

#include <utility>

namespace {

// Context-menu command ids. They are only ever read back from this menu, so any two
// distinct values work.
constexpr UINT kCommandRestore = 1;
constexpr UINT kCommandQuit = 2;

// The tooltip is capped by the NOTIFYICONDATA field length.
constexpr size_t kTooltipCapacity = 128;

}  // namespace

UINT TrayIcon::CallbackMessage() {
  // Registered once per process; the same string always yields the same value.
  static const UINT message =
      ::RegisterWindowMessageW(L"PersonalPlannerTrayIconMessage");
  return message;
}

TrayIcon::TrayIcon(HWND window, HICON icon, const std::wstring& tooltip,
                   std::function<void()> on_quit)
    : window_(window), icon_(icon), tooltip_(tooltip),
      on_quit_(std::move(on_quit)) {
  data_.cbSize = sizeof(NOTIFYICONDATAW);
  data_.hWnd = window_;
  data_.uID = 1;
  data_.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  data_.uCallbackMessage = CallbackMessage();
  data_.hIcon = icon_;
  if (!tooltip_.empty()) {
    ::wcsncpy_s(data_.szTip, kTooltipCapacity, tooltip_.c_str(), _TRUNCATE);
  }
}

TrayIcon::~TrayIcon() { Remove(); }

bool TrayIcon::Add() {
  if (added_) {
    return true;
  }
  if (window_ == nullptr || icon_ == nullptr) {
    return false;
  }
  added_ = ::Shell_NotifyIconW(NIM_ADD, &data_) != FALSE;
  return added_;
}

void TrayIcon::Remove() {
  if (!added_) {
    return;
  }
  ::Shell_NotifyIconW(NIM_DELETE, &data_);
  added_ = false;
}

bool TrayIcon::HandleMessage(WPARAM wparam, LPARAM lparam) {
  if (wparam != data_.uID) {
    return false;
  }
  switch (static_cast<UINT>(lparam)) {
    case WM_LBUTTONDBLCLK:
    case NIN_SELECT:
      RestoreMainWindow();
      return true;
    case WM_RBUTTONUP:
    case WM_CONTEXTMENU:
      ShowContextMenu();
      return true;
    default:
      return false;
  }
}

void TrayIcon::RestoreMainWindow() {
  if (window_ == nullptr) {
    return;
  }
  // Restore before showing: a window hidden while minimized would otherwise come back
  // minimized, which reads as "the icon did nothing".
  ::ShowWindow(window_, SW_RESTORE);
  ::ShowWindow(window_, SW_SHOW);
  ::SetForegroundWindow(window_);
}

void TrayIcon::ShowContextMenu() {
  HMENU menu = ::CreatePopupMenu();
  if (menu == nullptr) {
    return;
  }
  // Menu labels are written as \u escapes on purpose: MSVC reads this file using the
  // system code page (936 here), and a raw non-ASCII literal both breaks parsing and
  // trips warning C4819, which this project builds with as an error. main.cpp writes the
  // window title the same way.
  ::AppendMenuW(menu, MF_STRING, kCommandRestore,
                L"\u6253\u5F00\u4E3B\u754C\u9762");  // "open main window"
  ::AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  ::AppendMenuW(menu, MF_STRING, kCommandQuit, L"\u9000\u51FA");  // "quit"

  POINT cursor = {};
  ::GetCursorPos(&cursor);
  // The owning window must be foreground, otherwise the menu does not dismiss when the
  // user clicks elsewhere (documented requirement of TrackPopupMenu).
  ::SetForegroundWindow(window_);
  const UINT command = ::TrackPopupMenuEx(
      menu, TPM_RIGHTBUTTON | TPM_RETURNCMD | TPM_NONOTIFY, cursor.x, cursor.y,
      window_, nullptr);
  // Documented follow-up: without this the menu can stay stuck on screen.
  ::PostMessageW(window_, WM_NULL, 0, 0);
  ::DestroyMenu(menu);

  if (command == kCommandRestore) {
    RestoreMainWindow();
  } else if (command == kCommandQuit && on_quit_) {
    on_quit_();
  }
}
