import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    initialDark: prefs.getBool('sn_dark_mode') ?? true,
  ));
}

class NotesApp extends StatefulWidget {
  final DropboxAuthService auth;
  final bool initialDark;
  const NotesApp({super.key, required this.auth, required this.initialDark});

  static _NotesAppState of(BuildContext context) =>
      context.findAncestorStateOfType<_NotesAppState>()!;

  @override
  State<NotesApp> createState() => _NotesAppState();
}

class _NotesAppState extends State<NotesApp> {
  late bool isDark = widget.initialDark;

  Future<void> toggleTheme() async {
    setState(() => isDark = !isDark);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('sn_dark_mode', isDark);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Notes',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF5C6BC0),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF5C6BC0),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      themeMode: isDark ? ThemeMode.dark : ThemeMode.light,
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