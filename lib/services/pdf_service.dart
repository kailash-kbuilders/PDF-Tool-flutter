import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect, Size;

import 'package:image/image.dart' as img;
import 'package:printing/printing.dart' show Printing;
import 'package:syncfusion_flutter_pdf/pdf.dart';

import '../errors.dart';
import '../models.dart';

/// All heavy work runs in a background isolate. Public methods are static
/// and only capture plain data, so nothing unsendable is copied.
class PdfService {
  // ---------------------------------------------------------------- open
  static PdfDocument _open(Uint8List bytes) {
    try {
      return PdfDocument(inputBytes: bytes);
    } catch (e) {
      final s = e.toString().toLowerCase();
      if (s.contains('password') || s.contains('encrypt')) {
        throw const AppError(
            'This PDF is password protected. Remove the password first.');
      }
      throw const AppError('Unable to open this PDF.');
    }
  }

  static Uint8List _out(List<int> data) => Uint8List.fromList(data);

  // ---------------------------------------------------------- page info
  static Future<int> pageCount(Uint8List bytes) =>
      Isolate.run(() => _pageCount(bytes));

  static int _pageCount(Uint8List bytes) {
    final d = _open(bytes);
    try {
      return d.pages.count;
    } finally {
      d.dispose();
    }
  }

  /// Flat list: w0,h0,w1,h1,...
  static Future<List<double>> pageSizes(Uint8List bytes) =>
      Isolate.run(() => _pageSizes(bytes));

  static List<double> _pageSizes(Uint8List bytes) {
    final d = _open(bytes);
    try {
      final out = <double>[];
      for (var i = 0; i < d.pages.count; i++) {
        final s = d.pages[i].size;
        out.add(s.width);
        out.add(s.height);
      }
      return out;
    } finally {
      d.dispose();
    }
  }

  static List<int> parsePageSpec(String spec, int max) {
    final msg = 'Enter valid page numbers between 1 and $max, like 1-5 or 1,3,7.';
    final out = <int>[];
    for (final raw in spec.split(',')) {
      final part = raw.trim();
      if (part.isEmpty) continue;
      final m = RegExp(r'^(\d+)\s*-\s*(\d+)$').firstMatch(part);
      if (m != null) {
        final a = int.parse(m.group(1)!);
        final b = int.parse(m.group(2)!);
        if (a < 1 || b < a || b > max) throw AppError(msg);
        for (var i = a; i <= b; i++) {
          out.add(i);
        }
      } else if (RegExp(r'^\d+$').hasMatch(part)) {
        final n = int.parse(part);
        if (n < 1 || n > max) throw AppError(msg);
        out.add(n);
      } else {
        throw AppError(msg);
      }
    }
    if (out.isEmpty) throw AppError(msg);
    return out;
  }

  // ------------------------------------------- merge / split / organise
  static Future<Uint8List> assemble(
          List<Uint8List> sources, List<PageRef> refs) =>
      Isolate.run(() => _assemble(sources, refs));

  static Future<Uint8List> _assemble(
      List<Uint8List> sources, List<PageRef> refs) async {
    final docs = <PdfDocument>[];
    final out = PdfDocument();
    try {
      for (final s in sources) {
        docs.add(_open(s));
      }
      for (final r in refs) {
        final page = docs[r.doc].pages[r.page];
        final size = page.size;
        final section = out.sections!.add();
        section.pageSettings.margins.all = 0;
        section.pageSettings.size = size;
        final np = section.pages.add();
        np.graphics.drawPdfTemplate(page.createTemplate(), Offset.zero, size);
        final q = (page.rotation.index + r.turns) % 4;
        if (q != 0) np.rotation = PdfPageRotateAngle.values[q];
      }
      out.compressionLevel = PdfCompressionLevel.best;
      return _out(await out.save());
    } finally {
      for (final d in docs) {
        d.dispose();
      }
      out.dispose();
    }
  }

  static Future<Uint8List> merge(List<Uint8List> sources) =>
      Isolate.run(() => _merge(sources));

