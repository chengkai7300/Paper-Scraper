"""main.py - 项目入口

两种工作模式
------------
1. **常规抓取模式**（默认）
   抓取 arXiv -> 与 ``papers_metadata.json`` 比对去重 -> 记录新论文
   -> 可选下载 PDF -> 评分排序 -> 写回元数据。

   已记录的论文会被**跳过**，因此历史评分不会自动更新。

2. **历史回溯模式**（``--revaluate``）
   不联网、不抓取，直接读取 ``papers_metadata.json``，对评分已失效的记录
   做增量重评，并输出改动前后的对比报告。详见 ``history.py``。

常用示例
--------
    python main.py                              # 抓取 + 评分
    python main.py --query "agent" --download   # 指定关键词并下载 PDF
    python main.py --revaluate --report r.txt   # 回溯重评 + 导出报告
"""

import argparse
import os
import json
from retriever import Retriever
from executor import Executor
from evaluator import PaperEvaluator
import history

DOWNLOAD_DIR = "arxiv_pdfs"
METADATA_FILE = "papers_metadata.json"


def load_papers_metadata():
    if os.path.exists(METADATA_FILE):
        with open(METADATA_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    return []


def save_papers_metadata(papers_metadata):
    with open(METADATA_FILE, "w", encoding="utf-8") as f:
        json.dump(papers_metadata, f, indent=4, ensure_ascii=False)


def build_arg_parser():
    parser = argparse.ArgumentParser(
        description="Zotero-arXiv-Daily Scraper Simulation"
    )
    parser.add_argument(
        "--download",
        action="store_true",
        default=os.environ.get("ARXIV_DOWNLOAD_PDF", "0") == "1",
        help="下载论文 PDF（默认关闭，仅分析元数据）",
    )
    parser.add_argument(
        "--query",
        default="LLM",
        help="arXiv 搜索关键词（默认: LLM）",
    )
    parser.add_argument(
        "--max",
        dest="max_results",
        type=int,
        default=50,
        help="单次从 arXiv 最多抓取的论文数（默认: 50，超出会自动分页）",
    )
    parser.add_argument(
        "--sort",
        choices=("relevance", "submitted"),
        default="relevance",
        help="结果排序：relevance（默认，相关度）或 submitted（按提交时间倒序）",
    )
    parser.add_argument(
        "--external",
        action="store_true",
        help="启用 Semantic Scholar / Hugging Face 外部数据增强",
    )
    parser.add_argument(
        "--llm",
        action="store_true",
        help="启用 LLM 语义评分（需设置 OPENAI_API_KEY）",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=None,
        help="仅处理前 N 篇新论文（便于快速测试）",
    )
    # ---- 历史回溯 / 增量评价 ----
    parser.add_argument(
        "--revaluate",
        "--refresh",
        dest="revaluate",
        action="store_true",
        help="回溯历史记录，用当前权重做增量评价（不联网、不抓取）",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="配合 --revaluate：忽略增量判断，强制重算全部历史记录",
    )
    parser.add_argument(
        "--top",
        type=int,
        default=10,
        help="对比报告中 Top-N 的数量（默认: 10）",
    )
    parser.add_argument(
        "--report",
        default=None,
        help="把对比报告写入指定文件，例如 --report report.txt",
    )
    parser.add_argument(
        "--no-backup",
        action="store_true",
        help="配合 --revaluate：重评落盘前不生成 .backup.json 备份",
    )
    return parser


def run_revaluation(args):
    """--revaluate：回溯历史记录做增量评价，并输出前后对比报告。"""
    print("\n--- 历史回溯 · 增量评价模式 ---")
    if not os.path.exists(METADATA_FILE):
        print(f"{METADATA_FILE} not found; nothing to re-evaluate.")
        print("\nZotero-arXiv-Daily Scraper Simulation Finished.")
        return

    papers = load_papers_metadata()
    evaluator = PaperEvaluator(use_external=args.external, use_llm=args.llm)

    result = history.run(
        papers, evaluator, force=args.force, top_n=args.top
    )
    print("\n" + result["report"])

    if args.report:
        with open(args.report, "w", encoding="utf-8") as f:
            f.write(result["report"])
        print(f"Report written to {args.report}")

    stats = result["stats"]
    if stats["reevaluated"] == 0:
        print("没有任何记录需要重算，元数据未改动。")
    else:
        if not args.no_backup:
            backup = history.save_backup(METADATA_FILE)
            print(f"Backup written to {backup}")
        save_papers_metadata(papers)
        print(
            f"已更新 {stats['reevaluated']} 条历史评分"
            f"（沿用 {stats['skipped']} 条）并写回 {METADATA_FILE}。"
        )

    print("\nZotero-arXiv-Daily Scraper Simulation Finished.")


def main():
    args = build_arg_parser().parse_args()

    print("Starting Zotero-arXiv-Daily Scraper Simulation...")
    print(f"  download_pdf = {args.download}")
    print(f"  use_external = {args.external}")
    print(f"  use_llm      = {args.llm}")
    print(f"  query        = {args.query!r}")    print(f"  max_results  = {args.max_results}")
    print(f"  sort         = {args.sort!r}")
    # ---- 历史回溯 / 增量评价模式：不联网，直接处理已有记录 ----
    if args.revaluate:
        run_revaluation(args)
        return

    # 仅在需要下载时才创建目录
    if args.download and not os.path.exists(DOWNLOAD_DIR):
        os.makedirs(DOWNLOAD_DIR)
        print(f"Created download directory: {DOWNLOAD_DIR}")

    all_papers_metadata = load_papers_metadata()
    downloaded_urls_set = {p["url"] for p in all_papers_metadata}
    print(f"Loaded {len(all_papers_metadata)} previously recorded papers.")

    retriever = Retriever()

    evaluator = PaperEvaluator(
        use_external=args.external,
        use_llm=args.llm,
    )
    executor = Executor(evaluator=evaluator)

    papers = retriever.fetch_papers(
        args.query,
        max_results=args.max_results,
        sort_by=None if args.sort == "relevance" else "submitted",
    )

    if not papers:
        print("No papers found for the query.")
        print("\nZotero-arXiv-Daily Scraper Simulation Finished.")
        return

    print("\n--- Fetched Papers ---")
    new_papers_to_process = []
    for paper in papers:
        if paper["url"] not in downloaded_urls_set:
            new_papers_to_process.append(paper)
            all_papers_metadata.append(paper)  # 先记录元数据
            print(f"New paper recorded: {paper['title']}")
        else:
            print(f"Skipping already recorded paper: {paper['title']}")

    if args.limit is not None:
        new_papers_to_process = new_papers_to_process[: args.limit]
        print(f"Limited to first {len(new_papers_to_process)} new papers.")

    # ---- 可选：下载 PDF ----
    if args.download and new_papers_to_process:
        print("\n--- Downloading PDFs ---")
        if not os.path.exists(DOWNLOAD_DIR):
            os.makedirs(DOWNLOAD_DIR)
        for paper in new_papers_to_process:
            url = paper.get("url")
            if not url or url == "N/A":
                continue
            pdf_url = url.replace("/abs/", "/pdf/")
            safe_title = "".join(
                c for c in paper["title"]
                if c.isalnum() or c in (" ", "_", "-")
            ).rstrip()
            pdf_filename = f"{safe_title[:100]}.pdf"
            pdf_save_path = os.path.join(DOWNLOAD_DIR, pdf_filename)
            executor.download_pdf(pdf_url, pdf_save_path)
    else:
        if new_papers_to_process:
            print("\n--- Skipping PDF download (analysis-only mode) ---")

    # ---- 分析阶段（始终执行）----
    print("\n--- Processing Papers ---")
    processed_results = executor.process_papers(new_papers_to_process)

    if new_papers_to_process:
        save_papers_metadata(all_papers_metadata)
        print(
            f"Saved metadata for {len(new_papers_to_process)} new papers "
            f"to {METADATA_FILE}."
        )
    else:
        print("No new papers metadata to record.")

    print("\n--- Processing Summary (Ranked by Value) ---")
    for result in processed_results:
        print(
            f"#{result['rank']:02d} [{result['final_score']:5.1f}] "
            f"{result['title']}"
        )

    print("\nZotero-arXiv-Daily Scraper Simulation Finished.")


if __name__ == "__main__":
    main()