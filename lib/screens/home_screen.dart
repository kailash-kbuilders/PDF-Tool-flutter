import 'package:flutter/material.dart';

import '../models.dart';
import '../store.dart';
import '../theme.dart';
import '../ui.dart';
import 'convert_screens.dart';
import 'organizer_screen.dart';
import 'scan_screen.dart';
import 'security_screens.dart';
import 'viewer_screen.dart';

class HomeScreen extends StatelessWidget {
  final VoidCallback onSeeAllRecent;
  const HomeScreen({super.key, required this.onSeeAllRecent});

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final tools = <ToolTile>[
      ToolTile(icon: Icons.merge_type, label: 'Merge PDF',
          onTap: () => pushPage<void>(context, const OrganizerScreen(initialTab: 0))),
      ToolTile(icon: Icons.call_split, label: 'Split PDF',
          onTap: () => pushPage<void>(context, const OrganizerScreen(initialTab: 1))),
      ToolTile(icon: Icons.edit_outlined, label: 'Edit PDF',
          onTap: () => pickAndOpenPdf(context)),
      ToolTile(icon: Icons.image_outlined, label: 'Image to PDF',
          onTap: () => pushPage<void>(context, const ImageToPdfScreen())),
      ToolTile(icon: Icons.compress, label: 'Compress PDF',
          onTap: () => pushPage<void>(context, const CompressScreen())),
      ToolTile(icon: Icons.document_scanner_outlined, label: 'Scan to PDF',
          onTap: () => pushPage<void>(context, const ScanScreen())),
      ToolTile(icon: Icons.lock_outline, label: 'Protect PDF',
          onTap: () => pushPage<void>(context, const ProtectScreen())),
      ToolTile(icon: Icons.water_drop_outlined, label: 'Watermark',
          onTap: () => pushPage<void>(context, const WatermarkScreen())),
    ];
    final recents = store.recents.take(3).toList();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: scheme.secondaryContainer,
            borderRadius: BorderRadius.circular(14),
          ),
          child: const Row(
            children: [
              Icon(Icons.verified_user_outlined, color: AppColors.red),
              SizedBox(width: 12),
              Expanded(
                child: Text('Your files stay on your device.',
                    style: TextStyle(fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: () => pickAndOpenPdf(context),
                icon: const Icon(Icons.folder_open),
                label: const Text('Open PDF'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => pushPage<void>(context, const ScanScreen()),
                icon: const Icon(Icons.document_scanner_outlined),
                label: const Text('Scan'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        const Text('Tools',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        GridView.count(
          crossAxisCount: 4,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          childAspectRatio: 0.82,
          children: tools,
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            const Expanded(
              child: Text('Recent files',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            ),
            if (recents.isNotEmpty)
              TextButton(onPressed: onSeeAllRecent, child: const Text('See all')),
          ],
        ),
        if (recents.isEmpty)
          Card(
            margin: EdgeInsets.zero,
            elevation: 0,
            color: scheme.surface,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: EmptyState(
                icon: Icons.history,
                title: 'No recent files',
                action: 'Choose a PDF',
                onAction: () => pickAndOpenPdf(context),
              ),
            ),
          )
        else
          for (final f in recents) RecentCard(file: f),
      ],
    );
  }
}

class RecentCard extends StatelessWidget {
  final RecentFile file;
  const RecentCard({super.key, required this.file});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      color: Theme.of(context).colorScheme.surface,
      child: ListTile(
        leading: const Icon(Icons.picture_as_pdf, color: AppColors.red, size: 30),
        title: Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text('PDF · ${fmtDateTime(file.ts)}'),
        trailing: TextButton(
          onPressed: () =>
              pushPage<void>(context, ViewerScreen(name: file.name, path: file.path)),
          child: const Text('Open'),
        ),
      ),
    );
  }
}
