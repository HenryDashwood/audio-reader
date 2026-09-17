import Foundation

/// Exact source-text coordinates, independent of voice, speed and audio duration.
nonisolated struct ArticleBookmark: Codable, Equatable, Hashable, Sendable {
    let textVersion: String
    let offsetUTF16: Int
    var isValid: Bool { isProgressToken(textVersion) && offsetUTF16 >= 0 }
    enum CodingKeys: String, CodingKey {
        case textVersion = "text_version"
        case offsetUTF16 = "offset_utf16"
    }
}

nonisolated struct ArticleProgressState: Codable, Equatable, Sendable {
    let textVersion: String
    let contentID: Int?
    let revision: String
    let bookmark: ArticleBookmark?
    var isValid: Bool {
        isProgressToken(textVersion) && isProgressToken(revision) && (contentID == nil || contentID! > 0)
            && (bookmark == nil || bookmark!.isValid && bookmark!.textVersion == textVersion)
    }
    enum CodingKeys: String, CodingKey {
        case revision, bookmark
        case textVersion = "text_version"
        case contentID = "content_id"
    }
}

/// Persist and retry this exact value; never replace the expected revision after a conflict.
nonisolated struct ArticleProgressReport: Codable, Equatable, Sendable {
    let requestID: String
    let expectedRevision: String
    let textVersion: String
    let contentID: Int?
    let offsetUTF16: Int
    let completed: Bool
    var isValid: Bool {
        (1...64).contains(requestID.utf8.count)
            && requestID.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
            && isProgressToken(expectedRevision) && isProgressToken(textVersion)
            && (contentID == nil || contentID! > 0) && offsetUTF16 >= 0
    }
    enum CodingKeys: String, CodingKey {
        case completed
        case requestID = "request_id"
        case expectedRevision = "expected_revision"
        case textVersion = "text_version"
        case contentID = "content_id"
        case offsetUTF16 = "offset_utf16"
    }
}

nonisolated struct ArticleProgressReceipt: Decodable, Sendable {
    let episode: Episode
    let progress: ArticleProgressState
    let acceptedRevision: String
    var changedSinceAcceptance: Bool { progress.revision != acceptedRevision }
    enum CodingKeys: String, CodingKey {
        case episode, progress
        case acceptedRevision = "accepted_revision"
    }
}

nonisolated func isProgressToken(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}
