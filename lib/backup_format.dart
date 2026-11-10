// backup_format.dart
// バックアップファイル(JSON)の形式と、その読み取り・書き出し。
//
// {
//   "format": "simplenote_app_backup",
//   "version": 1,
//   "exportedAt": 1730000000000,
//   "tagOrder": ["mobile", "btc"],          // タグの並び順(無ければ空)
//   "notes": [
//     {
//       "id": "...",                         // ノートID(英数字と - _ のみ)
//       "text": "本文(1行目がタイトル)",
//       "tags": ["mobile"],
//       "pinned": false,
//       "deleted": false,                    // ゴミ箱に入っているか
//       "createdAt": 1730000000000,
//       "contentAt": 1730000000000
//     }
//   ]
// }
//
// タイトルとプレビューは、本文から作り直せるので、ファイルには入れない。

import 'dart:convert';

const backupFormat = 'simplenote_app_backup';
const backupVersion = 1;

// Dropbox のパスに使うので、ASCII の安全な文字だけを許す
final _idRe = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

class BackupNote {
  final String id;
  final String text;
  final List<String> tags;
  final bool pinned;
  final bool deleted;
  final int createdAt;
  final int contentAt;

  const BackupNote({
    required this.id,
    required this.text,
    required this.tags,
    required this.pinned,
    required this.deleted,
    required this.createdAt,
    required this.contentAt,
  });

  /// ID が、取り込める形か
  bool get validId => _idRe.hasMatch(id);

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'tags': tags,
        'pinned': pinned,
        'deleted': deleted,
        'createdAt': createdAt,
        'contentAt': contentAt,
      };

  /// 読み取れない形のときは null
  static BackupNote? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'];
    final text = j['text'];
    if (id is! String || text is! String) return null;
    final seen = <String>{};
    final tags = <String>[];
    final raw = j['tags'];
    if (raw is List) {
      for (final t in raw) {
        final s = t.toString().trim();
        if (s.isNotEmpty && seen.add(s.toLowerCase())) tags.add(s);
      }
    }
    return BackupNote(
      id: id,
      text: text,
      tags: tags,
      pinned: j['pinned'] == true,
      deleted: j['deleted'] == true,
      createdAt: (j['createdAt'] as num?)?.toInt() ?? 0,
      contentAt: (j['contentAt'] as num?)?.toInt() ?? 0,
    );
  }
}

class BackupData {
  final int exportedAt; // 書き出した日時 (ms)
  final List<String> tagOrder;
  final List<BackupNote> notes;
  final int unreadable; // 読み取れなかった(または ID が重複した)ノートの数

  const BackupData({
    required this.exportedAt,
    required this.tagOrder,
    required this.notes,
    this.unreadable = 0,
  });
}

/// 読み込む前に見せる、取り込み結果の見込み
class BackupPreview {
  final int total; // ファイルに入っているノート数(読み取れたもの)
  final int trashed; // うち、ゴミ箱内
  final int added; // 新しく追加されるノート
  final int same; // いまと同じ ID のノート
  final int changed; // 同じ ID のうち、内容や状態が違うもの
  final int invalid; // 読み取れない・ID が不正で、取り込めないノート

  const BackupPreview({
    required this.total,
    required this.trashed,
    required this.added,
    required this.same,
    required this.changed,
    required this.invalid,
  });
}

/// バックアップファイルを読み取る。形式が違うときは、日本語のメッセージつきの FormatException。
BackupData parseBackup(String source) {
  if (source.startsWith('\uFEFF')) source = source.substring(1); // BOM
  Object? data;
  try {
    data = jsonDecode(source);
  } on FormatException {
    throw const FormatException('JSONとして読めませんでした');
  }
  if (data is! Map || data['format'] != backupFormat) {
    throw const FormatException('このアプリのバックアップファイルではありません');
  }
  final ver = data['version'];
  if (ver is! num || ver > backupVersion) {
    throw const FormatException('新しい版のバックアップファイルです。アプリを更新してください');
  }
  final rawNotes = data['notes'];
  if (rawNotes is! List) {
    throw const FormatException('バックアップにノートの一覧がありません');
  }

  final notes = <BackupNote>[];
  final ids = <String>{};
  var unreadable = 0;
  for (final r in rawNotes) {
    final n = BackupNote.fromJson(r);
    if (n == null || !ids.add(n.id)) {
      unreadable++;
      continue;
    }
    notes.add(n);
  }

  final order = <String>[];
  final rawOrder = data['tagOrder'];
  if (rawOrder is List) {
    final seen = <String>{};
    for (final k in rawOrder) {
      final s = k.toString().trim().toLowerCase();
      if (s.isNotEmpty && seen.add(s)) order.add(s);
    }
  }

  return BackupData(
    exportedAt: (data['exportedAt'] as num?)?.toInt() ?? 0,
    tagOrder: order,
    notes: notes,
    unreadable: unreadable,
  );
}

/// バックアップファイルの中身(JSON文字列)を作る。人が読めるよう、字下げをつける。
String encodeBackup(BackupData d) {
  return const JsonEncoder.withIndent('  ').convert({
    'format': backupFormat,
    'version': backupVersion,
    'exportedAt': d.exportedAt,
    'tagOrder': d.tagOrder,
    'notes': d.notes.map((n) => n.toJson()).toList(),
  });
}