import CoreLocation
import Foundation
import UserNotifications

/// The permissions step after sign-in (contract/permissions-onboarding-2026-10-28.md): why notifications and location
/// help, then the system prompts only when the player taps Turn on. Skipped, it never comes back on its own.
enum PermissionState: Equatable { case unasked, on, off }

enum PermissionsStep {
    static let seenKey = "onboarding.permissions.seen"

    /// Once per device, and only while there's something left to ask.
    static func shouldShow(seen: Bool, notifications: PermissionState, location: PermissionState) -> Bool {
        !seen && (notifications == .unasked || location == .unasked)
    }

    static var seen: Bool {
        get { UserDefaults.standard.bool(forKey: seenKey) }
        set { UserDefaults.standard.set(newValue, forKey: seenKey) }
    }

    /// Nil when the system doesn't answer within 2 s (seen on simulators, where it never does), so the step can't hold
    /// sign-in on the loading screen.
    static func notifications() async -> PermissionState? {
        await withCheckedContinuation { (continuation: CheckedContinuation<PermissionState?, Never>) in
            let first = FirstAnswer(continuation)
            Task {
                switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
                case .notDetermined: first.resume(.unasked)
                case .denied: first.resume(.off)
                default: first.resume(.on)
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(2))
                first.resume(nil)
            }
        }
    }

    @MainActor static func location() async -> PermissionState {
        switch await LocationFix.shared.status() {
        case .notDetermined: .unasked
        case .denied, .restricted: .off
        default: .on
        }
    }

    /// Debug: `-T1Permissions` shows the step, signed in or not, whatever was answered before.
    static let demo: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-T1Permissions")
        #else
        false
        #endif
    }()

    static func needed() async -> Bool {
        if demo { return true }
        // No answer counts as nothing to ask.
        return shouldShow(seen: seen, notifications: await notifications() ?? .on, location: await location())
    }
}

/// Resumes its continuation once, with whichever answer comes first.
private final class FirstAnswer<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    init(_ continuation: CheckedContinuation<T, Never>) { self.continuation = continuation }

    func resume(_ value: T) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}
