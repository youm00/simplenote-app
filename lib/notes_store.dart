// notes_store.dart
// アプリ全体のノート状態。画面はここを見て、書き込みもここ経由で行う。
//  - 一覧は index.json だけで表示 (本文は開いたときに取得)
//  - 変更は即座に画面へ反映し、Dropbox への書き込みは裏でキュー処理
//  - 失敗した変更は、次のポーリング時に自動で再送
//  - 30秒ごと(+アプリ復帰時)に index.json の rev を確認し、変わっていれば取り込む
//  - タグ: ノートごとに index.json の tags に保存。大文字小文字は区別せず同じタグとして扱う
//  - タグの名前変更・削除は、全ノート(ゴミ箱内も含む)にまとめて適用し、index.json を1回で更新する
//  - タグの並び順(ドラッグ&ドロップ): index.json の tagOrder(小文字化したタグ名の配列)に保存して、端末間で共有する。
//    並べ替えた直後〜送信が終わるまでは、手元の並び順を優先する(_orderDirty)。
//  - オフライン: 全ノートのメタ情報・本文・未送信の変更を、端末内(SharedPreferences)にも保存する。
//    起動時はこれを先に表示し、圏外で編集した分は、アプリを終了しても残り、つながったときに自動で送る。
//  - バックアップ: 全ノートを JSON で書き出す(buildBackup)/読み込む(importBackup)。
//    読み込んだノートは、本文ファイルを4件ずつ並行して送り、index.json は1回の更新でまとめて送る。
//  - 自動バックアップ(v17): 同期が成功したあと、今日まだ取っていなければ、Dropbox の /backup/ に
//    simplenote_backup_YYYYMMDD_HHmmss.json を保存する(1日1回、最大365件)。手動の保存(backupNow)と、
//    Dropbox のバックアップの一覧・取得(listRemoteBackups / downloadRemoteBackup)も、ここから行う。
//  - 全文検索: 全ノートの本文をメモリに持つ(_content)。起動後の最初の同期で、ZIP 1回でまとめて取得し、
//    以降は、本文が更新されたノートだけを取り直す。取得中は、取得済みの分だけが検索対象になる。

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'backup_format.dart';
import 'dropbox_notes_service.dart';

String _two(int v) => v.toString().padLeft(2, '0');

