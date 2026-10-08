// URL 打开端口（路线图 §3.6 / §11 Task 11）。
//
// **为什么要单独一个文件而不是在页面里直接用 `url_launcher`**：从"点一个按钮"到"系统浏览器打开
// 一个地址"是平台行为，测试里不能真的弹出浏览器。抽出端口之后：
//   · 页面只依赖一个 `Future<bool> Function(Uri)`，Widget 测试可以断言**它被调用时拿到的是哪个
//     地址**——这正是"只允许打开已验证的仓库 Release 地址"那条规则的验证点；
//   · `url_launcher` 只出现在这一个文件里，联网/外链边界因此仍然数得清。
//
// **它只打开浏览器**：不在应用内下载、不执行安装包（§3.6 明文禁止静默下载与静默安装）。
import 'package:url_launcher/url_launcher.dart';

/// 打开一个外部地址；返回是否成功。
typedef UpdateUrlOpener = Future<bool> Function(Uri url);

/// 真实实现：交给系统默认浏览器。
///
/// `LaunchMode.externalApplication` 是刻意的：**不用 `inAppBrowser`**，因为更新页上要打开的
/// 是一个用户需要自己判断、自己下载的页面，把它塞进应用内的 WebView 只会让人以为"应用在学习
/// 我的下载行为"。
Future<bool> openUpdateUrlExternally(Uri url) =>
    launchUrl(url, mode: LaunchMode.externalApplication);
