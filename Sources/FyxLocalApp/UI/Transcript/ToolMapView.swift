// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import SwiftUI
import FyxLocalTools
#if canImport(MapKit)
import MapKit
#endif

/// Renders the output of the `maps` tool as an interactive map inline in the
/// transcript. The tool (FyxLocalTools) emits a `MapSpec` (center/span/pins/route)
/// wrapped in its result payload; rendering lives here because MapKit is a UI
/// dependency — mirroring how `ToolChartView` owns Swift Charts.
///
/// Lenient like `ToolChartView`: if the JSON has no decodable `map` spec we fall
/// back to pretty JSON so the chat keeps working and the model gets the payload
/// back unchanged.
struct ToolMapView: View {
    let json: String

    /// The tool payload wraps the spec under `map` (search/directions/geocode all
    /// share this). Decode just that field.
    private struct Wrapper: Decodable { let map: MapSpec }

    private var spec: MapSpec? {
        guard let data = json.data(using: .utf8) else { return nil }
        if let w = try? JSONDecoder().decode(Wrapper.self, from: data) { return w.map }
        // Also accept a bare MapSpec (defensive).
        return try? JSONDecoder().decode(MapSpec.self, from: data)
    }

    var body: some View {
        if let spec {
            content(spec)
        } else {
            fallback
        }
    }

#if canImport(MapKit)
    @ViewBuilder
    private func content(_ spec: MapSpec) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Map(initialPosition: .region(region(spec))) {
                ForEach(Array(spec.pins.enumerated()), id: \.offset) { _, pin in
                    Marker(pin.title, coordinate: CLLocationCoordinate2D(latitude: pin.lat, longitude: pin.lon))
                }
                if spec.route.count > 1 {
                    MapPolyline(coordinates: spec.route.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) })
                        .stroke(.blue, lineWidth: 4)
                }
            }
            .mapControls {
                MapCompass()
                MapScaleView()
            }
            // A single, unambiguous frame. Chaining `.frame(maxWidth:)` then
            // `.frame(height:)` produced conflicting Auto Layout constraints on
            // the underlying NSHostingView that crashed during the display
            // commit (NSWindow _postWindowNeedsUpdateConstraints) once the map
            // rendered eagerly (auto-expanded). One frame, fixed height +
            // flexible width, resolves cleanly.
            .frame(maxWidth: 480, minHeight: 300, maxHeight: 300)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.smallRadius))

            if !spec.summary.isEmpty {
                Text(spec.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func region(_ spec: MapSpec) -> MKCoordinateRegion {
        // Sanitize the span: a zero/NaN/over-range delta (e.g. a degenerate
        // single-point route) yields an invalid region that can crash Map's
        // layout. Clamp to a sane window.
        func clampSpan(_ v: Double) -> Double {
            guard v.isFinite, v > 0 else { return 0.05 }
            return min(max(v, 0.002), 120)
        }
        func clampLat(_ v: Double) -> Double { v.isFinite ? min(max(v, -90), 90) : 0 }
        func clampLon(_ v: Double) -> Double { v.isFinite ? min(max(v, -180), 180) : 0 }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: clampLat(spec.centerLat), longitude: clampLon(spec.centerLon)),
            span: MKCoordinateSpan(latitudeDelta: clampSpan(spec.spanLat), longitudeDelta: clampSpan(spec.spanLon))
        )
    }
#else
    @ViewBuilder
    private func content(_ spec: MapSpec) -> some View {
        Text(spec.summary).font(.caption).foregroundStyle(.secondary)
    }
#endif

    private var fallback: some View {
        Text(json)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
    }
}
