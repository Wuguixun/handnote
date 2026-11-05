import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import '../models/models.dart';
import '../services/pdf_service.dart';

/// 导出面板：边距、是否保留原图、水印、页码，导出后可预览 / 分享
class ExportSheet extends StatefulWidget {
  final Note note;
  const ExportSheet({super.key, required this.note});

  @override
  State<ExportSheet> createState() => _ExportSheetState();
}

class _ExportSheetState extends State<ExportSheet> {
  ExportOptions _options = const ExportOptions();
  bool _busy = false;

  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      final service = PdfService();
      final file = await service.exportToFile(widget.note, _options);
      if (!mounted) return;

      await showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        builder: (_) => SizedBox(
          height: MediaQuery.of(context).size.height * 0.8,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text('预览', style: TextStyle(fontSize: 15)),
                    ),
                    TextButton.icon(
                      onPressed: () => Share.shareXFiles(
                        [XFile(file.path)],
                        subject: widget.note.title,
                      ),
                      icon: const Icon(Icons.share, size: 16),
                      label: const Text('分享'),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: PdfPreview(
                  build: (_) => file.readAsBytes(),
                  canChangePageFormat: false,
                  canDebug: false,
                  allowPrinting: true,
                  allowSharing: true,
                ),
              ),
            ],
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.of(context).viewInsets.bottom;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 16, 20, 20 + pad),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('导出 PDF',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            _row('页面尺寸', DropdownButton<PdfPageLayout>(
              value: _options.layout,
              underline: const SizedBox(),
              items: const [
                DropdownMenuItem(
                    value: PdfPageLayout.a4Portrait, child: Text('A4 竖版')),
                DropdownMenuItem(
                    value: PdfPageLayout.a4Landscape, child: Text('A4 横版')),
                DropdownMenuItem(
                    value: PdfPageLayout.b5Portrait, child: Text('B5 竖版')),
              ],
              onChanged: (v) =>
                  setState(() => _options = _options.copyWith(layout: v)),
            )),
            _row('页边距', SizedBox(
              width: 180,
              child: Slider(
                value: _options.marginMm,
                min: 8,
                max: 30,
                divisions: 11,
                label: '${_options.marginMm.round()} mm',
                onChanged: (v) =>
                    setState(() => _options = _options.copyWith(marginMm: v)),
              ),
            )),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('保留原稿页', style: TextStyle(fontSize: 14)),
              subtitle: const Text('每页排版后附一张原图，便于核对笔迹',
                  style: TextStyle(fontSize: 11)),
              value: _options.keepOriginalImage,
              onChanged: (v) => setState(
                  () => _options = _options.copyWith(keepOriginalImage: v)),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('添加水印', style: TextStyle(fontSize: 14)),
              value: _options.withWatermark,
              onChanged: (v) =>
                  setState(() => _options = _options.copyWith(withWatermark: v)),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('显示页码', style: TextStyle(fontSize: 14)),
              value: _options.withPageNumber,
              onChanged: (v) =>
                  setState(() => _options = _options.copyWith(withPageNumber: v)),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              height: 46,
              child: FilledButton(
                onPressed: _busy ? null : _export,
                child: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('生成 PDF'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(String title, Widget child) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(title, style: const TextStyle(fontSize: 14)),
            child,
          ],
        ),
      );
}
