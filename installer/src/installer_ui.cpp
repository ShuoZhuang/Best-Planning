#include "installer_ui.h"

#include <commctrl.h>

#include <thread>

#include "installer_ui_ids.h"

#pragma comment(lib, "comctl32.lib")

namespace planner::installer {

SecondaryClick ClassifySecondaryClick(UiPage page) {
  // 只有"进度页"的次级按钮是取消；完成页同样显示 100% 进度条，但它的次级按钮是
  // "完成"，必须解析（否则 worker 永远等不到决定，用户只能关窗口并得到退出码 99）。
  return page == UiPage::Progress ? SecondaryClick::RequestCancel
                                  : SecondaryClick::Resolve;
}

namespace {

constexpr UINT kModelMessage = WM_APP + 1;
constexpr UINT kProgressMessage = WM_APP + 2;
constexpr UINT kWorkerDoneMessage = WM_APP + 3;

struct ProgressUpdate {
  int percent = 0;
  bool indeterminate = false;
  std::wstring status;
};

void CenterOnWorkArea(HWND dialog) {
  RECT window{};
  if (!GetWindowRect(dialog, &window)) return;
  HMONITOR monitor = MonitorFromWindow(dialog, MONITOR_DEFAULTTONEAREST);
  MONITORINFO info{};
  info.cbSize = sizeof(info);
  if (!GetMonitorInfoW(monitor, &info)) return;
  const int width = window.right - window.left;
  const int height = window.bottom - window.top;
  const int x = info.rcWork.left +
                ((info.rcWork.right - info.rcWork.left) - width) / 2;
  const int y = info.rcWork.top +
                ((info.rcWork.bottom - info.rcWork.top) - height) / 2;
  SetWindowPos(dialog, nullptr, x, y, 0, 0, SWP_NOSIZE | SWP_NOZORDER);
}

void SetControlText(HWND dialog, int id, const std::wstring& text) {
  SetDlgItemTextW(dialog, id, text.c_str());
  ShowWindow(GetDlgItem(dialog, id), text.empty() ? SW_HIDE : SW_SHOW);
}

void ConfigureButton(HWND dialog, int id, const std::wstring& text,
                     bool enabled) {
  HWND button = GetDlgItem(dialog, id);
  if (button == nullptr) return;
  SetWindowTextW(button, text.c_str());
  ShowWindow(button, text.empty() ? SW_HIDE : SW_SHOW);
  EnableWindow(button, enabled ? TRUE : FALSE);
}

}  // namespace

InstallerUi::InstallerUi() = default;
InstallerUi::~InstallerUi() = default;

int InstallerUi::Run(HINSTANCE instance, std::function<int()> worker) {
  worker_ = std::move(worker);
  INITCOMMONCONTROLSEX controls{};
  controls.dwSize = sizeof(controls);
  controls.dwICC = ICC_PROGRESS_CLASS;
  InitCommonControlsEx(&controls);

  dialog_ = CreateDialogParamW(instance, MAKEINTRESOURCEW(IDD_INSTALLER),
                               nullptr, DialogProc,
                               reinterpret_cast<LPARAM>(this));
  if (dialog_ == nullptr) return 99;
  ShowWindow(dialog_, SW_SHOWNORMAL);
  UpdateWindow(dialog_);

  std::thread thread([this] {
    int code = 99;
    try {
      code = worker_ ? worker_() : 99;
    } catch (...) {
      code = 99;
    }
    // 先落结果再通知界面：用户可能已经关掉窗口（dialog_ 为空），此时不能把工作线程
    // 的真实退出码丢掉——否则"安装成功"会被报成 99（INSTALLER_INTERNAL_ERROR）。
    worker_exit_code_.store(code);
    if (dialog_ != nullptr) {
      PostMessageW(dialog_, kWorkerDoneMessage, static_cast<WPARAM>(code), 0);
    }
  });

  MSG message{};
  while (GetMessageW(&message, nullptr, 0, 0) > 0) {
    if (dialog_ != nullptr && IsDialogMessageW(dialog_, &message)) continue;
    TranslateMessage(&message);
    DispatchMessageW(&message);
  }
  thread.join();
  return worker_exit_code_.load();
}

void InstallerUi::Present(const UiModel& model) {
  if (headless_) return;
  auto* copy = new UiModel(model);
  if (dialog_ == nullptr ||
      !PostMessageW(dialog_, kModelMessage, 0,
                    reinterpret_cast<LPARAM>(copy))) {
    delete copy;
  }
}

int InstallerUi::RunHeadless(std::function<int()> worker,
                             bool launch_after_install,
                             bool reinstall_same_version) {
  headless_ = true;
  headless_launch_ = launch_after_install;
  headless_reinstall_ = reinstall_same_version;
  launch_requested_ = launch_after_install;
  worker_ = std::move(worker);
  try {
    return worker_ ? worker_() : 99;
  } catch (...) {
    return 99;
  }
}

UiDecision InstallerUi::Ask(const UiModel& model) {
  if (headless_) {
    // 验收模式：安装页自动确认；完成页默认"完成"，指定 --launch 时才尝试启动。
    launch_requested_ = headless_launch_;
    if (model.page == UiPage::Completed) {
      return headless_launch_ ? UiDecision::Primary : UiDecision::Secondary;
    }
    if (model.page == UiPage::Failed) return UiDecision::Secondary;
    if (model.page == UiPage::SameVersion && headless_reinstall_) {
      return UiDecision::Secondary;
    }
    return UiDecision::Primary;
  }
  {
    std::lock_guard<std::mutex> lock(mutex_);
    decided_ = false;
    pending_decision_ = UiDecision::None;
  }
  Present(model);
  std::unique_lock<std::mutex> lock(mutex_);
  decision_ready_.wait(lock, [this] { return decided_ || closing_; });
  if (!decided_) return UiDecision::None;
  return pending_decision_;
}

void InstallerUi::SetProgress(int percent, const std::wstring& status,
                              bool indeterminate) {
  if (headless_) return;
  auto* update = new ProgressUpdate{percent, indeterminate, status};
  if (dialog_ == nullptr ||
      !PostMessageW(dialog_, kProgressMessage, 0,
                    reinterpret_cast<LPARAM>(update))) {
    delete update;
  }
}

void InstallerUi::Resolve(UiDecision decision) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    pending_decision_ = decision;
    decided_ = true;
  }
  decision_ready_.notify_all();
}

