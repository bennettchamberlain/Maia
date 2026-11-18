/// Build-time configuration. Override with
/// `flutter run --dart-define=MAIA_API_URL=http://host:8090`.
abstract final class AppConfig {
  static const apiUrl = String.fromEnvironment(
    'MAIA_API_URL',
    defaultValue: 'http://100.86.127.113:8090',
  );

  /// The account this build signs in as on launch.
  static const handle = 'maia';
  static const password = 'maia-admin';

  /// You.com Web Search key. Pass `--dart-define=YDC_API_KEY=...`.
  static const ydcApiKey = String.fromEnvironment('YDC_API_KEY');
}
