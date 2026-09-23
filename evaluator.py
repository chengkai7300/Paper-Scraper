"""
evaluator.py - arXiv 论文价值评估模块

设计目标
--------
在不依赖外部服务的情况下，基于现有元数据（标题、作者、摘要、提交时间）
给出可执行的启发式评分；同时预留两层可选增强：
  1. ExternalEnricher：Semantic Scholar 引用量 / 作者 h-index / HF 点赞量
  2. LLMEvaluator：OpenAI 兼容 API 的多维语义评分

评分维度
--------
- title_score     标题质量（长度、结构、具体性、模板化惩罚）
- author_score    作者信号（人数、机构关键词、et al.）
- abstract_score  摘要信息量（长度、方法词、结果词、数字指标）
- recency_score   时效性（距今天数）
- topic_score     主题热度（命中当前热点关键词）
- venue_score     发表场所（可选，从文本探测顶会/顶刊/workshop）
- external_score  外部引用量 + 作者 h-index（可选）

默认权重（HeuristicEvaluator.DEFAULT_WEIGHTS）
----------------------------------------------
title 0.20 / author 0.20 / abstract 0.15 / recency 0.15 / topic 0.30
abstract 曾占 0.30，现降为 0.15；其文本长度与"套话"特征区分度低
（实测 150 篇样本 std≈0.17），故把权重回补给标题、作者与时效性。

综合分 = 各维度加权和 * 100，范围 0-100。
"""

from __future__ import annotations

import hashlib
import json
import math
import os
import re
from datetime import date, datetime
from typing import Any, Dict, List, Optional, Sequence, Tuple


# ---------------------------------------------------------------------------
# 关键词资源
# ---------------------------------------------------------------------------

TITLE_METHOD_WORDS = [
    "benchmark", "framework", "evaluation", "rethinking", "efficient",
    "robust", "scalable", "unified", "adaptive", "hierarchical",
    "understanding", "exploring", "analysis", "study", "empirical",
    "systematic", "survey", "toward", "towards", "beyond",
]

TITLE_TEMPLATE_PHRASES = [
    "is all you need", "all you need", "a survey of",
]

TOPIC_KEYWORDS: Dict[str, float] = {
    "llm": 1.0, "large language model": 1.0, "language model": 0.7,
    "agent": 0.9, "multi-agent": 0.9, "agentic": 0.9,
    "rag": 0.9, "retrieval-augmented": 0.9, "retrieval augmented": 0.9,
    "reasoning": 0.8, "chain-of-thought": 0.8, "cot": 0.5,
    "diffusion": 0.8, "multimodal": 0.8, "omni": 0.7,
    "benchmark": 0.7, "evaluation": 0.6,
    "safety": 0.7, "alignment": 0.7, "jailbreak": 0.7, "backdoor": 0.7,
    "quantization": 0.7, "distillation": 0.7, "fine-tuning": 0.6,
    "federated": 0.7, "privacy": 0.7, "differential privacy": 0.8,
    "medical": 0.7, "clinical": 0.7, "health": 0.6,
    "speech": 0.6, "asr": 0.6, "audio": 0.6, "vision": 0.6,
    "code": 0.6, "software engineering": 0.6,
    "knowledge graph": 0.7, "graph": 0.5,
    "reinforcement learning": 0.7,
    "self-improvement": 0.8, "self-evolution": 0.8,
    "transformer": 0.6, "attention": 0.5,
    "gui": 0.7, "cyber": 0.6, "security": 0.7,
    "finance": 0.6, "financial": 0.6,
    "robot": 0.6, "embodied": 0.7,
    "inference": 0.6, "serving": 0.6,
    "kv cache": 0.7, "gpu": 0.6, "kernel": 0.6,
    "watermark": 0.6, "unlearning": 0.7,
}

VENUE_TOP_TIER = [
    "neurips", "nips", "icml", "iclr", "acl", "emnlp", "naacl", "coling",
    "cvpr", "iccv", "eccv", "aaai", "ijcai", "acm mm", "kdd", "sigir",
    "www", "wsdm", "icde", "vldb", "sigmod", "osdi", "sosp", "isca",
    "micro", "asplos", "hpca", "sc", "nature", "science", "cell",
    "jmlr", "tpami", "tkde", "ieee transactions", "acm transactions",
    "ieee internet computing", "ieee lcss",
]

