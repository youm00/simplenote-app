import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../backup_files.dart';
import '../backup_format.dart';
import '../dropbox_notes_service.dart';
import '../main.dart';
import '../notes_store.dart';
import '../simplenote_import.dart';

String _two(int v) => v.toString().padLeft(2, '0');

/// 「2026-11-13 10:45」の形
String _fmtDt(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${d.year}-${_two(d.month)}-${_two(d.day)} ${_two(d.hour)}:${_two(d.minute)}';
}

/// ファイルの大きさ(KB / MB)
String _fmtSize(int bytes) {
  if (bytes >= 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  return '${(bytes / 1024).round()} KB';
}

/// 設定画面。ドロワーの「設定」から開く。
/// テーマの選択、バックアップ(書き出し・読み込み、Dropbox への自動バックアップと復元)、
/// 本家 Simplenote からの取り込み、ログアウト。
class SettingsScreen extends StatefulWidget {
  final NotesStore store;
  final Future<void> Function() onLogout;
  const SettingsScreen({super.key, required this.store, required this.onLogout});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _busy = false; // バックアップの処理中

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

  // ── 読み込み(このアプリのバックアップ / 本家 Simplenote の書き出し / Dropbox のバックアップ 共通) ──
  /// ファイルを取得し([load]。省略すると、端末のファイル選択)、[parse] で BackupData に変換して、
  /// 確認ダイアログのあと、取り込む。
  Future<void> _importFile(
    BackupData Function(Uint8List bytes) parse, {
    required String title,
    Future<Uint8List?> Function()? load,
  }) async {
    setState(() => _busy = true);
    try {
      final bytes = await (load ?? pickBackupFile)();
      if (bytes == null) return; // キャンセル

      final BackupData data;
      try {
        data = parse(bytes);
      } on FormatException catch (e) {
        _snack('読み込めません: ${e.message}');
        return;
      }

      final preview = widget.store.previewBackup(data);
      if (!mounted) return;
      final overwrite = await showDialog<bool>(
        context: context,
        builder: (_) => _ImportDialog(title: title, preview: preview),
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

  Future<void> _import() => _importFile(
        (bytes) => parseBackup(utf8.decode(bytes)),
        title: 'バックアップを読み込む',
      );

  Future<void> _importSimplenote() => _importFile(
        parseSimplenoteExport,
        title: '本家 Simplenote から取り込む',
      );

  // ── Dropbox へのバックアップ・復元 ───────────────────────────
  Future<void> _backupNow() async {
    setState(() => _busy = true);
    try {
      final n = await widget.store.backupNow();
      _snack('$n件のノートを、Dropbox の backup フォルダに保存しました');
    } catch (e) {
      _snack('バックアップに失敗しました: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restoreFromDropbox() async {
    setState(() => _busy = true);
    List<BackupFileInfo>? files;
    try {
      files = await widget.store.listRemoteBackups();
    } catch (e) {
      _snack('バックアップの一覧を取得できませんでした: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (files == null || !mounted) return;
    if (files.isEmpty) {
      _snack('Dropbox の backup フォルダに、バックアップがありません');
      return;
    }

    final picked = await showDialog<BackupFileInfo>(
      context: context,
      builder: (_) => _BackupPickDialog(files: files!),
    );
    if (picked == null) return;

    await _importFile(
      (bytes) => parseBackup(utf8.decode(bytes)),
      title: 'Dropbox のバックアップから復元',
      load: () => widget.store.downloadRemoteBackup(picked.path),
    );
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
    final lastBackup = widget.store.lastBackupDate;
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
                  leading: const Icon(Icons.cloud_sync_outlined),
                  title: const Text('Dropbox への自動バックアップ'),
                  subtitle: Text(
                      '1日1回、同期のあとに、Dropbox の backup フォルダへ保存します(最大${NotesStore.backupKeep}件)。'
                      '最後のバックアップ: ${lastBackup ?? 'まだありません'}'),
                ),
                ListTile(
                  enabled: !_busy,
                  leading: const Icon(Icons.cloud_upload_outlined),
                  title: const Text('今すぐ Dropbox にバックアップ'),
                  subtitle: const Text('全ノート(ゴミ箱内も含む)を、いま保存します'),
                  onTap: _busy ? null : _backupNow,
                ),
                ListTile(
                  enabled: !_busy,
                  leading: const Icon(Icons.settings_backup_restore),
                  title: const Text('Dropbox のバックアップから復元'),
                  subtitle: const Text('backup フォルダのバックアップを選んで、ノートを戻します'),
                  onTap: _busy ? null : _restoreFromDropbox,
                ),
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
                _sectionTitle('取り込み'),
                ListTile(
                  enabled: !_busy,
                  leading: const Icon(Icons.move_to_inbox_outlined),
                  title: const Text('本家 Simplenote から取り込む'),
                  subtitle: const Text(
                      '本家で書き出した ZIP(または notes.json)を選びます。ピン留めとタグの並び順は、書き出しに入っていないため、戻りません'),
                  onTap: _busy ? null : _importSimplenote,
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

/// Dropbox のバックアップを選ぶダイアログ(新しい順)。選んだものを返す。
class _BackupPickDialog extends StatelessWidget {
  final List<BackupFileInfo> files;
  const _BackupPickDialog({required this.files});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('復元するバックアップ(新しい順)'),
      content: SizedBox(
        width: 360,
        height: 420,
        child: ListView.builder(
          itemCount: files.length,
          itemBuilder: (context, i) {
            final f = files[i];
            return ListTile(
              dense: true,
              title: Text(_fmtDt(f.modifiedMs)),
              subtitle: Text(_fmtSize(f.size)),
              onTap: () => Navigator.pop(context, f),
            );
          },
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('キャンセル')),
      ],
    );
  }
}

/// 読み込み前の確認ダイアログ。
/// 結果: null=キャンセル、false=追加だけ(いまのノートは変更しない)、true=ファイルの内容で上書き
class _ImportDialog extends StatelessWidget {
  final String title;
  final BackupPreview preview;
  const _ImportDialog({required this.title, required this.preview});

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
      title: Text(title),
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
              Text('「上書き」: 同じノートも、ファイルの内容(本文・タグ・ピン・ゴミ箱)に戻します。',
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