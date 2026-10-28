import CoreLocation

struct Fix { let lat: Double; let lng: Double; let accuracyM: Int }

/// One foreground fix, when-in-use only. Never runs in the background.
@MainActor
final class LocationFix: NSObject, CLLocationManagerDelegate {
    static let shared = LocationFix()
    private let manager = CLLocationManager()
    private var waiting: [CheckedContinuation<Fix?, Never>] = []
    private var asking: [CheckedContinuation<Bool, Never>] = []

    /// A new manager says notDetermined until its first callback, so the real status waits for that.
    private var statusKnown = false
    private var knowing: [CheckedContinuation<Void, Never>] = []

    func status() async -> CLAuthorizationStatus {
        if !statusKnown { await withCheckedContinuation { knowing.append($0) } }
        return manager.authorizationStatus
    }

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

    /// A fix only when location is already allowed: never shows the system prompt (the Events home's presence).
    func currentIfAllowed() async -> Fix? {
        guard [.authorizedWhenInUse, .authorizedAlways].contains(await status()) else { return nil }
        return await current()
    }

    /// The system prompt (permissions step); true once allowed.
    func ask() async -> Bool {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: return true
        case .notDetermined: break
        default: return false
        }
        return await withCheckedContinuation { continuation in
            asking.append(continuation)
            manager.requestWhenInUseAuthorization()
        }
    }

    private func answered(_ allowed: Bool) {
        let pending = asking
        asking.removeAll()
        pending.forEach { $0.resume(returning: allowed) }
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
            if !self.statusKnown {
                self.statusKnown = true
                self.knowing.forEach { $0.resume() }
                self.knowing.removeAll()
            }
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                self.answered(true)
                if !self.waiting.isEmpty { manager.requestLocation() }
            case .denied, .restricted:
                self.answered(false)
                self.finish(nil)
            default: break
            }
        }
    }
}
