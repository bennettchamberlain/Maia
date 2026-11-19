import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_ui/material_ui.dart';
import 'package:maie_app/chat/bloc/chat_bloc.dart';
import 'package:maie_app/chat/memory_match.dart';
import 'package:maie_app/chat/parts/chat_part.dart';
import 'package:maie_app/graph/ontology_view.dart';
import 'package:maie_app/chat/parts/you_search.dart';
import 'package:maie_app/chat/voice_cubit.dart';
import 'package:maie_app/ui/chrome.dart';
import 'package:maie_app/ui/company_logo.dart';
import 'package:maie_app/ui/fault.dart';
import 'package:maie_models/maie_models.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:url_launcher/url_launcher.dart';

/// Renders the parsed surface for one assistant message.
class ChatMessageBody extends StatelessWidget {
  const new({
    super.key,
    required this.text,
    required this.foreground,
    this.tools = const [],
    this.streaming = false,
    this.ask = '',
  });

  final String text;
  final Color foreground;
  final List<ChatToolCall> tools;
  final bool streaming;

  /// The user message this reply is answering. Memory cards that do not
  /// contain that ask are not shown.
  final String ask;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final segments = _shown(parseChatSegments(text, tools: tools), ask);
    if (segments.isEmpty && streaming) {
      return const SizedBox(width: 72, child: ShadProgress(minHeight: 6));
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 0.0;
        return SizedBox(
          width: width,
          child: DefaultTextStyle(
            style: theme.textTheme.p.copyWith(color: foreground),
            softWrap: true,
            overflow: TextOverflow.clip,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final segment in segments) ...[
                  switch (segment) {
                    ChatProse(:final text) => Text(
                      _plain(text),
                      style: theme.textTheme.p.copyWith(color: foreground),
                    ),
                    ChatBlock(:final part) => ChatPartView(part),
                    ChatBlockPending() => const SizedBox(
                      height: 96,
                      child: MaieSkeleton(rows: 2),
                    ),
                  },
                  const SizedBox(height: 8),
                ],
                if (streaming && text.isNotEmpty)
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: SizedBox(
                      width: 72,
                      child: ShadProgress(minHeight: 6),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

List<ChatSegment> _shown(List<ChatSegment> segments, String ask) {
  final shown = <ChatSegment>[];
  for (final segment in segments) {
    switch (segment) {
      case ChatProse(:final text):
        final clean = replyWithoutToolLecture(text);
        if (clean.trim().isNotEmpty) shown.add(ChatProse(clean));
      case ChatBlock(:final part):
        final trimmed = withoutUnrelatedMemory(part, ask);
        if (trimmed != null) shown.add(ChatBlock(trimmed));
      case ChatBlockPending():
        shown.add(segment);
    }
  }
  return shown;
}

class ChatPartView extends StatelessWidget {
  const new(this.part, {super.key, this.searchClient});

  final ChatPart part;
  final YouSearchClient? searchClient;

  @override
  Widget build(BuildContext context) {
    return switch (part) {
      ChatText(:final text) => Text(text, softWrap: true),
      ChatHeading(:final text) => Text(
        text,
        softWrap: true,
        style: ShadTheme.of(context).textTheme.h4,
      ),
      ChatDivider() => const MaieDivider.horizontal(),
      ChatColumn(:final children) => _ColumnView(children),
      ChatRow(:final children) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final child in children)
              SizedBox(width: 240, child: ChatPartView(child)),
          ],
        ),
      ),
      ChatList(:final children) => Column(
        children: [
          for (final child in children) ...[
            ChatPartView(child),
            const MaieDivider.horizontal(),
          ],
        ],
      ),
      final ChatCard card => _CardView(card),
      final ChatLink link => _SourceChip(link),
      final ChatImage image => _ImageView(image),
      ChatWebSearch(:final query) => _YouSearchView(
        query: query,
        client: searchClient,
      ),
      ChatSpeech(:final text) => _SpeechView(text),
      final ChatMemory memory => _MemoryView(memory),
      final ChatPlace place => _PlaceView(place),
      final ChatPerson person => _PersonView(person),
      final ChatQuote quote => _QuoteView(quote),
      final ChatMetric metric => _MetricView(metric),
      ChatBadge(:final text) => ShadBadge.outline(child: Text(text)),
      final ChatTimeline timeline => _TimelineView(timeline),
      final ChatCheck check => _CheckView(check),
      final ChatChecklist list => _ChecklistView(list),
      final ChatGraph graph => _GraphView(graph),
      final ChatMap map => _MapView(map.markers),
      ChatActions(:final items) => _ActionsView(items),
    };
  }
}

