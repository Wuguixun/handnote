import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/app_database.dart';
import 'models/models.dart';
import 'pages/export_sheet.dart';
import 'pages/review_page.dart';
import 'pipeline/note_pipeline.dart';
import 'services/capture_service.dart';
import 'services/ocr_service.dart';
import 'services/pdf_service.dart';

void main() {
  runApp(const ProviderScope(child: HandNoteApp()));
}

class HandNoteApp extends StatelessWidget {
  const HandNoteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '我的手写笔记',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2F6B5E),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF7F6F3),
        appBarTheme: const AppBarTheme(elevation: 0, centerTitle: false),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  List<Note> _notes = const [];
  final _searchCtrl = TextEditingController();
  String _keyword = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = AppDatabase.instance;
    List<Note> list;
    if (_keyword.isEmpty) {
      list = await db.listNotes();
    } else {
      final ids = await db.search(_keyword);
      list = [];
      for (final id in ids) {
        final n = await db.loadNote(id);
        if (n != null) list.add(n);
      }
    }
    if (mounted) setState(() => _notes = list);
  }

  Future<void> _startCapture() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('拍照记一页'),
              onTap: () => Navigator.pop(context, 'camera'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('相册多选'),
              onTap: () => Navigator.pop(context, 'gallery'),
            ),
          ],
        ),
      ),
    );
    if (action == null) return;

    final capture = CaptureService();
    final paths = <String>[];
    if (action == 'camera') {
      final path = await capture.takePhoto();
      if (path != null) paths.add(path);
    } else {
      paths.addAll(await capture.pickFromGallery());
    }
    if (paths.isEmpty || !mounted) return;

    final note = await showDialog<Note>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ProcessingDialog(paths: paths),
    );
    if (note != null && mounted) {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => ReviewPage(note: note)),
      );
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('我的手写笔记',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: '搜索笔记里的文字',
                prefixIcon: const Icon(Icons.search, size: 20),
                filled: true,
                fillColor: Colors.white,
                contentPadding: const EdgeInsets.symmetric(vertical: 4),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
              onSubmitted: (v) {
                setState(() => _keyword = v.trim());
                _load();
              },
            ),
          ),
          Expanded(
            child: _notes.isEmpty
                ? const _EmptyState()
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
                    itemCount: _notes.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (_, i) {
                      final n = _notes[i];
                      return _NoteCard(note: n, onTap: () async {
                        await Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => ReviewPage(note: n)),
                        );
                        _load();
                      });
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _startCapture,
        icon: const Icon(Icons.add_a_photo_outlined),
        label: const Text('新建笔记'),
      ),
    );
  }
}

class _NoteCard extends StatelessWidget {
  final Note note;
  final VoidCallback onTap;

  const _NoteCard({required this.note, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 56,
                  height: 74,
                  child: note.pages.isEmpty
                      ? const ColoredBox(color: Color(0xFFEDEBE6))
                      : Image.file(File(note.pages.first.imagePath),
                          fit: BoxFit.cover),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(note.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Text(
                      note.searchBody.replaceAll('\n', ' ').trim(),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12, color: Color(0xFF6B6B6B), height: 1.4),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Text('${note.pages.length} 页',
                            style: const TextStyle(
                                fontSize: 11, color: Color(0xFF9A9A9A))),
                        if (note.category != null) ...[
                          const SizedBox(width: 8),
                          _Chip(text: note.category!),
                        ],
                        for (final t in note.tags.take(2)) ...[
                          const SizedBox(width: 6),
                          _Chip(text: '#$t'),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String text;
  const _Chip({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFFEFF2F0),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(text,
          style: const TextStyle(fontSize: 10, color: Color(0xFF5A6B63))),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.edit_note, size: 56, color: Color(0xFFBDBDBD)),
          const SizedBox(height: 12),
          const Text('拍下一页手写笔记，自动变成清晰的 PDF',
              style: TextStyle(color: Color(0xFF8A8A8A), fontSize: 13)),
          const SizedBox(height: 6),
          const Text('支持相册多选，按顺序合成一份笔记',
              style: TextStyle(color: Color(0xFFB0B0B0), fontSize: 12)),
        ],
      ),
    );
  }
}

/// 处理中的全屏进度，跑完主链路后返回 Note
class _ProcessingDialog extends StatefulWidget {
  final List<String> paths;
  const _ProcessingDialog({required this.paths});

  @override
  State<_ProcessingDialog> createState() => _ProcessingDialogState();
}

class _ProcessingDialogState extends State<_ProcessingDialog> {
  double _progress = 0;
  String _label = '正在裁边、去阴影…';

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final note = await NotePipeline().run(
      widget.paths,
      onProgress: (stage, cur, total) {
        if (!mounted) return;
        setState(() {
          _progress = (cur / total).clamp(0, 1);
          _label = switch (stage) {
            PipelineStage.preprocessing => '正在裁边、去阴影…',
            PipelineStage.recognizing => '正在识别手写文字…',
            PipelineStage.layingOut => '正在整理排版…',
            PipelineStage.done => '完成',
          };
        });
      },
    );
    if (mounted) Navigator.pop(context, note);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_label, style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 16),
          LinearProgressIndicator(value: _progress),
        ],
      ),
    );
  }
}
