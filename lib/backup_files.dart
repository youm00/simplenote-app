// backup_files.dart
// バックアップファイルの「保存」と「選択」を、プラットフォームごとに切り替える入口。
//  - Android など : file_picker を使う(backup_files_io.dart)
//  - Web         : ブラウザの標準の仕組みを使う(backup_files_web.dart)
//    (Web では、file_picker の saveFile / pickFile が使えない環境があったため)
//
// 使う側は、どちらの実装かを気にせずに、次の2つを呼ぶだけでよい。
//   Future<bool> saveBackupFile(String fileName, Uint8List bytes)  … 保存できたら true
//   Future<Uint8List?> pickBackupFile()                            … キャンセルなら null
export 'backup_files_io.dart' if (dart.library.js_interop) 'backup_files_web.dart';
