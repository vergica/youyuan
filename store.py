"""后端的三份持久状态：视频池、已展示记录、设置。

放在一个模块里，因为它们都是长跑进程要维持、要落盘、重启后要能接着用的
状态，而且共用同一个原子写盘函数。除了池子的抓取（靠注入 fetch 也能离线测），
这里不碰网络。

/ Pool /
  后台每轮把所有分区抓一遍并进来。**已在池中的刷新入池时间而不是跳过**，
  入池超过 TTL 的删掉。**必须容忍某个分区某一轮返回 0 条**（坑 10）——
  空列表是合法输入，不动已有数据。

/ History /
  「换一换」时用它避开刚看过的。**留多久**和**排除多久**是两件事：排除窗口
  是采样规则（sampling 的 seen_window，界面可改），保留期只影响磁盘占用，
  所以按固定值清理、不跟着设置走 —— 否则把窗口从 12h 改成 24h 时，
  之前按 12h 清掉的记录会丢，用户会看到重复。

/ Settings /
  界面上的旋钮。**默认值写死在代码里，用户改过的才落盘**，这样以后调默认值
  时没动过设置的人能跟着变。写入一律校验，越界 / 类型不对 / 不认识的键都抛
  ValueError，不悄悄夹断（CLAUDE.md「开发约定」）。
"""

from __future__ import annotations

import json
import logging
import os
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Callable, Iterable

from bilibili import fetch_section_videos

log = logging.getLogger('youyuan.store')

DEFAULT_TTL = 24 * 3600
DEFAULT_WORKERS = 5
DEFAULT_RETAIN = 7 * 24 * 3600


