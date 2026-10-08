// 更新设置页（路线图 §3.6 / §5 / §7.3 / §11 Task 11）。
//
// 这一页有一个不寻常的地方：**它什么都不做，只显示和转发**。检查的判定在
// `UpdateService`（`lib/application/update_service.dart`），网络在
// `GithubReleaseClient`，调度在 `UpdateCheckScheduler`。页面只负责把"现在的状态"讲清楚。
// 这样切分是因为本仓库已经有过教训：把数据规则塞进页面（`analytics_page.dart` 一千二百多行）
// 会让那些规则只能用 Widget 测试验证，而它们本来是纯函数。
//
// 三件必须做对的事：
//   ① **六种状态各自长得不一样**，尤其"自动失败"与"手动失败"——前者非打扰，后者必须说清原因；
//   ② **失败文案绝不带堆栈或本地路径**：原因来自 `UpdateFailureReason` 这个枚举，页面因此
//      **没有能力**泄漏别的东西（`backup_page.dart` 已经因为显示原始异常踩过一次）；
//   ③ **"查看下载"只打开已验证的仓库 Release 地址**：验证发生在这一页，`openUrl` 端口拿到的
//      一定是 `https://github.com/ShuoZhuang/Best-Planning/releases/...`。
import 'package:flutter/material.dart';
import 'package:personal_planner/application/update_service.dart';
import 'package:personal_planner/design/planner_theme.dart';
import 'package:personal_planner/domain/models/app_update.dart';
import 'package:personal_planner/platform/update/github_release_client.dart';
import 'package:personal_planner/platform/update/url_launcher_adapter.dart';

/// 这一次检查是**谁**发起的。
///
/// 失败时这两种要给完全不同的表现（§3.6）：自动检查是后台行为，失败不该打扰用户；手动检查是
/// 用户刚点了按钮，什么都不说等于按钮坏了。因此"是哪种"必须一路传到界面，而不是由界面猜
/// （界面猜不出来，它只看到"失败了"）。
enum CheckTrigger { automatic, manual }

/// 页面要显示的六种状态（§11 Task 11 的"六种界面状态"）。
enum UpdatePageState {
  /// 还在读设置与安装版本。
  loading,

  /// 正在请求。
  checking,

  /// 有更高的正式版本。
  updateAvailable,

  /// 已经是最新。
  upToDate,

  /// 上次检查失败。
  failed,

  /// 有更高版本，但被用户跳过过。
  skipped,
}

/// 页面对控制器的全部依赖。
///
/// 页面只认这个接口，因此六种状态都能在 Widget 测试里直接摆出来，而不必驱动一个真服务。
///
/// **继承 `Listenable` 而不是 `ChangeNotifier`**：真实的监听机制由 `ChangeNotifier` 提供，
/// 但一个测试替身不需要继承它（它可以直接把自己当成 notifier）。声明成 `ChangeNotifier` 会把
/// 实现细节（`notifyListeners` 是 protected）泄漏进接口。
abstract interface class UpdatePageController implements Listenable {
  UpdatePageState get status;

  /// 当前**安装**版本；读不出来时为 `null`（页面据此不显示版本行，而不是编一个号）。
  AppVersion? get currentAppVersion;

  UpdateSettings get currentSettings;

  /// 有更新（或被跳过）时的那条 Release。
  ReleaseInfo? get availableRelease;

  UpdateFailureReason? get failureReason;

  /// 最近一次检查是谁发起的；还没检查过时为 `null`。
  CheckTrigger? get lastCheckTrigger;

  Future<void> load();

  Future<void> checkNow();

  Future<void> setAutoCheckEnabled(bool enabled);

  Future<void> skipCurrentVersion();

  /// 释放监听器。页面只在 [UpdatePage.disposeController] 为真时调用它。
  void dispose();
}

/// 读自动检查开关的最小端口。
///
/// 让 [UpdatePageController.memory] 能在测试里直接用，而不必构造一个真服务。生产的读取仍然
/// 走 `JsonUpdateSettingsStore`（即 `UpdateService`）。
abstract interface class UpdateAutoCheckStore {
  Future<bool> loadEnabled();

