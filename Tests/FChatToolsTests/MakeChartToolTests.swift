// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
import FChatCore
import FChatProviders
@testable import FChatTools

@Suite("MakeChartTool")
struct MakeChartToolTests {

    @Test func happyPathBarChartReturnsChartDisplayHint() async throws {
        let tool = MakeChartTool()
        let args = #"""
        {"type":"bar","series":[{"name":"Revenue","points":[{"x":"Q1","y":12.3},{"x":"Q2","y":15.6}]}]}
        """#
        let output = try await tool.invoke(arguments: args)
        #expect(output.isError == false)
        #expect(output.display == .chart)
        // Output re-emits canonical JSON; assert it parses back into a spec.
        let data = try #require(output.outputJSON.data(using: .utf8))
        let roundTripped = try ChartSpec(jsonData: data)
        #expect(roundTripped.type == .bar)
        #expect(roundTripped.series.first?.points.count == 2)
    }

    @Test func happyPathLineChart() async throws {
        let tool = MakeChartTool()
        let output = try await tool.invoke(
            arguments: #"{"type":"line","title":"Trend","series":[{"points":[{"x":1,"y":10},{"x":2,"y":20}]}]}"#
        )
        #expect(output.isError == false)
        #expect(output.display == .chart)
        let spec = try ChartSpec(jsonData: Data(output.outputJSON.utf8))
        #expect(spec.type == .line)
        #expect(spec.title == "Trend")
        #expect(spec.hasCategoricalX == false)
    }

    @Test func happyPathPieChart() async throws {
        let tool = MakeChartTool()
        let output = try await tool.invoke(
            arguments: #"{"type":"pie","series":[{"points":[{"x":"Apple","y":25},{"x":"Samsung","y":22},{"x":"Other","y":53}]}]}"#
        )
        #expect(output.isError == false)
        #expect(output.display == .chart)
    }

    @Test func missingSeriesIsError() async throws {
        let tool = MakeChartTool()
        let output = try await tool.invoke(arguments: #"{"type":"bar"}"#)
        #expect(output.isError == true)
        #expect(output.display == .markdown)
        #expect(output.outputJSON.contains("error"))
    }

    @Test func emptySeriesArrayIsError() async throws {
        let tool = MakeChartTool()
        let output = try await tool.invoke(arguments: #"{"type":"bar","series":[]}"#)
        #expect(output.isError == true)
        #expect(output.outputJSON.lowercased().contains("least one"))
    }

    @Test func emptyPointsIsError() async throws {
        let tool = MakeChartTool()
        let output = try await tool.invoke(
            arguments: #"{"type":"bar","series":[{"name":"x","points":[]}]}"#
        )
        #expect(output.isError == true)
        #expect(output.outputJSON.lowercased().contains("no points"))
    }

    @Test func unknownChartTypeIsError() async throws {
        let tool = MakeChartTool()
        let output = try await tool.invoke(
            arguments: #"{"type":"radar","series":[{"name":"x","points":[{"x":"a","y":1}]}]}"#
        )
        #expect(output.isError == true)
    }

    @Test func definitionMentionsAllThreeChartTypes() {
        let def = MakeChartTool().definition(for: .english)
        #expect(def.name == "make_chart")
        let lower = def.description.lowercased()
        #expect(lower.contains("bar"))
        #expect(lower.contains("line"))
        #expect(lower.contains("pie"))
    }
}

@Suite("ChartSpec decoding")
struct ChartSpecDecodingTests {

    @Test func stringXValuesProduceCategorical() throws {
        let json = #"{"type":"bar","series":[{"points":[{"x":"A","y":1},{"x":"B","y":2}]}]}"#
        let spec = try ChartSpec(jsonData: Data(json.utf8))
        #expect(spec.hasCategoricalX == true)
    }

    @Test func numericXValuesProduceContinuous() throws {
        let json = #"{"type":"line","series":[{"points":[{"x":1,"y":10},{"x":2.5,"y":15}]}]}"#
        let spec = try ChartSpec(jsonData: Data(json.utf8))
        #expect(spec.hasCategoricalX == false)
    }

    @Test func mixedXValuesAreTreatedAsCategorical() throws {
        // Heuristic: any string anywhere → categorical. Mixing types is
        // documented as unsupported but we should not crash; categorical
        // is the safe default.
        let json = #"{"type":"bar","series":[{"points":[{"x":1,"y":10},{"x":"two","y":15}]}]}"#
        let spec = try ChartSpec(jsonData: Data(json.utf8))
        #expect(spec.hasCategoricalX == true)
    }

    @Test func multiSeriesPreservesOrder() throws {
        let json = #"""
        {"type":"line","series":[
            {"name":"A","points":[{"x":1,"y":10}]},
            {"name":"B","points":[{"x":1,"y":20}]},
            {"name":"C","points":[{"x":1,"y":30}]}
        ]}
        """#
        let spec = try ChartSpec(jsonData: Data(json.utf8))
        #expect(spec.series.map(\.name) == ["A", "B", "C"])
    }

    @Test func optionalFieldsAreOptional() throws {
        let minimal = #"{"type":"bar","series":[{"points":[{"x":"a","y":1}]}]}"#
        let spec = try ChartSpec(jsonData: Data(minimal.utf8))
        #expect(spec.title == nil)
        #expect(spec.xLabel == nil)
        #expect(spec.yLabel == nil)
        #expect(spec.series.first?.name == nil)
        #expect(spec.series.first?.points.first?.label == nil)
    }

    @Test func canonicalJSONIsStable() throws {
        let json = #"{"type":"bar","title":"X","series":[{"name":"S","points":[{"x":"a","y":1}]}]}"#
        let spec = try ChartSpec(jsonData: Data(json.utf8))
        let bytes1 = try spec.canonicalJSONData()
        let bytes2 = try spec.canonicalJSONData()
        #expect(bytes1 == bytes2)
    }
}
