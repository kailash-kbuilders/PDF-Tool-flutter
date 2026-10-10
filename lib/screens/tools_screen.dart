import 'package:flutter/material.dart';

import '../ui.dart';
import '../models.dart';
import 'convert_screens.dart';
import 'extra_screens.dart';
import 'organizer_screen.dart';
import 'scan_screen.dart';
import 'security_screens.dart';

class ToolsScreen extends StatelessWidget {
  const ToolsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    Widget section(String title, List<ToolTile> tiles) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Card(
          margin: EdgeInsets.zero,
          elevation: 0,
          color: scheme.surface,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 6),
                  child: Text(title,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                ),
                GridView.count(
                  crossAxisCount: 4,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  childAspectRatio: 0.82,
                  children: tiles,
                ),
              ],
            ),
          ),
        ),
      );
    }

    void go(Widget w) => pushPage<void>(context, w);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        section('PDF Organizer', [
          ToolTile(icon: Icons.merge_type, label: 'Merge',
              onTap: () => go(const OrganizerScreen(initialTab: 0))),
          ToolTile(icon: Icons.call_split, label: 'Split',
              onTap: () => go(const OrganizerScreen(initialTab: 1))),
          ToolTile(icon: Icons.view_agenda_outlined, label: 'Pages',
              onTap: () => go(const OrganizerScreen(initialTab: 2))),
          ToolTile(icon: Icons.pin_outlined, label: 'Page numbers',
              onTap: () => go(const PageNumbersScreen())),
          ToolTile(icon: Icons.crop, label: 'Crop pages',
              onTap: () => go(const CropScreen())),
          ToolTile(icon: Icons.grid_view, label: 'Pages per sheet',
              onTap: () => go(const NUpScreen())),
        ]),
        section('Converter', [
          ToolTile(icon: Icons.image_outlined, label: 'Image to PDF',
              onTap: () => go(const ImageToPdfScreen())),
          ToolTile(icon: Icons.text_snippet_outlined, label: 'Text to PDF',
              onTap: () => go(const TextToPdfScreen())),
          ToolTile(icon: Icons.document_scanner_outlined, label: 'Scan to PDF',
              onTap: () => go(const ScanScreen())),
          ToolTile(icon: Icons.photo_library_outlined, label: 'PDF to images',
              onTap: () => go(const PdfToImagesScreen())),
          ToolTile(icon: Icons.notes, label: 'Extract text',
              onTap: () => go(const ExtractTextScreen())),
          ToolTile(icon: Icons.filter_b_and_w, label: 'To grayscale',
              onTap: () => go(const GrayscaleScreen())),
        ]),
        section('Security & Utilities', [
          ToolTile(icon: Icons.lock_outline, label: 'Protect',
              onTap: () => go(const ProtectScreen())),
          ToolTile(icon: Icons.lock_open_outlined, label: 'Remove password',
              onTap: () => go(const UnlockScreen())),
          ToolTile(icon: Icons.compress, label: 'Compress',
              onTap: () => go(const CompressScreen())),
          ToolTile(icon: Icons.water_drop_outlined, label: 'Watermark',
              onTap: () => go(const WatermarkScreen())),
        ]),
        section('Annotator', [
          ToolTile(icon: Icons.edit_outlined, label: 'Annotate',
              onTap: () => pickAndOpenPdf(context)),
          ToolTile(icon: Icons.draw_outlined, label: 'Sign PDF',
              onTap: () => pickAndOpenPdf(context)),
          ToolTile(
              icon: Icons.assignment_outlined,
              label: 'Fill form',
              onTap: () async {
                final p = await pickSinglePdf(context, countPages: false);
                if (p != null && context.mounted) {
                  go(FormFillScreen(name: p.file.name, bytes: p.file.bytes));
                }
              }),
        ]),
      ],
    );
  }
}
