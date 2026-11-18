/// Error from scoria-api. `statusCode` is the HTTP status; `code` is the
/// machine-readable error the server returned, when it did.
class MaiaApiException implements Exception {
  const MaiaApiException(this.statusCode, this.message, {this.code});

  final int statusCode;
  final String message;
  final String? code;

  bool get isUnauthorized => statusCode == 401;

  @override
  String toString() => 'MaiaApiException($statusCode, $code): $message';
}
