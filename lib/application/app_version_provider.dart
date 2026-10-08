// 运行时版本的唯一来源（路线图 §3.6 最后一条 / §11 Task 10）。
//
// **为什么要换掉那个常量**：`lib/app/backup_assembly.dart` 里的 `appVersion` 是一个手写常量，
// 由 `test/app/version_consistency_test.dart` 守着与 `pubspec.yaml` 一致。它作为**备份清单里
// 的一个记录**是诚实的（清单本来就由构建时的代码写），但作为**更新判断的依据**不成立：
// 用户装的是哪个构建由安装包决定，而不是由源码里抄的一行决定。一旦这行漂移（改版本时漏改、
// 或者拿到的是别人转发的构建产物），程序就会拿一个错误的数字去和 GitHub 上的 tag 比大小，
// 而表现是"明明有新版本却一直说已是最新"——**用户完全看不出原因**。
import 'package:package_info_plus/package_info_plus.dart';
import 'package:personal_planner/domain/models/app_update.dart';

/// 当前**安装**版本的读取端口。
///
/// 读不出来时返回 `null` 而不是抛异常：没有版本号只该让界面少显示一行，不该让更新页打不开，
/// 也不该让程序起不来。
abstract interface class AppVersionProvider {
  Future<AppVersion?> currentVersion();
}

/// 从安装包元数据读版本。
///
/// **`package_info_plus` 的 `version` 只给三段**（`1.6.2`），构建号在 `buildNumber` 里
/// （`37`），因此这里把两者拼成 `1.6.2+37` 再解析——否则"当前版本"与备份清单里记的那个号
/// 会一个带 `+37` 一个不带，用户看到两个不一样的版本号。
final class PackageInfoAppVersionProvider implements AppVersionProvider {
  const PackageInfoAppVersionProvider();

  @override
  Future<AppVersion?> currentVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final build = info.buildNumber;
      return AppVersion.parse(
        build.isEmpty ? info.version : '${info.version}+$build',
      );
    } on Object {
      // 平台通道不可用（某些测试环境、或插件未装配）时返回 `null`：
      // 更新服务据此按"未知版本"处理——**宁可多提醒一次，也不要永远说已是最新**。
      return null;
    }
  }
}

/// 固定版本，供测试与"已知版本"的装配点使用。
final class FixedAppVersionProvider implements AppVersionProvider {
  const FixedAppVersionProvider(this.version);

  final AppVersion version;

  @override
  Future<AppVersion?> currentVersion() async => version;
}