  Future<void> saveEnabled(bool enabled);
}

/// 内存实现，供测试与"设置仓储不可用"的降级路径使用。
///
/// 字段是公开的（而不是带下划线 + 初始化形参），因为 `prefer_initializing_formals` 会把
/// `_enabled = enabled` 这种写法标出来；一个只有两个方法的测试替身不值得为此绕路。
final class MemoryUpdateAutoCheckStore implements UpdateAutoCheckStore {
  MemoryUpdateAutoCheckStore({this.enabled = true});

  bool enabled;

  @override
  Future<bool> loadEnabled() async => enabled;

  @override
  Future<void> saveEnabled(bool value) async => enabled = value;
}

/// 生产控制器：把 `UpdateService` 的结论翻译成界面状态。
final class ServiceUpdatePageController extends ChangeNotifier
    implements UpdatePageController {
  ServiceUpdatePageController({required this.service, required this.autoCheck});

  /// 用真服务构造。
  ///
  /// **直接复用 `UpdateService` 的设置读写**（同一个键、同一套"读失败回默认"），而不是在这里
  /// 再实现一遍：两处实现漂移会让界面上的开关与调度器实际读到的值不一致——那种不一致没有任何
  /// 界面症状，只会表现为"我明明关了它还在联网"。
  factory ServiceUpdatePageController.production(UpdateService service) =>
      ServiceUpdatePageController(
        service: service,
        autoCheck: _ServiceAutoCheckStore(service),
      );

  final UpdateService service;
  final UpdateAutoCheckStore autoCheck;

  UpdatePageState _status = UpdatePageState.loading;
  AppVersion? _currentAppVersion;
  UpdateSettings _settings = const UpdateSettings();
  ReleaseInfo? _release;
  UpdateFailureReason? _failure;
  CheckTrigger? _trigger;

  @override
  UpdatePageState get status => _status;

  @override
  AppVersion? get currentAppVersion => _currentAppVersion;

  @override
  UpdateSettings get currentSettings => _settings;

  @override
  ReleaseInfo? get availableRelease => _release;

  @override
  UpdateFailureReason? get failureReason => _failure;

  @override
  CheckTrigger? get lastCheckTrigger => _trigger;

  /// 读设置与当前版本。
  ///
  /// **读失败不回退到"整页打不开"**：设置读不出来时仍然显示默认开关与"立即检查"
  /// （§7.3 第一条要求：设置页首次打开就要显示当前安装版本）。
  @override
  Future<void> load() async {
    _settings = await service.loadSettings();
    final provider = service.versions;
    if (provider != null) {
      _currentAppVersion = await provider.currentVersion();
    }
    _status = UpdatePageState.upToDate;
    notifyListeners();
  }

  @override
  Future<void> checkNow() => _check(manual: true);

  /// 手动检查**总是**立即请求（§7.3），因此这里不判 24 小时窗口。
  Future<void> _check({required bool manual}) async {
    _trigger = manual ? CheckTrigger.manual : CheckTrigger.automatic;
    _status = UpdatePageState.checking;
    _failure = null;
    notifyListeners();

    final result = await service.check(manual: manual);
    _currentAppVersion = result.currentVersion ?? _currentAppVersion;
    _release = result.release;
    _failure = result.failure;
    _status = switch (result.outcome) {
      UpdateCheckOutcome.updateAvailable => UpdatePageState.updateAvailable,
      UpdateCheckOutcome.skippedVersion => UpdatePageState.skipped,
      UpdateCheckOutcome.failed => UpdatePageState.failed,
      // `disabled`（开关关着）与 `throttled`（24 小时窗口内）都不是失败，也不是"有更新"：
      // 它们对用户的意思就是"当前没有需要你知道的新版本"，因此与"已是最新"同一档。
      UpdateCheckOutcome.upToDate ||
      UpdateCheckOutcome.disabled ||
      UpdateCheckOutcome.throttled => UpdatePageState.upToDate,
    };
    // 重新读一次设置：检查会更新 `lastCheckedUtc` 与 `etag`，界面上的"上次检查"要跟着变。
    _settings = await service.loadSettings();
    notifyListeners();
  }

  @override
  Future<void> setAutoCheckEnabled(bool enabled) async {
    // 先改内存里的值再落库：开关要立刻响应（写库失败也不该让开关弹回去）。
    _settings = _settings.copyWith(autoCheckEnabled: enabled);
    notifyListeners();
    await autoCheck.saveEnabled(enabled);
  }

  @override
  Future<void> skipCurrentVersion() async {
    final release = _release;
    if (release == null) return;
    await service.skipVersion(release.version);
    _settings = await service.loadSettings();
    _status = UpdatePageState.skipped;
    _trigger = null;
    notifyListeners();
  }
}

