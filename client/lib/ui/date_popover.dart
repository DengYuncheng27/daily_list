import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lunar/lunar.dart';

import '../core/models.dart';
import '../core/recurrence.dart';

const _teal = Color(0xFF55ADB1);
const _text = Color(0xFF30373D);
const _muted = Color(0xFF879095);
const _line = Color(0xFFEDF0F0);

class TaskSchedule {
  final DateTime? dueDate;
  final String? dueTime;
  final DateTime? endDate;
  final String? endTime;
  final int? reminderMinutes;
  final String recurrence;
  final RecurrenceRule? recurrenceRule;
  const TaskSchedule({
    this.dueDate,
    this.dueTime,
    this.endDate,
    this.endTime,
    this.reminderMinutes,
    this.recurrence = 'none',
    this.recurrenceRule,
  });
  TaskItem applyTo(TaskItem task) => task.copyWith(
    dueDate: dueDate,
    dueTime: dueTime,
    endDate: endDate,
    endTime: endTime,
    reminderMinutes: reminderMinutes,
    recurrence: recurrence,
    recurrenceRule: recurrenceRule,
  );
}

Future<TaskSchedule?> showTaskSchedulePicker(
  BuildContext context, {
  required TaskItem task,
  GlobalKey? anchorKey,
}) {
  final box = anchorKey?.currentContext?.findRenderObject();
  final anchor = box is RenderBox && box.hasSize
      ? box.localToGlobal(Offset.zero) & box.size
      : null;
  return showGeneralDialog<TaskSchedule>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '取消日期设置',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 140),
    transitionBuilder: (_, animation, _, child) =>
        FadeTransition(opacity: animation, child: child),
    pageBuilder: (context, _, _) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = math.min(374.0, constraints.maxWidth - 24);
            final height = math.min(780.0, constraints.maxHeight - 24);
            final left = anchor == null
                ? (constraints.maxWidth - width) / 2
                : anchor.left.clamp(
                    12.0,
                    math.max(12.0, constraints.maxWidth - width - 12),
                  );
            final top = anchor == null
                ? math.max(12.0, (constraints.maxHeight - height) / 2)
                : (anchor.bottom + 8).clamp(
                    12.0,
                    math.max(12.0, constraints.maxHeight - height - 12),
                  );
            return Stack(
              children: [
                Positioned(
                  left: left.toDouble(),
                  top: top.toDouble(),
                  width: width,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: height),
                    child: _SchedulePanel(task: task),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );
}

class _SchedulePanel extends StatefulWidget {
  final TaskItem task;
  const _SchedulePanel({required this.task});
  @override
  State<_SchedulePanel> createState() => _SchedulePanelState();
}

class _SchedulePanelState extends State<_SchedulePanel> {
  late DateTime _month;
  DateTime? _date, _end;
  String? _time, _endTime;
  int? _reminder;
  late RecurrenceRule _rule;
  bool _range = false, _selectEnd = false;
  bool _timeOpen = false, _reminderOpen = false, _repeatOpen = false;
  bool _repeatDetails = false, _customDetails = false;
  bool _ruleEdited = false, _pickingDates = false;
  String? _error;
  bool _untilInvalid = false;
  final _invalidNumbers = <String>{};
  final _startTimeInput = TextEditingController();
  final _endTimeInput = TextEditingController();

  DateTime get _today => dateOnly(DateTime.now());
  DateTime get _selected => _date ?? _today;

  @override
  void initState() {
    super.initState();
    final task = widget.task;
    _date = task.dueDate == null ? null : dateOnly(task.dueDate!);
    _end = task.endDate == null ? null : dateOnly(task.endDate!);
    _time = task.dueTime;
    _endTime = task.endTime;
    _reminder = task.reminderMinutes;
    _rule = recurrenceFor(task);
    _range = _end != null;
    _month = DateTime(_selected.year, _selected.month);
    _startTimeInput.text = _time ?? '';
    _endTimeInput.text = _endTime ?? '';
  }

  @override
  void dispose() {
    _startTimeInput.dispose();
    _endTimeInput.dispose();
    super.dispose();
  }

  void _updateRule(RecurrenceRule rule) => setState(() {
    _rule = rule;
    _ruleEdited = true;
    _error = null;
    if (rule.frequency != 'none') _date ??= _today;
  });

  void _quickDate(DateTime date, {String? time}) => setState(() {
    _date = date;
    _month = DateTime(date.year, date.month);
    if (_range && (_end == null || _end!.isBefore(date))) _end = date;
    if (time != null) {
      _time = time;
      _startTimeInput.text = time;
    }
    _error = null;
  });

  RecurrenceRule _resultRule() {
    final changed =
        _ruleEdited || calendarDate(_date) != calendarDate(widget.task.dueDate);
    return changed ? _rule.copyWith(anchorDate: _date, occurrence: 1) : _rule;
  }

