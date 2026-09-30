/// 后端返回的数据结构。
///
/// 字段名跟后端一一对应（见 CLAUDE.md「后端 API」一节）—— 改这边之前先看那边。
library;

/// 一个视频条目。
///
/// 字段是后端 `parse_section_videos` 的那几个，另加两个：
/// [route] 是它属于哪个分区（后端在池子里定的），[added] 是入池时间。
class Video {
  const Video({
    required this.bvid,
    required this.title,
    required this.author,
    required this.cover,
    required this.seconds,
    required this.play,
    required this.danmaku,
    required this.route,
  });

  final String bvid;
  final String title;
  final String author;
  final String cover;

  /// 总时长（秒）。多P视频是**所有分P之和**，跟 B 站列表页显示的一致。
  final int seconds;

  final int play;
  final int danmaku;
  final String route;

  factory Video.fromJson(Map<String, dynamic> json) => Video(
        bvid: json['bvid'] as String,
        title: json['title'] as String,
        author: json['author'] as String,
        cover: json['cover'] as String,
        seconds: json['seconds'] as int,
        play: json['play'] as int,
        danmaku: json['danmaku'] as int,
        route: json['route'] as String,
      );

  /// '12:07' / '1:02:33'。超过一小时才显示小时段。
  String get durationText {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    final mm = m.toString().padLeft(h > 0 ? 2 : 1, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  /// '1.1万' 这样的显示用计数。跟 B 站列表页一个口径。
  String get playText => formatCount(play);

  String get danmakuText => formatCount(danmaku);

  /// 能直接喂给 `Image.network` 的封面地址。
  ///
  /// **两个数据源的格式不一样**：分区页给 `//i2.hdslb.com/...`（协议相对，
  /// 非浏览器环境里不是合法 URL），`view` 接口给 `http://...`。统一补成 https。
  /// 封面图不需要 Referer，所以客户端直接拉，不用后端代理。
  String get coverUrl {
    if (cover.startsWith('//')) return 'https:$cover';
    if (cover.startsWith('http://')) return cover.replaceFirst('http://', 'https://');
    return cover;
  }
}

/// 把计数压成 B 站那种 3 位有效数字的写法。
///
/// 后端解析时已把 '1.1万' 还原成整数，这里只是显示时压回去 —— 精度损失
/// 发生在 B 站那边，不在我们这（坑 11）。
String formatCount(int n) {
  if (n < 10000) return '$n';
  if (n < 100000000) {
    final v = n / 10000;
    return '${_trim(v)}万';
  }
  return '${_trim(n / 100000000)}亿';
}

/// 保留一位小数，整数就不显示 '.0'（1.0万 → 1万）。
String _trim(double v) {
  final s = v.toStringAsFixed(1);
  return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
}

/// 一个分区。
class Channel {
  const Channel({required this.route, required this.name, required this.quota});

  final String route;
  final String name;

  /// 这个分区的权重，0~10。0 表示这一轮不给它配额。
  final int quota;

  factory Channel.fromJson(Map<String, dynamic> json) => Channel(
        route: json['route'] as String,
        name: json['name'] as String,
        quota: json['quota'] as int,
      );
}

/// 用户能调的旋钮。字段就是后端 `store.Settings` 的那几个。
class Settings {
  const Settings({required this.values});

  /// 原样保留后端返回的字典 —— 这样后端加了新旋钮，客户端不改也不会丢。
  final Map<String, dynamic> values;

  factory Settings.fromJson(Map<String, dynamic> json) => Settings(values: json);

  int get n => values['n'] as int;
  int get minSeconds => values['min_seconds'] as int;
  int get seenWindow => values['seen_window'] as int;
  int get refreshInterval => values['refresh_interval'] as int;

  /// 各分区权重。后端返回时已经补齐过，每个分区都有值。
  Map<String, int> get quota => (values['quota'] as Map)
      .map((k, v) => MapEntry(k as String, v as int));

  int quotaOf(String route) => quota[route] ?? 5;
}

/// 一轮内容。
class Feed {
  const Feed({required this.items, required this.poolTotal});

  final List<Video> items;

  /// 池子总共多大 —— 用来在界面上提示"为什么这次给的少"。
  final int poolTotal;

  factory Feed.fromJson(Map<String, dynamic> json) => Feed(
        items: (json['items'] as List)
            .map((e) => Video.fromJson(e as Map<String, dynamic>))
            .toList(),
        poolTotal: json['pool_total'] as int,
      );
}

/// 视频详情。播放前要用它换 [cid]。
class VideoDetail {
  const VideoDetail({
    required this.bvid,
    required this.cid,
    required this.title,
    required this.pages,
    required this.seconds,
  });

  final String bvid;

  /// 当前分P的 cid —— 拿它去调 playurl。
  final int cid;

  final String title;
  final List<VideoPart> pages;

  /// 所有分P的总时长。
  final int seconds;

  factory VideoDetail.fromJson(Map<String, dynamic> json) => VideoDetail(
        bvid: json['bvid'] as String,
        cid: json['cid'] as int,
        title: json['title'] as String,
        seconds: json['seconds'] as int,
        pages: (json['pages'] as List)
            .map((e) => VideoPart.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// 一个分P。
class VideoPart {
  const VideoPart({
    required this.cid,
    required this.page,
    required this.title,
    required this.seconds,
  });

  final int cid;
  final int page;
  final String title;
  final int seconds;

  factory VideoPart.fromJson(Map<String, dynamic> json) => VideoPart(
        cid: json['cid'] as int,
        page: json['page'] as int,
        title: json['title'] as String,
        seconds: json['seconds'] as int,
      );
}
