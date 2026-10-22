// The official 11.x Markdown shortcut API is marked experimental upstream.
// ignore_for_file: experimental_member_use

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;

import '../core/app_controller.dart';
import '../core/models.dart';

const _accent = Color(0xFF55ADB1);

/// Delta stays the source of truth. Old plain-text notes are migrated only when
/// the user edits the item, so opening an old task never silently rewrites it.
quill.Document taskDocument(TaskItem task) {
  if (task.richContent.isNotEmpty) {
    try {
      return quill.Document.fromJson(task.richContent);
    } catch (_) {
      // Keep legacy readable text available if a future client writes an
      // unsupported document format.
    }
  }
  return quill.Document.fromJson([
    {'insert': '${task.notes.replaceAll('\r\n', '\n').trimRight()}\n'},
  ]);
}

class DayflowRichEditor extends StatefulWidget {
  const DayflowRichEditor({
    super.key,
    required this.controller,
    required this.appController,
    required this.focusNode,
    required this.scrollController,
    required this.attachments,
    required this.onAddAttachment,
    this.uploading = false,
    this.isNote = false,
  });

  final quill.QuillController controller;
  final AppController appController;
  final FocusNode focusNode;
  final ScrollController scrollController;
  final List<AttachmentItem> attachments;
  final ValueChanged<bool> onAddAttachment;
  final bool uploading;
  final bool isNote;

  @override
  State<DayflowRichEditor> createState() => _DayflowRichEditorState();
}

