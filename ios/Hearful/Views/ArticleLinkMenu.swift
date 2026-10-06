import WebKit

@MainActor
enum ArticleLinkMenu {
    static func configuration(
        for url: URL?, save: @escaping @MainActor (URL) -> Void
    ) -> UIContextMenuConfiguration? {
        guard let url,
            ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
            url.host != nil, url.user == nil, url.password == nil
        else { return nil }

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { suggested in
            let saveAction = UIAction(
                title: "Save to Magpie", image: UIImage(systemName: "bookmark")
            ) { _ in save(url) }
            return UIMenu(children: [saveAction] + suggested)
        }
    }
}
