import Foundation

/// Shared storage contains pending captures and account routing, never credentials.
/// Each capture is one atomically written file so the extension and app cannot
/// overwrite each other's queue. The app removes only acknowledged files.
nonisolated struct CaptureInbox {
    static let groupID = "group.com.henrydashwood.hearful"
    static let shared = CaptureInbox(
        directory: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID))
    let directory: URL?

    struct Account: Codable, Equatable, Sendable {
        let userID: String
        let server: URL
    }

    struct Capture: Codable, Identifiable, Sendable {
        let id: UUID
        let account: Account
        let url: URL
        let title: String?
        let html: String?
        // Optional fields keep captures from older app versions decodable.
        var contentFormat: String? = nil
        var replaceExisting: Bool? = nil
        let createdAt: Date
    }

    enum InboxError: LocalizedError {
        case unavailable, signedOut, invalidURL, tooLarge
        var errorDescription: String? {
            switch self {
            case .unavailable:
                "Magpie could not access its saved links. Please open Magpie and try again."
            case .signedOut: "Open Magpie and sign in before saving an article."
            case .invalidURL: "Choose an HTTP or HTTPS web link to save."
            case .tooLarge: "This page is too large to capture. Try saving its link instead."
            }
        }
    }

    var account: Account? {
        guard let directory,
            let data = try? Data(contentsOf: directory.appendingPathComponent("account.json"))
        else { return nil }
        return try? JSONDecoder().decode(Account.self, from: data)
    }

    func configure(_ account: Account) throws {
        guard let directory else { throw InboxError.unavailable }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(account).write(
            to: directory.appendingPathComponent("account.json"),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    @discardableResult
    func save(
        url: URL, title: String? = nil, html: String? = nil,
        contentFormat: String? = nil, replaceExisting: Bool = false
    ) throws -> Capture {
        guard let account else { throw InboxError.signedOut }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
            url.user == nil, url.password == nil
        else { throw InboxError.invalidURL }
        guard (html?.utf8.count ?? 0) <= 2_000_000 else { throw InboxError.tooLarge }
        guard let directory else { throw InboxError.unavailable }
        let capture = Capture(
            id: UUID(), account: account, url: url, title: title.map { String($0.prefix(500)) },
            html: html, contentFormat: contentFormat, replaceExisting: replaceExisting, createdAt: Date())
        try JSONEncoder().encode(capture).write(
            to: directory.appendingPathComponent("capture-\(capture.id).json"),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return capture
    }

    func pending(for account: Account) -> [Capture] {
        guard let directory,
            let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        return files.filter { $0.lastPathComponent.hasPrefix("capture-") }.compactMap {
            url -> Capture? in
            guard let data = try? Data(contentsOf: url),
                let capture = try? JSONDecoder().decode(Capture.self, from: data),
                capture.account == account
            else { return nil }
            return capture
        }.sorted { $0.createdAt < $1.createdAt }
    }

    func remove(_ capture: Capture) throws {
        guard let directory else { throw InboxError.unavailable }
        try FileManager.default.removeItem(
            at: directory.appendingPathComponent("capture-\(capture.id).json"))
    }

    func signOut() {
        if let account {
            for capture in pending(for: account) { try? remove(capture) }
        }
        if let directory {
            try? FileManager.default.removeItem(
                at: directory.appendingPathComponent("account.json"))
        }
    }
}
