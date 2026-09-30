"""FastAPI 后端。

**只做翻译** —— 把 HTTP 请求翻成对 pool / history / sampling / settings
的调用，自己不含业务判断。

    uv run server.py [--host H] [--port P] [--reload] [--log-level L]

**默认监听 0.0.0.0 且无认证**，别往公网放（CLAUDE.md「待决事项」）。
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import logging
import os
import threading
import time
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Mapping

from fastapi import FastAPI, HTTPException

import sampling
from bilibili import fetch_channel_list, fetch_video_info
from store import History, Pool, Settings, check_n_override

log = logging.getLogger('youyuan.server')


def _setup_logging(level: str = 'INFO') -> None:
    """**只有这个模块配置日志**，其余模块只 getLogger —— 否则演示脚本的
    输出会被日志淹掉。"""
    logging.basicConfig(
        level=getattr(logging, level.upper(), logging.INFO),
        format='%(asctime)s %(levelname)-7s %(name)s: %(message)s',
        datefmt='%m-%d %H:%M:%S',
        force=True,
    )


# 模块级先配一次，这样 `uvicorn server:app` 直接起也有日志
_setup_logging(os.environ.get('YOUYUAN_LOG', 'INFO'))

# 用环境变量而不是命令行参数：`--reload` 时 uvicorn 在子进程里重新导入本模块，
# 父进程的 argparse 参数传不过去，环境变量才能跨过去。
DATA = Path(os.environ.get('YOUYUAN_DATA') or Path(__file__).parent / 'data')

pool = Pool(DATA / 'pool.json')
history = History(DATA / 'history.json')
settings = Settings(DATA / 'settings.json')

# 分区目录。启动时抓一次，之后每轮刷新顺带更新；抓不到就沿用上一份。
_channels: dict[str, dict] = {}


def _sync_channels() -> dict[str, dict]:
    """刷新分区目录。**抓失败不抛** —— 它在后台循环里跑，一次网络抖动
    不该让循环停摆，沿用上一份继续刷。"""
    global _channels
    try:
        _channels = fetch_channel_list()
        log.debug('分区目录已更新：%d 个分区', len(_channels))
    except Exception as exc:
        log.warning('抓分区目录失败，沿用上一份（%d 个分区）：%s',
                    len(_channels), exc)
    return _channels


def _refresh_blocking() -> dict:
    """抓一轮并入库。阻塞调用，由 asyncio.to_thread 包起来跑。"""
    channels = _sync_channels()
    pool.ttl = settings.get()['ttl']
    report = pool.refresh(list(channels))
    log.info('池子刷新：新增 %d，刷新 %d，淘汰 %d，共 %d 条；空分区 %s；失败 %s',
             report['added'], report['refreshed'], report['pruned'],
             report['total'], report['empty'] or '无', report['errors'] or '无')
    return report


# 启动时连抓几轮。**不是 1** —— 见 _refresh_loop。
STARTUP_REFRESHES = 2


async def _refresh_once() -> None:
    """抓一轮。**出错只记不停** —— 这条循环是后端唯一的数据来源，
    停一次池子就只出不进。"""
    try:
        await asyncio.to_thread(_refresh_blocking)
    except Exception:
        log.exception('池子刷新出错')


async def _refresh_loop() -> None:
    """抓一轮 → 睡 refresh_interval → 再抓一轮。

    **启动时连抓两轮，中间不睡**：池子刚起来太小（一轮约 420 条，再被
    时长下限滤掉大半），连点几次「换一换」就见底。第一轮算预热，
    第二轮才算周期里的第一次。
    """
    for _ in range(STARTUP_REFRESHES):
        await _refresh_once()
    while True:
        await asyncio.sleep(settings.get()['refresh_interval'])
        await _refresh_once()


@asynccontextmanager
async def lifespan(app: FastAPI):
    # 先把分区目录抓下来（就一个请求，很快），这样 /api/channels 一上来就能用；
    # 池子刷新慢，扔后台跑，不挡启动。
    await asyncio.to_thread(_sync_channels)
    task = asyncio.create_task(_refresh_loop())
    log.info('后端起来了：%d 个分区，池子文件 %s', len(_channels), pool.path)
    try:
        yield
    finally:
        task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await task


app = FastAPI(title='youyuan', lifespan=lifespan)


# ============ 请求体 ============
#
# **故意不用 pydantic 模型**：它会在 store.Settings.update 之前静默地把
# `'30'` 转成 30、把 `true` 转成 1、把不认识的键丢掉，于是 store 那套校验
# 在 HTTP 路径上大半够不着（详见 CLAUDE.md 坑 13）。收原始 dict，校验就
# 只剩 store 一份，报错统一是中文 400。代价是 /docs 里不再显示具名字段。


def _current_settings() -> dict:
    """设置 + 补齐过的各分区权重。让界面一次拿全，不用自己合并默认值。"""
    return settings.get() | {'quota': settings.quota_for(_channels)}


# /api/feed 是「读已展示记录 → 采样 → 写回」，**这三步必须一气呵成**：
# 不加锁时两个并发请求会读到同一份快照、返回重叠内容（apitest 并发组能撞出来）。
# 锁放这一层，因为 sampling 和 history 各自都线程安全，不安全的是它俩的组合。
_feed_lock = threading.Lock()


def _log_feed(stats: dict, quota: Mapping[str, int]) -> None:
    """把这一轮采样的各段计数摊成日志 —— 「为什么只有 3 条」的答案在这。

    第一行从左往右读就是一条条目被淘汰的顺序；第二行只说"不正常"的部分，
    正常时不打。见 CLAUDE.md「日志」一节。
    """
    log.info('feed: 池 %d → 时长滤 %d → 无配额 %d → 已看过 %d → 候选 %d → 抽中 %d',
             stats['pool'], stats['too_short'], stats['no_quota'],
             stats['hidden'], stats['candidates'], stats['picked'])

    routes = stats['routes']
    silent = [r for r, w in quota.items() if w > 0 and r not in routes]
    starved = [f'{r}(配 {v["quota"]} 得 {v["took"]})'
               for r, v in routes.items() if v['took'] < v['quota']]
    bits = []
    if silent:
        bits.append(f'{len(silent)} 个分区够格的一条都没有：{"、".join(silent)}')
    if starved:
        bits.append(f'{len(starved)} 个分区配额没喂饱：{"、".join(starved)}')
    if stats['picked'] < stats['n']:
        bits.append(f'要 {stats["n"]} 条只凑出 {stats["picked"]} 条')
    if bits:
        log.info('feed: %s', '；'.join(bits))
    log.debug('feed 每区明细：%s', '、'.join(
        f'{r} 够{v["pool"]}/配{v["quota"]}/出{v["took"]}'
        for r, v in sorted(routes.items())))


# ============ 路由 ============


@app.get('/api/channels')
def get_channels() -> list[dict]:
    """分区目录 + 每区当前权重，主界面拿它渲染 31 个滑块。

    route 也是池子里条目的 route 字段，name 是显示名。
    """
    quota = settings.quota_for(_channels)
    log.debug('要分区目录：%d 个', len(_channels))
    return [{'route': route, 'name': c['name'], 'quota': quota[route]}
            for route, c in _channels.items()]


@app.get('/api/settings')
def get_settings() -> dict:
    log.debug('要设置')
    return _current_settings()


@app.put('/api/settings')
def put_settings(patch: dict) -> dict:
    """局部更新设置 —— 只传要改的键。

    校验全在 store.Settings.update 里（未知键、类型、范围），这里只把
    ValueError 翻成 400。理由见上面「请求体」那段。
    """
    try:
        settings.update(patch)
    except ValueError as exc:
        raise HTTPException(400, str(exc)) from exc
    # 池子的 TTL 是它自己的一份，改了设置要马上同步过去
    pool.ttl = settings.get()['ttl']
    return _current_settings()


@app.get('/api/feed')
def get_feed(n: int | None = None) -> dict:
    """取这一轮要展示的视频。首次加载和「换一换」都是它。

    **会改状态** —— 结果记进已展示记录，所以连点两次不会刷出同一批。

    n 是一次性覆盖（不改设置），范围跟设置共用一份，越界 400；不校验的话
    `?n=-1` 会一路走到 rng.sample 抛 ValueError，变成 500。
    """
    if n is not None:
        try:
            check_n_override(n)
        except ValueError as exc:
            raise HTTPException(400, str(exc)) from exc
    config = settings.get()
    entries = pool.entries()
    quota = settings.quota_for(_channels)
    stats: dict = {}
    # 快照 → 采样 → 记录，全程持锁。见 _feed_lock 那段。
    # pool.entries() 放在锁外：它有自己的锁，而且那个浅拷贝是 O(池子大小)。
    with _feed_lock:
        picked = sampling.sample(
            entries,
            quota,
            n=config['n'] if n is None else n,
            min_seconds=config['min_seconds'],
            seen=history.shown,
            seen_window=config['seen_window'],
            stats=stats,
        )
        if picked:
            history.record(e['bvid'] for e in picked)
            history.save()
    _log_feed(stats, quota)
    return {'items': picked, 'pool_total': len(entries)}


@app.get('/api/video/{bvid}')
def get_video(bvid: str, p: int = 1) -> dict:
    """视频详情，含分P清单和 cid —— 客户端拿 cid 去调 playurl。

    池子里的条目**没有 cid**，所以播放前得来这儿换一次。
    """
    t0 = time.monotonic()
    try:
        info = fetch_video_info(bvid, p=p)
    except Exception as exc:
        log.warning('取详情 %s p=%d 失败（%.0fms）：%s',
                    bvid, p, (time.monotonic() - t0) * 1000, exc)
        raise HTTPException(502, f'取视频详情失败：{exc}') from exc
    log.info('取详情 %s p=%d → cid=%s，%d 个分P（%.0fms）',
             bvid, p, info['cid'], len(info['pages']),
             (time.monotonic() - t0) * 1000)
    return info


@app.get('/api/pool/status')
def get_pool_status() -> dict:
    """池子有多少条、各区分布、上次刷新时间。"""
    status = pool.status()
    log.debug('要池子状态：%d 条 / %d 个分区 / 已展示记录 %d 条',
              status['total'], len(status['by_route']), len(history))
    return status | {'refresh_interval': settings.get()['refresh_interval'],
                     'ttl': settings.get()['ttl'],
                     'shown': len(history)}


@app.post('/api/pool/refresh')
async def post_pool_refresh() -> dict:
    """手动触发一次刷新并返回本轮报告。调试用，正常情况下不用碰。"""
    return await asyncio.to_thread(_refresh_blocking)


def main() -> None:
    parser = argparse.ArgumentParser(description='youyuan 后端')
    parser.add_argument('--host', default='0.0.0.0',
                        help='监听地址（默认 0.0.0.0，即所有网卡）')
    parser.add_argument('--port', type=int, default=8000)
    parser.add_argument('--reload', action='store_true', help='改代码自动重载')
    parser.add_argument('--log-level', default=os.environ.get('YOUYUAN_LOG', 'INFO'),
                        help='DEBUG 能看到每个请求、每个分区的抓取明细（默认 INFO）')
    args = parser.parse_args()

    _setup_logging(args.log_level)
    if args.log_level.upper() == 'DEBUG':
        log.debug('DEBUG 级别已开，数据目录 %s', DATA)
    if args.host == '0.0.0.0':
        log.warning('监听 0.0.0.0 且没有认证，同网段/公网任何人都能访问')

    import uvicorn
    # --reload 要传 import 字符串，uvicorn 才能在子进程里重新导入
    uvicorn.run('server:app' if args.reload else app,
                host=args.host, port=args.port, reload=args.reload)


if __name__ == '__main__':
    main()
