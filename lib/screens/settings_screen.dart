import 'package:flutter/material.dart';

import '../models.dart';
import '../store.dart';
import '../theme.dart';
import '../ui.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final scheme = Theme.of(context).colorScheme;

    Widget section(String title, List<Widget> children) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
            child: Text(title,
                style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    color: scheme.onSurface.withAlpha(170))),
          ),
          Card(
            margin: EdgeInsets.zero,
            elevation: 0,
            color: scheme.surface,
            clipBehavior: Clip.antiAlias,
            child: Column(children: children),
          ),
        ],
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        section('APPEARANCE', [
          SwitchListTile(
            secondary: const Icon(Icons.dark_mode_outlined),
            title: const Text('Dark mode'),
            value: store.dark,
            onChanged: (v) => store.setDark(v),
          ),
        ]),
        section('PREFERENCES', [
          ListTile(
            leading: const Icon(Icons.view_day_outlined),
            title: const Text('Default PDF viewer mode'),
            trailing: Text(store.viewerMode == ViewerMode.vertical ? 'Vertical' : 'Horizontal'),
            onTap: () async {
              final v = await showDialog<ViewerMode>(
                context: context,
                builder: (ctx) => SimpleDialog(
                  title: const Text('Viewer mode'),
                  children: [
                    SimpleDialogOption(
                        onPressed: () => Navigator.of(ctx).pop(ViewerMode.vertical),
                        child: const Text('Vertical scrolling')),
                    SimpleDialogOption(
                        onPressed: () => Navigator.of(ctx).pop(ViewerMode.horizontal),
                        child: const Text('Horizontal reading')),
                  ],
                ),
              );
              if (v != null) await store.setViewerMode(v);
            },
          ),
          ListTile(
            leading: const Icon(Icons.compress),
            title: const Text('Default compression quality'),
            trailing: Text(_levelName(store.compression)),
            onTap: () async {
              final v = await showDialog<CompressionLevel>(
                context: context,
                builder: (ctx) => SimpleDialog(
                  title: const Text('Compression'),
                  children: [
                    for (final l in CompressionLevel.values)
                      SimpleDialogOption(
                          onPressed: () => Navigator.of(ctx).pop(l),
                          child: Text(_levelName(l))),
                  ],
                ),
              );
              if (v != null) await store.setCompression(v);
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_sweep_outlined, color: Colors.red),
            title: const Text('Clear recent files', style: TextStyle(color: Colors.red)),
            onTap: () async {
              final ok = await confirmDialog(context,
                  title: 'Clear recent files?',
                  body: 'This removes all recent files from the app. Copies you saved or shared elsewhere are not affected.',
                  action: 'Clear');
              if (ok) await store.clearRecents();
            },
          ),
        ]),
        section('ABOUT', [
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('PDF Toolkit'),
            subtitle: Text('Version 1.0.0'),
          ),
          const ListTile(
            leading: Icon(Icons.verified_user_outlined),
            title: Text('Privacy'),
            subtitle: Text('All document processing happens on your device.'),
          ),
        ]),
      ],
    );
  }

  static String _levelName(CompressionLevel l) {
    switch (l) {
      case CompressionLevel.low:
        return 'Low';
      case CompressionLevel.medium:
        return 'Medium';
      case CompressionLevel.high:
        return 'High';
    }
  }
}