class _SpeechView extends StatelessWidget {
  const _SpeechView(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    VoiceCubit? voice;
    try {
      voice = context.watch<VoiceCubit>();
    } on Object {
      voice = null;
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.all(Radius.circular(8)),
        border: Border.all(color: theme.colorScheme.border),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
        child: Row(
          children: [
            Icon(
              LucideIcons.volume2,
              size: 14,
              color: theme.colorScheme.mutedForeground,
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: theme.textTheme.muted)),
            ShadIconButton.ghost(
              icon: const Icon(LucideIcons.play, size: 14),
              onPressed:
                  text.trim().isEmpty || voice == null || !voice.state.enabled
                  ? null
                  : () => voice!.speak(text),
            ),
          ],
        ),
      ),
    );
  }
}

class _MemoryView extends StatelessWidget {
  const _MemoryView(this.memory);

  final ChatMemory memory;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final title = memory.title.isEmpty ? memory.kind : memory.title;
    final meta = [
      if (memory.kind.isNotEmpty && memory.title.isNotEmpty) memory.kind,
      if (memory.when.isNotEmpty) memory.when,
    ].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text.rich(
          TextSpan(
            children: [
              TextSpan(text: title),
              if (meta.isNotEmpty)
                TextSpan(text: '  $meta', style: theme.textTheme.muted),
            ],
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        if (memory.body.isNotEmpty)
          Text(
            memory.body,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.muted,
          ),
        if (memory.place != null) _PlaceView(memory.place!),
      ],
    );
  }
}

class _MapView extends StatelessWidget {
  const _MapView(this.markers);

  final List<ChatMapMarker> markers;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    if (markers.isEmpty) {
      return Text('no locations', style: theme.textTheme.muted);
    }
    final points = [
      for (final marker in markers) LatLng(marker.lat, marker.lng),
    ];
    return SelectionContainer.disabled(
      child: SizedBox(
        height: 220,
        child: ClipRRect(
          borderRadius: const BorderRadius.all(Radius.circular(12)),
          child: Stack(
            children: [
              FlutterMap(
                options: MapOptions(
                  initialCenter: points.first,
                  initialZoom: 13,
                  initialCameraFit: points.length < 2
                      ? null
                      : CameraFit.bounds(
                          bounds: LatLngBounds.fromPoints(points),
                          padding: const EdgeInsets.all(36),
                          maxZoom: 14,
                        ),
                ),
                children: [
                  TileLayer(
                    urlTemplate:
                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'com.maie.app',
                  ),
                  MarkerLayer(
                    markers: [
                      for (final marker in markers)
                        Marker(
                          point: LatLng(marker.lat, marker.lng),
                          width: 140,
                          height: 48,
                          alignment: Alignment.topCenter,
                          child: _MapPin(marker.title),
                        ),
                    ],
                  ),
                ],
              ),
              Positioned(
                right: 6,
                bottom: 4,
                child: Text(
                  '© OpenStreetMap',
                  style: theme.textTheme.small.copyWith(
                    color: theme.colorScheme.foreground,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MapPin extends StatelessWidget {
  const _MapPin(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        if (title.isNotEmpty)
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.small,
          ),
        Icon(LucideIcons.mapPin, size: 18, color: theme.colorScheme.primary),
      ],
    );
  }
}

class _PlaceView extends StatelessWidget {
  const _PlaceView(this.place);

  final ChatPlace place;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Row(
      children: [
        Icon(
          LucideIcons.mapPin,
          size: 14,
          color: theme.colorScheme.mutedForeground,
        ),
        const SizedBox(width: 8),
        Expanded(child: Text(place.line, style: theme.textTheme.muted)),
      ],
    );
  }
}

class _PersonView extends StatelessWidget {
  const _PersonView(this.person);

  final ChatPerson person;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final initial = (person.name.isEmpty ? '?' : person.name[0]).toUpperCase();
    return Row(
      children: [
        ShadAvatar(
          null,
          size: const Size.square(28),
          placeholder: Text(initial, style: theme.textTheme.small),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                person.name.isEmpty ? person.handle : person.name,
                style: theme.textTheme.p,
              ),
              if (person.handle.isNotEmpty || person.relation.isNotEmpty)
                Text(
                  [
                    if (person.handle.isNotEmpty) person.handle,
                    if (person.relation.isNotEmpty) person.relation,
                  ].join(' · '),
                  style: theme.textTheme.muted,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _QuoteView extends StatelessWidget {
  const _QuoteView(this.quote);

  final ChatQuote quote;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: theme.colorScheme.border, width: 3),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.only(left: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(quote.text, softWrap: true, style: theme.textTheme.p),
            if (quote.attribution.isNotEmpty)
              Text(
                quote.attribution,
                softWrap: true,
                style: theme.textTheme.muted,
              ),
          ],
        ),
      ),
    );
  }
}

class _MetricView extends StatelessWidget {
  const _MetricView(this.metric);

  final ChatMetric metric;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: metric.value),
          if (metric.label.isNotEmpty)
            TextSpan(text: '  ${metric.label}', style: theme.textTheme.muted),
          if (metric.detail.isNotEmpty)
            TextSpan(text: '  ${metric.detail}', style: theme.textTheme.muted),
        ],
      ),
    );
  }
}

