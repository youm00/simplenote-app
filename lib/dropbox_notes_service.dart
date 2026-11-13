// dropbox_notes_service.dart
//
// Dropbox 上のレイアウト(アプリフォルダ配下):
//   /simplenote/index.json        … 全ノートのメタ情報(タイトル・プレビュー・ピン・ゴミ箱・日時)と、タグの並び順(tagOrder)
//   /simplenote/notes/<id>.txt    … ノート本文(プレーンテキスト)
//   /backup/simplenote_backup_YYYYMMDD_HHmmss.json … 自動・手動バックアップ(v17。最大365件)
//
// 全文検索用に、全ノートの本文を ZIP で一括取得する (downloadAllNotes)。
//
// index.json の更新は Dropbox の rev を使った楽観的ロックで行い、
// 他の端末と同時に更新して競合した場合は、取得し直して自分の変更だけを再適用する。

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;

import 'dropbox_auth_service.dart';

const _root = '/simplenote';
const _indexPath = '$_root/index.json';
const _notesDir = '$_root/notes';

/// バックアップの保存先(アプリフォルダの直下。Scratchpad・BulletMemo と同じ)
const _backupDir = '/backup';

/// バックアップのファイル名の先頭(この名前のファイルだけを、一覧・削除の対象にする)
const _backupPrefix = 'simplenote_backup_';

// ──────────────────────────────────────────────────────────────
// モデル
// ──────────────────────────────────────────────────────────────

class NoteMeta {
  final String id;
  final String title;
  final String preview;
  final bool pinned;
  final bool deleted;
  final List<String> tags;
  final int createdAt; // 作成日時 (ms)
  final int contentAt; // 本文の最終更新 (ms) … 並び順・表示用
  final int changedAt; // 何らかの変更の最終時刻 (ms) … 競合解決用

  const NoteMeta({
    required this.id,
    required this.title,
    required this.preview,
    required this.pinned,
    required this.deleted,
    required this.tags,
    required this.createdAt,
    required this.contentAt,
    required this.changedAt,
  });

