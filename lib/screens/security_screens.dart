import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models.dart';
import '../services/file_service.dart';
import '../services/pdf_service.dart';
import '../store.dart';
import '../ui.dart';

// ---------------------------------------------------------------- protect
class ProtectScreen extends StatefulWidget {
  const ProtectScreen({super.key});

  @override
  State<ProtectScreen> createState() => _ProtectScreenState();
}

class _ProtectScreenState extends State<ProtectScreen> {
  LoadedPdf? _pdf;
  final TextEditingController _pw = TextEditingController();
  final TextEditingController _pw2 = TextEditingController();
  bool _show = false;

  @override
  void dispose() {
    _pw.dispose();
    _pw2.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final p = await pickSinglePdf(context);
    if (p != null && mounted) setState(() => _pdf = p);
  }

  Future<void> _run() async {
    final p = _pdf!;
    if (_pw.text.isEmpty) {
      await showError(context, 'Enter a password.');
      return;
    }
    if (_pw.text != _pw2.text) {
      await showError(context, 'Passwords do not match.');
      return;
    }
    final pw = _pw.text;
    await runPdfJob(context, '${FileService.safeStem(p.file.name)}_protected',
        () => PdfService.protect(p.file.bytes, pw));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: buildAppBar(context, title: const Text('Protect PDF')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          PdfPickerCard(pdf: _pdf, onPick: _pick),
          if (_pdf != null) ...[
            const SizedBox(height: 16),
            TextField(
              controller: _pw,
              obscureText: !_show,
              decoration: InputDecoration(
                labelText: 'Password',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(_show ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _show = !_show),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _pw2,
              obscureText: !_show,
              decoration: const InputDecoration(
                labelText: 'Confirm password',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _run,
              icon: const Icon(Icons.lock_outline),
              label: const Text('Encrypt PDF'),
            ),
          ],
        ],
      ),
    );
  }
}

// ----------------------------------------------------------------- unlock
class UnlockScreen extends StatefulWidget {
  const UnlockScreen({super.key});

  @override
  State<UnlockScreen> createState() => _UnlockScreenState();
}

class _UnlockScreenState extends State<UnlockScreen> {
  LoadedPdf? _pdf;
  final TextEditingController _pw = TextEditingController();
  bool _show = false;

  @override
  void dispose() {
    _pw.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final p = await pickSinglePdf(context, countPages: false);
    if (p != null && mounted) setState(() => _pdf = p);
  }

  Future<void> _run() async {
    final p = _pdf!;
    final pw = _pw.text;
    await runPdfJob(context, '${FileService.safeStem(p.file.name)}_unlocked',
        () => PdfService.unlock(p.file.bytes, pw));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: buildAppBar(context, title: const Text('Remove PDF password')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          PdfPickerCard(pdf: _pdf, onPick: _pick),
          if (_pdf != null) ...[
            const SizedBox(height: 16),
            TextField(
              controller: _pw,
              obscureText: !_show,
              decoration: InputDecoration(
                labelText: 'Current password',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(_show ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _show = !_show),
                ),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _run,
              icon: const Icon(Icons.lock_open_outlined),
              label: const Text('Decrypt PDF'),
            ),
          ],
        ],
      ),
    );
  }
}

// --------------------------------------------------------------- compress
class CompressScreen extends StatefulWidget {
  const CompressScreen({super.key});

  @override
  State<CompressScreen> createState() => _CompressScreenState();
}

class _CompressScreenState extends State<CompressScreen> {
  LoadedPdf? _pdf;
  late CompressionLevel _level;

  @override
  void initState() {
    super.initState();
    _level = StoreScope.read(context).compression;
  }

  double get _factor {
    switch (_level) {
      case CompressionLevel.low:
        return 0.85;
      case CompressionLevel.medium:
        return 0.55;
      case CompressionLevel.high:
        return 0.35;
    }
  }

  String get _hint {
    switch (_level) {
      case CompressionLevel.low:
        return 'Keeps text selectable. Small savings.';
      case CompressionLevel.medium:
        return 'Pages become images (text not selectable). Good balance.';
      case CompressionLevel.high:
        return 'Pages become lower-quality images. Smallest file.';
    }
  }

  Future<void> _pick() async {
    final p = await pickSinglePdf(context);
    if (p != null && mounted) setState(() => _pdf = p);
  }

