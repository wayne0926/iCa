import Foundation
import CoreLocation

enum Secrets {
    static let googleMaps = value("GoogleMapsAPIKey")
    static let meteoblue = value("MeteoblueAPIKey")

    private static func value(_ key: String) -> String? {
        guard let v = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !v.isEmpty, !v.hasPrefix("$(") else { return nil }
        return v
    }
}

/// Small JSON file cache in Caches/, so a cold start draws weather and routes
/// before the network answers.
actor DiskCache {
    static let shared = DiskCache()

    private struct Entry<T: Codable>: Codable {
        let saved: Date
        let value: T
    }

    private let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tageslicht", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    func read<T: Codable>(_ type: T.Type, key: String, maxAge: TimeInterval) -> (T, Date)? {
        readNow(type, key: key, maxAge: maxAge)
    }

    /// Reads need no isolation: files are replaced atomically.
    nonisolated func readNow<T: Codable>(_ type: T.Type, key: String, maxAge: TimeInterval) -> (T, Date)? {
        let url = dir.appendingPathComponent(Self.fileName(key))
        guard let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(Entry<T>.self, from: data),
              Date().timeIntervalSince(entry.saved) < maxAge else { return nil }
        return (entry.value, entry.saved)
    }

    func write<T: Codable>(_ value: T, key: String) {
        let url = dir.appendingPathComponent(Self.fileName(key))
        if let data = try? JSONEncoder().encode(Entry(saved: Date(), value: value)) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func fileName(_ key: String) -> String {
        // Stable, filesystem-safe name.
        var h: UInt64 = 1469598103934665603
        for b in key.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return String(h, radix: 16) + ".json"
    }
}

/// One-shot "where am I" with a Bonn fallback, so nothing waits on GPS forever.
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var waiters: [CheckedContinuation<Coordinate?, Never>] = []
    private(set) var last: Coordinate?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func current() async -> Coordinate? {
        if let last { return last }
        switch manager.authorizationStatus {
        case .denied, .restricted: return nil
        case .notDetermined: manager.requestWhenInUseAuthorization()
        default: manager.requestLocation()
        }
        return await withCheckedContinuation { c in
            waiters.append(c)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(8))
                self.resume(with: self.last)
            }
        }
    }

    private func resume(with c: Coordinate?) {
        let w = waiters
        waiters.removeAll()
        w.forEach { $0.resume(returning: c) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways: manager.requestLocation()
            case .denied, .restricted: self.resume(with: nil)
            default: break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        let c = Coordinate(lat: l.coordinate.latitude, lon: l.coordinate.longitude)
        Task { @MainActor in
            self.last = c
            self.resume(with: c)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.resume(with: self.last) }
    }
}
