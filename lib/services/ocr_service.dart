import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../models/models.dart';

enum OcrEngine {
  /// 设备本地 PaddleOCR（默认，离线、免费、隐私不出设备）
  local,

  /// 云端手写 OCR（准确率更高，要联网，按次计费）
  cloud,
}

class CloudOcrConfig {
  final String apiKey;
  final String secretKey;
  final String endpoint; // 换供应商只改这里

  const CloudOcrConfig({
    required this.apiKey,
    required this.secretKey,
    this.endpoint = 'https://aip.baidubce.com/rest/2.0/ocr/v1/handwriting',
  });
}

/// OCR 统一入口。上层只调 [recognizePage]，换引擎、换供应商都不影响业务代码
class OcrService {
  static const MethodChannel _channel = MethodChannel('handnote/ocr');
  final CloudOcrConfig? cloud;
  String? _accessToken;

  OcrService({this.cloud});

  Future<List<TextLine>> recognizePage(
    String imagePath, {
    OcrEngine engine = OcrEngine.local,
  }) async {
    if (engine == OcrEngine.cloud && cloud != null) {
      return _recognizeByCloud(imagePath);
    }
    return _recognizeByLocal(imagePath);
  }

  // ------------------------------------------------------------ 本地 PaddleOCR

  /// 原生侧加载 PP-OCRv5 mobile 的 det + cls + rec 模型，
  /// 返回 [{text, confidence, x, y, w, h}]（像素坐标，这里统一归一化）
  Future<List<TextLine>> _recognizeByLocal(String imagePath) async {
    final raw = await _channel.invokeListMethod<Map<Object?, Object?>>(
      'recognize',
      {'path': imagePath, 'language': 'ch'},
    );
    if (raw == null || raw.isEmpty) return [];

    final bytes = await File(imagePath).readAsBytes();
    final size = await _imageSize(bytes);

    final lines = <TextLine>[];
    for (var i = 0; i < raw.length; i++) {
      final m = raw[i];
      final text = (m['text'] as String? ?? '').trim();
      if (text.isEmpty) continue;
      final x = (m['x'] as num).toDouble();
      final y = (m['y'] as num).toDouble();
      final w = (m['w'] as num).toDouble();
      final h = (m['h'] as num).toDouble();
      lines.add(TextLine(
        text: text,
        confidence: (m['confidence'] as num?)?.toDouble() ?? 0.0,
        box: Rect.fromLTWH(x / size.$1, y / size.$2, w / size.$1, h / size.$2),
        lineNo: i,
      ));
    }
    return lines;
  }

  // -------------------------------------------------------------- 云端兜底

  Future<String> _ensureToken() async {
    if (_accessToken != null) return _accessToken!;
    final cfg = cloud!;
    final uri = Uri.parse(
      'https://aip.baidubce.com/oauth/2.0/token?grant_type=client_credentials'
      '&client_id=${cfg.apiKey}&client_secret=${cfg.secretKey}',
    );
    final resp = await http.post(uri);
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    _accessToken = json['access_token'] as String;
    return _accessToken!;
  }

  Future<List<TextLine>> _recognizeByCloud(String imagePath) async {
    final token = await _ensureToken();
    final bytes = await File(imagePath).readAsBytes();
    final size = await _imageSize(bytes);

    final resp = await http.post(
      Uri.parse('${cloud!.endpoint}?access_token=$token'),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'image': base64Encode(bytes),
        'recognize_granularity': 'big', // 按行返回，坐标更稳
        'language_type': 'CHN_ENG',
      },
    );

    final json = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    if (json['error_code'] != null) {
      throw OcrException('云端识别失败：${json['error_msg']}');
    }

    final list = (json['words_result'] as List).cast<dynamic>();
    final lines = <TextLine>[];
    for (var i = 0; i < list.length; i++) {
      final map = list[i] as Map<String, dynamic>;
      final loc = (map['location'] as Map<String, dynamic>?) ?? const {};
      final x = (loc['left'] as num?)?.toDouble() ?? 0;
      final y = (loc['top'] as num?)?.toDouble() ?? 0;
      final w = (loc['width'] as num?)?.toDouble() ?? size.$1;
      final h = (loc['height'] as num?)?.toDouble() ?? 40;
      final text = (map['words'] as String? ?? '').trim();
      if (text.isEmpty) continue;
      lines.add(TextLine(
        text: text,
        confidence: 0.95,
        box: Rect.fromLTWH(x / size.$1, y / size.$2, w / size.$1, h / size.$2),
        lineNo: i,
      ));
    }
    return lines;
  }

  /// 只解码图片头取宽高，不做整图像素处理
  static Future<(double, double)> _imageSize(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final w = frame.image.width.toDouble();
    final h = frame.image.height.toDouble();
    frame.image.dispose();
    codec.dispose();
    return (w, h);
  }
}

class OcrException implements Exception {
  final String message;
  OcrException(this.message);
  @override
  String toString() => 'OcrException: $message';
}
