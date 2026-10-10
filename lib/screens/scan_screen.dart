import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart' as mlkit;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../models.dart';
import '../services/image_service.dart';
import '../services/pdf_service.dart';
import '../ui.dart';
import 'image_editor_screen.dart';

/// "Image to PDF" uses the same screen as the scanner.
class ImageToPdfScreen extends StatelessWidget {
  const ImageToPdfScreen({super.key});

  @override
  Widget build(BuildContext context) => const ScanScreen(imagesMode: true);
}

class ScanScreen extends StatefulWidget {
  final bool imagesMode;
  const ScanScreen({super.key, this.imagesMode = false});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final List<EditablePage> _pages = [];
  int _nextId = 0;
  late bool _autoEnhance;
  late bool _searchable;
  bool _idCard = false;
  double _margin = 20;
  final ImagePicker _picker = ImagePicker();

  static const _filterNames = ['Original', 'Magic Color', 'B&W', 'Grayscale'];

  @override
  void initState() {
    super.initState();
    _autoEnhance = !widget.imagesMode;
    _searchable = !widget.imagesMode;
  }

  Future<void> _addRaw(List<Uint8List> raws) async {
    final enhance = _autoEnhance;
    final done = await runWithProgress<List<EditablePage>>(context, () async {
      final out = <EditablePage>[];
      for (final r in raws) {
        final n = await PdfService.normalizeImage(r);
        final page = EditablePage(_nextId++, n);
        if (enhance) {
          page.params = EditParams.magic;
          page.edited = await ImageService.applyFull(n, EditParams.magic);
        }
        out.add(page);
      }
      return out;
    }, message: 'Preparing pages…');
    if (done == null || !mounted) return;
    setState(() => _pages.addAll(done));
  }

  Future<void> _camera() async {
    XFile? shot;
    try {
      shot = await _picker.pickImage(source: ImageSource.camera);
    } catch (_) {
      if (mounted) {
        await showError(context, 'Camera is not available. Use "Images" instead.');
      }
      return;
    }
    if (shot == null || !mounted) return;
    final bytes = await shot.readAsBytes();
    if (!mounted) return;
    await _addRaw([bytes]);
  }

  Future<void> _gallery() async {
    try {
      final files = await _picker.pickMultiImage();
      if (files.isEmpty || !mounted) return;
      final raws = <Uint8List>[];
      for (final f in files) {
        raws.add(await f.readAsBytes());
      }
      if (!mounted) return;
      await _addRaw(raws);
    } catch (_) {
      if (mounted) await showError(context, 'This file format is not supported.');
    }
  }

  Future<void> _edit(EditablePage p) async {
    final res = await pushPage<EditResult>(
      context,
      ImageEditorScreen(original: p.orig, initial: p.params),
    );
    if (res == null || !mounted) return;
    setState(() {
      p.params = res.params;
      p.edited = res.params.isDefault ? null : res.image;
      p.ocr = null;
    });
  }

  Future<void> _filterAll(int filter) async {
    if (_pages.isEmpty) return;
    final list = List<EditablePage>.from(_pages);
    final ok = await runWithProgress<bool>(context, () async {
      for (final p in list) {
        final np = p.params.copyWith(filter: filter);
        final img = await ImageService.applyFull(p.orig, np);
        p.params = np;
        p.edited = np.isDefault ? null : img;
        p.ocr = null;
      }
      return true;
    }, message: 'Applying filter…');
    if (ok == true && mounted) setState(() {});
  }

  Future<OcrPage> _runOcr(EditablePage p) async {
    final cached = p.ocr;
    if (cached != null) return cached;
    final cur = p.cur;
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/scan_${DateTime.now().microsecondsSinceEpoch}.jpg');
    await f.writeAsBytes(cur.bytes);
    final rec = mlkit.TextRecognizer(script: mlkit.TextRecognitionScript.latin);
    try {
      final res = await rec.processImage(mlkit.InputImage.fromFilePath(f.path));
      final lines = <OcrLine>[];
      for (final b in res.blocks) {
        for (final l in b.lines) {
          final r = l.boundingBox;
          lines.add(OcrLine(l.text, r.left, r.top, r.right, r.bottom));
        }
      }
      final page = OcrPage(cur.w, cur.h, lines);
      p.ocr = page;
      return page;
    } finally {
      await rec.close();
      try {
        await f.delete();
      } catch (_) {}
    }
  }

