from __future__ import annotations

import json
import logging
import re
from typing import TYPE_CHECKING

from bs4 import BeautifulSoup

from fetch import fetch_html, fetch_json

if TYPE_CHECKING:
    import requests

log = logging.getLogger('youyuan.bilibili')

_HOME = 'https://www.bilibili.com/'

# 调接口必须显式覆盖 Referer —— fetch.py 默认填的是 api.bilibili.com 自己，
# 那样会被风控软拦（坑 4）。
_API_HEADERS = {
    'Accept': '*/*',
    'Referer': _HOME,
    'Origin': 'https://www.bilibili.com',
}


# ============ 纯解析：吃已经抓好的内容，不碰网络，可离线测试 ============


def parse_channel_list(html: str) -> dict[str, dict]:
    """从首页 HTML 提取 /c/ 分区，返回 {route: 分区信息}。

    两道筛选都过才留：有 channelId（滤掉 all / sort 这类导航项）、
    url 含 /c/（滤掉 6 个 PGC 分区和指向独立域名的）。信息只留
    name / channelId / sub，分区页地址由 key 拼成 `{_HOME}c/{route}/`。

    找不到 channel_list 或某条解析失败时抛 ValueError。
    """
    # side_channel_list 是兄弟键，拿它当右边界圈出 channel_list 的内容
    block_re = re.compile(r'channel_list:{(.*?)},side_channel_list')

    # 条目形如 key:"<转义过的 JSON>"，收尾引号用 [^\\]" 判定
    entry_re = re.compile(r'(\w+):(".*?[^\\]")')

    block = block_re.search(html)
    if block is None:
        raise ValueError('HTML 里找不到 channel_list')

    channels = {}
    for entry in entry_re.finditer(block.group(1)):
        key, raw = entry.group(1), entry.group(2)
        try:
            # 第一层解 JS 字符串转义，第二层解内层 JSON
            value = json.loads(json.loads(raw))
        except json.JSONDecodeError as exc:
            raise ValueError(f'频道 {key!r} 解析失败: {exc}') from exc

        if (isinstance(value, dict)
                and value.get('channelId') is not None
                and '/c/' in value.get('url', '')):
            channels[key] = {
                'name': value['name'],
                'channelId': value['channelId'],
                'sub': [
                    {'name': s['name'], 'route': s['route'],
                     'subChannelId': s['subChannelId']}
                    for s in value.get('sub') or []
                ],
            }
    log.debug('分区目录解析出 %d 个分区', len(channels))
    return channels


def _to_seconds(duration: str) -> int:
    """'12:07' -> 727，'1:02:33' -> 3753。"""
    parts = [int(p) for p in duration.split(':')]
    if len(parts) == 2:
        return parts[0] * 60 + parts[1]
    return parts[0] * 3600 + parts[1] * 60 + parts[2]


def _parse_count(text: str) -> int:
    """把显示用计数转成整数：'2157' -> 2157，'233.8万' -> 2338000。"""
    unit = {'万': 10_000, '亿': 100_000_000}.get(text[-1:])
    if unit is None:
        return int(text)
    return round(float(text[:-1]) * unit)


def _author_name(raw: str) -> str:
    """'星球研究所 · 08-04' -> '星球研究所'。"""
    return raw.rsplit(' · ', 1)[0] if ' · ' in raw else raw


def _card_title(card) -> str:
    """取卡片标题：优先 `title` 属性（完整），退而取文本（可能被截断）。

    偶有空 `title` 的卡片（约 1/300），收进去就是客户端上一个空白格子，
    所以拿不到标题的直接丢掉。
    """
    el = card.select_one('.bili-video-card__title')
    if el is None:
        return ''
    return el.get('title') or el.get_text(strip=True)


