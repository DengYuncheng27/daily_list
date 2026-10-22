import 'dart:convert';

import 'package:dayflow/app.dart';
import 'package:dayflow/core/api_client.dart';
import 'package:dayflow/core/app_controller.dart';
import 'package:dayflow/core/storage.dart';
import 'package:dayflow/ui/auth_screen.dart';
import 'package:dayflow/ui/calendar_view.dart';
import 'package:dayflow/ui/task_editor.dart';
import 'package:dayflow/ui/task_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _MemoryStorage implements AppStorage {
  Map<String, dynamic>? active;
  final Map<String, Map<String, dynamic>> workspaces = {};
  final Map<String, String> tokens = {};

  Map<String, dynamic>? _copy(Map<String, dynamic>? value) => value == null
      ? null
      : jsonDecode(jsonEncode(value)) as Map<String, dynamic>;

  @override
  Future<Map<String, dynamic>?> readActiveAccount() async => _copy(active);

  @override
  Future<void> writeActiveAccount(Map<String, dynamic>? account) async {
    active = _copy(account);
  }

  @override
  Future<Map<String, dynamic>?> readWorkspace(String key) async =>
      _copy(workspaces[key]);

  @override
  Future<void> writeWorkspace(
    String key,
    Map<String, dynamic> workspace,
  ) async {
    workspaces[key] = _copy(workspace)!;
  }

  @override
  Future<String?> readRefreshToken(String key) async => tokens[key];

  @override
  Future<void> writeRefreshToken(String key, String? token) async {
    if (token == null) {
      tokens.remove(key);
    } else {
      tokens[key] = token;
    }
  }
}

void _setViewport(WidgetTester tester, Size size) {
  final oldErrorHandler = FlutterError.onError;
  FlutterError.onError = (details) {
    debugPrint(details.toString());
    oldErrorHandler?.call(details);
  };
  addTearDown(() => FlutterError.onError = oldErrorHandler);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
}

Future<void> _settleWithoutErrors(WidgetTester tester, String step) async {
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull, reason: step);
}

Future<void> _navigate(WidgetTester tester, String label, bool mobile) async {
  final finder = mobile
      ? find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text(label),
        )
      : find.text(label).first;
  await tester.tap(finder);
  await _settleWithoutErrors(tester, 'Navigate to $label');
}

Finder get _editorTitle => find
    .descendant(of: find.byType(TaskEditor), matching: find.byType(TextField))
    .first;

