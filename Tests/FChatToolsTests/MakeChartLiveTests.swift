// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
import FChatCore
import FChatProviders
@testable import FChatTools

/// Live integration test: ask the magi model to produce a chart via
/// `make_chart` and verify the JSON it streams as `arguments` parses
/// into a valid `ChartSpec`. Gated behind `FCHAT_LIVE_ENDPOINT=1` so
/// CI / unattended builds don't hit the network.
@Suite(
    "MakeChart live",
    .disabled(if: ProcessInfo.processInfo.environment["FCHAT_LIVE_ENDPOINT"] == nil,
              "set FCHAT_LIVE_ENDPOINT=1 to enable")
)
struct MakeChartLiveTests {

    @Test func modelProducesValidBarChartSpec() async throws {
        let provider = OpenAIResponsesProvider(
            id: ProviderID(rawValue: "magi-test"),
            baseURL: URL(string: "https://magi.fyrby.internal:8000/v1")!,
            secretStore: InMemorySecretStore()
        )
        let models = try await provider.listModels()
        let modelID = try #require(models.first?.id)

        let tool = MakeChartTool()
        let toolDef = tool.definition(for: .english)

        let prompt = """
        Use the make_chart tool to draw a BAR chart of quarterly revenue: \
        Q1=12.3, Q2=15.6, Q3=9.2, Q4=18.1. Title it "Revenue 2025". \
        Don't include any prose or markdown in your reply — just call \
        the tool exactly once.
        """

        let request = ChatRequest(
            model: modelID,
            input: [.message(role: .user, content: [.inputText(prompt)])],
            instructions: "You are a helpful assistant.",
            temperature: 0.0,
            reasoningEffort: nil,
            reasoningSummary: .auto,
            tools: [toolDef],
            toolChoice: .auto,
            store: false
        )

        // Collect tool-call argument bytes per callID as they stream.
        var argsByCallID: [String: String] = [:]
        var sawCallForMakeChart = false
        for try await event in provider.streamResponse(request) {
            switch event {
            case .toolCallStarted(_, _, let name):
                if name == "make_chart" { sawCallForMakeChart = true }
            case .toolCallArgumentsDelta(_, let callID, let delta):
                argsByCallID[callID, default: ""] += delta
            case .toolCallCompleted(_, let callID, let name, let arguments):
                if name == "make_chart" {
                    sawCallForMakeChart = true
                    argsByCallID[callID] = arguments
                }
            case .responseError(let message, _):
                Issue.record("provider error: \(message)")
                return
            default:
                break
            }
        }

        #expect(sawCallForMakeChart, "model did not call make_chart")
        let firstArgs = try #require(argsByCallID.values.first(where: { !$0.isEmpty }),
                                     "no make_chart call had arguments")

        // The crucial assertion: whatever JSON the model wrote, our
        // ChartSpec must parse it without error.
        let data = try #require(firstArgs.data(using: .utf8))
        let spec = try ChartSpec(jsonData: data)
        #expect(spec.type == .bar)
        #expect(spec.series.count >= 1)
        // 4 quarters of data.
        let totalPoints = spec.series.reduce(0) { $0 + $1.points.count }
        #expect(totalPoints == 4, "expected 4 points (Q1-Q4); got \(totalPoints)")
        // Y values should include our exact numbers.
        let ys = Set(spec.series.flatMap { $0.points.map(\.y) })
        #expect(ys.contains(12.3))
        #expect(ys.contains(15.6))
        #expect(ys.contains(9.2))
        #expect(ys.contains(18.1))
    }
}