VENUE_WORKSHOP = ["workshop", "findings", "symposium", "poster", "demo"]

INSTITUTION_KEYWORDS = [
    "google", "deepmind", "openai", "microsoft", "meta", "apple", "amazon",
    "nvidia", "ibm", "adobe", "salesforce", "bytedance", "alibaba",
    "tencent", "baidu", "huawei", "xiaomi", "tsinghua", "peking",
    "zhejiang", "shanghai jiao tong", "stanford", "mit", "berkeley",
    "cmu", "carnegie mellon", "oxford", "cambridge", "eth", "epfl",
    "max planck", "kaist", "yonsei", "seoul national", "tokyo",
]

# 机构分层，用于"机构"维度。
#
# ⚠️ 匹配必须用词边界（kw_match），不能用 `in`：
# "mit" 会命中 "Smith College"，"meta" 会命中 "metabolic"，"eth" 会命中 "ethics"。
INSTITUTION_TOP_TIER = [
    "google", "deepmind", "openai", "anthropic", "microsoft", "meta",
    "apple", "nvidia", "stanford", "mit",
    "massachusetts institute of technology", "berkeley", "uc berkeley",
    "carnegie mellon", "cmu", "oxford", "cambridge", "eth zurich", "epfl",
    "tsinghua", "peking", "princeton", "harvard", "caltech",
    "california institute of technology",
]

INSTITUTION_STRONG_TIER = [
    "amazon", "ibm", "adobe", "salesforce", "bytedance", "alibaba",
    "tencent", "baidu", "huawei", "xiaomi", "samsung", "naver", "kakao",
    "allen institute", "max planck", "kaist", "seoul national", "tokyo",
    "zhejiang", "shanghai jiao tong", "fudan", "university of washington",
    "cornell", "columbia", "ucla", "uc san diego", "uc davis",
    "new york university", "university of toronto", "mila",
    "university of melbourne", "university of sydney", "monash",
    # 下面几条是按真实抓到的机构名补的（原本只能拿到中性分 0.5）
    "university of california", "purdue", "rensselaer",
    "georgia institute of technology", "university of illinois",
    "university of michigan", "university of chicago",
    "university of texas", "nanyang technological",
    "chinese university of hong kong", "hong kong university of science",
    "sun yat-sen", "nec laboratories", "nec",
]


# ---------------------------------------------------------------------------
# 工具函数
# ---------------------------------------------------------------------------

def kw_match(kw: str, text: str) -> bool:
    """词边界匹配，允许英文复数 s。"""
    pattern = r"\b" + re.escape(kw) + r"s?\b"
    return re.search(pattern, text) is not None


def _normalize_date(text: str) -> Optional[date]:
    if not text or text == "N/A":
        return None
    try:
        return datetime.strptime(text, "%Y-%m-%d").date()
    except ValueError:
        return None


#: 参与评分的文本字段（改变其中任意一个都应触发重评）
CONTENT_FIELDS = ("title", "authors", "abstract", "submission_time")


def paper_content_hash(paper: Dict[str, Any]) -> str:
    """论文内容指纹，用于增量评价时判断记录是否发生变化。"""
    payload = "\x1f".join(str(paper.get(k) or "") for k in CONTENT_FIELDS)
    return hashlib.sha1(payload.encode("utf-8")).hexdigest()[:16]


# ---------------------------------------------------------------------------
# 启发式评分器
# ---------------------------------------------------------------------------

