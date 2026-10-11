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

// Generic boolean check, used by the flash-behaviour assertions below. Kept
// separate from ExpectAction so those can compare Win32 flags and integers
// without pretending they are tray actions.
void Check(const char* label, bool actual, bool expected) {
  ++checks;
  if (actual == expected) {
    std::printf("ok   %-40s -> %s\n", label, actual ? "true" : "false");
    return;
  }
  ++failures;
  std::printf("FAIL %-40s expected %s, got %s\n", label,
              expected ? "true" : "false", actual ? "true" : "false");
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

  // ---- Flash behaviour when SetForegroundWindow is refused (spec 6.2) -------
  //
  // The spec says the app must not treat a refused foreground request as a
  // failure: the window is already restored and shown, so the remaining step is
  // to draw attention with a flash. Three properties of that flash are load
  // bearing for the user, and all three are invisible to a widget test because
  // they are Win32 flags:
  //
  //  1. FLASHW_TIMERNOFG -- keep flashing until the window comes to the
  //     foreground. Without it the flash stops after uCount and a user who
  //     stepped away never sees it.
  //  2. FLASHW_ALL -- flash both the caption and the taskbar button, so the
  //     attention cue is visible regardless of which one the user is looking at.
  //  3. A finite uCount and a zero dwTimeout -- the flash must not become a
  //     permanent distraction, which is what dwTimeout != 0 or uCount == 0
  //     (flash until cancelled) would produce.
  {
    // A non-null handle is required: the decision refuses to flash without a
    // window (see the null case below). The handle is never dereferenced here --
    // FlashPlanFor only copies it into the struct.
    HWND const fake_window = reinterpret_cast<HWND>(static_cast<uintptr_t>(1));
    const FlashPlan plan = FlashPlanFor(false, fake_window);
    Check("refused foreground flashes", plan.flash, true);
    Check("flash keeps going (FLASHW_TIMERNOFG)",
          (plan.info.dwFlags & FLASHW_TIMERNOFG) != 0, true);
    Check("flash covers caption and taskbar (FLASHW_ALL)",
          (plan.info.dwFlags & FLASHW_ALL) == FLASHW_ALL, true);
    Check("flash is bounded (uCount > 0)", plan.info.uCount > 0, true);
    Check("flash is not driven by a timeout", plan.info.dwTimeout == 0, true);
    Check("flash info is sized", plan.info.cbSize == sizeof(FLASHWINFO), true);
    Check("flash targets the window it was given", plan.info.hwnd == fake_window,
          true);
  }

  // When the foreground request succeeds there must be no flash: flashing a
  // window the user is already looking at is noise, and it would also hide a
  // genuine regression in the flash decision.
  {
    HWND const fake_window = reinterpret_cast<HWND>(static_cast<uintptr_t>(1));
    const FlashPlan plan = FlashPlanFor(true, fake_window);
    Check("granted foreground does not flash", plan.flash, false);
  }

  // A null window cannot be flashed at all; the decision must say so instead of
  // handing a null handle to the shell.
  {
    const FlashPlan plan = FlashPlanFor(false, nullptr);
    Check("no window means no flash", plan.flash, false);
  }

  std::printf("\n%d checks, %d failures\n", checks, failures);
  return failures == 0 ? 0 : 1;
}
