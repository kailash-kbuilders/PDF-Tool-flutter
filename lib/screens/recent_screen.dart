import 'dart:io';

import 'package:flutter/material.dart';

import '../models.dart';
import '../services/file_service.dart';
import '../store.dart';
import '../theme.dart';
import '../ui.dart';
import 'extra_screens.dart';
import 'viewer_screen.dart';

class RecentScreen extends StatefulWidget {
  const RecentScreen({super.key});

  @override
  State<RecentScreen> createState() => _RecentScreenState();
}

class _RecentScreenState extends State<RecentScreen> {
  String _query = '';
  bool _favOnly = false;
  int _sort = 0; // 0 newest, 1 oldest, 2 name, 3 size

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final all = store.recents;
    if (all.isEmpty) {
      return Column(
        children: [
          Expanded(
            child: EmptyState(
              icon: Icons.history,
              title: 'No recent files',
              subtitle: 'PDFs you create or process will show up here.',
              action: 'Choose a PDF',
              onAction: () => pickAndOpenPdf(context),
            ),
          ),
          TextButton.icon(
            onPressed: () => pushPage<void>(context, const TrashScreen()),
            icon: const Icon(Icons.delete_outline),
            label: Text('Trash (${store.trash.length})'),
          ),
          const SizedBox(height: 12),
        ],
      );
    }
    final q = _query.trim().toLowerCase();
    final items = all
        .where((f) => (!_favOnly || f.fav) && (q.isEmpty || f.name.toLowerCase().contains(q)))
        .toList();
    items.sort((a, b) {
      switch (_sort) {
        case 1:
          return a.ts.compareTo(b.ts);
        case 2:
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case 3:
          return b.size.compareTo(a.size);
        default:
          return b.ts.compareTo(a.ts);
      }
    });

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  onChanged: (v) => setState(() => _query = v),
                  decoration: InputDecoration(
                    hintText: 'Search files',
                    prefixIcon: const Icon(Icons.search),
                    isDense: true,
                    filled: true,
                    fillColor: Theme.of(context).colorScheme.surface,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              PopupMenuButton<int>(
                tooltip: 'Sort',
                icon: const Icon(Icons.sort),
                onSelected: (v) => setState(() => _sort = v),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 0, child: Text('Newest first')),
                  PopupMenuItem(value: 1, child: Text('Oldest first')),
                  PopupMenuItem(value: 2, child: Text('Name')),
                  PopupMenuItem(value: 3, child: Text('Largest')),
                ],
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              ChoiceChip(
                label: const Text('All'),
                selected: !_favOnly,
                onSelected: (_) => setState(() => _favOnly = false),
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                avatar: const Icon(Icons.star, size: 16, color: Colors.amber),
                label: const Text('Favorites'),
                selected: _favOnly,
                onSelected: (_) => setState(() => _favOnly = true),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () => pushPage<void>(context, const TrashScreen()),
                icon: const Icon(Icons.delete_outline, size: 18),
                label: Text('Trash (${store.trash.length})'),
              ),
            ],
          ),
        ),
        Expanded(
          child: items.isEmpty
              ? const EmptyState(icon: Icons.search_off, title: 'No matching files')
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  itemCount: items.length,
                  itemBuilder: (context, i) {
                    final f = items[i];
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      elevation: 0,
                      color: Theme.of(context).colorScheme.surface,
                      child: ListTile(
                        leading: const Icon(Icons.picture_as_pdf, color: AppColors.red, size: 30),
                        title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text('${fmtDateTime(f.ts)} · ${fmtSize(f.size)}'),
                        onTap: () => pushPage<void>(
                            context, ViewerScreen(name: f.name, path: f.path)),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'Favorite',
                              icon: Icon(f.fav ? Icons.star : Icons.star_border,
                                  color: f.fav ? Colors.amber : null),
                              onPressed: () => store.toggleFav(f.path),
                            ),
                            PopupMenuButton<String>(
                              onSelected: (v) {
                                if (v == 'open') {
                                  pushPage<void>(
                                      context, ViewerScreen(name: f.name, path: f.path));
                                } else if (v == 'rename') {
                                  _rename(context, store, f);
                                } else {
                                  _delete(context, store, f);
                                }
                              },
                              itemBuilder: (_) => const [
                                PopupMenuItem(value: 'open', child: Text('Open')),
                                PopupMenuItem(value: 'rename', child: Text('Rename')),
                                PopupMenuItem(value: 'delete', child: Text('Move to trash')),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<void> _rename(BuildContext context, AppStore store, RecentFile f) async {
    final text = await showDialog<String>(
      context: context,
      builder: (_) => TextInputDialog(title: 'Rename', initial: FileService.stem(f.name)),
    );
    if (text == null || !context.mounted) return;
    final stem = FileService.safeStem(text);
    try {
      final dir = File(f.path).parent.path;
      final newPath = '$dir/$stem.pdf';
      if (newPath != f.path && await File(newPath).exists()) {
        if (context.mounted) await showError(context, 'A file with this name already exists.');
        return;
      }
      await File(f.path).rename(newPath);
      await store.replaceRecent(f.path, f.copyWith(path: newPath, name: '$stem.pdf'));
    } catch (_) {
      if (context.mounted) await showError(context, 'PDF processing failed. Please try again.');
    }
  }

  Future<void> _delete(BuildContext context, AppStore store, RecentFile f) async {
    final ok = await confirmDialog(context,
        title: 'Move to trash?',
        body: '${f.name} will be moved to the trash. You can restore it later.',
        action: 'Move');
    if (!ok) return;
    final dir = await FileService.trashDir();
    await store.moveToTrash(f, dir.path);
  }
}