class _DayflowRichEditorState extends State<DayflowRichEditor> {
  final _editorKey = GlobalKey<quill.EditorState>();
  bool _commandsVisible = false;
  int? _slashOffset;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_detectCommand);
  }

  @override
  void didUpdateWidget(covariant DayflowRichEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_detectCommand);
      widget.controller.addListener(_detectCommand);
      _commandsVisible = false;
    }
  }

  void _detectCommand() {
    final selection = widget.controller.selection;
    final plain = widget.controller.document.toPlainText();
    final cursor = selection.extentOffset.clamp(0, plain.length);
    final before = plain.substring(0, cursor);
    final line = before.substring(before.lastIndexOf('\n') + 1);
    final visible =
        widget.focusNode.hasFocus && selection.isCollapsed && line == '/';
    _slashOffset = visible ? cursor - 1 : null;
    if (visible != _commandsVisible && mounted) {
      setState(() => _commandsVisible = visible);
    }
  }

  void _command(quill.Attribute? format, {bool? attachment}) {
    final at = _slashOffset;
    if (at != null) {
      widget.controller.replaceText(
        at,
        1,
        '',
        TextSelection.collapsed(offset: at),
      );
    }
    setState(() => _commandsVisible = false);
    if (attachment != null) {
      widget.onAddAttachment(attachment);
    } else {
      widget.controller.formatSelection(format);
      widget.focusNode.requestFocus();
    }
  }

  void _setAccessibleText(String text) {
    if (widget.controller.readOnly) return;
    // Quill keeps a mandatory trailing newline. Its caret stays before that
    // sentinel, including when assistive technology replaces the whole value.
    final value = text.endsWith('\n') ? text : '$text\n';
    _editorKey.currentState?.userUpdateTextEditingValue(
      TextEditingValue(
        text: value,
        selection: TextSelection.collapsed(offset: value.length - 1),
      ),
      SelectionChangedCause.keyboard,
    );
  }

  void _setAccessibleSelection(TextSelection selection) {
    final editor = _editorKey.currentState;
    if (editor == null) return;
    final lastOffset = widget.controller.document.length - 1;
    editor.userUpdateTextEditingValue(
      editor.textEditingValue.copyWith(
        selection: selection.copyWith(
          baseOffset: selection.baseOffset.clamp(0, lastOffset),
          extentOffset: selection.extentOffset.clamp(0, lastOffset),
        ),
      ),
      SelectionChangedCause.keyboard,
    );
  }

  Widget _accessibleBody(Widget child) => ListenableBuilder(
    listenable: Listenable.merge([widget.controller, widget.focusNode]),
    builder: (context, child) => _RichEditingSemantics(
      key: const ValueKey('rich-body-semantics'),
      selection: widget.controller.selection,
      properties: SemanticsProperties(
        label: '正文',
        textField: true,
        multiline: true,
        enabled: !widget.controller.readOnly,
        readOnly: widget.controller.readOnly,
        focused: widget.focusNode.hasFocus,
        value: widget.controller.document.toPlainText(),
        textDirection: Directionality.of(context),
        onFocus: () => _editorKey.currentState?.requestKeyboard(),
        onSetText: _setAccessibleText,
        onSetSelection: _setAccessibleSelection,
      ),
      child: child!,
    ),
    child: child,
  );

  quill.SpaceShortcutEvent _markdown(
    String marker,
    quill.Attribute attribute,
  ) => quill.SpaceShortcutEvent(
    character: marker,
    handler: (_, controller) {
      final at = controller.selection.baseOffset - marker.length;
      if (at < 0) return false;
      controller.replaceText(
        at,
        marker.length,
        '',
        TextSelection.collapsed(offset: at),
      );
      controller.formatSelection(attribute);
      return true;
    },
  );

  @override
  void dispose() {
    widget.controller.removeListener(_detectCommand);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _RichToolbar(
        controller: widget.controller,
        focusNode: widget.focusNode,
        onAddAttachment: widget.onAddAttachment,
        uploading: widget.uploading,
      ),
      if (_commandsVisible)
        Container(
          key: const ValueKey('rich-slash-commands'),
          margin: const EdgeInsets.only(top: 10),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFFF4FAFA),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final entry in <String, quill.Attribute>{
                '标题': quill.Attribute.h2,
                '无序列表': quill.Attribute.ul,
                '有序列表': quill.Attribute.ol,
                '勾选列表': quill.Attribute.unchecked,
                '引用': quill.Attribute.blockQuote,
                '代码块': quill.Attribute.codeBlock,
              }.entries)
                ActionChip(
                  label: Text(entry.key),
                  onPressed: () => _command(entry.value),
                ),
              ActionChip(
                label: const Text('图片'),
                onPressed: () => _command(null, attachment: true),
              ),
              ActionChip(
                label: const Text('附件'),
                onPressed: () => _command(null, attachment: false),
              ),
            ],
          ),
        ),
      const SizedBox(height: 12),
      _accessibleBody(
        quill.QuillEditor(
          controller: widget.controller,
          focusNode: widget.focusNode,
          scrollController: widget.scrollController,
          config: quill.QuillEditorConfig(
            editorKey: _editorKey,
            scrollable: false,
            padding: const EdgeInsets.symmetric(vertical: 8),
            minHeight: widget.isNote ? 220 : 140,
            placeholder: widget.isNote ? '写下想法，输入 / 插入内容…' : '添加描述，输入 / 插入内容…',
            characterShortcutEvents: quill.standardCharactersShortcutEvents,
            spaceShortcutEvents: [
              ...quill.standardSpaceShorcutEvents,
              _markdown('>', quill.Attribute.blockQuote),
              _markdown('```', quill.Attribute.codeBlock),
              _markdown('[]', quill.Attribute.unchecked),
            ],
            onTapOutsideEnabled: false,
            embedBuilders: [
              _AttachmentImageBuilder(
                appController: widget.appController,
                attachments: widget.attachments,
              ),
            ],
            unknownEmbedBuilder: _UnknownEmbedBuilder(),
          ),
        ),
      ),
    ],
  );
}

/// Quill 11.x does not publish editable-text semantics. On Web, once semantics
/// is enabled the engine requires a focused text-field node to create/activate
/// the textarea used by Quill's existing TextInputClient. Keep this a leaf so
/// Quill's inner static text/focus nodes cannot intercept accessibility focus.
/// No onTap is added: the engine's textarea must receive its own click.
/// https://github.com/singerdmx/flutter-quill/issues/2531
class _RichEditingSemantics extends SingleChildRenderObjectWidget {
  const _RichEditingSemantics({
    super.key,
    required this.properties,
    required this.selection,
    required super.child,
  });

  final SemanticsProperties properties;
  final TextSelection selection;

  @override
  _RenderRichEditingSemantics createRenderObject(BuildContext context) =>
      _RenderRichEditingSemantics(selection, properties: properties);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderRichEditingSemantics renderObject,
  ) {
    renderObject
      ..properties = properties
      ..textDirection = properties.textDirection
      ..selection = selection;
  }
}

class _RenderRichEditingSemantics extends RenderSemanticsAnnotations {
  _RenderRichEditingSemantics(this._selection, {required super.properties})
    : super(
        textDirection: properties.textDirection,
        container: true,
        excludeSemantics: true,
      );

  TextSelection _selection;

