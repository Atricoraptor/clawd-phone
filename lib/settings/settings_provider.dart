import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class AppSettings {
  final String model;
  final ThemeMode themeMode;
  final double fontSize;

  const AppSettings({
    this.model = 'claude-haiku-4-5-20251001',
    this.themeMode = ThemeMode.system,
    this.fontSize = 14.0,
  });

  AppSettings copyWith({
    String? model,
    ThemeMode? themeMode,
    double? fontSize,
  }) =>
      AppSettings(
        model: model ?? this.model,
        themeMode: themeMode ?? this.themeMode,
        fontSize: fontSize ?? this.fontSize,
      );
}

class SettingsNotifier extends StateNotifier<AppSettings> {
  static const _storage = FlutterSecureStorage();

  SettingsNotifier() : super(const AppSettings()) {
    _load();
  }

  Future<void> _load() async {
    final model =
        await _storage.read(key: 'model') ?? 'claude-haiku-4-5-20251001';
    final themeName = await _storage.read(key: 'theme') ?? 'system';
    final fontSize =
        double.tryParse(await _storage.read(key: 'fontSize') ?? '14') ?? 14.0;

    state = AppSettings(
      model: model,
      themeMode: _parseTheme(themeName),
      fontSize: fontSize,
    );
  }

  Future<void> setModel(String model) async {
    await _storage.write(key: 'model', value: model);
    state = state.copyWith(model: model);
  }

  Future<void> setTheme(ThemeMode mode) async {
    await _storage.write(key: 'theme', value: mode.name);
    state = state.copyWith(themeMode: mode);
  }

  Future<void> setFontSize(double size) async {
    await _storage.write(key: 'fontSize', value: size.toString());
    state = state.copyWith(fontSize: size);
  }

  ThemeMode _parseTheme(String name) => switch (name) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
}

final settingsProvider =
    StateNotifierProvider<SettingsNotifier, AppSettings>(
  (ref) => SettingsNotifier(),
);

/// Model options shown in settings.
const availableModels = [
  ('claude-haiku-4-5-20251001', 'Haiku 4.5', 'Fastest', ''),
  ('claude-sonnet-4-6', 'Sonnet 4.6', 'Balanced', ''),
  ('claude-opus-4-6', 'Opus 4.6', 'Best results', ''),
];
