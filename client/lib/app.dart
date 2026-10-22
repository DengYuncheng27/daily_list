import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:uuid/uuid.dart';

import 'core/app_controller.dart';
import 'core/models.dart';
import 'ui/auth_screen.dart';
import 'ui/calendar_view.dart';
import 'ui/task_editor.dart';
import 'ui/task_list.dart';
import 'ui/quick_add.dart';
import 'ui/ticktick_import_screen.dart';

class _EmptyInspector extends StatelessWidget {
  const _EmptyInspector();
  @override
  Widget build(BuildContext context) => ColoredBox(
    color: const Color(0xFFFDFEFE),
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.article_outlined,
              size: 44,
              color: dayflowAccent.withValues(alpha: .35),
            ),
            const SizedBox(height: 18),
            const Text(
              '选择一个任务或笔记',
              style: TextStyle(fontSize: 15, color: Color(0xFF758387)),
            ),
            const SizedBox(height: 9),
            const Text(
              '在这里编辑内容、子任务、图片和附件',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Color(0xFFA4AFB2)),
            ),
          ],
        ),
      ),
    ),
  );
}

class DayflowApp extends StatelessWidget {
  const DayflowApp({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '日序 Dayflow',
    debugShowCheckedModeBanner: false,
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
    localizationsDelegates: [
      ...GlobalMaterialLocalizations.delegates,
      quill.FlutterQuillLocalizations.delegate,
    ],
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: dayflowAccent,
        primary: dayflowAccent,
        surface: Colors.white,
        error: const Color(0xFFD55E65),
      ),
      scaffoldBackgroundColor: Colors.white,
      fontFamily: 'DayflowSans',
      fontFamilyFallback: const [
        'PingFang SC',
        'Noto Sans SC',
        'Roboto',
        'sans-serif',
      ],
      textTheme: const TextTheme(
        bodyMedium: TextStyle(fontSize: 14, color: Color(0xFF42495B)),
        bodySmall: TextStyle(fontSize: 12, color: Color(0xFF8B92A4)),
      ),
      dividerColor: const Color(0xFFEBEDF3),
      dividerTheme: const DividerThemeData(
        color: Color(0xFFEBEDF3),
        thickness: .8,
        space: 1,
      ),
      iconTheme: const IconThemeData(size: 20, color: Color(0xFF8991A2)),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFFF8F9FC),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 15,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xFFEBEDF3)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: dayflowAccent),
        ),
        labelStyle: const TextStyle(fontSize: 13, color: Color(0xFF9299A9)),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: const Color(0xFF6D7589),
          side: const BorderSide(color: Color(0xFFE2E5EE)),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          textStyle: const TextStyle(fontSize: 12),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: dayflowAccent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(textStyle: const TextStyle(fontSize: 12)),
      ),
      checkboxTheme: CheckboxThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
        side: const BorderSide(color: Color(0xFFCED3E0), width: 1.5),
        visualDensity: VisualDensity.compact,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      tooltipTheme: const TooltipThemeData(
        waitDuration: Duration(milliseconds: 500),
      ),
    ),
    home: ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (controller.loading) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        if (!controller.authenticated &&
            !controller.demoMode &&
            controller.tasks.isEmpty &&
            !controller.requiresLogin) {
          return AuthScreen(controller: controller);
        }
        return Workspace(
          key: ValueKey(
            '${controller.demoMode}:${controller.user?.id}:${controller.serverUrl}',
          ),
          controller: controller,
        );
      },
    ),
  );
}

