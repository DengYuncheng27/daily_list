import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../core/app_controller.dart';
import '../core/models.dart';
import 'date_popover.dart';

const _accent = Color(0xFF55ADB1);
const _muted = Color(0xFF99A4A7);

class TaskListView extends StatefulWidget {
  const TaskListView({
    super.key,
    required this.controller,
    required this.tasks,
    required this.title,
    this.subtitle,
    required this.onSelect,
    required this.onCreate,
    this.selectedId,
  });
  final AppController controller;
  final List<TaskItem> tasks;
  final String title;
  final String? subtitle;
  final ValueChanged<TaskItem> onSelect;
  final VoidCallback onCreate;
  final String? selectedId;
  @override
  State<TaskListView> createState() => _TaskListViewState();
}

class _TaskListViewState extends State<TaskListView> {
  final selected = <String>{};
  final listFocus = FocusNode();
  bool showCompleted = false;
  String sort = 'date';
  String? lastSelected;
  AppController get c => widget.controller;

  @override
  void dispose() {
    listFocus.dispose();
    super.dispose();
  }

  List<TaskItem> sorted(Iterable<TaskItem> source) {
    final tasks = source.toList();
    tasks.sort((a, b) {
      if (sort == 'priority') {
        final priority = b.priority.compareTo(a.priority);
        if (priority != 0) return priority;
      }
      if (sort == 'title') return a.title.compareTo(b.title);
      if (sort == 'list') {
        final list = (c.taskList(a.listId)?.name ?? '收件箱').compareTo(
          c.taskList(b.listId)?.name ?? '收件箱',
        );
        if (list != 0) return list;
      }
      final date = (a.dueDate ?? DateTime(9999)).compareTo(
        b.dueDate ?? DateTime(9999),
      );
      if (date != 0) return date;
      final time = (a.dueTime ?? '99:99').compareTo(b.dueTime ?? '99:99');
      if (time != 0) return time;
      return b.priority.compareTo(a.priority);
    });
    return tasks;
  }

  Map<String, List<TaskItem>> grouped(List<TaskItem> active) {
    final groups = <String, List<TaskItem>>{};
    for (final task in active) {
      final group = sort == 'list'
          ? c.taskList(task.listId)?.name ?? '收件箱'
          : sort == 'priority'
          ? ['无优先级', '低优先级', '中优先级', '高优先级'][task.priority]
          : sort == 'title'
          ? '全部'
          : task.itemType == 'note'
          ? '笔记'
          : dateGroup(task.dueDate);
      groups.putIfAbsent(group, () => []).add(task);
    }
    return groups;
  }

  List<TaskItem> get visibleTasks {
    final active = sorted(widget.tasks.where((task) => !task.completed));
    return [
      ...grouped(active).values.expand((tasks) => tasks),
      if (showCompleted || active.isEmpty)
        ...sorted(widget.tasks.where((task) => task.completed)),
    ];
  }