  Future<void> _run() async {
    final p = _pdf!;
    final level = _level;
    int? newSize;
    await runPdfJob(
      context,
      '${FileService.safeStem(p.file.name)}_compressed',
      () async {
        final out = await PdfService.compress(p.file.bytes, level);
        newSize = out.length;
        return out;
      },
      note: () => newSize == null
          ? null
          : '${fmtSize(p.file.size)} → ${fmtSize(newSize!)}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = _pdf;
    return Scaffold(
      appBar: buildAppBar(context, title: const Text('Compress PDF')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          PdfPickerCard(pdf: p, onPick: _pick),
          if (p != null) ...[
            const SizedBox(height: 16),
            SegmentedButton<CompressionLevel>(
              segments: const [
                ButtonSegment(value: CompressionLevel.low, label: Text('Low')),
                ButtonSegment(value: CompressionLevel.medium, label: Text('Medium')),
                ButtonSegment(value: CompressionLevel.high, label: Text('High')),
              ],
              selected: {_level},
              onSelectionChanged: (s) => setState(() => _level = s.first),
            ),
            const SizedBox(height: 10),
            Text(_hint),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(child: _SizeBox(label: 'Original', value: fmtSize(p.file.size))),
                const SizedBox(width: 12),
                Expanded(
                  child: _SizeBox(
                    label: 'Estimated',
                    value: '~${fmtSize((p.file.size * _factor).round())}',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _run,
              icon: const Icon(Icons.compress),
              label: const Text('Compress PDF'),
            ),
          ],
        ],
      ),
    );
  }
}

class _SizeBox extends StatelessWidget {
  final String label;
  final String value;
  const _SizeBox({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Text(label, style: TextStyle(color: Theme.of(context).hintColor, fontSize: 12)),
          const SizedBox(height: 4),
          Text(value, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

// -------------------------------------------------------------- watermark
class WatermarkScreen extends StatefulWidget {
  const WatermarkScreen({super.key});

  @override
  State<WatermarkScreen> createState() => _WatermarkScreenState();
}

class _WatermarkScreenState extends State<WatermarkScreen> {
  LoadedPdf? _pdf;
  bool _useImage = false;
  PickedFile? _image;
  final TextEditingController _text = TextEditingController(text: 'CONFIDENTIAL');
  double _size = 0.5;
  double _opacity = 0.3;
  double _angle = 45;
  double _posY = 0.5;
  int _color = 0xFF969696;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final p = await pickSinglePdf(context);
    if (p != null && mounted) setState(() => _pdf = p);
  }

  Future<void> _pickImage() async {
    try {
      final f = await FileService.pickImages(multiple: false);
      if (f.isNotEmpty && mounted) setState(() => _image = f.first);
    } catch (_) {
      if (mounted) await showError(context, 'This file format is not supported.');
    }
  }

  Future<void> _run() async {
    final p = _pdf!;
    if (_useImage && _image == null) {
      await showError(context, 'Choose an image first.');
      return;
    }
    if (!_useImage && _text.text.trim().isEmpty) {
      await showError(context, 'Enter watermark text.');
      return;
    }
    final text = _useImage ? null : _text.text.trim();
    final Uint8List? image = _useImage ? _image!.bytes : null;
    final size = _size, opacity = _opacity, angle = _angle, posY = _posY;
    final color = _color;
    await runPdfJob(
      context,
      '${FileService.safeStem(p.file.name)}_watermarked',
      () => PdfService.watermark(p.file.bytes,
          text: text, image: image, size: size, opacity: opacity, angle: angle, posY: posY, color: color),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: buildAppBar(context, title: const Text('Watermark')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          PdfPickerCard(pdf: _pdf, onPick: _pick),
          if (_pdf != null) ...[
            const SizedBox(height: 16),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Text'), icon: Icon(Icons.title)),
                ButtonSegment(value: true, label: Text('Image'), icon: Icon(Icons.image_outlined)),
              ],
              selected: {_useImage},
              onSelectionChanged: (s) => setState(() => _useImage = s.first),
            ),
            const SizedBox(height: 12),
            if (_useImage)
              OutlinedButton.icon(
                onPressed: _pickImage,
                icon: const Icon(Icons.add_photo_alternate_outlined),
                label: Text(_image == null ? 'Choose image' : _image!.name),
              )
            else
              TextField(
                controller: _text,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'Watermark text',
                  border: OutlineInputBorder(),
                ),
              ),
            const SizedBox(height: 12),
            // live preview
            AspectRatio(
              aspectRatio: 0.72,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: LayoutBuilder(builder: (context, c) {
                  return Stack(
                    children: [
                      Positioned(
                        left: 0,
                        right: 0,
                        top: c.maxHeight * _posY - 24,
                        child: Opacity(
                          opacity: _opacity,
                          child: Transform.rotate(
                            angle: -_angle * 3.14159265 / 180,
                            child: Center(
                              child: _useImage && _image != null
                                  ? Image.memory(_image!.bytes,
                                      width: c.maxWidth * (0.1 + _size * 0.8))
                                  : Text(
                                      _text.text,
                                      style: TextStyle(
                                        color: Color(_color),
                                        fontWeight: FontWeight.bold,
                                        fontSize: c.maxWidth * (0.05 + _size * 0.2),
                                      ),
                                    ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                }),
              ),
            ),
            const SizedBox(height: 8),
            const Text('Size'),
            Slider(value: _size, onChanged: (v) => setState(() => _size = v)),
            Text('Transparency (${(_opacity * 100).round()}% visible)'),
            Slider(
                value: _opacity,
                min: 0.05,
                max: 1,
                onChanged: (v) => setState(() => _opacity = v)),
            Text('Rotation (${_angle.round()}°)'),
            Slider(
                value: _angle,
                min: 0,
                max: 360,
                divisions: 24,
                onChanged: (v) => setState(() => _angle = v)),
            const Text('Color'),
            const SizedBox(height: 6),
            Row(
              children: [
                for (final c in const [0xFF969696, 0xFFE31B23, 0xFF1565C0, 0xFF2E7D32, 0xFF111111])
                  GestureDetector(
                    onTap: () => setState(() => _color = c),
                    child: Container(
                      width: 30,
                      height: 30,
                      margin: const EdgeInsets.only(right: 10),
                      decoration: BoxDecoration(
                        color: Color(c),
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: _color == c ? Colors.blueGrey : Colors.black26,
                            width: _color == c ? 3 : 1),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            const Text('Position'),
            const SizedBox(height: 4),
            SegmentedButton<double>(
              segments: const [
                ButtonSegment(value: 0.15, label: Text('Top')),
                ButtonSegment(value: 0.5, label: Text('Center')),
                ButtonSegment(value: 0.85, label: Text('Bottom')),
              ],
              selected: {_posY},
              onSelectionChanged: (s) => setState(() => _posY = s.first),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _run,
              icon: const Icon(Icons.water_drop_outlined),
              label: const Text('Apply Watermark'),
            ),
          ],
        ],
      ),
    );
  }
}

// ----------------------------------------------------------- page numbers
class PageNumbersScreen extends StatefulWidget {
  const PageNumbersScreen({super.key});

  @override
  State<PageNumbersScreen> createState() => _PageNumbersScreenState();
}

class _PageNumbersScreenState extends State<PageNumbersScreen> {
  LoadedPdf? _pdf;
  int _style = 2;
  int _align = 1;
  bool _top = false;

  Future<void> _pick() async {
    final p = await pickSinglePdf(context);
    if (p != null && mounted) setState(() => _pdf = p);
  }

  Future<void> _run() async {
    final p = _pdf!;
    final style = _style, align = _align, top = _top;
    await runPdfJob(
      context,
      '${FileService.safeStem(p.file.name)}_numbered',
      () => PdfService.addPageNumbers(p.file.bytes, style: style, align: align, top: top),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: buildAppBar(context, title: const Text('Page numbers')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          PdfPickerCard(pdf: _pdf, onPick: _pick),
          if (_pdf != null) ...[
            const SizedBox(height: 16),
            const Text('Format'),
            const SizedBox(height: 4),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('1')),
                ButtonSegment(value: 1, label: Text('1 / N')),
                ButtonSegment(value: 2, label: Text('Page 1 of N')),
              ],
              selected: {_style},
              onSelectionChanged: (s) => setState(() => _style = s.first),
            ),
            const SizedBox(height: 16),
            const Text('Alignment'),
            const SizedBox(height: 4),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('Left')),
                ButtonSegment(value: 1, label: Text('Center')),
                ButtonSegment(value: 2, label: Text('Right')),
              ],
              selected: {_align},
              onSelectionChanged: (s) => setState(() => _align = s.first),
            ),
            const SizedBox(height: 16),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Place at top of page'),
              value: _top,
              onChanged: (v) => setState(() => _top = v),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _run,
              icon: const Icon(Icons.pin_outlined),
              label: const Text('Add page numbers'),
            ),
          ],
        ],
      ),
    );
  }
}
