import 'dart:async';

import 'package:flutter/material.dart';

import '../dropbox_notes_service.dart';
import '../notes_store.dart';

String _two(int v) => v.toString().padLeft(2, '0');

/// 「2026年11月11日 19:48」の形。日時が不明(0 以下)のときは「—」。
String _fmtDateTime(int ms) {
  if (ms <= 0) return '—';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${d.year}年${d.month}月${d.day}日 ${_two(d.hour)}:${_two(d.minute)}';
}

class NoteEditScreen extends StatefulWidget {
  final NotesStore store;
  final String id;
  final bool isNew;

  /// 検索結果から開いたときの検索語。本文の中で一致した部分を強調し、最初の一致箇所まで移動する。
  final String searchQuery;

  /// 広い画面で、右側の編集部分として埋め込むとき true。
  /// 戻るボタンは出さず、ゴミ箱へ・復元・完全削除のあとは [onClose] を呼ぶ(画面を閉じる代わり)。
  /// 埋め込みのときは、タグの行を、本文の上ではなく、上部バーに出す。
  final bool embedded;
  final VoidCallback? onClose;

  /// 埋め込みのとき、上部バーの左端に出すウィジェット(一覧の表示/非表示のボタン)
  final Widget? leading;

  const NoteEditScreen({
    super.key,
    required this.store,
    required this.id,
    this.isNew = false,
    this.searchQuery = '',
    this.embedded = false,
    this.onClose,
    this.leading,
  });

  @override
  State<NoteEditScreen> createState() => _NoteEditScreenState();
}

