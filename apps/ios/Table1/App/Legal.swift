import Foundation

/// What Account → About says: the Wizards Fan Content Policy notice (required for using Magic names and card
/// images), the privacy policy and the version (same words on web and Android).
enum Legal {
    static let fanContent = "Table 1 is unofficial Fan Content permitted under the Fan Content Policy. Not approved/endorsed by Wizards. Portions of the materials used are property of Wizards of the Coast. ©Wizards of the Coast LLC."
    static let termsURL = URL(string: "https://table-1.site/terms")!
    static let privacyURL = URL(string: "https://table-1.site/privacy")!

    static var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }
}
