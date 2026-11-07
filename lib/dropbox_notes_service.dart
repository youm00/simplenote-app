// dropbox_notes_service.dart
//
// Dropbox 上のレイアウト(アプリフォルダ配下):
//   /simplenote/index.json        … 全ノートのメタ情報(タイトル・プレビュー・ピン・ゴミ箱・日時)
//   /simplenote/notes/<id>.txt    … ノート本文(プレーンテキスト)
//
// index.json の更新は Dropbox の rev を使った楽観的ロックで行い、
// 他の端末と同時に更新して競合した場合は、取得し直して自分の変更だけを再適用する。

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'dropbox_auth_service.dart';

const _root = '/simplenote';
const _indexPath = '$_root/index.json';
const _notesDir = '$_root/notes';

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

class IndexSnapshot {
  final String? rev; // index.json の Dropbox rev (未作成なら null)
  final Map<String, NoteMeta> notes;
  IndexSnapshot(this.rev, this.notes);
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
    if (resp.statusCode == 409) return null; // 未作成
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
    if (resp.statusCode == 409) return IndexSnapshot.empty(); // 未作成
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
    final text = utf8.decode(resp.bodyBytes);
    if (text.trim().isNotEmpty) {
      final data = jsonDecode(text) as Map<String, dynamic>;
      final raw = (data['notes'] as Map?) ?? const {};
      raw.forEach((k, v) {
        notes[k as String] =
            NoteMeta.fromJson(k, Map<String, dynamic>.from(v as Map));
      });
    }
    return IndexSnapshot(rev, notes);
  }

  Future<IndexSnapshot> _uploadIndex(
      Map<String, NoteMeta> notes, String? rev) async {
    final token = await _token();
    final body = jsonEncode({
      'v': 1,
      'notes': notes.map((k, v) => MapEntry(k, v.toJson())),
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
    return IndexSnapshot(newRev, notes);
  }

  /// index.json を「読み → 変更 → 書き」で更新する。競合したら最新を取得し直して再適用。
  Future<IndexSnapshot> mutateIndex(
    void Function(Map<String, NoteMeta> notes) mutate, {
    IndexSnapshot? base,
  }) async {
    var snap = base;
    for (var attempt = 0; attempt < 5; attempt++) {
      snap ??= await fetchIndex();
      final notes = Map<String, NoteMeta>.from(snap.notes);
      mutate(notes);
      try {
        return await _uploadIndex(notes, snap.rev);
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
    if (resp.statusCode == 409) return ''; // ファイルなし
    throw Exception('note download error ${resp.statusCode}: ${resp.body}');
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
    // 409 = すでに存在しない → OK 扱い
    if (resp.statusCode != 200 && resp.statusCode != 409) {
      throw Exception('note delete error ${resp.statusCode}: ${resp.body}');
    }
  }
}
