import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:maie_app/config/field_cubit.dart';
import 'package:maie_app/ui/chrome.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Account settings. Storage is sketched here and not wired up yet.
class SettingsPage extends StatelessWidget {
  const new({required this.onClose, super.key});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final field = context.watch<FieldCubit>().state;
    return Scaffold(
      body: MaiePane(
        header: MaieHeader(
          title: 'Settings',
          leading: ShadIconButton.ghost(
            onPressed: onClose,
            icon: const Icon(LucideIcons.arrowLeft, size: 16),
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: [
            ShadCheckbox(
              value: field,
              onChanged: (value) => context.read<FieldCubit>().setOn(value),
              label: const Text('Field behind the app'),
              sublabel: const Text(
                'The mark plays in the open. Glass covers what you read.',
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Text('Storage', style: theme.textTheme.h4),
                const SizedBox(width: 8),
                const ShadBadge.outline(child: Text('To do')),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'The cloud holds the record. This device keeps a cache of it, '
              'and the cache stays in step with your accounts. Storage is '
              'billed. The copy is yours to download.',
              style: theme.textTheme.muted,
            ),
            const SizedBox(height: 16),
            const _StorageRow(
              label: 'Keep a cache on this device',
              detail: 'On. Sync fills it from the cloud.',
              value: true,
            ),
            const SizedBox(height: 12),
            const _StorageRow(
              label: 'Cloud storage',
              detail: 'Billed later. Not connected to a plan yet.',
              value: false,
            ),
            const SizedBox(height: 16),
            const ShadButton.outline(
              enabled: false,
              child: Text('Download everything'),
            ),
          ],
        ),
      ),
    );
  }
}

class _StorageRow extends StatelessWidget {
  const new({required this.label, required this.detail, required this.value});

  final String label;
  final String detail;
  final bool value;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: theme.textTheme.p),
              Text(detail, style: theme.textTheme.muted),
            ],
          ),
        ),
        ShadSwitch(value: value, enabled: false),
      ],
    );
  }
}
