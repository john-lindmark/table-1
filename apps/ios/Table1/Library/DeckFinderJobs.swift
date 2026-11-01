import Foundation
import Supabase

/* Deck finder jobs (contract/deck-finder-2026-10-15.md § Jobs): a search runs on the server as a job, so the
   phone can be locked; the screen polls the job and a `deck.found` push brings the player back to it. Rules
   shared with web and Android in testdata/deck-finder/cases.json (DeckFinderTests). */

/// One search job as `deck_finder_job` returns it.
struct DeckFinderJob: Decodable {
    struct Answer: Codable, Equatable { let question: String; let answer: String }
    let jobId: String
    let status: String
    let query: String
    let format: String?
    let answers: [Answer]
    let result: DeckFinderResult?
    let createdAt: Date
    let finishedAt: Date?

    var finished: Bool { status == "done" || status == "failed" }
}

enum DeckFinderJobs {
    /// How often the screen asks after a running job.
    static let pollSeconds: UInt64 = 3

    /// Whether Find a deck, opened with no job of its own, shows the account's newest job: a search still running
    /// is picked up, and one that finished in the last hour (a locked phone's search) is shown.
    static func resume(status: String, finishedSecondsAgo: Double?) -> Bool {
        if status == "queued" || status == "running" { return true }
        guard let ago = finishedSecondsAgo else { return false }
        return ago < 3600
    }

    static func resume(_ job: DeckFinderJob, now: Date = Date()) -> Bool {
        resume(status: job.status, finishedSecondsAgo: job.finishedAt.map { now.timeIntervalSince($0) })
    }

    /// The line under a found deck's name: placement · event · date, whichever are known.
    static func headline(placement: String, event: String, date: String) -> String {
        [placement, event, date].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            if let date = ISO8601DateFormatter.withFractions.date(from: s) ?? ISO8601DateFormatter.plain.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a date: \(s)"))
        }
        return d
    }()

    private struct Started: Decodable { let jobId: String; let status: String }

    /// Starts a search; the job id to poll. Throws with the server's words when refused (the day's allowance).
    static func start(query: String, format: String, answers: [DeckFinderJob.Answer]) async throws -> String {
        let data = try await supabase.rpc("deck_finder_start", params: [
            "p_query": AnyJSON.string(query), "p_format": .string(format),
            "p_answers": .array(answers.map { .object(["question": .string($0.question), "answer": .string($0.answer)]) }),
        ]).execute().data
        return try decoder.decode(Started.self, from: data).jobId
    }

    /// One of your jobs, or with no id the newest of the last 24 hours; nil when there is none.
    static func job(id: String?) async throws -> DeckFinderJob? {
        let data = try await supabase.rpc("deck_finder_job", params: ["p_id": id.map { AnyJSON.string($0) } ?? .null]).execute().data
        if data.isEmpty || data == Data("null".utf8) { return nil }
        return try decoder.decode(DeckFinderJob.self, from: data)
    }

    /// What a refused start says: the server's own message (allowance, sign-in), else the error.
    static func words(_ error: Error) -> String {
        if let e = error as? PostgrestError { return e.message }
        return error.localizedDescription
    }
}

private extension ISO8601DateFormatter {
    static let withFractions: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let plain = ISO8601DateFormatter()
}
