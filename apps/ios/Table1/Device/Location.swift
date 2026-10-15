import CoreLocation

struct Fix { let lat: Double; let lng: Double; let accuracyM: Int }

/// One foreground fix, when-in-use only. Never runs in the background.
@MainActor
final class LocationFix: NSObject, CLLocationManagerDelegate {
    static let shared = LocationFix()
    private let manager = CLLocationManager()
    private var waiting: [CheckedContinuation<Fix?, Never>] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    func current() async -> Fix? {
        switch manager.authorizationStatus {
        case .denied, .restricted: return nil
        case .notDetermined: manager.requestWhenInUseAuthorization()
        default: break
        }
        return await withCheckedContinuation { continuation in
            waiting.append(continuation)
            manager.requestLocation()
        }
    }

    private func finish(_ fix: Fix?) {
        let pending = waiting
        waiting.removeAll()
        pending.forEach { $0.resume(returning: fix) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        let fix = Fix(lat: l.coordinate.latitude, lng: l.coordinate.longitude, accuracyM: max(5, Int(l.horizontalAccuracy)))
        Task { @MainActor in self.finish(fix) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(nil) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                if !self.waiting.isEmpty { manager.requestLocation() }
            case .denied, .restricted:
                self.finish(nil)
            default: break
            }
        }
    }
}
