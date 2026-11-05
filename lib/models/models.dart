import 'dart:ui' show Rect;

/// 排版块类型：标题 / 小标题 / 正文 / 无序列表 / 有序列表 / 待办 / 引用 / 公式
enum BlockType { title, heading, body, bullet, ordered, todo, quote, formula }

/// OCR 输出的最小单元：一行文字 + 置信度 + 在原图中的归一化坐标框
/// 坐标统一归一化到 0..1，换机型、换分辨率都不用重新换算
class TextLine {
  final String text;
  final double confidence;
  final Rect box; // 归一化坐标
  final int lineNo;

  const TextLine({
    required this.text,
    required this.confidence,
    required this.box,
    this.lineNo = 0,
  });

  double get centerY => box.center.dy;
  double get height => box.height;

  TextLine copyWith({String? text, double? confidence}) => TextLine(
        text: text ?? this.text,
        confidence: confidence ?? this.confidence,
        box: box,
        lineNo: lineNo,
      );

  Map<String, dynamic> toJson() => {
        'text': text,
        'confidence': confidence,
        'l': box.left,
        't': box.top,
        'r': box.right,
        'b': box.bottom,
        'n': lineNo,
      };

  factory TextLine.fromJson(Map<String, dynamic> j) => TextLine(
        text: j['text'] as String,
        confidence: (j['confidence'] as num).toDouble(),
        box: Rect.fromLTRB(
          (j['l'] as num).toDouble(),
          (j['t'] as num).toDouble(),
          (j['r'] as num).toDouble(),
          (j['b'] as num).toDouble(),
        ),
        lineNo: (j['n'] as int?) ?? 0,
      );
}

/// 排版后的一个语义块。source 保留原始行，用户改字时可回跳到原图位置
class NoteBlock {
  BlockType type;
  int level;
  String text;
  bool checked;
  final List<TextLine> source;

  NoteBlock({
    required this.type,
    required this.text,
    this.level = 1,
    this.checked = false,
    this.source = const [],
  });

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'level': level,
        'text': text,
        'checked': checked,
      };

  factory NoteBlock.fromJson(Map<String, dynamic> j) => NoteBlock(
        type: BlockType.values.firstWhere(
          (e) => e.name == j['type'],
          orElse: () => BlockType.body,
        ),
        level: (j['level'] as int?) ?? 1,
        text: j['text'] as String,
        checked: (j['checked'] as bool?) ?? false,
      );
}

/// 一页手写稿。MVP 里"一页手写 = 一页 PDF"，跨页断行不会错乱
class NotePage {
  final String id;
  String noteId;
  int order;
  String imagePath; // 预处理后的图
  String? originalPath; // 原图，导出时可选择保留
  List<TextLine> lines;
  List<NoteBlock> blocks;

  NotePage({
    required this.id,
    required this.noteId,
    required this.order,
    required this.imagePath,
    this.originalPath,
    List<TextLine>? lines,
    List<NoteBlock>? blocks,
  })  : lines = lines ?? <TextLine>[],
        blocks = blocks ?? <NoteBlock>[];

  /// 页面被 OCR 识别后立刻落库的纯文本，供笔记库全文检索
  String get plainText => blocks.isEmpty
      ? lines.map((e) => e.text).join('\n')
      : blocks.map((b) => b.text).join('\n');
}

/// 一篇笔记（多页组成）
class Note {
  final String id;
  String title;
  String? category; // 科目 / 项目
  List<String> tags;
  DateTime createdAt;
  DateTime updatedAt;
  List<NotePage> pages;
  String? voiceNotePath; // P1：贴在首页的语音备注

  Note({
    required this.id,
    required this.title,
    this.category,
    List<String>? tags,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<NotePage>? pages,
    this.voiceNotePath,
  })  : tags = tags ?? <String>[],
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now(),
        pages = pages ?? <NotePage>[];

  String get searchBody => pages.map((e) => e.plainText).join('\n');
}

/// 导出参数。UI 上就是导出面板那几个开关
class ExportOptions {
  final PdfPageLayout layout;
  final double marginMm;
  final bool keepOriginalImage;
  final bool withWatermark;
  final bool withPageNumber;
  final bool withDateHeader;
  final String? watermarkText;

  const ExportOptions({
    this.layout = PdfPageLayout.a4Portrait,
    this.marginMm = 18,
    this.keepOriginalImage = false,
    this.withWatermark = false,
    this.withPageNumber = true,
    this.withDateHeader = true,
    this.watermarkText = '我的手写笔记',
  });

  ExportOptions copyWith({
    PdfPageLayout? layout,
    double? marginMm,
    bool? keepOriginalImage,
    bool? withWatermark,
    bool? withPageNumber,
    bool? withDateHeader,
    String? watermarkText,
  }) =>
      ExportOptions(
        layout: layout ?? this.layout,
        marginMm: marginMm ?? this.marginMm,
        keepOriginalImage: keepOriginalImage ?? this.keepOriginalImage,
        withWatermark: withWatermark ?? this.withWatermark,
        withPageNumber: withPageNumber ?? this.withPageNumber,
        withDateHeader: withDateHeader ?? this.withDateHeader,
        watermarkText: watermarkText ?? this.watermarkText,
      );
}

enum PdfPageLayout { a4Portrait, a4Landscape, b5Portrait }
