import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../core/app_controller.dart';
import '../core/models.dart';
import 'date_popover.dart';

const _teal = Color(0xFF55ADB1);

class QuickAdd extends StatefulWidget {
  const QuickAdd({
    super.key,
    required this.controller,
    required this.listId,
    this.defaultDate,
    this.noteMode = false,
    required this.onCreated,
    required this.onExpand,
  });
  final AppController controller;
  final String listId;
  final DateTime? defaultDate;
  final bool noteMode;
  final ValueChanged<TaskItem> onCreated;
  final VoidCallback onExpand;
  @override
  QuickAddState createState() => QuickAddState();
}

class QuickAddState extends State<QuickAdd> {
  final text = TextEditingController();
  final focus = FocusNode();
  final dateAnchor = GlobalKey();
  late TaskItem draft;
  bool saving = false;
  String? error;

  @override
  void initState() {
    super.initState();
    resetDraft();
  }

  @override
  void didUpdateWidget(covariant QuickAdd oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (text.text.isEmpty &&
        (widget.listId != oldWidget.listId ||
            widget.noteMode != oldWidget.noteMode ||
            widget.defaultDate != oldWidget.defaultDate)) {
      resetDraft();
    }
  }

  void resetDraft() {
    draft = TaskItem(
      id: const Uuid().v4(),
      title: '',
      dueDate: widget.noteMode ? null : widget.defaultDate,
      listId: widget.listId,
      itemType: widget.noteMode ? 'note' : 'task',
    );
  }

  void requestFocus() => focus.requestFocus();

  @override
  void dispose() {
    text.dispose();
    focus.dispose();
    super.dispose();
  }

  Future<void> chooseDate() async {
    final schedule = await showTaskSchedulePicker(
      context,
      task: draft,
      anchorKey: dateAnchor,
    );
    if (schedule != null && mounted) {
      setState(() => draft = schedule.applyTo(draft));
      focus.requestFocus();
    }
  }

  Future<bool> submit({bool open = true}) async {
    if (saving) return false;
    if (text.text.trim().isEmpty) {
      focus.requestFocus();
      return false;
    }
    final snapshot = draft.copyWith(
      title: text.text.trim(),
      listId: widget.listId,
    );
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.controller.saveTask(snapshot);
      if (!mounted) return true;
      setState(() {
        text.clear();
        resetDraft();
      });
      if (open) widget.onCreated(snapshot);
      return true;
    } catch (failure) {
      if (mounted) setState(() => error = '添加失败，请重试。$failure');
      return false;
    } finally {
      if (mounted) {
        setState(() => saving = false);
        if (!open) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) focus.requestFocus();
          });
        }
      }
    }
  }

  Future<bool> requestClose() async {
    if (text.text.trim().isEmpty) return true;
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加栏里还有内容'),
        content: const Text('保存后再切换账号，还是保留在这里继续编辑？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'continue'),
            child: const Text('继续编辑'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'discard'),
            child: const Text('放弃'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'save'),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (result == 'discard') {
      text.clear();
      return true;
    }
    return result == 'save' && await submit(open: false);
  }

  String get dateLabel {
    final date = draft.dueDate;
    if (date == null) return '日期';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(date.year, date.month, date.day);
    final label = day == today
        ? '今天'
        : day == DateTime(now.year, now.month, now.day + 1)
        ? '明天'
        : '${date.month}月${date.day}日';
    return '$label${draft.dueTime == null ? '' : ' ${draft.dueTime}'}';
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(22, 8, 22, 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.enter, shift: true): () {
              if (text.text.trim().isNotEmpty) {
                submit();
              } else {
                widget.onExpand();
              }
            },
          },
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFFFCFEFE),
              borderRadius: BorderRadius.circular(7),
              border: Border.all(color: _teal.withValues(alpha: .65)),
            ),
            child: Row(
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 10),
                  child: Icon(
                    draft.itemType == 'note'
                        ? Icons.description_outlined
                        : Icons.add,
                    size: 19,
                    color: const Color(0xFFADB8BD),
                  ),
                ),
                Expanded(
                  child: TextField(
                    key: const ValueKey('quick-add-input'),
                    controller: text,
                    focusNode: focus,
                    // Keep the web text-input connection alive between adds.
                    // Disabling the field closes it while its focus can remain
                    // set, leaving the next keyboard input disconnected.
                    inputFormatters: [
                      TextInputFormatter.withFunction(
                        (oldValue, newValue) => saving ? oldValue : newValue,
                      ),
                    ],
                    maxLength: 300,
                    style: const TextStyle(fontSize: 14),
                    onEditingComplete: () {},
                    onSubmitted: (_) => submit(open: false),
                    onChanged: (_) => setState(() => error = null),
                    decoration: InputDecoration(
                      hintText: draft.itemType == 'note' ? '添加笔记' : '添加任务',
                      counterText: '',
                      isDense: true,
                      fillColor: Colors.transparent,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 13,
                      ),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                    ),
                  ),
                ),
                TextButton(
                  key: dateAnchor,
                  onPressed: saving ? null : chooseDate,
                  style: TextButton.styleFrom(
                    foregroundColor: _teal,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(36, 36),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        draft.recurrenceRule != null ||
                                draft.recurrence != 'none'
                            ? Icons.repeat
                            : Icons.calendar_month_outlined,
                        size: 17,
                      ),
                      const SizedBox(width: 5),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 90),
                        child: Text(dateLabel, overflow: TextOverflow.ellipsis),
                      ),
                      const Icon(Icons.keyboard_arrow_down, size: 17),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: '添加选项',
                  padding: EdgeInsets.zero,
                  iconSize: 18,
                  onSelected: (value) {
                    if (value == 'expand') {
                      if (text.text.trim().isEmpty) {
                        widget.onExpand();
                      } else {
                        submit();
                      }
                    } else {
                      setState(() => draft = draft.copyWith(itemType: value));
                      focus.requestFocus();
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'task', child: Text('新建任务')),
                    PopupMenuItem(value: 'note', child: Text('新建笔记')),
                    PopupMenuDivider(),
                    PopupMenuItem(value: 'expand', child: Text('在详情中添加')),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              error!,
              style: const TextStyle(color: Colors.red, fontSize: 12),
            ),
          ),
        if (text.text.isNotEmpty && error == null)
          const Padding(
            padding: EdgeInsets.only(top: 5, left: 3),
            child: Text(
              'Enter 连续添加 · Shift + Enter 添加并展开详情',
              style: TextStyle(color: Color(0xFF9BA5AA), fontSize: 10),
            ),
          ),
      ],
    ),
  );
}
