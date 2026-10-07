// FR-STAT-05 的"休息保护情况"：**数据层必须真的把保护时段交出来**。
//
// 这一节此前在服务侧与页面侧都写好并有测试（`energy_periods_test.dart` 覆盖了"保护总时长
// 按本地日累计""被占用按实际时长折算"等），但**数据层只读用户已保存的规则**，于是：
//
// 1. **全新安装下 `protectedWindows` 恒为空**——默认值里午餐与晚餐本来受保护，可这个键在
//    用户没保存过规则时根本不存在。空列表 → 服务返回 `null` → **整节不显示**。这与精力区间
//    当初"区间不在数据集里"是同一类失效：每一层都在，只是数据永远拿不到。
// 2. **睡眠完全不在这一节里**——`protectedTimes` 只有午餐／晚餐／固定休息，睡眠在
//    `sleepRange`，而"休息保护"最主要的一段恰恰是睡眠。
//
// 本文件钉住这两点，以及"用户保存过规则时以用户的为准"。
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/data/database/app_database.dart';
import 'package:personal_planner/data/database/daos/analytics_dao.dart';
import 'package:personal_planner/domain/models/analytics.dart';
import 'package:personal_planner/domain/services/default_settings.dart';
import 'package:personal_planner/data/repositories/drift_calendar_repository.dart';

void main() {
  late AppDatabase database;
  late AnalyticsDao dao;

  final filter = AnalyticsFilter(
    startUtc: DateTime.utc(2026, 10, 1),
    endUtc: DateTime.utc(2026, 10, 8),
  );

  Future<List<AnalyticsProtectedWindow>> windows() async =>
      (await dao.load(filter)).protectedWindows;

  Future<void> seedRules(String json) => database
      .into(database.settings)
      .insert(
        SettingsCompanion.insert(
          key: 'planning.userRules.v1',
          jsonValue: json,
          updatedAtUtc: 1,
        ),
      );

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    dao = AnalyticsDao(database, calendar: DriftCalendarRepository(database));
  });

  tearDown(() => database.close());

  test('全新安装下仍有保护时段：取默认值，而不是空列表', () async {
    // **这条是判别性的**：修复前这里返回空列表，整节在界面上不显示。
    final result = await windows();

    final defaults = DefaultSettings.v1();
    expect(result, isNotEmpty);
    expect(
      result.where((item) => item.label == '午餐'),
      hasLength(1),
      reason: '默认值里午餐是受保护的，统计里就该看得到',
    );
    expect(
      result.map((item) => item.label),
      containsAll(<String>['午餐', '晚餐', '睡眠']),
    );
    final sleep = result.singleWhere((item) => item.label == '睡眠');
    expect(sleep.startMinute, defaults.sleepRange.startMinute);
    expect(sleep.endMinute, defaults.sleepRange.endMinute);
    // 睡眠跨午夜（默认 23:00–07:00），因此 `endMinute < startMinute`；服务侧据此判定跨日。
    expect(sleep.endMinute, lessThan(sleep.startMinute));
    expect(sleep.isWeekend, isNull, reason: '睡眠默认不区分工作日与周末');
  });

  test('用户保存过保护时段时用用户的，睡眠也取用户的值', () async {
    await seedRules(
      '{"common":{"protectedTimes":[{"kind":"lunch","range":'
      '{"startMinute":720,"endMinute":780},"dayKind":"weekday","enabled":true}],'
      '"sleepRange":{"startMinute":60,"endMinute":420}}}',
    );

    final result = await windows();

    // 用户那条**替换**默认列表，因此晚餐与固定休息不再出现。
    expect(result.where((item) => item.label == '晚餐'), isEmpty);
    expect(result.where((item) => item.label == '固定休息'), isEmpty);
    final lunch = result.singleWhere((item) => item.label == '午餐');
    expect(lunch.startMinute, 720);
    expect(lunch.endMinute, 780);
    expect(lunch.isWeekend, isFalse, reason: '这条只适用于工作日');
    final sleep = result.singleWhere((item) => item.label == '睡眠');
    expect(sleep.startMinute, 60, reason: '睡眠应取用户保存的值，而不是默认值');
    expect(sleep.endMinute, 420);
  });

  test('关闭的保护段不出现在统计里（关掉保护不该让数字变差）', () async {
    await seedRules(
      '{"common":{"protectedTimes":[{"kind":"lunch","range":'
      '{"startMinute":720,"endMinute":780},"dayKind":"any","enabled":false},'
      '{"kind":"dinner","range":{"startMinute":1080,"endMinute":1140},'
      '"dayKind":"any","enabled":true}]}}',
    );

    final result = await windows();

    expect(result.where((item) => item.label == '午餐'), isEmpty);
    expect(result.where((item) => item.label == '晚餐'), hasLength(1));
  });

  test('设置损坏时退回默认值，而不是让整节消失', () async {
    await seedRules('{not json');

    final result = await windows();

    expect(result, isNotEmpty);
    expect(result.map((item) => item.label), contains('午餐'));
  });

  group('按日临时例外（FR-REPLAN-07 的"临时放宽"）', () {
    Future<void> seedOverride(String date, String json) => database
        .into(database.settings)
        .insert(
          SettingsCompanion.insert(
            key: 'planning.dateOverride.$date',
            jsonValue: json,
            updatedAtUtc: 1,
          ),
        );

    Future<List<DateTime>> relaxed() async =>
        (await dao.load(filter)).relaxedLocalDates;

    test('没有例外时为空', () async {
      expect(await relaxed(), isEmpty);
    });

    test('读得出存在的例外日期（键里就写着本地日期）', () async {
      await seedOverride('2026-10-03', '{"dailyMovableTaskLimitMinutes":300}');
      await seedOverride('2026-10-05', '{"dailyMovableTaskLimitMinutes":120}');

      expect(
        await relaxed(),
        unorderedEquals([DateTime.utc(2026, 10, 3), DateTime.utc(2026, 10, 5)]),
      );
    });

    test('形状不对的键被跳过，而不是被规范化成另一天', () async {
      // `DateTime(2026, 13, 40)` 会被规范化成 2027-02-09——那会凭空造出一个不存在的
      // "放宽日"，而统计里就会出现一个用户从未放宽过的日期。
      await seedOverride('2026-13-40', '{}');
      await seedOverride('not-a-date', '{}');
      await seedOverride('2026-10-04', '{}');

      expect(await relaxed(), <DateTime>[DateTime.utc(2026, 10, 4)]);
    });

    test('清除例外后它就不再出现（放宽是可逆的）', () async {
      await seedOverride('2026-10-03', '{}');
      expect(await relaxed(), hasLength(1));

      await (database.delete(
            database.settings,
          )..where((row) => row.key.equals('planning.dateOverride.2026-10-03')))
          .go();

      expect(await relaxed(), isEmpty);
    });
  });
}
