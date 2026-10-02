import 'dart:convert';

import 'package:flutter/material.dart';
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
  final _focusMinutes = TextEditingController(text: '50');
  final _breakMinutes = TextEditingController(text: '10');
  final _lifeQuota = TextEditingController(text: '360');
  bool _editing = false;
  bool _saving = false;

  @override
  void dispose() {
    _focusMinutes.dispose();
    _breakMinutes.dispose();
    _lifeQuota.dispose();
    super.dispose();
  }

  Future<void> _finish({bool saveChanges = false}) async {
    setState(() => _saving = true);
    if (saveChanges) {
      await widget.repository.write(
        'planning.userRules.v1',
        jsonEncode({
          'common': {
            'defaultFocusMinutes': int.tryParse(_focusMinutes.text) ?? 50,
            'breakMinutes': int.tryParse(_breakMinutes.text) ?? 10,
            'weeklyLifeQuotaMinutes': int.tryParse(_lifeQuota.text) ?? 360,
          },
          'weekday': <String, Object?>{},
          'weekend': <String, Object?>{},
        }),
      );
    }
    await widget.repository.write(
      OnboardingPage.schemaVersionKey,
      OnboardingPage.currentSchemaVersion.toString(),
    );
    await widget.repository.write('planning.trustAutoAdjust.v1', 'false');
    if (!mounted) return;
    widget.onComplete();
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
                  _DefaultCard(title: '睡眠保护', value: '23:30–07:30'),
                  _DefaultCard(title: '专注节奏', value: '50 分钟专注 · 10 分钟休息'),
                  _DefaultCard(title: '生活配额', value: '每周 360 分钟生活娱乐'),
                  _DefaultCard(title: '自动调整：关闭', value: '先预览并确认'),
                  _DefaultCard(title: '应用锁：关闭', value: '可稍后在设置中开启'),
                ],
              ),
              if (_editing) ...[
                const SizedBox(height: 24),
                Text('修改常用默认值', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    _minutesField(
                      '专注分钟',
                      _focusMinutes,
                      'onboarding-focus-minutes',
                    ),
                    _minutesField(
                      '休息分钟',
                      _breakMinutes,
                      'onboarding-break-minutes',
                    ),
                    _minutesField(
                      '每周生活配额',
                      _lifeQuota,
                      'onboarding-life-quota',
                    ),
                  ],
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

  Widget _minutesField(
    String label,
    TextEditingController controller,
    String key,
  ) => SizedBox(
    width: 220,
    child: TextField(
      key: Key(key),
      controller: controller,
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
