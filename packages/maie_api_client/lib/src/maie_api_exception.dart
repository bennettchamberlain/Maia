/// Error from maie-api. `statusCode` is the HTTP status; `code` is the
/// machine-readable error the server returned, when it did. `ref` points
/// at the stored detail. [shown] is the line to put on screen.
class MaieApiException implements Exception {
  const MaieApiException(this.statusCode, this.message, {this.code, this.ref});

  final int statusCode;
  final String message;
  final String? code;
  final String? ref;

  bool get isUnauthorized => statusCode == 401;

  /// Short line. Raw exceptions stay in the database under [ref].
  String get shown {
    final base = _plain(message);
    if (ref == null || ref!.isEmpty) return base;
    return '$base Reference $ref.';
  }

  static String _plain(String message) {
    final m = message.trim();
    if (m.isEmpty || m.length > 180 || _raw.hasMatch(m)) {
      return 'Something went wrong. Try again.';
    }
    return m;
  }

  static final _raw = RegExp(
    r'Exception|Error:|stack trace|INVALID_|thought_signature|gel\.|sqlstate',
    caseSensitive: false,
  );

  @override
  String toString() => 'MaieApiException($statusCode, $code): $message';
}
