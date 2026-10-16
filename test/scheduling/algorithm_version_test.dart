// 1.8.0（裁定第 3 点；设计 §6）：**算法版本必须两处一致**。
//
// 裁定原文："同意算法版本升到 `12`。稳定身份、块级延后、局部级联、方案级坏空档比较
// 作为同一次算法升级完成，最后统一升到 12。**它是内部排程算法版本，不是软件版本号。**"
//
// 两个地方各存着一份"当前算法版本"：
//   · `DeterministicScheduleEngine.algorithmVersion`（产出的提案带它）；
//   · `test/fixtures/scheduling/golden_week.json` 的 `expected.algorithmVersion`
//     （基准记录它）。
//
// `schedule_engine_test.dart` 只比对"提案的版本 == 基准里的版本"，因此
// **两处一起改**时它会照常通过——那份用例守不住"忘记同步"这件事。
// 本文件把"两处必须都等于当前算法版本"单独钉住：
// 只改一处会当场红，而不会静默地让基准与引擎分叉。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/services/default_settings.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';

import '../support/daily_policies.dart';

void main() {
  test('golden 基准记录的算法版本与引擎常量一致', () {
    final fixture = jsonDecode(
      File('test/fixtures/scheduling/golden_week.json').readAsStringSync(),
    ) as Map<String, Object?>;

    final expected = fixture['expected']! as Map<String, Object?>;
    expect(
      expected['algorithmVersion'],
      DeterministicScheduleEngine.algorithmVersion,
      reason:
          '基准文件与引擎常量分叉了。只改一处时 '
          '`schedule_engine_test.dart` 仍会通过（它比对的是"提案 vs 基准"），'
          '因此这条单独存在：两处都必须是当前算法版本',
    );
  });

  test('算法版本是纯数字串（它是内部算法版本，不是软件版本号）', () {
    final version = DeterministicScheduleEngine.algorithmVersion;
    expect(
      RegExp(r'^\d+$').hasMatch(version),
      isTrue,
      reason:
          '裁定第 3 点："它是内部排程算法版本，不是软件版本号"——'
          '因此不该出现 `1.8.0` 这类点号形式（那会与 `pubspec.yaml` 混起来）',
    );
  });

  test('引擎产出的提案带上当前算法版本', () {
    // 与上面两条互补：常量对了、基准对了，还要确认**它真的被写进提案**，
    // 否则历史计划无法按版本区分（"算法变了"与"输入变了"分不开）。
    //
    // **第一版这里写的是 `expect(engine, isNotNull)`** —— 而 `engine` 是非空类型，
    // 那条断言恒真、什么也没验。改成果真跑一次生成、读提案上的版本。
    final zones = TimeZoneDatabase();
    final engine = DeterministicScheduleEngine(zones);
    final window = TimeRange(
      startUtc: DateTime.utc(2026, 10, 12),
      endUtc: DateTime.utc(2026, 10, 13),
    );
    const zoneId = 'UTC';
    final rules = DefaultSettings.v1();
    final proposal = engine.generate(
      ScheduleProblem(
        planningWindow: window,
        timeZoneId: zoneId,
        tasks: const [],
        fixedIntervals: const [],
        protectedIntervals: const [],
        lockedBlocks: const [],
        rules: rules,
        dailyPolicies: dailyPoliciesForWindow(
          zones: zones,
          window: window,
          rules: rules,
          timeZoneId: zoneId,
        ),
        weeklyLifeQuotaByWeekStart: weeklyLifeQuotasForWindow(
          zones: zones,
          window: window,
          rules: rules,
          timeZoneId: zoneId,
        ),
        preferences: const PreferenceProfile(),
        inputHash: 'version-guard',
      ),
    );

    expect(
      proposal.algorithmVersion,
      DeterministicScheduleEngine.algorithmVersion,
      reason: '提案必须带上当前算法版本，否则历史计划无法按版本区分',
    );
  });
}
