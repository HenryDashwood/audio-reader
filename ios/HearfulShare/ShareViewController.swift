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
        view.backgroundColor = .systemGroupedBackground
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
                            contentFormat: "pdf"))
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
            case .saving, .ready, .pdfReady: "Save to Magpie"
            case .uploading: "Saving to Magpie…"
            case .queued: "Save not finished"
            case .saved: "Saved to Magpie"
            case .failed: "Can't save this"
            }
        }

        var message: String {
            switch self {
            case .saving: "Getting this page ready to save."
            case .uploading: "Saving to your account. Keep this pane open until saving finishes."
            case .queued(let message): message
            case .pdfReady:
                "Magpie turns this PDF into text you can listen to. Datalab prepares it privately for your account."
            case .ready(_, _, _, let issue, let hasText):
                if issue == "website-sign-in" {
                    "This site only shows the full article after you sign in. Sign in to it in Safari, then share the article again."
                } else if issue == "page-identity" {
                    "The page does not match its article address. Reload it in Safari and share it again."
                } else if issue != nil {
                    "Magpie could not capture this article. Check that it has loaded in Safari and share it again."
                } else if hasText {
                    "Article text found. Saving again updates your copy."
                } else {
                    "Magpie will fetch the article from this link when it saves."
                }
            case .saved(_, _, let preparing):
                preparing ? "Your PDF is saved. Magpie is preparing it for reading and listening; you can close this pane." : "Your item is saved to Magpie. It will download for offline reading in the app."
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

        /// A capture problem Safari can fix: the person can go back, or keep just the link.
        var needsSafari: Bool {
            if case .ready(_, _, _, let issue, _) = self { return issue != nil }
            return false
        }
    }

    private enum Tone { case progress, good, info, warning, error }

    let state: Phase
    var save: () -> Void = {}
    let done: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 18) {
                    header
                    if let item {
                        ItemCard(title: item.title, url: item.url, preview: item.preview, isPDF: item.pdf)
                    }
                    status
                    actions
                        .padding(.top, 4)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .frame(maxWidth: 476)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .top)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private var header: some View {
        ZStack {
            HStack(spacing: 8) {
                MagpieIcon(size: 28)
                Text(state.heading)
                    .font(.headline)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
            }
            .padding(.horizontal, 52)
            HStack {
                Button(action: done) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel(state.isSaving ? "Finish later" : (state.isReady ? "Cancel" : "Close"))
                .disabled({ if case .saving = state { return true }; return false }())
                Spacer()
            }
        }
        .frame(minHeight: 44)
    }

    private var item: (title: String?, url: URL, preview: String?, pdf: Bool)? {
        switch state {
        case .ready(let title, let url, let preview, _, _): (title, url, preview, false)
        case .pdfReady(let title, let url): (title, url, nil, true)
        case .saved(let title, let url, let preparing): (title, url, nil, preparing)
        default: nil
        }
    }

    private var tone: Tone {
        switch state {
        case .saving, .uploading: .progress
        case .queued: .warning
        case .failed: .error
        case .saved: .good
        case .pdfReady: .info
        case .ready(_, _, _, let issue, let hasText): issue != nil ? .warning : (hasText ? .good : .info)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch tone {
        case .warning, .error:
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: tone == .error ? "exclamationmark.circle" : (state.needsSafari ? "lock" : "exclamationmark.triangle"))
                    .foregroundStyle(tone == .error ? Color.red : Color.orange)
                Text(state.message)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.subheadline)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background((tone == .error ? Color.red : Color.orange).opacity(0.14), in: .rect(cornerRadius: 20))
            .accessibilityElement(children: .combine)
        default:
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if tone == .progress {
                    ProgressView()
                } else {
                    Image(systemName: tone == .good ? "checkmark.circle" : (isPDF ? "lock" : "link"))
                        .foregroundStyle(.tint)
                }
                Text(state.message)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.subheadline)
            .padding(.horizontal, 6)
            .accessibilityElement(children: .combine)
        }
    }

    private var isPDF: Bool {
        if case .pdfReady = state { return true }
        return false
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 6) {
            switch state {
            case .ready where state.needsSafari:
                PrimaryButton(title: "Back to Safari", action: done)
                Button("Save link only", action: save)
                    .frame(maxWidth: .infinity, minHeight: 48)
            case .ready, .pdfReady:
                PrimaryButton(title: "Save", action: save)
            case .queued:
                PrimaryButton(title: "Retry", action: save)
            case .saved:
                PrimaryButton(title: "Done", action: done)
            case .failed:
                Button(action: done) {
                    Text("Close").font(.headline).frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .tint(.secondary)
            case .saving, .uploading:
                EmptyView()
            }
        }
    }
}

private struct PrimaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.headline).frame(maxWidth: .infinity, minHeight: 40)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
    }
}

/// The app icon's mark on its dark tile, so the pane is recognisably Magpie in light and dark.
private struct MagpieIcon: View {
    let size: CGFloat

    var body: some View {
        Image("MagpieMark")
            .resizable()
            .scaledToFit()
            .padding(size * 0.12)
            .frame(width: size, height: size)
            .background(Color(red: 0.067, green: 0.075, blue: 0.094), in: .rect(cornerRadius: size * 0.26))
            .accessibilityHidden(true)
    }
}

private struct ItemCard: View {
    let title: String?
    let url: URL
    let preview: String?
    let isPDF: Bool

    private var pdf: Bool { isPDF || url.pathExtension.lowercased() == "pdf" }
    private var source: String? {
        guard let host = url.host(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
    private var name: String {
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
        if pdf, !url.lastPathComponent.isEmpty, url.lastPathComponent != "/" { return url.lastPathComponent }
        return source ?? url.absoluteString
    }
    private var detail: String {
        if pdf { return source.map { "PDF from \($0)" } ?? "PDF document" }
        return source.map { "Article from \($0)" } ?? url.absoluteString
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 4) {
                    Image(systemName: pdf ? "doc.text" : "doc.plaintext")
                        .font(.title3)
                    Text(pdf ? "PDF" : "PAGE")
                        .font(.caption2.weight(.bold))
                }
                .foregroundStyle(.tint)
                .frame(width: 52, height: 64)
                .background(Color.accentColor.opacity(0.14), in: .rect(cornerRadius: 12))
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(name)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let preview, !preview.isEmpty {
                Divider()
                Text(preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .accessibilityLabel("Article begins: \(preview)")
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 26))
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

#Preview("PDF") {
    ShareConfirmationView(
        state: .pdfReady(title: "2205.14135v2.pdf", url: URL(string: "https://arxiv.org/pdf/2205.14135")!)
    ) {}
}

#Preview("Needs website sign-in") {
    ShareConfirmationView(
        state: .ready(title: "Why we still write letters", url: URL(string: "https://members.example.com/letters")!,
            preview: nil, issue: "website-sign-in", hasText: false)
    ) {}
}
