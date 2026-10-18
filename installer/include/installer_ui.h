// 安装器界面（规格 §11）。
//
// 界面只展示状态与可理解的处理建议：不显示 HRESULT、异常文本或调用栈，
// 也不允许绕过控制器直接调用证书或部署接口。
#pragma once

#include <windows.h>

#include <atomic>
#include <condition_variable>
#include <functional>
#include <mutex>
#include <string>

#include "installer_errors.h"

namespace planner::installer {

enum class UiPage {
  Preparing,
  WaitingForAppClose,
  SameVersion,
  Progress,
  Completed,
  Failed,
};

enum class UiDecision {
  None = 0,
  Primary = 1,
  Secondary = 2,
  Tertiary = 3,
};

// 次级按钮被点击时的语义（纯函数，便于单测）。
//
// 只有**进度页**上的次级按钮是"取消"：它只登记取消请求，真正的取消点由状态机决定，
// 因此不解析界面等待。其余页面（同版本页、完成页、失败页、准备页）上的次级按钮都是
// 一个确定的答复，必须解析，否则工作线程会永远等下去。
//
// 2026-10-18 实测缺陷：完成页也显示 100% 进度条，早先的实现用"进度条是否可见"判断，
// 于是完成页的"完成"被当成"取消"、按钮被禁用、worker 永不返回，用户只能关窗口，
// 而关窗口又把退出码变成 99（成功却报内部错误）。
enum class SecondaryClick {
  RequestCancel,
  Resolve,
};

SecondaryClick ClassifySecondaryClick(UiPage page);

struct UiModel {
  UiPage page = UiPage::Preparing;
  std::wstring headline;
  std::wstring subtitle;
  std::wstring mode;
  std::wstring details;
  std::wstring status_line;
  std::wstring code_line;
  std::wstring primary_button;
  std::wstring secondary_button;
  std::wstring tertiary_button;
  bool show_launch_checkbox = false;
  bool launch_checked = true;
  bool primary_enabled = true;
  bool secondary_enabled = true;
  bool tertiary_enabled = true;
  bool show_progress = false;
  bool indeterminate_progress = false;
  int progress_percent = 0;
  bool allow_close = false;
};

class InstallerUi {
 public:
  InstallerUi();
  ~InstallerUi();

  InstallerUi(const InstallerUi&) = delete;
  InstallerUi& operator=(const InstallerUi&) = delete;

  // UI 线程：创建窗口、启动工作线程、进入消息循环；返回工作线程的退出码。
  int Run(HINSTANCE instance, std::function<int()> worker);

  // 验收/CI 用：不创建窗口，页面自动确认（安装流程本身完全不变）。
  int RunHeadless(std::function<int()> worker, bool launch_after_install = false,
                   bool reinstall_same_version = false);
  bool headless() const { return headless_; }

  // 工作线程：更新整页模型，并（可选）阻塞等待用户决定。
  void Present(const UiModel& model);
  UiDecision Ask(const UiModel& model);
  void SetProgress(int percent, const std::wstring& status, bool indeterminate);

  bool LaunchRequested() const { return launch_requested_.load(); }
  bool CancelRequested() const { return cancel_requested_.load(); }

 private:
  static INT_PTR CALLBACK DialogProc(HWND dialog, UINT message, WPARAM wparam,
                                     LPARAM lparam);
  INT_PTR HandleMessage(HWND dialog, UINT message, WPARAM wparam, LPARAM lparam);
  void ApplyModel(const UiModel& model);
  void Resolve(UiDecision decision);
  void EndSession();

  std::atomic<HWND> dialog_{nullptr};
  std::function<int()> worker_;
  std::atomic<bool> launch_requested_{true};
  std::atomic<bool> cancel_requested_{false};

  std::mutex mutex_;
  std::condition_variable decision_ready_;
  UiDecision pending_decision_ = UiDecision::None;
  bool decided_ = false;
  bool closing_ = false;
  bool headless_ = false;
  bool headless_launch_ = false;
  bool headless_reinstall_ = false;

  int worker_result_ = 99;
  bool allow_close_model_ = false;
  UiPage page_ = UiPage::Preparing;

  // 工作线程写、界面线程在 join 之后读：用原子量避免"关闭窗口时吞掉真实退出码"。
  std::atomic<int> worker_exit_code_{99};
};

}  // namespace planner::installer
