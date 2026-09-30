/// 客户端诊断日志的统一出口。
///
/// 单独成文件是为了前缀只写一遍（`[youyuan]` 是 CLAUDE.md 写明的 grep 锚点），
/// 以及将来要「同时写一份到文件」时只改这一处。
library;

import 'package:flutter/foundation.dart';

/// 设成 false 时 AOT 编译会把 `ylog` 调用连同参数求值一起当死代码删掉。
const bool kLogEnabled = true;

/// 打一行诊断。tag 用来分区，比如 `api` / `feed` / `player`。
void ylog(String tag, String message) {
  if (!kLogEnabled) return;
  debugPrint('[youyuan] [$tag] $message');
}
