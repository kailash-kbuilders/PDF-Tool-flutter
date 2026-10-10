import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models.dart';
import '../services/image_service.dart';
import '../theme.dart';
import '../ui.dart';

class EditResult {
  final NormImage image;
  final EditParams params;
  const EditResult(this.image, this.params);
}

/// Page editor: filters, brightness/contrast, rotate, crop.
/// Undo / Redo / Remove filter sit right above the bottom bar.
class ImageEditorScreen extends StatefulWidget {
  final NormImage original;
  final EditParams initial;
  const ImageEditorScreen({super.key, required this.original, required this.initial});

  @override
  State<ImageEditorScreen> createState() => _ImageEditorScreenState();
}

class _ImageEditorScreenState extends State<ImageEditorScreen> {
  Rgba? _base;
  final Map<int, ui.Image> _thumbs = {};
  ui.Image? _preview;
  final List<EditParams> _history = [];
  int _hi = 0;
  EditParams? _draft; // while a slider is moving
  int _tab = 0; // 0 filters, 1 adjust, 2 rotate, 3 crop
  bool _busy = true;
  int _version = 0;
  Rect _crop = const Rect.fromLTRB(0, 0, 1, 1);
  bool _saving = false;

  static const _filterNames = ['Original', 'Magic Color', 'B&W', 'Grayscale'];

  EditParams get _p => _history[_hi];
  EditParams get _shown => _draft ?? _p;

  @override
  void initState() {
    super.initState();
    _history.add(widget.initial);
    _init();
  }

  @override
  void dispose() {
    _preview?.dispose();
    for (final t in _thumbs.values) {
      t.dispose();
    }
    super.dispose();
  }

  Future<void> _init() async {
    final base = await ImageService.decode(widget.original.bytes, maxSide: 1000);
    final small = await ImageService.decode(widget.original.bytes, maxSide: 160);
    for (var f = 0; f < 4; f++) {
      final r = await ImageService.processBg(small, EditParams(filter: f));
      final ui_ = await ImageService.toUiImage(r);
      if (!mounted) return;
      _thumbs[f] = ui_;
    }
    if (!mounted) return;
    _base = base;
    await _render(_p);
  }

  Future<void> _render(EditParams p) async {
    final base = _base;
    if (base == null) return;
    final v = ++_version;
    if (mounted) setState(() => _busy = true);
    final q = (_tab == 3) ? p.copyWith(cl: 0, ct: 0, cr: 0, cb: 0) : p;
    final res = await ImageService.processBg(base, q);
    final img = await ImageService.toUiImage(res);
    if (v != _version || !mounted) {
      img.dispose();
      return;
    }
    final old = _preview;
    setState(() {
      _preview = img;
      _busy = false;
    });
    old?.dispose();
  }

  void _commit(EditParams np) {
    _draft = null;
    if (np == _p) {
      _render(_p);
      return;
    }
    _history.removeRange(_hi + 1, _history.length);
    _history.add(np);
    _hi++;
    _render(_p);
  }

  void _undo() {
    if (_hi == 0) return;
    setState(() => _hi--);
    _render(_p);
  }

  void _redo() {
    if (_hi >= _history.length - 1) return;
    setState(() => _hi++);
    _render(_p);
  }

  void _setTab(int t) {
    if (t == _tab) return;
    setState(() {
      _tab = t;
      _crop = Rect.fromLTRB(_p.cl, _p.ct, 1 - _p.cr, 1 - _p.cb);
    });
    _render(_p);
  }

  Future<void> _autoCrop() async {
    final base = _base;
    if (base == null) return;
    final rotated = await ImageService.processBg(base, EditParams(rot: _p.rot));
    final r = await ImageService.autoCropBg(rotated);
    if (!mounted) return;
    if (r == null) {
      showSnack(context, 'Could not find page edges. Adjust the corners manually.');
      return;
    }
    setState(() => _crop = Rect.fromLTRB(r[0], r[1], 1 - r[2], 1 - r[3]));
  }

  void _applyCrop() {
    _commit(_p.copyWith(
      cl: _crop.left,
      ct: _crop.top,
      cr: 1 - _crop.right,
      cb: 1 - _crop.bottom,
    ));
    setState(() => _tab = 0);
    _render(_p);
  }

  void _rotate(int dir) {
    _commit(_p.copyWith(rot: (_p.rot + dir) % 4, cl: 0, ct: 0, cr: 0, cb: 0));
    setState(() => _crop = const Rect.fromLTRB(0, 0, 1, 1));
  }

