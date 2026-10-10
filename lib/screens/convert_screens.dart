import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';

import '../errors.dart';
import '../models.dart';
import '../services/file_service.dart';
import '../services/pdf_service.dart';
import '../theme.dart';
import '../ui.dart';

// ------------------------------------------------------------ text -> pdf
class TextToPdfScreen extends StatefulWidget {
  const TextToPdfScreen({super.key});

  @override
  State<TextToPdfScreen> createState() => _TextToPdfScreenState();
}

class _TextToPdfScreenState extends State<TextToPdfScreen> {
  final TextEditingController _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _wrap(String l, String r) {
    final t = _c.text;
    final s = _c.selection;
    if (s.start < 0 || s.end < 0) {
      _c.text = '$t$l$r';
      return;
    }
    final sel = s.textInside(t);
    final nt = s.textBefore(t) + l + sel + r + s.textAfter(t);
    _c.value = TextEditingValue(
      text: nt,
      selection: TextSelection.collapsed(offset: s.start + l.length + sel.length + r.length),
    );
  }

  void _prefix(String p) {
    final t = _c.text;
    final s = _c.selection;
    final pos = s.start < 0 ? t.length : s.start;
    final lineStart = pos == 0 ? 0 : t.lastIndexOf('\n', pos - 1) + 1;
    _c.value = TextEditingValue(
      text: t.substring(0, lineStart) + p + t.substring(lineStart),
      selection: TextSelection.collapsed(offset: pos + p.length),
    );
  }

  void _preview() {
    if (_c.text.trim().isEmpty) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Preview'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final raw in _c.text.split('\n'))
                  Builder(builder: (_) {
                    final m = MdLine.parse(raw);
                    return Padding(
                      padding: EdgeInsets.only(
                          left: m.bullet ? 12 : 0, bottom: m.text.isEmpty ? 8 : 4),
                      child: Text(
                        m.display,
                        style: TextStyle(
                          fontSize: m.size(14),
                          fontWeight: m.isBold ? FontWeight.bold : FontWeight.normal,
                          fontStyle: m.italic ? FontStyle.italic : FontStyle.normal,
                        ),
                      ),
                    );
                  }),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Close')),
        ],
      ),
    );
  }

  Future<void> _create() async {
    if (_c.text.trim().isEmpty) {
      await showError(context, 'Please enter some text first.');
      return;
    }
    final text = _c.text;
    await runPdfJob(context, 'text', () => PdfService.textToPdf(text));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: buildAppBar(context, title: const Text('Text to PDF')),
      body: Column(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                ActionChip(label: const Text('H1'), onPressed: () => _prefix('# ')),
                const SizedBox(width: 6),
                ActionChip(label: const Text('H2'), onPressed: () => _prefix('## ')),
                const SizedBox(width: 6),
                ActionChip(label: const Text('H3'), onPressed: () => _prefix('### ')),
                const SizedBox(width: 6),
                ActionChip(label: const Text('Bullet'), onPressed: () => _prefix('- ')),
                const SizedBox(width: 6),
                ActionChip(label: const Text('Bold'), onPressed: () => _wrap('**', '**')),
                const SizedBox(width: 6),
                ActionChip(label: const Text('Italic'), onPressed: () => _wrap('_', '_')),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                controller: _c,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                decoration: InputDecoration(
                  hintText: 'Type or paste your text here…\n\n# Heading\n- bullet point\n**bold line**',
                  filled: true,
                  fillColor: scheme.surface,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
          ),
          Material(
            color: scheme.surface,
            elevation: 6,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _preview,
                        icon: const Icon(Icons.visibility_outlined),
                        label: const Text('Preview'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _create,
                        icon: const Icon(Icons.picture_as_pdf),
                        label: const Text('Create PDF'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------ extract text
class ExtractTextScreen extends StatefulWidget {
  const ExtractTextScreen({super.key});

  @override
  State<ExtractTextScreen> createState() => _ExtractTextScreenState();
}

class _ExtractTextScreenState extends State<ExtractTextScreen> {
  LoadedPdf? _pdf;

  Future<void> _pick() async {
    final p = await pickSinglePdf(context);
    if (p != null && mounted) setState(() => _pdf = p);
  }

  Future<void> _extract() async {
    final p = _pdf!;
    final text = await runWithProgress<String>(context, () => PdfService.extractText(p.file.bytes));
    if (text == null || !mounted) return;
    if (text.trim().isEmpty) {
      await showError(context, 'No text found in this PDF. Try Scan to PDF with OCR for scanned pages.');
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Extracted text'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(child: SelectableText(text)),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (ctx.mounted) showSnack(ctx, 'Copied to clipboard.');
            },
            child: const Text('Copy'),
          ),
          TextButton(
            onPressed: () async {
              try {
                await FilePicker.platform.saveFile(
                  dialogTitle: 'Save text',
                  fileName: '${FileService.safeStem(p.file.name)}.txt',
                  bytes: Uint8List.fromList(utf8.encode(text)),
                  type: FileType.custom,
                  allowedExtensions: ['txt'],
                );
              } catch (_) {
                if (ctx.mounted) showSnack(ctx, 'Not enough storage space.');
              }
            },
            child: const Text('Save .txt'),
          ),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Done')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: buildAppBar(context, title: const Text('Extract text')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          PdfPickerCard(pdf: _pdf, onPick: _pick),
          if (_pdf != null) ...[
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _extract,
              icon: const Icon(Icons.notes),
              label: const Text('Extract text'),
            ),
          ],
        ],
      ),
    );
  }
}

