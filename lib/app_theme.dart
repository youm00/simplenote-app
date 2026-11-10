// app_theme.dart
// アプリのテーマ(ライト / ダーク / ダークブルー)の定義と、選んだテーマの保存。
//
// ダークブルーの色を調整したいときは、_darkBlueScheme() の中の色だけを変える。
//   背景    #15202B (X のダークテーマに近い濃紺)
//   文字    #E7EEF5 (淡い青みがかった白)、補助の文字 #8B98A5
//   アクセント #1D9BF0 (X の青)
//
// SharedPreferences のキーは、ほかのアプリと混ざらないよう "sn_" を付ける。
// 以前の「ダークモードのオン/オフ」(sn_dark_mode)は、sn_theme が無いときだけ、引き継ぐ。

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppThemeKind { light, dark, darkBlue }

extension AppThemeKindInfo on AppThemeKind {
  String get label => switch (this) {
        AppThemeKind.light => 'ライト',
        AppThemeKind.dark => 'ダーク',
        AppThemeKind.darkBlue => 'ダークブルー',
      };

  /// 設定画面のプレビュー用(背景色, アクセント色)
  (Color, Color) get preview => switch (this) {
        AppThemeKind.light => (const Color(0xFFFFFBFE), const Color(0xFF5C6BC0)),
        AppThemeKind.dark => (const Color(0xFF121318), const Color(0xFFB8C3FF)),
        AppThemeKind.darkBlue => (const Color(0xFF15202B), const Color(0xFF1D9BF0)),
      };
}

const _prefKey = 'sn_theme';
const _oldDarkKey = 'sn_dark_mode';
const _seed = Color(0xFF5C6BC0);

/// 保存してあるテーマを読む。無ければ、以前のダークモード設定を引き継ぐ(それも無ければ、ダーク)。
AppThemeKind loadThemeKind(SharedPreferences prefs) {
  final saved = prefs.getString(_prefKey);
  for (final k in AppThemeKind.values) {
    if (k.name == saved) return k;
  }
  return (prefs.getBool(_oldDarkKey) ?? true)
      ? AppThemeKind.dark
      : AppThemeKind.light;
}

Future<void> saveThemeKind(AppThemeKind k) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_prefKey, k.name);
}

ThemeData buildTheme(AppThemeKind kind) {
  switch (kind) {
    case AppThemeKind.light:
      return ThemeData(
        colorScheme: ColorScheme.fromSeed(
            seedColor: _seed, brightness: Brightness.light),
        useMaterial3: true,
      );
    case AppThemeKind.dark:
      return ThemeData(
        colorScheme:
            ColorScheme.fromSeed(seedColor: _seed, brightness: Brightness.dark),
        useMaterial3: true,
      );
    case AppThemeKind.darkBlue:
      final scheme = _darkBlueScheme();
      return ThemeData(
        colorScheme: scheme,
        useMaterial3: true,
        scaffoldBackgroundColor: scheme.surface,
        // 新規ボタンは、アクセントの青をそのまま使う
        floatingActionButtonTheme: FloatingActionButtonThemeData(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
        ),
        dividerColor: scheme.outlineVariant,
      );
  }
}

ColorScheme _darkBlueScheme() {
  const bg = Color(0xFF15202B);
  const accent = Color(0xFF1D9BF0);
  return ColorScheme.fromSeed(seedColor: accent, brightness: Brightness.dark)
      .copyWith(
    // アクセント
    primary: accent,
    onPrimary: Colors.white,
    primaryContainer: const Color(0xFF1A4565),
    onPrimaryContainer: const Color(0xFFD6ECFC),
    secondary: const Color(0xFF8BBFE6),
    onSecondary: bg,
    // ドロワーで選んでいる項目の背景
    secondaryContainer: const Color(0xFF22384C),
    onSecondaryContainer: const Color(0xFFE7F3FD),
    // 検索で一致した部分の強調(青い背景の上でも目立つように、琥珀色)
    tertiary: const Color(0xFFE8C45A),
    onTertiary: bg,
    tertiaryContainer: const Color(0xFF5C4B14),
    onTertiaryContainer: const Color(0xFFFFE9A8),
    // 背景と文字
    surface: bg,
    onSurface: const Color(0xFFE7EEF5),
    onSurfaceVariant: const Color(0xFF8B98A5),
    surfaceDim: const Color(0xFF111A23),
    surfaceBright: const Color(0xFF2A3743),
    surfaceContainerLowest: const Color(0xFF111A23),
    surfaceContainerLow: const Color(0xFF192633), // ドロワーの背景
    surfaceContainer: const Color(0xFF1C2937),
    surfaceContainerHigh: const Color(0xFF223140),
    surfaceContainerHighest: const Color(0xFF2A3A4A), // 検索の案内バーなど
    // 線
    outline: const Color(0xFF4A5A69),
    outlineVariant: const Color(0xFF2F3E4C),
    // スクロール時に、上部バーが色づかないようにする
    surfaceTint: Colors.transparent,
  );
}