class HeuristicEvaluator:
    """仅依赖现有元数据的启发式评分器。"""

    # abstract 权重由 0.30 下调至 0.15：摘要文本长度/套话容易被人为"堆砌"，
    # 区分度反而低于标题、作者与时效性；释放出的权重按比例回补给其余维度。
    DEFAULT_WEIGHTS = {
        "title": 0.20,
        "author": 0.20,
        "abstract": 0.15,
        "recency": 0.15,
        "topic": 0.30,
    }

    def __init__(self, weights: Optional[Dict[str, float]] = None):
        self.weights = dict(weights or self.DEFAULT_WEIGHTS)
        total = sum(self.weights.values())
        if total <= 0:
            raise ValueError("weights must sum to a positive value")
        self.weights = {k: v / total for k, v in self.weights.items()}

    # ---- 各维度 ----

    def _title_score(self, title: str) -> float:
        if not title or title == "N/A":
            return 0.0
        t = title.lower()
        score = 0.5
        n_words = len(title.split())
        if 8 <= n_words <= 20:
            score += 0.20
        elif 5 <= n_words < 8 or 20 < n_words <= 25:
            score += 0.10
        if ":" in title:
            score += 0.10
        if any(w in t for w in TITLE_METHOD_WORDS):
            score += 0.10
        if title.strip().endswith("?"):
            score += 0.05
        if any(p in t for p in TITLE_TEMPLATE_PHRASES):
            score -= 0.05
        return max(0.0, min(1.0, score))

    def _author_score(self, authors: str) -> float:
        if not authors or authors == "N/A":
            return 0.2
        a = authors.lower()
        score = 0.5
        names = [x.strip() for x in authors.split(",") if x.strip()]
        n = len(names)
        if 2 <= n <= 8:
            score += 0.20
        elif n == 1:
            score -= 0.10
        elif n > 15:
            score -= 0.05
        if "et al" in a:
            score -= 0.05
        if any(inst in a for inst in INSTITUTION_KEYWORDS):
            score += 0.20
        return max(0.0, min(1.0, score))

    def _abstract_score(self, abstract: str) -> float:
        if not abstract or abstract == "N/A":
            return 0.0
        t = abstract.lower()
        n = len(abstract)
        score = 0.0
        if 500 <= n <= 2000:
            score += 0.30
        elif 200 <= n < 500 or 2000 < n <= 3000:
            score += 0.20
        elif n > 100:
            score += 0.10

        method_words = [
            "we propose", "we introduce", "we present", "we develop",
            "we design", "we show", "framework", "method", "approach",
            "algorithm", "architecture",
        ]
        hits = sum(1 for w in method_words if w in t)
        score += 0.20 if hits >= 2 else (0.10 if hits == 1 else 0.0)

        result_words = [
            "achieve", "improve", "outperform", "state-of-the-art",
            "sota", "surpass", "reduce", "increase", "gain", "accuracy",
        ]
        hits = sum(1 for w in result_words if w in t)
        score += 0.20 if hits >= 2 else (0.10 if hits == 1 else 0.0)

        if re.search(r"\d+(\.\d+)?\s*%", abstract):
            score += 0.15
        if re.search(r"\d+(\.\d+)?\s*(x|fold|times)", abstract, re.IGNORECASE):
            score += 0.10
        if any(w in t for w in ["benchmark", "dataset", "evaluation",
                                "experiment", "ablation"]):
            score += 0.10
        return max(0.0, min(1.0, score))

    def _recency_score(self, submission_time: str,
                       today: Optional[date] = None) -> float:
        d = _normalize_date(submission_time)
        if d is None:
            return 0.3
        days = ((today or date.today()) - d).days
        if days < 0:
            days = 0
        if days <= 30:
            return 1.0
        if days <= 90:
            return 1.0 - (days - 30) / 60.0 * 0.5
        if days <= 365:
            return 0.5 - (days - 90) / 275.0 * 0.3
        return 0.2

    def _topic_score(self, text: str) -> float:
        if not text:
            return 0.0
        t = text.lower()
        total = 0.0
        for kw, w in TOPIC_KEYWORDS.items():
            if kw_match(kw, t):
                total += w
        return 1.0 - math.exp(-total / 2.0)

    def _venue_score(self, text: str) -> Optional[float]:
        if not text:
            return None
        t = text.lower()
        has_signal = any(p in t for p in [
            "accepted", "published", "proceedings", "conference",
            "journal", "findings", "workshop",
        ])
        if not has_signal:
            return None
        score = 0.0
        if any(v in t for v in VENUE_TOP_TIER):
            score = max(score, 0.9)
        if any(v in t for v in VENUE_WORKSHOP):
            score = max(score, 0.5)
        if score == 0.0:
            score = 0.3
        return score

    def _institution_score(self, institutions: Sequence[str]) -> Optional[float]:
        """作者机构：**仅在真的拿到机构信息时**返回分值，否则 None。

        机构名不在 arXiv 的 API 响应里，依赖额外抓取；已经落盘的历史记录
        里没有这个数据。做成"有数据才参与"后，没有机构信息的论文评分完全不变，
        既有的金标准对拍与历史记录保持逐位一致。

        代价：有机构和没机构的论文可比性变弱（与 venue 维度同一类取舍）。
        """
        if not institutions:
            return None
        best = 0.0
        for inst in institutions:
            t = inst.lower()
            if any(kw_match(kw, t) for kw in INSTITUTION_TOP_TIER):
                best = max(best, 1.0)
            elif any(kw_match(kw, t) for kw in INSTITUTION_STRONG_TIER):
                best = max(best, 0.85)
        # 有机构但不在名单里：给中性分，名单必然不全
        return 0.5 if best == 0.0 else best

    # ---- 综合 ----

    def evaluate(self, paper: Dict[str, Any],
                 today: Optional[date] = None,
                 institutions: Optional[Sequence[str]] = None) -> Dict[str, Any]:
        title = paper.get("title", "") or ""
        authors = paper.get("authors", "") or ""
        abstract = paper.get("abstract", "") or ""
        submission_time = paper.get("submission_time", "") or ""
        text_all = f"{title} {abstract}"

        dims: Dict[str, Optional[float]] = {
            "title": self._title_score(title),
            "author": self._author_score(authors),
            "abstract": self._abstract_score(abstract),
            "recency": self._recency_score(submission_time, today),
            "topic": self._topic_score(text_all),
        }

        venue = self._venue_score(text_all)
        if venue is not None:
            dims["venue"] = venue

        weights = dict(self.weights)
        # ⚠️ 追加顺序必须与 Swift 的 dimensionKeys 一致：
        # venue 先、institution 后；两者同时出现时原有五维会被乘两次 (1 - 0.10)。
        if "venue" in dims:
            shift = 0.10
            for k in weights:
                weights[k] *= (1 - shift)
            weights["venue"] = shift

        institution = self._institution_score(institutions or [])
        if institution is not None:
            dims["institution"] = institution
            shift = 0.10
            for k in weights:
                weights[k] *= (1 - shift)
            weights["institution"] = shift

        final = sum((dims[k] or 0.0) * weights[k] for k in weights)
        return {
            "dimension_scores": {
                k: (round(v, 3) if v is not None else None)
                for k, v in dims.items()
            },
            "weights": {k: round(v, 3) for k, v in weights.items()},
            "final_score": round(final * 100, 2),
        }


