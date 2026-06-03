// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FyxLocalTools
#if canImport(MapKit)
import MapKit
import CoreLocation
#endif

/// MapKit + Core Location implementation of `MapProvider`, in the app layer so
/// `FyxLocalTools` never imports MapKit. MapKit objects (`MKMapItem`, `MKRoute`,
/// `CLPlacemark`) are non-Sendable, so everything is mapped to the Sendable
/// `Place`/`RouteInfo` before crossing back out.
///
/// Needs NO entitlement (unlike Calendar/Reminders/Contacts). Only "near me"
/// touches Core Location, gated by `NSLocationWhenInUseUsageDescription` + the
/// runtime TCC prompt. `CLGeocoder` is rate-limited, so address lookups prefer
/// `MKLocalSearch` and `CLGeocoder` is reserved for coordinate→address.
final class MKMapProvider: MapProvider {
#if canImport(MapKit)
    // A retained, main-actor delegate object owns the CLLocationManager and
    // bridges the delegate callbacks to async/await. Core Location on macOS
    // needs a delegate set BEFORE requesting authorization, the manager kept
    // alive across the async prompt, and an explicit requestLocation() to get a
    // fix (reading `manager.location` alone never triggers one). A single shared
    // instance so authorization + fixes refer to the same manager.
    @MainActor private static let oneShot = LocationOneShot()

    // MARK: - Location authorization ("near me" only)

    @MainActor
    func locationAuthorization() async -> MapAuth {
        guard CLLocationManager.locationServicesEnabled() else { return .unavailable }
        return Self.map(Self.oneShot.status)
    }

    @MainActor
    func requestLocationAccess() async -> MapAuth {
        Self.map(await Self.oneShot.requestAuthorization())
    }

    @MainActor
    func currentLocation() async -> Coordinate? {
        guard CLLocationManager.locationServicesEnabled() else { return nil }
        return await Self.oneShot.currentLocation()
    }

    // MARK: - Search

