// 1.8.0（规范 §5.2）：`reconcile` 的取消判据依赖三条**结构性质**。
//
// 它们一旦被破坏，症状是"关掉一类提醒时连别的类一起清掉"（本批次修过这个缺陷）
// 或"某一类永远取消不掉"。三条都是**纯结构**的，可以脱离界面与端口验证。
//
// 本文件**不动端口**：只验前缀与类别的对应关系，那是取消逻辑唯一依赖的事实。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/notification_service.dart';
import 'package:personal_planner/domain/repositories/notification_port.dart';

void main() {
  group('通知前缀与类别的结构性质（规范 §5.2）', () {
    /// 每个 `NotificationKind` 对应的**真实前缀**。
    ///
    /// **在这里显式列出而不是从生产代码取**：这样前缀一旦被改动，这条用例就会失败，
    /// 逼人回来看"生成端与识别端还对不对得上"。从生产代码取会让它永远为真——
    /// 而本批次反复出现的正是"看着对、其实没接上"。
    const prefixes = <NotificationKind, String>{
      NotificationKind.taskStart: 'planner.task_start.',
      NotificationKind.calendarStart: 'planner.calendar_start.',
      NotificationKind.deadline: 'planner.deadline.',
      NotificationKind.conflict: 'planner.conflict.',
      NotificationKind.recurringGoal: 'planner.recurring.',
    };

    test('每一类的示例 id 都被识别成**它自己**那一类', () {
      for (final entry in prefixes.entries) {
        final id = '${entry.value}sample.entity.2026-10-12';
        expect(
          NotificationService.categoryOf(id),
          entry.key,
          reason:
              '${entry.value} 开头的 id 必须被认成 ${entry.key.name}；'
              '认成别的类会让"关掉这一类"误伤另一类——本批次修过的正是这个缺陷',
        );
      }
    });

    test('所有前缀都在粗粒度前缀之下（否则取消的遍历会整类漏掉）', () {
      for (final prefix in prefixes.values) {
        expect(
          prefix.startsWith(NotificationService.managedPrefix),
          isTrue,
          reason:
              '$prefix 不以 ${NotificationService.managedPrefix} 开头；'
              '按粗粒度前缀过滤的路径会因此整类漏取消',
        );
      }
    });

    test('**没有任何一个前缀是另一个的前缀**（否则识别结果取决于判断顺序）', () {
      final list = prefixes.values.toList();
      for (final a in list) {
        for (final b in list) {
          if (identical(a, b)) continue;
          expect(
            a.startsWith(b),
            isFalse,
            reason:
                '「$a」以「$b」开头时，`_categoryOf` 的识别结果取决于 if 的先后顺序——'
                '那是一种"改一行 if 顺序就换一类"的脆弱设计',
          );
        }
      }
    });

    test('非本应用的通知 id 一律识别为 null（不能被误取消）', () {
      for (final id in const [
        'other_app.reminder.1',
        'planner.', // 只有粗粒度前缀，没有具体类别
        'planner.something_new.1', // 将来新增的、本版本不认识的类别
        '',
      ]) {
        expect(
          NotificationService.categoryOf(id),
          isNull,
          reason:
              '「$id」不是本版本排入的：把它当成自己人会误取消别的程序'
              '（或未来版本）的通知',
        );
      }
    });

    test('`managedPrefixes` = 粗粒度前缀 ＋ 每个具体类别各一次', () {
      // 这份清单**不参与取消判据**（真正的判据是"识别类别 → 看开关"），
      // 但它是**声明意图**的地方。第一版我断言"清单里每个前缀都能识别出类别"，
      // 结果红了——因为清单里**第一个就是**粗粒度前缀 `planner.`，
      // 而它按定义认不出具体类别（`categoryOf('planner.sample')` 就是 `null`）。
      //
      // 这不是错误，而是这份清单**同时装着两种东西**：一个"这是不是本应用的"（粗），
      // 以及每个"这是哪一类"（细）。把这条区分写下来，比把它抹平更有价值——
      // 抹平会让人以为"planner. 也是一个类别"。
      final declared = NotificationService.managedPrefixes.toSet();
      expect(
        declared.contains(NotificationService.managedPrefix),
        isTrue,
        reason: '清单必须含粗粒度前缀——它是"这条 id 属于本应用"的兜底判据',
      );
      for (final prefix in prefixes.values) {
        expect(
          declared.contains(prefix),
          isTrue,
          reason: '「$prefix」能识别出类别，却不在声明清单里',
        );
      }
      expect(
        declared.length,
        prefixes.length + 1,
        reason:
            '清单长度 = 具体类别数 ＋ 粗粒度前缀；多出来或少了都说明有人加/删了前缀'
            '却没同步生成端或识别端',
      );
    });
  });
}
