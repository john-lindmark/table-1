import Foundation
import Supabase

/// Backend settings come from Info.plist (set in project.yml) so nothing secret lives in code.
/// The anon key is public by design; Row Level Security does the gating.
enum Config {
    static let supabaseURL = URL(string: Bundle.main.object(forInfoDictionaryKey: "T1SupabaseURL") as? String ?? "")!
    static let supabaseKey = Bundle.main.object(forInfoDictionaryKey: "T1SupabaseAnonKey") as? String ?? ""
}

/// Server JSON is snake_case; Swift models are camelCase.
let wireDecoder: JSONDecoder = T1Shared.snakeDecoder

/// One client for the whole app; the session lives in the Keychain and restores silently.
/// The same client the widget extension uses; the session is in the shared Keychain group.
let supabase = T1Shared.client
