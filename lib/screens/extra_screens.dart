import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models.dart';
import '../services/file_service.dart';
import '../services/pdf_service.dart';
import '../store.dart';
import '../theme.dart';
import '../ui.dart';

// -------------------------------------------------------------- form filler
class FormFillScreen extends StatefulWidget {
  final String name;
  final Uint8List bytes;
  const FormFillScreen({super.key, required this.name, required this.bytes});

  @override
  State<FormFillScreen> createState() => _FormFillScreenState();
}

class _FormFillScreenState extends State<FormFillScreen> {
  List<List<Object>>? _fields;
  String? _error;
  final Map<int, TextEditingController> _ctrls = {};
  final Map<int, bool> _checks = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final f = await PdfService.readForm(widget.bytes);
      for (final row in f) {
        final idx = row[0] as int;
        if (row[2] == 0) {
          _ctrls[idx] = TextEditingController(text: row[3] as String);
        } else if (row[2] == 1) {
          _checks[idx] = row[3] as bool;
        }
      }
      if (mounted) setState(() => _fields = f);
    } catch (_) {
      if (mounted) setState(() => _error = 'Unable to open this PDF.');
    }
  }

  Future<void> _save() async {
    final values = <int, Object>{};
    _ctrls.forEach((k, c) => values[k] = c.text);
    _checks.forEach((k, v) => values[k] = v);
    final bytes = widget.bytes;
    await runPdfJob(context, '${FileService.safeStem(widget.name)}_filled',
        () => PdfService.fillForm(bytes, values));
  }

  @override
  Widget build(BuildContext context) {
    final f = _fields;
    Widget body;
    if (_error != null) {
      body = EmptyState(icon: Icons.error_outline, title: _error!);
    } else if (f == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (f.isEmpty) {
      body = const EmptyState(
        icon: Icons.assignment_outlined,
        title: 'No fillable form fields',
        subtitle: 'This PDF does not contain interactive form fields.',
      );
    } else {
      body = ListView(
        padding: const EdgeInsets.all(16),
        children: [
          for (final row in f)
            if (row[2] == 0)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: TextField(
                  controller: _ctrls[row[0] as int],
                  decoration: InputDecoration(
                    labelText: row[1] as String,
                    border: const OutlineInputBorder(),
                  ),
                ),
              )
            else if (row[2] == 1)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(row[1] as String),
                value: _checks[row[0] as int] ?? false,
                onChanged: (v) => setState(() => _checks[row[0] as int] = v ?? false),
              )
            else
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(row[1] as String),
                subtitle: const Text('This field type cannot be edited here.'),
              ),
        ],
      );
    }
    return Scaffold(
      appBar: buildAppBar(context, title: const Text('Fill form')),
      body: body,
      bottomNavigationBar: (f == null || f.isEmpty)
          ? null
          : Material(
              elevation: 6,
              color: Theme.of(context).colorScheme.surface,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: FilledButton.icon(
                    onPressed: _save,
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('Save filled PDF'),
                  ),
                ),
              ),
            ),
    );
  }
}

