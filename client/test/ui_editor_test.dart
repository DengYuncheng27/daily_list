import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Tristate;

import 'package:dayflow/core/app_controller.dart';
import 'package:dayflow/core/models.dart';
import 'package:dayflow/ui/task_editor.dart';
import 'package:dayflow/ui/task_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:flutter_test/flutter_test.dart';

class _MemoryController extends AppController {
  _MemoryController([Iterable<TaskItem> seed = const []]) {
    for (final task in seed) {
      entries[task.id] = task;
    }
  }
  final entries = <String, TaskItem>{};
  Completer<void>? saveGate;
  Completer<AttachmentItem?>? pickGate;
  AttachmentItem? picked;
  bool failSave = false;
  int saveCount = 0;
  String? downloaded;

  @override
  List<TaskItem> get tasks => entries.values.toList();
  @override
  List<ProjectList> get lists => const [
    ProjectList(id: 'inbox', name: '收件箱'),
    ProjectList(id: 'work', name: '工作', color: 0xFF55ADB1),
  ];
  @override
  TaskItem? getTask(String id) => entries[id];
  @override
  ProjectList? taskList(String id) =>
      lists.where((list) => list.id == id).firstOrNull;
  @override
  Future<void> saveTask(TaskItem task) async {
    saveCount++;
    final gate = saveGate;
    saveGate = null;
    if (gate != null) await gate.future;
    if (failSave) throw Exception('磁盘不可写');
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
    final task = entries[id]!;
    await saveTask(task.copyWith(completed: !task.completed));
  }

  @override
  Future<AttachmentItem?> pickAttachment({bool imagesOnly = false}) async =>
      pickGate == null ? picked : pickGate!.future;
  @override
  Future<Uint8List> downloadAttachment(AttachmentItem attachment) async =>
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aYZkAAAAASUVORK5CYII=',
      );
  @override
  Future<void> saveAttachmentToDevice(AttachmentItem attachment) async {
    downloaded = attachment.id;
  }
}

void _viewport(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _host(Widget child) => MaterialApp(
  localizationsDelegates: const [
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    quill.FlutterQuillLocalizations.delegate,
  ],
  theme: ThemeData(
    colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF55ADB1)),
  ),
  home: Scaffold(body: child),
);

Finder get _title => find.byKey(const ValueKey('task-title'));
Future<void> _autosave(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 700));
  await tester.pumpAndSettle();
}

