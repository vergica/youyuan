/// 客户端**直连 B 站**拿播放地址 —— 视频流不经过 youyuan 后端，这样后端带宽
/// 为零，且客户端拿到的是离自己最近的 CDN 节点（CLAUDE.md「整体设计」）。
///
/// ⚠️ 这里的规则跟后端 `bilibili.py` 的 `parse_play_info` 是**同一套逻辑的
/// 第二份实现**（排序、风控校验、fnval 位掩码）。改一边要想着另一边。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

/// B 站接口要的请求头，三样缺一不可（CLAUDE.md 坑 4）。
///
/// **下载流也要用同一套** —— 主 CDN 不带 Referer 会 403（坑 8）。media_kit
/// 会把它设成 mpv 的全局 `http-header-fields`，所以 `audio-add` 时自动带上。
const bilibiliHeaders = <String, String>{
  'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36',
  'Referer': 'https://www.bilibili.com/',
  'Origin': 'https://www.bilibili.com',
  'Accept': '*/*',
};

/// fnval 位掩码，4048 = 全都要（坑 6）：16 DASH | 64 HDR | 128 4K |
/// 256 杜比音频 | 512 杜比视界 | 1024 8K | 2048 AV1。
///
/// **不给它只会返回老格式 durl**，而未登录时 durl 只给 360P、dash 给到 480P。
const _fnval = 4048;

/// 拿流失败。message 可以直接显示给人看。
class PlayException implements Exception {
  PlayException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 一条流。
class Stream {
  const Stream({
    required this.id,
    required this.url,
    required this.codecs,
    this.height,
  });

  /// 视频流是画质编号，音频流是码率编号。**越大越好。**
  final int id;

  final String url;
  final String codecs;

  /// 只有视频流有。
  final int? height;

  String get label {
    if (height != null) return '${height}p';
    return '$id';
  }
}

class PlayInfo {
  const PlayInfo({
    required this.videos,
    required this.audios,
    required this.duration,
  });

  /// 已按质量从好到差排好序。
  final List<Stream> videos;
  final List<Stream> audios;

  /// 这个分P的时长（秒）。
  final int duration;

  Stream get bestVideo => videos.first;
  Stream get bestAudio => audios.first;
}

/// 调 playurl 拿某个分P的音视频流。
///
/// [cid] 要用后端 `/api/video/{bvid}` 返回的那个 —— 池子里的条目没有 cid。
Future<PlayInfo> fetchPlayInfo(
  String bvid,
  int cid, {
  http.Client? client,
}) async {
  final uri = Uri.parse('https://api.bilibili.com/x/player/wbi/playurl')
      .replace(queryParameters: {
    'bvid': bvid,
    'cid': '$cid',
    'fnval': '$_fnval',
  });

  final http.Response res;
  try {
    res = await (client ?? http.Client())
        .get(uri, headers: bilibiliHeaders)
        .timeout(const Duration(seconds: 20));
  } catch (e) {
    throw PlayException('连不上 B 站接口：$e');
  }

  final dynamic payload;
  try {
    payload = jsonDecode(utf8.decode(res.bodyBytes));
  } catch (_) {
    throw PlayException('B 站返回的不是 JSON（HTTP ${res.statusCode}）');
  }

  // 一级校验
  if (payload['code'] != 0) {
    throw PlayException('B 站接口返回 code=${payload['code']}：${payload['message']}');
  }

  final data = payload['data'];
  final dash = data is Map ? data['dash'] : null;

  // 二级校验：**code=0 不代表拿到了流**。风控软拦时 data 里只有一个
  // v_voucher 令牌（坑 5），只查 code 会崩在一个跟风控无关的空指针上。
  if (dash == null) {
    throw PlayException('B 站没返回流（多半是风控拦截）。'
        'data 里的键：${data is Map ? data.keys.join(", ") : data}');
  }

  return PlayInfo(
    videos: _sorted(dash['video'], withHeight: true),
    audios: _sorted(dash['audio'], withHeight: false),
    duration: (dash['duration'] as num).toInt(),
  );
}

/// 按 (-id, codecid) 排序：质量降序，同质量按编码兼容性升序。
///
/// **必须排**（坑 7）：接口给的顺序不稳定，不排的话 `[0]` 偶尔会拿到次高的
/// —— 而那个频率意味着你测的时候发现不了。
List<Stream> _sorted(dynamic raw, {required bool withHeight}) {
  if (raw is! List) return const [];
  final streams = raw.map((e) {
    final m = e as Map<String, dynamic>;
    return Stream(
      id: (m['id'] as num).toInt(),
      url: m['baseUrl'] as String,
      codecs: '${m['codecs']}',
      height: withHeight ? (m['height'] as num?)?.toInt() : null,
    );
  }).toList();

  // Dart 的 sort 不稳定，但主键 + 次键已经唯一确定了顺序，所以没关系
  streams.sort((a, b) {
    final byId = b.id.compareTo(a.id);
    if (byId != 0) return byId;
    return _codecid(a).compareTo(_codecid(b));
  });
  return streams;
}

/// codecid 没进 Stream，从 codecs 反推一个代理值：7=AVC → 12=HEVC → 13=AV1。
int _codecid(Stream s) {
  final c = s.codecs.toLowerCase();
  if (c.startsWith('avc')) return 7;
  if (c.startsWith('hvc') || c.startsWith('hev')) return 12;
  if (c.startsWith('av01')) return 13;
  return 99;
}
