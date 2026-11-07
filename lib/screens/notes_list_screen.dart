import 'package:flutter/material.dart';

import '../main.dart';
import '../notes_store.dart';
import 'note_edit_screen.dart';

String _two(int v) => v.toString().padLeft(2, '0');

String _fmtDate(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${_two(d.month)}/${_two(d.day)} ${_two(d.hour)}:${_two(d.minute)}';
}

String _fmtTime(DateTime d) => '${_two(d.hour)}:${_two(d.minute)}:${_two(d.second)}';

class NotesListScreen extends StatefulWidget {
  final NotesStore store;
  final Future<void> Function() onLogout;
  const NotesListScreen({super.key, required this.store, required this.onLogout});

  @override
  State<NotesListScreen> createState() => _NotesListScreenState();
}

class _NotesListScreenState extends State<NotesListScreen>
    with WidgetsBindingObserver {
  bool _trash = false;
  String _query = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // アプリに戻ってきたら、すぐ同期する
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) widget.store.refresh();
  }

  void _create() {
    final id = widget.store.createNote();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => NoteEditScreen(store: widget.store, id: id, isNew: true),
      ),
    );
  }

  Future<bool> _confirm(String title, String body) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: body.isEmpty ? null : Text(body),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('キャンセル')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('OK')),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _onMenu(String v) async {
    switch (v) {
      case 'theme':
        NotesApp.of(context).toggleTheme();
        break;
      case 'empty':
        if (await _confirm('ゴミ箱を空にしますか？', 'この操作は元に戻せません。') && mounted) {
          widget.store.emptyTrash();
        }
        break;
      case 'logout':
        if (await _confirm('ログアウトしますか？', '') && mounted) {
          await widget.onLogout();
        }
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final notes = store.visibleNotes(trash: _trash, query: _query);
        final scheme = Theme.of(context).colorScheme;
        final syncTip = store.error ??
            (store.lastSynced == null
                ? '同期中…'
                : '最終同期 ${_fmtTime(store.lastSynced!)}');

        return Scaffold(
          appBar: AppBar(
            title: Text(_trash ? 'ゴミ箱' : 'ノート'),
            actions: [
              IconButton(
                tooltip: syncTip,
                icon: Icon(store.error != null
                    ? Icons.cloud_off
                    : Icons.cloud_done_outlined),
                onPressed: () => store.refresh(force: true),
              ),
              IconButton(
                tooltip: _trash ? 'ノートへ' : 'ゴミ箱',
                icon: Icon(_trash ? Icons.notes : Icons.delete_outline),
                onPressed: () => setState(() => _trash = !_trash),
              ),
              PopupMenuButton<String>(
                onSelected: _onMenu,
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'theme', child: Text('ダーク/ライト切替')),
                  if (_trash)
                    const PopupMenuItem(value: 'empty', child: Text('ゴミ箱を空にする')),
                  const PopupMenuItem(value: 'logout', child: Text('ログアウト')),
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
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 800),
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: TextField(
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search),
                          hintText: '検索(タイトルと冒頭部分)',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        onChanged: (v) => setState(() => _query = v),
                      ),
                    ),
                    if (store.error != null)
                      Container(
                        width: double.infinity,
                        color: scheme.errorContainer,
                        padding: const EdgeInsets.all(8),
                        child: Text(
                          store.error!,
                          style: TextStyle(
                              color: scheme.onErrorContainer, fontSize: 12),
                        ),
                      ),
                    Expanded(
                      child: store.loading && notes.isEmpty
                          ? const Center(child: CircularProgressIndicator())
                          : RefreshIndicator(
                              onRefresh: () => store.refresh(force: true),
                              child: notes.isEmpty
                                  ? ListView(
                                      physics: const AlwaysScrollableScrollPhysics(),
                                      children: const [
                                        SizedBox(height: 120),
                                        Center(child: Text('ノートはありません')),
                                      ],
                                    )
                                  : ListView.separated(
                                      physics: const AlwaysScrollableScrollPhysics(),
                                      itemCount: notes.length,
                                      separatorBuilder: (_, __) =>
                                          const Divider(height: 1),
                                      itemBuilder: (context, i) {
                                        final n = notes[i];
                                        return ListTile(
                                          leading: n.pinned
                                              ? const Icon(Icons.push_pin, size: 20)
                                              : null,
                                          title: Text(
                                            n.title.isEmpty ? '(無題)' : n.title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          subtitle: n.preview.isEmpty
                                              ? null
                                              : Text(
                                                  n.preview,
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                ),
                                          trailing: Text(
                                            _fmtDate(n.contentAt),
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall,
                                          ),
                                          onTap: () => Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (_) => NoteEditScreen(
                                                  store: store, id: n.id),
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
