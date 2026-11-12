import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../notes_store.dart';
import 'note_edit_screen.dart';
import 'settings_screen.dart';
import 'tag_manage_screen.dart';

// ── 広い画面(2列表示)の設定 ─────────────────────────────────
/// この幅(論理ピクセル)以上のとき、ノート一覧と編集を横に並べる
const double _wideBreakpoint = 1000;

/// 左のノート一覧の幅の初期値(境の線をドラッグして変えられる)
const double _listPaneDefaultWidth = 360;

/// 左のノート一覧の幅の下限と、編集側に最低限残す幅
const double _listPaneMinWidth = 240;
const double _editorPaneMinWidth = 400;

/// 一覧の幅を保存する SharedPreferences のキー
const String _listWidthKey = 'sn_list_width';

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

/// 一覧と編集の境の線。マウスで左右にドラッグして、一覧の幅を変えられる。
/// 見える線は1pxだが、つかみやすいように、操作できる範囲は左右に広げてある。
class _PaneDivider extends StatefulWidget {
  final void Function(double dx) onDrag;
  final VoidCallback onDragEnd;
  const _PaneDivider({required this.onDrag, required this.onDragEnd});

  @override
  State<_PaneDivider> createState() => _PaneDividerState();
}

class _PaneDividerState extends State<_PaneDivider> {
  bool _hover = false;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = _hover || _dragging;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) => setState(() => _dragging = true),
        onHorizontalDragUpdate: (d) => widget.onDrag(d.delta.dx),
        onHorizontalDragEnd: (_) {
          setState(() => _dragging = false);
          widget.onDragEnd();
        },
        onHorizontalDragCancel: () {
          setState(() => _dragging = false);
          widget.onDragEnd();
        },
        child: SizedBox(
          width: 9, // つかめる範囲
          child: Center(
            child: Container(
              // 触れている間・ドラッグ中は、線を太く、アクセント色にする
              width: active ? 3 : 1,
              color: active ? scheme.primary : scheme.outlineVariant,
            ),
          ),
        ),
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
  final _scaffoldKey = GlobalKey<ScaffoldState>(); // ドロワーを開閉するための、外側の Scaffold
  final _searchC = TextEditingController();

  _View _view = _View.all;
  String? _tag; // _view == tag のときの、タグのキー(小文字化したもの)
  bool _searching = false; // 狭い画面での、検索欄の表示(広い画面では、検索欄は常に出る)

  // 広い画面で、右側に開いているノート
  String? _openId;
  bool _openNew = false;
  String _openQuery = ''; // 検索結果から開いたときの検索語(本文内の強調に使う)

  // 広い画面での、一覧の幅(境の線をドラッグして変える。端末に保存する)
  double _listWidth = _listPaneDefaultWidth;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadListWidth();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchC.dispose();
    super.dispose();
  }

  // ── 一覧の幅の保存 ───────────────────────────────────────────
  Future<void> _loadListWidth() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final w = prefs.getDouble(_listWidthKey);
      if (w != null && mounted) {
        setState(() => _listWidth = w < _listPaneMinWidth ? _listPaneMinWidth : w);
      }
    } catch (_) {
      // 読めなければ、初期値のまま
    }
  }

  Future<void> _saveListWidth() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_listWidthKey, _listWidth);
    } catch (_) {
      // 保存できなくても、動作は止めない
    }
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

  /// ノートを開く。広い画面では右側の編集部分に出し、狭い画面では編集画面を重ねる。
  void _openNote(
    String id, {
    required bool wide,
    bool isNew = false,
    String query = '',
  }) {
    if (wide) {
      setState(() {
        _openId = id;
        _openNew = isNew;
        _openQuery = query;
      });
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => NoteEditScreen(
            store: widget.store,
            id: id,
            isNew: isNew,
            searchQuery: query,
          ),
        ),
      );
    }
  }

  void _create(List<String> initialTags, {required bool wide}) {
    final id = widget.store.createNote(tags: initialTags);
    _openNote(id, wide: wide, isNew: true);
  }

  /// 広い画面で、右側の編集部分を閉じる(ゴミ箱へ・復元・完全削除のあと)
  void _closeEditor() {
    if (!mounted) return;
    setState(() {
      _openId = null;
      _openNew = false;
      _openQuery = '';
    });
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

  Widget _drawerList(List<TagCount> tags, _View view, String? tagKey) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
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
    );
  }

  /// 広い画面で、一覧の上に常に出す検索欄
  Widget _wideSearchField() {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: TextField(
        controller: _searchC,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          hintText: '検索(本文・タイトル・タグ)',
          isDense: true,
          filled: true,
          fillColor: scheme.surfaceContainerHighest,
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _searchC.text.isEmpty
              ? null
              : IconButton(
                  tooltip: 'クリア',
                  icon: const Icon(Icons.close),
                  onPressed: () {
                    _searchC.clear();
                    setState(() {});
                  },
                ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(24),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  // ── 画面 ─────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= _wideBreakpoint;

        // 一覧の幅: 下限と「編集側に残す幅」の範囲に収める(ウィンドウを狭めたときも、はみ出さない)
        final maxListWidth = (constraints.maxWidth - _editorPaneMinWidth)
            .clamp(_listPaneMinWidth, double.infinity)
            .toDouble();
        final listWidth =
            _listWidth.clamp(_listPaneMinWidth, maxListWidth).toDouble();

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

            // 広い画面では、検索欄が常に出る。狭い画面では、検索欄を開いているときだけ。
            final query = (wide || _searching) ? _searchC.text : '';
            final q = query.trim();

            final notes = store.visibleNotes(
              trash: trash,
              query: query,
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
            final unsent = store.pendingCount > 0
                ? '未送信の変更 ${store.pendingCount}件 / '
                : '';
            final syncTip = unsent +
                (store.error ??
                    (store.offline
                        ? 'オフライン(つながったら、自動で同期します)'
                        : store.lastSynced == null
                            ? '同期中…'
                            : '最終同期 ${_fmtTime(store.lastSynced!)}'));

            // 広い画面で開いているノートが、もう無いとき(ほかの端末で削除された、など)は、閉じる
            final openId = _openId;
            if (wide &&
                openId != null &&
                !_openNew &&
                store.metaOf(openId) == null) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted && _openId == openId) _closeEditor();
              });
            }

            // ── 一覧の上部バー ──
            final emptyTrashButton = (trash && notes.isNotEmpty)
                ? IconButton(
                    tooltip: 'ゴミ箱を空にする',
                    icon: const Icon(Icons.delete_sweep_outlined),
                    onPressed: () async {
                      if (await _confirm('ゴミ箱を空にしますか？', 'この操作は元に戻せません。') &&
                          mounted) {
                        store.emptyTrash();
                      }
                    },
                  )
                : null;
            final syncButton = IconButton(
              tooltip: syncTip,
              icon: Icon((store.error != null || store.offline)
                  ? Icons.cloud_off
                  : Icons.cloud_done_outlined),
              onPressed: () => store.refresh(force: true),
            );

            final searchingNarrow = !wide && _searching;

            final appBar = AppBar(
              automaticallyImplyLeading: false,
              leading: searchingNarrow
                  ? IconButton(
                      icon: const Icon(Icons.arrow_back),
                      onPressed: _closeSearch,
                    )
                  : IconButton(
                      tooltip: 'メニュー',
                      icon: const Icon(Icons.menu),
                      onPressed: () => _scaffoldKey.currentState?.openDrawer(),
                    ),
              title: searchingNarrow
                  ? TextField(
                      controller: _searchC,
                      autofocus: true,
                      decoration: const InputDecoration(
                        hintText: '検索(本文・タイトル・タグ)',
                        border: InputBorder.none,
                      ),
                      onChanged: (_) => setState(() {}),
                    )
                  // タイトルの右に、いま表示している一覧の件数を出す
                  : Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          '${notes.length}',
                          style: TextStyle(
                            fontSize: 16,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
              actions: [
                if (searchingNarrow) ...[
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
                  if (emptyTrashButton != null) emptyTrashButton,
                  syncButton,
                  if (wide)
                    IconButton(
                      tooltip: '新規ノート',
                      icon: const Icon(Icons.edit_square),
                      onPressed: trash
                          ? null
                          : () => _create(
                                activeTag == null
                                    ? const <String>[]
                                    : [activeTag.label],
                                wide: true,
                              ),
                    )
                  else
                    IconButton(
                      tooltip: '検索',
                      icon: const Icon(Icons.search),
                      onPressed: _openSearch,
                    ),
                ],
              ],
            );

            // ── 一覧の本体 ──
            final listBody = Column(
              children: [
                if (wide) _wideSearchField(),
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
                if (q.isNotEmpty && !store.fullTextReady)
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
                                  physics: const AlwaysScrollableScrollPhysics(),
                                  children: const [
                                    SizedBox(height: 120),
                                    Center(child: Text('ノートはありません')),
                                  ],
                                )
                              : ListView.builder(
                                  physics: const AlwaysScrollableScrollPhysics(),
                                  padding: const EdgeInsets.only(bottom: 88),
                                  itemCount: notes.length,
                                  itemBuilder: (context, i) {
                                    final n = notes[i];
                                    // 検索語が本文にだけあるときは、その前後を抜粋して表示する
                                    final snippet = q.isEmpty
                                        ? null
                                        : store.bodySnippet(n.id, q);
                                    final subText = snippet ?? n.preview;
                                    final hasPreview = subText.isNotEmpty;
                                    final isOpen = wide && n.id == _openId;
                                    return ListTile(
                                      tileColor: isOpen
                                          ? scheme.secondaryContainer
                                          : null,
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                              horizontal: 16, vertical: 6),
                                      isThreeLine: hasPreview,
                                      title: _hlText(
                                        n.title.isEmpty ? '(無題)' : n.title,
                                        q,
                                        hlColor: scheme.tertiaryContainer,
                                        hlTextColor:
                                            scheme.onTertiaryContainer,
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleMedium
                                            ?.copyWith(
                                                fontWeight: FontWeight.bold),
                                      ),
                                      subtitle: hasPreview
                                          ? _hlText(
                                              subText,
                                              q,
                                              hlColor: scheme.tertiaryContainer,
                                              hlTextColor:
                                                  scheme.onTertiaryContainer,
                                              maxLines: 2,
                                            )
                                          : null,
                                      trailing: n.pinned
                                          ? const Icon(Icons.push_pin, size: 18)
                                          : null,
                                      // 検索中なら、本文内の一致箇所を強調する
                                      onTap: () => _openNote(
                                        n.id,
                                        wide: wide,
                                        query: q,
                                      ),
                                    );
                                  },
                                ),
                        ),
                ),
              ],
            );

            // ── 一覧(狭い画面では新規ボタンつき) ──
            final listScaffold = Scaffold(
              appBar: appBar,
              floatingActionButton: (wide || trash)
                  ? null
                  : FloatingActionButton(
                      shape: const CircleBorder(),
                      onPressed: () => _create(
                        activeTag == null
                            ? const <String>[]
                            : [activeTag.label],
                        wide: false,
                      ),
                      child: const Icon(Icons.edit_square),
                    ),
              body: wide
                  ? SafeArea(child: listBody)
                  : SafeArea(
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 800),
                          child: listBody,
                        ),
                      ),
                    ),
            );

            // ── 広い画面: 一覧 | 編集 ──
            Widget content = listScaffold;
            if (wide) {
              final editorPane = openId == null
                  ? Scaffold(
                      appBar: AppBar(automaticallyImplyLeading: false),
                      body: Center(
                        child: Text(
                          'ノートを選択してください',
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      ),
                    )
                  : NoteEditScreen(
                      // ノートを切り替えたときは、編集画面を作り直す(前のノートは、そのとき保存される)
                      key: ValueKey('$openId|$_openQuery'),
                      store: store,
                      id: openId,
                      isNew: _openNew,
                      searchQuery: _openQuery,
                      embedded: true,
                      onClose: _closeEditor,
                    );
              content = Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(width: listWidth, child: listScaffold),
                  // 境の線: 左右にドラッグして、一覧の幅を変える
                  _PaneDivider(
                    onDrag: (dx) => setState(() {
                      _listWidth = (listWidth + dx)
                          .clamp(_listPaneMinWidth, maxListWidth)
                          .toDouble();
                    }),
                    onDragEnd: _saveListWidth,
                  ),
                  Expanded(child: editorPane),
                ],
              );
            }

            // ドロワーは、外側の Scaffold に持たせる(ハンバーガーで開くと、一覧と編集の上に重なる)
            return PopScope(
              canPop: !searchingNarrow,
              onPopInvokedWithResult: (didPop, _) {
                if (!didPop) _closeSearch();
              },
              child: Scaffold(
                key: _scaffoldKey,
                drawer: Drawer(
                  child: SafeArea(child: _drawerList(tags, view, tagKey)),
                ),
                body: content,
              ),
            );
          },
        );
      },
    );
  }
}