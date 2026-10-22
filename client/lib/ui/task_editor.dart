// Flutter Quill exposes clipboard hooks as experimental in the pinned 11.x API.
// ignore_for_file: experimental_member_use

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:uuid/uuid.dart';

import '../core/app_controller.dart';
import '../core/models.dart';
import 'date_popover.dart';
import 'import_source_dialog.dart';
import 'rich_text_editor.dart';

const _accent = Color(0xFF55ADB1);
const _ink = Color(0xFF242938);
const _muted = Color(0xFF8991A4);
const _line = Color(0xFFEDF0F5);

/// Keep the key stable while selecting items; call requestClose before removal.
class TaskEditor extends StatefulWidget {
  const TaskEditor({
    super.key,
    required this.controller,
    this.task,
    this.initialDate,
    this.initialListId,
    required this.onClose,
  });
  final AppController controller;
  final TaskItem? task;
  final DateTime? initialDate;
  final String? initialListId;
  final VoidCallback onClose;
  @override
  TaskEditorState createState() => TaskEditorState();
}

class TaskEditorState extends State<TaskEditor> {
  final _title = TextEditingController();
  final _titleFocus = FocusNode();
  final _bodyFocus = FocusNode();
  final _bodyScroll = ScrollController();
  final _pageScroll = ScrollController();
  final _dateAnchor = GlobalKey();
  final _pending = <String, _Draft>{};
  final _subtasks = <_SubtaskField>[];
  late TaskItem _base;
  late quill.QuillController _rich;
  StreamSubscription<quill.DocChange>? _richChanges;
  Timer? _debounce;
  Future<bool>? _saving;
  String? _error;
  late String _selectionKey;
  int _revision = 0;
  bool _loading = false;
  bool _uploading = false;
  bool _deleting = false;

  bool get hasUnsavedChanges => _pending.isNotEmpty || _uploading;
  bool get _isNote => _base.itemType == 'note';