  static Future<Uint8List> _merge(List<Uint8List> sources) async {
    final refs = <PageRef>[];
    for (var i = 0; i < sources.length; i++) {
      final n = _pageCount(sources[i]);
      for (var p = 0; p < n; p++) {
        refs.add(PageRef(i, p));
      }
    }
    return _assemble(sources, refs);
  }

  /// [pages] are 1-based.
  static Future<Uint8List> extractPages(Uint8List bytes, List<int> pages) =>
      assemble([bytes], pages.map((p) => PageRef(0, p - 1)).toList());

  // -------------------------------------------------------------- security
  static Future<Uint8List> protect(Uint8List bytes, String password) =>
      Isolate.run(() => _protect(bytes, password));

  static Future<Uint8List> _protect(Uint8List bytes, String password) async {
    final d = _open(bytes);
    try {
      d.security.userPassword = password;
      d.security.ownerPassword = password;
      return _out(await d.save());
    } finally {
      d.dispose();
    }
  }

  static Future<Uint8List> unlock(Uint8List bytes, String password) =>
      Isolate.run(() => _unlock(bytes, password));

  static Future<Uint8List> _unlock(Uint8List bytes, String password) async {
    PdfDocument d;
    try {
      d = PdfDocument(inputBytes: bytes, password: password);
    } catch (_) {
      throw const AppError('Incorrect password.');
    }
    try {
      d.security.userPassword = '';
      d.security.ownerPassword = '';
      return _out(await d.save());
    } finally {
      d.dispose();
    }
  }

  // ---------------------------------------------------------- compression
  static Future<Uint8List> _light(Uint8List bytes) =>
      Isolate.run(() => _lightWorker(bytes));

  static Future<Uint8List> _lightWorker(Uint8List bytes) async {
    final d = _open(bytes);
    try {
      d.fileStructure.incrementalUpdate = false;
      d.compressionLevel = PdfCompressionLevel.best;
      return _out(await d.save());
    } finally {
      d.dispose();
    }
  }

  static Future<Uint8List> compress(
      Uint8List bytes, CompressionLevel level) async {
    final light = await _light(bytes);
    final lightBest = light.length < bytes.length ? light : bytes;
    if (level == CompressionLevel.low) return lightBest;

    final dpi = level == CompressionLevel.medium ? 110.0 : 80.0;
    final quality = level == CompressionLevel.medium ? 70 : 50;
    final sizes = await pageSizes(bytes);
    final jpgs = <Uint8List>[];
    await for (final r in Printing.raster(bytes, dpi: dpi)) {
      final w = r.width;
      final h = r.height;
      final px = Uint8List.fromList(r.pixels);
      jpgs.add(await _encodeJpegBg(px, w, h, quality));
    }
    final rebuilt = await _buildFromJpegsBg(jpgs, sizes);
    return rebuilt.length < lightBest.length ? rebuilt : lightBest;
  }

  static Future<Uint8List> _encodeJpegBg(Uint8List rgba, int w, int h, int q,
          {bool gray = false}) =>
      Isolate.run(() => _encodeJpeg(rgba, w, h, q, gray));

  static Uint8List _encodeJpeg(Uint8List rgba, int w, int h, int q, bool gray) {
    if (gray) {
      for (var i = 0; i + 3 < rgba.length; i += 4) {
        final l = (rgba[i] * 299 + rgba[i + 1] * 587 + rgba[i + 2] * 114) ~/ 1000;
        rgba[i] = l;
        rgba[i + 1] = l;
        rgba[i + 2] = l;
      }
    }
    final image = img.Image.fromBytes(
      width: w,
      height: h,
      bytes: rgba.buffer,
      numChannels: 4,
    );
    return Uint8List.fromList(img.encodeJpg(image, quality: q));
  }

  static Future<Uint8List> _buildFromJpegsBg(
          List<Uint8List> jpgs, List<double> sizes) =>
      Isolate.run(() => _buildFromJpegs(jpgs, sizes));

