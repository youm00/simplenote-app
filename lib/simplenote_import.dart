// simplenote_import.dart
// 本家 Simplenote の書き出しファイルを、このアプリのバックアップ形式(BackupData)に変換する。
//
// 本家の書き出し(Settings > Export Notes)は、ZIP の中に source/notes.json が入っている:
// {
//   "activeNotes":  [ { "id": "...", "content": "タイトル\r\n本文", "creationDate": "2024-06-14T06:24:41.000Z",
//                       "lastModified": "...Z", "tags": ["Mobile"] } ],
//   "trashedNotes": [ ...同じ形(ゴミ箱内)... ]
// }
// ・ピン留めは、書き出しに入っていない(キーが無ければ、ピン留めなしとして扱う)。
// ・タグの並び順は、入っていない。
// ZIP のままでも、取り出した notes.json でも、読み込める。

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'backup_format.dart';

/// 本家 Simplenote の書き出しファイル(ZIP または notes.json)を読み取る。
/// 形式が違うときは、日本語のメッセージつきの FormatException。
BackupData parseSimplenoteExport(Uint8List bytes) {
  String source;
  if (bytes.length >= 2 && bytes[0] == 0x50 && bytes[1] == 0x4B) {
    // 'PK' で始まる → ZIP
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw const FormatException('ZIPファイルを開けませんでした');
    }
    ArchiveFile? found;
    for (final f in archive) {
      if (!f.isFile) continue;
      final name = f.name.replaceAll('\\', '/');
      if (name.split('/').last != 'notes.json') continue;
      found = f;
      if (name.contains('source/')) break; // source フォルダのものを優先
    }
    if (found == null) {
      throw const FormatException('ZIPの中に notes.json が見つかりません');
    }
    source = utf8.decode(found.content as List<int>, allowMalformed: true);
  } else {
    source = utf8.decode(bytes, allowMalformed: true);
  }

  if (source.startsWith('\uFEFF')) source = source.substring(1); // BOM
  Object? data;
  try {
    data = jsonDecode(source);
  } on FormatException {
    throw const FormatException('JSONとして読めませんでした');
  }
  if (data is! Map ||
      (data['activeNotes'] is! List && data['trashedNotes'] is! List)) {
    throw const FormatException('本家 Simplenote の書き出しファイルではありません');
  }

  final notes = <BackupNote>[];
  final ids = <String>{};
  var unreadable = 0;

  void collect(Object? list, {required bool deleted}) {
    if (list is! List) return;
    for (final r in list) {
      final n = _convert(r, deleted: deleted);
      if (n == null || !ids.add(n.id)) {
        unreadable++;
        continue;
      }
      notes.add(n);
    }
  }

  collect(data['activeNotes'], deleted: false);
  collect(data['trashedNotes'], deleted: true);

  return BackupData(
    exportedAt: DateTime.now().millisecondsSinceEpoch,
    tagOrder: const [], // 本家の書き出しには、タグの並び順が入っていない
    notes: notes,
    unreadable: unreadable,
  );
}

/// 本家のノート1件を変換する。読み取れない形のときは null。
BackupNote? _convert(Object? j, {required bool deleted}) {
  if (j is! Map) return null;
  final id = j['id'];
  final content = j['content'];
  if (id is! String || content is! String) return null;

  // 改行を \n にそろえる(本家は \r\n)
  final text = content.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

  final created = _ms(j['creationDate']);
  final modified = _ms(j['lastModified']);

  final seen = <String>{};
  final tags = <String>[];
  final raw = j['tags'];
  if (raw is List) {
    for (final t in raw) {
      // このアプリのタグには、スペースやカンマを使えないので、_ に置き換える
      var s = t
          .toString()
          .replaceAll(RegExp(r'[\s,，、]+'), '_')
          .replaceFirst(RegExp(r'^[#＃]+'), '')
          .trim();
      if (s.runes.length > 30) s = String.fromCharCodes(s.runes.take(30));
      if (s.isNotEmpty && seen.add(s.toLowerCase())) tags.add(s);
    }
  }

  return BackupNote(
    id: id,
    text: text,
    tags: tags,
    pinned: j['pinned'] == true, // 書き出しに無ければ、false
    deleted: deleted,
    createdAt: created != 0 ? created : modified,
    contentAt: modified != 0 ? modified : created,
  );
}

/// ISO 形式の日時文字列を、ミリ秒にする。読めなければ 0。
int _ms(Object? v) {
  if (v is! String) return 0;
  return DateTime.tryParse(v)?.millisecondsSinceEpoch ?? 0;
}