class _TimelineView extends StatelessWidget {
  const _TimelineView(this.timeline);

  final ChatTimeline timeline;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (timeline.title.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(timeline.title, style: theme.textTheme.muted),
          ),
        for (final child in timeline.children)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: ChatPartView(child),
          ),
      ],
    );
  }
}

class _CheckView extends StatelessWidget {
  const _CheckView(this.check);

  final ChatCheck check;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Row(
      children: [
        Icon(
          check.done ? LucideIcons.circleCheck : LucideIcons.circle,
          size: 14,
          color: theme.colorScheme.mutedForeground,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            check.text,
            style: theme.textTheme.p.copyWith(
              decoration: check.done ? TextDecoration.lineThrough : null,
            ),
          ),
        ),
      ],
    );
  }
}

class _ChecklistView extends StatelessWidget {
  const _ChecklistView(this.list);

  final ChatChecklist list;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (list.title.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(list.title, style: theme.textTheme.h4),
          ),
        for (final item in list.items) _CheckView(item),
      ],
    );
  }
}

class _GraphView extends StatelessWidget {
  const _GraphView(this.graph);

  final ChatGraph graph;

  @override
  Widget build(BuildContext context) {
    return OntologyCanvas(graph: graph);
  }
}

class _ActionsView extends StatelessWidget {
  const _ActionsView(this.items);

  final List<ChatAction> items;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final item in items)
          ShadButton.outline(
            onPressed: () => _run(context, item),
            child: Text(item.label),
          ),
      ],
    );
  }

  void _run(BuildContext context, ChatAction item) {
    if (item.url.isNotEmpty) {
      unawaited(_open(item.url));
      return;
    }
    final prompt = item.prompt.trim();
    if (prompt.isEmpty) return;
    try {
      context.read<ChatBloc>().add(ChatMessageSent(prompt));
    } on Object {
      // Rendered outside a chat session.
    }
  }
}

class _CardView extends StatelessWidget {
  const new(this.card);

  final ChatCard card;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return _Disclosure(
      detail: card.detail,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.background,
          borderRadius: const BorderRadius.all(Radius.circular(8)),
          border: Border.all(color: theme.colorScheme.border),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (card.title.isNotEmpty)
                Text(card.title, softWrap: true, style: theme.textTheme.p),
              if (card.subtitle.isNotEmpty)
                Text(
                  card.subtitle,
                  softWrap: true,
                  style: theme.textTheme.muted,
                ),
              for (final child in card.children) ChatPartView(child),
            ],
          ),
        ),
      ),
    );
  }
}

class _ColumnView extends StatelessWidget {
  const _ColumnView(this.children);

  final List<ChatPart> children;

