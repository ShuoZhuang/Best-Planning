// Windows 包部署错误 → 稳定错误码 → 用户可读原因（规格 §11.5、§10.4）。
//
// 界面**只**显示这里的原因与处理建议，不显示裸 HRESULT 或异常文本；
// HRESULT 只写进日志。
#pragma once

#include <windows.h>

namespace planner::native {

struct DeploymentFailure {
  const wchar_t* code;    // 稳定错误编号（写日志与"复制信息"用）
  const wchar_t* reason;  // 用户能理解的原因
  const wchar_t* action;  // 推荐处理方式
  int exit_code;          // 规格 §10.4
};

DeploymentFailure DescribeDeploymentFailure(HRESULT error);

}  // namespace planner::native