def parse_section_videos(html: str) -> list[dict]:
    """从分区页 HTML 提取视频列表（服务端渲染 15 条，见坑 10、坑 12）。

    公共字段与 parse_video_info 同名同义。拿不到标题的卡片会被跳过，
    所以返回条数可能少于 15。这里只有相对时间标签，要时间戳得走详情。
    """
    soup = BeautifulSoup(html, 'html.parser')
    videos = []
    skipped = 0

    for card in soup.select('div.feed-card.head-card'):
        title = _card_title(card)
        if not title:
            skipped += 1
            continue

        href = card.select_one('a.bili-cover-card')['href']
        stats = [s.get_text(strip=True) for s in card.select('.bili-cover-card__stat')]

        videos.append({
            'bvid': re.search(r'/video/(BV\w+)', href).group(1),
            'title': title,
            'mid': int(re.search(r'space\.bilibili\.com/(\d+)',
                                 card.select_one('a.bili-video-card__author')['href']).group(1)),
            'author': _author_name(
                card.select_one('a.bili-video-card__author span[title]')['title']),
            'cover': card.select_one('.bili-cover-card__thumbnail img')['src'],
            'seconds': _to_seconds(stats[2]),
            'play': _parse_count(stats[0]),
            'danmaku': _parse_count(stats[1]),
        })

    # 0 条多半是坑 10（骨架屏），报警交给调用方记进报告的 empty
    log.debug('分区页解析出 %d 条，跳过 %d 张无标题卡片', len(videos), skipped)
    return videos


def parse_video_info(payload: dict, p: int = 1) -> dict:
    """从 view 接口响应提取视频详情（走接口不走 HTML，见坑 9）。

    公共字段与 parse_section_videos 同名同义。seconds 是**所有分P的总时长**，
    part_seconds 才是当前分P的；cid / part_seconds 都指向 p 指定的那一P。
    """
    if payload.get('code') != 0:
        raise ValueError(f'view 接口返回 code={payload.get("code")}: '
                         f'{payload.get("message")}')

    d = payload['data']
    stat = d['stat']

    # 接口给的 cid / duration 永远是第 1P 的，跟 p 无关（坑 2）。
    # p 越界就退回它，不抛异常。
    pages = d.get('pages') or []
    current = next((pg for pg in pages if pg['page'] == p), None)

    # 越界会静默退回第 1P —— 最容易让人以为接口错了，所以记下来
    if pages and current is None:
        log.warning('%s 没有第 %d 个分P（共 %d 个），退回第 1P 的 cid',
                    d['bvid'], p, len(pages))
    log.debug('详情 %s p=%d → cid=%s 本P %ss 共 %d 个分P',
              d['bvid'], p, current['cid'] if current else d['cid'],
              current['duration'] if current else d['duration'], len(pages))

    return {
        'bvid': d['bvid'],
        'aid': d['aid'],
        'cid': current['cid'] if current else d['cid'],
        'p': p,
        'title': d['title'],
        'desc': d['desc'],
        'mid': d['owner']['mid'],
        'author': d['owner']['name'],
        'cover': d['pic'],
        'seconds': d['duration'],
        'part_seconds': current['duration'] if current else d['duration'],
        'pubdate': d['pubdate'],
        'play': stat['view'],
        'danmaku': stat['danmaku'],
        'like': stat['like'],
        'favorite': stat['favorite'],
        'coin': stat['coin'],
        'pages': [
            {'cid': pg['cid'], 'page': pg['page'],
             'title': pg['part'], 'seconds': pg['duration']}
            for pg in pages
        ],
    }


