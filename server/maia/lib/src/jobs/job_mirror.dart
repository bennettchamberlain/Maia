import 'dart:async';
import 'dart:convert';

import 'package:maia_api/src/db.dart';
import 'package:postgres/postgres.dart';

/// Writes the jobs-page mirror for a pg-boss job.
///
/// ETL and weave run in Python and never touched this row, so the page
/// stayed on `created` after the work finished.
Future<void> markJob(
  Db db,
  String personId,
  String pgbossId,
  String state, {
  String? error,
}) async {
  final done =
      state == 'completed' || state == 'failed' || state == 'cancelled';
  await db.asPerson(personId).execute(
    done
        ? r'''
          update JobRecord filter .pgboss_id = <uuid>$id set {
            state := <JobState><str>$state,
            completed_at := datetime_of_statement(),
            error := <optional str>$error,
          }
          '''
        : r'''
          update JobRecord filter .pgboss_id = <uuid>$id set {
            state := <JobState><str>$state,
            started_at := datetime_of_statement(),
            error := <optional str>$error,
          }
          ''',
    {'id': pgbossId, 'state': state, 'error': error},
  );
}

/// Copies terminal pg-boss states onto mirrors still marked created.
Future<void> reconcileJobMirrors(Db db, Pool<void> pool) async {
  try {
    final rows = await pool.execute(
      "select id::text, state::text from pgboss.job where state <> 'created'",
    );
    for (final row in rows) {
      final id = '${row[0]}';
      final state = '${row[1]}';
      if (id.isEmpty || !_states.contains(state) || state == 'created') {
        continue;
      }
      final done =
          state == 'completed' || state == 'failed' || state == 'cancelled';
      try {
        await db.bypass.execute(
          done
              ? r'''
                update JobRecord
                filter .pgboss_id = <uuid>$id and .state = JobState.created
                set {
                  state := <JobState><str>$state,
                  completed_at := datetime_of_statement(),
                }
                '''
              : r'''
                update JobRecord
                filter .pgboss_id = <uuid>$id and .state = JobState.created
                set { state := <JobState><str>$state }
                ''',
          {'id': id, 'state': state},
        );
      } on Object {
        // One bad row should not stop the rest of the mirror.
      }
    }
  } on Object {
    // pg-boss may not be installed yet. The runner still starts.
  }
}

const _states = {
  'created',
  'retry',
  'active',
  'completed',
  'cancelled',
  'failed',
};

/// True when an open mirror for this name is still fresh enough to keep.
bool openMirrorBlocks(String? createdAtIso, DateTime now) {
  final created = DateTime.tryParse(createdAtIso ?? '');
  if (created == null) return false;
  return now.toUtc().difference(created.toUtc()) < const Duration(minutes: 15);
}

/// Reads the newest open mirror's timestamp from a `queryJSON` payload.
String? newestOpenCreatedAt(String json) {
  final decoded = jsonDecode(json);
  if (decoded is! List || decoded.isEmpty) return null;
  final row = decoded.first;
  if (row is! Map) return null;
  final at = row['created_at'];
  return at == null ? null : '$at';
}

/// Asks for a sync on a timer so connected accounts keep cloning.
class SyncClock {
  /// [every] is how often a new sync is offered. Open mirrors block dupes.
  new(this._sync, {this.every = const Duration(minutes: 10)});

  final Future<void> Function() _sync;

  /// How often a sync is offered.
  final Duration every;
  Timer? _timer;

  /// Starts the timer and runs one pass immediately.
  void start() {
    _timer ??= Timer.periodic(every, (_) => unawaited(_once()));
    unawaited(_once());
  }

  /// Stops the timer.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _once() async {
    try {
      await _sync();
    } on Object {
      // The next tick tries again.
    }
  }
}

/// Runs [inner] and mirrors its outcome onto the person's job row.
Future<Object?> mirrorPythonJob(
  Db db, {
  required Map<String, dynamic> data,
  required String pgbossId,
  required Future<Object?> Function() inner,
}) async {
  final personId = data['person_id']?.toString() ?? '';
  if (personId.isNotEmpty) {
    await markJob(db, personId, pgbossId, 'active');
  }
  try {
    final out = await inner();
    if (personId.isNotEmpty) {
      await markJob(db, personId, pgbossId, 'completed');
    }
    return out;
  } on Object catch (e) {
    if (personId.isNotEmpty) {
      await markJob(db, personId, pgbossId, 'failed', error: '$e');
    }
    rethrow;
  }
}
