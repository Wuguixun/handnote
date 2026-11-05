import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/models.dart';

/// PDF 导出：一页手写稿 = 至少一页 PDF，用矢量文字绘制，
/// 导出的 PDF 文字可选中、可复制、可被阅读器全文检索。
class PdfService {
  /// 正文每行可容纳的字数（A4 / 11pt / 18mm 边距下的经验值）
  static const _charsPerLine = 42;
  static const _linesPerPage = 34;

  Future<Uint8List> build(Note note, ExportOptions options) async {
    // 中文字体必须嵌入，否则多数阅读器显示为方框或乱码
    final font = pw.Font.ttf(
      await rootBundle.load('assets/fonts/NotoSansSC-Regular.ttf'),
    );

    final doc = pw.Document(
      title: note.title,
      author: '我的手写笔记',
      creator: '我的手写笔记',
      subject: note.category ?? '',
      theme: pw.ThemeData.withFont(base: font, bold: font),
    );

    final pages = _paginate(note);
    final total = pages.length + (options.keepOriginalImage ? note.pages.length : 0);

    var pageNo = 1;
    for (final content in pages) {
      doc.addPage(_contentPage(
        note: note,
        page: content,
        font: font,
        options: options,
        pageNumber: pageNo++,
        totalPages: total,
      ));

      // 需要保留原稿时，在每页排版后补一张原图页
      if (options.keepOriginalImage) {
        final srcPage = note.pages[content.sourceIndex];
        final file = File(srcPage.imagePath);
        if (file.existsSync()) {
          final image = pw.MemoryImage(file.readAsBytesSync());
          doc.addPage(pw.Page(
            pageFormat: _format(options.layout),
            margin: const pw.EdgeInsets.all(24),
            build: (_) => pw.Column(
              children: [
                pw.Expanded(
                  child: pw.Image(image, fit: pw.BoxFit.contain),
                ),
                pw.SizedBox(height: 8),
                pw.Text(
                  '原稿 · 第 ${srcPage.order + 1} 页',
                  style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey600),
                ),
              ],
            ),
          ));
          pageNo++;
        }
      }
    }

