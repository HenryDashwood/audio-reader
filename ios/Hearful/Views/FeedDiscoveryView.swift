import SwiftUI

/// Finds every feed advertised by a web address before cataloguing anything.
/// A single unambiguous feed opens immediately; several become an accessible
/// choice so a comments or category feed can never silently beat the main one.
struct FeedDiscoveryView: View {
    let url: URL
    @StateObject private var model = FeedDiscoveryModel()

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                ProgressView("Looking for feeds…")
            case .failed(let message):
                ContentUnavailableView {
                    Label("Could not find a feed", systemImage: "dot.radiowaves.left.and.right")
                } description: {
                    Text(message)
                } actions: {
                    // A site with no feed may still send a newsletter. The
                    // backend asks its signup form to send it to her private
                    // address, and says what happened either way.
                    Button {
                        Task { await model.signUp(url: url) }
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
                    Button("Try Again") { Task { await model.load(url: url) } }
                }
            case .signedUp(let signup):
                ContentUnavailableView {
                    Label(
                        signup.submitted ? "Asked for the newsletter" : "Needs signing up by hand",
                        systemImage: signup.submitted ? "envelope.badge" : "person.crop.circle.badge.exclamationmark")
                } description: {
                    Text(signup.spokenResponse)
                } actions: {
                    if !signup.submitted, let address = signup.address {
                        CopyAddressButton(address: address)
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
        .task { await model.load(url: url) }
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
    private let api: HearfulAPIProtocol

    init(api: HearfulAPIProtocol = HearfulAPI()) {
        self.api = api
    }

    func load(url: URL) async {
        state = .loading
        do {
            let response = try await api.discoverFeeds(url: url)
            guard !response.candidates.isEmpty else {
                state = .failed("Magpie reached that site, but it did not advertise a readable feed.")
                return
            }
            state = .loaded(response.candidates)
            let count = response.candidates.count
            AccessibilityNotification.Announcement(
                count == 1 ? "One feed found" : "\(count) feeds found. Choose a feed."
            ).post()
        } catch let error as APIError {
            state = .failed(error.spokenResponse)
            AccessibilityNotification.Announcement(error.spokenResponse).post()
        } catch {
            state = .failed("Something went wrong.")
            AccessibilityNotification.Announcement("Feed discovery failed").post()
        }
    }

    /// Ask the site for its newsletter. The reply is a sentence whatever
    /// happened, so it is shown and spoken as it is; a newsletter that was
    /// signed up appears in Following on its own when its first email lands.
    func signUp(url: URL) async {
        guard !signingUp else { return }
        signingUp = true
        defer { signingUp = false }
        do {
            let signup = try await api.signUpForNewsletter(url: url)
            state = .signedUp(signup)
            AccessibilityNotification.Announcement(signup.spokenResponse).post()
        } catch let error as APIError {
            state = .failed(error.spokenResponse)
            AccessibilityNotification.Announcement(error.spokenResponse).post()
        } catch {
            state = .failed("Something went wrong.")
            AccessibilityNotification.Announcement("Signing up failed").post()
        }
    }
}
