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
    let readout: SettingsReadout

    var body: some View {
        Section {
            switch model.state {
            case .loading:
                ProgressView("Getting your newsletter address…")
            case .unavailable(let message):
                Text(message).foregroundStyle(.secondary)
            case .loaded(let address):
                let scope = model.addressScope
                Text(address.address)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .accessibilityLabel("Your newsletter address is \(address.spoken)")
                Button("Read Address Aloud") {
                    readout.speak("Your newsletter address is \(address.spoken)", expectedScope: scope)
                }
                .accessibilityHint("Says the address one word at a time")
                Button("Spell Address") {
                    readout.speak("Your newsletter address is spelled \(address.spelledOut)", expectedScope: scope)
                }
                .accessibilityHint("Says every letter, for writing it down")
                CopyAddressButton(address: address.address, scope: scope)
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

/// Copies an address with feedback that is visible, felt and announced.
///
/// Kept as one control because the same action also appears when Magpie finds
/// a newsletter that needs signing up by hand. Whichever route she took, it
/// should answer the tap in the same way.
struct CopyAddressButton: View {
    let address: String
    let scope: String?
    @State private var copied = false
    @State private var feedbackTrigger = 0
    @State private var resetTask: Task<Void, Never>?

    func copy(to pasteboard: UIPasteboard) -> Bool {
        guard scope == ShortcutScope.current else { return false }
        pasteboard.string = address
        return true
    }

    var body: some View {
        Button {
            guard copy(to: .general) else { return }
            feedbackTrigger += 1
            resetTask?.cancel()
            withAnimation(.easeInOut(duration: 0.15)) { copied = true }
            AccessibilityNotification.Announcement("Address copied.").post()
            resetTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.15)) { copied = false }
            }
        } label: {
            Label(
                copied ? "Copied" : "Copy Address",
                systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .sensoryFeedback(.success, trigger: feedbackTrigger)
        .accessibilityLabel(copied ? "Address copied" : "Copy Address")
        .accessibilityHint(
            "Puts the address on the clipboard, ready to paste into a signup form")
        .onChange(of: address) {
            resetTask?.cancel()
            copied = false
        }
        .onDisappear { resetTask?.cancel() }
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
    private(set) var addressScope: String?
    private var revision = 0
    private let api: HearfulAPIProtocol

    init(api: HearfulAPIProtocol = HearfulAPI()) {
        self.api = api
    }

    func load() async {
        let session = HearfulAPI.RequestSession()
        if addressScope != session.scope {
            addressScope = session.scope
            state = .loading
        }
        revision += 1
        let request = revision
        do {
            let address = try await session.perform { try await api.newsletterAddress() }
            guard request == revision, session.scope == ShortcutScope.current, !Task.isCancelled else { return }
            state = .loaded(address)
        } catch {
            guard request == revision, session.scope == ShortcutScope.current, !Task.isCancelled else { return }
            state = .unavailable((error as? APIError)?.spokenResponse ?? "Something went wrong.")
        }
    }
}

// MARK: - Senders waiting for an answer

/// The senders that have written to her address and are waiting to be
/// followed or blocked. Shown at the top of Latest: that is where new things
/// arrive, and following one puts its messages into the very list below.
struct PendingNewslettersSection: View {
    @ObservedObject var model: PendingNewslettersModel
    private struct BlockConfirmation {
        let sender: PendingNewsletter
        let scope: String?
    }
    @State private var blocking: BlockConfirmation?

    var body: some View {
        if !model.pending.isEmpty {
            Section {
                let scope = model.listScope
                ForEach(model.pending) { item in
                    PendingNewsletterRow(
                        item: item,
                        busy: model.busyID == item.id,
                        follow: { Task { await model.approve(item, expectedScope: scope) } },
                        block: { blocking = BlockConfirmation(sender: item, scope: scope) })
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
            ) { confirmation in
                Button("Block \(confirmation.sender.title)", role: .destructive) {
                    Task { await model.block(confirmation.sender, expectedScope: confirmation.scope) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { confirmation in
                Text(
                    "Everything \(confirmation.sender.title) has sent is deleted, and anything it sends later "
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
    private var listRevision = 0
    private(set) var listScope: String?
    private let api: HearfulAPIProtocol

    private let announce: (String) -> Void

    init(api: HearfulAPIProtocol = HearfulAPI(), announce: @escaping (String) -> Void = {
        AccessibilityNotification.Announcement($0).post()
    }) {
        self.announce = announce
        self.api = api
    }

    /// Quiet on failure: this list is a courtesy at the top of Following, and
    /// a network error there is already reported by the library itself.
    func load() async {
        let session = HearfulAPI.RequestSession()
        let scope = session.scope
        if listScope != scope {
            listScope = scope
            pending = []
            busyID = nil
            errorMessage = nil
        }
        guard busyID == nil else { return }
        listRevision += 1
        let revision = listRevision
        let rows = try? await session.perform { try await api.pendingNewsletters() }
        guard revision == listRevision, scope == ShortcutScope.current, !Task.isCancelled else { return }
        if let rows { pending = rows }
    }

    @discardableResult
    func approve(_ item: PendingNewsletter, expectedScope: String? = ShortcutScope.current) async -> Bool {
        await change(item, follow: true, expectedScope: expectedScope)
    }

    @discardableResult
    func block(_ item: PendingNewsletter, expectedScope: String? = ShortcutScope.current) async -> Bool {
        await change(item, follow: false, expectedScope: expectedScope)
    }

    private func change(_ item: PendingNewsletter, follow: Bool, expectedScope: String?) async -> Bool {
        let session = HearfulAPI.RequestSession()
        guard listScope == expectedScope, expectedScope == session.scope,
              busyID == nil, pending.contains(where: { $0.id == item.id }) else { return false }
        listRevision += 1
        let revision = listRevision
        busyID = item.id
        errorMessage = nil
        defer { if revision == listRevision { busyID = nil } }
        do {
            try await session.perform {
                if follow { _ = try await api.approveNewsletter(id: item.id) }
                else { try await api.blockNewsletter(id: item.id) }
            }
            guard revision == listRevision, expectedScope == ShortcutScope.current else { return false }
            pending.removeAll { $0.id == item.id }
            if follow {
                NotificationCenter.default.post(name: .hearfulSubscriptionsChanged, object: nil)
                announce("Following \(item.title). \(item.messageCountLabel.capitalizedFirst) now in Latest.")
            } else {
                announce("Blocked \(item.title).")
            }
            return true
        } catch {
            guard revision == listRevision, expectedScope == ShortcutScope.current else { return false }
            report(error)
            return false
        }
    }

    private func report(_ error: Error) {
        let message = (error as? APIError)?.spokenResponse ?? "Something went wrong."
        errorMessage = message
        announce(message)
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
