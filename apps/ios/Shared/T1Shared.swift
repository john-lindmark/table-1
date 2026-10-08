import Foundation
import Supabase

/// Settings and the Supabase client shared by the app and the widget extension.
/// The session lives in a shared Keychain access group so the widget, the Live Activity buttons and the
/// app all act as the same signed-in player.
enum T1Shared {
    static let appGroup = "group.site.table1.events"
    static let keychainGroup = "94889YTX94.site.table1.shared"
    static let supabaseURL = URL(string: "https://aaozhfcbvqrgkkrihkrd.supabase.co")!
    // Public by design; Row Level Security does the gating.
    static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFhb3poZmNidnFyZ2trcmloa3JkIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjQwMDE5MTUsImV4cCI6MjA3OTU3NzkxNX0.7TyCLK4NZsiKXbLU504T3CxLdnHrp95FVKgpnKEMrKI"

    static let isExtension = Bundle.main.bundlePath.hasSuffix(".appex")

    /// Server JSON is snake_case; Swift models are camelCase.
    static let snakeDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    /// One client per process. The extension never runs a background refresh timer; it refreshes
    /// on demand, so a widget reload costs one request and no idle work.
    static let client = SupabaseClient(
        supabaseURL: supabaseURL,
        supabaseKey: anonKey,
        options: SupabaseClientOptions(
            db: .init(decoder: snakeDecoder),
            auth: .init(storage: SharedAuthStorage(), automaticallyRefreshesToken: !isExtension)
        )
    )
}

/// Keychain storage in the shared access group. Sessions saved by earlier builds (app-only group)
/// are copied over on first read, so existing players stay signed in.
struct SharedAuthStorage: AuthLocalStorage {
    private let shared = KeychainLocalStorage(accessGroup: T1Shared.keychainGroup)
    private let legacy = KeychainLocalStorage()

    func store(key: String, value: Data) throws { try shared.store(key: key, value: value) }

    func retrieve(key: String) throws -> Data? {
        if let value = try shared.retrieve(key: key) { return value }
        guard !T1Shared.isExtension, let old = try? legacy.retrieve(key: key) else { return nil }
        try? shared.store(key: key, value: old)
        return old
    }

    func remove(key: String) throws {
        try shared.remove(key: key)
        try? legacy.remove(key: key)
    }
}
