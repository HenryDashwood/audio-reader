import SwiftUI

/// Settings → Downloads: how much may be kept, what arrives by itself, and
/// everything that is on the phone now.
struct DownloadsView: View {
    @AppStorage(DownloadSettings.limitKey) private var limitBytes = DownloadSettings.defaultLimit
    @AppStorage(DownloadSettings.automaticKey) private var automatic = DownloadSettings.defaultAutomatic
    @AppStorage(DownloadSettings.perShowKey) private var perShow = DownloadSettings.defaultPerShow
    @AppStorage(DownloadSettings.wifiOnlyKey) private var wifiOnly = DownloadSettings.defaultWiFiOnly
    @ObservedObject private var downloads = EpisodeDownloads.shared
    @ObservedObject private var player = PlaybackCoordinator.shared
    @State private var confirmingRemoveAll = false
    @State private var prompt: DownloadPrompt?

    var body: some View {
        List {
            Section {
                usage
                Picker("Storage limit", selection: $limitBytes) {
                    ForEach(DownloadSettings.limitOptions, id: \.self) { bytes in
                        Text(DownloadSettings.limitLabel(bytes)).tag(bytes)
                    }
                }
            } footer: {
                Text(
                    "When downloads reach the limit, Magpie removes episodes you have finished, then the oldest "
                        + "automatic downloads. Episodes you download yourself stay until you have heard them; "
                        + "Magpie asks before one takes you over the limit."
                )
            }

            Section {
                Toggle("Download new episodes", isOn: $automatic)
                if automatic {
                    Picker("Episodes per show", selection: $perShow) {
                        ForEach(DownloadSettings.perShowOptions, id: \.self) { count in
                            Text("\(count)").tag(count)
                        }
                    }
                }
                Toggle("Use Wi-Fi only", isOn: $wifiOnly)
            } header: {
                Text("Automatic Downloads")
            } footer: {
                Text(
                    "Magpie keeps the newest unplayed episodes of each show you follow, so they play without a "
                        + "connection. With Wi-Fi only on, new episodes wait for Wi-Fi, and Magpie asks before "
                        + "downloading anything you choose over mobile data. Finished episodes are removed a day later."
                )
            }

            Section("On This iPhone") {
                if downloads.sortedRecords.isEmpty {
                    Text("Nothing downloaded yet. Swipe on an episode, or use the download button on its page.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(downloads.sortedRecords) { record in
                        row(record)
                    }
                }
            }

            if !downloads.records.isEmpty {
                Section {
                    Button("Remove All Downloads", role: .destructive) { confirmingRemoveAll = true }
                }
            }
        }
        .navigationTitle("Downloads")
        .downloadPrompt($prompt)
        .confirmationDialog(
            "Remove all downloads?", isPresented: $confirmingRemoveAll, titleVisibility: .visible
        ) {
            Button("Remove All Downloads", role: .destructive) {
                downloads.removeAll()
                AccessibilityNotification.Announcement("All downloads removed").post()
            }
        } message: {
            Text("Episodes will need a connection to play.")
        }
        .onChange(of: limitBytes) { downloads.settingsChanged() }
        .onChange(of: automatic) { downloads.settingsChanged() }
        .onChange(of: perShow) { downloads.settingsChanged() }
        .onChange(of: wifiOnly) { downloads.settingsChanged() }
    }

    private var usage: some View {
        let used = downloads.usedBytes
        let limit = limitBytes > 0 ? Int64(limitBytes) : nil
        let summary = limit.map { "\(formatBytes(used)) of \(formatBytes($0)) used" } ?? "\(formatBytes(used)) used"
        return VStack(alignment: .leading, spacing: 8) {
            Text(summary)
            if let limit {
                ProgressView(value: Double(min(used, limit)), total: Double(limit))
                    .tint(used > limit ? .orange : .accentColor)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Downloads use \(summary)")
    }

    private func row(_ record: DownloadRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            EpisodeRow(
                episode: record.episode,
                progress: player.listeningProgress(for: record.episode),
                isCurrent: player.currentEpisode?.id == record.id,
                play: record.status == .downloaded ? { player.playReportingFailure(record.episode) } : nil
            )
            Text(details(record))
                .font(.caption)
                .foregroundStyle(.secondary)
            if case .failed(let message) = record.status {
                Text(message).font(.caption).foregroundStyle(.secondary)
                Button("Retry download") { prompt = downloads.requestFromTap([record.episode]) }
                    .font(.footnote)
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Retry download: \(record.episode.title)")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                downloads.remove(episodeID: record.id)
                AccessibilityNotification.Announcement("Download removed: \(record.episode.title)").post()
            } label: {
                Label(record.status.isActive ? "Cancel download" : "Remove download", systemImage: "trash")
            }
        }
    }

    private func details(_ record: DownloadRecord) -> String {
        var parts = [record.status == .downloaded ? formatBytes(record.bytes) : "About \(formatBytes(record.bytes))"]
        if record.origin == .automatic { parts.append("Automatic") }
        if record.playedAt != nil { parts.append("Finished") }
        return parts.joined(separator: " · ")
    }
}

/// The Settings row that leads to Downloads, with what is used so far.
struct DownloadsSettingsLink: View {
    @ObservedObject private var downloads = EpisodeDownloads.shared

    var body: some View {
        NavigationLink {
            DownloadsView()
        } label: {
            LabeledContent {
                Text(downloads.records.isEmpty ? "None" : formatBytes(downloads.usedBytes))
            } label: {
                Label("Downloads", systemImage: "arrow.down.circle")
            }
        }
    }
}
