import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../models.dart';
import '../store.dart';

class FileService {
  static Future<Directory> outputDir() async {
    final base = await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}/PDF Toolkit');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  static Future<Directory> trashDir() async {
    final base = await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}/PDF Toolkit Trash');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  static String _stamp() {
    final n = DateTime.now();
    String t(int v) => v.toString().padLeft(2, '0');
    return '${n.year}${t(n.month)}${t(n.day)}_${t(n.hour)}${t(n.minute)}${t(n.second)}';
  }

  static String stem(String name) {
    var s = name;
    if (s.toLowerCase().endsWith('.pdf')) s = s.substring(0, s.length - 4);
    return s;
  }

  static String safeStem(String name) {
    final s = stem(name).replaceAll(RegExp(r'[^A-Za-z0-9_\- ]'), '_').trim();
    return s.isEmpty ? 'document' : s;
  }

  static Future<List<PickedFile>> _pick(List<String> ext, bool multiple) async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ext,
      allowMultiple: multiple,
      withData: true,
    );
    if (res == null) return [];
    final out = <PickedFile>[];
    for (final f in res.files) {
      Uint8List? b = f.bytes;
      if (b == null && f.path != null) b = await File(f.path!).readAsBytes();
      if (b == null) continue;
      out.add(PickedFile(f.name, f.path, b));
    }
    return out;
  }

  static Future<List<PickedFile>> pickPdfs({bool multiple = false}) =>
      _pick(['pdf'], multiple);

  static Future<List<PickedFile>> pickImages({bool multiple = true}) =>
      _pick(['jpg', 'jpeg', 'png'], multiple);

  static Future<RecentFile> saveOutput(
      Uint8List bytes, String baseName, AppStore store) async {
    final dir = await outputDir();
    final name = '${safeStem(baseName)}_${_stamp()}.pdf';
    final file = File('${dir.path}/$name');
    await file.writeAsBytes(bytes, flush: true);
    final rf = RecentFile(
      path: file.path,
      name: name,
      ts: DateTime.now().millisecondsSinceEpoch,
      size: bytes.length,
    );
    await store.addRecent(rf);
    return rf;
  }
}