# ---------------------------------------------------------------------------
# 外部数据增强
# ---------------------------------------------------------------------------

class ExternalEnricher:
    """Semantic Scholar 引用量 / 作者 h-index + Hugging Face 点赞量。"""

    BASE = "https://api.semanticscholar.org/graph/v1/paper"
    FIELDS = ("title,citationCount,influentialCitationCount,venue,year,"
              "authors.name,authors.hIndex,authors.affiliations")

    def __init__(self, timeout: int = 10):
        self.timeout = timeout
        self._cache: Dict[str, Optional[Dict]] = {}

    @staticmethod
    def extract_arxiv_id(url: str) -> Optional[str]:
        m = re.search(r"arxiv\.org/abs/([\d.]+)", url or "")
        return m.group(1) if m else None

    def fetch_s2(self, arxiv_id: str) -> Optional[Dict]:
        key = f"s2:{arxiv_id}"
        if key in self._cache:
            return self._cache[key]
        data = None
        try:
            import requests
            r = requests.get(
                f"{self.BASE}/arXiv:{arxiv_id}",
                params={"fields": self.FIELDS},
                timeout=self.timeout,
            )
            if r.status_code == 200:
                data = r.json()
        except Exception as e:  # noqa: BLE001
            print(f"[ExternalEnricher/S2] {arxiv_id}: {e}")
        self._cache[key] = data
        return data

    def fetch_hf_upvotes(self, arxiv_id: str) -> Optional[int]:
        """Hugging Face Papers 的点赞量（覆盖不全，可能为 None）。"""
        key = f"hf:{arxiv_id}"
        if key in self._cache:
            return self._cache[key]
        upvotes = None
        try:
            import requests
            r = requests.get(
                f"https://huggingface.co/api/papers/{arxiv_id}",
                timeout=self.timeout,
            )
            if r.status_code == 200:
                upvotes = r.json().get("upvotes")
        except Exception:  # noqa: BLE001
            pass
        self._cache[key] = upvotes
        return upvotes

    def enrich(self, paper: Dict) -> Optional[Dict]:
        arxiv_id = self.extract_arxiv_id(paper.get("url", ""))
        if not arxiv_id:
            return None
        raw = self.fetch_s2(arxiv_id) or {}
        citations = raw.get("citationCount") or 0
        influential = raw.get("influentialCitationCount") or 0
        h_indices = [a.get("hIndex") or 0
                     for a in raw.get("authors", []) if a.get("hIndex")]
        h_avg = sum(h_indices) / len(h_indices) if h_indices else 0.0

        citation_score = min(1.0, math.log1p(citations) / math.log1p(1000))
        h_score = min(1.0, h_avg / 50.0)
        external_score = (0.7 * citation_score + 0.3 * h_score) * 100

        hf_upvotes = self.fetch_hf_upvotes(arxiv_id)

        return {
            "citationCount": citations,
            "influentialCitationCount": influential,
            "venue": raw.get("venue"),
            "year": raw.get("year"),
            "author_h_index_avg": round(h_avg, 2),
            "hf_upvotes": hf_upvotes,
            "external_score": round(external_score, 2),
        }


