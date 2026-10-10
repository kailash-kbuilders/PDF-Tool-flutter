import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../errors.dart';
import '../models.dart';
import '../services/file_service.dart';
import '../services/pdf_service.dart';
import '../store.dart';
import '../theme.dart';
import '../ui.dart';
import 'viewer_screen.dart';

class OrganizerScreen extends StatelessWidget {
  final int initialTab;
  const OrganizerScreen({super.key, this.initialTab = 0});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      initialIndex: initialTab,
      child: Scaffold(
        appBar: buildAppBar(
          context,
          title: const Text('PDF Organizer'),
          bottom: const TabBar(
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white70,
            indicatorColor: Colors.white,
            tabs: [Tab(text: 'Merge'), Tab(text: 'Split'), Tab(text: 'Pages')],
          ),
        ),
        body: const TabBarView(children: [_MergeTab(), _SplitTab(), _PagesTab()]),
      ),
    );
  }
}

// ------------------------------------------------------------------ merge
class _Doc {
  final int id;
  final PickedFile file;
  final int pages;
  _Doc(this.id, this.file, this.pages);
}

class _MergeTab extends StatefulWidget {
  const _MergeTab();

  @override
  State<_MergeTab> createState() => _MergeTabState();
}

class _MergeTabState extends State<_MergeTab> with AutomaticKeepAliveClientMixin {
  final List<_Doc> _docs = [];
  int _nextId = 0;

  @override
  bool get wantKeepAlive => true;

  Future<void> _add() async {
    List<PickedFile> picked;
    try {
      picked = await FileService.pickPdfs(multiple: true);
    } catch (_) {
      if (mounted) await showError(context, 'Unable to open this PDF.');
      return;
    }
    for (final f in picked) {
      try {
        final n = await PdfService.pageCount(f.bytes);
        if (!mounted) return;
        setState(() => _docs.add(_Doc(_nextId++, f, n)));
      } catch (e) {
        if (!mounted) return;
        await showError(context, '${f.name}: ${friendlyError(e)}');
      }
    }
  }