    return doc.save();
  }

  /// 导出到应用目录，返回文件路径（再交给 share_plus / 打印预览）
  Future<File> exportToFile(Note note, ExportOptions options) async {
    final bytes = await build(note, options);
    final dir = await getApplicationDocumentsDirectory();
    final outDir = Directory(p.join(dir.path, 'exports'));
    if (!outDir.existsSync()) outDir.createSync(recursive: true);
    final safeName = _safeFileName(note.title);
    final file = File(p.join(outDir.path, '$safeName.pdf'));
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  String _safeFileName(String s) {
    final t = s.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    return t.isEmpty ? '未命名笔记' : t;
  }

  // ------------------------------------------------------------ 分页估算

  /// 按"行数预算"把一页笔记的块拆成若干 PDF 页。
  /// 笔记场景页数很少，估算分页比精确测量更简单，也不会把标题留在页尾。
  List<_PdfPageContent> _paginate(Note note) {
    final result = <_PdfPageContent>[];

    for (var i = 0; i < note.pages.length; i++) {
      final blocks = note.pages[i].blocks;
      final chunks = <List<NoteBlock>>[];
      var current = <NoteBlock>[];
      var used = 0;

      for (final b in blocks) {
        final cost = _lineCost(b);
        if (used + cost > _linesPerPage && current.isNotEmpty) {
          chunks.add(current);
          current = <NoteBlock>[];
          used = 0;
        }
        current.add(b);
        used += cost;
      }
      if (current.isNotEmpty) chunks.add(current);
      if (chunks.isEmpty) chunks.add(<NoteBlock>[]);

      for (final c in chunks) {
        result.add(_PdfPageContent(sourceIndex: i, blocks: c));
      }
    }
    return result;
  }

  int _lineCost(NoteBlock b) {
    final textLines = math.max(1, (b.text.length / _charsPerLine).ceil());
    switch (b.type) {
      case BlockType.title:
        return textLines + 2;
      case BlockType.heading:
        return textLines + 1;
      case BlockType.quote:
        return textLines + 1;
      default:
        return textLines;
    }
  }

  // ------------------------------------------------------------ 页面绘制

  pw.Page _contentPage({
    required Note note,
    required _PdfPageContent page,
    required pw.Font font,
    required ExportOptions options,
    required int pageNumber,
    required int totalPages,
  }) {
    final margin = options.marginMm * PdfPageFormat.mm;

    return pw.Page(
      pageFormat: _format(options.layout),
      margin: pw.EdgeInsets.fromLTRB(margin, margin, margin, margin * 0.8),
      build: (context) {
        final content = pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            if (options.withDateHeader) ...[
              pw.Text(
                '${_dateText(note.createdAt)}'
                '${note.category == null ? '' : '  ·  ${note.category}'}'
                '${note.tags.isEmpty ? '' : '  ·  #${note.tags.join(' #')}'}',
                style: const pw.TextStyle(fontSize: 8.5, color: PdfColors.grey600),
              ),
              pw.SizedBox(height: 10),
            ],
            ..._renderBlocks(page.blocks),
          ],
        );

        final layers = <pw.Widget>[];
        if (options.withWatermark) {
          layers.add(_watermark(options.watermarkText ?? '我的手写笔记', font));
        }
        layers.add(content);
        if (options.withPageNumber) {
          layers.add(pw.Positioned(
            right: 0,
            bottom: 0,
            child: pw.Text(
              '$pageNumber / $totalPages',
              style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey600),
            ),
          ));
        }
        return pw.Stack(fit: pw.StackFit.expand, children: layers);
      },
    );
  }

  List<pw.Widget> _renderBlocks(List<NoteBlock> blocks) {
    final widgets = <pw.Widget>[];
    final counters = <int, int>{};

    for (var i = 0; i < blocks.length; i++) {
      final b = blocks[i];
      final indent = (b.level - 1) * 12.0;

      switch (b.type) {
        case BlockType.title:
          widgets.add(pw.Text(
            b.text,
            style: const pw.TextStyle(fontSize: 20, lineSpacing: 4),
          ));
          widgets.add(pw.Container(
            margin: const pw.EdgeInsets.only(top: 6, bottom: 14),
            height: 1.2,
            width: 60,
            color: PdfColors.grey700,
          ));
          break;

        case BlockType.heading:
          widgets.add(pw.Container(
            margin: pw.EdgeInsets.only(left: indent, top: 10, bottom: 4),
            child: pw.Text(
              b.text,
              style: const pw.TextStyle(fontSize: 13.5),
            ),
          ));
          break;

        case BlockType.body:
          widgets.add(pw.Container(
            margin: pw.EdgeInsets.only(left: indent, bottom: 5),
            child: pw.Text(
              b.text,
              style: const pw.TextStyle(fontSize: 11, lineSpacing: 4),
            ),
          ));
          break;

        case BlockType.bullet:
          widgets.add(_line(indent, '·  ', b.text));
          break;

        case BlockType.ordered:
          final c = (counters[b.level] ?? 0) + 1;
          counters[b.level] = c;
          widgets.add(_line(indent, '$c.  ', b.text));
          break;

        case BlockType.todo:
          widgets.add(pw.Container(
            margin: pw.EdgeInsets.only(left: indent, bottom: 5),
            child: pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Container(
                  width: 9,
                  height: 9,
                  margin: const pw.EdgeInsets.only(top: 2, right: 6),
                  decoration: pw.BoxDecoration(
                    border: pw.Border.all(width: 0.8, color: PdfColors.grey700),
                  ),
                  child: b.checked
                      ? pw.Center(
                          child: pw.Text('✓',
                              style: const pw.TextStyle(fontSize: 7)),
                        )
                      : null,
                ),
                pw.Expanded(
                  child: pw.Text(
                    b.text,
                    style: pw.TextStyle(
                      fontSize: 11,
                      lineSpacing: 4,
                      decoration: b.checked ? pw.TextDecoration.lineThrough : null,
                    ),
                  ),
                ),
              ],
            ),
          ));
          break;

        case BlockType.quote:
          widgets.add(pw.Container(
            margin: pw.EdgeInsets.only(left: indent, bottom: 6),
            padding: const pw.EdgeInsets.only(left: 8),
            decoration: const pw.BoxDecoration(
              border: pw.Border(
                left: pw.BorderSide(width: 2, color: PdfColors.grey500),
              ),
            ),
            child: pw.Text(
              b.text,
              style: const pw.TextStyle(fontSize: 10.5, color: PdfColors.grey800),
            ),
          ));
          break;

        case BlockType.formula:
          widgets.add(pw.Container(
            margin: pw.EdgeInsets.only(left: indent, bottom: 6),
            child: pw.Text(
              b.text,
              style: const pw.TextStyle(fontSize: 11.5),
            ),
          ));
          break;
      }
    }
    return widgets;
  }

  pw.Widget _line(double indent, String prefix, String text) => pw.Container(
        margin: pw.EdgeInsets.only(left: indent, bottom: 5),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.SizedBox(width: 16, child: pw.Text(prefix,
                style: const pw.TextStyle(fontSize: 11))),
            pw.Expanded(
              child: pw.Text(text,
                  style: const pw.TextStyle(fontSize: 11, lineSpacing: 4)),
            ),
          ],
        ),
      );

  pw.Widget _watermark(String text, pw.Font font) => pw.Center(
        child: pw.Transform.rotate(
          angle: -math.pi / 6,
          child: pw.Opacity(
            opacity: 0.06,
            child: pw.Text(
              text,
              style: pw.TextStyle(font: font, fontSize: 56),
            ),
          ),
        ),
      );

  PdfPageFormat _format(PdfPageLayout layout) {
    switch (layout) {
      case PdfPageLayout.a4Landscape:
        return PdfPageFormat.a4.landscape;
      case PdfPageLayout.b5Portrait:
        return const PdfPageFormat(
          176 * PdfPageFormat.mm,
          250 * PdfPageFormat.mm,
        );
      case PdfPageLayout.a4Portrait:
        return PdfPageFormat.a4;
    }
  }

  String _dateText(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

class _PdfPageContent {
  final int sourceIndex;
  final List<NoteBlock> blocks;
  const _PdfPageContent({required this.sourceIndex, required this.blocks});
}
