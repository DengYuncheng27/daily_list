import 'package:dayflow/core/app_controller.dart';
import 'package:dayflow/core/models.dart';
import 'package:dayflow/core/recurrence.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lunar/lunar.dart';

import 'core_controller_test.dart' show MemoryStorage;

TaskItem task(DateTime date, RecurrenceRule rule, {DateTime? end}) => TaskItem(
  id: 'recurring',
  title: 'Review',
  dueDate: date,
  endDate: end,
  dueTime: '09:00',
  endTime: end == null ? null : '10:00',
  recurrenceRule: rule,
);

List<DateTime> sequence(TaskItem task, int length) =>
    previewOccurrences(task, limit: length);

void main() {
  test(
    'extended task and rule DTO round trip, nullable clear keeps old defaults',
    () {
      final original =
          task(
            DateTime(2026, 10, 20),
            RecurrenceRule(
              frequency: 'dates',
              dates: [DateTime(2026, 10, 22)],
              count: 5,
              until: DateTime(2027),
              lunarMode: 'monthly',
            ),
            end: DateTime(2026, 10, 22),
          ).copyWith(
            itemType: 'note',
            richContent: [
              {'insert': 'hello\n'},
            ],
            attachments: const [
              AttachmentItem(
                id: 'a',
                name: 'a.txt',
                mimeType: 'text/plain',
                sha256: 'a',
                size: 1,
              ),
            ],
          );
      final restored = TaskItem.fromEntity(original.toEntity());
      expect(restored.toPayload(), original.toPayload());
      expect(
        restored
            .copyWith(endDate: null, endTime: null, recurrenceRule: null)
            .endDate,
        isNull,
      );
      expect(
        TaskItem.fromEntity({
          'id': 'old',
          'payload': {'title': 'old'},
        }).itemType,
        'task',
      );
      expect(
        restored.recurrenceRule!.copyWith(count: null, until: null).count,
        isNull,
      );
    },
  );

  test('monthly clamp retains 31st intent across February', () {
    expect(
      sequence(
        task(DateTime(2026, 1, 31), const RecurrenceRule(frequency: 'monthly')),
        3,
      ),
      [DateTime(2026, 2, 28), DateTime(2026, 3, 31), DateTime(2026, 4, 30)],
    );
  });

  test('monthly multiple dates deduplicate clamped days', () {
    expect(
      sequence(
        task(
          DateTime(2026, 2, 1),
          const RecurrenceRule(frequency: 'monthly', monthDays: [15, 30, 31]),
        ),
        4,
      ),
      [
        DateTime(2026, 2, 15),
        DateTime(2026, 2, 28),
        DateTime(2026, 3, 15),
        DateTime(2026, 3, 30),
      ],
    );
  });

  test('nth weekday skips missing fifth, last weekday remains in month', () {
    expect(
      sequence(
        task(
          DateTime(2026, 1, 1),
          const RecurrenceRule(
            frequency: 'monthly',
            ordinal: 5,
            ordinalWeekday: 1,
          ),
        ),
        2,
      ),
      [DateTime(2026, 3, 30), DateTime(2026, 6, 29)],
    );
    expect(
      sequence(
        task(
          DateTime(2026, 1, 1),
          const RecurrenceRule(
            frequency: 'monthly',
            ordinal: -1,
            ordinalWeekday: 5,
          ),
        ),
        2,
      ),
      [DateTime(2026, 1, 30), DateTime(2026, 2, 27)],
    );
  });

  test('weekly multiple weekdays stay on the anchored alternating week', () {
    expect(
      sequence(
        task(
          DateTime(2026, 10, 19),
          const RecurrenceRule(
            frequency: 'weekly',
            interval: 2,
            weekdays: [1, 3, 5],
          ),
        ),
        5,
      ),
      [
        DateTime(2026, 10, 21),
        DateTime(2026, 10, 23),
        DateTime(2026, 11, 2),
        DateTime(2026, 11, 4),
        DateTime(2026, 11, 6),
      ],
    );
  });

  test('yearly leap-day and selected month preserve desired dates', () {
    expect(
      sequence(
        task(DateTime(2024, 2, 29), const RecurrenceRule(frequency: 'yearly')),
        4,
      ),
      [
        DateTime(2025, 2, 28),
        DateTime(2026, 2, 28),
        DateTime(2027, 2, 28),
        DateTime(2028, 2, 29),
      ],
    );
    expect(
      sequence(
        task(
          DateTime(2026, 1, 1),
          const RecurrenceRule(frequency: 'yearly', month: 12, monthDays: [25]),
        ),
        1,
      ),
      [DateTime(2026, 12, 25)],
    );
  });

  test(
    'completion basis uses the real completion date and calendar interval',
    () {
      final next = nextOccurrence(
        task(
          DateTime(2026, 1, 1),
          const RecurrenceRule(
            frequency: 'monthly',
            basis: 'completion',
            monthDays: [1],
          ),
        ),
        completedAt: DateTime(2026, 1, 3, 21),
      );
      expect(next!.date, DateTime(2026, 2, 3));
      expect(
        nextOccurrence(
          task(
            DateTime(2026, 10, 20),
            const RecurrenceRule(
              frequency: 'daily',
              interval: 3,
              basis: 'completion',
            ),
          ),
          completedAt: DateTime(2026, 10, 24),
        )!.date,
        DateTime(2026, 10, 27),
      );
    },
  );

  test('end date is inclusive and total count includes current occurrence', () {
    expect(
      sequence(
        task(
          DateTime(2026, 1, 1),
          const RecurrenceRule(frequency: 'daily', count: 3),
        ),
        10,
      ),
      [DateTime(2026, 1, 2), DateTime(2026, 1, 3)],
    );
    expect(
      sequence(
        task(
          DateTime(2026, 1, 1),
          RecurrenceRule(frequency: 'daily', until: DateTime(2026, 1, 3)),
        ),
        10,
      ),
      [DateTime(2026, 1, 2), DateTime(2026, 1, 3)],
    );
  });

  test('duration keeps civil day span and end time is independent', () {
    final next = nextOccurrence(
      task(
        DateTime(2026, 3, 7),
        const RecurrenceRule(frequency: 'weekly'),
        end: DateTime(2026, 3, 9),
      ),
      completedAt: DateTime(2026, 3, 7),
    );
    expect(next!.date, DateTime(2026, 3, 14));
    expect(next.endDate, DateTime(2026, 3, 16));
  });

  test(
    'China 2026 respects every published working weekend and holiday block',
    () {
      for (final d in [
        DateTime(2026, 1, 4),
        DateTime(2026, 2, 14),
        DateTime(2026, 2, 28),
        DateTime(2026, 5, 9),
        DateTime(2026, 9, 20),
        DateTime(2026, 10, 10),
      ]) {
        expect(isChinaWorkday2026(d), isTrue, reason: '$d');
      }
      for (final d in [
        DateTime(2026, 1, 1),
        DateTime(2026, 2, 23),
        DateTime(2026, 4, 6),
        DateTime(2026, 5, 5),
        DateTime(2026, 6, 19),
        DateTime(2026, 9, 25),
        DateTime(2026, 10, 7),
      ]) {
        expect(isChinaHoliday2026(d), isTrue, reason: '$d');
        expect(isChinaWorkday2026(d), isFalse, reason: '$d');
      }
      expect(
        sequence(
          task(
            DateTime(2026, 2, 14),
            const RecurrenceRule(
              frequency: 'workdays',
              workdayMode: 'china2026',
            ),
          ),
          1,
        ),
        [DateTime(2026, 2, 24)],
      );
      expect(
        sequence(
          task(
            DateTime(2026, 10, 9),
            const RecurrenceRule(
              frequency: 'workdays',
              workdayMode: 'china2026',
            ),
          ),
          1,
        ),
        [DateTime(2026, 10, 10)],
      );
    },
  );

  test('official holiday data has an explicit boundary and a finite schedule can end', () {
    final t = task(
      DateTime(2026, 12, 31),
      const RecurrenceRule(frequency: 'workdays', workdayMode: 'china2026'),
    );
    expect(
      () => nextOccurrence(t, completedAt: t.dueDate!),
      throwsA(isA<RecurrenceException>()),
    );
    expect(
      nextOccurrence(
        t.copyWith(
          recurrenceRule: t.recurrenceRule!.copyWith(
            until: DateTime(2026, 12, 31),
          ),
        ),
        completedAt: t.dueDate!,
      ),
      isNull,
    );
    expect(
      sequence(
        task(
          DateTime(2026, 12, 31),
          const RecurrenceRule(frequency: 'workdays'),
        ),
        1,
      ),
      [DateTime(2027, 1, 1)],
    );
  });

  test('weekend and official holiday repeats have different meanings', () {
    expect(
      sequence(
        task(
          DateTime(2026, 10, 8),
          const RecurrenceRule(frequency: 'holidays'),
        ),
        2,
      ),
      [DateTime(2026, 10, 10), DateTime(2026, 10, 11)],
    );
    expect(
      sequence(
        task(
          DateTime(2026, 9, 20),
          const RecurrenceRule(frequency: 'holidays', workdayMode: 'china2026'),
        ),
        2,
      ),
      [DateTime(2026, 9, 25), DateTime(2026, 9, 26)],
    );
  });

  test(
    'annual lunar mid-autumn conversion and monthly recurrence are real',
    () {
      expect(
        sequence(
          task(
            DateTime(2025, 10, 6),
            const RecurrenceRule(
              frequency: 'lunar',
              lunarMonth: 8,
              lunarDay: 15,
            ),
          ),
          1,
        ),
        [DateTime(2026, 9, 25)],
      );
      final dates = sequence(
        task(
          DateTime(2026, 2, 17),
          const RecurrenceRule(
            frequency: 'lunar',
            lunarMode: 'monthly',
            lunarDay: 1,
          ),
        ),
        3,
      );
      expect(dates.first, DateTime(2026, 3, 19));
      expect(dates.map((d) => Lunar.fromDate(d).getDay()), [1, 1, 1]);
      expect(dates.map((d) => Lunar.fromDate(d).getMonth()), [2, 3, 4]);
    },
  );

  test('lunar leap month skips years without that month, monthly includes leap month', () {
    final initial = Lunar.fromYmd(2025, 6, 1).getSolar();
    final date = DateTime(
      initial.getYear(),
      initial.getMonth(),
      initial.getDay(),
    );
    final next = sequence(
      task(
        date,
        const RecurrenceRule(
          frequency: 'lunar',
          lunarMode: 'monthly',
          lunarDay: 1,
        ),
      ),
      2,
    );
    expect(Lunar.fromDate(next[0]).getMonth(), -6);
    expect(Lunar.fromDate(next[1]).getMonth(), 7);
    final yearly = sequence(
      task(
        date,
        const RecurrenceRule(
          frequency: 'lunar',
          lunarMonth: 6,
          lunarDay: 1,
          lunarLeap: true,
        ),
      ),
      2,
    );
    expect(yearly.map((d) => Lunar.fromDate(d).getMonth()), [-6, -6]);
    expect(yearly[1].year, greaterThan(2026));
  });

  test('Ebbinghaus uses study-day numbers then repeating 15-day gaps', () {
    expect(
      sequence(
        task(
          DateTime(2026, 1, 1),
          const RecurrenceRule(frequency: 'ebbinghaus'),
        ),
        6,
      ),
      [
        DateTime(2026, 1, 2),
        DateTime(2026, 1, 4),
        DateTime(2026, 1, 7),
        DateTime(2026, 1, 15),
        DateTime(2026, 1, 30),
        DateTime(2026, 2, 14),
      ],
    );
  });

  test('custom dates sort, deduplicate, skip past entries and terminate', () {
    expect(
      sequence(
        task(
          DateTime(2026, 10, 20),
          RecurrenceRule(
            frequency: 'dates',
            dates: [
              DateTime(2026, 11, 3),
              DateTime(2026, 10, 25),
              DateTime(2026, 10, 1),
              DateTime(2026, 10, 25),
            ],
          ),
        ),
        10,
      ),
      [DateTime(2026, 10, 25), DateTime(2026, 11, 3)],
    );
  });

  test('note conversion cannot generate recurring completions', () async {
    final app = AppController(storage: MemoryStorage());
    addTearDown(app.dispose);
    await app.enterDemo();
    final note = task(
      DateTime(2026, 1, 1),
      const RecurrenceRule(frequency: 'daily'),
    ).copyWith(itemType: 'note');
    await app.saveTask(note);
    await app.toggleTask(note.id);
    await app.saveTask(note.copyWith(completed: true));
    expect(app.getTask(note.id)!.completed, isFalse);
    expect(app.tasks.where((t) => t.title == note.title), hasLength(1));
  });

  test(
    'unsupported next official year leaves task and outbox unchanged',
    () async {
      final app = AppController(storage: MemoryStorage());
      addTearDown(app.dispose);
      await app.enterDemo();
      final t = task(
        DateTime(2026, 12, 31),
        const RecurrenceRule(frequency: 'workdays', workdayMode: 'china2026'),
      );
      await app.saveTask(t);
      final count = app.pendingCount;
      await expectLater(
        app.toggleTask(t.id),
        throwsA(isA<RecurrenceException>()),
      );
      expect(app.getTask(t.id)!.completed, isFalse);
      expect(app.pendingCount, count);
    },
  );

  test('completed edge works through saveTask, deduplicates and carries typed rule', () async {
    final app = AppController(storage: MemoryStorage());
    addTearDown(app.dispose);
    await app.enterDemo();
    final t = task(
      DateTime(2026, 1, 31),
      const RecurrenceRule(frequency: 'monthly', count: 3),
    );
    await app.saveTask(t);
    await app.saveTask(t.copyWith(completed: true));
    final successor = app.tasks.singleWhere(
      (v) => v.title == t.title && v.id != t.id,
    );
    expect(successor.dueDate, DateTime(2026, 2, 28));
    expect(successor.recurrenceRule!.occurrence, 2);
    await app.toggleTask(t.id);
    await app.toggleTask(t.id);
    expect(app.tasks.where((v) => v.title == t.title), hasLength(2));
    await app.toggleTask(successor.id);
    expect(
      app.tasks.where((v) => v.title == t.title).map((v) => v.dueDate),
      contains(DateTime(2026, 3, 31)),
    );
  });

  test('invalid intervals and inconsistent ordinal input are rejected', () {
    expect(
      () => validateRecurrence(const RecurrenceRule(interval: 0)),
      throwsA(isA<RecurrenceException>()),
    );
    expect(
      () => validateRecurrence(const RecurrenceRule(ordinal: 2)),
      throwsA(isA<RecurrenceException>()),
    );
  });

  test(
    'moving duration task preserves span, time and repeat behavior',
    () async {
      final app = AppController(storage: MemoryStorage());
      addTearDown(app.dispose);
      await app.enterDemo();
      final t = task(
        DateTime(2026, 10, 20),
        const RecurrenceRule(frequency: 'weekly', weekdays: [2]),
        end: DateTime(2026, 10, 22),
      );
      await app.saveTask(t);
      await app.moveTask(t.id, DateTime(2026, 11, 1));
      final moved = app.getTask(t.id)!;
      expect(moved.dueDate, DateTime(2026, 11, 1));
      expect(moved.endDate, DateTime(2026, 11, 3));
      expect(moved.dueTime, '09:00');
      expect(moved.endTime, '10:00');
      expect(moved.recurrenceRule!.frequency, 'weekly');
    },
  );

  test('weekly task moved before its anchor still has a future occurrence', () {
    expect(
      sequence(
        task(
          DateTime(2026, 9, 1),
          RecurrenceRule(
            frequency: 'weekly',
            anchorDate: DateTime(2026, 10, 20),
            weekdays: [2],
            interval: 2,
          ),
        ),
        1,
      ),
      [DateTime(2026, 9, 8)],
    );
  });
}
