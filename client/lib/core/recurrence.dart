import 'dart:math' as math;

import 'package:lunar/lunar.dart';

import 'models.dart';

class RecurrenceException implements Exception {
  final String message;
  const RecurrenceException(this.message);
  @override
  String toString() => message;
}

DateTime dateOnly(DateTime date) => DateTime(date.year, date.month, date.day);
DateTime addCalendarDays(DateTime date, int days) =>
    DateTime(date.year, date.month, date.day + days);
int calendarDaysBetween(DateTime first, DateTime second) => DateTime.utc(
  second.year,
  second.month,
  second.day,
).difference(DateTime.utc(first.year, first.month, first.day)).inDays;

RecurrenceRule recurrenceFor(TaskItem task) =>
    task.recurrenceRule ??
    RecurrenceRule(frequency: task.recurrence, anchorDate: task.dueDate);

class NextOccurrence {
  final DateTime date;
  final DateTime? endDate;
  final RecurrenceRule rule;
  const NextOccurrence(this.date, this.endDate, this.rule);
}

const recurrenceFrequencies = {
  'none',
  'daily',
  'weekly',
  'monthly',
  'yearly',
  'workdays',
  'holidays',
  'lunar',
  'ebbinghaus',
  'dates',
};

void validateRecurrence(RecurrenceRule rule) {
  void check(bool condition, String message) {
    if (!condition) throw RecurrenceException(message);
  }

  check(recurrenceFrequencies.contains(rule.frequency), '无法识别此重复规则。');
  check(rule.interval >= 1 && rule.interval <= 999, '重复间隔须为 1–999。');
  check(rule.occurrence >= 1, '重复次数无效。');
  check(rule.count == null || rule.count! >= 1, '终止次数须大于 0。');
  check(['due', 'completion'].contains(rule.basis), '重复依据无效。');
  check(rule.weekdays.every((d) => d >= 1 && d <= 7), '星期须为周一到周日。');
  check(rule.monthDays.every((d) => d >= 1 && d <= 31), '日期须为 1–31 日。');
  check(rule.month == null || (rule.month! >= 1 && rule.month! <= 12), '月份无效。');
  check(
    rule.ordinal == null ||
        rule.ordinal == -1 ||
        (rule.ordinal! >= 1 && rule.ordinal! <= 5),
    '每月第几周无效。',
  );
  check(
    (rule.ordinal == null) == (rule.ordinalWeekday == null),
    '请选择每月第几周和星期。',
  );
  check(
    rule.ordinalWeekday == null ||
        (rule.ordinalWeekday! >= 1 && rule.ordinalWeekday! <= 7),
    '星期无效。',
  );
  check(['weekdays', 'china2026'].contains(rule.workdayMode), '工作日模式无效。');
  check(['yearly', 'monthly'].contains(rule.lunarMode), '农历重复单位无效。');
  check(
    rule.lunarMonth == null ||
        (rule.lunarMonth! >= 1 && rule.lunarMonth! <= 12),
    '农历月份无效。',
  );
  check(
    rule.lunarDay == null || (rule.lunarDay! >= 1 && rule.lunarDay! <= 30),
    '农历日期无效。',
  );
  if (rule.frequency == 'ebbinghaus') {
    check(
      rule.reviewDays.isNotEmpty &&
          rule.reviewDays.first == 1 &&
          rule.reviewDays.every((d) => d >= 1 && d <= 3650) &&
          List.generate(
            rule.reviewDays.length - 1,
            (i) => rule.reviewDays[i + 1] > rule.reviewDays[i],
          ).every((v) => v),
      '复习日须从第 1 天开始并递增。',
    );
  }
  if (rule.frequency == 'dates') {
    check(rule.dates.isNotEmpty, '请至少选择一个重复日期。');
  }
}

