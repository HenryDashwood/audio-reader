import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
final class ShareViewController: UIViewController {
    private var confirmation: UIHostingController<ShareConfirmationView>?
    private var started = false
    private var pendingInput: Input?
    private var queuedPDF: PDFUploadInbox.Pending?
    private var queuedCapture: CaptureInbox.Capture?
    private var uploadTask: Task<Void, Never>?

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
        var pdf: Data? = nil
        var preview: String? = nil
        var contentFormat: String? = nil
        var captureFailure: String? = nil
    }

    private func read(_ provider: NSItemProvider, type: String) async -> Input? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { value, _ in
                if type == UTType.propertyList.identifier,
                    let dictionary = value as? NSDictionary,
                    let result = dictionary[NSExtensionJavaScriptPreprocessingResultsKey]
                        as? [String: Any],
                    let rawURL = result["url"] as? String, let url = URL(string: rawURL),
                    ["http", "https"].contains(url.scheme?.lowercased() ?? "")
                {
                    continuation.resume(
                        returning: Input(
                            url: url, title: result["title"] as? String,
                            html: result["html"] as? String, preview: result["preview"] as? String,
                            contentFormat: result["contentFormat"] as? String, captureFailure: result["captureFailure"] as? String))
                } else if let url = value as? URL, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    continuation.resume(returning: Input(url: url, title: nil, html: nil))
                } else if let value = value as? String, let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
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
        if input == nil {
            for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                input = await withCheckedContinuation { continuation in
                    provider.loadFileRepresentation(forTypeIdentifier: UTType.pdf.identifier) { url, _ in
                        guard let url, let data = try? PDFUploadInbox.readFile(url) else {
                            continuation.resume(returning: nil); return
                        }
                        continuation.resume(returning: Input(url: URL(fileURLWithPath: url.lastPathComponent),
                            title: url.lastPathComponent, html: nil, pdf: data,
                            preview: "PDF · Prepared privately with Datalab", contentFormat: "pdf"))
                    }
                }
                if input != nil { break }
            }
        }
        do {
            guard let input else { throw CaptureInbox.InboxError.invalidURL }
            pendingInput = input
            if input.contentFormat == "pdf" || input.pdf != nil || input.url.pathExtension.lowercased() == "pdf" {
                show(.pdfReady(title: input.title, url: input.url))
            } else {
                show(.ready(title: input.title, url: input.url, preview: input.preview,
                    issue: input.captureFailure, hasText: input.html?.isEmpty == false))
            }
        } catch {
            show(.failed(message: error.localizedDescription))
        }
    }

    private func saveCapture() {
        guard uploadTask == nil else { return }
        do {
            if pendingInput?.pdf != nil || queuedPDF != nil {
                if queuedPDF == nil, let input = pendingInput, let data = input.pdf {
                    guard let account = CaptureInbox.shared.account else { throw CaptureUploader.Failure.signIn }
                    queuedPDF = try PDFUploadInbox.shared.save(data, filename: input.title ?? "Document.pdf", account: account)
                }
                guard let pdf = queuedPDF else { throw CaptureInbox.InboxError.unavailable }
                pendingInput = nil
                show(.uploading)
                uploadTask = Task { [weak self] in
                    do {
                        try await PDFUploadInbox.shared.upload(pdf)
                        self?.queuedPDF = nil
                        self?.show(.saved(title: pdf.filename, url: URL(fileURLWithPath: pdf.filename), preparing: true))
                    } catch { self?.show(.queued(message: error.localizedDescription)) }
                    self?.uploadTask = nil
                }
                return
            }
            if queuedCapture == nil {
                guard let input = pendingInput else { throw CaptureInbox.InboxError.invalidURL }
                queuedCapture = try CaptureInbox.shared.save(
                    url: input.url, title: input.title, html: input.html,
                    contentFormat: input.contentFormat, replaceExisting: true)
            }
            guard let capture = queuedCapture else { throw CaptureInbox.InboxError.unavailable }
            pendingInput = nil
            show(.uploading)
            uploadTask = Task { [weak self] in
                do {
                    let preparing = try await CaptureUploader().finish(capture, inbox: .shared)
                    try Task.checkCancellation()
                    self?.queuedCapture = nil
                    self?.show(.saved(title: capture.title, url: capture.url, preparing: preparing))
                } catch is CancellationError {
                    // Dismissal leaves the durable queue available to a later retry.
                } catch {
                    guard !Task.isCancelled else { return }
                    let message = (error as? CaptureUploader.Failure)?.localizedDescription
                        ?? "The upload could not finish. Your capture is kept on this device. Retry here, or Magpie will retry when you next open it."
                    self?.show(.queued(message: message))
                }
                self?.uploadTask = nil
            }
        } catch {
            show(.failed(message: error.localizedDescription))
        }
    }

    private func makeConfirmation(state: ShareConfirmationView.Phase) -> ShareConfirmationView {
        ShareConfirmationView(state: state, save: { [weak self] in
            self?.saveCapture()
        }) { [weak self] in
            self?.uploadTask?.cancel()
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
    }

    private func show(_ state: ShareConfirmationView.Phase) {
        confirmation?.rootView = makeConfirmation(state: state)
        if state.isSaved || state.isFailure {
            UINotificationFeedbackGenerator().notificationOccurred(state.isSaved ? .success : .error)
        }
        UIAccessibility.post(
            notification: .announcement, argument: "\(state.heading). \(state.message)")
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        uploadTask?.cancel()
    }
}

