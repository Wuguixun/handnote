import 'dart:io';

import 'package:flutter/material.dart';

import '../data/app_database.dart';
import '../models/models.dart';
import '../pipeline/note_pipeline.dart';
import 'export_sheet.dart';

/// 校对 + 排版调整页：
/// 上面的缩略图是"原图对照"，下面每个块都可直接改字、改类型；
/// 永远允许用户手动修改 —— 不追求 100% 自动。
class ReviewPage extends StatefulWidget {
  final Note note;
  const ReviewPage({super.key, required this.note});

  @override
  State<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends State<ReviewPage> {
  late Note _note;
  int _pageIndex = 0;
  bool _showImage = true;

  @override
  void initState() {
    super.initState();
    _note = widget.note;
  }

  NotePage get _page => _note.pages[_pageIndex];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_note.title,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
        actions: [
          IconButton(
            tooltip: '对照原图',
            icon: Icon(_showImage
                ? Icons.image_outlined
                : Icons.image_not_supported_outlined),
            onPressed: () => setState(() => _showImage = !_showImage),
          ),
          IconButton(
            icon: const Icon(Icons.ios_share),
            onPressed: () => showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              builder: (_) => ExportSheet(note: _note),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // 多页切换（一页一段，不混排）
          if (_note.pages.length > 1)
            SizedBox(
              height: 40,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: _note.pages.length,
                itemBuilder: (_, i) => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
                  child: ChoiceChip(
                    label: Text('第 ${i + 1} 页'),
                    selected: i == _pageIndex,
                    onSelected: (_) => setState(() => _pageIndex = i),
                  ),
                ),
              ),
            ),
          if (_showImage)
            Container(
              height: 180,
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              color: Colors.black12,
              child: InteractiveViewer(
                maxScale: 4,
                child: Image.file(File(_page.imagePath), fit: BoxFit.contain),
              ),
            ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
              itemCount: _page.blocks.length + 1,
              itemBuilder: (_, i) {
                if (i == _page.blocks.length) {
                  return TextButton.icon(
                    onPressed: _addBlock,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('补一行'),
                  );
                }
                final b = _page.blocks[i];
                return _EditableBlock(
                  block: b,
                  onChanged: (v) => setState(() => b.text = v),
                  onTypeChanged: (t) => setState(() => b.type = t),
                  onDelete: () => setState(() => _page.blocks.removeAt(i)),
                );
              },
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _save,
                  child: const Text('保存笔记'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: () => showModalBottomSheet(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => ExportSheet(note: _note),
                  ),
                  child: const Text('导出 PDF'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _addBlock() {
    setState(() {
      _page.blocks.add(NoteBlock(type: BlockType.body, text: ''));
    });
  }

  Future<void> _save() async {
    await NotePipeline().saveEdits(_note);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已保存'), duration: Duration(seconds: 1)),
      );
    }
  }
}

class _EditableBlock extends StatelessWidget {
  final NoteBlock block;
  final ValueChanged<String> onChanged;
  final ValueChanged<BlockType> onTypeChanged;
  final VoidCallback onDelete;

  const _EditableBlock({
    required this.block,
    required this.onChanged,
    required this.onTypeChanged,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final label = switch (block.type) {
      BlockType.title => '标题',
      BlockType.heading => '小标题',
      BlockType.body => '正文',
      BlockType.bullet => '列表',
      BlockType.ordered => '有序',
      BlockType.todo => '待办',
      BlockType.quote => '引用',
      BlockType.formula => '公式',
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PopupMenuButton<BlockType>(
            tooltip: '改块类型',
            initialValue: block.type,
            onSelected: onTypeChanged,
            itemBuilder: (_) => BlockType.values
                .map((t) => PopupMenuItem(value: t, child: Text(t.name)))
                .toList(),
            child: Container(
              width: 46,
              padding: const EdgeInsets.symmetric(vertical: 8),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: const Color(0xFFEDEBE6),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(label,
                  style: const TextStyle(fontSize: 11, color: Color(0xFF7A7A7A))),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextFormField(
              initialValue: block.text,
              maxLines: null,
              onChanged: onChanged,
              style: TextStyle(
                fontSize: block.type == BlockType.title ? 17 : 14,
                fontWeight: block.type == BlockType.title
                    ? FontWeight.w600
                    : FontWeight.w400,
              ),
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: '识别为空的这一行，可以自己补写',
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 16, color: Color(0xFFB0B0B0)),
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}
