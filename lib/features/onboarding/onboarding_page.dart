import 'package:flutter/material.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';

final class OnboardingPage extends StatefulWidget {
  const OnboardingPage({
    required this.repository,
    required this.onComplete,
    super.key,
  });

  static const schemaVersionKey = 'onboarding.schemaVersion';
  static const currentSchemaVersion = 1;

  final SettingsRepository repository;
  final VoidCallback onComplete;

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

final class _OnboardingPageState extends State<OnboardingPage> {
  final Map<String, TextEditingController> _controllers = {
    'high-start': TextEditingController(text: '09:00'),
    'high-end': TextEditingController(text: '12:00'),
    'medium-start': TextEditingController(text: '14:00'),
    'medium-end': TextEditingController(text: '17:00'),
    'low-start': TextEditingController(text: '19:00'),
    'low-end': TextEditingController(text: '22:00'),
    'sleep-start': TextEditingController(text: '23:30'),
    'sleep-end': TextEditingController(text: '07:30'),
    'minimum-sleep': TextEditingController(text: '420'),
    'lunch-start': TextEditingController(text: '12:00'),
    'lunch-end': TextEditingController(text: '13:00'),
    'dinner-start': TextEditingController(text: '18:00'),
    'dinner-end': TextEditingController(text: '19:00'),
    'focus-minutes': TextEditingController(text: '50'),
    'break-minutes': TextEditingController(text: '10'),
    'min-chunk': TextEditingController(text: '30'),
    'max-chunk': TextEditingController(text: '90'),
    'daily-limit': TextEditingController(text: '360'),
    'life-quota': TextEditingController(text: '360'),
  };

  bool _editing = false;
  bool _saving = false;
  bool _lunchEnabled = true;
  bool _dinnerEnabled = true;
  bool _trustAutoAdjust = false;
  bool _preferenceLearningEnabled = true;
  String? _error;

  TextEditingController _controller(String key) => _controllers[key]!;

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _finish({bool saveChanges = false}) async {
    if (saveChanges) {
      final errors = <String>[];
      final high = _readRange('high', errors);
      final medium = _readRange('medium', errors);
      final low = _readRange('low', errors);
      final sleep = _readRange('sleep', errors);
      final lunch = _readRange('lunch', errors);
      final dinner = _readRange('dinner', errors);
      final minimumSleep = _positive('minimum-sleep', errors);
      final focus = _positive('focus-minutes', errors);
      final breakMinutes = _nonNegative('break-minutes', errors);
      final minChunk = _positive('min-chunk', errors);
      final maxChunk = _positive('max-chunk', errors);
      final dailyLimit = _positive('daily-limit', errors);
      final lifeQuota = _nonNegative('life-quota', errors);
      if (minChunk != null && maxChunk != null && minChunk > maxChunk) {
        errors.add('最短片段不能大于最长片段');
      }
      if (dailyLimit != null && dailyLimit > LocalTimeRange.minutesPerDay) {
        errors.add('每日上限不能超过 1440 分钟');
      }
      if (errors.isNotEmpty) {
        setState(() => _error = errors.first);
        return;
      }

      setState(() {
        _saving = true;
        _error = null;
      });
      final settings = SettingsService(repository: widget.repository);
      try {
        await settings.saveUserRules(
          UserPlanningRules(
            common: PlanningRulesPatch(
              energyWindows: [
                EnergyWindow(range: high!, level: EnergyLevel.high),
                EnergyWindow(range: medium!, level: EnergyLevel.medium),
                EnergyWindow(range: low!, level: EnergyLevel.low),
              ],
              protectedTimes: [
                ProtectedTimeRule(
                  kind: ProtectedTimeKind.lunch,
                  range: lunch!,
                  enabled: _lunchEnabled,
                ),
                ProtectedTimeRule(
                  kind: ProtectedTimeKind.dinner,
                  range: dinner!,
                  enabled: _dinnerEnabled,
                ),
              ],
              sleepRange: sleep,
              minimumSleepMinutes: minimumSleep,
              defaultFocusMinutes: focus,
              breakMinutes: breakMinutes,
              minChunkMinutes: minChunk,
              maxChunkMinutes: maxChunk,
              dailyMovableTaskLimitMinutes: dailyLimit,
              weeklyLifeQuotaMinutes: lifeQuota,
            ),
          ),
        );
        await settings.setTrustAutoAdjust(_trustAutoAdjust);
        if (!_preferenceLearningEnabled) {
          await settings.saveLearnedPreferences(
            const PreferenceProfile(enabled: false),
          );
        }
      } on SettingsValidationException catch (error) {
        if (mounted) {
          setState(() {
            _saving = false;
            _error = error.fieldErrors.values.first;
          });
        }
        return;
      }
    } else {
      setState(() => _saving = true);
      await SettingsService(repository: widget.repository)
          .setTrustAutoAdjust(false);
    }

    await widget.repository.write(
      OnboardingPage.schemaVersionKey,
      OnboardingPage.currentSchemaVersion.toString(),
    );
    if (!mounted) return;
    widget.onComplete();
  }

  LocalTimeRange? _readRange(String key, List<String> errors) {
    final start = _parseTime(_controller('$key-start').text);
    final end = _parseTime(_controller('$key-end').text);
    if (start == null || end == null || start == end) {
      errors.add('时间请使用 HH:mm 格式，且开始与结束不能相同');
      return null;
    }
    return LocalTimeRange(startMinute: start, endMinute: end);
  }

  int? _positive(String key, List<String> errors) {
    final value = int.tryParse(_controller(key).text.trim());
    if (value == null || value <= 0) {
      errors.add('分钟数必须大于 0');
      return null;
    }
    return value;
  }

