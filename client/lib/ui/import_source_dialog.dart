import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/attachments.dart';

Future<void> showImportSourceDialog(
  BuildContext context,
  Map<String, String> fields,
) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    title: const Text('滴答清单导入原文'),
    content: SizedBox(
      width: 600,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '原始字段随任务保存和同步。这里保留导入时的内容，后续编辑不会覆盖原文。',
              style: TextStyle(fontSize: 12, color: Color(0xFF738285)),
            ),
            const SizedBox(height: 16),
            for (final field in fields.entries.where((e) => e.value.isNotEmpty))
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      field.key,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 4),
                    SelectableText(
                      field.value,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () async {
          try {
            await SystemAttachmentPicker().save(
              'dayflow-import-source.json',
              Uint8List.fromList(
                utf8.encode(const JsonEncoder.withIndent('  ').convert(fields)),
              ),
            );
          } catch (error) {
            if (context.mounted) {
              ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(content: Text('保存失败：$error')));
            }
          }
        },
        child: const Text('保存原文'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  ),
);
