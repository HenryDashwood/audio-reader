import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
final class ShareViewController: UIViewController {
    private var confirmation: UIHostingController<ShareConfirmationView>?
    private var started = false
    private var pendingInput: Input?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let confirmation = UIHostingController(rootView: makeConfirmation(state: .saving))
        self.confirmation = confirmation
        addChild(confirmation)
        confirmation.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(confirmation.view)
        NSLayoutConstraint.activate([
            confirmation.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            confirmation.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            confirmation.view.topAnchor.constraint(equalTo: view.topAnchor),
            confirmation.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        confirmation.didMove(toParent: self)
        // Share hosts may use this to present a compact sheet. The content also
        // centers and scrolls when a host supplies a taller or smaller surface.
        preferredContentSize = CGSize(width: 420, height: 480)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        Task { await capture() }
    }

    private struct Input: Sendable {
        let url: URL
        let title: String?
        let html: String?
        var preview: String? = nil
        var contentFormat: String? = nil
    }

    private func read(_ provider: NSItemProvider, type: String) async -> Input? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { value, _ in
                if type == UTType.propertyList.identifier,
                    let dictionary = value as? NSDictionary,
                    let result = dictionary[NSExtensionJavaScriptPreprocessingResultsKey]
                        as? [String: Any],
                    let rawURL = result["url"] as? String, let url = URL(string: rawURL)
                {
                    continuation.resume(
                        returning: Input(
                            url: url, title: result["title"] as? String,
                            html: result["html"] as? String, preview: result["preview"] as? String,
                            contentFormat: result["contentFormat"] as? String))
                } else if let url = value as? URL {
                    continuation.resume(returning: Input(url: url, title: nil, html: nil))
                } else if let value = value as? String, let url = URL(string: value) {
                    continuation.resume(returning: Input(url: url, title: nil, html: nil))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func capture() async {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap {
            $0.attachments ?? []
        }
        var input: Input?
        // Safari's page capture takes priority over the bare link attachment.
        for type in [UTType.propertyList.identifier, UTType.url.identifier] {
            for provider in providers where provider.hasItemConformingToTypeIdentifier(type) {
                if let found = await read(provider, type: type) {
                    input = found
                    break
                }
            }
            if input != nil { break }
        }
        do {
            guard let input else { throw CaptureInbox.InboxError.invalidURL }
            pendingInput = input
            show(.ready(title: input.title, url: input.url, preview: input.preview))
        } catch {
            show(.failed(message: error.localizedDescription))
        }
    }

    private func saveCapture() {
        do {
            guard let input = pendingInput else { throw CaptureInbox.InboxError.invalidURL }
            try CaptureInbox.shared.save(
                url: input.url, title: input.title, html: input.html,
                contentFormat: input.contentFormat, replaceExisting: true)
            pendingInput = nil
            show(.saved(title: input.title, url: input.url))
        } catch {
            show(.failed(message: error.localizedDescription))
        }
    }

    private func makeConfirmation(state: ShareConfirmationView.Phase) -> ShareConfirmationView {
        ShareConfirmationView(state: state, save: { [weak self] in
            self?.saveCapture()
        }) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
    }

    private func show(_ state: ShareConfirmationView.Phase) {
        confirmation?.rootView = makeConfirmation(state: state)
        if !state.isReady {
            UINotificationFeedbackGenerator().notificationOccurred(state.isSaved ? .success : .error)
        }
        UIAccessibility.post(
            notification: .announcement, argument: "\(state.heading). \(state.message)")
    }
}

private struct ShareConfirmationView: View {
    enum Phase {
        case saving
        case ready(title: String?, url: URL, preview: String?)
        case saved(title: String?, url: URL)
        case failed(message: String)

        var heading: String {
            switch self {
            case .saving: "Preparing article…"
            case .ready: "Save to Magpie"
            case .saved: "Saved to Magpie"
            case .failed: "Couldn't save article"
            }
        }

        var message: String {
            switch self {
            case .saving: "Getting this page ready to save."
            case .ready(_, _, let preview):
                if let preview, !preview.isEmpty {
                    "Ready to read or listen to later."
                } else {
                    "The article couldn't be identified in this page. Save its link and Magpie will try the original address."
                }
            case .saved:
                "Saved on this device. Open Magpie to prepare it for reading and listening."
            case .failed(let message): message
            }
        }

        var isSaving: Bool {
            if case .saving = self { return true }
            return false
        }

        var isSaved: Bool {
            if case .saved = self { return true }
            return false
        }

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    let state: Phase
    var save: () -> Void = {}
    let done: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 20) {
                        statusIcon
                        VStack(spacing: 10) {
                            Text(state.heading)
                                .font(.title2.bold())
                                .foregroundStyle(.primary)
                                .accessibilityAddTraits(.isHeader)
                            Text(state.message)
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    if case .saved(let title, let url) = state {
                        articlePreview(title: title, url: url)
                    }

                    if case .ready(let title, let url, let preview) = state {
                        articlePreview(title: title, url: url, preview: preview)
                        VStack(spacing: 16) {
                            Text("Already saved? This updates your copy. If the text changes, listening starts from the beginning.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                            Button(action: save) {
                                Text("Save article")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity, minHeight: 32)
                            }
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.roundedRectangle(radius: 16))
                            .controlSize(.large)
                            Button("Cancel", action: done)
                                .font(.body)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !state.isReady {
                        Button(action: done) {
                            Text("Done")
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 32)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.roundedRectangle(radius: 16))
                        .controlSize(.large)
                        .disabled(state.isSaving)
                    }
                }
                .padding(28)
                .frame(maxWidth: 476)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Color(uiColor: .systemBackground))
    }

    private var statusIcon: some View {
        ZStack {
            Circle()
                .fill(Color(uiColor: state.isSaved ? .systemGreen : .secondaryLabel).opacity(0.12))
            if state.isSaving {
                ProgressView()
                    .controlSize(.large)
            } else {
                Image(systemName: state.isReady ? "doc.text" : (state.isSaved ? "checkmark" : "exclamationmark"))
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Color(uiColor: state.isSaved ? .systemGreen : .label))
            }
        }
        .frame(width: 72, height: 72)
        .accessibilityHidden(true)
    }

    private func articlePreview(title: String?, url: URL, preview: String? = nil) -> some View {
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = url.host() ?? url.absoluteString
        let source = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host

        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                if let title, !title.isEmpty {
                    Text(title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(source)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text(source)
                        .font(.headline)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let preview, !preview.isEmpty {
                Divider()
                Text(preview)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Article begins: \(preview)")
            }
        }
        .padding(18)
        .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 18))
        .accessibilityElement(children: .combine)
    }
}

#Preview("Ready to save") {
    ShareConfirmationView(
        state: .ready(
            title: "The quiet pleasure of listening to a good story",
            url: URL(string: "https://www.example.com/article")!,
            preview: "Some stories deserve your full attention. Others find their place alongside a morning walk, a familiar journey, or a quiet moment at home.")
    ) {}
}

#Preview("Link only") {
    ShareConfirmationView(
        state: .ready(title: nil, url: URL(string: "https://www.example.com/article")!, preview: nil)
    ) {}
}

#Preview("Saved article") {
    ShareConfirmationView(
        state: .saved(
            title: "The quiet pleasure of listening to a good story",
            url: URL(string: "https://www.example.com/article")!)
    ) {}
}

#Preview("Saving") {
    ShareConfirmationView(state: .saving) {}
}

#Preview("Unable to save") {
    ShareConfirmationView(state: .failed(message: CaptureInbox.InboxError.signedOut.localizedDescription)) {}
}
