/// youyuan 客户端入口：拿后端地址、拉一次分区目录、在「内容」和「设置」之间切。
///
/// 同一套代码跑 Linux 桌面和 Android，所以布局是响应式的：
/// 宽屏侧边导航，窄屏底部导航。
library;

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'feed_page.dart';
import 'log.dart';
import 'models.dart';
import 'playback.dart';
import 'settings_page.dart';

/// 后端地址存在这里。第一次启动用默认值，设置页可以改。
const _kBackendKey = 'backend_url';

/// 默认地址。桌面上后端常跟客户端同一台机器。
const _defaultBackend = 'http://127.0.0.1:8000';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // media_kit 要先初始化才能建 Player（它会拉起 libmpv）
  MediaKit.ensureInitialized();
  // **播放器在这儿就建好**，不是等用户点开视频才建。
  // 建它要把 libmpv 的整套管线拉起来，放在点进去那一刻就是"第一次卡一下"。
  initPlayback();

  final prefs = await SharedPreferences.getInstance();
  final backend = prefs.getString(_kBackendKey) ?? _defaultBackend;
  ylog('main', '启动：后端 $backend'
      '${prefs.containsKey(_kBackendKey) ? "（存过的）" : "（默认值）"}');
  runApp(YouyuanApp(backend: backend));
}

class YouyuanApp extends StatelessWidget {
  const YouyuanApp({super.key, required this.backend});

  final String backend;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '有源',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6C8EBF)),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6C8EBF),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: Shell(initialBackend: backend),
    );
  }
}

class Shell extends StatefulWidget {
  const Shell({super.key, required this.initialBackend});

  final String initialBackend;

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  late Api _api = Api(widget.initialBackend);

  int _index = 0;
  List<Channel> _channels = const [];
  Settings? _settings;
  String? _error;

  /// 上次的宽窄屏判定，只在翻转时打日志（翻转才是危险动作，见坑 14）。
  bool? _lastWide;

  /// 「连不上后端」那一页上的地址输入框。
  ///
  /// 地址填错时 `_settings` 拿不到 → 设置页渲染不出来 → 没有任何地方能改
  /// 回来。所以把入口放在错误页本身，它只要连不上就一定看得见。
  late final TextEditingController _backendInput =
      TextEditingController(text: _api.baseUrl);

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  @override
  void dispose() {
    _backendInput.dispose();
    super.dispose();
  }