class _NoteEditScreenState extends State<NoteEditScreen>
    with WidgetsBindingObserver {
  final _c = _HighlightController();
  final _scroll = ScrollController();
  Timer? _timer;
  bool _loaded = false;
  bool _dirty = false;
  String? _loadError;

  // 本文内検索(検索結果から開いたとき)
  String _query = ''; // 強調する検索語。空なら、強調も案内バーも出さない
  int _cur = 0; // いま選んでいる一致箇所(0始まり)
  // 一致箇所へのスクロール位置の計算に使う、本文欄の大きさと文字スタイル
  double _fieldW = 0;
  double _fieldH = 0;
  TextStyle? _fieldStyle;
  TextScaler _textScaler = TextScaler.noScaling;

  @override
  void initState() {
    super.initState();
    _query = widget.searchQuery.trim();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  Future<void> _load() async {
    try {
      final t = await widget.store.loadContent(widget.id);
      if (!mounted) return;
      _c.text = t;
      _c.setHighlight(_query, 0);
      setState(() {
        _loaded = true;
        _loadError = null;
      });
      // 本文欄が表示されて、大きさが決まったあとで、最初の一致箇所へ移動する
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _jumpToFirstMatch();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadError = '$e');
    }
  }

  // 入力が止まって 1.2 秒後に保存
  void _onChanged(String _) {
    _dirty = true;
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 1200), _flush);
  }

  void _flush() {
    _timer?.cancel();
    if (!_dirty) return;
    _dirty = false;
    widget.store.saveContent(widget.id, _c.text);
  }

  // アプリがバックグラウンドへ行くときは、すぐ保存
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _flush();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    if (_loaded) {
      final store = widget.store;
      final id = widget.id;
      final text = _c.text;
      final dirty = _dirty;
      final meta = store.metaOf(id);
      // dispose 中は widget tree がロックされているため、通知を伴う処理は後回しにする
      if (text.trim().isEmpty) {
        // 空になったノートはゴミ箱へ(新規で一度も保存していないものは何もしない)
        if (meta != null && !meta.deleted) {
          Future.microtask(() => store.setDeleted(id, true));
        }
      } else if (dirty) {
        Future.microtask(() => store.saveContent(id, text));
      }
    }
    _c.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ── 操作 ─────────────────────────────────────────────────────

  /// 編集を終える。全画面のときは画面を閉じ、埋め込みのときは、親に閉じてもらう。
  void _close() {
    if (widget.embedded) {
      widget.onClose?.call();
    } else {
      Navigator.pop(context);
    }
  }

  void _toTrash() {
    _flush();
    widget.store.setDeleted(widget.id, true);
    _close();
  }

  void _restore() {
    widget.store.setDeleted(widget.id, false);
    _close();
  }

  Future<void> _deleteForever() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('完全に削除しますか？'),
        content: const Text('この操作は元に戻せません。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('キャンセル')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('削除')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    _timer?.cancel();
    _dirty = false;
    widget.store.removeForever(widget.id);
    _close();
  }

  /// ノートの情報(最終同期・更新・作成・単語数・文字数)を出す。
  void _showInfo() {
    final meta = widget.store.metaOf(widget.id);
    if (meta == null) return;
    final text = _c.text;
    final words = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
    final chars = text.runes.length;
    final synced = widget.store.lastSynced;

    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Expanded(child: Text(label)),
              Text(value),
            ],
          ),
        );

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ノートの情報'),
        content: SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              row('最終同期',
                  synced == null ? '—' : _fmtDateTime(synced.millisecondsSinceEpoch)),
              row('更新', _fmtDateTime(meta.contentAt)),
              row('作成', _fmtDateTime(meta.createdAt)),
              row('単語数', '$words'),
              row('文字数', '$chars'),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('閉じる')),
        ],
      ),
    );
  }

  /// タグを追加するダイアログを開く。
  /// 新規ノートで、まだ一度も保存されていない場合は、先に本文を保存してからタグを付ける。
  Future<void> _addTag() async {
    final store = widget.store;
    if (store.metaOf(widget.id) == null) {
      if (_c.text.trim().isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('先に本文を入力してください')),
        );
        return;
      }
      _dirty = true;
      _flush(); // saveContent が同期的にメタ情報を作る
    }
    final have = (store.metaOf(widget.id)?.tags ?? const <String>[])
        .map((t) => t.toLowerCase())
        .toSet();
    final suggestions = store
        .tagCounts(trash: false)
        .where((t) => !have.contains(t.key))
        .map((t) => t.label)
        .toList();

    final res = await showDialog<List<String>>(
      context: context,
      builder: (_) => _TagDialog(suggestions: suggestions),
    );
    if (res == null || res.isEmpty || !mounted) return;
    store.addTags(widget.id, res);
  }

  // ── 本文内検索 ───────────────────────────────────────────────

  /// 本文の中で、検索語に一致する位置(文字のオフセット)を、先頭から順に返す。
  /// 一覧の強調表示と同じ規則(大文字小文字は区別しない、重ならない一致のみ)。
  List<int> _matchStarts() {
    if (_query.isEmpty) return const [];
    final text = _c.text;
    final lower = text.toLowerCase();
    if (lower.length != text.length) return const [];
    final q = _query.toLowerCase();
    final out = <int>[];
    var i = 0;
    while (true) {
      final j = lower.indexOf(q, i);
      if (j < 0) break;
      out.add(j);
      i = j + q.length;
    }
    return out;
  }

  void _jumpToFirstMatch() {
    final starts = _matchStarts();
    if (starts.isEmpty) return;
    _scrollToOffset(starts[0], animate: false);
  }

  /// 一致箇所を、前(-1)・次(+1)へ移す。端まで行ったら、反対側に戻る。
  void _gotoMatch(int delta) {
    final starts = _matchStarts();
    if (starts.isEmpty) return;
    final n = starts.length;
    setState(() => _cur = ((_cur + delta) % n + n) % n);
    _c.setHighlight(_query, _cur);
    _scrollToOffset(starts[_cur]);
  }

  void _closeSearchBar() {
    setState(() => _query = '');
    _c.setHighlight('', 0);
  }

  /// 本文の [offset] 文字目が、画面の上から3分の1あたりに来るように、スクロールする。
  /// 同じ幅・同じ文字スタイルで文字を配置し直して、その行の高さを求めている。
  void _scrollToOffset(int offset, {bool animate = true}) {
    final style = _fieldStyle;
    if (style == null || !_scroll.hasClients || _fieldW <= 0) return;
    // 文字を置ける幅は、本文欄の幅より、カーソルの分(約3px)だけ狭い
    final tp = TextPainter(
      text: TextSpan(text: _c.text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: _textScaler,
    )..layout(maxWidth: (_fieldW - 3).clamp(1.0, double.infinity).toDouble());
    final y = tp.getOffsetForCaret(TextPosition(offset: offset), Rect.zero).dy;
    tp.dispose();
    final pos = _scroll.position;
    final target = (y - _fieldH / 3).clamp(0.0, pos.maxScrollExtent).toDouble();
    if (animate) {
      _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    } else {
      _scroll.jumpTo(target);
    }
  }

  /// 「「gmail」 3 / 12」と、前へ・次へ・閉じるのボタン
  Widget _searchBar() {
    if (_query.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final n = _matchStarts().length;
    final cur = n == 0 ? 0 : _cur.clamp(0, n - 1);
    return Container(
      margin: const EdgeInsets.only(top: 4, bottom: 4),
      padding: const EdgeInsets.only(left: 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              n == 0 ? '本文に「$_query」はありません' : '「$_query」  ${cur + 1} / $n',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13),
            ),
          ),
          IconButton(
            tooltip: '前の一致箇所',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.keyboard_arrow_up),
            onPressed: n == 0 ? null : () => _gotoMatch(-1),
          ),
          IconButton(
            tooltip: '次の一致箇所',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.keyboard_arrow_down),
            onPressed: n == 0 ? null : () => _gotoMatch(1),
          ),
          IconButton(
            tooltip: '強調を消す',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close),
            onPressed: _closeSearchBar,
          ),
        ],
      ),
    );
  }

  // ── 画面 ─────────────────────────────────────────────────────

  /// タグのチップ(タグごとの × と、「+ タグ」)。本文の上(狭い画面)と上部バー(広い画面)で共通。
  List<Widget> _tagChips(NoteMeta? meta, bool deleted) {
    final tags = meta?.tags ?? const <String>[];
    return [
      for (final t in tags)
        InputChip(
          label: Text('#$t'),
          visualDensity: VisualDensity.compact,
          onDeleted: deleted ? null : () => widget.store.removeTag(widget.id, t),
        ),
      if (!deleted)
        ActionChip(
          avatar: const Icon(Icons.add, size: 18),
          label: const Text('タグ'),
          visualDensity: VisualDensity.compact,
          onPressed: _addTag,
        ),
    ];
  }

  /// 本文の上に出すタグの行(狭い画面用)
  Widget _tagBar(NoteMeta? meta, bool deleted) {
    final tags = meta?.tags ?? const <String>[];
    if (deleted && tags.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Wrap(
          spacing: 8,
          runSpacing: 0,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: _tagChips(meta, deleted),
        ),
      ),
    );
  }

  /// 上部バーに出すタグの行(広い画面用)。多いときは横にスクロールする。
  Widget? _appBarTags(NoteMeta? meta, bool deleted) {
    final tags = meta?.tags ?? const <String>[];
    if (deleted && tags.isEmpty) return null;
    final chips = _tagChips(meta, deleted);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var i = 0; i < chips.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            chips[i],
          ],
        ],
      ),
    );
  }

  Widget _body(bool deleted, NoteMeta? meta) {
    if (_loadError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('読み込みに失敗しました: $_loadError', textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () {
                setState(() => _loadError = null);
                _load();
              },
              child: const Text('再試行'),
            ),
          ],
        ),
      );
    }
    if (!_loaded) return const Center(child: CircularProgressIndicator());
    final scheme = Theme.of(context).colorScheme;
    // 本文の欄と、一致箇所へのスクロール位置の計算で、同じ文字スタイルを使う
    final fieldStyle =
        (Theme.of(context).textTheme.bodyLarge ?? const TextStyle(fontSize: 16))
            .copyWith(color: scheme.onSurface);
    _fieldStyle = fieldStyle;
    _textScaler = MediaQuery.textScalerOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          // 広い画面(埋め込み)では、タグは上部バーに出すので、ここには出さない
          if (!widget.embedded) _tagBar(meta, deleted),
          _searchBar(),
          Expanded(
            child: LayoutBuilder(
              builder: (context, c) {
                // 上下の余白(8 + 8)を除いた、文字が表示される領域の大きさ
                _fieldW = c.maxWidth;
                _fieldH = c.maxHeight - 16;
                return TextField(
                  controller: _c,
                  scrollController: _scroll,
                  style: fieldStyle,
                  onChanged: _onChanged,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  autofocus: widget.isNew,
                  readOnly: deleted,
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(vertical: 8),
                    hintText: '1行目がタイトルになります',
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.store,
      builder: (context, _) {
        final meta = widget.store.metaOf(widget.id);
        final deleted = meta?.deleted ?? false;
        final pinned = meta?.pinned ?? false;
        return Scaffold(
          appBar: AppBar(
            // 埋め込みのときは、戻るボタンを出さない(左端には、一覧の表示/非表示のボタンを出す)
            automaticallyImplyLeading: !widget.embedded,
            leading: widget.embedded ? widget.leading : null,
            // 埋め込みのときは、タグの行を上部バーに出す(1行分、本文が広がる)
            centerTitle: false,
            title: widget.embedded ? _appBarTags(meta, deleted) : null,
            actions: [
              if (meta != null)
                IconButton(
                  tooltip: 'ノートの情報',
                  icon: const Icon(Icons.info_outline),
                  onPressed: _showInfo,
                ),
              if (meta != null)
                IconButton(
                  tooltip: 'ピン留め',
                  icon: Icon(pinned ? Icons.push_pin : Icons.push_pin_outlined),
                  onPressed: () => widget.store.setPinned(widget.id, !pinned),
                ),
              if (!deleted)
                IconButton(
                  tooltip: 'ゴミ箱へ',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: meta == null ? null : _toTrash,
                )
              else ...[
                IconButton(
                  tooltip: '復元',
                  icon: const Icon(Icons.restore_from_trash),
                  onPressed: _restore,
                ),
                IconButton(
                  tooltip: '完全に削除',
                  icon: const Icon(Icons.delete_forever),
                  onPressed: _deleteForever,
                ),
              ],
            ],
          ),
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 800),
                child: _body(deleted, meta),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// タグ追加ダイアログ。
/// 入力欄にカンマ・スペース区切りで複数入力できる。既存のタグは候補として表示し、タップで即追加。
class _TagDialog extends StatefulWidget {
  final List<String> suggestions;
  const _TagDialog({required this.suggestions});

  @override
  State<_TagDialog> createState() => _TagDialogState();
}

class _TagDialogState extends State<_TagDialog> {
  final _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _submit() {
    final tags = parseTags(_c.text);
    Navigator.pop(context, tags.isEmpty ? null : tags);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('タグを追加'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _c,
              autofocus: true,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                hintText: 'スペースかカンマ区切りで複数可',
              ),
            ),
            if (widget.suggestions.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text('既存のタグ', style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                children: [
                  for (final s in widget.suggestions)
                    ActionChip(
                      label: Text('#$s'),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => Navigator.pop(context, [s]),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('キャンセル')),
        TextButton(onPressed: _submit, child: const Text('追加')),
      ],
    );
  }
}

/// 検索語に一致した部分を、背景色で強調する本文用のコントローラ。
/// いま選んでいる一致箇所(current)は、ほかより濃い色で表示する。
class _HighlightController extends TextEditingController {
  String _query = '';
  int _current = 0;

  void setHighlight(String query, int current) {
    _query = query;
    _current = current;
    notifyListeners(); // 本文欄の再描画だけが走る(本文は変わらない)
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    // 日本語入力の変換中は、変換の下線を優先して、強調はしない
    if (_query.isEmpty || (withComposing && value.isComposingRangeValid)) {
      return super.buildTextSpan(
          context: context, style: style, withComposing: withComposing);
    }
    final text = this.text;
    final lower = text.toLowerCase();
    final q = _query.toLowerCase();
    if (lower.length != text.length) {
      return super.buildTextSpan(
          context: context, style: style, withComposing: withComposing);
    }
    final scheme = Theme.of(context).colorScheme;
    final spans = <TextSpan>[];
    var i = 0;
    var index = 0;
    while (true) {
      final j = lower.indexOf(q, i);
      if (j < 0) {
        spans.add(TextSpan(text: text.substring(i)));
        break;
      }
      if (j > i) spans.add(TextSpan(text: text.substring(i, j)));
      final isCurrent = index == _current;
      spans.add(TextSpan(
        text: text.substring(j, j + q.length),
        style: TextStyle(
          backgroundColor:
              isCurrent ? scheme.primary : scheme.tertiaryContainer,
          color: isCurrent ? scheme.onPrimary : scheme.onTertiaryContainer,
        ),
      ));
      i = j + q.length;
      index++;
    }
    return TextSpan(style: style, children: spans);
  }
}