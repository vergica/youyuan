/// 播放页：向后端要 cid → 直接找 B 站要流地址 → media_kit（libmpv）播放。
/// **视频流不经过 youyuan 后端**（见 CLAUDE.md「整体设计」）。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
// 加前缀是因为 media_kit_video 也导出一个叫 `Video` 的 widget，而本项目的
// models.dart 里 `Video` 是数据模型。不加前缀的话每次用都得写 hide，很吵。
import 'package:media_kit_video/media_kit_video.dart' as mk;

import 'api.dart';
import 'bilibili.dart';
import 'log.dart';
import 'models.dart';
import 'playback.dart';

class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key, required this.api, required this.video});

  final Api api;

  /// 从内容页点进来的条目。注意它**没有 cid** —— 要另外向后端换。
  final Video video;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  /// 用的是全局那一个（playback.dart），不是这里建的。
  Player get _player => player;
  mk.VideoController get _controller => videoController;

  VideoDetail? _detail;
  PlayInfo? _info;
  String? _error;
  String? _warning;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    // mpv 的报错默认是看不见的 —— 它会安静地播不出声。挂上日志才能看到原话。
    _player.stream.error.listen((e) => _diag('mpv error: $e'));
    _player.stream.log.listen((e) {
      // 音频相关的报错未必是 error 级，光看 error 会漏掉，所以单独捞。
      final text = e.text.toLowerCase();
      final audioish = e.prefix.startsWith('ao') ||
          e.prefix.startsWith('ad') ||
          text.contains('audio') ||
          text.contains('cache');
      if (e.level == 'error' || e.level == 'warn' || audioish) {
        _diag('mpv ${e.level} [${e.prefix}] ${e.text.trim()}');
      }
    });
    _play(1);
  }

  /// 本地短名，播放这块的日志最多。
  void _diag(String message) => ylog('player', message);

  @override
  void dispose() {
    // **不能 dispose 播放器** —— 它是全局共用的，下一个视频还要用它。
    // 但也不能让它接着放：退出播放页就该停声，所以 stop 而不是什么都不做。
    _player.stop();
    super.dispose();
  }

  /// 等 mpv 报出时长 —— 那就是"文件已加载"的信号。返回等了多久（给人看的）。
  ///
  /// 超时不算失败：可能只是网络慢，`audio-add` 照样发出去让 mpv 自己处理。
  Future<String> _waitForLoad() async {
    if (_player.state.duration > Duration.zero) {
      // `await open()` 返回时文件还没开好，此处 duration 往往仍是**上一条
      // 视频的**。这时早退会让 `audio-add` 抢跑、被 mpv 静默丢掉。
      // 把值原样打出来：日志里看到非 0 的 duration 就是踩中了。
      return '已有（0ms，duration 还是 ${_player.state.duration}）';
    }
    final sw = Stopwatch()..start();
    try {
      final d = await _player.stream.duration
          .firstWhere((d) => d > Duration.zero)
          .timeout(const Duration(seconds: 15));
      return '${sw.elapsedMilliseconds}ms（duration=$d）';
    } catch (_) {
      return '超时 15s';
    }
  }

  Future<void> _play(int page) async {
    setState(() {
      _loading = true;
      _error = null;
      _warning = null;
    });

    final sw = Stopwatch()..start();
    _diag('开始播 ${widget.video.bvid} 第 $page 个分P'
        '${_info != null ? "（换P：这一页已经播过一轮了）" : "（首次）"}');
    try {
      // 1. 换 cid —— 池子里的条目没有 cid，这是必须的一跳
      final detail = await widget.api.video(widget.video.bvid, p: page);
      _diag('拿到 cid=${detail.cid}（${sw.elapsedMilliseconds}ms）');

      // 2. 直接找 B 站要流地址（不经过我们的后端）
      final info = await fetchPlayInfo(detail.bvid, detail.cid);
      // 选中的是哪一档要记下来：画质/音质选错是"看着不对/听着不对"
      // 那类问题的第一嫌疑，而排序规则在客户端是**第二份实现**。
      _diag('拿到流（${sw.elapsedMilliseconds}ms）：'
          '画面 ${info.bestVideo.label} ${info.bestVideo.codecs}、'
          '声音 ${info.bestAudio.id} ${info.bestAudio.codecs}'
          '（共 ${info.videos.length} 档画质 / ${info.audios.length} 档音质）');

      // 3. 播视频流
      final native = _player.platform as NativePlayer;
      await _player.open(
        Media(info.bestVideo.url, httpHeaders: bilibiliHeaders),
        play: true,
      );

      // 4. **等文件真的加载完再挂音轨** —— `open()` 的加载是异步的，太早调
      //    `audio-add` 时 mpv 还没有"当前文件"，命令被静默丢掉，
      //    症状正好是**有画面没声音且不报错**。
      final waited = await _waitForLoad();

      // 5. 挂音轨。DASH 的音视频是两条分开的流，mpv 靠 audio-add 合成。
      //    请求头不用重复传（media_kit 设了 mpv 的全局 `http-header-fields`）。
      //    单独 try 住：没声音是**能看**的降级状态，不该让整页报错。
      try {
        _diag('audio-add 前 http-header-fields='
            '${await native.getProperty('http-header-fields')}');
        await native.command(['audio-add', info.bestAudio.url, 'select']);
        _diag('audio-add 已发出（加载等了 $waited）');
      } catch (e) {
        _diag('audio-add 抛异常：$e');
        if (mounted) setState(() => _warning = '音轨加载失败，只有画面：$e');
      }

      if (!mounted) return;
      setState(() {
        _detail = detail;
        _info = info;
        _loading = false;
      });

      // 回头看一眼 mpv 的内部状态。mounted 判断不能省 —— 用户可能已经
      // 退出这一页，那时每个 getProperty 都会抛异常，刷一屏噪音。
      Future.delayed(const Duration(seconds: 5), () async {
        if (!mounted) return;
        for (final p in [
          'track-list/count', 'aid', 'audio',
          // ⚠️ 是 `current-ao`，不是 `ao`。
          //
          // 踩过：`ao` 这个属性**有没有声音都是空的**（拿命令行 mpv 实测过，
          // 同一秒里 stdout 打着 `AO: [pipewire] 44100Hz stereo 2ch floatp`
          // 而 `${ao}` 展开成 `[]`）。之前据此认定"音频输出驱动没起来"，
          // 是误诊。`current-ao` 才给出真正在用的驱动。
          'current-ao', 'audio-device', 'audio-codec-name', 'audio-params',
          'volume', 'mute', 'ao-volume', 'ao-mute',
        ]) {
          try {
            _diag('  $p = ${await native.getProperty(p)}');
          } catch (e) {
            _diag('  $p = <读不到: $e>');
          }
        }
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on PlayException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted && _error != null) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.video;
    return Scaffold(
      appBar: AppBar(
        title: Text(v.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      // LayoutBuilder 放在 Column **外面**：Column 给非 flex 子节点的高度约束
      // 是无限的，放里面就量不到可用高度了。
      body: LayoutBuilder(
        builder: (context, c) {
          // 视频按 16:9 撑满宽度时会顶掉整个窗口高度，再加 AppBar 就溢出
          // （那条黄黑警告带），所以给视频区封顶。
          //
          // **留白用固定值而不是百分比**：下面那块放的是标题、作者、画质，
          // 多分P 时还有一整列分P —— 需要多少高度跟窗口多大基本无关。
          // 后一个 max 是兜底，窗口矮到极点时别把视频压成一条。
          const infoReserve = 180.0;
          final videoHeight = math.min(
            c.maxWidth * 9 / 16,
            math.max(c.maxHeight - infoReserve, c.maxHeight * 0.5),
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: videoHeight,
                child: Center(
                  child: SizedBox(
                    width: videoHeight * 16 / 9,
                    child: ColoredBox(
                      color: Colors.black,
                      child: _error != null
                          ? _errorBox()
                          : mk.Video(controller: _controller),
                    ),
                  ),
                ),
              ),
              if (_loading) const LinearProgressIndicator(),
              if (_warning != null)
                Container(
                  width: double.infinity,
                  color: Theme.of(context).colorScheme.errorContainer,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Text(_warning!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.onErrorContainer)),
                ),
              Expanded(child: _infoPane(v)),
            ],
          );
        },
      ),
    );
  }

  Widget _errorBox() => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.white70, size: 40),
              const SizedBox(height: 12),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, height: 1.5),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => _play(_detail?.pages.isNotEmpty == true
                    ? _detail!.pages.first.page
                    : 1),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );

  Widget _infoPane(Video v) {
    final theme = Theme.of(context);
    final detail = _detail;
    final info = _info;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(v.title, style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          '${v.author} · ${v.playText}播放 · ${v.danmakuText}弹幕 · ${v.durationText}',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.outline),
        ),
        const SizedBox(height: 4),
        Text(
          '${v.bvid}${info != null ? " · 当前 ${info.bestVideo.label}"
              " · ${info.videos.length} 档画质 / ${info.audios.length} 档音质" : ""}',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.outline),
        ),
        if (detail != null && detail.pages.length > 1) ...[
          const Divider(height: 32),
          Text('${detail.pages.length} 个分P', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          for (final p in detail.pages)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: SizedBox(
                width: 32,
                child: Text('${p.page}',
                    style: theme.textTheme.bodyMedium,
                    textAlign: TextAlign.center),
              ),
              title: Text(p.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('${p.seconds ~/ 60}:'
                  '${(p.seconds % 60).toString().padLeft(2, "0")}'),
              onTap: () => _play(p.page),
            ),
        ],
      ],
    );
  }
}
