// backup_files_web.dart
// Web での、バックアップファイルの保存(ダウンロード)と選択。ブラウザの標準の仕組み(package:web)を使う。

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// ファイルとして、ダウンロードさせる。(ブラウザの設定により、保存先の確認が出ることも、すぐ保存されることもある)
/// ブラウザでは、保存したかどうかを知る方法がないので、常に true を返す。
Future<bool> saveBackupFile(String fileName, Uint8List bytes) async {
  final blob = web.Blob(
    <JSAny>[bytes.toJS].toJS,
    web.BlobPropertyBag(type: 'application/json'),
  );
  final url = web.URL.createObjectURL(blob);
  final a = (web.document.createElement('a') as web.HTMLAnchorElement)
    ..href = url
    ..download = fileName;
  web.document.body!.appendChild(a);
  a.click();
  a.remove();
  web.URL.revokeObjectURL(url);
  return true;
}

/// ブラウザのファイル選択を開いて、選んだファイルの中身を返す。キャンセルなら null。
/// (ボタンを押した操作の直後に、呼び出すこと。await のあとでは、ブラウザに止められることがある)
Future<Uint8List?> pickBackupFile() {
  final completer = Completer<Uint8List?>();
  final input = (web.document.createElement('input') as web.HTMLInputElement)
    ..type = 'file'
    ..accept = '.json,application/json';

  Future<void> read() async {
    try {
      final files = input.files;
      if (files == null || files.length == 0) {
        if (!completer.isCompleted) completer.complete(null);
        return;
      }
      final buf = await files.item(0)!.arrayBuffer().toDart;
      if (!completer.isCompleted) {
        completer.complete(buf.toDart.asUint8List());
      }
    } catch (e, st) {
      if (!completer.isCompleted) completer.completeError(e, st);
    }
  }

  input.addEventListener(
    'change',
    ((web.Event _) {
      unawaited(read());
    }).toJS,
  );
  // ファイルを選ばずに閉じたとき
  input.addEventListener(
    'cancel',
    ((web.Event _) {
      if (!completer.isCompleted) completer.complete(null);
    }).toJS,
  );
  input.click();
  return completer.future;
}
