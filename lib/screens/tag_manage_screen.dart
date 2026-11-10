import 'package:flutter/material.dart';

import '../notes_store.dart';

/// タグの編集画面(並べ替え・名前の変更・削除)。ドロワーのタグ欄の「編集」から開く。
///  - 左のハンドルをドラッグすると、並べ替えられる。この順番が、ドロワーのタグの並びになる。
///  - 名前の変更・削除は、ゴミ箱内のノートも含めた全ノートに適用される。
class TagManageScreen extends StatelessWidget {
  final NotesStore store;
  const TagManageScreen({super.key, required this.store});

  Future<void> _rename(BuildContext context, TagCount t) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _RenameDialog(initial: t.label),
    );
    if (name == null) return;
    store.renameTag(t.label, name);
  }

  Future<void> _delete(BuildContext context, TagCount t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('タグ「${t.label}」を削除しますか？'),
        content: const Text('すべてのノートからこのタグが外れます。ノート自体は削除されません。'),
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
    store.deleteTag(t.label);
  }

  /// ドラッグ&ドロップの結果を、並び順として保存する。
  void _onReorder(List<TagCount> tags, int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex -= 1;
    final keys = tags.map((t) => t.key).toList();
    final moved = keys.removeAt(oldIndex);
    keys.insert(newIndex, moved);
    store.setTagOrder(keys);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('タグを編集')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 800),
            child: ListenableBuilder(
              listenable: store,
              builder: (context, _) {
                final tags = store.orderedTags();
                if (tags.isEmpty) {
                  return const Center(child: Text('タグはありません'));
                }
                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '左のハンドルをドラッグして、並べ替えられます',
                          style: TextStyle(
                              fontSize: 12, color: scheme.onSurfaceVariant),
                        ),
                      ),
                    ),
                    Expanded(
                      child: ReorderableListView.builder(
                        buildDefaultDragHandles: false,
                        itemCount: tags.length,
                        onReorder: (o, n) => _onReorder(tags, o, n),
                        itemBuilder: (context, i) {
                          final t = tags[i];
                          return ListTile(
                            key: ValueKey(t.key),
                            leading: ReorderableDragStartListener(
                              index: i,
                              child: const Padding(
                                padding: EdgeInsets.all(8),
                                child: Icon(Icons.drag_handle),
                              ),
                            ),
                            title: Text(t.label),
                            subtitle: Text('${t.count}件'),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: '名前を変更',
                                  icon: const Icon(Icons.edit_outlined),
                                  onPressed: () => _rename(context, t),
                                ),
                                IconButton(
                                  tooltip: '削除',
                                  icon: const Icon(Icons.delete_outline),
                                  onPressed: () => _delete(context, t),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _RenameDialog extends StatefulWidget {
  final String initial;
  const _RenameDialog({required this.initial});

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final _c = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _submit() {
    final tags = parseTags(_c.text);
    Navigator.pop(context, tags.isEmpty ? null : tags.first);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('タグの名前を変更'),
      content: TextField(
        controller: _c,
        autofocus: true,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
        decoration: const InputDecoration(
          helperText: 'スペースは使えません。すでにあるタグ名にすると統合されます',
          helperMaxLines: 2,
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('キャンセル')),
        TextButton(onPressed: _submit, child: const Text('変更')),
      ],
    );
  }
}