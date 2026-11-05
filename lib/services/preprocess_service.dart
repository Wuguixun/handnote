import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// 手写稿图像预处理流水线：
/// 等比缩放 → 灰度 → 边缘/轮廓找纸张四角 → 透视矫正 → 去阴影 → CLAHE 增强 → 去杂色
///
/// 说明：opencv_dart 的个别函数签名会随版本微调，集成时以 `dart doc` 为准；
/// 全部计算放在 Isolate 里跑，主线程只等结果，不会卡住拍照后的预览动画。
class PreprocessService {
  final _uuid = const Uuid();

  Future<String> process(String rawPath) async {
    final dir = await getApplicationDocumentsDirectory();
    final outDir = Directory(p.join(dir.path, 'pages', 'processed'));
    if (!outDir.existsSync()) outDir.createSync(recursive: true);
    final dst = p.join(outDir.path, '${_uuid.v4()}.jpg');

    // 重活丢到 Isolate，避免大图处理掉帧
    await Isolate.run(() => _processSync(rawPath, dst));
    return dst;
  }

  static void _processSync(String rawPath, String dstPath) {
    final src = cv.imread(rawPath);
    if (src.isEmpty) return;

    // 1) 长边限制到 2000px：再大对识别没收益，只增加耗时和内存
    const maxSide = 2000;
    final longSide = math.max(src.cols, src.rows);
    var work = src;
    if (longSide > maxSide) {
      final scale = maxSide / longSide.toDouble();
      final w = (src.cols * scale).round();
      final h = (src.rows * scale).round();
      work = cv.resize(src, (w, h), interpolation: cv.INTER_AREA);
    }

    // 2) 找纸张四边形并做透视矫正
    final corrected = _correctPerspective(work);

    // 3) 灰度 → 去阴影 → 对比度增强 → 二值化去杂色
    final gray = cv.cvtColor(corrected, cv.COLOR_BGR2GRAY);
    final flat = _removeShadow(gray);
    final enhanced = _enhance(flat);
    final cleaned = _denoise(enhanced);

    // 4) 写回磁盘（保留灰度增强结果，识别引擎直接吃这张）
    cv.imwrite(dstPath, cleaned);
    src.dispose();
    work.dispose();
    gray.dispose();
    flat.dispose();
    enhanced.dispose();
    cleaned.dispose();
  }

  /// 纸张四角检测 + 透视矫正。找不到四点就原样返回（例如贴边拍摄）
  static cv.Mat _correctPerspective(cv.Mat src) {
    final gray = cv.cvtColor(src, cv.COLOR_BGR2GRAY);
    final blurred = cv.gaussianBlur(gray, (5, 5), 0);
    final edges = cv.canny(blurred, 50, 150);

    final (contours, _) = cv.findContours(
      edges,
      cv.RETR_EXTERNAL,
      cv.CHAIN_APPROX_SIMPLE,
    );

    final imgArea = src.cols * src.rows;
    cv.VecPoint? best;
    double bestArea = 0;

    for (final c in contours) {
      final area = cv.contourArea(c);
      if (area < imgArea * 0.25) continue; // 太小，肯定不是纸
      final peri = cv.arcLength(c, true);
      final approx = cv.approxPolyDP(c, 0.02 * peri, true);
      if (approx.length == 4 && area > bestArea) {
        best = approx;
        bestArea = area;
      }
    }

    if (best == null) {
      gray.dispose();
      blurred.dispose();
      edges.dispose();
      return src;
    }

    // 四点按 左上→右上→右下→左下 排序后映射到矩形
    final pts = _orderCorners(best);
    final wTop = _dist(pts[0], pts[1]);
    final wBottom = _dist(pts[3], pts[2]);
    final hLeft = _dist(pts[0], pts[3]);
    final hRight = _dist(pts[1], pts[2]);
    final outW = math.max(wTop, wBottom).round().clamp(1, 4000);
    final outH = math.max(hLeft, hRight).round().clamp(1, 4000);

    final srcPts = cv.VecPoint2f.fromList([
      cv.Point2f(pts[0].x, pts[0].y),
      cv.Point2f(pts[1].x, pts[1].y),
      cv.Point2f(pts[2].x, pts[2].y),
      cv.Point2f(pts[3].x, pts[3].y),
    ]);
    final dstPts = cv.VecPoint2f.fromList([
      cv.Point2f(0, 0),
      cv.Point2f(outW.toDouble(), 0),
      cv.Point2f(outW.toDouble(), outH.toDouble()),
      cv.Point2f(0, outH.toDouble()),
    ]);

    final m = cv.getPerspectiveTransform(srcPts, dstPts);
    final warped = cv.warpPerspective(src, m, (outW, outH));

    gray.dispose();
    blurred.dispose();
    edges.dispose();
    m.dispose();
    return warped;
  }

  /// 去阴影：用大核高斯估计光照背景，原图除以背景 → 光照被归一化
  /// 这一步对"手机影子压在纸上"的拍摄场景提升非常明显
  static cv.Mat _removeShadow(cv.Mat gray) {
    final bg = cv.gaussianBlur(gray, (0, 0), 15);
    final norm = cv.divide(gray, bg, scale: 255);
    bg.dispose();
    return norm;
  }

  /// CLAHE 局部自适应对比度增强：笔画深浅不一的本子也能拉出笔迹
  static cv.Mat _enhance(cv.Mat gray) {
    final clahe = cv.createCLAHE(clipLimit: 2.0, tileGridSize: (8, 8));
    return clahe.apply(gray);
  }

  /// 中值滤波去颗粒，再自适应阈值二值化，最后轻微开运算去掉孤立噪点
  static cv.Mat _denoise(cv.Mat gray) {
    final med = cv.medianBlur(gray, 3);
    final (_, bin) = cv.threshold(
      med, 0, 255, cv.THRESH_BINARY | cv.THRESH_OTSU,
    );
    final kernel = cv.getStructuringElement(cv.MORPH_RECT, (2, 2));
    final opened = cv.morphologyEx(bin, cv.MORPH_OPEN, kernel);
    med.dispose();
    bin.dispose();
    kernel.dispose();
    return opened;
  }

  static double _dist(cv.Point a, cv.Point b) {
    final dx = a.x - b.x;
    final dy = a.y - b.y;
    return math.sqrt(dx * dx + dy * dy);
  }

  /// 把四个角排成 左上、右上、右下、左下
  static List<cv.Point> _orderCorners(cv.VecPoint pts) {
    final sorted = pts.toList()..sort((a, b) => (a.x + a.y).compareTo(b.x + b.y));
    final tl = sorted.first;
    final br = sorted.last;
    final rest = pts.toList()..sort((a, b) => (a.x - a.y).compareTo(b.x - b.y));
    final tr = rest.last;
    final bl = rest.first;
    return [tl, tr, br, bl];
  }
}