// ------------------------------------------------------------ pdf -> images
class PdfToImagesScreen extends StatefulWidget {
  const PdfToImagesScreen({super.key});

  @override
  State<PdfToImagesScreen> createState() => _PdfToImagesScreenState();
}

class _PdfToImagesScreenState extends State<PdfToImagesScreen> {
  LoadedPdf? _pdf;
  final TextEditingController _c = TextEditingController();
  double _dpi = 150;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final p = await pickSinglePdf(context);
    if (p != null && mounted) setState(() => _pdf = p);
  }

  Future<void> _convert() async {
    final p = _pdf!;
    List<int> pages;
    try {
      pages = _c.text.trim().isEmpty
          ? List.generate(p.pages, (i) => i + 1)
          : PdfService.parsePageSpec(_c.text, p.pages);
    } catch (e) {
      await showError(context, friendlyError(e));
      return;
    }
    if (pages.length > 40) {
      await showError(context, 'Please choose 40 pages or fewer at a time.');
      return;
    }
    if (!mounted) return;
    final images = await runWithProgress<List<Uint8List>>(context, () async {
      final out = <Uint8List>[];
      for (final n in pages) {
        final b = await PdfService.renderPage(p.file.bytes, n - 1, dpi: _dpi);
        if (b == null) throw const AppError('PDF processing failed. Please try again.');
        out.add(b);
      }
      return out;
    }, message: 'Creating images…');
    if (images == null || !mounted) return;
    final stem = FileService.safeStem(p.file.name);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Images created successfully.',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: images.length,
                  itemBuilder: (_, i) => ListTile(
                    leading: Image.memory(images[i], width: 40, height: 52, fit: BoxFit.cover, cacheWidth: 100),
                    title: Text('${stem}_page_${pages[i]}.png'),
                    subtitle: Text(fmtSize(images[i].length)),
                    trailing: IconButton(
                      icon: const Icon(Icons.download),
                      onPressed: () async {
                        try {
                          await FilePicker.platform.saveFile(
                            dialogTitle: 'Save image',
                            fileName: '${stem}_page_${pages[i]}.png',
                            bytes: images[i],
                            type: FileType.image,
                          );
                        } catch (_) {
                          if (ctx.mounted) showSnack(ctx, 'Not enough storage space.');
                        }
                      },
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: buildAppBar(context, title: const Text('PDF to images')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          PdfPickerCard(pdf: _pdf, onPick: _pick),
          if (_pdf != null) ...[
            const SizedBox(height: 16),
            TextField(
              controller: _c,
              decoration: InputDecoration(
                labelText: 'Pages (leave empty for all)',
                hintText: 'e.g. 1-3 or 2,5',
                helperText: 'This PDF has ${_pdf!.pages} pages',
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Text('Quality: ${_dpi.round()} DPI'),
            Slider(
              value: _dpi,
              min: 72,
              max: 220,
              divisions: 4,
              onChanged: (v) => setState(() => _dpi = v),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _convert,
              icon: const Icon(Icons.photo_library_outlined),
              label: const Text('Convert to images'),
            ),
          ],
        ],
      ),
    );
  }
}
