import 'package:maie_models/maie_models.dart';

/// One day in the memory column.
class DayGroup {
  const DayGroup({required this.label, required this.entries});

  final String label;
  final List<TimelineEntry> entries;
}

/// Groups [entries] by the local day they ended, keeping list order.
List<DayGroup> groupEntries(List<TimelineEntry> entries, DateTime now) {
  final groups = <DateTime, List<TimelineEntry>>{};
  final order = <DateTime>[];
  final today = DateTime(now.year, now.month, now.day);
  for (final entry in entries) {
    final local = entry.endedAt.toLocal();
    final day = DateTime(local.year, local.month, local.day);
    final bucket = groups[day];
    if (bucket == null) {
      groups[day] = [entry];
      order.add(day);
    } else {
      bucket.add(entry);
    }
  }
  return [
    for (final day in order)
      DayGroup(label: dayLabel(day, today), entries: groups[day]!),
  ];
}

/// `Today`, `Yesterday`, or `Tue 10 Nov`.
String dayLabel(DateTime day, DateTime today) {
  final date = DateTime(day.year, day.month, day.day);
  final start = DateTime(today.year, today.month, today.day);
  if (date == start) return 'Today';
  if (date == start.subtract(const Duration(days: 1))) return 'Yesterday';
  const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${weekdays[date.weekday - 1]} ${date.day} ${months[date.month - 1]}';
}

/// `2:35 PM – 3:08 PM`, or both dates when the span crosses midnight.
String formatSpan(DateTime start, DateTime end) {
  final a = start.toLocal();
  final b = end.toLocal();
  final sameDay =
      a.year == b.year && a.month == b.month && a.day == b.day;
  if (sameDay) return '${_clock(a)} – ${_clock(b)}';
  return '${_dayClock(a)} – ${_dayClock(b)}';
}

String _dayClock(DateTime time) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${months[time.month - 1]} ${time.day}, ${_clock(time)}';
}

String _clock(DateTime time) {
  final hour = time.hour % 12 == 0 ? 12 : time.hour % 12;
  final minute = time.minute.toString().padLeft(2, '0');
  final suffix = time.hour < 12 ? 'AM' : 'PM';
  return '$hour:$minute $suffix';
}

/// Account line for a connector card. Empty for a chat.
String entryAccountLine(TimelineEntry entry) {
  if (entry.kind == 'session' || entry.kind == 'file') return '';
  final platform = switch (entry.platform ?? entry.kind) {
    'gmail' || 'mail' => 'Gmail',
    'google-calendar' || 'calendar' => 'Calendar',
    'github' => 'GitHub',
    final other => other,
  };
  final account = entry.account;
  if (account == null || account.isEmpty || account == entry.platform) {
    return platform;
  }
  return '$platform · $account';
}
