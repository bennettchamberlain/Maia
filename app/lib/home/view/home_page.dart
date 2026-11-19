import 'dart:math' as math;

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:maie_app/chat/chat.dart';
import 'package:maie_app/home/view/settings_page.dart';
import 'package:maie_app/jobs/jobs.dart';
import 'package:maie_app/memory/memory.dart';
import 'package:maie_app/session/session.dart';
import 'package:maie_app/tools/tools.dart';
import 'package:maie_app/ui/glass.dart';
import 'package:maie_app/ui/span.dart';
import 'package:maie_models/maie_models.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Shell with one destination per feature. Chat, memory and jobs are live;
/// the rest are stubbed until their server slices exist.
class HomePage extends StatefulWidget {
  const new({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  var _index = 0;
  var _settings = false;
  var _account = false;

  static const _destinations = <({IconData icon, String label})>[
    (icon: LucideIcons.messageCircle, label: 'Chat'),
    (icon: LucideIcons.brain, label: 'Memory'),
    (icon: LucideIcons.unplug, label: 'Connectors'),
    (icon: LucideIcons.listTodo, label: 'Jobs'),
    // Places: LucideIcons.mapPin
    // People: LucideIcons.users
    // Asks:   LucideIcons.messageSquare
  ];

  void _select(int index) {
    setState(() {
      _index = index;
      _settings = false;
      _account = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final person = context.select<SessionCubit, Person?>((c) => c.state.person);
    final span = maieSpan(MediaQuery.sizeOf(context).width);
    final chatRail = span == MaieSpan.rail && !_settings && _index == 0;
    final icons = _DockIcons(
      index: _index,
      settings: _settings,
      person: person,
      fill: !chatRail,
      onSelected: _select,
      onAccount: () => setState(() => _account = !_account),
    );
    final pages = <Widget>[
      ChatPage(railFooter: chatRail ? icons : null),
      const MemoryPage(),
      const ToolsPage(),
      const JobsPage(),
    ];
    final body = _settings
        ? SettingsPage(onClose: () => setState(() => _settings = false))
        : IndexedStack(index: _index, children: pages);

    if (span == MaieSpan.stack) {
      return Scaffold(
        body: SafeArea(bottom: false, child: body),
        bottomNavigationBar: _BottomNav(index: _index, onSelected: _select),
      );
    }

    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Row(
              children: [
                if (!chatRail) icons,
                Expanded(child: body),
              ],
            ),
            if (_account)
              Positioned(
                left: 80,
                bottom: 12,
                width: 220,
                child: _AccountCard(
                  settings: _settings,
                  onSettings: () => setState(() {
                    _settings = !_settings;
                    _account = false;
                  }),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _DockIcons extends StatelessWidget {
  const new({
    required this.index,
    required this.settings,
    required this.person,
    required this.fill,
    required this.onSelected,
    required this.onAccount,
  });

  final int index;
  final bool settings;
  final Person? person;
  final bool fill;
  final ValueChanged<int> onSelected;
  final VoidCallback onAccount;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final handle = person?.handle ?? 'Maie';
    final initial = handle.isEmpty ? 'M' : handle.substring(0, 1).toUpperCase();
    final buttons = <Widget>[
      for (var i = 0; i < _HomePageState._destinations.length; i++)
        _DockButton(
          icon: _HomePageState._destinations[i].icon,
          label: _HomePageState._destinations[i].label,
          selected: !settings && index == i,
          onPressed: () => onSelected(i),
        ),
      _DockButton(
        icon: LucideIcons.circleUser,
        label: handle,
        selected: settings,
        onPressed: onAccount,
        mark: initial,
      ),
      const SizedBox(height: 8),
    ];
    if (!fill) return Column(mainAxisSize: MainAxisSize.min, children: buttons);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: theme.colorScheme.border)),
      ),
      child: SizedBox(
        width: 72,
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final height = constraints.maxHeight.isFinite
                  ? constraints.maxHeight
                  : 0.0;
              return SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: height),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: buttons,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _DockButton extends StatelessWidget {
  const new({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onPressed,
    this.mark,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onPressed;
  final String? mark;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Tooltip(
        message: label,
        child: Material(
          color: selected ? theme.colorScheme.accent : Colors.transparent,
          borderRadius: const BorderRadius.all(Radius.circular(10)),
          child: InkWell(
            onTap: onPressed,
            borderRadius: const BorderRadius.all(Radius.circular(10)),
            child: SizedBox(
              width: 44,
              height: 44,
              child: Center(
                child: mark == null
                    ? Icon(icon, size: 18)
                    : Text(mark!, style: theme.textTheme.small),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AccountCard extends StatelessWidget {
  const new({required this.settings, required this.onSettings});

  final bool settings;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.background,
        borderRadius: const BorderRadius.all(Radius.circular(10)),
        border: Border.all(color: theme.colorScheme.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _NavButton(
              icon: LucideIcons.settings,
              label: 'Settings',
              selected: settings,
              onPressed: onSettings,
            ),
            const SizedBox(height: 4),
            _NavButton(
              icon: LucideIcons.logOut,
              label: 'Sign out',
              selected: false,
              onPressed: () => context.read<SessionCubit>().signedOut(),
            ),
          ],
        ),
      ),
    );
  }
}

class _BottomNav extends StatelessWidget {
  const new({required this.index, required this.onSelected});

  final int index;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final field = watchField(context);
    final bar = DecoratedBox(
      decoration: BoxDecoration(
        color: field ? Colors.transparent : theme.colorScheme.background,
        border: Border(top: BorderSide(color: theme.colorScheme.border)),
      ),
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < 1 || constraints.maxHeight < 1) {
              return const SizedBox.shrink();
            }
            final count = _HomePageState._destinations.length;
            final slot = math.max(72, constraints.maxWidth / count).toDouble();
            final barHeight = math.min(56, constraints.maxHeight).toDouble();
            return SizedBox(
              width: constraints.maxWidth,
              height: barHeight,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: SizedBox(
                  width: slot * count,
                  height: 56,
                  child: Row(
                    children: [
                      for (var i = 0; i < count; i++)
                        SizedBox(
                          width: slot,
                          child: _NavButton(
                            icon: _HomePageState._destinations[i].icon,
                            label: _HomePageState._destinations[i].label,
                            selected: index == i,
                            stacked: true,
                            onPressed: () => onSelected(i),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
    if (!field) return bar;
    return MaieGlass(opacity: 0.62, border: false, child: bar);
  }
}

class _NavButton extends StatelessWidget {
  const new({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onPressed,
    this.stacked = false,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final bool stacked;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final glyph = Icon(icon, size: 16);
    final labelText = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: stacked
          ? theme.textTheme.small.copyWith(fontSize: 11)
          : theme.textTheme.small,
    );
    // ShadButton's row gives its label unbounded width, so a narrow slot
    // overflows. A plain button passes the slot's max width through.
    return Material(
      color: selected ? theme.colorScheme.accent : Colors.transparent,
      borderRadius: const BorderRadius.all(Radius.circular(6)),
      child: InkWell(
        onTap: onPressed,
        borderRadius: const BorderRadius.all(Radius.circular(6)),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: stacked ? 4 : 12,
            vertical: stacked ? 4 : 8,
          ),
          child: stacked
              ? Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [glyph, const SizedBox(height: 2), labelText],
                )
              : Row(
                  children: [
                    glyph,
                    const SizedBox(width: 8),
                    Expanded(child: labelText),
                  ],
                ),
        ),
      ),
    );
  }
}