/// Returns the successor only when the present occurrence is completed.
/// The caller persists [NextOccurrence.rule] with the successor, retaining the
/// original monthly/lunar anchor even when this month has fewer days.
NextOccurrence? nextOccurrence(TaskItem task, {required DateTime completedAt}) {
  if (task.itemType == 'note') return null;
  var rule = recurrenceFor(task);
  validateRecurrence(rule);
  if (rule.frequency == 'none') return null;
  if (rule.count != null && rule.occurrence >= rule.count!) return null;
  final current = dateOnly(task.dueDate ?? completedAt);
  final anchor = dateOnly(rule.anchorDate ?? current);
  rule = rule.copyWith(anchorDate: anchor);
  final base = rule.basis == 'completion' ? dateOnly(completedAt) : current;
  if (rule.until != null && !dateOnly(rule.until!).isAfter(base)) return null;
  DateTime? next;
  if (rule.basis == 'completion' &&
      ['daily', 'weekly', 'monthly', 'yearly'].contains(rule.frequency)) {
    next = switch (rule.frequency) {
      'daily' => addCalendarDays(base, rule.interval),
      'weekly' => addCalendarDays(base, 7 * rule.interval),
      'monthly' => _monthDate(base.year, base.month + rule.interval, base.day),
      _ => _monthDate(base.year + rule.interval, base.month, base.day),
    };
  } else {
    switch (rule.frequency) {
      case 'daily':
        next = addCalendarDays(base, rule.interval);
      case 'weekly':
        final weekdays = rule.weekdays.isEmpty
            ? [anchor.weekday]
            : rule.weekdays;
        final weekAnchor = addCalendarDays(anchor, 1 - anchor.weekday);
        for (var i = 1; i <= rule.interval * 7 + 7; i++) {
          final d = addCalendarDays(base, i);
          final weeks = (calendarDaysBetween(weekAnchor, d) / 7).floor();
          if (weeks % rule.interval == 0 && weekdays.contains(d.weekday)) {
            next = d;
            break;
          }
        }
      case 'monthly':
        final start = base.year * 12 + base.month - 1;
        final first = anchor.year * 12 + anchor.month - 1;
        // Fifth weekdays can be absent. Search only matching calendar months.
        for (var offset = 0; offset <= rule.interval * 24; offset++) {
          final index = start + offset;
          if ((index - first) % rule.interval != 0) continue;
          next = _candidateInMonth(
            index ~/ 12,
            index % 12 + 1,
            rule,
            anchor.day,
          ).where((d) => d.isAfter(base)).firstOrNull;
          if (next != null) break;
        }
      case 'yearly':
        for (
          var year = base.year;
          year <= base.year + rule.interval * 400;
          year++
        ) {
          if ((year - anchor.year) % rule.interval != 0) continue;
          next = _candidateInMonth(
            year,
            rule.month ?? anchor.month,
            rule,
            anchor.day,
          ).where((d) => d.isAfter(base)).firstOrNull;
          if (next != null) break;
        }
      case 'workdays':
      case 'holidays':
        var remaining = rule.interval;
        for (var i = 1; i <= 370 * rule.interval; i++) {
          final d = addCalendarDays(base, i);
          if (rule.until != null && d.isAfter(dateOnly(rule.until!))) {
            return null;
          }
          final matches = rule.workdayMode == 'china2026'
              ? (rule.frequency == 'workdays'
                    ? isChinaWorkday2026(d)
                    : isChinaHoliday2026(d))
              : (rule.frequency == 'workdays'
                    ? d.weekday <= 5
                    : d.weekday >= 6);
          if (matches && --remaining == 0) {
            next = d;
            break;
          }
        }
      case 'lunar':
        next = _nextLunar(base, anchor, rule);
      case 'ebbinghaus':
        final index = rule.occurrence;
        final reviews = rule.reviewDays;
        final nextOffset = index < reviews.length
            ? reviews[index] - 1
            : reviews.last - 1 + (index - reviews.length + 1) * reviews.last;
        final previousOffset = index - 1 < reviews.length
            ? reviews[index - 1] - 1
            : reviews.last - 1 + (index - reviews.length) * reviews.last;
        next = rule.basis == 'completion'
            ? addCalendarDays(base, nextOffset - previousOffset)
            : addCalendarDays(anchor, nextOffset);
        // A manually postponed occurrence must still advance in time.
        if (!next.isAfter(base)) {
          next = addCalendarDays(base, nextOffset - previousOffset);
        }
      case 'dates':
        final dates = rule.dates.map(dateOnly).toSet().toList()..sort();
        next = dates.where((d) => d.isAfter(base)).firstOrNull;
    }
  }
  if (next == null) return null;
  if (rule.until != null && next.isAfter(dateOnly(rule.until!))) return null;
  final end = task.endDate == null
      ? null
      : addCalendarDays(
          next,
          math.max(0, calendarDaysBetween(current, task.endDate!)),
        );
  return NextOccurrence(
    next,
    end,
    rule.copyWith(occurrence: rule.occurrence + 1),
  );
}

DateTime _monthDate(int year, int month, int day) {
  final normalized = DateTime(year, month, 1);
  final maxDay = DateTime(normalized.year, normalized.month + 1, 0).day;
  return DateTime(normalized.year, normalized.month, math.min(day, maxDay));
}

List<DateTime> _candidateInMonth(
  int year,
  int month,
  RecurrenceRule rule,
  int day,
) {
  if (rule.ordinal != null && rule.ordinalWeekday != null) {
    final last = DateTime(year, month + 1, 0);
    if (rule.ordinal == -1) {
      return [
        DateTime(
          year,
          month,
          last.day - (last.weekday - rule.ordinalWeekday! + 7) % 7,
        ),
      ];
    }
    final first = DateTime(year, month);
    final d =
        1 +
        (rule.ordinalWeekday! - first.weekday + 7) % 7 +
        (rule.ordinal! - 1) * 7;
    return d <= last.day ? [DateTime(year, month, d)] : [];
  }
  return (rule.monthDays.isEmpty ? [day] : rule.monthDays)
      .map((d) => _monthDate(year, month, d))
      .toSet()
      .toList()
    ..sort();
}

