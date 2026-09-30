/// 全局唯一的播放器，**App 启动时就建好**。
///
/// 播放页以前各自 `Player()` + `VideoController()`，等于每个视频都重建一遍
/// libmpv 的管线。挪到启动做，代价是启动慢一点、这份内存常驻到进程结束。
///
/// 注意：实测构造只要 ~11ms，所以「第一次点视频卡一下」**不是**构造的开销，
/// 而是第一次真正加载媒体那一步。提前建省不掉那个，只是不再每页重建。
library;

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart' as mk;

import 'log.dart';

/// 唯一的播放器实例，由 [initPlayback] 赋值。
late final Player player;

/// 跟 [player] 配套的视频控制器。真正建立渲染管线的是它，所以也要一起提前建。
late final mk.VideoController videoController;

/// 在 `main()` 里、`runApp()` 之前调用一次，且必须在
/// `MediaKit.ensureInitialized()` 之后。
void initPlayback() {
  final sw = Stopwatch()..start();
  player = Player();
  final playerMs = sw.elapsedMilliseconds;

  sw.reset();
  videoController = mk.VideoController(player);
  ylog('playback', '播放器已就绪：Player() ${playerMs}ms + '
      'VideoController() ${sw.elapsedMilliseconds}ms');
}
