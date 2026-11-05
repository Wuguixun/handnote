import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/models.dart';

/// 本地笔记库。所有数据都在设备上，不上传服务器 —— 隐私优先的默认设计
class AppDatabase {
  AppDatabase._();
  static final AppDatabase instance = AppDatabase._();
  Database? _db;

  Future<Database> get db async {
    if (_db != null) return _db!;
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'handnote.db');
    _db = await openDatabase(
      path,
      version: 1,
      onCreate: _onCreate,
    );
    return _db!;
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE notes(
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        category TEXT,
        tags TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        voice_path TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE pages(
        id TEXT PRIMARY KEY,
        note_id TEXT NOT NULL,
        page_order INTEGER NOT NULL,
        image_path TEXT NOT NULL,
        original_path TEXT,
        lines_json TEXT NOT NULL,
        blocks_json TEXT NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX idx_pages_note ON pages(note_id, page_order)');
    // 检索用索引表：正文拼成一段落进 body，MVP 阶段用 LIKE 匹配，
    // 笔记量上万后再迁移到 FTS5(trigram) 虚拟表
    await db.execute('''
      CREATE TABLE search_index(
        note_id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        body TEXT NOT NULL
      )
    ''');
  }

  // ---------------------------------------------------------------- 笔记读写

  Future<void> saveNote(Note note) async {
    final d = await db;
    await d.transaction((txn) async {
      await txn.insert(
        'notes',
        {
          'id': note.id,
          'title': note.title,
          'category': note.category,
          'tags': note.tags.join(','),
          'created_at': note.createdAt.millisecondsSinceEpoch,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
          'voice_path': note.voiceNotePath,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      await txn.delete('pages', where: 'note_id = ?', whereArgs: [note.id]);
      for (final page in note.pages) {
        await txn.insert('pages', {
          'id': page.id,
          'note_id': note.id,
          'page_order': page.order,
          'image_path': page.imagePath,
          'original_path': page.originalPath,
          'lines_json': jsonEncode(page.lines.map((e) => e.toJson()).toList()),
          'blocks_json': jsonEncode(page.blocks.map((e) => e.toJson()).toList()),
        });
      }

      await txn.insert(
        'search_index',
        {
          'note_id': note.id,
          'title': note.title,
          'body': note.searchBody,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  Future<Note?> loadNote(String id) async {
    final d = await db;
    final rows = await d.query('notes', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    final n = rows.first;

    final pageRows = await d.query(
      'pages',
      where: 'note_id = ?',
      whereArgs: [id],
      orderBy: 'page_order ASC',
    );

    return Note(
      id: n['id'] as String,
      title: n['title'] as String,
      category: n['category'] as String?,
      tags: (n['tags'] as String?)?.isEmpty ?? true
          ? <String>[]
          : (n['tags'] as String).split(','),
      createdAt: DateTime.fromMillisecondsSinceEpoch(n['created_at'] as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(n['updated_at'] as int),
      voiceNotePath: n['voice_path'] as String?,
      pages: pageRows
          .map((r) => NotePage(
                id: r['id'] as String,
                noteId: r['note_id'] as String,
                order: r['page_order'] as int,
                imagePath: r['image_path'] as String,
                originalPath: r['original_path'] as String?,
                lines: (jsonDecode(r['lines_json'] as String) as List)
                    .map((e) => TextLine.fromJson(e as Map<String, dynamic>))
                    .toList(),
                blocks: (jsonDecode(r['blocks_json'] as String) as List)
                    .map((e) => NoteBlock.fromJson(e as Map<String, dynamic>))
                    .toList(),
              ))
          .toList(),
    );
  }

  Future<List<Note>> listNotes({
    String? category,
    String? tag,
    int limit = 100,
  }) async {
    final d = await db;
    final where = <String>[];
    final args = <Object?>[];
    if (category != null && category.isNotEmpty) {
      where.add('category = ?');
      args.add(category);
    }
    final rows = await d.query(
      'notes',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'updated_at DESC',
      limit: limit,
    );
    final notes = <Note>[];
    for (final r in rows) {
      final note = await loadNote(r['id'] as String);
      if (note == null) continue;
      if (tag != null && tag.isNotEmpty && !note.tags.contains(tag)) continue;
      notes.add(note);
    }
    return notes;
  }

  /// 全文检索：先搜标题和正文（LIKE，覆盖中文短词足够快）
  Future<List<String>> search(String keyword) async {
    final q = keyword.trim();
    if (q.isEmpty) return [];
    final d = await db;
    final rows = await d.query(
      'search_index',
      where: 'title LIKE ? OR body LIKE ?',
      whereArgs: ['%$q%', '%$q%'],
      limit: 200,
    );
    return rows.map((e) => e['note_id'] as String).toList();
  }

  Future<void> deleteNote(String id) async {
    final d = await db;
    await d.delete('notes', where: 'id = ?', whereArgs: [id]);
    await d.delete('pages', where: 'note_id = ?', whereArgs: [id]);
    await d.delete('search_index', where: 'note_id = ?', whereArgs: [id]);
  }

  Future<void> close() async => _db?.close();
}
