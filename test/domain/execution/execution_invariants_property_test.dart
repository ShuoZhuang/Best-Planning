import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/execution/execution_fragment.dart';
import 'package:personal_planner/domain/execution/execution_progress.dart';
import 'package:personal_planner/scheduling/recurring_pace_curve.dart';

void main() {
  test('进度守恒：剩余非负，剩余+有效投入恰好等于承诺量', () {
    for (var allocated = 0; allocated <= 120; allocated += 7) {
      for (var credited = 0; credited <= 150; credited += 13) {
        final allocatedMicros = allocated * 60000000;
        final creditedMicros = credited * 60000000;
        final effectiveCredit = credited > allocated ? allocated : credited;
        final remainingMicros = allocatedMicros - effectiveCredit * 60000000;
        expect(remainingMicros, greaterThanOrEqualTo(0));
        expect(remainingMicros + effectiveCredit * 60000000, allocatedMicros);
        expect(
          executionSchedulingMinutes(remainingMicros),
          remainingMicros % 60000000 == 0
              ? remainingMicros ~/ 60000000
              : remainingMicros ~/ 60000000 + 1,
        );
        expect(
          executionOverdrawnMicros(
            allocatedMicros: allocatedMicros,
            creditedMicros: creditedMicros,
          ),
          (credited > allocated ? credited - allocated : 0) * 60000000,
        );
      }
    }
  });

  test('片段有效投入永不超过承诺量', () {
    for (var allocated = 0; allocated <= 100; allocated += 11) {
      for (var real = 0; real <= 120; real += 17) {
        for (var declared = 0; declared <= 90; declared += 19) {
          final effective = fragmentEffectiveMicros(
            realCreditedMicros: real,
            declaredMicros: declared,
            allocatedMicros: allocated,
          );
          expect(effective, lessThanOrEqualTo(allocated));
        }
      }
    }
  });

  test('节奏目标始终位于 requiredNow 与剩余量之间', () {
    for (var remaining = 0; remaining <= 180; remaining += 20) {
      for (var visible = 0; visible <= 120; visible += 30) {
        for (var after = 0; after <= 120; after += 30) {
          for (final curve in RecurringPaceCurve.values) {
            final decision = recurringPaceDecision(
              remainingMinutes: remaining,
              visibleCapacityMinutes: visible,
              afterCapacityMinutes: after,
              curve: curve,
            );
            expect(decision.targetNowMinutes, greaterThanOrEqualTo(0));
            expect(decision.targetNowMinutes, lessThanOrEqualTo(remaining));
            if (!decision.noCapacity) {
              expect(
                decision.targetNowMinutes,
                greaterThanOrEqualTo(decision.requiredNowMinutes),
              );
            }
          }
        }
      }
    }
  });
}