  Future<void> _showText(EditablePage p) async {
    final page = await runWithProgress<OcrPage>(context, () => _runOcr(p),
        message: 'Reading text…');
    if (page == null || !mounted) return;
    final text = page.text;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Recognized text'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(text.trim().isEmpty ? 'No text found on this page.' : text),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (ctx.mounted) showSnack(ctx, 'Copied to clipboard.');
            },
            child: const Text('Copy'),
          ),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Done')),
        ],
      ),
    );
  }

  Future<void> _create() async {
    if (_pages.isEmpty) return;
    final pages = List<EditablePage>.from(_pages);
    final searchable = _searchable && !_idCard;
    final idCard = _idCard;
    final margin = widget.imagesMode ? _margin : 0.0;
    await runPdfJob(context, widget.imagesMode ? 'images' : 'scan', () async {
      List<OcrPage?>? ocr;
      if (searchable) {
        ocr = [];
        for (final p in pages) {
          try {
            ocr.add(await _runOcr(p));
          } catch (_) {
            ocr.add(null);
          }
        }
      }
      return PdfService.imagesToPdf(
        pages.map((p) => p.cur.bytes).toList(),
        margin: idCard ? 30 : margin,
        ocr: ocr,
        normalize: false,
        idCard: idCard,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = widget.imagesMode ? 'Image to PDF' : 'Scan to PDF';
    return Scaffold(
      appBar: buildAppBar(context, title: Text(title)),
      body: _pages.isEmpty
          ? Column(
              children: [
                Expanded(
                  child: EmptyState(
                    icon: widget.imagesMode
                        ? Icons.image_outlined
                        : Icons.document_scanner_outlined,
                    title: widget.imagesMode ? 'No images selected' : 'No pages yet',
                    subtitle: 'Capture a document or choose existing images.\nFilters make scans look like clean paper.',
                    action: widget.imagesMode ? 'Choose images' : 'Scan with camera',
                    onAction: widget.imagesMode ? _gallery : _camera,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 24),
                  child: OutlinedButton.icon(
                    onPressed: widget.imagesMode ? _camera : _gallery,
                    icon: Icon(widget.imagesMode
                        ? Icons.photo_camera_outlined
                        : Icons.photo_library_outlined),
                    label: Text(widget.imagesMode ? 'Use camera' : 'Choose images'),
                  ),
                ),
              ],
            )
          : Column(
              children: [
                Expanded(
                  child: ReorderableListView.builder(
                    padding: const EdgeInsets.all(16),
                    buildDefaultDragHandles: false,
                    itemCount: _pages.length,
                    onReorder: (o, n) {
                      setState(() {
                        if (n > o) n -= 1;
                        final it = _pages.removeAt(o);
                        _pages.insert(n, it);
                      });
                    },
                    itemBuilder: (context, i) {
                      final p = _pages[i];
                      final cur = p.cur;
                      return Card(
                        key: ValueKey(p.id),
                        margin: const EdgeInsets.only(bottom: 8),
                        elevation: 0,
                        color: scheme.surface,
                        child: ListTile(
                          contentPadding: const EdgeInsets.only(left: 12, right: 4),
                          onTap: () => _edit(p),
                          leading: ReorderableDragStartListener(
                            index: i,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: Image.memory(cur.bytes,
                                  width: 48, height: 60, fit: BoxFit.cover, cacheWidth: 140),
                            ),
                          ),
                          title: Text('Page ${i + 1}'),
                          subtitle: Text(_filterNames[p.params.filter] +
                              (p.params.isDefault ? '' : ' · edited')),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: 'Edit',
                                icon: const Icon(Icons.tune),
                                onPressed: () => _edit(p),
                              ),
                              IconButton(
                                tooltip: 'Read text (OCR)',
                                icon: const Icon(Icons.text_fields),
                                onPressed: () => _showText(p),
                              ),
                              IconButton(
                                tooltip: 'Remove',
                                icon: const Icon(Icons.close),
                                onPressed: () => setState(() => _pages.removeAt(i)),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                Material(
                  color: scheme.surface,
                  elevation: 6,
                  child: SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                            maxHeight: MediaQuery.of(context).size.height * 0.48),
                        child: SingleChildScrollView(
                          child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: [
                                const Text('All pages: '),
                                for (var f = 0; f < 4; f++) ...[
                                  ActionChip(
                                    label: Text(_filterNames[f]),
                                    onPressed: () => _filterAll(f),
                                  ),
                                  const SizedBox(width: 6),
                                ],
                              ],
                            ),
                          ),
                          SwitchListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Auto-enhance new pages'),
                            value: _autoEnhance,
                            onChanged: (v) => setState(() => _autoEnhance = v),
                          ),
                          SwitchListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: const Text('ID card layout (front + back on 1 page)'),
                            value: _idCard,
                            onChanged: (v) => setState(() => _idCard = v),
                          ),
                          if (!_idCard)
                            SwitchListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: const Text('Make searchable (OCR)'),
                              value: _searchable,
                              onChanged: (v) => setState(() => _searchable = v),
                            ),
                          if (widget.imagesMode && !_idCard)
                            Row(
                              children: [
                                Text('Margin ${_margin.round()} pt'),
                                Expanded(
                                  child: Slider(
                                    value: _margin,
                                    min: 0,
                                    max: 60,
                                    divisions: 12,
                                    onChanged: (v) => setState(() => _margin = v),
                                  ),
                                ),
                              ],
                            ),
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: _camera,
                                  icon: const Icon(Icons.photo_camera_outlined),
                                  label: const Text('Camera'),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: _gallery,
                                  icon: const Icon(Icons.photo_library_outlined),
                                  label: const Text('Images'),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                              onPressed: _create,
                              icon: const Icon(Icons.picture_as_pdf),
                              label: Text('Create PDF (${_pages.length})'),
                            ),
                          ),
                        ],
                      ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
