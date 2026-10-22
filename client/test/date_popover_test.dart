import 'package:dayflow/core/models.dart';
import 'package:dayflow/ui/date_popover.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> open(
  WidgetTester tester,
  TaskItem task,
  ValueChanged<TaskSchedule?> result,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async =>
                result(await showTaskSchedulePicker(context, task: task)),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('holiday markers use official 2026 days only', (tester) async {
    await open(
      tester,
      TaskItem(id: 't', title: 'Task', dueDate: DateTime(2026, 10, 20)),
      (_) {},
    );
    expect(find.byTooltip('2026-10-01 · 国务院 2026 年安排：放假'), findsOneWidget);
    expect(find.byTooltip('2026-10-10 · 国务院 2026 年安排：调休补班'), findsOneWidget);
    expect(find.byTooltip('2026-10-17 · 国务院 2026 年安排：放假'), findsNothing);
    for (var i = 0; i < 4; i++) {
      await tester.tap(find.byTooltip('下个月'));
      await tester.pumpAndSettle();
    }
    expect(find.text('休'), findsNothing);
    expect(find.text('班'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'cancel is null and clear explicitly removes all schedule fields',
    (tester) async {
      TaskSchedule? result;
      var returned = false;
      final task = TaskItem(
        id: 't',
        title: 'Task',
        dueDate: DateTime(2026, 10, 20),
        dueTime: '09:00',
        endDate: DateTime(2026, 10, 22),
        endTime: '10:00',
        reminderMinutes: 5,
        recurrence: 'monthly',
      );
      await open(tester, task, (v) {
        result = v;
        returned = true;
      });
      await tester.tap(find.byTooltip('取消'));
      await tester.pumpAndSettle();
      expect(returned, isTrue);
      expect(result, isNull);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('schedule-clear')));
      await tester.pumpAndSettle();
      final cleared = result!.applyTo(task);
      expect(cleared.dueDate, isNull);
      expect(cleared.endDate, isNull);
      expect(cleared.dueTime, isNull);
      expect(cleared.reminderMinutes, isNull);
      expect(cleared.recurrence, 'none');
      expect(cleared.title, 'Task');
    },
  );

  testWidgets('range picks two dates and saves with fields preserved', (
    tester,
  ) async {
    TaskSchedule? result;
    await open(
      tester,
      TaskItem(id: 't', title: 'Task', dueDate: DateTime(2026, 10, 20)),
      (v) => result = v,
    );
    await tester.tap(find.text('时间段'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('calendar-2026-10-21')));
    await tester.tap(find.byKey(const Key('calendar-2026-10-23')));
    await tester.tap(find.byKey(const Key('schedule-confirm')));
    await tester.pumpAndSettle();
    expect(result!.dueDate, DateTime(2026, 10, 21));
    expect(result!.endDate, DateTime(2026, 10, 23));
    expect(tester.takeException(), isNull);
  });

  testWidgets('time range validates order before returning', (tester) async {
    TaskSchedule? result;
    await open(
      tester,
      TaskItem(
        id: 't',
        title: 'Task',
        dueDate: DateTime(2026, 10, 20),
        endDate: DateTime(2026, 10, 20),
        dueTime: '10:00',
        endTime: '11:00',
      ),
      (v) => result = v,
    );
    await tester.ensureVisible(find.text('时间', skipOffstage: false));
    await tester.tap(find.text('时间'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('schedule-end-time')));
    await tester.enterText(find.byKey(const Key('schedule-end-time')), '09:00');
    await tester.tap(find.byKey(const Key('schedule-confirm')));
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(find.byKey(const Key('schedule-error')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('schedule-end-time')), '12:30');
    await tester.tap(find.byKey(const Key('schedule-confirm')));
    await tester.pumpAndSettle();
    expect(result!.endTime, '12:30');
  });

  testWidgets('weekly settings persist a real weekday selection', (
    tester,
  ) async {
    TaskSchedule? result;
    await open(
      tester,
      TaskItem(
        id: 't',
        title: 'Task',
        dueDate: DateTime(2026, 10, 19),
        recurrenceRule: const RecurrenceRule(
          frequency: 'weekly',
          weekdays: [1],
        ),
      ),
      (v) => result = v,
    );
    await tester.ensureVisible(find.text('重复'));
    await tester.tap(find.text('重复'));
    await tester.pumpAndSettle();
    expect(find.text('每周（周一）'), findsOneWidget);
    expect(find.text('每月（19 日）'), findsOneWidget);
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
    await tester.tap(find.byKey(const Key('repeat-preset-weekly')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('repeat-weekday-3')));
    await tester.tap(find.byKey(const Key('repeat-weekday-3')));
    await tester.tap(find.byKey(const Key('schedule-confirm')));
    await tester.pumpAndSettle();
    expect(result!.recurrenceRule!.weekdays, [1, 3]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('direct repeat presets open details with a working back path', (
    tester,
  ) async {
    TaskSchedule? result;
    await open(
      tester,
      TaskItem(id: 't', title: 'Task', dueDate: DateTime(2026, 10, 20)),
      (v) => result = v,
    );
    await tester.ensureVisible(find.text('重复'));
    await tester.tap(find.text('重复'));
    await tester.pumpAndSettle();
    expect(find.text('每周（周二）'), findsOneWidget);
    expect(find.text('每年（10 月 20 日）'), findsOneWidget);
    await tester.tap(find.byKey(const Key('repeat-preset-daily')));
    await tester.pumpAndSettle();
    expect(find.text('每隔'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('number-interval-daily')),
      '3',
    );
    await tester.tap(find.byKey(const Key('repeat-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('repeat-preset-daily')), findsOneWidget);
    await tester.tap(find.byTooltip('返回日期设置'));
    await tester.pumpAndSettle();
    expect(find.text('每 3 天'), findsOneWidget);
    await tester.tap(find.byKey(const Key('schedule-confirm')));
    await tester.pumpAndSettle();
    expect(result!.recurrenceRule!.interval, 3);
  });

  testWidgets(
    'keyboard and narrow phone keep confirmation visible without overflow',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 740);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetViewInsets);
      await open(
        tester,
        TaskItem(id: 't', title: 'Task', dueDate: DateTime(2026, 10, 20)),
        (_) {},
      );
      final confirmation = tester.getRect(
        find.byKey(const Key('schedule-confirm')),
      );
      expect(confirmation.bottom, lessThan(440));
      expect(confirmation.left, greaterThanOrEqualTo(0));
      expect(tester.takeException(), isNull);
    },
  );
}