  static Future<Uint8List> _buildFromJpegs(
      List<Uint8List> jpgs, List<double> sizes) async {
    final doc = PdfDocument();
    try {
      for (var i = 0; i < jpgs.length; i++) {
        final w = sizes[i * 2];
        final h = sizes[i * 2 + 1];
        final section = doc.sections!.add();
        section.pageSettings.margins.all = 0;
        section.pageSettings.size = Size(w, h);
        final page = section.pages.add();
        page.graphics.drawImage(PdfBitmap(jpgs[i]), Rect.fromLTWH(0, 0, w, h));
      }
      doc.compressionLevel = PdfCompressionLevel.best;
      return _out(await doc.save());
    } finally {
      doc.dispose();
    }
  }

  // ------------------------------------------------------------ watermark
  static Future<Uint8List> watermark(
    Uint8List bytes, {
    String? text,
    Uint8List? image,
    required double size,
    required double opacity,
    required double angle,
    required double posY,
    int color = 0xFF969696,
  }) =>
      Isolate.run(
          () => _watermark(bytes, text, image, size, opacity, angle, posY, color));

  static Future<Uint8List> _watermark(Uint8List bytes, String? text,
      Uint8List? image, double size, double opacity, double angle,
      double posY, int color) async {
    final d = _open(bytes);
    try {
      final bmp = image != null ? PdfBitmap(image) : null;
      for (var i = 0; i < d.pages.count; i++) {
        final page = d.pages[i];
        final sz = page.size;
        final g = page.graphics;
        g.save();
        g.setTransparency(opacity);
        g.translateTransform(sz.width / 2, sz.height * posY);
        g.rotateTransform(-angle);
        if (bmp != null) {
          final w = sz.width * (0.1 + size * 0.8);
          final h = w * bmp.height / bmp.width;
          g.drawImage(bmp, Rect.fromLTWH(-w / 2, -h / 2, w, h));
        } else if (text != null && text.isNotEmpty) {
          final font = PdfStandardFont(
            PdfFontFamily.helvetica,
            sz.width * (0.05 + size * 0.2),
            style: PdfFontStyle.bold,
          );
          final m = font.measureString(text);
          g.drawString(
            text,
            font,
            brush: PdfSolidBrush(_pc(color)),
            bounds: Rect.fromLTWH(-m.width / 2, -m.height / 2, m.width, m.height),
          );
        }
        g.restore();
      }
      return _out(await d.save());
    } finally {
      d.dispose();
    }
  }

  // ---------------------------------------------------------- annotations
  static Future<Uint8List> burnAnnotations(
          Uint8List bytes, List<AnnoData> annos) =>
      Isolate.run(() => _burn(bytes, annos));

  static PdfColor _pc(int argb) =>
      PdfColor((argb >> 16) & 255, (argb >> 8) & 255, argb & 255);