DateTime? _nextLunar(DateTime base, DateTime anchor, RecurrenceRule rule) {
  // Deliberately bound the supported UI range instead of implying an unlimited
  // astronomical calculation guarantee.
  if (base.year < 1901 || base.year > 2099) {
    throw const RecurrenceException('农历重复支持公历 1901–2099 年。');
  }
  final origin = Lunar.fromDate(anchor);
  final from = Lunar.fromDate(base);
  final day = rule.lunarDay ?? origin.getDay();
  final month = rule.lunarMonth ?? origin.getMonth().abs();
  DateTime solarDate(LunarMonth m) {
    final solar = Lunar.fromYmd(
      m.getYear(),
      m.getMonth(),
      math.min(day, m.getDayCount()),
    ).getSolar();
    return DateTime(solar.getYear(), solar.getMonth(), solar.getDay());
  }

  if (rule.lunarMode == 'monthly') {
    // Every lunar month includes leap months. Interval counts real lunar months.
    var index = 0;
    for (var year = origin.getYear(); year <= 2099; year++) {
      for (final m in LunarYear.fromYear(year).getMonthsInYear()) {
        if (year == origin.getYear() &&
            m.getFirstJulianDay() <
                LunarMonth.fromYm(
                  origin.getYear(),
                  origin.getMonth(),
                )!.getFirstJulianDay()) {
          continue;
        }
        final d = solarDate(m);
        if (index % rule.interval == 0 && d.isAfter(base) && d.year <= 2099) {
          return d;
        }
        index++;
      }
    }
  } else {
    for (var year = from.getYear(); year <= 2099; year++) {
      if ((year - origin.getYear()) % rule.interval != 0) continue;
      final m = LunarMonth.fromYm(year, rule.lunarLeap ? -month : month);
      if (m == null) {
        continue; // A selected leap month only exists in some years.
      }
      final d = solarDate(m);
      if (d.isAfter(base) && d.year <= 2099) return d;
    }
  }
  throw const RecurrenceException('后续农历日期超出 1901–2099 年支持范围。');
}

/// 国务院办公厅 国办发明电〔2025〕7号，2025-11-04。
/// https://www.gov.cn/zhengce/content/202511/content_7047090.htm
/// Ranges are published days off, including adjoining weekends. Ordinary
/// weekends outside these ranges are not described as statutory holidays.
const _chinaHolidayRanges2026 = [
  [1, 1, 1, 3],
  [2, 15, 2, 23],
  [4, 4, 4, 6],
  [5, 1, 5, 5],
  [6, 19, 6, 21],
  [9, 25, 9, 27],
  [10, 1, 10, 7],
];
const _chinaWorkingWeekends2026 = {
  '01-04',
  '02-14',
  '02-28',
  '05-09',
  '09-20',
  '10-10',
};

void _requireChina2026(DateTime date) {
  if (date.year != 2026) {
    throw const RecurrenceException(
      '中国调休数据目前仅覆盖 2026 年。请改用周一至周五 / 每周末，或将结束日期设为 2026-12-31。',
    );
  }
}

bool isChinaHoliday2026(DateTime date) {
  _requireChina2026(date);
  final day = dateOnly(date);
  return _chinaHolidayRanges2026.any(
    (r) =>
        !day.isBefore(DateTime(2026, r[0], r[1])) &&
        !day.isAfter(DateTime(2026, r[2], r[3])),
  );
}

bool isChinaWorkday2026(DateTime date) {
  _requireChina2026(date);
  if (_chinaWorkingWeekends2026.contains(calendarDate(date)!.substring(5))) {
    return true;
  }
  return date.weekday <= 5 && !isChinaHoliday2026(date);
}

String recurrenceLabel(RecurrenceRule rule) {
  final interval = rule.interval;
  final unit = switch (rule.frequency) {
    'daily' => interval == 1 ? '每天' : '每 $interval 天',
    'weekly' => interval == 1 ? '每周' : '每 $interval 周',
    'monthly' => interval == 1 ? '每月' : '每 $interval 个月',
    'yearly' => interval == 1 ? '每年' : '每 $interval 年',
    'workdays' => rule.workdayMode == 'china2026' ? '中国工作日 · 2026' : '周一至周五',
    'holidays' => rule.workdayMode == 'china2026' ? '中国放假日 · 2026' : '每周末',
    'lunar' => rule.lunarMode == 'monthly' ? '农历每月' : '农历每年',
    'ebbinghaus' => '艾宾浩斯记忆法',
    'dates' => '自选日期 · ${rule.dates.length} 天',
    _ => '不重复',
  };
  return unit;
}

List<DateTime> previewOccurrences(
  TaskItem task, {
  int limit = 3,
  DateTime? completedAt,
}) {
  final result = <DateTime>[];
  var current = task;
  for (var i = 0; i < limit; i++) {
    final next = nextOccurrence(
      current,
      completedAt: i == 0
          ? (completedAt ?? current.dueDate ?? DateTime.now())
          : current.dueDate!,
    );
    if (next == null) break;
    result.add(next.date);
    current = current.copyWith(
      dueDate: next.date,
      endDate: next.endDate,
      recurrenceRule: next.rule,
    );
  }
  return result;
}