/// 「2026-11-13」の形(自動バックアップを、1日1回にするための日付)
String _dateStr(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';

/// 「simplenote_backup_20261113_104512.json」の形
String _backupFileName(DateTime d) =>
    'simplenote_backup_${d.year}${_two(d.month)}${_two(d.day)}'
    '_${_two(d.hour)}${_two(d.minute)}${_two(d.second)}.json';

/// タグ一覧用(ドロワー・タグ編集画面・候補表示に使う)
class TagCount {
  final String key; // 小文字化したもの。比較・絞り込み用
  final String label; // 表示用(最初に見つかった表記)
  final int count;
  const TagCount(this.key, this.label, this.count);
}

/// 入力文字列をタグのリストにする。
///  - 区切りは、空白・カンマ(, ，)・読点(、)
///  - 先頭の # は取り除く
///  - 1つのタグは最大30文字
///  - 大文字小文字だけが違うものは重複として除く
List<String> parseTags(String input) {
  final seen = <String>{};
  final out = <String>[];
  for (var s in input.split(RegExp(r'[\s,，、]+'))) {
    s = s.replaceFirst(RegExp(r'^[#＃]+'), '').trim();
    if (s.isEmpty) continue;
    if (s.runes.length > 30) s = String.fromCharCodes(s.runes.take(30));
    if (seen.add(s.toLowerCase())) out.add(s);
  }
  return out;
}

/// Dropbox の index.json に問題があるとき(無い・空)の、画面に出す案内
class IndexProblem {
  final String message;

  /// この端末に、残っているノートがあり、それで index.json を作り直せるか
  final bool localCopyAvailable;
  const IndexProblem(this.message, {required this.localCopyAvailable});
}

class NotesStore extends ChangeNotifier {
  NotesStore(this._svc);
  final DropboxNotesService _svc;

  static const _pollInterval = Duration(seconds: 30);

  Map<String, NoteMeta> _notes = {};
  IndexSnapshot _snap = IndexSnapshot.empty();

  // 本文キャッシュ (id -> text) と、そのキャッシュが対応する contentAt
  final Map<String, String> _content = {};
  final Map<String, int> _contentStamp = {};

  // 新規ノートに、最初の保存時に付けるタグ(タグを選んだ状態で「新規」を押したとき用)
  final Map<String, List<String>> _pendingTags = {};

  // タグの並び順(小文字化したタグ名)。ここに無いタグは、並び順の最後に回る。
  List<String> _tagOrder = [];
  bool _orderDirty = false; // 並び順に、未送信の変更がある

  // 本文の一括取得(全文検索用)の状態
  bool _contentSyncing = false;
  DateTime? _contentFailAt; // 直近の取得失敗の時刻(5分は再試行しない)
  static const _contentRetryWait = Duration(minutes: 5);
  static const _zipThreshold = 8; // 取得が必要なノートがこの数以上なら、ZIP でまとめて取得

  // 自動バックアップの状態(v17)
  /// Dropbox に残すバックアップの最大件数(超えた分は、古い順に自動で削除する)
  static const backupKeep = 365;
  static const _backupDateKey = 'sn_cache_last_backup'; // ログアウトで、端末内の保存といっしょに消える
  static const _backupRetryWait = Duration(minutes: 10);
  bool _backingUp = false;
  DateTime? _backupFailAt; // 直近の自動バックアップの失敗の時刻(10分は再試行しない)

  /// 最後にバックアップに成功した日(「2026-11-13」の形)。まだ無ければ null。
  String? lastBackupDate;

  /// バックアップを保存している最中か
  bool get backingUp => _backingUp;

  final Set<String> _dirty = {}; // 未同期の変更があるノート
  final Set<String> _fileDirty = {}; // 本文ファイルが未アップロード
  final Set<String> _removing = {}; // 完全削除の処理待ち
  bool _fetchedOnce = false; // 起動してから、index.json を取得できたか

  /// 通信できない状態か(圏外・通信の復帰待ちなど)。このときは、赤いエラーの帯は出さない。
  bool offline = false;
  int _netRetry = 0; // 通信の失敗が続いているときの、静かな再試行の回数
  Timer? _retryTimer;

  /// Dropbox の index.json に問題があるとき(無い・空)の案内。問題が無ければ null。
  IndexProblem? indexProblem;

  /// 「Dropbox の index.json が空なのに、この端末にはノートが残っている」ときは、
  /// 利用者が選ぶまで、index.json への書き込みを止める(残っているノートを、1件の編集で上書きしないため)。
  bool get _indexBlocked => indexProblem?.localCopyAvailable ?? false;

  bool loading = true;
  String? error;
  DateTime? lastSynced;

  int _jobs = 0;
  Future<void> _queue = Future.value();
  Timer? _timer;
  bool _disposed = false;

  // ── ライフサイクル ───────────────────────────────────────────
  void start() {
    unawaited(_boot());
  }

  Future<void> _boot() async {
    await _loadLocal(); // 端末内に保存してあるものを、まず表示する
    if (_disposed) return;
    _notify();
    refresh(force: true);
    _timer = Timer.periodic(_pollInterval, (_) => refresh());
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _retryTimer?.cancel();
    if (_saveTimer?.isActive ?? false) {
      _saveTimer!.cancel();
      unawaited(_flushLocal()); // 予約中の保存は、済ませておく
    }
    super.dispose();
  }

  /// 通信できないことによるエラーか(名前解決の失敗・接続の失敗・タイムアウトなど)
  static bool _isNetworkError(Object e) {
    if (e is TimeoutException) return true;
    final s = e.toString();
    return s.contains('SocketException') ||
        s.contains('Failed host lookup') ||
        s.contains('XMLHttpRequest error') ||
        s.contains('Connection closed') ||
        s.contains('Connection reset') ||
        s.contains('Connection refused') ||
        s.contains('Network is unreachable') ||
        s.contains('HandshakeException') ||
        s.contains('トークンを取得できません'); // 通信できず、アクセストークンを更新できなかったとき
  }

  /// 通信の失敗が続くあいだ、2・4・8・16秒後に、静かに再試行する(その後は、30秒ごとの同期に任せる)。
  void _scheduleNetRetry() {
    if (_disposed) return;
    const waits = [2, 4, 8, 16];
    if (_netRetry >= waits.length) return;
    final wait = Duration(seconds: waits[_netRetry++]);
    _retryTimer?.cancel();
    _retryTimer = Timer(wait, () => refresh());
  }

  /// 通信できたことを記録する。
  void _markOnline() {
    if (offline || _netRetry != 0) {
      offline = false;
      _netRetry = 0;
      _retryTimer?.cancel();
    }
  }

  /// 画面に変更を知らせて、端末内への保存も予約する。[saveNow] は、利用者の操作の直後に、すぐ保存したいとき。
  void _notify({bool saveNow = false}) {
    if (_disposed) return;
    notifyListeners();
    _scheduleSave(delay: saveNow ? Duration.zero : _saveDelay);
  }

  // ── 参照 ─────────────────────────────────────────────────────
  NoteMeta? metaOf(String id) => _notes[id];

  /// 一覧に表示するノート。検索は、本文・タイトル・プレビュー・タグが対象(大文字小文字は区別しない)。
  /// [tag] を渡すと、そのタグが付いたノートだけに絞る(大文字小文字は区別しない)。
  /// [untaggedOnly] が true なら、タグが1つも付いていないノートだけに絞る。
  List<NoteMeta> visibleNotes({
    required bool trash,
    String query = '',
    String? tag,
    bool untaggedOnly = false,
  }) {
    final q = query.trim().toLowerCase();
    final tagKey = tag?.toLowerCase();
    final list = _notes.values.where((n) {
      if (n.deleted != trash) return false;
      if (untaggedOnly && n.tags.isNotEmpty) return false;
      if (tagKey != null && !n.tags.any((t) => t.toLowerCase() == tagKey)) {
        return false;
      }
      if (q.isEmpty) return true;
      return n.title.toLowerCase().contains(q) ||
          n.preview.toLowerCase().contains(q) ||
          n.tags.any((t) => t.toLowerCase().contains(q)) ||
          (_content[n.id]?.toLowerCase().contains(q) ?? false);
    }).toList();
    list.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      return b.contentAt.compareTo(a.contentAt);
    });
    return list;
  }

  /// 使われているタグの一覧(件数の多い順、同数なら名前順)。
  /// [trash] が true ならゴミ箱内のノート、false なら通常のノートが対象。
  List<TagCount> tagCounts({required bool trash}) {
    final labels = <String, String>{};
    final counts = <String, int>{};
    for (final n in _notes.values) {
      if (n.deleted != trash) continue;
      for (final t in n.tags) {
        final k = t.toLowerCase();
        labels.putIfAbsent(k, () => t);
        counts[k] = (counts[k] ?? 0) + 1;
      }
    }
    final list = counts.entries
        .map((e) => TagCount(e.key, labels[e.key]!, e.value))
        .toList();
    list.sort((a, b) {
      final c = b.count.compareTo(a.count);
      return c != 0 ? c : a.key.compareTo(b.key);
    });
    return list;
  }

  /// ドロワー・タグ編集画面に出す、通常のノートで使われているタグの一覧(並べ替えた順)。
  /// 並び順が決まっていないタグ(新しく付けたもの)は、最後に、件数の多い順で並ぶ。
  List<TagCount> orderedTags() {
    final list = tagCounts(trash: false); // 件数の多い順
    final pos = <String, int>{};
    for (var i = 0; i < _tagOrder.length; i++) {
      pos.putIfAbsent(_tagOrder[i], () => i);
    }
    final ordered = list.where((t) => pos.containsKey(t.key)).toList()
      ..sort((a, b) => pos[a.key]!.compareTo(pos[b.key]!));
    final rest = list.where((t) => !pos.containsKey(t.key));
    return [...ordered, ...rest];
  }

  /// タグの並び順を、まるごと置き換える(ドラッグ&ドロップの結果)。[keys] は小文字化したタグ名。
  void setTagOrder(List<String> keys) {
    final seen = <String>{};
    _tagOrder = [
      for (final k in keys)
        if (seen.add(k.toLowerCase())) k.toLowerCase(),
    ];
    _orderDirty = true;
    _notify(saveNow: true);
    _enqueue(_pushOrder);
  }

  /// タグの名前を変えたとき、並び順の中の位置を引き継ぐ。
  void _renameInOrder(String oldKey, String newKey) {
    final i = _tagOrder.indexOf(oldKey);
    if (i < 0 || oldKey == newKey) return;
    final seen = <String>{};
    final next = <String>[];
    for (var j = 0; j < _tagOrder.length; j++) {
      final k = j == i ? newKey : _tagOrder[j];
      if (seen.add(k)) next.add(k); // 統合で重なったら、先にあるほうを残す
    }
    _tagOrder = next;
    _orderDirty = true;
    _enqueue(_pushOrder);
  }

  /// タグを削除したとき、並び順からも外す。
  void _removeFromOrder(String key) {
    if (!_tagOrder.contains(key)) return;
    _tagOrder = _tagOrder.where((k) => k != key).toList();
    _orderDirty = true;
    _enqueue(_pushOrder);
  }

  /// 手元に未送信の並び順の変更が無いときだけ、取得した並び順を採用する。
  void _adoptOrder(IndexSnapshot s) {
    if (!_orderDirty) _tagOrder = List<String>.of(s.tagOrder);
  }

  Future<void> _pushOrder() async {
    if (!_orderDirty || _indexBlocked) return;
    final order = List<String>.of(_tagOrder);
    final res = await _svc.mutateIndex(
      (_) {},
      base: _snap,
      mutateOrder: (_) => order,
    );
    _snap = res;
    _markOnline();
    if (listEquals(order, _tagOrder)) _orderDirty = false;
    _applyRemote(res.notes);
    lastSynced = DateTime.now();
  }

  // ── 全文検索 ─────────────────────────────────────────────────

  /// 本文を取得中か
  bool get contentSyncing => _contentSyncing;

  /// 全ノートの本文が、手元に揃っているか(揃っていなければ、検索結果が足りない可能性がある)
  bool get fullTextReady => _neededContentIds().isEmpty;

  /// 検索語が、本文にだけ含まれているとき、その前後の抜粋を返す(一覧の表示用)。
  /// タイトルやプレビューに含まれているとき、本文が未取得のとき、見つからないときは null。
  String? bodySnippet(String id, String query, {int radius = 40}) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return null;
    final n = _notes[id];
    final text = _content[id];
    if (n == null || text == null) return null;
    if (n.title.toLowerCase().contains(q) ||
        n.preview.toLowerCase().contains(q)) {
      return null;
    }
    final lower = text.toLowerCase();
    if (lower.length != text.length) return null;
    final i = lower.indexOf(q);
    if (i < 0) return null;
    var s = max(0, i - radius);
    var e = min(text.length, i + q.length + radius);
    // サロゲートペア(絵文字など)の途中で切らない
    if (s > 0 && _isLowSurrogate(text.codeUnitAt(s))) s--;
    if (e < text.length && _isLowSurrogate(text.codeUnitAt(e))) e++;
    final snip = text.substring(s, e).replaceAll(RegExp(r'\s+'), ' ').trim();
    return '${s > 0 ? '…' : ''}$snip${e < text.length ? '…' : ''}';
  }

  static bool _isLowSurrogate(int u) => u >= 0xDC00 && u <= 0xDFFF;

  /// 本文を取得する必要があるノートの ID(未取得、または本文が古いもの)。
  /// 自分の未送信の変更があるノートは、手元の本文が最新なので、対象にしない。
  List<String> _neededContentIds() {
    final ids = <String>[];
    for (final n in _notes.values) {
      if (_dirty.contains(n.id) || _removing.contains(n.id)) continue;
      if (_content.containsKey(n.id) && _contentStamp[n.id] == n.contentAt) {
        continue;
      }
      ids.add(n.id);
    }
    return ids;
  }

  /// 本文が手元に無い(または古い)ノートを取得して、キャッシュに入れる。
  /// 多いときは ZIP でまとめて、少ないときは1件ずつ取得する。失敗しても、検索の範囲が狭くなるだけ。
  Future<void> _syncContents() async {
    if (_disposed || _contentSyncing) return;
    final failed = _contentFailAt;
    if (failed != null &&
        DateTime.now().difference(failed) < _contentRetryWait) {
      return;
    }
    final need = _neededContentIds();
    if (need.isEmpty) return;

    _contentSyncing = true;
    _notify();
    try {
      // 取得の前の更新日時を控える。本文は、これより後に取得するので、同じか新しい。
      final stamps = {for (final id in need) id: _notes[id]!.contentAt};

      final got = await _fetchBodies(need);

      _storeFetched(need, stamps, got);
      _contentFailAt = null;
    } catch (_) {
      _contentFailAt = DateTime.now();
    } finally {
      _contentSyncing = false;
      _notify();
    }
  }

  /// 本文を取得する。多いときは ZIP でまとめて、少ないときは(またはZIPが失敗したら)1件ずつ。
  Future<Map<String, String>> _fetchBodies(List<String> need) async {
    if (need.length >= _zipThreshold) {
      Map<String, String> got;
      try {
        got = await _svc.downloadAllNotes();
      } catch (_) {
        return _downloadEach(need); // ZIP がだめなら、1件ずつ
      }
      // ZIP に入っていなかったノートは、1件ずつ確かめる(本当に無いときだけ、空の本文として扱う)
      final missing = need.where((id) => !got.containsKey(id)).toList();
      if (missing.isNotEmpty) got.addAll(await _downloadEach(missing));
      return got;
    }
    return _downloadEach(need);
  }

  /// 取得した本文を、キャッシュに入れる。
  void _storeFetched(
    List<String> need,
    Map<String, int> stamps,
    Map<String, String> got,
  ) {
    for (final id in need) {
      if (!_notes.containsKey(id) || _dirty.contains(id)) continue;
      // 取得している間に、別の経路(ノートを開くなど)で、より新しい本文が入っていたら、そちらを残す
      if (_content.containsKey(id) && (_contentStamp[id] ?? -1) >= stamps[id]!) {
        continue;
      }
      _content[id] = got[id] ?? '';
      _contentStamp[id] = stamps[id]!;
    }
  }

  /// 1件ずつ(4件並行で)本文を取得する
  Future<Map<String, String>> _downloadEach(List<String> ids) async {
    final out = <String, String>{};
    for (var i = 0; i < ids.length; i += 4) {
      final chunk = ids.sublist(i, min(i + 4, ids.length));
      final texts = await Future.wait(chunk.map(_svc.loadNote));
      for (var k = 0; k < chunk.length; k++) {
        out[chunk[k]] = texts[k];
      }
    }
    return out;
  }

  // ── バックアップ ──────────────────────────────────────────────

  /// 書き出し用に、全ノートの本文を手元にそろえる。取得できなければ、例外(書き出しを中止する)。
  Future<void> _ensureAllContents() async {
    while (_contentSyncing) {
      await Future.delayed(const Duration(milliseconds: 100)); // 裏の取得が終わるのを待つ
    }
    final need = _neededContentIds();
    if (need.isEmpty) return;
    final stamps = {for (final id in need) id: _notes[id]!.contentAt};
    final got = await _fetchBodies(need);
    _storeFetched(need, stamps, got);
    _scheduleSave();
  }

  /// バックアップの内容を作る(ゴミ箱内のノート、タグの並び順も含む)。
  Future<BackupData> buildBackup() async {
    await _ensureAllContents();
    final notes = _notes.values
        .map((n) => BackupNote(
              id: n.id,
              text: _content[n.id] ?? '',
              tags: n.tags,
              pinned: n.pinned,
              deleted: n.deleted,
              createdAt: n.createdAt,
              contentAt: n.contentAt,
            ))
        .toList()
      ..sort((a, b) => b.contentAt.compareTo(a.contentAt));
    return BackupData(
      exportedAt: DateTime.now().millisecondsSinceEpoch,
      tagOrder: List<String>.of(_tagOrder),
      notes: notes,
    );
  }

  /// 読み込む前に、取り込み結果の見込みを数える。
  BackupPreview previewBackup(BackupData data) {
    var trashed = 0, added = 0, same = 0, changed = 0, invalid = data.unreadable;
    for (final b in data.notes) {
      if (!b.validId) {
        invalid++;
        continue;
      }
      if (b.deleted) trashed++;
      final cur = _notes[b.id];
      if (cur == null) {
        added++;
        continue;
      }
      same++;
      final sameTags = cur.tags.length == b.tags.length &&
          cur.tags.every((t) => b.tags.any((u) => u.toLowerCase() == t.toLowerCase()));
      if (cur.contentAt != b.contentAt ||
          cur.deleted != b.deleted ||
          cur.pinned != b.pinned ||
          !sameTags) {
        changed++;
      }
    }
    return BackupPreview(
      total: data.notes.length - (invalid - data.unreadable),
      trashed: trashed,
      added: added,
      same: same,
      changed: changed,
      invalid: invalid,
    );
  }

  /// バックアップを取り込む。取り込んだノートの数を返す。
  ///  - [overwrite] が false: いまに無いノートだけを追加する(いまのノートは変更しない)。
  ///  - [overwrite] が true : 同じ ID のノートも、バックアップの内容(本文・タグ・ピン・ゴミ箱)に戻す。
  /// 取り込んだノートは「いま変更した」扱い(changedAt = 現在)にして、他の端末との競合でも勝つようにする。
  int importBackup(BackupData data, {required bool overwrite}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final ids = <String>[];
    for (final b in data.notes) {
      if (!b.validId) continue;
      if (_removing.contains(b.id)) continue; // 完全削除の処理待ちのものは、取り込まない
      if (_notes.containsKey(b.id) && !overwrite) continue;
      _notes[b.id] = NoteMeta(
        id: b.id,
        title: titleOf(b.text),
        preview: previewOf(b.text),
        pinned: b.pinned,
        deleted: b.deleted,
        tags: List<String>.unmodifiable(b.tags),
        createdAt: b.createdAt,
        contentAt: b.contentAt,
        changedAt: now,
      );
      _content[b.id] = b.text;
      _contentStamp[b.id] = b.contentAt;
      _pendingTags.remove(b.id);
      _dirty.add(b.id);
      _fileDirty.add(b.id);
      ids.add(b.id);
    }

    // タグの並び順: 上書きのときはバックアップのもの、追加だけのときは、いまが未設定の場合だけ
    if (data.tagOrder.isNotEmpty && (overwrite || _tagOrder.isEmpty)) {
      setTagOrder(data.tagOrder);
    }

    _notify(saveNow: true);
    if (ids.isNotEmpty) {
      _enqueue(() async {
        await _uploadBodies(ids);
        await _pushMany(ids);
      });
    }
    return ids.length;
  }

  /// 本文ファイルを、4件ずつ並行してアップロードする(取り込み用)。
  /// 送っている間に、そのノートが編集されたときは、「未送信」の印を残す。
  Future<void> _uploadBodies(List<String> ids) async {
    final todo = ids
        .where((id) =>
            _fileDirty.contains(id) && _notes.containsKey(id) && _content[id] != null)
        .toList();
    for (var i = 0; i < todo.length; i += 4) {
      final chunk = todo.sublist(i, min(i + 4, todo.length));
      final texts = {for (final id in chunk) id: _content[id]!};
      await Future.wait(chunk.map((id) => _svc.saveNote(id, texts[id]!)));
      for (final id in chunk) {
        if (_content[id] == texts[id]) _fileDirty.remove(id);
      }
    }
  }

  // ── Dropbox へのバックアップ(v17) ────────────────────────────

  /// いま、全ノートのバックアップを、Dropbox の /backup/ に保存する(手動・自動の共通)。
  /// 保存したノートの数を返す。失敗したら、例外。保存したあと、365件を超えた古い分を削除する。
  Future<int> backupNow() async {
    if (_backingUp) throw Exception('別のバックアップを実行中です');
    if (_notes.isEmpty) throw Exception('バックアップするノートがありません');
    _backingUp = true;
    _notify();
    try {
      final now = DateTime.now();
      final data = await buildBackup();
      final bytes = utf8.encode(encodeBackup(data));
      await _svc.uploadBackup(_backupFileName(now), bytes);
      await _recordBackupDate(_dateStr(now));
      try {
        await _svc.pruneBackups(keep: backupKeep); // 古い分の削除に失敗しても、バックアップ自体は成功
      } catch (_) {}
      return data.notes.length;
    } finally {
      _backingUp = false;
      _notify();
    }
  }

  /// 最後にバックアップした日を、記録する(端末内にも保存する)。
  Future<void> _recordBackupDate(String d) async {
    lastBackupDate = d;
    if (!_localReady || _disposed) return; // ログアウト中などは、保存しない
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_localReady && !_disposed) await prefs.setString(_backupDateKey, d);
    } catch (_) {}
  }

  /// 今日まだバックアップを取っていなければ、取る。同期が成功するたびに呼ばれる(起動時と、30秒ごと)。
  /// 次のときは、取らない: まだ一度も同期できていない / 未送信の変更がある / 一覧に問題がある /
  /// ノートが無い / 今日はもう取った / 直前に失敗した(10分は待つ)。
  Future<void> _autoBackupIfNeeded() async {
    if (_disposed || _backingUp || !_localReady) return;
    if (!_fetchedOnce || _hasUnsent || _jobs > 0 || indexProblem != null) return;
    if (_notes.isEmpty) return;
    if (lastBackupDate == _dateStr(DateTime.now())) return;
    final failed = _backupFailAt;
    if (failed != null &&
        DateTime.now().difference(failed) < _backupRetryWait) {
      return;
    }
    try {
      await backupNow();
      _backupFailAt = null;
    } catch (_) {
      _backupFailAt = DateTime.now(); // 通信できないときなどは、静かに、あとでやり直す
    }
  }

  /// Dropbox の /backup/ にあるバックアップの一覧(新しい順)。
  Future<List<BackupFileInfo>> listRemoteBackups() => _svc.listBackups();

  /// Dropbox のバックアップファイルの中身を取得する(復元用)。
  Future<Uint8List> downloadRemoteBackup(String path) =>
      _svc.downloadBackup(path);

  // ── 端末内への保存(オフライン編集の永続化) ─────────────────────
  // 端末内(SharedPreferences)に、次のものを保存して、アプリを終了しても、圏外でも、使えるようにする。
  //   sn_cache_index   … 全ノートのメタ情報、本文の更新日時、タグの並び順
  //   sn_cache_c_<id>  … ノートの本文(キャッシュ。全文検索・圏外での閲覧に使う)
  //   sn_cache_pending … 未送信の変更。ノートごとのメタ情報と本文(本文を変えたものだけ)を、この1つのキーに
  //                      まとめて入れる。1回の書き込みで完結するので、途中で終了しても、編集が失われない。
  //   sn_cache_last_backup … 最後に Dropbox へバックアップした日(v17)
  // 起動すると、まずこれを読み込んで画面に出し、そのあと Dropbox と同期する。
  static const _idxKey = 'sn_cache_index';
  static const _pendKey = 'sn_cache_pending';
  static const _bodyPrefix = 'sn_cache_c_';
  static const _saveDelay = Duration(milliseconds: 400);

  bool _localReady = false; // 読み込みが終わり、保存してよい状態か
  Timer? _saveTimer;
  DateTime? _saveDue;
  bool _saving = false;
  bool _saveAgain = false;
  final Map<String, String> _persistedBodies = {}; // 端末内に保存済みの本文(変わったものだけ書く)
  String? _lastIndexJson;
  String? _lastPendingJson;

  /// 未送信の変更があるか
  bool get _hasUnsent =>
      _dirty.isNotEmpty || _removing.isNotEmpty || _orderDirty;

  /// 未送信の変更の数(同期アイコンの説明・ログアウトの確認に使う)
  int get pendingCount =>
      _dirty.length + _removing.length + (_orderDirty ? 1 : 0);

  bool get hasPending => pendingCount > 0;

  /// 起動時に、端末内に保存してあるものを読み込む。読めなければ、保存なしの状態で始める。
  Future<void> _loadLocal() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      lastBackupDate = prefs.getString(_backupDateKey);

      // 一覧(メタ情報)と、本文のキャッシュ
      final rawIdx = prefs.getString(_idxKey);
      if (rawIdx != null) {
        final data = jsonDecode(rawIdx) as Map<String, dynamic>;
        final notes = (data['notes'] as Map?) ?? const {};
        final stamps = (data['stamps'] as Map?) ?? const {};
        notes.forEach((k, v) {
          final id = k as String;
          _notes[id] =
              NoteMeta.fromJson(id, Map<String, dynamic>.from(v as Map));
          final body = prefs.getString('$_bodyPrefix$id');
          final stamp = (stamps[id] as num?)?.toInt();
          if (body != null && stamp != null) {
            _content[id] = body;
            _contentStamp[id] = stamp;
            _persistedBodies[id] = body;
          }
        });
        _tagOrder = ((data['tagOrder'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList();
      }

      // 未送信の変更(こちらを優先する)
      final rawPend = prefs.getString(_pendKey);
      if (rawPend != null) {
        final data = jsonDecode(rawPend) as Map<String, dynamic>;
        final dirty = (data['dirty'] as Map?) ?? const {};
        dirty.forEach((k, v) {
          final id = k as String;
          final e = Map<String, dynamic>.from(v as Map);
          final meta = NoteMeta.fromJson(
              id, Map<String, dynamic>.from(e['m'] as Map));
          _notes[id] = meta;
          _dirty.add(id);
          final t = e['t'];
          if (t is String) {
            _content[id] = t;
            _contentStamp[id] = meta.contentAt;
            _fileDirty.add(id);
          }
        });
        for (final raw in (data['removing'] as List?) ?? const []) {
          final id = raw.toString();
          _removing.add(id);
          _notes.remove(id);
          _content.remove(id);
          _contentStamp.remove(id);
          _dirty.remove(id);
          _fileDirty.remove(id);
        }
        if (data['orderDirty'] == true) {
          _orderDirty = true;
          _tagOrder = ((data['tagOrder'] as List?) ?? const [])
              .map((e) => e.toString())
              .toList();
        }
      }
      _lastIndexJson = rawIdx;
      _lastPendingJson = rawPend;

      // 一覧に無いノートの、古い本文キャッシュを片付ける
      for (final key in prefs.getKeys().toList()) {
        if (key.startsWith(_bodyPrefix) &&
            !_notes.containsKey(key.substring(_bodyPrefix.length))) {
          await prefs.remove(key);
        }
      }
      if (_notes.isNotEmpty) loading = false;
    } catch (_) {
      // 壊れていたら、読み込めた分も捨てて、保存なしの状態から始める(Dropbox から取り直す)
      _notes = {};
      _content.clear();
      _contentStamp.clear();
      _persistedBodies.clear();
      _dirty.clear();
      _fileDirty.clear();
      _removing.clear();
      _tagOrder = [];
      _orderDirty = false;
      _lastIndexJson = null;
      _lastPendingJson = null;
    }
    _localReady = true;
  }

  /// 端末内への保存を、予約する。すでに、これより早い予約があるときは、遅らせない。
  void _scheduleSave({Duration delay = _saveDelay}) {
    if (_disposed || !_localReady) return;
    final due = DateTime.now().add(delay);
    final cur = _saveDue;
    if ((_saveTimer?.isActive ?? false) && cur != null && !cur.isAfter(due)) {
      return;
    }
    _saveTimer?.cancel();
    _saveDue = due;
    _saveTimer = Timer(delay, () => unawaited(_flushLocal()));
  }

  /// 端末内への保存を、いますぐ済ませる(アプリが裏に回るとき用)。
  void saveLocalNow() => _scheduleSave(delay: Duration.zero);

  Future<void> _flushLocal() async {
    if (!_localReady) return;
    if (_saving) {
      _saveAgain = true; // 書き込み中に変わったら、終わったあとに、もう一度書く
      return;
    }
    _saving = true;
    try {
      do {
        _saveAgain = false;
        await _writeLocal();
      } while (_saveAgain && _localReady);
    } catch (_) {
      // 容量不足などで書けなくても、アプリの動作は止めない(次の機会に、また書く)
    } finally {
      _saving = false;
    }
  }

  /// 実際の書き込み。順番は、未送信 → 本文 → 一覧(未送信を先に確定させる)。変わったものだけを書く。
  Future<void> _writeLocal() async {
    final prefs = await SharedPreferences.getInstance();

    // (1) 未送信の変更
    final dirty = <String, dynamic>{};
    for (final id in _dirty) {
      final m = _notes[id];
      if (m == null) continue;
      dirty[id] = {
        'm': m.toJson(),
        't': _fileDirty.contains(id) ? _content[id] : null,
      };
    }
    final pendingJson = jsonEncode({
      'v': 1,
      'dirty': dirty,
      'removing': _removing.toList(),
      'orderDirty': _orderDirty,
      if (_orderDirty) 'tagOrder': _tagOrder,
    });
    if (pendingJson != _lastPendingJson) {
      await prefs.setString(_pendKey, pendingJson);
      _lastPendingJson = pendingJson;
    }
    if (!_localReady) return;

    // (2) 本文のキャッシュ
    final want = <String>[
      for (final id in _notes.keys)
        if (_content.containsKey(id)) id
    ];
    for (final id in want) {
      final t = _content[id];
      if (t != null && _persistedBodies[id] != t) {
        await prefs.setString('$_bodyPrefix$id', t);
        _persistedBodies[id] = t;
        if (!_localReady) return;
      }
    }
    final wantSet = want.toSet();
    for (final id in _persistedBodies.keys.toList()) {
      if (!wantSet.contains(id)) {
        await prefs.remove('$_bodyPrefix$id');
        _persistedBodies.remove(id);
      }
    }
    if (!_localReady) return;

    // (3) 一覧(メタ情報・本文の更新日時・タグの並び順)
    final stamps = <String, int>{
      for (final id in _notes.keys)
        if (_content.containsKey(id) && _contentStamp.containsKey(id))
          id: _contentStamp[id]!
    };
    final indexJson = jsonEncode({
      'v': 1,
      'notes': _notes.map((k, v) => MapEntry(k, v.toJson())),
      'stamps': stamps,
      'tagOrder': _tagOrder,
    });
    if (indexJson != _lastIndexJson) {
      await prefs.setString(_idxKey, indexJson);
      _lastIndexJson = indexJson;
    }
  }

  /// ログアウトのときに、端末内に保存したものを、すべて消す(ほかのアカウントに見えないように)。
  /// 未送信の変更も、ここで消える。
  Future<void> clearLocalData() async {
    _localReady = false;
    _saveTimer?.cancel();
    while (_saving) {
      await Future.delayed(const Duration(milliseconds: 20));
    }
    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs.getKeys().toList()) {
      if (key.startsWith('sn_cache_')) await prefs.remove(key);
    }
  }

  // ── 一覧(index.json)の復旧 ────────────────────────────────────

  /// この端末に残っているノートの内容で、Dropbox の index.json を作り直す(本文ファイルは、そのまま)。
  /// タグ・ピン留め・ゴミ箱の情報も、この端末にあるものが戻る。送るノートの数を返す。
  int restoreIndexFromLocal() {
    indexProblem = null; // これで、index.json への書き込みの停止が解ける
    final now = DateTime.now().millisecondsSinceEpoch;
    final ids = _notes.keys.toList();
    for (final id in ids) {
      _notes[id] = _notes[id]!.copyWith(changedAt: now);
      _dirty.add(id);
    }
    if (_tagOrder.isNotEmpty) _orderDirty = true;
    _notify(saveNow: true);
    _enqueue(() => _pushMany(ids));
    if (_orderDirty) _enqueue(_pushOrder);
    return ids.length;
  }

  /// Dropbox の notes フォルダにある本文ファイルから、一覧に無いノートを追加する。
  /// (index.json が壊れた・消えたときの復旧用。いまある一覧のノートは、変更しない)
  /// タイトルとプレビューは、本文から作り直す。更新日時は、ファイルの更新日時にする。
  /// タグ・ピン留め・ゴミ箱の情報は、index.json にしか無いので、戻らない。追加したノートの数を返す。
  Future<int> rebuildIndexFromFolder() async {
    final files = await _svc.listNoteFiles();
    final add = files
        .where((f) => !_notes.containsKey(f.id) && !_removing.contains(f.id))
        .toList();
    if (add.isEmpty) return 0;

    final got = await _fetchBodies(add.map((f) => f.id).toList());
    final now = DateTime.now().millisecondsSinceEpoch;
    final ids = <String>[];
    for (final f in add) {
      final text = got[f.id] ?? '';
      if (text.trim().isEmpty) continue; // 空の本文ファイルは、飛ばす
      _notes[f.id] = NoteMeta(
        id: f.id,
        title: titleOf(text),
        preview: previewOf(text),
        pinned: false,
        deleted: false,
        tags: const [],
        createdAt: f.modifiedMs,
        contentAt: f.modifiedMs,
        changedAt: now,
      );
      _content[f.id] = text;
      _contentStamp[f.id] = f.modifiedMs;
      _dirty.add(f.id); // 本文ファイルは、すでに Dropbox にあるので、index.json だけを送る
      ids.add(f.id);
    }
    if (ids.isEmpty) return 0;
    indexProblem = null;
    _notify(saveNow: true);
    _enqueue(() => _pushMany(ids));
    return ids.length;
  }

  // ── 同期 ─────────────────────────────────────────────────────
  Future<void> refresh({bool force = false}) async {
    if (_jobs > 0) return; // 送信中は競合を避けてスキップ
    if (_hasUnsent && _fetchedOnce && !_indexBlocked) {
      _retryPending(); // 未送信の変更があれば、まず再送
      return;
    }
    try {
      // 起動してから、まだ一度も取得していないときは、必ず取得する(圏外で溜めた変更を送る前に、最新を見る)
      if (!force && _fetchedOnce) {
        final rev = await _svc.indexRev();
        if (rev == _snap.rev) {
          lastSynced = DateTime.now();
          error = null;
          _markOnline();
          unawaited(_syncContents()); // 前回、取り切れなかった分があれば、続きを取得
          unawaited(_autoBackupIfNeeded()); // 今日まだなら、バックアップ
          _notify();
          return;
        }
      }
      final snap = await _svc.fetchIndex();
      _snap = snap;
      _fetchedOnce = true;
      final localHas = _notes.values.any((n) => !_dirty.contains(n.id));
      if (snap.notes.isEmpty && localHas) {
        // Dropbox の index.json が空(または無い)のに、この端末にはノートが残っている。
        // 端末内のノートを消さず、index.json も書き換えずに、利用者に選んでもらう。
        indexProblem = IndexProblem(
          snap.rev == null
              ? 'Dropbox に index.json が見つかりません。この端末には、ノートが残っています。'
              : 'Dropbox の index.json に、ノートが1件もありません。この端末には、ノートが残っています。',
          localCopyAvailable: true,
        );
      } else {
        _adoptOrder(snap);
        _applyRemote(snap.notes);
        indexProblem = (snap.notes.isEmpty && _notes.isEmpty)
            ? IndexProblem(
                snap.rev == null
                    ? 'Dropbox に、ノートの一覧(index.json)がありません。初めて使うときは、このままで大丈夫です。'
                        '以前のノートが Dropbox に残っているときは、下のボタンで、一覧を作り直せます。'
                    : 'Dropbox の index.json に、ノートが1件もありません。'
                        '以前のノートが Dropbox に残っているときは、下のボタンで、一覧を作り直せます。',
                localCopyAvailable: false,
              )
            : null;
      }
      lastSynced = DateTime.now();
      error = null;
      _markOnline();
      unawaited(_syncContents()); // 本文の取得は、裏で進める
      unawaited(_autoBackupIfNeeded()); // 今日まだなら、バックアップ(未送信の変更があるときは、取らない)
      if (_hasUnsent) _retryPending(); // 圏外で溜めた変更を、ここで送る
    } catch (e) {
      if (_isNetworkError(e)) {
        // 通信できないだけ。赤い帯は出さず、静かに再試行する(未送信の変更は、端末内に残っている)
        offline = true;
        error = null;
        _scheduleNetRetry();
      } else {
        error = '同期に失敗しました: $e';
      }
    } finally {
      loading = false;
      _notify();
    }
  }

  /// 取得した index をローカルへ反映する。未同期の自分の変更は、より新しければ守る。
  void _applyRemote(Map<String, NoteMeta> remote) {
    final merged = <String, NoteMeta>{};
    final lostEdits = <NoteMeta>[]; // 競合で負けた、本文の編集
    remote.forEach((id, r) {
      if (_removing.contains(id)) return;
      final l = _notes[id];
      if (l != null && _dirty.contains(id) && l.changedAt >= r.changedAt) {
        merged[id] = l; // 自分の未送信の変更のほうが新しい
      } else {
        if (_dirty.contains(id)) {
          // 他の端末の変更が勝った → 自分の未送信分は破棄。ただし、本文の編集は、あとでコピーとして残す
          if (_fileDirty.contains(id) && l != null) lostEdits.add(l);
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

    // 競合で負けた本文の編集は、消さずに、別のノート「(競合コピー)…」として残す。送信は、次の同期で行う。
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final l in lostEdits) {
      final text = _content[l.id];
      if (text == null || text.trim().isEmpty) continue;
      final id = _newId();
      final copy = '（競合コピー）$text';
      _notes[id] = NoteMeta(
        id: id,
        title: titleOf(copy),
        preview: previewOf(copy),
        pinned: false,
        deleted: false,
        tags: l.tags,
        createdAt: now,
        contentAt: now,
        changedAt: now,
      );
      _content[id] = copy;
      _contentStamp[id] = now;
      _dirty.add(id);
      _fileDirty.add(id);
    }
  }

  // ── 書き込みキュー ───────────────────────────────────────────
  void _enqueue(Future<void> Function() job) {
    _jobs++;
    _queue = _queue.then((_) async {
      try {
        await job();
        error = null;
      } catch (e) {
        if (_isNetworkError(e)) {
          offline = true;
          error = null;
          _scheduleNetRetry();
        } else {
          error = '保存に失敗しました(自動で再試行します): $e';
        }
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
    if (_orderDirty) _enqueue(_pushOrder);
  }

  Future<void> _push(String id) async {
    if (_indexBlocked) return;
    final meta = _notes[id];
    if (meta == null || !_dirty.contains(id)) return;
    final stamp = meta.changedAt;

    if (_fileDirty.contains(id)) {
      final text = _content[id];
      if (text != null) await _svc.saveNote(id, text);
    }
    final res = await _svc.mutateIndex((n) => n[id] = meta, base: _snap);
    _snap = res;
    _adoptOrder(res);
    _markOnline();

    final cur = _notes[id];
    if (cur != null && cur.changedAt == stamp) {
      _dirty.remove(id);
      _fileDirty.remove(id);
    }
    _applyRemote(res.notes);
    lastSynced = DateTime.now();
  }

  /// 複数ノートのメタ情報だけを、index.json の1回の更新でまとめて送る(タグの一括変更用)。
  /// 本文が未アップロードのノートは、ここでは送らない(そのノート自身の _push が送る)。
  Future<void> _pushMany(List<String> ids) async {
    if (_indexBlocked) return;
    final metas = <String, NoteMeta>{};
    for (final id in ids) {
      final m = _notes[id];
      if (m != null && _dirty.contains(id) && !_fileDirty.contains(id)) {
        metas[id] = m;
      }
    }
    if (metas.isEmpty) return;
    final stamps = {for (final e in metas.entries) e.key: e.value.changedAt};

    final res = await _svc.mutateIndex((n) => n.addAll(metas), base: _snap);
    _snap = res;
    _adoptOrder(res);
    _markOnline();

    for (final e in stamps.entries) {
      final cur = _notes[e.key];
      if (cur != null && cur.changedAt == e.value) {
        _dirty.remove(e.key);
      }
    }
    _applyRemote(res.notes);
    lastSynced = DateTime.now();
  }

  Future<void> _purge(String id) async {
    if (_indexBlocked) return;
    await _svc.deleteNote(id);
    final res = await _svc.mutateIndex((n) => n.remove(id), base: _snap);
    _snap = res;
    _adoptOrder(res);
    _markOnline();
    _removing.remove(id);
    _applyRemote(res.notes);
    lastSynced = DateTime.now();
  }

  // ── 操作 ─────────────────────────────────────────────────────

  /// 新しいノートの ID を発行する。内容が入力されるまで Dropbox には何も書かない。
  /// [tags] を渡すと、最初の保存のときに、そのタグが付く。
  String createNote({List<String> tags = const []}) {
    final id = _newId();
    _content[id] = '';
    if (tags.isNotEmpty) _pendingTags[id] = List<String>.of(tags);
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
    _scheduleSave();
    return text;
  }

  void saveContent(String id, String text) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final old = _notes[id] ??
        NoteMeta.create(id).copyWith(
          tags: _pendingTags.remove(id) ?? const <String>[],
        );
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
    _notify(saveNow: true);
    _enqueue(() => _push(id));
  }

  void _changeMeta(String id, NoteMeta Function(NoteMeta) f) {
    final old = _notes[id];
    if (old == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    _notes[id] = f(old).copyWith(changedAt: now);
    _dirty.add(id);
    _notify(saveNow: true);
    _enqueue(() => _push(id));
  }

  void setPinned(String id, bool v) =>
      _changeMeta(id, (m) => m.copyWith(pinned: v));

  void setDeleted(String id, bool v) =>
      _changeMeta(id, (m) => m.copyWith(deleted: v));

  /// タグを丸ごと置き換える。並び順(contentAt)は変わらない。
  void setTags(String id, List<String> tags) =>
      _changeMeta(id, (m) => m.copyWith(tags: List<String>.unmodifiable(tags)));

  /// タグを追加する(すでにあるもの=大文字小文字違いを含む=は無視)。
  void addTags(String id, List<String> add) {
    final m = _notes[id];
    if (m == null) return;
    final have = m.tags.map((t) => t.toLowerCase()).toSet();
    final next = [...m.tags];
    for (final t in add) {
      if (have.add(t.toLowerCase())) next.add(t);
    }
    if (next.length == m.tags.length) return;
    setTags(id, next);
  }

  /// タグを1つ外す(大文字小文字は区別しない)。
  void removeTag(String id, String tag) {
    final m = _notes[id];
    if (m == null) return;
    final k = tag.toLowerCase();
    final next = m.tags.where((t) => t.toLowerCase() != k).toList();
    if (next.length == m.tags.length) return;
    setTags(id, next);
  }

  // ── タグの一括変更 ───────────────────────────────────────────

  /// 全ノート(ゴミ箱内も含む)に対して、タグを変換する。
  /// [f] が null を返したノートは変更しない。
  void _bulkTags(List<String>? Function(List<String> tags) f) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final ids = <String>[];
    for (final e in _notes.entries.toList()) {
      final next = f(e.value.tags);
      if (next == null) continue;
      _notes[e.key] = e.value.copyWith(
        tags: List<String>.unmodifiable(next),
        changedAt: now,
      );
      _dirty.add(e.key);
      ids.add(e.key);
    }
    if (ids.isEmpty) return;
    _notify(saveNow: true);
    _enqueue(() => _pushMany(ids));
  }

  /// タグの名前を変える。変更後の名前が、すでにあるタグと同じ(大文字小文字違い含む)なら、統合される。
  /// [newName] にスペース等が含まれる場合は、最初のタグだけを使う。
  void renameTag(String oldTag, String newName) {
    final parsed = parseTags(newName);
    if (parsed.isEmpty) return;
    final nn = parsed.first;
    final ok = oldTag.toLowerCase();
    _renameInOrder(ok, nn.toLowerCase()); // 並び順の中の位置を引き継ぐ
    _bulkTags((tags) {
      if (!tags.any((t) => t.toLowerCase() == ok)) return null;
      final out = <String>[];
      final seen = <String>{};
      for (final t in tags) {
        final v = t.toLowerCase() == ok ? nn : t;
        if (seen.add(v.toLowerCase())) out.add(v);
      }
      return out;
    });
  }

  /// タグを、全ノートから外す(ノート自体は消えない)。
  void deleteTag(String tag) {
    final k = tag.toLowerCase();
    _removeFromOrder(k);
    _bulkTags((tags) {
      if (!tags.any((t) => t.toLowerCase() == k)) return null;
      return tags.where((t) => t.toLowerCase() != k).toList();
    });
  }

  void removeForever(String id) {
    _notes.remove(id);
    _dirty.remove(id);
    _fileDirty.remove(id);
    _content.remove(id);
    _contentStamp.remove(id);
    _pendingTags.remove(id);
    _removing.add(id);
    _notify(saveNow: true);
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