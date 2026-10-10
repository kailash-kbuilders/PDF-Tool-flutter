import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:printing/printing.dart' show Printing;

import '../errors.dart';
import '../models.dart';
import '../services/file_service.dart';
import '../services/image_service.dart';
import '../services/pdf_service.dart';
import '../store.dart';
import '../theme.dart';
import '../ui.dart';
import 'extra_screens.dart';

enum Tool {
  view,
  draw,
  highlight,
  underline,
  strike,
  text,
  note,
  stamp,
  signature,
  image,
  move
}

class _Sig {
  final Uint8List bytes;
  final double ratio; // height / width
  const _Sig(this.bytes, this.ratio);
}

const _stamps = <String, int>{
  'DRAFT': 0xFF1565C0,
  'APPROVED': 0xFF2E7D32,
  'CONFIDENTIAL': 0xFFC62828,
  'PAID': 0xFF2E7D32,
  'REJECTED': 0xFFC62828,
  'SIGNED': 0xFF1565C0,
};

class ViewerScreen extends StatefulWidget {
  final String name;
  final String? path;
  final Uint8List? bytes;
  const ViewerScreen({super.key, required this.name, this.path, this.bytes});

  @override
  State<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends State<ViewerScreen> {
  Uint8List? _bytes;
  List<double> _aspect = [];
  String? _error;
  final Map<int, Uint8List> _cache = {};
  final List<AnnoData> _annos = [];
  Tool _tool = Tool.view;
  int _color = 0xFFE31B23;
  int _hlColor = 0xFFFFEB3B;
  bool _horizontal = false;
  bool _night = false;
  AnnoData? _live;
  _Sig? _sig;
  AnnoData? _selected;

  // zoom / navigation
  double _zoom = 1.0;
  final ScrollController _sc = ScrollController();
  PageController _pc = PageController();
  int _curPage = 0;
  List<double> _pageTops = [];
  double _vh = 600;
  final Map<int, Offset> _pointers = {};
  double _pinchStartDist = 0;
  double _pinchStartZoom = 1;

  static const _palette = [0xFFE31B23, 0xFF1565C0, 0xFF2E7D32, 0xFF111111, 0xFFFFEB3B];

  String get _bmKey => '${widget.name}|${_bytes?.length ?? 0}';

  @override
  void initState() {
    super.initState();
    _horizontal = StoreScope.read(context).viewerMode == ViewerMode.horizontal;
    _sc.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _sc.dispose();
    _pc.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      Uint8List? b = widget.bytes;
      if (b == null && widget.path != null) {
        b = await File(widget.path!).readAsBytes();
      }
      if (b == null) throw const AppError('Unable to open this PDF.');
      final sizes = await PdfService.pageSizes(b);
      if (sizes.isEmpty) throw const AppError('Unable to open this PDF.');
      final asp = <double>[];
      for (var i = 0; i + 1 < sizes.length; i += 2) {
        asp.add(sizes[i] <= 0 ? 1.4 : sizes[i + 1] / sizes[i]);
      }
      if (!mounted) return;
      setState(() {
        _bytes = b;
        _aspect = asp;
      });
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    }
  }

  // ------------------------------------------------------------ navigation
  void _onScroll() {
    if (_horizontal || !_sc.hasClients || _pageTops.isEmpty) return;
    final off = _sc.offset + _vh * 0.3;
    var idx = 0;
    for (var i = 0; i < _pageTops.length; i++) {
      if (_pageTops[i] <= off) {
        idx = i;
      } else {
        break;
      }
    }
    if (idx != _curPage) setState(() => _curPage = idx);
  }

  void _jumpTo(int i) {
    if (i < 0 || i >= _aspect.length) return;
    if (_horizontal) {
      if (_pc.hasClients) _pc.jumpToPage(i);
      setState(() => _curPage = i);
    } else if (_sc.hasClients && i < _pageTops.length) {
      _sc.jumpTo(clampD(_pageTops[i] - 8, 0, _sc.position.maxScrollExtent));
      setState(() => _curPage = i);
    }
  }

