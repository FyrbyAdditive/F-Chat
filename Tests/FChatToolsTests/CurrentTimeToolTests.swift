// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
import FChatCore
import FChatProviders
@testable import FChatTools

@Suite("CurrentTimeTool")
struct CurrentTimeToolTests {

    @Test func emptyArgumentsReturnsLocalTime() async throws {
        let tool = CurrentTimeTool()
        let output = try await tool.invoke(arguments: "")
        #expect(output.isError == false)
        let parsed = try JSONSerialization.jsonObject(with: Data(output.outputJSON.utf8)) as? [String: String]
        #expect(parsed?["iso8601"] != nil)
        #expect(parsed?["human"] != nil)
        #expect(parsed?["timezone"] != nil)
    }

    @Test func explicitUTCReturnsUTC() async throws {
        let tool = CurrentTimeTool()
        let output = try await tool.invoke(arguments: #"{"timezone":"UTC"}"#)
        let parsed = try JSONSerialization.jsonObject(with: Data(output.outputJSON.utf8)) as? [String: String]
        // Foundation canonicalises TimeZone(identifier: "UTC")!.identifier
        // to "GMT" on macOS, which is what the LLM ends up seeing.
        #expect(parsed?["timezone"] == "GMT")
        // ISO-8601 in UTC ends with Z.
        #expect(parsed?["iso8601"]?.hasSuffix("Z") == true)
    }

    @Test func explicitIANAZoneHonoured() async throws {
        let tool = CurrentTimeTool()
        let output = try await tool.invoke(arguments: #"{"timezone":"Asia/Tokyo"}"#)
        let parsed = try JSONSerialization.jsonObject(with: Data(output.outputJSON.utf8)) as? [String: String]
        #expect(parsed?["timezone"] == "Asia/Tokyo")
    }

    @Test func unknownTimezoneFallsBackToLocal() async throws {
        // Bad zone identifiers should NOT error — fall back to local so
        // the model still gets a useful answer.
        let tool = CurrentTimeTool()
        let output = try await tool.invoke(arguments: #"{"timezone":"Atlantis/Lost_City"}"#)
        #expect(output.isError == false)
        let parsed = try JSONSerialization.jsonObject(with: Data(output.outputJSON.utf8)) as? [String: String]
        let tz = parsed?["timezone"]
        #expect(tz != "Atlantis/Lost_City")
        #expect(tz == TimeZone.current.identifier)
    }

    @Test func definitionMentionsTimezoneParameter() {
        let def = CurrentTimeTool().definition(for: .english)
        #expect(def.name == "current_time")
        #expect(def.parametersSchema.raw.contains("timezone"))
    }
}
