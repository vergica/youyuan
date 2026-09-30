"""采样：从池子里挑出这一轮要展示的视频。

纯函数 —— 不碰网络、不碰存储、不碰时钟（都由调用方传进来），所以能离线反复测。

  ① 分块采样  每区：滤掉时长不够的 → 排除刚展示过的 → 随机抽 x 条（x 是滑块值）
  ② 二次采样  从候选集合里均匀随机抽 n 条

二次采样均匀随机就够：分块后每区有 x 条，均匀抽 n 条的期望是 n·xₛ/Σx，
数学上已经按比例。已知取舍见 CLAUDE.md「整体设计」。
"""

from __future__ import annotations

import random
import time
from typing import Iterable, Mapping

# 默认值。界面上都能改，改了由调用方传进来，这里只是兜底。
DEFAULT_MIN_SECONDS = 5 * 60
DEFAULT_SEEN_WINDOW = 12 * 3600


def sample(
    entries: Iterable[dict],
    quota: Mapping[str, int],
    *,
    n: int,
    min_seconds: int = DEFAULT_MIN_SECONDS,
    seen: Mapping[str, float] | None = None,
    seen_window: float = DEFAULT_SEEN_WINDOW,
    rng: random.Random | None = None,
    now: float | None = None,
    stats: dict | None = None,
) -> list[dict]:
    """从池子条目里采出这一轮要展示的视频。

    entries     池子快照，每条至少含 route / bvid / seconds，其余原样透传。
    quota       {route: 权重}，**没列出的按 0 算**（这一轮不给它配额）。
    seen        {bvid: 上次展示的时间戳}；rng / now 注入只为测试可复现。
    stats       传字典进来会填入各段计数供日志使用；不传则无任何副作用
                —— 本函数不打印任何东西，数字交给调用方处置。

    返回顺序即展示顺序。数量不足时不凑数、不从别的区借，**长度 ≤ n 是常态**。

    seconds 对多P视频是**所有分P的总时长**（CLAUDE.md 坑 2）。
    """
    rng = rng if rng is not None else random.Random()
    now = time.time() if now is None else now
    seen = seen or {}

    # 无条件累加：热循环里塞 `if stats is not None` 既不更省也更难读。
    total = too_short = no_quota = hidden = 0

    # ① 分块采样：先按区分组，顺带把不合格的滤掉
    chunks: dict[str, list[dict]] = {}
    for entry in entries:
        total += 1
        if entry['seconds'] < min_seconds:
            too_short += 1
            continue
        weight = quota.get(entry['route'], 0)
        if weight <= 0:
            no_quota += 1
            continue
        shown_at = seen.get(entry['bvid'])
        if shown_at is not None and now - shown_at < seen_window:
            hidden += 1
            continue
        chunks.setdefault(entry['route'], []).append(entry)

    candidates: list[dict] = []
    for route, items in chunks.items():
        # 不够 x 条就全给，不补 —— 「配额大于池子」是正常情况，不是错误
        candidates.extend(rng.sample(items, min(quota[route], len(items))))

    # ② 二次采样：均匀随机抽 n 条，顺带把顺序也打散了
    picked = rng.sample(candidates, min(n, len(candidates)))

    if stats is not None:
        stats.update(
            pool=total, too_short=too_short, no_quota=no_quota, hidden=hidden,
            # pool < quota 就是"这个区在挨饿"，日志靠它一眼看出来
            routes={route: {'pool': len(items), 'quota': quota[route],
                            'took': min(quota[route], len(items))}
                    for route, items in chunks.items()},
            candidates=len(candidates), picked=len(picked), n=n,
        )
    return picked
