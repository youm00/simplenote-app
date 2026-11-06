import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Supabase ダッシュボード → Project Settings → API の値を入れる
// (anon / publishable キーは公開前提。データはRLSで守られる)
const supabaseUrl = 'https://kfqlanpdmjeprysollqn.supabase.co';
const supabaseAnonKey = 'sb_publishable_lzsVa2dqFnH0izVrUbzfDw_h8u2nGci';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(url: supabaseUrl, anonKey: supabaseAnonKey);
  runApp(const MyApp());
}

final supabase = Supabase.instance.client;

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Notes',
      themeMode: ThemeMode.system,
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: StreamBuilder<AuthState>(
        stream: supabase.auth.onAuthStateChange,
        builder: (context, _) => supabase.auth.currentSession == null
            ? const LoginPage()
            : const NotesPage(),
      ),
    );
  }
}

// ---------------------------------------------------------------- ログイン

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;

  Future<void> _login() async {
    setState(() => _busy = true);
    try {
      await supabase.auth.signInWithPassword(
        email: _email.text.trim(),
        password: _password.text,
      );
    } on AuthException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('ログイン失敗: ${e.message}')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ログイン')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: ListView(
              padding: const EdgeInsets.all(24),
              shrinkWrap: true,
              children: [
                TextField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: 'メールアドレス'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'パスワード'),
                  onSubmitted: (_) => _login(),
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _busy ? null : _login,
                  child: Text(_busy ? '...' : 'ログイン'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 一覧

String _title(String c) {
  final first = c.trim().split('\n').first;
  return first.isEmpty ? '(無題)' : first;
}

String _preview(String c) {
  final lines = c.trim().split('\n');
  return lines.length > 1 ? lines.skip(1).join(' ') : '';
}

class NotesPage extends StatefulWidget {
  const NotesPage({super.key});

  @override
  State<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends State<NotesPage> {
  // Realtime: 他の端末での変更も自動で反映される
  final _stream = supabase
      .from('notes')
      .stream(primaryKey: ['id']).order('updated_at', ascending: false);

  bool _trash = false;
  String _query = '';

  Future<void> _create() async {
    final row =
        await supabase.from('notes').insert({'content': ''}).select().single();
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => EditPage(note: row)),
    );
  }

  Future<void> _confirmLogout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ログアウトしますか？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('キャンセル')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('ログアウト')),
        ],
      ),
    );
    if (ok == true) await supabase.auth.signOut();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_trash ? 'ゴミ箱' : 'ノート'),
        actions: [
          IconButton(
            tooltip: _trash ? 'ノートへ' : 'ゴミ箱',
            icon: Icon(_trash ? Icons.notes : Icons.delete_outline),
            onPressed: () => setState(() => _trash = !_trash),
          ),
          PopupMenuButton<String>(
            onSelected: (_) => _confirmLogout(),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'logout', child: Text('ログアウト')),
            ],
          ),
        ],
      ),
      floatingActionButton: _trash
          ? null
          : FloatingActionButton(
              onPressed: _create,
              child: const Icon(Icons.add),
            ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: TextField(
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: '検索',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (v) => setState(() => _query = v.toLowerCase()),
              ),
            ),
            Expanded(
              child: StreamBuilder<List<Map<String, dynamic>>>(
                stream: _stream,
                builder: (context, snap) {
                  if (snap.hasError) {
                    return Center(child: Text('エラー: ${snap.error}'));
                  }
                  if (!snap.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final notes = snap.data!
                      .where((n) =>
                          (n['deleted'] == true) == _trash &&
                          (n['content'] as String)
                              .toLowerCase()
                              .contains(_query))
                      .toList()
                    ..sort((a, b) {
                      final pa = a['pinned'] == true ? 1 : 0;
                      final pb = b['pinned'] == true ? 1 : 0;
                      if (pa != pb) return pb - pa;
                      return (b['updated_at'] as String)
                          .compareTo(a['updated_at'] as String);
                    });
                  if (notes.isEmpty) {
                    return const Center(child: Text('ノートはありません'));
                  }
                  return ListView.separated(
                    itemCount: notes.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final n = notes[i];
                      final content = n['content'] as String;
                      return ListTile(
                        leading: n['pinned'] == true
                            ? const Icon(Icons.push_pin, size: 20)
                            : null,
                        title: Text(_title(content),
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(_preview(content),
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => EditPage(note: n)),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 編集

class EditPage extends StatefulWidget {
  final Map<String, dynamic> note;
  const EditPage({super.key, required this.note});

  @override
  State<EditPage> createState() => _EditPageState();
}

class _EditPageState extends State<EditPage> {
  late final TextEditingController _c =
      TextEditingController(text: widget.note['content'] as String);
  late bool _pinned = widget.note['pinned'] == true;
  late bool _deleted = widget.note['deleted'] == true;
  Timer? _timer;
  bool _dirty = false;
  bool _removed = false; // 完全削除済み
  String get _id => widget.note['id'] as String;

  void _onChanged(String _) {
    _dirty = true;
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 800), _save);
  }

  Future<void> _save() async {
    _timer?.cancel();
    if (!_dirty || _removed) return;
    _dirty = false;
    try {
      await supabase
          .from('notes')
          .update({'content': _c.text}).eq('id', _id);
    } catch (e) {
      _dirty = true;
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('保存に失敗: $e')));
      }
    }
  }

  Future<void> _togglePin() async {
    setState(() => _pinned = !_pinned);
    await supabase.from('notes').update({'pinned': _pinned}).eq('id', _id);
  }

  Future<void> _setDeleted(bool v) async {
    await _save();
    await supabase.from('notes').update({'deleted': v}).eq('id', _id);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _deleteForever() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('完全に削除しますか？'),
        content: const Text('この操作は元に戻せません。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('キャンセル')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('削除')),
        ],
      ),
    );
    if (ok != true) return;
    _removed = true;
    await supabase.from('notes').delete().eq('id', _id);
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (!_removed) {
      if (_c.text.trim().isEmpty && !_deleted) {
        // 空のノートは残さない
        supabase.from('notes').delete().eq('id', _id);
      } else {
        _save(); // 未保存分を送信(textは同期的に読まれる)
      }
    }
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        actions: [
          IconButton(
            tooltip: 'ピン留め',
            icon: Icon(_pinned ? Icons.push_pin : Icons.push_pin_outlined),
            onPressed: _togglePin,
          ),
          if (!_deleted)
            IconButton(
              tooltip: 'ゴミ箱へ',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _setDeleted(true),
            )
          else ...[
            IconButton(
              tooltip: '復元',
              icon: const Icon(Icons.restore_from_trash),
              onPressed: () => _setDeleted(false),
            ),
            IconButton(
              tooltip: '完全に削除',
              icon: const Icon(Icons.delete_forever),
              onPressed: _deleteForever,
            ),
          ],
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            controller: _c,
            onChanged: _onChanged,
            maxLines: null,
            expands: true,
            textAlignVertical: TextAlignVertical.top,
            autofocus: _c.text.isEmpty,
            readOnly: _deleted,
            decoration: const InputDecoration(
              border: InputBorder.none,
              hintText: '1行目がタイトルになります',
            ),
          ),
        ),
      ),
    );
  }
}