import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Light or dark: follow the phone (the default), or always one of them.
/// Remembered across launches, and read before the first frame so the app
/// never flashes the other theme.
final appearance = ValueNotifier<ThemeMode>(ThemeMode.system);

const _key = 'theme_mode';

Future<void> loadAppearance() async {
  try {
    final saved = (await SharedPreferences.getInstance()).getString(_key);
    for (final m in ThemeMode.values) {
      if (m.name == saved) appearance.value = m;
    }
  } catch (_) {
    // No storage (a test, a broken plugin): keep following the phone.
  }
}

/// Applies [next] at once and remembers it.
Future<void> setAppearance(ThemeMode next) async {
  appearance.value = next;
  try {
    await (await SharedPreferences.getInstance()).setString(_key, next.name);
  } catch (_) {}
}