  static Future<Uint8List> _burn(Uint8List bytes, List<AnnoData> annos) async {
    final d = _open(bytes);
    try {
      for (final a in annos) {
        if (a.page >= d.pages.count) continue;
        final page = d.pages[a.page];
        final sz = page.size;
        final W = sz.width;
        final H = sz.height;
        final g = page.graphics;
        final p = a.pts;
        if (a.type == AnnoType.draw) {
          if (p.length < 4) continue;
          final pen = PdfPen(_pc(a.color), width: math.max(0.5, a.width * W));
          for (var i = 0; i + 3 < p.length; i += 2) {
            g.drawLine(pen, Offset(p[i] * W, p[i + 1] * H),
                Offset(p[i + 2] * W, p[i + 3] * H));
          }
        } else if (a.type == AnnoType.highlight) {
          if (p.length < 4) continue;
          final r = Rect.fromPoints(
              Offset(p[0] * W, p[1] * H), Offset(p[2] * W, p[3] * H));
          g.save();
          g.setTransparency(0.35);
          g.drawRectangle(brush: PdfSolidBrush(_pc(a.color)), bounds: r);
          g.restore();
        } else if (a.type == AnnoType.underline) {
          if (p.length < 4) continue;
          final r = Rect.fromPoints(
              Offset(p[0] * W, p[1] * H), Offset(p[2] * W, p[3] * H));
          g.drawLine(PdfPen(_pc(a.color), width: math.max(0.8, 0.003 * W)),
              r.bottomLeft, r.bottomRight);
        } else if (a.type == AnnoType.note) {
          if (p.length < 2) continue;
          final fs = W * 0.022;
          final boxW = W * 0.36;
          final lines = _noteLines(a.text, boxW - 8, fs);
          final boxH = lines * fs * 1.25 + 8;
          final x = math.min(p[0] * W, W - boxW);
          final y = math.min(p[1] * H, H - boxH);
          g.drawRectangle(
            pen: PdfPen(PdfColor(200, 160, 0), width: 0.8),
            brush: PdfSolidBrush(PdfColor(255, 243, 160)),
            bounds: Rect.fromLTWH(x, y, boxW, boxH),
          );
          try {
            g.drawString(
              a.text,
              PdfStandardFont(PdfFontFamily.helvetica, fs),
              brush: PdfBrushes.black,
              bounds: Rect.fromLTWH(x + 4, y + 4, boxW - 8, boxH - 8),
            );
          } catch (_) {}
        } else if (a.type == AnnoType.signature) {
          if (p.length < 4 || a.image == null) continue;
          g.drawImage(PdfBitmap(a.image!),
              Rect.fromLTWH(p[0] * W, p[1] * H, p[2] * W, p[3] * H));
        } else if (a.type == AnnoType.text) {
          if (p.length < 2 || a.text.isEmpty) continue;
          try {
            g.drawString(
              a.text,
              PdfStandardFont(PdfFontFamily.helvetica, math.max(6.0, a.width * W)),
              brush: PdfSolidBrush(_pc(a.color)),
              bounds: Rect.fromLTWH(p[0] * W, p[1] * H,
                  math.max(20.0, W - p[0] * W - 4), math.max(20.0, H - p[1] * H)),
            );
          } catch (_) {}
        } else if (a.type == AnnoType.strike) {
          if (p.length < 4) continue;
          final r = Rect.fromPoints(
              Offset(p[0] * W, p[1] * H), Offset(p[2] * W, p[3] * H));
          g.drawLine(PdfPen(_pc(a.color), width: math.max(0.8, 0.003 * W)),
              r.centerLeft, r.centerRight);
        } else if (a.type == AnnoType.stamp) {
          if (p.length < 2 || a.text.isEmpty) continue;
          try {
            final fs = W * 0.05;
            final font = PdfStandardFont(PdfFontFamily.helvetica, fs,
                style: PdfFontStyle.bold);
            final m = font.measureString(a.text);
            final pad = fs * 0.4;
            final bx = math.max(0.0, math.min(p[0] * W, W - m.width - 2 * pad));
            final by = math.max(0.0, math.min(p[1] * H, H - m.height - 2 * pad));
            g.drawRectangle(
              pen: PdfPen(_pc(a.color), width: fs * 0.12),
              bounds: Rect.fromLTWH(bx, by, m.width + 2 * pad, m.height + 2 * pad),
            );
            g.drawString(a.text, font,
                brush: PdfSolidBrush(_pc(a.color)),
                bounds: Rect.fromLTWH(bx + pad, by + pad, m.width + 2, m.height + 2));
          } catch (_) {}
        }
      }
      return _out(await d.save());
    } finally {
      d.dispose();
    }
  }

  static int _noteLines(String text, double width, double fs) {
    final perLine = math.max(6, (width / (fs * 0.52)).floor());
    var n = 0;
    for (final l in text.split('\n')) {
      n += math.max(1, (l.length / perLine).ceil());
    }
    return n;
  }

  // ----------------------------------------------------- image / text → PDF
  static Future<Uint8List> imagesToPdf(
    List<Uint8List> images, {
    double margin = 20,
    List<OcrPage?>? ocr,
    bool normalize = true,
    bool idCard = false,
  }) =>
      Isolate.run(() => _imagesToPdf(images, margin, ocr, normalize, idCard));

