
"""retriever.py - arXiv 论文抓取模块（官方 Atom API 版）

数据源
------
``https://export.arxiv.org/api/query`` —— arXiv 官方 Atom API。

相比旧实现（抓取 arxiv.org 搜索页 + BeautifulSoup 解析 HTML）：

* **稳定**：返回结构化 Atom XML，不再依赖 ``li.arxiv-result`` 这类未公开
  承诺的页面类名，arXiv 改版不会直接导致解析全线失败；
* **零额外依赖**：用标准库 ``xml.etree.ElementTree`` 解析，可移除
  ``beautifulsoup4``；
* **可控**：支持分页（``start`` / ``max_results``）、排序、超时、重试与限速。

网络约定（对齐 arXiv API 使用条款）
-----------------------------------
* 单连接串行，不做并发请求；
* 请求间隔 >= ``min_interval``（默认 3 秒），仅在分页时生效；
* 携带描述性 ``User-Agent``（可用环境变量 ``ARXIV_USER_AGENT`` 覆盖）；
* 超时 ``(连接, 读取)`` 默认 ``(10, 30)`` 秒；
* 429 / 5xx 指数退避重试，并尊重 ``Retry-After``。

输出约定
--------
``{"title", "authors", "url", "abstract", "submission_time"}``

* 解析失败填空字符串或 ``"N/A"``，不抛异常，保证下游可用；
* ``submission_time`` 归一化为 ``YYYY-MM-DD``；
* ``url`` 归一化为 ``https://arxiv.org/abs/<id>`` 并**去掉版本号后缀 vN**，
  与 ``papers_metadata.json`` 中既有记录形态一致，否则去重会失效。

注意
----
模块不做去重、不落盘、不下载 PDF，这些由 ``main.py`` / ``executor.py`` 负责。
"""

import os
import re
import time
import xml.etree.ElementTree as ET

import requests

ATOM_API = "https://export.arxiv.org/api/query"
ATOM_NS = {"atom": "http://www.w3.org/2005/Atom"}

#: 默认请求头：描述性 UA，便于 arXiv 在异常流量时定位来源
DEFAULT_USER_AGENT = "new-paper-scraper/1.0 (arXiv Atom API client)"

#: 单次抓取的默认条数（与旧 HTML 实现的单页上限相当）
DEFAULT_MAX_RESULTS = 50

#: 分页时单页请求条数
PAGE_SIZE = 100

#: 需要重试的 HTTP 状态码
RETRY_STATUS = {429, 500, 502, 503, 504}


class _RetryableStatus(Exception):
    """可重试的 HTTP 状态（429 / 5xx）。"""

    def __init__(self, response):
        super().__init__(f"HTTP {response.status_code}")
        self.response = response


def _clean(text):
    """折叠空白：Atom 文本带缩进与换行，需要归一化。"""
    return " ".join((text or "").split())


def _entry_text(entry, path):
    node = entry.find(path, ATOM_NS)
    return _clean(node.text) if node is not None else ""


_ID_RE = re.compile(r"arxiv\.org/abs/([^/?#]+)", re.IGNORECASE)
_VERSION_RE = re.compile(r"v\d+$", re.IGNORECASE)


def _entry_url(entry):
    """归一化为 https://arxiv.org/abs/<id>（去掉版本号，保证可去重）。"""
    href = ""
    for link in entry.findall("atom:link", ATOM_NS):
        if link.get("rel") == "alternate":
            href = link.get("href") or ""
            break
    if not href:
        href = _entry_text(entry, "atom:id")
    match = _ID_RE.search(href)
    if not match:
        return "N/A"
    return "https://arxiv.org/abs/" + _VERSION_RE.sub("", match.group(1))


def _entry_authors(entry):
    names = [_clean(node.text)
             for node in entry.findall("atom:author/atom:name", ATOM_NS)]
    names = [n for n in names if n]
    return ", ".join(names) if names else "N/A"


def _entry_abstract(entry):
    text = _entry_text(entry, "atom:summary")
    if text.lower().startswith("abstract:"):
        text = text[len("abstract:"):].strip()
    return text or "N/A"


def _entry_date(entry, path):
    """取 ``<published>``（v1 提交日）并归一化为 YYYY-MM-DD。"""
    raw = _entry_text(entry, path)
    match = re.match(r"(\d{4})-(\d{2})-(\d{2})", raw)
    return f"{match.group(1)}-{match.group(2)}-{match.group(3)}" if match else "N/A"


def parse_atom(xml_text):
    """把 Atom XML 解析为统一的论文字典列表；解析失败返回空列表。"""
    try:
        root = ET.fromstring(xml_text)
    except ET.ParseError as exc:
        print(f"[Retriever] Atom 解析失败: {exc}")
        return []

    papers = []
    for entry in root.findall("atom:entry", ATOM_NS):
        papers.append({
            "title": _entry_text(entry, "atom:title") or "N/A",
            "authors": _entry_authors(entry),
            "url": _entry_url(entry),
            "abstract": _entry_abstract(entry),
            "submission_time": _entry_date(entry, "atom:published"),
        })
    return papers


