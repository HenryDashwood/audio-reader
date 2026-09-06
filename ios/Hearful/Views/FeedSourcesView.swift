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
                        Button("Try again") { Task { await model.load(showID: show.id) } }
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

    init(api: any HearfulAPIProtocol = HearfulAPI()) { self.api = api }

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
    }

    func combine(_ other: Show, into showID: Int) async {
        await change(showID: showID, sourceID: other.id, separating: false)
    }

    func separate(_ source: FeedSource, from showID: Int) async {
        await change(showID: showID, sourceID: source.id, separating: true)
    }

    private func change(showID: Int, sourceID: Int, separating: Bool) async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            if separating {
                try await api.separateSource(showID: showID, sourceID: sourceID)
            } else {
                try await api.combineSource(showID: showID, sourceID: sourceID)
            }
            NotificationCenter.default.post(name: .hearfulSubscriptionsChanged, object: nil)
            AccessibilityNotification.Announcement(separating ? "Source separated." : "Sources combined.").post()
            try await refresh(showID: showID)
        } catch { report(error) }
    }

    private func report(_ error: Error) {
        let message = (error as? APIError)?.spokenResponse ?? "Could not update sources. Please try again."
        self.error = message
        AccessibilityNotification.Announcement(message).post()
    }
}