  static Future<Uint8List> _imagesToPdf(List<Uint8List> images, double margin,
      List<OcrPage?>? ocr, bool normalize, bool idCard) async {
    final doc = PdfDocument();
    try {
      if (idCard) {
        // front and back of an ID card on one A4 sheet
        for (var i = 0; i < images.length; i += 2) {
          final section = doc.sections!.add();
          section.pageSettings.margins.all = 30;
          section.pageSettings.size = const Size(595, 842);
          final page = section.pages.add();
          final cs = page.getClientSize();
          final cellH = (cs.height - 30) / 2;
          for (var k = 0; k < 2 && i + k < images.length; k++) {
            final bytes =
                normalize ? _normalizeBytes(images[i + k]) : images[i + k];
            final bmp = PdfBitmap(bytes);
            final iw = bmp.width.toDouble();
            final ih = bmp.height.toDouble();
            final sc = math.min(cs.width * 0.8 / iw, cellH * 0.8 / ih);
            final w = iw * sc;
            final h = ih * sc;
            page.graphics.drawImage(
              bmp,
              Rect.fromLTWH((cs.width - w) / 2, k * (cellH + 30) + (cellH - h) / 2, w, h),
            );
          }
        }
      } else {
        for (var i = 0; i < images.length; i++) {
          final bytes = normalize ? _normalizeBytes(images[i]) : images[i];
          final bmp = PdfBitmap(bytes);
          final iw = bmp.width.toDouble();
          final ih = bmp.height.toDouble();
          final section = doc.sections!.add();
          section.pageSettings.margins.all = margin;
          section.pageSettings.size = const Size(595, 842);
          if (iw > ih) {
            section.pageSettings.orientation = PdfPageOrientation.landscape;
          }
          final page = section.pages.add();
          final client = page.getClientSize();
          final scale = math.min(client.width / iw, client.height / ih);
          final w = iw * scale;
          final h = ih * scale;
          final rect = Rect.fromLTWH(
              (client.width - w) / 2, (client.height - h) / 2, w, h);
          page.graphics.drawImage(bmp, rect);

          final o = (ocr != null && i < ocr.length) ? ocr[i] : null;
          if (o != null && o.w > 0 && o.h > 0) {
            final sx = rect.width / o.w;
            final sy = rect.height / o.h;
            final g = page.graphics;
            g.save();
            g.setTransparency(0);
            for (final l in o.lines) {
              try {
                final fs = math.max(4.0, (l.b - l.t) * sy * 0.8);
                g.drawString(
                  l.text,
                  PdfStandardFont(PdfFontFamily.helvetica, fs),
                  brush: PdfBrushes.black,
                  bounds: Rect.fromLTWH(
                      rect.left + l.l * sx,
                      rect.top + l.t * sy,
                      math.max(10.0, (l.r - l.l) * sx),
                      (l.b - l.t) * sy),
                );
              } catch (_) {}
            }
            g.restore();
          }
        }
      }
      doc.compressionLevel = PdfCompressionLevel.best;
      return _out(await doc.save());
    } finally {
      doc.dispose();
    }
  }

  static Uint8List _normalizeBytes(Uint8List bytes, {int maxSide = 2200}) {
    final isJpeg = bytes.length > 2 && bytes[0] == 0xFF && bytes[1] == 0xD8;
    if (!isJpeg) return bytes;
    final decoded = img.decodeJpg(bytes);
    if (decoded == null) return bytes;
    var im = img.bakeOrientation(decoded);
    final longest = math.max(im.width, im.height);
    if (longest > maxSide) {
      im = im.width >= im.height
          ? img.copyResize(im, width: maxSide)
          : img.copyResize(im, height: maxSide);
    }
    return Uint8List.fromList(img.encodeJpg(im, quality: 88));
  }

  static Future<NormImage> normalizeImage(Uint8List bytes) =>
      Isolate.run(() => _normalizeFull(bytes));

