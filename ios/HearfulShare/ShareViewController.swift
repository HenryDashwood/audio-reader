import UIKit
import UniformTypeIdentifiers

@MainActor
final class ShareViewController: UIViewController {
    private let status = UILabel()
    private let done = UIButton(type: .system)
    private var started = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        status.font = .preferredFont(forTextStyle: .body)
        status.adjustsFontForContentSizeCategory = true
        status.numberOfLines = 0
        status.text = "Saving to Magpie…"
        done.isEnabled = false
        done.setTitle("Done", for: .normal)
        done.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        done.addTarget(self, action: #selector(finish), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [status, done])
        stack.axis = .vertical
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 32),
        ])
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
                            html: result["html"] as? String))
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
            try CaptureInbox.shared.save(url: input.url, title: input.title, html: input.html)
            status.text =
                "Saved on this device. Open Magpie to prepare the article for reading and listening."
        } catch { status.text = error.localizedDescription }
        done.isEnabled = true
        UIAccessibility.post(notification: .announcement, argument: status.text)
    }

    @objc private func finish() { extensionContext?.completeRequest(returningItems: nil) }
}
