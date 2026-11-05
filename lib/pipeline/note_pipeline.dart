import 'package:uuid/uuid.dart';

import '../data/app_database.dart';
import '../models/models.dart';
import 'capture_service.dart';
import 'layout_service.dart';
import 'ocr_service.dart';
import 'preprocess_service.dart';

enum PipelineStage { preprocessing, recognizing, layingOut, done }

typedef ProgressCallback = void Function(
  PipelineStage stage,
  int current,
  int total,
);

/// 主链路编排：拍/选图 → 预处理 → OCR → 排版 → 落库
/// 每一页独立处理，某一页失败不阻塞其余页，失败页保留原图供重试
class NotePipeline {
  final CaptureService _capture;
  final PreprocessService _preprocess;
  final OcrService _ocr;
  final LayoutService _layout;
  final AppDatabase _db;
  final _uuid = const Uuid();

  NotePipeline({
    CaptureService? capture,
    PreprocessService? preprocess,
    OcrService? ocr,
    LayoutService? layout,
    AppDatabase? db,
  })  : _capture = capture ?? CaptureService(),
        _preprocess = preprocess ?? PreprocessService(),
        _ocr = ocr ?? OcrService(),
        _layout = layout ?? LayoutService(),
        _db = db ?? AppDatabase.instance;

  Future<Note> run(
    List<String> rawPaths, {
    OcrEngine engine = OcrEngine.local,
    ProgressCallback? onProgress,
  }) async {
    final noteId = _uuid.v4();
    final note = Note(
      id: noteId,
      title: '未命名笔记',
      pages: [],
    );

    for (var i = 0; i < rawPaths.length; i++) {
      final raw = rawPaths[i];
      final page = NotePage(
        id: _uuid.v4(),
        noteId: noteId,
        order: i,
        imagePath: raw, // 预处理失败时先兜底用原图
        originalPath: raw,
      );

      try {
        onProgress?.call(PipelineStage.preprocessing, i + 1, rawPaths.length);
        final processed = await _preprocess.process(raw);
        page.imagePath = processed;

        onProgress?.call(PipelineStage.recognizing, i + 1, rawPaths.length);
        page.lines = await _ocr.recognizePage(processed, engine: engine);

        onProgress?.call(PipelineStage.layingOut, i + 1, rawPaths.length);
        page.blocks = _layout.analyze(page.lines);

        // 用首页第一块当默认标题，用户可在结果页改
        if (i == 0 && page.blocks.isNotEmpty) {
          note.title = page.blocks.first.text.trim();
          if (note.title.isEmpty) note.title = '未命名笔记';
        }
      } catch (_) {
        // 单页失败：保留原图 + 空识别结果，让用户手写录入或重试
        page.lines = const [];
        page.blocks = [];
      }

      note.pages.add(page);
    }

    await _db.saveNote(note);
    onProgress?.call(PipelineStage.done, rawPaths.length, rawPaths.length);
    return note;
  }

  /// 单页重试（换云端引擎再识别一次）
  Future<NotePage> retryPage(NotePage page, {OcrEngine engine = OcrEngine.cloud}) async {
    page.lines = await _ocr.recognizePage(page.imagePath, engine: engine);
    page.blocks = _layout.analyze(page.lines);
    return page;
  }

  /// 用户改完文字后重新排版并保存
  Future<Note> saveEdits(Note note) async {
    for (final page in note.pages) {
      // 编辑过的正文按行重新切分，再走一次规则排版
      page.blocks = page.blocks
          .map((b) {
            if (b.text.trim().isEmpty) return null;
            return NoteBlock(
              type: b.type,
              text: b.text.trim(),
              level: b.level,
              checked: b.checked,
              source: b.source,
            );
          })
          .whereType<NoteBlock>()
          .toList();
    }
    note.updatedAt = DateTime.now();
    await _db.saveNote(note);
    return note;
  }
}
