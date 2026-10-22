import 'package:dayflow/core/app_controller.dart';
import 'package:dayflow/core/models.dart';
import 'package:dayflow/ui/task_list.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Controller extends AppController {
  _Controller() {
    for (var i = 1; i <= 4; i++) {
      entries['$i'] = TaskItem(
        id: '$i',
        title: '任务 $i',
        dueDate: DateTime(2026, 10, 20 + i),
        notes: i == 1 ? '复制时应保留的正文' : '',
        richContent: i == 1
            ? [
                {
                  'insert': '复制时应保留的正文\n',
                  'attributes': {'bold': true},
                },
              ]
            : const [],
      );
    }
  }
  final entries = <String, TaskItem>{};
  final completedIds = <String>[];
  @override
  List<TaskItem> get tasks => entries.values.toList();
  @override
  List<ProjectList> get lists => const [ProjectList(id: 'inbox', name: '收件箱')];
  @override
  TaskItem? getTask(String id) => entries[id];
  @override
  ProjectList? taskList(String id) => lists.first;
  @override
  Future<void> saveTask(TaskItem task) async {
    entries[task.id] = task;
    notifyListeners();
  }

  @override
  Future<void> deleteTask(String id) async {
    entries.remove(id);
    notifyListeners();
  }

  @override
  Future<void> toggleTask(String id) async {
    completedIds.add(id);
    final task = entries[id]!;
    await saveTask(task.copyWith(completed: !task.completed));
  }
}

void main() {
  Future<void> host(
    WidgetTester tester,
    _Controller controller, {
    ValueChanged<TaskItem>? onSelect,
    String? selectedId,
  }) async {
    tester.view.physicalSize = const Size(700, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: controller,
            builder: (context, _) => TaskListView(
              controller: controller,
              tasks: controller.tasks,
              title: '全部',
              selectedId: selectedId,
              onSelect: onSelect ?? (_) {},
              onCreate: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> ctrlSelect(WidgetTester tester, String title) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(find.text(title));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'Ctrl toggles discrete selection and Shift adds the visible range',
    (tester) async {
      final controller = _Controller();
      await host(tester, controller);
      await ctrlSelect(tester, '任务 1');
      await ctrlSelect(tester, '任务 3');
      expect(find.text('已选择 2 项'), findsOneWidget);
      await ctrlSelect(tester, '任务 3');
      expect(find.text('已选择 1 项'), findsOneWidget);
      await tester.tap(find.byTooltip('取消多选'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('任务 1'));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.tap(find.text('任务 3'));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(find.text('已选择 3 项'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('batch priority and date affect only selected tasks', (
    tester,
  ) async {
    final controller = _Controller();
    await host(tester, controller);
    await ctrlSelect(tester, '任务 1');
    await ctrlSelect(tester, '任务 3');
    await tester.tap(find.byTooltip('批量设置优先级'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('高优先级'));
    await tester.pumpAndSettle();
    expect(controller.entries['1']!.priority, 3);
    expect(controller.entries['3']!.priority, 3);
    expect(controller.entries['2']!.priority, 0);
    expect(controller.entries['4']!.priority, 0);
    await tester.tap(find.byTooltip('批量设置日期'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('calendar-2026-10-30')));
    await tester.tap(find.byKey(const Key('schedule-confirm')));
    await tester.pumpAndSettle();
    expect(controller.entries['1']!.dueDate, DateTime(2026, 10, 30));
    expect(controller.entries['3']!.dueDate, DateTime(2026, 10, 30));
    expect(controller.entries['2']!.dueDate, DateTime(2026, 10, 22));
    expect(controller.entries['4']!.dueDate, DateTime(2026, 10, 24));
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyboard navigation and Shift selection skip collapsed tasks', (
    tester,
  ) async {
    final controller = _Controller();
    controller.entries['2'] = controller.entries['2']!.copyWith(
      completed: true,
    );
    final opened = <String>[];
    await host(
      tester,
      controller,
      selectedId: '1',
      onSelect: (task) => opened.add(task.id),
    );
    expect(find.text('任务 2'), findsNothing);
    await tester.tap(find.text('任务 1'));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(opened.last, '3');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(find.text('任务 3'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(find.text('已选择 2 项'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a note has no completion checkbox and batch completion skips it',
    (tester) async {
      final controller = _Controller();
      controller.entries['1'] = controller.entries['1']!.copyWith(
        itemType: 'note',
      );
      await host(tester, controller);
      expect(find.byType(Checkbox), findsNWidgets(3));
      await ctrlSelect(tester, '任务 1');
      await ctrlSelect(tester, '任务 2');
      await tester.tap(find.byTooltip('批量完成'));
      await tester.pumpAndSettle();
      expect(controller.completedIds, ['2']);
      expect(controller.entries['1']!.completed, isFalse);
      expect(controller.entries['2']!.completed, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('right click copies rich content and delete can be undone', (
    tester,
  ) async {
    final controller = _Controller();
    await host(tester, controller);
    await tester.tap(find.text('任务 1'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制'));
    await tester.pumpAndSettle();
    final duplicate = controller.tasks.singleWhere(
      (task) => task.title == '任务 1（副本）',
    );
    expect(duplicate.id, isNot('1'));
    expect(duplicate.richContent, controller.entries['1']!.richContent);
    await tester.tap(find.text('任务 1'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(controller.entries.containsKey('1'), isFalse);
    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect(controller.entries['1']!.title, '任务 1');
    expect(
      controller.entries['1']!.richContent.first['attributes'],
      containsPair('bold', true),
    );
    expect(tester.takeException(), isNull);
  });
}