// ------------------------------------------------------------------- trash
class TrashScreen extends StatelessWidget {
  const TrashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final items = store.trash;
    return Scaffold(
      appBar: buildAppBar(
        context,
        title: const Text('Trash'),
        actions: [
          if (items.isNotEmpty)
            TextButton(
              onPressed: () async {
                final ok = await confirmDialog(context,
                    title: 'Empty trash?',
                    body: 'All files in the trash will be deleted permanently.',
                    action: 'Empty');
                if (ok) await store.emptyTrash();
              },
              child: const Text('Empty', style: TextStyle(color: Colors.white)),
            ),
        ],
      ),
      body: items.isEmpty
          ? const EmptyState(
              icon: Icons.delete_outline,
              title: 'Trash is empty',
              subtitle: 'Deleted files stay here until you remove them for good.',
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: items.length,
              itemBuilder: (context, i) {
                final f = items[i];
                return Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  elevation: 0,
                  color: Theme.of(context).colorScheme.surface,
                  child: ListTile(
                    leading: const Icon(Icons.picture_as_pdf, color: AppColors.red),
                    title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text('${fmtDateTime(f.ts)} · ${fmtSize(f.size)}'),
                    trailing: PopupMenuButton<String>(
                      onSelected: (v) async {
                        if (v == 'restore') {
                          final dir = await FileService.outputDir();
                          await store.restoreFromTrash(f, dir.path);
                        } else {
                          final ok = await confirmDialog(context,
                              title: 'Delete forever?',
                              body: 'This file will be deleted permanently.',
                              action: 'Delete');
                          if (ok) await store.deleteForever(f);
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'restore', child: Text('Restore')),
                        PopupMenuItem(value: 'delete', child: Text('Delete forever')),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}

// -------------------------------------------------------------- crop pages
class CropScreen extends StatefulWidget {
  const CropScreen({super.key});

  @override
  State<CropScreen> createState() => _CropScreenState();
}

class _CropScreenState extends State<CropScreen> {
  LoadedPdf? _pdf;
  double _aspect = 1.4;
  double _l = 0, _t = 0, _r = 0, _b = 0;
  final Map<int, Uint8List> _cache = {};

  Future<void> _pick() async {
    final p = await pickSinglePdf(context);
    if (p == null || !mounted) return;
    double asp = 1.4;
    try {
      final s = await PdfService.pageSizes(p.file.bytes);
      if (s.length >= 2 && s[0] > 0) asp = s[1] / s[0];
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _pdf = p;
      _aspect = asp;
      _cache.clear();
      _l = _t = _r = _b = 0;
    });
  }

  Future<void> _run() async {
    final p = _pdf!;
    final l = _l, t = _t, r = _r, b = _b;
    await runPdfJob(context, '${FileService.safeStem(p.file.name)}_cropped',
        () => PdfService.cropPages(p.file.bytes, l, t, r, b));
  }

  Widget _slider(String label, double v, void Function(double) set) {
    return Row(
      children: [
        SizedBox(width: 70, child: Text('$label ${(v * 100).round()}%')),
        Expanded(
          child: Slider(
            value: v,
            min: 0,
            max: 0.4,
            onChanged: (x) => setState(() => set(x)),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = _pdf;
    return Scaffold(
      appBar: buildAppBar(context, title: const Text('Crop pages')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          PdfPickerCard(pdf: p, onPick: _pick),
          if (p != null) ...[
            const SizedBox(height: 12),
            Center(
              child: SizedBox(
                width: 220,
                child: AspectRatio(
                  aspectRatio: 1 / _aspect,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      PageImage(
                          bytes: p.file.bytes, index: 0, cache: _cache, dpi: 60),
                      IgnorePointer(
                        child: CustomPaint(painter: _CropShade(_l, _t, _r, _b)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            _slider('Left', _l, (v) => _l = v),
            _slider('Top', _t, (v) => _t = v),
            _slider('Right', _r, (v) => _r = v),
            _slider('Bottom', _b, (v) => _b = v),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _run,
              icon: const Icon(Icons.crop),
              label: const Text('Crop all pages'),
            ),
          ],
        ],
      ),
    );
  }
}

class _CropShade extends CustomPainter {
  final double l, t, r, b;
  _CropShade(this.l, this.t, this.r, this.b);

  @override
  void paint(Canvas canvas, Size s) {
    final shade = Paint()..color = Colors.black45;
    final keep = Rect.fromLTRB(l * s.width, t * s.height, s.width - r * s.width, s.height - b * s.height);
    canvas.drawRect(Rect.fromLTRB(0, 0, s.width, keep.top), shade);
    canvas.drawRect(Rect.fromLTRB(0, keep.bottom, s.width, s.height), shade);
    canvas.drawRect(Rect.fromLTRB(0, keep.top, keep.left, keep.bottom), shade);
    canvas.drawRect(Rect.fromLTRB(keep.right, keep.top, s.width, keep.bottom), shade);
    canvas.drawRect(
        keep,
        Paint()
          ..color = AppColors.red
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5);
  }

  @override
  bool shouldRepaint(covariant _CropShade o) =>
      o.l != l || o.t != t || o.r != r || o.b != b;
}

// ------------------------------------------------------------------- n-up
class NUpScreen extends StatefulWidget {
  const NUpScreen({super.key});

  @override
  State<NUpScreen> createState() => _NUpScreenState();
}

class _NUpScreenState extends State<NUpScreen> {
  LoadedPdf? _pdf;
  int _n = 4;

  Future<void> _pick() async {
    final p = await pickSinglePdf(context);
    if (p != null && mounted) setState(() => _pdf = p);
  }

  Future<void> _run() async {
    final p = _pdf!;
    final n = _n;
    await runPdfJob(context, '${FileService.safeStem(p.file.name)}_${n}up',
        () => PdfService.nUp(p.file.bytes, n));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: buildAppBar(context, title: const Text('Pages per sheet')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          PdfPickerCard(pdf: _pdf, onPick: _pick),
          if (_pdf != null) ...[
            const SizedBox(height: 16),
            const Text('Pages on one sheet'),
            const SizedBox(height: 6),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 2, label: Text('2')),
                ButtonSegment(value: 4, label: Text('4')),
                ButtonSegment(value: 6, label: Text('6')),
              ],
              selected: {_n},
              onSelectionChanged: (s) => setState(() => _n = s.first),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _run,
              icon: const Icon(Icons.grid_view),
              label: const Text('Create layout'),
            ),
          ],
        ],
      ),
    );
  }
}

// -------------------------------------------------------------- grayscale
class GrayscaleScreen extends StatefulWidget {
  const GrayscaleScreen({super.key});

  @override
  State<GrayscaleScreen> createState() => _GrayscaleScreenState();
}

class _GrayscaleScreenState extends State<GrayscaleScreen> {
  LoadedPdf? _pdf;

  Future<void> _pick() async {
    final p = await pickSinglePdf(context);
    if (p != null && mounted) setState(() => _pdf = p);
  }

  Future<void> _run() async {
    final p = _pdf!;
    await runPdfJob(context, '${FileService.safeStem(p.file.name)}_gray',
        () => PdfService.convertGrayscale(p.file.bytes));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: buildAppBar(context, title: const Text('Convert to grayscale')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          PdfPickerCard(pdf: _pdf, onPick: _pick),
          if (_pdf != null) ...[
            const SizedBox(height: 12),
            const Text('Pages are converted to black & white images, so text will no longer be selectable.'),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _run,
              icon: const Icon(Icons.filter_b_and_w),
              label: const Text('Convert to grayscale'),
            ),
          ],
        ],
      ),
    );
  }
}