  set selection(TextSelection value) {
    if (_selection == value) return;
    _selection = value;
    markNeedsSemanticsUpdate();
  }

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    if (_selection.isValid) config.textSelection = _selection;
  }
}

class _RichToolbar extends StatelessWidget {
  const _RichToolbar({
    required this.controller,
    required this.focusNode,
    required this.onAddAttachment,
    required this.uploading,
  });
  final quill.QuillController controller;
  final FocusNode focusNode;
  final ValueChanged<bool> onAddAttachment;
  final bool uploading;

  void _toggle(quill.Attribute attribute) {
    final current = controller.getSelectionStyle().attributes[attribute.key];
    controller.formatSelection(
      current?.value == attribute.value
          ? quill.Attribute.clone(attribute, null)
          : attribute,
    );
    focusNode.requestFocus();
  }

  Future<void> _link(BuildContext context) async {
    final selection = controller.selection;
    final existing = controller
        .getSelectionStyle()
        .attributes[quill.Attribute.link.key];
    final url = TextEditingController(text: existing?.value?.toString() ?? '');
    final label = TextEditingController(
      text: selection.isCollapsed ? '' : controller.getPlainText(),
    );
    String? error;
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('插入链接'),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: label,
                  decoration: const InputDecoration(labelText: '显示文字'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: url,
                  autofocus: true,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(
                    labelText: '链接地址',
                    hintText: 'https://',
                    errorText: error,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            if (existing != null)
              TextButton(
                onPressed: () => Navigator.pop(context, ('', '')),
                child: const Text('移除链接'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final parsed = Uri.tryParse(url.text.trim());
                if (parsed == null ||
                    !{'https', 'http', 'mailto'}.contains(parsed.scheme) ||
                    (parsed.scheme != 'mailto' && parsed.host.isEmpty)) {
                  setState(() => error = '请输入 http、https 或 mailto 链接');
                  return;
                }
                Navigator.pop(context, (url.text.trim(), label.text.trim()));
              },
              child: const Text('插入'),
            ),
          ],
        ),
      ),
    );
    url.dispose();
    label.dispose();
    if (result == null || !context.mounted) return;
    controller.updateSelection(selection, quill.ChangeSource.local);
    if (result.$1.isEmpty) {
      controller.formatSelection(
        quill.Attribute.clone(quill.Attribute.link, null),
      );
    } else if (selection.isCollapsed) {
      final text = result.$2.isEmpty ? result.$1 : result.$2;
      controller.replaceText(selection.start, 0, text, null);
      controller.formatText(
        selection.start,
        text.length,
        quill.LinkAttribute(result.$1),
      );
      controller.updateSelection(
        TextSelection.collapsed(offset: selection.start + text.length),
        quill.ChangeSource.local,
      );
    } else {
      final text = result.$2.isEmpty ? controller.getPlainText() : result.$2;
      controller.replaceText(
        selection.start,
        selection.end - selection.start,
        text,
        null,
      );
      controller.formatText(
        selection.start,
        text.length,
        quill.LinkAttribute(result.$1),
      );
      controller.updateSelection(
        TextSelection.collapsed(offset: selection.start + text.length),
        quill.ChangeSource.local,
      );
    }
    focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      Widget format(String label, IconData icon, quill.Attribute attribute) {
        final active =
            controller.getSelectionStyle().attributes[attribute.key]?.value ==
            attribute.value;
        return _Tool(
          label: label,
          icon: icon,
          selected: active,
          onPressed: () => _toggle(attribute),
        );
      }

      return DecoratedBox(
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: Color(0xFFEDF0F5))),
        ),
        child: Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Wrap(
            spacing: 1,
            runSpacing: 2,
            children: [
              format('粗体', Icons.format_bold, quill.Attribute.bold),
              format('斜体', Icons.format_italic, quill.Attribute.italic),
              format(
                '删除线',
                Icons.strikethrough_s,
                quill.Attribute.strikeThrough,
              ),
              format('标题', Icons.title, quill.Attribute.h2),
              format('无序列表', Icons.format_list_bulleted, quill.Attribute.ul),
              format('有序列表', Icons.format_list_numbered, quill.Attribute.ol),
              format('勾选列表', Icons.checklist, quill.Attribute.unchecked),
              format(
                '引用',
                Icons.format_quote_outlined,
                quill.Attribute.blockQuote,
              ),
              format('代码块', Icons.code, quill.Attribute.codeBlock),
              _Tool(
                label: '链接',
                icon: Icons.link,
                onPressed: () => _link(context),
              ),
              _Tool(
                label: '插入图片',
                icon: Icons.image_outlined,
                onPressed: uploading ? null : () => onAddAttachment(true),
              ),
              _Tool(
                label: '添加附件',
                icon: Icons.attach_file,
                onPressed: uploading ? null : () => onAddAttachment(false),
              ),
              _Tool(
                label: '撤销',
                icon: Icons.undo,
                onPressed: controller.hasUndo ? controller.undo : null,
              ),
              _Tool(
                label: '重做',
                icon: Icons.redo,
                onPressed: controller.hasRedo ? controller.redo : null,
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _Tool extends StatelessWidget {
  const _Tool({
    required this.label,
    required this.icon,
    this.onPressed,
    this.selected = false,
  });
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: label,
    onPressed: onPressed,
    constraints: const BoxConstraints.tightFor(width: 32, height: 34),
    padding: EdgeInsets.zero,
    style: IconButton.styleFrom(
      backgroundColor: selected ? _accent.withValues(alpha: .09) : null,
      foregroundColor: selected ? _accent : const Color(0xFF737C8B),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
    ),
    icon: Icon(icon, size: 18),
  );
}

class _AttachmentImageBuilder extends quill.EmbedBuilder {
  _AttachmentImageBuilder({
    required this.appController,
    required this.attachments,
  });
  final AppController appController;
  final List<AttachmentItem> attachments;

  @override
  String get key => 'image';

  @override
  String toPlainText(quill.Embed node) => '[图片]';

  @override
  Widget build(BuildContext context, quill.EmbedContext embedContext) {
    final reference = embedContext.node.value.data.toString();
    final id = reference.startsWith('attachment:')
        ? reference.substring('attachment:'.length)
        : null;
    final attachment = attachments.where((item) => item.id == id).firstOrNull;
    if (attachment == null) {
      return const _ImageStatus(
        icon: Icons.broken_image_outlined,
        text: '图片附件不可用',
      );
    }
    return _PrivateImage(
      key: ValueKey('${appController.serverUrl}:${attachment.id}'),
      controller: appController,
      attachment: attachment,
    );
  }
}

class _PrivateImage extends StatefulWidget {
  const _PrivateImage({
    super.key,
    required this.controller,
    required this.attachment,
  });
  final AppController controller;
  final AttachmentItem attachment;
  @override
  State<_PrivateImage> createState() => _PrivateImageState();
}

class _PrivateImageState extends State<_PrivateImage> {
  late Future<Uint8List> _bytes;
  @override
  void initState() {
    super.initState();
    _bytes = widget.controller.downloadAttachment(widget.attachment);
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: FutureBuilder<Uint8List>(
      future: _bytes,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return InkWell(
            onTap: () => setState(() {
              _bytes = widget.controller.downloadAttachment(widget.attachment);
            }),
            child: const _ImageStatus(icon: Icons.refresh, text: '图片加载失败，点击重试'),
          );
        }
        if (!snapshot.hasData) {
          return const _ImageStatus(
            icon: Icons.image_outlined,
            text: '正在加载图片…',
          );
        }
        return ClipRRect(
          borderRadius: BorderRadius.circular(7),
          child: Image.memory(
            snapshot.data!,
            fit: BoxFit.contain,
            semanticLabel: widget.attachment.name,
            errorBuilder: (_, _, _) => const _ImageStatus(
              icon: Icons.broken_image_outlined,
              text: '无法预览该图片，可从附件下载',
            ),
          ),
        );
      },
    ),
  );
}

class _ImageStatus extends StatelessWidget {
  const _ImageStatus({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minHeight: 96),
    color: const Color(0xFFF7F8FA),
    alignment: Alignment.center,
    padding: const EdgeInsets.all(16),
    child: Wrap(
      spacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Icon(icon, size: 20, color: const Color(0xFF8991A4)),
        Text(
          text,
          style: const TextStyle(color: Color(0xFF8991A4), fontSize: 12),
        ),
      ],
    ),
  );
}

class _UnknownEmbedBuilder extends quill.EmbedBuilder {
  @override
  String get key => 'unknown';
  @override
  Widget build(BuildContext context, quill.EmbedContext embedContext) =>
      const _ImageStatus(
        icon: Icons.insert_drive_file_outlined,
        text: '此内容暂不支持预览',
      );
}
