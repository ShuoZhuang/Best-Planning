final class TimeRange {
  TimeRange({required this.startUtc, required this.endUtc}) {
    if (!startUtc.isUtc || !endUtc.isUtc) {
      throw ArgumentError('TimeRange requires UTC DateTime values.');
    }
    if (!endUtc.isAfter(startUtc)) {
      throw ArgumentError('endUtc must be after startUtc.');
    }
  }

  final DateTime startUtc;
  final DateTime endUtc;

  Duration get duration => endUtc.difference(startUtc);
  int get durationMinutes => duration.inMinutes;

  bool contains(DateTime instantUtc) =>
      !instantUtc.isBefore(startUtc) && instantUtc.isBefore(endUtc);

  bool overlaps(TimeRange other) =>
      startUtc.isBefore(other.endUtc) && other.startUtc.isBefore(endUtc);

  TimeRange copyWith({DateTime? startUtc, DateTime? endUtc}) => TimeRange(
    startUtc: startUtc ?? this.startUtc,
    endUtc: endUtc ?? this.endUtc,
  );

  @override
  bool operator ==(Object other) =>
      other is TimeRange &&
      startUtc == other.startUtc &&
      endUtc == other.endUtc;

  @override
  int get hashCode => Object.hash(startUtc, endUtc);
}

final class LocalTimeRange {
  LocalTimeRange({required this.startMinute, required this.endMinute}) {
    if (startMinute < 0 || startMinute >= minutesPerDay) {
      throw ArgumentError.value(startMinute, 'startMinute');
    }
    if (endMinute < 0 || endMinute > minutesPerDay) {
      throw ArgumentError.value(endMinute, 'endMinute');
    }
    if (startMinute == endMinute) {
      throw ArgumentError('A local time range cannot have zero length.');
    }
  }

  static const int minutesPerDay = 24 * 60;

  final int startMinute;
  final int endMinute;

  bool get crossesMidnight => endMinute < startMinute;

  int get durationMinutes => crossesMidnight
      ? minutesPerDay - startMinute + endMinute
      : endMinute - startMinute;

  List<LocalDaySegment> splitAtMidnight() {
    if (!crossesMidnight) {
      return [
        LocalDaySegment(
          dayOffset: 0,
          startMinute: startMinute,
          endMinute: endMinute,
        ),
      ];
    }

    return [
      LocalDaySegment(
        dayOffset: 0,
        startMinute: startMinute,
        endMinute: minutesPerDay,
      ),
      if (endMinute > 0)
        LocalDaySegment(dayOffset: 1, startMinute: 0, endMinute: endMinute),
    ];
  }

  LocalTimeRange copyWith({int? startMinute, int? endMinute}) => LocalTimeRange(
    startMinute: startMinute ?? this.startMinute,
    endMinute: endMinute ?? this.endMinute,
  );

  @override
  bool operator ==(Object other) =>
      other is LocalTimeRange &&
      startMinute == other.startMinute &&
      endMinute == other.endMinute;

  @override
  int get hashCode => Object.hash(startMinute, endMinute);
}

final class LocalDaySegment {
  const LocalDaySegment({
    required this.dayOffset,
    required this.startMinute,
    required this.endMinute,
  }) : assert(dayOffset >= 0),
       assert(startMinute >= 0 && startMinute < LocalTimeRange.minutesPerDay),
       assert(
         endMinute > startMinute && endMinute <= LocalTimeRange.minutesPerDay,
       );

  final int dayOffset;
  final int startMinute;
  final int endMinute;

  @override
  bool operator ==(Object other) =>
      other is LocalDaySegment &&
      dayOffset == other.dayOffset &&
      startMinute == other.startMinute &&
      endMinute == other.endMinute;

  @override
  int get hashCode => Object.hash(dayOffset, startMinute, endMinute);
}