void main() {
  testWidgets('account navigation protects unsent quick-add text', (
    tester,
  ) async {
    _setViewport(tester, const Size(1440, 900));
    final controller = AppController(storage: _MemoryStorage());
    addTearDown(controller.dispose);
    await controller.enterDemo();
    await tester.pumpWidget(DayflowApp(controller: controller));
    await _settleWithoutErrors(tester, 'quick-add before login');
    final input = find.byKey(const ValueKey('quick-add-input'));
    await tester.enterText(input, '登录前需要保留的快捷输入');
    await tester.tap(find.text('登录'));
    await _settleWithoutErrors(tester, 'quick-add login guard');
    expect(find.text('添加栏里还有内容'), findsOneWidget);
    await tester.tap(find.text('继续编辑'));
    await _settleWithoutErrors(tester, 'keep quick-add text');
    expect(tester.widget<TextField>(input).controller!.text, '登录前需要保留的快捷输入');
    expect(find.byType(AuthScreen), findsNothing);
    await tester.tap(find.text('登录'));
    await _settleWithoutErrors(tester, 'quick-add login guard retry');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await _settleWithoutErrors(tester, 'save quick-add before login');
    expect(
      controller.tasks.any((task) => task.title == '登录前需要保留的快捷输入'),
      isTrue,
    );
    expect(find.byType(AuthScreen), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  for (final size in const [
    Size(390, 844),
    Size(320, 640),
    Size(1440, 900),
    Size(1024, 768),
    Size(932, 900),
  ]) {
    final name = '${size.width.toInt()}x${size.height.toInt()}';
    testWidgets('app navigation, editor, calendar and auth fit $name', (
      tester,
    ) async {
      _setViewport(tester, size);
      final controller = AppController(storage: _MemoryStorage());
      addTearDown(controller.dispose);
      await controller.enterDemo();
      await tester.pumpWidget(DayflowApp(controller: controller));
      await _settleWithoutErrors(tester, '$name initial today');
      expect(find.byType(TaskListView), findsOneWidget);
      final mobile = size.width < 760;
      await _navigate(tester, '月历', mobile);

      await tester.tap(find.byTooltip('下个月'));
      await _settleWithoutErrors(tester, '$name empty month');
      await tester.tap(
        find.descendant(
          of: find.byType(MonthCalendar),
          matching: find.text('今天'),
        ),
      );
      await _settleWithoutErrors(tester, '$name month today');

      await _navigate(tester, '今天', mobile);
      expect(find.byType(TaskListView), findsOneWidget);
      await tester.tap(find.text('梳理本周的三件重要事项'));
      await _settleWithoutErrors(tester, '$name editor');
      expect(find.byType(TaskEditor), findsOneWidget);
      if (size.width >= 900) {
        expect(
          find.byType(TaskListView),
          findsOneWidget,
          reason: 'Desktop keeps the list visible beside the persistent detail pane',
        );
      }
      await tester.enterText(_editorTitle, '已编辑的计划 $name');
      await tester.pump(const Duration(milliseconds: 700));
      await _settleWithoutErrors(tester, '$name edited task');
      expect(
        controller.tasks.any((task) => task.title == '已编辑的计划 $name'),
        isTrue,
      );

      expect(find.byType(TaskEditor), findsOneWidget);
      await tester.tap(find.byTooltip('关闭'));
      await _settleWithoutErrors(tester, '$name close editor');
      await tester.enterText(
        find.byKey(const ValueKey('quick-add-input')),
        '新建任务 $name',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await _settleWithoutErrors(tester, '$name created task');
      expect(
        controller.tasks.any((task) => task.title == '新建任务 $name'),
        isTrue,
      );

      await _navigate(tester, '月历', mobile);
      expect(find.byType(MonthCalendar), findsOneWidget);
      await tester.tap(find.text('登录'));
      await _settleWithoutErrors(tester, '$name login route');
      expect(find.byType(AuthScreen), findsOneWidget);

      final register = find.text('创建账号');
      await tester.ensureVisible(register);
      await tester.tap(register);
      await _settleWithoutErrors(tester, '$name registration form');
      expect(find.text('开启你的日序'), findsOneWidget);
      final server = find.text('服务器地址');
      await tester.ensureVisible(server);
      await tester.tap(server);
      await _settleWithoutErrors(tester, '$name server form');
      if (mobile) {
        tester.view.viewInsets = const FakeViewPadding(bottom: 270);
        await _settleWithoutErrors(tester, '$name auth with keyboard');
        tester.view.resetViewInsets();
        await _settleWithoutErrors(tester, '$name keyboard dismissed');
      }
      await tester.ensureVisible(find.text('返回'));
      await tester.tap(find.text('返回'));
      await _settleWithoutErrors(tester, '$name return from auth');
      expect(find.byType(MonthCalendar), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }

  testWidgets('first-run mobile auth can register, validate and enter demo', (
    tester,
  ) async {
    _setViewport(tester, const Size(320, 640));
    final controller = AppController(storage: _MemoryStorage());
    addTearDown(controller.dispose);
    await controller.initialize();
    await tester.pumpWidget(DayflowApp(controller: controller));
    await _settleWithoutErrors(tester, 'first-run login');
    expect(find.byType(AuthScreen), findsOneWidget);
    await tester.ensureVisible(find.text('创建账号'));
    await tester.tap(find.text('创建账号'));
    await _settleWithoutErrors(tester, 'first-run registration');
    final submit = find.widgetWithText(FilledButton, '创建账号');
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await _settleWithoutErrors(tester, 'registration validation');
    expect(find.text('请填写名字'), findsOneWidget);
    expect(find.text('请输入有效邮箱'), findsOneWidget);
    expect(find.text('请填写至少 10 位的密码'), findsOneWidget);
    await tester.ensureVisible(find.text('先体验一下'));
    await tester.tap(find.text('先体验一下'));
    await _settleWithoutErrors(tester, 'demo from first run');
    expect(controller.demoMode, isTrue);
    expect(find.byType(TaskListView), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('desktop auth fits a 1024x768 window', (tester) async {
    _setViewport(tester, const Size(1024, 768));
    final controller = AppController(storage: _MemoryStorage());
    addTearDown(controller.dispose);
    await controller.initialize();
    await tester.pumpWidget(DayflowApp(controller: controller));
    await _settleWithoutErrors(tester, '1024x768 standalone login');
    await tester.ensureVisible(find.text('创建账号'));
    await tester.tap(find.text('创建账号'));
    await _settleWithoutErrors(tester, '1024x768 standalone registration');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
    'login and logout guard drafts and account switch resets editor',
    (tester) async {
      _setViewport(tester, const Size(1440, 900));
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/auth/login')) {
          return http.Response(
            jsonEncode({
              'accessToken': 'test-access',
              'refreshToken': 'test-refresh',
              'user': {
                'id': 'account-a',
                'email': 'account@example.com',
                'name': '新账号',
              },
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        return http.Response(
          jsonEncode({
            'cursor': 0,
            'hasMore': false,
            'accepted': [],
            'conflicts': [],
            'changes': [],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      addTearDown(client.close);
      final controller = AppController(
        storage: _MemoryStorage(),
        apiFactory: (url) => ApiClient(url, client: client),
      );
      addTearDown(controller.dispose);
      await controller.enterDemo();
      await tester.pumpWidget(DayflowApp(controller: controller));
      await _settleWithoutErrors(tester, 'demo before account change');
      await tester.tap(find.text('梳理本周的三件重要事项'));
      await _settleWithoutErrors(tester, 'draft editor');
      await tester.enterText(_editorTitle, '');
      await tester.tap(find.text('登录'));
      await _settleWithoutErrors(tester, 'account change draft guard');
      expect(find.text('还有未保存的内容'), findsOneWidget);
      await tester.tap(find.text('放弃修改'));
      await _settleWithoutErrors(tester, 'login after discarding demo draft');
      expect(find.byType(AuthScreen), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextFormField, '邮箱'),
        'account@example.com',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, '密码'),
        'test-password-123',
      );
      await tester.tap(find.widgetWithText(FilledButton, '登录'));
      await _settleWithoutErrors(tester, 'signed-in account');
      expect(controller.authenticated, isTrue);
      expect(controller.demoMode, isFalse);
      expect(controller.tasks, isEmpty);
      expect(find.byType(TaskEditor), findsNothing);
      expect(find.text('不能带到新账号的未保存草稿'), findsNothing);

      await tester.tap(find.byTooltip('添加选项'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('在详情中添加'));
      await _settleWithoutErrors(tester, 'new account draft');
      final rich = tester.widget<quill.QuillEditor>(
        find.byType(quill.QuillEditor),
      );
      rich.controller.replaceText(0, 0, '退出前还没有保存的账号草稿', null);
      await tester.pump();
      await tester.tap(find.text('新账号'));
      await _settleWithoutErrors(tester, 'account settings with a draft');
      if (find.text('还有未保存的内容').evaluate().isEmpty) {
        await tester.tap(find.text('退出登录'));
        await _settleWithoutErrors(tester, 'logout draft guard');
      }
      expect(find.text('还有未保存的内容'), findsOneWidget);
      await tester.tap(find.text('继续编辑'));
      await _settleWithoutErrors(tester, 'cancel logout');
      expect(controller.authenticated, isTrue);
      expect(
        tester
            .widget<quill.QuillEditor>(find.byType(quill.QuillEditor))
            .controller
            .document
            .toPlainText()
            .trim(),
        '退出前还没有保存的账号草稿',
      );

      await tester.tap(find.text('新账号'));
      await _settleWithoutErrors(tester, 'retry account action');
      if (find.text('还有未保存的内容').evaluate().isEmpty) {
        await tester.tap(find.text('退出登录'));
        await _settleWithoutErrors(tester, 'retry logout guard');
      }
      await tester.tap(find.text('放弃修改'));
      await _settleWithoutErrors(tester, 'discard account draft');
      if (find.text('退出登录').evaluate().isNotEmpty) {
        await tester.tap(find.text('退出登录'));
        await _settleWithoutErrors(tester, 'confirm logout');
      }
      expect(controller.authenticated, isFalse);
      expect(find.byType(TaskEditor), findsNothing);
      expect(find.byType(AuthScreen), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
}
