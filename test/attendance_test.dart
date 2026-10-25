import 'package:attendo/attendance.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('quarter calculations', () {
    final q = DateTime(2026, 1);
    final workdays = {1, 2, 3, 4, 5};
    final today = DateTime(2026, 1, 9);

    test('rounds the target up and counts unique office dates', () {
      final entries = <String, AttendanceEntry>{
        '2026-01-05': AttendanceEntry(
          date: DateTime(2026, 1, 5),
          status: AttendanceStatus.office,
        ),
        '2026-01-06': AttendanceEntry(
          date: DateTime(2026, 1, 6),
          status: AttendanceStatus.office,
        ),
        '2026-01-07': AttendanceEntry(
          date: DateTime(2026, 1, 7),
          status: AttendanceStatus.pto,
        ),
        '2026-01-08': AttendanceEntry(
          date: DateTime(2026, 1, 8),
          status: AttendanceStatus.holiday,
        ),
      };
      final summary = calculateQuarter(
        quarter: q,
        today: today,
        entries: entries,
        workdays: workdays,
        targetPercent: 60,
      );

      expect(summary.scheduledDays, 64);
      expect(summary.eligibleDays, 62);
      expect(summary.targetDays, 38);
      expect(summary.officeDays, 2);
      expect(summary.remainingOfficeDays, 36);
      expect(summary.attendanceRatePercent, 3);
    });

    test('matches the 60 percent target example with 50 eligible days', () {
      final entries = <String, AttendanceEntry>{};
      var excludedDays = 0;
      var officeDays = 0;
      for (var date = DateTime(2026, 1, 1);
          !date.isAfter(DateTime(2026, 3, 31));
          date = date.add(const Duration(days: 1))) {
        if (!workdays.contains(date.weekday)) continue;
        final key =
            '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
        if (excludedDays < 14) {
          entries[key] = AttendanceEntry(
            date: date,
            status: excludedDays.isEven
                ? AttendanceStatus.pto
                : AttendanceStatus.holiday,
          );
          excludedDays++;
        } else if (officeDays < 18) {
          entries[key] = AttendanceEntry(
            date: date,
            status: AttendanceStatus.office,
          );
          officeDays++;
        }
      }
      final summary = calculateQuarter(
        quarter: q,
        today: DateTime(2026, 3, 31),
        entries: entries,
        workdays: workdays,
        targetPercent: 60,
      );

      expect(summary.eligibleDays, 50);
      expect(summary.targetDays, 30);
      expect(summary.officeDays, 18);
      expect(summary.remainingOfficeDays, 12);
      expect(summary.attendanceRatePercent, 36);
    });

    test('floors attendance rate to whole percentages of eligible days', () {
      final entries = <String, AttendanceEntry>{};
      var excludedDays = 0;
      var officeDays = 0;
      for (var date = DateTime(2026, 1, 1);
          !date.isAfter(DateTime(2026, 3, 31));
          date = date.add(const Duration(days: 1))) {
        if (!workdays.contains(date.weekday)) continue;
        if (excludedDays < 2) {
          entries[attendanceDateKey(date)] = AttendanceEntry(
            date: date,
            status: AttendanceStatus.pto,
          );
          excludedDays++;
        } else if (officeDays < 14) {
          entries[attendanceDateKey(date)] = AttendanceEntry(
            date: date,
            status: AttendanceStatus.office,
          );
          officeDays++;
        }
      }
      final summary = calculateQuarter(
        quarter: q,
        today: DateTime(2026, 3, 31),
        entries: entries,
        workdays: workdays,
        targetPercent: 60,
      );

      expect(summary.eligibleDays, 62);
      expect(summary.attendanceRate, 14 / 62);
      expect(summary.attendanceRatePercent, 22);
    });

    test('does not round fractional attendance percentages up', () {
      int percentage(int officeDays, int eligibleDays) => QuarterSummary(
            scheduledDays: eligibleDays,
            eligibleDays: eligibleDays,
            elapsedEligibleDays: eligibleDays,
            officeDays: officeDays,
            targetDays: 0,
            remainingOfficeDays: 0,
            suitableFutureDays: 0,
          ).attendanceRatePercent;

      expect(percentage(37, 62), 59);
      expect(percentage(35, 62), 56);
      expect(percentage(49, 62), 79);
    });

    test('ignores a holiday on a non-working day', () {
      final entries = {
        '2026-01-04': AttendanceEntry(
          date: DateTime(2026, 1, 4),
          status: AttendanceStatus.holiday,
        ),
      };
      final summary = calculateQuarter(
        quarter: q,
        today: today,
        entries: entries,
        workdays: workdays,
        targetPercent: 60,
      );

      expect(summary.eligibleDays, summary.scheduledDays);
    });

    test('excludes sick leave from eligible workdays and target', () {
      final entries = {
        '2026-01-05': AttendanceEntry(
          date: DateTime(2026, 1, 5),
          status: AttendanceStatus.pto,
        ),
        '2026-01-06': AttendanceEntry(
          date: DateTime(2026, 1, 6),
          status: AttendanceStatus.holiday,
        ),
        '2026-01-07': AttendanceEntry(
          date: DateTime(2026, 1, 7),
          status: AttendanceStatus.sick,
        ),
      };
      final summary = calculateQuarter(
        quarter: q,
        today: today,
        entries: entries,
        workdays: workdays,
        targetPercent: 60,
      );

      expect(summary.scheduledDays, 64);
      expect(summary.eligibleDays, 61);
      expect(summary.targetDays, 37);
      expect(summary.officeDays, 0);
    });

    test('uses a zero-safe rate and treats a zero target as met', () {
      final summary = calculateQuarter(
        quarter: q,
        today: DateTime(2025, 12, 1),
        entries: const {},
        workdays: const {},
        targetPercent: 60,
      );

      expect(summary.targetDays, 0);
      expect(summary.attendanceRate, 0);
      expect(summary.targetProgress, 1);
    });
  });
}
