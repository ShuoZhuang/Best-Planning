// 内部功能开关（规格 §18）。
//
// 旧更新实现已经删除，因此这个开关不再在"旧/新"之间切换，而是决定**是否装配自更新功能**：
// 关闭时不显示左下角入口、不自动检查/下载、不建立回退基线；签名验证与安装链的代码仍在，
// 但没有任何入口能触发它。
//
// 默认开启：正式发布前必须由发布流水线显式传入
// `--dart-define=BEST_PLANNING_NATIVE_UPDATER=true`，避免某个构建意外关闭更新能力。
const bool nativeUpdaterEnabled = bool.fromEnvironment(
  'BEST_PLANNING_NATIVE_UPDATER',
  defaultValue: true,
);
