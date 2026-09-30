/// youyuan 后端的 API 客户端，只做翻译（跟后端 `server.py` 一个分工）。
/// **采样、配额、池子这些规则全在后端**，客户端不重实现一遍。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'log.dart';
import 'models.dart';

/// 请求后端失败。message 是可以直接显示给人看的中文。
class ApiException implements Exception {
  ApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

class Api {
  Api(this.baseUrl);

  /// 形如 `http://127.0.0.1:8000`。末尾多余的斜杠会被去掉。
  final String baseUrl;

  static const _timeout = Duration(seconds: 30);

  String get _base =>
      baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;

  Future<List<Channel>> channels() async {
    final data = await _get('/api/channels') as List;
    return data.map((e) => Channel.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Settings> settings() async =>
      Settings.fromJson(await _get('/api/settings') as Map<String, dynamic>);

  /// 局部更新 —— 只传要改的键，别的原样不动。
  Future<Settings> updateSettings(Map<String, dynamic> patch) async =>
      Settings.fromJson(
          await _send('PUT', '/api/settings', patch) as Map<String, dynamic>);

  /// 取一轮内容。首次加载和「换一换」都是它。
  ///
  /// **会改后端状态**：返回的内容进已展示记录，12 小时内不再出现。
  Future<Feed> feed({int? n}) async {
    final data = await _get('/api/feed', n == null ? null : {'n': '$n'})
        as Map<String, dynamic>;
    return Feed.fromJson(data);
  }

  /// 视频详情。**播放前必须先调它换 cid** —— 池子里的条目没有 cid。
  Future<VideoDetail> video(String bvid, {int p = 1}) async {
    final data = await _get('/api/video/$bvid', p == 1 ? null : {'p': '$p'})
        as Map<String, dynamic>;
    return VideoDetail.fromJson(data);
  }

  Future<Map<String, dynamic>> poolStatus() async =>
      await _get('/api/pool/status') as Map<String, dynamic>;

  /// 手动触发一次池子刷新。调试用。
  Future<Map<String, dynamic>> refreshPool() async =>
      await _send('POST', '/api/pool/refresh', null) as Map<String, dynamic>;

  // ---------- 内部 ----------

  Future<dynamic> _get(String path, [Map<String, String>? query]) async {
    var uri = Uri.parse('$_base$path');
    if (query != null) uri = uri.replace(queryParameters: query);
    return _decode(await _request('GET $path', () => http.get(uri)));
  }

  Future<dynamic> _send(String method, String path, Object? body) async {
    final uri = Uri.parse('$_base$path');
    final request = http.Request(method, uri)
      ..headers['content-type'] = 'application/json'
      ..body = body == null ? '' : jsonEncode(body);
    // 注意是 client.send(request)，不是 http.send —— 后者不存在，
    // send 是 Client 的方法，package:http 只把 get/post 这些做成了顶层函数
    return _decode(await _request('$method $path',
        () => http.Client().send(request).then(
              (streamed) => http.Response.fromStream(streamed),
            )));
  }

  /// label 只进日志用（形如 "→ GET /api/feed"）。
  Future<http.Response> _request(
      String label, Future<http.Response> Function() send) async {
    if (_base.isEmpty) {
      ylog('api', '✗ $label：还没设后端地址');
      throw ApiException('还没设后端地址。去设置页填一个，比如 http://127.0.0.1:8000');
    }
    final sw = Stopwatch()..start();
    ylog('api', '→ $label');
    try {
      final res = await send().timeout(_timeout);
      ylog('api', '← $label ${res.statusCode} ${res.bodyBytes.length}B '
          '${sw.elapsedMilliseconds}ms');
      return res;
    } on SocketException catch (e) {
      // 四种失败都记日志：界面只给一句人话，日志要留下是哪一种
      ylog('api', '✗ $label 连不上（${sw.elapsedMilliseconds}ms）：'
          '${e.osError?.message ?? e.message}');
      throw ApiException('连不上后端 $_base\n${e.osError?.message ?? e.message}');
    } on http.ClientException catch (e) {
      ylog('api', '✗ $label 请求失败（${sw.elapsedMilliseconds}ms）：${e.message}');
      throw ApiException('请求 $_base 失败：${e.message}');
    } on TimeoutException {
      ylog('api', '✗ $label 超时（${sw.elapsedMilliseconds}ms）');
      throw ApiException('后端 $_base 超过 ${_timeout.inSeconds} 秒没响应');
    }
  }

  /// 解析响应。**非 2xx 一律抛异常**并把后端的 detail 带出来 —— 宁可报错
  /// 也不要错值，别让界面拿到半截的结果。
  dynamic _decode(http.Response res) {
    final text = utf8.decode(res.bodyBytes);
    if (res.statusCode >= 400) {
      String detail = text;
      try {
        final decoded = jsonDecode(text);
        if (decoded is Map && decoded['detail'] != null) {
          detail = '${decoded['detail']}';
        }
      } catch (_) {
        // 不是 JSON 就直接用原文
      }
      throw ApiException('后端返回 ${res.statusCode}：$detail');
    }
    try {
      return jsonDecode(text);
    } catch (e) {
      throw ApiException('后端返回的不是 JSON：${text.substring(0, text.length.clamp(0, 120))}');
    }
  }
}
