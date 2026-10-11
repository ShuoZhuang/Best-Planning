#include "tray_icon.h"

#include <shellapi.h>

#include <utility>

#include "tray_icon_message_policy.h"

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
                   std::function<void()> on_quit, DWORD cb_size,
                   UINT callback_message)
    : window_(window), icon_(icon), tooltip_(tooltip),
      on_quit_(std::move(on_quit)) {
  data_.cbSize = cb_size == 0 ? sizeof(NOTIFYICONDATAW) : cb_size;
  data_.hWnd = window_;
  data_.uID = 1;
  data_.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  data_.uCallbackMessage =
      callback_message == 0 ? CallbackMessage() : callback_message;
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
  // The message table lives in `tray_icon_message_policy.h` so it can be asserted
  // without the engine (`tray_icon_message_policy_test.cpp`). The defect this fixes:
  // `WM_LBUTTONUP` was absent, so on shells that report a single left click through
  // it the icon did nothing at all. Which of these messages a given shell sends
  // depends on its version, so all four "activate" messages must be accepted.
  //
  // A double click therefore arrives as two independent `kOpen` actions. That is
  // fine and intended: `RestoreMainWindow` is idempotent, so the second one shows an
  // already-visible window instead of hiding it. There is deliberately no toggle.
  switch (ActionForTrayMessage(static_cast<UINT>(lparam))) {
    case TrayAction::kOpen:
      RestoreMainWindow();
      return true;
    case TrayAction::kMenu:
      ShowContextMenu();
      return true;
    case TrayAction::kNone:
      return false;
  }
  return false;
}

void TrayIcon::RestoreMainWindow() {
  if (window_ == nullptr) {
    return;
  }
  // Order matters (design spec section 6.1): restore a minimized window, show a hidden
  // one, and only then ask for the foreground. `SW_RESTORE` also shows the window, but
  // `SW_SHOW` is what makes "hidden but not minimized" (which is how closing to the
  // tray leaves it) actually appear.
  if (::IsIconic(window_)) {
    ::ShowWindow(window_, SW_RESTORE);
  }
  if (!::IsWindowVisible(window_)) {
    ::ShowWindow(window_, SW_SHOW);
  }
  // Always ask, even when the window was already visible: the caller's expectation for
  // "left click on the icon" is that the window comes to the front, and a visible but
  // buried window would otherwise look like the click did nothing.
  //
  // `SetForegroundWindow` can be refused by the Windows foreground rules. The spec is
  // explicit that this must not be reported as a failure (section 6.2): the window has
  // already been restored and shown by the two calls above, so the outer step is to
  // draw the user's attention with a flash rather than to pretend nothing happened.
  if (::SetForegroundWindow(window_) == FALSE) {
    FLASHWINFO flash = {};
    flash.cbSize = sizeof(flash);
    flash.hwnd = window_;
    flash.dwFlags = FLASHW_ALL | FLASHW_TIMERNOFG;
    flash.uCount = 3;
    flash.dwTimeout = 0;
    ::FlashWindowEx(&flash);
  }
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