  Future<void> _askPage() async {
    final text = await showDialog<String>(
      context: context,
      builder: (_) => TextInputDialog(
        title: 'Go to page (1-${_aspect.length})',
        initial: '${_curPage + 1}',
      ),
    );
    final n = int.tryParse((text ?? '').trim());
    if (n != null) _jumpTo(n - 1);
  }

  void _toggleMode() {
    setState(() {
      _horizontal = !_horizontal;
      _zoom = 1;
      if (_horizontal) {
        _pc.dispose();
        _pc = PageController(initialPage: _curPage);
      }
    });
    if (!_horizontal) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _jumpTo(_curPage));
    }
  }

  Future<void> _openSearch() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _SearchSheet(
        bytes: _bytes!,
        onJump: (p) {
          Navigator.of(ctx).pop();
          _jumpTo(p);
        },
      ),
    );
  }

  Future<void> _openBookmarks() async {
    final store = StoreScope.read(context);
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => ListenableBuilder(
        listenable: store,
        builder: (_, __) {
          final pages = store.bookmarksFor(_bmKey);
          return SafeArea(
            child: pages.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(32),
                    child: Text('No bookmarks yet. Tap the bookmark icon on a page.',
                        textAlign: TextAlign.center),
                  )
                : ListView(
                    shrinkWrap: true,
                    children: [
                      for (final p in pages)
                        ListTile(
                          leading: const Icon(Icons.bookmark, color: AppColors.red),
                          title: Text('Page ${p + 1}'),
                          onTap: () {
                            Navigator.of(ctx).pop();
                            _jumpTo(p);
                          },
                          trailing: IconButton(
                            icon: const Icon(Icons.close),
                            onPressed: () => store.toggleBookmark(_bmKey, p),
                          ),
                        ),
                    ],
                  ),
          );
        },
      ),
    );
  }

  // ----------------------------------------------------------------- tools
  Future<void> _selectTool(Tool t) async {
    if (t == Tool.signature) {
      final sig = await showDialog<_Sig>(
        context: context,
        builder: (_) => const _SignatureDialog(),
      );
      if (sig == null || !mounted) return;
      setState(() {
        _sig = sig;
        _tool = Tool.signature;
        _selected = null;
      });
      showSnack(context, 'Tap on the page to place your signature.');
      return;
    }
    if (t == Tool.image) {
      try {
        final files = await FileService.pickImages(multiple: false);
        if (files.isEmpty || !mounted) return;
        final r = await ImageService.decode(files.first.bytes, maxSide: 64);
        if (!mounted) return;
        setState(() {
          _sig = _Sig(files.first.bytes, r.h / r.w);
          _tool = Tool.signature;
          _selected = null;
        });
        showSnack(context, 'Tap on the page to place the image.');
      } catch (_) {
        if (mounted) await showError(context, 'This file format is not supported.');
      }
      return;
    }
    setState(() {
      _tool = t;
      if (t != Tool.move) _selected = null;
    });
  }

  int _typeForTool() {
    if (_tool == Tool.highlight) return AnnoType.highlight;
    if (_tool == Tool.underline) return AnnoType.underline;
    if (_tool == Tool.strike) return AnnoType.strike;
    return AnnoType.draw;
  }

  Future<void> _addNote(int page, Offset p) async {
    final text = await showDialog<String>(
      context: context,
      builder: (_) =>
          const TextInputDialog(title: 'Sticky note', hint: 'Write a note…', maxLines: 4),
    );
    if (text == null || text.trim().isEmpty || !mounted) return;
    setState(() => _annos.add(
        AnnoData(type: AnnoType.note, page: page, pts: [p.dx, p.dy], text: text.trim())));
  }

  Future<void> _addText(int page, Offset p) async {
    final text = await showDialog<String>(
      context: context,
      builder: (_) =>
          const TextInputDialog(title: 'Add text', hint: 'Type here…', maxLines: 3),
    );
    if (text == null || text.trim().isEmpty || !mounted) return;
    setState(() => _annos.add(AnnoData(
          type: AnnoType.text,
          page: page,
          pts: [p.dx, p.dy],
          text: text.trim(),
          color: _color,
          width: 0.03,
        )));
  }

  Future<void> _addStamp(int page, Offset p) async {
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Choose stamp'),
        children: [
          for (final e in _stamps.entries)
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(e.key),
              child: Text(e.key,
                  style: TextStyle(color: Color(e.value), fontWeight: FontWeight.bold)),
            ),
        ],
      ),
    );
    if (name == null || !mounted) return;
    setState(() => _annos.add(AnnoData(
          type: AnnoType.stamp,
          page: page,
          pts: [p.dx, p.dy],
          text: name,
          color: _stamps[name]!,
        )));
  }

  void _placeSignature(int page, Offset p, double w, double h) {
    final sig = _sig;
    if (sig == null) return;
    const sw = 0.3;
    final sh = sw * sig.ratio * (w / h);
    final x = clampD(p.dx - sw / 2, 0, 1 - sw);
    final y = clampD(p.dy - sh / 2, 0, 1 - sh);
    final a = AnnoData(
        type: AnnoType.signature, page: page, pts: [x, y, sw, sh], image: sig.bytes);
    setState(() {
      _annos.add(a);
      _selected = a;
      _tool = Tool.move;
    });
  }

  void _selectAt(int page, Offset p) {
    AnnoData? hit;
    for (final a in _annos.reversed) {
      if (a.type == AnnoType.signature &&
          a.page == page &&
          Rect.fromLTWH(a.pts[0], a.pts[1], a.pts[2], a.pts[3]).contains(p)) {
        hit = a;
        break;
      }
    }
    setState(() => _selected = hit);
  }

  void _moveSelected(int page, Offset delta, double w, double h) {
    final s = _selected;
    if (s == null || s.page != page) return;
    setState(() {
      s.pts[0] = clampD(s.pts[0] + delta.dx / w, 0, 1 - s.pts[2]);
      s.pts[1] = clampD(s.pts[1] + delta.dy / h, 0, 1 - s.pts[3]);
    });
  }

  void _scaleSelected(double f) {
    final s = _selected;
    if (s == null) return;
    setState(() {
      final nw = clampD(s.pts[2] * f, 0.06, 0.95);
      final k = nw / s.pts[2];
      final nh = clampD(s.pts[3] * k, 0.02, 0.95);
      s.pts[2] = nw;
      s.pts[3] = nh;
      s.pts[0] = clampD(s.pts[0], 0, 1 - nw);
      s.pts[1] = clampD(s.pts[1], 0, 1 - nh);
    });
  }

  void _deleteSelected() {
    final s = _selected;
    if (s == null) return;
    setState(() {
      _annos.remove(s);
      _selected = null;
    });
  }

  void _undo() {
    if (_annos.isEmpty) return;
    setState(() {
      final r = _annos.removeLast();
      if (identical(r, _selected)) _selected = null;
    });
  }

  Future<void> _save() async {
    if (_annos.isEmpty) {
      showSnack(context, 'Add an annotation first.');
      return;
    }
    final src = _bytes!;
    final list = List<AnnoData>.from(_annos);
    final base = FileService.safeStem(widget.name);
    await runPdfJob(context, '${base}_annotated', () => PdfService.burnAnnotations(src, list));
  }

  // -------------------------------------------------------------------- UI
  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final bookmarked = _bytes != null && store.bookmarksFor(_bmKey).contains(_curPage);
    final ready = _bytes != null;
    return Scaffold(
      backgroundColor: _night ? const Color(0xFF2A2A2A) : null,
      appBar: buildAppBar(
        context,
        title: Text(widget.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (ready)
            TextButton(
              onPressed: _askPage,
              child: Text('${_curPage + 1}/${_aspect.length}',
                  style: const TextStyle(color: Colors.white)),
            ),
          IconButton(
            tooltip: 'Search',
            icon: const Icon(Icons.search),
            onPressed: ready ? _openSearch : null,
          ),
          IconButton(
            tooltip: 'Bookmark this page',
            icon: Icon(bookmarked ? Icons.bookmark : Icons.bookmark_border),
            onPressed: ready ? () => store.toggleBookmark(_bmKey, _curPage) : null,
          ),
          IconButton(
            tooltip: 'Save',
            icon: const Icon(Icons.save_outlined),
            onPressed: ready ? _save : null,
          ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'mode') {
                _toggleMode();
              } else if (v == 'night') {
                setState(() => _night = !_night);
              } else if (v == 'bookmarks') {
                await _openBookmarks();
              } else if (v == 'zoom') {
                setState(() => _zoom = 1);
              } else if (v == 'fill' && _bytes != null) {
                await pushPage<void>(context, FormFillScreen(name: widget.name, bytes: _bytes!));
              } else if (v == 'share' && _bytes != null) {
                final n = widget.name.toLowerCase().endsWith('.pdf')
                    ? widget.name
                    : '${widget.name}.pdf';
                await Printing.sharePdf(bytes: _bytes!, filename: n);
              } else if (v == 'print' && _bytes != null) {
                final b = _bytes!;
                await Printing.layoutPdf(onLayout: (_) async => b, name: widget.name);
              } else if (v == 'info' && _bytes != null) {
                showSnack(context, '${_aspect.length} pages · ${fmtSize(_bytes!.length)}');
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                  value: 'mode',
                  child: Text(_horizontal ? 'Vertical scrolling' : 'Horizontal reading')),
              PopupMenuItem(
                  value: 'night',
                  child: Text(_night ? 'Light reading mode' : 'Dark reading mode')),
              const PopupMenuItem(value: 'bookmarks', child: Text('Bookmarks')),
              const PopupMenuItem(value: 'zoom', child: Text('Reset zoom')),
              const PopupMenuItem(value: 'fill', child: Text('Fill form')),
              const PopupMenuItem(value: 'share', child: Text('Share')),
              const PopupMenuItem(value: 'print', child: Text('Print')),
              const PopupMenuItem(value: 'info', child: Text('Document info')),
            ],
          ),
        ],
      ),
      body: _body(),
      bottomNavigationBar: _bytes == null ? null : _toolbar(),
    );
  }

  double _dist() {
    final v = _pointers.values.toList();
    return (v[0] - v[1]).distance;
  }

  Widget _body() {
    if (_error != null) {
      return EmptyState(
        icon: Icons.error_outline,
        title: _error!,
        action: 'Go back',
        onAction: () => Navigator.of(context).pop(),
      );
    }
    if (_bytes == null) return const Center(child: CircularProgressIndicator());
    return LayoutBuilder(builder: (context, c) {
      final vw = c.maxWidth;
      final vh = c.maxHeight;
      _vh = vh;
      final lock = _tool != Tool.view;
      final ScrollPhysics? physics = lock ? const NeverScrollableScrollPhysics() : null;

      if (_horizontal) {
        return PageView.builder(
          controller: _pc,
          physics: physics,
          itemCount: _aspect.length,
          onPageChanged: (i) => setState(() => _curPage = i),
          itemBuilder: (_, i) {
            var w = vw - 16;
            if (w * _aspect[i] > vh - 16) w = (vh - 16) / _aspect[i];
            return Center(child: _pageBox(i, w));
          },
        );
      }

      final lw = vw * _zoom;
      final tops = <double>[];
      var y = 8.0;
      for (final a in _aspect) {
        tops.add(y);
        y += (lw - 16) * a + 8;
      }
      _pageTops = tops;

      final list = ListView.builder(
        controller: _sc,
        physics: physics,
        padding: const EdgeInsets.all(8),
        itemCount: _aspect.length,
        itemBuilder: (_, i) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Center(child: _pageBox(i, lw - 16)),
        ),
      );
      final Widget content = _zoom > 1.01
          ? SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: physics,
              child: SizedBox(width: lw, height: vh, child: list),
            )
          : list;

      return Listener(
        onPointerDown: (e) {
          _pointers[e.pointer] = e.position;
          if (_pointers.length == 2) {
            _pinchStartDist = _dist();
            _pinchStartZoom = _zoom;
          }
        },
        onPointerMove: (e) {
          if (!_pointers.containsKey(e.pointer)) return;
          _pointers[e.pointer] = e.position;
          if (_pointers.length == 2 && _tool == Tool.view && _pinchStartDist > 0) {
            final z = clampD(_pinchStartZoom * _dist() / _pinchStartDist, 1, 4);
            if ((z - _zoom).abs() > 0.03) setState(() => _zoom = z);
          }
        },
        onPointerUp: (e) => _pointers.remove(e.pointer),
        onPointerCancel: (e) => _pointers.remove(e.pointer),
        child: GestureDetector(
          onDoubleTap: _tool == Tool.view
              ? () => setState(() => _zoom = _zoom > 1.1 ? 1.0 : 2.0)
              : null,
          child: content,
        ),
      );
    });
  }

  Widget _pageBox(int i, double w) {
    final h = w * _aspect[i];
    final shapes = _annos.where((a) => a.page == i && a.type != AnnoType.signature).toList();
    final sigs = _annos.where((a) => a.page == i && a.type == AnnoType.signature).toList();
    final live = (_live != null && _live!.page == i) ? _live : null;
    return Container(
      width: w,
      height: h,
      decoration: const BoxDecoration(
        color: Colors.white,
        boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 4)],
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: PageImage(
              key: ValueKey('page$i'),
              bytes: _bytes!,
              index: i,
              cache: _cache,
              dpi: 110,
              night: _night,
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(painter: _AnnoPainter(shapes, live)),
            ),
          ),
          for (final s in sigs)
            Positioned(
              left: s.pts[0] * w,
              top: s.pts[1] * h,
              width: s.pts[2] * w,
              height: s.pts[3] * h,
              child: IgnorePointer(
                child: Container(
                  decoration: identical(s, _selected)
                      ? BoxDecoration(border: Border.all(color: AppColors.red, width: 1.5))
                      : null,
                  child: Image.memory(s.image!, fit: BoxFit.fill),
                ),
              ),
            ),
          if (_tool != Tool.view) Positioned.fill(child: _gestures(i, w, h)),
        ],
      ),
    );
  }

  Widget _gestures(int page, double w, double h) {
    Offset n(Offset p) => Offset(clampD(p.dx / w, 0, 1), clampD(p.dy / h, 0, 1));
    if (_tool == Tool.draw ||
        _tool == Tool.highlight ||
        _tool == Tool.underline ||
        _tool == Tool.strike) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (d) {
          final p = n(d.localPosition);
          setState(() {
            _live = AnnoData(
              type: _typeForTool(),
              page: page,
              pts: [p.dx, p.dy],
              color: _tool == Tool.highlight ? _hlColor : _color,
              width: _tool == Tool.draw ? 0.004 : 0.003,
            );
          });
        },
        onPanUpdate: (d) {
          final l = _live;
          if (l == null) return;
          final p = n(d.localPosition);
          setState(() {
            if (_tool == Tool.draw) {
              l.pts = [...l.pts, p.dx, p.dy];
            } else {
              l.pts = [l.pts[0], l.pts[1], p.dx, p.dy];
            }
          });
        },
        onPanEnd: (_) {
          final l = _live;
          if (l == null) return;
          setState(() {
            final ok = l.type == AnnoType.draw
                ? l.pts.length >= 4
                : (l.pts.length >= 4 && (l.pts[2] - l.pts[0]).abs() > 0.01);
            if (ok) _annos.add(l);
            _live = null;
          });
        },
      );
    }
    if (_tool == Tool.note) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) => _addNote(page, n(d.localPosition)),
      );
    }
    if (_tool == Tool.text) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) => _addText(page, n(d.localPosition)),
      );
    }
    if (_tool == Tool.stamp) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) => _addStamp(page, n(d.localPosition)),
      );
    }
    if (_tool == Tool.signature) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) => _placeSignature(page, n(d.localPosition), w, h),
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (d) => _selectAt(page, n(d.localPosition)),
      onPanStart: (d) => _selectAt(page, n(d.localPosition)),
      onPanUpdate: (d) => _moveSelected(page, d.delta, w, h),
    );
  }

  Widget _toolBtn(Tool t, IconData icon, String label) {
    final on = _tool == t;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => _selectTool(t),
      child: Container(
        width: 62,
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: on ? Theme.of(context).colorScheme.secondaryContainer : null,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: on ? AppColors.red : null),
            const SizedBox(height: 2),
            Text(label, style: const TextStyle(fontSize: 10.5)),
          ],
        ),
      ),
    );
  }

  Widget _toolbar() {
    final active = _tool == Tool.highlight ? _hlColor : _color;
    final showColors = _tool == Tool.draw ||
        _tool == Tool.highlight ||
        _tool == Tool.underline ||
        _tool == Tool.strike ||
        _tool == Tool.text;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_selected != null)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('Selected:'),
                  IconButton(
                      tooltip: 'Smaller',
                      icon: const Icon(Icons.remove_circle_outline),
                      onPressed: () => _scaleSelected(0.85)),
                  IconButton(
                      tooltip: 'Larger',
                      icon: const Icon(Icons.add_circle_outline),
                      onPressed: () => _scaleSelected(1.18)),
                  IconButton(
                      tooltip: 'Delete',
                      icon: const Icon(Icons.delete_outline, color: AppColors.red),
                      onPressed: _deleteSelected),
                ],
              ),
            if (showColors)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (final c in _palette)
                      GestureDetector(
                        onTap: () => setState(() {
                          if (_tool == Tool.highlight) {
                            _hlColor = c;
                          } else {
                            _color = c;
                          }
                        }),
                        child: Container(
                          width: 26,
                          height: 26,
                          margin: const EdgeInsets.symmetric(horizontal: 6),
                          decoration: BoxDecoration(
                            color: Color(c),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: active == c ? Colors.blueGrey : Colors.black26,
                              width: active == c ? 3 : 1,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Row(
                children: [
                  _toolBtn(Tool.view, Icons.pan_tool_outlined, 'Scroll'),
                  _toolBtn(Tool.draw, Icons.gesture, 'Draw'),
                  _toolBtn(Tool.highlight, Icons.border_color_outlined, 'Highlight'),
                  _toolBtn(Tool.underline, Icons.format_underlined, 'Underline'),
                  _toolBtn(Tool.strike, Icons.format_strikethrough, 'Strike'),
                  _toolBtn(Tool.text, Icons.text_fields, 'Text'),
                  _toolBtn(Tool.note, Icons.sticky_note_2_outlined, 'Note'),
                  _toolBtn(Tool.stamp, Icons.approval, 'Stamp'),
                  _toolBtn(Tool.signature, Icons.draw_outlined, 'Signature'),
                  _toolBtn(Tool.image, Icons.add_photo_alternate_outlined, 'Image'),
                  _toolBtn(Tool.move, Icons.open_with, 'Move'),
                  InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: _annos.isEmpty ? null : _undo,
                    child: Container(
                      width: 62,
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.undo, size: 22, color: _annos.isEmpty ? Colors.grey : null),
                          const SizedBox(height: 2),
                          const Text('Undo', style: TextStyle(fontSize: 10.5)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------- search sheet
class _SearchSheet extends StatefulWidget {
  final Uint8List bytes;
  final void Function(int page) onJump;
  const _SearchSheet({required this.bytes, required this.onJump});

  @override
  State<_SearchSheet> createState() => _SearchSheetState();
}

class _SearchSheetState extends State<_SearchSheet> {
  final TextEditingController _c = TextEditingController();
  List<List<Object>>? _res;
  bool _busy = false;
  String? _err;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final q = _c.text.trim();
    if (q.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      final r = await PdfService.searchText(widget.bytes, q);
      if (!mounted) return;
      setState(() {
        _res = r;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _res = [];
        _busy = false;
        _err = friendlyError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final res = _res;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: ConstrainedBox(
          constraints:
              BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: TextField(
                  controller: _c,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _run(),
                  decoration: InputDecoration(
                    hintText: 'Search in this PDF',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(icon: const Icon(Icons.search), onPressed: _run),
                  ),
                ),
              ),
              if (_busy) const Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator()),
              if (_err != null) Padding(padding: const EdgeInsets.all(16), child: Text(_err!)),
              if (res != null && res.isEmpty && !_busy && _err == null)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('No matches found. Scanned pages have no text to search.'),
                ),
              if (res != null && res.isNotEmpty)
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: res.length,
                    itemBuilder: (_, i) => ListTile(
                      dense: true,
                      title: Text('Page ${(res[i][0] as int) + 1}'),
                      subtitle: Text(res[i][1] as String, maxLines: 2),
                      onTap: () => widget.onJump(res[i][0] as int),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------- painting
class _AnnoPainter extends CustomPainter {
  final List<AnnoData> annos;
  final AnnoData? live;
  _AnnoPainter(this.annos, this.live);

  @override
  void paint(Canvas canvas, Size size) {
    for (final a in annos) {
      _draw(canvas, size, a);
    }
    if (live != null) _draw(canvas, size, live!);
  }

  void _draw(Canvas canvas, Size size, AnnoData a) {
    final W = size.width;
    final H = size.height;
    final color = Color(a.color);
    final p = a.pts;
    if (a.type == AnnoType.draw) {
      if (p.length < 4) return;
      final paint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = a.width * W;
      final path = Path()..moveTo(p[0] * W, p[1] * H);
      for (var i = 2; i + 1 < p.length; i += 2) {
        path.lineTo(p[i] * W, p[i + 1] * H);
      }
      canvas.drawPath(path, paint);
    } else if (a.type == AnnoType.highlight) {
      if (p.length < 4) return;
      final r = Rect.fromPoints(Offset(p[0] * W, p[1] * H), Offset(p[2] * W, p[3] * H));
      canvas.drawRect(r, Paint()..color = color.withAlpha(90));
    } else if (a.type == AnnoType.underline || a.type == AnnoType.strike) {
      if (p.length < 4) return;
      final r = Rect.fromPoints(Offset(p[0] * W, p[1] * H), Offset(p[2] * W, p[3] * H));
      final paint = Paint()
        ..color = color
        ..strokeWidth = _max(1.5, 0.003 * W);
      if (a.type == AnnoType.underline) {
        canvas.drawLine(r.bottomLeft, r.bottomRight, paint);
      } else {
        canvas.drawLine(r.centerLeft, r.centerRight, paint);
      }
    } else if (a.type == AnnoType.note) {
      if (p.length < 2) return;
      final fs = W * 0.022;
      final boxW = W * 0.36;
      final tp = TextPainter(
        text: TextSpan(text: a.text, style: TextStyle(color: Colors.black, fontSize: fs)),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: boxW - 8);
      final boxH = tp.height + 8;
      final x = (p[0] * W).clamp(0.0, W - boxW).toDouble();
      final y = (p[1] * H).clamp(0.0, H - boxH).toDouble();
      final rect = Rect.fromLTWH(x, y, boxW, boxH);
      canvas.drawRect(rect, Paint()..color = const Color(0xFFFFF3A0));
      canvas.drawRect(
          rect,
          Paint()
            ..color = const Color(0xFFC8A000)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.8);
      tp.paint(canvas, Offset(x + 4, y + 4));
    } else if (a.type == AnnoType.text) {
      if (p.length < 2 || a.text.isEmpty) return;
      final tp = TextPainter(
        text: TextSpan(text: a.text, style: TextStyle(color: color, fontSize: a.width * W)),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: _max(20, W - p[0] * W - 4));
      tp.paint(canvas, Offset(p[0] * W, p[1] * H));
    } else if (a.type == AnnoType.stamp) {
      if (p.length < 2 || a.text.isEmpty) return;
      final fs = W * 0.05;
      final tp = TextPainter(
        text: TextSpan(
            text: a.text,
            style: TextStyle(color: color, fontSize: fs, fontWeight: FontWeight.bold)),
        textDirection: TextDirection.ltr,
      )..layout();
      final pad = fs * 0.4;
      final bx = _max(0, (p[0] * W).clamp(0.0, W).toDouble() > W - tp.width - 2 * pad
          ? W - tp.width - 2 * pad
          : p[0] * W);
      final by = _max(0, (p[1] * H) > H - tp.height - 2 * pad ? H - tp.height - 2 * pad : p[1] * H);
      canvas.drawRect(
        Rect.fromLTWH(bx, by, tp.width + 2 * pad, tp.height + 2 * pad),
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = fs * 0.12,
      );
      tp.paint(canvas, Offset(bx + pad, by + pad));
    }
  }

  double _max(double a, double b) => a > b ? a : b;

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

// ------------------------------------------------------------ signature pad
class _SignatureDialog extends StatefulWidget {
  const _SignatureDialog();

  @override
  State<_SignatureDialog> createState() => _SignatureDialogState();
}

class _SignatureDialogState extends State<_SignatureDialog> {
  final List<List<Offset>> _strokes = [];
  bool _busy = false;

  Future<void> _done() async {
    final pts = _strokes.expand((s) => s).toList();
    if (pts.isEmpty || _busy) return;
    _busy = true;
    var minX = pts.first.dx, maxX = pts.first.dx, minY = pts.first.dy, maxY = pts.first.dy;
    for (final p in pts) {
      if (p.dx < minX) minX = p.dx;
      if (p.dx > maxX) maxX = p.dx;
      if (p.dy < minY) minY = p.dy;
      if (p.dy > maxY) maxY = p.dy;
    }
    const pad = 8.0;
    const scale = 3.0;
    final bw = (maxX - minX) + pad * 2;
    final bh = (maxY - minY) + pad * 2;
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    canvas.scale(scale);
    canvas.translate(pad - minX, pad - minY);
    final paint = Paint()
      ..color = const Color(0xFF111111)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    for (final s in _strokes) {
      if (s.length == 1) {
        canvas.drawCircle(s.first, 1.3, Paint()..color = const Color(0xFF111111));
        continue;
      }
      final path = Path()..moveTo(s.first.dx, s.first.dy);
      for (final p in s.skip(1)) {
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(path, paint);
    }
    final image = await rec.endRecording().toImage((bw * scale).ceil(), (bh * scale).ceil());
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null || !mounted) return;
    Navigator.of(context).pop(_Sig(data.buffer.asUint8List(), bh / bw));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Draw your signature'),
      content: Container(
        width: double.maxFinite,
        height: 200,
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: Colors.black26),
          borderRadius: BorderRadius.circular(8),
        ),
        child: ClipRect(
          child: GestureDetector(
            onPanStart: (d) => setState(() => _strokes.add([d.localPosition])),
            onPanUpdate: (d) => setState(() => _strokes.last.add(d.localPosition)),
            child: CustomPaint(
              painter: _PadPainter(_strokes),
              size: Size.infinite,
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => setState(_strokes.clear), child: const Text('Clear')),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: _done, child: const Text('Add')),
      ],
    );
  }
}

class _PadPainter extends CustomPainter {
  final List<List<Offset>> strokes;
  _PadPainter(this.strokes);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF111111)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    for (final s in strokes) {
      if (s.length == 1) {
        canvas.drawCircle(s.first, 1.3, Paint()..color = const Color(0xFF111111));
        continue;
      }
      final path = Path()..moveTo(s.first.dx, s.first.dy);
      for (final p in s.skip(1)) {
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
