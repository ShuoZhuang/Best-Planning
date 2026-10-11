#ifndef RUNNER_TRAY_ICON_MESSAGE_POLICY_H_
#define RUNNER_TRAY_ICON_MESSAGE_POLICY_H_

#include <windows.h>

// What a notification-area callback message means for the app.
//
// This lives in its own header, with no dependency on Flutter, the engine, or
// `TrayIcon` itself, so it can be compiled into a plain console test executable
// (`tray_icon_message_policy_test.cpp`). `tray_icon.cpp` consumes it.
//
// Why the mapping is split out at all: the defect this fixes is that
// `WM_LBUTTONUP` was not in the switch, so on shells that report a left click
// through it the icon did nothing. That is a pure table, and a pure table is
// exactly the thing worth asserting mechanically instead of clicking by hand.
enum class TrayAction {
  kNone,
  // Bring the main window back and put it in front. Must be idempotent: a double
  // click delivers two of these, and the second one must not toggle the window
  // back to hidden.
  kOpen,
  // Show the context menu ("open main window" / "quit").
  kMenu,
};

// Maps one notification-area callback message to the action to take.
//
// `message` is the value the shell posts as the low word of the callback
// `lParam` (NOTIFYICON_VERSION_4), or the full `lParam` for the legacy
// protocol. Both of the message identifiers the v4 protocol wraps in
// `WM_USER`-range space are integers, so no branching on protocol is needed.
inline TrayAction ActionForTrayMessage(UINT message) {
  switch (message) {
    // A single left click. `WM_LBUTTONUP` is the message that actually varies
    // between shell configurations; `NIN_SELECT` and `NIN_KEYSELECT` are the
    // documented v4 equivalents for mouse and keyboard activation.
    case WM_LBUTTONUP:
    case WM_LBUTTONDBLCLK:
    case NIN_SELECT:
    case NIN_KEYSELECT:
      return TrayAction::kOpen;
    // Right click opens the menu, and never touches window visibility.
    case WM_RBUTTONUP:
    case WM_CONTEXTMENU:
      return TrayAction::kMenu;
    default:
      return TrayAction::kNone;
  }
}

#endif  // RUNNER_TRAY_ICON_MESSAGE_POLICY_H_
