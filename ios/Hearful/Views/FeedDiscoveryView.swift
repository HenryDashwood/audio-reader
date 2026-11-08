import SwiftUI

/// Finds every feed advertised by a web address before cataloguing anything.
/// A single unambiguous feed opens immediately; several become an accessible
/// choice so a comments or category feed can never silently beat the main one.
struct FeedDiscoveryView: View {
    private struct Location: Hashable {
        let url: URL
        let owner: AuthController.SessionOwner?
    }

    let url: URL
    @EnvironmentObject private var auth: AuthController
    @StateObject private var model = FeedDiscoveryModel()

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                ProgressView("Looking for feeds…")
            case .failed(let message):
                let visit = model.visit
                ContentUnavailableView {
                    Label("Could not find a feed", systemImage: "dot.radiowaves.left.and.right")
                } description: {
                    Text(message)
                } actions: {
                    // A site with no feed may still send a newsletter. The
                    // backend asks its signup form to send it to her private
                    // address, and says what happened either way.
                    Button {
                        Task { await model.signUp(for: visit) }
                    } label: {
                        if model.signingUp {
                            ProgressView()
                        } else {
                            Label("Sign up by email", systemImage: "envelope")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.signingUp)
                    .accessibilityHint("Asks the site to send its newsletter to your Magpie address")
                    Button("Try Again") { Task { await model.retry(for: visit) } }
                        .disabled(model.signingUp)
                }
            case .signedUp(let signup):
                ContentUnavailableView {
                    Label(
                        signup.resultTitle,
                        systemImage: signup.submitted ? "envelope.badge" : "person.crop.circle.badge.exclamationmark")
                } description: {
                    Text(signup.spokenResponse)
                } actions: {
                    if !signup.submitted, let address = signup.address {
                        CopyAddressButton(address: address, scope: model.visit?.scope)
                        .buttonStyle(.borderedProminent)
                    }
                }
            case .loaded(let candidates):
                if let only = candidates.first, candidates.count == 1 {
                    PodcastPreviewView(podcast: only.podcastResult)
                } else {
                    candidateList(candidates)
                }
            }
        }
        .navigationTitle("Feeds")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: Location(url: url, owner: auth.sessionOwner)) { await model.load(url: url) }
        .onDisappear { model.close() }
    }

    private func candidateList(_ candidates: [FeedDiscoveryCandidate]) -> some View {
        List {
            Section {
                ForEach(candidates) { candidate in
                    // This screen was itself opened by a destination-style
                    // NavigationLink. Mixing a value link here made SwiftUI
                    // reorder the opaque and typed destinations, briefly
                    // pushing another copy of this screen above the preview.
                    NavigationLink {
                        PodcastPreviewView(podcast: candidate.podcastResult)
                    } label: {
                        FeedCandidateRow(candidate: candidate)
                    }
                }
            } header: {
                Text("Choose a feed")
            } footer: {
                Text("Only the feed you open will be added to Magpie’s catalogue.")
            }
        }
        .listStyle(.plain)
    }
}

private struct FeedCandidateRow: View {
    let candidate: FeedDiscoveryCandidate

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: candidate.audioItemCount > 0 ? "waveform" : "doc.text")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(candidate.title).font(.headline).lineLimit(2)
                    if candidate.isPrimary {
                        Label("Recommended", systemImage: "checkmark.seal.fill")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.tint)
                    }
                }
                Text(metadata)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let latest = candidate.recentItemTitles.first {
                    Text("Latest: \(latest)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var formatName: String {
        switch candidate.format.lowercased() {
        case "atom": "Atom"
        case "json": "JSON Feed"
        default: "RSS"
        }
    }

    private var itemName: String {
        if candidate.audioItemCount > 0 {
            candidate.itemCount == 1 ? "episode" : "episodes"
        } else {
            candidate.itemCount == 1 ? "post" : "posts"
        }
    }

    private var metadata: String {
        "\(formatName) · \(candidate.itemCount) \(itemName)"
    }

    private var accessibilityLabel: String {
        var parts = [candidate.title]
        if candidate.isPrimary { parts.append("recommended feed") }
        parts.append(metadata)
        if let latest = candidate.recentItemTitles.first { parts.append("latest, \(latest)") }
        return parts.joined(separator: ", ")
    }
}

@MainActor
final class FeedDiscoveryModel: ObservableObject {
    enum State: Equatable {
        case loading
        case loaded([FeedDiscoveryCandidate])
        case failed(String)
        case signedUp(NewsletterSignup)
    }

    @Published private(set) var state: State = .loading
    @Published private(set) var signingUp = false
    struct Visit: Equatable {
        let url: URL
        let scope: String?
        fileprivate let id = UUID()
    }

    private(set) var visit: Visit?
    private let api: HearfulAPIProtocol
    private let announce: (String) -> Void

    init(api: HearfulAPIProtocol = HearfulAPI(), announce: @escaping (String) -> Void = {
        AccessibilityNotification.Announcement($0).post()
    }) {
        self.api = api
        self.announce = announce
    }

    func close() {
        visit = nil
        signingUp = false
        state = .loading
    }

    private func isCurrent(_ request: Visit) -> Bool {
        visit == request && request.scope == ShortcutScope.current && !Task.isCancelled
    }

    func retry(for request: Visit?) async {
        guard let request, isCurrent(request), case .failed = state, !signingUp else { return }
        await load(url: request.url)
    }

    func load(url: URL) async {
        guard !Task.isCancelled else { return }
        let session = HearfulAPI.RequestSession()
        let request = Visit(url: url, scope: session.scope)
        visit = request
        signingUp = false
        state = .loading
        do {
            let response = try await session.perform { try await api.discoverFeeds(url: url) }
            guard isCurrent(request) else { return }
            guard !response.candidates.isEmpty else {
                state = .failed("Magpie reached that site, but it did not advertise a readable feed.")
                return
            }
            state = .loaded(response.candidates)
            let count = response.candidates.count
            announce(count == 1 ? "One feed found" : "\(count) feeds found. Choose a feed.")
        } catch {
            guard isCurrent(request) else { return }
            let message = (error as? APIError)?.spokenResponse
            state = .failed(message ?? "Something went wrong.")
            announce(message ?? "Feed discovery failed")
        }
    }

    func signUp(for request: Visit?) async {
        guard let request, isCurrent(request), case .failed = state, !signingUp else { return }
        let session = HearfulAPI.RequestSession()
        signingUp = true
        defer { if visit == request { signingUp = false } }
        do {
            let signup = try await session.perform { try await api.signUpForNewsletter(url: request.url) }
            guard isCurrent(request) else { return }
            state = .signedUp(signup)
            announce(signup.spokenResponse)
        } catch {
            guard isCurrent(request) else { return }
            let message = (error as? APIError)?.spokenResponse
            state = .failed(message ?? "Something went wrong.")
            announce(message ?? "Signing up failed")
        }
    }
}
