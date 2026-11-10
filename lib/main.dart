import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_theme.dart';
import 'dropbox_auth_service.dart';
import 'dropbox_notes_service.dart';
import 'notes_store.dart';
import 'screens/notes_list_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final auth = DropboxAuthService();
  await auth.handleWebRedirect(); // Web: Dropbox から戻った直後の code を処理
  final prefs = await SharedPreferences.getInstance();
  runApp(NotesApp(
    auth: auth,
    initialTheme: loadThemeKind(prefs),
  ));
}

class NotesApp extends StatefulWidget {
  final DropboxAuthService auth;
  final AppThemeKind initialTheme;
  const NotesApp({super.key, required this.auth, required this.initialTheme});

  static _NotesAppState of(BuildContext context) =>
      context.findAncestorStateOfType<_NotesAppState>()!;

  @override
  State<NotesApp> createState() => _NotesAppState();
}

class _NotesAppState extends State<NotesApp> {
  late AppThemeKind themeKind = widget.initialTheme;

  /// テーマを切り替えて、保存する(設定画面から呼ばれる)
  Future<void> setTheme(AppThemeKind k) async {
    if (k == themeKind) return;
    setState(() => themeKind = k);
    await saveThemeKind(k);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Notes',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(themeKind),
      home: AuthGate(auth: widget.auth),
    );
  }
}

/// ログイン状態に応じて「ログイン画面」と「ノート一覧」を切り替える
class AuthGate extends StatefulWidget {
  final DropboxAuthService auth;
  const AuthGate({super.key, required this.auth});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  bool? _signedIn;
  bool _busy = false;
  NotesStore? _store;

  @override
  void initState() {
    super.initState();
    _check();
  }

  @override
  void dispose() {
    _store?.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    final ok = await widget.auth.hasLogin();
    if (ok) _startStore();
    if (mounted) setState(() => _signedIn = ok);
  }

  void _startStore() {
    _store?.dispose();
    _store = NotesStore(DropboxNotesService(widget.auth))..start();
  }

  Future<void> _login() async {
    setState(() => _busy = true);
    final ok = await widget.auth.authenticate(); // Web ではページ遷移して戻ってこない
    if (!mounted) return;
    if (ok) {
      _startStore();
      setState(() {
        _signedIn = true;
        _busy = false;
      });
    } else {
      setState(() => _busy = false);
      if (!kIsWeb) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 20),
            showCloseIcon: true,
            content: Text('ログインに失敗しました\n${widget.auth.lastError ?? ''}'),
          ),
        );
      }
    }
  }

  Future<void> _logout() async {
    await _store?.clearLocalData(); // 端末内に保存したノートも消す(ほかのアカウントに見えないように)
    await widget.auth.signOut();
    final old = _store;
    if (!mounted) return;
    setState(() {
      _store = null;
      _signedIn = false;
    });
    // 画面が差し替わってから破棄する
    WidgetsBinding.instance.addPostFrameCallback((_) => old?.dispose());
  }

  @override
  Widget build(BuildContext context) {
    final signedIn = _signedIn;
    if (signedIn == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!signedIn || _store == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Notes')),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Dropbox にログインしてください'),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _busy ? null : _login,
                child: Text(_busy ? '...' : 'Dropbox でログイン'),
              ),
            ],
          ),
        ),
      );
    }
    return NotesListScreen(store: _store!, onLogout: _logout);
  }
}