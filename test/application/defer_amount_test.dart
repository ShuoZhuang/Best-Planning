// 1.8.0（规范 §11.1）：延后对话框的自定义值与快捷值约束。
//
// 规范那张表逐列写死了约束：
//
// | 单位 | 快捷值 | 自定义约束 |
// | 分钟 | 5、10、15、30、45 | 1～1440，**最终按 5 分钟粒度向上对齐并在确认前展示实际值** |
// | 小时 | 1、2、3、6 | 1～72 的整数 |
// | 天 | 1、2、3、7 | 1～365 的整数 |
//
// 本文件验的是"范围校验"之外的**那一半**：向上对齐。范围校验在对话框里已有，
// 而对齐此前**完全没有实现** —— 用户输入 7 分钟，应用的就是 7 分钟，而排程器按
// 5 分钟粒度工作。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/pending_moves.dart';

void main() {
  group('延后自定义值的范围校验（规范 §11.1 的"自定义约束"列）', () {
    test('分钟：1 与 1440 是边界内，0 与 1441 是边界外', () {
      expect(deferAmountIsValid(1, DeferUnit.minutes), isTrue);
      expect(deferAmountIsValid(1440, DeferUnit.minutes), isTrue);
      expect(deferAmountIsValid(0, DeferUnit.minutes), isFalse);
      expect(deferAmountIsValid(1441, DeferUnit.minutes), isFalse);
      expect(deferAmountIsValid(-5, DeferUnit.minutes), isFalse);
    });

    test('小时：1 与 72 是边界内，0 与 73 是边界外', () {
      expect(deferAmountIsValid(1, DeferUnit.hours), isTrue);
      expect(deferAmountIsValid(72, DeferUnit.hours), isTrue);
      expect(deferAmountIsValid(0, DeferUnit.hours), isFalse);
      expect(deferAmountIsValid(73, DeferUnit.hours), isFalse);
    });

    test('天：1 与 365 是边界内，0 与 366 是边界外', () {
      expect(deferAmountIsValid(1, DeferUnit.days), isTrue);
      expect(deferAmountIsValid(365, DeferUnit.days), isTrue);
      expect(deferAmountIsValid(0, DeferUnit.days), isFalse);
      expect(deferAmountIsValid(366, DeferUnit.days), isFalse);
    });
  });

  group('分钟按 5 分钟粒度**向上**对齐（规范 §11.1）', () {
    test('已经是 5 的倍数时不变', () {
      for (final value in const [5, 10, 15, 30, 45, 1440]) {
        expect(
          alignDeferAmount(value, DeferUnit.minutes),
          value,
          reason: '$value 本来就在粒度上，不该被改动',
        );
      }
    });

    test('不是 5 的倍数时**向上**取（而不是向下或就近）', () {
      expect(
        alignDeferAmount(1, DeferUnit.minutes),
        5,
        reason: '向上取；向下取会变成 0，那是"不延后"——与用户意图相反',
      );
      expect(alignDeferAmount(6, DeferUnit.minutes), 10);
      expect(alignDeferAmount(7, DeferUnit.minutes), 10);
      expect(alignDeferAmount(11, DeferUnit.minutes), 15);
      expect(alignDeferAmount(1441, DeferUnit.minutes), 1445);
    });

    test('**小时与天不受 5 分钟粒度影响**（粒度只属于分钟那一栏）', () {
      for (final value in const [1, 2, 3, 6, 72]) {
        expect(alignDeferAmount(value, DeferUnit.hours), value);
      }
      for (final value in const [1, 2, 3, 7, 365]) {
        expect(alignDeferAmount(value, DeferUnit.days), value);
      }
    });

    test('对齐不会把值降到 0 以下（1 分钟必须变成 5，不是 0）', () {
      // 这是"向上"的意义所在：整数除法写成 `value ~/ 5 * 5` 会把 1..4 变成 0，
      // 而 0 分钟延后等于没延后——用户点了确认却什么都没发生。
      for (final value in const [1, 2, 3, 4]) {
        final aligned = alignDeferAmount(value, DeferUnit.minutes);
        expect(aligned, 5);
        expect(aligned, greaterThan(0));
      }
    });
  });
}