  factory NoteMeta.create(String id) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return NoteMeta(
      id: id,
      title: '',
      preview: '',
      pinned: false,
      deleted: false,
      tags: const [],
      createdAt: now,
      contentAt: now,
      changedAt: now,
    );
  }

  NoteMeta copyWith({
    String? title,
    String? preview,
    bool? pinned,
    bool? deleted,
    List<String>? tags,
    int? contentAt,
    int? changedAt,
  }) {
    return NoteMeta(
      id: id,
      title: title ?? this.title,
      preview: preview ?? this.preview,
      pinned: pinned ?? this.pinned,
      deleted: deleted ?? this.deleted,
      tags: tags ?? this.tags,
      createdAt: createdAt,
      contentAt: contentAt ?? this.contentAt,
      changedAt: changedAt ?? this.changedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        't': title,
        'p': preview,
        'pin': pinned,
        'del': deleted,
        'tags': tags,
        'c': createdAt,
        'u': contentAt,
        's': changedAt,
      };

  factory NoteMeta.fromJson(String id, Map<String, dynamic> j) {
    return NoteMeta(
      id: id,
      title: (j['t'] as String?) ?? '',
      preview: (j['p'] as String?) ?? '',
      pinned: j['pin'] == true,
      deleted: j['del'] == true,
      tags: ((j['tags'] as List?) ?? const []).map((e) => e.toString()).toList(),
      createdAt: (j['c'] as num?)?.toInt() ?? 0,
      contentAt: (j['u'] as num?)?.toInt() ?? 0,
      changedAt: (j['s'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 本文の最初の空でない行をタイトルにする(最大100文字)
String titleOf(String text) {
  for (final line in text.split('\n')) {
    final t = line.trim();
    if (t.isNotEmpty) return String.fromCharCodes(t.runes.take(100));
  }
  return '';
}

/// タイトル行より後ろをプレビューにする(最大300文字)。一覧の検索対象にもなる。
String previewOf(String text) {
  final lines = text.split('\n');
  var i = 0;
  while (i < lines.length && lines[i].trim().isEmpty) {
    i++;
  }
  final rest = lines
      .skip(i + 1)
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .join(' ');
  return String.fromCharCodes(rest.runes.take(300));
}

/// notes フォルダにある本文ファイル1つ分の情報(index.json の復旧用)
class NoteFileInfo {
  final String id;
  final int modifiedMs; // ファイルの更新日時 (ms)
  const NoteFileInfo(this.id, this.modifiedMs);
}

/// Dropbox の backup フォルダにあるバックアップファイル1つ分の情報
class BackupFileInfo {
  final String path; // Dropbox 上のパス(ダウンロード・削除に使う)
  final String name; // ファイル名
  final int modifiedMs; // Dropbox 上の更新日時 (ms)
  final int size; // バイト数
  const BackupFileInfo(this.path, this.name, this.modifiedMs, this.size);
}

class IndexSnapshot {
  final String? rev; // index.json の Dropbox rev (未作成なら null)
  final Map<String, NoteMeta> notes;
  final List<String> tagOrder; // ドロワーのタグの並び順(小文字化したタグ名)。未設定なら空
  IndexSnapshot(this.rev, this.notes, [this.tagOrder = const []]);
  factory IndexSnapshot.empty() => IndexSnapshot(null, {});
}

class ConflictException implements Exception {
  const ConflictException();
}

// ──────────────────────────────────────────────────────────────
// サービス
// ──────────────────────────────────────────────────────────────

class DropboxNotesService {
  final DropboxAuthService auth;
  DropboxNotesService(this.auth);

  Future<String> _token() async {
    final t = await auth.getValidAccessToken();
    if (t == null) {
      throw Exception('ログインが必要です(トークンを取得できません。ネットワークを確認するか、再ログインしてください)');
    }
    return t;
  }

  String _notePath(String id) => '$_notesDir/$id.txt';

  // ── index.json の rev だけ取得 (ポーリング用・軽量) ──────────
  Future<String?> indexRev() async {
    final token = await _token();
    final resp = await http.post(
      Uri.parse('https://api.dropboxapi.com/2/files/get_metadata'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'path': _indexPath}),
    );
    if (resp.statusCode == 409 && resp.body.contains('not_found')) return null; // 未作成
    if (resp.statusCode != 200) {
      throw Exception('metadata error ${resp.statusCode}: ${resp.body}');
    }
    return (jsonDecode(resp.body) as Map<String, dynamic>)['rev'] as String?;
  }

  // ── index.json を取得 ────────────────────────────────────────
  Future<IndexSnapshot> fetchIndex() async {
    final token = await _token();
    final resp = await http.post(
      Uri.parse('https://content.dropboxapi.com/2/files/download'),
      headers: {
        'Authorization': 'Bearer $token',
        'Dropbox-API-Arg': jsonEncode({'path': _indexPath}),
      },
    );
    if (resp.statusCode == 409 && resp.body.contains('not_found')) {
      return IndexSnapshot.empty(); // 未作成
    }
    if (resp.statusCode != 200) {
      throw Exception('index download error ${resp.statusCode}: ${resp.body}');
    }

    String? rev;
    final result = resp.headers['dropbox-api-result'];
    if (result != null) {
      rev = (jsonDecode(result) as Map<String, dynamic>)['rev'] as String?;
    }
    rev ??= await indexRev(); // ヘッダーが読めない環境向けの保険

    final notes = <String, NoteMeta>{};
    var order = <String>[];
    final text = utf8.decode(resp.bodyBytes);
    if (text.trim().isNotEmpty) {
      final data = jsonDecode(text) as Map<String, dynamic>;
      order = ((data['tagOrder'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList();
      final raw = (data['notes'] as Map?) ?? const {};
      raw.forEach((k, v) {
        notes[k as String] =
            NoteMeta.fromJson(k, Map<String, dynamic>.from(v as Map));
      });
    }
    return IndexSnapshot(rev, notes, order);
  }

  Future<IndexSnapshot> _uploadIndex(
      Map<String, NoteMeta> notes, String? rev, List<String> order) async {
    final token = await _token();
    final body = jsonEncode({
      'v': 1,
      'notes': notes.map((k, v) => MapEntry(k, v.toJson())),
      if (order.isNotEmpty) 'tagOrder': order,
    });
    final resp = await http.post(
      Uri.parse('https://content.dropboxapi.com/2/files/upload'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/octet-stream',
        'Dropbox-API-Arg': jsonEncode({
          'path': _indexPath,
          'mode': rev == null ? 'add' : {'.tag': 'update', 'update': rev},
          'autorename': false,
          'mute': true,
        }),
      },
      body: utf8.encode(body),
    );
    if (resp.statusCode == 409 && resp.body.contains('conflict')) {
      throw const ConflictException();
    }
    if (resp.statusCode != 200) {
      throw Exception('index upload error ${resp.statusCode}: ${resp.body}');
    }
    final newRev = (jsonDecode(resp.body) as Map<String, dynamic>)['rev'] as String?;
    return IndexSnapshot(newRev, notes, order);
  }

  /// index.json を「読み → 変更 → 書き」で更新する。競合したら最新を取得し直して再適用。
  Future<IndexSnapshot> mutateIndex(
    void Function(Map<String, NoteMeta> notes) mutate, {
    IndexSnapshot? base,
    List<String> Function(List<String> order)? mutateOrder,
  }) async {
    var snap = base;
    for (var attempt = 0; attempt < 5; attempt++) {
      snap ??= await fetchIndex();
      final notes = Map<String, NoteMeta>.from(snap.notes);
      mutate(notes);
      // タグの並び順は、指定がなければ、取得した最新のものをそのまま書き戻す(消さない)
      final order =
          mutateOrder != null ? mutateOrder(snap.tagOrder) : snap.tagOrder;
      try {
        return await _uploadIndex(notes, snap.rev, order);
      } on ConflictException {
        snap = null; // 取得し直して再試行
      }
    }
    throw Exception('index.json の更新が他の端末と競合し続けました');
  }

  // ── ノート本文 ───────────────────────────────────────────────
  Future<String> loadNote(String id) async {
    final token = await _token();
    final resp = await http.post(
      Uri.parse('https://content.dropboxapi.com/2/files/download'),
      headers: {
        'Authorization': 'Bearer $token',
        'Dropbox-API-Arg': jsonEncode({'path': _notePath(id)}),
      },
    );
    if (resp.statusCode == 200) return utf8.decode(resp.bodyBytes);
    if (resp.statusCode == 409 && resp.body.contains('not_found')) {
      return ''; // ファイルなし
    }
    throw Exception('note download error ${resp.statusCode}: ${resp.body}');
  }

  /// 全ノートの本文を、ZIP 1回でまとめて取得する (全文検索用)。 id -> 本文
  /// notes フォルダがまだ無い場合は、空を返す。
  Future<Map<String, String>> downloadAllNotes() async {
    final token = await _token();
    final resp = await http.post(
      Uri.parse('https://content.dropboxapi.com/2/files/download_zip'),
      headers: {
        'Authorization': 'Bearer $token',
        'Dropbox-API-Arg': jsonEncode({'path': _notesDir}),
      },
    );
    if (resp.statusCode == 409 && resp.body.contains('not_found')) {
      return {};
    }
    if (resp.statusCode != 200) {
      throw Exception('notes zip error ${resp.statusCode}: ${resp.body}');
    }
    final archive = ZipDecoder().decodeBytes(resp.bodyBytes);
    final out = <String, String>{};
    for (final f in archive) {
      if (!f.isFile) continue;
      final name = f.name.split('/').last;
      if (!name.endsWith('.txt')) continue;
      final id = name.substring(0, name.length - 4);
      out[id] = utf8.decode(f.content as List<int>, allowMalformed: true);
    }
    return out;
  }

  /// notes フォルダにある本文ファイルの一覧(ID と更新日時)。フォルダが無ければ空。
  Future<List<NoteFileInfo>> listNoteFiles() async {
    final token = await _token();
    final out = <NoteFileInfo>[];
    String? cursor;
    while (true) {
      final resp = await http.post(
        Uri.parse(cursor == null
            ? 'https://api.dropboxapi.com/2/files/list_folder'
            : 'https://api.dropboxapi.com/2/files/list_folder/continue'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(cursor == null
            ? {'path': _notesDir, 'limit': 2000}
            : {'cursor': cursor}),
      );
      if (resp.statusCode == 409 && resp.body.contains('not_found')) return out;
      if (resp.statusCode != 200) {
        throw Exception('notes list error ${resp.statusCode}: ${resp.body}');
      }
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      for (final e in (data['entries'] as List)) {
        final m = e as Map<String, dynamic>;
        if (m['.tag'] != 'file') continue;
        final name = m['name'] as String;
        if (!name.endsWith('.txt')) continue;
        final t = DateTime.tryParse(
            (m['server_modified'] ?? m['client_modified'] ?? '') as String);
        out.add(NoteFileInfo(
          name.substring(0, name.length - 4),
          (t ?? DateTime.now()).millisecondsSinceEpoch,
        ));
      }
      if (data['has_more'] != true) return out;
      cursor = data['cursor'] as String;
    }
  }

  Future<void> saveNote(String id, String text) async {
    final token = await _token();
    final resp = await http.post(
      Uri.parse('https://content.dropboxapi.com/2/files/upload'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/octet-stream',
        'Dropbox-API-Arg': jsonEncode({
          'path': _notePath(id),
          'mode': 'overwrite',
          'autorename': false,
          'mute': true,
        }),
      },
      body: utf8.encode(text),
    );
    if (resp.statusCode != 200) {
      throw Exception('note upload error ${resp.statusCode}: ${resp.body}');
    }
  }

  Future<void> deleteNote(String id) async {
    final token = await _token();
    final resp = await http.post(
      Uri.parse('https://api.dropboxapi.com/2/files/delete_v2'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'path': _notePath(id)}),
    );
    // 409 のうち、「すでに存在しない」(not_found)だけを、OK 扱いにする。
    // 書き込みの混雑(too_many_write_operations)など、ほかの409は、エラーにして、あとで再試行させる
    // (エラーにしないと、本文ファイルが残ったまま、一覧からだけ消えてしまう)。
    final alreadyGone =
        resp.statusCode == 409 && resp.body.contains('not_found');
    if (resp.statusCode != 200 && !alreadyGone) {
      throw Exception('note delete error ${resp.statusCode}: ${resp.body}');
    }
  }

  // ── バックアップ(/backup フォルダ) ───────────────────────────

  /// バックアップを、backup フォルダに新しいファイルとして保存する。
  /// 日時つきの新規ファイルなので、複数の端末が同じ日に保存しても、上書きしない。
  Future<void> uploadBackup(String fileName, List<int> bytes) async {
    final token = await _token();
    final resp = await http.post(
      Uri.parse('https://content.dropboxapi.com/2/files/upload'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/octet-stream',
        'Dropbox-API-Arg': jsonEncode({
          'path': '$_backupDir/$fileName',
          'mode': 'add',
          'autorename': true, // 同じ名前があっても、別名で保存する(上書きしない)
          'mute': true,
        }),
      },
      body: bytes,
    );
    if (resp.statusCode != 200) {
      throw Exception('backup upload error ${resp.statusCode}: ${resp.body}');
    }
  }

  /// backup フォルダにあるバックアップの一覧(新しい順)。フォルダが無ければ空。
  /// このアプリが作った名前(simplenote_backup_*.json)のファイルだけを返す。
  Future<List<BackupFileInfo>> listBackups() async {
    final token = await _token();
    final out = <BackupFileInfo>[];
    String? cursor;
    while (true) {
      final resp = await http.post(
        Uri.parse(cursor == null
            ? 'https://api.dropboxapi.com/2/files/list_folder'
            : 'https://api.dropboxapi.com/2/files/list_folder/continue'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(cursor == null
            ? {'path': _backupDir, 'limit': 2000}
            : {'cursor': cursor}),
      );
      if (resp.statusCode == 409 && resp.body.contains('not_found')) {
        return out; // まだ backup フォルダが無い
      }
      if (resp.statusCode != 200) {
        throw Exception('backup list error ${resp.statusCode}: ${resp.body}');
      }
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      for (final e in (data['entries'] as List)) {
        final m = e as Map<String, dynamic>;
        if (m['.tag'] != 'file') continue;
        final name = m['name'] as String;
        if (!name.startsWith(_backupPrefix) || !name.endsWith('.json')) continue;
        final t = DateTime.tryParse(
            (m['server_modified'] ?? m['client_modified'] ?? '') as String);
        out.add(BackupFileInfo(
          (m['path_display'] as String?) ?? '$_backupDir/$name',
          name,
          (t ?? DateTime.fromMillisecondsSinceEpoch(0)).millisecondsSinceEpoch,
          (m['size'] as num?)?.toInt() ?? 0,
        ));
      }
      if (data['has_more'] != true) break;
      cursor = data['cursor'] as String;
    }
    out.sort((a, b) => b.modifiedMs.compareTo(a.modifiedMs)); // 新しい順
    return out;
  }

  /// バックアップファイルの中身を取得する。
  Future<Uint8List> downloadBackup(String path) async {
    final token = await _token();
    final resp = await http.post(
      Uri.parse('https://content.dropboxapi.com/2/files/download'),
      headers: {
        'Authorization': 'Bearer $token',
        'Dropbox-API-Arg': jsonEncode({'path': path}),
      },
    );
    if (resp.statusCode != 200) {
      throw Exception('backup download error ${resp.statusCode}: ${resp.body}');
    }
    return resp.bodyBytes;
  }

  /// バックアップが [keep] 件を超えていたら、古いものから削除する。削除した件数を返す。
  /// 書き込みの混雑などで削除に失敗したら、そこで止めて、次の機会に続きをやる。
  Future<int> pruneBackups({int keep = 365}) async {
    final all = await listBackups(); // 新しい順
    if (all.length <= keep) return 0;
    final token = await _token();
    var deleted = 0;
    for (final f in all.sublist(keep).reversed) {
      // 古いものから
      final resp = await http.post(
        Uri.parse('https://api.dropboxapi.com/2/files/delete_v2'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'path': f.path}),
      );
      final alreadyGone =
          resp.statusCode == 409 && resp.body.contains('not_found');
      if (resp.statusCode != 200 && !alreadyGone) break;
      deleted++;
    }
    return deleted;
  }
}