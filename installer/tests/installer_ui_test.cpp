// 安装器界面的决策测试（计划外的必要修复：完成页按钮与退出码）。
//
// 2026-10-18 真实安装验收发现：完成页显示 100% 进度条，而次级按钮的点击语义是按
// "进度条是否可见"判断的，于是完成页的"完成"被当成"取消"——按钮被禁用、worker 永不
// 返回，用户只能关窗口；关窗口又让 Run() 返回 99（成功却报内部错误）。
//
// 这一条用例把"哪一页的次级按钮只登记取消"钉住，防止再用视觉状态推断语义。
#include <windows.h>

#include "installer_ui.h"
#include "test_support.h"

namespace {

using planner::installer::ClassifySecondaryClick;
using planner::installer::SecondaryClick;
using planner::installer::UiPage;

}  // namespace

TEST(ui_progress_page_secondary_requests_cancel) {
  // 进度页上的次级按钮是"取消"：只登记请求，真正的取消点由状态机决定。
  EXPECT_TRUE(ClassifySecondaryClick(UiPage::Progress) ==
              SecondaryClick::RequestCancel);
}

TEST(ui_completed_page_secondary_resolves) {
  // 完成页也显示进度条，但它的次级按钮是"完成"，必须解析。
  EXPECT_TRUE(ClassifySecondaryClick(UiPage::Completed) ==
              SecondaryClick::Resolve);
}

TEST(ui_other_pages_secondary_resolves) {
  for (UiPage page : {UiPage::Preparing, UiPage::WaitingForAppClose,
                      UiPage::SameVersion, UiPage::Failed}) {
    EXPECT_TRUE(ClassifySecondaryClick(page) == SecondaryClick::Resolve);
  }
}