  static NormImage _normalizeFull(Uint8List bytes) {
    final dec = img.decodeImage(bytes);
    if (dec == null) {
      throw const AppError('This file format is not supported.');
    }
    var im = img.bakeOrientation(dec);
    final longest = math.max(im.width, im.height);
    if (longest > 2200) {
      im = im.width >= im.height
          ? img.copyResize(im, width: 2200)
          : img.copyResize(im, height: 2200);
    }
    return NormImage(
        Uint8List.fromList(img.encodeJpg(im, quality: 88)), im.width, im.height);
  }

  static Future<Uint8List> textToPdf(String text, {double fontSize = 12}) =>
      Isolate.run(() => _textToPdf(text, fontSize));

  static Future<Uint8List> _textToPdf(String text, double fontSize) async {
    final doc = PdfDocument();
    try {
      final section = doc.sections!.add();
      section.pageSettings.size = PdfPageSize.a4;
      section.pageSettings.margins.all = 40;
      var page = section.pages.add();
      final width = page.getClientSize().width;
      final height = page.getClientSize().height;
      final layout = PdfLayoutFormat(layoutType: PdfLayoutType.paginate);
      var y = 0.0;
      for (final raw in text.split('\n')) {
        final st = MdLine.parse(raw);
        if (st.text.isEmpty) {
          y += fontSize * 0.9;
          continue;
        }
        if (y > height - fontSize * 3) {
          page = section.pages.add();
          y = 0;
        }
        final fs = st.size(fontSize);
        final font = PdfStandardFont(
          PdfFontFamily.helvetica,
          fs,
          style: st.isBold
              ? PdfFontStyle.bold
              : (st.italic ? PdfFontStyle.italic : PdfFontStyle.regular),
        );
        final indent = st.bullet ? 12.0 : 0.0;
        final el = PdfTextElement(
            text: st.display, font: font, brush: PdfBrushes.black);
        final res = el.draw(
          page: page,
          bounds: Rect.fromLTWH(indent, y, width - indent, 0),
          format: layout,
        );
        if (res != null) {
          page = res.page;
          y = res.bounds.bottom + (st.level > 0 ? fs * 0.5 : fs * 0.3);
        }
      }
      doc.compressionLevel = PdfCompressionLevel.best;
      return _out(await doc.save());
    } finally {
      doc.dispose();
    }
  }

  // ---------------------------------------------------------- page numbers
  /// style: 0 = "1", 1 = "1 / N", 2 = "Page 1 of N". align: 0 left, 1 center, 2 right.
  static Future<Uint8List> addPageNumbers(Uint8List bytes,
          {required int style,
          required int align,
          required bool top,
          int start = 1}) =>
      Isolate.run(() => _pageNumbers(bytes, style, align, top, start));

  static Future<Uint8List> _pageNumbers(
      Uint8List bytes, int style, int align, bool top, int start) async {
    final d = _open(bytes);
    try {
      final total = d.pages.count;
      final font = PdfStandardFont(PdfFontFamily.helvetica, 10);
      for (var i = 0; i < total; i++) {
        final page = d.pages[i];
        final sz = page.size;
        final n = i + start;
        final label = style == 0
            ? '$n'
            : style == 1
                ? '$n / ${total + start - 1}'
                : 'Page $n of ${total + start - 1}';
        final m = font.measureString(label);
        final x = align == 0
            ? 30.0
            : align == 1
                ? (sz.width - m.width) / 2
                : sz.width - 30 - m.width;
        final y = top ? 16.0 : sz.height - 28;
        page.graphics.drawString(label, font,
            brush: PdfBrushes.black,
            bounds: Rect.fromLTWH(x, y, m.width + 2, m.height + 2));
      }
      return _out(await d.save());
    } finally {
      d.dispose();
    }
  }

  // ------------------------------------------------------------- n-up
  static Future<Uint8List> nUp(Uint8List bytes, int perSheet) =>
      Isolate.run(() => _nUp(bytes, perSheet));