class Workspace extends StatefulWidget {
  const Workspace({super.key, required this.controller});
  final AppController controller;
  @override
  State<Workspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<Workspace> with WidgetsBindingObserver {
  String section = 'today';
  String query = '';
  bool editorOpen = false;
  TaskItem? editing;
  DateTime? newDate;
  bool showSearch = false;
  final searchController = TextEditingController();
  final searchFocus = FocusNode();
  final scaffold = GlobalKey<ScaffoldState>();
  final editorKey = GlobalKey<TaskEditorState>();
  final quickKey = GlobalKey<QuickAddState>();
  bool sidebarVisible = true;
  double detailWidth = 420;
  Timer? syncTimer;
  Timer? reminderTimer;
  final reminded = <String>{};
  AppController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    syncTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (c.authenticated && !c.demoMode) unawaited(c.sync());
    });
    reminderTimer = Timer.periodic(
      const Duration(seconds: 20),
      (_) => checkReminders(),
    );
  }

  @override
  void dispose() {
    syncTimer?.cancel();
    reminderTimer?.cancel();
    searchController.dispose();
    searchFocus.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && c.authenticated) {
      unawaited(c.sync());
    }
  }

  void checkReminders() {
    final now = DateTime.now();
    for (final task in c.tasks) {
      if (task.completed ||
          task.reminderMinutes == null ||
          task.dueDate == null ||
          task.dueTime == null) {
        continue;
      }
      final time = task.dueTime!.split(':');
      if (time.length != 2) continue;
      final hour = int.tryParse(time[0]);
      final minute = int.tryParse(time[1]);
      if (hour == null || minute == null) continue;
      final due = DateTime(
        task.dueDate!.year,
        task.dueDate!.month,
        task.dueDate!.day,
        hour,
        minute,
      );
      final at = due.subtract(Duration(minutes: task.reminderMinutes!));
      final key = '${task.id}:${at.toIso8601String()}';
      if (!reminded.contains(key) &&
          !at.isAfter(now) &&
          now.difference(at).inMinutes < 5) {
        reminded.add(key);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 10),
            content: Text('待办提醒：${task.title}'),
            action: SnackBarAction(
              label: '查看',
              onPressed: () => openTask(task),
            ),
          ),
        );
      }
    }
  }

  void openTask(TaskItem task) => setState(() {
    editing = task;
    newDate = null;
    editorOpen = true;
  });
  void createTask([DateTime? date]) => setState(() {
    editing = null;
    newDate = date ?? (section == 'today' ? DateTime.now() : null);
    editorOpen = true;
  });
  void closeEditor() => setState(() {
    editorOpen = false;
    editing = null;
  });

  Future<void> focusQuickAdd() async {
    if (editorOpen && MediaQuery.sizeOf(context).width < 900) {
      if (!(await editorKey.currentState?.requestClose() ?? true)) return;
      if (!mounted) return;
      closeEditor();
    }
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => quickKey.currentState?.requestFocus(),
    );
  }

  String get currentListId =>
      [
            'calendar',
            'today',
            'week',
            'all',
            'notes',
            'completed',
          ].contains(section) ||
          section.startsWith('tag:')
      ? 'inbox'
      : section;

  String get title => switch (section) {
    'calendar' => '月历',
    'today' => '今天',
    'week' => '最近 7 天',
    'all' => '全部任务',
    'notes' => '笔记',
    'completed' => '已完成',
    _ =>
      section.startsWith('tag:')
          ? '#${section.substring(4)}'
          : c.taskList(section)?.name ?? '收件箱',
  };

  List<TaskItem> get filtered {
    final now = DateTime.now();
    final day = DateTime(now.year, now.month, now.day);
    return c.tasks.where((task) {
      if (query.isNotEmpty) {
        return '${task.title} ${task.notes} ${task.tags.join(' ')}'
            .toLowerCase()
            .contains(query.toLowerCase());
      }
      return switch (section) {
        'calendar' || 'all' => !task.completed,
        'notes' => task.itemType == 'note',
        'today' =>
          task.itemType != 'note' &&
              !task.completed &&
              task.dueDate != null &&
              !DateTime(
                task.dueDate!.year,
                task.dueDate!.month,
                task.dueDate!.day,
              ).isAfter(day),
        'week' =>
          task.itemType != 'note' &&
              !task.completed &&
              task.dueDate != null &&
              !task.dueDate!.isBefore(day) &&
              task.dueDate!.isBefore(day.add(const Duration(days: 7))),
        'completed' => task.completed,
        _ =>
          section.startsWith('tag:')
              ? task.tags.contains(section.substring(4))
              : task.listId == section,
      };
    }).toList();
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.keyN, control: true): () =>
          focusQuickAdd(),
      const SingleActivator(LogicalKeyboardKey.keyN, meta: true): () =>
          focusQuickAdd(),
      const SingleActivator(LogicalKeyboardKey.keyF, control: true):
          focusSearch,
      const SingleActivator(LogicalKeyboardKey.keyF, meta: true): focusSearch,
      const SingleActivator(LogicalKeyboardKey.escape): () async {
        if (editorOpen &&
            (await editorKey.currentState?.requestClose() ?? true)) {
          if (mounted && editorOpen) closeEditor();
        } else if (query.isNotEmpty) {
          searchController.clear();
          setState(() => query = '');
        }
      },
    },
    child: Focus(
      autofocus: true,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 900;
          final desktop = constraints.maxWidth >= 760;
          final showSidebar = desktop && sidebarVisible;
          final sidebarWidth = constraints.maxWidth < 1280 ? 190.0 : 220.0;
          final maxDetail =
              (constraints.maxWidth - (showSidebar ? sidebarWidth : 0) - 380)
                  .clamp(320.0, 700.0);
          final inspectorWidth = detailWidth.clamp(320.0, maxDetail);
          final editor = TaskEditor(
            key: editorKey,
            controller: c,
            task: editing == null ? null : c.getTask(editing!.id) ?? editing,
            initialDate: newDate,
            initialListId: currentListId,
            onClose: closeEditor,
          );
          return Scaffold(
            key: scaffold,
            drawer: desktop
                ? null
                : Drawer(
                    width: 265,
                    shape: const RoundedRectangleBorder(),
                    child: sidebar(),
                  ),
            body: SafeArea(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (showSidebar)
                    SizedBox(width: sidebarWidth, child: sidebar()),
                  if (showSidebar) const VerticalDivider(width: 1),
                  if (!editorOpen || wide)
                    Expanded(
                      child: Column(
                        children: [
                          topbar(desktop),
                          if (c.syncError != null ||
                              c.requiresLogin ||
                              c.conflicts.isNotEmpty)
                            syncBanner(),
                          if (c.demoMode) demoBanner(),
                          if (section != 'completed')
                            QuickAdd(
                              key: quickKey,
                              controller: c,
                              listId: currentListId,
                              defaultDate: section == 'today'
                                  ? DateTime(
                                      DateTime.now().year,
                                      DateTime.now().month,
                                      DateTime.now().day,
                                    )
                                  : null,
                              noteMode: section == 'notes',
                              onCreated: openTask,
                              onExpand: () => createTask(),
                            ),
                          Expanded(
                            child: section == 'calendar' && query.isEmpty
                                ? MonthCalendar(
                                    controller: c,
                                    tasks: c.tasks,
                                    onSelect: openTask,
                                    onCreate: createTask,
                                  )
                                : TaskListView(
                                    controller: c,
                                    tasks: filtered,
                                    title: query.isNotEmpty ? '搜索结果' : title,
                                    subtitle: query.isNotEmpty
                                        ? '找到 ${filtered.length} 项任务'
                                        : subtitle,
                                    onSelect: openTask,
                                    onCreate: () => focusQuickAdd(),
                                    selectedId: editing?.id,
                                  ),
                          ),
                        ],
                      ),
                    ),
                  if (wide) ...[
                    MouseRegion(
                      cursor: SystemMouseCursors.resizeLeftRight,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onHorizontalDragUpdate: (details) => setState(() {
                          detailWidth = (inspectorWidth - details.delta.dx)
                              .clamp(320.0, maxDetail);
                        }),
                        child: const SizedBox(
                          width: 5,
                          child: Center(child: VerticalDivider(width: 1)),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: inspectorWidth,
                      child: editorOpen ? editor : const _EmptyInspector(),
                    ),
                  ] else if (editorOpen)
                    Expanded(child: editor),
                ],
              ),
            ),
            bottomNavigationBar: desktop || editorOpen
                ? null
                : NavigationBar(
                    height: 64,
                    backgroundColor: const Color(0xFFFAFBFE),
                    indicatorColor: const Color(0xFFDFF0F0),
                    selectedIndex: section == 'today'
                        ? 0
                        : section == 'calendar'
                        ? 1
                        : 2,
                    onDestinationSelected: (index) => setState(() {
                      section = ['today', 'calendar', 'inbox'][index];
                      query = '';
                      searchController.clear();
                    }),
                    destinations: const [
                      NavigationDestination(
                        icon: Icon(Icons.wb_sunny_outlined),
                        selectedIcon: Icon(
                          Icons.wb_sunny_rounded,
                          color: dayflowAccent,
                        ),
                        label: '今天',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.calendar_month_outlined),
                        selectedIcon: Icon(
                          Icons.calendar_month_rounded,
                          color: dayflowAccent,
                        ),
                        label: '月历',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.checklist_rounded),
                        label: '清单',
                      ),
                    ],
                  ),
          );
        },
      ),
    ),
  );

  String get subtitle => switch (section) {
    'today' => '${DateTime.now().month} 月 ${DateTime.now().day} 日 · 包含逾期未完成任务',
    'week' => '未来 7 天的安排',
    'notes' => '${filtered.length} 篇笔记',
    'completed' => '已完成的任务',
    _ => '${filtered.where((t) => !t.completed).length} 项待完成',
  };

  void focusSearch() {
    setState(() => showSearch = true);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => searchFocus.requestFocus(),
    );
  }

  Widget topbar(bool desktop) => Container(
    height: 60,
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: Row(
      children: [
        IconButton(
          tooltip: desktop ? '切换侧边栏' : '打开清单',
          onPressed: () {
            if (desktop) {
              setState(() => sidebarVisible = !sidebarVisible);
            } else {
              scaffold.currentState?.openDrawer();
            }
          },
          icon: const Icon(Icons.menu_open_rounded, size: 21),
        ),
        if (showSearch)
          Expanded(
            child: TextField(
              controller: searchController,
              focusNode: searchFocus,
              style: const TextStyle(fontSize: 14),
              decoration: InputDecoration(
                hintText: '搜索任务、笔记和标签',
                prefixIcon: const Icon(Icons.search_rounded, size: 17),
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                suffixIcon: IconButton(
                  tooltip: '关闭搜索',
                  icon: const Icon(Icons.close_rounded, size: 17),
                  onPressed: () {
                    searchController.clear();
                    setState(() {
                      query = '';
                      showSearch = false;
                    });
                  },
                ),
              ),
              onChanged: (value) => setState(() => query = value),
            ),
          )
        else
          Expanded(
            child: Text(
              title,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: Color(0xFF272F33),
              ),
            ),
          ),
        if (!showSearch)
          IconButton(
            tooltip: '搜索任务',
            onPressed: focusSearch,
            icon: const Icon(Icons.search_rounded, size: 21),
          ),
        IconButton(
          tooltip: '添加任务',
          onPressed: focusQuickAdd,
          icon: const Icon(Icons.add_rounded, size: 21),
        ),
      ],
    ),
  );

  Widget sidebar() {
    final pending = c.tasks
        .where((t) => !t.completed && t.itemType != 'note')
        .length;
    final completed = c.tasks.where((t) => t.completed).length;
    return Container(
      color: const Color(0xFFF3F8F8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 28, 20, 26),
            child: Row(
              children: [
                Icon(Icons.view_day_rounded, size: 26, color: dayflowAccent),
                SizedBox(width: 10),
                Text(
                  '日序',
                  style: TextStyle(
                    fontSize: 23,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 2,
                    color: Color(0xFF343C53),
                  ),
                ),
                SizedBox(width: 7),
                Flexible(
                  child: Text(
                    'DAYFLOW',
                    maxLines: 1,
                    overflow: TextOverflow.fade,
                    softWrap: false,
                    style: TextStyle(
                      fontSize: 8,
                      letterSpacing: 1.4,
                      color: Color(0xFFA3AABD),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              children: [
                nav(
                  'today',
                  '今天',
                  Icons.wb_sunny_outlined,
                  c.tasks
                      .where(
                        (t) =>
                            !t.completed &&
                            t.itemType != 'note' &&
                            t.dueDate != null &&
                            DateUtils.dateOnly(t.dueDate!).compareTo(
                                  DateUtils.dateOnly(DateTime.now()),
                                ) <=
                                0,
                      )
                      .length,
                ),
                nav('week', '最近 7 天', Icons.date_range_outlined, null),
                nav('calendar', '月历', Icons.calendar_month_outlined, null),
                nav('all', '全部任务', Icons.layers_outlined, pending),
                nav(
                  'notes',
                  '笔记',
                  Icons.description_outlined,
                  c.tasks.where((t) => t.itemType == 'note').length,
                ),
                const SizedBox(height: 25),
                Padding(
                  padding: const EdgeInsets.only(left: 13, right: 6, bottom: 8),
                  child: Row(
                    children: [
                      const Text(
                        '我的清单',
                        style: TextStyle(
                          fontSize: 10,
                          color: Color(0xFFA4ABBA),
                          letterSpacing: 1.3,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: '新建清单',
                        onPressed: () => editList(),
                        icon: const Icon(Icons.add_rounded, size: 17),
                        constraints: const BoxConstraints.tightFor(
                          width: 28,
                          height: 28,
                        ),
                        padding: EdgeInsets.zero,
                      ),
                    ],
                  ),
                ),
                nav(
                  'inbox',
                  '收件箱',
                  Icons.inbox_outlined,
                  c.tasks
                      .where((t) => t.listId == 'inbox' && !t.completed)
                      .length,
                ),
                ...c.lists
                    .where((l) => l.id != 'inbox')
                    .map(
                      (list) => nav(
                        list.id,
                        list.name,
                        Icons.tag_rounded,
                        c.tasks
                            .where((t) => t.listId == list.id && !t.completed)
                            .length,
                        list: list,
                      ),
                    ),
                const SizedBox(height: 25),
                nav('completed', '已完成', Icons.task_alt_rounded, completed),
                if (c.tasks.any((task) => task.tags.isNotEmpty)) ...[
                  const Padding(
                    padding: EdgeInsets.fromLTRB(13, 25, 0, 10),
                    child: Text(
                      '标签',
                      style: TextStyle(fontSize: 11, color: Color(0xFF8A979B)),
                    ),
                  ),
                  for (final tag
                      in (c.tasks.expand((task) => task.tags).toSet().toList()
                        ..sort()))
                    nav(
                      'tag:$tag',
                      tag,
                      Icons.tag,
                      c.tasks.where((task) => task.tags.contains(tag)).length,
                    ),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(25, 14, 22, 18),
            child: Row(
              children: [
                Icon(
                  c.demoMode
                      ? Icons.science_outlined
                      : c.syncing
                      ? Icons.sync_rounded
                      : c.syncError != null
                      ? Icons.cloud_off_outlined
                      : Icons.cloud_done_outlined,
                  size: 14,
                  color: c.syncError != null
                      ? const Color(0xFFC58E65)
                      : const Color(0xFF9CA6BB),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    c.demoMode
                        ? '本地体验空间'
                        : c.syncing
                        ? '正在同步…'
                        : c.pendingCount > 0
                        ? '${c.pendingCount} 项等待同步'
                        : '更改已保存',
                    style: const TextStyle(
                      fontSize: 10,
                      color: Color(0xFF9AA3B7),
                    ),
                  ),
                ),
                if (!c.demoMode)
                  IconButton(
                    tooltip: '立即同步',
                    onPressed: c.syncing ? null : () => c.sync(),
                    icon: const Icon(Icons.refresh_rounded, size: 15),
                    constraints: const BoxConstraints.tightFor(
                      width: 24,
                      height: 24,
                    ),
                    padding: EdgeInsets.zero,
                  ),
              ],
            ),
          ),
          const Divider(),
          InkWell(
            onTap: showAccount,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 19, 20, 21),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 16,
                    backgroundColor: const Color(0xFFE9ECF8),
                    child: Text(
                      c.demoMode
                          ? '序'
                          : (c.user?.name.isNotEmpty == true
                                ? c.user!.name.characters.first
                                : '我'),
                      style: const TextStyle(
                        fontSize: 12,
                        color: dayflowAccent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          c.demoMode ? '体验用户' : c.user?.name ?? '我的空间',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          c.demoMode ? '登录以同步你的任务' : '账号与同步',
                          style: const TextStyle(
                            fontSize: 9,
                            color: Color(0xFFA6ADBD),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(
                    Icons.settings_outlined,
                    size: 17,
                    color: Color(0xFFA3ABBA),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget nav(
    String id,
    String name,
    IconData icon,
    int? count, {
    ProjectList? list,
  }) {
    final active = section == id;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: active ? const Color(0xFFDFF0F0) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () {
            setState(() {
              section = id;
              query = '';
              searchController.clear();
            });
            if (scaffold.currentState?.isDrawerOpen ?? false) {
              Navigator.pop(context);
            }
          },
          onLongPress: list == null ? null : () => editList(list),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 18,
                  color: list != null
                      ? Color(list.color)
                      : active
                      ? dayflowAccent
                      : const Color(0xFF9AA3B7),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                      color: active ? dayflowAccent : const Color(0xFF747D91),
                    ),
                  ),
                ),
                if (list != null)
                  SizedBox(
                    width: 23,
                    height: 20,
                    child: IconButton(
                      tooltip: '编辑清单',
                      onPressed: () => editList(list),
                      padding: EdgeInsets.zero,
                      icon: const Icon(
                        Icons.more_horiz_rounded,
                        size: 15,
                        color: Color(0xFFAFB6C5),
                      ),
                    ),
                  ),
                if (count != null && count > 0)
                  Padding(
                    padding: const EdgeInsets.only(left: 5),
                    child: Text(
                      '$count',
                      style: TextStyle(
                        fontSize: 10,
                        color: active ? dayflowAccent : const Color(0xFFABB2C1),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget demoBanner() => Container(
    color: const Color(0xFFFCFCFE),
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 7),
    child: Row(
      children: [
        const Icon(Icons.science_outlined, size: 14, color: Color(0xFF9AA4C2)),
        const SizedBox(width: 8),
        const Expanded(
          child: Text(
            '体验空间 · 可以自由编辑，数据仅保存在这台设备',
            style: TextStyle(fontSize: 10, color: Color(0xFF9AA4B9)),
          ),
        ),
        InkWell(
          onTap: showLogin,
          child: const Padding(
            padding: EdgeInsets.only(left: 8),
            child: Text(
              '登录',
              style: TextStyle(fontSize: 11, color: dayflowAccent),
            ),
          ),
        ),
      ],
    ),
  );

  Widget syncBanner() => Material(
    color: const Color(0xFFFFF7E9),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 8),
      child: Row(
        children: [
          const Icon(
            Icons.info_outline_rounded,
            size: 16,
            color: Color(0xFFC29855),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              c.conflicts.isNotEmpty
                  ? '${c.conflicts.length} 项内容在其他设备上也有修改，请选择保留的版本'
                  : c.requiresLogin
                  ? '本地修改已保留，重新登录后继续同步'
                  : '同步暂不可用，本地修改已保存。${c.syncError ?? ''}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Color(0xFFA17C42)),
            ),
          ),
          TextButton(
            onPressed: c.conflicts.isNotEmpty
                ? showConflicts
                : c.requiresLogin
                ? showLogin
                : () => c.sync(),
            child: Text(
              c.conflicts.isNotEmpty
                  ? '处理'
                  : c.requiresLogin
                  ? '登录'
                  : '重试',
            ),
          ),
        ],
      ),
    ),
  );

  Future<void> showLogin() async {
    if (!(await quickKey.currentState?.requestClose() ?? true) || !mounted) {
      return;
    }
    if (editorOpen) {
      final allowed = await editorKey.currentState?.requestClose() ?? true;
      if (!allowed || !mounted) return;
      closeEditor();
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => AuthScreen(
          controller: c,
          onBack: () => Navigator.of(context).pop(),
        ),
      ),
    );
  }

  Future<void> showTickTickImport() async {
    final imported = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (context) => TickTickImportScreen(controller: c),
      ),
    );
    if (mounted && imported == true) {
      setState(() {
        section = 'all';
        query = '';
        searchController.clear();
      });
    }
  }

  Future<void> showAccount() async {
    if (!(await quickKey.currentState?.requestClose() ?? true) || !mounted) {
      return;
    }
    if (editorOpen) {
      final allowed = await editorKey.currentState?.requestClose() ?? true;
      if (!allowed || !mounted) return;
      closeEditor();
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        scrollable: true,
        title: const Text(
          '账号与同步',
          style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
        ),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                c.demoMode ? '当前为独立体验空间' : c.user?.email ?? '已缓存的离线空间',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              Text(
                c.demoMode
                    ? '登录后会切换到账号自己的空间。体验数据不会自动上传。'
                    : '服务器：${c.serverUrl}\n等待同步：${c.pendingCount} 项',
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFF8D96AA),
                  height: 1.8,
                ),
              ),
              const SizedBox(height: 18),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(
                  Icons.file_upload_outlined,
                  color: dayflowAccent,
                ),
                title: const Text('从滴答清单导入', style: TextStyle(fontSize: 14)),
                subtitle: const Text(
                  '选择 CSV 备份，预览后迁移数据',
                  style: TextStyle(fontSize: 11),
                ),
                trailing: const Icon(Icons.chevron_right, size: 18),
                onTap: () {
                  Navigator.pop(dialogContext);
                  showTickTickImport();
                },
              ),
              const SizedBox(height: 12),
              const Text(
                '任务提醒会在应用打开时显示。关闭应用后暂不发送系统推送。',
                style: TextStyle(
                  fontSize: 11,
                  height: 1.6,
                  color: Color(0xFF9CA5B8),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                '快捷键  Ctrl / ⌘ + N 新任务 · Ctrl / ⌘ + F 搜索',
                style: TextStyle(fontSize: 10, color: Color(0xFFA4ADBD)),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('关闭'),
          ),
          if (c.conflicts.isNotEmpty)
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                showConflicts();
              },
              child: const Text('同步冲突'),
            ),
          if (c.demoMode || c.requiresLogin)
            FilledButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                showLogin();
              },
              child: const Text('登录账号'),
            )
          else
            TextButton(
              onPressed: () async {
                Navigator.pop(dialogContext);
                if (c.pendingCount > 0) {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('还有未同步的修改'),
                      content: const Text(
                        '未同步内容会保留在该账号的本地缓存中。下次登录同一账号可继续同步，确定退出吗？',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('取消'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('退出登录'),
                        ),
                      ],
                    ),
                  );
                  if (confirmed != true) return;
                }
                await c.signOut();
              },
              child: const Text('退出登录'),
            ),
        ],
      ),
    );
  }

  Future<void> showConflicts() async {
    if (c.conflicts.isEmpty) return;
    final conflict = c.conflicts.first;
    final choice = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('选择保留的版本'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '这项内容在两台设备上被修改过。选择后会继续同步。',
                  style: TextStyle(fontSize: 12, height: 1.7),
                ),
                const SizedBox(height: 20),
                const Text(
                  '这台设备',
                  style: TextStyle(fontSize: 11, color: dayflowAccent),
                ),
                const SizedBox(height: 7),
                Text(
                  conflict.localDeleted ? '已删除' : conflict.localTitle,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                if (!conflict.localDeleted)
                  Text(
                    _conflictSummary(conflict.localPayload),
                    style: const TextStyle(fontSize: 11, height: 1.6),
                  ),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Divider(),
                ),
                const Text(
                  '服务器上的版本',
                  style: TextStyle(fontSize: 11, color: Color(0xFF9CA4B6)),
                ),
                const SizedBox(height: 7),
                Text(
                  conflict.server['deleted'] == true
                      ? '已删除'
                      : conflict.serverTitle,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                if (conflict.server['deleted'] != true)
                  Text(
                    _conflictSummary(
                      Map<String, dynamic>.from(
                        conflict.server['payload'] as Map? ?? {},
                      ),
                    ),
                    style: const TextStyle(fontSize: 11, height: 1.6),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('稍后'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('保留服务器版'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('保留本机版'),
          ),
        ],
      ),
    );
    if (choice != null) {
      await c.resolveConflict(conflict.entityId, keepLocal: choice);
      if (mounted && c.conflicts.isNotEmpty) await showConflicts();
    }
  }

  String _conflictSummary(Map<String, dynamic> payload) {
    if (!payload.containsKey('title')) return '';
    final text =
        '${payload['completed'] == true ? '已完成' : '待完成'} · ${payload['dueDate'] ?? '无日期'} ${payload['dueTime'] ?? ''}'
        '\n${payload['notes'] ?? ''}';
    return text.length > 500 ? '${text.substring(0, 500)}…' : text;
  }

  Future<void> editList([ProjectList? list]) async {
    final name = TextEditingController(text: list?.name ?? '');
    var color = list?.color ?? 0xFF5C6FE8;
    String? validation;
    const colors = [
      0xFF5C6FE8,
      0xFF58A793,
      0xFFE1A25D,
      0xFFD78298,
      0xFF8B78C6,
      0xFF62A0C9,
    ];
    final action = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: Text(
            list == null ? '新建清单' : '编辑清单',
            style: const TextStyle(fontSize: 19),
          ),
          content: SizedBox(
            width: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: name,
                  autofocus: true,
                  maxLength: 50,
                  decoration: InputDecoration(
                    labelText: '清单名称',
                    errorText: validation,
                  ),
                  onSubmitted: (value) {
                    if (value.trim().isNotEmpty) Navigator.pop(context, 'save');
                  },
                ),
                const SizedBox(height: 20),
                Row(
                  children: colors
                      .map(
                        (value) => Padding(
                          padding: const EdgeInsets.only(right: 11),
                          child: Semantics(
                            label: '清单颜色 ${colors.indexOf(value) + 1}',
                            selected: value == color,
                            child: InkWell(
                              onTap: () => setDialog(() => color = value),
                              borderRadius: BorderRadius.circular(20),
                              child: CircleAvatar(
                                radius: 17,
                                backgroundColor: Color(value),
                                child: value == color
                                    ? const Icon(
                                        Icons.check_rounded,
                                        color: Colors.white,
                                        size: 17,
                                      )
                                    : null,
                              ),
                            ),
                          ),
                        ),
                      )
                      .toList(),
                ),
                if (list != null)
                  const Padding(
                    padding: EdgeInsets.only(top: 18),
                    child: Text(
                      '删除清单会将其中的任务移到收件箱。',
                      style: TextStyle(fontSize: 11, color: Color(0xFF9AA3B5)),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            if (list != null)
              TextButton(
                onPressed: () => Navigator.pop(context, 'delete'),
                child: const Text(
                  '删除清单',
                  style: TextStyle(color: Color(0xFFCF7181)),
                ),
              ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                if (name.text.trim().isEmpty) {
                  setDialog(() => validation = '请输入清单名称');
                  return;
                }
                Navigator.pop(context, 'save');
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (action == 'save') {
      await c.saveList(
        list?.copyWith(name: name.text.trim(), color: color) ??
            ProjectList(
              id: const Uuid().v4(),
              name: name.text.trim(),
              color: color,
            ),
      );
    } else if (action == 'delete' && list != null) {
      await c.deleteList(list.id);
      if (mounted && section == list.id) setState(() => section = 'inbox');
    }
    // TextField's closing route still owns its controller during the transition.
    Future<void>.delayed(const Duration(milliseconds: 350), name.dispose);
  }
}
