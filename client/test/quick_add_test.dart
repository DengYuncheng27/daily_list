import 'dart:async';

import 'package:dayflow/core/app_controller.dart';
import 'package:dayflow/core/models.dart';
import 'package:dayflow/ui/quick_add.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Controller extends AppController {
  final saved = <TaskItem>[];
  Completer<void>? saveGate;
  @override
  Future<void> saveTask(TaskItem task) async {
    final gate = saveGate;
    saveGate = null;
    if (gate != null) await gate.future;
    saved.add(task);
  }
}

void main() {
  Future<void> host(
    WidgetTester tester,
    _Controller controller, {
    ValueChanged<TaskItem>? created,
  }) async {
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              QuickAdd(
                controller: controller,
                listId: 'work',
                defaultDate: DateTime(2026, 10, 20),
                onCreated: created ?? (_) {},
                onExpand: () {},
              ),
            ],
          ),
        ),
      ),
    );
  }

  testWidgets('Enter adds repeatedly and keeps focus without opening detail', (
    tester,
  ) async {
    final controller = _Controller();
    final gate = Completer<void>();
    controller.saveGate = gate;
    var opens = 0;
    await host(tester, controller, created: (_) => opens++);
    final input = find.byKey(const ValueKey('quick-add-input'));
    await tester.enterText(input, '连续添加一');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      tester.widget<TextField>(input).enabled,
      isNot(false),
      reason: 'Saving must preserve the live text input connection on the web',
    );
    expect(tester.testTextInput.isVisible, isTrue);
    await tester.enterText(input, '保存期间的误输入');
    expect(tester.widget<TextField>(input).controller!.text, '连续添加一');
    gate.complete();
    await tester.pumpAndSettle();
    expect(controller.saved.single.title, '连续添加一');
    expect(tester.widget<TextField>(input).controller!.text, '');
    expect(tester.widget<TextField>(input).focusNode!.hasFocus, isTrue);
    await tester.enterText(input, '连续添加二');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(controller.saved.map((task) => task.title), ['连续添加一', '连续添加二']);
    expect(controller.saved.first.id, isNot(controller.saved.last.id));
    expect(opens, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Shift Enter saves once and opens the new task', (tester) async {
    final controller = _Controller();
    TaskItem? opened;
    await host(tester, controller, created: (task) => opened = task);
    await tester.enterText(
      find.byKey(const ValueKey('quick-add-input')),
      '展开详情',
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(controller.saved, hasLength(1));
    expect(opened?.id, controller.saved.single.id);
    expect(opened?.title, '展开详情');
    expect(tester.takeException(), isNull);
  });

  testWidgets('date can be selected before typing a title', (tester) async {
    final controller = _Controller();
    await host(tester, controller);
    final calendar = find.ancestor(
      of: find.byIcon(Icons.calendar_month_outlined),
      matching: find.byType(TextButton),
    );
    await tester.tap(calendar);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('calendar-2026-10-23')));
    await tester.tap(find.byKey(const Key('schedule-confirm')));
    await tester.pumpAndSettle();
    expect(controller.saved, isEmpty);
    await tester.enterText(
      find.byKey(const ValueKey('quick-add-input')),
      '先安排日期',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(controller.saved.single.dueDate, DateTime(2026, 10, 23));
    expect(controller.saved.single.listId, 'work');
    expect(tester.takeException(), isNull);
  });
}