def parse_play_info(payload: dict) -> dict:
    """从 playurl 响应提取音视频流地址。

    返回 quality / accept_quality / duration / video / audio。audio 项的
    codecid 恒为 0（音频没有编码编号，看 codecs 就行）。

    两级校验：code 非 0 报错；code 为 0 但没 dash 也报错 —— 后者是风控
    软拦，data 里只有一个 v_voucher 令牌（坑 5）。
    """
    if payload.get('code') != 0:
        raise ValueError(f'playurl 返回 code={payload.get("code")}: '
                         f'{payload.get("message")}')

    data = payload['data']
    dash = data.get('dash')
    if dash is None:
        raise ValueError(f'接口没返回 dash 流（多半是风控拦截）：'
                         f'data 的键 = {list(data)}')

    video = [
        {'id': v['id'], 'codecid': v['codecid'], 'codecs': v['codecs'],
         'width': v['width'], 'height': v['height'],
         'url': v['baseUrl'], 'backup_url': v['backupUrl']}
        for v in dash['video']
    ]
    audio = [
        {'id': a['id'], 'codecid': a['codecid'], 'codecs': a['codecs'],
         'url': a['baseUrl'], 'backup_url': a['backupUrl']}
        for a in dash['audio']
    ]

    # 必须排（坑 7）：接口给的顺序不稳定，不排的话 [0] 取到哪个是随机的。
    # 主键 id 降序（越大越好），次键 codecid 升序（7=AVC 兼容最好 → 13=AV1）。
    video.sort(key=lambda s: (-s['id'], s['codecid']))
    audio.sort(key=lambda s: (-s['id'], s['codecid']))

    log.debug('流：%d 档画质（最高 %dp/%s），%d 档音质（最高 %d/%s），时长 %ss',
              len(video), video[0]['height'] if video else 0,
              video[0]['codecs'] if video else '无',
              len(audio), audio[0]['id'] if audio else 0,
              audio[0]['codecs'] if audio else '无', dash['duration'])

    return {
        'quality': data['quality'],
        'accept_quality': data['accept_quality'],
        'duration': dash['duration'],
        'video': video,
        'audio': audio,
    }


# ============ 网络封装：自己拼地址并抓取，交给上面的解析 ============


def fetch_channel_list(*, timeout: float = 10.0,
                       session: requests.Session | None = None) -> dict[str, dict]:
    """抓 B 站首页并解析出分区目录。"""
    return parse_channel_list(fetch_html(_HOME, timeout=timeout, session=session))


def fetch_section_videos(route: str, *, timeout: float = 10.0,
                         session: requests.Session | None = None) -> list[dict]:
    """抓某个分区页并解析出视频列表。route 是分区 key，如 'knowledge'。"""
    return parse_section_videos(
        fetch_html(f'{_HOME}c/{route}/', timeout=timeout, session=session))


def fetch_video_info(bvid: str, *, p: int = 1, timeout: float = 10.0,
                     session: requests.Session | None = None) -> dict:
    """调 view 接口取视频详情。p 指定分P（从 1 开始），默认第 1 个。"""
    payload = fetch_json('https://api.bilibili.com/x/web-interface/view',
                         params={'bvid': bvid}, timeout=timeout,
                         headers=_API_HEADERS, session=session)
    return parse_video_info(payload, p)


def fetch_play_info(bvid: str, cid: int, *, fnval: int = 4048,
                    timeout: float = 10.0,
                    session: requests.Session | None = None) -> dict:
    """调 playurl 取指定分P的音视频流地址。cid 用详情接口返回的那个。

    fnval 是位掩码，默认 4048 全都要；不给只会返回老格式 durl（坑 6）。
    下载这些流要带同样的请求头，主 CDN 不带 Referer 会 403（坑 8）。
    """
    payload = fetch_json('https://api.bilibili.com/x/player/wbi/playurl',
                         params={'bvid': bvid, 'cid': cid, 'fnval': fnval},
                         timeout=timeout, headers=_API_HEADERS, session=session)
    return parse_play_info(payload)


if __name__ == '__main__':
    channels = fetch_channel_list()
    print(f'分区 {len(channels)} 个')

    videos = fetch_section_videos('game')
    print(f'game 分区 {len(videos)} 条，第一条 {videos[0]["title"][:24]!r}')

    info = fetch_video_info(videos[0]['bvid'])
    print(f'详情 {info["title"][:24]!r} p={info["p"]} cid={info["cid"]} '
          f'本P {info["part_seconds"]}s')

    play = fetch_play_info(info['bvid'], info['cid'])
    print(f'流 {len(play["video"])} 视频 + {len(play["audio"])} 音频，'
          f'时长 {play["duration"]}s')