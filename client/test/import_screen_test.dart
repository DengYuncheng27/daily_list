import 'dart:convert';
import 'dart:typed_data';

import 'package:dayflow/core/app_controller.dart';
import 'package:dayflow/core/attachments.dart';
import 'package:dayflow/ui/ticktick_import_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'core_controller_test.dart' show MemoryStorage;

const _csv =
    'Folder Name,List Name,Title,Content,Status,taskId\r\n'
    '生活,阅读,导入测试任务,"第一行\n第二行",0,abc\r\n'
    '生活,阅读,已完成记录,保持原文,2,def\r\n';

Future<void> _select(WidgetTester tester) async {
  final picker = find.text('选择滴答备份 CSV');
  await tester.scrollUntilVisible(
    picker,
    250,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.runAsync(() async {
    await tester.tap(picker);
    await tester.pump();
    for (var attempt = 0; attempt < 100; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      if (find.byType(LinearProgressIndicator).evaluate().isEmpty) return;
    }
    throw StateError('CSV preview did not finish within five seconds');
  });
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'preview does not import; confirming preserves original fields and repeat is skipped',
    (tester) async {
      final storage = MemoryStorage();
      final controller = AppController(storage: storage);
      await controller.enterDemo();
      final before = controller.tasks.length;
      addTearDown(controller.dispose);
      Future<void> open() => tester.pumpWidget(
        MaterialApp(
          home: TickTickImportScreen(
            key: UniqueKey(),
            controller: controller,
            pickBackupFile: () async => PickedAttachment(
              'backup.csv',
              Uint8List.fromList(utf8.encode(_csv)),
            ),
          ),
        ),
      );
      await open();
      await _select(tester);
      expect(find.text('核对备份，确认后导入'), findsOneWidget);
      expect(controller.tasks.length, before);
      await tester.ensureVisible(find.text('确认导入 2 条'));
      await tester.tap(find.text('确认导入 2 条'));
      await tester.pumpAndSettle();
      expect(controller.tasks.length, before + 2);
      final task = controller.tasks.singleWhere((t) => t.title == '导入测试任务');
      expect(task.importData['Content'], '第一行\n第二行');
      expect(
        controller.tasks.singleWhere((t) => t.title == '已完成记录').completed,
        isTrue,
      );
      expect(find.text('数据已保存'), findsOneWidget);
      await open();
      await _select(tester);
      await tester.ensureVisible(find.text('确认导入（跳过重复）'));
      await tester.tap(find.text('确认导入（跳过重复）'));
      await tester.pumpAndSettle();
      expect(controller.tasks.length, before + 2);
      expect(find.textContaining('跳过 2 条已导入记录'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'invalid backup on a phone reports error without changing tasks',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = AppController(storage: MemoryStorage());
      await controller.enterDemo();
      addTearDown(controller.dispose);
      final before = controller.tasks.length;
      await tester.pumpWidget(
        MaterialApp(
          home: TickTickImportScreen(
            controller: controller,
            pickBackupFile: () async => PickedAttachment(
              'wrong.csv',
              Uint8List.fromList(utf8.encode('not a backup')),
            ),
          ),
        ),
      );
      await _select(tester);
      expect(find.textContaining('未找到滴答清单 CSV 表头'), findsOneWidget);
      expect(controller.tasks.length, before);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
