#ifndef RUNNER_TRAY_ICON_H_
#define RUNNER_TRAY_ICON_H_

#include <windows.h>

#include <functional>
#include <string>

// Notification-area (system tray) icon for the running app.
//
// Why this lives in the runner instead of a plugin: this workspace cannot create the
// plugin symlinks that `flutter pub get` wants (see the SDD ledger's environment note),
// so adding a tray plugin would mean hand-editing the generated plugin registrant and
// hand-creating a link. The tray needs only a few shell32 calls, so owning them here is
// smaller and sturdier than that detour.
class TrayIcon {
 public:
  // Callback message the shell posts to the window. A registered message is used rather
  // than `WM_APP + n` so it cannot collide with a plugin's own private message.
  static UINT CallbackMessage();

  // `on_quit` runs when the user picks the quit item from the context menu.
  TrayIcon(HWND window, HICON icon, const std::wstring& tooltip,
           std::function<void()> on_quit);
  ~TrayIcon();

  TrayIcon(const TrayIcon&) = delete;
  TrayIcon& operator=(const TrayIcon&) = delete;

  // Adds the icon. Idempotent; returns whether the icon is present afterwards.
  bool Add();
  // Removes the icon. Idempotent. A forced process kill leaves the icon to the shell,
  // which drops it once the window it belongs to is gone.
  void Remove();

  // Handles a callback message for this icon. Returns true when it was ours.
  bool HandleMessage(WPARAM wparam, LPARAM lparam);

 private:
  void ShowContextMenu();
  void RestoreMainWindow();

  HWND window_;
  HICON icon_;
  std::wstring tooltip_;
  std::function<void()> on_quit_;
  bool added_ = false;
  NOTIFYICONDATAW data_ = {};
};

#endif  // RUNNER_TRAY_ICON_H_