  /// 拉分区目录和设置。两个都要成功才能渲染设置页的滑块。
  Future<void> _loadConfig() async {
    ylog('main', '拉分区目录和设置…');
    try {
      final channels = await _api.channels();
      final settings = await _api.settings();
      if (!mounted) return;
      ylog('main', '拿到 ${channels.length} 个分区；'
          'n=${settings.n} 最小时长=${settings.minSeconds}s '
          '排除窗口=${settings.seenWindow}s');
      setState(() {
        _channels = channels;
        _settings = settings;
        _error = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      ylog('main', '拉配置失败：${e.message}');
      setState(() => _error = e.message);
    }
  }

  /// 切页。收成一个口子只为记日志：日志里「切页」后面若紧跟一句
  /// 「第 1 次要一轮内容…」，就说明 State 又被重建了（坑 14）。
  void _go(int i) {
    ylog('main', '切页：$_index → $i');
    setState(() => _index = i);
  }

  Future<void> _changeBackend(String url) async {
    if (url.isEmpty || url == _api.baseUrl) return;
    ylog('main', '换后端地址：${_api.baseUrl} → $url');
    _backendInput.text = url;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kBackendKey, url);
    setState(() {
      _api = Api(url);
      _channels = const [];
      _settings = null;
    });
    await _loadConfig();
  }

  @override
  Widget build(BuildContext context) {
    final routeNames = {for (final c in _channels) c.route: c.name};

    final pages = [
      FeedPage(api: _api, routeNames: routeNames),
      if (_settings != null)
        SettingsPage(
          api: _api,
          channels: _channels,
          settings: _settings!,
          onBackendChanged: _changeBackend,
          onSaved: _loadConfig,
        )
      else
        _configError(),
    ];

    // 诊断：State 被重建是看不见的，这行把每次 build 的构成摆出来对账
    ylog('main', 'build：_index=$_index settings=${_settings != null} '
        'channels=${_channels.length} '
        'pages=${pages.map((p) => p.runtimeType).toList()}');

    return LayoutBuilder(
      builder: (context, constraints) {
        // 宽屏侧边栏，窄屏底栏 —— 桌面和手机同一套代码
        final wide = constraints.maxWidth >= 700;
        if (wide != _lastWide) {
          ylog('main', '布局翻转 wide=$wide（可用宽 '
              '${constraints.maxWidth.toStringAsFixed(0)}px）');
          _lastWide = wide;
        }

        // **树的结构必须跟 wide 无关**：用 SizedBox.shrink() 占位而不是
        // `if (wide)` 增删子节点，否则位置一变 Flutter 就把 State 整个重建、
        // 白烧一轮内容（坑 14）。
        return Scaffold(
          body: Row(
            children: [
              if (wide)
                NavigationRail(
                  selectedIndex: _index,
                  onDestinationSelected: _go,
                  labelType: NavigationRailLabelType.all,
                  destinations: const [
                    NavigationRailDestination(
                      icon: Icon(Icons.grid_view_outlined),
                      selectedIcon: Icon(Icons.grid_view),
                      label: Text('内容'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.tune_outlined),
                      selectedIcon: Icon(Icons.tune),
                      label: Text('设置'),
                    ),
                  ],
                )
              else
                const SizedBox.shrink(),
              if (wide) const VerticalDivider(width: 1) else const SizedBox.shrink(),
              // **IndexedStack 而不是 `pages[_index]`**：后者在切页时会换掉
              // 这个位置的 widget 类型，Flutter 把旧 State 整个 dispose 重建。
              // 界面上看不出来，代价是每去一趟设置页再回来就白拉一轮内容
              // （详见 CLAUDE.md 坑 14）。IndexedStack 两页都留在树里、只画
              // 选中的那个，位置上的类型就恒定了。
              Expanded(child: IndexedStack(index: _index, children: pages)),
            ],
          ),
          // 同理：null ↔ widget 会改变 Scaffold 的子节点个数，一样会顶到别处
          bottomNavigationBar: wide
              ? const SizedBox.shrink()
              : NavigationBar(
                  selectedIndex: _index,
                  onDestinationSelected: _go,
                  destinations: const [
                    NavigationDestination(
                      icon: Icon(Icons.grid_view_outlined),
                      selectedIcon: Icon(Icons.grid_view),
                      label: '内容',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.tune_outlined),
                      selectedIcon: Icon(Icons.tune),
                      label: '设置',
                    ),
                  ],
                ),
        );
      },
    );
  }

  /// 设置页要分区和设置都拿到才渲染得出来，拿不到就显示这个。
  ///
  /// **它必须能改后端地址** —— 否则地址填错一次，整个 App 就回不去了。
  Widget _configError() {
    return Scaffold(
      appBar: AppBar(title: const Text('有源')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.settings_ethernet, size: 44),
                const SizedBox(height: 14),
                Text('连不上后端', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 10),
                Text(
                  _error ?? '正在连 ${_api.baseUrl} …',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.outline, height: 1.6),
                ),
                const SizedBox(height: 18),
                TextField(
                  controller: _backendInput,
                  decoration: const InputDecoration(
                    labelText: '后端地址',
                    hintText: 'http://127.0.0.1:8000',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (v) => _changeBackend(v.trim()),
                ),
                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    FilledButton(
                      onPressed: () => _changeBackend(_backendInput.text.trim()),
                      child: const Text('连这个地址'),
                    ),
                    const SizedBox(width: 8),
                    TextButton(onPressed: _loadConfig, child: const Text('重试')),
                  ],
                ),
                const SizedBox(height: 4),
                TextButton(
                  onPressed: () => _go(0),
                  child: const Text('先去看看内容页'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