    @MainActor
    func search(query: String, near: Coordinate?, limit: Int) async throws -> [Place] {
        // If the query names a known POI category (e.g. "petrol station" /
        // "gas" / "bensinstation" → .gasStation), search by CATEGORY, which is
        // language-independent — `naturalLanguageQuery` is a NAME matcher and
        // fails for English category words near a Swedish location, which is why
        // "petrol station" returned nothing and the model fell back to a brand.
        if let near, let category = Self.category(for: query) {
            if let byCategory = try? await categorySearch(category, near: near, limit: limit), !byCategory.isEmpty {
                return byCategory
            }
            // fall through to text search if the category search came back empty
        }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = .pointOfInterest
        if let near {
            request.region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: near.lat, longitude: near.lon),
                latitudinalMeters: 25_000, longitudinalMeters: 25_000
            )
        }
        let response = try await MKLocalSearch(request: request).start()
        return Self.sortedByDistance(response.mapItems.map(Self.place(from:)), near: near, limit: limit)
    }

    /// Category POI search with radius widening (5 → 15 → 50 km, capped at the
    /// API max), nearest-first. Used for "nearest X" category queries.
    @MainActor
    private func categorySearch(_ category: MKPointOfInterestCategory, near: Coordinate, limit: Int) async throws -> [Place] {
        let center = CLLocationCoordinate2D(latitude: near.lat, longitude: near.lon)
        for radius in [5_000.0, 15_000.0, 50_000.0] {
            let r = min(radius, MKLocalPointsOfInterestRequest.maxRadius)
            let request = MKLocalPointsOfInterestRequest(center: center, radius: r)
            request.pointOfInterestFilter = MKPointOfInterestFilter(including: [category])
            if let response = try? await MKLocalSearch(request: request).start(), !response.mapItems.isEmpty {
                return Self.sortedByDistance(response.mapItems.map(Self.place(from:)), near: near, limit: limit)
            }
        }
        return []
    }

    /// MKLocalSearch ranks by relevance, NOT distance — so a farther match can
    /// outrank the nearest. With a bias point, sort by true distance.
    private static func sortedByDistance(_ places: [Place], near: Coordinate?, limit: Int) -> [Place] {
        guard let near else { return Array(places.prefix(limit)) }
        let origin = CLLocation(latitude: near.lat, longitude: near.lon)
        let sorted = places.sorted {
            origin.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))
                < origin.distance(from: CLLocation(latitude: $1.latitude, longitude: $1.longitude))
        }
        return Array(sorted.prefix(limit))
    }

    /// Map a free-text query to a POI category when it clearly names one. Covers
    /// English + Swedish synonyms for the common asks; returns nil otherwise (so
    /// the caller falls back to name-based text search).
    private static func category(for query: String) -> MKPointOfInterestCategory? {
        let q = query.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { q.contains($0) } }
        if has(["petrol", "gas station", "gas ", "fuel", "bensin", "tank", "mack"]) { return .gasStation }
        if has(["ev charg", "charging station", "laddstation", "laddstolpe"]) { return .evCharger }
        if has(["pharmacy", "chemist", "drugstore", "apotek"]) { return .pharmacy }
        if has(["hospital", "sjukhus", "akuten", "emergency room"]) { return .hospital }
        if has(["cafe", "café", "coffee", "fik"]) { return .cafe }
        if has(["restaurant", "restaurang", "diner", "eatery"]) { return .restaurant }
        if has(["bakery", "bageri"]) { return .bakery }
        if has(["parking", "parkering", "garage"]) { return .parking }
        if has(["atm", "bankomat", "uttagsautomat", "cash machine"]) { return .atm }
        if has(["bank"]) { return .bank }
        if has(["hotel", "hotell", "motel"]) { return .hotel }
        if has(["airport", "flygplats"]) { return .airport }
        if has(["police", "polis"]) { return .police }
        if has(["supermarket", "grocery", "mataffär", "livsmedel", "ica", "coop"]) { return .foodMarket }
        if has(["hospital", "clinic", "vårdcentral"]) { return .hospital }
        return nil
    }

    // MARK: - Geocoding

    func geocode(address: String) async throws -> [Place] {
        // Prefer MKLocalSearch (no documented throttle) for address → place.
        let viaSearch = try? await search(query: address, near: nil, limit: 5)
        if let viaSearch, !viaSearch.isEmpty { return viaSearch }
        // Fall back to CLGeocoder (rate-limited; single call).
        let placemarks = try await CLGeocoder().geocodeAddressString(address)
        return placemarks.compactMap(Self.place(from:))
    }

    func reverseGeocode(_ coordinate: Coordinate) async throws -> Place? {
        let location = CLLocation(latitude: coordinate.lat, longitude: coordinate.lon)
        let placemarks = try await CLGeocoder().reverseGeocodeLocation(location)
        return placemarks.first.flatMap(Self.place(from:))
    }

    // MARK: - Directions

    @MainActor
    func directions(from: Coordinate, to: Coordinate, transport: String) async throws -> RouteInfo {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: from.lat, longitude: from.lon)))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: to.lat, longitude: to.lon)))
        request.transportType = Self.transportType(transport)
        let response = try await MKDirections(request: request).calculate()
        guard let route = response.routes.first else {
            return RouteInfo(distanceMeters: 0, travelTimeSeconds: 0, transport: transport, steps: [], polyline: [])
        }
        let steps = route.steps.map(\.instructions).filter { !$0.isEmpty }
        let polyline = Self.coordinates(of: route.polyline)
        return RouteInfo(
            distanceMeters: route.distance,
            travelTimeSeconds: route.expectedTravelTime,
            transport: transport,
            steps: steps,
            polyline: polyline
        )
    }

    // MARK: - Mapping

    private static func place(from item: MKMapItem) -> Place {
        let pm = item.placemark
        return Place(
            name: item.name ?? pm.name ?? "(unnamed)",
            address: formatted(pm),
            latitude: pm.coordinate.latitude,
            longitude: pm.coordinate.longitude,
            phone: item.phoneNumber,
            url: item.url?.absoluteString,
            category: item.pointOfInterestCategory?.rawValue
        )
    }

    private static func place(from placemark: CLPlacemark) -> Place? {
        guard let coord = placemark.location?.coordinate else { return nil }
        return Place(
            name: placemark.name ?? placemark.locality ?? "(unnamed)",
            address: formatted(placemark),
            latitude: coord.latitude,
            longitude: coord.longitude
        )
    }

    private static func formatted(_ placemark: CLPlacemark) -> String? {
        let parts = [
            placemark.subThoroughfare, placemark.thoroughfare,
            placemark.locality, placemark.administrativeArea,
            placemark.postalCode, placemark.country
        ].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private static func transportType(_ s: String) -> MKDirectionsTransportType {
        switch s.lowercased() {
        case "walking": return .walking
        case "transit": return .transit
        default: return .automobile
        }
    }

    private static func coordinates(of polyline: MKPolyline) -> [Coordinate] {
        let count = polyline.pointCount
        guard count > 0 else { return [] }
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: count)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: count))
        return coords.map { Coordinate(lat: $0.latitude, lon: $0.longitude) }
    }

    private static func map(_ status: CLAuthorizationStatus) -> MapAuth {
        switch status {
        // macOS uses .authorized / .authorizedAlways (no .authorizedWhenInUse).
        case .authorized, .authorizedAlways: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .unavailable
        }
    }
