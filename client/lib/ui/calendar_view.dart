import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/app_controller.dart';

const dayflowAccent = Color(0xFF55ADB1);

bool sameDate(DateTime? a, DateTime? b) =>
    a != null &&
    b != null &&
    a.year == b.year &&
    a.month == b.month &&
    a.day == b.day;

class MonthCalendar extends StatefulWidget {
  const MonthCalendar({
    super.key,
    required this.controller,
    required this.tasks,
    required this.onSelect,
    required this.onCreate,
  });
  final AppController controller;
  final List<TaskItem> tasks;
  final ValueChanged<TaskItem> onSelect;
  final ValueChanged<DateTime> onCreate;

  @override
  State<MonthCalendar> createState() => _MonthCalendarState();
}

class _MonthCalendarState extends State<MonthCalendar> {
  late DateTime month;
  late DateTime selected;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    month = DateTime(now.year, now.month);
    selected = DateTime(now.year, now.month, now.day);
  }

  void shift(int n) => setState(() {
    month = DateTime(month.year, month.month + n);
    selected = month;
  });

  List<TaskItem> forDay(DateTime day) =>
      widget.tasks.where((t) {
        if (t.dueDate == null) return false;
        final start = DateTime(
          t.dueDate!.year,
          t.dueDate!.month,
          t.dueDate!.day,
        );
        final end = t.endDate ?? start;
        return !day.isBefore(start) &&
            !day.isAfter(DateTime(end.year, end.month, end.day));
      }).toList()..sort((a, b) {
        if (a.completed != b.completed) return a.completed ? 1 : -1;
        final byTime = (a.dueTime ?? '99:99').compareTo(b.dueTime ?? '99:99');
        return byTime != 0 ? byTime : b.priority.compareTo(a.priority);
      });

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final compact = box.maxWidth < 480;
      final first = DateTime(month.year, month.month, 1);
      final start = first.subtract(Duration(days: first.weekday - 1));
      final today = DateTime.now();
      final dayItems = forDay(selected);
      final monthCount = widget.tasks
          .where(
            (t) =>
                t.dueDate?.year == month.year &&
                t.dueDate?.month == month.month &&
                !t.completed,
          )
          .length;
      final content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              compact ? 20 : 30,
              18,
              compact ? 12 : 24,
              22,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${month.year} 年 ${month.month} 月',
                        style: TextStyle(
                          fontSize: compact ? 24 : 29,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.8,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        '本月还有 $monthCount 项待办',
                        style: const TextStyle(
                          color: Color(0xFF9297A5),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                OutlinedButton(
                  onPressed: () => setState(() {
                    month = DateTime(today.year, today.month);
                    selected = DateTime(today.year, today.month, today.day);
                  }),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(52, 34),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                  ),
                  child: const Text('今天'),
                ),
                const SizedBox(width: 6),
                IconButton(
                  tooltip: '上个月',
                  onPressed: () => shift(-1),
                  icon: const Icon(Icons.chevron_left_rounded, size: 22),
                ),
                IconButton(
                  tooltip: '下个月',
                  onPressed: () => shift(1),
                  icon: const Icon(Icons.chevron_right_rounded, size: 22),
                ),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 24),
            child: Row(
              children: List.generate(
                7,
                (i) => Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      ['周一', '周二', '周三', '周四', '周五', '周六', '周日'][i],
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: i > 4
                            ? const Color(0xFFB3B7C1)
                            : const Color(0xFF858B9A),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (compact)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: SizedBox(
                height: 300,
                child: _grid(start, today, true, 300),
              ),
            )
          else
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                child: LayoutBuilder(
                  builder: (_, constraints) =>
                      _grid(start, today, false, constraints.maxHeight),
                ),
              ),
            ),
          if (compact) ...[
            const Divider(height: 25),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${selected.month} 月 ${selected.day} 日 · ${['周一', '周二', '周三', '周四', '周五', '周六', '周日'][selected.weekday - 1]}',
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '在这一天添加任务',
                    onPressed: () => widget.onCreate(selected),
                    icon: const Icon(Icons.add_rounded, color: dayflowAccent),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 220,
              child: dayItems.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.wb_sunny_outlined,
                            size: 28,
                            color: Color(0xFFBCC4DA),
                          ),
                          const SizedBox(height: 10),
                          const Text(
                            '这一天，留一点空白',
                            style: TextStyle(
                              color: Color(0xFF9399A9),
                              fontSize: 13,
                            ),
                          ),
                          TextButton(
                            onPressed: () => widget.onCreate(selected),
                            child: const Text('安排一件事'),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      itemCount: dayItems.length,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      itemBuilder: (_, index) {
                        final task = dayItems[index];
                        return ListTile(
                          contentPadding: const EdgeInsets.only(right: 10),
                          leading: Checkbox(
                            value: task.completed,
                            onChanged: (_) =>
                                widget.controller.toggleTask(task.id),
                          ),
                          title: Text(
                            task.title,
                            style: TextStyle(
                              fontSize: 14,
                              decoration: task.completed
                                  ? TextDecoration.lineThrough
                                  : null,
                            ),
                          ),
                          subtitle: Text(
                            '${task.dueTime ?? '全天'} · ${widget.controller.taskList(task.listId)?.name ?? '收件箱'}',
                            style: const TextStyle(fontSize: 11),
                          ),
                          onTap: () => widget.onSelect(task),
                        );
                      },
                    ),
            ),
          ] else
            Padding(
              padding: const EdgeInsets.fromLTRB(30, 0, 30, 16),
              child: Row(
                children: [
                  const Icon(
                    Icons.touch_app_outlined,
                    size: 13,
                    color: Color(0xFFA2A7B4),
                  ),
                  const SizedBox(width: 6),
                  const Expanded(
                    child: Text(
                      '点击任务查看详情 · 双击日期添加 · 拖动任务调整日期',
                      style: TextStyle(fontSize: 11, color: Color(0xFFA2A7B4)),
                    ),
                  ),
                  Text(
                    '${widget.tasks.where((t) => t.dueDate == null && !t.completed).length} 项未排期',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF8B91A0),
                    ),
                  ),
                ],
              ),
            ),
        ],
      );
      return compact ? SingleChildScrollView(child: content) : content;
    },
  );

  Widget _grid(DateTime start, DateTime today, bool compact, double height) {
    final rowHeight = height / 6;
    return Column(
      children: List.generate(
        6,
        (week) => SizedBox(
          height: rowHeight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: List.generate(7, (weekday) {
              final date = start.add(Duration(days: week * 7 + weekday));
              final tasks = forDay(date);
              final current = date.month == month.month;
              final isToday = sameDate(date, today);
              final isSelected = sameDate(date, selected);
              return Expanded(
                child: DragTarget<String>(
                  onWillAcceptWithDetails: (details) =>
                      widget.controller.getTask(details.data) != null,
                  onAcceptWithDetails: (details) async {
                    await widget.controller.moveTask(details.data, date);
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('已移至 ${date.month} 月 ${date.day} 日'),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    }
                  },
                  builder: (context, candidates, rejected) => Material(
                    color: candidates.isNotEmpty
                        ? dayflowAccent.withValues(alpha: .14)
                        : isSelected
                        ? const Color(0xFFF6F7FF)
                        : !current
                        ? const Color(0xFFFAFBFD)
                        : Colors.white,
                    child: InkWell(
                      onTap: () => setState(() => selected = date),
                      onDoubleTap: () => widget.onCreate(date),
                      onLongPress: compact ? () => widget.onCreate(date) : null,
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border(
                            top: const BorderSide(
                              color: Color(0xFFEBEDF3),
                              width: .7,
                            ),
                            right: BorderSide(
                              color: compact
                                  ? Colors.transparent
                                  : const Color(0xFFEBEDF3),
                              width: .7,
                            ),
                          ),
                        ),
                        padding: EdgeInsets.fromLTRB(
                          compact ? 1 : 5,
                          5,
                          compact ? 1 : 5,
                          2,
                        ),
                        child: Column(
                          crossAxisAlignment: compact
                              ? CrossAxisAlignment.center
                              : CrossAxisAlignment.stretch,
                          children: [
                            Align(
                              alignment: compact
                                  ? Alignment.center
                                  : Alignment.centerRight,
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 180),
                                width: compact ? 27 : 25,
                                height: compact ? 27 : 25,
                                decoration: BoxDecoration(
                                  color: isToday
                                      ? dayflowAccent
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  '${date.day}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: isToday || isSelected
                                        ? FontWeight.w700
                                        : FontWeight.w400,
                                    color: isToday
                                        ? Colors.white
                                        : current
                                        ? const Color(0xFF4A5162)
                                        : const Color(0xFFBEC2CE),
                                  ),
                                ),
                              ),
                            ),
                            if (compact)
                              Padding(
                                padding: const EdgeInsets.only(top: 3),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: tasks
                                      .take(3)
                                      .map(
                                        (t) => Container(
                                          margin: const EdgeInsets.symmetric(
                                            horizontal: 1.5,
                                          ),
                                          width: 4,
                                          height: 4,
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            color: t.completed
                                                ? const Color(0xFFCFD3DF)
                                                : Color(
                                                    widget.controller
                                                            .taskList(t.listId)
                                                            ?.color ??
                                                        0xFF5C6FE8,
                                                  ),
                                          ),
                                        ),
                                      )
                                      .toList(),
                                ),
                              )
                            else ...[
                              const SizedBox(height: 3),
                              ...tasks
                                  .take(
                                    ((rowHeight - 52) / 24).floor().clamp(0, 4),
                                  )
                                  .map(
                                    (task) => Padding(
                                      padding: const EdgeInsets.only(bottom: 3),
                                      child: Draggable<String>(
                                        data: task.id,
                                        feedback: Material(
                                          elevation: 6,
                                          borderRadius: BorderRadius.circular(
                                            6,
                                          ),
                                          child: SizedBox(
                                            width: 175,
                                            child: _taskChip(
                                              task,
                                              feedback: true,
                                            ),
                                          ),
                                        ),
                                        childWhenDragging: Opacity(
                                          opacity: .3,
                                          child: _taskChip(task),
                                        ),
                                        child: _taskChip(task),
                                      ),
                                    ),
                                  ),
                              if (tasks.length >
                                      ((rowHeight - 52) / 24).floor().clamp(
                                        0,
                                        4,
                                      ) &&
                                  rowHeight > 55)
                                InkWell(
                                  onTap: () => _showDay(date),
                                  child: Padding(
                                    padding: const EdgeInsets.only(left: 4),
                                    child: Text(
                                      '+ ${tasks.length - ((rowHeight - 52) / 24).floor().clamp(0, 4)} 项',
                                      style: const TextStyle(
                                        fontSize: 10,
                                        color: Color(0xFF8D94A5),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }

  Widget _taskChip(TaskItem task, {bool feedback = false}) {
    final color = Color(
      widget.controller.taskList(task.listId)?.color ?? 0xFF5C6FE8,
    );
    return InkWell(
      onTap: feedback ? null : () => widget.onSelect(task),
      borderRadius: BorderRadius.circular(4),
      child: Container(
        height: 21,
        padding: const EdgeInsets.symmetric(horizontal: 5),
        decoration: BoxDecoration(
          color: task.completed
              ? const Color(0xFFF1F2F5)
              : color.withValues(alpha: .09),
          borderRadius: BorderRadius.circular(4),
          border: Border(
            left: BorderSide(
              color: task.completed ? const Color(0xFFD0D4DE) : color,
              width: 2,
            ),
          ),
        ),
        child: Row(
          children: [
            if (task.completed)
              const Padding(
                padding: EdgeInsets.only(right: 3),
                child: Icon(
                  Icons.check_rounded,
                  size: 11,
                  color: Color(0xFF939AAA),
                ),
              ),
            Expanded(
              child: Text(
                task.title,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: task.completed ? const Color(0xFFA2A8B4) : color,
                  decoration: task.completed
                      ? TextDecoration.lineThrough
                      : null,
                ),
              ),
            ),
            if (task.dueTime != null && feedback)
              Text(task.dueTime!, style: TextStyle(fontSize: 9, color: color)),
          ],
        ),
      ),
    );
  }

  void _showDay(DateTime date) {
    final tasks = forDay(date);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                '${date.month} 月 ${date.day} 日',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              trailing: IconButton(
                tooltip: '添加任务',
                icon: const Icon(Icons.add_rounded),
                onPressed: () {
                  Navigator.pop(context);
                  widget.onCreate(date);
                },
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: tasks
                    .map(
                      (task) => ListTile(
                        leading: Icon(
                          task.completed
                              ? Icons.check_circle_outline_rounded
                              : Icons.radio_button_unchecked_rounded,
                          size: 20,
                        ),
                        title: Text(task.title),
                        subtitle: Text(task.dueTime ?? '全天'),
                        onTap: () {
                          Navigator.pop(context);
                          widget.onSelect(task);
                        },
                      ),
                    )
                    .toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
