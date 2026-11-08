import SwiftUI

struct FeedSourcesView: View {
    let show: Show
    @StateObject private var model = FeedSourcesModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Combine sources of the same publication into one list. Matching articles appear once, using the copy with the most text, and share reading progress.")
                        .font(.callout)
                    Text("Separating a source returns it to your library with its reading progress.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Section("Sources in \(show.title)") {
                    ForEach(model.sources) { source in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(source.title).font(.headline)
                            Text(source.locationLabel).font(.subheadline).foregroundStyle(.secondary)
                            if source.isFailing {
                                Label("This source is not updating", systemImage: "exclamationmark.triangle")
                                    .font(.callout)
                            }
                            if source.isPrimary {
                                Text("Used for the publication’s name and artwork")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Button("Separate source") {
                                    Task { await model.separate(source, from: show.id) }
                                }
                                .disabled(model.needsSourceRefresh)
                                .accessibilityLabel("Separate \(source.title), \(source.locationLabel)")
                            }
                        }
                    }
                }
                Section {
                    ForEach(model.available) { other in
                        Button {
                            Task { await model.combine(other, into: show.id) }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(other.title, systemImage: "plus.circle")
                                if let source = other.sources?.first(where: { $0.isPrimary }) {
                                    Text(source.locationLabel).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(model.needsSourceRefresh)
                        .accessibilityLabel("Combine \(other.title) with \(show.title)")
                    }
                } header: {
                    Text("Combine with a subscription")
                } footer: {
                    Text("To use another feed, subscribe to it in your library first. Combining a publication includes all its sources.")
                }
                if let error = model.error {
                    Section {
                        Text(error).foregroundStyle(.red)
                        Button("Try again") { Task { await model.retry(showID: show.id) } }
                    }
                }
            }
            .disabled(model.busy)
            .overlay { if model.busy { ProgressView().accessibilityLabel("Updating sources") } }
            .navigationTitle("Manage sources")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { await model.load(showID: show.id) }
        }
    }
}

@MainActor
final class FeedSourcesModel: ObservableObject {
    @Published private(set) var sources: [FeedSource] = []
    @Published private(set) var available: [Show] = []
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    private let api: any HearfulAPIProtocol

    private let notifications: NotificationCenter
    private let announce: (String) -> Void
    private var savedChange: String?
    var needsSourceRefresh: Bool { savedChange != nil }

    init(api: any HearfulAPIProtocol = HearfulAPI(), notifications: NotificationCenter = .default,
         announce: @escaping (String) -> Void = { AccessibilityNotification.Announcement($0).post() }) {
        self.api = api
        self.notifications = notifications
        self.announce = announce
    }

    func retry(showID: Int) async {
        guard !busy else { return }
        notifications.post(name: .hearfulSubscriptionsChanged, object: nil)
        await load(showID: showID)
    }

    func load(showID: Int) async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do { try await refresh(showID: showID) }
        catch { report(error) }
    }

    private func refresh(showID: Int) async throws {
        async let loadedSources = api.feedSources(showID: showID)
        async let loadedShows = api.shows()
        let (sources, shows) = try await (loadedSources, loadedShows)
        self.sources = sources.sorted { $0.isPrimary && !$1.isPrimary }
        available = shows.filter { $0.id != showID }
        savedChange = nil
    }

    func combine(_ other: Show, into showID: Int) async {
        await change(showID: showID, sourceID: other.id, separating: false)
    }

    func separate(_ source: FeedSource, from showID: Int) async {
        await change(showID: showID, sourceID: source.id, separating: true)
    }

    private func change(showID: Int, sourceID: Int, separating: Bool) async {
        guard !busy, !needsSourceRefresh else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            if separating {
                try await api.separateSource(showID: showID, sourceID: sourceID)
            } else {
                try await api.combineSource(showID: showID, sourceID: sourceID)
            }
            let success = separating ? "Source separated." : "Sources combined."
            savedChange = success
            notifications.post(name: .hearfulSubscriptionsChanged, object: nil)
            try await refresh(showID: showID)
            announce(success)
        } catch { report(error) }
    }

    private func report(_ error: Error) {
        let message: String
        if let savedChange {
            message = "\(savedChange) The source list couldn’t be refreshed. Tap Try again to refresh Manage Sources and Following."
        } else {
            message = (error as? APIError)?.spokenResponse ?? "Could not update sources. Please try again."
        }
        self.error = message
        announce(message)
    }
}
