// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FyxLocalTools

@Suite("MapsTool")
struct MapsToolTests {

    /// Stub provider recording calls.
    actor StubMap: MapProvider {
        let auth: MapAuth
        let location: Coordinate?
        let pool: [Place]
        let route: RouteInfo?
        private(set) var lastSearchNear: Coordinate??   // outer optional = "was search called"
        private(set) var searchCalls = 0
        private(set) var lastLimit: Int?

        init(auth: MapAuth = .authorized, location: Coordinate? = nil, pool: [Place] = [], route: RouteInfo? = nil) {
            self.auth = auth
            self.location = location
            self.pool = pool
            self.route = route
        }
        func locationAuthorization() async -> MapAuth { auth }
        func requestLocationAccess() async -> MapAuth { auth }
        func currentLocation() async -> Coordinate? { location }
        func search(query: String, near: Coordinate?, limit: Int) async throws -> [Place] {
            searchCalls += 1
            lastSearchNear = .some(near)
            lastLimit = limit
            return Array(pool.prefix(limit))
        }
        func geocode(address: String) async throws -> [Place] { pool }
        func reverseGeocode(_ c: Coordinate) async throws -> Place? { pool.first }
        func directions(from: Coordinate, to: Coordinate, transport: String) async throws -> RouteInfo {
            route ?? RouteInfo(distanceMeters: 0, travelTimeSeconds: 0, transport: transport, steps: [], polyline: [])
        }
    }

    private func places() -> [Place] {
        [
            Place(name: "Blue Bottle", address: "1 Main St", latitude: 51.50, longitude: -0.12),
            Place(name: "Monmouth", address: "2 Market St", latitude: 51.51, longitude: -0.09),
        ]
    }

    private func obj(_ out: ToolOutput) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(out.outputJSON.utf8)) as? [String: Any] ?? [:]
    }

    @Test func searchReturnsPlacesAndMapPins() async throws {
        let t = MapsTool(provider: StubMap(pool: places()))
        let out = try await t.invoke(arguments: #"{"action":"search","query":"coffee"}"#)
        #expect(out.isError == false)
        #expect(out.display == .map)
        let o = try obj(out)
        #expect((o["count"] as? Int) == 2)
        let map = o["map"] as? [String: Any]
        let pins = map?["pins"] as? [[String: Any]]
        #expect(pins?.count == 2)
        #expect((pins?.first?["title"] as? String) == "Blue Bottle")
    }

    @Test func searchRequiresQuery() async throws {
        let t = MapsTool(provider: StubMap(pool: places()))
        let out = try await t.invoke(arguments: #"{"action":"search"}"#)
        #expect(out.isError == true)
    }

    @Test func nearMeWithLocationBiasesSearch() async throws {
        let here = Coordinate(lat: 51.5, lon: -0.1)
        let stub = StubMap(location: here, pool: places())
        let t = MapsTool(provider: stub)
        _ = try await t.invoke(arguments: #"{"action":"search","query":"coffee","near":"me"}"#)
        // The final search call should be biased by the current location.
        let near = await stub.lastSearchNear
        #expect(near == .some(.some(here)))
    }

    @Test func nearMeWithoutLocationFallsBackNoError() async throws {
        // Denied/!location: tool should still succeed (unbiased) and note it.
        let t = MapsTool(provider: StubMap(auth: .denied, location: nil, pool: places()))
        let out = try await t.invoke(arguments: #"{"action":"search","query":"coffee","near":"me"}"#)
        #expect(out.isError == false)
        let o = try obj(out)
        #expect(o["note"] != nil)   // explains the fallback
    }

    @Test func directionsReturnsRouteAndTwoPins() async throws {
        let route = RouteInfo(
            distanceMeters: 12000, travelTimeSeconds: 1500, transport: "automobile",
            steps: ["Head north", "Turn left"],
            polyline: [Coordinate(lat: 51.50, lon: -0.12), Coordinate(lat: 51.53, lon: -0.10)]
        )
        let t = MapsTool(provider: StubMap(pool: places(), route: route))
        let out = try await t.invoke(arguments: #"{"action":"directions","from":"A","to":"B"}"#)
        #expect(out.isError == false)
        #expect(out.display == .map)
        let o = try obj(out)
        let r = o["route"] as? [String: Any]
        #expect((r?["distanceMeters"] as? Double) == 12000)
        let map = o["map"] as? [String: Any]
        #expect((map?["pins"] as? [[String: Any]])?.count == 2)
        #expect((map?["route"] as? [[String: Any]])?.count == 2)
    }

    @Test func directionsRequiresFromAndTo() async throws {
        let t = MapsTool(provider: StubMap(pool: places()))
        let out = try await t.invoke(arguments: #"{"action":"directions","from":"A"}"#)
        #expect(out.isError == true)
    }

    @Test func reverseGeocodeReturnsPlace() async throws {
        let t = MapsTool(provider: StubMap(pool: places()))
        let out = try await t.invoke(arguments: #"{"action":"reverse_geocode","lat":51.5,"lon":-0.1}"#)
        #expect(out.isError == false)
        #expect(out.display == .map)
        let o = try obj(out)
        #expect((o["count"] as? Int) == 1)
    }

    @Test func reverseGeocodeRequiresLatLon() async throws {
        let t = MapsTool(provider: StubMap(pool: places()))
        let out = try await t.invoke(arguments: #"{"action":"reverse_geocode","lat":51.5}"#)
        #expect(out.isError == true)
    }

    @Test func geocodeReturnsPlaces() async throws {
        let t = MapsTool(provider: StubMap(pool: places()))
        let out = try await t.invoke(arguments: #"{"action":"geocode","address":"1 Main St"}"#)
        #expect(out.isError == false)
        #expect(out.display == .map)
    }

    @Test func limitClampedToMax() async throws {
        let stub = StubMap(pool: places())
        let t = MapsTool(provider: stub)
        _ = try await t.invoke(arguments: #"{"action":"search","query":"x","limit":9999}"#)
        #expect(await stub.lastLimit == 25)
    }

    @Test func locateReturnsCurrentPlace() async throws {
        let here = Coordinate(lat: 59.33, lon: 18.07)   // Stockholm
        let stub = StubMap(location: here, pool: [Place(name: "Stockholm", address: "Stockholm, Sweden", latitude: 59.33, longitude: 18.07)])
        let t = MapsTool(provider: stub)
        let out = try await t.invoke(arguments: #"{"action":"locate"}"#)
        #expect(out.isError == false)
        #expect(out.display == .map)
        let o = try obj(out)
        #expect((o["count"] as? Int) == 1)
    }

    @Test func locateWithoutLocationErrors() async throws {
        let t = MapsTool(provider: StubMap(location: nil))
        let out = try await t.invoke(arguments: #"{"action":"locate"}"#)
        #expect(out.isError == true)
    }

    @Test func unknownActionErrors() async throws {
        let t = MapsTool(provider: StubMap())
        let out = try await t.invoke(arguments: #"{"action":"teleport"}"#)
        #expect(out.isError == true)
    }

    @Test func malformedArgsErrors() async throws {
        let t = MapsTool(provider: StubMap())
        let out = try await t.invoke(arguments: #"{"action":123}"#)
        #expect(out.isError == true)
    }
}