  Future<void> _merge() => runPdfJob(
        context,
        'merged',
        () => PdfService.merge(_docs.map((d) => d.file.bytes).toList()),
      );

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scheme = Theme.of(context).colorScheme;
    if (_docs.isEmpty) {
      return EmptyState(
        icon: Icons.picture_as_pdf_outlined,
        title: 'No PDF selected',
        subtitle: 'Choose two or more PDFs to merge.',
        action: 'Choose PDF',
        onAction: _add,
      );
    }
    return Column(
      children: [
        Expanded(
          child: ReorderableListView.builder(
            padding: const EdgeInsets.all(16),
            buildDefaultDragHandles: false,
            itemCount: _docs.length,
            onReorder: (o, n) {
              setState(() {
                if (n > o) n -= 1;
                final it = _docs.removeAt(o);
                _docs.insert(n, it);
              });
            },
            itemBuilder: (context, i) {
              final d = _docs[i];
              return Card(
                key: ValueKey(d.id),
                margin: const EdgeInsets.only(bottom: 8),
                elevation: 0,
                color: scheme.surface,
                child: ListTile(
                  leading: ReorderableDragStartListener(
                    index: i,
                    child: const Icon(Icons.drag_handle),
                  ),
                  title: Text(d.file.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${d.pages} pages · ${fmtSize(d.file.size)}'),
                  trailing: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() => _docs.removeAt(i)),
                  ),
                ),
              );
            },
          ),
        ),
        _BottomBar(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _add,
                icon: const Icon(Icons.add),
                label: const Text('Add PDFs'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                onPressed: _docs.length >= 2 ? _merge : null,
                icon: const Icon(Icons.merge_type),
                label: Text('Merge (${_docs.length})'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _BottomBar extends StatelessWidget {
  final List<Widget> children;
  const _BottomBar({required this.children});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      elevation: 6,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: children),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ split
class _SplitTab extends StatefulWidget {
  const _SplitTab();

  @override
  State<_SplitTab> createState() => _SplitTabState();
}

class _SplitTabState extends State<_SplitTab> with AutomaticKeepAliveClientMixin {
  LoadedPdf? _pdf;
  final TextEditingController _c = TextEditingController();
  final TextEditingController _n = TextEditingController(text: '1');
  int _mode = 0; // 0 = page range, 1 = every N pages

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _n.dispose();
    _c.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final p = await pickSinglePdf(context);
    if (p != null && mounted) setState(() => _pdf = p);
  }

  Future<void> _splitEvery() async {
    final p = _pdf!;
    final n = int.tryParse(_n.text.trim()) ?? 0;
    if (n < 1 || n > p.pages) {
      await showError(context, 'Enter a number between 1 and ${p.pages}.');
      return;
    }
    final store = StoreScope.read(context);
    final stem = FileService.safeStem(p.file.name);
    final files = await runWithProgress<List<RecentFile>>(context, () async {
      final parts = await PdfService.splitEvery(p.file.bytes, n);
      final out = <RecentFile>[];
      for (var i = 0; i < parts.length; i++) {
        out.add(await FileService.saveOutput(parts[i], '${stem}_part${i + 1}', store));
      }
      return out;
    });
    if (files == null || !mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text('${files.length} PDFs created successfully.',
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: files.length,
                  itemBuilder: (_, i) => ListTile(
                    leading: const Icon(Icons.picture_as_pdf, color: AppColors.red),
                    title: Text(files[i].name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(fmtSize(files[i].size)),
                    trailing: TextButton(
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        pushPage<void>(
                            context, ViewerScreen(name: files[i].name, path: files[i].path));
                      },
                      child: const Text('Open'),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('Done'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _split() async {
    if (_mode == 1) {
      await _splitEvery();
      return;
    }
    final p = _pdf!;
    List<int> pages;
    try {
      pages = PdfService.parsePageSpec(_c.text, p.pages);
    } catch (e) {
      await showError(context, friendlyError(e));
      return;
    }
    if (!mounted) return;
    await runPdfJob(context, '${FileService.safeStem(p.file.name)}_split',
        () => PdfService.extractPages(p.file.bytes, pages));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        PdfPickerCard(pdf: _pdf, onPick: _pick),
        if (_pdf != null) ...[
          const SizedBox(height: 16),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, label: Text('Page range')),
              ButtonSegment(value: 1, label: Text('Every N pages')),
            ],
            selected: {_mode},
            onSelectionChanged: (s) => setState(() => _mode = s.first),
          ),
          const SizedBox(height: 12),
          if (_mode == 0)
            TextField(
              controller: _c,
              keyboardType: TextInputType.text,
              decoration: InputDecoration(
                labelText: 'Pages to extract',
                hintText: 'e.g. 1-5 or 1,3,7,10',
                helperText: 'This PDF has ${_pdf!.pages} pages',
                border: const OutlineInputBorder(),
              ),
            )
          else
            TextField(
              controller: _n,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: 'Pages per file',
                helperText: 'This PDF has ${_pdf!.pages} pages',
                border: const OutlineInputBorder(),
              ),
            ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _split,
            icon: const Icon(Icons.call_split),
            label: const Text('Split PDF'),
          ),
        ],
      ],
    );
  }
}

// ------------------------------------------------------------------ pages
class _PageItem {
  final int index;
  int rot = 0;
  final int uid;
  _PageItem(this.index, this.uid);
}

class _PagesTab extends StatefulWidget {
  const _PagesTab();

  @override
  State<_PagesTab> createState() => _PagesTabState();
}

class _PagesTabState extends State<_PagesTab> with AutomaticKeepAliveClientMixin {
  LoadedPdf? _pdf;
  List<_PageItem> _items = [];
  final Map<int, Uint8List> _thumbs = {};
  int _uid = 0;

  @override
  bool get wantKeepAlive => true;

  Future<void> _pick() async {
    final p = await pickSinglePdf(context);
    if (p == null || !mounted) return;
    setState(() {
      _pdf = p;
      _thumbs.clear();
      _items = List.generate(p.pages, (i) => _PageItem(i, _uid++));
    });
  }

  Future<void> _save() async {
    final p = _pdf!;
    if (_items.isEmpty) {
      await showError(context, 'Keep at least one page.');
      return;
    }
    final refs = _items.map((e) => PageRef(0, e.index, e.rot % 4)).toList();
    await runPdfJob(context, '${FileService.safeStem(p.file.name)}_edited',
        () => PdfService.assemble([p.file.bytes], refs));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scheme = Theme.of(context).colorScheme;
    final p = _pdf;
    if (p == null) {
      return EmptyState(
        icon: Icons.picture_as_pdf_outlined,
        title: 'No PDF selected',
        subtitle: 'Reorder, rotate, duplicate or delete pages.',
        action: 'Choose PDF',
        onAction: _pick,
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: Text('${_items.length} pages · ${p.file.name}',
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              IconButton(
                tooltip: 'Reverse order',
                icon: const Icon(Icons.swap_vert),
                onPressed: () => setState(() => _items = _items.reversed.toList()),
              ),
              IconButton(
                tooltip: 'Choose another PDF',
                icon: const Icon(Icons.folder_open),
                onPressed: _pick,
              ),
            ],
          ),
        ),
        Expanded(
          child: ReorderableListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            buildDefaultDragHandles: false,
            itemCount: _items.length,
            onReorder: (o, n) {
              setState(() {
                if (n > o) n -= 1;
                final it = _items.removeAt(o);
                _items.insert(n, it);
              });
            },
            itemBuilder: (context, i) {
              final it = _items[i];
              return Card(
                key: ValueKey(it.uid),
                margin: const EdgeInsets.only(bottom: 8),
                elevation: 0,
                color: scheme.surface,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Row(
                    children: [
                      ReorderableDragStartListener(
                        index: i,
                        child: const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 6),
                          child: Icon(Icons.drag_handle),
                        ),
                      ),
                      SizedBox(
                        width: 64,
                        height: 84,
                        child: ClipRect(
                          child: AnimatedRotation(
                            turns: it.rot / 4.0,
                            duration: const Duration(milliseconds: 200),
                            child: PageImage(
                              bytes: p.file.bytes,
                              index: it.index,
                              cache: _thumbs,
                              dpi: 36,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text('Page ${it.index + 1}',
                            style: const TextStyle(fontWeight: FontWeight.w600)),
                      ),
                      IconButton(
                        tooltip: 'Rotate 90°',
                        icon: const Icon(Icons.rotate_right),
                        onPressed: () => setState(() => it.rot += 1),
                      ),
                      IconButton(
                        tooltip: 'Duplicate',
                        icon: const Icon(Icons.copy_all_outlined),
                        onPressed: () => setState(() {
                          final c = _PageItem(it.index, _uid++);
                          c.rot = it.rot;
                          _items.insert(i + 1, c);
                        }),
                      ),
                      IconButton(
                        tooltip: 'Delete',
                        icon: const Icon(Icons.delete_outline, color: AppColors.red),
                        onPressed: () => setState(() => _items.removeAt(i)),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        _BottomBar(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _save,
                icon: const Icon(Icons.save_outlined),
                label: const Text('Save PDF'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
