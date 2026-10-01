import 'dart:math' as math;

import 'package:personal_planner/scheduling/schedule_problem.dart';

final class CapacityModel {
  const CapacityModel({
    required this.horizonCapacityMinutes,
    required this.capacityAfterHorizonBeforeDueMinutes,
    this.evaluatedUntilUtc,
  }) : assert(horizonCapacityMinutes >= 0),
       assert(capacityAfterHorizonBeforeDueMinutes >= 0);

  static const int maximumExpansionDays = 180;

  final int horizonCapacityMinutes;
  final int capacityAfterHorizonBeforeDueMinutes;
  final DateTime? evaluatedUntilUtc;

  int get capacityUntilDueMinutes =>
      horizonCapacityMinutes + capacityAfterHorizonBeforeDueMinutes;

  factory CapacityModel.estimate({
    required DateTime nowUtc,
    required DateTime horizonEndUtc,
    required DateTime dueAtUtc,
    required int Function(DateTime startUtc, DateTime endUtc) capacityForRange,
  }) {
    _requireUtc(nowUtc, 'nowUtc');
    _requireUtc(horizonEndUtc, 'horizonEndUtc');
    _requireUtc(dueAtUtc, 'dueAtUtc');
    final expansionLimit = nowUtc.add(
      const Duration(days: maximumExpansionDays),
    );
    final evaluatedUntil = dueAtUtc.isBefore(expansionLimit)
        ? dueAtUtc
        : expansionLimit;
    final effectiveHorizonEnd = horizonEndUtc.isBefore(evaluatedUntil)
        ? horizonEndUtc
        : evaluatedUntil;

    final horizonCapacity = effectiveHorizonEnd.isAfter(nowUtc)
        ? capacityForRange(nowUtc, effectiveHorizonEnd)
        : 0;
    final futureCapacity = evaluatedUntil.isAfter(effectiveHorizonEnd)
        ? capacityForRange(effectiveHorizonEnd, evaluatedUntil)
        : 0;
    if (horizonCapacity < 0 || futureCapacity < 0) {
      throw ArgumentError('Capacity estimates cannot be negative.');
    }
    return CapacityModel(
      horizonCapacityMinutes: horizonCapacity,
      capacityAfterHorizonBeforeDueMinutes: futureCapacity,
      evaluatedUntilUtc: evaluatedUntil,
    );
  }
}

final class DeadlinePressure {
  const DeadlinePressure({
    required this.requiredNowMinutes,
    required this.pacedNowMinutes,
    required this.targetMinutes,
    required this.hasDeadlinePressure,
  });

  const DeadlinePressure.none()
    : requiredNowMinutes = 0,
      pacedNowMinutes = 0,
      targetMinutes = 0,
      hasDeadlinePressure = false;

  final int requiredNowMinutes;
  final int pacedNowMinutes;
  final int targetMinutes;
  final bool hasDeadlinePressure;
}

final class PressureCalculator {
  const PressureCalculator();

  DeadlinePressure calculate(SchedulableTask task, CapacityModel capacity) {
    if (task.dueAtUtc == null) return const DeadlinePressure.none();

    final requiredNow = math.max(
      0,
      task.requiredMinutes - capacity.capacityAfterHorizonBeforeDueMinutes,
    );
    final totalCapacity = capacity.capacityUntilDueMinutes;
    final pacedNow = totalCapacity == 0
        ? task.requiredMinutes
        : _ceilDivide(
            task.requiredMinutes * capacity.horizonCapacityMinutes,
            totalCapacity,
          );
    return DeadlinePressure(
      requiredNowMinutes: requiredNow,
      pacedNowMinutes: pacedNow,
      targetMinutes: math.min(
        task.requiredMinutes,
        math.max(requiredNow, pacedNow),
      ),
      hasDeadlinePressure: true,
    );
  }
}

int _ceilDivide(int numerator, int denominator) =>
    (numerator + denominator - 1) ~/ denominator;

void _requireUtc(DateTime value, String name) {
  if (!value.isUtc) {
    throw ArgumentError.value(value, name, 'Must be UTC.');
  }
}