  Future<void> _done() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final params = _p;
      final img = await ImageService.applyFull(widget.original, params);
      if (!mounted) return;
      Navigator.of(context).pop(EditResult(img, params));
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        await showError(context, 'PDF processing failed. Please try again.');
      }
    }
  }

  // ------------------------------------------------------------------ UI
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: buildAppBar(
        context,
        title: const Text('Edit page'),
        actions: [
          _saving
              ? const Padding(
                  padding: EdgeInsets.all(14),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  ),
                )
              : TextButton.icon(
                  onPressed: _done,
                  icon: const Icon(Icons.check, color: Colors.white),
                  label: const Text('Done', style: TextStyle(color: Colors.white)),
                ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _previewArea()),
          if (_tab == 3) _cropBar(),
          if (_tab == 1) _adjustPanel(),
          if (_tab == 0) _filterPanel(),
          if (_tab == 2) _rotatePanel(),
          // undo / redo / remove filter: directly above the bottom bar
          Material(
            color: scheme.surface,
            elevation: 2,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  TextButton.icon(
                    onPressed: _hi > 0 ? _undo : null,
                    icon: const Icon(Icons.undo),
                    label: const Text('Undo'),
                  ),
                  TextButton.icon(
                    onPressed: _hi < _history.length - 1 ? _redo : null,
                    icon: const Icon(Icons.redo),
                    label: const Text('Redo'),
                  ),
                  TextButton.icon(
                    onPressed: _p.isDefault ? null : () => _commit(EditParams.none),
                    icon: const Icon(Icons.layers_clear_outlined),
                    label: const Text('Remove filter'),
                  ),
                ],
              ),
            ),
          ),
          NavigationBar(
            height: 60,
            selectedIndex: _tab,
            backgroundColor: scheme.surface,
            indicatorColor: scheme.secondaryContainer,
            onDestinationSelected: _setTab,
            destinations: const [
              NavigationDestination(
                  icon: Icon(Icons.auto_fix_high_outlined),
                  selectedIcon: Icon(Icons.auto_fix_high, color: AppColors.red),
                  label: 'Filters'),
              NavigationDestination(
                  icon: Icon(Icons.tune),
                  selectedIcon: Icon(Icons.tune, color: AppColors.red),
                  label: 'Adjust'),
              NavigationDestination(
                  icon: Icon(Icons.rotate_90_degrees_cw_outlined),
                  selectedIcon: Icon(Icons.rotate_90_degrees_cw, color: AppColors.red),
                  label: 'Rotate'),
              NavigationDestination(
                  icon: Icon(Icons.crop),
                  selectedIcon: Icon(Icons.crop, color: AppColors.red),
                  label: 'Crop'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _previewArea() {
    final img = _preview;
    return Container(
      color: const Color(0xFF2B2B2B),
      padding: const EdgeInsets.all(12),
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (img != null)
            Center(
              child: AspectRatio(
                aspectRatio: img.width / img.height,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    RawImage(image: img, fit: BoxFit.fill),
                    if (_tab == 3) _cropOverlay(),
                  ],
                ),
              ),
            ),
          if (_busy) const CircularProgressIndicator(),
        ],
      ),
    );
  }

  // ---- crop overlay with four corner handles
  Widget _cropOverlay() {
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      final h = c.maxHeight;
      Widget handle(double nx, double ny, void Function(Offset d) onMove) {
        return Positioned(
          left: nx * w - 22,
          top: ny * h - 22,
          child: GestureDetector(
            onPanUpdate: (d) => setState(() => onMove(Offset(d.delta.dx / w, d.delta.dy / h))),
            child: Container(
              width: 44,
              height: 44,
              color: Colors.transparent,
              alignment: Alignment.center,
              child: Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  color: AppColors.red,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
              ),
            ),
          ),
        );
      }

      const minSize = 0.12;
      return Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(painter: _CropPainter(_crop)),
            ),
          ),
          handle(_crop.left, _crop.top, (d) {
            _crop = Rect.fromLTRB(
              clampD(_crop.left + d.dx, 0, _crop.right - minSize),
              clampD(_crop.top + d.dy, 0, _crop.bottom - minSize),
              _crop.right,
              _crop.bottom,
            );
          }),
          handle(_crop.right, _crop.top, (d) {
            _crop = Rect.fromLTRB(
              _crop.left,
              clampD(_crop.top + d.dy, 0, _crop.bottom - minSize),
              clampD(_crop.right + d.dx, _crop.left + minSize, 1),
              _crop.bottom,
            );
          }),
          handle(_crop.left, _crop.bottom, (d) {
            _crop = Rect.fromLTRB(
              clampD(_crop.left + d.dx, 0, _crop.right - minSize),
              _crop.top,
              _crop.right,
              clampD(_crop.bottom + d.dy, _crop.top + minSize, 1),
            );
          }),
          handle(_crop.right, _crop.bottom, (d) {
            _crop = Rect.fromLTRB(
              _crop.left,
              _crop.top,
              clampD(_crop.right + d.dx, _crop.left + minSize, 1),
              clampD(_crop.bottom + d.dy, _crop.top + minSize, 1),
            );
          }),
        ],
      );
    });
  }

  Widget _cropBar() {
    return Container(
      color: Theme.of(context).colorScheme.surface,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          OutlinedButton.icon(
            onPressed: _autoCrop,
            icon: const Icon(Icons.auto_awesome, size: 18),
            label: const Text('Auto'),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: () => setState(() => _crop = const Rect.fromLTRB(0, 0, 1, 1)),
            child: const Text('Reset'),
          ),
          const Spacer(),
          FilledButton(onPressed: _applyCrop, child: const Text('Apply crop')),
        ],
      ),
    );
  }

  Widget _filterPanel() {
    return Container(
      color: Theme.of(context).colorScheme.surface,
      height: 108,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.all(10),
        itemCount: 4,
        itemBuilder: (context, i) {
          final sel = _p.filter == i;
          final t = _thumbs[i];
          return GestureDetector(
            onTap: () => _commit(_p.copyWith(filter: i)),
            child: Container(
              width: 74,
              margin: const EdgeInsets.only(right: 10),
              child: Column(
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      border: Border.all(
                          color: sel ? AppColors.red : Colors.black26, width: sel ? 3 : 1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(5),
                      child: t == null
                          ? const SizedBox.shrink()
                          : RawImage(image: t, fit: BoxFit.cover),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(_filterNames[i],
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: sel ? FontWeight.bold : FontWeight.normal)),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _adjustPanel() {
    final p = _shown;
    return Container(
      color: Theme.of(context).colorScheme.surface,
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _sliderRow('Brightness', p.brightness, (v) => _p.copyWith(brightness: v)),
          _sliderRow('Contrast', p.contrast, (v) => _p.copyWith(contrast: v)),
        ],
      ),
    );
  }

  Widget _sliderRow(String label, double value, EditParams Function(double) make) {
    return Row(
      children: [
        SizedBox(width: 96, child: Text('$label ${value.round()}')),
        Expanded(
          child: Slider(
            value: value,
            min: -100,
            max: 100,
            onChanged: (v) {
              final np = _draft == null ? make(v) : _mergeDraft(label, v);
              setState(() => _draft = np);
              _render(np);
            },
            onChangeEnd: (_) {
              final d = _draft;
              if (d != null) _commit(d);
            },
          ),
        ),
      ],
    );
  }

  EditParams _mergeDraft(String label, double v) {
    final d = _draft ?? _p;
    return label == 'Brightness' ? d.copyWith(brightness: v) : d.copyWith(contrast: v);
  }

  Widget _rotatePanel() {
    return Container(
      color: Theme.of(context).colorScheme.surface,
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          OutlinedButton.icon(
            onPressed: () => _rotate(3),
            icon: const Icon(Icons.rotate_left),
            label: const Text('Left 90°'),
          ),
          OutlinedButton.icon(
            onPressed: () => _rotate(1),
            icon: const Icon(Icons.rotate_right),
            label: const Text('Right 90°'),
          ),
        ],
      ),
    );
  }
}

class _CropPainter extends CustomPainter {
  final Rect crop; // normalised
  _CropPainter(this.crop);

  @override
  void paint(Canvas canvas, Size size) {
    final r = Rect.fromLTRB(
        crop.left * size.width, crop.top * size.height, crop.right * size.width, crop.bottom * size.height);
    final shade = Paint()..color = Colors.black54;
    canvas.drawRect(Rect.fromLTRB(0, 0, size.width, r.top), shade);
    canvas.drawRect(Rect.fromLTRB(0, r.bottom, size.width, size.height), shade);
    canvas.drawRect(Rect.fromLTRB(0, r.top, r.left, r.bottom), shade);
    canvas.drawRect(Rect.fromLTRB(r.right, r.top, size.width, r.bottom), shade);
    canvas.drawRect(
        r,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5);
  }

  @override
  bool shouldRepaint(covariant _CropPainter old) => old.crop != crop;
}
