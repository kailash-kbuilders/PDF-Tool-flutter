import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:printing/printing.dart' show Printing;

import 'errors.dart';
import 'models.dart';
import 'screens/viewer_screen.dart';
import 'services/file_service.dart';
import 'services/pdf_service.dart';
import 'store.dart';
import 'theme.dart';

// ------------------------------------------------------------- formatting
String fmtSize(int b) {
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
  return '${(b / (1024 * 1024)).toStringAsFixed(2)} MB';
}

String fmtDateTime(int ts) {
  const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final d = DateTime.fromMillisecondsSinceEpoch(ts);
  String t(int v) => v.toString().padLeft(2, '0');
  return '${d.day} ${m[d.month - 1]} ${d.year}, ${t(d.hour)}:${t(d.minute)}';
}

double clampD(double v, double lo, double hi) => v < lo ? lo : (v > hi ? hi : v);

// ------------------------------------------------------------- navigation
Future<T?> pushPage<T>(BuildContext context, Widget page) =>
    Navigator.of(context).push<T>(MaterialPageRoute<T>(builder: (_) => page));

PreferredSizeWidget buildAppBar(
  BuildContext context, {
  required Widget title,
  List<Widget>? actions,
  PreferredSizeWidget? bottom,
}) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return AppBar(
    backgroundColor: dark ? AppColors.dark : AppColors.red,
    foregroundColor: Colors.white,
    scrolledUnderElevation: 0,
    toolbarHeight: 48,
    titleTextStyle: const TextStyle(
        fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white),
    title: title,
    actions: actions,
    bottom: bottom,
  );
}

Future<void> pickAndOpenPdf(BuildContext context) async {
  List<PickedFile> files;
  try {
    files = await FileService.pickPdfs();
  } catch (_) {
    if (context.mounted) await showError(context, 'Unable to open this PDF.');
    return;
  }
  if (files.isEmpty || !context.mounted) return;
  await pushPage<void>(
      context, ViewerScreen(name: files.first.name, bytes: files.first.bytes));
}

// ---------------------------------------------------------------- dialogs
Future<void> showError(BuildContext context, String message) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.error_outline, color: AppColors.red),
      content: Text(message, textAlign: TextAlign.center),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('OK')),
      ],
    ),
  );
}

void showSnack(BuildContext context, String message) {
  final m = ScaffoldMessenger.of(context);
  m.clearSnackBars();
  m.showSnackBar(SnackBar(content: Text(message)));
}

Future<bool> confirmDialog(BuildContext context,
    {required String title, required String body, required String action}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true), child: Text(action)),
      ],
    ),
  );
  return ok == true;
}

Future<T?> runWithProgress<T>(
  BuildContext context,
  Future<T> Function() job, {
  String message = 'Processing PDF…',
}) async {
  final nav = Navigator.of(context, rootNavigator: true);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(width: 20),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    ),
  );
  await Future<void>.delayed(const Duration(milliseconds: 60));
  try {
    final r = await job();
    nav.pop();
    return r;
  } catch (e) {
    nav.pop();
    if (context.mounted) await showError(context, friendlyError(e));
    return null;
  }
}

/// Runs [job], saves the result as a PDF, shows the success sheet.
Future<void> runPdfJob(
  BuildContext context,
  String baseName,
  Future<Uint8List> Function() job, {
  String? Function()? note,
}) async {
  final store = StoreScope.read(context);
  final file = await runWithProgress<RecentFile>(context, () async {
    final bytes = await job();
    return FileService.saveOutput(bytes, baseName, store);
  });
  if (file != null && context.mounted) {
    await showResultSheet(context, file, note: note?.call());
  }
}

Future<void> showResultSheet(BuildContext context, RecentFile f, {String? note}) {
  return showModalBottomSheet<void>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle, color: Colors.green, size: 44),
            const SizedBox(height: 8),
            const Text('PDF created successfully.',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(f.name, textAlign: TextAlign.center),
            Text(note ?? fmtSize(f.size),
                style: TextStyle(color: Theme.of(ctx).hintColor)),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: const Text('Open'),
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      if (context.mounted) {
                        pushPage<void>(context, ViewerScreen(name: f.name, path: f.path));
                      }
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.share, size: 18),
                    label: const Text('Share'),
                    onPressed: () async {
                      final b = await File(f.path).readAsBytes();
                      await Printing.sharePdf(bytes: b, filename: f.name);
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.print_outlined, size: 18),
                    label: const Text('Print'),
                    onPressed: () async {
                      final b = await File(f.path).readAsBytes();
                      await Printing.layoutPdf(onLayout: (_) async => b, name: f.name);
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.download, size: 18),
                    label: const Text('Save'),
                    onPressed: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      try {
                        final b = await File(f.path).readAsBytes();
                        final p = await FilePicker.platform.saveFile(
                          dialogTitle: 'Save PDF',
                          fileName: f.name,
                          bytes: b,
                          type: FileType.custom,
                          allowedExtensions: ['pdf'],
                        );
                        if (p != null) {
                          messenger.showSnackBar(
                              const SnackBar(content: Text('Saved to your device.')));
                        }
                      } catch (_) {
                        messenger.showSnackBar(
                            const SnackBar(content: Text('Not enough storage space.')));
                      }
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Done'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