void InstallerUi::EndSession() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    closing_ = true;
    cancel_requested_ = true;
  }
  decision_ready_.notify_all();
  HWND dialog = dialog_;
  dialog_ = nullptr;
  if (dialog != nullptr) DestroyWindow(dialog);
}

void InstallerUi::ApplyModel(const UiModel& model) {
  if (dialog_ == nullptr) return;
  page_ = model.page;
  SetControlText(dialog_, IDC_HEADLINE, model.headline);
  SetControlText(dialog_, IDC_SUBTITLE, model.subtitle);
  SetControlText(dialog_, IDC_MODE, model.mode);
  SetControlText(dialog_, IDC_DETAILS, model.details);
  SetControlText(dialog_, IDC_STATUS, model.status_line);
  SetControlText(dialog_, IDC_CODE, model.code_line);
  ConfigureButton(dialog_, IDC_PRIMARY, model.primary_button,
                  model.primary_enabled);
  ConfigureButton(dialog_, IDC_SECONDARY, model.secondary_button,
                  model.secondary_enabled);
  ConfigureButton(dialog_, IDC_TERTIARY, model.tertiary_button,
                  model.tertiary_enabled);

  HWND check = GetDlgItem(dialog_, IDC_CHECK_LAUNCH);
  ShowWindow(check, model.show_launch_checkbox ? SW_SHOW : SW_HIDE);
  CheckDlgButton(dialog_, IDC_CHECK_LAUNCH,
                 model.launch_checked ? BST_CHECKED : BST_UNCHECKED);
  launch_requested_ = model.launch_checked;

  HWND progress = GetDlgItem(dialog_, IDC_PROGRESS);
  ShowWindow(progress, model.show_progress ? SW_SHOW : SW_HIDE);
  if (model.show_progress) {
    if (model.indeterminate_progress) {
      SendMessageW(progress, PBM_SETMARQUEE, TRUE, 40);
    } else {
      SendMessageW(progress, PBM_SETMARQUEE, FALSE, 0);
      SendMessageW(progress, PBM_SETPOS,
                   static_cast<WPARAM>(model.progress_percent), 0);
    }
  }

  allow_close_model_ = model.allow_close;

  // 关闭按钮只在允许取消的阶段可用（规格 §9.8）。
  HMENU menu = GetSystemMenu(dialog_, FALSE);
  if (menu != nullptr) {
    EnableMenuItem(menu, SC_CLOSE,
                   model.allow_close ? MF_BYCOMMAND | MF_ENABLED
                                     : MF_BYCOMMAND | MF_GRAYED);
  }
}

