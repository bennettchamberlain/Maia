import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:maia_api_client/maia_api_client.dart';
import 'package:maia_app/chat/bloc/chat_bloc.dart';
import 'package:maia_app/ui/fault.dart';
import 'package:maia_models/maia_models.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

DateTime? _lastHaptic;

/// Long-press haptic. Right-click does not call this.
void maiaSelectionHaptic(TargetPlatform platform) {
  if (platform != TargetPlatform.iOS && platform != TargetPlatform.android) {
    return;
  }
  final now = DateTime.now();
  final previous = _lastHaptic;
  if (previous != null && now.difference(previous).inMilliseconds < 400) {
    return;
  }
  _lastHaptic = now;
  HapticFeedback.mediumImpact();
}

/// The text toolbar plus fork and file actions.
Widget maiaTextMenu(
  BuildContext context,
  EditableTextState state, {
  required String fallbackText,
  String? messageId,
}) {
  maiaSelectionHaptic(Theme.of(context).platform);
  final selected = _selected(state, fallbackText);
  return AdaptiveTextSelectionToolbar.buttonItems(
    anchors: state.contextMenuAnchors,
    buttonItems: [
      ...state.contextMenuButtonItems,
      if (messageId != null)
        ContextMenuButtonItem(
          label: 'Fork into new chat',
          onPressed: () {
            ContextMenuController.removeAny();
            final session = context.read<ChatBloc>().state.open;
            if (session == null) return;
            context.read<ChatBloc>().add(
              ChatForkRequested(
                sessionId: session.id,
                messageId: messageId,
                selection: selected,
              ),
            );
          },
        ),
      ContextMenuButtonItem(
        label: 'Add to file',
        onPressed: () {
          ContextMenuController.removeAny();
          final session = context.read<ChatBloc>().state.open;
          unawaited(
            _addToFile(
              context,
              selected,
              sessionId: session?.id,
              messageId: messageId,
            ),
          );
        },
      ),
      ContextMenuButtonItem(
        label: 'New file',
        onPressed: () {
          ContextMenuController.removeAny();
          final session = context.read<ChatBloc>().state.open;
          context.read<ChatBloc>().add(
            ChatFileSaved(
              text: selected,
              sessionId: session?.id,
              messageId: messageId,
            ),
          );
        },
      ),
    ],
  );
}

Future<void> _addToFile(
  BuildContext context,
  String text, {
  String? sessionId,
  String? messageId,
}) {
  final bloc = context.read<ChatBloc>();
  final api = context.read<MaiaApiClient>();
  return showShadDialog<void>(
    context: context,
    builder: (dialogContext) => _AddToFileDialog(
      api: api,
      bloc: bloc,
      text: text,
      sessionId: sessionId,
      messageId: messageId,
    ),
  );
}

String _selected(EditableTextState state, String fallback) {
  try {
    final value = state.textEditingValue;
    final selection = value.selection;
    if (!selection.isValid || selection.isCollapsed) return fallback.trim();
    final text = selection.textInside(value.text).trim();
    return text.isEmpty ? fallback.trim() : text;
  } on Object {
    return fallback.trim();
  }
}

class _AddToFileDialog extends StatefulWidget {
  const _AddToFileDialog({
    required this.api,
    required this.bloc,
    required this.text,
    this.sessionId,
    this.messageId,
  });

  final MaiaApiClient api;
  final ChatBloc bloc;
  final String text;
  final String? sessionId;
  final String? messageId;

  @override
  State<_AddToFileDialog> createState() => _AddToFileDialogState();
}

class _AddToFileDialogState extends State<_AddToFileDialog> {
  List<Document>? _files;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final files = await widget.api.documents();
      if (!mounted) return;
      setState(() => _files = files);
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() => _error = shownFault(e));
      rememberFault(widget.api, 'add to file', e);
    }
  }

  void _choose(Document file) {
    widget.bloc.add(
      ChatFileSaved(
        text: widget.text,
        documentId: file.id,
        sessionId: widget.sessionId,
        messageId: widget.messageId,
      ),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final files = _files;
    return ShadDialog(
      title: const Text('Add to file'),
      actions: [
        ShadButton.outline(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
      child: SizedBox(
        width: 280,
        child: files == null
            ? Text(_error ?? 'Loading files…')
            : files.isEmpty
            ? const Text('No files yet. Choose New file from the menu.')
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final file in files)
                    ShadButton.ghost(
                      onPressed: () => _choose(file),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          file.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}
