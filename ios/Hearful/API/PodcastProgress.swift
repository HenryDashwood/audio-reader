import Foundation

nonisolated struct PodcastProgressReport: Codable, Equatable, Sendable {
    let requestID: String
    let expectedRevision: String
    let seconds: Double
    let completed: Bool
    var isValid: Bool {
        isProgressToken(expectedRevision) && seconds.isFinite && seconds >= 0
            && (1...64).contains(requestID.utf8.count)
            && requestID.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
    }
    enum CodingKeys: String, CodingKey {
        case completed
        case requestID = "request_id"
        case expectedRevision = "expected_revision"
        case seconds = "position_seconds"
    }
}

nonisolated struct PodcastProgressReceipt: Decodable, Sendable {
    let episode: Episode
    let acceptedRevision: String
    var changedSinceAcceptance: Bool { episode.progressRevision != acceptedRevision }
    enum CodingKeys: String, CodingKey {
        case episode
        case acceptedRevision = "accepted_revision"
    }
}
