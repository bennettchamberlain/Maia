import 'dart:convert';

import 'package:http/http.dart' as http;

/// One's public connector directory. Cached so the tools page can search
/// the whole catalog without asking One on every keystroke.
class OneCatalog {
  OneCatalog({http.Client? httpClient}) : _http = httpClient ?? http.Client();

  final http.Client _http;
  List<Map<String, dynamic>>? _rows;
  DateTime? _loadedAt;

  Future<Map<String, dynamic>> snapshot() async {
    final rows = await _load();
    final categories = <String>{
      for (final row in rows) row['category'] as String,
    }.toList()..sort();
    return {
      'total': rows.length,
      'categories': categories,
      'connectors': rows,
    };
  }

  Future<List<Map<String, dynamic>>> _load() async {
    final cached = _rows;
    final at = _loadedAt;
    if (cached != null &&
        at != null &&
        DateTime.now().difference(at) < const Duration(hours: 12)) {
      return cached;
    }
    final all = <Map<String, dynamic>>[];
    for (var page = 1; page <= 20; page++) {
      final response = await _http.get(
        Uri.parse(
          'https://api.withone.ai/v1/available-connectors?limit=150&page=$page',
        ),
        headers: const {'user-agent': 'maia'},
      );
      if (response.statusCode >= 400) {
        throw http.ClientException(
          'connector catalog ${response.statusCode}',
          Uri.parse('https://api.withone.ai/v1/available-connectors'),
        );
      }
      final json = jsonDecode(response.body);
      if (json is! Map<String, dynamic>) break;
      final rows = json['rows'];
      if (rows is! List || rows.isEmpty) break;
      for (final row in rows) {
        if (row is! Map<String, dynamic>) continue;
        final slug = (row['platform'] as String?)?.trim() ?? '';
        if (slug.isEmpty || row['active'] == false) continue;
        final description = (row['description'] as String? ?? '').trim();
        all.add({
          'slug': slug,
          'title': (row['title'] ?? row['name'] ?? slug).toString(),
          'category': (row['category'] as String?)?.trim().isNotEmpty == true
              ? row['category']
              : 'Other',
          'description': description.length <= 180
              ? description
              : '${description.substring(0, 177)}...',
          'image': row['image'],
        });
      }
      final pages = json['pages'];
      if (pages is int && page >= pages) break;
    }
    _rows = all;
    _loadedAt = DateTime.now();
    return all;
  }
}
