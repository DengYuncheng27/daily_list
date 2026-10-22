import 'dart:convert';
import 'dart:io';

import 'package:dayflow/core/recurrence.dart';
import 'package:dayflow/core/ticktick_import.dart';
import 'package:flutter_test/flutter_test.dart';

String csv(List<String> headers, List<List<String>> rows) => [headers, ...rows]
    .map((r) => r.map((v) => '"${v.replaceAll('"', '""')}"').join(','))
    .join('\r\n');

TickTickImportPreview parse(
  List<String> headers,
  List<List<String>> rows, {
  String account = 'default',
}) => TickTickImport.parseBytes(
  utf8.encode(csv(headers, rows)),
  sourceAccount: account,
);

Set<String> codes(TickTickImportPreview preview) =>
    preview.warnings.map((w) => w.code).toSet();

void main() {
  test('official-shaped synthetic v7.1 fixture parses metadata and multiline content', () {
    final p = TickTickImport.parseBytes(
      File('test/fixtures/ticktick_backup_synthetic.csv').readAsBytesSync(),
      sourceName: 'fixture.csv',
    );
    expect(p.tasks, hasLength(5));
    expect(p.metadata, hasLength(3));
    expect(p.tasks.first.title, '部署 "日序", 验收');
    expect(p.tasks.first.notes, contains('第一行\n第二行'));
    expect(p.tasks.first.dueDate, DateTime(2026, 10, 22));
    expect(p.tasks.first.dueTime, '09:00');
    expect(p.tasks.first.endTime, '10:30');
    expect(p.tasks.first.priority, 3);
    expect(p.tasks.first.tags, ['工作', '发布']);
    expect(p.tasks.first.reminderMinutes, 15);
    expect(p.lists.map((l) => l.name), contains('工作 / 产品'));
    expect(p.completedCount, 2);
    expect(p.noteCount, 1);
    expect(p.checklistCount, 2);
    expect(p.attachmentReferenceCount, 1);
    expect(p.tasks[1].subtasks.map((s) => s.completed), [false, true]);
    expect(p.tasks[3].importData['__parentDayflowId'], p.tasks.first.id);
    expect(p.tasks[4].completed, isTrue);
    expect(p.tasks.first.importData['Estimated Pomodoro'], '3');
    expect(jsonDecode(jsonEncode(p.toReportJson()))['counts']['tasks'], 5);
  });

  test('BOM, CR only, trailing cells, and empty rows are supported', () {
    final p = TickTickImport.parseBytes(
      utf8.encode('\uFEFFTitle,List Name,Content\r\rA,Inbox,"a\rb"\rB,Work,\r'),
    );
    expect(p.tasks, hasLength(2));
    expect(p.tasks.first.notes, 'a\nb');
    expect(p.tasks.first.listId, 'inbox');
    expect(p.tasks.last.notes, '');
  });

  test(
    'UTF16 little and big endian BOMs decode without corrupting Chinese',
    () {
      final input = '标题,清单\n测试,工作';
      for (final little in [true, false]) {
        final bytes = <int>[
          if (little) ...[255, 254] else ...[254, 255],
        ];
        for (final c in input.codeUnits) {
          bytes.addAll(little ? [c & 255, c >> 8] : [c >> 8, c & 255]);
        }
        expect(TickTickImport.parseBytes(bytes).tasks.single.title, '测试');
      }
    },
  );

  test('RFC quoting rejects broken files before producing partial preview', () {
    for (final input in [
      'Title,List Name\n"open,Inbox',
      'Title,List Name\n"a"unexpected,Inbox',
      'Title,List Name\na"b,Inbox',
    ]) {
      expect(
        () => TickTickImport.parseBytes(utf8.encode(input)),
        throwsA(isA<TickTickImportException>()),
      );
    }
    expect(
      () => TickTickImport.parseBytes([255, 0, 255]),
      throwsA(isA<TickTickImportException>()),
    );
    expect(
      () => TickTickImport.parseBytes(utf8.encode('Title,List\nA,\u0000')),
      throwsA(isA<TickTickImportException>()),
    );
  });

  test('CSV header detection does not assume six physical preamble lines', () {
    final p = TickTickImport.parseBytes(
      utf8.encode(
        '"Date: 2026-10-22"\n"Status:\n0 Normal\n1 Completed\n2 Archived"\n"Title","Content"\n"A","Notes"',
      ),
    );
    expect(p.tasks.single.title, 'A');
    expect(p.metadata, hasLength(2));
    expect(
      () => TickTickImport.parseBytes(utf8.encode('just some text')),
      throwsA(isA<TickTickImportException>()),
    );
  });

  test('duplicate headers and mismatched columns keep all raw data', () {
    final p = TickTickImport.parseBytes(
      utf8.encode('Title,Content,Content\nA,one,two,extra\nB'),
    );
    expect(p.tasks.first.notes, 'one');
    expect(p.records.first.rawFields['Content [2]'], 'two');
    expect(p.records.first.rawFields['Extra column 4'], 'extra');
    expect(p.tasks.last.title, 'B');
    expect(codes(p), containsAll(['duplicate_header', 'column_count']));
  });

  test(
    'source metadata does not overwrite user fields with reserved names',
    () {
      final p = parse(
        ['Title', 'Content', '__source', 'CSV:__source'],
        [
          ['A', 'B', 'mine', 'also mine'],
        ],
      );
      expect(p.tasks.single.importData['__source'], 'ticktick');
      expect(
        p.tasks.single.importData.values,
        containsAll(['mine', 'also mine']),
      );
      expect(p.records.single.rawFields['__source'], 'mine');
    },
  );

  test(
    'real source IDs are stable across edits and source accounts are isolated',
    () {
      final a = parse(
        ['Title', 'List Name', 'taskId'],
        [
          ['First', 'One', 'abcd1234'],
        ],
      );
      final b = parse(
        ['Title', 'List Name', 'taskId'],
        [
          ['Renamed', 'Two', 'abcd1234'],
        ],
      );
      final other = parse(
        ['Title', 'List Name', 'taskId'],
        [
          ['First', 'One', 'abcd1234'],
        ],
        account: 'second',
      );
      expect(a.tasks.single.id, b.tasks.single.id);
      expect(a.tasks.single.id, isNot(other.tasks.single.id));
      expect(a.lists.single.id, isNot(other.lists.single.id));
    },
  );

  test('numeric export row IDs do not make new reordered tasks disappear', () {
    final a = parse(
      ['Title', 'List Name', 'taskId', 'Status'],
      [
        ['Alpha', 'Work', '0', '0'],
        ['Beta', 'Work', '1', '0'],
      ],
    );
    final b = parse(
      ['Title', 'List Name', 'taskId', 'Status'],
      [
        ['Beta', 'Work', '0', '1'],
        ['Alpha', 'Work', '1', '0'],
        ['Gamma', 'Work', '2', '0'],
      ],
    );
    expect(a.tasks.first.id, b.tasks[1].id);
    expect(a.tasks[1].id, b.tasks.first.id);
    expect(b.tasks.last.id, isNot(a.tasks.first.id));
    expect(codes(a), contains('fallback_identity'));
  });

  test(
    'duplicate identical task rows remain distinct but repeat imports stable',
    () {
      final rows = [
        ['A', 'Work'],
        ['A', 'Work'],
      ];
      final a = parse(['Title', 'List Name'], rows);
      final b = parse(['Title', 'List Name'], rows);
      expect(a.tasks.map((t) => t.id).toSet(), hasLength(2));
      expect(a.tasks.map((t) => t.id), b.tasks.map((t) => t.id));
      expect(codes(a), contains('duplicate_identity'));
    },
  );

  test('folder paths isolate identically named lists and flatten visibly', () {
    final p = parse(
      ['Title', 'List Name', 'Folder Name'],
      [
        ['A', 'Todo', 'Work'],
        ['B', 'Todo', 'Home'],
        ['C', 'Inbox', ''],
      ],
    );
    expect(p.lists.map((l) => l.name), ['Work / Todo', 'Home / Todo']);
    expect(p.tasks.last.listId, 'inbox');
    expect(p.tasks.first.listId, isNot(p.tasks[1].listId));
  });

  test('IANA conversion respects summer/winter DST and explicit offsets', () {
    final p = parse(
      ['Title', 'Start Date', 'Timezone', 'Is All Day'],
      [
        ['Summer', '2026-07-01T14:00:00+0000', 'America/New_York', 'false'],
        ['Winter', '2026-12-01T14:00:00Z', 'America/New_York', 'false'],
        ['Offset', '2026-10-22T09:30:00+0800', 'Asia/Shanghai', 'false'],
      ],
    );
    expect(p.tasks.map((t) => t.dueTime), ['10:00', '09:00', '09:30']);
  });

  test(
    'all-day/floating dates retain calendar date instead of shifting timezone',
    () {
      final p = parse(
        ['Title', 'Due Date', 'Timezone', 'Is All Day', 'Is Floating'],
        [
          [
            'All day',
            '2026-10-22T00:00:00Z',
            'America/Los_Angeles',
            'true',
            'false',
          ],
          [
            'Floating',
            '2026-10-22T00:30:00Z',
            'America/Los_Angeles',
            'false',
            'true',
          ],
          ['Date only', '20261022', 'Asia/Shanghai', '', ''],
        ],
      );
      expect(
        p.tasks.map((t) => t.dueDate),
        everyElement(DateTime(2026, 10, 22)),
      );
      expect(p.tasks.map((t) => t.dueTime), [null, '00:30', null]);
    },
  );

  test(
    'invalid dates/ranges warn without normalizing them into wrong days',
    () {
      final p = parse(
        ['Title', 'Start Date', 'Due Date'],
        [
          ['Bad day', '2026-02-30', ''],
          ['Bad month', '2026-13-01', ''],
          ['Bad clock', '2026-10-22T25:00:00Z', ''],
          ['Reverse', '2026-10-23', '2026-10-22'],
        ],
      );
      expect(p.tasks.take(3).map((t) => t.dueDate), everyElement(isNull));
      expect(p.tasks.last.dueDate, DateTime(2026, 10, 23));
      expect(p.tasks.last.endDate, isNull);
      expect(codes(p), containsAll(['invalid_date', 'date_range']));
    },
  );

  test('unknown timezone retains written wall time and reports fallback', () {
    final p = parse(
      ['Title', 'Start Date', 'Timezone'],
      [
        ['A', '2026-10-22T08:20:00+0800', 'Mars/Olympus'],
      ],
    );
    expect(p.tasks.single.dueTime, '08:20');
    expect(codes(p), contains('unknown_timezone'));
  });

  test('completed status uses backup semantics, archived data is retained', () {
    final p = parse(
      ['Title', 'Status', 'Completed Time'],
      [
        ['Pending', '0', ''],
        ['Done', '1', '2026-10-22T09:00:00+0800'],
        ['Archived', '2', ''],
        ['Unknown', '900', ''],
      ],
    );
    expect(p.tasks.map((t) => t.completed), [false, true, true, false]);
    expect(p.tasks[1].completedAt, DateTime.utc(2026, 10, 22, 1));
    expect(p.tasks[2].deleted, false);
    expect(codes(p), containsAll(['archived_status', 'unknown_status']));
  });

  test('priority 0 1 3 5 maps to no low medium high', () {
    final p = parse(
      ['Title', 'Priority'],
      [
        for (final n in [0, 1, 3, 5, 9]) ['P$n', '$n'],
      ],
    );
    expect(p.tasks.map((t) => t.priority), [0, 1, 2, 3, 0]);
    expect(codes(p), contains('unknown_priority'));
  });

  test('CSV/JSON tags and Markdown remain literal, safe, and editable', () {
    final p = parse(
      ['Title', 'Tags', 'Content'],
      [
        [
          'A',
          '["工作","文档","工作"]',
          '# 标题\n**粗体**\n<script>alert(1)</script>\n![图](https://example.invalid/file.png)',
        ],
        ['B', '#one, two；three', '# 你好'],
      ],
    );
    expect(p.tasks.first.tags, ['工作', '文档']);
    expect(p.tasks.last.tags, ['one', 'two', 'three']);
    expect(
      p.tasks.first.richContent.single['insert'],
      '${p.tasks.first.notes}\n',
    );
    expect(p.tasks.first.attachments, isEmpty);
    expect(
      codes(p),
      containsAll(['markdown_preserved', 'attachment_reference']),
    );
  });

  test('checklist unicode and Markdown states map without dropping body', () {
    final content = '说明\n▫未完成\n▪已完成\n- [ ] 等待\n- [x] 完成';
    final p = parse(
      ['Title', 'Kind', 'Content'],
      [
        ['采购', 'CHECKLIST', content],
      ],
    );
    expect(p.tasks.single.subtasks.map((s) => s.completed), [
      false,
      true,
      false,
      true,
    ]);
    expect(p.tasks.single.subtasks.map((s) => s.id).toSet(), hasLength(4));
    expect(p.tasks.single.notes, content);
  });

  test('child tasks preserve full content and relation instead of reducing to title', () {
    final p = parse(
      ['Title', 'taskId', 'parentId', 'Content'],
      [
        ['Parent', 'p', '', 'Body P'],
        ['Child', 'c', 'p', 'Body C'],
        ['Orphan', 'o', 'missing', 'Body O'],
      ],
    );
    expect(p.tasks, hasLength(3));
    expect(p.tasks[1].notes, 'Body C');
    expect(p.tasks[1].importData['__parentDayflowId'], p.tasks.first.id);
    expect(p.tasks.last.importData['__sourceParentId'], 'missing');
    expect(codes(p), contains('parent_relation'));
  });

  test(
    'simple RRULE daily weekly monthly ordinal and yearly map faithfully',
    () {
      final p = parse(
        ['Title', 'Start Date', 'Repeat'],
        [
          ['Daily', '2026-10-22', 'RRULE:FREQ=DAILY;INTERVAL=2'],
          ['Weekly', '2026-10-22', 'FREQ=WEEKLY;BYDAY=MO,WE,FR;WKST=MO'],
          ['Monthly', '2026-10-22', 'FREQ=MONTHLY;BYDAY=-1FR'],
          ['Yearly', '2026-10-22', 'FREQ=YEARLY;BYMONTH=10;BYMONTHDAY=22'],
        ],
      );
      expect(p.tasks.map((t) => t.recurrenceRule?.frequency), [
        'daily',
        'weekly',
        'monthly',
        'yearly',
      ]);
      expect(
        nextOccurrence(
          p.tasks.first,
          completedAt: DateTime(2026, 10, 22),
        )?.date,
        DateTime(2026, 10, 24),
      );
      expect(p.tasks[1].recurrenceRule?.weekdays, [1, 3, 5]);
      expect(p.tasks[2].recurrenceRule?.ordinal, -1);
      expect(p.tasks[3].recurrenceRule?.month, 10);
    },
  );

  test('unsupported repeat rules are not silently weakened', () {
    final invalid = [
      'FREQ=DAILY;BYHOUR=10',
      'FREQ=DAILY;BYDAY=MO',
      'FREQ=WEEKLY;INTERVAL=2;WKST=SU',
      'FREQ=MONTHLY;BYMONTHDAY=-1',
      'FREQ=MONTHLY;BYMONTHDAY=31',
      'FREQ=MONTHLY;BYDAY=MO,TU',
      'FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=29',
      'FREQ=YEARLY;BYDAY=1MO',
      'FREQ=DAILY;INTERVAL=0',
      'FREQ=DAILY;COUNT=100001',
      'FREQ=DAILY;UNTIL=20260230',
      'FREQ=DAILY\nFREQ=WEEKLY',
      'FREQ=MONTHLY;BYDAY=-2MO',
      'FREQ=DAILY;X-TICKTICK=COMPLETION',
    ];
    final p = parse(
      ['Title', 'Start Date', 'Repeat'],
      [
        for (final rule in invalid) [rule, '2026-10-22', rule],
      ],
    );
    expect(p.tasks.map((t) => t.recurrenceRule), everyElement(isNull));
    expect(
      p.warnings.where((w) => w.code == 'unsupported_recurrence'),
      hasLength(invalid.length),
    );
  });

  test('UNTIL timestamp adjusts day when last time precedes task time', () {
    final p = parse(
      ['Title', 'Start Date', 'Timezone', 'Repeat'],
      [
        [
          'A',
          '2026-10-22T09:00:00+0800',
          'Asia/Shanghai',
          'FREQ=DAILY;UNTIL=20261031T000000Z',
        ],
      ],
    );
    expect(p.tasks.single.recurrenceRule?.until, DateTime(2026, 10, 30));
  });

  test(
    'repeat COUNT warns that past occurrence count is absent from backup',
    () {
      final p = parse(
        ['Title', 'Due Date', 'Repeat'],
        [
          ['A', '2026-10-22', 'FREQ=DAILY;COUNT=5'],
        ],
      );
      expect(p.tasks.single.recurrenceRule?.count, 5);
      expect(codes(p), contains('recurrence_count'));
    },
  );

  test('reminders import one equivalent before-time trigger only', () {
    final p = parse(
      ['Title', 'Start Date', 'Reminder'],
      [
        for (final reminder in [
          'TRIGGER:-PT15M',
          '-P1DT2H',
          'P0DT0H0M0S',
          'PT1H',
          '-PT1S',
          '-P',
          '-P366D',
          '-PT5M,-PT10M',
        ])
          [reminder, '2026-10-22T09:00:00Z', reminder],
      ],
    );
    expect(p.tasks.map((t) => t.reminderMinutes), [
      15,
      1560,
      0,
      null,
      null,
      null,
      null,
      null,
    ]);
  });

  test('sync schema limits clip visible fields but preserve raw source', () {
    final title = '😀' * 350;
    final content = 'a' * 22000;
    final tags = List.generate(22, (i) => '标签$i${'a' * 42}').join(',');
    final p = parse(
      ['Title', 'Content', 'Tags', 'List Name'],
      [
        [title, content, tags, 'x' * 105],
      ],
    );
    expect(p.tasks.single.title.runes.length, 300);
    expect(p.tasks.single.notes.length, 20000);
    expect(p.tasks.single.richContent.single['insert'], '$content\n');
    expect(p.tasks.single.tags, hasLength(20));
    expect(p.tasks.single.tags.every((t) => t.runes.length <= 40), isTrue);
    expect(p.tasks.single.importData['Title'], title);
    expect(p.lists.single.name.length, 100);
  });

  test(
    'limits reject giant input, rows, columns, and fields before import',
    () {
      expect(
        () => TickTickImport.parseBytes(
          List.filled(TickTickImport.maxBytes + 1, 65),
        ),
        throwsA(isA<TickTickImportException>()),
      );
      expect(
        () => TickTickImport.parseBytes(
          utf8.encode('Title,List\n${'A,Inbox\n' * 100001}'),
        ),
        throwsA(isA<TickTickImportException>()),
      );
      expect(
        () => parse(
          ['Title', 'Content'],
          [
            ['A', 'x' * 100001],
          ],
        ),
        throwsA(isA<TickTickImportException>()),
      );
      expect(
        () => parse(
          ['Title', 'x' * 181],
          [
            ['A', 'B'],
          ],
        ),
        throwsA(isA<TickTickImportException>()),
      );
      expect(
        () => parse(
          ['Title', ...List.generate(100, (i) => 'field$i')],
          [
            ['A'],
          ],
        ),
        throwsA(isA<TickTickImportException>()),
      );
    },
  );
}
