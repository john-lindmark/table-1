import AppIntents
import Foundation

/// Reports a result from the Live Activity or a widget. Runs in the app's process (LiveActivityIntent),
/// updates every surface instantly, then settles on the server's answer.
struct ReportResultIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Report match result"
    static var description = IntentDescription("Reports your result for your current Table 1 match.")
    static var isDiscoverable = false
    /// Unlock first: nobody else can report your result from your Lock Screen.
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Seat") var participantId: String
    @Parameter(title: "Match") var matchId: String
    @Parameter(title: "Side") var mySide: Int
    @Parameter(title: "My wins") var myWins: Int
    @Parameter(title: "Their wins") var theirWins: Int
    @Parameter(title: "Version") var version: Int

    init() {}

    init(participantId: String, state: LiveState, outcome: MatchOutcome) {
        self.participantId = participantId
        self.matchId = state.matchId ?? ""
        self.mySide = state.mySide ?? 0
        self.myWins = outcome.wins.my
        self.theirWins = outcome.wins.their
        self.version = state.matchVersion ?? -1
    }

    func perform() async throws -> some IntentResult {
        guard !matchId.isEmpty else { return .result() }
        let (my, their) = (myWins, theirWins)
        let before = await LiveSync.apply(participantId: participantId) { s in
            s.status = "reported_me"; s.myWins = my; s.theirWins = their; s.draws = 0
        }
        do {
            try await LiveAPI.report(matchId: matchId, mySide: mySide, my: my, their: their,
                                     version: version >= 0 ? version : nil)
        } catch {
            if let before { await LiveSync.restore(participantId: participantId, to: before) }
            throw error
        }
        await LiveSync.refreshFromServer()
        return .result()
    }
}

/// Confirms or disputes the opponent's report from the Live Activity or a widget.
struct RespondResultIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Confirm or dispute result"
    static var isDiscoverable = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Seat") var participantId: String
    @Parameter(title: "Match") var matchId: String
    @Parameter(title: "Accept") var accept: Bool

    init() {}

    init(participantId: String, matchId: String, accept: Bool) {
        self.participantId = participantId
        self.matchId = matchId
        self.accept = accept
    }

    func perform() async throws -> some IntentResult {
        let accepted = accept
        let before = await LiveSync.apply(participantId: participantId) { s in
            s.status = accepted ? "confirmed" : "disputed"
        }
        do {
            try await LiveAPI.respond(matchId: matchId, accept: accepted)
        } catch {
            if let before { await LiveSync.restore(participantId: participantId, to: before) }
            throw error
        }
        await LiveSync.refreshFromServer()
        return .result()
    }
}
