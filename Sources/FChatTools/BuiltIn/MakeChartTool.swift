// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FChatCore
import FChatProviders

/// Built-in tool that asks the model for a small JSON chart spec and
/// echoes it back as a `.chart`-typed tool result. The UI side
/// (`ToolChartView` in FChatApp) then renders it as a Swift Charts bar /
/// line / pie chart inline in the transcript bubble.
///
/// The tool exists so the model can produce *visual* output rather than
/// only prose / tables. Opt-in (not in defaultEnabledTools): users enable
/// in Settings → Tools when they want it.
///
/// Validation rules: we re-emit the spec verbatim on success so the UI
/// gets the exact bytes the model supplied (deterministic for tests and
/// for disk round-trip). On failure we surface a human-readable error so
/// the model can correct on the next iteration.
public struct MakeChartTool: Tool {
    public let name = "make_chart"

    public init() {}

    public func definition(for language: PromptLanguage) -> ToolDefinition {
        let description: String
        switch language {
        case .english:
            description = """
            Render a small chart inline in the chat. Supported types: \
            "bar", "line", "pie". Provide a `series` array of \
            `{name, points}`; each point is `{x, y, label?}`. `x` can be \
            a string (categorical axis) or a number (continuous axis); \
            mix-and-match isn't supported — pick one per chart. `y` is \
            always a number. Optional top-level fields: `title`, \
            `xLabel`, `yLabel` (xLabel/yLabel are ignored for pies). \
            For pie charts use one series; each point's `x` becomes the \
            slice label and `y` its size. Use this when the user asks \
            for a chart, a "graph", or when a visual comparison would \
            be much clearer than a table.
            """
        case .swedish:
            description = """
            Rita ett litet diagram direkt i chatten. Stödda typer: \
            "bar", "line", "pie". Skicka en `series`-array med \
            `{name, points}`; varje punkt är `{x, y, label?}`. `x` kan \
            vara en sträng (kategorisk axel) eller ett tal (kontinuerlig \
            axel) — blanda inte i samma diagram. `y` är alltid ett tal. \
            Valfria toppfält: `title`, `xLabel`, `yLabel` (de senare \
            ignoreras för pajdiagram). För pajdiagram, använd en serie \
            där varje punkts `x` blir tårtbitens etikett och `y` dess \
            storlek. Använd verktyget när användaren ber om en graf, \
            ett diagram eller när en visuell jämförelse är mycket \
            tydligare än en tabell.
            """
        }
        let schema = JSONSchema(raw: #"""
        {"type":"object","properties":{"type":{"type":"string","enum":["bar","line","pie"]},"title":{"type":"string"},"xLabel":{"type":"string"},"yLabel":{"type":"string"},"series":{"type":"array","minItems":1,"items":{"type":"object","properties":{"name":{"type":"string"},"points":{"type":"array","minItems":1,"items":{"type":"object","properties":{"x":{},"y":{"type":"number"},"label":{"type":"string"}},"required":["x","y"]}}},"required":["points"]}}},"required":["type","series"],"additionalProperties":false}
        """#)
        return ToolDefinition(name: name, description: description, parametersSchema: schema, strict: false)
    }

    public func invoke(arguments: String) async throws -> ToolOutput {
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalised = trimmed.isEmpty ? "{}" : trimmed
        guard let data = normalised.data(using: .utf8) else {
            return error("Arguments not valid UTF-8.")
        }
        do {
            // Validate by parsing through our spec model. On success we
            // re-emit canonical JSON so the UI sees the same bytes the
            // tests assert, regardless of the model's key order.
            let spec = try ChartSpec(jsonData: data)
            let canonical = try spec.canonicalJSONData()
            let outputJSON = String(data: canonical, encoding: .utf8) ?? normalised
            return ToolOutput(outputJSON: outputJSON, isError: false, display: .chart)
        } catch let e as ChartSpec.ValidationError {
            return error(e.message)
        } catch {
            return self.error("Could not parse chart spec: \(error.localizedDescription)")
        }
    }

    private func error(_ message: String) -> ToolOutput {
        ToolOutput(
            outputJSON: "{\"error\":\"\(message.escapedForJSON())\"}",
            isError: true,
            display: .markdown
        )
    }
}

/// Decodable model of the chart-tool JSON, shared between the tool (for
/// validation) and the UI (for rendering). Lives in FChatTools so both
/// FChatTools tests and the FChatApp renderer can import it; the renderer
/// itself is in FChatApp because Swift Charts is a UI dependency.
public struct ChartSpec: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case bar, line, pie
    }
    public struct Series: Sendable, Hashable, Codable {
        public var name: String?
        public var points: [Point]
    }
    public struct Point: Sendable, Hashable, Codable {
        /// X-axis value; either a string (categorical) or a number
        /// (continuous). We accept both during decode and decide which
        /// scale the chart uses based on whether any point has a string.
        public var x: XValue
        public var y: Double
        public var label: String?
    }
    public enum XValue: Sendable, Hashable, Codable {
        case string(String)
        case number(Double)

        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) {
                self = .string(s)
            } else if let n = try? c.decode(Double.self) {
                self = .number(n)
            } else {
                throw DecodingError.typeMismatch(
                    XValue.self,
                    .init(codingPath: decoder.codingPath, debugDescription: "x must be String or Number")
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .string(let s): try c.encode(s)
            case .number(let n): try c.encode(n)
            }
        }

        public var stringValue: String {
            switch self {
            case .string(let s): return s
            case .number(let n):
                if n == n.rounded() {
                    return String(Int(n))
                }
                return String(n)
            }
        }
        public var numberValue: Double? {
            if case .number(let n) = self { return n }
            return nil
        }
    }

    public var type: Kind
    public var title: String?
    public var xLabel: String?
    public var yLabel: String?
    public var series: [Series]

    public struct ValidationError: Error {
        public let message: String
    }

    public init(jsonData: Data) throws {
        let decoder = JSONDecoder()
        let decoded: ChartSpec
        do {
            decoded = try decoder.decode(ChartSpec.self, from: jsonData)
        } catch {
            throw ValidationError(message: "Expected `{type, series, ...}` shape. Decode error: \(error)")
        }
        try decoded.validate()
        self = decoded
    }

    public init(
        type: Kind,
        title: String? = nil,
        xLabel: String? = nil,
        yLabel: String? = nil,
        series: [Series]
    ) {
        self.type = type
        self.title = title
        self.xLabel = xLabel
        self.yLabel = yLabel
        self.series = series
    }

    public func validate() throws {
        guard !series.isEmpty else {
            throw ValidationError(message: "`series` must contain at least one series.")
        }
        for (i, s) in series.enumerated() {
            guard !s.points.isEmpty else {
                throw ValidationError(message: "Series \(i) has no points.")
            }
        }
    }

    /// Returns true when at least one point's x is a string. Drives the
    /// renderer's choice between categorical (BarMark over a string axis)
    /// and continuous (BarMark over a numeric axis).
    public var hasCategoricalX: Bool {
        for s in series {
            for p in s.points {
                if case .string = p.x { return true }
            }
        }
        return false
    }

    public func canonicalJSONData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}
