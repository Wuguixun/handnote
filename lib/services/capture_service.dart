import 'dart:io';

import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// 拍照 / 相册多选 → 落到应用私有目录，返回按顺序排好的本地路径
/// 顺序即页序，用户可在确认页用拖拽重新排序
class CaptureService {
  final ImagePicker _picker = ImagePicker();
  final _uuid = const Uuid();

  /// 现场拍照，一次一张，连续拍构成多页
  Future<String?> takePhoto() async {
    final x = await _picker.pickImage(
      source: ImageSource.camera,
      preferredCameraDevice: CameraDevice.rear,
      imageQuality: 95, // 手写识别不要压缩太狠，掉笔画
      maxWidth: 3000,
    );
    if (x == null) return null;
    return _persist(x);
  }

  /// 相册多选，一次最多 9 张，返回的顺序与用户点选顺序一致
  Future<List<String>> pickFromGallery({int limit = 9}) async {
    final xs = await _picker.pickMultiImage(
      imageQuality: 95,
      maxWidth: 3000,
      limit: limit,
    );
    final paths = <String>[];
    for (final x in xs) {
      paths.add(await _persist(x));
    }
    return paths;
  }

  /// 把临时文件复制到私有目录，避免系统清理缓存后笔记图片丢失
  Future<String> _persist(XFile x) async {
    final dir = await getApplicationDocumentsDirectory();
    final rawDir = Directory(p.join(dir.path, 'pages', 'raw'));
    if (!rawDir.existsSync()) rawDir.createSync(recursive: true);
    final ext = p.extension(x.path).isEmpty ? '.jpg' : p.extension(x.path);
    final dst = p.join(rawDir.path, '${_uuid.v4()}$ext');
    await File(x.path).copy(dst);
    return dst;
  }
}
