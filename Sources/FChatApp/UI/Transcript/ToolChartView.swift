// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import SwiftUI
import Charts
import FChatTools

/// Renders the output of the `make_chart` tool as a Swift Charts chart
/// inline in the transcript. The tool itself lives in FChatTools (data
/// model + validation); rendering lives here because Swift Charts is a
/// UI dependency.
///
/// The view is deliberately lenient: if the JSON fails to parse (the
/// model produced something off-schema), we fall back to showing the
/// raw JSON pretty-printed alongside an error banner. The chat keeps
/// working; the model gets the unchanged payload back on the next turn
/// and can correct itself.
struct ToolChartView: View {
    let json: String

    var body: some View {
        if let data = json.data(using: .utf8),
           let spec = try? ChartSpec(jsonData: data) {
            render(spec)
        } else {
            fallback
        }
    }

    @ViewBuilder
    private func render(_ spec: ChartSpec) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = spec.title, !title.isEmpty {
                Text(title)
                    .font(.callout.bold())
            }
            switch spec.type {
            case .bar:
                BarChart(spec: spec)
            case .line:
                LineChart(spec: spec)
            case .pie:
                PieChart(spec: spec)
            }
        }
        .frame(maxWidth: .infinity, idealHeight: 260, maxHeight: 320)
    }

    @ViewBuilder
    private var fallback: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Chart spec could not be parsed")
                .font(.caption.bold())
                .foregroundStyle(.red)
            Text(json)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}

// MARK: - Bar

private struct BarChart: View {
    let spec: ChartSpec

    var body: some View {
        let pairs = flattenedPairs(spec.series)
        Chart(pairs) { item in
            if spec.hasCategoricalX {
                BarMark(
                    x: .value(spec.xLabel ?? "x", item.x),
                    y: .value(spec.yLabel ?? "y", item.y)
                )
                .foregroundStyle(by: .value("Series", item.seriesName))
                .annotation(position: .top, alignment: .center) {
                    if let label = item.label {
                        Text(label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if let xNum = item.xNumber {
                BarMark(
                    x: .value(spec.xLabel ?? "x", xNum),
                    y: .value(spec.yLabel ?? "y", item.y)
                )
                .foregroundStyle(by: .value("Series", item.seriesName))
            }
        }
        .chartLegend(position: .bottom, alignment: .leading)
    }
}

// MARK: - Line

private struct LineChart: View {
    let spec: ChartSpec

    var body: some View {
        let pairs = flattenedPairs(spec.series)
        Chart(pairs) { item in
            if spec.hasCategoricalX {
                LineMark(
                    x: .value(spec.xLabel ?? "x", item.x),
                    y: .value(spec.yLabel ?? "y", item.y)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(by: .value("Series", item.seriesName))
                PointMark(
                    x: .value(spec.xLabel ?? "x", item.x),
                    y: .value(spec.yLabel ?? "y", item.y)
                )
                .foregroundStyle(by: .value("Series", item.seriesName))
            } else if let xNum = item.xNumber {
                LineMark(
                    x: .value(spec.xLabel ?? "x", xNum),
                    y: .value(spec.yLabel ?? "y", item.y)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(by: .value("Series", item.seriesName))
                PointMark(
                    x: .value(spec.xLabel ?? "x", xNum),
                    y: .value(spec.yLabel ?? "y", item.y)
                )
                .foregroundStyle(by: .value("Series", item.seriesName))
            }
        }
        .chartLegend(position: .bottom, alignment: .leading)
    }
}

// MARK: - Pie

private struct PieChart: View {
    let spec: ChartSpec

    var body: some View {
        // Pies only render the first series — multi-series pies are
        // ill-defined. The model is told this in the tool description.
        let points = spec.series.first?.points ?? []
        Chart(Array(points.enumerated()), id: \.offset) { _, point in
            SectorMark(
                angle: .value("Value", point.y),
                innerRadius: .ratio(0.4),
                angularInset: 1.5
            )
            .cornerRadius(2)
            .foregroundStyle(by: .value("Slice", point.x.stringValue))
        }
        .chartLegend(position: .trailing, alignment: .center)
    }
}

// MARK: - Pair flattening

/// Identifiable pair of (seriesName, point) for ForEach inside Chart.
private struct ChartPair: Identifiable {
    let id = UUID()
    let seriesName: String
    let x: String
    let xNumber: Double?
    let y: Double
    let label: String?
}

private func flattenedPairs(_ series: [ChartSpec.Series]) -> [ChartPair] {
    var pairs: [ChartPair] = []
    for (i, s) in series.enumerated() {
        let name = s.name ?? (series.count == 1 ? "Value" : "Series \(i + 1)")
        for p in s.points {
            pairs.append(ChartPair(
                seriesName: name,
                x: p.x.stringValue,
                xNumber: p.x.numberValue,
                y: p.y,
                label: p.label
            ))
        }
    }
    return pairs
}