// ------------------------------------------------------------ small widgets
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final String? action;
  final VoidCallback? onAction;
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.action,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: Theme.of(context).hintColor),
            const SizedBox(height: 12),
            Text(title,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(subtitle!, textAlign: TextAlign.center),
            ],
            if (action != null) ...[
              const SizedBox(height: 16),
              FilledButton(onPressed: onAction, child: Text(action!)),
            ],
          ],
        ),
      ),
    );
  }
}

class LoadedPdf {
  final PickedFile file;
  final int pages;
  const LoadedPdf(this.file, this.pages);
}

Future<LoadedPdf?> pickSinglePdf(BuildContext context, {bool countPages = true}) async {
  List<PickedFile> files;
  try {
    files = await FileService.pickPdfs();
  } catch (_) {
    if (context.mounted) await showError(context, 'Unable to open this PDF.');
    return null;
  }
  if (files.isEmpty) return null;
  final f = files.first;
  if (!countPages) return LoadedPdf(f, 0);
  try {
    final n = await PdfService.pageCount(f.bytes);
    return LoadedPdf(f, n);
  } catch (e) {
    if (context.mounted) await showError(context, friendlyError(e));
    return null;
  }
}

class PdfPickerCard extends StatelessWidget {
  final LoadedPdf? pdf;
  final VoidCallback onPick;
  const PdfPickerCard({super.key, required this.pdf, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final p = pdf;
    if (p == null) {
      return Card(
        margin: EdgeInsets.zero,
        elevation: 0,
        color: scheme.surface,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 28),
          child: EmptyState(
            icon: Icons.picture_as_pdf_outlined,
            title: 'No PDF selected',
            action: 'Choose PDF',
            onAction: onPick,
          ),
        ),
      );
    }
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: scheme.surface,
      child: ListTile(
        leading: const Icon(Icons.picture_as_pdf, color: AppColors.red, size: 32),
        title: Text(p.file.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(p.pages > 0
            ? '${fmtSize(p.file.size)} · ${p.pages} pages'
            : fmtSize(p.file.size)),
        trailing: TextButton(onPressed: onPick, child: const Text('Change')),
      ),
    );
  }
}

/// Lazily renders one PDF page (cached) as an image.
class PageImage extends StatefulWidget {
  final Uint8List bytes;
  final int index;
  final Map<int, Uint8List> cache;
  final double dpi;
  final bool night;
  const PageImage({
    super.key,
    required this.bytes,
    required this.index,
    required this.cache,
    this.dpi = 100,
    this.night = false,
  });

  @override
  State<PageImage> createState() => _PageImageState();
}

class _PageImageState extends State<PageImage> {
  late Future<Uint8List?> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<Uint8List?> _load() async {
    final c = widget.cache[widget.index];
    if (c != null) return c;
    final r = await PdfService.renderPage(widget.bytes, widget.index, dpi: widget.dpi);
    if (r != null) widget.cache[widget.index] = r;
    return r;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: _future,
      builder: (context, snap) {
        final data = snap.data;
        if (data == null) {
          return ColoredBox(
            color: Colors.white,
            child: Center(
              child: snap.connectionState == ConnectionState.done
                  ? const Icon(Icons.broken_image_outlined, color: Colors.grey)
                  : const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          );
        }
        Widget image = Image.memory(data, fit: BoxFit.fill, gaplessPlayback: true);
        if (widget.night) {
          image = ColorFiltered(
            colorFilter: const ColorFilter.matrix(<double>[
              -1, 0, 0, 0, 255,
              0, -1, 0, 0, 255,
              0, 0, -1, 0, 255,
              0, 0, 0, 1, 0,
            ]),
            child: image,
          );
        }
        return image;
      },
    );
  }
}

class ToolTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const ToolTile({super.key, required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircleAvatar(
              radius: 24,
              backgroundColor: scheme.secondaryContainer,
              child: Icon(icon, color: AppColors.red),
            ),
            const SizedBox(height: 6),
            Text(label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }
}

class TextInputDialog extends StatefulWidget {
  final String title;
  final String initial;
  final String hint;
  final int maxLines;
  const TextInputDialog({
    super.key,
    required this.title,
    this.initial = '',
    this.hint = '',
    this.maxLines = 1,
  });

  @override
  State<TextInputDialog> createState() => _TextInputDialogState();
}

class _TextInputDialogState extends State<TextInputDialog> {
  late final TextEditingController _c;

  @override
  void initState() {
    super.initState();
    _c = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _c,
        autofocus: true,
        maxLines: widget.maxLines,
        decoration: InputDecoration(
            hintText: widget.hint, border: const OutlineInputBorder()),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.of(context).pop(_c.text),
            child: const Text('OK')),
      ],
    );
  }
}
