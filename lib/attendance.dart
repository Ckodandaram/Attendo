import 'dart:math' as math;

enum AttendanceStatus {
  office('In office', 'Office'),
  remote('Remote', 'Remote'),
  pto('PTO', 'PTO'),
  holiday('Public holiday', 'Holiday'),
  sick('Sick leave', 'Sick');

  const AttendanceStatus(this.label, this.shortLabel);

  final String label;
  final String shortLabel;

  static AttendanceStatus fromValue(String value) =>
      AttendanceStatus.values.firstWhere((status) => status.name == value);
}

class AttendanceEntry {
  const AttendanceEntry({
    required this.date,
    required this.status,
    this.note = '',
  });

  final DateTime date;
  final AttendanceStatus status;
  final String note;

  String get dateKey => attendanceDateKey(date);

  factory AttendanceEntry.fromMap(Map<String, Object?> map) {
    final parts = (map['date']! as String).split('-').map(int.parse).toList();
    return AttendanceEntry(
      date: DateTime(parts[0], parts[1], parts[2]),
      status: AttendanceStatus.fromValue(map['status']! as String),
      note: map['note'] as String? ?? '',
    );
  }

  Map<String, Object?> toMap() => {
        'date': dateKey,
        'status': status.name,
        'note': note,
      };
}

String attendanceDateKey(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

class QuarterSummary {
  const QuarterSummary({
    required this.scheduledDays,
    required this.eligibleDays,
    required this.elapsedEligibleDays,
    required this.officeDays,
    required this.targetDays,
    required this.remainingOfficeDays,
    required this.suitableFutureDays,
  });

  final int scheduledDays;
  final int eligibleDays;
  final int elapsedEligibleDays;
  final int officeDays;
  final int targetDays;
  final int remainingOfficeDays;
  final int suitableFutureDays;

  double get attendanceRate =>
      eligibleDays == 0 ? 0 : officeDays / eligibleDays;

  int get attendanceRatePercent =>
      eligibleDays == 0 ? 0 : officeDays * 100 ~/ eligibleDays;

  double get targetProgress =>
      targetDays == 0 ? 1 : (officeDays / targetDays).clamp(0, 1).toDouble();

  bool get isAchievable => remainingOfficeDays <= suitableFutureDays;
}

DateTime quarterStart(DateTime date) {
  final firstMonth = ((date.month - 1) ~/ 3) * 3 + 1;
  return DateTime(date.year, firstMonth);
}

DateTime quarterEnd(DateTime date) {
  final start = quarterStart(date);
  return DateTime(start.year, start.month + 3, 0);
}

String quarterLabel(DateTime date) =>
    'Q${((date.month - 1) ~/ 3) + 1} ${date.year}';

QuarterSummary calculateQuarter({
  required DateTime quarter,
  required DateTime today,
  required Map<String, AttendanceEntry> entries,
  required Set<int> workdays,
  required int targetPercent,
}) {
  final start = quarterStart(quarter);
  final end = quarterEnd(quarter);
  var scheduled = 0;
  var excluded = 0;
  var elapsedEligible = 0;
  var office = 0;
  var suitableFuture = 0;
  final normalizedToday = DateTime(today.year, today.month, today.day);

  for (var day = start;
      !day.isAfter(end);
      day = day.add(const Duration(days: 1))) {
    if (!workdays.contains(day.weekday)) continue;
    scheduled++;
    final entry = entries[attendanceDateKey(day)];
    final isExcluded = entry?.status == AttendanceStatus.pto ||
        entry?.status == AttendanceStatus.holiday ||
        entry?.status == AttendanceStatus.sick;
    if (isExcluded) {
      excluded++;
      continue;
    }
    if (!day.isAfter(normalizedToday)) {
      elapsedEligible++;
      if (entry?.status == AttendanceStatus.office) office++;
    } else if (entry == null) {
      suitableFuture++;
    }
  }

  final eligible = scheduled - excluded;
  final target = (eligible * targetPercent / 100).ceil();
  return QuarterSummary(
    scheduledDays: scheduled,
    eligibleDays: eligible,
    elapsedEligibleDays: elapsedEligible,
    officeDays: office,
    targetDays: target,
    remainingOfficeDays: math.max(0, target - office),
    suitableFutureDays: suitableFuture,
  );
}
