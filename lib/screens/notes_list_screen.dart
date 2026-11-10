import 'package:flutter/material.dart';

import '../notes_store.dart';
import 'note_edit_screen.dart';
import 'settings_screen.dart';
import 'tag_manage_screen.dart';

String _two(int v) => v.toString().padLeft(2, '0');

String _fmtTime(DateTime d) => '${_two(d.hour)}:${_two(d.minute)}:${_two(d.second)}';

/// Dropbox の index.json に問題があるときの案内と、復旧のボタン
class _IndexProblemBanner extends StatefulWidget {
  final NotesStore store;
  final IndexProblem problem;
  const _IndexProblemBanner({required this.store, required this.problem});

  @override
  State<_IndexProblemBanner> createState() => _IndexProblemBannerState();
}

class _IndexProblemBannerState extends State<_IndexProblemBanner> {
  bool _busy = false;

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _rebuild() async {
    setState(() => _busy = true);
    try {
      final n = await widget.store.rebuildIndexFromFolder();
      _snack(n == 0
          ? 'Dropbox の notes フォルダに、追加できるノートはありませんでした'
          : '$n件のノートを、一覧に追加しました(タグ・ピン留めは戻りません)');
    } catch (e) {
      _snack('作り直しに失敗しました: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _restoreLocal() {
    final n = widget.store.restoreIndexFromLocal();
    _snack('この端末の$n件のノートで、一覧を作り直しています');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.tertiaryContainer,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.problem.message,
            style: TextStyle(fontSize: 13, color: scheme.onTertiaryContainer),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              if (widget.problem.localCopyAvailable)
                FilledButton.tonal(
                  onPressed: _busy ? null : _restoreLocal,
                  child: const Text('この端末の内容で作り直す'),
                ),
              OutlinedButton(
                onPressed: _busy ? null : _rebuild,
                child: const Text('Dropbox のノートから作り直す'),
              ),
            ],
          ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: LinearProgressIndicator(minHeight: 2),
            ),
        ],
      ),
    );
  }
}

/// 検索語に一致する部分を、背景色で目立たせたテキストにする(大文字小文字は区別しない)
Widget _hlText(
  String text,
  String query, {
  required Color hlColor,
  required Color hlTextColor,
  TextStyle? style,
  int maxLines = 1,
}) {
  final q = query.trim().toLowerCase();
  final lower = text.toLowerCase();
  if (q.isEmpty || lower.length != text.length) {
    return Text(text,
        maxLines: maxLines, overflow: TextOverflow.ellipsis, style: style);
  }
  final spans = <TextSpan>[];
  var i = 0;
  while (true) {
    final j = lower.indexOf(q, i);
    if (j < 0) {
      spans.add(TextSpan(text: text.substring(i)));
      break;
    }
    if (j > i) spans.add(TextSpan(text: text.substring(i, j)));
    spans.add(TextSpan(
      text: text.substring(j, j + q.length),
      style: TextStyle(backgroundColor: hlColor, color: hlTextColor),
    ));
    i = j + q.length;
  }
  return Text.rich(TextSpan(children: spans),
      maxLines: maxLines, overflow: TextOverflow.ellipsis, style: style);
}

/// 全文検索の対象が、まだ全部は揃っていないときに出す案内
class _FullTextBanner extends StatelessWidget {
  final bool syncing;
  const _FullTextBanner({required this.syncing});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.surfaceContainerHighest,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (syncing) const LinearProgressIndicator(minHeight: 2),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              syncing
                  ? '本文を読み込み中です。完了するまで、検索結果が足りないことがあります'
                  : '一部のノートの本文が未取得です(自動で再試行します)',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

/// 一覧に表示する対象(ドロワーで切り替える)
enum _View { all, trash, untagged, tag }

class NotesListScreen extends StatefulWidget {
  final NotesStore store;
  final Future<void> Function() onLogout;
  const NotesListScreen({super.key, required this.store, required this.onLogout});

  @override
  State<NotesListScreen> createState() => _NotesListScreenState();
}

class _NotesListScreenState extends State<NotesListScreen>
    with WidgetsBindingObserver {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _searchC = TextEditingController();

  _View _view = _View.all;
  String? _tag; // _view == tag のときの、タグのキー(小文字化したもの)
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchC.dispose();
    super.dispose();
  }