/// 让控制器直接复用 `UpdateService` 的设置读写（同一个键、同一套回退）。
final class _ServiceAutoCheckStore implements UpdateAutoCheckStore {
  const _ServiceAutoCheckStore(this.service);

  final UpdateService service;

  @override
  Future<bool> loadEnabled() async =>
      (await service.loadSettings()).autoCheckEnabled;

  @override
  Future<void> saveEnabled(bool enabled) async {
    final current = await service.loadSettings();
    if (current.autoCheckEnabled == enabled) return;
    await service.saveSettings(current.copyWith(autoCheckEnabled: enabled));
  }
}

final class UpdatePage extends StatefulWidget {
  const UpdatePage({
    required this.controller,
    this.openUrl,
    this.disposeController = false,
    super.key,
  });

  final UpdatePageController controller;

  /// 打开外部地址。默认交给系统浏览器；测试注入替身以断言"到底打开了哪个地址"。
  ///
  /// **默认值不是 `null`**：生产路径上它必须真的能打开，漏注入不该表现成"点了没反应"。
  final UpdateUrlOpener? openUrl;

  /// 这一页是否负责释放 [controller]。
  ///
  /// 默认 `false`（释放是创建方的事，与 Flutter 的惯例一致）。路由里那一处是例外：控制器正是在
  /// `builder` 里 new 出来的，没有一个更外层的持有者，因此由页面接管释放——否则每进出一次更新页
  /// 就多留一个 `ChangeNotifier` 与其监听器。
  final bool disposeController;

  @override
  State<UpdatePage> createState() => _UpdatePageState();
}

