/// 内容页：响应式卡片网格。
///
/// 「换一换」= 重新向后端要一轮，**整页替换**（不做无限滚动、不追加）。
library;

import 'package:flutter/material.dart';

import 'api.dart';
import 'log.dart';
import 'models.dart';
import 'player_page.dart';

class FeedPage extends StatefulWidget {
  const FeedPage({super.key, required this.api, required this.routeNames});

  final Api api;

  /// route → 显示名。后端给的是 route（如 'knowledge'），界面上要显示「知识」。
  final Map<String, String> routeNames;

  @override
  State<FeedPage> createState() => _FeedPageState();
}

class _FeedPageState extends State<FeedPage> {
  List<Video>? _items;
  int _poolTotal = 0;
  String? _error;
  bool _loading = true;

  /// 加载了几次。只给排查用：日志里看到第 2 次，就说明 State 被重建了
  /// —— `/api/feed` 有副作用，多拉一轮就白烧 30 条（见 CLAUDE.md 坑 14）。
  int _loadCount = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    ylog('feed', '页面销毁 —— 这一世共加载 $_loadCount 次');
    super.dispose();
  }

  Future<void> _load() async {
    final seq = ++_loadCount;
    setState(() {
      _loading = true;
      _error = null;
    });
    ylog('feed', '第 $seq 次要一轮内容…');
    try {
      final feed = await widget.api.feed();
      if (!mounted) return;
      ylog('feed', '第 $seq 次拿到 ${feed.items.length} 条，池中 ${feed.poolTotal} 条');
      if (feed.items.isEmpty) {
        ylog('feed', '第 $seq 次是空的 —— 原因看后端日志的 feed: 汇总行');
      }
      setState(() {
        _items = feed.items;
        _poolTotal = feed.poolTotal;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      ylog('feed', '第 $seq 次失败：${e.message}');
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('有源'),
        actions: [
          if (_items != null)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(
                child: Text(
                  '池中 $_poolTotal 条',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
          FilledButton.tonalIcon(
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
            label: const Text('换一换'),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _Centered(
        icon: Icons.cloud_off,
        title: '拉不到内容',
        // 指一条出路：地址填错时「设置」页会因为拿不到配置而渲染不出来，
        // 那里其实是错误页（带地址输入框），不点破的话用户找不到。
        detail: '$_error\n\n如果是连不上后端，去「设置」页改地址。',
        action: FilledButton(onPressed: _load, child: const Text('重试')),
      );
    }
    final items = _items ?? const <Video>[];
    if (items.isEmpty) return _emptyState();
    return _Grid(
      items: items,
      routeNames: widget.routeNames,
      api: widget.api,
    );
  }

  /// 一条都没有时，把**可能的原因**摆出来。这不是罕见情况 —— 池子刚起来
  /// 很小，再被"最小时长"和排除窗口一削就见底。与其显示"暂无内容"，
  /// 不如告诉用户是哪几个旋钮在起作用。
  Widget _emptyState() {
    return _Centered(
      icon: Icons.hourglass_empty,
      title: _poolTotal == 0 ? '池子还是空的' : '这一轮挑不出内容',
      detail: _poolTotal == 0
          ? '后端刚起来，正在抓第一轮。等十几秒再点「换一换」。'
          : '池中有 $_poolTotal 条，但都被过滤掉了。可能是：\n'
              '· 最小时长设得偏高（默认 5 分钟会滤掉约 2/3）\n'
              '· 最近看过的还没过 12 小时排除窗口\n'
              '· 各分区权重太低，配额不够\n'
              '去设置页调一下，或者等下一轮池子刷新。',
      action: FilledButton(onPressed: _load, child: const Text('再试一次')),
    );
  }
}

/// 自适应列数的网格。
///
/// 自己算列数和行高而不用 `SliverGridDelegateWithMaxCrossAxisExtent`：
/// 封面要保持 16:9，卡片高度得跟着列宽走，固定 childAspectRatio 会留白或溢出。
class _Grid extends StatelessWidget {
  const _Grid({required this.items, required this.routeNames, required this.api});

  final List<Video> items;
  final Map<String, String> routeNames;
  final Api api;

  static const _spacing = 12.0;
  static const _padding = 12.0;

  /// 卡片里封面以下那部分的高度：标题两行 + 作者/播放一行 + 内边距。
  static const _textBlockHeight = 84.0;

  @override
  Widget build(BuildContext context) {
    // 跟着系统字号放大 —— 写死高度的话，用户把字号调大就会看到
    // "BOTTOM OVERFLOWED BY N PIXELS" 那条黄黑警告带。
    final textBlock =
        _textBlockHeight * MediaQuery.textScalerOf(context).scale(1.0);

    return LayoutBuilder(
      builder: (context, constraints) {
        final usable = constraints.maxWidth - _padding * 2;
        // 目标卡片宽度 300，至少 1 列
        final columns = (usable / 300).floor().clamp(1, 8);
        final tileWidth = (usable - _spacing * (columns - 1)) / columns;
        final tileHeight = tileWidth * 9 / 16 + textBlock;

        return GridView.builder(
          padding: const EdgeInsets.all(_padding),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: _spacing,
            crossAxisSpacing: _spacing,
            mainAxisExtent: tileHeight,
          ),
          itemCount: items.length,
          itemBuilder: (context, i) => _Card(
            video: items[i],
            routeName: routeNames[items[i].route],
            api: api,
          ),
        );
      },
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.video, required this.routeName, required this.api});

  final Video video;
  final String? routeName;
  final Api api;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => PlayerPage(api: api, video: video),
        )),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.network(
                    video.coverUrl,
                    fit: BoxFit.cover,
                    // 封面拉不下来不该让整张卡片崩掉 —— 留个占位就行
                    errorBuilder: (_, _, _) => Container(
                      color: theme.colorScheme.surfaceContainerHighest,
                      child: Icon(Icons.broken_image_outlined,
                          color: theme.colorScheme.outline),
                    ),
                    loadingBuilder: (context, child, progress) => progress == null
                        ? child
                        : Container(color: theme.colorScheme.surfaceContainerHighest),
                  ),
                  Positioned(
                    right: 6,
                    bottom: 6,
                    child: _Badge(text: video.durationText),
                  ),
                  if (routeName != null)
                    Positioned(left: 6, top: 6, child: _Badge(text: routeName!)),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        video.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w500),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${video.author} · ${video.playText}播放',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.outline),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 盖在封面上的小标签（时长、分区名）。
class _Badge extends StatelessWidget {
  const _Badge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.66),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: const TextStyle(color: Colors.white, fontSize: 11),
      ),
    );
  }
}

/// 居中的提示块。出错和空列表都用它，样式统一。
class _Centered extends StatelessWidget {
  const _Centered({
    required this.icon,
    required this.title,
    required this.detail,
    required this.action,
  });

  final IconData icon;
  final String title;
  final String detail;
  final Widget action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 44, color: theme.colorScheme.outline),
              const SizedBox(height: 14),
              Text(title, style: theme.textTheme.titleMedium),
              const SizedBox(height: 10),
              Text(
                detail,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline, height: 1.6),
              ),
              const SizedBox(height: 18),
              action,
            ],
          ),
        ),
      ),
    );
  }
}