  // アプリに戻ってきたら、すぐ同期する
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      widget.store.refresh();
    } else {
      widget.store.saveLocalNow(); // 裏に回るときは、端末内への保存をすぐ済ませる
    }
  }

  // ── 操作 ─────────────────────────────────────────────────────
  void _create(List<String> initialTags) {
    final id = widget.store.createNote(tags: initialTags);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => NoteEditScreen(store: widget.store, id: id, isNew: true),
      ),
    );
  }

  void _select(_View v, {String? tag}) {
    setState(() {
      _view = v;
      _tag = tag;
    });
    _scaffoldKey.currentState?.closeDrawer();
  }

  void _openSearch() => setState(() => _searching = true);

  void _closeSearch() {
    _searchC.clear();
    setState(() => _searching = false);
  }

  Future<bool> _confirm(String title, String body) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: body.isEmpty ? null : Text(body),
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
    return ok == true;
  }

  void _openSettings() {
    _scaffoldKey.currentState?.closeDrawer();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          store: widget.store,
          onLogout: widget.onLogout,
        ),
      ),
    );
  }

  void _openTagManage() {
    _scaffoldKey.currentState?.closeDrawer();
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => TagManageScreen(store: widget.store)),
    );
  }

  // ── ドロワー ─────────────────────────────────────────────────
  Widget _drawerItem({
    IconData? icon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final fg = selected ? scheme.onSecondaryContainer : scheme.onSurface;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Material(
        color: selected ? scheme.secondaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(28),
        child: InkWell(
          borderRadius: BorderRadius.circular(28),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, color: fg),
                  const SizedBox(width: 16),
                ],
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: fg,
                      fontSize: 16,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _drawer(List<TagCount> tags, _View view, String? tagKey) {
    final scheme = Theme.of(context).colorScheme;
    return Drawer(
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            _drawerItem(
              icon: Icons.library_books_outlined,
              label: 'すべてのノート',
              selected: view == _View.all,
              onTap: () => _select(_View.all),
            ),
            _drawerItem(
              icon: Icons.delete_outline,
              label: 'ゴミ箱',
              selected: view == _View.trash,
              onTap: () => _select(_View.trash),
            ),
            _drawerItem(
              icon: Icons.settings_outlined,
              label: '設定',
              selected: false,
              onTap: _openSettings,
            ),
            const Divider(height: 24),
            Padding(
              padding: const EdgeInsets.only(left: 28, right: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'タグ',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ),
                  TextButton(
                    onPressed: _openTagManage,
                    child: const Text('編集'),
                  ),
                ],
              ),
            ),
            if (tags.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(28, 8, 12, 8),
                child: Text(
                  'タグはまだありません',
                  style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
                ),
              ),
            for (final t in tags)
              _drawerItem(
                label: t.label,
                selected: view == _View.tag && tagKey == t.key,
                onTap: () => _select(_View.tag, tag: t.key),
              ),
            const Divider(height: 24),
            _drawerItem(
              icon: Icons.label_off_outlined,
              label: 'タグがつけられていないメモ',
              selected: view == _View.untagged,
              onTap: () => _select(_View.untagged),
            ),
          ],
        ),
      ),
    );
  }

  // ── 画面 ─────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final tags = store.orderedTags(); // 並べ替えた順

        // 選んでいたタグが、もう使われていなければ「すべてのノート」に戻す
        var view = _view;
        String? tagKey = _tag;
        if (view == _View.tag && !tags.any((t) => t.key == tagKey)) {
          view = _View.all;
          tagKey = null;
        }
        final trash = view == _View.trash;
        final activeTag = view == _View.tag
            ? tags.firstWhere((t) => t.key == tagKey)
            : null;

        final notes = store.visibleNotes(
          trash: trash,
          query: _searchC.text,
          tag: activeTag?.key,
          untaggedOnly: view == _View.untagged,
        );

        final title = switch (view) {
          _View.all => 'すべてのノート',
          _View.trash => 'ゴミ箱',
          _View.untagged => 'タグがつけられていないメモ',
          _View.tag => activeTag!.label,
        };

        final scheme = Theme.of(context).colorScheme;
        final unsent =
            store.pendingCount > 0 ? '未送信の変更 ${store.pendingCount}件 / ' : '';
        final syncTip = unsent +
            (store.error ??
                (store.offline
                    ? 'オフライン(つながったら、自動で同期します)'
                    : store.lastSynced == null
                        ? '同期中…'
                        : '最終同期 ${_fmtTime(store.lastSynced!)}'));

        return PopScope(
          canPop: !_searching,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _closeSearch();
          },
          child: Scaffold(
            key: _scaffoldKey,
            drawer: _drawer(tags, view, tagKey),
            appBar: AppBar(
              leading: _searching
                  ? IconButton(
                      icon: const Icon(Icons.arrow_back),
                      onPressed: _closeSearch,
                    )
                  : IconButton(
                      tooltip: 'メニュー',
                      icon: const Icon(Icons.menu),
                      onPressed: () => _scaffoldKey.currentState?.openDrawer(),
                    ),
              title: _searching
                  ? TextField(
                      controller: _searchC,
                      autofocus: true,
                      decoration: const InputDecoration(
                        hintText: '検索(本文・タイトル・タグ)',
                        border: InputBorder.none,
                      ),
                      onChanged: (_) => setState(() {}),
                    )
                  : Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
              actions: [
                if (_searching) ...[
                  if (_searchC.text.isNotEmpty)
                    IconButton(
                      tooltip: 'クリア',
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        _searchC.clear();
                        setState(() {});
                      },
                    ),
                ] else ...[
                  if (trash && notes.isNotEmpty)
                    IconButton(
                      tooltip: 'ゴミ箱を空にする',
                      icon: const Icon(Icons.delete_sweep_outlined),
                      onPressed: () async {
                        if (await _confirm('ゴミ箱を空にしますか？', 'この操作は元に戻せません。') &&
                            mounted) {
                          store.emptyTrash();
                        }
                      },
                    ),
                  IconButton(
                    tooltip: syncTip,
                    icon: Icon((store.error != null || store.offline)
                        ? Icons.cloud_off
                        : Icons.cloud_done_outlined),
                    onPressed: () => store.refresh(force: true),
                  ),
                  IconButton(
                    tooltip: '検索',
                    icon: const Icon(Icons.search),
                    onPressed: _openSearch,
                  ),
                ],
              ],
            ),
            floatingActionButton: trash
                ? null
                : FloatingActionButton(
                    shape: const CircleBorder(),
                    onPressed: () => _create(
                      activeTag == null ? const <String>[] : [activeTag.label],
                    ),
                    child: const Icon(Icons.edit_square),
                  ),
            body: SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 800),
                  child: Column(
                    children: [
                      if (store.error != null)
                        Container(
                          width: double.infinity,
                          color: scheme.errorContainer,
                          padding: const EdgeInsets.all(8),
                          child: Text(
                            store.error!,
                            style: TextStyle(
                                color: scheme.onErrorContainer, fontSize: 12),
                          ),
                        ),
                      if (_searching &&
                          _searchC.text.trim().isNotEmpty &&
                          !store.fullTextReady)
                        _FullTextBanner(syncing: store.contentSyncing),
                      if (store.indexProblem != null)
                        _IndexProblemBanner(
                          store: store,
                          problem: store.indexProblem!,
                        ),
                      Expanded(
                        child: store.loading && notes.isEmpty
                            ? const Center(child: CircularProgressIndicator())
                            : RefreshIndicator(
                                onRefresh: () => store.refresh(force: true),
                                child: notes.isEmpty
                                    ? ListView(
                                        physics:
                                            const AlwaysScrollableScrollPhysics(),
                                        children: const [
                                          SizedBox(height: 120),
                                          Center(child: Text('ノートはありません')),
                                        ],
                                      )
                                    : ListView.builder(
                                        physics:
                                            const AlwaysScrollableScrollPhysics(),
                                        padding:
                                            const EdgeInsets.only(bottom: 88),
                                        itemCount: notes.length,
                                        itemBuilder: (context, i) {
                                          final n = notes[i];
                                          // 検索語が本文にだけあるときは、その前後を抜粋して表示する
                                          final q = _searchC.text.trim();
                                          final snippet = q.isEmpty
                                              ? null
                                              : store.bodySnippet(n.id, q);
                                          final subText = snippet ?? n.preview;
                                          final hasPreview = subText.isNotEmpty;
                                          return ListTile(
                                            contentPadding:
                                                const EdgeInsets.symmetric(
                                                    horizontal: 16, vertical: 6),
                                            isThreeLine: hasPreview,
                                            title: _hlText(
                                              n.title.isEmpty ? '(無題)' : n.title,
                                              q,
                                              hlColor: scheme.tertiaryContainer,
                                              hlTextColor: scheme.onTertiaryContainer,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .titleMedium
                                                  ?.copyWith(fontWeight: FontWeight.bold),
                                            ),
                                            subtitle: hasPreview
                                                ? _hlText(
                                                    subText,
                                                    q,
                                                    hlColor: scheme.tertiaryContainer,
                                                    hlTextColor: scheme.onTertiaryContainer,
                                                    maxLines: 2,
                                                  )
                                                : null,
                                            trailing: n.pinned
                                                ? const Icon(Icons.push_pin,
                                                    size: 18)
                                                : null,
                                            onTap: () => Navigator.push(
                                              context,
                                              MaterialPageRoute(
                                                builder: (_) => NoteEditScreen(
                                                  store: store,
                                                  id: n.id,
                                                  searchQuery: q, // 検索中なら、本文内の一致箇所を強調
                                                ),
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}