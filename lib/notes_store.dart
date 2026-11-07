// notes_store.dart
// アプリ全体のノート状態。画面はここを見て、書き込みもここ経由で行う。
//  - 一覧は index.json だけで表示 (本文は開いたときに取得)
//  - 変更は即座に画面へ反映し、Dropbox への書き込みは裏でキュー処理
//  - 失敗した変更は、次のポーリング時に自動で再送
//  - 30秒ごと(+アプリ復帰時)に index.json の rev を確認し、変わっていれば取り込む

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'dropbox_notes_service.dart';

class NotesStore extends ChangeNotifier {
  NotesStore(this._svc);
  final DropboxNotesService _svc;

  static const _pollInterval = Duration(seconds: 30);

  Map<String, NoteMeta> _notes = {};
  IndexSnapshot _snap = IndexSnapshot.empty();

  // 本文キャッシュ (id -> text) と、そのキャッシュが対応する contentAt
  final Map<String, String> _content = {};
  final Map<String, int> _contentStamp = {};

  final Set<String> _dirty = {}; // 未同期の変更があるノート
  final Set<String> _fileDirty = {}; // 本文ファイルが未アップロード
  final Set<String> _removing = {}; // 完全削除の処理待ち

  bool loading = true;
  String? error;
  DateTime? lastSynced;

  int _jobs = 0;
  Future<void> _queue = Future.value();
  Timer? _timer;
  bool _disposed = false;