  TaskSchedule _schedule() => TaskSchedule(
    dueDate: _date,
    dueTime: _time,
    endDate: _range ? _end : null,
    endTime: _range ? _endTime : null,
    reminderMinutes: _reminder,
    recurrence: ['daily', 'weekly', 'monthly'].contains(_rule.frequency)
        ? _rule.frequency
        : 'none',
    recurrenceRule: _rule.frequency == 'none' ? null : _resultRule(),
  );

  bool _validTime(String value) =>
      RegExp(r'^([01]\d|2[0-3]):[0-5]\d$').hasMatch(value);

  void _confirm() {
    final time = _startTimeInput.text.trim();
    final endTime = _endTimeInput.text.trim();
    String? error;
    if (time.isNotEmpty && !_validTime(time)) error = '开始时间请填写 HH:mm，例如 09:30。';
    if (_range && endTime.isNotEmpty && !_validTime(endTime)) {
      error = '结束时间请填写 HH:mm。';
    }
    if (_rule.frequency != 'none' && _invalidNumbers.isNotEmpty) {
      error = '请填写有效的重复间隔或次数。';
    }
    if (_rule.until != null && _untilInvalid) {
      error = '截止日期请填写有效的 YYYY-MM-DD 日期。';
    }
    if (_date == null &&
        (time.isNotEmpty || _reminder != null || _rule.frequency != 'none')) {
      error = '请先选择日期。';
    }
    if (_range && (_date == null || _end == null)) error = '请选择开始和结束日期。';
    if (_range && _date != null && _end != null && _end!.isBefore(_date!)) {
      error = '结束日期不能早于开始日期。';
    }
    if (_range &&
        _date == _end &&
        time.isNotEmpty &&
        endTime.isNotEmpty &&
        _validTime(time) &&
        _validTime(endTime) &&
        endTime.compareTo(time) < 0) {
      error = '结束时间不能早于开始时间。';
    }
    if (_range && (time.isEmpty != endTime.isEmpty)) {
      error = '时间段请同时填写开始和结束时间，或都留空作为全天。';
    }
    // Runtime notifications are based on a concrete wall-clock time.
    if (_reminder != null && time.isEmpty) error = '请先设置时间，再添加提醒。';
    _time = time.isEmpty ? null : time;
    _endTime = endTime.isEmpty ? null : endTime;
    if (error == null && _rule.frequency != 'none') {
      try {
        final rule = _resultRule();
        validateRecurrence(rule);
        if (rule.until != null && rule.until!.isBefore(_selected)) {
          throw const RecurrenceException('结束重复日期不能早于开始日期。');
        }
        // Validate just the next occurrence; preview can stop at a later data
        // boundary without preventing valid schedules within the supported year.
        nextOccurrence(
          _schedule().applyTo(widget.task),
          completedAt: _selected,
        );
      } on RecurrenceException catch (e) {
        error = e.message;
      }
    }
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.of(context).pop(_schedule());
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: Theme.of(context).copyWith(
      colorScheme: Theme.of(context).colorScheme.copyWith(primary: _teal),
      inputDecorationTheme: const InputDecorationTheme(
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        border: OutlineInputBorder(borderSide: BorderSide(color: _line)),
        enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: _line)),
        focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: _teal)),
      ),
    ),
    child: Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      elevation: 12,
      shadowColor: Colors.black.withValues(alpha: .18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 10, 10, 0),
            child: Row(
              children: [
                _tab(
                  '日期',
                  !_range,
                  () => setState(() {
                    _range = false;
                    _selectEnd = false;
                    _repeatOpen = false;
                    _pickingDates = false;
                  }),
                ),
                const SizedBox(width: 22),
                _tab(
                  '时间段',
                  _range,
                  () => setState(() {
                    _range = true;
                    _date ??= _today;
                    _end ??= _date;
                    _selectEnd = false;
                    _repeatOpen = false;
                    _pickingDates = false;
                  }),
                ),
                const Spacer(),
                IconButton(
                  tooltip: '取消',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, size: 17, color: _muted),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: _line),
          Flexible(
            child: SingleChildScrollView(
              key: ValueKey('schedule-body-$_repeatOpen-$_repeatDetails'),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (!_repeatOpen) ...[
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          _shortcut(
                            '今天',
                            Icons.wb_sunny_outlined,
                            () => _quickDate(_today),
                          ),
                          _shortcut(
                            '明天',
                            Icons.wb_twilight,
                            () => _quickDate(addCalendarDays(_today, 1)),
                          ),
                          _shortcut(
                            '下周',
                            Icons.next_week_outlined,
                            () => _quickDate(
                              addCalendarDays(_today, 8 - _today.weekday),
                            ),
                          ),
                          _shortcut(
                            '今晚',
                            Icons.nights_stay_outlined,
                            () => _quickDate(_today, time: '20:00'),
                          ),
                        ],
                      ),
                      if (_range) ...[
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Expanded(
                              child: _rangeDate(
                                '开始',
                                _date,
                                !_selectEnd,
                                () => setState(() => _selectEnd = false),
                              ),
                            ),
                            const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 8),
                              child: Icon(
                                Icons.arrow_forward,
                                size: 14,
                                color: _muted,
                              ),
                            ),
                            Expanded(
                              child: _rangeDate(
                                '结束',
                                _end,
                                _selectEnd,
                                () => setState(() => _selectEnd = true),
                              ),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 10),
                      _calendar(),
                      const SizedBox(height: 8),
                      const Divider(height: 1, color: _line),
                      _expandRow(
                        Icons.access_time,
                        '时间',
                        _time == null
                            ? '全天'
                            : '$_time${_range && _endTime != null ? ' – $_endTime' : ''}',
                        _timeOpen,
                        () => setState(() => _timeOpen = !_timeOpen),
                      ),
                      if (_timeOpen) _timeSettings(),
                      _expandRow(
                        Icons.notifications_none,
                        '提醒',
                        _reminder == null
                            ? '无'
                            : _reminder == 0
                            ? '准时'
                            : '提前 $_reminder 分钟',
                        _reminderOpen,
                        () => setState(() => _reminderOpen = !_reminderOpen),
                      ),
                      if (_reminderOpen) _reminderSettings(),
                      _expandRow(
                        Icons.repeat,
                        '重复',
                        recurrenceLabel(_rule),
                        _repeatOpen,
                        () => setState(() {
                          _repeatOpen = true;
                          _repeatDetails = false;
                        }),
                      ),
                    ],
                    if (_repeatOpen) _repeatSettings(),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Text(
                          _error!,
                          key: const Key('schedule-error'),
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFFBE5555),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const Divider(height: 1, color: _line),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            child: Row(
              children: [
                TextButton(
                  key: const Key('schedule-clear'),
                  onPressed: () =>
                      Navigator.of(context).pop(const TaskSchedule()),
                  child: const Text('清除', style: TextStyle(color: _muted)),
                ),
                const Spacer(),
                FilledButton(
                  key: const Key('schedule-confirm'),
                  onPressed: _confirm,
                  style: FilledButton.styleFrom(
                    backgroundColor: _teal,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(108, 38),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                  child: const Text('确定'),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  Widget _tab(String label, bool selected, VoidCallback onTap) => InkWell(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 13),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: selected ? _teal : Colors.transparent,
            width: 2,
          ),
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 14,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          color: selected ? _teal : _muted,
        ),
      ),
    ),
  );

  Widget _shortcut(String label, IconData icon, VoidCallback onTap) => InkWell(
    borderRadius: BorderRadius.circular(8),
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 5),
      child: Column(
        children: [
          Icon(icon, size: 23, color: _teal),
          const SizedBox(height: 6),
          Text(label, style: const TextStyle(fontSize: 12, color: _text)),
        ],
      ),
    ),
  );

  Widget _rangeDate(
    String label,
    DateTime? date,
    bool selected,
    VoidCallback onTap,
  ) => InkWell(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(color: selected ? _teal : _line),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 10, color: _muted)),
          Text(
            calendarDate(date) ?? '选择日期',
            style: const TextStyle(fontSize: 12, color: _text),
          ),
        ],
      ),
    ),
  );

  Widget _calendar() {
    final first = DateTime(_month.year, _month.month);
    final begin = addCalendarDays(first, 1 - first.weekday);
    final dates = List.generate(42, (i) => addCalendarDays(begin, i));
    return Column(
      children: [
        Row(
          children: [
            Text(
              '${_month.year} 年 ${_month.month} 月',
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: _text,
              ),
            ),
            const Spacer(),
            IconButton(
              tooltip: '上个月',
              visualDensity: VisualDensity.compact,
              onPressed: () => setState(
                () => _month = DateTime(_month.year, _month.month - 1),
              ),
              icon: const Icon(Icons.chevron_left, size: 19, color: _muted),
            ),
            TextButton(
              style: TextButton.styleFrom(
                minimumSize: const Size(30, 30),
                padding: const EdgeInsets.symmetric(horizontal: 4),
              ),
              onPressed: () =>
                  setState(() => _month = DateTime(_today.year, _today.month)),
              child: const Text(
                '今天',
                style: TextStyle(fontSize: 11, color: _muted),
              ),
            ),
            IconButton(
              tooltip: '下个月',
              visualDensity: VisualDensity.compact,
              onPressed: () => setState(
                () => _month = DateTime(_month.year, _month.month + 1),
              ),
              icon: const Icon(Icons.chevron_right, size: 19, color: _muted),
            ),
          ],
        ),
        Row(
          children: ['一', '二', '三', '四', '五', '六', '日']
              .map(
                (d) => Expanded(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 7),
                      child: Text(
                        d,
                        style: const TextStyle(fontSize: 11, color: _muted),
                      ),
                    ),
                  ),
                ),
              )
              .toList(),
        ),
        LayoutBuilder(
          builder: (context, constraints) => Wrap(
            children: dates.map((d) {
              final selected = _pickingDates
                  ? _rule.dates.any((v) => dateOnly(v) == d)
                  : d == _date || (_range && d == _end);
              final inRange =
                  _range &&
                  _date != null &&
                  _end != null &&
                  d.isAfter(_date!) &&
                  d.isBefore(_end!);
              final isToday = d == _today;
              final marker = d.year != 2026
                  ? null
                  : isChinaHoliday2026(d)
                  ? '休'
                  : d.weekday >= 6 && isChinaWorkday2026(d)
                  ? '班'
                  : null;
              return SizedBox(
                width: constraints.maxWidth / 7,
                height: 34,
                child: InkWell(
                  key: Key('calendar-${calendarDate(d)}'),
                  borderRadius: BorderRadius.circular(17),
                  onTap: () => setState(() {
                    if (_pickingDates) {
                      final selectedDates = _rule.dates.map(dateOnly).toSet();
                      selectedDates.contains(d)
                          ? selectedDates.remove(d)
                          : selectedDates.add(d);
                      final sorted = selectedDates.toList()..sort();
                      _rule = _rule.copyWith(dates: sorted);
                      _ruleEdited = true;
                      if (sorted.isNotEmpty) _date = sorted.first;
                    } else if (_range && _selectEnd) {
                      _end = d;
                      _selectEnd = false;
                    } else {
                      _date = d;
                      if (_range) {
                        if (_end == null || _end!.isBefore(d)) _end = d;
                        _selectEnd = true;
                      }
                    }
                    _error = null;
                  }),
                  child: Container(
                    decoration: BoxDecoration(
                      color: inRange ? _teal.withValues(alpha: .10) : null,
                    ),
                    alignment: Alignment.center,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Container(
                          width: 28,
                          height: 28,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: selected ? _teal : null,
                            border: isToday && !selected
                                ? Border.all(color: _teal)
                                : null,
                          ),
                          child: Text(
                            '${d.day}',
                            style: TextStyle(
                              fontSize: 12,
                              color: selected
                                  ? Colors.white
                                  : d.month == _month.month
                                  ? _text
                                  : _muted.withValues(alpha: .45),
                            ),
                          ),
                        ),
                        if (marker != null)
                          Positioned(
                            right: 1,
                            top: 0,
                            child: Tooltip(
                              message:
                                  '${calendarDate(d)} · 国务院 2026 年安排：${marker == '休' ? '放假' : '调休补班'}',
                              child: Container(
                                width: 12,
                                height: 12,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: marker == '休'
                                      ? const Color(0xFFEAF6F5)
                                      : const Color(0xFFFFF2E8),
                                  borderRadius: BorderRadius.circular(3),
                                ),
                                child: Text(
                                  marker,
                                  style: TextStyle(
                                    fontSize: 8,
                                    height: 1,
                                    fontWeight: FontWeight.w500,
                                    color: marker == '休'
                                        ? _teal
                                        : const Color(0xFFBF895C),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  Widget _expandRow(
    IconData icon,
    String title,
    String value,
    bool open,
    VoidCallback tap,
  ) => InkWell(
    onTap: tap,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Icon(icon, size: 17, color: _muted),
          const SizedBox(width: 11),
          Text(title, style: const TextStyle(fontSize: 13, color: _text)),
          const Spacer(),
          Flexible(
            child: Text(
              value,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: _muted),
            ),
          ),
          const SizedBox(width: 6),
          Icon(
            open ? Icons.expand_less : Icons.chevron_right,
            size: 16,
            color: _muted,
          ),
        ],
      ),
    ),
  );

  Widget _timeSettings() => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Column(
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const Key('schedule-start-time'),
                controller: _startTimeInput,
                keyboardType: TextInputType.datetime,
                decoration: InputDecoration(
                  labelText: _range ? '开始时间' : '时间',
                  hintText: '09:00',
                ),
                onChanged: (value) =>
                    setState(() => _time = value.isEmpty ? null : value),
              ),
            ),
            if (_range) ...[
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  key: const Key('schedule-end-time'),
                  controller: _endTimeInput,
                  keyboardType: TextInputType.datetime,
                  decoration: const InputDecoration(
                    labelText: '结束时间',
                    hintText: '10:00',
                  ),
                  onChanged: (value) =>
                      setState(() => _endTime = value.isEmpty ? null : value),
                ),
              ),
            ],
            IconButton(
              tooltip: '设为全天',
              onPressed: () => setState(() {
                _time = null;
                _endTime = null;
                _reminder = null;
                _startTimeInput.clear();
                _endTimeInput.clear();
              }),
              icon: const Icon(Icons.clear, size: 16, color: _muted),
            ),
          ],
        ),
        const SizedBox(height: 5),
        const Align(
          alignment: Alignment.centerLeft,
          child: Text(
            '使用设备本地时区 · 24 小时制',
            style: TextStyle(fontSize: 10, color: _muted),
          ),
        ),
      ],
    ),
  );

  Widget _reminderSettings() => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _dropdown<int>(
          '提醒时间',
          _reminder ?? -1,
          {
            -1: '无',
            0: '准时',
            5: '提前 5 分钟',
            10: '提前 10 分钟',
            15: '提前 15 分钟',
            30: '提前 30 分钟',
            60: '提前 1 小时',
            1440: '提前 1 天',
            if (_reminder != null &&
                ![-1, 0, 5, 10, 15, 30, 60, 1440].contains(_reminder))
              _reminder!: '提前 $_reminder 分钟',
          },
          (v) => setState(() {
            _reminder = v == -1 ? null : v;
            if (_reminder != null && _time == null) {
              _date ??= _today;
              _time = '09:00';
              _startTimeInput.text = '09:00';
              if (_range && _endTime == null) {
                _endTime = '10:00';
                _endTimeInput.text = '10:00';
              }
            }
          }),
        ),
        const SizedBox(height: 6),
        const Text(
          '提醒在应用打开时生效；未设置时间时默认 09:00。',
          style: TextStyle(fontSize: 10, color: _muted),
        ),
      ],
    ),
  );

  Widget _repeatSettings() {
    if (!_repeatDetails) return _repeatPresets();
    final rule = _rule;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton(
              key: const Key('repeat-back'),
              tooltip: '返回重复选项',
              visualDensity: VisualDensity.compact,
              onPressed: () => setState(() {
                _repeatDetails = false;
                _pickingDates = false;
              }),
              icon: const Icon(
                Icons.arrow_back_ios_new,
                size: 16,
                color: _muted,
              ),
            ),
            Text(
              _customDetails ? '自定义重复' : recurrenceLabel(rule),
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: _text,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (_customDetails)
          _dropdown<String>(
            '重复方式',
            rule.frequency,
            const {
              'none': '不重复',
              'daily': '每天',
              'weekly': '每周',
              'monthly': '每月',
              'yearly': '每年',
              'workdays': '工作日',
              'holidays': '节假日 / 周末',
              'lunar': '农历重复',
              'ebbinghaus': '艾宾浩斯记忆法',
              'dates': '自选日期',
            },
            (v) {
              _selectRepeatPreset(v, custom: true);
            },
          ),
        if (rule.frequency != 'none') ...[
          const SizedBox(height: 10),
          if (!['ebbinghaus', 'dates'].contains(rule.frequency)) ...[
            Row(
              children: [
                const Text('每隔', style: TextStyle(fontSize: 12, color: _muted)),
                const SizedBox(width: 10),
                SizedBox(
                  width: 72,
                  child: _number(
                    'interval-${rule.frequency}',
                    rule.interval,
                    (v) => _updateRule(rule.copyWith(interval: v)),
                    max: 999,
                  ),
                ),
                const SizedBox(width: 8),
                Text(switch (rule.frequency) {
                  'daily' => '天',
                  'weekly' => '周',
                  'monthly' => '个月',
                  'yearly' => '年',
                  'workdays' => '个工作日',
                  'holidays' => '个休息日',
                  _ => rule.lunarMode == 'monthly' ? '个农历月' : '个农历年',
                }, style: const TextStyle(fontSize: 12, color: _muted)),
              ],
            ),
            const SizedBox(height: 10),
          ],
          if (rule.frequency == 'weekly' && rule.basis == 'due') _weekdays(),
          if (['monthly', 'yearly'].contains(rule.frequency) &&
              rule.basis == 'due')
            _monthSettings(),
          if (['workdays', 'holidays'].contains(rule.frequency)) ...[
            _dropdown<String>('日历模式', rule.workdayMode, {
              'weekdays': rule.frequency == 'workdays' ? '每周一至周五' : '每周六、周日',
              'china2026': '中国大陆调休 · 仅 2026 年',
            }, (v) => _updateRule(rule.copyWith(workdayMode: v))),
            if (rule.workdayMode == 'china2026')
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  '依据国务院 2026 年安排，含补班周末。2027 年起需更新日历；可设结束日期或改用每周模式。',
                  style: TextStyle(fontSize: 11, color: _muted),
                ),
              ),
            const SizedBox(height: 10),
          ],
          if (rule.frequency == 'lunar') _lunarSettings(),
          if (rule.frequency == 'ebbinghaus')
            const Padding(
              padding: EdgeInsets.only(bottom: 10),
              child: Text(
                '第 1、2、4、7、15 天复习，此后每隔 15 天。第 1 天为首次学习当天。',
                style: TextStyle(fontSize: 11, color: _muted),
              ),
            ),
          if (rule.frequency == 'dates') ...[
            if (_pickingDates) _calendar(),
            OutlinedButton.icon(
              onPressed: () => setState(() => _pickingDates = !_pickingDates),
              icon: Icon(
                _pickingDates ? Icons.done : Icons.date_range,
                size: 16,
              ),
              label: Text(_pickingDates ? '正在上方日历选择多天' : '在日历中选择日期'),
            ),
            Wrap(
              spacing: 4,
              runSpacing: 3,
              children: rule.dates
                  .map(
                    (d) => InputChip(
                      label: Text(
                        calendarDate(d)!,
                        style: const TextStyle(fontSize: 10),
                      ),
                      onDeleted: () => _updateRule(
                        rule.copyWith(
                          dates: rule.dates.where((v) => v != d).toList(),
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
            const SizedBox(height: 6),
          ],
          if (rule.frequency != 'dates') ...[
            _dropdown<String>('重复依据', rule.basis, const {
              'due': '按到期日',
              'completion': '按完成日',
            }, (v) => _updateRule(rule.copyWith(basis: v))),
            if (rule.basis == 'completion')
              const Padding(
                padding: EdgeInsets.only(top: 5, bottom: 5),
                child: Text(
                  '从实际完成日期重新计算间隔，以下预览假设当天完成。',
                  style: TextStyle(fontSize: 10, color: _muted),
                ),
              ),
            const SizedBox(height: 10),
          ],
          _endSettings(),
          _preview(),
        ],
      ],
    );
  }

  void _selectRepeatPreset(String frequency, {bool custom = false}) {
    _invalidNumbers.clear();
    _untilInvalid = false;
    final lunar = Lunar.fromDate(_selected);
    final nextRule = custom && _rule.frequency != 'none'
        ? _rule.copyWith(frequency: frequency)
        : frequency == _rule.frequency
        ? _rule
        : RecurrenceRule(
            frequency: frequency,
            anchorDate: _selected,
            weekdays: [_selected.weekday],
            monthDays: [_selected.day],
            month: _selected.month,
            lunarMonth: lunar.getMonth().abs(),
            lunarDay: lunar.getDay(),
            lunarLeap: lunar.getMonth() < 0,
            dates: frequency == 'dates' ? [_selected] : const [],
          );
    _updateRule(nextRule);
    setState(() {
      _customDetails = custom;
      _repeatDetails = frequency != 'none';
      _repeatOpen = frequency != 'none';
      _pickingDates = frequency == 'dates';
    });
  }

  Widget _repeatPresets() {
    final weekday = ['一', '二', '三', '四', '五', '六', '日'][_selected.weekday - 1];
    final presets = <(String, String, IconData)>[
      ('none', '不重复', Icons.block),
      ('daily', '每天', Icons.today_outlined),
      ('weekly', '每周（周$weekday）', Icons.view_week_outlined),
      ('monthly', '每月（${_selected.day} 日）', Icons.calendar_view_month),
      (
        'yearly',
        '每年（${_selected.month} 月 ${_selected.day} 日）',
        Icons.event_repeat,
      ),
      ('workdays', '工作日', Icons.work_outline),
      ('holidays', '节假日', Icons.beach_access_outlined),
      ('lunar', '农历重复', Icons.nightlight_outlined),
      ('ebbinghaus', '艾宾浩斯记忆法', Icons.psychology_outlined),
      ('dates', '自选日期', Icons.event_available_outlined),
      ('custom', '自定义', Icons.tune),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton(
              tooltip: '返回日期设置',
              visualDensity: VisualDensity.compact,
              onPressed: () => setState(() {
                _repeatOpen = false;
                _pickingDates = false;
              }),
              icon: const Icon(
                Icons.arrow_back_ios_new,
                size: 16,
                color: _muted,
              ),
            ),
            const Text(
              '重复',
              style: TextStyle(
                fontSize: 14,
                color: _text,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ...presets.map((p) {
          final selected = p.$1 == _rule.frequency;
          return InkWell(
            key: Key('repeat-preset-${p.$1}'),
            borderRadius: BorderRadius.circular(6),
            onTap: () => _selectRepeatPreset(
              p.$1 == 'custom'
                  ? (_rule.frequency == 'none' ? 'daily' : _rule.frequency)
                  : p.$1,
              custom: p.$1 == 'custom',
            ),
            child: Container(
              height: 38,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: selected ? _teal.withValues(alpha: .08) : null,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  Icon(p.$3, size: 16, color: selected ? _teal : _muted),
                  const SizedBox(width: 12),
                  Text(
                    p.$2,
                    style: TextStyle(
                      fontSize: 13,
                      color: selected ? _teal : _text,
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    selected ? Icons.check : Icons.chevron_right,
                    size: 16,
                    color: selected ? _teal : _muted,
                  ),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }

  Widget _weekdays() => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(
      children: List.generate(7, (index) {
        final day = index + 1;
        final selected = _rule.weekdays.contains(day);
        return Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: InkWell(
              key: Key('repeat-weekday-$day'),
              onTap: () {
                final days = _rule.weekdays.toSet();
                if (selected && days.length > 1) {
                  days.remove(day);
                } else {
                  days.add(day);
                }
                _updateRule(_rule.copyWith(weekdays: days.toList()..sort()));
              },
              borderRadius: BorderRadius.circular(6),
              child: Container(
                alignment: Alignment.center,
                height: 32,
                decoration: BoxDecoration(
                  color: selected ? _teal : const Color(0xFFF4F6F6),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  ['一', '二', '三', '四', '五', '六', '日'][index],
                  style: TextStyle(
                    fontSize: 12,
                    color: selected ? Colors.white : _muted,
                  ),
                ),
              ),
            ),
          ),
        );
      }),
    ),
  );

  Widget _monthSettings() => Column(
    children: [
      if (_rule.frequency == 'yearly') ...[
        _dropdown<int>('月份', _rule.month ?? _selected.month, {
          for (var i = 1; i <= 12; i++) i: '$i 月',
        }, (v) => _updateRule(_rule.copyWith(month: v))),
        const SizedBox(height: 10),
      ],
      _dropdown<String>(
        '日期规则',
        _rule.ordinal == null ? 'day' : 'weekday',
        const {'day': '指定日期', 'weekday': '第几个星期几'},
        (v) => _updateRule(
          _rule.copyWith(
            ordinal: v == 'day' ? null : 1,
            ordinalWeekday: v == 'day' ? null : _selected.weekday,
          ),
        ),
      ),
      const SizedBox(height: 10),
      if (_rule.ordinal != null)
        Row(
          children: [
            Expanded(
              child: _dropdown<int>('第几个', _rule.ordinal!, const {
                1: '第一个',
                2: '第二个',
                3: '第三个',
                4: '第四个',
                5: '第五个',
                -1: '最后一个',
              }, (v) => _updateRule(_rule.copyWith(ordinal: v))),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _dropdown<int>('星期', _rule.ordinalWeekday!, const {
                1: '周一',
                2: '周二',
                3: '周三',
                4: '周四',
                5: '周五',
                6: '周六',
                7: '周日',
              }, (v) => _updateRule(_rule.copyWith(ordinalWeekday: v))),
            ),
          ],
        )
      else
        Wrap(
          spacing: 3,
          runSpacing: 3,
          children: List.generate(31, (i) {
            final day = i + 1;
            final selected = _rule.monthDays.contains(day);
            return SizedBox(
              width: 33,
              height: 29,
              child: InkWell(
                borderRadius: BorderRadius.circular(4),
                onTap: () {
                  final days = _rule.monthDays.toSet();
                  if (selected && days.length > 1) {
                    days.remove(day);
                  } else {
                    days.add(day);
                  }
                  _updateRule(_rule.copyWith(monthDays: days.toList()..sort()));
                },
                child: Container(
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: selected ? _teal : const Color(0xFFF4F6F6),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '$day',
                    style: TextStyle(
                      fontSize: 11,
                      color: selected ? Colors.white : _text,
                    ),
                  ),
                ),
              ),
            );
          }),
        ),
      Padding(
        padding: const EdgeInsets.only(top: 5, bottom: 10),
        child: Text(
          _rule.ordinal == 5 ? '没有第五个对应星期的月份会跳过。' : '日期超出月份天数时使用当月最后一天。',
          style: const TextStyle(fontSize: 10, color: _muted),
        ),
      ),
    ],
  );

  Widget _lunarSettings() => Column(
    children: [
      _dropdown<String>('农历周期', _rule.lunarMode, const {
        'yearly': '农历每年',
        'monthly': '农历每月（含闰月）',
      }, (v) => _updateRule(_rule.copyWith(lunarMode: v))),
      const SizedBox(height: 10),
      Row(
        children: [
          if (_rule.lunarMode == 'yearly') ...[
            Expanded(
              child: _dropdown<int>('农历月', _rule.lunarMonth ?? 1, {
                for (var i = 1; i <= 12; i++) i: '$i 月',
              }, (v) => _updateRule(_rule.copyWith(lunarMonth: v))),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: _dropdown<int>('农历日', _rule.lunarDay ?? 1, {
              for (var i = 1; i <= 30; i++) i: '$i 日',
            }, (v) => _updateRule(_rule.copyWith(lunarDay: v))),
          ),
        ],
      ),
      if (_rule.lunarMode == 'yearly')
        CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('只在闰月重复', style: TextStyle(fontSize: 12)),
          value: _rule.lunarLeap,
          onChanged: (v) => _updateRule(_rule.copyWith(lunarLeap: v)),
        ),
      const Padding(
        padding: EdgeInsets.only(top: 5, bottom: 10),
        child: Text(
          '支持 1901–2099 年；小月的三十按廿九处理。仅闰月时会跳过没有该闰月的年份。',
          style: TextStyle(fontSize: 10, color: _muted),
        ),
      ),
    ],
  );

  Widget _endSettings() {
    final mode = _rule.count != null
        ? 'count'
        : _rule.until != null
        ? 'date'
        : 'never';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _dropdown<String>(
          '结束重复',
          mode,
          const {'never': '永不结束', 'date': '按日期结束', 'count': '按次数结束'},
          (v) {
            _untilInvalid = false;
            _invalidNumbers.remove('count');
            _updateRule(
              _rule.copyWith(
                count: v == 'count' ? 10 : null,
                until: v == 'date'
                    ? DateTime(
                        _selected.year,
                        _selected.month + 1,
                        _selected.day,
                      )
                    : null,
              ),
            );
          },
        ),
        if (mode == 'count')
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Row(
              children: [
                const Text('共', style: TextStyle(fontSize: 12, color: _muted)),
                const SizedBox(width: 8),
                SizedBox(
                  width: 80,
                  child: _number(
                    'count',
                    _rule.count!,
                    (v) => _updateRule(_rule.copyWith(count: v)),
                    max: 100000,
                  ),
                ),
                const SizedBox(width: 8),
                const Text(
                  '次（包含当前任务）',
                  style: TextStyle(fontSize: 11, color: _muted),
                ),
              ],
            ),
          ),
        if (mode == 'date')
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: TextFormField(
              key: ValueKey('until-${calendarDate(_rule.until)}'),
              initialValue: calendarDate(_rule.until),
              decoration: const InputDecoration(
                labelText: '截止日期',
                hintText: '2026-12-31',
              ),
              onChanged: (v) {
                final date = DateTime.tryParse(v);
                _untilInvalid = date == null || calendarDate(date) != v;
                if (date != null && calendarDate(date) == v) {
                  // Do not rebuild this keyed field while the user is typing.
                  _rule = _rule.copyWith(until: date);
                  _ruleEdited = true;
                }
              },
            ),
          ),
      ],
    );
  }

  Widget _preview() {
    final dates = <DateTime>[];
    String? problem;
    try {
      var task = _schedule().applyTo(widget.task);
      for (var i = 0; i < 3; i++) {
        final next = nextOccurrence(task, completedAt: task.dueDate ?? _today);
        if (next == null) break;
        dates.add(next.date);
        task = task.copyWith(
          dueDate: next.date,
          endDate: next.endDate,
          recurrenceRule: next.rule,
        );
      }
    } on RecurrenceException catch (e) {
      problem = e.message;
    }
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            dates.isEmpty
                ? '完成当前任务后：${problem == null ? '重复结束' : '暂无可用日期'}'
                : '后续：${dates.map((d) => calendarDate(d)!).join('  ·  ')}',
            style: const TextStyle(fontSize: 10, color: _teal),
          ),
          if (problem != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                problem,
                style: const TextStyle(fontSize: 10, color: _muted),
              ),
            ),
        ],
      ),
    );
  }

  Widget _number(
    String key,
    int value,
    ValueChanged<int> change, {
    required int max,
  }) => TextFormField(
    key: ValueKey('number-$key'),
    initialValue: '$value',
    keyboardType: TextInputType.number,
    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
    decoration: const InputDecoration(),
    onChanged: (v) {
      final number = int.tryParse(v);
      if (number != null && number >= 1 && number <= max) {
        _invalidNumbers.remove(key);
        change(number);
      } else {
        _invalidNumbers.add(key);
      }
    },
  );

  Widget _dropdown<T>(
    String label,
    T value,
    Map<T, String> options,
    ValueChanged<T> change,
  ) => DropdownButtonFormField<T>(
    key: ValueKey('$label:$value'),
    initialValue: value,
    isExpanded: true,
    style: const TextStyle(fontSize: 12, color: _text),
    decoration: InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(fontSize: 11, color: _muted),
    ),
    items: options.entries
        .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
        .toList(),
    onChanged: (v) {
      if (v != null) change(v);
    },
  );
}
