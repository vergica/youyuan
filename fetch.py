"""模拟浏览器抓取网页和接口的通用工具。"""

import json
import logging
import time
from typing import Any
from urllib.parse import urlsplit

import requests

log = logging.getLogger('youyuan.fetch')

DEFAULT_HEADERS = {
    'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
                  '(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36',
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
}


def _request(
    url: str,
    *,
    params: dict | None = None,
    timeout: float,
    headers: dict[str, str] | None = None,
    session: requests.Session | None = None,
) -> requests.Response:
    """发 GET、套默认头、检查状态码。

    Referer 默认取目标 URL 的 origin —— **调接口时必须用 headers 覆盖**，
    否则会被风控软拦（CLAUDE.md 坑 4）。
    """
    parts = urlsplit(url)
    request_headers = dict(DEFAULT_HEADERS)
    if parts.scheme and parts.netloc:
        request_headers['Referer'] = f'{parts.scheme}://{parts.netloc}/'
    if headers:
        request_headers.update(headers)

    http = session if session is not None else requests
    t0 = time.monotonic()
    try:
        r = http.get(url, headers=request_headers, params=params, timeout=timeout)
        r.raise_for_status()
    except requests.RequestException as exc:
        log.warning('GET %s 失败（%.0fms）：%s',
                    url, (time.monotonic() - t0) * 1000, exc)
        raise
    log.debug('GET %s → %s %dB %.0fms', r.url, r.status_code,
              len(r.content), (time.monotonic() - t0) * 1000)
    return r


def fetch_html(
    url: str,
    *,
    timeout: float = 10.0,
    headers: dict[str, str] | None = None,
    session: requests.Session | None = None,
) -> str:
    """抓取 url 并返回网页文本，失败时抛 requests 异常。

    headers 会覆盖默认请求头，用于自定义 User-Agent、Cookie 等。
    需要跨请求复用连接或维持登录态时，传入自己的 session。
    """
    r = _request(url, timeout=timeout, headers=headers, session=session)

    if 'charset' not in r.headers.get('content-type', '').lower():
        r.encoding = r.apparent_encoding or r.encoding

    return r.text


def fetch_json(
    url: str,
    *,
    params: dict | None = None,
    timeout: float = 10.0,
    headers: dict[str, str] | None = None,
    session: requests.Session | None = None,
) -> Any:
    """抓取接口并返回解析后的 JSON，失败时抛 requests 异常或 ValueError。

    headers 覆盖默认请求头。
    响应不是 JSON 时抛 ValueError 并附上开头内容，便于认出错误页。
    """
    r = _request(url, params=params, timeout=timeout,
                 headers=headers, session=session)
    try:
        return r.json()
    except json.JSONDecodeError as exc:
        raise ValueError(f'{url} 返回的不是 JSON，开头是：{r.text[:80]!r}') from exc