#else
    func locationAuthorization() async -> MapAuth { .unavailable }
    func requestLocationAccess() async -> MapAuth { .unavailable }
    func currentLocation() async -> Coordinate? { nil }
    func search(query: String, near: Coordinate?, limit: Int) async throws -> [Place] { [] }
    func geocode(address: String) async throws -> [Place] { [] }
    func reverseGeocode(_ coordinate: Coordinate) async throws -> Place? { nil }
    func directions(from: Coordinate, to: Coordinate, transport: String) async throws -> RouteInfo {
        RouteInfo(distanceMeters: 0, travelTimeSeconds: 0, transport: transport, steps: [], polyline: [])
    }
#endif
}

#if canImport(MapKit)
/// Main-actor delegate object that owns a `CLLocationManager` and bridges its
/// callbacks to async/await. Retained for the app's lifetime (via the static on
/// `MKMapProvider`) so the manager survives the async authorization prompt.
///
/// Correct macOS one-shot flow (the previous polling version never worked):
/// delegate set in `init` → request authorization only when `.notDetermined`,
/// awaiting `locationManagerDidChangeAuthorization` → then `requestLocation()`
/// and read the fix from `didUpdateLocations` (NOT `manager.location`, which is
/// nil until a fix is actually delivered).
@MainActor
final class LocationOneShot: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var authConts: [CheckedContinuation<CLAuthorizationStatus, Never>] = []
    private var locConts: [CheckedContinuation<Coordinate?, Never>] = []

    override init() {
        super.init()
        manager.delegate = self          // delegate BEFORE any request
        manager.desiredAccuracy = kCLLocationAccuracyKilometer   // "where am I" / bias don't need pinpoint
    }

    var status: CLAuthorizationStatus { manager.authorizationStatus }

    /// Present the prompt when undecided; resolve once the status is settled.
    func requestAuthorization() async -> CLAuthorizationStatus {
        let current = manager.authorizationStatus
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { cont in
            authConts.append(cont)
            manager.requestWhenInUseAuthorization()
        }
    }

    /// One-shot current location, prompting for access first if needed. Returns
    /// nil if denied/restricted or no fix arrives within the timeout (so a stalled
    /// fix can't hang the tool-call past its 60s budget).
    func currentLocation() async -> Coordinate? {
        var s = manager.authorizationStatus
        if s == .notDetermined { s = await requestAuthorization() }
        guard s == .authorized || s == .authorizedAlways else {
            FileHandle.standardError.write(Data("[FyxLocal][maps] location not authorized (status=\(s.rawValue))\n".utf8))
            return nil
        }

        // A cached fix is good enough for region biasing / "where am I"; use it
        // immediately and avoid waiting on a fresh fix that may never arrive.
        if let cached = manager.location, cached.timestamp.timeIntervalSinceNow > -300 {
            return Coordinate(lat: cached.coordinate.latitude, lon: cached.coordinate.longitude)
        }

        // Otherwise request a fresh one-shot fix, but race it against a timeout.
        return await withTaskGroup(of: Coordinate?.self) { group in
            group.addTask { await self.requestOneShot() }
            group.addTask {
                try? await Task.sleep(nanoseconds: 8 * 1_000_000_000)   // 8s ceiling
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// The actual `requestLocation()` round-trip, resumed by the delegate.
    private func requestOneShot() async -> Coordinate? {
        await withCheckedContinuation { cont in
            locConts.append(cont)
            manager.requestLocation()
        }
    }

    // MARK: CLLocationManagerDelegate
    // The delegate requirements are `nonisolated`, but Core Location dispatches
    // callbacks on the run loop where the manager was created — the main thread,
    // since this object is @MainActor. So we hop back via assumeIsolated.

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // Read the status off `manager` here (not inside the closure) so the
        // non-Sendable manager itself isn't captured across the actor hop.
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            // Fires immediately on init too; only resume if we're awaiting a
            // decision and the status is no longer indeterminate.
            guard status != .notDetermined, !authConts.isEmpty else { return }
            let conts = authConts; authConts = []
            conts.forEach { $0.resume(returning: status) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let coord = locations.last.map { Coordinate(lat: $0.coordinate.latitude, lon: $0.coordinate.longitude) }
        MainActor.assumeIsolated {
            let conts = locConts; locConts = []
            conts.forEach { $0.resume(returning: coord) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            let conts = locConts; locConts = []
            conts.forEach { $0.resume(returning: nil) }
        }
    }
}
#endif