# ---------------------------------------------------------------------------
# 可选 LLM 语义评分
# ---------------------------------------------------------------------------

class LLMEvaluator:
    """OpenAI 兼容 API 的多维语义评分。默认关闭，需设置环境变量。"""

    DEFAULT_PROMPT = (
        "You are an expert reviewer. Given the title and abstract of an arXiv "
        "paper, rate it on five dimensions from 0 to 10 (integers):\n"
        "1. novelty\n2. technical_rigor\n3. clarity\n"
        "4. potential_impact\n5. relevance_to_hot_topics\n"
        "Return ONLY a JSON object with these five keys.\n\n"
        "Title: {title}\n\nAbstract: {abstract}\n"
    )

    def __init__(self, api_key: Optional[str] = None,
                 base_url: Optional[str] = None,
                 model: Optional[str] = None,
                 timeout: int = 30):
        self.api_key = api_key or os.environ.get("OPENAI_API_KEY")
        self.base_url = (base_url or os.environ.get(
            "OPENAI_BASE_URL", "https://api.openai.com/v1")).rstrip("/")
        self.model = model or os.environ.get("OPENAI_MODEL", "gpt-4o-mini")
        self.timeout = timeout
        self.enabled = bool(self.api_key)

    def evaluate(self, paper: Dict) -> Optional[Dict]:
        if not self.enabled:
            return None
        title = paper.get("title", "")
        abstract = (paper.get("abstract", "") or "")[:4000]
        prompt = self.DEFAULT_PROMPT.format(title=title, abstract=abstract)
        try:
            import json as _json
            import requests
            r = requests.post(
                f"{self.base_url}/chat/completions",
                headers={
                    "Authorization": f"Bearer {self.api_key}",
                    "Content-Type": "application/json",
                },
                json={
                    "model": self.model,
                    "messages": [{"role": "user", "content": prompt}],
                    "temperature": 0.0,
                    "response_format": {"type": "json_object"},
                },
                timeout=self.timeout,
            )
            r.raise_for_status()
            content = r.json()["choices"][0]["message"]["content"]
            scores = _json.loads(content)
            avg = sum(float(v) for v in scores.values()) / max(1, len(scores))
            return {"raw": scores, "llm_score": round(avg * 10, 2)}
        except Exception as e:  # noqa: BLE001
            print(f"[LLMEvaluator] {title[:60]}: {e}")
            return None


