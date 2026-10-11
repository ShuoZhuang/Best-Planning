// Native unit test for the notification-area message table (1.8.0, task 4).
//
// Deliberately a plain console executable: it links nothing from Flutter and no
// engine, so it runs in a few milliseconds and cannot fail for a reason that has
// nothing to do with the mapping. The mapping is the whole subject here: the
// defect being fixed was "left click does nothing on some shells", which is a
// missing `case`, and a missing `case` is exactly what a table test catches.
//
// This file is kept pure ASCII on purpose. MSVC reads it using the system code
// page (936 on this machine) and the project builds with C4819 as an error, so a
// stray em dash turns a green test into a compile failure. `tray_icon.cpp` and
// `main.cpp` carry the same note for their UI strings.
#include <cstdio>

#include "tray_icon_message_policy.h"

namespace {

int failures = 0;
int checks = 0;

const char* Name(TrayAction action) {
  switch (action) {
    case TrayAction::kNone:
      return "kNone";
    case TrayAction::kOpen:
      return "kOpen";
    case TrayAction::kMenu:
      return "kMenu";
  }
  return "?";
}

void ExpectAction(const char* label, UINT message, TrayAction expected) {
  ++checks;
  const TrayAction actual = ActionForTrayMessage(message);
  if (actual == expected) {
    std::printf("ok   %-28s -> %s\n", label, Name(actual));
    return;
  }
  ++failures;
  std::printf("FAIL %-28s expected %s, got %s\n", label, Name(expected),
              Name(actual));
}

}  // namespace

int main() {
  // Every message that must bring the window back. WM_LBUTTONUP is the one the
  // defect was about; the other three were already handled and must stay handled.
  ExpectAction("WM_LBUTTONUP", WM_LBUTTONUP, TrayAction::kOpen);
  ExpectAction("WM_LBUTTONDBLCLK", WM_LBUTTONDBLCLK, TrayAction::kOpen);
  ExpectAction("NIN_SELECT", NIN_SELECT, TrayAction::kOpen);
  ExpectAction("NIN_KEYSELECT", NIN_KEYSELECT, TrayAction::kOpen);

  // Right click stays menu-only: it must never open the window (that would make
  // the context menu impossible to reach).
  ExpectAction("WM_RBUTTONUP", WM_RBUTTONUP, TrayAction::kMenu);
  ExpectAction("WM_CONTEXTMENU", WM_CONTEXTMENU, TrayAction::kMenu);

  // Everything else is somebody else's message. Returning kNone for these is what
  // keeps the tray from swallowing ordinary window traffic.
  ExpectAction("WM_LBUTTONDOWN", WM_LBUTTONDOWN, TrayAction::kNone);
  ExpectAction("WM_MOUSEMOVE", WM_MOUSEMOVE, TrayAction::kNone);
  ExpectAction("WM_MBUTTONUP", WM_MBUTTONUP, TrayAction::kNone);
  ExpectAction("WM_CLOSE", WM_CLOSE, TrayAction::kNone);
  ExpectAction("WM_NULL", WM_NULL, TrayAction::kNone);
  ExpectAction("0", 0, TrayAction::kNone);

  // A double click delivers two independent kOpen actions. The policy layer must
  // not encode any "toggle" notion: the idempotence lives in
  // TrayIcon::RestoreMainWindow, and this asserts the table never turns the
  // second click into something else.
  ExpectAction("WM_LBUTTONDBLCLK #2", WM_LBUTTONDBLCLK, TrayAction::kOpen);

  std::printf("\n%d checks, %d failures\n", checks, failures);
  return failures == 0 ? 0 : 1;
}
