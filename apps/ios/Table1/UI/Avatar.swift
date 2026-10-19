import Supabase
import SwiftUI
import UIKit

// Avatars (contract/avatars-2026-10-16.md): initials on a muted tile picked from the account id, or the
// player's photo from the public `avatars` bucket. Same rules on every platform.

enum AvatarStyle {
    /// Muted tints near the surface's lightness: a quiet tile, never mistaken for the teal accent.
    static let palette: [Color] = [0x4A3F6B, 0x5B3E5A, 0x63414A, 0x5E4A38, 0x4D5236, 0x36524A, 0x3A4C66, 0x4B4B5E].map {
        Color(red: Double($0 >> 16 & 0xFF) / 255, green: Double($0 >> 8 & 0xFF) / 255, blue: Double($0 & 0xFF) / 255)
    }

    /// First letter of the first and last word; one word gives one letter.
    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: \.isWhitespace).compactMap { $0.first(where: { $0.isLetter || $0.isNumber }) }
        guard let first = words.first else { return "?" }
        return (words.count > 1 ? String(first) + String(words.last!) : String(first)).uppercased()
    }

    /// The account id when there is one, so a player looks the same everywhere; a guest's name otherwise.
    static func seed(userId: String?, name: String) -> String {
        userId?.lowercased() ?? name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// FNV-1a 32-bit over the seed's UTF-8 bytes.
    static func colorIndex(_ seed: String) -> Int {
        var h: UInt32 = 2_166_136_261
        for b in seed.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
        return Int(h % UInt32(palette.count))
    }
}

/// Which accounts have photos, read from `profiles` in batches for the ids on screen and kept for the session.
@MainActor @Observable
final class AvatarStore {
    static let shared = AvatarStore()

    /// user id → bucket path; a nil value means "no photo" (asked already).
    private(set) var paths: [String: String?] = [:]
    @ObservationIgnored private var pending: Set<String> = []
    @ObservationIgnored private var flushing = false

    func path(_ userId: String) -> String? { paths[userId] ?? nil }

    static func url(_ path: String) -> URL {
        Config.supabaseURL.appending(path: "storage/v1/object/public/avatars").appending(path: path)
    }

    func want(_ userId: String) {
        guard paths[userId] == nil, !pending.contains(userId) else { return }
        pending.insert(userId)
        guard !flushing else { return }
        flushing = true
        Task { @MainActor in
            // Let the rest of the list ask first, then one query.
            try? await Task.sleep(for: .milliseconds(30))
            await flush()
        }
    }

    private func flush() async {
        defer { flushing = false }
        while !pending.isEmpty {
            let ids = Array(pending.prefix(100))
            // people() returns only accounts you have a reason to see (contract/privacy-lockdown-2026-10-18.md);
            // anyone else, or across a block, comes back missing and draws initials.
            struct Row: Decodable { let userId: String; let avatarUrl: String? }
            let rows: [Row]? = try? await supabase.rpc("people", params: ["p_ids": AnyJSON.array(ids.map { .string($0) })])
                .execute().value
            pending.subtract(ids)
            guard let rows else { continue }   // offline: ask again next time it's drawn
            var found = Dictionary(uniqueKeysWithValues: ids.map { ($0, String?.none) })
            for r in rows { found[r.userId] = r.avatarUrl }
            paths.merge(found) { _, new in new }
        }
    }

    /// Your own change, shown at once.
    func set(_ userId: String, path: String?) { paths[userId] = .some(path) }
}

actor AvatarImages {
    static let shared = AvatarImages()
    private let memory = NSCache<NSString, UIImage>()
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.urlCache = URLCache(memoryCapacity: 0, diskCapacity: 20 << 20,
                              directory: URL.cachesDirectory.appending(path: "Avatars", directoryHint: .isDirectory))
        c.requestCachePolicy = .returnCacheDataElseLoad   // a new upload has a new name
        return URLSession(configuration: c)
    }()

    func image(_ path: String) async -> UIImage? {
        if let hit = memory.object(forKey: path as NSString) { return hit }
        guard let (data, response) = try? await session.data(from: AvatarStore.url(path)),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let image = UIImage(data: data) else { return nil }
        memory.setObject(image, forKey: path as NSString)
        return image
    }
}

/// A square tile: the photo when the account has one, otherwise initials on its color.
struct AvatarView: View {
    let name: String
    var userId: String?
    var size: CGFloat = 24
    @State private var image: UIImage?

    var body: some View {
        let path = userId.flatMap { AvatarStore.shared.path($0) }
        ZStack {
            AvatarStyle.palette[AvatarStyle.colorIndex(AvatarStyle.seed(userId: userId, name: name))]
            Text(AvatarStyle.initials(name))
                .font(T1.mono(size * 0.4, .medium)).tracking(0.5).foregroundStyle(T1.text)
                .lineLimit(1).minimumScaleFactor(0.5)
            if let image, path != nil {
                Image(uiImage: image).resizable().scaledToFill()
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .accessibilityHidden(true)
        .onAppear { if let userId { AvatarStore.shared.want(userId) } }
        .task(id: path) {
            image = nil
            if let path { image = await AvatarImages.shared.image(path) }
        }
    }
}

extension UIImage {
    /// Centre square, 512 px, JPEG 0.8: well under the bucket's 1 MB limit.
    func avatarJPEG() -> Data? {
        let side = min(size.width, size.height)
        guard side > 0 else { return nil }
        let out: CGFloat = min(512, side)
        let scale = out / side
        let drawSize = CGSize(width: size.width * scale, height: size.height * scale)
        let origin = CGPoint(x: (out - drawSize.width) / 2, y: (out - drawSize.height) / 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let square = UIGraphicsImageRenderer(size: CGSize(width: out, height: out), format: format).image { _ in
            draw(in: CGRect(origin: origin, size: drawSize))
        }
        return square.jpegData(compressionQuality: 0.8)
    }
}

extension Repo {
    /// Uploads to <user_id>/<random>.jpg, points the profile at it, then removes the old file.
    static func setAvatar(_ jpeg: Data) async throws {
        guard let uid = userId?.lowercased() else { return }
        let path = "\(uid)/\(UUID().uuidString.lowercased()).jpg"
        try await supabase.storage.from("avatars")
            .upload(path, data: jpeg, options: FileOptions(contentType: "image/jpeg", upsert: true))
        let result = try await avatarCall("avatar_set", ["p_path": .string(path)])
        await AvatarStore.shared.set(uid, path: path)
        if let old = result.previous, old != path { _ = try? await supabase.storage.from("avatars").remove(paths: [old]) }
    }

    static func clearAvatar() async throws {
        guard let uid = userId?.lowercased() else { return }
        let result = try await avatarCall("avatar_clear", [:])
        await AvatarStore.shared.set(uid, path: nil)
        if let old = result.previous { _ = try? await supabase.storage.from("avatars").remove(paths: [old]) }
    }

    private struct AvatarResult: Decodable { let avatarUrl: String?; let previous: String? }

    private static func avatarCall(_ fn: String, _ params: [String: AnyJSON]) async throws -> AvatarResult {
        let data = try await supabase.rpc(fn, params: params).execute().data
        return try wireDecoder.decode(AvatarResult.self, from: data)
    }
}