class Retriever:
    """arXiv 官方 Atom API 客户端。

    同一实例内请求串行执行，不会并发访问 arXiv。
    """

    def __init__(self, user_agent=None, timeout=(10, 30), min_interval=3.0,
                 max_retries=3, backoff=2.0, session=None):
        self.user_agent = (user_agent
                           or os.environ.get("ARXIV_USER_AGENT")
                           or DEFAULT_USER_AGENT)
        self.timeout = timeout
        self.min_interval = max(0.0, float(min_interval))
        self.max_retries = max(0, int(max_retries))
        self.backoff = max(1.0, float(backoff))
        self.session = session or requests.Session()
        self.session.headers.update({"User-Agent": self.user_agent})
        # 兼容旧字段名（历史脚本可能引用）
        self.base_url = "https://arxiv.org"
        self.search_url = ATOM_API
        self._last_request_at = 0.0

    # ---- 网络 ----

    def _throttle(self):
        """保证两次请求之间至少间隔 min_interval 秒。"""
        if self.min_interval <= 0:
            return
        wait = self.min_interval - (time.monotonic() - self._last_request_at)
        if wait > 0:
            time.sleep(wait)

    @staticmethod
    def _retry_delay(response, attempt, backoff):
        """优先尊重 Retry-After，否则指数退避。"""
        header = response.headers.get("Retry-After") if response is not None else None
        if header:
            try:
                return max(0.0, float(header))
            except ValueError:
                pass  # HTTP-date 形式，退回指数退避
        return backoff ** attempt

    def _get(self, params):
        """带超时 / 限速 / 退避重试的单次 GET；最终失败返回 None。"""
        last_error = None
        for attempt in range(self.max_retries + 1):
            self._throttle()
            response = None
            try:
                response = self.session.get(ATOM_API, params=params,
                                            timeout=self.timeout)
                self._last_request_at = time.monotonic()
                if response.status_code in RETRY_STATUS:
                    raise _RetryableStatus(response)
                response.raise_for_status()
                return response.text
            except _RetryableStatus as exc:
                last_error = exc
                delay = self._retry_delay(exc.response, attempt, self.backoff)
            except requests.exceptions.RequestException as exc:
                last_error = exc
                self._last_request_at = time.monotonic()
                delay = self._retry_delay(response, attempt, self.backoff)

            if attempt < self.max_retries:
                print(f"[Retriever] 请求失败（第 {attempt + 1} 次），"
                      f"{delay:.1f}s 后重试：{last_error}")
                time.sleep(delay)

        print(f"[Retriever] 请求最终失败，放弃：{last_error}")
        return None

    # ---- 抓取 ----

    def fetch_papers(self, query, max_results=DEFAULT_MAX_RESULTS, start=0,
                     sort_by=None, page_size=PAGE_SIZE):
        """按关键词抓取论文，返回论文字典列表。

        query       关键词，按 ``all:`` 字段匹配（等价于旧 ``searchtype=all``）
        max_results 最多抓取条数；``None`` 表示不限（谨慎使用）
        start       起始偏移，用于续抓
        sort_by     ``None`` 走相关度排序（与历史行为一致）；
                    ``"submitted"`` 按提交时间倒序
        page_size   分页时单页条数
        """
        query = (query or "").strip()
        if not query:
            print("[Retriever] 空关键词，跳过抓取。")
            return []

        print(f"Fetching papers for query: {query!r} from arXiv "
              f"(Atom API, max_results={max_results})...")

        papers = []
        seen = set()
        cursor = max(0, int(start))
        remaining = None if max_results is None else max(0, int(max_results))
        page_size = max(1, int(page_size))

        try:
            while remaining is None or remaining > 0:
                size = page_size if remaining is None else min(page_size, remaining)
                params = {
                    "search_query": f"all:{query}",
                    "start": cursor,
                    "max_results": size,
                }
                if sort_by == "submitted":
                    params["sortBy"] = "submittedDate"
                    params["sortOrder"] = "descending"

                xml_text = self._get(params)
                if xml_text is None:
                    break

                batch = parse_atom(xml_text)
                if not batch:
                    break

                for paper in batch:
                    if paper["url"] in seen:
                        continue
                    seen.add(paper["url"])
                    papers.append(paper)

                cursor += len(batch)
                if remaining is not None:
                    remaining -= len(batch)
                if len(batch) < size:
                    break  # 已到结果末尾，无需继续分页
        except Exception as exc:  # noqa: BLE001 - 兜底：不向上抛异常
            print(f"[Retriever] 抓取过程中出现异常: {exc}")

        print(f"[Retriever] 抓取到 {len(papers)} 篇（去重后）。")
        return papers
