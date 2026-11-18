import 'dart:math' as math;

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:maia_app/chat/chat.dart';
import 'package:maia_app/jobs/jobs.dart';
import 'package:maia_app/memory/memory.dart';
import 'package:maia_app/tools/tools.dart';
import 'package:maia_app/session/session.dart';
import 'package:maia_app/ui/chrome.dart';
import 'package:maia_models/maia_models.dart';
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

  static const _pages = <Widget>[
    ChatPage(),
    MemoryPage(),
    ToolsPage(),
    JobsPage(),
    // PositionsPage(),   // background location + presence overlap
    // PeoplePage(),      // relationships, tiers, consent grants
    // AsksPage(),        // ask a friend; disclosure ladder
    // SettingsPage(),
  ];

  static const _destinations = <({IconData icon, String label})>[
    (icon: LucideIcons.messageCircle, label: 'Chat'),
    (icon: LucideIcons.brain, label: 'Memory'),
    (icon: LucideIcons.unplug, label: 'Connectors'),
    (icon: LucideIcons.listTodo, label: 'Jobs'),
    // Places: LucideIcons.mapPin
    // People: LucideIcons.users
    // Asks:   LucideIcons.messageSquare
  ];

  @override
  Widget build(BuildContext context) {
    final person = context.select<SessionCubit, Person?>(
      (c) => c.state.person,
    );
    final wide = MediaQuery.sizeOf(context).width >= 700;
    final body = IndexedStack(index: _index, children: _pages);

    if (wide) {
      return Scaffold(
        body: Row(
          children: [
            _Sidebar(
              handle: person?.handle,
              index: _index,
              onSelected: (i) => setState(() => _index = i),
            ),
            Expanded(child: body),
          ],
        ),
      );
    }

    return Scaffold(
      body: body,
      bottomNavigationBar: _BottomNav(
        index: _index,
        onSelected: (i) => setState(() => _index = i),
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const new({
    required this.handle,
    required this.index,
    required this.onSelected,
  });

  final String? handle;
  final int index;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final initial = (handle ?? '?').substring(0, 1).toUpperCase();
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: theme.colorScheme.border)),
      ),
      child: SizedBox(
        width: 220,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: MaiaPane(
            header: Row(
              children: [
                ShadAvatar(
                  null,
                  size: const Size.square(32),
                  placeholder: Text(initial, style: theme.textTheme.small),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    handle ?? 'Maia',
                    style: theme.textTheme.small,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
              ],
            ),
            body: ListView(
              padding: const EdgeInsets.only(top: 16),
              children: [
                for (var i = 0; i < _HomePageState._destinations.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: _NavButton(
                      icon: _HomePageState._destinations[i].icon,
                      label: _HomePageState._destinations[i].label,
                      selected: index == i,
                      onPressed: () => onSelected(i),
                    ),
                  ),
              ],
            ),
            footer: const _SignOutButton(),
          ),
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
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.background,
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
                  children: [
                    glyph,
                    const SizedBox(height: 2),
                    labelText,
                  ],
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

class _SignOutButton extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: const BorderRadius.all(Radius.circular(6)),
      child: InkWell(
        onTap: () => context.read<SessionCubit>().signedOut(),
        borderRadius: const BorderRadius.all(Radius.circular(6)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              const Icon(LucideIcons.logOut, size: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Sign out',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ShadTheme.of(context).textTheme.small,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
