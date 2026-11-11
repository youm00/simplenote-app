import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../backup_files.dart';
import '../backup_format.dart';
import '../main.dart';
import '../notes_store.dart';

/// 設定画面。ドロワーの「設定」から開く。
/// テーマの選択、バックアップ(書き出し・読み込み)、ログアウト。
class SettingsScreen extends StatefulWidget {
  final NotesStore store;
  final Future<void> Function() onLogout;
  const SettingsScreen({super.key, required this.store, required this.onLogout});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _busy = false; // バックアップの処理中

  String _two(int v) => v.toString().padLeft(2, '0');

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  // ── バックアップの書き出し ───────────────────────────────────
  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      // 全ノートの本文をそろえてから、ファイルの内容を作る
      final data = await widget.store.buildBackup();
      final json = encodeBackup(data);
      final d = DateTime.now();
      final name = 'simplenote_backup_${d.year}${_two(d.month)}${_two(d.day)}'
          '_${_two(d.hour)}${_two(d.minute)}${_two(d.second)}.json';
      final saved =
          await saveBackupFile(name, Uint8List.fromList(utf8.encode(json)));
      if (!saved) {
        _snack('保存をキャンセルしました');
      } else {
        _snack('${data.notes.length}件のノートを書き出しました');
      }
    } catch (e) {
      _snack('書き出しに失敗しました: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── バックアップの読み込み ───────────────────────────────────
  Future<void> _import() async {
    setState(() => _busy = true);
    try {
      final bytes = await pickBackupFile();
      if (bytes == null) return; // キャンセル

      final BackupData data;
      try {
        data = parseBackup(utf8.decode(bytes));
      } on FormatException catch (e) {
        _snack('読み込めません: ${e.message}');
        return;
      }

      final preview = widget.store.previewBackup(data);
      if (!mounted) return;
      final overwrite = await showDialog<bool>(
        context: context,
        builder: (_) => _ImportDialog(preview: preview),
      );
      if (overwrite == null) return; // キャンセル

      final n = widget.store.importBackup(data, overwrite: overwrite);
      _snack(n == 0 ? '取り込むノートはありませんでした' : '$n件のノートを読み込みました');
    } catch (e) {
      _snack('読み込みに失敗しました: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── 一覧の作り直し ───────────────────────────────────────────
  Future<void> _rebuildIndex() async {
    setState(() => _busy = true);
    try {
      final n = await widget.store.rebuildIndexFromFolder();
      _snack(n == 0
          ? '一覧に無いノートは、見つかりませんでした'
          : '$n件のノートを、一覧に追加しました(タグ・ピン留めは戻りません)');
    } catch (e) {
      _snack('作り直しに失敗しました: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── ログアウト ───────────────────────────────────────────────
  Future<void> _logout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ログアウトしますか？'),
        content: Text(
          widget.store.hasPending
              ? '未送信の変更が${widget.store.pendingCount}件あります。ログアウトすると、その変更も消えます。'
                  '(端末内に保存したノートのコピーも消えます。Dropbox 上のノートは消えません)'
              : '端末内に保存したノートのコピーは消えます。Dropbox 上のノートは消えません。',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('キャンセル')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('OK')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    // ログアウトで画面が差し替わるので、先にこの設定画面を閉じておく
    final onLogout = widget.onLogout;
    Navigator.pop(context);
    await onLogout();
  }

  // ── 画面 ─────────────────────────────────────────────────────
  Widget _sectionTitle(String text) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(text, style: TextStyle(color: scheme.onSurfaceVariant)),
    );
  }

  /// テーマの1項目。左に、背景色とアクセント色のプレビューを出す。
  Widget _themeTile(AppThemeKind kind, AppThemeKind current) {
    final scheme = Theme.of(context).colorScheme;
    final (bg, accent) = kind.preview;
    final selected = kind == current;
    return ListTile(
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: bg,
          shape: BoxShape.circle,
          border: Border.all(color: scheme.outline),
        ),
        alignment: Alignment.center,
        child: Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
        ),
      ),
      title: Text(kind.label),
      trailing: selected ? Icon(Icons.check, color: scheme.primary) : null,
      onTap: () async {
        await NotesApp.of(context).setTheme(kind);
        if (mounted) setState(() {});
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final current = NotesApp.of(context).themeKind;
    return Scaffold(
      appBar: AppBar(
        title: const Text('設定'),
        bottom: _busy
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 800),
            child: ListView(
              children: [
                _sectionTitle('テーマ'),
                for (final k in AppThemeKind.values) _themeTile(k, current),
                const Divider(height: 24),
                _sectionTitle('バックアップ'),
                ListTile(
                  enabled: !_busy,
                  leading: const Icon(Icons.file_download_outlined),
                  title: const Text('バックアップを書き出す'),
                  subtitle: const Text('全ノート(ゴミ箱内も含む)を、1つのファイルに保存します'),
                  onTap: _busy ? null : _export,
                ),
                ListTile(
                  enabled: !_busy,
                  leading: const Icon(Icons.file_upload_outlined),
                  title: const Text('バックアップを読み込む'),
                  subtitle: const Text('書き出したファイルから、ノートを戻します'),
                  onTap: _busy ? null : _import,
                ),
                ListTile(
                  enabled: !_busy,
                  leading: const Icon(Icons.build_outlined),
                  title: const Text('Dropbox のノートから一覧を作り直す'),
                  subtitle: const Text(
                      '一覧(index.json)が壊れた・消えたときに使います。一覧に無いノートだけを追加します'),
                  onTap: _busy ? null : _rebuildIndex,
                ),
                const Divider(height: 24),
                ListTile(
                  leading: const Icon(Icons.logout),
                  title: const Text('ログアウト'),
                  onTap: _logout,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 読み込み前の確認ダイアログ。
/// 結果: null=キャンセル、false=追加だけ(いまのノートは変更しない)、true=バックアップの内容で上書き
class _ImportDialog extends StatelessWidget {
  final BackupPreview preview;
  const _ImportDialog({required this.preview});

  @override
  Widget build(BuildContext context) {
    final p = preview;
    final scheme = Theme.of(context).colorScheme;
    final small = TextStyle(fontSize: 13, color: scheme.onSurfaceVariant);

    final lines = <String>[
      'ファイルのノート: ${p.total}件(ゴミ箱内 ${p.trashed}件)',
      '新しく追加されるノート: ${p.added}件',
      if (p.same > 0) 'いまと同じノート: ${p.same}件(うち、内容や状態が違うもの ${p.changed}件)',
      if (p.invalid > 0) '取り込めないノート: ${p.invalid}件(読み取れない形式)',
    ];

    final nothing = p.added == 0 && p.same == 0;
    return AlertDialog(
      title: const Text('バックアップを読み込む'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final l in lines)
              Padding(padding: const EdgeInsets.only(bottom: 4), child: Text(l)),
            if (p.same > 0) ...[
              const SizedBox(height: 12),
              Text('「追加だけ」: いまのノートは変更せず、足りないノートだけを戻します。', style: small),
              const SizedBox(height: 4),
              Text('「上書き」: 同じノートも、バックアップの内容(本文・タグ・ピン・ゴミ箱)に戻します。',
                  style: small),
            ],
          ],
        ),
      ),
      actions: nothing
          ? [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('閉じる')),
            ]
          : [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('キャンセル')),
              if (p.same > 0) ...[
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('追加だけ')),
                TextButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('上書き')),
              ] else
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('読み込む')),
            ],
    );
  }
}