Future<void> _disposeEditor(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

void main() {
  testWidgets(
    'accessible body focus registers native input and preserves rich formatting',
    (tester) async {
      _viewport(tester, const Size(430, 1000));
      final semantics = tester.ensureSemantics();
      const task = TaskItem(
        id: 'accessible-input',
        title: '无障碍正文',
        richContent: [
          {
            'insert': '保留粗体',
            'attributes': {'bold': true},
          },
          {'insert': '\n'},
        ],
      );
      final controller = _MemoryController([task]);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _host(TaskEditor(controller: controller, task: task, onClose: () {})),
      );
      final body = find.byKey(const ValueKey('rich-body-semantics'));
      expect(body, findsOneWidget);
      final node = tester.getSemantics(body);
      expect(node.getSemanticsData().flagsCollection.isTextField, isTrue);
      expect(node.getSemanticsData().flagsCollection.isMultiline, isTrue);
      expect(
        node.getSemanticsData().flagsCollection.isEnabled,
        Tristate.isTrue,
      );
      node.owner!.performAction(node.id, SemanticsAction.focus);
      await tester.pump();
      await tester.pump();
      expect(tester.testTextInput.hasAnyClients, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
      expect(
        tester.getSemantics(body).getSemanticsData().flagsCollection.isFocused,
        Tristate.isTrue,
      );
      // Exercise the platform TextInputClient, including a CJK composing range.
      // No document/controller mutation is used to insert the user's text.
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '保留粗体输入\n',
          selection: TextSelection.collapsed(offset: 6),
          composing: TextRange(start: 4, end: 6),
        ),
      );
      await tester.pump();
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '保留粗体输入\n第二行\n',
          selection: TextSelection.collapsed(offset: 10),
        ),
      );
      await _autosave(tester);
      final saved = controller.getTask(task.id)!;
      expect(saved.notes, '保留粗体输入\n第二行');
      expect(saved.richContent.first['attributes'], containsPair('bold', true));
      expect(
        tester.getSemantics(body).getSemanticsData().value,
        '${saved.notes}\n',
      );
      node.owner!.performAction(node.id, SemanticsAction.setSelection, {
        'base': 0,
        'extent': 4,
      });
      await tester.pump();
      expect(
        tester.getSemantics(body).getSemanticsData().textSelection,
        const TextSelection(baseOffset: 0, extentOffset: 4),
      );
      node.owner!.performAction(
        node.id,
        SemanticsAction.setText,
        '${saved.notes}！\n',
      );
      await _autosave(tester);
      expect(controller.getTask(task.id)!.notes, '${saved.notes}！');
      expect(
        controller.getTask(task.id)!.richContent.first['attributes'],
        containsPair('bold', true),
      );
      expect(tester.takeException(), isNull);
      await _disposeEditor(tester);
      semantics.dispose();
    },
  );

  testWidgets(
    'body pointer tap accepts platform input without semantic actions',
    (tester) async {
      _viewport(tester, const Size(430, 1000));
      const task = TaskItem(id: 'pointer-input', title: '鼠标正文');
      final controller = _MemoryController([task]);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _host(TaskEditor(controller: controller, task: task, onClose: () {})),
      );
      final editor = find.byType(quill.QuillEditor);
      await tester.tapAt(tester.getTopLeft(editor) + const Offset(10, 16));
      await tester.pump();
      expect(tester.testTextInput.hasAnyClients, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '普通输入正常\n',
          selection: TextSelection.collapsed(offset: 6),
        ),
      );
      await _autosave(tester);
      expect(controller.getTask(task.id)!.notes, '普通输入正常');
      expect(tester.takeException(), isNull);
      await _disposeEditor(tester);
    },
  );

  testWidgets('new task autosaves without dismissing the persistent editor', (
    tester,
  ) async {
    _viewport(tester, const Size(390, 844));
    final controller = _MemoryController();
    addTearDown(controller.dispose);
    var closeCount = 0;
    await tester.pumpWidget(
      _host(
        TaskEditor(
          controller: controller,
          initialDate: DateTime(2026, 10, 20),
          initialListId: 'work',
          onClose: () => closeCount++,
        ),
      ),
    );
    await tester.enterText(_title, '准备月度计划');
    expect(controller.tasks, isEmpty);
    await _autosave(tester);
    final saved = controller.tasks.single;
    expect(saved.title, '准备月度计划');
    expect(saved.listId, 'work');
    expect(saved.dueDate, DateTime(2026, 10, 20));
    expect(closeCount, 0);
    expect(find.text('已保存'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _disposeEditor(tester);
  });

  testWidgets(
    'switching tasks flushes the previous draft and preserves the selected item',
    (tester) async {
      _viewport(tester, const Size(430, 900));
      const a = TaskItem(id: 'a', title: '任务 A');
      const b = TaskItem(id: 'b', title: '任务 B');
      final controller = _MemoryController([a, b]);
      addTearDown(controller.dispose);
      final key = GlobalKey<TaskEditorState>();
      var selected = a;
      late StateSetter rebuild;
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return TaskEditor(
                key: key,
                controller: controller,
                task: selected,
                onClose: () {},
              );
            },
          ),
        ),
      );
      await tester.enterText(_title, '任务 A 的修改');
      rebuild(() => selected = b);
      await tester.pumpAndSettle();
      expect(controller.getTask('a')!.title, '任务 A 的修改');
      expect(tester.widget<TextField>(_title).controller!.text, '任务 B');
      await tester.enterText(_title, '任务 B 的修改');
      final closed = key.currentState!.requestClose();
      await tester.pumpAndSettle();
      expect(await closed, isTrue);
      expect(controller.getTask('b')!.title, '任务 B 的修改');
      expect(key.currentState!.hasUnsavedChanges, isFalse);
      expect(tester.takeException(), isNull);
      await _disposeEditor(tester);
    },
  );

  testWidgets(
    'typing during an asynchronous save persists the newest revision',
    (tester) async {
      _viewport(tester, const Size(430, 900));
      const task = TaskItem(id: 'slow', title: '原始标题');
      final controller = _MemoryController([task]);
      addTearDown(controller.dispose);
      final gate = Completer<void>();
      controller.saveGate = gate;
      await tester.pumpWidget(
        _host(TaskEditor(controller: controller, task: task, onClose: () {})),
      );
      await tester.enterText(_title, '第一版');
      await tester.pump(const Duration(milliseconds: 700));
      await tester.enterText(_title, '输入仍在继续的第二版');
      gate.complete();
      await _autosave(tester);
      expect(controller.getTask('slow')!.title, '输入仍在继续的第二版');
      expect(controller.saveCount, 2);
      expect(tester.widget<TextField>(_title).controller!.text, '输入仍在继续的第二版');
      expect(tester.takeException(), isNull);
      await _disposeEditor(tester);
    },
  );

  testWidgets('failed autosave retains draft and guards closing until saved', (
    tester,
  ) async {
    _viewport(tester, const Size(430, 900));
    const task = TaskItem(id: 'failure', title: '旧标题');
    final controller = _MemoryController([task])..failSave = true;
    addTearDown(controller.dispose);
    final key = GlobalKey<TaskEditorState>();
    await tester.pumpWidget(
      _host(
        TaskEditor(
          key: key,
          controller: controller,
          task: task,
          onClose: () {},
        ),
      ),
    );
    await tester.enterText(_title, '保留这个修改');
    await _autosave(tester);
    expect(controller.getTask(task.id)!.title, '旧标题');
    expect(find.text('保存失败'), findsOneWidget);
    final closing = key.currentState!.requestClose();
    await tester.pumpAndSettle();
    expect(find.text('还有未保存的内容'), findsOneWidget);
    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    expect(await closing, isFalse);
    expect(tester.widget<TextField>(_title).controller!.text, '保留这个修改');
    controller.failSave = false;
    final retry = key.currentState!.requestClose();
    await tester.pumpAndSettle();
    expect(await retry, isTrue);
    expect(controller.getTask(task.id)!.title, '保留这个修改');
    expect(tester.takeException(), isNull);
    await _disposeEditor(tester);
  });

  testWidgets(
    'rich text formatting survives autosave and conversion to a note',
    (tester) async {
      _viewport(tester, const Size(430, 900));
      const task = TaskItem(id: 'rich', title: '项目说明', notes: '需要强调的文字');
      final controller = _MemoryController([task]);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _host(TaskEditor(controller: controller, task: task, onClose: () {})),
      );
      final editor = tester.widget<quill.QuillEditor>(
        find.byType(quill.QuillEditor),
      );
      editor.controller.updateSelection(
        const TextSelection(baseOffset: 0, extentOffset: 4),
        quill.ChangeSource.local,
      );
      await tester.tap(find.byTooltip('粗体'));
      await _autosave(tester);
      expect(
        controller.getTask(task.id)!.richContent.first['attributes'],
        containsPair('bold', true),
      );
      expect(controller.getTask(task.id)!.notes, '需要强调的文字');
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('转换为笔记'));
      await _autosave(tester);
      expect(controller.getTask(task.id)!.itemType, 'note');
      expect(find.byTooltip('标记完成'), findsNothing);
      expect(find.text('添加子任务'), findsNothing);
      expect(
        controller.getTask(task.id)!.richContent.first['attributes'],
        containsPair('bold', true),
      );
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('转换为任务'));
      await _autosave(tester);
      expect(controller.getTask(task.id)!.itemType, 'task');
      expect(find.byTooltip('标记完成'), findsOneWidget);
      expect(controller.getTask(task.id)!.notes, '需要强调的文字');
      expect(
        controller.getTask(task.id)!.richContent.first['attributes'],
        containsPair('bold', true),
      );
      expect(tester.takeException(), isNull);
      await _disposeEditor(tester);
    },
  );

  testWidgets(
    'slash command inserts a real formatted block and undo restores it',
    (tester) async {
      _viewport(tester, const Size(430, 900));
      const task = TaskItem(id: 'slash', title: '命令测试');
      final controller = _MemoryController([task]);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _host(TaskEditor(controller: controller, task: task, onClose: () {})),
      );
      final editor = tester.widget<quill.QuillEditor>(
        find.byType(quill.QuillEditor),
      );
      editor.focusNode.requestFocus();
      await tester.pump();
      editor.controller.replaceText(
        0,
        0,
        '/',
        const TextSelection.collapsed(offset: 1),
      );
      await tester.pumpAndSettle();
      final commands = find.byKey(const ValueKey('rich-slash-commands'));
      expect(commands, findsOneWidget);
      await tester.tap(
        find.descendant(of: commands, matching: find.text('标题')),
      );
      await tester.pumpAndSettle();
      editor.controller.replaceText(
        0,
        0,
        '格式标题',
        const TextSelection.collapsed(offset: 4),
      );
      await _autosave(tester);
      final content = controller.getTask(task.id)!.richContent;
      expect(
        content.any((op) => (op['attributes'] as Map?)?['header'] == 2),
        isTrue,
      );
      expect(controller.getTask(task.id)!.notes, '格式标题');
      expect(find.byTooltip('撤销'), findsOneWidget);
      await tester.tap(find.byTooltip('撤销'));
      await _autosave(tester);
      expect(controller.getTask(task.id)!.notes, isNot('格式标题'));
      expect(tester.takeException(), isNull);
      await _disposeEditor(tester);
    },
  );

  testWidgets('markdown heading keyboard shortcut produces a Delta heading', (
    tester,
  ) async {
    _viewport(tester, const Size(430, 900));
    const task = TaskItem(id: 'markdown', title: 'Markdown');
    final controller = _MemoryController([task]);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _host(TaskEditor(controller: controller, task: task, onClose: () {})),
    );
    final editor = tester.widget<quill.QuillEditor>(
      find.byType(quill.QuillEditor),
    );
    editor.focusNode.requestFocus();
    await tester.pump();
    editor.controller.replaceText(
      0,
      0,
      '#',
      const TextSelection.collapsed(offset: 1),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await _autosave(tester);
    expect(
      controller
          .getTask(task.id)!
          .richContent
          .any((op) => (op['attributes'] as Map?)?['header'] == 1),
      isTrue,
    );
    expect(tester.takeException(), isNull);
    await _disposeEditor(tester);
  });

  testWidgets(
    'image upload finished after selection change belongs to the original task',
    (tester) async {
      _viewport(tester, const Size(430, 900));
      const a = TaskItem(id: 'a', title: '原任务');
      const b = TaskItem(id: 'b', title: '新任务');
      const attachment = AttachmentItem(
        id: 'image-id',
        name: '图片.png',
        mimeType: 'image/png',
        size: 100,
        sha256: 'abc',
      );
      final controller = _MemoryController([a, b])
        ..pickGate = Completer<AttachmentItem?>();
      addTearDown(controller.dispose);
      var selected = a;
      late StateSetter rebuild;
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return TaskEditor(
                controller: controller,
                task: selected,
                onClose: () {},
              );
            },
          ),
        ),
      );
      await tester.tap(find.byTooltip('插入图片'));
      await tester.pump();
      rebuild(() => selected = b);
      await tester.pump();
      controller.pickGate!.complete(attachment);
      await tester.pumpAndSettle();
      expect(controller.getTask('a')!.attachments.single.id, 'image-id');
      expect(controller.getTask('b')!.attachments, isEmpty);
      expect(
        jsonEncode(controller.getTask('a')!.richContent),
        contains('attachment:image-id'),
      );
      expect(tester.widget<TextField>(_title).controller!.text, '新任务');
      expect(tester.takeException(), isNull);
      await _disposeEditor(tester);
    },
  );

  testWidgets('attachment download and removal use the saved metadata', (
    tester,
  ) async {
    _viewport(tester, const Size(430, 1000));
    const attachment = AttachmentItem(
      id: 'file',
      name: '方案.pdf',
      mimeType: 'application/pdf',
      size: 2048,
      sha256: 'abc',
    );
    const task = TaskItem(
      id: 'file-task',
      title: '带附件的任务',
      attachments: [attachment],
    );
    final controller = _MemoryController([task]);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _host(TaskEditor(controller: controller, task: task, onClose: () {})),
    );
    await tester.ensureVisible(find.byTooltip('下载 方案.pdf'));
    await tester.tap(find.byTooltip('下载 方案.pdf'));
    await tester.pumpAndSettle();
    expect(controller.downloaded, 'file');
    await tester.tap(find.byTooltip('移除 方案.pdf'));
    await _autosave(tester);
    expect(controller.getTask(task.id)!.attachments, isEmpty);
    expect(tester.takeException(), isNull);
    await _disposeEditor(tester);
  });

  testWidgets(
    'rich editor supports 320px width and previously synced metadata',
    (tester) async {
      _viewport(tester, const Size(320, 640));
      final task = TaskItem(
        id: 'narrow',
        title: '需要在手机窄屏上编辑的任务，标题可以换行',
        listId: 'removed-list',
        dueDate: DateTime(2027, 1, 2),
        dueTime: '09:30',
        reminderMinutes: 7,
        priority: 3,
        notes: '说明文字仍然可以完整阅读。',
        tags: const ['项目', '需要跟进'],
        subtasks: const [SubTask(id: 'step', title: '第一个子任务')],
      );
      final controller = _MemoryController([task]);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _host(TaskEditor(controller: controller, task: task, onClose: () {})),
      );
      await tester.pumpAndSettle();
      expect(find.text('原清单已移除'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('添加子任务'));
      await tester.tap(find.byKey(const ValueKey('editor-save-status')));
      await tester.pumpAndSettle();
      expect(controller.getTask(task.id)!.reminderMinutes, 7);
      expect(controller.getTask(task.id)!.subtasks.single.title, '第一个子任务');
      expect(tester.takeException(), isNull);
      await _disposeEditor(tester);
    },
  );

  testWidgets('task list supports mobile content and completion', (
    tester,
  ) async {
    _viewport(tester, const Size(320, 740));
    final task = TaskItem(
      id: 'list',
      title: '需要完整展示的长标题任务，包含日期标签和子任务',
      listId: 'work',
      dueDate: DateTime.now(),
      dueTime: '09:30',
      priority: 3,
      tags: const ['工作', '待确认'],
      subtasks: const [SubTask(id: 'step', title: '整理资料', completed: true)],
    );
    final controller = _MemoryController([task]);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _host(
        ListenableBuilder(
          listenable: controller,
          builder: (context, _) => TaskListView(
            controller: controller,
            tasks: controller.tasks,
            title: '今天',
            onSelect: (_) {},
            onCreate: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('1/1'), findsOneWidget);
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    expect(controller.getTask(task.id)!.completed, isTrue);
    expect(tester.takeException(), isNull);
    await _disposeEditor(tester);
  });
}
