import 'dart:math';

import 'package:maia_api/src/db.dart';

/// Stores the raw failure. The caller shows the summary and the ref.
class FaultLog {
  FaultLog(this.db);

  final Db db;
  final _random = Random.secure();

  Future<String?> write({
    required String kind,
    required String action,
    required String summary,
    required String detail,
    String? route,
    String? client,
    String? personId,
  }) async {
    final ref = _ref();
    try {
      await db.bypass.execute(
        r'''
        insert ClientFault {
          ref := <str>$ref,
          kind := <str>$kind,
          action := <str>$action,
          summary := <str>$summary,
          detail := <str>$detail,
          route := <optional str>$route,
          client := <optional str>$client,
          person := (select Person filter .id = <optional uuid>$person limit 1),
        }
        ''',
        {
          'ref': ref,
          'kind': kind,
          'action': _clip(action, 200),
          'summary': _clip(summary, 300),
          'detail': _clip(detail),
          'route': route == null ? null : _clip(route, 300),
          'client': client == null ? null : _clip(client, 200),
          'person': personId,
        },
      );
      return ref;
    } on Object {
      return null;
    }
  }

  String _ref() {
    final bytes = List<int>.generate(4, (_) => _random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static String _clip(String s, [int n = 4000]) =>
      s.length <= n ? s : s.substring(0, n);
}

/// Short line for a status, when the handler did not already write one.
String friendlyFault(int status) => switch (status) {
  400 => 'That request was not understood.',
  401 => 'Please sign in again.',
  403 => "You don't have access to that.",
  404 => 'That could not be found.',
  409 => 'That conflicts with something already saved.',
  503 => 'That service is not available right now.',
  _ => 'Something went wrong. Try again.',
};
