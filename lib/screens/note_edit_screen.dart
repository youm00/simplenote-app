import 'dart:async';

import 'package:flutter/material.dart';

import '../notes_store.dart';

class NoteEditScreen extends StatefulWidget {
  final NotesStore store;
  final String id;
  final bool isNew;
  const NoteEditScreen({
    super.key,
    required this.store,
    required this.id,
    this.isNew = false,
  });

  @override
  State<NoteEditScreen> createState() => _NoteEditScreenState();
}

class _NoteEditScreenState extends State<NoteEditScreen>
    with WidgetsBindingObserver {
  final _c = TextEditingController();
  Timer? _timer;
  bool _loaded = false;
  bool _dirty = false;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  Future<void> _load() async {
    try {
      final t = await widget.store.loadContent(widget.id);
      if (!mounted) return;
      _c.text = t;
      setState(() {
        _loaded = true;
        _loadError = null;
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
    super.dispose();
  }

  // ── 操作 ─────────────────────────────────────────────────────
  void _toTrash() {
    _flush();
    widget.store.setDeleted(widget.id, true);
    Navigator.pop(context);
  }

  void _restore() {
    widget.store.setDeleted(widget.id, false);
    Navigator.pop(context);
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
    Navigator.pop(context);
  }

  // ── 画面 ─────────────────────────────────────────────────────
  Widget _body(bool deleted) {
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: TextField(
        controller: _c,
        onChanged: _onChanged,
        maxLines: null,
        expands: true,
        textAlignVertical: TextAlignVertical.top,
        autofocus: widget.isNew,
        readOnly: deleted,
        decoration: const InputDecoration(
          border: InputBorder.none,
          hintText: '1行目がタイトルになります',
        ),
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
            actions: [
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
                child: _body(deleted),
              ),
            ),
          ),
        );
      },
    );
  }
}
