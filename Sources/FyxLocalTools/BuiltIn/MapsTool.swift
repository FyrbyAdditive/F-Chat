// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FyxLocalCore
import FyxLocalProviders

/// Read-only Apple Maps access: place/POI search, directions & ETA, and
/// geocoding, via an injected `MapProvider` (MapKit + Core Location in the app
/// layer). Every result carries a `MapSpec` so the UI can render an interactive
/// map inline (`display: .map`), plus structured data the model can talk about.
///
/// Needs NO write-confirmation (read-only) and NO entitlement. Only "near me"
/// touches Core Location; when it's unauthorized the tool falls back to an
/// unbiased search rather than failing.
public struct MapsTool: Tool {
    public let name = "maps"
    public let provider: any MapProvider
    public let defaultLimit: Int
    public let maxLimit: Int

    public init(provider: any MapProvider, defaultLimit: Int = 10, maxLimit: Int = 25) {
        self.provider = provider
        self.defaultLimit = defaultLimit
        self.maxLimit = maxLimit
    }

    public func definition(for language: PromptLanguage) -> ToolDefinition {
        let description = PromptStrings.string("tool.maps.desc", language)
        let schema = JSONSchema(raw: #"""
        {"type":"object","properties":{"action":{"type":"string","enum":["locate","search","directions","geocode","reverse_geocode"]},"query":{"type":"string","description":"search: natural-language place query."},"near":{"type":"string","description":"search: \"me\" for device location, or a place/address to bias around."},"from":{"type":"string","description":"directions: origin place name or address (or \"me\")."},"to":{"type":"string","description":"directions: destination place name or address."},"transport":{"type":"string","enum":["automobile","walking","transit"],"description":"directions: travel mode (default automobile)."},"address":{"type":"string","description":"geocode: address to resolve."},"lat":{"type":"number","description":"reverse_geocode: latitude."},"lon":{"type":"number","description":"reverse_geocode: longitude."},"limit":{"type":"integer","minimum":1,"maximum":25,"description":"search: max results (default 10)."}},"required":["action"],"additionalProperties":false}
        """#)
        return ToolDefinition(name: name, description: description, parametersSchema: schema, strict: false)
    }

    private struct Args: Decodable {
        let action: String
        let query: String?
        let near: String?
        let from: String?
        let to: String?
        let transport: String?
        let address: String?
        let lat: Double?
        let lon: Double?
        let limit: Int?
    }

    public func invoke(arguments: String) async throws -> ToolOutput {
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalised = trimmed.isEmpty ? "{}" : trimmed
        guard let data = normalised.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(Args.self, from: data) else {
            return errorOutput("Could not parse arguments. Got: \(arguments.escapedForJSONInline())")
        }

        switch parsed.action.lowercased() {
        case "locate": return await locate()
        case "search": return await search(parsed)
        case "directions": return await directions(parsed)
        case "geocode": return await geocode(parsed)
        case "reverse_geocode": return await reverseGeocode(parsed)
        default:
            return errorOutput("Unknown action '\(parsed.action.escapedForJSONInline())'. Use locate, search, directions, geocode, or reverse_geocode.")
        }
    }

    // MARK: - Actions

    /// "Where am I" — current location, reverse-geocoded to a human place.
    private func locate() async -> ToolOutput {
        guard let here = await provider.currentLocation() else {
            return errorOutput("Your location isn't available. Make sure Location is allowed for FyxLocal in System Settings → Privacy & Security → Location Services, then try again — or tell me a place to use instead.")
        }
        let place = (try? await provider.reverseGeocode(here))
            ?? Place(name: "Current location", latitude: here.lat, longitude: here.lon)
        let pin = MapSpec.Pin(lat: place.latitude, lon: place.longitude, title: place.name, subtitle: place.address)
        let spec = MapSpec.fitting([place.coordinate], pins: [pin], summary: place.address ?? "Current location")
        let payload = SearchPayload(action: "locate", count: 1, places: [place], note: nil, map: spec)
        return encoded(payload)
    }

    private func search(_ args: Args) async -> ToolOutput {
        guard let query = args.query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            return errorOutput("search requires a `query`.")
        }
        let limit = max(1, min(args.limit ?? defaultLimit, maxLimit))

        // Resolve an optional region bias from `near`.
        var bias: Coordinate?
        var locationNote: String?
        if let near = args.near?.trimmingCharacters(in: .whitespacesAndNewlines), !near.isEmpty {
            if near.lowercased() == "me" {
                bias = await provider.currentLocation()
                if bias == nil {
                    locationNote = "Your location isn't available (not allowed or off) — searching without a location bias. Ask the user for an area if needed."
                }
            } else if let resolved = try? await provider.search(query: near, near: nil, limit: 1).first {
                bias = resolved.coordinate
            } else if let geo = try? await provider.geocode(address: near).first {
                bias = geo.coordinate
            }
        }

        do {
            let places = try await provider.search(query: query, near: bias, limit: limit)
            let pins = places.map { MapSpec.Pin(lat: $0.latitude, lon: $0.longitude, title: $0.name, subtitle: $0.address) }
            let coords = places.map(\.coordinate)
            let summary = places.isEmpty ? "No results for “\(query)”." : "\(places.count) result(s) for “\(query)”."
            let spec = MapSpec.fitting(coords, pins: pins, summary: summary)
            let payload = SearchPayload(action: "search", count: places.count, places: places, note: locationNote, map: spec)
            return encoded(payload)
        } catch {
            return errorOutput("maps search failed: \(error.localizedDescription.escapedForJSONInline())")
        }
    }

    private func directions(_ args: Args) async -> ToolOutput {
        guard let fromStr = args.from?.trimmingCharacters(in: .whitespacesAndNewlines), !fromStr.isEmpty,
              let toStr = args.to?.trimmingCharacters(in: .whitespacesAndNewlines), !toStr.isEmpty else {
            return errorOutput("directions requires `from` and `to`.")
        }
        let transport = (args.transport ?? "automobile").lowercased()

        guard let fromCoord = await resolvePlace(fromStr) else {
            return errorOutput("Couldn't find a location for `from`: “\(fromStr.escapedForJSONInline())”.")
        }
        guard let toResolved = await resolvePlaceFull(toStr) else {
            return errorOutput("Couldn't find a location for `to`: “\(toStr.escapedForJSONInline())”.")
        }
        let fromResolved = await resolvePlaceFull(fromStr)

        do {
            let route = try await provider.directions(from: fromCoord, to: toResolved.coordinate, transport: transport)
            var pins: [MapSpec.Pin] = []
            if let f = fromResolved { pins.append(.init(lat: f.latitude, lon: f.longitude, title: "Start", subtitle: f.name)) }
            else { pins.append(.init(lat: fromCoord.lat, lon: fromCoord.lon, title: "Start", subtitle: fromStr)) }
            pins.append(.init(lat: toResolved.latitude, lon: toResolved.longitude, title: "End", subtitle: toResolved.name))
            let frameCoords = route.polyline.isEmpty ? pins.map { Coordinate(lat: $0.lat, lon: $0.lon) } : route.polyline
            let summary = "\(Self.km(route.distanceMeters)), about \(Self.minutes(route.travelTimeSeconds)) by \(transport)."
            let spec = MapSpec.fitting(frameCoords, pins: pins, route: route.polyline, summary: summary)
            let payload = DirectionsPayload(action: "directions", route: route, map: spec)
            return encoded(payload)
        } catch {
            // "No route found" most often means the requested mode isn't
            // available for this route — for transit that's common (Apple has no
            // public-transit data for many areas). Be explicit and DON'T silently
            // substitute another mode; let the user decide.
            let ns = error as NSError
            let noRoute = ns.domain == "MKErrorDomain" && ns.code == 5
            if noRoute && transport == "transit" {
                return errorOutput("No public-transit route is available between “\(fromStr.escapedForJSONInline())” and “\(toStr.escapedForJSONInline())” (Apple Maps has no transit data for this area). Tell the user transit isn't available here; offer driving or walking only if they want it — do not assume.")
            }
            if noRoute {
                return errorOutput("No \(transport) route was found between “\(fromStr.escapedForJSONInline())” and “\(toStr.escapedForJSONInline())”.")
            }
            return errorOutput("maps directions failed: \(error.localizedDescription.escapedForJSONInline())")
        }
    }

    private func geocode(_ args: Args) async -> ToolOutput {
        guard let address = args.address?.trimmingCharacters(in: .whitespacesAndNewlines), !address.isEmpty else {
            return errorOutput("geocode requires an `address`.")
        }
        do {
            let places = try await provider.geocode(address: address)
            let pins = places.map { MapSpec.Pin(lat: $0.latitude, lon: $0.longitude, title: $0.name, subtitle: $0.address) }
            let summary = places.isEmpty ? "No match for “\(address)”." : (places.first?.address ?? places.first?.name ?? address)
            let spec = MapSpec.fitting(places.map(\.coordinate), pins: pins, summary: summary)
            let payload = SearchPayload(action: "geocode", count: places.count, places: places, note: nil, map: spec)
            return encoded(payload)
        } catch {
            return errorOutput("maps geocode failed: \(error.localizedDescription.escapedForJSONInline())")
        }
    }

    private func reverseGeocode(_ args: Args) async -> ToolOutput {
        guard let lat = args.lat, let lon = args.lon else {
            return errorOutput("reverse_geocode requires `lat` and `lon`.")
        }
        do {
            guard let place = try await provider.reverseGeocode(Coordinate(lat: lat, lon: lon)) else {
                return errorOutput("No address found at \(lat), \(lon).")
            }
            let pin = MapSpec.Pin(lat: place.latitude, lon: place.longitude, title: place.name, subtitle: place.address)
            let spec = MapSpec.fitting([place.coordinate], pins: [pin], summary: place.address ?? place.name)
            let payload = SearchPayload(action: "reverse_geocode", count: 1, places: [place], note: nil, map: spec)
            return encoded(payload)
        } catch {
            return errorOutput("maps reverse_geocode failed: \(error.localizedDescription.escapedForJSONInline())")
        }
    }

    // MARK: - Helpers

    /// Resolve a free-text place ("me" / name / address) to a coordinate.
    private func resolvePlace(_ text: String) async -> Coordinate? {
        if text.lowercased() == "me" { return await provider.currentLocation() }
        return await resolvePlaceFull(text)?.coordinate
    }

    /// Resolve a free-text place to a full `Place` (for pin labels).
    private func resolvePlaceFull(_ text: String) async -> Place? {
        if let hit = try? await provider.search(query: text, near: nil, limit: 1).first { return hit }
        if let geo = try? await provider.geocode(address: text).first { return geo }
        return nil
    }

    private func encoded<T: Encodable>(_ payload: T) -> ToolOutput {
        do {
            let json = try JSONEncoder().encode(payload)
            return ToolOutput(outputJSON: String(decoding: json, as: UTF8.self), isError: false, display: .map)
        } catch {
            return errorOutput("failed to encode map result: \(error.localizedDescription.escapedForJSONInline())")
        }
    }

    private static func km(_ meters: Double) -> String {
        if meters < 1000 { return "\(Int(meters.rounded())) m" }
        return String(format: "%.1f km", meters / 1000)
    }
    private static func minutes(_ seconds: Double) -> String {
        let mins = Int((seconds / 60).rounded())
        if mins < 60 { return "\(mins) min" }
        let h = mins / 60, m = mins % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }
}

// MARK: - Output payloads

private struct SearchPayload: Encodable {
    let action: String
    let count: Int
    let places: [Place]
    let note: String?
    let map: MapSpec
}

private struct DirectionsPayload: Encodable {
    let action: String
    let route: RouteInfo
    let map: MapSpec
}
