import 'package:maia_app/chat/draft.dart';
import 'package:maia_app/chat/store_file.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// The name the user sees for a stored file, with a small preview.
class FileChip extends StatelessWidget {
  const new({
    required this.file,
    this.onRemove,
    this.foreground,
    super.key,
  });

  final StoredChatFile file;
  final VoidCallback? onRemove;
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final color = foreground ?? theme.colorScheme.foreground;
    return Container(
      height: 28,
      constraints: const BoxConstraints(maxWidth: 180),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.muted,
        borderRadius: const BorderRadius.all(Radius.circular(6)),
        border: Border.all(color: theme.colorScheme.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          filePreview(file),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              file.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.small.copyWith(color: color),
            ),
          ),
          if (onRemove != null)
            GestureDetector(
              onTap: onRemove,
              child: Padding(
                padding: const EdgeInsets.only(left: 2),
                child: Icon(LucideIcons.x, size: 12, color: color),
              ),
            ),
        ],
      ),
    );
  }
}

/// Renders a stored message: file tokens become chips, the path stays hidden.
class FileAwareText extends StatelessWidget {
  const new({
    required this.text,
    required this.style,
    this.contextMenuBuilder,
    super.key,
  });

  final String text;
  final TextStyle style;
  final Widget Function(BuildContext, EditableTextState)? contextMenuBuilder;

  @override
  Widget build(BuildContext context) {
    final spans = <InlineSpan>[
      for (final run in messageRuns(text))
        switch (run) {
          MessageText(:final text) => TextSpan(text: text),
          MessageFile(:final file) => WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: FileChip(file: file),
            ),
          ),
        },
    ];
    return SelectableText.rich(
      TextSpan(style: style, children: spans),
      contextMenuBuilder: contextMenuBuilder,
    );
  }
}
