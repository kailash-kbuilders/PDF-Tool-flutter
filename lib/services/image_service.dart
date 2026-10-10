import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;

import '../models.dart';

/// Image editing for scans: rotate, crop, document filters, brightness/contrast.
/// Pixel work is plain typed-data maths that runs in a background isolate.
class ImageService {
  // ------------------------------------------------------------- decoding
  /// Decodes any image to raw RGBA. If [maxSide] is set, the image is
  /// down-scaled (keeping aspect ratio) while decoding.
  static Future<Rgba> decode(Uint8List bytes, {int? maxSide}) async {
    ui.Codec codec = await ui.instantiateImageCodec(bytes);
    ui.FrameInfo frame = await codec.getNextFrame();
    var image = frame.image;
    if (maxSide != null && (image.width > maxSide || image.height > maxSide)) {
      final landscape = image.width >= image.height;
      image.dispose();
      codec.dispose();
      codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: landscape ? maxSide : null,
        targetHeight: landscape ? null : maxSide,
      );
      frame = await codec.getNextFrame();
      image = frame.image;
    }
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final out = Rgba(
      Uint8List.fromList(data!.buffer.asUint8List()),
      image.width,
      image.height,
    );
    image.dispose();
    codec.dispose();
    return out;
  }

  static Future<ui.Image> toUiImage(Rgba r) {
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(r.data, r.w, r.h, ui.PixelFormat.rgba8888, c.complete);
    return c.future;
  }

  // ----------------------------------------------------------- processing
  static Future<Rgba> processBg(Rgba src, EditParams p) =>
      Isolate.run(() => process(src.data, src.w, src.h, p));

  static Future<NormImage> applyFull(NormImage orig, EditParams p) async {
    if (p.isDefault) return orig;
    final base = await decode(orig.bytes);
    final res = await processBg(base, p);
    final jpg = await _encodeBg(res);
    return NormImage(jpg, res.w, res.h);
  }

  static Future<Uint8List> _encodeBg(Rgba r) => Isolate.run(() {
        final im = img.Image.fromBytes(
          width: r.w,
          height: r.h,
          bytes: Uint8List.fromList(r.data).buffer,
          numChannels: 4,
        );
        return Uint8List.fromList(img.encodeJpg(im, quality: 88));
      });

  static Uint32List _u32(Uint8List b) {
    final c = (b.offsetInBytes % 4 == 0) ? b : Uint8List.fromList(b);
    return c.buffer.asUint32List(c.offsetInBytes, c.lengthInBytes ~/ 4);
  }

  static Rgba process(Uint8List src, int w, int h, EditParams p) {
    var s32 = _u32(src);
    var cw = w;
    var ch = h;

    // 1) rotate
    final q = p.rot % 4;
    if (q != 0) {
      final dw = (q == 2) ? cw : ch;
      final dh = (q == 2) ? ch : cw;
      final d = Uint32List(dw * dh);
      for (var y = 0; y < ch; y++) {
        for (var x = 0; x < cw; x++) {
          final v = s32[y * cw + x];
          int xd, yd;
          if (q == 1) {
            xd = ch - 1 - y;
            yd = x;
          } else if (q == 2) {
            xd = cw - 1 - x;
            yd = ch - 1 - y;
          } else {
            xd = y;
            yd = cw - 1 - x;
          }
          d[yd * dw + xd] = v;
        }
      }
      s32 = d;
      cw = dw;
      ch = dh;
    }

    // 2) crop
    if (p.hasCrop) {
      var x0 = (p.cl * cw).floor();
      var y0 = (p.ct * ch).floor();
      var x1 = cw - (p.cr * cw).floor();
      var y1 = ch - (p.cb * ch).floor();
      if (x1 - x0 < 16) {
        x0 = 0;
        x1 = cw;
      }
      if (y1 - y0 < 16) {
        y0 = 0;
        y1 = ch;
      }
      final nw = x1 - x0;
      final nh = y1 - y0;
      final d = Uint32List(nw * nh);
      for (var y = 0; y < nh; y++) {
        d.setRange(y * nw, y * nw + nw, s32, (y + y0) * cw + x0);
      }
      s32 = d;
      cw = nw;
      ch = nh;
    }

    final px = s32.buffer.asUint8List(s32.offsetInBytes, s32.lengthInBytes);
    final out = Uint8List.fromList(px);

    // 3) filter
    if (p.filter == 1 || p.filter == 2) {
      _documentFilter(out, cw, ch, p.filter == 2);
    } else if (p.filter == 3) {
      for (var i = 0; i < out.length; i += 4) {
        final l = ((out[i] * 299 + out[i + 1] * 587 + out[i + 2] * 114) ~/ 1000);
        out[i] = l;
        out[i + 1] = l;
        out[i + 2] = l;
      }
    }

    // 4) brightness / contrast
    if (p.brightness != 0 || p.contrast != 0) {
      final f = 1 + p.contrast / 100;
      final lut = Uint8List(256);
      for (var v = 0; v < 256; v++) {
        final o = (v - 128) * f + 128 + p.brightness * 1.28;
        lut[v] = o < 0 ? 0 : (o > 255 ? 255 : o.round());
      }
      for (var i = 0; i < out.length; i += 4) {
        out[i] = lut[out[i]];
        out[i + 1] = lut[out[i + 1]];
        out[i + 2] = lut[out[i + 2]];
      }
    }
    return Rgba(out, cw, ch);
  }

  /// Removes shadows / uneven light (paper becomes white, text stays dark).
  static void _documentFilter(Uint8List px, int w, int h, bool bw) {
    final f = math.max(8, (math.max(w, h) / 64).ceil());
    final gw = (w / f).ceil();
    final gh = (h / f).ceil();
    var gr = Float32List(gw * gh);
    var gg = Float32List(gw * gh);
    var gb = Float32List(gw * gh);

    // brightest value per cell and channel = paper colour
    for (var y = 0; y < h; y += 2) {
      final gy = y ~/ f;
      for (var x = 0; x < w; x += 2) {
        final i = (y * w + x) * 4;
        final c = gy * gw + (x ~/ f);
        if (px[i] > gr[c]) gr[c] = px[i].toDouble();
        if (px[i + 1] > gg[c]) gg[c] = px[i + 1].toDouble();
        if (px[i + 2] > gb[c]) gb[c] = px[i + 2].toDouble();
      }
    }
    // smooth the background map
    for (var pass = 0; pass < 2; pass++) {
      gr = _blur(gr, gw, gh);
      gg = _blur(gg, gw, gh);
      gb = _blur(gb, gw, gh);
    }

    // tone curve
    final lut = Uint8List(256);
    for (var v = 0; v < 256; v++) {
      if (bw) {
        var t = (v - 85) / (190 - 85);
        t = t < 0 ? 0 : (t > 1 ? 1 : t);
        lut[v] = (255 * t * t * (3 - 2 * t)).round();
      } else {
        var t = (v - 28) / (232 - 28);
        t = t < 0 ? 0 : (t > 1 ? 1 : t);
        lut[v] = (255 * math.pow(t, 1.3)).round();
      }
    }

    for (var y = 0; y < h; y++) {
      final fy = (y + 0.5) / f - 0.5;
      var y0 = fy.floor();
      final wy = fy - y0;
      var y1 = y0 + 1;
      if (y0 < 0) y0 = 0;
      if (y1 > gh - 1) y1 = gh - 1;
      if (y0 > gh - 1) y0 = gh - 1;
      for (var x = 0; x < w; x++) {
        final fx = (x + 0.5) / f - 0.5;
        var x0 = fx.floor();
        final wx = fx - x0;
        var x1 = x0 + 1;
        if (x0 < 0) x0 = 0;
        if (x1 > gw - 1) x1 = gw - 1;
        if (x0 > gw - 1) x0 = gw - 1;
        final a = y0 * gw + x0, b = y0 * gw + x1, c = y1 * gw + x0, d = y1 * gw + x1;
        final i = (y * w + x) * 4;
        final bgR = _lerp2(gr[a], gr[b], gr[c], gr[d], wx, wy);
        final bgG = _lerp2(gg[a], gg[b], gg[c], gg[d], wx, wy);
        final bgB = _lerp2(gb[a], gb[b], gb[c], gb[d], wx, wy);
        var r = px[i] * 255 / (bgR < 45 ? 45 : bgR);
        var g = px[i + 1] * 255 / (bgG < 45 ? 45 : bgG);
        var bl = px[i + 2] * 255 / (bgB < 45 ? 45 : bgB);
        if (r > 255) r = 255;
        if (g > 255) g = 255;
        if (bl > 255) bl = 255;
        if (bw) {
          final l = (r * 0.299 + g * 0.587 + bl * 0.114).round();
          final o = lut[l > 255 ? 255 : l];
          px[i] = o;
          px[i + 1] = o;
          px[i + 2] = o;
        } else {
          px[i] = lut[r.round()];
          px[i + 1] = lut[g.round()];
          px[i + 2] = lut[bl.round()];
        }
      }
    }
  }

  static double _lerp2(double a, double b, double c, double d, double wx, double wy) {
    final top = a + (b - a) * wx;
    final bot = c + (d - c) * wx;
    return top + (bot - top) * wy;
  }

  static Float32List _blur(Float32List g, int gw, int gh) {
    final o = Float32List(gw * gh);
    for (var y = 0; y < gh; y++) {
      for (var x = 0; x < gw; x++) {
        var sum = 0.0;
        var n = 0;
        for (var dy = -1; dy <= 1; dy++) {
          final yy = y + dy;
          if (yy < 0 || yy >= gh) continue;
          for (var dx = -1; dx <= 1; dx++) {
            final xx = x + dx;
            if (xx < 0 || xx >= gw) continue;
            sum += g[yy * gw + xx];
            n++;
          }
        }
        o[y * gw + x] = sum / n;
      }
    }
    return o;
  }

  // ------------------------------------------------------------ auto crop
  /// Returns [left, top, right, bottom] fractions to remove, or null.
  static Future<List<double>?> autoCropBg(Rgba src) =>
      Isolate.run(() => autoCrop(src.data, src.w, src.h));

  static List<double>? autoCrop(Uint8List px, int w, int h) {
    final f = math.max(4, (math.max(w, h) / 100).ceil());
    final gw = (w / f).ceil();
    final gh = (h / f).ceil();
    final lum = Float32List(gw * gh);
    final cnt = Float32List(gw * gh);
    for (var y = 0; y < h; y += 2) {
      for (var x = 0; x < w; x += 2) {
        final i = (y * w + x) * 4;
        final c = (y ~/ f) * gw + (x ~/ f);
        lum[c] += px[i] * 0.299 + px[i + 1] * 0.587 + px[i + 2] * 0.114;
        cnt[c] += 1;
      }
    }
    final hist = List<int>.filled(256, 0);
    for (var c = 0; c < lum.length; c++) {
      if (cnt[c] > 0) {
        lum[c] = lum[c] / cnt[c];
        var bi = lum[c].round();
        if (bi < 0) bi = 0;
        if (bi > 255) bi = 255;
        hist[bi]++;
      }
    }
    // Otsu threshold
    final total = gw * gh;
    var sumAll = 0.0;
    for (var t = 0; t < 256; t++) {
      sumAll += t * hist[t];
    }
    var wB = 0, sumB = 0.0, best = 0.0, thr = 128;
    for (var t = 0; t < 256; t++) {
      wB += hist[t];
      if (wB == 0) continue;
      final wF = total - wB;
      if (wF == 0) break;
      sumB += t * hist[t];
      final mB = sumB / wB;
      final mF = (sumAll - sumB) / wF;
      final between = wB * wF * (mB - mF) * (mB - mF);
      if (between > best) {
        best = between;
        thr = t;
      }
    }
    final rows = List<int>.filled(gh, 0);
    final cols = List<int>.filled(gw, 0);
    for (var y = 0; y < gh; y++) {
      for (var x = 0; x < gw; x++) {
        if (lum[y * gw + x] > thr) {
          rows[y]++;
          cols[x]++;
        }
      }
    }
    int first(List<int> a, int limit) {
      for (var i = 0; i < a.length; i++) {
        if (a[i] > limit) return i;
      }
      return 0;
    }

    int last(List<int> a, int limit) {
      for (var i = a.length - 1; i >= 0; i--) {
        if (a[i] > limit) return i;
      }
      return a.length - 1;
    }

    final top = first(rows, (gw * 0.08).round());
    final bottom = last(rows, (gw * 0.08).round());
    final left = first(cols, (gh * 0.08).round());
    final right = last(cols, (gh * 0.08).round());
    if (bottom <= top || right <= left) return null;
    final l = math.max(0, left - 1) / gw;
    final t = math.max(0, top - 1) / gh;
    final r = 1 - math.min(gw, right + 2) / gw;
    final b = 1 - math.min(gh, bottom + 2) / gh;
    final area = (1 - l - r) * (1 - t - b);
    if (area < 0.25 || area > 0.97) return null;
    return <double>[l, t, r < 0 ? 0.0 : r, b < 0 ? 0.0 : b];
  }
}