  // ── ライフサイクル ───────────────────────────────────────────
  void start() {
    refresh(force: true);
    _timer = Timer.periodic(_pollInterval, (_) => refresh());
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  // ── 参照 ─────────────────────────────────────────────────────
  NoteMeta? metaOf(String id) => _notes[id];

  List<NoteMeta> visibleNotes({required bool trash, String query = ''}) {
    final q = query.trim().toLowerCase();
    final list = _notes.values.where((n) {
      if (n.deleted != trash) return false;
      if (q.isEmpty) return true;
      return n.title.toLowerCase().contains(q) ||
          n.preview.toLowerCase().contains(q) ||
          n.tags.any((t) => t.toLowerCase().contains(q));
    }).toList();
    list.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      return b.contentAt.compareTo(a.contentAt);
    });
    return list;
  }

  // ── 同期 ─────────────────────────────────────────────────────
  Future<void> refresh({bool force = false}) async {
    if (_jobs > 0) return; // 送信中は競合を避けてスキップ
    if (_dirty.isNotEmpty || _removing.isNotEmpty) {
      _retryPending(); // 未送信の変更があれば、まず再送
      return;
    }
    try {
      if (!force) {
        final rev = await _svc.indexRev();
        if (rev == _snap.rev) {
          lastSynced = DateTime.now();
          error = null;
          _notify();
          return;
        }
      }
      final snap = await _svc.fetchIndex();
      _snap = snap;
      _applyRemote(snap.notes);
      lastSynced = DateTime.now();
      error = null;
    } catch (e) {
      error = '同期に失敗しました: $e';
    } finally {
      loading = false;
      _notify();
    }
  }

  /// 取得した index をローカルへ反映する。未同期の自分の変更は、より新しければ守る。
  void _applyRemote(Map<String, NoteMeta> remote) {
    final merged = <String, NoteMeta>{};
    remote.forEach((id, r) {
      if (_removing.contains(id)) return;
      final l = _notes[id];
      if (l != null && _dirty.contains(id) && l.changedAt >= r.changedAt) {
        merged[id] = l; // 自分の未送信の変更のほうが新しい
      } else {
        if (_dirty.contains(id)) {
          // 他の端末の変更が勝った → 自分の未送信分は破棄
          _dirty.remove(id);
          _fileDirty.remove(id);
        }
        merged[id] = r;
      }
    });
    for (final id in _dirty) {
      final l = _notes[id];
      if (l != null && !merged.containsKey(id)) merged[id] = l; // 新規で未送信
    }
    _notes = merged;
  }

  // ── 書き込みキュー ───────────────────────────────────────────
  void _enqueue(Future<void> Function() job) {
    _jobs++;
    _queue = _queue.then((_) async {
      try {
        await job();
        error = null;
      } catch (e) {
        error = '保存に失敗しました(自動で再試行します): $e';
      } finally {
        _jobs--;
        _notify();
      }
    });
  }

  void _retryPending() {
    for (final id in _dirty.toList()) {
      _enqueue(() => _push(id));
    }
    for (final id in _removing.toList()) {
      _enqueue(() => _purge(id));
    }
  }

  Future<void> _push(String id) async {
    final meta = _notes[id];
    if (meta == null || !_dirty.contains(id)) return;
    final stamp = meta.changedAt;

    if (_fileDirty.contains(id)) {
      final text = _content[id];
      if (text != null) await _svc.saveNote(id, text);
    }
    final res = await _svc.mutateIndex((n) => n[id] = meta, base: _snap);
    _snap = res;

    final cur = _notes[id];
    if (cur != null && cur.changedAt == stamp) {
      _dirty.remove(id);
      _fileDirty.remove(id);
    }
    _applyRemote(res.notes);
    lastSynced = DateTime.now();
  }

  Future<void> _purge(String id) async {
    await _svc.deleteNote(id);
    final res = await _svc.mutateIndex((n) => n.remove(id), base: _snap);
    _snap = res;
    _removing.remove(id);
    _applyRemote(res.notes);
    lastSynced = DateTime.now();
  }

  // ── 操作 ─────────────────────────────────────────────────────

  /// 新しいノートの ID を発行する。内容が入力されるまで Dropbox には何も書かない。
  String createNote() {
    final id = _newId();
    _content[id] = '';
    return id;
  }

  /// 本文を読み込む (キャッシュが古ければ Dropbox から取得)
  Future<String> loadContent(String id) async {
    final meta = _notes[id];
    final cached = _content[id];
    if (cached != null && (meta == null || _contentStamp[id] == meta.contentAt)) {
      return cached;
    }
    final text = await _svc.loadNote(id);
    _content[id] = text;
    _contentStamp[id] = meta?.contentAt ?? 0;
    return text;
  }

  void saveContent(String id, String text) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final old = _notes[id] ?? NoteMeta.create(id);
    _notes[id] = old.copyWith(
      title: titleOf(text),
      preview: previewOf(text),
      contentAt: now,
      changedAt: now,
    );
    _content[id] = text;
    _contentStamp[id] = now;
    _dirty.add(id);
    _fileDirty.add(id);
    _notify();
    _enqueue(() => _push(id));
  }

  void _changeMeta(String id, NoteMeta Function(NoteMeta) f) {
    final old = _notes[id];
    if (old == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    _notes[id] = f(old).copyWith(changedAt: now);
    _dirty.add(id);
    _notify();
    _enqueue(() => _push(id));
  }

  void setPinned(String id, bool v) =>
      _changeMeta(id, (m) => m.copyWith(pinned: v));

  void setDeleted(String id, bool v) =>
      _changeMeta(id, (m) => m.copyWith(deleted: v));

  void removeForever(String id) {
    _notes.remove(id);
    _dirty.remove(id);
    _fileDirty.remove(id);
    _content.remove(id);
    _contentStamp.remove(id);
    _removing.add(id);
    _notify();
    _enqueue(() => _purge(id));
  }

  void emptyTrash() {
    final ids = _notes.values.where((n) => n.deleted).map((n) => n.id).toList();
    for (final id in ids) {
      removeForever(id);
    }
  }

  String _newId() {
    final r = Random.secure();
    final rand = List.generate(6, (_) => r.nextInt(36).toRadixString(36)).join();
    return '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}$rand';
  }
}
