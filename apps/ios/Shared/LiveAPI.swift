import Foundation
import Supabase

/// The three calls the Live Activity and widgets make. Each is a single small request.
enum LiveAPI {
    private struct StateResponse: Decodable { let snapshots: [LiveSnapshot] }

    /// Every live seat for the signed-in player, with rank, opponent and clock (one request).
    static func fetch() async throws -> [LiveSnapshot] {
        try await T1Shared.client.functions.invoke(
            "live-activity",
            options: FunctionInvokeOptions(body: ["action": "state"])
        ) { data, _ in try JSONDecoder().decode(StateResponse.self, from: data).snapshots }
    }

    /// Reports a result from this player's side. Same RPC, version check and idempotency as the app.
    static func report(matchId: String, mySide: Int, my: Int, their: Int, draws: Int = 0, version: Int?) async throws {
        var params: [String: AnyJSON] = [
            "p_match_id": .string(matchId),
            "p_side0_wins": .integer(mySide == 0 ? my : their),
            "p_side1_wins": .integer(mySide == 0 ? their : my),
            "p_draws": .integer(draws),
            "p_idempotency_key": .string(UUID().uuidString.lowercased()),
        ]
        if let version { params["p_expected_version"] = .integer(version) }
        try await T1Shared.client.rpc("report_match", params: params).execute()
    }

    static func respond(matchId: String, accept: Bool) async throws {
        try await T1Shared.client.rpc("respond_to_result", params: [
            "p_match_id": AnyJSON.string(matchId), "p_accept": .bool(accept),
        ]).execute()
    }

    /// Runs `work`, giving up after `seconds` (widget timelines must return promptly).
    static func withTimeout<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw CancellationError()
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }
}