  int? _nonNegative(String key, List<String> errors) {
    final value = int.tryParse(_controller(key).text.trim());
    if (value == null || value < 0) {
      errors.add('分钟数不能小于 0');
      return null;
    }
    return value;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 880),
          child: ListView(
            padding: const EdgeInsets.all(32),
            children: [
              Icon(
                Icons.auto_awesome_outlined,
                size: 48,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                '先照顾好生活，再安排任务',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 8),
              const Text(
                '这些默认值可以随时修改。系统只滚动规划未来 7 天，同时检查更远截止日期。',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              const Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  _DefaultCard(title: '高精力', value: '09:00–12:00'),
                  _DefaultCard(title: '中精力', value: '14:00–17:00'),
                  _DefaultCard(title: '低精力', value: '19:00–22:00'),
                  _DefaultCard(title: '睡眠保护', value: '23:30–07:30 · 至少 7 小时'),
                  _DefaultCard(
                    title: '用餐保护',
                    value: '午餐 12:00–13:00 · 晚餐 18:00–19:00',
                  ),
                  _DefaultCard(title: '专注节奏', value: '50 分钟专注 · 10 分钟休息'),
                  _DefaultCard(title: '任务片段', value: '30–90 分钟 · 每日上限 360 分钟'),
                  _DefaultCard(title: '生活配额', value: '每周 360 分钟生活娱乐'),
                  _DefaultCard(title: '自动调整：关闭', value: '先预览并确认'),
                  _DefaultCard(title: '偏好学习', value: '开启建议 · 关闭自动采用'),
                  _DefaultCard(title: '应用锁：关闭', value: '可稍后在设置中开启'),
                ],
              ),
              if (_editing) ...[
                const SizedBox(height: 24),
                _buildEditor(context),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 28),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton(
                    onPressed: _saving
                        ? null
                        : () => _finish(saveChanges: _editing),
                    child: Text(_editing ? '保存修改' : '一键采用默认设置'),
                  ),
                  OutlinedButton(
                    onPressed: _saving
                        ? null
                        : () => setState(() => _editing = true),
                    child: const Text('修改设置'),
                  ),
                  TextButton(
                    onPressed: _saving ? null : _finish,
                    child: const Text('稍后设置'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _buildEditor(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('修改关键默认值', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          const Text('未标记的时段使用中性精力；这些设置不是健康建议，之后仍可在设置页调整。'),
          const SizedBox(height: 16),
          _rangeEditor('高精力区间', 'high'),
          _rangeEditor('中精力区间', 'medium'),
          _rangeEditor('低精力区间', 'low'),
          _rangeEditor('常规睡眠', 'sleep'),
          _numberField('最低睡眠', 'minimum-sleep'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('保护午餐时间'),
            value: _lunchEnabled,
            onChanged: (value) => setState(() => _lunchEnabled = value),
          ),
          _rangeEditor('午餐保护', 'lunch'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('保护晚餐时间'),
            value: _dinnerEnabled,
            onChanged: (value) => setState(() => _dinnerEnabled = value),
          ),
          _rangeEditor('晚餐保护', 'dinner'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _numberField('默认专注', 'focus-minutes'),
              _numberField('片段间休息', 'break-minutes'),
              _numberField('最短片段', 'min-chunk'),
              _numberField('最长片段', 'max-chunk'),
              _numberField('每日可移动任务上限', 'daily-limit'),
              _numberField('每周生活娱乐配额', 'life-quota'),
            ],
          ),
          SwitchListTile(
            key: const Key('onboarding-trust-auto-adjust'),
            contentPadding: EdgeInsets.zero,
            title: const Text('信任自动调整'),
            subtitle: const Text('默认关闭；开启后仍会记录调整历史与原因。'),
            value: _trustAutoAdjust,
            onChanged: (value) => setState(() => _trustAutoAdjust = value),
          ),
          SwitchListTile(
            key: const Key('onboarding-preference-learning'),
            contentPadding: EdgeInsets.zero,
            title: const Text('开启偏好建议'),
            subtitle: const Text('默认开启建议、关闭自动采用；只影响软偏好。'),
            value: _preferenceLearningEnabled,
            onChanged: (value) =>
                setState(() => _preferenceLearningEnabled = value),
          ),
          const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.lock_outline),
            title: Text('应用锁保持关闭'),
            subtitle: Text('启用时必须由你在设置中创建密码；数据库文件本身不会因此加密。'),
          ),
        ],
      ),
    ),
  );

  Widget _rangeEditor(String label, String key) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Wrap(
      spacing: 10,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SizedBox(width: 150, child: Text(label)),
        _timeField('$key-start', '开始'),
        _timeField('$key-end', '结束'),
      ],
    ),
  );

  Widget _timeField(String key, String label) => SizedBox(
    width: 130,
    child: TextField(
      key: Key('onboarding-$key'),
      controller: _controller(key),
      decoration: InputDecoration(labelText: label, hintText: 'HH:mm'),
    ),
  );

  Widget _numberField(String label, String key) => SizedBox(
    width: 230,
    child: TextField(
      key: Key('onboarding-$key'),
      controller: _controller(key),
      keyboardType: TextInputType.number,
      decoration: InputDecoration(labelText: label, suffixText: '分钟'),
    ),
  );
}

final class _DefaultCard extends StatelessWidget {
  const _DefaultCard({required this.title, required this.value});
  final String title;
  final String value;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 250,
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(value),
          ],
        ),
      ),
    ),
  );
}

int? _parseTime(String input) {
  final match = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(input.trim());
  if (match == null) return null;
  final hour = int.parse(match.group(1)!);
  final minute = int.parse(match.group(2)!);
  if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
  return hour * 60 + minute;
}
