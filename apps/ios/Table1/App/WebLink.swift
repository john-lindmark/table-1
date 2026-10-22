import SafariServices
import SwiftUI

/// A tapped https://table-1.site link, as the app opens it (contract/universal-links-2026-10-22.md).
/// Every web address with a screen here opens that screen; the rest stay on the web. Shared cases:
/// testdata/universal-links/cases.json.
enum WebLink: Equatable {
    case signIn // the sign-in email's button; SignIn.handleEmailLink reads the url itself
    case joinQr(JoinLink)
    case joinCode(String)
    /// The event if you organize or play in it, else the public standings page on the web.
    case standings(String)
    case events([Route])
    case collection([LibraryRoute])
    case account([LibraryRoute])
    case tracker(String?)
    /// table-1.site, but no screen in the app (privacy policy, account deletion, a web sign-in's return): the browser.
    case web

    static let hosts: Set<String> = ["table-1.site", "www.table-1.site"]

    static func standingsURL(_ eventId: String) -> URL { URL(string: "https://table-1.site/s/\(eventId)")! }

    /// nil when the url isn't a table-1.site link at all.
    static func parse(_ url: URL) -> WebLink? {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.scheme == "https",
              let host = c.host?.lowercased(), hosts.contains(host) else { return nil }
        // A web sign-in (Apple/Google) coming back to the page that asked: that session belongs to the browser.
        let fragment = c.fragment ?? ""
        if fragment.contains("access_token=") || fragment.contains("error_description=") { return .web }
        if c.queryItems?.contains(where: { $0.name == "code" && !($0.value ?? "").isEmpty }) == true { return .web }

        let p = c.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        switch p.first {
        case nil, "sign-in" where p.count == 1: return .events([])
        case "e" where p.count == 2: return .events([.event(p[1])])
        case "e" where p.count == 3 && p[2] == "add": return .events([.event(p[1]), .addPlayers(p[1])])
        case "p" where p.count == 2: return .events([.event(p[1])])
        case "s" where p.count == 2: return .standings(p[1])
        case "join" where p.count == 2: return .joinCode(p[1])
        case "j": return JoinLink(url.absoluteString).map { .joinQr($0) } ?? .web
        case "auth" where p == ["auth", "confirm"]: return .signIn
        case "life" where p.count <= 2: return .tracker(p.count == 2 ? p[1] : nil)
        case "library": return library(Array(p.dropFirst())).map { .collection($0) } ?? .web
        case "me" where p.count == 1: return .account([])
        case "friends" where p.count == 1 || p == ["friends", "add"]: return .account([.social(.friends)])
        case "sharing" where p.count == 1: return .account([.social(.sharing)])
        // A profile's section opens the profile: the section's title and deck come from the profile itself.
        case "u" where (2...4).contains(p.count): return .account([.social(.profile(p[1]))])
        default: return .web
        }
    }

    private static let jobs: Set<String> = ["W", "U", "B", "R", "G", "M", "C", "L", "F"]

    /// The Collection stack under /library, parents first so Back lands where it would on the web.
    private static func library(_ p: [String]) -> [LibraryRoute]? {
        switch p.first {
        case nil: return []
        case "cards" where p.count == 1: return [.allCards]
        case "add" where p.count == 1: return [.add]
        case "card" where p.count == 2: return [.card(p[1])]
        case "decks" where p.count == 1: return [.lists(.deck)]
        case "cubes" where p.count == 1: return [.lists(.cube)]
        case "find" where p.count == 1: return [.lists(.deck), .findDeck]
        case "import" where p.count == 1: return [.collectionImport]
        case "import" where p.count == 2:
            let kind: CardList.Kind = p[1] == "cube" ? .cube : .deck
            return [.lists(kind), .importList(kind)]
        case "list" where p.count >= 2: return list(p[1], Array(p.dropFirst(2)))
        case "rankings" where p.count == 1: return [.lists(.cube), .rankings(nil)]
        case "ranking" where p.count >= 2: return ranking(p[1], Array(p.dropFirst(2))).map { [.ranking(p[1])] + $0 }
        case "trades" where p.count == 1: return [.trades]
        case "trade" where p.count == 2: return [.trades, .trade(p[1] == "new" ? nil : p[1])]
        case "binders" where p.count == 1: return [.binders]
        case "binder" where p.count == 2: return [.binders, .binder(p[1])]
        case "wants" where p.count == 1: return [.wants]
        case "matches" where p.count == 1: return [.social(.matches)]
        case "match" where p.count == 2: return [.social(.matches), .social(.match(p[1]))]
        default: return nil
        }
    }

    private static func list(_ id: String, _ rest: [String]) -> [LibraryRoute]? {
        let top: [LibraryRoute] = [.list(id)]
        switch rest {
        case []: return top
        case ["add"]: return top + [.listAdd(id)]
        // Change printing needs the line, which only the deck screen knows.
        case ["printing"]: return top
        case ["stats"]: return top + [.listStats(id)]
        case ["stats", "hand"]: return top + [.listStats(id), .sampleHand(id)]
        case ["stats", "odds"]: return top + [.listStats(id), .drawOdds(id)]
        case ["stats", "pack"]: return top + [.listStats(id), .samplePack(id)]
        case ["versions"]: return top + [.versions(id)]
        case ["rankings"]: return top + [.rankings(id)]
        default:
            if rest.count == 2, rest[0] == "v", let n = Int(rest[1]) { return top + [.versions(id), .version(id, n)] }
            return nil
        }
    }

    /// The screens above a ranking's overview.
    private static func ranking(_ id: String, _ rest: [String]) -> [LibraryRoute]? {
        switch rest.first {
        case nil: return []
        case "pack" where rest.count == 1: return [.rankingPack(id)]
        case "changes" where rest.count == 1: return [.rankingChanges(id)]
        case "screen" where rest.count == 2 && jobs.contains(rest[1]): return [.rankingPick(id, rest[1])]
        case "lists" where rest.count == 2 && jobs.contains(rest[1]): return [.rankingLists(id, rest[1])]
        case "card" where rest.count == 3 && jobs.contains(rest[2]): return [.rankingCard(id, rest[1], rest[2])]
        case "compare" where rest.count == 3 && jobs.contains(rest[2]): return [.rankingCompare(id, rest[1], rest[2])]
        default: return nil
        }
    }

    /// Telemetry's `to` (never an id).
    var kind: String {
        switch self {
        case .signIn: "sign_in"
        case .joinQr: "join_qr"
        case .joinCode: "join_code"
        case .standings: "standings"
        case .events(let s): s.isEmpty ? "events" : "event"
        case .collection: "collection"
        case .account: "account"
        case .tracker: "tracker"
        case .web: "web"
        }
    }
}

/// A table-1.site page with no screen in the app.
struct WebPage: Identifiable {
    let id = UUID()
    let url: URL
}

/// The page in an in-app browser: it never hands its own address back to the app, so a link the app can't show
/// can't bounce between the two.
struct WebPageView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let vc = SFSafariViewController(url: url)
        vc.preferredBarTintColor = UIColor(T1.bg)
        vc.preferredControlTintColor = UIColor(T1.accent)
        vc.dismissButtonStyle = .done
        return vc
    }

    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}
