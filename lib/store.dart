import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

class AppStore extends ChangeNotifier {
  SharedPreferences? _p;
  bool _dark = false;
  ViewerMode _viewerMode = ViewerMode.vertical;
  CompressionLevel _compression = CompressionLevel.medium;
  List<RecentFile> _recents = [];
  List<RecentFile> _trash = [];
  Map<String, List<int>> _bookmarks = {};

  List<RecentFile> get trash => List.unmodifiable(_trash);

  bool get dark => _dark;
  ViewerMode get viewerMode => _viewerMode;
  CompressionLevel get compression => _compression;
  List<RecentFile> get recents => List.unmodifiable(_recents);

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    _p = p;
    _dark = p.getBool('dark') ?? false;
    _viewerMode = p.getString('viewer') == 'horizontal'
        ? ViewerMode.horizontal
        : ViewerMode.vertical;
    final c = p.getString('compression');
    _compression = CompressionLevel.values.firstWhere(
      (e) => e.name == c,
      orElse: () => CompressionLevel.medium,
    );
    final raw = p.getString('recents_v1');
    if (raw != null) {
      try {
        final list = jsonDecode(raw) as List;
        _recents = list
            .map((e) => RecentFile.fromJson(Map<String, dynamic>.from(e as Map)))
            .where((r) => File(r.path).existsSync())
            .toList();
      } catch (_) {
        _recents = [];
      }
    }
    final rawTrash = p.getString('trash_v1');
    if (rawTrash != null) {
      try {
        final list = jsonDecode(rawTrash) as List;
        _trash = list
            .map((e) => RecentFile.fromJson(Map<String, dynamic>.from(e as Map)))
            .where((r) => File(r.path).existsSync())
            .toList();
      } catch (_) {
        _trash = [];
      }
    }
    final rawBm = p.getString('bookmarks_v1');
    if (rawBm != null) {
      try {
        final m = jsonDecode(rawBm) as Map;
        _bookmarks = m.map((k, v) =>
            MapEntry(k as String, (v as List).map((e) => (e as num).toInt()).toList()));
      } catch (_) {
        _bookmarks = {};
      }
    }
    notifyListeners();
  }

  Future<void> _saveTrash() async {
    await _p?.setString('trash_v1', jsonEncode(_trash.map((e) => e.toJson()).toList()));
  }

  List<int> bookmarksFor(String key) => List<int>.from(_bookmarks[key] ?? const <int>[]);

  Future<void> toggleBookmark(String key, int page) async {
    final list = _bookmarks[key] ?? <int>[];
    if (list.contains(page)) {
      list.remove(page);
    } else {
      list.add(page);
      list.sort();
    }
    _bookmarks[key] = list;
    notifyListeners();
    await _p?.setString('bookmarks_v1', jsonEncode(_bookmarks));
  }

  Future<void> toggleFav(String path) async {
    final i = _recents.indexWhere((r) => r.path == path);
    if (i == -1) return;
    _recents[i] = _recents[i].copyWith(fav: !_recents[i].fav);
    notifyListeners();
    await _saveRecents();
  }

  /// Moves a recent file into the in-app trash.
  Future<void> moveToTrash(RecentFile f, String trashDir) async {
    String newPath = '$trashDir/${DateTime.now().millisecondsSinceEpoch}_${f.name}';
    try {
      await File(f.path).rename(newPath);
    } catch (_) {
      try {
        await File(f.path).copy(newPath);
        await File(f.path).delete();
      } catch (_) {
        newPath = f.path;
      }
    }
    _recents.removeWhere((r) => r.path == f.path);
    _trash.insert(0, f.copyWith(path: newPath));
    notifyListeners();
    await _saveRecents();
    await _saveTrash();
  }

  Future<void> restoreFromTrash(RecentFile f, String outDir) async {
    var target = '$outDir/${f.name}';
    if (await File(target).exists()) {
      target = '$outDir/${DateTime.now().millisecondsSinceEpoch}_${f.name}';
    }
    try {
      await File(f.path).rename(target);
    } catch (_) {
      await File(f.path).copy(target);
      await File(f.path).delete();
    }
    _trash.removeWhere((r) => r.path == f.path);
    _recents.insert(0, f.copyWith(path: target));
    notifyListeners();
    await _saveRecents();
    await _saveTrash();
  }

  Future<void> deleteForever(RecentFile f) async {
    try {
      await File(f.path).delete();
    } catch (_) {}
    _trash.removeWhere((r) => r.path == f.path);
    notifyListeners();
    await _saveTrash();
  }

  Future<void> emptyTrash() async {
    for (final r in _trash) {
      try {
        await File(r.path).delete();
      } catch (_) {}
    }
    _trash = [];
    notifyListeners();
    await _saveTrash();
  }

  Future<void> _saveRecents() async {
    await _p?.setString(
        'recents_v1', jsonEncode(_recents.map((e) => e.toJson()).toList()));
  }

  Future<void> setDark(bool v) async {
    _dark = v;
    notifyListeners();
    await _p?.setBool('dark', v);
  }

  Future<void> setViewerMode(ViewerMode m) async {
    _viewerMode = m;
    notifyListeners();
    await _p?.setString('viewer', m.name);
  }

  Future<void> setCompression(CompressionLevel c) async {
    _compression = c;
    notifyListeners();
    await _p?.setString('compression', c.name);
  }

  Future<void> addRecent(RecentFile f) async {
    _recents.removeWhere((r) => r.path == f.path);
    _recents.insert(0, f);
    if (_recents.length > 50) _recents = _recents.sublist(0, 50);
    notifyListeners();
    await _saveRecents();
  }

  Future<void> removeRecent(String path) async {
    _recents.removeWhere((r) => r.path == path);
    notifyListeners();
    await _saveRecents();
  }

  Future<void> replaceRecent(String oldPath, RecentFile f) async {
    final i = _recents.indexWhere((r) => r.path == oldPath);
    if (i == -1) return;
    _recents[i] = f;
    notifyListeners();
    await _saveRecents();
  }

  Future<void> clearRecents() async {
    for (final r in _recents) {
      try {
        await File(r.path).delete();
      } catch (_) {}
    }
    _recents = [];
    notifyListeners();
    await _saveRecents();
  }
}

class StoreScope extends InheritedNotifier<AppStore> {
  const StoreScope({
    super.key,
    required AppStore store,
    required super.child,
  }) : super(notifier: store);

  static AppStore of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<StoreScope>()!.notifier!;

  static AppStore read(BuildContext context) {
    final w = context
        .getElementForInheritedWidgetOfExactType<StoreScope>()!
        .widget as StoreScope;
    return w.notifier!;
  }
}
