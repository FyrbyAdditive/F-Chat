// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

/// A geographic coordinate, flattened to Sendable values.
public struct Coordinate: Sendable, Hashable, Codable {
    public var lat: Double
    public var lon: Double
    public init(lat: Double, lon: Double) {
        self.lat = lat
        self.lon = lon
    }
}

/// One place / point of interest, flattened to Sendable values. The platform
/// `MKMapItem`/`CLPlacemark` is mapped to this in the app layer so `FyxLocalTools`
/// never imports MapKit.
public struct Place: Sendable, Hashable, Codable {
    public var name: String
    public var address: String?
    public var latitude: Double
    public var longitude: Double
    public var phone: String?
    public var url: String?
    public var category: String?    // POI category, if any

    public init(
        name: String,
        address: String? = nil,
        latitude: Double,
        longitude: Double,
        phone: String? = nil,
        url: String? = nil,
        category: String? = nil
    ) {
        self.name = name
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.phone = phone
        self.url = url
        self.category = category
    }

    public var coordinate: Coordinate { Coordinate(lat: latitude, lon: longitude) }
}

/// A computed route between two points, flattened to Sendable values.
public struct RouteInfo: Sendable, Hashable, Codable {
    public var distanceMeters: Double
    public var travelTimeSeconds: Double
    public var transport: String        // "automobile" | "walking" | "transit"
    public var steps: [String]          // step instructions (text)
    public var polyline: [Coordinate]   // decoded geometry for the map overlay

    public init(
        distanceMeters: Double,
        travelTimeSeconds: Double,
        transport: String,
        steps: [String],
        polyline: [Coordinate]
    ) {
        self.distanceMeters = distanceMeters
        self.travelTimeSeconds = travelTimeSeconds
        self.transport = transport
        self.steps = steps
        self.polyline = polyline
    }
}

/// Core Location authorization tiers (for "near me" queries only; all other
/// map actions need no authorization).
public enum MapAuth: Sendable, Equatable {
    case authorized
    case denied
    case restricted
    case notDetermined
    case unavailable    // location services off / platform without Core Location
}

/// A declarative spec for the inline map widget. Mirrors `ChartSpec`: the tool
/// emits this as JSON with `display: .map`, and `ToolMapView` (app layer) renders
/// a live SwiftUI `Map` from it. Defined here in `FyxLocalTools` so it stays
/// platform-free; the UI owns all MapKit rendering.
public struct MapSpec: Sendable, Hashable, Codable {
    public struct Pin: Sendable, Hashable, Codable {
        public var lat: Double
        public var lon: Double
        public var title: String
        public var subtitle: String?
        public init(lat: Double, lon: Double, title: String, subtitle: String? = nil) {
            self.lat = lat
            self.lon = lon
            self.title = title
            self.subtitle = subtitle
        }
    }

    public var centerLat: Double
    public var centerLon: Double
    public var spanLat: Double          // latitude delta (degrees) for region framing
    public var spanLon: Double          // longitude delta (degrees)
    public var pins: [Pin]
    public var route: [Coordinate]      // empty unless a directions result
    public var summary: String          // human-readable caption

    public init(
        centerLat: Double,
        centerLon: Double,
        spanLat: Double,
        spanLon: Double,
        pins: [Pin],
        route: [Coordinate] = [],
        summary: String
    ) {
        self.centerLat = centerLat
        self.centerLon = centerLon
        self.spanLat = spanLat
        self.spanLon = spanLon
        self.pins = pins
        self.route = route
        self.summary = summary
    }

    /// Frame a region around a set of coordinates with sensible padding. Returns
    /// a single-point default span when there's one (or zero) coordinate.
    public static func fitting(_ coords: [Coordinate], pins: [Pin], route: [Coordinate] = [], summary: String) -> MapSpec {
        guard let first = coords.first else {
            return MapSpec(centerLat: 0, centerLon: 0, spanLat: 1, spanLon: 1, pins: pins, route: route, summary: summary)
        }
        var minLat = first.lat, maxLat = first.lat
        var minLon = first.lon, maxLon = first.lon
        for c in coords {
            minLat = min(minLat, c.lat); maxLat = max(maxLat, c.lat)
            minLon = min(minLon, c.lon); maxLon = max(maxLon, c.lon)
        }
        let centerLat = (minLat + maxLat) / 2
        let centerLon = (minLon + maxLon) / 2
        // Pad by 40%, with a floor so a single point still shows a useful area.
        let spanLat = max((maxLat - minLat) * 1.4, 0.01)
        let spanLon = max((maxLon - minLon) * 1.4, 0.01)
        return MapSpec(centerLat: centerLat, centerLon: centerLon, spanLat: spanLat, spanLon: spanLon, pins: pins, route: route, summary: summary)
    }
}

/// Abstraction over Apple Maps / Core Location. The concrete MapKit-backed
/// implementation is injected from the app layer (mirrors `CalendarProvider`).
/// Read-only — no writes, no confirmation machinery. Only "near me" needs
/// location authorization; search/geocode/directions are permission-free.
public protocol MapProvider: Sendable {
    func locationAuthorization() async -> MapAuth
    /// Trigger the system Location prompt (when-in-use) when `notDetermined`.
    func requestLocationAccess() async -> MapAuth
    /// One current-location fix, or nil if unauthorized/unavailable.
    func currentLocation() async -> Coordinate?
    /// Natural-language place search. `near` biases the region (user location or
    /// a resolved place); nil means an unbiased global search.
    func search(query: String, near: Coordinate?, limit: Int) async throws -> [Place]
    /// Forward geocode an address string to candidate places.
    func geocode(address: String) async throws -> [Place]
    /// Reverse geocode a coordinate to a place. nil if nothing found.
    func reverseGeocode(_ coordinate: Coordinate) async throws -> Place?
    /// Compute a route between two coordinates for the given transport type.
    func directions(from: Coordinate, to: Coordinate, transport: String) async throws -> RouteInfo
}