# ---------------------------------------------------------------------------
# 组合评估器
# ---------------------------------------------------------------------------

class PaperEvaluator:
    """组合启发式 + 可选外部增强 + 可选 LLM 评分。"""

    def __init__(self,
                 weights: Optional[Dict[str, float]] = None,
                 use_external: bool = False,
                 use_llm: bool = False,
                 external_weight: float = 0.20,
                 llm_weight: float = 0.30):
        self.heuristic = HeuristicEvaluator(weights)
        self.enricher = ExternalEnricher() if use_external else None
        self.llm = LLMEvaluator() if use_llm else None
        self.external_weight = external_weight
        self.llm_weight = llm_weight

    @property
    def llm_enabled(self) -> bool:
        """LLM 实际是否可用（未配置 API Key 时视为关闭）。"""
        return bool(self.llm and self.llm.enabled)

    @property
    def config_key(self) -> str:
        """评分配置指纹：启发式权重 + 外部/LLM 增强配置。

        该指纹会随评分结果一起写入历史记录，用于判断旧评分是否
        "与当前配置同口径"，从而支持增量重算。
        """
        payload = {
            "weights": {k: round(v, 6)
                        for k, v in sorted(self.heuristic.weights.items())},
            "external": bool(self.enricher),
            "llm": self.llm_enabled,
            "external_weight": self.external_weight,
            "llm_weight": self.llm_weight,
        }
        raw = json.dumps(payload, sort_keys=True, ensure_ascii=False)
        return hashlib.sha1(raw.encode("utf-8")).hexdigest()[:12]

    def evaluate(self, paper: Dict[str, Any],
                 today: Optional[date] = None,
                 institutions: Optional[Sequence[str]] = None) -> Dict[str, Any]:
        result = self.heuristic.evaluate(paper, today=today,
                                        institutions=institutions)
        final = result["final_score"]

        external = self.enricher.enrich(paper) if self.enricher else None
        result["external"] = external
        if external and external.get("external_score") is not None:
            w = self.external_weight
            final = final * (1 - w) + external["external_score"] * w

        llm_result = self.llm.evaluate(paper) if self.llm else None
        result["llm"] = llm_result
        if llm_result and llm_result.get("llm_score") is not None:
            w = self.llm_weight
            final = final * (1 - w) + llm_result["llm_score"] * w

        result["base_score"] = round(result["final_score"], 2)
        result["final_score"] = round(final, 2)

        # ---- 增量评价所需的溯源信息 ----
        result["config_key"] = self.config_key
        result["content_hash"] = paper_content_hash(paper)
        result["evaluated_on"] = (today or date.today()).isoformat()
        return result

    def rank(self, papers: List[Dict[str, Any]]
             ) -> List[Tuple[float, Dict[str, Any]]]:
        scored: List[Tuple[float, Dict[str, Any]]] = []
        for p in papers:
            r = self.evaluate(p)
            p["evaluation"] = r
            scored.append((r["final_score"], p))
        scored.sort(key=lambda x: x[0], reverse=True)
        return scored


# ---------------------------------------------------------------------------
# 独立运行：对现有 papers_metadata.json 做评估
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    path = "papers_metadata.json"
    if not os.path.exists(path):
        print(f"{path} not found.")
        raise SystemExit(1)

    with open(path, "r", encoding="utf-8") as f:
        papers = json.load(f)

    evaluator = PaperEvaluator(use_external=False, use_llm=False)
    ranked = evaluator.rank(papers)

    print(f"Evaluated {len(ranked)} papers.\n")
    for i, (score, p) in enumerate(ranked, 1):
        dims = p["evaluation"]["dimension_scores"]
        print(
            f"#{i:02d} score={score:5.1f} | "
            f"T={dims['title']:.2f} A={dims['author']:.2f} "
            f"Ab={dims['abstract']:.2f} R={dims['recency']:.2f} "
            f"Tp={dims['topic']:.2f} | {p['title']}"
        )