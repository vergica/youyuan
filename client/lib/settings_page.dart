/// 设置页：后端地址 + 31 个分区滑块 + 那几档全局旋钮。
///
/// **这些旋钮是 this project 的个性化层**（见 CLAUDE.md「核心设计原则」）：
/// 你的偏好只决定每个分区给几条（配额层），内容由后端按群体信号挑。
/// 所以这一页只有滑块，**没有任何"根据你的点击自动调整"的东西** ——
/// 一旦加了自动学习，就等于把推荐算法重新造了一遍。
library;

import 'package:flutter/material.dart';

import 'api.dart';
import 'log.dart';
import 'models.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.api,
    required this.channels,
    required this.settings,
    required this.onBackendChanged,
    required this.onSaved,
  });

  final Api api;
  final List<Channel> channels;
  final Settings settings;

  /// 改了后端地址。外壳要拿新地址重建 Api。
  final ValueChanged<String> onBackendChanged;

  /// 保存成功后回调，让外壳刷新分区和设置。
  final Future<void> Function() onSaved;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _backend =
      TextEditingController(text: widget.api.baseUrl);

  late Map<String, int> _quota = widget.settings.quota;

  // 时长/条数这类用秒和条存，界面上给人看的单位更友好
  late int _minSeconds = widget.settings.minSeconds;
  late int _n = widget.settings.n;
  late int _seenHours = widget.settings.seenWindow ~/ 3600;
  late int _refreshMinutes = widget.settings.refreshInterval ~/ 60;
  late int _ttlHours = (widget.settings.values['ttl'] as int) ~/ 3600;

  bool _saving = false;
  String? _message;

  Map<String, dynamic> _patch() => {
        'quota': _quota,
        'min_seconds': _minSeconds,
        'n': _n,
        'seen_window': _seenHours * 3600,
        'refresh_interval': _refreshMinutes * 60,
        'ttl': _ttlHours * 3600,
      };

  @override
  void dispose() {
    _backend.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _message = null;
    });
    final newBackend = _backend.text.trim();
    if (newBackend != widget.api.baseUrl) {
      widget.onBackendChanged(newBackend);
    }
    // 把整个 patch 记下来 —— 排查"我明明改了滑块，内容怎么没变"时，
    // 第一步就是确认客户端到底发出去了什么。后端那边会再记一次收到的值，
    // 两头对得上才说明是采样的问题，不是传输的问题。
    ylog('settings', '保存：$_patch()');
    final sw = Stopwatch()..start();
    try {
      await widget.api.updateSettings(_patch());
      await widget.onSaved();
      ylog('settings', '保存成功（${sw.elapsedMilliseconds}ms）');
    } on ApiException catch (e) {
      // 后端对越界值一律返 400 并说清哪个键不对 —— 原样显示，别自己编
      ylog('settings', '保存失败（${sw.elapsedMilliseconds}ms）：${e.message}');
      if (mounted) setState(() => _message = '保存失败：${e.message}');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _setAll(int value) {
    setState(() => _quota = {for (final c in widget.channels) c.route: value});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
        actions: [
          // 只在**失败**时占用这块地方。成功不提示 —— 保存是常规操作，
          // 每次弹个「已保存」只是噪音。
          if (_message != null)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Text(_message!,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.error)),
              ),
            ),
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: const Icon(Icons.save),
            label: const Text('保存'),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _section(theme, '后端'),
          TextField(
            controller: _backend,
            decoration: const InputDecoration(
              labelText: '后端地址',
              hintText: 'http://127.0.0.1:8000',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          _poolStatus(theme),

          _section(theme, '每个分区给几条'),
          Text(
            '权重 0~10。0 表示这个分区这一轮一条都不给。',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline, height: 1.5),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              for (final v in [0, 3, 5, 8, 10])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: OutlinedButton(
                    onPressed: () => _setAll(v),
                    child: Text('全设 $v'),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          for (final c in widget.channels) _slider(theme, c),

          _section(theme, '显示'),
          _intSlider(theme, '最小时长', _minSeconds, 0, 3600, 60,
              (v) => setState(() => _minSeconds = v),
              '${_minSeconds ~/ 60} 分钟',
              '短于这个时长的视频不参与采样。默认 5 分钟。'),
          _intSlider(theme, '一次显示条数', _n, 5, 120, 5,
              (v) => setState(() => _n = v), '$_n 条', null),
          _intSlider(theme, '已看过的排除多久', _seenHours, 1, 72, 1,
              (v) => setState(() => _seenHours = v), '$_seenHours 小时',
              '这段时间内展示过的视频不再出现，避免「换一换」刷出重复。'),

          _section(theme, '高级'),
          _intSlider(theme, '池子刷新间隔', _refreshMinutes, 5, 360, 5,
              (v) => setState(() => _refreshMinutes = v), '$_refreshMinutes 分钟',
              '改完要重启后端才生效。'),
          _intSlider(theme, '池子里留多久', _ttlHours, 1, 72, 1,
              (v) => setState(() => _ttlHours = v), '$_ttlHours 小时',
              '连续这么久没被再抓到的条目会被清掉。'),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _section(ThemeData theme, String title) => Padding(
        padding: const EdgeInsets.only(top: 28, bottom: 10),
        child: Text(title,
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w600)),
      );

  Widget _slider(ThemeData theme, Channel c) {
    final v = _quota[c.route] ?? 5;
    return Row(
      children: [
        SizedBox(
          width: 96,
          child: Text(c.name, style: theme.textTheme.bodyMedium),
        ),
        Expanded(
          child: Slider(
            value: v.toDouble(),
            max: 10,
            divisions: 10,
            label: '$v',
            onChanged: (x) =>
                setState(() => _quota = {..._quota, c.route: x.round()}),
          ),
        ),
        SizedBox(
          width: 28,
          child: Text('$v',
              textAlign: TextAlign.end, style: theme.textTheme.bodyMedium),
        ),
      ],
    );
  }

  Widget _intSlider(
    ThemeData theme,
    String label,
    int value,
    int min,
    int max,
    int step,
    ValueChanged<int> onChanged,
    String display,
    String? help,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                  width: 140,
                  child: Text(label, style: theme.textTheme.bodyMedium)),
              Expanded(
                child: Slider(
                  value: value.toDouble().clamp(min.toDouble(), max.toDouble()),
                  min: min.toDouble(),
                  max: max.toDouble(),
                  divisions: ((max - min) ~/ step).clamp(1, 200),
                  label: display,
                  onChanged: (x) => onChanged((x / step).round() * step),
                ),
              ),
              SizedBox(
                width: 76,
                child: Text(display,
                    textAlign: TextAlign.end,
                    style: theme.textTheme.bodyMedium),
              ),
            ],
          ),
          if (help != null)
            Padding(
              padding: const EdgeInsets.only(left: 140, bottom: 8),
              child: Text(help,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline, height: 1.4)),
            ),
        ],
      ),
    );
  }

  Widget _poolStatus(ThemeData theme) {
    return FutureBuilder<Map<String, dynamic>>(
      future: widget.api.poolStatus(),
      builder: (context, snap) {
        if (snap.hasError) {
          return Text('池子状态取不到：${snap.error}',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error));
        }
        if (!snap.hasData) {
          return Text('正在问池子状态…', style: theme.textTheme.bodySmall);
        }
        final s = snap.data!;
        final last = s['last_refresh'] as num?;
        final ago = last == null
            ? '还没刷过'
            : '${((DateTime.now().millisecondsSinceEpoch / 1000 - last) / 60).round()} 分钟前刷过';
        return Text(
          '池中 ${s['total']} 条 · $ago · 已展示记录 ${s['shown']} 条',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.outline),
        );
      },
    );
  }
}
