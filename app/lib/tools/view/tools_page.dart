import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:maie_api_client/maie_api_client.dart';
import 'package:maie_app/one/callback_forwarder.dart';
import 'package:maie_app/ui/chrome.dart';
import 'package:maie_app/ui/company_logo.dart';
import 'package:maie_app/ui/fault.dart';
import 'package:maie_models/maie_models.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:url_launcher/url_launcher.dart';

/// One Connect catalog. Each row starts OAuth for that connector.
class ToolsPage extends StatefulWidget {
  const ToolsPage({super.key});

  @override
  State<ToolsPage> createState() => _ToolsPageState();
}

class _ToolsPageState extends State<ToolsPage> with WidgetsBindingObserver {
  ChatCatalog? _catalog;
  List<_Connector> _apps = const [];
  String? _error;
  var _loading = true;
  var _busy = false;
  var _query = '';
  var _category = 'all';

  MaieApiClient get _api => context.read<MaieApiClient>();

  ChatConnection? get _one => _catalog?.connections
      .cast<ChatConnection?>()
      .firstWhere((c) => c?.id == 'one', orElse: () => null);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final catalog = await _api.chatTools();
      OneConnectorPage? directory;
      try {
        directory = await _api.oneConnectors();
      } on Exception catch (e) {
        rememberFault(_api, 'one connectors', e);
        directory = null;
      }
      if (!mounted) return;
      setState(() {
        _catalog = catalog;
        if (directory != null && directory.connectors.isNotEmpty) {
          _apps = [
            for (final row in directory.connectors)
              _Connector(
                row.slug,
                row.title,
                row.category,
                row.description,
                image: row.image,
              ),
          ];
        }
        _loading = false;
      });
    } on Exception catch (e) {
      if (!mounted) return;
      rememberFault(_api, 'tools', e);
      setState(() {
        _error = shownFault(e);
        _loading = false;
      });
    }
  }

  String? _absolute(String? path) {
    if (path == null || path.isEmpty) return null;
    if (path.startsWith('http')) return path;
    final parsed = Uri.parse(path);
    final resolved = _api.baseUrl.resolve(
      parsed.path.startsWith('/') ? parsed.path.substring(1) : parsed.path,
    );
    return resolved
        .replace(
          queryParameters: {
            ...resolved.queryParameters,
            ...parsed.queryParameters,
          },
          fragment: parsed.hasFragment ? parsed.fragment : null,
        )
        .toString();
  }

  Future<void> _openOauth(String? url) async {
    if (url == null) return;
    final opened = await OneCallbackForwarder.instance.browserUrl(
      _api.baseUrl,
      Uri.parse(url),
    );
    await launchUrl(opened, mode: LaunchMode.externalApplication);
  }

  Future<void> _connect(String platform) async {
    setState(() => _busy = true);
    try {
      final result = await _api.oneAccount(platform, syncing: true);
      if (!mounted) return;
      if (result.isOauth) {
        await _openOauth(_absolute(result.authorizeUrl));
        setState(() => _busy = false);
        return;
      }
      if (result.isUnconfigured) {
        setState(() => _busy = false);
        ShadToaster.of(context).show(
          ShadToast.destructive(
            title: const Text('One'),
            description: Text(
              result.message ??
                  'The Linux box needs ONE_CLIENT_ID and ONE_CONNECT_KEY.',
            ),
          ),
        );
        return;
      }
      await _load();
      if (!mounted) return;
      setState(() => _busy = false);
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      rememberFault(_api, 'tools', e);
      ShadToaster.of(context).show(
        ShadToast.destructive(
          title: const Text('Connect'),
          description: Text(shownFault(e)),
        ),
      );
    }
  }

  Future<void> _disconnect(String platform) async {
    setState(() => _busy = true);
    try {
      await _api.oneAccount(platform, syncing: false);
      await _load();
    } on Exception catch (e) {
      if (!mounted) return;
      rememberFault(_api, 'tools', e);
      ShadToaster.of(context).show(
        ShadToast.destructive(
          title: const Text('Disconnect'),
          description: Text(shownFault(e)),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sync(String platform) async {
    setState(() => _busy = true);
    try {
      await _api.oneSync(platforms: [platform]);
      if (!mounted) return;
      ShadToaster.of(context).show(
        ShadToast(
          title: const Text('Sync queued'),
          description: Text(platform),
        ),
      );
    } on Exception catch (e) {
      if (!mounted) return;
      rememberFault(_api, 'tools', e);
      ShadToaster.of(context).show(
        ShadToast.destructive(
          title: const Text('Sync'),
          description: Text(shownFault(e)),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  OneAccount? _accountFor(_Connector item) {
    final accounts = _one?.accounts ?? const <OneAccount>[];
    for (final account in accounts) {
      if (account.platform == item.slug) return account;
    }
    return null;
  }

  bool _connected(_Connector item) {
    if (_accountFor(item) != null) return true;
    return _one?.platforms.contains(item.slug) ?? false;
  }

  _Connector _connectorFor(OneAccount account) {
    for (final item in _apps) {
      if (item.slug == account.platform) return item;
    }
    return _Connector(
      account.platform,
      account.label,
      'Other',
      'Granted through One.',
    );
  }

  List<(String, String)> get _categoryChips {
    final names = _apps.map((item) => item.category).toSet().toList()..sort();
    return [('all', 'All'), for (final name in names) (name, name)];
  }

  List<_Connector> get _visible {
    final q = _query.trim().toLowerCase();
    final matched = [
      for (final item in _apps)
        if ((_category == 'all' || item.category == _category) &&
            (q.isEmpty ||
                item.title.toLowerCase().contains(q) ||
                item.slug.contains(q) ||
                item.description.toLowerCase().contains(q)))
          item,
    ];
    final cap = q.isEmpty && _category == 'all' ? 24 : 80;
    if (matched.length <= cap) return matched;
    return matched.sublist(0, cap);
  }

  int get _connectedCount => _one?.accounts.length ?? 0;

  String get _connectedLabel {
    final n = _connectedCount;
    if (n == 1) return '1 account connected';
    return '$n accounts connected';
  }

  void _openDetail(_Connector item) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _ConnectorDetail(
          item: item,
          account: _accountFor(item),
          connected: _connected(item),
          busy: _busy,
          onConnect: () => _connect(item.slug),
          onDisconnect: () => _disconnect(item.slug),
          onSync: () => _sync(item.slug),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Scaffold(
      body: MaiePane(
        header: MaieHeader(
          title: 'Connectors',
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                _connectedLabel,
                style: theme.textTheme.small,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            MaieBusyIcon(
              key: const Key('tools_refresh_button'),
              busy: _busy,
              icon: const Icon(LucideIcons.refreshCw, size: 16),
              onPressed: _load,
            ),
          ],
        ),
        body: _loading && _catalog == null
            ? const MaieSkeleton()
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                children: [
                  if (_error != null) ...[
                    ShadAlert.destructive(
                      title: const Text('Could not load connectors'),
                      description: Text(_error!),
                    ),
                    const SizedBox(height: 12),
                  ],
                  ShadInput(
                    placeholder: const Text('Search apps'),
                    leading: const Icon(LucideIcons.search, size: 16),
                    onChanged: (v) => setState(() => _query = v),
                  ),
                  const SizedBox(height: 12),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final chip in _categoryChips) ...[
                          _CategoryChip(
                            label: chip.$2,
                            selected: _category == chip.$1,
                            onPressed: () =>
                                setState(() => _category = chip.$1),
                          ),
                          const SizedBox(width: 8),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(_connectedLabel, style: theme.textTheme.h4),
                  const SizedBox(height: 4),
                  Text(
                    'One keeps the login. Maie stores the grant and '
                    'pulls each account into memory.',
                    style: theme.textTheme.muted,
                  ),
                  const SizedBox(height: 20),
                  if (_query.isEmpty &&
                      _category == 'all' &&
                      _connectedCount > 0) ...[
                    _SectionLabel('Connected'),
                    const SizedBox(height: 8),
                    for (final account in _one!.accounts)
                      _ConnectorRow(
                        item: _connectorFor(account),
                        connected: true,
                        busy: _busy,
                        onConnect: () => _connect(account.platform),
                        onOpen: () => _openDetail(_connectorFor(account)),
                      ),
                    const SizedBox(height: 16),
                  ],
                  _SectionLabel(
                    _query.isEmpty && _category == 'all'
                        ? 'Apps'
                        : '${_visible.length} shown',
                  ),
                  const SizedBox(height: 8),
                  for (final item in _visible)
                    _ConnectorRow(
                      item: item,
                      connected: _connected(item),
                      busy: _busy,
                      onConnect: () => _connect(item.slug),
                      onOpen: () => _openDetail(item),
                    ),
                  if (_apps.isNotEmpty && _query.isEmpty && _category == 'all')
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'Search ${_apps.length} apps. Connect opens One, '
                        'where you can grant any of them.',
                        style: theme.textTheme.muted,
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}

class _Connector {
  const _Connector(
    this.slug,
    this.title,
    this.category,
    this.description, {
    this.image,
  });

  final String slug;
  final String title;
  final String category;
  final String description;
  final String? image;
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(text, style: ShadTheme.of(context).textTheme.muted);
  }
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    if (selected) {
      return ShadButton(
        size: ShadButtonSize.sm,
        onPressed: onPressed,
        child: Text(label),
      );
    }
    return ShadButton.outline(
      size: ShadButtonSize.sm,
      onPressed: onPressed,
      child: Text(label),
    );
  }
}

class _ConnectorRow extends StatelessWidget {
  const _ConnectorRow({
    required this.item,
    required this.connected,
    required this.busy,
    required this.onConnect,
    required this.onOpen,
  });

  final _Connector item;
  final bool connected;
  final bool busy;
  final VoidCallback onConnect;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              _AppGlyph(item: item),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  item.title,
                  style: theme.textTheme.small,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (connected)
                Flexible(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        LucideIcons.check,
                        size: 16,
                        color: theme.colorScheme.foreground,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          'Connected',
                          style: theme.textTheme.muted,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                )
              else
                MaieBusyButton(
                  label: 'Connect',
                  busyLabel: 'Connecting',
                  busy: busy,
                  outline: true,
                  size: ShadButtonSize.sm,
                  onPressed: onConnect,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AppGlyph extends StatelessWidget {
  const _AppGlyph({required this.item, this.size = 36});

  final _Connector item;
  final double size;

  @override
  Widget build(BuildContext context) {
    return CompanyLogo(image: item.image, slug: item.slug, size: size);
  }
}

class _ConnectorDetail extends StatelessWidget {
  const _ConnectorDetail({
    required this.item,
    required this.account,
    required this.connected,
    required this.busy,
    required this.onConnect,
    required this.onDisconnect,
    required this.onSync,
  });

  final _Connector item;
  final OneAccount? account;
  final bool connected;
  final bool busy;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;
  final VoidCallback onSync;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Scaffold(
      body: MaiePane(
        header: MaieHeader(
          title: item.title,
          leading: ShadIconButton.ghost(
            icon: const Icon(LucideIcons.arrowLeft, size: 16),
            onPressed: () => Navigator.of(context).pop(),
          ),
          actions: [
            ShadIconButton.ghost(
              icon: const Icon(LucideIcons.x, size: 16),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Row(
              children: [
                _AppGlyph(item: item, size: 48),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    item.title,
                    style: theme.textTheme.h4,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: connected
                  ? MaieBusyButton(
                      label: 'Disconnect',
                      busyLabel: 'Disconnecting',
                      busy: busy,
                      outline: true,
                      onPressed: onDisconnect,
                    )
                  : MaieBusyButton(
                      label: 'Connect',
                      busyLabel: 'Connecting',
                      busy: busy,
                      onPressed: onConnect,
                    ),
            ),
            const SizedBox(height: 10),
            Text(item.description, style: theme.textTheme.muted),
            const SizedBox(height: 24),
            Text('Accounts', style: theme.textTheme.muted),
            const SizedBox(height: 8),
            ShadCard(
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      account?.label ?? 'default',
                      style: theme.textTheme.small,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    connected ? 'Connected' : 'Off',
                    style: theme.textTheme.muted.copyWith(
                      color: connected
                          ? const Color(0xFF34C759)
                          : theme.colorScheme.mutedForeground,
                    ),
                  ),
                ],
              ),
            ),
            if (connected) ...[
              const SizedBox(height: 16),
              MaieBusyButton(
                label: 'Sync now',
                busyLabel: 'Syncing',
                busy: busy,
                outline: true,
                onPressed: onSync,
              ),
            ],
            const SizedBox(height: 24),
            Text(
              'OAuth stays at One. Maie stores a grant pointer, not the token.',
              style: theme.textTheme.muted,
            ),
          ],
        ),
      ),
    );
  }
}

