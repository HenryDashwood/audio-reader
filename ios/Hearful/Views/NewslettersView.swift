import SwiftUI
import UIKit

// MARK: - Her address

/// The Settings section that shows her newsletter address.
///
/// The address is random letters, which is the worst possible thing to read
/// off a screen or hear as one word. So it is offered three ways: spelled
/// out letter by letter for VoiceOver and for the Read Aloud button, copied
/// to the clipboard for pasting into a signup form, and shared so someone
/// helping her can receive it as a message rather than take dictation.
struct NewsletterAddressSection: View {
    @StateObject private var model = NewsletterAddressModel()
    @State private var speaker = Speaker()

    var body: some View {
        Section {
            switch model.state {
            case .loading:
                ProgressView("Getting your newsletter address…")
            case .unavailable(let message):
                Text(message).foregroundStyle(.secondary)
            case .loaded(let address):
                Text(address.address)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .accessibilityLabel("Your newsletter address is \(address.spoken)")
                Button("Read Address Aloud") {
                    Task { await speaker.speak("Your newsletter address is \(address.spoken)") }
                }
                .accessibilityHint("Spells the address out one letter at a time")
                Button("Copy Address") {
                    UIPasteboard.general.string = address.address
                    AccessibilityNotification.Announcement("Address copied.").post()
                }
                .accessibilityHint("Puts the address on the clipboard, ready to paste into a signup form")
                ShareLink(item: address.address, subject: Text("My Magpie newsletter address")) {
                    Label("Share Address", systemImage: "square.and.arrow.up")
                }
                .accessibilityHint("Sends the address to someone who can sign you up")
            }
        } header: {
            Text("Newsletters")
        } footer: {
            Text(
                "Give this address to a newsletter instead of your own email. "
                    + "The first time a sender writes to it, Magpie asks you whether to follow them "
                    + "before anything is read to you."
            )
        }
        .task { await model.load() }
    }
}

@MainActor
final class NewsletterAddressModel: ObservableObject {
    enum State: Equatable {
        case loading
        case loaded(NewsletterAddress)
        case unavailable(String)
    }

    @Published private(set) var state: State = .loading
    private let api: HearfulAPIProtocol

    init(api: HearfulAPIProtocol = HearfulAPI()) {
        self.api = api
    }

    func load() async {
        do {
            state = .loaded(try await api.newsletterAddress())
        } catch {
            state = .unavailable((error as? APIError)?.spokenResponse ?? "Something went wrong.")
        }
    }
}

// MARK: - Senders waiting for an answer

/// The senders that have written to her address and are waiting to be
/// followed or blocked. Shown at the top of Following, because it is the one
/// thing on that screen that needs something from her.
struct PendingNewslettersSection: View {
    @ObservedObject var model: PendingNewslettersModel
    @State private var blocking: PendingNewsletter?

    var body: some View {
        if !model.pending.isEmpty {
            Section {
                ForEach(model.pending) { item in
                    PendingNewsletterRow(
                        item: item,
                        busy: model.busyID == item.id,
                        follow: { Task { await model.approve(item) } },
                        block: { blocking = item })
                }
                if let message = model.errorMessage {
                    Text(message).font(.callout).foregroundStyle(.red)
                }
            } header: {
                Text("Waiting for your answer")
            } footer: {
                // The plain list style used by Following renders footers at
                // body size, larger than the rows they explain; Settings'
                // grouped style makes them footnotes. Match that here.
                Text(
                    "These senders have written to your newsletter address. "
                        + "Follow one to have what it sends read to you. "
                        + "Block one and its messages are dropped from now on."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .confirmationDialog(
                "Block this sender?",
                isPresented: Binding(get: { blocking != nil }, set: { if !$0 { blocking = nil } }),
                titleVisibility: .visible,
                presenting: blocking
            ) { item in
                Button("Block \(item.title)", role: .destructive) {
                    Task { await model.block(item) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { item in
                Text(
                    "Everything \(item.title) has sent is deleted, and anything it sends later "
                        + "is dropped without being kept.")
            }
        }
    }
}

private struct PendingNewsletterRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let item: PendingNewsletter
    let busy: Bool
    let follow: () -> Void
    let block: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(item.senderAddress)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(item.title), \(detail), waiting for your answer")

            HStack(spacing: 12) {
                Button(action: follow) {
                    if busy {
                        ProgressView()
                    } else {
                        Text("Follow")
                    }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Follow \(item.title)")
                .accessibilityHint("Puts everything it has sent in Latest and reads what comes next")

                Button("Block", role: .destructive, action: block)
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Block \(item.title)")
                    .accessibilityHint("Deletes its messages and drops anything it sends later")
            }
            .disabled(busy)
        }
        .padding(.vertical, 4)
    }

    private var detail: String {
        if let latest = item.latestTitle {
            return "\(item.messageCountLabel), latest: \(latest)"
        }
        return item.messageCountLabel
    }
}

@MainActor
final class PendingNewslettersModel: ObservableObject {
    @Published private(set) var pending: [PendingNewsletter] = []
    @Published private(set) var busyID: Int?
    @Published private(set) var errorMessage: String?
    private let api: HearfulAPIProtocol

    init(api: HearfulAPIProtocol = HearfulAPI()) {
        self.api = api
    }

    /// Quiet on failure: this list is a courtesy at the top of Following, and
    /// a network error there is already reported by the library itself.
    func load() async {
        if let fetched = try? await api.pendingNewsletters() {
            pending = fetched
        }
    }

    /// True on success. The sender becomes a show in Following and its
    /// messages appear in Latest; both screens are told to reload.
    @discardableResult
    func approve(_ item: PendingNewsletter) async -> Bool {
        guard busyID == nil else { return false }
        busyID = item.id
        errorMessage = nil
        defer { busyID = nil }
        do {
            _ = try await api.approveNewsletter(id: item.id)
            pending.removeAll { $0.id == item.id }
            NotificationCenter.default.post(name: .hearfulSubscriptionsChanged, object: nil)
            AccessibilityNotification.Announcement(
                "Following \(item.title). \(item.messageCountLabel.capitalizedFirst) now in Latest."
            ).post()
            return true
        } catch {
            report(error)
            return false
        }
    }

    @discardableResult
    func block(_ item: PendingNewsletter) async -> Bool {
        guard busyID == nil else { return false }
        busyID = item.id
        errorMessage = nil
        defer { busyID = nil }
        do {
            try await api.blockNewsletter(id: item.id)
            pending.removeAll { $0.id == item.id }
            AccessibilityNotification.Announcement("Blocked \(item.title).").post()
            return true
        } catch {
            report(error)
            return false
        }
    }

    private func report(_ error: Error) {
        let message = (error as? APIError)?.spokenResponse ?? "Something went wrong."
        errorMessage = message
        AccessibilityNotification.Announcement(message).post()
    }
}

extension String {
    /// "2 messages" as the start of a sentence: "2 messages" stays, "one
    /// message" would become "One message".
    fileprivate var capitalizedFirst: String {
        guard let first = first else { return self }
        return first.uppercased() + dropFirst()
    }
}