  Future<void> run(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('操作失败：$error')));
      }
    }
  }

  void choose(TaskItem task) {
    listFocus.requestFocus();
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isShiftPressed && lastSelected != null) {
      final order = visibleTasks;
      final from = order.indexWhere((item) => item.id == lastSelected);
      final to = order.indexWhere((item) => item.id == task.id);
      if (from >= 0 && to >= 0) {
        setState(() {
          selected.addAll(
            order
                .sublist(from < to ? from : to, (from > to ? from : to) + 1)
                .map((t) => t.id),
          );
        });
      }
    } else if (keyboard.isControlPressed ||
        keyboard.isMetaPressed ||
        selected.isNotEmpty) {
      setState(() {
        if (!selected.add(task.id)) selected.remove(task.id);
      });
    } else {
      widget.onSelect(task);
    }
    lastSelected = task.id;
  }

  Future<void> dates(TaskItem task, {GlobalKey? anchor}) async {
    final result = await showTaskSchedulePicker(
      context,
      task: task,
      anchorKey: anchor,
    );
    if (result != null) {
      await run(() => c.saveTask(result.applyTo(c.getTask(task.id) ?? task)));
    }
  }

  Future<void> moveToList(List<TaskItem> tasks) async {
    final id = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('移动到清单'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'inbox'),
            child: const Text('收件箱'),
          ),
          for (final list in c.lists.where((l) => l.id != 'inbox'))
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, list.id),
              child: Text(list.name),
            ),
        ],
      ),
    );
    if (id != null) {
      await run(() async {
        for (final task in tasks) {
          await c.saveTask((c.getTask(task.id) ?? task).copyWith(listId: id));
        }
      });
    }
  }

  Future<void> priority(List<TaskItem> tasks) async {
    final value = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('设置优先级'),
        children: [
          for (final value in [3, 2, 1, 0])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, value),
              child: Text(['无优先级', '低优先级', '中优先级', '高优先级'][value]),
            ),
        ],
      ),
    );
    if (value != null) {
      await run(() async {
        for (final task in tasks) {
          await c.saveTask(
            (c.getTask(task.id) ?? task).copyWith(priority: value),
          );
        }
      });
    }
  }

  Future<void> menu(TaskItem task, Offset position) async {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final value = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        const PopupMenuItem(value: 'date', child: Text('日期与重复')),
        const PopupMenuItem(value: 'priority', child: Text('优先级')),
        const PopupMenuItem(value: 'move', child: Text('移动到清单')),
        const PopupMenuItem(value: 'copy', child: Text('复制')),
        PopupMenuItem(
          value: 'type',
          child: Text(task.itemType == 'note' ? '转换为任务' : '转换为笔记'),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'delete',
          child: Text('删除', style: TextStyle(color: Colors.redAccent)),
        ),
      ],
    );
    if (!mounted) return;
    switch (value) {
      case 'date':
        await dates(task);
      case 'priority':
        await priority([task]);
      case 'move':
        await moveToList([task]);
      case 'copy':
        await run(
          () => c.saveTask(
            task.copyWith(
              id: const Uuid().v4(),
              title: '${task.title}（副本）',
              version: 0,
              completed: false,
              completedAt: null,
            ),
          ),
        );
      case 'type':
        await run(
          () => c.saveTask(
            task.copyWith(
              itemType: task.itemType == 'note' ? 'task' : 'note',
              completed: false,
              completedAt: null,
            ),
          ),
        );
      case 'delete':
        await run(() => c.deleteTask(task.id));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('已删除'),
              action: SnackBarAction(
                label: '撤销',
                onPressed: () =>
                    run(() => c.saveTask(task.copyWith(deleted: false))),
              ),
            ),
          );
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    selected.removeWhere((id) => !widget.tasks.any((task) => task.id == id));
    final active = sorted(widget.tasks.where((task) => !task.completed));
    final done = sorted(widget.tasks.where((task) => task.completed));
    final groups = grouped(active);
    final batch = widget.tasks
        .where((task) => selected.contains(task.id))
        .toList();
    return Focus(
      focusNode: listFocus,
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent ||
            (event.logicalKey != LogicalKeyboardKey.arrowDown &&
                event.logicalKey != LogicalKeyboardKey.arrowUp)) {
          return KeyEventResult.ignored;
        }
        final tasks = visibleTasks;
        if (tasks.isEmpty) return KeyEventResult.ignored;
        final current = tasks.indexWhere((t) => t.id == widget.selectedId);
        final next =
            (current +
                    (event.logicalKey == LogicalKeyboardKey.arrowDown ? 1 : -1))
                .clamp(0, tasks.length - 1);
        widget.onSelect(tasks[next]);
        return KeyEventResult.handled;
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 12, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    selected.isEmpty
                        ? widget.subtitle ?? '${active.length} 项'
                        : '已选择 ${selected.length} 项',
                    style: const TextStyle(fontSize: 11, color: _muted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (selected.isNotEmpty) ...[
                  IconButton(
                    tooltip: '批量完成',
                    icon: const Icon(Icons.done_all, size: 18),
                    onPressed: () => run(() async {
                      for (final task in batch.where(
                        (t) => t.itemType != 'note' && !t.completed,
                      )) {
                        await c.toggleTask(task.id);
                      }
                      if (mounted) setState(selected.clear);
                    }),
                  ),
                  IconButton(
                    tooltip: '批量设置日期',
                    icon: const Icon(Icons.event, size: 18),
                    onPressed: () async {
                      if (batch.isEmpty) return;
                      final result = await showTaskSchedulePicker(
                        context,
                        task: batch.first,
                      );
                      if (result != null) {
                        await run(() async {
                          for (final task in batch) {
                            await c.saveTask(
                              result.applyTo(c.getTask(task.id) ?? task),
                            );
                          }
                        });
                      }
                    },
                  ),
                  IconButton(
                    tooltip: '批量设置优先级',
                    icon: const Icon(Icons.flag_outlined, size: 18),
                    onPressed: () => priority(batch),
                  ),
                  IconButton(
                    tooltip: '批量移动',
                    icon: const Icon(Icons.drive_file_move_outlined, size: 18),
                    onPressed: () => moveToList(batch),
                  ),
                  IconButton(
                    tooltip: '取消多选',
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => setState(selected.clear),
                  ),
                ] else ...[
                  PopupMenuButton<String>(
                    tooltip: '分组与排序',
                    icon: const Icon(Icons.sort, size: 19),
                    onSelected: (value) => setState(() => sort = value),
                    itemBuilder: (_) => [
                      for (final item in {
                        'date': '按日期',
                        'priority': '按优先级',
                        'list': '按清单',
                        'title': '按标题',
                      }.entries)
                        CheckedPopupMenuItem(
                          value: item.key,
                          checked: sort == item.key,
                          child: Text(item.value),
                        ),
                    ],
                  ),
                  IconButton(
                    tooltip: '多选任务',
                    icon: const Icon(Icons.checklist, size: 19),
                    onPressed: () {
                      if (active.isNotEmpty) {
                        setState(() => selected.add(active.first.id));
                      }
                    },
                  ),
                ],
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(22, 0, 22, 24),
              children: [
                if (active.isEmpty && done.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 70),
                    child: Column(
                      children: [
                        Icon(
                          Icons.inbox_outlined,
                          size: 42,
                          color: _accent.withValues(alpha: .4),
                        ),
                        const SizedBox(height: 16),
                        const Text('这里还没有内容', style: TextStyle(color: _muted)),
                        TextButton(
                          onPressed: widget.onCreate,
                          child: const Text('添加任务'),
                        ),
                      ],
                    ),
                  ),
                for (final group in groups.entries) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(2, 12, 0, 5),
                    child: Text(
                      '${group.key}  ${group.value.length}',
                      style: TextStyle(
                        fontSize: 11,
                        color: group.key == '已逾期'
                            ? const Color(0xFFCE7C72)
                            : _muted,
                      ),
                    ),
                  ),
                  for (final task in group.value) taskRow(task),
                ],
                if (done.isNotEmpty) ...[
                  InkWell(
                    onTap: () => setState(() => showCompleted = !showCompleted),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      child: Row(
                        children: [
                          Icon(
                            showCompleted || active.isEmpty
                                ? Icons.expand_more
                                : Icons.chevron_right,
                            size: 18,
                          ),
                          Text(
                            '已完成  ${done.length}',
                            style: const TextStyle(color: _muted, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (showCompleted || active.isEmpty)
                    for (final task in done) taskRow(task),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget taskRow(TaskItem task) {
    final list = c.taskList(task.listId);
    final selectedRow =
        selected.contains(task.id) ||
        (selected.isEmpty && widget.selectedId == task.id);
    final anchor = GlobalKey();
    final note = task.itemType == 'note';
    final overdue =
        !task.completed &&
        task.dueDate != null &&
        DateTime(
          task.dueDate!.year,
          task.dueDate!.month,
          task.dueDate!.day,
        ).isBefore(DateUtils.dateOnly(DateTime.now()));
    return GestureDetector(
      onSecondaryTapDown: (event) => menu(task, event.globalPosition),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          color: selectedRow ? const Color(0xFFE8F3F3) : Colors.transparent,
          border: Border(
            left: BorderSide(width: 3, color: Color(list?.color ?? 0xFF76ADA5)),
            bottom: const BorderSide(color: Color(0xFFEDF1F2), width: .7),
          ),
        ),
        child: InkWell(
          onTap: () => choose(task),
          onLongPress: () => setState(() => selected.add(task.id)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(7, 11, 9, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 29,
                  height: 25,
                  child: selected.isNotEmpty
                      ? Checkbox(
                          value: selected.contains(task.id),
                          onChanged: (_) => setState(() {
                            if (!selected.add(task.id)) {
                              selected.remove(task.id);
                            }
                          }),
                        )
                      : note
                      ? const Icon(
                          Icons.description_outlined,
                          color: _accent,
                          size: 18,
                        )
                      : Checkbox(
                          value: task.completed,
                          onChanged: (_) => run(() => c.toggleTask(task.id)),
                          side: BorderSide(
                            color: [
                              const Color(0xFFAFB8BC),
                              const Color(0xFF6494D6),
                              const Color(0xFFE0AF4C),
                              const Color(0xFFD96363),
                            ][task.priority],
                          ),
                        ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        task.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.55,
                          color: task.completed
                              ? _muted
                              : const Color(0xFF3F4B50),
                          decoration: task.completed
                              ? TextDecoration.lineThrough
                              : null,
                        ),
                      ),
                      if (task.notes.trim().isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Text(
                            task.notes.trim(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11, color: _muted),
                          ),
                        ),
                      const SizedBox(height: 5),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            list?.name ?? '收件箱',
                            style: const TextStyle(color: _muted, fontSize: 11),
                          ),
                          if (task.subtasks.isNotEmpty)
                            Text(
                              '${task.subtasks.where((s) => s.completed).length}/${task.subtasks.length}',
                              style: const TextStyle(
                                color: _muted,
                                fontSize: 10,
                              ),
                            ),
                          if (task.attachments.isNotEmpty)
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.attach_file,
                                  size: 12,
                                  color: _muted,
                                ),
                                Text(
                                  '${task.attachments.length}',
                                  style: const TextStyle(
                                    fontSize: 10,
                                    color: _muted,
                                  ),
                                ),
                              ],
                            ),
                          if (task.recurrence != 'none' ||
                              task.recurrenceRule != null)
                            const Icon(Icons.repeat, size: 12, color: _muted),
                          for (final tag in task.tags.take(3))
                            Text(
                              '#$tag',
                              style: const TextStyle(
                                fontSize: 10,
                                color: _accent,
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (task.dueDate != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: InkWell(
                      key: anchor,
                      onTap: () => dates(task, anchor: anchor),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Text(
                          shortDate(task),
                          style: TextStyle(
                            fontSize: 11,
                            color: overdue ? const Color(0xFFD96860) : _muted,
                          ),
                        ),
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
}

String dateGroup(DateTime? value) {
  if (value == null) return '未安排';
  final now = DateTime.now();
  final delta = DateTime.utc(
    value.year,
    value.month,
    value.day,
  ).difference(DateTime.utc(now.year, now.month, now.day)).inDays;
  if (delta < 0) return '已逾期';
  if (delta == 0) return '今天';
  if (delta == 1) return '明天';
  return '${value.month}月${value.day}日';
}

String shortDate(TaskItem task) {
  final day = task.dueDate!;
  final group = dateGroup(day);
  final label = group == '今天' || group == '明天'
      ? group
      : '${day.month}月${day.day}日';
  return '$label${task.dueTime == null ? '' : '\n${task.dueTime}'}';
}
