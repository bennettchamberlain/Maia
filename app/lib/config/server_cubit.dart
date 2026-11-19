import 'package:bloc/bloc.dart';
import 'package:flutter/foundation.dart';
import 'package:maie_app/config/app_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which maie-api the app talks to. Defaults to the build-time
/// [AppConfig.apiUrl]; the sign-in screen lets you point at a LAN address
/// (your Mac/Linux box from a phone) and remembers it.
class ServerCubit extends Cubit<String> {
  new({SharedPreferences? prefs, String? initial})
    : _prefs = prefs,
      super(initial ?? _initial(prefs));

  static String _initial(SharedPreferences? prefs) {
    return rewriteLoopback(prefs?.getString(_key) ?? AppConfig.apiUrl);
  }

  /// Phones cannot reach the Mac via localhost. A device build that
  /// passed `--dart-define=MAIE_API_URL=...` replaces loopback with that.
  static String rewriteLoopback(String url) {
    if (kIsWeb) return url;
    final parsed = Uri.tryParse(url.contains('://') ? url : 'http://$url');
    if (parsed == null) return AppConfig.apiUrl;
    if (parsed.host == 'localhost' || parsed.host == '127.0.0.1') {
      return AppConfig.apiUrl;
    }
    return url;
  }

  static const _key = 'maie.server_url';
  final SharedPreferences? _prefs;

  /// Parsed server, or the build-time default while the field is half-typed.
  Uri get uri => tryNormalise(state) ?? tryNormalise(AppConfig.apiUrl)!;

  Future<void> set(String url) async {
    final value = url.trim();
    if (value.isEmpty) return;
    emit(value);
    await _prefs?.setString(_key, value);
  }

  /// `192.168.1.5:8090` -> `http://192.168.1.5:8090/`; keeps a scheme if
  /// one is given; guarantees the trailing slash `Uri.resolve` needs.
  /// Null for a half-typed value such as `192.168.74.81:8:8090`.
  static Uri? tryNormalise(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return null;
    if (!s.contains('://')) s = 'http://$s';
    if (!s.endsWith('/')) s = '$s/';
    final uri = Uri.tryParse(s);
    if (uri == null || uri.host.isEmpty) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    return uri;
  }
}
