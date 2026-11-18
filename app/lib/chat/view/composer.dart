import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:maia_app/chat/draft.dart';
import 'package:maia_app/chat/store_file.dart';
import 'package:maia_app/chat/view/file_chip.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// The chat field. File chips sit in the text and can be dragged to a new
/// spot in the sentence.
class ChatComposer extends StatefulWidget {
  const new({
    required this.placeholder,
    required this.enabled,
    required this.onSubmit,
    super.key,
  });

  final String placeholder;
  final bool enabled;
  final VoidCallback onSubmit;

  @override
  State<ChatComposer> createState() => ChatComposerState();
}

class ChatComposerState extends State<ChatComposer> {
  final _draft = ChatDraft();
  final _controllers = <int, TextEditingController>{};
  final _focus = <int, FocusNode>{};

  /// The message the model should see, or null when the field is empty.
  /// Clears the field.
  String? take() {
    _pull();
    if (!_draft.hasContent) return null;
    final wire = _draft.wire();
    _draft.reset();
    _bind();
    setState(() {});
    return wire;
  }

  Future<void> addPicked(XFile file) async {
    final stored = await storePickedFile(file);
    if (!mounted) return;
    _pull();
    final id = _focusedId();
    final offset = id == null
        ? _draft.texts.last.text.length
        : _controllers[id]?.selection.extentOffset ?? 0;
    final right = _draft.insertFile(stored, textId: id, offset: offset);
    _bind();
    setState(() {});
    _focus[right.id]?.requestFocus();
  }

  @override
  void initState() {
    super.initState();
    _bind();
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    for (final node in _focus.values) {
      node.dispose();
    }
    super.dispose();
  }

  void _pull() {
    for (final text in _draft.texts) {
      text.text = _controllers[text.id]?.text ?? text.text;
    }
  }

  int? _focusedId() {
    for (final entry in _focus.entries) {
      if (entry.value.hasFocus) return entry.key;
    }
    return null;
  }

  void _bind() {
    final live = <int>{};
    for (final text in _draft.texts) {
      live.add(text.id);
      final controller = _controllers.putIfAbsent(
        text.id,
        () => TextEditingController(text: text.text),
      );
      if (controller.text != text.text) {
        controller.value = TextEditingValue(
          text: text.text,
          selection: TextSelection.collapsed(offset: text.text.length),
        );
      }
      _focus.putIfAbsent(text.id, FocusNode.new);
    }
    for (final id in _controllers.keys.toList()) {
      if (live.contains(id)) continue;
      _controllers.remove(id)!.dispose();
      _focus.remove(id)!.dispose();
    }
  }

  void _move(DraftFile file, DraftText text, double dx, double width) {
    _pull();
    final style = ShadTheme.of(context).textTheme.p;
    final offset = _offsetFor(text.text, style, dx, width);
    _draft.moveFile(file, textId: text.id, offset: offset);
    _bind();
    setState(() {});
  }

  int _offsetFor(String text, TextStyle style, double dx, double width) {
    if (text.isEmpty) return 0;
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: width);
    return painter.getPositionForOffset(Offset(dx, 8)).offset;
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final only = _draft.pieces.length == 1;
    return Container(
      key: const Key('chat_composer'),
      constraints: const BoxConstraints(minHeight: 40),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.all(Radius.circular(8)),
        border: Border.all(color: theme.colorScheme.border),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final piece in _draft.pieces)
                switch (piece) {
                  DraftText() => _textField(
                    piece,
                    theme,
                    constraints.maxWidth,
                    only,
                  ),
                  DraftFile() => _chip(piece),
                },
            ],
          );
        },
      ),
    );
  }

  Widget _textField(
    DraftText text,
    ShadThemeData theme,
    double maxWidth,
    bool only,
  ) {
    final controller = _controllers[text.id]!;
    final node = _focus[text.id]!;
    final showHint = only && controller.text.isEmpty;
    final field = TextField(
      controller: controller,
      focusNode: node,
      enabled: widget.enabled,
      minLines: 1,
      maxLines: 5,
      style: theme.textTheme.p,
      textInputAction: TextInputAction.send,
      onChanged: (_) => setState(() {}),
      onSubmitted: (_) => widget.onSubmit(),
      decoration: InputDecoration(
        isCollapsed: true,
        border: InputBorder.none,
        hintText: showHint ? widget.placeholder : null,
        hintStyle: theme.textTheme.muted,
      ),
    );
    final index = _draft.pieces.indexOf(text);
    final previousIsFile = index > 0 && _draft.pieces[index - 1] is DraftFile;
    final child = controller.text.isEmpty && previousIsFile
        ? Shortcuts(
            shortcuts: const {
              SingleActivator(LogicalKeyboardKey.backspace): _RemoveFile(),
            },
            child: Actions(
              actions: {
                _RemoveFile: CallbackAction<_RemoveFile>(
                  onInvoke: (_) {
                    _pull();
                    _draft.removeFile(_draft.pieces[index - 1] as DraftFile);
                    _bind();
                    setState(() {});
                    return null;
                  },
                ),
              },
              child: field,
            ),
          )
        : field;
    return SizedBox(
      width: only ? maxWidth : _fieldWidth(controller.text, theme, maxWidth),
      child: Builder(
        builder: (fieldContext) {
          return DragTarget<DraftFile>(
            onAcceptWithDetails: (details) {
              final box = fieldContext.findRenderObject() as RenderBox?;
              final width = box?.size.width ?? maxWidth;
              final dx = box == null
                  ? width
                  : box.globalToLocal(details.offset).dx;
              _move(details.data, text, dx, width);
            },
            builder: (_, _, _) => child,
          );
        },
      ),
    );
  }

  double _fieldWidth(String text, ShadThemeData theme, double maxWidth) {
    final painter = TextPainter(
      text: TextSpan(text: text.isEmpty ? ' ' : text, style: theme.textTheme.p),
      textDirection: TextDirection.ltr,
    )..layout();
    final width = painter.width + 12;
    if (width > maxWidth) return maxWidth;
    return width < 24 ? 24 : width;
  }

  Widget _chip(DraftFile piece) {
    final chip = FileChip(
      file: piece.file,
      onRemove: () {
        _pull();
        _draft.removeFile(piece);
        _bind();
        setState(() {});
      },
    );
    return LongPressDraggable<DraftFile>(
      data: piece,
      feedback: Material(color: const Color(0x00000000), child: chip),
      childWhenDragging: Opacity(opacity: 0.35, child: chip),
      child: chip,
    );
  }
}

class _RemoveFile extends Intent {
  const new();
}
