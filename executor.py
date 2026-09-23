"""executor.py - 论文处理与下载模块

职责
----
- ``process_papers``：调用 ``PaperEvaluator.rank`` 按综合分降序排列，
  打印一行摘要（各维度分 + 标题），并返回结构化结果供 ``main.py`` 汇总；
- ``download_pdf``：下载 PDF 到指定路径，失败时打印原因并返回 ``False``。

约定
----
``rank`` 会把评分结果写回每篇论文的 ``paper["evaluation"]``，因此传入的
论文对象会被就地修改（``main.py`` 依赖这一点把评分一并落盘）。
"""

import os
import requests
from evaluator import PaperEvaluator


class Executor:
    def __init__(self, evaluator: PaperEvaluator = None):
        self.evaluator = evaluator or PaperEvaluator()

    def process_papers(self, papers):
        """评估并按综合分降序排序，输出格式化结果。"""
        print(f"Processing {len(papers)} papers.")
        if not papers:
            return []

        ranked = self.evaluator.rank(papers)
        results = []
        for rank, (score, paper) in enumerate(ranked, 1):
            dims = paper["evaluation"]["dimension_scores"]
            line = (
                f"#{rank:02d} | score={score:5.1f} | "
                f"T={dims['title']:.2f} A={dims['author']:.2f} "
                f"Ab={dims['abstract']:.2f} R={dims['recency']:.2f} "
                f"Tp={dims['topic']:.2f} | {paper['title']}"
            )
            print("  " + line)
            results.append({
                "rank": rank,
                "final_score": score,
                "title": paper.get("title", ""),
                "authors": paper.get("authors", ""),
                "url": paper.get("url", ""),
                "submission_time": paper.get("submission_time", ""),
                "evaluation": paper.get("evaluation", {}),
            })
        return results

    def download_pdf(self, pdf_url, save_path):
        if not pdf_url or pdf_url == "N/A":
            print("No PDF URL provided for download.")
            return False
        try:
            print(f"Downloading PDF from {pdf_url} to {save_path}")
            response = requests.get(pdf_url, stream=True)
            response.raise_for_status()
            with open(save_path, "wb") as pdf_file:
                for chunk in response.iter_content(chunk_size=8192):
                    pdf_file.write(chunk)
            print(f"Successfully downloaded PDF to {save_path}")
            return True
        except requests.exceptions.RequestException as e:
            print(f"Error downloading PDF from {pdf_url}: {e}")
            return False
        except IOError as e:
            print(f"Error saving PDF to {save_path}: {e}")
            return False