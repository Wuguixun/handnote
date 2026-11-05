import 'dart:math' as math;

import '../models/models.dart';

/// 规则式智能排版：把 OCR 的散行还原成「标题 / 正文 / 列表 / 待办」结构。
///
/// 设计取舍：手写没有字体信息，靠视觉特征（行高、行左侧缩进、行首符号、
/// 行尾标点）判断结构，比训练一个版面模型快得多，也更容易被用户理解。
/// 判错的成本很低 —— 结果页允许用户点一下改块类型。
class LayoutService {
  static final _bullet = RegExp(r'^[\-\*•·▪●◦○]\s*');
  static final _ordered =
      RegExp(r'^(\d{1,2}\s*[\.、\)）]|[（(]\s*\d{1,2}\s*[)）]|[一二三四五六七八九十]+\s*[、\.])\s*');
  static final _todo = RegExp(r'^[□☐▢]\s*|^\[\s?\]\s*|^[√✔✓✗×]\s*');
  static final _quote = RegExp(r'^[>》」]\s*');
  static final _math = RegExp(r'[=≈≠<>≤≥∑∫√±∞π]');
  static final _titleEnd = RegExp(r'[。，,；;：:！!？?]$');

  List<NoteBlock> analyze(List<TextLine> lines) {
    if (lines.isEmpty) return const [];

    final rows = _clusterRows(lines);
    final medianH = _median(rows.map((r) => r.height).toList());

    // 页面最左的缩进作为基准，用于判断层级
    final minLeft = rows.map((r) => r.box.left).reduce(math.min);

    final blocks = <NoteBlock>[];
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      final text = row.text.trim();
      if (text.isEmpty) continue;

      final level = _indentLevel(row.box.left - minLeft);

      if (i == 0 && _looksLikeTitle(row, medianH)) {
        blocks.add(NoteBlock(
          type: BlockType.title,
          text: _stripTitleDecor(text),
          source: row.source,
        ));
        continue;
      }

      if (_todo.hasMatch(text)) {
        blocks.add(NoteBlock(
          type: BlockType.todo,
          text: text.replaceFirst(_todo, '').trim(),
          checked: text.trimLeft().startsWith('√') ||
              text.trimLeft().startsWith('✔') ||
              text.trimLeft().startsWith('✓'),
          level: level,
          source: row.source,
        ));
        continue;
      }

      if (_bullet.hasMatch(text)) {
        blocks.add(NoteBlock(
          type: BlockType.bullet,
          text: text.replaceFirst(_bullet, '').trim(),
          level: level,
          source: row.source,
        ));
        continue;
      }

      if (_ordered.hasMatch(text)) {
        blocks.add(NoteBlock(
          type: BlockType.ordered,
          text: text.replaceFirst(_ordered, '').trim(),
          level: level,
          source: row.source,
        ));
        continue;
      }

      if (_quote.hasMatch(text)) {
        blocks.add(NoteBlock(
          type: BlockType.quote,
          text: text.replaceFirst(_quote, '').trim(),
          level: level,
          source: row.source,
        ));
        continue;
      }

      // 手写公式：MVP 只做标记与保留原样，不重建 LaTeX（P2 再做）
      if (_math.hasMatch(text) && text.length <= 40 && !_hasCjk(text)) {
        blocks.add(NoteBlock(
          type: BlockType.formula,
          text: text,
          level: level,
          source: row.source,
        ));
        continue;
      }

      // 短行 + 无句末标点 + 比正文高 → 当小标题
      if (text.length <= 18 &&
          !_titleEnd.hasMatch(text) &&
          row.height > medianH * 1.25) {
        blocks.add(NoteBlock(
          type: BlockType.heading,
          text: text,
          level: level,
          source: row.source,
        ));
        continue;
      }

      blocks.add(NoteBlock(
        type: BlockType.body,
        text: text,
        level: level,
        source: row.source,
      ));
    }

    return blocks;
  }

  /// 把同一视觉行里的多个 OCR 片段合并（手写常被切成两三段）
  List<_Row> _clusterRows(List<TextLine> lines) {
    final sorted = lines.toList()
      ..sort((a, b) => a.box.center.dy.compareTo(b.box.center.dy));

    final rows = <_Row>[];
    for (final line in sorted) {
      final last = rows.isEmpty ? null : rows.last;
      final tol = math.max(line.box.height, last?.height ?? 0) * 0.6;
      if (last != null && (line.box.center.dy - last.centerY).abs() <= tol) {
        last.add(line);
      } else {
        rows.add(_Row(line));
      }
    }
    // 同一行内部按 x 拼回阅读顺序
    for (final r in rows) {
      r.fragments.sort((a, b) => a.box.left.compareTo(b.box.left));
    }
    return rows;
  }

  bool _looksLikeTitle(_Row row, double medianH) {
    final t = row.text.trim();
    if (t.length > 24) return false;
    if (_titleEnd.hasMatch(t) && t.length > 12) return false;
    final bigger = row.height > medianH * 1.2;
    final centered = (row.centerX - 0.5).abs() < 0.12;
    return bigger || centered || t.length <= 12;
  }

  String _stripTitleDecor(String s) =>
      s.replaceAll(RegExp(r'^[#\s]+'), '').trim();

  bool _hasCjk(String s) => RegExp(r'[\u4e00-\u9fa5]').hasMatch(s);

  /// 缩进层级：每 4% 页宽算一级，最多 3 级
  int _indentLevel(double dx) {
    if (dx <= 0) return 1;
    final level = 1 + (dx / 0.04).floor();
    return level.clamp(1, 3);
  }

  double _median(List<double> v) {
    if (v.isEmpty) return 1;
    final s = v..sort();
    return s[s.length ~/ 2];
  }
}

class _Row {
  final List<TextLine> fragments = [];
  _Row(TextLine first) {
    fragments.add(first);
  }

  void add(TextLine l) => fragments.add(l);
  double get height => fragments.map((e) => e.box.height).reduce(math.max);
  double get centerY =>
      fragments.map((e) => e.box.center.dy).reduce((a, b) => a + b) /
      fragments.length;
  double get centerX =>
      fragments.map((e) => e.box.center.dx).reduce(math.min);
  String get text => fragments.map((e) => e.text).join();
  List<TextLine> get source => fragments;
}