  @override
  Widget build(BuildContext context) {
    final links = <ChatLink>[
      for (final child in children)
        if (child is ChatLink) child,
    ];
    final other = [
      for (final child in children)
        if (child is! ChatLink && child is! ChatHeading) child,
    ];
    if (links.isNotEmpty && other.isEmpty) return _SourcesView(links);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final child in children) ...[
          ChatPartView(child),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}

class _SourcesView extends StatelessWidget {
  const _SourcesView(this.links);

  final List<ChatLink> links;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Sources', style: ShadTheme.of(context).textTheme.muted),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [for (final link in links) _SourceChip(link)],
        ),
      ],
    );
  }
}

class _SourceChip extends StatelessWidget {
  const _SourceChip(this.link);

  final ChatLink link;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final host = _sourceHost(link.url);
    final label = host.isNotEmpty
        ? host
        : (link.title.isEmpty ? link.url : link.title);
    final tip = [
      if (link.title.isNotEmpty && link.title != label) link.title,
      if (link.snippet.isNotEmpty) link.snippet,
    ].join('\n');
    final chip = GestureDetector(
      onTap: () => _open(link.url),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 220),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: const BorderRadius.all(Radius.circular(6)),
            border: Border.all(color: theme.colorScheme.border),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(6, 4, 8, 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CompanyLogo(image: link.image, link: link.url, size: 16),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.small,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (tip.isEmpty) return chip;
    return Tooltip(message: tip, child: chip);
  }
}

String _sourceHost(String url) {
  final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
  if (host.startsWith('www.')) return host.substring(4);
  return host;
}

class _ImageView extends StatelessWidget {
  const new(this.image);

  final ChatImage image;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.all(Radius.circular(8)),
      child: Image.network(
        image.url,
        height: 160,
        width: double.infinity,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => Text(
          image.alt.isEmpty ? image.url : image.alt,
          style: ShadTheme.of(context).textTheme.muted,
        ),
      ),
    );
  }
}

class _Disclosure extends StatefulWidget {
  const new({required this.child, this.detail});

  final Widget child;
  final ChatPart? detail;

  @override
  State<_Disclosure> createState() => _DisclosureState();
}

class _DisclosureState extends State<_Disclosure> {
  var _open = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        widget.child,
        if (widget.detail != null)
          ShadButton.ghost(
            onPressed: () => setState(() => _open = !_open),
            child: Text(_open ? 'Less' : 'More'),
          ),
        if (_open && widget.detail != null)
          Padding(
            padding: const EdgeInsets.only(left: 12, bottom: 8),
            child: ChatPartView(widget.detail!),
          ),
      ],
    );
  }
}

class _YouSearchView extends StatefulWidget {
  const new({required this.query, this.client});

  final String query;
  final YouSearchClient? client;

  @override
  State<_YouSearchView> createState() => _YouSearchViewState();
}

class _YouSearchViewState extends State<_YouSearchView> {
  late final YouSearchClient _client;
  late final bool _ownsClient;
  List<YouHit>? _hits;
  String? _error;

  @override
  void initState() {
    super.initState();
    _ownsClient = widget.client == null;
    _client = widget.client ?? YouSearchClient();
    unawaited(_load());
  }

  @override
  void dispose() {
    if (_ownsClient) _client.close();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final hits = await _client.search(widget.query);
      if (!mounted) return;
      setState(() => _hits = hits);
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() => _error = shownFault(error));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final hits = _hits;
    if (_error != null) {
      return Text(_error!, style: theme.textTheme.muted);
    }
    if (hits == null) {
      return const SizedBox(height: 120, child: MaieSkeleton(rows: 2));
    }
    if (hits.isEmpty) {
      return Text('No results.', style: theme.textTheme.muted);
    }
    return ChatPartView(
      ChatColumn([
        for (final hit in hits)
          ChatLink(title: hit.title, url: hit.url, snippet: hit.description),
      ]),
    );
  }
}

String _plain(String text) => text
    .replaceAllMapped(RegExp(r'\*\*(.+?)\*\*'), (m) => m[1] ?? '')
    .replaceAllMapped(RegExp(r'`([^`]+)`'), (m) => m[1] ?? '')
    .replaceAll(RegExp(r'^#+\s*', multiLine: true), '');

Future<void> _open(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme) return;
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}
