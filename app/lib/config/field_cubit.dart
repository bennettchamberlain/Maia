import 'package:bloc/bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Whether the point-cloud mark plays behind the app.
class FieldCubit extends Cubit<bool> {
  new({SharedPreferences? prefs, bool? initial})
    : _prefs = prefs,
      super(initial ?? prefs?.getBool(_key) ?? false);

  static const _key = 'maie.field_background';
  final SharedPreferences? _prefs;

  Future<void> setOn(bool value) async {
    emit(value);
    await _prefs?.setBool(_key, value);
  }
}