private struct ShareConfirmationView: View {
    enum Phase {
        case saving
        case uploading
        case queued(message: String)
        case ready(title: String?, url: URL, preview: String?, issue: String? = nil, hasText: Bool = true)
        case pdfReady(title: String?, url: URL)
        case saved(title: String?, url: URL, preparing: Bool = false)
        case failed(message: String)

        var heading: String {
            switch self {
            case .saving: "Preparing article…"
            case .uploading: "Saving to Magpie…"
            case .queued: "Save not finished"
            case .ready: "Save to Magpie"
            case .pdfReady: "Save PDF to Magpie"
            case .saved: "Saved to Magpie"
            case .failed: "Couldn't save article"
            }
        }

        var message: String {
            switch self {
            case .saving: "Getting this page ready to save."
            case .uploading: "Saving to your account. Keep this pane open until saving finishes."
            case .queued(let message): message
            case .pdfReady:
                "Datalab receives this PDF or its link to prepare it for reading and listening. Your saved PDF stays private to your Magpie account."
            case .ready(_, _, _, let issue, let hasText):
                if issue == "website-sign-in" {
                    "This page requires a website sign-in or subscription. Return to Safari, sign in and share the unlocked article again. You can also save only its link."
                } else if issue == "page-identity" {
                    "The page does not match its article address. Return to Safari, reload it and share again, or save only its link."
                } else if hasText {
                    "Article text captured. Check the opening before saving; a website may still supply only a preview."
                } else {
                    "Magpie could not confidently capture this article. Return to Safari, check that the article has loaded and share again, or save only its link."
                }
            case .saved(_, _, let preparing):
                preparing ? "Your PDF is saved. Magpie is preparing it for reading and listening; you can close this pane." : "Your article is saved and ready for reading and listening in Magpie."
            case .failed(let message): message
            }
        }

        var isSaving: Bool {
            switch self {
            case .saving, .uploading: true
            default: false
            }
        }

        var isFailure: Bool {
            switch self {
            case .failed, .queued: true
            default: false
            }
        }

        var isSaved: Bool {
            if case .saved = self { return true }
            return false
        }

        var isReady: Bool {
            if case .ready = self { return true }
            if case .pdfReady = self { return true }
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

                    if case .saved(let title, let url, _) = state {
                        articlePreview(title: title, url: url)
                    }

                    if case .ready(let title, let url, let preview, _, let hasText) = state {
                        articlePreview(title: title, url: url, preview: preview)
                        VStack(spacing: 16) {
                            Text("Already saved? This updates your copy. If the text changes, listening starts from the beginning.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                            Button(action: save) {
                                Text(hasText ? "Save article" : "Save to Magpie")
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

                    if case .pdfReady(let title, let url) = state {
                        articlePreview(title: title, url: url)
                        Button("Save PDF", action: save)
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        Button("Cancel", action: done)
                            .frame(minHeight: 44)
                    }

                    if !state.isReady {
                        if case .queued = state {
                            Button(action: save) {
                                Text("Retry")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity, minHeight: 32)
                            }
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.roundedRectangle(radius: 16))
                            .controlSize(.large)
                        }
                        Button(action: done) {
                            Text(state.isSaving ? "Finish later" : "Done")
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 32)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.roundedRectangle(radius: 16))
                        .controlSize(.large)
                        .disabled({ if case .saving = state { return true }; return false }())
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
