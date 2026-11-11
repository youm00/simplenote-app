// backup_files_io.dart
// Android など(Web 以外)での、バックアップファイルの保存と選択。file_picker を使う。

import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// システムの「保存」画面で保存先を選んで、保存する。保存したら true、キャンセルなら false。
Future<bool> saveBackupFile(String fileName, Uint8List bytes) async {
  final saved = await FilePicker.saveFile(
    dialogTitle: 'バックアップの保存先',
    fileName: fileName,
    bytes: bytes,
    mimeType: 'application/json',
  );
  return saved != null;
}

/// システムのファイル選択画面で、ファイルを1つ選んで、中身を返す。キャンセルなら null。
Future<Uint8List?> pickBackupFile() async {
  final file = await FilePicker.pickFile(
    dialogTitle: 'バックアップファイルを選択',
    type: FileType.any,
  );
  if (file == null) return null;
  return file.readAsBytes();
}