def write_atomic(path: Path, blob: dict) -> None:
    """先写临时文件再 rename —— 崩在写一半不会把状态文件写坏。

    这些都是长跑进程的状态，写坏了下次启动就得从零开始攒。
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + '.tmp')
    text = json.dumps(blob, ensure_ascii=False)
    tmp.write_text(text, encoding='utf-8')
    os.replace(tmp, path)
    log.debug('落盘 %s（%d 字节）', path.name, len(text.encode('utf-8')))


class Pool:
    """视频池。线程安全 —— 后台刷新跑在线程里，请求处理同时在读。

    存 parse_section_videos 的字段再加 route（从哪个分区抓到的）和
    added（入池时间戳）。fetch 默认 bilibili.fetch_section_videos，
    测试时换成假的就能把整个刷新流程离线跑一遍。
    """

    def __init__(self, path: str | Path, *, ttl: float = DEFAULT_TTL,
                 fetch: Callable[[str], list[dict]] | None = None) -> None:
        self.path = Path(path)
        self.ttl = ttl
        self._fetch = fetch or fetch_section_videos
        self._lock = threading.Lock()
        self._entries: dict[str, dict] = {}
        self.last_refresh: float | None = None
        self._load()

    # ---------- 持久化 ----------

    def _load(self) -> None:
        if not self.path.exists():
            log.info('池子文件 %s 不存在，从空池子开始', self.path.name)
            return
        blob = json.loads(self.path.read_text(encoding='utf-8'))
        self._entries = blob.get('entries', {})
        self.last_refresh = blob.get('last_refresh')
        # 上次刷新时间能立刻看出后端是不是停了很久（条目可能已大面积过期）
        log.info('池子从 %s 恢复 %d 条（上次刷新 %s）', self.path.name,
                 len(self._entries),
                 time.strftime('%m-%d %H:%M:%S', time.localtime(self.last_refresh))
                 if self.last_refresh else '无记录')

    def save(self) -> None:
        with self._lock:
            blob = {'last_refresh': self.last_refresh,
                    'entries': dict(self._entries)}
        write_atomic(self.path, blob)

    # ---------- 读 ----------

    def entries(self) -> list[dict]:
        """池子快照，交给采样。返回浅拷贝 —— 采样期间后台可能在改这些条目。"""
        with self._lock:
            return [dict(e) for e in self._entries.values()]

    def status(self) -> dict:
        with self._lock:
            by_route: dict[str, int] = {}
            for e in self._entries.values():
                by_route[e['route']] = by_route.get(e['route'], 0) + 1
            return {'total': len(self._entries), 'by_route': by_route,
                    'last_refresh': self.last_refresh}

    def __len__(self) -> int:
        with self._lock:
            return len(self._entries)

    # ---------- 写 ----------

    def merge(self, route: str, videos: list[dict], *,
              now: float | None = None) -> tuple[int, int]:
        """把一轮抓取结果并进池子，返回 (新增, 刷新)。

        videos 为空是合法的（坑 10）。已在池中的刷新 added 并更新元数据
        （播放量、标题都可能变），**route 不动** —— 一个视频属于哪个分区
        在第一次入池时就定了，免得在分区之间跳来跳去。
        """
        now = time.time() if now is None else now
        added = refreshed = 0
        with self._lock:
            for video in videos:
                bvid = video['bvid']
                old = self._entries.get(bvid)
                if old is None:
                    self._entries[bvid] = {**video, 'route': route, 'added': now}
                    added += 1
                else:
                    old.update(video)
                    old['added'] = now
                    refreshed += 1
        return added, refreshed

    def prune(self, *, now: float | None = None) -> int:
        """删掉入池超过 TTL 的条目，返回删了几条。"""
        now = time.time() if now is None else now
        with self._lock:
            dead = [b for b, e in self._entries.items()
                    if now - e['added'] > self.ttl]
            for bvid in dead:
                del self._entries[bvid]
        if dead:
            log.debug('淘汰 %d 条（入池超过 %ds）', len(dead), self.ttl)
        return len(dead)

    def refresh(self, routes: Iterable[str], *,
                workers: int = DEFAULT_WORKERS,
                now: float | None = None) -> dict:
        """并发抓一批分区并并入池子，返回本轮报告。

        **单个分区失败不影响其他分区** —— 记进报告，该区上一轮的数据原样
        留着。抓不到数据分两种：请求报错进 errors，请求正常但没条目进
        empty（坑 10 的骨架屏）。两种都不动旧数据。
        """
        # 先实体化成列表：routes 是 Iterable，下面要既数一遍又遍历一遍，
        # 传生成器进来时 list() 会把它耗干（len(list(routes)) 就是现成的坑）。
        routes = list(routes)
        now = time.time() if now is None else now
        t0 = time.monotonic()
        report: dict = {'routes': 0, 'added': 0, 'refreshed': 0,
                        'empty': [], 'errors': {}}
        log.info('池子刷新开始：%d 个分区、%d 并发', len(routes), workers)

        with ThreadPoolExecutor(max_workers=workers) as pool:
            futures = [(route, pool.submit(self._fetch, route))
                       for route in routes]
            report['routes'] = len(futures)
            for route, future in futures:
                try:
                    videos = future.result()
                except Exception as exc:
                    report['errors'][route] = f'{type(exc).__name__}: {exc}'
                    log.warning('分区 %s 抓取失败：%s', route, exc)
                    continue
                if not videos:
                    report['empty'].append(route)
                    continue
                added, refreshed = self.merge(route, videos, now=now)
                report['added'] += added
                report['refreshed'] += refreshed
                log.debug('分区 %s：%d 条（新增 %d、刷新 %d）',
                          route, len(videos), added, refreshed)

        report['pruned'] = self.prune(now=now)
        with self._lock:
            self.last_refresh = now
        report['total'] = len(self)
        self.save()
        log.info('池子刷新完成：新增 %d、刷新 %d、淘汰 %d，共 %d 条（%.1fs）',
                 report['added'], report['refreshed'], report['pruned'],
                 report['total'], time.monotonic() - t0)
        # 空和失败分开报：空多半是坑 10（骨架屏，下一轮自己会好），
        # 失败才是要去看一眼的。混在一行里会分不清该不该管。
        if report['empty']:
            log.info('这轮返回空的分区 %d 个：%s（坑 10，下轮自动恢复）',
                     len(report['empty']), '、'.join(report['empty']))
        if report['errors']:
            log.warning('这轮抓失败的分区 %d 个：%s',
                        len(report['errors']), '、'.join(report['errors']))
        return report


class History:
    """{bvid: 上次展示的时间戳}。线程安全，落盘 JSON。"""

    def __init__(self, path: str | Path, *,
                 retain: float = DEFAULT_RETAIN) -> None:
        self.path = Path(path)
        self.retain = retain
        self._lock = threading.Lock()
        self._shown: dict[str, float] = {}
        self._load()

    def _load(self) -> None:
        if not self.path.exists():
            return
        blob = json.loads(self.path.read_text(encoding='utf-8'))
        self._shown = blob.get('shown', {})
        log.info('已展示记录从 %s 恢复 %d 条', self.path.name, len(self._shown))

    def save(self) -> None:
        with self._lock:
            blob = {'shown': dict(self._shown)}
        write_atomic(self.path, blob)

    @property
    def shown(self) -> dict[str, float]:
        """直接拿去当 sampling.sample 的 seen 参数。"""
        with self._lock:
            return dict(self._shown)

    def record(self, bvids: Iterable[str], *,
               now: float | None = None) -> int:
        """记一批刚展示出去的视频，顺带清掉超过保留期的，返回清掉几条。

        时间戳取"记下的那一刻"而非"看完的那一刻"：换一换点得飞快时中间那些
        根本没被看，按展示算正是想要的 —— 没看就不该重复出现。
        """
        now = time.time() if now is None else now
        # 边遍历边数：bvids 是 Iterable，server.py 传的就是个生成器，
        # 出了这个循环它已经空了（len(list(bvids)) 会数出 0 来）。
        count = 0
        with self._lock:
            for bvid in bvids:
                self._shown[bvid] = now
                count += 1
            dead = [b for b, ts in self._shown.items() if now - ts > self.retain]
            for bvid in dead:
                del self._shown[bvid]
            left = len(self._shown)
        log.debug('已展示记录：记下 %d 条、清掉 %d 条，现存 %d 条',
                  count, len(dead), left)
        return len(dead)

    def __len__(self) -> int:
        with self._lock:
            return len(self._shown)


DEFAULT_SETTINGS = {
    'quota': {},                  # {route: 0-10}，没单独设过的用 quota_default
    'quota_default': 5,
    'min_seconds': 5 * 60,        # 时长下限
    'n': 30,                      # 一次显示几条
    'seen_window': 12 * 3600,     # 已展示排除窗口
    'refresh_interval': 30 * 60,  # 池子刷新间隔
    'ttl': 24 * 3600,             # 池子条目存活时间
}

# 每个旋钮的合法范围，越界就报错。'quota' 单独处理（它是个字典）。
_LIMITS = {
    'quota_default': (0, 10),
    'min_seconds': (0, 24 * 3600),
    'n': (1, 200),
    'seen_window': (0, 7 * 24 * 3600),
    'refresh_interval': (60, 24 * 3600),
    'ttl': (60, 30 * 24 * 3600),
}


def check_n_override(n: int) -> None:
    """校验 `/api/feed?n=` 的一次性覆盖值，不合法抛 ValueError。

    它绕过 Settings.update 直接被 server 递给 sampling，不把这道关的话
    `rng.sample(x, -1)` 会一路冒成 HTTP 500。范围跟设置**共用 _LIMITS**。
    """
    lo, hi = _LIMITS['n']
    if not isinstance(n, int) or isinstance(n, bool):
        raise ValueError(f'n 要是整数，收到 {type(n).__name__}')
    if not lo <= n <= hi:
        raise ValueError(f'n 要在 {lo}~{hi} 之间，收到 {n}')


class Settings:
    """界面上的旋钮。线程安全，落盘 JSON。

    **只存用户改过的项**，读的时候和默认值合并 —— 将来调了默认值，
    没动过设置的人能跟着变，动过的人保持自己的选择。
    """

    def __init__(self, path: str | Path,
                 *, defaults: dict | None = None) -> None:
        self.path = Path(path)
        self._defaults = dict(defaults or DEFAULT_SETTINGS)
        self._lock = threading.Lock()
        self._changed: dict = {}
        self._load()

    def _load(self) -> None:
        if not self.path.exists():
            return
        blob = json.loads(self.path.read_text(encoding='utf-8'))
        self._changed = blob.get('settings', {})
        log.info('设置从 %s 恢复 %d 项改动：%s',
                 self.path.name, len(self._changed), sorted(self._changed))

    def save(self) -> None:
        with self._lock:
            blob = {'settings': dict(self._changed)}
        write_atomic(self.path, blob)

    def get(self) -> dict:
        with self._lock:
            return self._defaults | self._changed

    def update(self, patch: dict) -> dict:
        """局部更新，返回更新后的全部设置。不合法就抛 ValueError。"""
        allowed = set(self._defaults)
        unknown = set(patch) - allowed
        if unknown:
            raise ValueError(f'不认识的设置项：{sorted(unknown)}')

        for key, value in patch.items():
            if key == 'quota':
                _check_quota(value)
                continue
            lo, hi = _LIMITS[key]
            if not isinstance(value, int) or isinstance(value, bool):
                raise ValueError(f'{key} 要是整数，收到 {type(value).__name__}')
            if not lo <= value <= hi:
                raise ValueError(f'{key} 要在 {lo}~{hi} 之间，收到 {value}')

        before = self.get()
        with self._lock:
            self._changed.update(patch)
        self.save()
        log.info('设置更新：%s', _describe_patch(patch, before, self.get()))
        return self.get()

    def quota_for(self, routes: Iterable[str]) -> dict[str, int]:
        """给每个分区补上权重。没单独设过的用 quota_default。

        **只返回 routes 里有的分区** —— 池子里可能留着已下线的分区。
        """
        with self._lock:
            quota = dict(self._changed.get('quota') or {})
            default = self._changed.get('quota_default',
                                        self._defaults['quota_default'])
        return {route: quota.get(route, default) for route in routes}


def _describe_patch(patch: dict, before: dict, after: dict) -> str:
    """把一次设置更新摊成一行，排查时要能看清客户端到底发了什么。

    对比的是**合并默认值之后**的视图 —— 那才是用户眼里的值。
    """
    parts = []
    for key, value in patch.items():
        if key == 'quota':
            old = before.get('quota') or {}
            changed = [(r, old.get(r), v) for r, v in value.items()
                       if old.get(r) != v]
            if not changed:
                parts.append('quota 无变化')
                continue
            shown = '、'.join(f'{r} {o}→{v}' for r, o, v in changed[:4])
            more = f'（共 {len(changed)} 项）' if len(changed) > 4 else ''
            parts.append(f'quota {shown}{more}')
        else:
            parts.append(f'{key} {before.get(key)}→{after.get(key)}')
    return '；'.join(parts) if parts else '（空 patch）'


def _check_quota(quota) -> None:
    """权重校验。**允许 0**（这一轮不给这个分区配额）—— 界面滑块是 1~10，
    但 sampling 本来就按"配额 ≤ 0 就跳过"处理，两层对齐才不会打架。
    """
    if not isinstance(quota, dict):
        raise ValueError(f'quota 要是 {{分区: 权重}} 字典，'
                         f'收到 {type(quota).__name__}')
    for route, value in quota.items():
        if not isinstance(value, int) or isinstance(value, bool):
            raise ValueError(f'{route} 的权重要是整数，收到 {type(value).__name__}')
        if not 0 <= value <= 10:
            raise ValueError(f'{route} 的权重要在 0~10 之间，收到 {value}')


if __name__ == '__main__':
    import tempfile

    from bilibili import fetch_channel_list

    # 拿真数据跑一遍完整刷新：抓 31 个分区 → 入池 → 落盘 → 打印分布
    with tempfile.TemporaryDirectory() as tmp:
        pool = Pool(Path(tmp) / 'pool.json')
        routes = list(fetch_channel_list())
        print(f'分区 {len(routes)} 个，开始抓……')
        report = pool.refresh(routes)
        print(f'新增 {report["added"]}，刷新 {report["refreshed"]}，'
              f'淘汰 {report["pruned"]}，池中共 {report["total"]} 条')
        if report['empty']:
            print(f'返回空的分区：{report["empty"]}（坑 10，正常）')
        for route, err in report['errors'].items():
            print(f'  抓不到 {route}: {err[:70]}')

        # 再刷一次
        report2 = pool.refresh(routes)
        print(f'二轮：新增 {report2["added"]}，刷新 {report2["refreshed"]}')

        # 落盘后重开，数据应该还在
        again = Pool(Path(tmp) / 'pool.json')
        print(f'重开后池中共 {len(again)} 条')
        sample = again.entries()[0]
        print(f'样例条目：{sample["title"][:26]!r} {sample["play"]} 播放 '
              f'{sample["seconds"]}s')
