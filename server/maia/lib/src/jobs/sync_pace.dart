/// The connector to pull next, and the cursor to keep for the one after.
class SyncPick {
  const SyncPick(this.platform, this.next);

  final String platform;
  final int next;
}

/// One connector per pass, walking [platforms] from [cursor].
SyncPick? nextConnector(List<String> platforms, int cursor) {
  if (platforms.isEmpty) return null;
  final index = cursor < 0 ? 0 : cursor % platforms.length;
  return SyncPick(platforms[index], (index + 1) % platforms.length);
}

/// How long to wait before the connector at [index] so a full pass
/// does not hit One at the same moment.
Duration syncDelay(int index) =>
    index <= 0 ? Duration.zero : Duration(seconds: 90 * index);