INT_PTR InstallerUi::HandleMessage(HWND dialog, UINT message, WPARAM wparam,
                                   LPARAM lparam) {
  switch (message) {
    case WM_INITDIALOG: {
      SetWindowLongPtrW(dialog, DWLP_USER, lparam);
      CenterOnWorkArea(dialog);
      SendDlgItemMessageW(dialog, IDC_PROGRESS, PBM_SETRANGE32, 0, 100);
      HFONT font = reinterpret_cast<HFONT>(
          SendMessageW(dialog, WM_GETFONT, 0, 0));
      LOGFONTW description{};
      if (font != nullptr && GetObjectW(font, sizeof(description), &description)) {
        description.lfWeight = FW_SEMIBOLD;
        description.lfHeight = description.lfHeight * 12 / 10;
        HFONT headline = CreateFontIndirectW(&description);
        if (headline != nullptr) {
          SendDlgItemMessageW(dialog, IDC_HEADLINE, WM_SETFONT,
                              reinterpret_cast<WPARAM>(headline), TRUE);
        }
      }
      for (int id : {IDC_HEADLINE, IDC_SUBTITLE, IDC_MODE, IDC_DETAILS,
                     IDC_STATUS, IDC_CODE, IDC_PRIMARY, IDC_SECONDARY,
                     IDC_TERTIARY, IDC_CHECK_LAUNCH, IDC_PROGRESS}) {
        ShowWindow(GetDlgItem(dialog, id), SW_HIDE);
      }
      return TRUE;
    }
    case WM_COMMAND: {
      const int id = LOWORD(wparam);
      if (HIWORD(wparam) != BN_CLICKED) return FALSE;
      if (id == IDC_PRIMARY) {
        const bool checked = IsDlgButtonChecked(dialog, IDC_CHECK_LAUNCH) ==
                             BST_CHECKED;
        if (IsWindowVisible(GetDlgItem(dialog, IDC_CHECK_LAUNCH))) {
          launch_requested_ = checked;
        }
        Resolve(UiDecision::Primary);
        return TRUE;
      }
      if (id == IDC_SECONDARY) {
        // 只有进度页上的"取消"才登记请求；完成页/失败页上的次级按钮必须解析，
        // 否则工作线程永远等不到决定（2026-10-18 实测：完成页只能关窗口，退出码 99）。
        if (ClassifySecondaryClick(page_) == SecondaryClick::RequestCancel) {
          cancel_requested_ = true;
          EnableWindow(GetDlgItem(dialog, IDC_SECONDARY), FALSE);
          SetDlgItemTextW(dialog, IDC_STATUS, L"正在完成当前步骤，请稍候…");
          return TRUE;
        }
        Resolve(UiDecision::Secondary);
        return TRUE;
      }
      if (id == IDC_TERTIARY) {
        Resolve(UiDecision::Tertiary);
        return TRUE;
      }
      return FALSE;
    }
    case WM_CLOSE: {
      if (!allow_close_model_) return TRUE;
      EndSession();
      return TRUE;
    }
    case kModelMessage: {
      auto* model = reinterpret_cast<UiModel*>(lparam);
      if (model != nullptr) {
        ApplyModel(*model);
        delete model;
      }
      return TRUE;
    }
    case kProgressMessage: {
      auto* update = reinterpret_cast<ProgressUpdate*>(lparam);
      if (update != nullptr) {
        HWND progress = GetDlgItem(dialog, IDC_PROGRESS);
        if (update->indeterminate) {
          SendMessageW(progress, PBM_SETMARQUEE, TRUE, 40);
        } else {
          SendMessageW(progress, PBM_SETMARQUEE, FALSE, 0);
          SendMessageW(progress, PBM_SETPOS,
                       static_cast<WPARAM>(update->percent), 0);
        }
        SetDlgItemTextW(dialog, IDC_STATUS, update->status.c_str());
        delete update;
      }
      return TRUE;
    }
    case kWorkerDoneMessage: {
      worker_result_ = static_cast<int>(wparam);
      EndSession();
      return TRUE;
    }
    case WM_DESTROY: {
      PostQuitMessage(0);
      return TRUE;
    }
    default:
      return FALSE;
  }
}

INT_PTR CALLBACK InstallerUi::DialogProc(HWND dialog, UINT message,
                                         WPARAM wparam, LPARAM lparam) {
  InstallerUi* ui = reinterpret_cast<InstallerUi*>(
      GetWindowLongPtrW(dialog, DWLP_USER));
  if (ui == nullptr) {
    if (message == WM_INITDIALOG) {
      ui = reinterpret_cast<InstallerUi*>(lparam);
      SetWindowLongPtrW(dialog, DWLP_USER, lparam);
    } else {
      return FALSE;
    }
  }
  return ui->HandleMessage(dialog, message, wparam, lparam);
}

}  // namespace planner::installer
