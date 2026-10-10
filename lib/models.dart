import 'dart:typed_data';

enum ViewerMode { vertical, horizontal }

enum CompressionLevel { low, medium, high }

class PickedFile {
  final String name;
  final String? path;
  final Uint8List bytes;
  const PickedFile(this.name, this.path, this.bytes);
  int get size => bytes.length;
}

class RecentFile {
  final String path;
  final String name;
  final int ts;
  final int size;
  final bool fav;
  const RecentFile({
    required this.path,
    required this.name,
    required this.ts,
    required this.size,
    this.fav = false,
  });

  RecentFile copyWith({String? path, String? name, bool? fav}) => RecentFile(
        path: path ?? this.path,
        name: name ?? this.name,
        ts: ts,
        size: size,
        fav: fav ?? this.fav,
      );

  Map<String, dynamic> toJson() => {
        'path': path,
        'name': name,
        'ts': ts,
        'size': size,
        'fav': fav,
      };

  factory RecentFile.fromJson(Map<String, dynamic> j) => RecentFile(
        path: j['path'] as String,
        name: j['name'] as String,
        ts: (j['ts'] as num).toInt(),
        size: (j['size'] as num).toInt(),
        fav: (j['fav'] as bool?) ?? false,
      );
}

/// One output page: which source document, which page, extra quarter turns.
class PageRef {
  final int doc;
  final int page;
  final int turns;
  const PageRef(this.doc, this.page, [this.turns = 0]);
}

class AnnoType {
  static const int draw = 0;
  static const int highlight = 1;
  static const int underline = 2;
  static const int note = 3;
  static const int signature = 4;
  static const int text = 5;
  static const int strike = 6;
  static const int stamp = 7;
}

/// Annotation with page-normalised coordinates (0..1).
/// draw: pts = x,y,x,y...   highlight/underline: pts = x1,y1,x2,y2
/// note: pts = x,y          signature: pts = x,y,w,h
class AnnoData {
  final int type;
  final int page;
  List<double> pts;
  final int color;
  final double width; // fraction of page width
  final String text;
  final Uint8List? image;

  AnnoData({
    required this.type,
    required this.page,
    required this.pts,
    this.color = 0xFFE31B23,
    this.width = 0.004,
    this.text = '',
    this.image,
  });
}

class OcrLine {
  final String text;
  final double l;
  final double t;
  final double r;
  final double b;
  const OcrLine(this.text, this.l, this.t, this.r, this.b);
}

class OcrPage {
  final int w;
  final int h;
  final List<OcrLine> lines;
  const OcrPage(this.w, this.h, this.lines);
  String get text => lines.map((l) => l.text).join('\n');
}

class NormImage {
  final Uint8List bytes;
  final int w;
  final int h;
  const NormImage(this.bytes, this.w, this.h);
}

/// Tiny markdown-ish line parser shared by the PDF writer and the preview.
class MdLine {
  final String text;
  final int level;
  final bool bullet;
  final bool bold;
  final bool italic;
  const MdLine(this.text, this.level, this.bullet, this.bold, this.italic);

  static MdLine parse(String raw) {
    var s = raw.trimRight();
    var level = 0;
    var bullet = false;
    var bold = false;
    var italic = false;
    if (s.startsWith('### ')) {
      level = 3;
      s = s.substring(4);
    } else if (s.startsWith('## ')) {
      level = 2;
      s = s.substring(3);
    } else if (s.startsWith('# ')) {
      level = 1;
      s = s.substring(2);
    } else if (s.startsWith('- ') || s.startsWith('* ')) {
      bullet = true;
      s = s.substring(2);
    }
    if (s.length > 4 && s.startsWith('**') && s.endsWith('**')) {
      bold = true;
      s = s.substring(2, s.length - 2);
    } else if (s.length > 2 && s.startsWith('_') && s.endsWith('_')) {
      italic = true;
      s = s.substring(1, s.length - 1);
    } else if (s.length > 2 && s.startsWith('*') && s.endsWith('*')) {
      italic = true;
      s = s.substring(1, s.length - 1);
    }
    return MdLine(s, level, bullet, bold, italic);
  }

  bool get isBold => bold || level > 0;
  String get display => bullet ? '- $text' : text;
  double size(double base) {
    if (level == 1) return base * 1.9;
    if (level == 2) return base * 1.5;
    if (level == 3) return base * 1.25;
    return base;
  }
}


/// Non-destructive edit settings for a scanned / imported page.
/// filter: 0 original, 1 magic colour, 2 black & white, 3 grayscale.
class EditParams {
  final int filter;
  final double brightness; // -100..100
  final double contrast; // -100..100
  final int rot; // quarter turns clockwise
  final double cl; // crop fractions removed from each side (of rotated image)
  final double ct;
  final double cr;
  final double cb;

  const EditParams({
    this.filter = 0,
    this.brightness = 0,
    this.contrast = 0,
    this.rot = 0,
    this.cl = 0,
    this.ct = 0,
    this.cr = 0,
    this.cb = 0,
  });

  static const EditParams none = EditParams();
  static const EditParams magic = EditParams(filter: 1);

  bool get isDefault => this == none;
  bool get hasCrop => cl > 0 || ct > 0 || cr > 0 || cb > 0;

  EditParams copyWith({
    int? filter,
    double? brightness,
    double? contrast,
    int? rot,
    double? cl,
    double? ct,
    double? cr,
    double? cb,
  }) =>
      EditParams(
        filter: filter ?? this.filter,
        brightness: brightness ?? this.brightness,
        contrast: contrast ?? this.contrast,
        rot: rot ?? this.rot,
        cl: cl ?? this.cl,
        ct: ct ?? this.ct,
        cr: cr ?? this.cr,
        cb: cb ?? this.cb,
      );

  @override
  bool operator ==(Object other) =>
      other is EditParams &&
      other.filter == filter &&
      other.brightness == brightness &&
      other.contrast == contrast &&
      other.rot == rot &&
      other.cl == cl &&
      other.ct == ct &&
      other.cr == cr &&
      other.cb == cb;

  @override
  int get hashCode =>
      Object.hash(filter, brightness, contrast, rot, cl, ct, cr, cb);
}

class Rgba {
  final Uint8List data;
  final int w;
  final int h;
  const Rgba(this.data, this.w, this.h);
}

class EditablePage {
  final int id;
  final NormImage orig;
  NormImage? edited;
  EditParams params;
  OcrPage? ocr;
  EditablePage(this.id, this.orig, {this.params = EditParams.none});
  NormImage get cur => edited ?? orig;
}
