//
//  HistoryView.swift
//  PaperScraper
//
//  历史回溯与前后对比：对应 `python main.py --revaluate`，
//  直接展示 `History.renderReport` 生成的文本报告（与 CLI 输出同格式）。
//

import PaperScraperCore
import SwiftUI

struct HistoryView: View {

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                LabeledContent("论文记录", value: "\(model.papers.count) 篇")
                LabeledContent("已完成评分", value: "\(model.scoredCount) 篇")
                LabeledContent("当前权重", value: currentWeights)
                LabeledContent("配置指纹", value: model.evaluator.configKey)
            } header: {
                Text("当前口径")
            }

            Section {
                Button {
                    Task { await model.reevaluate() }
                } label: {
                    Label("增量重评", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                }
                .disabled(model.phase.isBusy || model.papers.isEmpty)

                Button {
                    Task { await model.reevaluate(force: true) }
                } label: {
                    Label("强制全量重算", systemImage: "arrow.clockwise.circle")
                }
                .disabled(model.phase.isBusy || model.papers.isEmpty)

                if model.phase.isBusy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(model.phase.message ?? "处理中…")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("操作")
            } footer: {
                Text("增量重评只会重算「评分已失效」的记录："
                     + "缺评分 / 配置变更 / 内容变更 / 跨天时效刷新。"
                     + "同配置同一天重复执行会全部跳过。")
            }

            if !model.reportText.isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: true) {
                        Text(model.reportText)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .padding(12)
                    }
                    .frame(maxHeight: 460)
                    .background(Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 12))

                    ShareLink(item: model.reportText) {
                        Label("导出报告", systemImage: "square.and.arrow.up")
                    }
                } header: {
                    Text("对比报告")
                } footer: {
                    Text("与 Python 版 --revaluate 输出同格式，可直接对照。")
                }
            } else {
                Section {
                    Text("还没生成报告。点击上面的「增量重评」查看改前 / 改后的分数与排名变化。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("回溯对比")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            }
        }
    }

    private var currentWeights: String {
        model.evaluator.heuristic.weights
            .sorted { $0.key < $1.key }
            .map { "\(DisplayFormat.dimensionLabel($0.key)) \(String(format: "%.2f", $0.value))" }
            .joined(separator: " / ")
    }
}