  static Future<Uint8List> _nUp(Uint8List bytes, int perSheet) async {
    final src = _open(bytes);
    final out = PdfDocument();
    try {
      final cols = perSheet == 6 ? 3 : 2;
      final rows = perSheet == 2 ? 1 : 2;
      final landscape = perSheet != 4;
      const gap = 8.0;
      final n = src.pages.count;
      for (var start = 0; start < n; start += perSheet) {
        final section = out.sections!.add();
        section.pageSettings.margins.all = 14;
        section.pageSettings.size = const Size(595, 842);
        if (landscape) {
          section.pageSettings.orientation = PdfPageOrientation.landscape;
        }
        final np = section.pages.add();
        final cs = np.getClientSize();
        final cw = (cs.width - gap * (cols - 1)) / cols;
        final ch = (cs.height - gap * (rows - 1)) / rows;
        for (var k = 0; k < perSheet && start + k < n; k++) {
          final page = src.pages[start + k];
          final ps = page.size;
          final sc = math.min(cw / ps.width, ch / ps.height);
          final w = ps.width * sc;
          final h = ps.height * sc;
          final cx = (k % cols) * (cw + gap) + (cw - w) / 2;
          final cy = (k ~/ cols) * (ch + gap) + (ch - h) / 2;
          np.graphics.drawPdfTemplate(
              page.createTemplate(), Offset(cx, cy), Size(w, h));
        }
      }
      out.compressionLevel = PdfCompressionLevel.best;
      return _out(await out.save());
    } finally {
      src.dispose();
      out.dispose();
    }
  }

  // -------------------------------------------------------------- crop
  static Future<Uint8List> cropPages(
          Uint8List bytes, double l, double t, double r, double b) =>
      Isolate.run(() => _crop(bytes, l, t, r, b));

  static Future<Uint8List> _crop(
      Uint8List bytes, double l, double t, double r, double b) async {
    final src = _open(bytes);
    final out = PdfDocument();
    try {
      for (var i = 0; i < src.pages.count; i++) {
        final page = src.pages[i];
        final ps = page.size;
        final nw = ps.width * (1 - l - r);
        final nh = ps.height * (1 - t - b);
        final section = out.sections!.add();
        section.pageSettings.margins.all = 0;
        section.pageSettings.size = Size(nw, nh);
        final np = section.pages.add();
        np.graphics.drawPdfTemplate(
            page.createTemplate(), Offset(-ps.width * l, -ps.height * t), ps);
      }
      out.compressionLevel = PdfCompressionLevel.best;
      return _out(await out.save());
    } finally {
      src.dispose();
      out.dispose();
    }
  }

  // ------------------------------------------------------- split / gray
  static Future<List<Uint8List>> splitEvery(Uint8List bytes, int n) =>
      Isolate.run(() => _splitEvery(bytes, n));

  static Future<List<Uint8List>> _splitEvery(Uint8List bytes, int n) async {
    final total = _pageCount(bytes);
    final out = <Uint8List>[];
    for (var s = 0; s < total; s += n) {
      final refs = <PageRef>[];
      for (var p = s; p < s + n && p < total; p++) {
        refs.add(PageRef(0, p));
      }
      out.add(await _assemble([bytes], refs));
    }
    return out;
  }

  static Future<Uint8List> convertGrayscale(Uint8List bytes) async {
    final sizes = await pageSizes(bytes);
    final jpgs = <Uint8List>[];
    await for (final r in Printing.raster(bytes, dpi: 130)) {
      jpgs.add(await _encodeJpegBg(
          Uint8List.fromList(r.pixels), r.width, r.height, 75,
          gray: true));
    }
    return _buildFromJpegsBg(jpgs, sizes);
  }

  // ------------------------------------------------------------- search
  /// Each hit: [pageIndex, snippet]
  static Future<List<List<Object>>> searchText(Uint8List bytes, String query) =>
      Isolate.run(() => _search(bytes, query));

