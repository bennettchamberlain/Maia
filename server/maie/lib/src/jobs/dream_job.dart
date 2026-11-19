import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:maie_api/src/chat/tools.dart';
import 'package:maie_api/src/db.dart';
import 'package:maie_api/src/harness/harness.dart';
import 'package:maie_api/src/library/store.dart';
import 'package:maie_jobs/maie_jobs.dart';

/// The only nightly job. One pass per person: promote what earned it,
/// then cache a short brief on the interests they already named.
class DreamJob {
  DreamJob({required this.db, this.youApiKey, this.library});

  final Db db;
  final String? youApiKey;
  final PersonLibrary? library;

  Future<Map<String, Object?>> run(Job job) async {
    final listed = jsonDecode(
      await db.bypass.queryJSON('select Person { id }'),
    );
    if (listed is! List || listed.isEmpty) return const {'people': 0};
    var researched = 0;
    var failed = 0;
    for (final row in listed) {
      if (row is! Map) continue;
      final id = row['id'];
      if (id is! String) continue;
      try {
        final out = await dream(
          db.asPerson(id),
          search: _search,
          now: DateTime.now(),
        );
        researched += (out['researched'] as int?) ?? 0;
        final topics = out['topics'];
        final named = topics is List ? topics.join(', ') : '';
        await library?.write(
          personId: id,
          kind: 'turns',
          id: 'night-${dreamDay(DateTime.now())}',
          name: 'Night',
          body:
              'Proposed ${out['proposed']} curated rows. '
              'Researched $named.',
        );
      } on Object {
        failed++;
      }
    }
    if (failed == listed.length) {
      throw StateError('dream failed for every person');
    }
    return {
      'people': listed.length,
      'researched': researched,
      'failed': failed,
      'day': job.data['day'],
    };
  }

  Future<List<Map<String, dynamic>>> Function(String topic)? get _search {
    final key = youApiKey;
    if (key == null || key.isEmpty) return null;
    return (topic) => youResearch(key, topic);
  }
}

/// You.com hits for one interest. Empty when the search itself fails.
Future<List<Map<String, dynamic>>> youResearch(
  String apiKey,
  String topic,
) async {
  final client = http.Client();
  try {
    final response = await client
        .post(
          Uri.parse('https://ydc-index.io/v1/search'),
          headers: {'X-API-Key': apiKey, 'content-type': 'application/json'},
          body: jsonEncode({'query': topic, 'count': 5}),
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode >= 400) return const [];
    return youWebHits(jsonDecode(response.body));
  } on Object {
    return const [];
  } finally {
    client.close();
  }
}

/// Sends `dream` once during the nightly hour. Nothing else is scheduled.
class DreamClock {
  DreamClock(this.jobs, {this.hour = 3, DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final PgBossQueue jobs;
  final int hour;
  final DateTime Function() _now;
  Timer? _timer;
  String? _sentDay;

  void start() {
    _timer ??= Timer.periodic(const Duration(minutes: 1), (_) {
      unawaited(_tick());
    });
    unawaited(_tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    final now = _now();
    final day = dreamDay(now);
    if (!dreamDue(now, lastDay: _sentDay, hour: hour)) return;
    await jobs.send(
      'dream',
      {'day': day},
      SendOptions(
        singletonKey: 'dream-$day',
        expireIn: const Duration(minutes: 30),
      ),
    );
    _sentDay = day;
  }
}