  @override
  void initState() {
    super.initState();
    _selectionKey = _keyFor(widget);
    _load(_initialTask(), initial: true);
    if (widget.task == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _titleFocus.requestFocus();
      });
    }
  }

  String _keyFor(TaskEditor editor) =>
      editor.task?.id ??
      'new:${editor.initialListId ?? 'inbox'}:${editor.initialDate?.toIso8601String() ?? ''}';
  TaskItem _initialTask() =>
      widget.task ??
      TaskItem(
        id: const Uuid().v4(),
        title: '',
        listId: widget.initialListId ?? 'inbox',
        dueDate: widget.initialDate,
      );

  @override
  void didUpdateWidget(covariant TaskEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextKey = _keyFor(widget);
    if (nextKey != _selectionKey) {
      _debounce?.cancel();
      _selectionKey = nextKey;
      _load(_pending[nextKey]?.task ?? _initialTask());
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_flush());
      });
    } else if (!_pending.containsKey(nextKey) &&
        _saving == null &&
        !_uploading &&
        widget.task != null &&
        !identical(widget.task, oldWidget.task) &&
        jsonEncode(_snapshot().toPayload()) !=
            jsonEncode(widget.task!.toPayload())) {
      _load(widget.task!);
    }
  }

  void _load(TaskItem task, {bool initial = false}) {
    _loading = true;
    _base = task;
    _title.text = task.title;
    _richChanges?.cancel();
    final oldRich = initial ? null : _rich;
    _rich = quill.QuillController(
      document: taskDocument(task),
      selection: const TextSelection.collapsed(offset: 0),
      config: quill.QuillControllerConfig(
        clipboardConfig: quill.QuillClipboardConfig(
          onImagePaste: (bytes) async {
            await _addAttachment(true, bytes: bytes);
            // We insert after the authenticated upload ourselves, including
            // when the visible task changes while that upload is in flight.
            return null;
          },
        ),
      ),
    );
    _richChanges = _rich.changes.listen((_) {
      if (!_loading && mounted) _change(() {});
    });
    final oldFields = _subtasks.toList();
    _subtasks
      ..clear()
      ..addAll(task.subtasks.map(_SubtaskField.fromTask));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      oldRich?.dispose();
      for (final field in oldFields) {
        field.dispose();
      }
    });
    _error = null;
    _loading = false;
  }

  TaskItem _snapshot() {
    final plain = _rich.document.toPlainText().trimRight();
    return _base.copyWith(
      title: _title.text.trim(),
      notes: plain.length > 20000 ? plain.substring(0, 20000) : plain,
      richContent: _rich.document
          .toDelta()
          .toJson()
          .map((operation) => Map<String, dynamic>.from(operation))
          .toList(),
      subtasks: _subtasks
          .where((field) => field.controller.text.trim().isNotEmpty)
          .map(
            (field) => SubTask(
              id: field.id,
              title: field.controller.text.trim(),
              completed: field.completed,
            ),
          )
          .toList(),
    );
  }

  void _change(VoidCallback action) {
    if (_loading || !mounted) return;
    setState(() {
      action();
      _pending[_selectionKey] = _Draft(_snapshot(), ++_revision);
      _error = null;
    });
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 650), () {
      if (mounted) unawaited(_flush());
    });
  }

  Future<bool> _flush() async {
    if (_saving != null) return _saving!;
    if (_pending.isEmpty) return true;
    final future = _flushPending();
    _saving = future;
    try {
      return await future;
    } finally {
      _saving = null;
      if (mounted) setState(() {});
    }
  }

  Future<bool> _flushPending() async {
    if (mounted) setState(() {});
    try {
      while (_pending.values.any((draft) => draft.task.title.isNotEmpty)) {
        final entry = _pending.entries.firstWhere(
          (entry) => entry.value.task.title.isNotEmpty,
        );
        final draft = entry.value;
        final textLength = draft.task.richContent.fold<int>(
          0,
          (sum, op) =>
              sum +
              (op['insert'] is String ? (op['insert'] as String).length : 1),
        );
        if (draft.task.richContent.length > 2000 || textLength > 100000) {
          throw const FormatException('正文过长，请缩短至 10 万字、2000 个格式片段以内。');
        }
        await widget.controller.saveTask(draft.task);
        final saved = widget.controller.getTask(draft.task.id) ?? draft.task;
        if (_pending[entry.key]?.revision == draft.revision) {
          _pending.remove(entry.key);
        } else if (_pending.containsKey(entry.key)) {
          final newer = _pending[entry.key]!;
          _pending[entry.key] = _Draft(
            newer.task.copyWith(
              version: saved.version,
              updatedAt: saved.updatedAt,
            ),
            newer.revision,
          );
        }
        if (_base.id == saved.id) {
          _base = _base.copyWith(
            version: saved.version,
            updatedAt: saved.updatedAt,
          );
        }
        if (!mounted) return false;
        setState(() {});
      }
      return _pending.isEmpty;
    } catch (error) {
      if (mounted) setState(() => _error = '未能保存：${_friendlyError(error)}');
      return false;
    }
  }

  Future<void> _saveNow() async {
    _debounce?.cancel();
    if (_title.text.trim().isEmpty) {
      setState(() => _error = _isNote ? '先为笔记写一个标题' : '先为任务写一个标题');
      _titleFocus.requestFocus();
      return;
    }
    if (!_pending.containsKey(_selectionKey)) {
      _change(() {});
      _debounce?.cancel();
    }
    await _flush();
  }

  /// Ordinary changes flush automatically; failed/untitled drafts need an
  /// explicit decision before the parent can discard this editor.
  Future<bool> requestClose() async {
    _debounce?.cancel();
    if (_uploading) {
      setState(() => _error = '附件正在上传，请稍候再关闭。');
      return false;
    }
    if (await _flush()) return true;
    if (!mounted) return false;
    final action = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('还有未保存的内容'),
        content: Text(
          _error ?? '有 ${_pending.length} 个草稿尚未填写标题，请继续编辑，或放弃这些草稿。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'discard'),
            child: const Text('放弃修改'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'continue'),
            child: const Text('继续编辑'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'retry'),
            child: const Text('重试保存'),
          ),
        ],
      ),
    );
    if (!mounted || action == null || action == 'continue') return false;
    if (action == 'discard') {
      setState(_pending.clear);
      return true;
    }
    return _flush();
  }

  Future<void> _close() async {
    if (await requestClose() && mounted) widget.onClose();
  }

  Future<void> _pickSchedule() async {
    final key = _selectionKey;
    final schedule = await showTaskSchedulePicker(
      context,
      task: _snapshot(),
      anchorKey: _dateAnchor,
    );
    if (schedule != null && mounted && key == _selectionKey) {
      _change(() => _base = schedule.applyTo(_base));
    }
  }

  Future<void> _delete() async {
    if (_deleting || _uploading) return;
    final task = _snapshot();
    final key = _selectionKey;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_isNote ? '删除笔记？' : '删除任务？'),
        content: Text('“${task.title}”将从所有设备移除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFCE5260),
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    _debounce?.cancel();
    setState(() => _deleting = true);
    try {
      if (_saving != null) await _saving;
      await widget.controller.deleteTask(task.id);
      _pending.remove(key);
      if (mounted && key == _selectionKey) widget.onClose();
    } catch (error) {
      if (mounted) setState(() => _error = '删除失败：${_friendlyError(error)}');
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  Future<void> _addAttachment(bool image, {Uint8List? bytes}) async {
    if (_uploading) return;
    if (_base.attachments.length >= 50) {
      setState(() => _error = '每个任务最多添加 50 个附件。');
      return;
    }
    final key = _selectionKey;
    final startTask = _snapshot();
    setState(() => _uploading = true);
    try {
      final attachment = bytes == null
          ? await widget.controller.pickAttachment(imagesOnly: image)
          : await widget.controller.addAttachmentBytes(
              name: '粘贴图片.png',
              bytes: bytes,
            );
      if (attachment == null || !mounted) return;
      if (key == _selectionKey) {
        _change(() {
          if (!_base.attachments.any((item) => item.id == attachment.id)) {
            _base = _base.copyWith(
              attachments: [..._base.attachments, attachment],
            );
          }
          if (image) {
            final at = _rich.selection.extentOffset.clamp(
              0,
              _rich.document.length - 1,
            );
            _rich.replaceText(
              at,
              0,
              quill.BlockEmbed.image('attachment:${attachment.id}'),
              TextSelection.collapsed(offset: at + 1),
            );
          }
        });
      } else {
        final current =
            _pending[key]?.task ??
            widget.controller.getTask(startTask.id) ??
            startTask;
        final document = taskDocument(current);
        if (image) {
          document.insert(
            document.length - 1,
            quill.BlockEmbed.image('attachment:${attachment.id}'),
          );
        }
        final updated = current.copyWith(
          attachments: [
            ...current.attachments,
            if (!current.attachments.any((item) => item.id == attachment.id))
              attachment,
          ],
          richContent: document.toDelta().toJson(),
        );
        document.close();
        _pending[key] = _Draft(updated, ++_revision);
      }
      await _flush();
    } catch (error) {
      if (mounted) setState(() => _error = '附件未添加：${_friendlyError(error)}');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  void _removeAttachment(AttachmentItem attachment) {
    _change(() {
      _base = _base.copyWith(
        attachments: _base.attachments
            .where((item) => item.id != attachment.id)
            .toList(),
      );
      // Only remove this task's references. Other devices/conflict copies may
      // still reference the blob, so deleting the shared private file is unsafe.
      var offset = 0;
      final positions = <int>[];
      for (final operation in _rich.document.toDelta().toJson()) {
        final insert = operation['insert'];
        if (insert is Map && insert['image'] == 'attachment:${attachment.id}') {
          positions.add(offset);
        }
        offset += insert is String ? insert.length : 1;
      }
      for (final position in positions.reversed) {
        _rich.replaceText(position, 1, '', null, ignoreFocus: true);
      }
    });
  }

  Future<void> _download(AttachmentItem attachment) async {
    try {
      await widget.controller.saveAttachmentToDevice(attachment);
    } catch (error) {
      if (mounted) setState(() => _error = '下载失败：${_friendlyError(error)}');
    }
  }

  void _addSubtask() {
    if (_subtasks.length >= 100) return;
    final field = _SubtaskField(
      id: const Uuid().v4(),
      title: '',
      completed: false,
    );
    _change(() => _subtasks.add(field));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) field.focus.requestFocus();
    });
  }

  Future<void> _editTags() async {
    final text = TextEditingController(text: _base.tags.join('，'));
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('标签'),
        content: TextField(
          controller: text,
          autofocus: true,
          decoration: const InputDecoration(hintText: '用逗号分隔，例如 工作，待跟进'),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, text.text),
            child: const Text('完成'),
          ),
        ],
      ),
    );
    text.dispose();
    if (result == null || !mounted) return;
    final tags = result
        .split(RegExp(r'[,，\s]+'))
        .map((tag) => tag.replaceFirst(RegExp(r'^#'), '').trim())
        .where((tag) => tag.isNotEmpty)
        .toSet()
        .take(20)
        .map((tag) => tag.length > 40 ? tag.substring(0, 40) : tag)
        .toList();
    _change(() => _base = _base.copyWith(tags: tags));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _richChanges?.cancel();
    _rich.dispose();
    _title.dispose();
    _titleFocus.dispose();
    _bodyFocus.dispose();
    _bodyScroll.dispose();
    _pageScroll.dispose();
    for (final field in _subtasks) {
      field.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.enter, control: true): _saveNow,
      const SingleActivator(LogicalKeyboardKey.enter, meta: true): _saveNow,
    },
    child: Material(
      color: Colors.white,
      child: Column(
        children: [
          _header(),
          const Divider(height: 1, color: _line),
          if (_uploading) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: SingleChildScrollView(
              key: const ValueKey('task-editor-scroll'),
              controller: _pageScroll,
              padding: const EdgeInsets.fromLTRB(24, 22, 24, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    key: const ValueKey('task-title'),
                    controller: _title,
                    focusNode: _titleFocus,
                    maxLines: null,
                    minLines: 1,
                    maxLength: 300,
                    textCapitalization: TextCapitalization.sentences,
                    style: TextStyle(
                      color: _base.completed ? _muted : _ink,
                      fontSize: 24,
                      height: 1.45,
                      fontWeight: FontWeight.w600,
                      decoration: _base.completed
                          ? TextDecoration.lineThrough
                          : null,
                    ),
                    decoration: InputDecoration(
                      hintText: _isNote ? '笔记标题' : '要做些什么？',
                      hintStyle: const TextStyle(color: Color(0xFFB1B6C1)),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      filled: false,
                      counterText: '',
                      contentPadding: EdgeInsets.zero,
                    ),
                    onChanged: (_) => _change(() {}),
                  ),
                  const SizedBox(height: 18),
                  if (_base.tags.isNotEmpty) ...[
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: _base.tags
                          .map(
                            (tag) => InkWell(
                              onTap: _editTags,
                              child: Text(
                                '#$tag',
                                style: const TextStyle(
                                  color: _accent,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          )
                          .toList(),
                    ),
                    const SizedBox(height: 18),
                  ],
                  DayflowRichEditor(
                    key: ValueKey(_base.id),
                    controller: _rich,
                    appController: widget.controller,
                    focusNode: _bodyFocus,
                    scrollController: _bodyScroll,
                    attachments: _base.attachments,
                    onAddAttachment: _addAttachment,
                    uploading: _uploading,
                    isNote: _isNote,
                  ),
                  if (!_isNote) _subtaskSection(),
                  if (_base.attachments.isNotEmpty) _attachmentSection(),
                  if (_error != null) ...[
                    const SizedBox(height: 18),
                    Text(
                      _error!,
                      key: const ValueKey('editor-error'),
                      style: const TextStyle(
                        color: Color(0xFFCE5260),
                        fontSize: 12,
                        height: 1.5,
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: _saveNow,
                        icon: const Icon(Icons.refresh, size: 16),
                        label: const Text('重试保存'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const Divider(height: 1, color: _line),
          _footer(),
        ],
      ),
    ),
  );

  Widget _header() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    child: Row(
      children: [
        if (_isNote)
          const Padding(
            padding: EdgeInsets.all(11),
            child: Icon(Icons.description_outlined, color: _muted, size: 20),
          )
        else
          Tooltip(
            message: _base.completed ? '标记未完成' : '标记完成',
            child: Checkbox(
              value: _base.completed,
              activeColor: _accent,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4),
              ),
              onChanged: (value) => _change(
                () => _base = _base.copyWith(
                  completed: value ?? false,
                  completedAt: value == true ? DateTime.now().toUtc() : null,
                ),
              ),
            ),
          ),
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: _dateAnchor,
              onPressed: _pickSchedule,
              icon: const Icon(Icons.calendar_today_outlined, size: 17),
              label: Text(
                _scheduleLabel(),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              style: TextButton.styleFrom(
                foregroundColor: _base.dueDate == null ? _muted : _accent,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                textStyle: const TextStyle(fontSize: 12),
              ),
            ),
          ),
        ),
        PopupMenuButton<int>(
          tooltip: '优先级',
          initialValue: _base.priority,
          onSelected: (value) =>
              _change(() => _base = _base.copyWith(priority: value)),
          icon: Icon(
            _base.priority == 0 ? Icons.flag_outlined : Icons.flag,
            size: 20,
            color: _priorityColor(_base.priority),
          ),
          itemBuilder: (_) => [
            for (final priority in [3, 2, 1, 0])
              PopupMenuItem(
                value: priority,
                child: Row(
                  children: [
                    Icon(
                      Icons.flag_outlined,
                      size: 18,
                      color: _priorityColor(priority),
                    ),
                    const SizedBox(width: 12),
                    Text(['无优先级', '低优先级', '中优先级', '高优先级'][priority]),
                  ],
                ),
              ),
          ],
        ),
        IconButton(
          tooltip: '关闭',
          onPressed: _close,
          icon: const Icon(Icons.close, size: 19, color: _muted),
        ),
      ],
    ),
  );

  String _scheduleLabel() {
    if (_base.dueDate == null) return '设置日期';
    final date = _base.dueDate!;
    var label = '${date.month} 月 ${date.day} 日';
    if (_base.dueTime != null) label += ' ${_base.dueTime}';
    if (_base.endDate != null) {
      label += ' → ${_base.endDate!.month}/${_base.endDate!.day}';
      if (_base.endTime != null) label += ' ${_base.endTime}';
    }
    if (_base.recurrence != 'none' || _base.recurrenceRule != null) {
      label += ' · 重复';
    }
    return label;
  }

  Widget _subtaskSection() {
    final done = _subtasks.where((field) => field.completed).length;
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_subtasks.isNotEmpty) ...[
            Row(
              children: [
                const Text(
                  '子任务',
                  style: TextStyle(color: _muted, fontSize: 12),
                ),
                const Spacer(),
                Text(
                  '$done / ${_subtasks.length}',
                  style: const TextStyle(color: _muted, fontSize: 11),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: done / _subtasks.length,
                minHeight: 3,
                backgroundColor: _line,
              ),
            ),
            const SizedBox(height: 7),
            ..._subtasks.map(_subtaskRow),
          ],
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _addSubtask,
              style: TextButton.styleFrom(
                foregroundColor: _muted,
                padding: EdgeInsets.zero,
              ),
              icon: const Icon(Icons.add, size: 17),
              label: const Text('添加子任务', style: TextStyle(fontSize: 12)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _subtaskRow(_SubtaskField field) => Row(
    key: ValueKey(field.id),
    children: [
      SizedBox(
        width: 28,
        child: Checkbox(
          value: field.completed,
          visualDensity: VisualDensity.compact,
          onChanged: (value) => _change(() => field.completed = value ?? false),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: TextField(
          controller: field.controller,
          focusNode: field.focus,
          maxLength: 200,
          style: TextStyle(
            fontSize: 13,
            color: field.completed ? _muted : _ink,
            decoration: field.completed ? TextDecoration.lineThrough : null,
          ),
          decoration: const InputDecoration(
            hintText: '下一步要做什么？',
            counterText: '',
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            filled: false,
            contentPadding: EdgeInsets.symmetric(vertical: 10),
          ),
          onChanged: (_) => _change(() {}),
          onSubmitted: (_) => _addSubtask(),
        ),
      ),
      IconButton(
        tooltip: '移除子任务',
        icon: const Icon(Icons.close, size: 15, color: _muted),
        visualDensity: VisualDensity.compact,
        onPressed: () {
          _change(() => _subtasks.remove(field));
          WidgetsBinding.instance.addPostFrameCallback((_) => field.dispose());
        },
      ),
    ],
  );

  Widget _attachmentSection() => Padding(
    padding: const EdgeInsets.only(top: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(color: _line),
        const SizedBox(height: 10),
        Text(
          '附件 · ${_base.attachments.length}',
          style: const TextStyle(color: _muted, fontSize: 12),
        ),
        const SizedBox(height: 8),
        for (final attachment in _base.attachments)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: [
                Icon(
                  attachment.mimeType.startsWith('image/')
                      ? Icons.image_outlined
                      : Icons.insert_drive_file_outlined,
                  color: _muted,
                  size: 23,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        attachment.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                      Text(
                        _fileSize(attachment.size),
                        style: const TextStyle(color: _muted, fontSize: 10),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '下载 ${attachment.name}',
                  onPressed: () => _download(attachment),
                  icon: const Icon(
                    Icons.download_outlined,
                    size: 18,
                    color: _muted,
                  ),
                ),
                IconButton(
                  tooltip: '移除 ${attachment.name}',
                  onPressed: () => _removeAttachment(attachment),
                  icon: const Icon(Icons.close, size: 16, color: _muted),
                ),
              ],
            ),
          ),
      ],
    ),
  );

  Widget _footer() {
    final lists = widget.controller.lists;
    final selected = lists.where((list) => list.id == _base.listId).firstOrNull;
    final pending = _pending.containsKey(_selectionKey);
    final status = _uploading
        ? '正在上传…'
        : _saving != null
        ? '保存中…'
        : _error != null
        ? '保存失败'
        : pending
        ? (_title.text.trim().isEmpty ? '待填写标题' : '待保存')
        : widget.controller.getTask(_base.id) == null
        ? '自动保存'
        : '已保存';
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        child: Row(
          children: [
            Expanded(
              child: PopupMenuButton<String>(
                tooltip: '移动到清单',
                initialValue: _base.listId,
                onSelected: (id) =>
                    _change(() => _base = _base.copyWith(listId: id)),
                itemBuilder: (_) => [
                  for (final list in lists)
                    PopupMenuItem(value: list.id, child: Text(list.name)),
                ],
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 10,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.list_alt,
                        size: 17,
                        color: selected == null
                            ? _muted
                            : Color(selected.color),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          selected?.name ?? '原清单已移除',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12, color: _muted),
                        ),
                      ),
                      const Icon(
                        Icons.keyboard_arrow_down,
                        size: 16,
                        color: _muted,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Tooltip(
              message: '立即保存 · Ctrl / ⌘ + Enter',
              child: TextButton(
                key: const ValueKey('editor-save-status'),
                onPressed: _saveNow,
                style: TextButton.styleFrom(
                  foregroundColor: _error == null
                      ? _muted
                      : const Color(0xFFCE5260),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: Text(status, style: const TextStyle(fontSize: 11)),
              ),
            ),
            PopupMenuButton<String>(
              tooltip: '更多',
              icon: const Icon(Icons.more_horiz, color: _muted, size: 21),
              onSelected: (action) {
                if (action == 'type') {
                  _change(
                    () => _base = _base.copyWith(
                      itemType: _isNote ? 'task' : 'note',
                      completed: false,
                      completedAt: null,
                    ),
                  );
                } else if (action == 'tags') {
                  _editTags();
                } else if (action == 'attachment') {
                  _addAttachment(false);
                } else if (action == 'save') {
                  _saveNow();
                } else if (action == 'importSource') {
                  showImportSourceDialog(context, _base.importData);
                } else if (action == 'delete') {
                  _delete();
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'type',
                  child: Text(_isNote ? '转换为任务' : '转换为笔记'),
                ),
                const PopupMenuItem(value: 'tags', child: Text('编辑标签')),
                const PopupMenuItem(value: 'attachment', child: Text('添加附件')),
                const PopupMenuItem(value: 'save', child: Text('立即保存')),
                if (_base.importData.isNotEmpty)
                  const PopupMenuItem(
                    value: 'importSource',
                    child: Text('查看导入原文'),
                  ),
                const PopupMenuDivider(),
                PopupMenuItem(
                  value: 'delete',
                  child: Text(
                    _isNote ? '删除笔记' : '删除任务',
                    style: const TextStyle(color: Color(0xFFCE5260)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Draft {
  const _Draft(this.task, this.revision);
  final TaskItem task;
  final int revision;
}

class _SubtaskField {
  _SubtaskField({
    required this.id,
    required String title,
    required this.completed,
  }) : controller = TextEditingController(text: title);
  factory _SubtaskField.fromTask(SubTask task) =>
      _SubtaskField(id: task.id, title: task.title, completed: task.completed);
  final String id;
  final TextEditingController controller;
  final FocusNode focus = FocusNode();
  bool completed;
  void dispose() {
    controller.dispose();
    focus.dispose();
  }
}

Color _priorityColor(int priority) => [
  _muted,
  const Color(0xFF5D83CA),
  const Color(0xFFE8AC45),
  const Color(0xFFD96769),
][priority.clamp(0, 3)];
String _fileSize(int bytes) => bytes >= 1024 * 1024
    ? '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB'
    : bytes >= 1024
    ? '${(bytes / 1024).ceil()} KB'
    : '$bytes B';
String _friendlyError(Object error) {
  final text = error.toString().replaceFirst(
    RegExp(r'^(Exception|FormatException): '),
    '',
  );
  return text.length > 180 ? '${text.substring(0, 180)}…' : text;
}