  static List<List<Object>> _search(Uint8List bytes, String query) {
    final d = _open(bytes);
    try {
      final ex = PdfTextExtractor(d);
      final q = query.toLowerCase();
      final out = <List<Object>>[];
      for (var i = 0; i < d.pages.count && out.length < 200; i++) {
        final text = ex.extractText(startPageIndex: i, endPageIndex: i);
        final low = text.toLowerCase();
        var pos = low.indexOf(q);
        var hits = 0;
        while (pos != -1 && hits < 5 && out.length < 200) {
          final a = math.max(0, pos - 30);
          final b = math.min(text.length, pos + q.length + 40);
          out.add(<Object>[
            i,
            text.substring(a, b).replaceAll(RegExp(r'\s+'), ' ').trim(),
          ]);
          hits++;
          pos = low.indexOf(q, pos + q.length);
        }
      }
      return out;
    } finally {
      d.dispose();
    }
  }

  // --------------------------------------------------------------- forms
  /// Each field: [index, name, type(0 text, 1 checkbox, 2 other), value]
  static Future<List<List<Object>>> readForm(Uint8List bytes) =>
      Isolate.run(() => _readForm(bytes));

  static List<List<Object>> _readForm(Uint8List bytes) {
    final d = _open(bytes);
    try {
      final out = <List<Object>>[];
      final fields = d.form.fields;
      for (var i = 0; i < fields.count; i++) {
        final dynamic f = fields[i];
        var name = 'Field ${i + 1}';
        try {
          final n = f.name;
          if (n is String && n.isNotEmpty) name = n;
        } catch (_) {}
        final tn = f.runtimeType.toString();
        if (tn.contains('TextBox')) {
          var v = '';
          try {
            final t = f.text;
            if (t is String) v = t;
          } catch (_) {}
          out.add(<Object>[i, name, 0, v]);
        } else if (tn.contains('CheckBox')) {
          var v = false;
          try {
            final c = f.checked;
            if (c is bool) v = c;
          } catch (_) {}
          out.add(<Object>[i, name, 1, v]);
        } else {
          out.add(<Object>[i, name, 2, '']);
        }
      }
      return out;
    } finally {
      d.dispose();
    }
  }

  static Future<Uint8List> fillForm(Uint8List bytes, Map<int, Object> values) =>
      Isolate.run(() => _fillForm(bytes, values));

  static Future<Uint8List> _fillForm(
      Uint8List bytes, Map<int, Object> values) async {
    final d = _open(bytes);
    try {
      final fields = d.form.fields;
      for (final e in values.entries) {
        if (e.key >= fields.count) continue;
        final dynamic f = fields[e.key];
        final v = e.value;
        final tn = f.runtimeType.toString();
        try {
          if (tn.contains('TextBox') && v is String) {
            f.text = v;
          } else if (tn.contains('CheckBox') && v is bool) {
            f.checked = v;
          }
        } catch (_) {}
      }
      return _out(await d.save());
    } finally {
      d.dispose();
    }
  }

  // ---------------------------------------------------------- extraction
  static Future<String> extractText(Uint8List bytes) =>
      Isolate.run(() => _extractText(bytes));

  static String _extractText(Uint8List bytes) {
    final d = _open(bytes);
    try {
      return PdfTextExtractor(d).extractText();
    } finally {
      d.dispose();
    }
  }

  // ----------------------------------------------------------- rendering
  static Future<void> _renderChain = Future<void>.value();

  /// Renders one page to PNG. Calls are queued so memory stays low.
  static Future<Uint8List?> renderPage(Uint8List bytes, int index,
      {double dpi = 100}) {
    final c = Completer<Uint8List?>();
    _renderChain = _renderChain.then((_) async {
      try {
        c.complete(await _renderNow(bytes, index, dpi));
      } catch (_) {
        c.complete(null);
      }
    });
    return c.future;
  }

  static Future<Uint8List?> _renderNow(
      Uint8List bytes, int index, double dpi) async {
    await for (final r in Printing.raster(bytes, pages: [index], dpi: dpi)) {
      return await r.toPng();
    }
    return null;
  }
}