final class _UpdatePageState extends State<UpdatePage> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
    // **不 await**：首帧先显示加载态，读到再补上——与设置入口页的"当前值"同一取舍，
    // 不为了几个字段把整页卡住。
    widget.controller.load();
  }

  @override
  void didUpdateWidget(covariant UpdatePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onChanged);
      widget.controller.addListener(_onChanged);
      widget.controller.load();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    // 只在**这一页创建的**控制器上释放：调用方自己 new 出来、还可能继续持有的实例不该被页面
    // 顺手销毁（那会让调用方拿到一个已释放的 notifier）。
    if (widget.disposeController) widget.controller.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('检查更新')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text('检查更新', style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 4),
            const Text('只检查，不下载、不安装；有更新时由你自己去 GitHub 下载。'),
            const SizedBox(height: 20),
            _settingsCard(context),
            const SizedBox(height: 20),
            _statusSection(context),
            const SizedBox(height: 24),
            _privacyNote(context),
          ],
        ),
      ),
    ),
  );

  /// 版本、更新源、自动检查开关。
  Widget _settingsCard(BuildContext context) {
    final controller = widget.controller;
    final version = controller.currentAppVersion;
    final checked = controller.currentSettings.lastCheckedUtc;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (version != null)
              Text(
                '当前版本 ${version.toString()}',
                key: const Key('update-current-version'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            const SizedBox(height: 8),
            Text(
              // 「还没有检查过」而不是一个空白或 `null`：这一行是用户判断"它到底工作没有"的
              // 唯一依据，留空等于让那条信息消失。
              checked == null
                  ? '上次检查：还没有检查过'
                  : '上次检查：${_formatStamp(checked.toLocal())}',
              key: const Key('update-last-checked'),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 4),
            Text(
              '更新源：$githubReleaseRepositoryUrl',
              key: const Key('update-source'),
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: PlannerPalette.textMuted),
            ),
            const Divider(height: 28),
            SwitchListTile(
              key: const Key('update-auto-check'),
              value: controller.currentSettings.autoCheckEnabled,
              onChanged: controller.setAutoCheckEnabled,
              contentPadding: EdgeInsets.zero,
              title: const Text('自动检查更新'),
              subtitle: const Text('启动约 10 秒后检查一次；运行期间最多每 24 小时一次'),
            ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                key: const Key('update-check-now'),
                // 检查中禁用：点了没反应比按钮变灰更糟（用户会反复点，而每次都发一次请求）。
                onPressed: controller.status == UpdatePageState.checking
                    ? null
                    : controller.checkNow,
                icon: const Icon(Icons.refresh),
                label: const Text('立即检查'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusSection(BuildContext context) {
    final controller = widget.controller;
    return switch (controller.status) {
      UpdatePageState.loading => const Padding(
        key: Key('update-loading'),
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      ),
      UpdatePageState.checking => const Padding(
        key: Key('update-checking'),
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Column(
          children: [
            LinearProgressIndicator(),
            SizedBox(height: 12),
            Text('正在检查…'),
          ],
        ),
      ),
      UpdatePageState.updateAvailable => _availableCard(context),
      UpdatePageState.upToDate => _messageCard(
        context,
        key: const Key('update-up-to-date'),
        icon: Icons.check_circle_outline,
        text: '已经是最新版本，没有需要更新的内容。',
      ),
      UpdatePageState.skipped => _skippedCard(context),
      UpdatePageState.failed =>
        controller.lastCheckTrigger == CheckTrigger.manual
            ? _failureCard(context)
            : _autoFailureHint(context),
    };
  }

  /// 有更新：版本、发布日期、说明、查看下载、跳过此版本。
  Widget _availableCard(BuildContext context) {
    final release = widget.controller.availableRelease;
    if (release == null) {
      // 有更新却没有 Release 是自相矛盾的状态（服务不会给出）。此时说"已是最新"比显示一个
      // 空卡片诚实——用户看到的状态与事实一致。
      return _messageCard(
        context,
        key: const Key('update-up-to-date'),
        icon: Icons.check_circle_outline,
        text: '已经是最新版本，没有需要更新的内容。',
      );
    }
    final url = _validatedReleaseUrl(release.htmlUrl);
    return Card(
      key: const Key('update-available'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.system_update_alt),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '发现新版本 ${release.version.label}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            if (release.publishedAtUtc != null) ...[
              const SizedBox(height: 6),
              Text(
                '发布日期：${_formatDate(release.publishedAtUtc!.toLocal())}',
                key: const Key('update-release-date'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (release.notes.trim().isNotEmpty) ...[
              const SizedBox(height: 12),
              // 用可滚动区域而不是直接铺开：真实 Release 正文可以很长，铺开会把
              // "查看下载" 推到很下面。
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: SingleChildScrollView(
                  key: const Key('update-release-notes'),
                  child: Text(release.notes.trim()),
                ),
              ),
            ],
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                // **地址没通过验证时整个按钮不渲染**（而不是渲染一个点不动的按钮，
                // 也不是退回到仓库首页）：§7.3 要求"点查看下载只打开已验证的地址"。
                if (url != null)
                  FilledButton.icon(
                    key: const Key('update-download'),
                    onPressed: () => _open(url),
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('查看下载'),
                  ),
                TextButton.icon(
                  key: const Key('update-skip-version'),
                  onPressed: widget.controller.skipCurrentVersion,
                  icon: const Icon(Icons.visibility_off_outlined),
                  label: const Text('跳过此版本'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '本应用不会自动下载或安装更新，也不会在后台替换正在运行的程序。',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: PlannerPalette.textMuted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _skippedCard(BuildContext context) {
    final release = widget.controller.availableRelease;
    return _messageCard(
      context,
      key: const Key('update-skipped'),
      icon: Icons.visibility_off_outlined,
      text: release == null
          ? '已跳过这个版本；更高版本仍会提醒。'
          : '已跳过 ${release.version.label}；更高版本仍会提醒。',
    );
  }

  /// 手动检查失败：**给出具体原因**。
  Widget _failureCard(BuildContext context) {
    final reason = widget.controller.failureReason;
    return Card(
      key: const Key('update-failure'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.error_outline,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('检查更新失败', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 4),
                  // **只可能是枚举里的那几句话**：这一页拿不到异常对象，因此不可能把堆栈或
                  // 本地路径显示出去（`backup_page.dart` 已经为相反的做法付过一次代价）。
                  Text(reason?.label ?? UpdateFailureReason.unknown.label),
                  const SizedBox(height: 8),
                  const Text('可以稍后再试；自动检查会在网络恢复后重新工作。'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 自动检查失败：**非打扰**。一行浅色说明，不用错误色、不用横幅、不弹提示。
  Widget _autoFailureHint(BuildContext context) => Padding(
    key: const Key('update-auto-failure-hint'),
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      children: [
        Icon(
          Icons.cloud_off_outlined,
          size: 18,
          color: PlannerPalette.textMuted,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '这次后台检查没有连上，不影响使用；需要时可以点「立即检查」。',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: PlannerPalette.textMuted),
          ),
        ),
      ],
    ),
  );

  Widget _messageCard(
    BuildContext context, {
    required Key key,
    required IconData icon,
    required String text,
  }) => Card(
    key: key,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Icon(icon),
          const SizedBox(width: 12),
          Expanded(child: Text(text)),
        ],
      ),
    ),
  );

  /// 首次进入说明联网边界（§3.6 原文）。
  Widget _privacyNote(BuildContext context) => Container(
    key: const Key('update-privacy-note'),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: PlannerPalette.surfaceRaised,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('联网说明', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        const Text(
          '检查更新只会向 GitHub 请求这个项目的公开版本信息（版本号、发布日期与更新说明），'
          '不上传本机的任何数据：任务、课表、统计、偏好与数据库内容都不会离开这台电脑。\n'
          '关闭「自动检查更新」之后，程序不会主动联网；「立即检查」则总是由你发起。',
        ),
      ],
    ),
  );

  /// 打开**已验证**的地址。
  ///
  /// `_validatedReleaseUrl` 已经把地址限制在仓库的 `/releases/` 下，因此这里拿到的 `Uri`
  /// 一定是可接受的；仍然把结果当布尔处理，是因为"浏览器没打开"与"没有按钮"是两种不同的
  /// 真实情况，不应该假装成功。
  Future<void> _open(Uri url) async {
    final opener = widget.openUrl ?? openUpdateUrlExternally;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final opened = await opener(url);
    if (!opened && mounted && messenger != null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('没有打开浏览器，请手动访问更新源地址。')),
      );
    }
  }
}

/// 只接受仓库 Release 页面的 HTTPS 地址；其余一律返回 `null`。
///
/// **这是"查看下载"的唯一防线**，因此判定写得很紧：协议必须是 `https`、主机必须是
/// `github.com`、路径必须以 `/<仓库>/releases/` 开头。任何一项不满足就当作"没有可点的地址"，
/// 界面因此不渲染那个按钮——而不是渲染一个会把人带到别处的链接。
///
/// 为什么按 `releases/` 前缀而不是逐个枚举 tag：tag 由发布流程决定，写死枚举会让新版本反而
/// 没有下载入口；而"必须在这个仓库的 releases 下"这一条已经把地址锁死在项目自己的发布页。
Uri? _validatedReleaseUrl(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  final uri = Uri.tryParse(raw);
  if (uri == null) return null;
  if (uri.scheme != 'https') return null;
  if (uri.host != 'github.com') return null;
  if (!uri.path.startsWith('/$githubReleaseRepository/releases/')) return null;
  return uri;
}

/// `2026/10/08 10:30`。**不显示秒**：用户看不出秒的意义，而它会随着每一帧变化。
String _formatStamp(DateTime value) =>
    '${_formatDate(value)} '
    '${value.hour.toString().padLeft(2, '0')}:'
    '${value.minute.toString().padLeft(2, '0')}';

String _formatDate(DateTime value) =>
    '${value.year}/${value.month.toString().padLeft(2, '0')}/'
    '${value.day.toString().padLeft(2, '0')}';
