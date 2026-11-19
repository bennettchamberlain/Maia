import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// One stored credential. The chat only ever sees [dummy].
class VaultHandle {
  const VaultHandle({required this.name, required this.dummy});

  final String name;

  /// Stable stand-in, `cred_` plus 8 hex digits. Random once, then kept.
  final String dummy;
}

/// Encrypted credentials for one person. The transcript stores the
/// dummy handle. The desktop reads the real value outside the model.
class VaultStore {
  VaultStore({required this.root, required this.secret, Random? random})
    : _random = random ?? Random.secure();

  final Directory root;
  final String secret;
  final Random _random;

  static final _name = RegExp(r'^[a-z][a-z0-9_]{0,31}$');
  static final _dummy = RegExp(r'^cred_[0-9a-f]{8}$');

  /// Saves [value] and returns the handle the model is allowed to say.
  /// A later save of the same name keeps the handle.
  Future<VaultHandle> put(String personId, String name, String value) async {
    _checkPerson(personId);
    if (!_name.hasMatch(name)) {
      throw const VaultException('credential name is not allowed');
    }
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed.length > 4000) {
      throw const VaultException('credential value is empty or too long');
    }
    final dir = Directory('${root.path}/$personId');
    await dir.create(recursive: true);
    final file = File('${dir.path}/$name.json');
    final existing = await _read(file);
    final dummy = existing?.dummy ?? _freshDummy(dir);
    final nonce = _nonce();
    final key = _key(personId);
    final cipher = _xor(
      utf8.encode(trimmed),
      _stream(key, nonce, trimmed.length),
    );
    final tag = _tag(key, nonce, cipher);
    await file.writeAsString(
      jsonEncode({
        'dummy': dummy,
        'nonce': base64Encode(nonce),
        'tag': base64Encode(tag),
        'cipher': base64Encode(cipher),
      }),
      flush: true,
    );
    return VaultHandle(name: name, dummy: dummy);
  }

  Future<List<VaultHandle>> list(String personId) async {
    _checkPerson(personId);
    final dir = Directory('${root.path}/$personId');
    if (!dir.existsSync()) return const [];
    final handles = <VaultHandle>[];
    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      final row = await _read(entity);
      if (row == null) continue;
      handles.add(VaultHandle(name: _base(entity), dummy: row.dummy));
    }
    handles.sort((a, b) => a.name.compareTo(b.name));
    return handles;
  }

  Future<void> remove(String personId, String name) async {
    _checkPerson(personId);
    if (!_name.hasMatch(name)) return;
    final file = File('${root.path}/$personId/$name.json');
    if (file.existsSync()) await file.delete();
  }

  /// Replaces any stored secret in [text] with its handle.
  Future<String> scrub(String personId, String text) async {
    final rows = await _rows(personId);
    return _scrub(rows, text);
  }

  /// Real values for handles that appear in [text], except the instabox key.
  /// The caller injects these into the desktop and must not log them.
  Future<Map<String, String>> filesFor(String personId, String text) async {
    final out = <String, String>{};
    for (final row in await _rows(personId)) {
      if (row.name == 'instabox') continue;
      if (!_dummy.hasMatch(row.dummy)) continue;
      if (!text.contains(row.dummy)) continue;
      final value = row.value;
      if (value == null || value.isEmpty) continue;
      out[row.dummy] = value;
    }
    return out;
  }

  /// The person's instabox key, if they stored one under that name.
  Future<String?> instaboxKey(String personId) async {
    for (final row in await _rows(personId)) {
      if (row.name == 'instabox') return row.value;
    }
    return null;
  }

  String _scrub(List<_Row> rows, String text) {
    final secrets = [
      for (final row in rows)
        if (row.value != null && row.value!.length >= 4) row,
    ]..sort((a, b) => b.value!.length.compareTo(a.value!.length));
    var out = text;
    for (final row in secrets) {
      out = out.replaceAll(row.value!, row.dummy);
    }
    return out;
  }

  Future<List<_Row>> _rows(String personId) async {
    _checkPerson(personId);
    final dir = Directory('${root.path}/$personId');
    if (!dir.existsSync()) return const [];
    final rows = <_Row>[];
    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      final row = await _read(entity);
      if (row == null) continue;
      rows.add(row);
    }
    return rows;
  }

  Future<_Row?> _read(File file) async {
    if (!file.existsSync()) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(await file.readAsString());
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    final dummy = decoded['dummy'];
    final nonce = _b64(decoded['nonce']);
    final tag = _b64(decoded['tag']);
    final cipher = _b64(decoded['cipher']);
    if (dummy is! String || nonce == null || tag == null || cipher == null) {
      return null;
    }
    final key = _key(_personOf(file));
    final expect = _tag(key, nonce, cipher);
    if (!_same(tag, expect)) return null;
    final plain = utf8.decode(
      _xor(cipher, _stream(key, nonce, cipher.length)),
      allowMalformed: false,
    );
    return _Row(name: _base(file), dummy: dummy, value: plain);
  }

  String _freshDummy(Directory dir) {
    for (var n = 0; n < 8; n++) {
      final dummy = 'cred_${_hex(4)}';
      final taken = dir.listSync().whereType<File>().any(
        (file) => file.readAsStringSync().contains('"$dummy"'),
      );
      if (!taken) return dummy;
    }
    return 'cred_${_hex(4)}';
  }

  String _hex(int bytes) {
    final data = List<int>.generate(bytes, (_) => _random.nextInt(256));
    return data.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  List<int> _nonce() => List<int>.generate(16, (_) => _random.nextInt(256));

  List<int> _key(String personId) {
    final mac = Hmac(sha256, utf8.encode(secret));
    return mac.convert(utf8.encode('maie-vault-v1:$personId')).bytes;
  }

  List<int> _stream(List<int> key, List<int> nonce, int length) {
    final out = <int>[];
    var counter = 0;
    while (out.length < length) {
      final mac = Hmac(sha256, key);
      final block = mac.convert([...nonce, ..._u32(counter)]).bytes;
      out.addAll(block);
      counter++;
    }
    return out.sublist(0, length);
  }

  List<int> _tag(List<int> key, List<int> nonce, List<int> cipher) {
    final mac = Hmac(sha256, key);
    return mac.convert([...nonce, ...cipher]).bytes.sublist(0, 16);
  }

  List<int> _xor(List<int> data, List<int> stream) => [
    for (var i = 0; i < data.length; i++) data[i] ^ stream[i],
  ];

  List<int> _u32(int n) => [
    (n >> 24) & 0xff,
    (n >> 16) & 0xff,
    (n >> 8) & 0xff,
    n & 0xff,
  ];

  bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  List<int>? _b64(Object? value) {
    if (value is! String) return null;
    try {
      return base64Decode(value);
    } on FormatException {
      return null;
    }
  }

  String _base(File file) =>
      file.uri.pathSegments.last.replaceFirst(RegExp(r'\.json$'), '');

  String _personOf(File file) =>
      file.parent.uri.pathSegments.where((part) => part.isNotEmpty).last;

  void _checkPerson(String personId) {
    if (!RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    ).hasMatch(personId)) {
      throw const VaultException('person id is not a uuid');
    }
  }
}

class _Row {
  const _Row({required this.name, required this.dummy, required this.value});

  final String name;
  final String dummy;
  final String? value;
}

class VaultException implements Exception {
  const VaultException(this.message);
  final String message;

  @override
  String toString() => message;
}
